# Preserve Exact Qualified Accepted-UFCS Resolution

**Status:** Complete

**Roadmap:** [Normalized Semantic Compilation Roadmap](NORMALIZED_SEMANTIC_COMPILATION_ROADMAP.md), Step 2e, fourteenth packet

**Depends on:** Exact direct accepted-callable resolution (Issue 84)

## Outcome

Qualified accepted-callable overload lookup now preserves the exact graph
identity attached to every candidate:

```blorp
pure func accepted_callable_lookup_qualified_ufcs(
	authority: AcceptedCallableAuthority,
	module_path: String,
	name: String,
	first_arg_type: SemanticType,
) -> List[AcceptedCallableBinding]
```

The qualified selector returns the same phase-specific binding rather than
discarding it into `OverloadEntry`:

```blorp
pure func accepted_callable_select_ufcs_method(
	matches: List[AcceptedCallableBinding],
	receiver_type: SemanticType,
) -> Option[AcceptedCallableBinding]
```

Inference therefore constructs `ResolvedGraphCallableCall` from
`binding.id`. It no longer loses graph identity during qualified overload
selection and does not reconstruct that identity from `OverloadEntry.def_id`.
The canonical source spelling is projected from the accepted definition row
for the existing typed-call compatibility payload. Although `CallableId` is
the canonical identity, current inference and lowering still inspect that
spelling for a few semantic special cases; retiring those consumers remains
explicit follow-up work.

This packet is deliberately limited to qualified graph calls. Unqualified
UFCS still combines accepted, Env, standalone, and builtin candidates through
the compatibility `OverloadEntry` representation. Separating those origin
domains is the next packet; this change does not hide that work behind a
sentinel ID or a module-path heuristic.

## Context

Issue 84 preserved exact identity for direct bare and qualified calls, but the
qualified overload path remained separate:

```blorp
graph_matches: List[OverloadEntry] =
	accepted_callable_lookup_qualified_ufcs(...)
selected = env_select_ufcs_method(graph_matches, receiver_type)
```

The accepted table had already validated each candidate's `CallableId`,
module owner, source-name identity, visibility, and semantic payload. Returning
only `OverloadEntry` discarded that proof immediately before resolution.
Inference then entered the generic UFCS path, where source origin was inferred
from compatibility module-path strings and graph callable identity was rebuilt
from a raw definition integer.

Qualified lookup has no legitimate Env or standalone candidate: the module
alias has already selected one graph module. It is therefore the smallest
complete boundary at which graph UFCS candidates can become exact without
changing the mixed unqualified compatibility path.

## Invariants

1. Every qualified accepted candidate retains the exact `CallableId` stored in
   its canonical accepted-table slot.
2. Candidate source spelling comes from the callable definition row, not from
   module-path comparison in inference.
3. Only public declarations are visible through a qualified module alias.
4. First-parameter filtering, newest-first candidate order, specificity
   ranking, and tie rejection remain unchanged.
5. Qualified accepted inference constructs the graph call target from
   `binding.id`; it never converts `binding.entry.def_id` into an ID.
6. `OverloadEntry.module_path` is not consulted after the accepted candidate
   has been selected.
7. The source module path and method spelling remain strings only at the
   source-facing qualified lookup boundary.
8. The selected binding's source spelling remains a temporary compatibility
   projection for `ResolvedCallInfo`. `CallableId` is canonical identity, but
   the spelling is still a semantic discriminator for existing float
   elementwise, debug-intrinsic, and lowering special cases until those
   consumers are normalized.
9. Env, standalone, builtin, trait-method, and unqualified UFCS behavior is not
   reclassified by this packet.
10. No parallel lookup index, generic integer dictionary, magic sentinel, or
    fallback reconstruction path is added.

## Implementation Strategy

### 1. Lock the boundary before implementation

The millisecond declaration-boundary test requires qualified accepted lookup
and selection to retain `AcceptedCallableBinding`. It also requires the
accepted inference helper to use `binding.id` and `binding.source_name`, and
rejects `module_path`, raw-ID conversion, or `env_select_ufcs_method` in the
qualified accepted path.

The test failed before the production change because lookup returned
`List[OverloadEntry]` and qualified inference used the generic Env selector.

### 2. Project exact bindings while scanning the canonical range

Qualified lookup still resolves the source module alias and method spelling at
the source-facing boundary. Once it finds the canonical module/name range, it
filters public entries by receiver compatibility and projects each accepted
slot with the Issue 84 binding constructor:

```blorp
match binding_from_slot(table, slot, slot.entry):
	Some(binding):
		result = result.append(binding)
	None:
		void
```

`binding_from_slot` reads the source spelling from the definition table and
retains the slot's exact ID. The table constructor has already validated that
the slot ID, owner, name ID, and semantic payload agree.

### 3. Preserve overload semantics without a compatibility conversion

The accepted selector applies the same score and tie behavior directly to
bindings. A receiver-specific score helper is shared with the Env selector:

```blorp
score = overload_entry_ufcs_selection_score(binding.entry, receiver_type)
```

This helper is equivalent to the former one-element argument-list score, but
does not allocate a temporary `[receiver_type]` list. Both selectors use it, so
accepted and compatibility candidates cannot drift in specificity behavior.

### 4. Enter one shared call-inference body with an exact target

The generic and accepted UFCS entry points now construct their own
`ResolvedCallInfo` and delegate to one shared inference body. The accepted
entry point is exact:

```blorp
resolved_call_info = resolved_call_from_graph_overload_entry(
	method.text,
	binding.source_name,
	binding.id,
	binding.entry,
)
```

Arity checks, generic substitution, callback inference, resource policy,
purity, and result typing remain in the shared implementation.

### 5. Reject attractive but more expensive carriers

The allocation probe exposed costs that broad integration metrics would have
hidden:

- returning a scalar ID and reverse-looking it up for scoring and projection
  added six allocations/releases per qualified call;
- an opaque slot candidate with checked accessors added four per call;
- a fused selected-binding query added three per call after specializing the
  receiver score;
- the retained exact-binding list adds one allocation/release per call and no
  retained object.

Those prototypes are removed. The surviving one-allocation cost is the
short-lived exact binding carrier. Retiring it requires changing the downstream
typed-call source-spelling representation, not adding unchecked accessors or
retaining more strings in accepted slots.

## Fast Feedback Loop

Start with the structural boundary guard:

```bash
python3 -m unittest \
  blorp.test.compiler.stage_06_typecheck.support.test_declaration_boundary.\
DeclarationBoundaryTests.test_qualified_accepted_ufcs_preserves_exact_identity
```

Then run the shared selector and accepted-authority behavior suites:

```bash
bin/blorp test blorp/test/compiler/stage_06_typecheck/type_system/test_env.brp
bin/blorp test blorp/test/compiler/stage_06_typecheck/test_typecheck_decl.brp
```

The declaration fixture verifies that an `Int` receiver selects the exact
`choose` overload ID and canonical source name. A separate pair of
receiver-compatible `ambiguous` overloads verifies newest-first candidate
order and exercises equal-score tie rejection in the accepted selector.

Run the inference and bridge suites only after the narrow tests pass:

```bash
bin/blorp test blorp/test/compiler/stage_06_typecheck/test_infer.brp
bin/blorp test blorp/test/compiler/stage_06_typecheck/test_typecheck_bridge.brp
```

The bridge suite contains the production source case `Dep.select(1)` with
`String` and `Int` overloads. For native instruction evidence, restrict exact
profiling to the changed modules:

```bash
/usr/bin/time -lp bin/blorp test \
  --profile-mode exact \
  --profile-module blorp/src/compiler/stage_06_typecheck/type_system/accepted_callable_authority \
  --profile-module blorp/src/compiler/stage_06_typecheck/infer \
  blorp/test/compiler/stage_06_typecheck/test_typecheck_bridge.brp
```

Use one temporary in-process allocation probe around 64 calls to
`test_typecheck_source_qualified_import_selects_ufcs_receiver`; reset
`MemStats` immediately before the loop. This isolates carrier allocation from
compiler startup and source construction. One baseline/candidate pair is
sufficient.

Finally run `scripts/compiler-check --changed` and one checked-bodies resource
screen. The bodies fixture does not contain qualified UFCS; use it only as a
build-level allocation/size regression guard, never as evidence for the changed
lookup path.

## Acceptance Criteria

- [x] The structural guard fails against the old `List[OverloadEntry]` API.
- [x] Qualified accepted lookup returns exact bindings.
- [x] Qualified accepted selection preserves the chosen binding and tie rules.
- [x] `Int` selects the intended overload ID and canonical source name.
- [x] Qualified inference constructs the graph target from `binding.id`.
- [x] The accepted inference helper does not inspect a module-path string or
  reconstruct an ID from `def_id`.
- [x] Env and accepted UFCS selection share one receiver-specific score.
- [x] The final design adds only one transient allocation/release per qualified
  call (+0.0033% in the focused probe), with zero retained objects or bytes.
- [x] All 30 Env, 142 declaration, 305 inference, and 117 bridge tests pass.
- [x] The changed-owner compiler gate passes: three production sources, six
  focused suites, one declaration-boundary check, and zero failures.
- [x] End-to-end retired instructions and peak footprint remain within 0.10%.
- [x] The checked-bodies build regression screen is allocation-neutral and all
  native/resource metrics remain within 0.40%, excluding noisy wall time.
- [x] Compiler executable size remains effectively neutral.
- [x] Independent review and test-runner verification report no unresolved
  issue.

## Measurements

The focused allocation probe executes the unchanged qualified-overload bridge
fixture 64 times after resetting `MemStats`:

| Metric | Issue 84 baseline | Candidate | Change |
| --- | ---: | ---: | ---: |
| Allocations | 1,940,672 | 1,940,736 | +0.0033% |
| Releases | 1,940,672 | 1,940,736 | +0.0033% |
| Retained objects | 0 | 0 | neutral |
| Retained bytes | 0 | 0 | neutral |

The exact-profile bridge screen ran all 117 tests and observed seven qualified
accepted lookups, seven accepted selections, and six successful exact accepted
call-inference entries:

| Metric | Issue 84 baseline | Candidate | Change |
| --- | ---: | ---: | ---: |
| Retired instructions | 173,625,860,858 | 173,797,104,031 | +0.0986% |
| Cycles | 47,002,836,620 | 46,332,934,846 | -1.4252% |
| Maximum RSS | 763,379,712 | 761,823,232 | -0.2039% |
| Peak footprint | 586,924,824 | 586,908,416 | -0.0028% |

The checked-bodies resource screen reused the final Issue 84 compiler as its
baseline and produced the same semantic and constructor checksums. It does not
execute qualified UFCS and is retained only as a broad regression guard:

| Metric | Issue 84 baseline | Candidate | Change |
| --- | ---: | ---: | ---: |
| Allocations | 17,232 | 17,232 | 0.0000% |
| Releases | 12,924 | 12,924 | 0.0000% |
| Retained objects | 4,308 | 4,308 | 0.0000% |
| Allocated bytes | 350,408 | 350,408 | 0.0000% |
| Retired instructions | 6,274,672,205 | 6,261,557,009 | -0.2090% |
| Cycles | 1,785,861,678 | 1,742,025,887 | -2.4546% |
| Maximum RSS | 24,821,760 | 24,920,064 | +0.3960% |
| Peak footprint | 17,596,728 | 17,629,496 | +0.1862% |
| Compiler bytes | 19,424,368 | 19,424,512 | +0.0007% |

Single-run wall times and setup/window microseconds were noisy and are retained
in the detailed result without a latency claim. Detailed evidence is in
[`compiler_qualified_accepted_ufcs_identity_step2e_2026-09-11.md`](../../../benchmarks/results/compiler_qualified_accepted_ufcs_identity_step2e_2026-09-11.md)
and its TSV companion.

## Next Packet

Separate unqualified accepted UFCS candidates from Env, standalone, and
compiler-builtin candidates. Graph candidates must retain `CallableId` through
retry and origin grouping without comparing `OverloadEntry.module_path`.
Preserve the compatibility domain explicitly until every non-graph origin has
its own legitimate identity representation.
