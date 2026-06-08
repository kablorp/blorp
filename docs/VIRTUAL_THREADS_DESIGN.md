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
- runtime-internal wait operation ids on fibers, plus timer-recorded wait ids
  that let timer expiry distinguish the current parked operation from a stale
  deadline entry left behind by an earlier wait;
- channel send/receive wait queues now use explicit stack-scoped waiter records
  carrying fiber, wait operation id, wait kind, deadline, wake reason, and a
  queue link, instead of identifying a channel wait by raw `blorp_Fiber*` alone;
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
  `queued`, `running`, `wake_pending`, `timer_index`, channel wait kind, and
  channel wake reason; the lifecycle enum is currently a checked mirror rather
  than the sole source of truth;
- select, sleep, and task-join paths still open-code park/wake transitions
  with raw `blorp_Fiber*` waiters; channel send/receive waits now have
  operation-identified waiter records, but those records are not yet a common
  runtime wait-operation abstraction shared by all wait structures;
- cancellation now enters the same `blorp_fiber_wake` boundary, but
  cancellation-before-park remains a cooperative pending-wake case until wait
  operation records are explicit;
- generated C still emits task batch, join, deadline, and cleanup protocol
  directly instead of calling a narrow runtime task-scope API;
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
  queue ownership, wait owner, timer index, channel wait kind, wake reason,
  owning worker, coroutine status, task pointer, and cancellation state.
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
parked). They do not yet reject stale timer entries or channel waiter metadata
on a woken fiber, because the current runtime can observe those transiently
until Phase 3 introduces exact wait-owner cleanup.

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
- channel seal and close wake tests proving waiters are removed once.

Initial implementation: `blorp_FiberWaitOwnerKind` is present on each fiber and
is set before every existing fiber park point for IO, task join, sleep, channel
send, channel receive, and select. `blorp_fiber_park` clears the owner after a
resume; immediate no-yield paths clear it explicitly. Scheduler debug snapshots
include `wait_owner=...`, and debug assertions reject a lifecycle-parked fiber
with no owner.

The next slice added a monotonic wait operation id to each fiber. Beginning a
wait mints a fresh id; clearing a wait clears the id. Timer insertion records
that exact id, and timer expiry skips entries whose recorded id no longer
matches the fiber's current wait id. This makes stale timer deadlines
non-authoritative for the current operation while preserving the existing raw
waiter structures.

Channel send/receive queues now use explicit waiter records instead of raw
fiber links. Each waiter records the wait operation id minted at park setup,
the channel wait kind, an optional deadline, and the wake reason chosen by the
winning waker. Channel drains skip stale waiter records whose operation id no
longer matches the fiber's current wait id. The remaining hardening step is to
move select, sleep, task join, and eventually timer ownership to the same
explicit wait-operation model, then factor the duplicated pieces into a common
runtime abstraction.

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
- stale timer entry regressions;
- timeout overflow and saturation cases.

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
- generated fairness checkpoints;
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
