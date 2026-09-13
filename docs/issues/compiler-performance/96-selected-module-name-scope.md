# Selected-Module Name Scope

**Status:** Implemented as the second packet of Step 2e convergence Cut A; the candidate-only width probe followed in [Issue 97](97-bound-visibility-width-probe.md)

**Roadmap:** [Step 2e visibility convergence](94-step2e-visibility-convergence.md)

## Why

The first Cut A packet gave `ModuleView` one graph-issued source-name table
and checked its exact `ModuleTable` allocation. All modules in that graph
share both. A view filled with names from module A could therefore be paired
with module B's typecheck scope without the table check noticing. Registration
could mutate the wrong view, and direct inference reads could resolve A's
names while checking B. This is a provenance error, not a spelling collision.

The selected module is now explicit in the name-scope capability retained by
`ModuleView`. `GraphSourceNameTable` remains shared by the graph; duplicating
its spelling table for every module would lose the memory benefit of the first
packet.

```blorp
private record GraphModuleNameScopeRep {
    graph_names: GraphSourceNameTable,
    module_id: ModuleId
}

private record BoundVisibility {
    issuer: GraphModuleNameScope,
    rows: List[BoundNameRow],
    row_index_by_source_name: Dict[Int, Int]
}
```

`PreparedModuleScope` projects this capability from its graph name table and
selected `ModuleId`. The view's owner check requires both exact table
allocation and equal selected module ID. In particular, two real modules
from the *same* graph are no longer interchangeable.

## Boundaries and implementation

Graph alias, selective-definition, selective-trait-method, and local-name
registration receive the active module ID and reject a mismatched view before
changing a row or ordered inventory. `TypecheckState` threads its selected ID
and rejects mismatched alias/import/local lookups. Bound-module construction
checks the view once before publishing it to header consumers.

Body inference has many direct `ModuleView` reads. At the single
`InferModuleFacts` construction boundary, it admits a view only when the
view matches the active scope; an invalid pair gets an empty view. This
fail-closed admission prevents names *and* accepted authorities from another
module becoming visible during inference without repeating the provenance
test for every name lookup. Normal graph and standalone views are unchanged.

This does not yet prove that a caller could not remint a source-name catalog
under the same table and module ID. The graph-building factory remains a
trusted API; Cut B/C joins must prove the exact issuer of bound and accepted
row references. It also does not replace the ordered `ImportBinding` inventory
or introduce accepted semantic outcomes.

## Fast feedback and acceptance

The shortest behavioral loop is the module-view suite for direct registration
and the declaration suite for real two-module graph binding. A test first
paired A's populated view with B's scope and failed before implementation.
It now verifies that registration makes no partial change, state lookups and
inference admission cannot read A's names, and binder publication rejects the
pair. The structural boundary check guards the capability type.

```bash
bin/blorp test blorp/test/compiler/stage_06_typecheck/test_module_view.brp
bin/blorp test blorp/test/compiler/stage_06_typecheck/test_typecheck_decl.brp
python3 blorp/test/compiler/stage_06_typecheck/support/test_declaration_boundary.py
scripts/compiler-check --changed
```

- [x] Same-graph, different-module registration fails without changing bound rows.
- [x] State and inference name reads fail closed for a mismatched view/scope.
- [x] Binder rejects a wrong-owner view before downstream header consumers see it.
- [x] Exact foreign-table rejection and standalone behavior remain unchanged.
- [x] Changed compiler owner gate passes (5 sources, 12 suites, 1 structural
  check); broad compiler and runtime gates pass (4,513 and 4,474 tests).
- [x] Direct visibility-width fixture isolates rows, collisions, imports,
  queries, diagnostic order, and privacy ([Issue 97](97-bound-visibility-width-probe.md)).
- [ ] An API-adapted pre-Cut-A direct comparison remains before Cut A closes.

## Resource screen

One baseline/candidate pair of the retained accepted-stage profile at
`accepted 1 32 4 16 16 memory` kept checksums, output counts, and constructor
lookup work fixed. This is a broad regression screen, not the pending
visibility-width probe.

| Signal | Before | After | Direction |
| --- | ---: | ---: | --- |
| Total allocations | 265,605 | 265,638 | +0.012% |
| Retained objects | 81,995 | 81,995 | unchanged |
| Allocated bytes | 6,016,344 | 6,016,344 | unchanged |
| Retired instructions | 8,334,269,304 | 8,360,977,247 | +0.320% |
| Peak memory footprint | 31,179,088 | 31,211,856 | +0.105% |
| Compiler executable bytes | 19,532,784 | 19,533,328 | +0.003% |

The new owner guards introduce small measurable work but stay below the 2%
investigation threshold. This packet does not claim a performance improvement.
The candidate's 16.57-second outer wall time had only 0.58 seconds of user
CPU, so that single wall sample is not useful as a latency comparison. The
direct fixture is needed to determine whether the complete Cut A improves
visibility-heavy workloads and memory locality.
