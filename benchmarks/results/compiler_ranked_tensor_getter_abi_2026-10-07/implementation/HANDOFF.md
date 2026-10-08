# Ranked tensor checked-get ABI preparation

Status: tests-only repository edit and an unimplemented scratch proposal. No
production edits, native commands, commits or allowlist changes by this worker.
This is a semantics-preserving refactor; the current admitted suffix readers do
not establish a demonstrated behavioral defect. Baseline output controls must
pass, and a later production GO is required.

## Problem and narrow owner

`blorp/src/compiler/stage_10_backend/emit.brp:8640` admits exactly twelve checked
getter symbols. `:8669` repeats the nine shaped symbols to derive argument
convention. `:8742` validates argument/value counts, tensor rank and static
dimensions, then builds `RankedTensorCheckedGet` (`:632`) without representation.
The direct-width renderer recovers that lost fact at `:8916`:

```blorp
get ?= ranked_tensor_checked_get_parts(name, args, arg_values)
if name.ends_with("_f64"):
    render_ranked_tensor_checked_get_scalar(get, ..., "double", "0.0", "blorp_vector_read_f64")
else if name.ends_with("_f32"):
    render_ranked_tensor_checked_get_scalar(get, ..., "float", "0.0f", "blorp_vector_read_f32")
else:
    render_ranked_tensor_checked_get_erased(get, ...)
```

Exact admission plus existing producer/runtime contracts is the authority.
`tensor_specialize.brp:180,247,343` selects scalar kind from the Core result,
chooses shaped ABI and preserves explicit unbox for erased results. Runtime
`runtime.c:11372–11529` defines pointer/double/float return conventions. Ownership
`ownership.brp:1861–1888` admits all twelve exact names/arity and distinguishes
erased alias from primitive results. No runtime ABI, Core schema, phase,
ownership contract or producer is being changed.

## Reachability and complete local consumer map

Full late-Core projection does not preserve these Builtin calls:
`backend_projection.brp:148,571` uses the valid ownership contract to construct
DirectRuntimeCall. `specialize_tensor_dispatch.brp:1196–1238` first changes
static plain getters into shape calls. Therefore standalone Builtin output
controls deliberately use the existing public `prepared_core_program` and
prepared artifact emitter, bypassing `run_pre_dce_tail`; they do not prove
production scalar inlining. Full-pipeline controls use the ordinary owning
`emit_source_spelled_c_artifact` helper and expect established runtime projection.

The local consolidation still has a production consumer: StructUnbox over
DirectRuntimeCall at `emit.brp:12287` obtains validated parts and emits an inline
fixed-record load. Its Builtin counterpart is at `:12263`.

All checked-parts consumers are:

- Direct-width Builtin emission, body `:7360` and simple expression `:15022`.
  Both call `emit_ranked_tensor_checked_get_call_from_values` (`:8916`).
- Explicit scalar unbox `:8959,8997` matches CoreUnboxKind, including Float16.
- Inline struct unbox `:9025` uses the already resolved C type; both call kinds
  above reach it.
- Renderers/prelude `:8866,8897,8943,9010` read tensor, indices and dimensions.
- Name guards `:7380,12263,12287,15037` distinguish an admitted-but-unsupported
  call from unknown-name fallback. They will use the same single admission.

DirectRuntimeCall scalar rendering stays on its existing runtime path. Plain
and shaped erased calls stay erased even with a Float tensor. Explicit unbox
kind remains the scalar authority; struct C type remains the struct authority.
There is no admitted `_f16` ranked ABI.

## Concrete first preparation

The complete scratch diff is `preparation.proposal.patch`; it has not been
applied. Four variants make unshaped typed reads unrepresentable:

```blorp
private enum RankedTensorReadRank:
    TensorReadRank3
    TensorReadRank4
    TensorReadRank5

private union RankedTensorReadAbi:
    ErasedRankedRead(RankedTensorReadRank)
    ErasedRankedShapeRead(RankedTensorReadRank)
    Float64RankedShapeRead(RankedTensorReadRank)
    Float32RankedShapeRead(RankedTensorReadRank)

private enum RankedTensorReadRepresentation:
    ErasedTensorRead
    Float64TensorRead
    Float32TensorRead

private pure func ranked_tensor_read_abi(name: String) -> Option[RankedTensorReadAbi]:
    match name:
        "blorp_tensor3_checked_get": Some(ErasedRankedRead(TensorReadRank3))
        "blorp_tensor3_checked_get_shape": Some(ErasedRankedShapeRead(TensorReadRank3))
        "blorp_tensor3_checked_get_shape_f64": Some(Float64RankedShapeRead(TensorReadRank3))
        "blorp_tensor3_checked_get_shape_f32": Some(Float32RankedShapeRead(TensorReadRank3))
        -- Exact same four arms for ranks 4 and 5; all other names -> None.
```

Parts derive a local rank, index offset and representation from admission. The
existing validation remains: expected count equals offset plus rank; obtain
static dimensions from the tensor's existing Core type; drop the correct
argument prefix; require matching indices/dimensions. Checked parts retain
only representation alongside tensor/indices/dims, so no rank is stored twice.
The first preparation leaves both renderer suffix branches unchanged. Review
that concrete local preparation independently before authorizing the main cut.

The main cut then replaces the two branches with:

```blorp
match get.representation:
    Float64TensorRead:
        render_ranked_tensor_checked_get_scalar(get, ..., "double", "0.0", "blorp_vector_read_f64")
    Float32TensorRead:
        render_ranked_tensor_checked_get_scalar(get, ..., "float", "0.0f", "blorp_vector_read_f32")
    ErasedTensorRead:
        render_ranked_tensor_checked_get_erased(get, ...)
```

Only root deletes the two corresponding allowlist rows. This retires duplicate
shape-name facts and downstream width recovery, while keeping exact ABI strings
at their current admission boundary. It does not complete broader runtime
operation identity work.

## Invariants and tests

Argument construction/evaluation, cleanup calls, emitted C strings and
fallback branches remain untouched. The body path evaluates receiver and all
arguments before rendering; shaped dimension expressions are still evaluated
even though static dimensions come from the existing tensor type. Producer
shape arguments are normally literals. Manually inconsistent shape values are
not a newly rejected state; this refactor must not add coherence validation.

Seven new owning-suite public controls are frozen in `tests-only.patch`:
all twelve standalone ABI/value/read/zero forms; statement receiver before
read; wrong short/long arity, rank and dynamic dimension; unknown f16/impostor/
extra suffix fallback; full-pipeline runtime projection; explicit Float/
Float32/Float16 unbox across erased rank/shape forms; full-pipeline inline
record unbox. Erased controls intentionally use a Float receiver and Ptr result.
Existing owning tests retain wider call-argument cleanup/ownership coverage.
Native baseline may refine exact output assertions, never production behavior.

`ranked_getter_oracle.brp` is a separate runnable production fixture in scratch:
ranks 3/4/5 × Float, Float32, Float16, Int, String and fixed RankedPoint;
negative index wrapping, scalar out-of-bounds zero, and record field extraction.
Main returns 0 for success. Fixed-record tensor factory capability is a baseline
question: report an unsupported path rather than broadening implementation.

Shortest repeatable feedback after a FRESH repository build:

```sh
bin/blorp test --timeout 180 blorp/test/test_compiler/test_stage_10_backend/test_core_emit.brp
bin/blorp test --timeout 180 blorp/test/test_compiler/test_stage_09_core/test_core_tensor_specialize.brp
bin/blorp compile /tmp/blorp-ranked-tensor-abi-implementation/ranked_getter_oracle.brp -o /tmp/blorp-ranked-tensor-abi-validation/baseline/oracle.c
bin/blorp run /tmp/blorp-ranked-tensor-abi-implementation/ranked_getter_oracle.brp
scripts/compiler-check --changed --plan
```

Native phases are test-runner-owned and need root GO/shared serial lock. Capture
whole baseline/candidate C bytes and inspect runtime widths plus inline struct
loads, then require identity. Run selected compiler gates, broad compiler and
codegen audit plus contextual tensor/runtime coverage proportional to this
emitter change, with independent source and test review. Strict census must
account only for the two removed readers; no new exceptions.

Measure final private-data cost using sealed current-production stage2 normal/
diagnostic pairs, matched frozen self/small inputs, at least three normal
instruction samples, paired allocation counts, identical C and exact unchanged
+0.5% ceilings. Repository min-of-runs permits background work; retain raw
spread/activity and make no wall-time or speed claim. Layout/ARC costs are
unverified until measured, including on unrecognized admission calls.

Stop on baseline capability ambiguity, unsupported private constructor layout,
need for new Core/runtime/carrier authority, ownership/fallback/evaluation drift,
unexplained C difference, source drift or budget failure. No reader-retirement
or acceptance is claimed before all required stages and reviews.

## Frozen preparation artifacts

`PROPOSAL_PINS.json` retains before/after full emitter bytes and proposal diff
hashes. `TESTS_READY.json` pins suite bytes, tests-only diff and seven names.
The scratch oracle SHA is
`8c9aca635816a35891825e6f784f99c3ea6153a74b991bddb21742b11524e57f`.
First baseline stopped at test syntax before running any cases. Corrected
multiline conditionals and plain-to-shape pipeline expectations are frozen in
TESTS_READY-v3.json / tests-only-v3.patch. The second attempt also stopped
before cases at unparenthesized multiline Boolean assignments, now corrected
in v3, pending controlled baseline retry.
The original tests-only snapshot remains retained.
