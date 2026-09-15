# Step 4A: Meta Binding Graph Invariants

**Status:** Implemented in this worktree; Step 4A remains open. This follows
the indexed solver store in [packet 103](103-step4a-solver-state-and-binding-store.md).

## Context

The indexed store rejected a binding *target* that the current solver had not
issued, but `bind_meta` still accepted a self-reference, a transitive cycle, or
a nested reference to an unissued meta. Unification checked occurs before
calling `bind_meta`, but direct callers could construct an invalid graph.
Unification also returned early for equal types, allowing two identical
unissued metas to bypass target validation. These are construction-boundary
invariants, not conditions finalization should have to repair.

The new tests failed before the implementation. They cover direct self-cycles,
transitive cycles through an existing binding, nested unissued references,
equal unissued metas at the root and inside a type, and a valid reference to
another issued meta.

## Implementation

`bind_meta` now checks target issuance and validates the proposed binding
graph before replacement. The graph walk follows existing bindings, rejects
the target if reached, and rejects any referenced ID outside the issued
frontier. It visits each relevant `SemanticType` shape. The former unification
occurs walk was moved into this constructor, so ordinary binding does not
perform an additional full walk.

The graph walk takes a private check mode:

```blorp
private enum MetaReferenceCheck:
    FindTargetMeta
    ValidateBindingGraph
    ValidateIssuedReferences
```

The equal-type fast path uses `ValidateIssuedReferences` before accepting the
equality. That mode receives the named `META_REFERENCE_NO_TARGET` value; it
never compares a meta to the target. Keeping the mode payload-free avoids an
allocation per direct binding in the focused width probe.
The public `occurs_meta` query retains its target-only meaning.

This is intentionally narrower than claiming that every unification input is
valid: type-variable substitution and variadic-dimension tail shortcuts can
still carry unissued raw metas without constructing a solver binding. Checking
both entire input trees at every unification entry would close those paths but
add a traversal to a hot path; it needs a separate benchmarked design, or a
nominal meta representation that rules invalid construction out earlier.
The targeted substitution and variadic checks, together with dimension and
range shortcuts, are addressed in the subsequent
[packet 105](105-step4a-unification-shortcut-meta-validation.md).

This cut does **not** solve cross-session aliasing: `SemanticMetaType(Int)` is
still constructible with an integer, and independent pure sessions can issue
the same index. A nominal wrapper without an explicit body/session identity
would merely rename that problem. The later provenance change must give each
body a stable, explicit session owner at construction and keep that identity
with every meta reference through solving.

## Fast feedback and performance guard

```bash
bin/blorp test blorp/test/compiler/stage_06_typecheck/type_system/test_context.brp
bin/blorp test blorp/test/compiler/stage_06_typecheck/type_system/test_dim_solver.brp
bin/blorp test blorp/test/compiler/stage_06_typecheck/test_infer.brp
scripts/compiler-check --changed
benchmarks/compiler_meta_binding_width_profile 128 16
benchmarks/compiler_ctfe_typecheck_profile 3 24 32 retained selected
```

The width probe exercises direct binding at a range of issued ID widths; the
CTFE guard checks the production inference path. Compare checksum, accepted
body/reuse counts, allocation/release counts, retained bytes, retired
instructions, peak memory, and worker size before claiming an improvement.
Elapsed time alone is too noisy for this small boundary change.

On the final 128 × 16 width probe, both the prior indexed store and this cut
report checksum 132,096, exact ID validation, 20,480 solver allocations and
releases, and zero retained objects/bytes. A short alternating direct worker
screen reports prior/final retired-instruction samples of 101,818,024 /
102,152,772 and 101,604,374 / 101,920,212, with peak footprint between
1,212,704 and 1,261,856 B across both. The prior worker cache key was
`eaa9b633a467ea63548912baf8728d99ae41d7777c72ea7303b00d39768261f3`;
the final key was
`a277492ae318258fa0ff50257c13d5314b9eaaa559684216aac01ba96461810a`.
These are local uncommitted worker snapshots, not git revisions or an
end-to-end latency claim.

The retained selected CTFE guard keeps checksum 2,538, 72 dependency body
checks, three reused bodies, 769,887 allocations, 769,884 releases, and
3 / 192 retained objects/bytes. In a short B-A-A-B direct run against packet
103's indexed worker (`cffdab21558c98b913089b69779a762e3e00bea45fe2ba900b35f023d1ed4e1e`),
the final worker (`e7c0b9230759881df4e9b6830f69ba8cbf70b6576d0edd5bb3ef868bb6a5c186`)
reported 1,567,603,284 / 1,568,073,744 retired instructions versus
1,568,368,649 / 1,567,040,928 before. Peak footprint was
14,991,672 / 14,975,288 B versus 14,958,904 / 14,909,776 B before. Both
workers had ten page faults in each run; their sizes were 6,391,968 and
6,391,776 bytes respectively (+0.003%). This is near parity across the
measured resource signals, not a wall-time improvement claim.

On the final source, focused context/dimension/inference tests pass 338 / 338;
the changed-owner compiler gate passes four production sources and 11 suites;
and the focused context ASan/UBSan test passes 22 / 22.

## Acceptance and remaining work

- Direct binding cannot create a self-cycle, transitive cycle, or unissued
  nested reference; equal-type unification cannot accept unissued metas.
- Valid issued-meta chains, diagnostics, and body-order behavior remain.
- Focused and changed-owner compiler tests pass without a material allocation,
  instruction, peak-memory, or worker-size regression.
- Session-owned nominal `MetaId`, detached solver lifetime, and final
  whole-program validation/finalization remain Step 4A work.
