# Preserve Exact Qualified Accepted Trait-Call Targets

**Status:** Complete

**Roadmap:** [Normalized Semantic Compilation Roadmap](NORMALIZED_SEMANTIC_COMPILATION_ROADMAP.md), Step 2e, eighteenth packet

**Depends on:** Exact selected accepted trait-call targets (Issue 88)

## Outcome

Qualified graph-backed trait selection now publishes the same exact typed target
as unqualified accepted selection:

```blorp
ResolvedAcceptedTraitMethodCall(TraitId, CallableId)
```

The accepted authority result makes its canonical trait identity mandatory and
authority-issued:

```blorp
private record AcceptedQualifiedTraitMethodInfoRep {
	trait_id: TraitId,
	trait_name: String,
	trait_identity: BoundTraitIdentity,
	method: TraitMethodSig,
	implementation_method: ImplMethodInfo
}

opaque type AcceptedQualifiedTraitMethodInfo = AcceptedQualifiedTraitMethodInfoRep
```

Consumers use explicit projections; they cannot construct or recombine a trait
ID, bound identity, signature, and implementation from different rows.
Inference distinguishes accepted and graphless compatibility results with a
private union. A qualified call resolved by accepted authority constructs
`AcceptedTraitMethodCalleeIdentity(trait_id)`; the existing selected-call
constructor then retains `TraitId + CallableId`. Env fallback remains explicit
and string-backed.

## Context

Issue 88 introduced an exact selected target, but qualified trait calls still
forced every result through the compatibility identity:

```blorp
identity = CompatibilityTraitMethodCalleeIdentity
```

This happened even when `accepted_find_qualified_trait_method_info` had already
found the exact topology method and concrete implementation row. Its public
result retained `trait_identity: Option[BoundTraitIdentity]` because inference
also used the same record shape for graphless Env fallback. That optional field
encoded two semantic domains through hidden coupling: `Some` usually meant an
accepted graph result and `None` usually meant compatibility.

Widening that record with another optional ID would make the illegal mixed state
larger. Instead, accepted authority now returns a fully accepted value and
inference owns the domain split explicitly.

## Invariants

1. `accepted_qualified_trait_method_id` projects the owner of the exact
   topology-issued `TraitMethodId` selected by qualified lookup.
2. The projected bound identity is mandatory and derived from that same ID.
3. Only the accepted authority can construct the opaque result, so callers
   cannot recombine an unrelated trait ID, signature, and implementation row.
4. `QualifiedTraitMethodSelection` explicitly distinguishes accepted authority
   from graphless compatibility; no `Option` convention or name heuristic makes
   that decision.
5. Accepted selection constructs `AcceptedTraitMethodCalleeIdentity(TraitId)`.
6. Compatibility selection retains its pre-existing
   `CompatibilityTraitMethodCalleeIdentity` and string-backed target.
7. The concrete implementation remains the canonical `CallableId` already
   stored in `ImplMethodInfo.target`.
8. The resulting accepted target is validated at typed JSON, CTFE, and Core
   boundaries by Issue 88's pair validation.
9. No additional retained dictionary, parallel ID list, sentinel, packed ID,
   or generic integer map is introduced.

## Code Example

For:

```blorp
-- contracts.brp
trait Renderable:
	pure func show(value: Self) -> String

trait Show: Renderable:
	pure func detail(value: Self) -> String

-- dep.brp
import:
	contracts: Renderable, Show

record Data {value: Int}

implements Show for Data:
	pure func show(value: Data) -> String:
		"data"
	pure func detail(value: Data) -> String:
		"detail"

implements Renderable for Data:
	pure func show(value: Data) -> String:
		"base"

-- main.brp
import:
	dep as D

pure func render(data: D.Data) -> String:
	D.show(data)
```

the call target previously retained:

```text
ResolvedSelectedTraitMethodCall("Show", implementation CallableId)
```

It now retains:

```text
ResolvedAcceptedTraitMethodCall(contracts::Renderable TraitId, dep::Show.show CallableId)
```

The bridge regression deliberately puts the child implementation first. It
independently locates the declaring `Renderable` row in `contracts` and the
selected child `Show.show` callable in `dep`, then compares both exact IDs. It
also verifies that the retained `BoundTraitIdentity` has `Renderable`'s module
and definition ID. A direct-trait fixture would not catch accidentally
publishing the implementation trait in place of the inherited method's
declaring trait.

## Implementation Strategy

### 1. Fail on the old mixed representation

The structural guard requires accepted qualified info to contain a mandatory
`TraitId` and `BoundTraitIdentity`, plus a private accepted-versus-compatibility
selection union in inference. The in-memory bridge fixture requires a qualified
call to retain the exact trait and implementation IDs. Both failed before the
production change.

### 2. Publish one opaque accepted authority result

`accepted_find_qualified_trait_method_info` already owns the exact
`AcceptedTraitMethodMatch`. It now publishes the owner of `requested.id` and
derives `BoundTraitIdentity` from that same owner. The private representation is
wrapped as `AcceptedQualifiedTraitMethodInfo`; projections expose the five
coherent facts without exposing a public constructor. Inherited methods
therefore retain their declaring trait rather than the child trait through
which they were found.

### 3. Make the mixed domain explicit in inference

`QualifiedTraitMethodSelection` has two variants:

```blorp
private union QualifiedTraitMethodSelection:
	AcceptedQualifiedTraitMethodSelection(AcceptedQualifiedTraitMethodInfo)
	CompatibilityQualifiedTraitMethodSelection(TraitMethodCallee, ImplMethodInfo)
```

The accepted arm builds an accepted callee identity and passes a present bound
identity. The compatibility arm carries the existing Env callee and no graph
identity. A small shared helper performs only the common call construction and
invariant checking after that explicit decision.

### 4. Keep source strings out of the retained target

The authority still exposes `trait_name` because current inference policies use
source-oriented trait APIs. That string is transient call-construction context;
it is not stored in the accepted `ResolvedCallTarget`. Retiring those remaining
inference policy strings is a separate packet rather than mixing policy API
migration into selection identity.

### 5. Record the backend rough edge

The first compact implementation used:

```blorp
accepted_find_qualified_trait_method_info(...)
	.map(AcceptedQualifiedTraitMethodSelection)
```

Generated C referenced the union constructor without its emitted definition
symbol and failed to compile. The final code uses an explicit `match`, which is
clear and allocation-conscious. A general fix for passing union constructors as
first-class functions belongs to backend tooling, not this semantic packet.

## Fast Feedback Loop

Run the millisecond structural guard first:

```bash
python3 -m unittest \
  blorp.test.compiler.stage_06_typecheck.support.test_declaration_boundary.\
DeclarationBoundaryTests.test_qualified_accepted_trait_selection_preserves_exact_identity
```

Then run the in-memory semantic owner:

```bash
bin/blorp test blorp/test/compiler/stage_06_typecheck/test_typecheck_bridge.brp
```

The direct fixture covers an inherited, implementation-owner qualified call and
exact declaring-trait/callable identity. Before broad validation, run the declaration and
inference suites because the accepted result schema and call construction are
their respective boundaries:

```bash
bin/blorp test \
  blorp/test/compiler/stage_06_typecheck/test_typecheck_decl.brp \
  blorp/test/compiler/stage_06_typecheck/test_infer.brp
```

For allocation feedback, use one candidate leak screen. A temporary in-process
probe resets `MemStats`, calls
`test_typed_graph_preserves_exact_qualified_trait_method_identity` once, captures
the Boolean result, and prints the four memory counters. Remove the probe
immediately. The counters are deterministic, so repeated runs and wall-time
sampling add no useful signal here. Use the unchanged checked-bodies fixture,
not this semantic assertion, for a like-for-like baseline/candidate comparison.

Finish with one unchanged checked-bodies regression screen and the changed-owner
gate:

```bash
/usr/bin/time -lp benchmarks/compiler_typecheck_phase_profile \
  bodies 1 32 4 16 16 memory
scripts/compiler-check --changed
```

## Acceptance Criteria

- [x] The structural guard fails on the optional accepted identity and absent
  qualified selection union.
- [x] The in-memory qualified-call fixture fails on the string-backed target.
- [x] Accepted qualified info is opaque and publishes mandatory `TraitId` and
  `BoundTraitIdentity` projections from the same exact method owner.
- [x] Accepted and Env compatibility results are distinct union variants.
- [x] Accepted qualified calls retain exact `TraitId + CallableId` targets.
- [x] The fixture independently verifies an inherited method's declaring trait,
  matching bound identity, and child-trait implementation callable.
- [x] Env fallback remains explicit and behavior-compatible.
- [x] The direct candidate probe releases every allocation and retains zero
  objects and bytes.
- [x] All 45 structural, 143 declaration, 305 inference, and 118 bridge tests
  pass.
- [x] The initial changed-owner gate passes all selected owners; the opaque
  refinement is covered by the final focused verification.
- [x] Checked-bodies allocations, releases, retained objects, and allocated bytes
  are exactly neutral against Issue 88.
- [x] Checked-bodies instructions remain within 0.002%; allocations and retained
  memory are neutral, while RSS and peak footprint improve about 0.91%-1.01%.
- [x] Compiler executable size remains effectively neutral at +0.0037%.
- [x] Independent review and test-runner verification report no unresolved
  issue.

## Measurements

The direct one-call candidate leak screen produced:

| Metric | Candidate |
| --- | ---: |
| Allocations | 30,981 |
| Releases | 30,981 |
| Retained objects | 0 |
| Retained bytes | 0 |

This is intentionally not reported as a focused before/after allocation delta:
the old string-backed target makes the semantic assertion return early, so its
cleanup path is not comparable. The screen establishes that the candidate's
opaque selection and exact target leave no retained call-owned objects. The
checked-bodies table below is the valid baseline/candidate regression guard.

The unchanged checked-bodies guard preserved semantic checksum
`2057305071532051463`, constructor checksum `-2142865109331864226`, 34 primary
outputs, and zero secondary outputs:

| Metric | Issue 88 | Candidate | Change |
| --- | ---: | ---: | ---: |
| Allocations | 17,244 | 17,244 | neutral |
| Releases | 12,936 | 12,936 | neutral |
| Retained objects | 4,308 | 4,308 | neutral |
| Allocated bytes | 350,408 | 350,408 | neutral |
| Retired instructions | 6,281,338,017 | 6,281,407,552 | +0.0011% |
| Cycles | 1,732,046,543 | 1,824,142,079 | observation only |
| Maximum RSS | 25,149,440 | 24,920,064 | -0.9121% |
| Peak footprint | 17,760,568 | 17,580,344 | -1.0147% |
| Compiler bytes | 19,443,168 | 19,443,888 | +0.0037% |

The earlier candidate screen measured 1,721,103,204 cycles, while the final
screen measured 1,824,142,079 with nearly identical retired instructions. That
spread confirms one-shot cycles are environmental noise, not a regression
claim. Wall, setup, and window time are observations only. See
[`compiler_qualified_accepted_trait_call_identity_step2e_2026-09-11.md`](../../../benchmarks/results/compiler_qualified_accepted_trait_call_identity_step2e_2026-09-11.md)
and its TSV companion.

## Next Packet

Audit the three remaining inference-time trait-name policy consumers
(elementwise support, self-bound obligations, and resource-argument selection)
and move those that have accepted provenance to `TraitId`-backed queries. Keep
unresolved dispatch string retirement separate until Core has an ID-backed
deferred-trait target.
