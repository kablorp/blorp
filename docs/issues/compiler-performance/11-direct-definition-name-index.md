# Add Direct Definition-Name Lookup To DefinitionIndex

**Status:** Ready for design confirmation and implementation

## Issue Summary

Stop scanning every module bucket and sorting matches whenever typechecking asks
for all source definitions with one name. Add a maintained by-name index, or
replace broad name queries with exact key/owner lookups where callers already
know the module and definition kind.

The preferred outcome is less broad querying, not merely another redundant
cache. Start by classifying current consumers.

## Profile Evidence

The compiler self-compilation baseline took 180.545 seconds, performed 704.1
million allocations, and reached 2.218 GB peak RSS. External sampling attributed
2,734 samples, 1.819% and about 3.31 seconds, to
`definition_index_source_definition_bindings` and its direct descendants.

The current function loops over every value of
`source_definition_ids_by_module_bucket_and_name`, retrieves each module's
entries for the requested name, appends every match, and sorts the final list by
definition ID. The cost therefore grows with total module count for every name
query, even when only one module can match.

## Current Call Path

Primary files:

- `compiler/src/stage_06_typecheck/graph/definition_index.brp`
- `compiler/src/stage_06_typecheck/state.brp`
- `compiler/src/stage_06_typecheck/type_occurrence.brp`

`typecheck_state_source_definition_bindings_for_name` forwards to the broad
index query. `type_occurrence.brp` then has two important consumers:

1. `type_definition_id` constructs a complete `SourceDefinitionKey`, scans all
   same-name bindings, and calls `source_definition_keys_equal` to find one
   exact key.
2. `type_definition_id_for_owner` scans all same-name bindings and filters them
   by local module identity or imported canonical path, accepting exactly one
   match.

The first consumer can likely call the existing exact
`definition_index_find_source_definition_id` API directly. The second needs an
owner-aware index or a true global by-name projection.

## Goals

1. Route exact-key consumers through exact-key lookup.
2. Make remaining name queries proportional to the number of matches, not the
   total number of modules.
3. Preserve ambiguity detection and deterministic definition-ID ordering.
4. Keep all indexes consistent behind the opaque `DefinitionIndex` boundary.
5. Demonstrate scaling across modules, names, and query counts.

## Non-Goals

- Do not expose the index representation publicly.
- Do not remove deterministic complete projections used by tooling/validation.
- Do not change definition ID allocation.
- Do not choose an arbitrary match when owner resolution is ambiguous.
- Do not key semantic identity by display string alone.
- Do not add a cache that is updated separately from insertion transactions.

## Proposed Design

### Step A: Remove Avoidable Broad Queries

Change `type_definition_id` to call:

```blorp
typecheck_state_find_source_definition_id(state, key)
```

This exact API already delegates to
`definition_index_find_source_definition_id`. Add a focused regression before
the change and remove the name scan from this path.

### Step B: Index Remaining Name Queries

If broad consumers remain hot, add a representation field similar to:

```blorp
source_definition_ids_by_name:
	Dict[String, List[SourceDefinitionBindingEntry]]
```

Update it in the same private insertion function that updates the module-bucket
index. Preserve entries in definition-ID/insertion order so the query does not
sort on every call. If insertion order is not guaranteed to equal definition-ID
order because reserved IDs can arrive out of order, either insert in sorted
position or store unsorted data plus a finalized immutable projection built
once.

An owner-aware key such as `(ModuleId, name, kind)` is preferable for
`type_definition_id_for_owner` when the caller can provide nominal module
identity. Do not flatten this into a delimiter-joined string.

## Mechanical Implementation Sequence

1. Inventory every broad name-query caller and label it exact-key,
   owner-qualified, or truly global.
2. Add a query-focused mode to the existing definition-index benchmark.
3. Change exact-key callers first and measure call-count reduction.
4. If needed, add the private by-name/owner index field and initialize it in all
   constructors/seeds.
5. Update insertion transactionally; conflict returns must leave all indexes
   unchanged.
6. Add a private validation routine or tests that compare every index
   projection after arbitrary insert sequences.
7. Preserve or precompute deterministic ordering; remove per-query `sort_by`
   only when equivalent.
8. Run definition index, type occurrence/typecheck, malformed-index, leak, and
   stage checks.

## Invariants And Pitfalls

- `DefinitionIndex` is opaque; keep representation details private.
- Exact `SourceDefinitionKey` includes module identity, kind, name, optional
  owner, and span. Do not drop fields to make lookup easier.
- Conflicting duplicate inserts must return the same conflict and not partially
  update secondary indexes.
- Reserved IDs may invalidate assumptions that insertion order equals numeric
  order.
- Global same-name projections must remain sorted by definition ID where that
  is currently observable.
- Owner-qualified lookup must return `None` for zero or multiple matches.
- Module display names and canonical identities are not interchangeable.
- Complete deterministic projections for diagnostics/tooling remain available.

## Fast Feedback Loop

Reuse:

- `compiler/benchmarks/compiler_definition_index_profile.brp`
- `compiler/benchmarks/compiler_definition_index_profile_fixture.brp`

The current source can be run through the generic benchmark runner:

```bash
benchmarks/compiler_blorp_benchmark_runner \
  compiler-definition-index-profile \
  compiler/benchmarks/compiler_definition_index_profile.brp \
  profile \
  25 20 32
```

Extend the benchmark result with a query checksum and controls for query count
and hit/miss distribution. Keep index construction and query timing separate.
Suggested matrix:

```text
modules: 1, 16, 64, 256
definitions/module: 16, 64, 256
queries: 100, 1,000, 10,000
same-name matches: 0, 1, 8, all modules
```

Report broad-query calls, module buckets visited, sort calls, returned matches,
checksum, allocations, and elapsed microseconds.

## Functional Tests

Run:

```bash
./blorp test --timeout 180 compiler/tests/test_compiler_definition_index.brp
./blorp test --timeout 180 compiler/tests/test_compiler_definition_index_identity.brp
./blorp test --timeout 180 compiler/tests/test_compiler_definition_index_reservations.brp
./blorp test --timeout 180 compiler/tests/test_compiler_typecheck_state.brp
./blorp test --timeout 180 compiler/tests/test_compiler_typecheck_decl.brp
scripts/compiler-check --stage typecheck
```

Retain should-fail coverage that opaque/private definition-index
representations cannot be forged.

## Acceptance Criteria

- Exact-key type occurrence lookup no longer materializes all same-name
  bindings.
- Remaining name queries do not visit every module bucket.
- Per-query sorting is removed or proven necessary and isolated.
- Secondary indexes remain transactionally consistent under successful,
  duplicate, conflicting, and reserved-ID insertion.
- Query scaling is proportional to matches rather than total modules.
- Definition IDs, ambiguity outcomes, and deterministic projections are
  unchanged.
- Focused typecheck and representation-boundary tests pass, with no leaks.
