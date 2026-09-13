# Bound Graph-Name Occupancy Rows

**Status:** Implemented as the first packet of Step 2e convergence Cut A; selected-module provenance and a candidate-only width probe followed in [Issues 96-97](97-bound-visibility-width-probe.md)

**Roadmap:** [Step 2e visibility convergence](94-step2e-visibility-convergence.md)

## Why this packet exists

Early typechecking must decide whether one source spelling names a local
declaration, a qualified module alias, a selective import, or the permitted
same-module alias-plus-selective pair. `ModuleView` previously stored those
facts in three graph dictionaries and consulted them in registration-specific
orders. Each dictionary used a `SourceNameId` index, but there was no common
row to inspect or enrich after accepted semantic identities become available.

This packet replaces the three graph dictionaries in place. It does not move
the ordered graph `ImportBinding` inventory or accepted category authorities;
their consumers still run before a candidate/outcome log exists. Standalone
source-mode maps remain a separate compatibility domain.

## Representation and behavior

The graph builder now creates one opaque `GraphSourceNameTable` from its
`ModuleTable` and the names gathered from all prepared modules. It owns the
`SourceNameTable` and exact module-table allocation as one product. Every
prepared scope of that graph projects the same product into `ModuleView`.
Graph registration checks the stored table against its active table; an
equal-layout table from another compilation is not accepted. The product is
graph-wide; [Issue 96](96-selected-module-name-scope.md) wraps it with the
selected module ID before constructing a module view.

```blorp
private union BoundNameOccupancy:
	BoundModuleAlias(ModuleId)
	BoundSelectiveName(ImportedNameBinding)
	BoundAliasAndSelectiveName(ModuleId, ImportedNameBinding)
	BoundLocalName(TopLevelNameKind)

private record BoundNameRow {
	source_name_id: SourceNameId,
	occupancy: BoundNameOccupancy
}

private record BoundVisibility {
	issuer: GraphModuleNameScope,
	rows: List[BoundNameRow],
	row_index_by_source_name: Dict[Int, Int]
}
```

The original packet's issuer was `GraphSourceNameTable`; this historical
sketch includes the selected-module wrapper added by Issue 96. The later
[width investigation](97-bound-visibility-width-probe.md) removed the
duplicated row-list/index storage in favor of one
`Dict[Int, BoundNameOccupancy]` keyed by source-name table index. That change
does not make dictionary iteration order semantic.

The current keyed table maps each cataloged source name to its occupancy.
Registration checks the row, then either updates that row and the ordered inventory together or returns a
conflict without publishing either change. A duplicate alias to the same
module remains idempotent; a duplicate selective import still conflicts. Alias
and selective imports may occupy one spelling only when their canonical
module targets agree. Clearing unqualified names keeps an alias row, collapses
an overlap row to alias-only, and retains only those keyed rows.

The compact occupancy row intentionally has no `ImportBindingRowId` yet.
`import_bindings` still owns order and exact selective `DefinitionId` payloads.
Cut B will replace that inventory with an ordered candidate log and checked
row references; adding references now would duplicate its authority. The
source-facing `ImportedNameBinding` survives for early diagnostics and header
consumers, not as an accepted semantic identity.

## Implementation and fast feedback

The narrow loop is the module-view suite (about seven seconds locally), then
the declaration binder suite (about thirteen seconds). The latter exercises
actual graph binding and checks the production combined-import order. The
structural declaration-boundary check takes milliseconds and rejects the three
old map fields. Run the owner gate once stable:

```bash
bin/blorp test blorp/test/compiler/stage_06_typecheck/test_module_view.brp
bin/blorp test blorp/test/compiler/stage_06_typecheck/test_typecheck_decl.brp
python3 blorp/test/compiler/stage_06_typecheck/support/test_declaration_boundary.py
scripts/compiler-check --changed
```

The module-view test covers both successful low-level registration orders,
exact `GraphQualifiedModuleBinding`/`GraphSelectiveDefinitionBinding` order,
same-target overlap in one row, duplicate and different-target conflicts,
unchanged inventory after rejection, graph clearing, and equal-layout foreign
table rejection. Declaration tests cover the genuine binder and uncataloged
graph names. A synthetic two-module graph issuer is used only for low-level
collision cases; production graph construction is exercised separately.

## Resource screen

One accepted-stage baseline/candidate counter pair used
`benchmarks/compiler_typecheck_phase_profile accepted 1 32 4 16 16 memory`.
The baseline was the same dirty worktree before this packet (including the
uncommitted Issue 93 changes), and the candidate was rebuilt after this
packet. Checksums, output counts, constructor rows, and lookup-work counters
are identical. No clean-parent or elapsed-latency claim is made.

| Signal | Before | After | Direction |
| --- | ---: | ---: | --- |
| Total allocations | 265,539 | 265,605 | +0.025% |
| Retained objects | 81,995 | 81,995 | unchanged |
| Allocated bytes | 6,017,136 | 6,016,344 | -0.013% |
| Retired instructions | 8,282,777,352 | 8,331,453,461 | +0.588% |
| Peak memory footprint | 30,998,840 | 31,048,016 | +0.159% |
| Compiler executable bytes | 19,530,640 | 19,532,784 | +0.011% |

The row/index replacement stays below the 2% investigation threshold in
these signals, but it is not a demonstrated overall performance improvement:
retired work rises and this harness includes other accepted-stage work. Cut A
still needs a retained visibility-width fixture that isolates rows, imports,
collisions, and queries before making a stronger memory or cache-locality
claim. A single wall-time pair is deliberately not treated as evidence.

## Acceptance and next boundary

- [x] Three graph occupancy dictionaries deleted, not retained in parallel.
- [x] One indexed row represents alias, selective, overlap, or local occupancy.
- [x] Production binding and direct reverse-order registration preserve
  successful binding order and conflict/idempotence semantics.
- [x] Equal-layout foreign module tables are rejected; graph and standalone
  registration domains remain separate.
- [x] Module-view 17/17, declaration 151/151, structural 50/50, and changed
  compiler owner gate (5 sources, 12 suites, 1 check) pass.
- [x] A single counter pair shows no material resource regression.
- [x] Bind the selected module ID to `ModuleView` and validate graph
  registration, state queries, inference admission, and bound-module
  construction against the active module scope ([Issue 96](96-selected-module-name-scope.md)).
- [x] Add the visibility-width resource fixture and diagnostic-order/privacy
  assertions named in Cut A's exit gate ([Issue 97](97-bound-visibility-width-probe.md)).
- [ ] Complete an API-adapted direct baseline comparison before closing Cut A.

The public `graph_source_name_table(module_table, candidates)` factory can
mint a new catalog under an existing table. This is a trusted graph-building
API today, not proof of a unique selected-module catalog. Cut B/C joins must
validate that they use the graph's actual issuer rather than reminting it.

During test development, a tuple match on two `Option[ImportBinding]` values
reproducibly crashed the generated declaration-suite executable (exit 139).
Two separate matches passed and preserve the intended assertion. This is a
separate compiler-codegen investigation, not a visibility semantic change.
