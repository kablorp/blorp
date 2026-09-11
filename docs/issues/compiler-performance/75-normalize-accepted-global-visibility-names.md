# Normalize Accepted Global Visibility Names

**Status:** Complete

**Roadmap:** [Normalized Semantic Compilation Roadmap](NORMALIZED_SEMANTIC_COMPILATION_ROADMAP.md), Step 2e, fourth packet

**Depends on:** Selective local-name identities (Issue 74)

## Outcome

Each accepted global authority now retains its unqualified visibility index as
`Dict[Int, AcceptedGlobalLocator]`, keyed by the active compilation's
`SourceNameId`, instead of `Dict[String, AcceptedGlobalLocator]`.

```blorp
private record AcceptedGlobalAuthorityRep {
	table: AcceptedGlobalTable
	source_name_table: SourceNameTable
	owner_module_path: String
	owner_module_id: Option[ModuleId]
	visible_locators_by_source_name_id: Dict[Int, AcceptedGlobalLocator]
	availability: AcceptedGlobalAvailability
}
```

The source-name table remains available as the diagnostic and compatibility
projection. Current inference callers may still ask by spelling, but the
authority converts at its public boundary and keeps only the compilation value
in its retained semantic index.

## Context

Issue 74 normalized selective import registration, but accepted global lookup
later rebuilt a string-keyed per-module authority from local and imported
spellings:

```blorp
visible_locators_by_source_name: Dict[String, AcceptedGlobalLocator]
```

That meant the compiler returned to retained string keys after graph admission.
Moving the import lookup one function earlier would not fix this and would not
remove Issue 74's measured transient allocations: a raw-index lookup prototype
already produced the same allocation count. The useful boundary is therefore
the next retained consumer, not the location of the same projection.

## Invariants

1. The authority receives an opaque `PreparedModuleScope`, derives its exact
   `SourceNameTable`, and verifies definition provenance with its global table.
2. Every local global inserted into the visibility authority must be cataloged.
3. An imported binding that resolves to a global must also have a cataloged
   local spelling.
4. Selective names belonging only to another declaration category remain
   irrelevant to the global authority.
5. Duplicate and private-import validation is unchanged.
6. Exact `GlobalId` lookup and qualified lookup remain definition/module-table
   backed and unchanged.
7. Clearing visible names clears the integer index without discarding the table
   required by later source-oriented queries.

## Implementation Strategy

### 1. Test fail-closed construction

Extend the declaration-skeleton graph test with a foreign prepared scope and
require rejection. An uncataloged imported-global alias must also fail closed,
while an uncataloged selective binding with no global target remains available
to its owning authority. The same test retains by-name and exact-ID assertions.

### 2. Thread graph ownership from the existing scope

`accepted_global_authority_for_module` passes `bound_module_scope(bound_module)`.
The constructor derives the spelling table, owner path, and definition index
from that single graph-owned capability. No new table is constructed.

### 3. Normalize construction and lookup together

During authority construction, resolve each local/imported spelling once and
store its dense table index. `accepted_global_find(authority, name)` performs
the compatibility projection and probes the integer map. Delete the old
string-keyed field in the same change.

### 4. Keep adjacent target normalization separate

`AcceptedVisibleGlobalBinding` still arrives as a source-oriented transient
triple, and qualified lookup still accepts module path plus source name. Moving
those paths to exact `GlobalId` inputs is a separate packet because it changes
authority construction inputs and qualified consumers, not merely this index.

## Fast Feedback Loop

```bash
bin/blorp test \
	blorp/test/compiler/stage_06_typecheck/test_declaration_skeleton_graph.brp
bin/blorp test blorp/test/compiler/stage_06_typecheck/test_typecheck_decl.brp
bin/blorp check --no-format \
	blorp/benchmark/compiler/selective_import_graph_fixture/main.brp
scripts/compiler-check --changed
```

Performance uses one retained, allocation-aware pair after the benchmark is
built, avoiding build time inside the measurement:

```bash
env BLORP_COMPILER_BENCHMARK_SKIP_BUILD=1 /usr/bin/time -lp \
	benchmarks/compiler_typecheck_phase_profile bound 1 32 4 16 16 memory
```

Checksums, allocations, releases, retained objects, allocated bytes, retired
instructions, RSS, peak footprint, and compiler size are acceptance signals.
One-shot wall time is recorded but not used as a claim.

## Acceptance Criteria

- [x] Accepted global unqualified visibility is integer-keyed.
- [x] The replaced retained string-keyed authority index is deleted.
- [x] Construction uses the indexed graph's existing source-name table.
- [x] Missing local-global catalog membership fails closed.
- [x] Source-oriented lookup remains available through one explicit projection.
- [x] Exact, qualified, visibility, availability, and provenance behavior is
  unchanged.
- [x] Focused declaration-skeleton and full declaration suites pass.
- [x] The production selective-import fixture typechecks.
- [x] Managed allocations, releases, retained objects, and allocated bytes are
  exactly neutral in the isolated bound-phase screen.
- [x] Instructions, cycles, RSS, peak footprint, and compiler size stay within
  the 1% investigation threshold.
- [x] Changed-owner checks pass: five production sources, fourteen focused
  suites, one declaration-boundary check, and zero failures.
- [x] Independent review reports no unresolved issue.

## Measurements

Both bound-phase runs report checksum `120388240154574545`, constructor
checksum `4522423758094903886`, 33 primary outputs, and 32 secondary outputs.

| Metric | Issue 74 | Candidate | Change |
| --- | ---: | ---: | ---: |
| allocations | 102,839 | 102,839 | 0.00% |
| releases | 101,691 | 101,691 | 0.00% |
| retained objects | 1,148 | 1,148 | 0.00% |
| allocated bytes | 94,672 | 94,672 | 0.00% |
| instructions retired | 6,638,858,766 | 6,655,756,895 | +0.25% |
| cycles | 1,867,496,451 | 1,868,698,446 | +0.06% |
| maximum RSS | 24,379,392 | 24,444,928 | +0.27% |
| peak footprint | 18,202,960 | 18,252,112 | +0.27% |
| compiler executable bytes | 19,387,424 | 19,387,424 | 0.00% |

The result is structurally useful and resource-neutral. The one-shot measured
window was +3.60% and is not treated as a latency claim. Raw evidence is in
[`compiler_accepted_global_source_names_step2e_2026-09-11.md`](../../../benchmarks/results/compiler_accepted_global_source_names_step2e_2026-09-11.md).

## Next Packet

Completed as
[`76-normalize-accepted-global-selective-targets.md`](76-normalize-accepted-global-selective-targets.md):
accepted global visibility now consumes validated `GlobalId` targets from graph
selective bindings instead of rejoining owner module paths and original names.
