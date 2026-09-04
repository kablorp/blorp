# Remove The Dormant Env UFCS Channel And Defer The Candidate Cutover

**Status:** Cleanup subset implemented; candidate cutover deferred by the fail-fast gate

**Dependencies:** Issue 41 is complete on `main`.

**Parallel work:** None. This is one mechanical Stage 06 cutover over the
accepted-callable authority, UFCS inference, and the remaining dormant `Env`
UFCS storage.

## Why This Issue Was Rescoped

The original issue was written before Issues 40 and 41. Its premise no longer
matches the source:

- Issue 40 already stores accepted source and foreign callables once in
  `AcceptedCallableTable`.
- Issue 40 already gives each module authority ordered source-function UFCS
  indices.
- Issue 40 already stopped publishing accepted graph callables into `Env`.
- Issue 41 already stores accepted traits, implementations, trait methods, and
  implementation methods in `AcceptedTraitImplementationTable`.
- Issue 41 already routes trait-method and implementation-method dispatch
  through that authority, with `Env` fallback limited to compiler builtins and
  explicitly provisional/session-local checking.
- `Env.ufcs_methods` has no production writer. Its writer is used only by unit
  tests and a synthetic declaration-catalog profile fixture that construct a
  state production no longer constructs.

Do not build another declaration table, move trait authority again, or recreate
accepted callable metadata. The remaining production problem is smaller: the
module view stores compact indices, but each query eagerly converts those
indices to a temporary `List[OverloadEntry]`, combines it with an `Env` list,
and partitions the combined list several times.

## Implementation Result

The full candidate-selection cutover was implemented in progressively simpler
forms and rejected. The final tagged-index prototype retired 292,865,779,893
instructions versus 292,269,127,523 for its paired Issue 41 control (+0.20%)
and increased peak memory from 832,046,016 to 843,006,936 bytes. Per the
fail-fast contract, the selector prototypes are not retained.

The independently useful deletion-heavy subset is retained:

- remove `OverloadSet` and `Env.ufcs_methods`;
- remove its test-only writer, module-qualified reader, resolution wrappers,
  and presence probe;
- rename the remaining scope reader to
  `env_lookup_session_ufcs_functions`;
- make qualified accepted UFCS authority-only; and
- rewrite synthetic tests through real session function insertion or a
  production-shaped graph.

The accepted-callable authority and ordinary candidate-list selection remain
as they were in Issue 41. The proposed cutover below is retained as deferred
design context, not as a description of the implemented production shape.

Three alternating, warmed, uncontended Phase 01-06 self-check pairs validated
the retained cleanup subset:

| Metric | Issue 41 control median | Cleanup median | Change |
| --- | ---: | ---: | ---: |
| Retired instructions | 291,826,672,550 | 291,659,008,982 | -0.057% |
| Wall time | 19.20 s | 17.96 s | -6.46% |
| Peak memory footprint | 832,455,616 B | 832,062,400 B | -0.047% |

Retired instructions are the acceptance signal; wall time is reported only as
supporting evidence because it was substantially noisier. At whole-compiler
measurement resolution, the cleanup is performance-neutral with a favorable
median and no latency or memory regression. Its demonstrated value is the
deletion of obsolete production machinery, not the low-single-digit runtime
improvement originally considered plausible for the full cutover.

The retained cleanup is accepted when the standalone field and every helper
that can read or write it are absent, qualified accepted UFCS has no `Env`
fallback, scope-based lexical/provisional/builtin UFCS behavior remains green,
and the focused and manifest-owned compiler gates pass. It deliberately does
not satisfy the deferred candidate-cutover criteria later in this document.

## Objective

Keep UFCS candidates as compact accepted-callable candidate IDs until a
candidate is selected. Read the selected callable from the existing table once,
while keeping lexical functions, provisional current-header functions, and
compiler builtins in their existing session-owned `Env` path. Then delete the
unused standalone `Env.ufcs_methods` channel.

This is a representation and traversal change. It must not change UFCS
visibility, precedence, overload scoring, inference, diagnostics, or the
ownership of any declaration family, except for the explicit correction of
cross-module suppression caused by comparing module-relative `def_id` values
without their module identity.

## Expected Scope

Production files expected to change:

- `blorp/src/compiler/stage_06_typecheck/type_system/accepted_callable_authority.brp`
- `blorp/src/compiler/stage_06_typecheck/type_system/env.brp`
- `blorp/src/compiler/stage_06_typecheck/infer.brp`
- imports in direct consumers of the removed helpers

Tests and documentation expected to change:

- focused accepted-callable authority tests;
- focused UFCS inference and behavior fixtures;
- `Env` tests that currently manufacture standalone UFCS entries;
- the Stage 06 declaration-boundary structural test and profile fixture;
- `docs/ARCHITECTURE.md`; and
- `ENVIRONMENT_REUSE_ROADMAP.md`.

Do not add a cache, invalidation, another graph pass, or another copy of
callable metadata.

## Current Production Shape

The retained authority already owns ordered compact indices:

```blorp
private record AcceptedCallableAuthorityRep {
	table: AcceptedCallableTable,
	owner: ModuleIdentity,
	visible_indices_by_source_name: Dict[String, List[Int]],
	ufcs_indices_by_source_name: Dict[String, List[Int]]
}
```

The query immediately expands those indices into full records:

```blorp
pure func accepted_callable_lookup_ufcs(
	authority: AcceptedCallableAuthority,
	name: String,
	first_arg_type: SemanticType,
) -> List[OverloadEntry]:
	representation = authority_rep(authority)
	var result: List[OverloadEntry] = []

	for index in representation.ufcs_indices_by_source_name.get_or(name, []):
		match entry_at(representation, index):
			Some(entry):
				if overload_entry_first_param_matches(entry, first_arg_type):
					result = result.append(entry)
			None:
				void

	result
```

Inference then allocates and traverses several intermediate lists:

```blorp
matches = env_lookup_ufcs_methods(context.state.env, name, receiver_type)
	.concat(graph_matches)

local_matches = matches.filter(func(entry): ...)
imported_matches = matches.filter(func(entry): ...)
builtin_matches = matches.filter(func(entry): ...)
fallback_matches = matches.filter(func(entry): ...)
```

This also derives ownership and precedence after materialization from
`module_path`, `origin`, and repeated selective-import tests. The module view
already knows those facts when it is built; it should retain the candidate
order explicitly.

## Deferred Candidate-Cutover End State

### Keep compact candidate groups in the authority

The module authority records the three semantic precedence groups directly:

```blorp
private record AcceptedCallableAuthorityRep {
	table: AcceptedCallableTable,
	owner: ModuleIdentity,
	visible_indices_by_source_name: Dict[String, List[Int]],
	ufcs_candidates_by_source_name: Dict[String, List[AcceptedUfcsCandidate]]
}
```

Each compact candidate pairs a table-owned integer index with its owner,
selective, or direct-import-fallback group. These values never cross the
authority module boundary. This is stricter and cheaper than returning a per-query batch
or selected-index handle: callers cannot combine an index with the wrong table
because callers never receive an index.

Selective imports enter the selective group only when the local and original
names are equal. Renamed imports remain bare-call aliases, while the original
name remains available in direct-import fallback. Fallback removes a promoted
candidate by exact table index, never by the module-relative
`OverloadEntry.def_id`.

### Select in place and expose one entry

Use one authority-directed visible selector:

```blorp
pure func accepted_callable_select_visible_ufcs(
	authority: AcceptedCallableAuthority,
	name: String,
	session_entries: List[OverloadEntry],
	receiver_type: SemanticType,
	argument_types: Option[List[SemanticType]],
) -> Option[OverloadEntry]
```

The selector tries the compact precedence groups internally, scores stored
function types, and materializes only the unique winner. For the local bucket,
it considers lexical/session entries and owner indices in the same scoring
loop. For the global receiver-only fallback, it considers all session entries
and all three accepted groups in one loop.

The accepted group tag is private to the authority; session groups are shared
only with inference's authority-absent compatibility path:

```blorp
private enum AcceptedUfcsCandidateGroup:
	NoAcceptedUfcsCandidateGroup
	OwnerUfcsCandidateGroup
	SelectiveUfcsCandidateGroup
	DirectImportUfcsCandidateGroup
	AllAcceptedUfcsCandidateGroups

enum SessionUfcsCandidateGroup:
	NoSessionUfcsCandidateGroup
	LocalSessionUfcsCandidateGroup
	ImportedSessionUfcsCandidateGroup
	BuiltinSessionUfcsCandidateGroup
	AllSessionUfcsCandidateGroup
```

Owner callable types are localized before matching and scoring. The final
accepted slot is re-read and checked against its exact `CallableId` before its
entry is returned. Qualified lookup traverses the existing module/name index in
reverse declaration order, checks public visibility in place, and likewise
returns only its unique winner.

This authority-contained design replaced the earlier proposed opaque batch and
selection handles after the fail-fast implementation showed that their extra
source and runtime plumbing erased the small candidate-list saving. It
preserves the same lineage guarantee with less code: no raw index leaves the
authority at all.

### Preserve retry cohorts without concatenation

Inference carries the selected entry with an explicit retry cohort:

```blorp
private union UfcsRetryCohort:
	LocalAndSessionUfcsRetryCohort
	ImportedModuleUfcsRetryCohort(String)
```

Local/session, owner, and builtin winners retry the local cohort. Imported
winners retry only the exact imported module. Session and accepted retry lists
are traversed separately, so the old concatenated candidate list is gone.
Retry remains a cold error-recovery path and materializes only candidates that
are actually attempted.

### Delete standalone Env UFCS storage

Remove `OverloadSet`, `Env.ufcs_methods`, its writer, module-qualified
reader, resolution wrappers, and presence probe. The remaining reader is named
`env_lookup_session_ufcs_functions` and reads only real functions in
`Env.scopes`: lexical functions, provisional current-header functions, and
compiler builtins.

Qualified accepted UFCS is authority-only. Synthetic tests that installed graph
functions into standalone Env UFCS storage are deleted or rewritten through
real session function insertion. No compatibility fallback remains.

## Deferred Mechanical Implementation Sequence

1. Split `ufcs_indices_by_source_name` into owner, unrenamed-selective, and
   direct-import-fallback maps while the authority is already traversing those
   inputs. Preserve the existing reverse installation order.
2. Exclude selective candidates from fallback with `index` equality. Because
   both values belong to the same table, this is exact callable identity and
   cannot suppress an unrelated declaration with the same numeric definition
   ID in another module.
3. Extract overload matching and scoring helpers in `env.brp` so they accept
   bound type parameters plus an effective function type. Reuse those helpers
   for stored accepted slots without constructing temporary entries.
4. Add the authority-contained visible selector. Traverse session entries and
   tagged accepted indices within each precedence bucket. Track only the
   current best source, exact accepted ID, score, and ambiguity bit;
   materialize the winning accepted entry once.
5. Route visible and qualified UFCS through that selector. Preserve the local,
   selective, fallback, builtin order and the final receiver-only selection
   across all candidates.
6. Keep retry cohorts explicit and traverse session and accepted candidates
   separately. Preserve speculative inference from the original context and
   receiver-only selection of successful retries.
7. Delete standalone `Env` UFCS storage and migrate tests to real session
   functions or production-shaped accepted authority.
8. Run the fail-fast instruction comparison. If direct selection does not beat
   the old temporary lists, retain only independently useful deletion-heavy
   work and do not add caches or a broader abstraction.

## Semantic Invariants

The implementation must preserve:

- field-call priority over UFCS;
- qualified ordinary call handling before unqualified UFCS;
- accepted free-function UFCS before trait-method fallback where currently
  applicable;
- combined lexical/session-plus-owner, selective-import,
  direct-import-fallback, and builtin precedence;
- exact source and reverse installation order within those groups;
- receiver compatibility and overload specificity scoring;
- ambiguity behavior when best scores tie;
- pure/impure callback retry behavior and exact effective-module cohort;
- generic type-parameter and dimension-constraint inference;
- resource-argument and debug-only checks from the selected callable;
- compiler-builtin preference for trait dispatch; and
- exact diagnostics and error ordering.

Do not change public UFCS syntax or introduce new fallback behavior.

## Deferred Candidate-Cutover Performance Contract

This issue is worthwhile only if indexed traversal beats the current temporary
candidate-list path. Retired instructions are primary; wall time is supporting
evidence.

Expected outcome:

- ordinary and qualified selection construct no temporary accepted-entry list;
- cold retry materializes only the exact cohort entries it will actually
  attempt, and never concatenates those entries with session candidates;
- standalone `Env` UFCS storage and its compatibility helpers are absent;
- accepted entries exposed to inference are bounded by selected and actually
  retried candidates, not all visited candidates;
- candidate visits scale with candidates for the queried name, not unrelated
  modules or declarations;
- median Phase 01-06 retired instructions are lower than the Issue 41 parent;
  and
- there is no clear wall-latency or peak-memory regression.

A low-single-digit whole-compiler instruction improvement is plausible. Do not
claim or engineer toward a predetermined percentage.

### Fail-fast checkpoint

After ordinary visible UFCS uses IDs but before deleting compatibility tests,
run one focused UFCS benchmark and one paired Phase 01-06 instruction sample.

- Continue if temporary full-entry lists disappear and retired instructions
  improve beyond run-to-run noise.
- If the result is neutral, inspect the selector for an obvious remaining
  accepted candidate-list construction, fix only that mistake, and sample once
  more.
- If it still does not improve, stop. Keep only independently valuable,
  deletion-heavy changes that lower instructions; do not add a more elaborate
  candidate abstraction, cache, or invalidation scheme to force a win.

## Fast Feedback Loop

During implementation:

1. run the accepted-callable authority suite after changing ID storage;
2. run focused `Env` tests after removing the standalone channel;
3. run focused inference/UFCS tests after each of ordinary, qualified, and retry
   cutovers;
4. run the production-shaped catalog/profile fixture after structural changes;
5. use `scripts/compiler-check --changed` before review; and
6. build once, then collect repeated Phase 01-06 measurements against the Issue
   41 parent.

Do not profile full compilation or later Core/backend stages. Do not run broad
gates while the focused UFCS tests are failing.

## Deferred Candidate-Cutover Acceptance Criteria

- The issue contains no new declaration authority or metadata cache.
- Accepted UFCS indices remain private to their table-owning authority; no
  `List[OverloadEntry]`, batch wrapper, or unbound integer token crosses the
  lookup boundary.
- Module authority records owner, selective-import, and direct-import-fallback
  order explicitly.
- Ordinary, qualified, and retry UFCS paths do not concatenate accepted and
  `Env` entry lists.
- The selected accepted candidate is exposed to inference once; retries expose
  only candidates actually attempted, and final slot reads revalidate exact
  identity against their originating table.
- `Env.ufcs_methods`, `OverloadSet`, its writer, its module-qualified reader,
  and synthetic compatibility tests are deleted.
- Remaining `Env` UFCS lookup is explicitly session-owned: lexical,
  provisional current-header, or compiler-builtin.
- Trait/implementation authority from Issue 41 is reused unchanged.
- Foreign, generic, purity, dimension, debug, resource, and builtin semantics
  are unchanged.
- Candidate and diagnostic ordering tests pass exactly.
- Cross-module candidates with the same numeric `def_id` remain distinct; only
  the same exact callable is removed from fallback after selective promotion.
- Structural checks prove ordinary and qualified selection create no temporary
  accepted-entry lists, accepted and session retry cohorts are not
  concatenated, and standalone `Env` UFCS storage is absent.
- Focused Stage 06 tests and `scripts/compiler-check --changed` pass.
- Median Phase 01-06 retired instructions improve against the Issue 41 parent,
  with no material wall-latency or peak-memory regression.
- `docs/ARCHITECTURE.md` and the environment-reuse roadmap describe the final
  accepted-ID versus lexical-`Env` split.

## Explicit Non-Goals

- No trait or implementation authority redesign.
- No lexical-scope data-structure optimization; Issue 44 remains conditional.
- No change to overload scoring or type inference.
- No generic callable metadata bag.
- No mutable cache or invalidation.
- No new accepted declaration publication into `Env`.
- No broad legacy-environment cleanup beyond the UFCS channel; Issue 43 owns
  the final repository-wide deletion and reprofile.
- No full-compilation performance work beyond Stage 06.

## Recorded Verification

The final metadata ownership is unchanged from Issue 41: the accepted-callable
table owns accepted graph functions and its module views own their ordered
indices; `Env` scopes own only lexical, provisional, and compiler-builtin
functions. The rejected prototypes did not add another authority, cache, or
invalidation path.

The retained patch deletes `Env.ufcs_methods`, `OverloadSet`, the standalone
writer, both standalone resolution wrappers, the module-qualified `Env`
reader, and the presence probe. Tests no longer manufacture the deleted
parallel channel: ordinary session tests publish real `FuncSymbol` values and
qualified behavior is covered with a production-shaped module graph. The
production and benchmark diff is 13 additions and 207 deletions.

Verification completed on the retained cleanup:

- focused `Env`: 30/30 passed;
- focused inference: 304/304 passed;
- focused typecheck bridge: 110/110 passed;
- declaration-boundary guard: 7/7 passed;
- `scripts/compiler-check --changed`: 6/6 suites and 1/1 structural check;
- `scripts/compiler-check --stage typecheck`: 31/31 suites and 2/2 checks,
  including the stage leak check;
- `scripts/test compiler-blorp`: 4,179/4,179 passed; and
- `git diff --check`: passed.

The Phase 01-06 measurements are recorded in the Implementation Result table.
The full candidate cutover failed the continuation rule at +0.20% retired
instructions and was removed. The deletion-only subset is performance-neutral
at whole-compiler resolution, has a favorable -0.057% median instruction
movement, and has no measured latency or peak-memory regression.
