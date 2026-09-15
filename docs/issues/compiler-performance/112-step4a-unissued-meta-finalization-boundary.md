# Step 4A: Do Not Finalize Unissued Metas As Type Variables

**Status:** Implemented in this worktree; Step 4A remains open.

## Context and safety boundary

`fresh_meta_with_origin` issues dense indices in a body-local opaque solver.
The old `zonk_type` path used `meta_origin_name` for every unbound
`SemanticMetaType(Int)`. For an index not issued by the current solver,
`meta_origin_name` supplied a display fallback such as `?m9`, and zonking
turned the bad meta into `SemanticTypeVar("?m9")`. The later solved-body and
typed-program meta-freedom checks could no longer see it. This is an
invalid-internal-state acceptance hole, not a supported way to create a
generic type parameter.

The finalization boundary now distinguishes issued-but-unbound from unissued
indices using the solver's origin table:

```blorp
private pure func unbound_meta_type(
    context: Context,
    meta_id: Int,
    finalize_unbound: Bool,
) -> SemanticType:
    if finalize_unbound:
        match from_opaque MetaSolverState(context.solver).origins.get(meta_id):
            Some(origin): SemanticTypeVar(origin)
            None: SemanticMetaType(meta_id)
    else:
        SemanticMetaType(meta_id)
```

Issued but unbound metas still become their recorded origin type variable.
An unissued positive or negative index stays a meta and is rejected by the
existing `SolvedBody`/typed-program audit. The display-only
`meta_origin_name` fallback remains available for diagnostics; it no longer
authorizes finalization. `resolve_type_metas` already left unbound metas
unresolved and is unchanged.

This does **not** solve cross-session same-index aliasing: a raw
`SemanticMetaType(0)` from one body can still coincide with issued index 0
in another. Nominal session-owned `MetaId` remains necessary. The cut simply
fails closed when an index is not issued by the receiving solver.

## Fast feedback and evidence

The updated context tests were observed failing in three places before the
implementation: nested zonking, long-chain unbound recovery, and a new reset
case. They now distinguish an issued unbound meta from out-of-range and stale
indices. Existing typed-program audit tests now pass unissued metas through
`zonk_type` in both a record field and a function body's value slot before
checking the same ordered unfinalized-meta diagnostics. The function case
directly protects the proof-producing body validation boundary.

```bash
bin/blorp test blorp/test/compiler/stage_06_typecheck/type_system/test_context.brp \
    blorp/test/compiler/stage_06_typecheck/test_typecheck_decl.brp
scripts/compiler-check --changed
bin/blorp test --sanitize --timeout 180 \
    blorp/test/compiler/stage_06_typecheck/type_system/test_context.brp \
    blorp/test/compiler/stage_06_typecheck/test_typecheck_decl.brp
benchmarks/compiler_ctfe_typecheck_profile 3 24 32 retained selected
```

The two focused suites pass 29 context and 158 declaration tests. Independent
changed-owner checks pass one production source and three focused suites;
targeted ASan/UBSan passes all 187 tests after the final function-slot test
strengthening. Review found no blocking issue and suggested that additional
function-slot coverage, which is included.

This is a rare invalid-state branch; the selected CTFE workload is a
regression screen, not a performance-win target. It preserves checksum
2,538, 72 dependency body checks, three reused bodies, zero errors,
770,319 / 770,316 allocations/releases, and 3 / 192 retained objects/bytes.
The pre-cut worker key is
`dec99636777e0dbcc001364e2efa6c03c7bab32155cc2e666b462174c27c0b66`;
the candidate key is
`c5224a179db1d44cec16902ceb3c3fa5d37dad3ef2fe9504f6d27b69aa975df6`.
In one warm comparison, retired instructions were 1,566,829,971 before and
1,568,215,866 after (+0.088%, near parity); peak footprint was 14,893,368 B
before and 14,909,752 B after (+0.11%). Worker size rose 16 B, from
6,378,976 to 6,378,992 B. An earlier baseline direct run had 303 page
faults and was excluded; the warm pair each had ten. No elapsed-time win or
loss is claimed from these short runs.

## Acceptance and remaining work

- Issued, unbound metas retain their prior generic-origin finalization.
- Unissued positive, negative, and reset-stale indices remain metas after
  zonking. The downstream typed-program guard emits its existing diagnostic.
- Valid programs preserve diagnostics and CTFE checksum/body-check counts;
  allocations, retired instructions, peak memory, and code size show no
  material regression.

Nominal session provenance and solver-lifetime separation remain open Step
4A work. No source syntax or public language behavior changes.
