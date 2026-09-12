# Preserve Exact Selected Accepted Trait-Call Targets

**Status:** Complete

**Roadmap:** [Normalized Semantic Compilation Roadmap](NORMALIZED_SEMANTIC_COMPILATION_ROADMAP.md), Step 2e, seventeenth packet

**Depends on:** Exact accepted trait-method resolution (Issue 87)

## Outcome

Graph-backed, unqualified accepted trait calls now retain a value-derived target
after concrete implementation selection:

```blorp
union ResolvedCallTarget:
	ResolvedAcceptedTraitMethodCall(TraitId, CallableId)
	ResolvedSelectedTraitMethodCall(String, CallableId)
	ResolvedUnindexedSelectedTraitMethodCall(String, Int)
	ResolvedUnresolvedTraitMethodCall(String)
	-- other call categories
```

The exact accepted variant carries the selected trait contract and concrete
implementation callable. It does not retain the trait source string. Graphless,
unindexed, qualified-compatibility, and unresolved dispatch remain in their
explicit string-backed variants.

CTFE dependency discovery and CTFE IR use the `CallableId` directly. Typed JSON
and lint project a trait name from `TraitId` and the invocation's
`DefinitionTable` only when human- or tool-facing output needs it. Core lowering
performs the same projection at the existing `SelectedTraitCall` compatibility
boundary; Core and C-emission representation are not migrated in this packet.
Inference still projects the name from the validated ID for elementwise policy,
self-bound obligation checking, and resource-argument policy. Those three
semantic compatibility consumers remain explicit follow-up boundaries; the
typed target no longer retains their source string.

## Context

Issue 87 made accepted method visibility and signature selection exact, but
`resolved_call_from_trait_method_callee` immediately projected the declaring
trait back to a string:

```blorp
ResolvedSelectedTraitMethodCall(callee.trait_name, callable_id)
```

That spelling then survived through typed AST metadata despite the accepted
table already providing a canonical `TraitMethodId` and concrete dispatch
already providing a canonical `CallableId`.

Retaining the complete `TraitMethodId` in the typed target was the first
prototype. A focused 32-call probe showed that its current structured
representation added 64 retained objects and 2,048 retained bytes—two objects
per call. That conflicts with the memory-ceiling objective. Once a concrete
implementation is selected, the exact semantic target needed downstream is the
trait contract plus implementation callable: `TraitId + CallableId`. The
method slot has already selected and validated the signature, while the
concrete method's `CallableId` identifies the executable definition. The final
variant therefore carries those two compact IDs and restores retention to
baseline.

## Invariants

1. Only a method resolved through accepted authority can construct
   `ResolvedAcceptedTraitMethodCall`.
2. The target's `TraitId` is derived from the owner of the exact
   `TraitMethodId`; it is never reconstructed from a trait name.
3. The target's `CallableId` is the selected accepted implementation method.
4. `TraitId + CallableId` is the exact post-selection dispatch identity. The
   method source spelling in `ResolvedCallInfo` is diagnostic/compatibility
   context, not target identity.
5. Accepted and compatibility callees are distinguished by a private union;
   no boolean flag, sentinel ID, or name heuristic decides which public target
   variant is constructed.
6. Graphless, unindexed, qualified-only, compiler-builtin, and unresolved calls
   retain their existing explicit compatibility variants.
7. CTFE does not reconstruct a trait name to discover or invoke the concrete
   callable.
8. Typed JSON and lint may project a trait name from the invocation-local
   definition table because their contracts are descriptive.
9. Core lowering projects the trait name once at the current Core boundary;
   the typed target itself remains ID-backed.
10. Typed JSON, CTFE, and Core lowering validate both halves of the pair before
    admitting or projecting it. Compiler-prelude and graph trait domains are
    validated explicitly.
11. No C-emission schema, generic integer dictionary, packed composite ID,
    magic numeric encoding, or parallel target index is introduced.

## Code Example

For:

```blorp
import:
	dep: Data, HasLength

pure func measure[T](data: Data[T]) -> Int:
	data.length()
```

the accepted typed target previously retained:

```text
ResolvedSelectedTraitMethodCall("HasLength", implementation CallableId)
```

It now retains:

```text
ResolvedAcceptedTraitMethodCall(HasLength TraitId, implementation CallableId)
```

The JSON projection remains compatible:

```json
{
  "kind": "trait_method",
  "trait_name": "HasLength",
  "impl_target": {
    "callable_id": 42,
    "module_path": "dep"
  }
}
```

The string in that JSON object is derived at serialization time; it is no
longer the semantic target carried by the accepted typed AST.

## Implementation Strategy

### 1. Lock the typed boundary first

The declaration-boundary guard requires
`ResolvedAcceptedTraitMethodCall(TraitId, CallableId)`, a private accepted versus
compatibility callee identity, and exact target construction inside
`resolved_call_from_trait_method_callee`. It failed against Issue 87 before
production code changed.

### 2. Preserve accepted provenance transiently

`TraitMethodCalleeIdentity` distinguishes an accepted `TraitId` from the
compatibility domain. The accepted constructor obtains that ID by projecting
the owner from the authority-issued `TraitMethodId`. Env and qualified
compatibility constructors use the explicit compatibility variant.

This private sum type prevents an accepted target from being selected merely
because a trait name happens to match.

### 3. Publish a phase-specific selected target

When accepted implementation lookup yields a graph `CallableId`, resolution
constructs `ResolvedAcceptedTraitMethodCall`. Compatibility callees retain
`ResolvedSelectedTraitMethodCall`. Unindexed and unresolved outcomes remain
unchanged, keeping this packet limited to concrete graph-backed selection.

Equality compares exact `TraitId` and `CallableId` values. Generic callable-ID
queries treat the new variant like any other selected concrete method.

### 4. Keep CTFE identity-only

CTFE body dependency discovery reads the concrete callable definition ID. CTFE
IR validates the `CallableId` against its `DefinitionTable` and classifies the
call as local or imported from the callable owner. Neither operation needs a
trait source name.

### 5. Validate both IDs, then project at explicit boundaries

`trait_id_is_valid` recognizes canonical compiler-prelude IDs and graph trait
rows. Typed JSON and CTFE validate that trait ID alongside the concrete callable
ID. Core lowering fails closed before constructing the current string-backed
`SelectedTraitCall`. Typed JSON and lint derive descriptive names with
`trait_id_name`; Core derives one only after validation.

Inference derives a name from the validated ID in three pre-existing semantic
policies: elementwise lifting, self-bound checking, and resource-argument
selection. These are deliberately documented compatibility consumers rather
than being mislabeled as descriptive boundaries.

### 6. Reject the retention-heavy representation

The full-`TraitMethodId` prototype passed semantic tests but added two retained
objects per call. Replacing it with the minimal post-selection identity removed
all retained-object and retained-byte growth. The rejected shape is not left in
the source.

## Fast Feedback Loop

Start with the millisecond structural guard:

```bash
python3 -m unittest \
  blorp.test.compiler.stage_06_typecheck.support.test_declaration_boundary.\
DeclarationBoundaryTests.test_selected_accepted_trait_call_preserves_exact_identity
```

Then run the direct inference and in-memory graph tests:

```bash
bin/blorp test blorp/test/compiler/stage_06_typecheck/test_infer.brp
bin/blorp test blorp/test/compiler/stage_06_typecheck/test_typecheck_bridge.brp
```

The bridge fixture checks that imported `Data[T].length()` carries the exact
accepted trait ID and selected implementation module. The broader changed-owner
gate covers typed JSON compatibility, CTFE dependency/IR consumers, Core
lowering, and lint:

```bash
scripts/compiler-check --changed
```

For allocation feedback, use one temporary in-process probe that resets
`MemStats` and calls
`test_typecheck_source_uses_imported_trait_method_as_ufcs` 32 times. One pair is
enough. Remove the probe after recording allocations, releases, current
objects, and allocated bytes.

For native work, retain the same exact-profile bridge boundary as Issue 87:

```bash
/usr/bin/time -lp bin/blorp test \
  --profile-mode exact \
  --profile-module blorp/src/compiler/stage_06_typecheck/type_system/accepted_trait_implementation_authority \
  --profile-module blorp/src/compiler/stage_06_typecheck/infer \
  blorp/test/compiler/stage_06_typecheck/test_typecheck_bridge.brp
```

Finish with one checked-bodies build guard. It is not a claim that selected
trait calls dominate the fixture; it protects overall compiler construction.

## Acceptance Criteria

- [x] The structural guard fails against Issue 87's string-backed selected
  target.
- [x] Accepted unqualified concrete dispatch carries `TraitId + CallableId`.
- [x] Compatibility and unresolved domains remain explicit variants.
- [x] The in-memory graph fixture verifies accepted trait and implementation
  identity.
- [x] CTFE dependency discovery and IR use the concrete callable without a
  trait-name reconstruction.
- [x] Typed JSON remains protocol-compatible through table-backed projection.
- [x] Lint's standard-list recognition remains behavior-compatible.
- [x] Core lowering projects at its existing boundary; C emission is unchanged.
- [x] The full-`TraitMethodId` retained-memory prototype is removed.
- [x] The focused probe adds only 0.0090% transient allocations/releases with
  zero retained-object or retained-byte growth.
- [x] Both IDs fail closed at typed JSON, CTFE, and Core boundaries.
- [x] All 44 structural, 305 inference, and 117 bridge tests pass.
- [x] The final changed-owner gate passes its twelve suites and three special
  checks, including leak validation selected by the shared identity helper.
- [x] Changed-path instructions remain within 0.18%, cycles within 0.66%, RSS
  improves 3.45%, and peak footprint remains within 0.13%.
- [x] The build-level screen is allocation-neutral and remains within 0.66%
  for instructions, cycles, RSS, and peak footprint.
- [x] Compiler executable size remains effectively neutral at +0.0038%.
- [x] Independent review and test-runner verification report no unresolved
  issue.

## Measurements

The 32-call imported-trait-method probe remained semantically valid:

| Metric | Issue 87 baseline | Candidate | Change |
| --- | ---: | ---: | ---: |
| Allocations | 1,066,112 | 1,066,208 | +0.0090% |
| Releases | 1,066,080 | 1,066,176 | +0.0090% |
| Retained objects | 32 | 32 | neutral |
| Retained bytes | 2,048 | 2,048 | neutral |

The exact-profile bridge screen passed all 117 tests:

| Metric | Issue 87 baseline | Candidate | Change |
| --- | ---: | ---: | ---: |
| Retired instructions | 174,498,604,370 | 174,798,755,752 | +0.1720% |
| Cycles | 45,279,195,818 | 45,577,618,124 | +0.6591% |
| Maximum RSS | 796,475,392 | 769,015,808 | -3.4476% |
| Peak footprint | 590,152,472 | 590,889,776 | +0.1249% |

The checked-bodies build guard produced identical semantic checksums and work
counts:

| Metric | Issue 87 baseline | Candidate | Change |
| --- | ---: | ---: | ---: |
| Allocations | 17,244 | 17,244 | neutral |
| Releases | 12,936 | 12,936 | neutral |
| Retained objects | 4,308 | 4,308 | neutral |
| Allocated bytes | 350,408 | 350,408 | neutral |
| Retired instructions | 6,280,666,388 | 6,281,338,017 | +0.0107% |
| Cycles | 1,732,531,368 | 1,732,046,543 | -0.0280% |
| Maximum RSS | 24,985,600 | 25,149,440 | +0.6557% |
| Peak footprint | 17,711,440 | 17,760,568 | +0.2774% |
| Compiler bytes | 19,442,432 | 19,443,168 | +0.0038% |

One-shot wall and setup/window times are retained in the detailed result but
are not latency claims. See
[`compiler_selected_accepted_trait_call_identity_step2e_2026-09-11.md`](../../../benchmarks/results/compiler_selected_accepted_trait_call_identity_step2e_2026-09-11.md)
and its TSV companion.

## Next Packet

Decide whether qualified accepted trait selection can publish the same exact
`TraitId + CallableId` target without widening its current mixed accepted/Env
result type. Keep unresolved dispatch string retirement separate until Core has
an ID-backed deferred-trait target.
