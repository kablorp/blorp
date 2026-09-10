# Amortize Runtime Cooperative Checkpoints

**Status:** Implemented and accepted for runtime-only Phase A

**Kind:** Cross-cutting compiler-runtime latency improvement

**Acceptance record:** Phase A was accepted on 2026-09-10 against immediate
parent `2e3cf2712bc349f0879a71ee18b0d3fe9cf33b38`. The implementation
candidate before this documentation update was
`d618dc3efc76e3f9983fb6f864accfd3dbb6ab2f`. Raw acceptance logs are retained
outside the repository under `/tmp/blorp-issue04-acceptance/`, including
`runtime_profile_pairs15_20260910T183920Z.log`,
`compiler_samples/compiler_pairs.log`,
`candidate_compiler_selfcompile_full.sample.txt`,
`control_compiler_selfcompile_full.sample.txt`,
`runtime_sources_embedded.diff`, and the generated-output identity artifacts in
`identity/`.

The accepted semantic contract is the carrier-thread budget contract in this
file: `BLORP_COOPERATIVE_CHECKPOINT_INTERVAL` remains 64; calls 1-63 decrement
and return without checkpoint-owned task/fiber inspection; call 64 resets the
budget before entering cancellation and yield consideration; cancellation and
runnable-fiber yield consideration are bounded by at most 64 generated
checkpoint calls; task entry, task exit, suspension, and resumption do not reset
the budget; blocking operations and explicit `yield_now()` keep their immediate
checks; and the budget is unobservable infrastructure state.

Authoritative measurements used uninstrumented runtime objects for timing and
test-instrumented runtime sources only for counter validation. The focused
runtime benchmark command was:

```bash
benchmarks/runtime_cooperative_checkpoint_profile \
  --pairs 15 \
  --control-ref 2e3cf2712bc349f0879a71ee18b0d3fe9cf33b38 \
  --keep-stage
```

Focused median elapsed times improved from 17.990 ms to 10.817 ms for the
non-fiber loop, a 39.87% improvement, and from 1.832 ms to 1.280 ms for the
fiber loop, a 30.13% improvement. Focused allocation and release counts were
identical at 0/0. Focused harness peak RSS changes were page-granular and
informational because the allocation/release contract was identical; the hard
0.5% RSS gate applies to the integrated compiler workload.

The optimized compiler self-compilation lane used one warmup and 10 alternating
measured pairs of:

```bash
/usr/bin/time -l <compiler> compile --no-format --no-embed-runtime \
  --time-phases -o <sample.c> blorp/src/main.brp
```

Compiler `outer_total` median improved from 26,847.550 ms to 25,698.981 ms,
a 4.278% improvement. `late_core` median improved from 9,706.478 ms to
9,306.811 ms, a 4.118% improvement. Integrated compiler peak RSS changed from
2,761,310,208 bytes to 2,760,327,168 bytes, a 0.036% decrease. All measured
non-embedded compiler C samples were byte-identical with SHA-256
`5406442f71994f95ea2f3e76c875b1f9a3d93c8c7c81716f02d41aa3eb8b0485`;
a focused loop/tail-recursion final Core identity probe was also
byte-identical. Full compiler final Core dumping was not available because that
dump path exited 139 before producing output, so the Core identity claim is
limited to the focused checkpoint-placement probe. The embedded runtime-source
diff was limited to the intended checkpoint implementation and test-only
counter block.

Native sampling showed direct `blorp_cooperative_checkpoint` self time fell
from 6.281% in the control compiler to 5.205% in the candidate compiler
(5.335% including the cold split). This remaining share admits a separate
generated-local-counter Phase B investigation. It is not a Phase A rejection
condition.

**Primary production owner:** `blorp/src/lib/runtime/native/runtime.c`

**Supersedes as execution source:**
[`../parallel-safe/05-amortize-cooperative-checkpoints-phase-a.md`](../parallel-safe/05-amortize-cooperative-checkpoints-phase-a.md)

**Historical roadmap:**
[`../compiler-performance/31-amortize-cooperative-loop-checkpoints.md`](../compiler-performance/31-amortize-cooperative-loop-checkpoints.md)

## Objective

Make the existing thread-local checkpoint budget guard cancellation polling and
scheduler-yield consideration. Calls 1–63 of each interval should execute only
the carrier-thread budget update, a predicted comparison, and return. Call 64
resets the budget before entering the existing slow path.

This issue is runtime-only Phase A. It does not remove generated checkpoints,
change fairness placement, add function-local generated counters, vary policy
by workload, or special-case the compiler.

## Why This Work Exists

The fairness pass deliberately inserts `CooperativeCheckpointExpr` at hot loop
backedges. Generated C calls:

```c
blorp_cooperative_checkpoint();
```

The runtime already defines one interval:

```c
#define BLORP_COOPERATIVE_CHECKPOINT_INTERVAL 64L
```

But the current function checks cancellation and fiber TLS before consulting
that budget:

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

Every fiber call therefore polls cancellation and reads current-fiber TLS before
the budget. Non-fiber compiler work returns before decrementing the budget and
has no amortized path at all.

In the compiler self-compilation sample, direct
`blorp_cooperative_checkpoint` self time was 12.23% of late Core and
`_tlv_get_addr` self time was 7.76%. TLS has callers unrelated to checkpoints,
so these values must not be added. The checkpoint percentage admits Phase A;
neither value predicts its result.

## Required Behavioral Contract

The budget belongs to the OS carrier thread. It is not reset at task entry,
task exit, fiber suspension, or fiber resumption.

For a carrier thread executing generated cooperative checkpoints:

- the initial budget is `BLORP_COOPERATIVE_CHECKPOINT_INTERVAL`, currently 64;
- calls 1–63 decrement and return without task or fiber inspection;
- call 64 resets the budget and enters the slow path;
- cancellation made visible immediately after a slow poll is observed within
  at most the next 64 generated checkpoint calls;
- a runnable fiber reaches scheduler-yield consideration within the same
  call-count bound;
- a new task or migrated fiber inherits the destination carrier's remaining
  budget and can poll earlier, never later, than the bound;
- nested loops, tail-recursive loops, short tasks, and repeated suspensions
  share the carrier budget and cannot multiply the delay;
- blocking operations preserve their existing immediate cancellation checks;
- explicit source `yield_now()` remains immediate and does not reset the
  generated-checkpoint budget; and
- reduction count is infrastructure state and is not observable source-level
  ordering.

This is a bound in checkpoint calls, not a wall-clock scheduling guarantee.
Changing the interval from 64 is outside this issue.

## Critical Reset Ordering

The budget must reset before calling the cancellation helper. Cancellation can
drain cleanups and `longjmp` out of the checkpoint frame. Resetting afterward
could leave the carrier's budget expired.

The expected shape is:

```c
void blorp_cooperative_checkpoint(void) {
    __blorp_cooperative_checkpoint_budget--;
    if (BLORP_LIKELY(__blorp_cooperative_checkpoint_budget > 0)) {
        return;
    }

    /* Reset before cancellation, which may leave through longjmp. */
    __blorp_cooperative_checkpoint_budget =
        BLORP_COOPERATIVE_CHECKPOINT_INTERVAL;

    if (__blorp_cancel_current_task_if_requested()) return;
    if (!__blorp_current_fiber) return;
    blorp_yield_now();
}
```

The branch macro is illustrative. Use an existing portability convention or a
plain branch if no shared convention exists.

Do not remove cancellation checks inside `blorp_yield_now()`. They execute on
the slow path and have explicit-yield semantics. Consequently, "one
cancellation poll per interval" means one checkpoint-owned poll. An expiring
fiber checkpoint can invoke additional cancellation checks through
`blorp_yield_now()` before yielding and after resumption.

## Semantic Gate Before Editing

Record agreement on all of the following:

1. polling cancellation once per 64 generated checkpoints is acceptable
   infrastructure behavior;
2. no public API promises cancellation at every loop backedge;
3. blocking calls and explicit yield remain immediate;
4. a carrier-owned budget persisting across task/fiber transitions preserves
   the global call-count bound; and
5. reset-before-cancellation is required because cancellation can exit
   non-locally.

If any statement is false, close the issue without changing production. Do not
weaken tests or add a hidden exception to force acceptance.

## Test-First Plan

The existing `blorp_test_cooperative_checkpoint_probe` forces one expiry and
checks that a real fiber yields. It does not prove the new contract. Add a
narrow native test harness before changing production behavior.

Required cases:

1. **Exact boundary:** calls 1–63 do not enter the slow path; call 64 does and
   resets the budget to 64.
2. **Every cancellation offset:** make cancellation visible at each offset
   from 1 through 64 and prove the stated bound.
3. **Reset before non-local exit:** cancellation-triggered `longjmp` leaves
   the carrier budget reset.
4. **Non-fiber path:** checkpoints advance the budget and poll slowly once per
   interval without attempting a fiber yield.
5. **Independent threads:** two pthreads maintain independent TLS budgets.
6. **Task transition:** a task on a reused worker inherits remaining budget.
7. **Repeated short resumes:** suspension before expiry cannot reset the budget
   indefinitely.
8. **Fiber migration:** if supported, the resumed fiber uses the target
   carrier's bounded budget.
9. **Nested loops:** delay remains one interval, not interval squared.
10. **Tail recursion:** lowered tail-recursive loops retain the same bound.
11. **Explicit yield:** `yield_now()` remains immediate and does not reset the
    checkpoint budget.
12. **Blocking cancellation:** channel, sleep, select, and join behavior is
    unchanged.
13. **Signals/timeouts:** CLI status, diagnostics, output forwarding, and
    termination remain unchanged.
14. **Fairness Core:** inserted checkpoint nodes and emitted calls are
    byte-identical.

Prefer a C harness that includes `runtime.c`, following existing native
benchmark precedent. It can inspect private TLS state and test-only counters
without expanding the standard-library API. Any compile-time instrumentation
must be absent from production objects.

Retain the existing real-fiber scheduler-yield test as integration evidence.

## Focused Benchmark

Add:

```text
benchmarks/runtime_cooperative_checkpoint_profile
```

The driver should materialize baseline and candidate `runtime.c` sources,
compile one C harness against each with identical flags, verify source/object
hashes, and alternate executions.

Include:

- a tight non-fiber checkpoint loop;
- a fiber loop with no cancellation;
- cancellation at every interval offset outside timed throughput;
- many short task/fiber resumptions;
- nested-loop and tail-recursive generated programs; and
- explicit-yield and blocking-operation controls.

No timed loop may allocate, perform I/O, read a clock, or query memory stats on
each iteration. Compute a deterministic checksum after the measured window.

Report:

```text
checkpoint_calls
checkpoint_slow_path_entries
checkpoint_owned_cancellation_polls
yield_considerations
cooperative_yields
elapsed_nanoseconds
allocations
releases
peak_rss_bytes
checksum
runtime_source_sha256
runtime_object_sha256
```

`tls_reads` may be reported from a native profiler, but must be labeled as a
sample-derived value rather than a portable counter.

## Incremental Implementation

1. Confirm and document the semantic gate.
2. Add exact native boundary, cancellation-offset, TLS, and transition tests.
3. Add test-only slow-path counters and the native benchmark.
4. Record immediate-parent focused and compiler self-compilation baselines.
5. Move the budget decrement and fast return before task/fiber inspection.
6. Reset the budget before the cancellation helper.
7. Preserve the existing slow cancellation, fiber check, and
   `blorp_yield_now()` call.
8. Verify one checkpoint-owned slow poll per 64 uninterrupted calls.
9. Confirm fairness Core and non-embedded generated C are unchanged.
10. Run focused runtime, cancellation, scheduler, Core fairness, counter, and
    diff/artifact gates for Phase A acceptance. Broader signal/timeout,
    sanitizer, leak, CLI, and changed-compiler gates remain owned by the normal
    preview/premerge process.
11. Collect alternating focused and compiler-on-compiler measurements.
12. Update both predecessor documents with the final policy and measured
    result.

Stop after Phase A. If checkpoint dispatch remains material, profile it and
write a separate issue for any generated local-counter design.

## Fast Feedback Loop

During C iteration, compile and run the issue-owned native harness directly.
This avoids rebuilding the compiler after every edit:

```bash
benchmarks/runtime_cooperative_checkpoint_profile \
  --candidate-working-tree --scenario non-fiber --iterations 100000000

benchmarks/runtime_cooperative_checkpoint_profile \
  --candidate-working-tree --scenario boundary --iterations 1
```

The exact CLI may follow existing Python benchmark drivers, but it must provide
one short correctness mode and one alternating measurement mode.

Run focused integration tests after each stable runtime edit:

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

Before review:

```bash
scripts/test runtime
scripts/test leak
scripts/test cli
scripts/compiler-check --changed
make test-asan
```

For compiler evidence, build optimized baseline and candidate executables
linked with their corresponding runtime objects. Alternate normal
self-compilation through C emission with `--time-phases`. Record hashes so the
runtime cache cannot silently cause both executables to use the same runtime.

## Expected Result

On 63 of every 64 checkpoint calls, slow task/fiber inspection disappears. The
non-fiber compiler path gains a real amortized fast path for the first time.

Expected observable effects:

- approximately 64× fewer checkpoint-owned cancellation polls in long,
  uninterrupted loops;
- materially lower direct checkpoint and checkpoint-attributable TLS samples;
- faster late Core and other loop-heavy compiler phases; and
- unchanged allocation behavior and generated program structure.

The historical profile makes a compiler self-compilation improvement above 1%
plausible. It is not safe to infer magnitude by adding checkpoint and TLS
sample shares.

From a fresh budget, `N` uninterrupted calls produce `floor(N / 64)`
checkpoint-owned polls. With an arbitrary inherited carrier remainder, they
produce no more than `ceil(N / 64)` polls. Use those formulas for deterministic
tests rather than asserting a fixed ratio on short runs.

## Definition Of Done

- The common checkpoint path performs only the carrier TLS-budget update,
  predicted comparison, and return.
- Exact first expiry is call 64.
- Cancellation and yield consideration remain bounded by 64 generated
  checkpoint calls across task/fiber transitions.
- The budget resets before any potentially non-local cancellation exit.
- There is one carrier-thread budget authority and no task/fiber reset path.
- Explicit yield and blocking-operation semantics are unchanged.
- Core fairness placement and emitted checkpoint call sites are unchanged.
- Focused native and compiler measurements use identity-verified runtime
  sources and objects.
- Correctness, performance, test-runner, and code-reviewer reviews pass.

## Acceptance Criteria

- [x] The semantic gate is explicitly accepted and recorded.
- [x] `BLORP_COOPERATIVE_CHECKPOINT_INTERVAL` remains the one policy source and
      remains 64.
- [x] Calls 1–63 avoid checkpoint-owned task/fiber inspection; call 64 enters
      the slow path and resets first.
- [x] Every cancellation offset from 1 through 64 satisfies the bound.
- [x] Cancellation `longjmp` leaves a reset carrier budget.
- [x] Pthread TLS independence and transition persistence are proven.
- [x] Nested loops, tail recursion, short resumptions, and task changes cannot
      multiply or reset the bound.
- [x] Blocking operations and explicit `yield_now()` remain unchanged.
- [x] Focused non-fiber and fiber checkpoint throughput improve by at least
      15% median.
- [x] Checkpoint-owned cancellation polls are no more than
      `ceil(checkpoint_calls / 64)` for uninterrupted successful execution.
- [x] Direct checkpoint self time is measured. Remaining direct self time at or
      above 2% admits a separate generated-local-counter Phase B; it is not a
      Phase A rejection condition.
- [x] Optimized compiler self-compilation improves by at least 1% median across
      the required alternating pairs.
- [x] Integrated compiler peak RSS does not regress by more than 0.5%, and
      allocation/release counts remain identical in the focused loop. Focused
      harness RSS changes are informational when they are page-granular and
      allocations/releases are identical.
- [x] Focused loop/tail-recursion final Core output and measured
      non-embedded compiler C are byte-identical. Embedded runtime output
      differs only by the intended checkpoint implementation.
- [x] Focused runtime, cancellation, scheduler, counter, diff/artifact,
      test-runner, code-reviewer, and Core fairness gates pass. Broader release
      gates remain owned by the normal preview/premerge process.

## Pitfalls

### Reset after cancellation

Cancellation can `longjmp`. Reset before calling it.

### Per-task resets

Resetting on task entry or fiber resume lets repeated short work postpone
polling indefinitely. The budget belongs to the carrier thread.

### Miscounting cancellation polls

`blorp_yield_now()` performs additional slow-path checks. Distinguish the one
checkpoint-owned poll from total cancellation-helper invocations.

### Benchmarking the wrong runtime

Embedded sources and runtime caches can invalidate the experiment. Verify both
source and object hashes.

### Expanding into generated counters

Function-local counters change Core and C and create nested-loop policy
questions. They require a new issue after Phase A is measured.

### Timing cancellation with sleeps

Wall-clock scheduling tests are flaky and do not prove a call-count bound. Use
exact counters and deterministic offsets.

## Non-Goals

- Changing the interval value.
- Removing or relocating Core checkpoints.
- Generated function-local counters.
- Compiler-, lexer-, or workload-specific checkpoint policies.
- Optimizing `blorp_yield_now()`.
- Changing blocking-operation cancellation checks.
- Exposing checkpoint budget state as a public language API.
