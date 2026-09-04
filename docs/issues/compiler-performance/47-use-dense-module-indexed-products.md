# Complete Dense Module-Indexed Products And Boundaries

**Status:** Ready only for a measured TypeHeader dense-storage investigation

**Dependencies:** Issue 45's broad graph-local ID candidate remains rejected.
Issue 46 retained only a private compatible scope slot and a module-indexed
`TypeHeaderGraph` product after its performance gate. No other declaration
category may be treated as already migrated.

**Parallel work:** None in Stage 06 graph facts, declaration catalog module
views, prepared module products, dependency indexes, or semantic projection
boundaries.

**Reactivation gate:** Begin with the retained TypeHeader product and compare
its sparse integer dictionary with a dense module-indexed list. Broader work
requires a separately measured replacement product; it cannot recreate Issue
45 or treat unimplemented Issue 46 categories as prerequisites already met.

## Objective

After accepted replacement prerequisites exist, replace Stage 06 dictionaries
whose complete key domain is that substrate's dense module range with
immutable indexed lists. Preserve
dictionaries for sparse source names, aliases, local definition IDs, and other
dimensions that are not dense module ownership.

In the same issue, remove transitional bridges, audit every graph-ID escape,
document the durable-identity boundary, and establish the cumulative Phase
01-06 result. Cleanup is coupled to the final measured conversions rather than
left as a performance-neutral fourth production issue.

This issue is about selecting the correct data structure and completing its
lifetime boundary after graph-local IDs exist. It must not become a generic
collection or nominal-identity rewrite.

## Required Reading

Before editing, read:

1. `AGENTS.md` and `docs/ARCHITECTURE.md`;
2. `GRAPH_MODULE_ID_ROADMAP.md` and the final evidence from Issues 45-46;
3. then-current declaration-authority roadmap issues and implementation;
4. `graph/indexed_graph.brp` and `modules/bound_module_graph.brp`;
5. `headers/declaration_catalog.brp`;
6. accepted alias, record, union, global, callable, trait, implementation, and
   UFCS authority modules present on current main;
7. prepared module facts/environment and frontend graph typecheck modules;
8. global/type/callable dependency graph modules; and
9. `bridge.brp`, semantic occurrence, LSP compiler-service/index projection;
10. the compiler import-graph, declaration-catalog, typecheck phase, and LSP
    profile fixtures.

## Context

Before graph-local IDs, module-indexed tables commonly use a stable string
derived from `ModuleIdentity`:

```blorp
module_key = module_identity_storage_key(module_identity)
match entries_by_module.get(module_key):
	Some(entries): ...
	None: ...
```

Once Issue 46 guarantees a dense graph-local range, a complete one-slot-per-
module product can instead be represented conceptually as:

```blorp
private record AcceptedGlobalModuleViewsRep {
	owner_scope: PreparedModuleScope,
	entries: List[AcceptedGlobalModuleView]
}

opaque type AcceptedGlobalModuleViews = AcceptedGlobalModuleViewsRep

private pure func accepted_global_module_views_rep(
	views: AcceptedGlobalModuleViews,
) -> AcceptedGlobalModuleViewsRep:
	from_opaque AcceptedGlobalModuleViews(views)

pure func accepted_global_module_view(
	views: AcceptedGlobalModuleViews,
	requested_scope: PreparedModuleScope,
) -> Option[AcceptedGlobalModuleView]:
	representation = accepted_global_module_views_rep(views)
	index ?= accepted_global_module_view_slot(views, requested_scope)
	representation.entries.get(index)
```

The actual implementation should not introduce a generic wrapper unless it
removes meaningful duplication and generated C remains direct. Category-
specific opaque products preserve the inseparable owner provenance and can
encode stronger invariants, such as every module having exactly one canonical
view.

## Mandatory Storage Audit

Before editing, inventory every Stage 06 dictionary or list addressed by
module identity. Use this table:

| Product | Current shape | Complete key domain? | Empty/default value | Ordered semantics | Candidate storage |
| --- | --- | --- | --- | --- | --- |

Classify each product as one of:

1. **Dense complete:** exactly one logical slot exists for every graph module;
2. **Dense optional:** every graph module has a slot containing `Option[T]` or
   a category-specific empty value;
3. **Sparse by design:** only modules owning a category or successful result
   appear; or
4. **Not module-indexed:** the apparent module component is part of a compound
   source-name, declaration, or external identity key.

Only classes 1 and 2 are automatic list candidates. Class 3 requires measured
memory and latency evidence showing an explicit empty slot is cheaper. Class 4
must remain outside this issue.

At minimum audit:

- prepared and bound modules;
- Stage 06 importable/bound visibility and dependency products;
- declaration catalog module views;
- accepted category authority indexes;
- source definition buckets;
- global/type/callable dependency tables;
- completed/failed module outcome tables;
- recoverable graph module products; and
- CTFE dependency views.

## Implementation Plan

### 1. Keep module count and index validation authoritative

The owning graph/module table supplies the exact module count. Constructors
must produce a list of that exact length or fail before publication.

The implementation follows the category-specific shape above: it asks the
opaque category product to validate provenance and derive a bounds-checked slot
using the accepted replacement substrate. It must not expose the list, the
replacement's private module handle, owner scope, or an unvalidated raw integer
index. Reuse provenance already owned by enclosing graph facts where possible.
Otherwise the opaque product's private constructor stores its owner scope; a
caller never supplies or replaces that owner beside the product. A malformed
internal fixture must not produce out-of-bounds behavior or accidentally
select another module.

### 2. Build once in graph-ID order

Construct each dense product in one pass after its category facts are known.
Do not repeatedly update a persistent list at arbitrary positions if that
copies the complete list per module. Compare:

- append in graph-ID order;
- one final map from already ordered module descriptors; and
- any established mutable-local accumulator that compiles to unique list
  growth.

Inspect generated C and allocator counts. Select the simplest representation
that performs one final product construction without intermediate complete
lists or dictionaries.

### 3. Preserve category-specific emptiness

An empty category view, a failed module, a missing recoverable result, and a
module outside a CTFE visibility closure are not interchangeable. Represent
those states with the existing precise variants or category-specific empty
values rather than using one nullable slot with undocumented meaning.

Examples:

```blorp
union RecoverableModuleSlot:
	RecoveredModule(RecoveredModuleFacts)
	FailedModule(CompilerError)

union CtfeModuleVisibilitySlot:
	CtfeVisible(CtfeModuleView)
	CtfeExcluded
```

These names are illustrative. Reuse existing types when they already encode
the distinction.

### 4. Retain sparse secondary dimensions

Integer module indexing does not make declaration names or local IDs dense.
For example, this is reasonable:

```text
List[Dict[String, List[CallableCandidate]]]
     ^ one slot per module
          ^ sparse source-name lookup within that module
```

Do not flatten every declaration into a graph-wide dense matrix. Preserve
source order, overload order, and category-specialized lookup.

### 5. Delete superseded indexes

For each migrated product, delete:

- string module-key construction at reads and writes;
- the old module-key dictionary;
- conversion helpers used only by that dictionary; and
- compatibility readers that probe both list and dictionary.

Do not keep a dictionary as a debugging mirror or fallback.

### 6. Complete the durable-identity boundary

Audit every remaining Stage 06 `ModuleIdentity`, replacement graph-local handle,
`module_identities_equal`, and `module_identity_storage_key` occurrence.
Descriptive identity remains correct for:

- graph construction from Stage 4 products;
- direct/provisional/compiler-surface ownership;
- duplicate/conflict diagnostics;
- canonical-path or origin decisions where those values are semantic inputs;
- freely comparable nominal IDs;
- `TypecheckedGraph`, exported symbol identity, semantic occurrences, and LSP
  projection; and
- final diagnostic/display formatting.

It is not justified for addressing a graph-owned prepared/bound module,
category view, or converted dense product. Delete duplicate owner fields,
compatibility constructors, integer-to-string module keys, fallback readers,
test-only representation accessors, and temporary benchmark strategies.

`TypecheckedGraph` and semantic occurrences intentionally retain durable
identity after the internal graph table is discarded. Do not retain the table
in those products. Update `docs/ARCHITECTURE.md` and LSP architecture docs to
state that graph-local IDs are internal ordinals, unstable across graph
composition changes, and never persistent workspace identity.

## Non-Goals

- Do not change source-name, alias, overload, local-ID, or span indexes merely
  because they contain a module component.
- Do not make sparse category payloads dense without allocation evidence.
- Do not change accepted/recoverable failure semantics or CTFE visibility.
- Do not reorder declarations, imports, diagnostics, overloads, or definitions.
- Do not introduce mutable graph state, caching, or lazy slot initialization.
- Do not expose raw lists or integer indexes through public compiler APIs.
- Do not replace freely comparable nominal IDs or semantic occurrence owners
  with graph-local ordinals.
- Do not retain the graph/module table in `TypecheckedGraph`, artifacts, or LSP
  state.

## TDD Plan

Write failing structural and behavior tests for:

1. empty graph/direct-program behavior where supported;
2. one module with empty and populated category views;
3. first, middle, and final dense module IDs select exact owners;
4. same source names in every module do not cross slots;
5. user/stdlib/source-package/native-package modules remain distinct;
6. chain, fan-out, layered/diamond, and dense adjacency preserve exact ordered
   edges;
7. module discovery order does not change semantic output;
8. modules with no declarations receive the correct category-specific empty
   view;
9. failed modules and CTFE-excluded modules retain distinct states;
10. recoverable graph lookup excludes exactly the same failed modules;
11. exact declaration and semantic occurrence ownership remains unchanged;
12. malformed dense-product lengths fail construction before publication, and
    every produced scope resolves to a bounded slot;
13. two graphs with colliding internal ordinals retain distinct durable
    nominal and occurrence identities;
14. product A queried with graph B's requested scope fails before indexing,
    with no API that accepts a caller-substituted owner scope; and
15. semantic occurrences remain usable after the internal graph product is
    discarded.

Add structural counters that fail while production still calls
`module_identity_storage_key` for a migrated dense product. Do not assert only
that the new list exists.

## Benchmark Plan

Use the existing production fixtures. For every converted product compare the
old string-key dictionary and final indexed representation on identical graph
facts. Temporary alternate implementations may exist on the measurement
branch but must be removed before review.

Required counters:

- module slots constructed;
- module-index reads;
- string module keys constructed;
- module-key dictionary reads/writes;
- complete product publications;
- symbols/declarations represented;
- workload validity, errors, and semantic checksum;
- allocations, releases, current objects/bytes;
- elapsed time and retired instructions; and
- peak RSS for production self-check.

Emit those fields as separate tagged `semantic`, `modeled_work`,
`exact_production`, and `measured_cost` rows. Exact production counters come
only from actual compiler boundaries; adjacency-derived expectations remain
modeled work.

Add an occurrence/LSP-heavy benchmark or existing replay row to catch costs
shifted into durable projection. The ordinary CLI self-check alone is not
sufficient evidence for this boundary.

Run the full roadmap matrix. Add category sparsity rows of `0%, 10%, 50%,
100%` for any class-3 product considered for dense storage. Reject dense storage
when empty-slot overhead exceeds the measured lookup/allocation benefit.

Analyze results by module count, declaration count, topology, and sparsity. An
aggregate median must not hide a region where a dense representation regresses
the normal small-graph case or makes sparse categories materially larger.

## Fast Feedback

Convert one product at a time:

1. run that product's focused suite;
2. run the retained graph/module table suites owned by the accepted replacement
   substrate and Issue 46;
3. run `1x16`, `8x16 chain`, and `8x16 dense` benchmark rows;
4. inspect generated C for one final list construction and direct indexed
   access;
5. search the converted product for residual storage-key reads/writes; and
6. record the targeted allocation/instruction delta before moving on.

After all retained products are converted and compatibility bridges are
deleted, run formatting, `scripts/compiler-check --changed`, the full Stage 06
owner gate, LSP tests, the complete synthetic matrix, and three alternating
production self-check pairs.

Do not run the broad gate while a representation candidate still has both
dictionary and list readers.

## Acceptance Criteria

- Every converted product has an exact dense-domain proof.
- Its stored list length equals the graph module count.
- Reads are direct graph-owned ID lookups with no string conversion.
- Construction performs one final product publication without an intermediate
  complete dictionary/list per module.
- Sparse source-name/declaration dimensions retain category-appropriate
  dictionaries and ordering.
- Empty, failed, missing, and CTFE-excluded states remain distinct.
- No old dictionary or fallback reader remains for converted products.
- No graph-local ID escapes into freely comparable nominal identity,
  `TypecheckedGraph`, artifact, semantic occurrence, or LSP state.
- Descriptive identity remains only at audited resolution, direct/provisional,
  diagnostic, nominal, and external projection boundaries.
- Generated C confirms direct index access and no per-read managed key
  construction.
- Every synthetic row is valid and checksum-identical.
- Focused allocations and retired instructions improve for each retained
  conversion; sparse-memory regressions are explicitly rejected.
- Whole-compiler median retired instructions improve against Issue 46 with no
  clear elapsed, RSS, or retained-memory regression.
- A cumulative comparison against the pre-Issue-45 control demonstrates that
  the complete roadmap is a net production win.
- Architecture and LSP documentation describe the final ID lifetime and
  durable projection boundary.
- Code-reviewer, test-runner, and final code-optimizer reviews approve.

If the audit finds that most remaining module tables are genuinely sparse,
convert only the proven dense products and document the rejected candidates.
The issue succeeds by removing measured work, not by maximizing list usage.
