# Perceus duplicates explicit frame-stack storage

Status: open. Former cleanup P4.

## Reproduction and cause

Three recursive unions carry the rest of the stack as their last field:
`PerceusOwnershipSummaryFrameStack` (`perceus/uses.brp`),
`PerceusLambdaNormalizeFrameStack` (`perceus/borrowed.brp`) and
`PerceusInsertBindingFrameStack` (`perceus/results_and_loops.brp`). All three
remain in current source. Each is a manual trampoline returning a rebuilt
value; a prior summary-walk optimization did not complete this common-stack
cleanup.

## Proposed change and fast loop

Probe one generic frame-payload stack in `traverse.brp` or a small
`stage_09_core/frame_stack.brp`, with list-backed push, pop and top. Check
whether Blorp generics express each payload cleanly and whether one list grown
in place costs less than one union node per frame. Stop if it allocates more;
keep the three unions. P4 is independent of strict value IDs and managed-let
bookkeeping.

Use `BLORP_PERCEUS_ENGINE_METRICS` counters in `perceus/work_counters.brp`
(consumed by `stage_09_core/work_profile.brp`) to attribute the summary and
binding-insertion walks, then exercise their owning cases in
`blorp/test/compiler/stage_09_core/test_core_perceus.brp`. About 94% of pass
allocations were in the drop-insertion walk; public helper size is not evidence
of dynamic reach. Attribution:
[pass](../../benchmarks/results/perceus_allocation_attribution_2026-09-22.md),
[engine](../../benchmarks/results/perceus_engine_attribution_2026-09-22.md).

## Acceptance and owner

Owner: `blorp/src/compiler/stage_09_core/perceus/{uses,borrowed,results_and_loops}.brp`.
Use [Worker Checklist](../WORKER_CHECKLIST.md) and the
[measurement protocol](../../benchmarks/README.md#self-compile-measurement-protocol).
Frozen parent/candidate self-compile and checksum-pinned small input must
produce byte-identical C. Summary-walk, binding-insertion,
`pass_perceus_complete` and total allocations must not rise; retired
instructions must not rise beyond 0.3%. Record any reduction with its cause.
Do not parallelize compiled test binaries, Perceus or late-Core passes.

Run the three owning walk suites (including `test_core_perceus.brp` with
`--timeout 600`), `make hygiene-check`, `scripts/compiler-check --changed`,
serial `compiler-blorp` and `compiler-tools` gates, `leak`, and
`compiler-core-sanitize`; add `runtime` when ownership behavior could change.
The `BLORP_GATE_RESULT` line is the gate verdict.

Cross-module constraints: imports do not re-export names, so benchmark alias
access needs a wrapper. A custom record crossing both directions of mutual
recursion can fail unification (`expected X, got path.X`); this is why the drop
engine lives with results/loops. A common helper must respect that boundary.
