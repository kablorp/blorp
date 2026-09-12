# Preserve Exact Accepted Unresolved Trait Calls

**Status:** Complete

**Roadmap:** [Normalized Semantic Compilation Roadmap](NORMALIZED_SEMANTIC_COMPILATION_ROADMAP.md), Step 2e, twentieth packet

**Depends on:** Exact accepted trait selection and policy queries (Issues 87-90)

## Outcome

An accepted graph-backed trait call that cannot yet select a concrete
implementation now retains its exact declaring `TraitId`:

```blorp
union ResolvedCallTarget:
	ResolvedAcceptedTraitMethodCall(TraitId, CallableId)
	ResolvedAcceptedUnresolvedTraitMethodCall(TraitId)
	ResolvedUnresolvedTraitMethodCall(String)
```

The string variant remains an explicit compatibility state for graphless Env
resolution. Accepted and compatibility calls no longer share a variant whose
payload cannot prove which authority selected it.

Typed-AST JSON, CTFE dependency scanning and translation, inference policy,
and Core lowering all consume the accepted unresolved identity directly.
They project the trait spelling only at JSON, diagnostic, CTFE intrinsic-name,
or Core compatibility boundaries that require text.

The cut also closes a visibility defect exposed by exact identity. A module's
public trait implementations remain available for UFCS, but a trait method is
entered into the bare-name map only when its trait or the method itself is
genuinely unqualified. Merely importing a module no longer makes every method
of every public trait an unqualified candidate. Distinct same-named traits in
qualified-only modules therefore remain separate instead of producing a false
method collision.

## Context

Issue 90 deliberately left unresolved calls string-backed because a name-only
Env candidate is not accepted identity. That was the correct compatibility
rule but too broad for graph calls. `TraitMethodCallee` already distinguishes
these cases:

```blorp
private union TraitMethodCalleeIdentity:
	AcceptedTraitMethodCalleeIdentity(TraitId)
	CompatibilityTraitMethodCalleeIdentity
```

The old target construction discarded that distinction when no implementation
was selected:

```blorp
ResolvedUnresolvedTraitMethodCall(callee.trait_name)
```

That forced later consumers back to source spelling even though Stage 06 had
already proved the declaring trait. It also made the accepted policy work from
Issue 90 incomplete for generic calls: selected calls carried `TraitId`, while
deferred calls with the same accepted callee did not.

The first end-to-end test exposed a separate visibility problem. Accepted
authority construction previously added methods from every public trait in
every direct import module to one unqualified `Dict[String, TraitMethodId]`.
Qualified-only traits therefore collided by spelling, and an unrelated trait
could replace a compiler-prelude candidate. The fix is not a precedence hack:
the authority now derives the bare method relation only from explicit local,
selective, and compiler-linked prelude visibility.

## Invariants

1. An accepted unresolved call stores `TraitId`; it never stores the declaring
   trait spelling as its semantic identity.
2. A graphless or otherwise compatibility-only unresolved call retains the
   separately named string variant.
3. `resolved_call_callable_id` returns `None` for both unresolved variants.
4. Accepted elementwise, `Self`-bound, and resource policies consume the exact
   identity for selected and unresolved accepted calls.
5. Typed JSON, CTFE, and Core reject an accepted unresolved `TraitId` that does
   not belong to their canonical `DefinitionTable`.
6. Core projects an accepted unresolved identity to `DeferredTraitCall` only
   after validating it against that table.
7. Direct-module imports expose public implementations for UFCS without
   implicitly exposing all trait methods as bare names.
8. Local traits, selectively imported traits, selectively imported methods,
   and explicitly compiler-linked prelude traits retain their existing
   unqualified behavior.
9. A graph trait-method import keeps its explicit surface kind even when the
   same spelling has exact callable/global `DefinitionId` targets.
10. Import binding order and overlapping definition-target order remain
    unchanged.
11. No generic integer dictionary, parallel identity map, magic value, or
    name-based authority fallback is added.

## Code Examples

An imported trait method invoked through a generic receiver stays exact even
without a concrete implementation:

```blorp
import:
	dep: Stringable, to_string

pure func render[T: Stringable](value: T) -> String:
	value.to_string()
```

The accepted target is:

```blorp
ResolvedAcceptedUnresolvedTraitMethodCall(dep_stringable_trait_id)
```

Core validates and projects it at the compatibility boundary:

```blorp
ResolvedAcceptedUnresolvedTraitMethodCall(trait_id):
	if trait_id_is_valid(definitions, trait_id):
		Ok(DeferredTraitCall(
			trait_id_name(definitions, trait_id),
			info.callee_name,
		))
	else:
		Err(CoreLowerInvalidCall(...))
```

Graphless callers remain honest about their weaker state:

```blorp
ResolvedUnresolvedTraitMethodCall("Stringable")
```

The import row also represents an overlapping surface without erasing either
fact:

```blorp
GraphSelectiveTraitMethodBinding(
	local_name,
	module_id,
	source_name,
	overlapping_definition_ids,
)
```

Trait authority consumes the explicit method kind. Callable and global
authorities consume only the category-checked IDs from the same row.

## Implementation Strategy

### 1. Prove the missing accepted state

The millisecond structural test requires the dedicated accepted unresolved
variant and verifies that accepted target construction selects it. The bridge
test builds a two-module graph, imports a user trait and method, invokes the
method on a constrained type parameter, and compares the retained target with
the exact trait row from the graph definition table.

The test also requires no callable target. This distinguishes genuinely
deferred dispatch from a selected implementation and prevents a name-only
builtin from satisfying the assertion.

### 2. Preserve accepted identity at target construction

`resolved_call_from_trait_method_callee` now branches on the already explicit
callee identity when `impl_method` has no target. It emits
`ResolvedAcceptedUnresolvedTraitMethodCall(TraitId)` for accepted graph
selection and keeps `ResolvedUnresolvedTraitMethodCall(String)` for the
compatibility branch.

All target equality and callable-ID projection rules handle the new variant
explicitly. The variant is not folded into a nullable callable field, because
accepted versus compatibility provenance is semantically relevant.

### 3. Carry overlapping import facts without changing kind

The module binder already knows whether an exported surface symbol is a trait
method. Previously, if that spelling also had definition IDs, registration
changed the row into `GraphSelectiveDefinitionBinding` and discarded the
method kind. That made later visibility depend on which other declarations
happened to share the spelling.

`GraphSelectiveTraitMethodBinding` now retains both its source method identity
and any exact overlapping definition IDs. Callable, global, CTFE, and Core
adapters project those IDs through category-specific constructors. A trait-only
method carries an empty ID list; no fake `DefinitionId` is minted for a
`TraitMethodId` that does not exist at the import-binding phase.

### 4. Build the unqualified trait relation from visibility

Accepted trait authority now receives an opaque, provenance-bound visibility
product:

```blorp
visibility ?= accepted_visible_trait_bindings(
	table,
	issuing_definition_table,
	module_view_import_bindings(view),
)
```

The product proves the import rows and accepted table share definition-table
provenance. Selective trait definitions are converted to exact `TraitId` rows
before authority construction, so raw `DefinitionId` integers cannot be
replayed through an equal-layout foreign compilation. Selective method
bindings scan only public traits in the exact imported `ModuleId`. Local traits
and explicit compiler-prelude links are added in stable construction order.
Direct public traits remain available to semantic obligation and
implementation resolution, but do not enter the bare method map solely because
their module is reachable.

The production adapter obtains the issuing table from the bound module's
prepared scope definition index. It preserves a rejected visibility product as
an explicit authority-preparation error instead of silently substituting an
empty visibility set. This keeps the provenance check meaningful in the real
pipeline, not only in focused constructors and tests.

This preserves the local ambiguity diagnostic while eliminating false
collisions between qualified-only namesakes.

UFCS keeps its broader language rule through a separate exact receiver query.
When a receiver type comes from an imported module, the authority scans visible
trait rows, follows each matching `TraitMethodId` to its implementation
candidates, and accepts exactly one applicable method identity. Multiple
applicable exact identities produce an actionable ambiguity diagnostic,
independent of module order. It does not repopulate the bare-name map or choose
a qualified-only namesake by order.

### 5. Migrate every retained-call consumer

- inference applies exact elementwise, `Self`-bound, and resource policy to
  both accepted target variants;
- CTFE body dependency scanning records unresolved trait fallback without
  inventing a callable dependency;
- CTFE translation validates the trait ID before producing the existing
  intrinsic compatibility call;
- typed-AST JSON validates the ID and projects the source trait name only into
  external JSON; and
- Core lowering validates the ID and performs its final deferred-dispatch name
  projection.

### 6. Keep the feedback loop narrow

The representation test runs in milliseconds. The bridge suite is the first
semantic gate because it covers accepted selection, generic unresolved
dispatch, imported methods, prelude precedence, and resource policy in one
owner. CTFE, JSON, and Core tests then exercise only their projection
boundaries. The manifest-owned and full compiler gates run once after those
tests are stable.

## Fast Feedback Loop

Run the structural boundary first:

```bash
python3 -m unittest \
  blorp.test.compiler.stage_06_typecheck.support.test_declaration_boundary.\
DeclarationBoundaryTests.test_unresolved_accepted_trait_call_preserves_exact_identity

python3 -m unittest \
  blorp.test.compiler.stage_06_typecheck.support.test_declaration_boundary.\
DeclarationBoundaryTests.test_graph_trait_method_binding_retains_overlapping_definition_ids
```

Run the accepted-selection and import owners next:

```bash
bin/blorp test blorp/test/compiler/stage_06_typecheck/test_typecheck_bridge.brp
bin/blorp test blorp/test/compiler/stage_06_typecheck/test_frontend_graph_typecheck.brp
bin/blorp test blorp/test/compiler/stage_06_typecheck/test_typecheck_state.brp
```

Then exercise each downstream boundary independently:

```bash
bin/blorp test blorp/test/compiler/stage_06_typecheck/test_typed_ast_json.brp
bin/blorp test blorp/test/compiler/stage_07_ctfe/test_ctfe_ir.brp
bin/blorp test blorp/test/compiler/stage_08_core_lower/test_core_lower.brp
```

Finish with the broad checks only once:

```bash
scripts/compiler-check --changed
scripts/test compiler-blorp
```

Use one deterministic baseline/candidate pair for allocation and instruction
guards. Additional pairs are warranted only if a result is near a rejection
threshold. Wall time is not a claim for this packet.

## Metric Classification

| Metric family | Classification | Reason |
| --- | --- | --- |
| Typecheck and production latency | Guard-only | The changed branch is small and wall time is noisy. |
| Managed allocations and bytes | Primary | The accepted target replaces a managed string payload with scalar identity. |
| Peak RSS and retained bytes | Primary | Deferred calls should retain less descriptive state and no parallel authority. |
| Retired instructions | Primary | Later policies avoid accepted-call name projection and re-entry. |
| Semantic work | Primary | Bare trait candidates and false collision work must decline. |
| Product, generated C, and compiler size | Guard-only | Generated semantics are unchanged; compiler growth must remain bounded. |
| Tooling query cost | Not applicable | No tooling query or snapshot API changes; JSON output remains a compatibility projection. |

## Acceptance Criteria

- [x] The focused structural test fails before the accepted unresolved variant
  exists and passes after it is introduced.
- [x] A graph-backed unresolved trait call retains the exact declaring
  `TraitId` and no callable ID.
- [x] Graphless unresolved calls retain the explicit string compatibility
  variant.
- [x] Accepted inference policies use the exact trait ID for selected and
  unresolved targets.
- [x] Typed JSON, CTFE, and Core validate the retained ID against their
  canonical definition table.
- [x] Core projects the validated ID to the existing deferred-dispatch name
  only at lowering.
- [x] Trait-method import rows retain their explicit kind and exact overlapping
  definition IDs.
- [x] Callable/global/CTFE/Core consumers preserve those overlapping exact
  definition targets.
- [x] Qualified-only same-named traits do not create an unqualified method
  collision.
- [x] An imported receiver can use its public trait implementation through
  UFCS without importing the trait method as a bare name.
- [x] Aliased selective trait-method calls retain their exact declaring
  `TraitId`.
- [x] Overlapping definition targets are rejected when they do not match the
  imported method spelling.
- [x] Accepted trait visibility is opaque and rejects a foreign issuing table.
- [x] Multiple applicable implicit UFCS traits report a stable ambiguity with
  actionable help, and private imported traits remain unavailable.
- [x] Local ambiguity, selective imports, imported UFCS, compiler-prelude
  visibility, and resource policy remain covered.
- [x] Focused structural, bridge, frontend graph, state, typed JSON, CTFE IR,
  and Core lowering suites pass.
- [x] The manifest-owned changed check and full compiler suite pass.
- [x] One retained baseline/candidate pair preserves semantic checksums and
  keeps allocations, retained memory, retired instructions, RSS, peak
  footprint, and compiler size within their thresholds.
- [x] Independent code review and test review pass.

## Measurements

The retained checked-bodies workload produced identical semantic and
constructor checksums and identical semantic-work counts in one clean
baseline/candidate pair. Allocations, releases, retained objects, allocated
bytes are exactly neutral. Retired instructions improve 0.103%, cycles improve
0.605%, maximum RSS improves 0.850%, peak footprint improves 1.015%, setup time
improves 0.296%, and the measured window improves 0.373%. The one-shot
wall-time result is an observation, not a claim. Compiler executable size grows
0.183%.

The full evidence, commands, and raw values are recorded in
[`compiler_accepted_unresolved_trait_identity_step2e_2026-09-12.md`](../../../benchmarks/results/compiler_accepted_unresolved_trait_identity_step2e_2026-09-12.md)
and
[`compiler_accepted_unresolved_trait_identity_step2e_2026-09-12.tsv`](../../../benchmarks/results/compiler_accepted_unresolved_trait_identity_step2e_2026-09-12.tsv).

## Validation Evidence

- `make -j1` rebuilt the self-hosted compiler successfully.
- `scripts/compiler-check --changed` passed 15 production sources, 34 focused
  suites, and 5 special checks in 409.72 seconds.
- `scripts/test compiler-blorp` passed all 4,498 compiler-owned tests in 3
  minutes 12 seconds.
- The focused structural, declaration, bridge, state, JSON, CTFE IR, and Core
  lowering suites cover the representation, provenance, visibility,
  diagnostics, and final string-projection boundaries independently.
- After the final production-provenance review correction, `make -j1`, the
  144-test declaration suite, and `bin/blorp check --no-format
  blorp/src/main.brp` passed. Independent code and test reviews found no
  remaining issue or coverage gap.

## Performance Expectations And Rollback

The primary mechanical win is a smaller accepted unresolved payload: a scalar
`TraitId` replaces a managed trait-name string in every such typed call. The
visibility correction also avoids populating and collision-checking bare
method entries for qualified-only traits. The combined change adds no retained
parallel index.

The import variant grows by one list field so it can preserve exact overlapping
targets without erasing its semantic kind. That list was already retained by
the alternative definition-binding variant; the change combines existing
facts rather than duplicating them. Measurements must reject the packet if the
new projection helpers or visibility construction materially regress managed
allocations, retained objects, instructions, RSS, peak footprint, or compiler
size.

## Next Packet

Replace the accepted trait-method visibility adapter's remaining late
`ModuleId + source-name` scan with exact `SourceNameId + TraitMethodId` rows
after the accepted trait table is published. Delete the remaining accepted
bare-method string dictionary in the same cut; do not add a parallel integer
dictionary beside it.
