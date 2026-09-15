# Step 2e Visibility Convergence: Finite Exit Sequence

**Status:** Complete. One scope-issued `BoundVisibility` product owns graph
occupancy, exact source-ordered candidate outcomes, and accepted import
payloads. Accepted alias, union, and explicit-constructor construction consumes
exact `ModuleId`/`DefinitionId` facts; the graph successful-only inventory and
the displaced path/name regrouping scans are deleted. The final correctness,
resource, rejected-experiment, and string-retention audit is recorded in the
[Step 2e completion screen](../../../benchmarks/results/compiler_step2e_visibility_completion_2026-09-14.md).

The real 64-module selective-import accepted stage improves retired
instructions and executable size while preserving all semantic and constructor
checksums; peak footprint and RSS stay effectively flat, allocation calls rise
0.95%, and retained bytes remain effectively flat. The bound stage improves
allocations and instructions while retaining a small exact candidate payload. The direct
immutable-snapshot width probe has a measured allocation cost for constructing
the new candidate history, but its instructions improve, growth is linear, and
all transient objects are released. A buffered replay subsystem was rejected: it
would complicate source-ordered diagnostics and constructor admission without
improving the real-pipeline checkpoint.

**Roadmap:** [Normalized Semantic Compilation Roadmap](NORMALIZED_SEMANTIC_COMPILATION_ROADMAP.md), Step 2e convergence

**Depends on:** Accepted catalog and category identity packets (Issues 68-93)

## Decision

Step 2e was not complete merely because individual authorities used IDs. Its
completion checkpoint was one phase-correct module-visibility relation that
records candidates, exact origin/order, accepted winner or conflict, and named
query indexes. Ordinary graph resolution must consume it;
the displaced graph indexes and reconstructed category visibility paths must be
deleted. This document fixes the exit sequence so a succession of isolated
dictionary removals cannot be mistaken for that outcome.

There are two necessary product moments, not two independently copied row
stores:

```text
parse / bind imports / resolve early headers
    BoundVisibility: source names, modules, category-safe definitions,
                     binding order and conflicts already knowable here
                  |
                  | accepted category tables publish TraitId, CallableId, ...
                  v
accepted semantic resolution / analysis snapshot
    AcceptedVisibility: bound-row references plus exact selected entities,
                        winner/overload/conflict outcomes
```

Early header and trait-reference resolution currently use `ModuleView` before
accepted trait, callable, record, union, alias, and global authorities exist.
Building only a late accepted table and redirecting early lookups to it would
create a phase cycle. The bound relation must own early decisions; the accepted
relation enriches those rows when IDs exist and replaces its graph-side
projection. The current accepted graph still retains its `BoundModuleGraph`
through header products; Step 2e must not claim physical release of that graph.
Accepted enrichment should refer to bound row IDs and retain only new semantic
payload/outcome rows, not copy the whole bound row store. Step 7 owns eventual
release at the codegen-ready handoff. Neither product is a process-global
interner or an incremental cross-run database.

## Current Authority Audit

| Fact and phase | Current owner | Readers to cut over | Displaced storage |
| --- | --- | --- | --- |
| Graph module alias occupancy and exact target during binding | `ModuleView` | import registrar, `type_resolution`, `infer` | `graph_module_aliases_by_source_name_id` |
| Graph selective-name occupancy and source-facing target during binding | `ModuleView` | import registrar, early type/trait header resolution, `infer` | `graph_imported_names_by_source_name_id` |
| Graph local-declaration occupancy and kind during binding | `ModuleView` | registrar, early trait/header resolution, `infer` | `graph_local_names_by_source_name_id` |
| Ordered qualified/selective import decisions | `ModuleView` / `ImportBinding` | accepted category adapters, type resolution, CTFE/Core compatibility | graph portions of `module_aliases`, `imported_names`, `import_bindings` once replaced |
| Accepted nominal/value/callable/trait visibility | category authorities | ordinary accepted resolution, diagnostics | category-specific candidate/reconstruction indexes once one accepted relation owns their common visibility rule |
| Tooling semantic projection | typed-program extraction | existing LSP definition, references, document-symbol, highlight, and hover queries | No current handler consumes module visibility; migration belongs to Step 8 when a genuine query exists |

The three graph `ModuleView` indexes already use `SourceNameId`-derived integer
keys. That is useful but not a row table: each category owns a separate map,
while conflict checks manually consult several maps in priority order.
`module_aliases`, `imported_names`, and `import_bindings` also preserve ordered
inventories and compatibility text. They cannot be deleted before each named
consumer can project or query the new relation. Standalone source-mode string
maps are a distinct compatibility domain, not graph authority to merge by a
shared nullable record.

LSP currently advertises definition, references, document symbols, document
highlights, and hover, but not completion. Its definition and document-symbol
handlers do not consume module visibility; they query exact occurrences or
document declarations. Step 2e may expose a compiler-owned module-level
analysis query after ordinary resolution uses the accepted relation, but must
not route an unrelated LSP handler through it just to claim a tooling cutover.
Step 8 owns genuine tooling migration. Public completion is a separately
scoped feature, not an implicit Step 2e requirement.

## Target Contract

The bound relation uses one source-name-keyed occupancy table, not three
category maps or an unindexed list scan on every registration. A row variant
makes legal cross-category overlap explicit. A separate candidate log owns
order; dictionary iteration order is not semantic order. This sketch shows
the post-Cut-B reference shape; Cut A retains only current occupancy:

```blorp
opaque type ImportBindingRowId = Int

union BoundNameOccupancy:
	BoundModuleAlias(ImportBindingRowId, ModuleId)
	BoundSelectiveName(ImportBindingRowId, ModuleId, Int)
	BoundAliasAndSelectiveName(ImportBindingRowId, ModuleId, ImportBindingRowId, ModuleId, Int)
	BoundLocalName(TopLevelNameKind)

record BoundVisibility {
	issuer: PreparedModuleScope,
	rows_by_source_name_index: Dict[Int, BoundNameOccupancy],
	candidates: List[BoundCandidate]
}
```

The sketch is a design constraint, not a license to make raw `Int` keys public.
The opaque `PreparedModuleScope` (or an equivalently checked scope capability)
owns the `SourceNameTable` and `ModuleTable` domains together. Construction
must reject a foreign scope, including an equal-layout graph from another
compilation. The existing `prepared_module_scopes_are_compatible` is not
sufficient: it deliberately accepts structurally equal foreign graphs. An
opaque graph-issued `GraphSourceNameTable` below `indexed_graph` now binds one
name catalog to the exact `ModuleTable`
allocation without an import cycle. Registration checks that exact table.
The implemented view binds selected-module ID and checks registration, state
lookup, inference admission, and binder publication. Later joins must also reject a reminted
source-name catalog from the public graph-building factory. Query APIs receive
an exact capability or retain it under the opaque table; a naked
`SourceNameId`/`ModuleId` pair is not proof of provenance.
`ImportBindingRowId` is a checked, issuer-local reference to the existing
ordered graph `ImportBinding` row, which owns exact `ModuleId` and
`DefinitionId` targets where they already exist. The source-facing
`ImportedNameBinding` is retained only for early header/diagnostic consumers
until cut B can project it from the bound row. Do not turn this sketch into a
second copied import-target list. Local definition identities are joined when
their graph definition rows are available; `TopLevelNameKind` alone is only
early namespace occupancy, not accepted semantic identity.
The completed occupancy row references the winning candidate row(s), while
the candidate relation owns checked binding references and issued order for
**each** candidate. Accepted imports occupy one required ordered semantic
payload column plus a parallel scalar row-ID column; sparse rejected rows
record their issued positions. The row-ID column prevents accepted consumers
from repeatedly reconstructing source order through rejected/local gaps.
Accepted locals project from their occupancy row IDs, so they are not copied
into a second retained list. Neither order is inferred from `SourceNameId` or
a summary-row position. The alias-plus-selective variant is required
because current binding permits both under one local spelling when they target
the same module. A
single `Option`-laden record would hide that invariant.

At accepted publication, each bound candidate joins to the category table
that owns its `DefinitionId`/`TraitId`/`CallableId` and obtains a typed
`VisibleSemanticEntity`. The accepted product retains candidate origin/order
and explicit accepted/rejected outcome; display strings are projected from
source and definition tables for diagnostics or external formats. There must
be no accepted fallback that guesses a target from spelling. Accepted outcome
rows refer to bound candidate IDs under the same scope rather than copying bound
source/target/order payloads. Measure unique bound row allocations, accepted
outcome bytes, and shared references at the accepted graph handoff; the
`BoundModuleGraph` is still retained today. Imported
trait-method rows must join only after their topology-issued `TraitMethodId`
exists, as Issues 92-93 established.

## Finite Exit Cuts

Each cut is one reviewed packet or a narrowly named namespace cohort. Do not
publish a new public table without cutting at least one production consumer
and deleting the corresponding old path in the same packet.

### A. Bound graph-name occupancy

Replace all three graph `ModuleView` source-name dictionaries with one keyed
bound-occupancy table issued by the prepared graph scope. Route registration conflicts and early graph alias,
selective-name, and local-kind lookups through it. Preserve the exact
same-target alias-plus-selective exception and first/duplicate registration
behavior. Keep standalone maps separate. Reject foreign and equal-layout
graph capabilities. Delete the three graph dictionaries
in the same cut; do not add the new table beside them.

The completed Cut A foundation has one occupancy relation, exact
overlap/conflict semantics, and foreign-table rejection. It binds selected-module
identity to the view and checks graph use against the active scope. The
candidate completion screen separates the historical three-map comparison
from the incremental candidate cost and records the final combined decision.

### B. Exact candidate provenance and decisions

Move ordered graph import/local candidates into a separate append-only log
under the same bound owner, with explicit origin and issued order per
candidate, including observed conflicts. The current-name occupancy index
references the admitted candidate row(s), while the log preserves both alias
and selective order when one spelling admits both. Derive the
existing compatibility inventories from rows at their named boundaries and
delete graph-owned inventory copies only after their consumers are cut. Prove
winner, overload set, shadowed candidate, and rejected conflict outcomes with
small collision fixtures, not a generic rank integer. Where early resolution
needs only a bound fact, it must not reach forward to accepted semantic IDs.

The [Cut A width probe](97-bound-visibility-width-probe.md) found that the old
per-candidate immutable `ModuleView` publication retained growing occupancy
and ordered inventories while COW updates ran. That evidence established the
scope-local, uniquely owned candidate/occupancy builder used by completed Cut
B. The first production slice batched only graph-local prescan rows; the final
slice also batches imports and publishes once at the phase boundary.

The preliminary Cut A stop rule rejected isolated width wins that materially
raised allocations or small-workload cost. The completed candidate relation
necessarily records information that Cut A did not have, so the final decision
uses the parent roadmap's real-pipeline thresholds and records the concentrated
probe separately. Its +38.74% short-lived allocation count is linear, leak-free,
and paired with 2.69% fewer retired instructions; the real accepted and bound stages
remain inside the combined resource gate. The paged-row trial documented in
the width probe failed both the smaller-case and allocation checks and remains
reverted.

The earlier local-only slice's temporary candidate list and per-import
publication are historical; neither remains in the completed owner.
Two other intermediate slices deleted the graph `module_aliases` inventory and
introduced explicit `ImportDeclDecision` values at the declaration boundary.
At those historical checkpoints, early resolution already used keyed
occupancy, but import publication was still per-candidate and rejected outcomes
were not retained. Completed Cut B supersedes both limitations: the admission
builder records every outcome in source order and publishes the immutable view
once.
The next historical deletion removed the second graph selective-name inventory:
`BoundNameOccupancy` owns exact current-name payloads and `import_bindings`
owns accepted source order. `module_view_imported_names` now projects an
ordered compatibility list only at named boundaries; header annotation
resolution uses keyed `module_view_find_imported_name` directly, and accepted
type-alias installation scans the binding log without building that list.
Standalone source bindings retain their own list. At that intermediate point,
per-candidate publication and rejected-candidate provenance still remained;
the completed scope-local admission owner below removed both gaps and was
screened on actual selective-import fan-out.
Graph import admission now publishes one bound view after the import loop.
Module decisions now stream in source order without a replay list, saving 690
allocation/release calls in the retained 10-iteration, 64-module fixture.
The completed Cut B change threads its builder through rejected and
idempotent results, carry parsed origin and order into issued rows, include
local prescan candidates, and replace the successful-only `import_bindings`
inventory rather than add a sidecar. Preserve the one-write constructor path
and checked source-catalog provenance. [Issue 143](143-step2e-scope-local-import-admission.md)
records the owner and resource evidence.

### C. Accepted enrichment and ordinary resolution

Join bound candidates to the published accepted catalog and replace
category-local visibility reconstruction in bounded type/trait, then
value/callable, then module-qualified cohorts. Every cohort must move at least
one ordinary production lookup to exact rows and remove a named superseded
index or scan. Keep semantic-name obligation and graphless Env compatibility
as explicit adapters until their own consumers can be moved; do not call those
adapters the accepted source-visible authority.

### D. Compiler query and deletion audit

Expose a narrow compiler-owned module-level visibility query only after a
named compiler consumer needs it. Existing LSP queries do not currently need
module-visible names; do not create a redundant LSP consumer or a completion
provider as part of this cut. Preserve existing LSP behavior with the protocol
gate. If a changed analysis/index path affects existing requests, capture
pre-change response payloads first and compare exact JSON for definition,
references, document symbols, highlights, and hover as applicable; the gate
alone does not prove byte-for-byte equality. Delete graph `ModuleView` maps and source-string
joins that have no remaining named consumer. Measure live source/name strings
and retained table bytes at bound publication, accepted publication, and the
codegen-ready handoff. Step 2e closes only when the roadmap acceptance criteria
below are demonstrably true, not when packet D is merely written down.

If a cut cannot delete its stated old authority, stop and revise the design
before another small ID wrapper lands. If the checkpoint fails the combined
resource scorecard, investigate a concrete retained workload; do not count
architectural neatness as a performance win.

## Fast Feedback And Evidence

Cut A's graph-mode binder and structural fixtures exist. Re-run and extend
them only for a Cut B behavior not already protected. The required cases are
same-source/same-target alias-plus-selective
success in both registration orders; different-target conflicts in both
orders; duplicate alias same-target idempotence versus different-target
conflict; duplicate selective conflict even for the same target; local/import
collision; private imported name; missing source ID; qualified-only module;
and standalone-source isolation. Assert the exact order of successful
`GraphQualifiedModuleBinding` and `GraphSelectiveDefinitionBinding` entries,
as well as unchanged `import_bindings` after rejection. Put the private
imported-name case at the declaration binder/import-validation boundary:
low-level `ModuleView` receives already-admitted bindings and cannot decide
source privacy itself. Graph clearing must retain qualified aliases while
removing selective/local rows. Keep the structural absence check for the
removed graph dictionaries; do not recreate the already-completed Cut A
test-first sequence.

```bash
python3 blorp/test/compiler/stage_06_typecheck/support/test_declaration_boundary.py
bin/blorp test blorp/test/compiler/stage_06_typecheck/test_module_view.brp
bin/blorp test blorp/test/compiler/stage_06_typecheck/test_typecheck_decl.brp
scripts/compiler-check --changed
```

Use one direct baseline/candidate counter pair before broad gates. Reuse the
retained visibility-width fixture from the [width probe](97-bound-visibility-width-probe.md),
varying module count, aliases, selective imports, duplicate spellings, and
query count; do not infer scaling from a
checked-bodies benchmark that barely exercises visibility. Record accepted
identity and diagnostic checksums, candidate visits, string hashes, index
probes, allocation/release and retained counts, allocated bytes, retired
instructions, peak RSS, executable size, and generated C identity. Request
timing pairs only if latency is the claim or a result is near a threshold.

Cut D additionally runs the existing `scripts/test lsp` gate. Where analysis
plumbing changes an existing request, capture its parent JSON before the cut
and compare exact bytes after it. Full compiler/runtime/leak gates remain
premerge guards; they are not the inner development loop.

## Acceptance And Stop Rule

- [x] Early bound versus later accepted ownership is explicit; no phase cycle
  or pretend early `TraitMethodId` is designed into the table.
- [x] The current graph maps, inventory consumers, category authorities, and
  existing LSP capability boundary are inventoried.
- [x] One scope-issued bound graph visibility relation replaces the three
  graph occupancy dictionaries, with graph-mode source-order, reciprocal
  overlap/conflict, foreign-provenance, and equal-layout rejection tested.
- [x] Candidate origin/order and accepted/conflict outcomes have one authority
  and preserve current precedence, privacy, overload, and diagnostics.
- [x] Ordinary graph resolution consumes exact facts and displaced graph and
  category paths are deleted; a compiler query exists only for a named
  consumer, while LSP migration waits for a genuine Step 8 use.
- [x] Accepted enrichment refers to the retained bound row owner without a
  second full bound-row copy; actual release waits for Step 7.
- [x] The combined checkpoint improves a strict majority of applicable
  resource families under the parent roadmap's thresholds, with no material
  real-pipeline guard regression or unvalidated string-retention transfer.
  The direct immutable-snapshot probe's linear transient allocation cost is
  the measured capability trade recorded in the completion screen.

No additional Step 2e visibility packet remains. Phase-specific import-state
typing would require changing the broad `TypecheckState` product and is not a
visibility authority or resource-gate prerequisite; treat it as a separately
measured typechecking-product change if a named consumer justifies it.
