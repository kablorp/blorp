# Index Graph-Owned Declarations By Module ID

**Status:** Implemented for type headers after measured vertical reactivation

**Dependencies:** Issue 45's standalone `GraphModuleId` candidate was rejected.
This issue was explicitly reactivated as a vertical slice: the replacement
scope slot and its first production declaration consumer were implemented and
measured together, and retained only after the combined slice reduced focused
allocations and whole-compiler retired instructions.

**Blocks:** Issue 47

**Retained scope:** Only the `TypeHeaderGraph` module index and existing
type-header installation consumers were migrated. Global and callable
candidates were measured and rejected. Other categories remain descriptive.

**Parallel work:** None in Stage 06 declaration catalog indexes, category
authorities, or module views.

## Objective

Replace descriptive module string keys and repeated module-owner comparisons
inside one graph-owned declaration product with a compatibility-validated
scope slot. Keep freely comparable nominal and external identities
descriptive. The retained replacement substrate is the prepared-module scope's
private target-first table index plus one narrow compatibility-checked index
accessor; it is not the rejected public `GraphModuleId` design.

Migrate one declaration category at a time. Each category checkpoint must
replace an existing outer module dictionary, owner scan, or storage-key path
and pass a focused performance gate before the next category begins.

## Required Reading

Before editing, read:

1. `AGENTS.md` and `docs/ARCHITECTURE.md`;
2. `GRAPH_MODULE_ID_ROADMAP.md`, Issue 45's rejection evidence, and the final
   implementation/evidence for any accepted replacement substrate;
3. all declaration-authority issues implemented on then-current main;
4. `graph/type_identity.brp`;
5. `headers/declaration_skeleton.brp`;
6. `graph/definition_identity.brp` and `definition_index.brp`;
7. `headers/declaration_catalog.brp`;
8. accepted alias, record, union, global, callable, trait, implementation, and
   UFCS authority modules present on current main;
9. `graph/semantic_occurrence.brp`, `bridge.brp`, and LSP semantic projection;
10. direct/provisional typecheck entrypoints; and
11. declaration-catalog, definition-index, accepted-authority, semantic
    occurrence, and LSP tests.

## Context

The benchmark/test-only `AcceptedDeclarationCatalog` currently demonstrates
category-specific payload lists plus indexes shaped like:

```blorp
type_index_by_module_and_name: Dict[String, Dict[String, Int]]
callable_index_by_module_and_definition_id: Dict[String, Dict[Int, Int]]
trait_method_index_by_module_owner_and_slot: Dict[String, Dict[Int, Dict[Int, Int]]]
```

On revision `0e25482b`, that consolidated catalog is not retained by the
production accepted graph and cannot supply production acceptance evidence.
Production uses category-specific accepted alias, record, union, and global
authorities, plus whatever callable/trait authorities exist on then-current
main. Those production tables and views are the migration target. The catalog
fixture may provide controlled inputs, but changing its private indexes alone
does not satisfy this issue.

Graph-owned category reads and writes still repeatedly derive descriptive
module keys or validate full nominal ownership. The pre-edit inventory must
identify the exact then-current production occurrences rather than assuming
the benchmark catalog has become authoritative.

It is unsafe to solve this by changing a freely comparable identity such as:

```blorp
private record TypeIdRep {
	module_identity: ModuleIdentity,
	name: String,
	span: SourceSpan
}
```

to contain only a graph-local ordinal. Two independently built graphs can both
issue ordinal `7`, and the same module can receive a different ordinal when
graph composition changes. Current `TypeId` equality is valid across graphs;
that behavior must remain.

The safe split is:

```text
durable nominal key at graph/query boundary
                 |
                 v
owning graph validates/resolves module
                 |
                 v
compatible module slot selects one graph-owned category bucket
                 |
                 v
exact local name/definition/span/category validation
```

Graph-owned outer indexes use the module ID. Existing payload records may keep
their durable nominal ID when that is the value returned by the category API;
do not add a second owner field to the same entry merely for lookup. Any
returned `TypeId`, `GlobalId`, `CallableId`, `ExportedSymbolKey`, or semantic
occurrence remains descriptive exactly as before.

## Mandatory Inventory

Before editing, inventory every module dimension in the declaration catalog
and category authorities:

| Category/product | Current outer key | Exact query input | Returned identity | Cross-graph lifetime? | Candidate change |
| --- | --- | --- | --- | --- | --- |

At minimum classify:

- accepted type, constructor, callable, global, trait, trait-method,
  implementation, and implementation-method indexes;
- runtime definition-category validation;
- accepted alias/record/union/global category tables and module views;
- callable/trait/implementation authorities added on current main;
- `DefinitionIndex` module buckets;
- provisional and lexical `Env` indexes;
- `TypeId` and declaration ID equality;
- exported symbol keys and semantic occurrences; and
- direct-program/compiler-surface ownership.

Mark each product as graph-owned, graphless/direct, or escaping. Only
graph-owned storage may use a validated table slot derived by the accepted
replacement substrate. `DefinitionIndex` requires a separate decision: migrate its
accepted-graph module dimension only if it is owned by the same graph and the
direct path remains exact without a permanent hybrid lookup.

### Implemented inventory and decision

| Category/product | Pre-change module dimension | Query/lifetime | Decision |
| --- | --- | --- | --- |
| `TypeHeaderGraph` local/public builtin, record, union, and alias inventories | `Dict[String, ModuleTypeHeaderIndices]` keyed by `module_identity_storage_key` | Graph-owned; installation callers already have `PreparedModuleScope` | Migrated to `Dict[Int, ModuleTypeHeaderIndices]`; scope queries validate graph compatibility and use the table slot |
| accepted alias/record/union graphs | Durable type IDs plus category-specific indexes | Graph-owned construction, but returned identities escape into accepted products | Their existing type-header reads use the new scope query; their own durable indexes remain descriptive |
| temporary global-header completion index | `Dict[String, Dict[String, GlobalHeader]]` | Graph-owned temporary completion pass | Prototype was exact but increased whole-compiler instructions by 0.026%; restored |
| accepted globals and global dependencies | Durable `GlobalId`/module-name indexes | Used after graph preparation and by dependency resolution | Remain descriptive; no retained numeric parallel index |
| callable headers and prepared callable modules | Durable `CallableId`, module buckets, and prepared-module lookup | Mixed graph construction and escaping callable identity | Prototype reduced one focused allocation window by only about 0.03% and increased whole-compiler instructions by 0.096%; restored |
| traits, trait methods, implementations, overloads, and UFCS | Definition/owner/callable identities rather than one removable graph-owned module outer key | Durable ownership and accepted publication | Remain descriptive |
| `DefinitionIndex` and declaration skeleton/catalog indexes | Descriptive source/exported definition keys | Also support direct/provisional paths | Remain descriptive; no permanent hybrid lookup was added |
| lexical/provisional `Env` indexes | Source names and callable IDs | Graphless or session-owned | Out of scope and unchanged |
| `TypeId`, constructor/global/callable/trait/impl IDs | `ModuleIdentity` inside durable nominal identity | Cross-graph comparison and diagnostics | Unchanged |
| exported keys, semantic occurrences, and LSP projection | Durable module/declaration identities | Escape the typecheck graph | Unchanged |
| direct-program and compiler-surface ownership | Descriptive identity without an accepted graph slot | Graphless | Unchanged |

The numeric slot is never a nominal identity. `PreparedModuleScope` stores its
target-first table position privately. `prepared_module_scope_compatible_index`
returns that position only after the existing allocation-or-structural graph
compatibility check and a bounds check. `TypeHeaderTable` retains its owner
scope, so a caller cannot pair an arbitrary owner with the integer dictionary.
The existing `ModuleIdentity` APIs remain as durable wrappers; production
callers that already own a scope use the scope-specific accessors directly.
The structural fallback compares both the complete parsed programs and their
retained module surfaces. Surface comparison uses the existing complete,
deterministic JSON projection on this cold cross-allocation path; the normal
same-allocation graph path short-circuits before structural projection.

## Implementation Plan

### 1. Add graph-owned category lookup boundaries

Queries that use module slots remain in the category authority's owner module.
The indexed product and its owner provenance are inseparable in that module's
private opaque representation, or through an existing graph-bearing field in
the same representation. The caller supplies only the requested
`PreparedModuleScope`, `BoundModule`, or equivalent provenance-bearing
product. Compatibility validation and list access happen in the same module;
do not return the numeric slot to a higher-level module and pass it back into a
private authority. Do not let the caller supply an owner scope beside an
independently selected product, and do not expose the replacement's private
module handle, a generic graph-plus-ID API, or a table-plus-ID API.

Illustrative shape:

```blorp
private record AcceptedRecordGraphRep {
	owner_scope: PreparedModuleScope,
	module_entries: List[Dict[String, AcceptedRecordEntry]]
}

pure func accepted_record_for_scope(
	authority: AcceptedRecordGraph,
	requested_scope: PreparedModuleScope,
	name: String,
) -> Option[AcceptedRecordEntry]:
	representation = accepted_record_graph_rep(authority)
	module_index ?= accepted_record_module_slot(authority, requested_scope)
	module_entries ?= representation.module_entries.get(module_index)
	module_entries.get(name)
```

The exact authority reuses an existing graph-bearing field when one is already
owned in the same private representation; otherwise it retains one owner scope
set by its private constructor. Its allocator/retained-reference cost is
included in the gate. Compatibility validation and indexed access both occur
inside the authority module. If a caller begins with a durable `TypeId`,
resolve/validate its module to a prepared scope once, then ask the authority to
validate/use that scope and validate the remaining name/span fields.

Where the caller already owns a `BoundModule`, `PreparedModuleScope`, or module
view, carry that provenance-bearing product directly. Do not stringify the
validated integer slot as a dictionary key.

### 2. Convert category indexes vertically

Use the declaration-authority order present on then-current main. A likely
sequence is:

1. aliases/types/records/unions/constructors/fields;
2. completed globals;
3. exact and source-name callables;
4. traits and implementations; and
5. UFCS and remaining callable metadata.

For each category:

1. add failing owner/index behavior and counter assertions;
2. change construction to select one module bucket by graph ID;
3. change every graph-owned reader;
4. preserve durable identity at API/output boundaries;
5. delete the category's string outer key and repeated module-owner scan;
6. run its focused matrix and production smoke comparison; and
7. retain the checkpoint only when allocations or retired instructions improve.

Do not build all replacement indexes before cutting over the first reader.
Do not leave a category with parallel descriptive and integer lookup.

### 3. Keep inner storage category-specific

This issue changes the outer module address. Inner declaration dimensions
remain category-specific:

```text
module ID -> Dict[String, Int]              type/global source names
module ID -> Dict[Int, Int]                 runtime definition IDs
module ID -> Dict[Int, Dict[Int, Int]]      owner and method slot
```

The outer representation may initially be a graph-owned ID-addressed product
that preserves category sparsity. Issue 47 owns broad conversion to dense
one-slot-per-module lists. Do not make sparse declaration names or definition
IDs into dense arrays without separate measurements.

### 4. Keep durable nominal equality unchanged

`type_ids_equal`, declaration ID equality, exported symbol equality, and
semantic occurrence identity must preserve current cross-graph behavior.
Graph-local fast paths must have names that communicate their owner, for
example `accepted_catalog_type_entry_for_module`, rather than silently changing
the semantics of an existing equality function.

Add a regression that constructs two graphs with colliding numeric ordinals
but different semantic modules. Durable IDs from those modules must remain
unequal, and passing graph B's requested scope to graph A's product must fail
compatibility validation before numeric lookup. The test must also prove that
there is no API accepting product A plus a caller-selected owner B and request
B pair.

### 5. Treat semantic occurrence as a durable boundary

`TypecheckedGraph` and semantic occurrences currently outlive the internal
`IndexedGraph` representation. Do not retain the graph table or insert a
numeric owner into those products. Resolve any graph-owned entry to its current
durable nominal identity before constructing `TypecheckedGraph`; occurrence
generation then remains unchanged.

Add an occurrence/LSP-heavy measurement to detect costs shifted into this
projection, because the ordinary CLI self-check may not exercise all LSP work.

## Non-Goals

- Do not replace `ModuleIdentity` inside freely comparable `TypeId`,
  declaration IDs, exported keys, or semantic occurrences.
- Do not introduce a universe-qualified identity, process-global interner, or
  path hash.
- Do not retain `IndexedGraph` or its table in `TypecheckedGraph` or LSP state.
- Do not change declaration identity components, allocation order, source
  order, visibility, overload order, or diagnostics.
- Do not migrate graphless/provisional `Env` storage without a separately
  proven graph owner.
- Do not create a generic catalog-entry arena or generic transaction/index
  framework.

## TDD Plan

For every migrated category, write failing tests for:

1. exact local and imported lookup through the production graph owner;
2. same declaration name/definition ID in multiple modules;
3. wrong category, owner, span, or definition ID failing closed;
4. unrelated modules not increasing candidates visited by exact lookup;
5. duplicate declaration/callable IDs preserving current rejection behavior;
6. local/import visibility, privacy, and source/overload ordering;
7. accepted and recoverable graph successful-subset behavior;
8. direct/provisional typecheck behavior remaining descriptive and unchanged;
9. two different graphs issuing the same numeric ordinal without durable
   identity collision, including product-A/request-scope-B rejection;
10. category representations cannot be constructed with caller-selected owner
    provenance and expose no numeric-slot query;
11. `TypecheckedGraph` disposal of internal module tables before semantic
    occurrence/LSP use; and
12. exact diagnostics, help text, spans, definition-ID frontiers, and response
    hashes.

Structural assertions must prove the old path is gone, for example:

```text
catalog_module_storage_keys == 0
catalog_graph_module_bucket_reads == expected_queries
catalog_graph_module_owner_scans == 0
```

Use existing instrumentation naming conventions. Counters are benchmark-only
or exact function instrumentation and must not add normal-build state fields.

## Benchmark Plan

Extend the existing frontend declaration-catalog fixture rather than adding a
parallel framework, but require its measured row to invoke the then-current
production category authority. A row that constructs only the benchmark/test
`AcceptedDeclarationCatalog` is modeled or fixture evidence, not a production
checkpoint. Reuse the corrected import-graph topology and owner/edge checksum
from Issue 45.

For each category and matrix row report:

- exact module/category/declaration dimensions;
- workload validity, exact errors, and semantic checksum;
- durable module comparisons;
- module storage-key constructions;
- durable-owner-to-graph-ID resolutions;
- canonical-path-to-ID boundary index reads;
- origin/descriptor validations and candidates examined at that boundary;
- graph-owned bucket reads and owner scans;
- exact candidates visited;
- descriptor-to-durable projections;
- elapsed time and retired instructions;
- allocations, releases, current objects/bytes; and
- peak RSS for the production self-check.

Required matrix:

```text
modules:                  1, 8, 32, 128
declarations per module:  1, 16, 64
same-name ratio:           0%, 50%, 100%
topology:                  chain, star, diamond/layered, dense
```

Vary module count and declarations independently. Run construction and query
windows separately so reduced query work is not hidden by table setup.

Distinguish four evidence classes in output/documentation:

1. semantic dimensions and checksums;
2. modeled fixture work derived from adjacency/category inputs;
3. exact production function/counter observations; and
4. allocator/time/instruction measurements.

Never label modeled integer operations as exact production counts.

## Fast Feedback

For each category:

1. run its catalog/authority identity suite;
2. run definition-index or callable/trait tests touched by the query;
3. run the cross-graph ordinal-collision regression;
4. run three matrix sentinels: `1x16`, `8x16 chain`, and `8x16 dense`;
5. inspect generated C for integer outer addressing and no stringified ID;
6. search the category for residual `module_identity_storage_key` calls; and
7. run `git diff --check`.

After a complete category passes, run `scripts/compiler-check --changed` and a
single production self-check. Run the full Stage 06 gate, complete matrix, and
three alternating production pairs only after all retained categories are
green.

## Acceptance Criteria

- Every migrated graph-owned category selects its outer module bucket by a
  compatibility-validated slot derived inside that category from the accepted
  replacement substrate.
- No migrated category constructs a descriptive module storage key or scans
  entries to rediscover their graph owner.
- Durable nominal IDs and semantic occurrences preserve exact cross-graph
  equality and lifetime.
- Two graphs with colliding ordinals cannot cross-resolve entries.
- Direct/compiler-surface/provisional behavior remains descriptive and exact.
- No old/new fallback index or public/test-only numeric API remains.
- Exact declaration, visibility, ordering, rejection, diagnostics, and ID
  frontiers are unchanged.
- Generated C shows integer outer addressing without per-query managed key
  construction.
- Every matrix row is valid and checksum-identical.
- Each retained category checkpoint improves focused allocations or retired
  instructions; the final issue improves whole-compiler median retired
  instructions against the accepted replacement substrate's recorded baseline
  without clear elapsed/RSS regression.
- LSP/semantic-occurrence semantic boundary validation shows no shifted
  regression. A dedicated LSP performance measurement is unavailable and must
  not be inferred from the protocol gate.
- Code-reviewer, test-runner, and final code-optimizer reviews approve.

If a category cannot use graph-local addressing without changing the durable
identity contract, leave it descriptive and document the boundary. Do not
weaken cross-graph identity semantics to increase migration coverage.

## Measured Result

The retained candidate was built from `3265c25e`. The production/test patch
used for the final measurements had SHA-256
`18de74988f2953059982d40b5b1ee31440f763c459c33a9e7fb1826ce26c66ae`.
The matched baseline and candidate compiler SHA-256 values were respectively
`caa6bea55658f1bb5ca43080940e7ee4d6a76e529cdef696bb60d0f66dd66f0e`
and `dfb701d3ddf1ad3bb23f1a9dcbd57a7ff38fb2114bf262a3bd53847ab9032f33`.

### Semantic evidence

Focused tests cover target/dependency separation, all four type-header
categories, public/local visibility, source order, structurally equivalent
separately allocated graphs, and rejection of a scope from an incompatible
graph with a colliding numeric position. A separate regression holds resolved
identity, parsed source, and module order constant while changing only the
retained module surface, and proves rejection at both the scope-index and
TypeHeader query boundaries. The final synthetic rows produced
identical semantic counts and checksums for baseline and candidate. All eight
production warmup/measured responses had SHA-256
`c1758b804e292be62860bce968c8cee14b4b6a8fec681ff19c5318e5195c0963`.
The complete LSP protocol fixture gate passed 36/36, including imported
definition/reference cases. No dedicated LSP latency benchmark exists, so this
is semantic boundary evidence rather than an LSP performance claim.

### Modeled workload evidence

The bounded stratified matrix independently varied module count (`1`, `8`,
`32`, `128`), declarations per module (`1`, `16`, `64`), and fixture fan-out
(`0`, `4`, dense) in construction and accepted-preparation windows. It did not
run the original full Cartesian same-name/topology matrix: the production
fixture has unique per-module names and exposes fan-out rather than named
chain/star/diamond shapes. Cross-module same-name and graph-collision behavior
is instead pinned by exact structural tests. This limitation is intentional
and is not presented as exact production work.

### Exact production and measured-cost evidence

Three alternating whole-compiler pairs ran:

```text
baseline:  /private/tmp/blorp-issue46-baseline-3265c25e/bin/blorp check --no-format blorp/src/main.brp
candidate: bin/blorp check --no-format blorp/src/main.brp
```

| Metric | Baseline median (range) | Candidate median (range) | Delta |
| --- | ---: | ---: | ---: |
| retired instructions | 316,652,363,561 (316,541,134,052-316,692,023,963) | 314,751,076,777 (314,722,407,304-314,820,303,087) | -0.600% |
| elapsed seconds | 17.60 (17.55-17.69) | 17.67 (17.60-18.23) | +0.398% |
| CPU cycles | 70,837,993,457 (70,561,340,490-71,131,092,823) | 71,039,516,433 (70,693,796,724-72,308,983,207) | +0.285% |
| maximum RSS bytes | 876,052,480 (875,954,176-876,347,392) | 875,773,952 (875,626,496-876,167,168) | -0.032% |
| peak footprint bytes | 869,860,312 (869,762,008-870,155,224) | 869,581,784 (869,434,328-869,975,000) | -0.032% |

The representative `8 modules x 16 declarations` three-pair header window
reduced median elapsed time from 8,414 to 8,231 microseconds (-2.18%),
allocations from 133,351 to 124,651 (-6.52%), and releases from 130,977 to
122,286 (-6.64%). The corresponding accepted-preparation window reduced
allocations from 1,170,481 to 1,155,741 (-1.26%); its median elapsed time moved
from 97,810 to 98,211 microseconds (+0.41%), within the timing noise observed
for that broader window.

Across the stratified matrix, header allocation reductions ranged from 3.46%
to 7.63%; accepted-preparation reductions ranged from 0.13% to 5.61%. The
largest accepted `128 x 64` dense scout exceeded 100 seconds and approximately
1.7 GB, so it was stopped rather than treated as evidence. The corresponding
header-only row completed and reduced allocations by 3.78%.

Generated C for the final production path represents the scope slot as
`long module_index`, returns it in a stack `Option[Int]`, and performs the
migrated outer lookup with an integer dictionary key. The lookup function has
no `module_identity_storage_key` call or integer-to-string conversion. The
scope itself remains the existing managed record; this issue adds one integer
field rather than a per-query wrapper allocation.

Raw ignored evidence is under:

```text
logs/issue46/final-pairs/
logs/issue46/final-matrix/
logs/issue46/final-matrix-scout/
logs/issue46/final-production-pairs/
logs/issue46/final-production-pairs-v2/
logs/issue46/final-generated-c/
logs/issue46/global-header-signal/
logs/issue46/callable-signal/
```

### Decision

Retain only the TypeHeader vertical slice. It removes one repeated descriptive
module-key construction path, has an exact public-behavior proof, reduces
focused allocation work, and produces a repeatable 0.60% whole-compiler
instruction reduction without a material elapsed or memory regression. Do not
infer a compiler-wide module-ID speedup from this category. The global and
callable prototypes did not pay for their conversion overhead and remain
descriptive. Issue 47 may evaluate dense storage for this retained type-header
product, but must re-audit every other product rather than assuming it has been
migrated.
