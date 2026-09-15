# Accumulate CTFE Pattern Bindings Once

**Status:** Proposed; recursive ownership experiment with a strict admission gate

**Current state:** `ctfe_pattern_bind_list` concatenates each child pattern's
returned bindings; nested tuple/constructor/list patterns can carry leaf results
through several recursive list boundaries. The retained self-compile observed
1,272 calls.
**Next action:** Add deep all-pattern success/failure tests and measure width and
depth separately before choosing an accumulator or explicit work stack.
**Read first:** `blorp/src/compiler/stage_07_ctfe/pattern.brp` and
`blorp/test/compiler/stage_07_ctfe/test_ctfe_pattern.brp`.
**Fast loop:** Run the CTFE pattern suite and proposed direct production binder
profile.
**Decision:** Preserve exact short-circuit semantics, especially first-success
`or`; reject a work stack that merely replaces child-result allocations.

## Objective

Make successful binding collection proportional to emitted bindings where
recursive transfer counters prove repeated copying.

## Candidate And Invariants

The leading candidate is one explicit stack of `(TypedPattern, CtfeValue)` work
items plus one locally owned binding accumulator. Push children in reverse so
processing remains left-to-right. Keep `TypedOrPattern` as ordered alternative
evaluation rather than enqueueing every alternative into shared state.

- Reject length mismatch before binding, as today.
- Stop at the same first mismatch/error and discard identical partial work.
- Preserve tuple, constructor, list, spread, and binding order and values.
- Preserve constructor identity checks and first-success `or` behavior.
- Preserve duplicate-name behavior; do not add validation here.
- Do not change CTFE pattern representation or add a public builder.

## Feedback Loop

Add a proposed `compiler_ctfe_pattern_binding_profile` around
`ctfe_pattern_bind`. Vary sibling width, nesting depth, binders per leaf,
spread position, alternative count, and failure position. Report pattern nodes,
bindings, modeled cross-level transfers, allocations/releases, instructions,
elapsed time, output checksum, and failure position.

```bash
bin/blorp test --timeout 180 blorp/test/compiler/stage_07_ctfe/test_ctfe_pattern.brp
scripts/compiler-check --changed
scripts/test compiler-blorp
```

## Acceptance And Rejection

Accept when demonstrated recursive transfers fall by at least 80%, a deep or
wide case improves instructions or allocations by at least 10%, a shallow
control stays within 3%, and bindings, error, and failure position match.
Reject if baseline is already aggregate-linear, alternatives are evaluated
eagerly, or stack/accumulator COW traffic offsets the removed lists.
