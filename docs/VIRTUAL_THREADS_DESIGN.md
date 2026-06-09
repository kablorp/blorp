# Virtual Threads Runtime Roadmap

This document defines the target shape and implementation roadmap for blorp's
fiber runtime. It distinguishes current implementation facts from future
runtime hardening work.

## Goal

Blorp should support large numbers of cheap, stackful virtual threads while
preserving the language's value-semantics model:

- `concurrent:`, `for ... concurrently(limit:)`, and `List.concurrent(...)`
  remain the primary user-facing APIs.
- A blocked task parks its fiber instead of blocking an OS worker thread.
- Spawning and running a no-op task is cheap enough that users can choose
  clear structured concurrency without manually batching tiny tasks.
- Sleeping, channel waits, task joins, and eventually supported I/O scale with
  the number of ready fibers, not with the number of parked fibers.

The runtime may use internal shared scheduler data, but user values must not
become mutually editable by multiple fibers.

## Safety Invariants

These invariants are non-negotiable:

- **No shared mutable Blorp values.** A Blorp value graph is not editable by two
  fibers at once. COW containers may mutate only when uniquely owned.
- **One live stack owner.** A stack belongs to exactly one live fiber. A stack
  pool may only own stacks that are not attached to a live coroutine.
- **One scheduling owner.** A fiber handle is in exactly one state: running on
  one worker, queued on one run queue, parked in one wait structure, completed,
  or free. It is never concurrently owned by two queues.
- **Channels transfer values, not mutable access.** Sending through a channel
  retains/copies/transfers immutable values according to the ownership ABI; it
  must not create a shared mutable reference.
- **Cancellation is structured.** A timeout or parent cancellation stops child
  work at explicit cancellation points. Cleanup of managed task-local values
  must be represented explicitly before cancellation is made more aggressive.
- **Runtime sharing is encapsulated.** Mutexes, atomics, and lock-free queues
  are allowed inside the runtime scheduler only. They do not change source
  language semantics.

## Inspiration

The target borrows selectively from existing runtimes:

- **BEAM:** process isolation, message passing, supervision-oriented mental
  model, and fairness by reduction-style budgeting.
- **Go:** M:N scheduling, worker-local run queues, work stealing, cheap stacks,
  and separate integration paths for blocking system calls.
- **Java Loom:** blocking-style user code that unmounts from carrier threads at
  runtime-managed blocking points.
- **Kotlin coroutines:** structured cancellation semantics.

Blorp should not copy Rust async's source-level `Future` model. Stackful fibers
fit blorp's readable structured-concurrency surface better than explicit
polling, pinning, or `async`/`await`.

## Target Runtime Shape

### OS Workers

The runtime owns a bounded number of OS worker threads. By default this is the
host logical CPU count, with explicit overrides from `BLORP_THREADS` or the
CLI `--threads` option.

Workers are carrier threads. They execute runnable fibers and runtime work
items, but parked fibers must not occupy a worker.

Per-operation width is a separate concept from worker-pool capacity.
`concurrent(max_threads: N)` should limit that block's active child work; it
should not permanently resize the process-wide worker pool or silently cap
later `List.parallel` / vector-parallel operations. Today those concepts are
partially coupled because the first pool initializer wins, which can make an
early `concurrent(max_threads: 2)` benchmark force later data-parallel
benchmarks onto two workers. The target design keeps global capacity,
structured-concurrency block limits, and data-parallel operation limits as
distinct runtime values.

### Fiber Lifecycle

Target lifecycle:

```text
free fiber/stack -> created -> queued -> running -> parked/queued -> completed -> free
```

Fiber creation should avoid hot-path `mmap`/`mprotect` and repeated coroutine
metadata allocation. The target is:

- cache fiber objects;
- cache guarded stack regions;
- keep one guard page per stack region in debug/safety configurations;
- poison or clear reused stacks in sanitizer/debug modes;
- return stacks to the pool only after the coroutine is dead and no wait queue
  can still reference the fiber handle.

### Scheduler

The scheduler should move from one global run queue to:

- one local run queue per worker;
- a global injection queue for external wakes and first-time submissions;
- work stealing from other workers when a local queue is empty;
- ownership-transfer queue operations that preserve the "one scheduling owner"
  invariant.

This reduces global mutex contention and improves locality for bursts of tiny
tasks.

### Timers

The timer queue should not be a sorted linked list scanned or inserted under a
global lock for every sleeping fiber. The target is one of:

- per-worker timer heaps plus occasional cross-worker wake injection; or
- a timing wheel for common millisecond-scale sleeps.

Sleeping fibers are parked fiber handles. Timer expiration transfers the handle
back to a run queue; it does not mutate user-visible Blorp values.

### Blocking Operations

Every Blorp blocking operation should either park the current fiber or run on a
bounded blocking pool:

- `sleep`
- channel `send` / `recv`
- task join
- future file, process, network, and terminal APIs

No normal Blorp blocking operation should pin an OS worker indefinitely. If a C
library call cannot be made fiber-aware, it should be isolated behind a
blocking-worker path with explicit backpressure.

### Fairness

The long-term target is cooperative fairness with compiler help:

- runtime calls are cancellation/yield points;
- loops can receive generated checkpoints when needed;
- pure CPU-bound work can be interrupted at predictable reduction-style
  intervals without exposing preemption machinery to users.

Fairness must not introduce shared mutable source values. It only controls when
a fiber gives the worker back to the scheduler.

## Performance Targets

Measure cold and warm cases separately. Cold numbers include thread-pool and
cache initialization; warm numbers measure steady-state scheduler cost.

Initial targets for a warmed runtime on a laptop-class machine:

| Case | Current observation | Target |
| --- | ---: | ---: |
| 1,000 no-op fibers | 5.4-8.6 ms | <= 1 ms |
| 5,000 no-op fibers | 22.6-29.3 ms | <= 5 ms |
| 10,000 no-op fibers | 37.4-43.6 ms | <= 10 ms |
| 50 fibers sleeping 50 ms | 51-55 ms | <= 51 ms |
| 500 fibers sleeping 10 ms | 13 ms | <= 11 ms |
| 5,000 fibers sleeping 10 ms | 44 ms | <= 15 ms |

These targets are intentionally practical rather than theoretical. They should
be revised only with benchmark data and with the benchmark source checked into
`benchmarks/`.

## Roadmap Discipline

Concurrency performance work must carry cleanup and hardening with it. Each
slice should be small enough to prove independently and should land in this
order:

- write a failing compiler, runtime, stress, or benchmark regression first;
- name the invariant the change is protecting;
- represent correctness-critical distinctions explicitly in Core IR, runtime
  state, or a closed registry, not in C name prefixes, comments, or coupled
  booleans;
- run the relevant thread-count matrix, leak-check, sanitizer, and benchmark
  gates before claiming the slice is complete;
- remove stale code and generated artifacts that could make future agents edit
  or measure the wrong implementation.

## Current Implementation Snapshot

This file is the source of truth for runtime scheduler and virtual-thread
hardening. `docs/CONCURRENCY_DESIGN_PROPOSAL.md` owns source-language and
standard-library ergonomics; this file owns the runtime state machine, wake
protocol, wait ownership, and verification gates.

Already implemented or partially implemented:

- scheduler instrumentation through `std/instrumentation.brp`, `runtime.c`, and
  `runtime_decl.c`;
- scheduler debug observability gated by `BLORP_SCHEDULER_DEBUG`, including
  fiber snapshots and conservative assertions at enqueue, park, timer insert,
  channel wait enqueue, worker resume, and wake handoff boundaries;
- runtime-internal `blorp_FiberState` lifecycle tracking with named transition
  helpers for created, queued, running, parked, completed, and free states;
- runtime-internal `blorp_FiberWakeCause` tracking for ready, timeout,
  cancelled, closed, and sealed wakeups, with dynamic wake sites routed through
  `blorp_fiber_wake` where the existing parked-to-runnable CAS chooses the
  winning cause;
- runtime-internal `blorp_FiberWaitOwnerKind` tracking for sleep, task join,
  channel send, channel receive, select, and IO wait categories, with debug
  snapshots and assertions for parked fibers without a wait owner;
- a runtime-internal `blorp_FiberWaitOperation` value minted by beginning a
  wait, carrying the fiber, wait owner, and operation id through waiter setup
  and through scheduler-owned timer, task-join, channel, and select waiter
  records;
- a named ready-to-park transition helper that marks an explicit wait operation
  parked only after a wait owner and wait operation id exist, replacing
  open-coded current-fiber `parked = 1` stores in wait paths;
- a named abandon-before-park helper that clears the parked and pending-wake
  mirrors only for the exact wait operation being abandoned, replacing
  open-coded cleanup in IO readiness-before-park and select ready-before-park
  paths;
- `blorp_fiber_park` takes the explicit wait operation and verifies, in
  scheduler debug mode, that park entry and resume still refer to that exact
  operation;
- shared timer-wait install/remove helpers for timed waits, so sleep, timed
  task joins, timed channel waits, and timed select use one runtime-owned path
  for preparing the stable per-fiber timer waiter and removing it after resume;
- runtime-internal wait operation ids on fibers, plus stable per-fiber timer
  waiter records that let timer expiry distinguish the current parked operation
  from a stale deadline entry left behind by an earlier wait;
- the timer heap now stores `blorp_TimerWaiter*` entries with deadline, heap
  index, wait operation id, and wake cause instead of raw `blorp_Fiber*`
  entries and loose timer fields on the fiber;
- channel send/receive wait queues now use explicit stack-scoped waiter records
  carrying fiber, wait operation id, wait kind, deadline, wake reason, and a
  queue link, instead of identifying a channel wait by raw `blorp_Fiber*` alone;
- channel-backed `select` waiters now carry the selected fiber's wait operation
  id and wake cause, so stale select waiters cannot wake a later operation on
  the same fiber;
- task joins now use explicit stack-scoped waiter records carrying fiber, wait
  operation id, and wake cause, so a stale timeout or completion cannot target a
  later wait operation on the same fiber;
- fiber object caching and guarded stack-region caching;
- worker-local run queues, owner-pinned queues, a global fallback queue, and
  work stealing;
- explicit Core concurrency nodes and invariants for `CConcurrent`,
  `CConcurrentlyLoop`, `CDetach`, `CSelect`, task scopes, capture kinds, output
  modes, limits, timeouts, and result contracts;
- cancellation cleanup frames for task-local managed values, active child task
  handles, dynamic fan-out windows, partial result lists, and owned fan-out
  iterables;
- deterministic cancellation test hooks and leak baselines for channel waits,
  joins, dynamic fan-out, select, sleep, and TCP accept/read;
- explicit builtin metadata for cancellation points and OS-worker-blocking
  operations;
- TCP/UDP reactor waiters with operation ids, wait owners, deadlines, exact
  waiter removal, and typed wake reasons.

Known remaining weakness:

- general fiber lifecycle still depends on coupled fields such as `parked`,
  `queued`, `running`, `wake_pending`, timer waiter heap state, channel wait
  kind, and channel wake reason; the lifecycle enum is currently a checked
  mirror rather than the sole source of truth;
- channel send/receive waits, channel-backed select waits, task joins, and
  timer waits now store the same explicit wait-operation token in their waiter
  records, use a shared ready-to-park transition, and use shared timer-wait
  install/remove helpers for timer-backed waits. Parking itself also takes that
  explicit wait operation. Channel send/receive queue drains now return a typed
  wake set that distinguishes ready waiters from expired timeout winners.
  Remaining duplication is now in owner-specific cleanup and queue handling
  rather than in the fiber/owner/id identity check;
- cancellation now enters the same `blorp_fiber_wake` boundary, but
  cancellation-before-park remains a cooperative pending-wake case until all
  wait owners share one explicit wait-operation abstraction;
- generated C still emits some deadline arithmetic and task-window sequencing
  directly instead of calling one narrow runtime task-scope API, but task batch
  setup, batch flushing, task slot cleanup registration, task joins, task
  releases, and task-window storage cleanup are behind runtime helpers;
- one-waiter-per-operation TCP policy is explicit, but not yet generalized to a
  common runtime wait-owner model.

## Runtime Hardening Roadmap

This roadmap supersedes the older mixed performance/cleanup sequence. The next
work should make runtime scheduler states explicit first, then improve
performance on top of the stronger model.

### Phase 0: Scheduler Observability

Goal: make scheduler bugs diagnosable before changing behavior.

Work:

- Add debug-only scheduler assertions around every enqueue, park, wake, timer
  insert/remove, waiter install/remove, task join, task completion, and fiber
  recycle boundary.
- Add a compact debug snapshot helper for fibers that reports lifecycle state,
  queue ownership, wait owner, timer waiter heap index, channel wait kind, wake
  reason, owning worker, coroutine status, task pointer, and cancellation state.
- Detect impossible live states, especially incomplete fibers that are not
  running, queued, or parked in a wait owner.
- Include enough state in abort messages to identify the owner, wake source,
  and last transition.
- Keep timing backstops out of tests when the real invariant is "this fiber is
  parked here." Use deterministic harnesses or explicit debug observations
  instead.

Tests:

- add focused runtime tests or compiler-unit tests for the debug snapshot and
  invariant helpers where possible;
- rerun existing cancellation and leak baselines to prove no behavior changed.

Acceptance:

```bash
make
scripts/test compiler-unit
scripts/test runtime --serial
scripts/test leak --serial
```

Initial implementation: `BLORP_SCHEDULER_DEBUG` enables internal runtime
assertions and fiber snapshots. The first assertions deliberately cover only
state combinations that are already illegal in the current implementation
(`queued and parked`, `running and queued`, and dead fibers still scheduled or
parked). The later wait-owner work makes timer waiter identity exact; channel
and select queues may still observe transient stale waiter records after a
winning wake, but those records carry operation ids and are skipped instead of
being authoritative.

### Phase 1: Explicit Fiber Lifecycle State

Goal: replace lifecycle-relevant flag combinations with one authoritative
state transition model.

Introduce a runtime-internal enum shaped like:

```c
typedef enum {
    BLORP_FIBER_FREE,
    BLORP_FIBER_CREATED,
    BLORP_FIBER_QUEUED,
    BLORP_FIBER_RUNNING,
    BLORP_FIBER_PARKED,
    BLORP_FIBER_COMPLETED
} blorp_FiberState;
```

The `CREATED` state is important. Today new fibers start with `parked = 1` so
the first schedule call can reuse the parked-to-runnable CAS. In the target
model, a never-run fiber should not pretend to be parked in a wait structure.

Work:

- Add `blorp_FiberState` and transition helpers without removing the existing
  fields immediately.
- Make transition helpers the only normal path for lifecycle changes:
  `fiber_mark_created`, `fiber_mark_queued`, `fiber_mark_running`,
  `fiber_mark_parked`, `fiber_mark_completed`, `fiber_mark_free`.
- Define the synchronization rule for state changes in code: either the
  existing fiber state lock owns transitions, or a documented atomic CAS helper
  owns them. Do not let the enum become another loosely coupled field.
- Assert legal previous states at every transition.
- Mirror existing fields from the enum during the migration only where needed
  for compatibility with current code.
- Preserve behavior first. This phase should not change scheduling policy.

Illegal states to remove:

- queued and parked at the same time;
- running on one worker while queued on another worker's run queue;
- completed or free while still reachable from a wait queue or timer heap;
- created but neither queued nor exclusively owned by the spawner;
- parked without an explicit wait owner.

Tests:

- run no-op, sleep, channel send/recv, timed send/recv, join, select, and TCP
  accept/read smoke cases under scheduler assertions;
- run the same cases under `BLORP_THREADS=1,2,4,8`.

Initial implementation: `blorp_FiberState` and lifecycle transition helpers are
present in `runtime.c`, and scheduler debug snapshots report lifecycle state.
The old `parked`, `queued`, `running`, and `wake_pending` fields remain
compatibility mirrors for the current scheduler. New fibers still use the
historical first-schedule `parked = 1` convention, but the lifecycle state
records `CREATED` before the first queue transition. Recycled fibers now clear
stale coroutine pointers before entering the object cache.

### Phase 2: One Wake Path

Goal: route all dynamic wakeups through one scheduler transition.

Work:

- Introduce an explicit wake cause enum shared by timer, channel, join, select,
  IO, and cancellation paths:

  ```c
  typedef enum {
      BLORP_WAKE_READY,
      BLORP_WAKE_TIMEOUT,
      BLORP_WAKE_CANCELLED,
      BLORP_WAKE_CLOSED,
      BLORP_WAKE_SEALED
  } blorp_FiberWakeCause;
  ```

- Replace direct calls to `blorp_fiber_schedule` from wait structures with a
  single `blorp_fiber_wake(fiber, cause, owner)` helper.
- Fold or drastically simplify `blorp_fiber_request_cancel_wake`: cancellation
  should set task cancellation state, then wake the task fiber with
  `BLORP_WAKE_CANCELLED`.
- Keep the "wake while still inside `mco_resume`" handoff, but make it an
  internal branch of the common wake helper rather than a separate cancellation
  protocol.
- Ensure exactly one waker wins each parked operation and records the winning
  cause.

Tests:

- deterministic cancellation at every current cancellation point;
- wake-before-yield races for yield, send, recv, join, sleep, select, and TCP
  waits;
- repeated stress runs under `BLORP_THREADS=1,2,4,8`.

Initial implementation: `blorp_FiberWakeCause` is present and dynamic wake
sites for timers, IO waiters, task completion, channels, and select now use
`blorp_fiber_wake`. The helper records the wake cause only after the existing
parked-to-runnable CAS succeeds, so a losing timeout/readiness race cannot
overwrite the winning cause. Cancellation also delegates through
`blorp_fiber_wake`; the helper owns the cooperative cancellation-before-park
pending-wake case. Initial fiber scheduling still uses the lower-level schedule
helper because a never-run fiber is not being woken from a wait.

### Phase 3: Wait Owner Model

Goal: every parked fiber is owned by exactly one wait structure.

Use the existing IO waiter model as the precedent. TCP/UDP waiters already carry
wait ids, owner descriptors, exact operation identity, deadlines, install/remove
helpers, cleanup frames, and typed wake reasons. General scheduler waiters
should converge on the same shape.

Work:

- Add a closed wait-owner descriptor for:
  - timer sleep;
  - task join;
  - channel send;
  - channel receive;
  - select;
  - IO reactor wait.
- Add per-wait operation ids or sequence numbers. Timeout and cancellation must
  remove the exact wait operation, not just "whatever waiter currently matches
  this fiber and kind."
- Move channel send/recv wait queues from raw `blorp_Fiber*` links toward
  waiter records with owner, kind, wake reason, deadline, and cleanup state.
- Move select waiters toward owned waiter records whose lifetime cannot outlive
  the selected operation. Heap allocation is acceptable if it removes
  stack-lifetime ambiguity across cross-thread wakes.
- Move sleeps and timed joins away from raw timer entries that point directly at
  a fiber without an operation identity.
- Make resource cleanup and waiter cleanup part of the same cancellation story:
  if cancellation jumps out of a parked operation, the wait owner is removed and
  managed task-local values are released.

Tests:

- `cancel_after_parked_for_test` coverage for sleep, join, channel send,
  channel receive, timed send, timed receive, select, TCP accept, TCP read, TCP
  connect, and any portable parked TCP write case;
- stale-deadline regression tests where a timed wait is satisfied before its
  deadline and the old deadline later fires;
- a deterministic runtime self-probe proving timer waiters are tied to exact
  wait operation ids, not just fiber pointers or wait-owner kinds;
- channel seal and close wake tests proving waiters are removed once.

Initial implementation: `blorp_FiberWaitOwnerKind` is present on each fiber and
is set before every existing fiber park point for IO, task join, sleep, channel
send, channel receive, and select. `blorp_fiber_park` clears the owner after a
resume; immediate no-yield paths clear it explicitly. Scheduler debug snapshots
include `wait_owner=...`, and debug assertions reject a lifecycle-parked fiber
with no owner.

Beginning a wait now returns a `blorp_FiberWaitOperation` that carries the
fiber, owner, and operation id as one explicit runtime value. Scheduler-owned
waiter records for task joins, channels, select, and timers store that value
directly instead of splitting it back into separate fiber and operation-id
fields or independently reading the current fiber state.
`blorp_fiber_prepare_wait_to_park` asserts, in scheduler debug mode, that this
explicit operation is still current before setting the parked bit. A
deterministic test-only probe exercises this transition without relying on
wall-clock scheduling. `blorp_fiber_abandon_wait_before_park` handles the
opposite edge for ready-before-park and install-failure paths: it can only clear
the prepared parked/pending-wake mirrors if the exact wait operation is still
current. `blorp_fiber_park` also receives the explicit wait operation, so a
wait site cannot yield through the scheduler without naming the operation it
previously began.

The next slice added a monotonic wait operation id to each fiber. Beginning a
wait mints a fresh id; clearing a wait clears the id. Timer insertion records
that exact id, and timer expiry skips entries whose recorded id no longer
matches the fiber's current wait id. This makes stale timer deadlines
non-authoritative for the current operation.

Timer waits now use stable per-fiber `blorp_TimerWaiter` records instead of raw
fiber heap entries. Each timer waiter records the owning fiber, deadline, heap
index, wait operation id, and wake cause. The timer heap stores waiter pointers,
and timer drain wakes through `blorp_timer_waiter_wake`, which rechecks the
current fiber wait id before scheduling. Timer drain makes this stale/current
decision while holding the timer queue lock so a resumed fiber cannot reuse its
stable timer waiter for a later operation before the old deadline has been
classified.

Timer-backed fiber waits now install and remove the timer deadline through
`blorp_fiber_install_timer_wait` and `blorp_fiber_remove_timer_wait`, both
taking the explicit wait operation value. Removal cannot require the operation
to still be current because `blorp_fiber_park` clears the current wait state
before returning; it instead rejects obviously mismatched nonzero timer
identities in scheduler debug mode. These helpers are intentionally smaller
than a full wait-owner abstraction: owner-specific structures still own their
channel/task/select cleanup, while the timer side no longer exposes
`self->timer_waiter` preparation at each wait site.

`std/test.timer_waiter_identity_probe_for_test` now exercises this invariant
without wall-clock scheduling: a waiter captured for an earlier wait is rejected
after the same fiber begins a later wait, while a waiter prepared for the current
operation is accepted. `std/test.current_timer_wait_install_probe_for_test`
checks that the shared install/remove helpers preserve the current wait identity
while registering and unregistering a timer. The existing ready-before-deadline
channel tests remain as end-to-end scheduler regressions, but these self-probes
protect the exact identity rules deterministically.

Channel send/receive queues now use explicit waiter records instead of raw
fiber links. Each waiter records the wait operation id minted at park setup,
the channel wait kind, an optional deadline, and the wake reason chosen by the
winning waker. Channel drains skip stale waiter records whose operation id no
longer matches the fiber's current wait id. Send/receive wake paths consume a
single helper result that makes `ready`, `expired`, and `empty` distinct, so a
future call site cannot silently treat timeout winners as ordinary ready
waiters.

Channel-backed `select` waiters now also record the current select operation id
and selected wake cause. A select wake from another channel or timer can leave
brief stale waiter records on sibling channels; those stale records are ignored
if the fiber has already cleared or moved past that select wait. The remaining
hardening step is to factor the duplicated wait-owner pieces into a common
runtime abstraction.

Task joins now use the same operation-identified shape. Each join wait installs
a stack-scoped `blorp_TaskJoinWaiter` on the task, recording the fiber and the
wait operation id minted before parking. Task completion extracts that exact
waiter and wakes it through `blorp_fiber_wake`; stale join waiters are skipped
if the fiber has already cleared or moved to another wait operation. Timed and
uncancellable joins remove the installed waiter immediately after resume, before
cancellation cleanup can leave the join scope. The task stores an explicit join
slot state, so stale waiters can be replaced deliberately while a second current
join waiter is rejected as a scheduler invariant failure instead of overwriting
the first waiter.

### Phase 4: Runtime Task Scope API

Goal: narrow generated C so Core emission does not open-code scheduler
protocol.

Core should continue to describe structured intent. Runtime should own dynamic
execution.

Keep these Core nodes:

- `CConcurrent`
- `CConcurrentlyLoop`
- `CDetach`
- `CSelect`

Move toward runtime APIs like:

```c
blorp_task_scope_begin(...)
blorp_task_scope_spawn(...)
blorp_task_scope_join(...)
blorp_task_scope_cancel(...)
blorp_task_scope_end(...)
```

Work:

- Move task batch setup, flushing, task-handle cleanup registration, timeout
  cancellation, and join result draining behind runtime helpers.
- Preserve the visible ABI: fixed bindings and collected fan-out still produce
  `Result[T, ConcurrencyError]` / `TaskResult[T]`.
- Keep compiler invariants focused on types, captures, scopes, output modes,
  and cleanup obligations.
- Keep codegen responsible for value representation, ARC/COW ownership, and
  source-level result shape, but not low-level scheduler transitions.

Initial implementation:

- Direct task-slot joins are encapsulated by
  `blorp_concurrent_join_cleanup_release(&task_slot, timeout_ms)`. Task-window
  joins call through this helper after flushing pending spawns, so the runtime
  performs the scheduler join, pops the task cleanup frame for the exact slot,
  releases the task handle, and nulls the slot on normal completion. If
  cancellation happens while joining, the existing task cleanup frame remains
  installed and cancellation drains it.
- Batch-level spawning is encapsulated by
  `blorp_concurrent_spawn_owned_cleanup_in_batch` and
  `blorp_concurrent_spawn_owned_rc_cleanup_in_batch`. Task-window spawn helpers
  call through these helpers, so the runtime writes the exact task slot and
  immediately registers that slot on the cancellation cleanup stack. Generated C
  no longer emits a spawned task without its cleanup frame as a separate
  intermediate state.
- List fan-out uses `BLORP_CONCURRENT_TASK_FLUSH_PERIODIC`; resource-source
  fan-out uses `BLORP_CONCURRENT_TASK_FLUSH_IMMEDIATE`. Generated C chooses the
  policy, but the runtime owns the batch, the periodic flush interval, and the
  unconditional flush required before joins.
- Dynamic fan-out now uses `blorp_ConcurrentTaskWindow` instead of two
  generated parallel arrays for task handles and cleanup frames. The runtime
  allocates, zero-initializes, and frees the paired storage as one cleanup
  protected object, so generated C cannot accidentally size, free, or clean up
  the task slots and cleanup slots inconsistently.
- Task-window protection is also runtime-owned through
  `blorp_concurrent_task_window_begin` /
  `blorp_concurrent_task_window_end`. Codegen still declares the stack frame
  storage, but it no longer manually sequences task-window allocation,
  cancellation cleanup registration, cleanup-pop, and free.
- Task-window cleanup frames are marked with a distinct cleanup kind. During
  cancellation, the cleanup drain flushes all active task-window batches before
  any task cleanup frame waits for a child. This prevents cancellation from
  waiting on a child task that was spawned into a pending batch but not yet made
  runnable.
- Task-window cleanup also treats non-null task slots as owned fallback state:
  it pops any still-registered task cleanup frame, cancels/joins/releases the
  task, and nulls the slot before freeing paired storage. Normal codegen still
  joins slots explicitly; the cleanup sweep is a runtime guardrail for
  cancellation and future emitter mistakes.
- `std/test.task_window_pending_cleanup_probe_for_test` deterministically
  exercises this fallback by creating a task window with child fibers still in
  its pending batch, then ending the window and verifying cleanup flushes,
  joins, releases, and clears storage without relying on wall-clock time.
- Task-window slot operations now go through
  `blorp_concurrent_task_window_spawn_owned`,
  `blorp_concurrent_task_window_spawn_owned_rc`, and
  `blorp_concurrent_task_window_join_release`. Generated C no longer indexes
  `window.tasks[slot]` and `window.cleanups[slot]` directly, so the runtime owns
  the invariant that a task handle and its cancellation cleanup frame come from
  the same bounded slot.
- Dynamic fan-out task-window spawning now owns its spawn batch internally.
  Generated C chooses only the flush policy (`periodic` for list fan-out,
  `immediate` for resource-source fan-out) and no longer declares
  `blorp_TaskBatch`, initializes it, flushes periodically, or remembers to flush
  before joins. `blorp_concurrent_task_window_join_release` flushes pending
  batched spawns before waiting, so the runtime owns the "scheduled before
  joined" invariant.
- Codegen still owns result representation, task slot numbering, and source
  syntax shape. Fixed `concurrent:` blocks now use the same runtime-owned
  task-window spawn, batch, join, and cleanup protocol as dynamic fan-out, so
  generated C no longer has a separate raw task-batch path for fixed bindings.
- Leak baselines now cover cancellation while parked in both fixed
  `concurrent:` joins and dynamic `List.concurrent` joins. These protect the
  invariant that active child task slots remain registered on the cancellation
  cleanup stack until a normal join helper call transfers and releases them.
- Per-operation concurrency limits no longer initialize the process-wide worker
  pool size. Generated C calls `blorp_thread_pool_ensure_initialized()` and
  passes limits only to task-window sizing/chunking. `BLORP_THREADS` and
  `--threads` remain the global carrier-thread capacity controls.
- Fixed `concurrent(max_threads: N)` now chunks fixed bindings through a
  task-window of capacity `N`, so the parameter bounds that block's active
  child tasks instead of permanently resizing the runtime pool.

Tests:

- generated-C audit tests for fixed `concurrent:`, bounded
  `for ... concurrently`, `List.concurrent`, timeouts, managed results, and
  cancellation cleanup;
- leak baselines for timeout while joining fixed and dynamic child tasks.

### Phase 5: Scheduler Capacity And Queue Policy

Goal: improve scalability without changing source semantics.

Work:

- Keep global OS-worker capacity distinct from per-operation concurrency
  limits. `BLORP_THREADS` and `--threads` configure carrier capacity;
  `concurrent(max_threads:)`, `for ... concurrently(limit:)`,
  `List.concurrent(limit, ...)`, and data-parallel operation widths constrain
  individual operations.
- Stop any remaining path where an early per-operation limit silently becomes
  the process-wide worker count.
- Revisit owner-pinned queues, global injection, and work stealing after the
  state/wake/wait-owner model is explicit.
- Use instrumentation to decide whether owner pinning or global injection is
  still the right policy for external wakes.

Tests and benchmarks:

- thread-count matrix for no-op fibers, bounded fan-out, sleep groups, channel
  roundtrips, and mixed channel/timer workloads;
- benchmark guardrails for spawn/join, park/wake, timeout setup/cancel, and
  bounded fan-out.

Initial implementation:

- `blorp_thread_pool_ensure_initialized()` is the generated-code entrypoint for
  carrier-pool initialization. It uses the runtime default/override path and
  intentionally accepts no operation-width argument.
- `for ... concurrently(limit:)`, `List.concurrent`, resource-source fan-out,
  and fixed `concurrent(max_threads:)` now keep operation width local to their
  task-window capacity instead of passing it to `blorp_thread_pool_init`.

### Phase 6: Timer Scalability

Goal: make large numbers of parked timers scale with parked timer count, not
with global lock contention or stale entries.

Work:

- After wait-owner identity is in place, decide between per-worker timer heaps
  and a timing wheel for common millisecond-scale sleeps.
- Keep timer entries tied to exact wait operations.
- Make large and overflowing deadlines explicit and consistent across sleep,
  channel timeouts, select, joins, and IO deadlines.

Tests:

- large sleep groups;
- mixed sleep/channel/select loads;
- deterministic timer identity probes plus end-to-end stale timer entry
  regressions;
- timeout overflow and saturation cases.

Initial implementation:

- Runtime timeout arithmetic now has shared saturated helpers for converting
  millisecond durations to nanoseconds, adding monotonic deadlines from either
  `now` or a captured start time, and creating realtime deadlines for
  condition-variable waits.
- Task joins, sleep, channel timeouts, `select` `after` arms, IO waiters, TCP
  timeout validation, worker timer waits, and process deadlines route through
  the shared helper instead of each carrying independent multiplication and
  overflow behavior.
- `std/test.timeout_arithmetic_probe_for_test` provides a deterministic
  runtime probe for immediate deadlines, normal durations, and overflow
  saturation without depending on wall-clock sleeps. Compiler-unit consistency
  tests also reject the old per-subsystem helper names.

### Phase 7: Blocking Integration Registry

Goal: every runtime primitive that can delay a fiber has an explicit contract.

Work:

- Keep builtin metadata as the source of truth for whether an operation is
  pure, impure, a cancellation point, a parallel boundary, parks a fiber, or
  blocks an OS worker.
- Extend the registry as file/process/database/network work moves onto
  fiber-aware or bounded blocking-worker paths.
- Do not infer wait behavior from function names, source modules, or generated C
  symbols.

Tests:

- compiler-unit consistency tests for builtin metadata;
- codegen audits for cleanup across every cancellation point;
- runtime tests showing OS-worker-blocking operations are explicitly bounded or
  documented until migrated.

Initial implementation:

- Builtin metadata now distinguishes `Cancellation_point`, `Fiber_parking`, and
  `Os_worker_blocking`. A cancellable operation like `yield_now` no longer has
  to pretend it is owned by a runtime wait structure, and a platform operation
  like DNS resolution remains explicitly OS-worker-blocking until it gains a
  fiber-aware or bounded-worker integration.
- Operation-result bridges and fallible stream terminals derive
  `Fiber_parking` directly from their manifest `ParksFiber` wait behavior.
  Compiler-unit tests compare the manifest against the generic builtin
  registry, so future networking/database/file operations must state whether
  they do not suspend, park a fiber, or block an OS worker.

### Phase 8: Fairness Checkpoints

Goal: improve cooperative fairness only after the scheduler state model is
correct.

Work:

- Use scheduler counters and stress cases to find starvation before adding
  compiler-generated checkpoints.
- Represent checkpoints as a distinct Core/runtime operation with known purity
  and cancellation behavior.
- Keep CPU-bound cancellation cooperative and documented unless the compiler has
  inserted explicit checkpoints.

Tests:

- no lost wakeups or dead tasks in CPU-heavy mixed workloads;
- fairness tests that assert documented guarantees only, not accidental FIFO
  order.

Initial implementation:

- Scheduler stats now expose `cooperative_yields`, a counter for explicit
  `yield_now()` checkpoints. This gives fairness experiments and CPU-bound
  stress tests a stable signal without claiming that yielding is a fiber park.
- Runtime tests assert that `yield_now()` advances the cooperative-yield counter
  both outside a fiber and inside a structured concurrent task.
- A CPU-heavy mixed-workload regression now uses an explicit `yield_now()` loop
  plus a channel handoff to prove another ready task can make progress without
  depending on FIFO task order.
- Cancellation tests now include both explicit `yield_now()` loops and loops
  that rely on compiler-owned checkpoints. This keeps the current guarantee
  precise: CPU-bound tasks are interruptible at explicit source checkpoints and
  at loop checkpoints inserted by the compiler.
- Core now has a compiler-owned `CCooperativeCheckpoint` node that emits
  `blorp_cooperative_checkpoint()`. The runtime helper checks cancellation on
  every call but only yields after a named reduction budget, so future
  compiler-inserted checkpoints do not have to masquerade as source-level
  impure `yield_now()` calls.
- `std/test.cooperative_checkpoint_probe_for_test` exercises that helper from
  inside a fiber and verifies an expired reduction budget produces an observed
  cooperative yield. The probe is test-only; normal programs still use
  `yield_now()` for explicit source-level handoff.
- `Core_fairness` now inserts `CCooperativeCheckpoint` at the start of ordinary
  `while`/`for` bodies and `@tail_recursive` loop bodies after resource cleanup
  rewriting and before final representation preparation. The pass is
  idempotent and covered by unit tests for ordinary, nested, unmanaged tailrec,
  and list-spread tailrec loops. Final Core invariants reject cooperative
  checkpoints that appear outside a loop-entry position, including duplicate
  checkpoints in the same loop body.
- Runtime cancellation tests now cover CPU-bound `while` and `@tail_recursive`
  loops with no source `yield_now()`, proving structured timeouts can stop
  loop-heavy compute through compiler-owned checkpoints.

## Verification Matrix

For every phase that touches runtime scheduling:

```bash
make
scripts/test compiler-unit
scripts/test runtime --serial
scripts/test leak --serial
BLORP_THREADS=1 scripts/test runtime --serial
BLORP_THREADS=2 scripts/test runtime --serial
BLORP_THREADS=4 scripts/test runtime --serial
BLORP_THREADS=8 scripts/test runtime --serial
```

Before merging major scheduler changes, also run focused cancellation and leak
stress:

```bash
for t in 1 2 4 8; do
  BLORP_THREADS=$t ./blorp test --no-cache --leak-check --suite --timeout 5 \
    tests/test_blorp/memory/leak_check_baselines/tcp_cancelled_read_string.brp
done
```

Add equivalent focused loops for channel send/receive, select, sleep, and task
join baselines as each wait owner is migrated.

## Deferred Performance Work

The following work remains valid, but should not precede the explicit
state/wake/wait-owner phases:

- `List.parallel` pipeline planning and fusion;
- per-worker timer heaps or timing wheels;
- deeper work-stealing and global injection tuning;
- checkpoint budget tuning and fairness metrics;
- data-parallel benchmark guardrails.

## Non-Goals

- No source-level `async` / `await`.
- No shared mutable references between fibers.
- No unbounded OS thread creation.
- No scheduler behavior that depends on source-name heuristics.
- No benchmark-only shortcuts that make particle simulations or synthetic noop
  tests faster without improving the general runtime.

## Acceptance Criteria

A virtual-thread optimization is ready when it has:

- a failing test, stress case, or benchmark that demonstrates the need;
- runtime tests for correctness and cancellation behavior;
- thread-count coverage for `BLORP_THREADS=1,2,4,8` when scheduling is touched;
- leak-check and sanitizer coverage for parked, woken, cancelled, and completed
  fibers;
- benchmark results before and after the change;
- clear ownership-state transitions in code, preferably as explicit enum-like
  states rather than coupled booleans;
- Core/runtime invariants updated when the change introduces a new semantic
  distinction;
- stale generated files and copied runtime snapshots removed or regenerated
  from the canonical `compiler/` implementation;
- no new source-level way to create mutually editable memory between fibers.
