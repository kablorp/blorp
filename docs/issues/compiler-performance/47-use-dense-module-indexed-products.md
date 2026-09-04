# Complete Dense Module-Indexed Products And Boundaries

**Status:** Implemented and measured for the TypeHeader product only

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

**Final scope:** The retained implementation converts only
`TypeHeaderTable.header_indices_by_module`. The audit did not justify another
product, so the broader conditional work below remains guidance for a future
independently measured slice rather than work completed by this issue.

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

## Implemented TypeHeader Result

### Storage audit and boundary

Issue 46's final inventory was rechecked against current main. The only
already graph-addressed product with a complete bounded module domain is the
TypeHeader per-module inventory:

| Product | Current logical shape | Domain classification | Decision |
| --- | --- | --- | --- |
| `TypeHeaderTable.header_indices_by_module` | one local/public header-index pair for target slot 0 and every dependency slot | dense optional; an empty module owns an explicit empty pair | converted from `Dict[Int, ModuleTypeHeaderIndices]` to an exact-length list |
| accepted alias/record/union authorities | durable type identities and category indexes | escaping nominal identity | retained |
| completed globals and global dependencies | durable `GlobalId` and module/name indexes | sparse and escaping | retained |
| callable headers/prepared callables | durable callable identity and sparse module/name buckets | mixed graph construction and escaping identity | retained |
| traits, implementations, overloads, and UFCS | owner/callable/definition identities | sparse by declaration and escaping | retained |
| definition/declaration indexes | source/exported definition keys and direct-program support | not solely graph-module indexed | retained |
| prepared environments and lexical `Env` | source names, callable IDs, and scopes | session-owned, not graph-module indexed | retained |
| recoverable/failed/CTFE products | category-specific result and visibility states | sparse by design; no accepted dense replacement product | retained |
| typed graph, semantic occurrences, and LSP indexes | durable module and declaration identities | external projection boundary | retained |

The owning indexed graph defines the range: target is slot `0`, dependencies
occupy `1..N`, and the list length is therefore `N + 1`. Construction creates
that exact list before visiting headers. Every query still passes a
`PreparedModuleScope`; `prepared_module_scope_compatible_index` validates graph
provenance and bounds before the private list is read. No raw slot or list is
exposed, and durable IDs/equality are unchanged.

The old integer dictionary and its fallback are gone. Source-name lookup stays
a dictionary because names are sparse. No representation accessor or raw slot
escapes the TypeHeader module; the benchmark reports the closed-form graph
dimension as `expected_module_slots` rather than presenting it as an observed
storage counter.

### Semantic evidence

The focused regression builds target, empty, middle, and final modules. It
asserts their exact public projections, public/private ordering in the middle
module, the empty module's category-specific empty projections, and exact
first/final selection. Generated C and the authoritative `N + 1` constructor
provide the representation-length evidence without a test-only public accessor.
Existing incompatible-scope and cross-graph tests continue to prove that
colliding numeric positions cannot cross graph ownership.

All 66 baseline/candidate matrix pairs completed successfully. Every pair had
identical stage, iteration, graph dimensions, primary/secondary output counts,
and checksum. The matrix independently varied modules (`1`, `8`, `32`, `128`),
and shapes per type-bearing module (`1`, `16`, `64`). Full-density rows varied
dependency fan-out (`1`, `4`, dense). Separate sparse rows varied
type-bearing-module density (`0%`, `10%`, `50%`) while holding
dependency-to-dependency fan-out at zero; they keep all modules selected and
change which dependency modules own type declarations. The measured runner's
raw `import_fanout=1` field on those sparse rows was the ignored requested
value, not executed topology. The final runner now reports
`requested_import_fanout` and `effective_import_fanout` separately.

The shared production capture has SHA-256
`d6a1d60e480c1e020d339e64067173a199ad4d75530363f6c0fa6ce4147b8635`
and is 11,329,287 bytes. All measured baseline/candidate target-only replays
produced the same 1,755,080-byte response with SHA-256
`2a57db4ae6c864f407da5ef9f2a6dd277a38b8b844588fc88b34090db93c3c49`.
The replay includes compiler semantic-occurrence projection, so this checks the
durable identity boundary used by the LSP; it is not a dedicated LSP latency
claim.

### Modeled work

For `M` dependency modules and `H` accepted headers, the candidate constructs
exactly `M + 1` module slots, performs `H` inventory updates in source order,
and publishes one final TypeHeader table. The baseline performs the same `H`
logical updates through an integer dictionary. These are closed-form workload
facts, not substituted production function counts. String module-key work is
zero in both variants because Issue 46 had already replaced the descriptive
key with a validated integer slot.

### Exact production function counts

A `--profile` build of the real phase runner at `8 modules x 16 shapes` reports
290 accepted headers in both variants:

| Boundary | Baseline calls | Candidate calls |
| --- | ---: | ---: |
| `type_header_table` | 1 | 1 |
| `module_type_header_indices_add` | 290 | 290 |
| integer-dictionary `get_or` for `ModuleTypeHeaderIndices` | 290 | absent |
| integer-dictionary `set` for `ModuleTypeHeaderIndices` | 290 | absent |
| list `repeat` for `ModuleTypeHeaderIndices` | absent | 1 |
| list `set` for `ModuleTypeHeaderIndices` | absent | 290 |

The accepted-preparation window reports 360 calls to
`type_header_table_module_indices_for_scope` in each variant and identical
allocator counts/checksum. The profiler's 1,024-function registry did not
expose the monomorphized low-level list read in that larger window, so the
generated-C inspection, not a modeled count, proves that read is a direct
`blorp_list_get` after compatibility validation.

### Measured cost

The compared source trees were both based on `75ff022e`, used the same fixture,
runner, tests, counter schema, and bootstrap compiler, and differed only in the
TypeHeader representation and its structural test. Source patch hashes were
`85ac30f2bad149745278473c8861f9ce0d7501f11d32cb29b73db5ef71a120f2`
for baseline and
`3d59001b67ec32840969c6d5860c5a3da127fa92f175d69e884bf83b3e58d543`
for candidate. Standalone runner hashes were
`2377a11c852b22ae9bc4dcb39365126767ca445cf4baa62719e975bbbb1c1ae5`
and
`407ac4e331b5388a9b0c35d2e809007bf163595c8df43466212eb59d52fec908`.

Across all 66 rows, the candidate reduced allocations in every row. Weighted
results were:

| Type-bearing density | Rows | Allocations | Releases | Header-window elapsed | Retired instructions |
| --- | ---: | ---: | ---: | ---: | ---: |
| 0% | 12 | -1.736% | -1.812% | -7.257% | +0.095% |
| 10% | 12 | -0.909% | -0.923% | -10.423% | -0.221% |
| 50% | 12 | -0.834% | -0.845% | -1.729% | -0.265% |
| 100% | 30 | -0.623% | -0.629% | -2.412% | -0.053% |

Elapsed time is supporting evidence from one paired five-iteration sample per
row. Retired instructions and exact allocator counts are the primary matrix
signals. On fully populated graphs, instruction totals improved for single,
chain, fan-out-4, and dense topology groups. The smallest one-shape group was
effectively flat; 16- and 64-shape groups reduced allocations by 0.662% and
0.674% respectively.

The explicit empty-category cost is bounded and visible. At 128 dependency
modules with 0% type-bearing dependencies, the final retained candidate product
uses 952 more bytes (one reference slot per module after the dictionary/list
base-size difference) while removing ten transient allocations over five
rebuilds. At 10% density the weighted retained-byte delta is +0.152%, and at
50%/100% it is +0.034%/+0.018%. This is accepted for this dense-optional product;
it is not evidence for converting any genuinely sparse category.

The allocator-instrumented compiler replay workers have hashes
`caf574d49d5331d9eae4f6d5e3a52735a0942c9246076385342832b752c60976`
and
`9e99b187fb937923308ac1d6e4c47c5b372285a240219cfe4323a80b8640303e`.
Through the production type-header checkpoint the candidate deterministically
removes 2,216 allocations and 2,216 releases, retains the same 3,743,444
objects, and retains 13,952 fewer bytes. Three clean alternating measured pairs
after one earlier warmup per worker produced:

| Metric | Baseline median (range) | Candidate median (range) | Median delta |
| --- | ---: | ---: | ---: |
| elapsed seconds | 9.306 (9.300-9.313) | 9.299 (9.269-9.443) | -0.074% |
| peak RSS bytes | 561,758,208 (561,594,368-562,380,800) | 562,003,968 (562,003,968-562,413,568) | +0.044% |
| type-header checkpoint microseconds | 184 (175-193) | 182 (173-194) | -1.087% |
| graph-prepare checkpoint microseconds | 2,510,248 (2,504,793-2,511,492) | 2,505,076 (2,500,386-2,566,797) | -0.206% |
| target typecheck checkpoint microseconds | 13,711 (13,114-13,732) | 14,073 (13,067-14,439) | +2.640% |
| semantic projection checkpoint microseconds | 83,354 (83,170-84,120) | 84,650 (83,257-85,205) | +1.555% |

The paired total-elapsed deltas were `-0.338%`, `-0.150%`, and `+1.477%`.
Absolute downstream checkpoint differences are small and have no corresponding
allocation or accepted-window instruction regression, so they are reported as
timing noise rather than a compiler-wide speedup. An earlier replay set
overlapped work in other worktrees and is retained only as
allocator/identity evidence.

The missing whole-compiler and cumulative instruction gates were measured with
the same current `blorp/src/main.brp` input. The production-tree-equivalent
pre-Issue-45 control is `3265c25e`: relative to its parent, it changes only the
bootstrap pin, not compiler production source. Compiler binary hashes were:

| Variant | Compiler SHA-256 |
| --- | --- |
| pre-Issue-45-equivalent control | `caa6bea55658f1bb5ca43080940e7ee4d6a76e529cdef696bb60d0f66dd66f0e` |
| Issue 46 baseline | `37250393d68c9ac916d9ec3beebd25a2b167a725d92b91c399c1d59cace2cd85` |
| final Issue 47 candidate | `baf89fbf1c157673428dccd848a02df64c1f61518dc1a2897618d090d538fa14` |

The balanced three-variant run produced byte-identical stdout with SHA-256
`c1758b804e292be62860bce968c8cee14b4b6a8fec681ff19c5318e5195c0963`
and empty stderr:

| Metric | Control median (range) | Issue 46 median (range) | Issue 47 median (range) |
| --- | ---: | ---: | ---: |
| retired instructions | 316,459,517,412 (316,434,994,707-316,512,327,080) | 314,704,992,722 (314,623,504,587-314,741,483,049) | 314,699,276,233 (314,684,782,634-314,839,158,847) |
| cycles | 70,690,505,286 (70,302,747,932-70,991,812,976) | 70,736,765,788 (70,624,899,484-71,294,290,507) | 70,548,517,477 (70,105,838,704-70,855,720,805) |
| maximum RSS bytes | 876,068,864 (875,741,184-876,216,320) | 876,101,632 (876,052,480-876,281,856) | 875,855,872 (875,773,952-876,118,016) |

Issue 47 is `-0.0018%` by median instructions versus Issue 46, below the
measurement's resolution. The cumulative Issue 47 result is `-0.556%` versus
the pre-Issue-45-equivalent control, consistent with Issue 46's retained gain.
A second paced alternating Issue 46/47 set also found no repeatable
instruction direction (`+0.014%` by medians; per-pair `-0.003%`, `+0.027%`,
`+0.014%`). Its paired elapsed median was `+0.858%`, with pair deltas of
`+5.303%`, `+0.858%`, and `-11.316%`; this is frequency/scheduling noise, not a
consistent regression. Median RSS changed by `+0.030%`.

The original issue text expected every final broad-roadmap conversion to show
a whole-compiler instruction reduction. That criterion is superseded for this
explicitly narrowed TypeHeader-only result: the effect is below whole-compiler
instruction resolution, while the production allocator reduction is exact and
the focused instruction total improves. This exception does not authorize
another dense product; a new conversion still needs its own predeclared gate.

Generated C constructs the repeated slot list with one `blorp_list_new`, fills
it in one loop, and updates uniquely owned storage. `type_header_table` creates
one final `TypeHeaderTable` from that inventory. A later pre-existing COW update
replaces the resolved header payload while retaining the same module-index
list; it does not rebuild the inventory. Reads call `blorp_list_get` directly.
No integer dictionary specialization for `ModuleTypeHeaderIndices`, fallback
reader, or intermediate complete module-index table remains.

Raw ignored evidence is under:

```text
logs/issue47/matrix/raw-v2/
logs/issue47/matrix/summary-v2.tsv
logs/issue47/function-profile/
logs/issue47/generated/
logs/issue47/replay/
logs/issue47/replay-clean/
logs/issue47/whole-compiler/
logs/issue47/whole-compiler-paced/
```

### Decision

Retain the TypeHeader dense list. It removes exact dictionary work, reduces
focused and production allocations, preserves durable semantics, and has only
a bounded one-reference-per-empty-module retained cost. Do not generalize this
result: every other Stage 06 category remains on its current representation and
requires a new dense-domain proof and independent performance gate.
