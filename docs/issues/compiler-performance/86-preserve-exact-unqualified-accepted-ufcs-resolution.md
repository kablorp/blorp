# Preserve Exact Unqualified Accepted-UFCS Resolution

**Status:** Complete

**Roadmap:** [Normalized Semantic Compilation Roadmap](NORMALIZED_SEMANTIC_COMPILATION_ROADMAP.md), Step 2e, fifteenth packet

**Depends on:** Exact qualified accepted-UFCS resolution (Issue 85)

## Outcome

Unqualified accepted-callable UFCS lookup now retains the graph binding that
owns each semantic candidate:

```blorp
pure func accepted_callable_lookup_ufcs(
	authority: AcceptedCallableAuthority,
	name: String,
	first_arg_type: SemanticType,
) -> List[AcceptedCallableBinding]
```

Inference no longer concatenates those graph bindings into the compatibility
`List[OverloadEntry]`. A phase-local sum type keeps the domains explicit:

```blorp
private union VisibleUfcsMethod:
	AcceptedVisibleUfcsMethod(AcceptedCallableBinding)
	CompatibilityVisibleUfcsMethod(OverloadEntry)
```

Accepted selection and purity-flexible retry therefore construct
`ResolvedGraphCallableCall` from the original `CallableId`. They do not rebuild
an ID from `OverloadEntry.def_id`, infer graph ownership from a module-path
string, or pass an accepted candidate back through the Env inference path.

## Context

Issue 85 made the qualified graph path exact, but the unqualified path still
discarded accepted identity twice:

```blorp
graph_matches: List[OverloadEntry] = accepted_callable_lookup_ufcs(...)
matches = env_matches.concat(graph_matches)
```

The combined list was divided into local, selective-import, direct-import
fallback, and builtin groups by inspecting `OverloadEntry.module_path` and
`FuncOrigin`. Once selected, the generic inference helper reconstructed graph
identity from the raw definition integer. If an unannotated callback required
retrying overloads under multiple expected purity signatures, the retry path
again combined accepted and Env entries, then used module-path equality as its
origin key.

Those strings were carrying two different responsibilities: legitimate source
adapter identity for standalone/Env candidates, and accidental graph identity
for already accepted candidates. The graph already has exact module,
definition, and source-name IDs, so preserving that distinction is a necessary
precondition for retiring strings later in the pipeline.

## Invariants

1. Every accepted UFCS candidate retains the exact `CallableId` stored in its
   canonical accepted-table slot.
2. Accepted origin is one explicit value: owner-local, selectively imported,
   or direct-import fallback.
3. Accepted origin classification uses the slot's `SourceNameId`, exact
   selective `CallableId` targets, and `ModuleId`; it does not inspect
   `OverloadEntry.module_path`.
4. Owner callables include private declarations; imported callables remain
   public-only.
5. Visibility precedence remains owner, selective import, direct fallback,
   builtin, then the existing receiver-only ambiguity fallback.
6. Full known argument types still rank concrete overloads and validate arity;
   unavailable argument types retain receiver-only selection.
7. Equal best scores still reject as ambiguous across both candidate domains.
8. Purity-flexible accepted retry remains inside the selected exact graph
   module and preserves the chosen binding.
9. Standalone, lexical, trait, and compiler-builtin candidates stay in the
   explicitly named compatibility variant; their legitimate string-backed
   adapters are not reclassified as graph identities.
10. `binding.source_name` remains temporary semantic compatibility context for
    current typed-call consumers. `CallableId`, not that spelling, is canonical
    callable identity.
11. No generic integer dictionary, parallel candidate index, magic sentinel,
    raw-ID reconstruction, or naming heuristic is introduced.

## Implementation Strategy

### 1. Lock the boundary first

The declaration-boundary test requires unqualified accepted lookup to return
`List[AcceptedCallableBinding]`, an exact accepted-origin query, a sum type at
the mixed inference boundary, and an accepted retry arm that uses exact owner
comparison. It rejects `List[OverloadEntry]`, graph module-path comparison, and
reserved/raw definition-ID reconstruction. The test failed against Issue 85
before production code changed.

### 2. Project exact bindings from canonical ranges

The existing owner/direct-module range scan remains the single source of
candidates. The only representation change is at projection:

```blorp
match binding_from_slot(table, slot, entry):
	Some(binding):
		matches = matches.append(binding)
	None:
		void
```

`entry_at` still localizes owner-module types before the binding is built.
Imported entries remain canonical and public-only. Candidate order is unchanged:
reverse declaration order within a name, owner first, then direct modules in
reverse installation order.

### 3. Derive visibility origin from accepted relations

`accepted_callable_ufcs_origin` first validates the binding against the
authority's canonical table. It then compares exact module IDs:

- the authority owner ID yields owner-local origin;
- an exact candidate ID named by the selective binding row yields selective
  origin, while an unselected same-name overload remains direct fallback;
- any other admitted direct module yields direct fallback origin.

The selective check starts from `slot.source_name_id` and follows the already
validated selective target `CallableId` values. No source spelling or module
path is consulted.

### 4. Keep the mixed boundary explicit

`VisibleUfcsMethod` is private to inference. Selection scans accepted bindings
and compatibility entries without converting either one. Shared public
`OverloadEntry` matching and score helpers keep full-argument and receiver-only
ranking behavior identical across both variants.

The selector returns the winning variant, allowing the caller to dispatch to
the exact accepted inference helper or the existing compatibility helper. The
builtin-to-trait fallback applies only to the compatibility variant.

### 5. Preserve exact identity through retry

When callback inference invalidates the initial accepted overload, retry looks
up accepted bindings again and retains only bindings whose validated
`CallableId` values share the selected binding's module owner. Successful
candidates are selected as bindings and re-enter exact accepted inference.

Compatibility retry continues to use Env and its string-backed module adapter.
It no longer receives graph candidates. This is intentional domain separation,
not a compatibility shim.

### 6. Short-circuit visibility precedence

The first exact implementation eagerly scanned all four visibility tiers and
added 51 transient allocations per exercised fixture. Lower tiers cannot affect
an already selected higher tier, so resolution now evaluates the next tier only
when the current one has no unique result. The combined receiver-and-argument
type list is also built once per resolution instead of once per tier. The
focused delta falls to 10 allocations per fixture, with no retained objects or
bytes. This also makes the precedence order executable control flow rather than
four eagerly materialized candidate lists.

## Fast Feedback Loop

Start with the millisecond structural guard:

```bash
python3 -m unittest \
  blorp.test.compiler.stage_06_typecheck.support.test_declaration_boundary.\
DeclarationBoundaryTests.test_unqualified_accepted_ufcs_preserves_exact_identity
```

Then run the smallest semantic owner:

```bash
bin/blorp test blorp/test/compiler/stage_06_typecheck/test_typecheck_decl.brp
```

Its accepted-authority fixture verifies exact IDs for owner, selective, and
direct origins, including a selective row that admits one overload without
upgrading a same-name sibling. Next run inference and bridge behavior:

```bash
bin/blorp test blorp/test/compiler/stage_06_typecheck/test_infer.brp
bin/blorp test blorp/test/compiler/stage_06_typecheck/test_typecheck_bridge.brp
```

The bridge suite covers local/direct precedence, imported-over-builtin
precedence, and the purity-flexible imported overload retry.

For allocation feedback, use one temporary in-process probe that resets
`MemStats` and calls
`test_typecheck_source_selects_pure_imported_ufcs_overload` 64 times. Retain
only the result, not the scratch source. One baseline/candidate pair is enough.

For native work, profile only the changed authority and inference modules:

```bash
/usr/bin/time -lp bin/blorp test \
  --profile-mode exact \
  --profile-module blorp/src/compiler/stage_06_typecheck/type_system/accepted_callable_authority \
  --profile-module blorp/src/compiler/stage_06_typecheck/infer \
  blorp/test/compiler/stage_06_typecheck/test_typecheck_bridge.brp
```

Finally run `scripts/compiler-check --changed` and one checked-bodies resource
screen. The bodies fixture does not execute unqualified UFCS; it is only a
build-level regression guard.

## Acceptance Criteria

- [x] The structural guard fails against Issue 85's compatibility lookup.
- [x] Unqualified accepted lookup returns exact bindings.
- [x] Owner, selective, and direct accepted origins are derived from graph IDs.
- [x] Mixed selection preserves accepted versus compatibility domains.
- [x] Full-argument ranking, receiver ranking, ties, and precedence remain
  behavior-compatible.
- [x] Accepted initial inference and retry use `binding.id` and exact module
  ownership, without graph module-path comparison.
- [x] The focused retry probe has zero retained objects and bytes; transient
  allocation/release growth is +0.0235%.
- [x] All 30 Env, 142 declaration, 305 inference, and 117 bridge tests pass.
- [x] The changed-owner compiler gate passes.
- [x] Changed-path instructions improve 0.005%, cycles remain within 0.54%,
  peak footprint improves 0.12%, and RSS improves 3.80%.
- [x] The build-level screen is allocation-neutral and stays within 0.85% for
  native and memory metrics.
- [x] Compiler executable size remains effectively neutral at +0.0067%.
- [x] Independent review and test-runner verification report no unresolved
  issue.

## Measurements

The 64-iteration purity-flexible retry probe remained semantically valid:

| Metric | Issue 85 baseline | Candidate | Change |
| --- | ---: | ---: | ---: |
| Allocations | 2,721,280 | 2,721,920 | +0.0235% |
| Releases | 2,721,280 | 2,721,920 | +0.0235% |
| Retained objects | 0 | 0 | neutral |
| Retained bytes | 0 | 0 | neutral |

The exact-profile bridge screen passed all 117 tests:

| Metric | Issue 85 baseline | Candidate | Change |
| --- | ---: | ---: | ---: |
| Retired instructions | 174,070,899,229 | 174,062,255,128 | -0.0050% |
| Cycles | 45,115,285,495 | 45,358,483,974 | +0.5391% |
| Maximum RSS | 796,049,408 | 765,788,160 | -3.8014% |
| Peak footprint | 589,398,808 | 588,694,296 | -0.1195% |

The checked-bodies build guard produced identical semantic checksums and work
counts:

| Metric | Issue 85 baseline | Candidate | Change |
| --- | ---: | ---: | ---: |
| Allocations | 17,232 | 17,232 | neutral |
| Releases | 12,924 | 12,924 | neutral |
| Retained objects | 4,308 | 4,308 | neutral |
| Allocated bytes | 350,408 | 350,408 | neutral |
| Retired instructions | 6,275,205,190 | 6,275,862,592 | +0.0105% |
| Cycles | 1,720,979,924 | 1,735,485,407 | +0.8429% |
| Maximum RSS | 24,936,448 | 25,001,984 | +0.2628% |
| Peak footprint | 17,645,880 | 17,695,056 | +0.2787% |
| Compiler bytes | 19,424,512 | 19,425,808 | +0.0067% |

One-shot wall and setup/window times are recorded in the detailed result but
are not latency claims. See
[`compiler_unqualified_accepted_ufcs_identity_step2e_2026-09-11.md`](../../../benchmarks/results/compiler_unqualified_accepted_ufcs_identity_step2e_2026-09-11.md)
and its TSV companion.

## Next Packet

Normalize the remaining trait-method callable target identity and decide the
smallest boundary at which `TraitMethodId` can replace method source spelling
without pulling CTFE or Core string retirement into the same change.
