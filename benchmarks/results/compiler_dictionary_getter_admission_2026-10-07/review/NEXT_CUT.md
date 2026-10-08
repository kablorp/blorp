# Next reader cut: ranked checked-get admission

**Proposal only; unimplemented.** This read-only prioritization considered two
families. No source, tests, allowlist, harness or benchmark inputs were changed,
and no native commands were run. The separate `REVIEW.md` is a retained review
record, not acceptance evidence for this proposal.

## Ranking and current boundary

1. **Smallest credible preparation: ranked tensor checked-get ABI policy, owned
   entirely by the backend emitter.** It needs a bounded local refactor before
   deleting two suffix readers; it is not a bare one-line substitution of an
   already-carried enum. No public Core/IR carrier or ownership change is needed.
2. **Defer packed-enum vector formatting.** The existing ownership API receives
   only name and arity; it lacks the enum authority needed to retire its prefix
   without changing legitimate dynamic-enum contracts. This remains wider than
   the emitter-local preparation.

The relevant roadmap rows are `docs/IDENTITY_ROADMAP.md:420` (checked-get width
and packed-enum formatting) and `:1335` (existing-facts-first order).

Current ranked width reader is
`blorp/src/compiler/stage_10_backend/emit.brp:8916–8940`:

```blorp
get ?= ranked_tensor_checked_get_parts(name, args, arg_values)
if name.ends_with("_f64"):
    render_ranked_tensor_checked_get_scalar(get, ..., "double", "0.0", "blorp_vector_read_f64")
else if name.ends_with("_f32"):
    render_ranked_tensor_checked_get_scalar(get, ..., "float", "0.0f", "blorp_vector_read_f32")
else:
    render_ranked_tensor_checked_get_erased(get, ...)
```

`ranked_tensor_checked_get_rank` at `emit.brp:8640` already admits exactly twelve
ABI names: ranks 3/4/5, each with plain erased, shape erased, shape f64 and shape
f32 forms. `ranked_tensor_checked_get_has_shape_args` at `:8669` repeats nine of
those names. `ranked_tensor_checked_get_parts` at `:8742` checks argument/value
counts, tensor rank, static dimensions and index count, then discards the
operation's representation while building the private record at `:632`.

Exact-name admission alone is not a proof of scalar storage width. The ABI and
producer edges supply that proof: runtime functions at
`blorp/src/lib/runtime/native/runtime.c:11372–11529` return `void*`, `double` or
`float` and use the corresponding erased/f64/f32 read helper. Producer
`blorp/src/compiler/stage_09_core/tensor_specialize.brp:180` selects an existing
`CheckedTensorScalarKind` from the checked result type; `:247` renders the
corresponding shape ABI name; `:343–404` emits direct Float/Float32 shape calls
with the result type, or preserves an erased Ptr call inside an explicit unbox.
Do not infer scalar representation from tensor record shape or result spelling
at the emitter. Preserve the admitted operation's established ABI instead.

## First preparation, then reader deletion

Replace the existing two exact-name tables with one private, precise operation
admission result. Illustrative shape (not proposed public IR):

```blorp
private enum RankedTensorReadRank:
    ReadRank3
    ReadRank4
    ReadRank5

private enum RankedTensorReadAbi:
    ErasedRead(RankedTensorReadRank)
    ErasedShapeRead(RankedTensorReadRank)
    Float64ShapeRead(RankedTensorReadRank)
    Float32ShapeRead(RankedTensorReadRank)

private pure func ranked_tensor_read_abi(name: String) -> Option[RankedTensorReadAbi]:
    match name:
        "blorp_tensor3_checked_get": Some(ErasedRead(ReadRank3))
        "blorp_tensor3_checked_get_shape_f64": Some(Float64ShapeRead(ReadRank3))
        -- Complete the same twelve existing exact ABI arms; unknown names -> None.
```

This consolidates the existing admission catalog, rather than adding a second
registry or moving suffix parsing into another helper. Named variants prohibit
a typed Float read with the plain erased argument convention. Private accessors
derive the rank/argument convention from the variant. Retain that admitted ABI
alongside the existing validated parts so rendering consumes it without reading
the name again.

First independently review/validate this local preparation with unchanged
rendering. The main reader cut then matches the retained ABI for erased/f64/f32
rendering and deletes `ends_with("_f64")` / `ends_with("_f32")`, plus their two
allowlist rows. It retires representation recovery from string shape and the
duplicated shape-name table; it does not remove ABI symbol strings or claim the
broader runtime-operation-id migration is complete.

## Transfer and fallback invariants

- Both direct-width inlining entry points are BuiltinCall branches:
  `emit.brp:7360` (body emission) and `:15022` (simple expression emission).
  Both must consume the same admission/validated-parts result. Existing
  DirectRuntimeCall emission and its ABI remain unchanged.
- Plain/shape erased calls must remain erased even when their tensor element is
  Float. The outer `CoreUnboxKind` remains the scalar authority for the unbox
  optimization (`emit.brp:8959`, `:8997`, `:12158`). Float16 follows that explicit
  unbox path; there is no admitted ranked `_f16` shape ABI in this catalog.
- Dynamic dimensions, rank mismatch, wrong arity/value count and unsupported
  names retain their current inline rejection/fallback behavior. Do not expand
  admission, infer aliases, or discard argument evaluation/cleanup.
- The existing ownership contracts at `ownership.brp:1861–1888` distinguish
  borrowed erased alias results from primitive f64/f32 results. Do not modify
  those contracts or introduce a backend ownership decision.

## Tests, identity, costs and stop rule

This is a semantics-preserving refactor. No truthful behavioral defect was found:
the current suffix readers are already behind exact-name admission. Establish
meaningful public emitter controls that **pass before and after**; do not invent
a failing bug or source-text/schema-mirroring test. If a real bug is discovered
later, obtain a separate failing-first regression and reassess scope.

Owning public output tests belong in `test_stage_10_backend/test_core_emit.brp`.
Exercise all twelve ABI names through both body and simple-expression emission,
static ranks 3/4/5, exact scalar C/read-helper/zero literals, erased Ptr results,
the explicit Float/Float32/Float16 unbox path, dynamic/static-shape fallback,
wrong arity/rank, and unknown suffix/lookalike controls. Existing rank3 controls
at `test_core_emit.brp:22056`, `:26446` and producer controls at
`test_core_tensor_specialize.brp:426`, `:448` provide baseline examples; they do
not prove complete coverage by themselves.

After a FRESH build, shortest suite commands are:

```sh
bin/blorp test --timeout 180 blorp/test/test_compiler/test_stage_10_backend/test_core_emit.brp
bin/blorp test --timeout 180 blorp/test/test_compiler/test_stage_09_core/test_core_tensor_specialize.brp
scripts/compiler-check --changed --plan
```

Run selected gates and broad compiler/codegen/runtime gates proportionate to the
final cut, with independent code-reviewer/test-runner verdicts. Inspect retained
generated C for rank3/4/5 Float/Float32/Float16/erased runnable cases. Require raw
whole-C identity, unchanged dump schema/Core where compared, and deletion of
only the two targeted allowlist rows with strict census/hygiene checks.

Enabling cost gate remains matched FRESH O2 paired normal/diagnostic stage2,
identical frozen self/small inputs, at least three normal instruction samples,
paired allocation evidence, exact unchanged +0.5% ceilings, source/binary/C pins
and repository minimum-of-runs protocol. Report raw spread and background work;
no quiet-window, wall-time or speed claim. Extra private enum/record costs must
be measured rather than guessed.

Stop on any transfer/ABI ambiguity, need for a public carrier or extra registry,
unexplained C change, loss of fallback/ownership behavior, source drift or cost
failure. Do not start implementation until dictionary resource acceptance and a
new coordinator GO. No measurement or implementation acceptance is claimed here.

## Why vector formatting ranks below this

`ownership.brp:2003–2036` accepts any `blorp_vector_to_string_` prefix and supplies
BorrowArg/ReturnOwned; `test_core_ownership.brp:575` pins a dynamically named enum
helper. Primitive names already occur in the exact owned-result vocabulary at
`ownership.brp:870–874`, but that finite list cannot cover declared enum names.
Producers `specialize_value.brp:68–98` and
`specialize_tensor_dispatch.brp:253–278` know the element type and bake an enum
name. Backend `emit.brp:844–876` later has projected type naming, but the contract
consumer `emit.brp:5519` still calls `builtin_contract(name, arity)` without that
authority. Deleting the prefix against the primitive list would lose enum
contracts and projected DirectRuntimeCall names.

The smallest preparation is to publish authoritative enum-vector formatter
operation identity/catalog from its producer and let ownership and projected
backend emission consume it. That crosses producer, ownership and projection
ownership boundaries; it is the already-deferred formatter preparation, not a
one-owner existing-fact reader fix. Do not add a duplicate enum-name registry or
make backend projection own the earlier ownership decision.
