# Step 4A: Validated Body Product, First Cut

**Status:** Implemented in this worktree; Step 4A remains open. Step 4B has not
been attempted.

The `InferredBody` representation shown below describes this first cut; the
later [issue-handoff cut](107-step4a-inferred-body-issue-handoff.md) removes
the broad `TypecheckState` from that product.

## Context and boundary

Step 3 retained checked body outcomes as validated, definition-keyed rows, but
the accepted artifact still held a raw `TypedFunctionInfo`. CTFE's worklist
read that same raw projection used for rejected recovery bodies. The final
function validator checked unresolved metas and typed-expression coherence by
convention before constructing an accepted artifact. None of those states was
visible in the types.

This cut gives the existing independent body-check path three opaque products:

```blorp
opaque type InferredBody = TypecheckFunctionBodyResult
opaque type SolvedBody = TypedFunctionInfo
opaque type ValidatedBody = SolvedBody

private record CheckedBodyArtifactRep {
    id: CallableId,
    plan_provenance: BodyPlanProvenance,
    main_policy: MainValidationPolicy,
    validated: ValidatedBody
}
```

`InferredBody` owns the materialized function result and its fresh inference
session. The only `SolvedBody` constructor checks parameter, source-return,
semantic-return, and recursively nested expression metas. It explicitly tracks
whether any meta remains; existing diagnostic count is not used as a proxy for
solvedness. Semantic validation then checks the typed expression's coherent
type information and all diagnostics already produced by lexical/inference
rules before issuing `ValidatedBody`. Failed solves retain a recovery body and
the same ordered diagnostics; they cannot produce an accepted artifact.

CTFE's accepted branch now reads through
`checked_body_artifact_validated_body` and
`validated_body_typed_function`. The generic
`body_check_outcome_typed_function` still exists for ordinary recovery
materialization, but CTFE no longer uses it. This is a real consumer cutover,
not a second dormant product beside the old accepted field.

## Diagnostic and performance strategy

The former final function check emitted meta errors in parameter order, then
source return, semantic return, and body; if the body had no meta it then
checked typed-expression coherence. The split preserves that order even if a
signature meta is present. Lexical purity, tail-recursion, resource, capture,
and other inference-time checks stay where they already own the necessary
facts. In the common meta-free case, the solved constructor avoids building
error labels and messages for types that need no diagnostic.

The shortest feedback loop is:

```bash
python3 -m unittest blorp.test.compiler.stage_06_typecheck.support.test_declaration_boundary
bin/blorp test blorp/test/compiler/stage_06_typecheck/test_body_check_order.brp
bin/blorp test blorp/test/compiler/stage_06_typecheck/test_typecheck_decl.brp
bin/blorp test blorp/test/compiler/stage_07_ctfe/test_ctfe_typecheck_profile_benchmark.brp
scripts/compiler-check --changed
benchmarks/compiler_ctfe_typecheck_profile 3 24 32 retained selected
```

The new tests require the accepted artifact's validated field and CTFE's
accepted-only accessor, compare the accepted typed projection with the prior
public projection, and assert exact signature-then-nested-body meta diagnostic
order. Existing body-order and CTFE tests cover rejected recovery, shuffled scheduling,
selective reuse, and bodyless dependencies.

The changed-owner compiler check passed seven suites. The broad compiler
gate passed 4,557 / 4,557 tests, and the focused typecheck ASan/UBSan gate
passed 181 / 181. The nested-body meta extension was rerun separately under
ASan/UBSan after the broad gate.

Against the committed Step 3d worker on the retained selected 3 × 24 × 32
workload, checksum 2,538, 72 dependency body checks, three reused bodies, and
3 / 192 retained objects/bytes remain unchanged. Managed allocation/release
calls move 770,955 / 770,952 to 769,887 / 769,884: 1,068 fewer allocation
calls (0.139%). Worker size rises 1,536 bytes (6,357,008 to 6,358,544;
0.024%). Two short direct pairs show retired instructions near parity; the
second warmed pair is 1,570,469,466 baseline versus 1,569,931,409 candidate,
with peak footprint 14,975,288 versus 14,876,984 bytes. The first pair had
294 baseline page faults versus ten candidate page faults and is not a clean
latency comparison. No wall-time win is claimed.

## Acceptance for this cut

- Accepted artifacts retain only `ValidatedBody`; rejected artifacts retain
  recovery-typed information and diagnostics.
- The solved constructor cannot publish unresolved metas in its current
  function-info fields; validation cannot issue an accepted product while
  any prior or final error/diagnostic remains.
- CTFE consumes the accepted-only accessor; source output, body-order,
  diagnostic, and selected-reuse behavior remain unchanged.
- Allocations improve and instructions, peak memory, retained bytes, and
  worker size remain within the roadmap's investigation thresholds.

## Remaining Step 4A and optional 4B

This does **not** finish Step 4A. `SemanticMetaType` still carries raw integer
IDs; meta origins/bindings/frontier still live in broad `Context` and
`TypecheckState`. `finalize_infer_result` and standalone/global raw
`InferResult` consumers remain. The final complete-program validator still
walks typed bodies, and the broader rule inventory and traversal fusion are
not complete. The next solver cut should first inventory every meta consumer,
then introduce a body-owned nominal `MetaId` with an explicit issuing session
and a meta-free solved constructor at the inference boundary. It must keep a
width-sensitive probe so a dense store does not become repeated COW copying.

Step 4B is the separate optional semantic-type interning experiment. It is
neither implemented nor required for Step 4A completion; decide it only after
shape repetition, equality work, hashing, allocations, and retained bytes are
measured in a focused worker.
