# Amortize Cooperative Loop Checkpoints

**Status:** Runtime-only Phase A implemented and accepted through
[the late-Core execution issue](../late-core-latency/04-amortize-runtime-cooperative-checkpoints.md).
This file retains the broader historical roadmap, including gated Phase B.
All Phase A lifecycle, counter, implementation, and acceptance instructions in
this historical file are superseded by the linked execution issue.

**Phase A acceptance record:** Accepted on 2026-09-10 against immediate parent
`2e3cf2712bc349f0879a71ee18b0d3fe9cf33b38`; the implementation candidate
before the documentation update was
`d618dc3efc76e3f9983fb6f864accfd3dbb6ab2f`. Raw logs are retained outside the
repository under `/tmp/blorp-issue04-acceptance/`.

The accepted runtime contract is inclusive and carrier-thread owned:
`BLORP_COOPERATIVE_CHECKPOINT_INTERVAL` remains 64; calls 1-63 decrement and
return without checkpoint-owned task/fiber inspection; call 64 resets before
cancellation and yield consideration; task entry, task exit, fiber suspension,
and fiber resumption do not reset the budget; explicit source `yield_now()` and
blocking runtime operations remain immediate; and the budget remains
unobservable infrastructure state.

Authoritative Phase A measurements used uninstrumented runtime objects for
timing and test-instrumented runtime sources only for counter validation.
Focused non-fiber throughput improved 39.87% median and focused fiber
throughput improved 30.13% median, with identical focused allocation/release
counts of 0/0. Optimized compiler self-compilation improved `outer_total` by
4.278% median and `late_core` by 4.118% median across 10 alternating measured
pairs. Integrated compiler peak RSS decreased by 0.036%; this integrated
compiler workload is the hard 0.5% RSS gate. Page-granular focused harness RSS
movement is informational when allocations/releases are identical.

The integrated compiler medians also recorded `phase_total` improving from
26,732.872 ms to 25,583.911 ms, a 4.298% improvement. Named phase median
deltas were: `typed_frontend` 2.712%, `core_lowering` 7.977%, `early_core`
7.150%, `runtime_projection` 0.666%, `late_core` 4.118%,
`backend_emission` 3.591%, and `artifact_construction` 0.259%.

Direct `blorp_cooperative_checkpoint` self time fell from 6.281% to 5.205%
(5.335% including the cold split). The remaining direct self-time share admits
a separate generated-local-counter Phase B investigation. It is not a Phase A
rejection condition.

## Objective

Reduce the per-iteration cost of compiler-inserted cooperative checkpoints
while preserving bounded cancellation responsiveness and scheduler fairness.

The first implementation slice should make the existing runtime reduction
budget guard both cancellation polling and scheduler yielding, rather than
checking cancellation and fiber state on every generated loop iteration. Only
if that measured change leaves checkpoint dispatch material should the compiler
emit a function-local countdown fast path.

This is a general runtime/compiler improvement. It must not introduce a lexer-
specific opt-out, remove checkpoints from CPU-heavy loops, or make cancellation
unbounded.

## Why This Issue Exists

The fairness pass inserts a `CooperativeCheckpointExpr` at the beginning of
ordinary `while`, `for`, and lowered tail-recursive loop bodies. Generated C
therefore contains:

```c
while (...) {
    blorp_cooperative_checkpoint();
    ...
}
```

Lexer loops execute this once per character. The runtime currently does:

```c
void blorp_cooperative_checkpoint(void) {
    if (__blorp_cancel_current_task_if_requested()) return;
    if (!__blorp_current_fiber) return;
    __blorp_cooperative_checkpoint_budget--;
    if (__blorp_cooperative_checkpoint_budget > 0) return;
    __blorp_cooperative_checkpoint_budget = 64;
    blorp_yield_now();
}
```

Thus every iteration pays a function call and thread-local task/fiber lookups.
Only scheduler yielding is amortized. In non-fiber work, the function returns
before decrementing its existing budget, so the budget provides no fast path at
all.

The current Stage 01-04 native sample places `_tlv_get_addr` among the largest
leaves. Lexing costs 583.623 ms and contains several tight character loops.
Checkpoint cost is not all of that time, but its placement makes even a small
per-iteration overhead broadly multiplicative.

The language guide already describes checkpoints as using a runtime reduction
budget and not being a source-level ordering primitive. It does not promise a
cancellation observation at every individual backedge. The implementation
should make the bounded polling contract explicit.

## Required Behavioral Contract

Define one named maximum checkpoint interval. The current
`BLORP_COOPERATIVE_CHECKPOINT_INTERVAL` is 64 and should remain the initial
value unless measurement and latency tests justify another value.

For any thread repeatedly executing generated checkpoints:

- a cancellation request must be observed within at most the configured number
  of checkpoint calls after it becomes visible;
- a runnable fiber must reach scheduler yield consideration within the same
  bound;
- blocking runtime operations continue to check cancellation at their existing
  boundaries and are not governed by this optimization;
- explicit source `yield_now()` remains immediate and unchanged; and
- the reduction count is not observable as program ordering.

The bound is inclusive: calls 1–63 take the fast path and call 64 enters the
slow path. The budget belongs to the OS carrier thread and persists across task
entry, task exit, fiber suspension, and fiber resumption. A task inherits the
carrier's remaining budget and may therefore poll earlier, never later, than
the bound. Do not add a task/fiber reset path.

## Phase A: Runtime Budget Fast Path

Reorder the runtime checkpoint so the cheap reduction test happens before slow
cancellation/fiber work:

```c
void blorp_cooperative_checkpoint(void) {
    __blorp_cooperative_checkpoint_budget--;
    if (__blorp_cooperative_checkpoint_budget > 0) return;

    __blorp_cooperative_checkpoint_budget =
        BLORP_COOPERATIVE_CHECKPOINT_INTERVAL;

    if (__blorp_cancel_current_task_if_requested()) return;
    if (!__blorp_current_fiber) return;
    blorp_yield_now();
}
```

This is illustrative, not permission to skip lifecycle analysis. Confirm:

- cancellation requested on another thread is seen by the next slow poll;
- cancellation during the slow poll cannot be lost;
- a cancelled task does not keep running indefinitely after the poll;
- scheduler stats and the existing checkpoint probe still report accurately;
- the budget cannot underflow through reentrancy; and
- each worker thread has an independent budget.

Reset the budget before calling the cancellation helper: cancellation may
perform a non-local exit. "One cancellation poll per interval" refers to the
checkpoint-owned poll; `blorp_yield_now` performs its own slow-path checks.

Keep the slow operation in one function. Do not duplicate task cancellation or
fiber-yield logic into generated programs.

## Phase B: Generated Local Countdown, Admitted Separately If Needed

After Phase A, profile the focused loop. If checkpoint overhead remains at
least 2% of the focused loop or `_tlv_get_addr` remains a material compiler
leaf attributable to checkpoints, admit a separate generated function-local
countdown investigation:

```c
long checkpoint_budget = BLORP_COOPERATIVE_CHECKPOINT_INTERVAL;
while (...) {
    if (--checkpoint_budget == 0) {
        checkpoint_budget = BLORP_COOPERATIVE_CHECKPOINT_INTERVAL;
        blorp_cooperative_checkpoint_slow();
    }
    ...
}
```

This avoids a runtime call and TLS access on most iterations. It is higher risk
because multiple and nested loops must share or independently own budgets
without making cancellation latency unbounded.

If Phase B is required, represent it explicitly in Core or prepared backend
state. Do not recognize C strings or rely on a function name prefix. Required
properties are:

- one initialized scalar budget per generated function or a documented shared
  budget across its loops;
- nested loops cannot multiply the maximum polling delay;
- tail-recursive, range, collection, and ordinary while loops receive the same
  policy;
- explicit checkpoints are not accidentally budgeted twice;
- functions without loops do not gain a counter; and
- generated-code growth is measured.

This Phase B admission signal is not a Phase A rejection condition. Phase A is
accepted when its semantic, focused-throughput, integrated compiler, output,
allocation, memory, and review gates pass. If Phase B proceeds, represent it
explicitly and test it as its own compiler/backend change.

## Semantic And Safety Requirements

- Cancellation remains bounded and race-safe.
- Structured concurrency still joins or cancels child work correctly.
- Timeout exit status and diagnostics remain unchanged.
- SIGINT and SIGTERM delivery through CLI/test paths remains unchanged.
- Scheduler fairness remains bounded for CPU-heavy fibers.
- Explicit `yield_now`, blocking channel operations, sleep, and select are
  unchanged.
- The checkpoint interval is a named constant with one source of truth.
- No environment-dependent or workload-name heuristic is introduced.
- Pure-function semantics are unchanged; checkpoints remain compiler-owned
  infrastructure effects.

## Test-First Plan

Before changing the runtime, add focused probes for:

1. **Budget boundary:** no cooperative yield before the interval and one yield
   at the boundary when a fiber and scheduler stats are active.
2. **Cancellation boundary:** a cancelled CPU loop exits within at most the
   documented number of checkpoint calls.
3. **Non-fiber path:** a large ordinary loop completes with the fast path and
   does not attempt a scheduler yield.
4. **Multiple tasks:** budget state from one task cannot prevent bounded polling
   in the next task on the same worker.
5. **Nested loops:** cancellation latency remains bounded rather than interval
   squared.
6. **Tail recursion:** lowered tail-recursive loops retain checkpoints.
7. **Signals/timeouts:** existing CLI and runtime tests retain their exit and
   diagnostic contracts.

Extend `blorp/test/compiler/stage_09_core/test_core_fairness.brp` only if Core
shape changes. For Phase A, its existing assertions should remain unchanged.
Extend the native checkpoint probe in `runtime.c` or add a narrow exported test
hook rather than inferring yields from wall-clock sleeps. Test hooks must be
test-only in purpose and must not expose scheduler state as a language API.

## Fast Feedback Loop

### 1. Create A Focused CPU Probe

Create ignored `scratch/cooperative_checkpoint_cost_probe.brp` with:

- a simple integer loop;
- a nested loop;
- a tail-recursive loop;
- deterministic checksums;
- no allocation, I/O, clocks, or memory-stat reads inside measured loops; and
- enough iterations for stable native timing.

Compile baseline and candidate generated C with identical optimization flags.
For Phase A, link each against the corresponding runtime source or library so a
full compiler rebuild is unnecessary. Do not accidentally compare an old
embedded runtime with edited `runtime.c`; record the runtime object hash.

### 2. Narrow Validation During Phase A

Use the smallest runtime build/test owner plus:

```bash
bin/blorp test blorp/test/compiler/stage_09_core/test_core_fairness.brp
bin/blorp test blorp/test/runtime/concurrency/test_cancellation.brp
bin/blorp test blorp/test/runtime/concurrency/test_scheduler_yield.brp
```

If direct runtime test tooling is required, add one documented command to this
issue's implementation report. Do not run `make` after every C edit.

### 3. Inspect And Sample The Native Probe

Verify that generated loops still contain checkpoints. Then use macOS `sample`
or the platform-equivalent profiler to compare:

- `blorp_cooperative_checkpoint`;
- `__blorp_cancel_current_task_if_requested`;
- `_tlv_get_addr`;
- scheduler yield; and
- the loop body itself.

Run one warmup and at least seven alternating timing pairs. Record every sample,
median, compiler/runtime hashes, C compiler version, flags, and checksum.

### 4. Admit Phase B Only At The Gate

Do not begin Core/backend work unless the post-Phase-A profile crosses the 2%
focused threshold above or leaves a material checkpoint-attributable compiler
leaf. If it does, write a separate Phase B issue, add focused Core and emitter
tests first, then iterate through `test_core_fairness.brp` and
`test_core_emit.brp` without a full rebuild.

### 5. Integrated Validation Last

Run `make` once after the selected phase is stable. Re-run cancellation,
scheduler, runtime, CLI signal/timeout, sanitizer, and leak checks. Finally
profile only Stages 01-04 against `blorp/src/main.brp` and compare lexing.

## Expected Results

Phase A reduces every hot-loop checkpoint from cancellation plus fiber TLS work
to one decrement, comparison, and predictable branch on 63 of every 64 calls.
Cancellation and scheduler work executes once per interval.

Expected results are:

- substantially fewer task/fiber TLS lookups in the focused loop;
- a lower `_tlv_get_addr` and checkpoint sample share;
- a measurable improvement in character-heavy lexing;
- no allocation change; and
- cancellation/yield latency bounded by 64 checkpoint calls initially.

Phase B, if justified, should remove the function call and TLS access from most
iterations and improve the focused loop further. It is not required if Phase A
makes checkpoint overhead immaterial.

## Acceptance Criteria

1. The cancellation and fairness polling bound is explicit and tested.
2. Phase A's fast path executes before task/fiber slow checks.
3. Cancellation, scheduler, timeout, signal, nested-loop, and tail-recursive
   behavior remains correct.
4. The focused native probe preserves checksums and reports all timing samples.
5. Native samples show slow checks occur approximately once per interval.
6. Allocation counts remain unchanged.
7. Phase B is admitted separately only if its documented profile gate is met;
   the gate is not a Phase A rejection condition.
8. Any Phase B IR/backend representation is explicit and handles nested loops
   without multiplying latency.
9. Generated C identity and compiler/runtime hashes are reported. Generated
   local-counter size belongs to any separate Phase B.
10. Focused runtime, cancellation, scheduler, fairness, counter,
    diff/artifact, test-runner, and code-reviewer gates pass. Broader CLI
    timeout/signal, sanitizer, leak, and changed-compiler gates remain owned by
    the normal preview/premerge process.
11. Fresh integrated compiler `outer_total`, `phase_total`, named phase, and
    `late_core` medians are reported; compiler self-compilation is the Phase A
    integrated decision metric.
12. No scratch binaries, C files, or logs are committed.

## Out Of Scope

- removing compiler-owned checkpoints;
- annotating lexer functions as non-cancellable;
- changing explicit `yield_now` semantics;
- weakening cancellation to an unbounded best effort;
- tuning the interval without latency and throughput data;
- changing channel, select, sleep, or process cancellation; and
- combining lexer state/token refactors with this runtime change.

## Implementation Report Requirements

Include the final polling contract, lifecycle analysis, chosen phase, reason
for stopping or admitting Phase B, runtime/compiler hashes, all focused samples,
native sample attribution, cancellation latency observations, integrated
compiler phase results, generated-output identity, test counts, reviewer
verdicts, and every rough edge found in task/fiber transitions. Sanitizer,
leak, CLI, and changed-compiler release gates remain part of the normal
preview/premerge evidence unless a later issue explicitly requires them here.
