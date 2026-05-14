# Virtual Threads Design Target

This document defines the target shape for blorp's fiber runtime. It is a
design target, not a claim about the current implementation.

## Goal

Blorp should support large numbers of cheap, stackful virtual threads while
preserving the language's value-semantics model:

- `concurrent:` and `concurrent for` remain the primary user-facing API.
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

```
free fiber/stack -> runnable -> running -> parked/runnable -> completed -> free
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

## Implementation Roadmap

1. **Repository and artifact hygiene**
   Keep `compiler/` as the only compiler source root. The retired root
   `ocaml/` tree must not contain tracked generated files, copied runtime code,
   or benchmark snapshots. This prevents future cleanup, benchmarking, or
   concurrency hardening from targeting stale code.

   Hardening target: `make hygiene-check` must fail when a root `ocaml/`
   source tree reappears, except for third-party tool names such as
   `ocaml/setup-ocaml`.

2. **Instrumentation and stress gates**
   Add scheduler counters and benchmark cases for spawn, run, park, wake, timer
   insert, timer drain, stack allocation, work stealing, and queue contention.
   Benchmarks belong under `benchmarks/`, and counters should be structured
   runtime state rather than parsed log text.

   Initial implementation: `std/instrumentation.brp` exposes
   `reset_scheduler_stats()` and `get_scheduler_stats()`. Counters are disabled
   until explicitly reset or queried, then record task spawn, fiber lifecycle,
   runnable queue, timer, stack-cache, work-steal, and lock-contention events.

   Hardening target: create deterministic stress cases for park/wake races,
   timeout races, nested `concurrent:` blocks, and `BLORP_THREADS=1,2,4,8`
   before changing scheduler behavior.

3. **Core concurrency semantics**
   Document and enforce the Core meaning of `CConcurrent` and `CConcurrentFor`:
   spawn-all-before-join behavior, result ordering, timeout cancellation,
   closure capture ownership, `max_threads` initialization, and the exact
   points where child results become managed values.

   Hardening target: extend Core invariants so backend emission can assume
   task closure metadata, ownership, cancellation, and result slots are already
   well-formed. Avoid backend-only semantic checks unless monomorphization
   makes an earlier check impossible.

   Initial compiler hardening: final Core invariants now enforce the typed
   result contract for `CConcurrent` and `CConcurrentFor`: task bodies have raw
   type `T`, joined bindings have `Result[T, ConcurrencyError]`,
   `concurrent for` expressions have `List[Result[T, ConcurrencyError]]`,
   timeout expressions are `Int`, task closure return metadata matches the task
   body, `max_threads` is positive when present, and `concurrent for` remains
   list-only until a representation-aware Core form exists.

4. **Cheap fiber lifecycle**
   Add fiber object and stack pooling. Preserve one-live-owner stack semantics
   and add sanitizer/debug poisoning for reused stacks.

   Initial implementation: dead fiber handles and dead guarded coroutine/stack
   regions are cached behind fixed runtime limits. The cache owns only dead
   fibers/stacks; a live fiber still has exclusive stack ownership.

   Hardening target: replace lifecycle-relevant coupled fields such as
   runnable, parked, running, queued, and free flags with a closed state model
   or transition helpers that make illegal ownership transitions impossible in
   normal runtime code and assert them in debug builds.

5. **Scheduler topology**
   Replace the single global run queue with worker-local queues, global
   injection, and work stealing. Keep queue ownership explicit in the fiber
   state model.

   Initial implementation: runnable fibers are distributed across worker-local
   queues. Worker-originated wakes prefer the current worker queue; external
   wakes use round-robin injection; idle workers steal from other worker queues.
   A small global fallback queue remains for initialization and shutdown edges.

   Hardening target: every run-queue operation should transfer ownership of a
   fiber handle exactly once. Tests should cover cross-worker wake, steal,
   shutdown drain, and cache reuse after completion.

6. **Timer scalability**
   Replace the sorted global timer list with per-worker heaps or a timing wheel.
   Benchmark large groups of sleeping fibers and mixed sleep/channel workloads.

   Hardening target: timer ownership must be explicit enough that a fiber cannot
   be simultaneously freed, queued, and still reachable from a timer. Timeout
   regressions should cover stale waiters on channels, joins, and sleeps.

7. **Blocking integration**
   Audit all std/pkg APIs that can block an OS thread. Move them to parking or
   bounded blocking-worker paths.

   Hardening target: maintain a closed blocking-operation registry that records
   whether each operation parks, blocks on a worker, yields, or is a
   cancellation point. Do not infer this from source names or generated C
   symbols.

8. **Structured cancellation cleanup**
   Make cancellation cleanup explicit in generated code so managed task-local
   values are released when a task exits through a cancellation point.

   Initial implementation: Core emission now registers immutable owned locals
   that have explicit Perceus drops with the current task's cancellation cleanup
   stack. Cancellation points drain that stack before jumping to the task
   runner, and normal `CDrop` emission pops the matching cleanup slot before
   releasing the value. The runtime path is inactive outside task execution.

   Hardening target: cancellation must have explicit Core/runtime cleanup
   edges before it becomes more aggressive. Add regression tests for releasing
   task-local ARC values, removing wait-queue entries, and completing joins
   after timeout cancellation.

9. **Worker-pool capacity vs. operation width**
   Decouple global OS-worker capacity from per-block and per-operation
   parallelism limits. `BLORP_THREADS` / `--threads` configure the carrier pool;
   `concurrent(max_threads: N)` constrains that structured block; list/vector
   parallel operations use the pool capacity unless given an explicit operation
   width.

   Initial finding: `benchmarks/blorp/paradigms.brp` currently runs
   `bench_concurrent_vs_sequential()` before the parallel-list benchmark. That
   block calls `concurrent(max_threads: 2)`, which initializes the process-wide
   pool to two workers. Later `List.parallel` cases therefore report roughly
   two-worker scaling unless `BLORP_THREADS` is set before launch. On a 10-core
   local run, the same cases moved from about 2x at `BLORP_THREADS=2` to about
   5.4-6.5x at `BLORP_THREADS=10`.

   Hardening target: represent pool capacity and operation width as distinct
   Core/runtime concepts instead of relying on first-use initialization order.
   Add thread-count benchmark coverage for data-parallel list/vector operations
   so accidental pool pre-warming is visible.

10. **List.parallel pipeline execution**
   Keep the user-facing `List.parallel` API focused on a scoped
   `ParallelList[T]` view, but make the implementation match the pipeline
   mental model more closely.

   Current behavior: `List.parallel` is a typed gateway. It calls the callback
   with the original list viewed as `ParallelList[T]`; each
   `ParallelList.map`, `filter`, or `filter_map` call then runs as its own
   thread-pool pass. A chain like `chunk.filter_map(...).map(...)` therefore
   materializes after `filter_map`, submits another work batch, waits again,
   and materializes after `map`.

   Target behavior: represent a `ParallelList` pipeline explicitly before
   lowering to runtime calls, so a supported chain can be planned as one
   ordered data-parallel operation. Preserve stable output ordering, pure
   callback requirements, nested-parallel rejection, and the absence of
   indexing/mutation/length on `ParallelList`.

   Likely implementation slices:

   - add focused benchmarks for `List.parallel` map/filter/filter_map/chains
     across `BLORP_THREADS=1,2,4,8`;
   - add a phase-specific Core representation for supported `ParallelList`
     stages instead of rediscovering stages from generated function names;
   - lower single-stage map/filter/filter_map to the existing runtime kernels;
   - lower common chains such as `filter_map -> map` to a fused runtime kernel
     only after the explicit representation and tests exist;
   - keep vector `map_indexed_parallel` and fiber scheduling changes separate
     unless benchmark evidence shows shared runtime machinery should move.

   Hardening target: illegal `ParallelList` operations should remain
   unrepresentable after typechecking. Pipeline planning should operate on
   explicit stage variants, not string prefixes or callback-name heuristics.

11. **Fairness checkpoints**
   Add generated checkpoints for long loops only after scheduler counters show
   where starvation occurs. Keep this explicit in Core rather than relying on
   name or syntax heuristics.

   Hardening target: checkpoints should be represented as a distinct IR/runtime
   operation with known purity and cancellation behavior. Do not hide them
   behind ordinary calls whose semantics must be rediscovered later.

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
