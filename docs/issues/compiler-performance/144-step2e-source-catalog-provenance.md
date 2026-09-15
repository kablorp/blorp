# Step 2e: Exact Source-Catalog Provenance at the Bound Handoff

**Status:** Complete. Implemented as a bounded Cut B prerequisite; the later
candidate/outcome owner and accepted exact-ID joins are complete in
[Step 2e](94-step2e-visibility-convergence.md).

## Why

`ModuleView` already checked that a graph view belonged to the exact
`ModuleTable` allocation and selected `ModuleId`. That did not prove that its
source-name catalog was the one issued by the prepared graph. A caller could
mint a new `GraphSourceNameTable` over the *same* module table with equal
spellings, place it in a `ModuleView`, and pass the old binder guard. A future
`BoundCandidateRowId` interpreted against that view could then refer to the
wrong catalog despite equal-looking integer indexes.

The source-name table already retains its spelling/index allocation. The new
`graph_module_name_scope_matches_catalog` checks that allocation identity,
the exact module-table allocation, and the selected module ID. It deliberately
does not use `source_name_tables_are_compatible`: that function compares
spellings and remains appropriate only where structural compatibility is the
contract. `ModuleView` exposes one checked exact-scope query. The reserved
state's graph lookups, declaration binder, and qualified type-name resolver
now use that query. Header and inference callers pass the reserved scope's
already-retained graph catalog and selected ID to the resolver; a module
table and numeric module ID alone are no longer enough. This avoids minting
a new scope object on each hot lookup. Scalar graph registration still checks its explicit
table/target inputs at its own boundary. No catalog or spelling rows are
copied into the view.

The regression constructs a second catalog from every spelling of the issued
catalog and the **same** module table:

```blorp
reminted_names = graph_source_name_table(module_table, copied_names)
reminted_view = module_view_for_graph(
    graph_module_name_scope(reminted_names, module_id),
)
mixed_state = { state | module_view = reminted_view }
```

The binder must reject that view with its existing selected-module error. The
test failed before the implementation (1/161) and passes afterward (161/161).
The qualified-type regression separately confirms that the original view
resolves `Target.Token`, while a sibling scope, foreign table, or same-table
reminted catalog leaves it unresolved.

## Feedback and acceptance

```bash
bin/blorp test blorp/test/compiler/stage_06_typecheck/test_typecheck_decl.brp
bin/blorp test blorp/test/compiler/stage_06_typecheck/test_module_view.brp
bin/blorp test blorp/test/compiler/stage_06_typecheck/test_typecheck_state.brp
scripts/compiler-check --changed
```

The exact-scope check must reject an equal-layout remint at every ordinary
bound-view reader, preserve the issued scope's normal lookup and binding
behavior, and retain no extra graph/name table. The pointer comparison is an
identity check on the opaque table allocation, not a spelling heuristic. This cut has an immediate binder and
state consumer and removes their former module-only graph-view admission; it
does **not** add a second visibility authority. At this prerequisite checkpoint
the combined Step 2e resource and deletion scorecard remained open, so this
change was not counted as a standalone performance win. The completed
scorecard is recorded in the Step 2e issue.

The 64-module/16-export production import-binding fixture retained its exact
checksum (126,080), 128 bindings, zero errors, 44,410 tracked allocations,
1,416 retained objects, and 97,064 net live bytes at ten iterations after
this cut—the same deterministic counters recorded before it. This is an
allocation/retention guard, not a latency or retired-instruction claim.

This bound-view rule does not silently change the separate accepted-global
completed-table rebase policy, which currently accepts structurally equal
source-name tables. Cut C must decide that policy at its own checked join.
