# Amortize Cooperative Checkpoints In The Runtime

**Status:** Ready, with explicit semantic gate

**Kind:** Independent compiler/runtime latency optimization

**Detailed predecessor:**
[Amortize Cooperative Loop Checkpoints](../compiler-performance/31-amortize-cooperative-loop-checkpoints.md).
This file is the execution source of truth for runtime-only Phase A.

**Parallel owner boundary:**

- `blorp/src/lib/runtime/native/runtime.c`
- existing runtime declaration only if a test hook signature changes
- runtime cancellation, scheduler, timeout, and signal fixtures
- a checkpoint-specific native benchmark

Do not edit the fairness Core pass, general Stage 09 pipeline, Stage 06, or C
emission in Phase A.

## Objective

Make the existing thread-local reduction budget guard both cancellation polling
and scheduler-yield consideration. On most generated loop backedges, execute
only a decrement, comparison, and predictable return.

This issue is limited to the runtime fast path. It does not add generated local
counters, remove Core checkpoints, vary checkpoint placement by workload, or
special-case the compiler.

## Why This Is A Durable Change

The compiler intentionally inserts cooperative checkpoints in CPU-heavy loops.
The runtime already defines one named interval:

```c
#define BLORP_COOPERATIVE_CHECKPOINT_INTERVAL 64L
```

But the current implementation performs slow checks before consulting that
budget:

```c
void blorp_cooperative_checkpoint(void) {
    if (__blorp_cancel_current_task_if_requested()) return;
    if (!__blorp_current_fiber) return;
    __blorp_cooperative_checkpoint_budget--;
    if (__blorp_cooperative_checkpoint_budget > 0) return;
    __blorp_cooperative_checkpoint_budget =
        BLORP_COOPERATIVE_CHECKPOINT_INTERVAL;
    blorp_yield_now();
}
```

Every call therefore reads cancellation and fiber TLS. Non-fiber compiler work
returns before decrementing the budget, so it has no amortized fast path.

A current backend-only compiler sample attributed 6.96% self time directly to
`blorp_cooperative_checkpoint`; `_tlv_get_addr` accounted for another 7.13%,
although TLS attribution includes other runtime operations. The percentages
must not be added, but the direct checkpoint cost is sufficient to admit the
runtime-only experiment.

Centralizing the polling interval in one runtime policy is preferable to
compiler heuristics or deleted safety points. It is a long-term design only if
the bounded cancellation contract below is accepted and tested.

## Required Behavioral Contract

For a thread repeatedly executing generated cooperative checkpoints:

- a visible cancellation request is observed within at most
  `BLORP_COOPERATIVE_CHECKPOINT_INTERVAL` checkpoint calls;
- a runnable fiber reaches scheduler-yield consideration within the same
  bound;
- blocking runtime operations retain their existing immediate cancellation
  boundaries;
- explicit source `yield_now()` remains immediate;
- task/fiber transitions cannot inherit an exhausted or pathologically delayed
  budget; and
- reduction counts remain infrastructure state, not observable source-level
  ordering.

Document whether the bound is inclusive. The test and implementation must use
the same definition.

The initial interval remains 64. Changing the value is outside this issue.

## Proposed Runtime Shape

The expected fast-path order is:

```c
void blorp_cooperative_checkpoint(void) {
    __blorp_cooperative_checkpoint_budget--;
    if (__builtin_expect(
            __blorp_cooperative_checkpoint_budget > 0,
            1)) {
        return;
    }

    __blorp_cooperative_checkpoint_budget =
        BLORP_COOPERATIVE_CHECKPOINT_INTERVAL;

    if (__blorp_cancel_current_task_if_requested()) return;
    if (!__blorp_current_fiber) return;
    blorp_yield_now();
}
```

This is illustrative. Use existing portability macros and branch conventions.
Do not add a compiler-specific mode or environment variable.

Audit exact task/fiber entry points before implementation. The thread-local
budget must persist across ordinary suspension and resumption of the same or a
different runnable fiber. In particular, do not reset it to a full interval on
every scheduler resume: a series of short resumptions could then postpone slow
polling indefinitely.

Reset only at worker-thread initialization unless an exact new-task boundary
can be proved to preserve the global polling bound. Any additional reset point
requires a counter-based test showing that repeated short resumes cannot defer
slow polling beyond one interval. Do not spread resets across unrelated runtime
operations.

The slow cancellation and scheduling logic remains centralized. Generated C
continues calling the same function.

## Semantic Gate

Before production modification, review and record agreement on these points:

1. bounded polling every 64 generated checkpoints is acceptable language
   infrastructure behavior;
2. no public API promises cancellation observation at every loop backedge;
3. blocking calls and explicit yield retain their current behavior; and
4. the chosen task-transition budget policy cannot multiply delay.

If any point is false, close the issue without implementing the optimization.
Do not weaken tests or add a hidden exception to force acceptance.

## Test-First Plan

Extend the native checkpoint probe and Blorp runtime fixtures before reordering
the implementation:

1. **Budget boundary:** slow polling does not occur before the configured
   boundary and occurs exactly at the boundary.
2. **Cancellation bound:** cancellation becomes visible at each offset within
   an interval and is observed within the documented maximum calls.
3. **Non-fiber path:** ordinary CPU work advances the budget and performs slow
   polling only at the interval.
4. **Independent threads:** each worker has independent thread-local state.
5. **Task transition:** a new task on a reused worker cannot inherit an
   unbounded delay from the previous task.
6. **Repeated short resumes:** suspending and resuming before the interval does
   not reset the budget and indefinitely postpone a slow poll.
7. **Nested loops:** delay is bounded by one interval, not interval squared.
8. **Tail recursion:** lowered tail-recursive loops retain the same bound.
9. **Explicit yield:** `yield_now()` remains immediate and does not consume the
   generated-checkpoint budget.
10. **Blocking cancellation:** channels, sleep, and select retain current prompt
   cancellation behavior.
11. **Signals and timeouts:** CLI exit status, output, and diagnostics remain
    unchanged.

Prefer exact counters exposed by a narrow test hook over wall-clock sleeps.
The hook must remain runtime-test infrastructure, not a standard-library API.

## Focused Benchmark

Create a deterministic CPU benchmark containing:

- a tight integer loop;
- a character-processing loop representative of lexing;
- nested loops;
- a lowered tail-recursive loop; and
- a non-fiber execution path.

No measured loop may perform allocation, I/O, clock reads, or memory-stat
queries. Compute a checksum after the measurement window.

Report:

```text
checkpoint_calls
checkpoint_slow_polls
cancellation_polls
scheduler_yield_considerations
tls_reads_when_available
elapsed_microseconds
allocations
releases
checksum
```

Compile baseline and candidate generated C with identical optimization flags
and link each against its corresponding runtime object. Record both runtime
object hashes so an old embedded runtime cannot invalidate the comparison.

## Incremental Implementation

1. Write exact budget and cancellation-bound tests against current behavior.
2. Add test-only counters around the existing slow operations.
3. Record focused and stage-two compiler baselines.
4. Audit task/fiber transition points and document the reset policy.
5. Move the budget fast path ahead of slow checks.
6. Add the narrow reset at an existing lifecycle boundary if required.
7. Verify the slow-poll count is approximately one per 64 checkpoint calls.
8. Run concurrency, signal, timeout, sanitizer, and leak gates.
9. Collect paired focused and stage-two compiler measurements.
10. Remove benchmark-only instrumentation from production builds or prove it
    compiles out completely.

Stop after Phase A. A generated local counter requires a separate admitted
issue and is not part of this parallel packet.

## Fast Feedback Loop

Run after every runtime change:

```bash
bin/blorp test --timeout 180 \
  blorp/test/runtime/concurrency/test_scheduler_yield.brp

bin/blorp test --timeout 180 \
  blorp/test/runtime/concurrency/test_cancellation.brp

bin/blorp test --timeout 180 \
  blorp/test/runtime/concurrency/test_scheduler_stats.brp

bin/blorp test --timeout 180 \
  blorp/test/compiler/stage_09_core/test_core_fairness.brp
```

The Core fairness test is expected to remain byte-identical because Phase A
does not change checkpoint insertion.

Then run:

```bash
scripts/test runtime
scripts/test leak
scripts/test cli
scripts/compiler-check --changed
```

Use the native runtime sanitizer gate before review:

```bash
make test-asan
```

For whole-compiler evidence, build optimized stage-two baseline and candidate
compilers and alternate `compile --no-format --no-embed-runtime` on
`blorp/src/main.brp`.

## Acceptance Criteria

- [ ] The maximum cancellation/yield polling interval is a named policy with
      one source of truth.
- [ ] Its inclusive/exclusive bound and task-transition behavior are
      documented and tested.
- [ ] The common checkpoint path executes the budget test before cancellation
      and fiber slow checks.
- [ ] Slow cancellation polling occurs approximately once per interval during
      uninterrupted CPU work.
- [ ] Cancellation, timeout, signal, nested-loop, and tail-recursive tests prove
      bounded behavior.
- [ ] Blocking operations and explicit `yield_now()` remain unchanged.
- [ ] No generated Core changes and no program-C changes when compiled with
      `--no-embed-runtime`; embedded output changes only by the intended runtime
      function body.
- [ ] Focused benchmark allocation and release counts remain identical.
- [ ] The focused loop median improves by at least 15%.
- [ ] In a fresh native sample, direct checkpoint self time falls below 2% of
      the focused workload.
- [ ] Stage-two compiler self-compilation median improves by at least 1% across
      the required alternating pairs. If it does not, reject the change rather
      than adding workload-specific behavior.
- [ ] Peak RSS does not regress by more than 0.5%.
- [ ] Runtime, leak, CLI, fairness, sanitizer, and changed compiler gates pass.

## Pitfalls

### Treating this as an implementation-only reorder

Polling every interval rather than every call changes cancellation latency.
The bounded contract must be accepted before code changes.

### Interval multiplication

Independent counters in nested loops or stale state across task transitions
can turn a bound of 64 into 4,096 or worse. Phase A keeps one thread-local
budget and must test transition behavior.

### Lost cancellation

Resetting before or after a slow poll must not cause a cancellation request to
be skipped for an additional interval. Exercise requests at every boundary
offset.

### Benchmarking the wrong runtime

The compiler can embed or cache runtime sources. Record and verify the linked
runtime object hash for both executables.

### Expanding into Phase B

Do not add function-local generated counters simply because they seem faster.
That changes Core/backend representation and creates nested-loop ownership
questions. Phase B requires new evidence after Phase A.

## Non-Goals

- Removing cooperative checkpoints.
- Moving or coalescing checkpoint expressions in Core.
- Changing the interval from 64.
- Workload-specific or compiler-only exceptions.
- Generated local countdown variables.
- Scheduler redesign.
