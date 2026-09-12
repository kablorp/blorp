# Retain Exact Accepted-Callable Visibility Inputs

**Status:** Complete

**Roadmap:** [Normalized Semantic Compilation Roadmap](NORMALIZED_SEMANTIC_COMPILATION_ROADMAP.md), Step 2e, eleventh packet

**Depends on:** Accepted-callable canonical module ranges (Issue 81)

## Outcome

`AcceptedCallableAuthorityRep` no longer retains two string-keyed candidate
dictionaries:

```blorp
visible_indices_by_source_name: Dict[String, List[Int]]
ufcs_indices_by_source_name: Dict[String, List[Int]]
```

It retains only the exact semantic inputs needed to answer those queries:

```blorp
private record AcceptedCallableNameAccess {
	visible_bindings: List[AcceptedVisibleCallableBinding],
	direct_module_ids: List[ModuleId]
}

private record AcceptedCallableAuthorityRep {
	table: AcceptedCallableTable,
	owner_module_id: Option[ModuleId],
	name_access: Option[AcceptedCallableNameAccess]
}
```

The owner path and directly imported module paths are resolved to `ModuleId`
once at authority construction. Selective imports already carry
`SourceNameId + List[CallableId]`. Local and direct-import candidates remain in
the canonical accepted-callable table and are selected through Issue 81's
binary-searchable module ranges only when queried.

This removes the last retained source-string index in accepted callable
typechecking. Public inference entry points still accept source spellings, but
each spelling is immediately resolved through the compilation-owned
`SourceNameTable`; the authority itself retains no source strings.

## Context

Issue 81 removed the table-level `List[Dict[String, List[Int]]]`, but each
module authority still rebuilt two compatibility dictionaries. For every
visible spelling, those dictionaries retained another list of canonical slot
indices. Local candidates appeared in both dictionaries, direct-import UFCS
candidates appeared in the second, and dictionary keys retained source
spellings even though the compilation graph already owned `SourceNameId`.

The obvious replacements were not acceptable:

1. A generic `Dict[Int, List[Int]]` would retain the same dictionary/node
   structure and duplicated candidate lists under an integer key.
2. A dense `List[List[Int]]` would allocate one slot for every graph source
   name in every module authority, even though each authority sees only a
   sparse subset.
3. Two sparse sorted row lists removed strings but duplicated visible and UFCS
   rows. The prototype raised retained objects about 7.9% and allocated bytes
   about 8.1%.
4. One combined sparse row list still retained a heap record per visible name
   per authority. It raised retained objects about 7.9% and allocated bytes
   about 11.5%.

The canonical table already is the candidate edge store. Retaining exact owner,
selective-binding, and direct-module inputs avoids materializing another
per-authority adjacency relation entirely.

## Invariants

1. Authority ownership is `Option[ModuleId]`, never a retained module path.
2. Selective visibility retains graph-issued `SourceNameId + CallableId` rows;
   it does not reconstruct targets from names.
3. Direct UFCS visibility retains only ordered `ModuleId` values.
4. Local callable lookup includes private owner callables and preserves reverse
   declaration precedence.
5. Selectively imported callable lookup includes public targets only.
6. Selective names may not conflict with an owner-local name or another active
   selective binding.
7. Unqualified UFCS searches owner callables first, then direct modules in the
   reverse installation order formerly produced by `Env`.
8. Direct and qualified UFCS expose public imported callables only.
9. Exact-ID lookup remains available after name access is removed and still
   localizes owner-module types.
10. Missing names, modules, table slots, and invalid IDs fail closed.
11. No string-keyed dictionary, generic integer dictionary, dense source-name
    matrix, or sparse per-name candidate copy is retained.

## Implementation Strategy

### 1. Lock the retained shape with a failing structural test

The millisecond-scale boundary test requires:

```text
AcceptedCallableAuthorityRep.owner_module_id: Option[ModuleId]
AcceptedCallableAuthorityRep.name_access:
    Option[AcceptedCallableNameAccess]
AcceptedCallableNameAccess.visible_bindings:
    List[AcceptedVisibleCallableBinding]
AcceptedCallableNameAccess.direct_module_ids: List[ModuleId]
```

It rejects `owner_module_path`, `Dict[String, List[Int]]`,
`Dict[Int, List[Int]]`, and a retained `AcceptedCallableNameRow` relation. The
test failed against Issue 81 before implementation.

### 2. Resolve module paths once

Keep the existing string-taking construction API as a compatibility boundary,
but resolve its values immediately:

```blorp
owner_module_id = owner_module_path.and_then(
	func(path): module_table_find_id_by_canonical_path(module_table, path),
)

for module_path in direct_module_paths:
	match module_table_find_id_by_canonical_path(module_table, module_path):
		Some(module_id): direct_module_ids = direct_module_ids.append(module_id)
		None: void
```

Later work can move callers to IDs directly. This packet removes retained
paths without expanding into a cross-module API migration.

### 3. Retain and sort only active selective bindings

Filter out bindings with no public accepted target, stable-sort the surviving
rows by numeric `SourceNameId`, and validate adjacent duplicates. A binary
search then finds a selective row in `O(log s)`, where `s` is the number of
active selective callable imports.

Owner conflicts are checked against the canonical table with
`table_name_slot_range`. No transient or retained dictionary is required.

### 4. Reuse canonical ranges for local lookup

Unqualified lookup resolves the spelling once. If the owner module has a
matching range, its final slot is the prior highest-precedence local overload:

```blorp
table_name_slot_range(table, owner_module_id, source_name_id).map(
	func(range): range.start + range.count - 1,
)
```

If no owner row exists, binary-search the sorted selective bindings and project
their exact public `CallableId` targets to canonical slots.

### 5. Probe exact modules for UFCS

UFCS no longer reads a precomputed name dictionary. It binary-searches the
owner module range, then each directly imported module range in the preserved
reverse installation order. Only the equal-name overload group is scanned.

For `d` direct modules, `n` slots per searched module, and `k` matching
overloads, lookup is `O((d + 1) log n + k)`. This is more work per UFCS query
than a materialized dictionary probe, but the accepted-stage workload with 16
direct imports still improves retired instructions 3.23%, showing that avoided
construction and retention dominate the measured pipeline.

### 6. Separate ownership from name-access capability

`accepted_callable_authority_without_visible_names` is used when a module view
must expose canonical exact-ID facts but no unqualified or unqualified-UFCS
name access. Qualified lookup remains available through its explicit module
path. Clearing the owner ID would incorrectly change type localization for
exact lookups.

An optional `AcceptedCallableNameAccess` makes this state explicit:

```blorp
into_opaque AcceptedCallableAuthority({ representation |
	name_access = None
})
```

The owner `ModuleId` remains available to exact-ID consumers. A regression test
proves that hidden unqualified lookup returns `None` while exact owner lookup
remains available and returns an owner-localized entry with no module path.

### 7. Derive profiling counts without retained candidate copies

`accepted_callable_authority_metrics` counts owner ranges, active selective
targets, and public direct-module slots on demand. Profiling does not justify
retaining the removed dictionaries in production state.

## Fast Feedback Loop

Run the structural boundary test first:

```bash
python3 -m unittest \
  blorp.test.compiler.stage_06_typecheck.support.test_declaration_boundary.\
DeclarationBoundaryTests.test_callable_authority_retains_exact_visibility_inputs
```

Then run the declaration behavior suite:

```bash
bin/blorp test \
  blorp/test/compiler/stage_06_typecheck/test_typecheck_decl.brp
```

This suite covers local and imported lookup, overload precedence, qualified and
unqualified UFCS, private rejection, duplicate selective visibility, malformed
canonical grouping, and hidden-name/exact-ID separation.

Once focused behavior is stable, run the changed-owner gate once:

```bash
scripts/compiler-check --changed
```

Finally take one accepted-stage guard sample:

```bash
env BLORP_COMPILER_BENCHMARK_SKIP_BUILD=1 /usr/bin/time -lp \
	benchmarks/compiler_typecheck_phase_profile accepted 1 32 4 16 16 memory
```

The benchmark intentionally includes 16 imported modules per target so the
on-demand UFCS strategy exercises nontrivial fanout. One-shot wall time remains
diagnostic only.

## Acceptance Criteria

- [x] The structural test fails against the Issue 81 authority shape.
- [x] The authority retains owner and direct-import `ModuleId` values, not
  module-path strings.
- [x] Selective lookup retains exact graph bindings and no copied candidate
  index rows.
- [x] The visible and UFCS string dictionaries are removed.
- [x] No generic integer dictionary or dense per-name list is introduced.
- [x] Local, selective, qualified, and UFCS precedence and visibility behavior
  remain unchanged.
- [x] Hidden name access preserves exact-ID owner lookup and localization.
- [x] All 142 declaration tests pass.
- [x] The changed-owner gate passes: one production source, five focused
  suites, one declaration-boundary check, and zero failures.
- [x] Allocations, releases, retained objects, allocated bytes, instructions,
  cycles, RSS, and peak footprint improve.
- [x] Compiler size remains below the 0.1% regression guard.
- [x] Independent review reports no unresolved issue.

## Measurements

Both accepted-stage samples produced identical semantic checksums, output
counts, accepted catalog counts, and benchmark work parameters.

| Metric | Issue 81 baseline | Candidate | Change |
| --- | ---: | ---: | ---: |
| Allocations | 279,265 | 265,849 | -4.8040% |
| Releases | 190,297 | 183,921 | -3.3506% |
| Retained objects | 88,968 | 81,928 | -7.9130% |
| Allocated bytes | 6,485,968 | 6,015,952 | -7.2467% |
| Retired instructions | 8,547,658,201 | 8,271,714,950 | -3.2283% |
| Cycles | 2,343,688,140 | 2,322,681,745 | -0.8963% |
| Maximum RSS | 40,042,496 | 37,666,816 | -5.9329% |
| Peak footprint | 33,505,616 | 31,097,168 | -7.1882% |
| Compiler bytes | 19,406,448 | 19,423,872 | +0.0898% |

Detailed evidence is retained in
[`compiler_accepted_callable_exact_visibility_inputs_step2e_2026-09-11.md`](../../../benchmarks/results/compiler_accepted_callable_exact_visibility_inputs_step2e_2026-09-11.md)
and its TSV companion.

## Next Packet

The implemented follow-up is
[`83-use-prepared-scopes-for-accepted-callable-authorities.md`](83-use-prepared-scopes-for-accepted-callable-authorities.md):
move the remaining string-taking accepted-callable construction parameters to
graph-bound `PreparedModuleScope` inputs, validate their module-table domain,
and retain only the resulting `ModuleId` values. Public inference queries stay
string-taking until their callers naturally own a `SourceNameId`.
