# Preserve Exact Accepted Trait-Method Resolution

**Status:** Complete

**Roadmap:** [Normalized Semantic Compilation Roadmap](NORMALIZED_SEMANTIC_COMPILATION_ROADMAP.md), Step 2e, sixteenth packet

**Depends on:** Exact unqualified accepted-UFCS resolution (Issue 86)

## Outcome

Accepted trait-method lookup now retains the canonical method identity issued by
the accepted trait topology:

```blorp
private record AcceptedTraitImplementationAuthorityRep {
	trait_method_id_by_name: Dict[String, TraitMethodId],
	-- other accepted relations
}

opaque type AcceptedTraitMethodBinding = AcceptedTraitMethodMatch

pure func accepted_trait_find_function_method(
	authority: AcceptedTraitImplementationAuthority,
	method_name: String,
) -> Option[AcceptedTraitMethodBinding]
```

Inference follows the exact ID to the declaring trait row and signature. It no
longer asks accepted authority for a trait name and then repeats a name-based
method lookup. Source spelling remains the input key because this is a source
visibility query; `TraitMethodId` is now the semantic target.

## Context

Issue 86 preserved exact `CallableId` through accepted unqualified UFCS
selection, but trait methods use a separate topology and identity domain. The
accepted trait authority still built this relation:

```blorp
trait_name_by_method_name: Dict[String, String]
```

The inference path used the returned trait spelling to search the accepted
table a second time:

```blorp
trait_name ?= accepted_trait_function_trait(authority, method_name)
trait_method_callee_from_trait(context, source_name, method_name, trait_name)
```

That lost the exact method row between visibility and semantic lookup. It also
made a source name serve as both a legitimate visibility key and an accidental
semantic target.

The early import binding cannot yet store a `TraitMethodId`: imports are parsed
and bound before the accepted trait topology issues those IDs. The earliest
correct cutover is accepted-authority construction, where source-visible names
and issued method rows coexist. Moving the cutover earlier would require a
parallel provisional identity or a later patch-up table; both would weaken the
single-authority design.

## Invariants

1. Accepted method visibility maps a source method spelling to the exact
   `TraitMethodId` issued by `AcceptedTraitImplementationTable`.
2. The ID owner identifies the declaring trait, including inherited methods;
   it is not reconstructed from the visible trait name.
3. Exact lookup validates the authority-issued ID's owner and method index
   against the canonical table before returning one opaque binding containing
   the ID, signature, and declaring trait.
4. Imported method signatures preserve their stored module qualification;
   owner-local signatures retain the existing localization behavior.
5. Duplicate method-name diagnostics preserve their current source-oriented
   trait names, projected from the conflicting IDs only when the diagnostic is
   built.
6. The public compatibility query that enumerates `(method, declaring trait)`
   pairs may project strings, but its internal traversal carries method IDs.
7. Env fallback remains string-backed because standalone and compiler-builtin
   trait methods do not necessarily belong to the accepted table.
8. The current `TraitMethodCallee` and typed/Core call target remain a named
   compatibility boundary. This packet does not extend into CTFE, Core, or C
   emission.
9. No generic integer dictionary, raw storage-key reconstruction, parallel
   method index, sentinel, or name-shape heuristic is introduced.

## Code Example

For an accepted trait declaration:

```blorp
trait Renderable:
	pure func render(self: Self) -> String
```

the authority previously retained the equivalent of:

```text
"render" -> "Renderable"
```

and inference searched for `("Renderable", "render")` again. It now retains:

```text
"render" -> TraitMethodId(owner = Renderable's TraitId, index = 0)
```

The exact ID selects the method row and declaring trait. Only the resulting
source-facing callee description is projected to strings for the existing
typed-call boundary.

## Implementation Strategy

### 1. Lock the representation boundary first

The declaration-boundary test requires the accepted authority to store
`Dict[String, TraitMethodId]`, expose one authority-owned lookup returning an
opaque exact binding, and make inference consume that result. It rejects
the former string target, the old two-stage name lookup, and a public API that
accepts an arbitrary `TraitMethodId`. The test failed before production code
changed.

### 2. Build the target relation from canonical rows

`table_trait_methods_seen` now returns `(source method name, TraitMethodId)`.
Each declared method pairs its signature slot with the table-issued ID at that
same slot. Supertrait traversal carries those exact pairs, so an inherited
method continues to point at its declaring trait rather than the visible child
trait.

The authority's source-visible dictionary stores those pairs directly. When a
duplicate source method name names two different IDs, diagnostic construction
projects the two owner IDs to trait names; diagnostic strings are not retained
as the semantic relation.

### 3. Validate exact lookup at the table boundary

The private `table_find_trait_method_by_id` resolves the dictionary-issued ID
owner to the accepted trait slot, reads both the stored method ID and signature
at the requested index, and checks exact ID equality. `TraitMethodId` does not
yet carry issuing-table provenance, so the arbitrary-ID resolver is deliberately
not public: callers obtain the authority's opaque binding atomically from a
source visibility lookup and can only project its validated fields.

### 4. Resolve once in inference

`infer_find_function_trait_method` now returns the existing
`TraitMethodCallee` after one exact accepted lookup. Local, imported,
imported-receiver, and qualified compatibility paths reuse that result instead
of resolving a trait spelling and then searching again by method spelling.

The fallback arm still uses Env and `trait_method_callee_from_trait`. This is a
deliberate compatibility domain for non-accepted declarations, not an alternate
accepted lookup.

### 5. Keep the packet allocation-conscious

Two broader prototypes were rejected:

- adding an optional ID to every `TraitMethodCallee`, although no downstream
  phase consumed it yet;
- introducing a new inference union merely to distinguish exact and Env lookup
  results.

The retained design uses one opaque authority-issued binding and the existing
callee type. It advances canonical selection without imposing an inference
sum-type wrapper on every trait-method call, and it prevents arbitrary IDs from
crossing the validation boundary. A closure-based uniqueness helper also
exposed a backend emission failure, so the final small loop states equality
directly and avoids capturing `TraitMethodId` in that helper.

## Fast Feedback Loop

Start with the millisecond structural guard:

```bash
python3 -m unittest \
  blorp.test.compiler.stage_06_typecheck.support.test_declaration_boundary.\
DeclarationBoundaryTests.test_accepted_trait_method_lookup_preserves_exact_identity
```

Then run the smallest semantic owner:

```bash
bin/blorp test blorp/test/compiler/stage_06_typecheck/test_typecheck_decl.brp
```

Its fixture creates `BaseRenderable.render` plus a `Renderable` subtrait,
obtains the base method's issued `TraitMethodId` from the topology, and verifies
that inherited visibility resolves the exact base ID, signature, and declaring
trait. Next cover inference consumers, including imported localization:

```bash
bin/blorp test blorp/test/compiler/stage_06_typecheck/test_infer.brp
bin/blorp test blorp/test/compiler/stage_06_typecheck/test_typecheck_bridge.brp
```

For allocation feedback, use one temporary in-process probe that resets
`MemStats` and calls
`test_typecheck_source_uses_imported_trait_method_as_ufcs` 32 times. One
baseline/candidate pair is sufficient; remove the probe afterward.

For native work, profile only the changed authority and inference modules:

```bash
/usr/bin/time -lp bin/blorp test \
  --profile-mode exact \
  --profile-module blorp/src/compiler/stage_06_typecheck/type_system/accepted_trait_implementation_authority \
  --profile-module blorp/src/compiler/stage_06_typecheck/infer \
  blorp/test/compiler/stage_06_typecheck/test_typecheck_bridge.brp
```

Finally run `scripts/compiler-check --changed` and one checked-bodies resource
screen. The bodies fixture is a build-level regression guard, not evidence that
the exact trait-method lookup dominates compilation time.

## Acceptance Criteria

- [x] The structural guard fails against Issue 86's string-target relation.
- [x] Accepted authority maps source method names to exact `TraitMethodId`s.
- [x] Inherited methods retain their declaring-trait owner ID.
- [x] Authority-owned lookup validates owner, slot, and stored method identity;
  arbitrary foreign IDs are not accepted at the public API.
- [x] Inference resolves accepted method identity and signature once.
- [x] Env and typed/Core compatibility boundaries remain explicit and bounded.
- [x] The focused probe adds only 0.0450% transient allocations/releases and
  retains no additional objects or bytes.
- [x] All 42 structural, 143 declaration, 305 inference, and 117 bridge tests
  pass.
- [x] The changed-owner compiler gate passes.
- [x] Changed-path instructions remain within 0.17%, cycles within 0.40%, and
  peak footprint within 0.26%.
- [x] The build-level screen stays within 0.10% for native and memory metrics;
  retained objects and allocated bytes are neutral.
- [x] Compiler executable size remains within 0.09%.
- [x] Independent review and test-runner verification report no unresolved
  issue.

## Measurements

The 32-call imported-trait-method probe remained semantically valid:

| Metric | Issue 86 baseline | Candidate | Change |
| --- | ---: | ---: | ---: |
| Allocations | 1,065,632 | 1,066,112 | +0.0450% |
| Releases | 1,065,600 | 1,066,080 | +0.0450% |
| Retained objects | 32 | 32 | neutral |
| Retained bytes | 2,048 | 2,048 | neutral |

The exact-profile bridge screen passed all 117 tests:

| Metric | Issue 86 baseline | Candidate | Change |
| --- | ---: | ---: | ---: |
| Retired instructions | 174,217,787,115 | 174,498,604,370 | +0.1612% |
| Cycles | 45,102,523,921 | 45,279,195,818 | +0.3917% |
| Maximum RSS | 765,280,256 | 796,475,392 | +4.0763% |
| Peak footprint | 588,661,528 | 590,152,472 | +0.2533% |

Maximum RSS is a noisy high-water observation here: retained memory is neutral,
peak footprint stays within 0.26%, and the smaller build-level screen keeps RSS
and peak within 0.10%. No wall-time claim is made from one baseline/candidate
pair.

The checked-bodies build guard produced identical semantic checksums and work
counts:

| Metric | Issue 86 baseline | Candidate | Change |
| --- | ---: | ---: | ---: |
| Allocations | 17,232 | 17,244 | +0.0696% |
| Releases | 12,924 | 12,936 | +0.0929% |
| Retained objects | 4,308 | 4,308 | neutral |
| Allocated bytes | 350,408 | 350,408 | neutral |
| Retired instructions | 6,275,021,261 | 6,280,666,388 | +0.0900% |
| Cycles | 1,738,301,765 | 1,732,531,368 | -0.3320% |
| Maximum RSS | 25,001,984 | 24,985,600 | -0.0655% |
| Peak footprint | 17,695,056 | 17,711,440 | +0.0926% |
| Compiler bytes | 19,425,808 | 19,442,432 | +0.0856% |

One-shot wall and setup/window times are recorded in the detailed result but
are not latency claims. See
[`compiler_accepted_trait_method_identity_step2e_2026-09-11.md`](../../../benchmarks/results/compiler_accepted_trait_method_identity_step2e_2026-09-11.md)
and its TSV companion.

## Next Packet

Find the smallest boundary where accepted `TraitMethodId` can survive in typed
call metadata without forcing CTFE, Core, and C-emission migration into one
change. If that boundary cannot be made allocation-neutral and phase-precise,
continue normalizing the module-level visibility rows first and return to typed
call targets when their owning table is ready.
