# Step 2e Visibility Convergence: Finite Exit Sequence

**Status:** Cut A occupancy, selected-module provenance, and candidate-only width probe implemented in [Issues 95-97](97-bound-visibility-width-probe.md). The API-adapted historical comparison is complete and exposes a resource regression; Cut A's performance gate remains open.

**Roadmap:** [Normalized Semantic Compilation Roadmap](NORMALIZED_SEMANTIC_COMPILATION_ROADMAP.md), Step 2e convergence

**Depends on:** Accepted catalog and category identity packets (Issues 68-93)

## Decision

Step 2e is not complete merely because individual authorities use IDs. Its
remaining checkpoint is one phase-correct module-visibility relation that
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
	BoundSelectiveName(ImportBindingRowId, ImportedNameBinding)
	BoundAliasAndSelectiveName(ImportBindingRowId, ModuleId, ImportBindingRowId, ImportedNameBinding)
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
sufficient: it deliberately accepts structurally equal foreign graphs. Issue
95 introduces an opaque graph-issued `GraphSourceNameTable` below
`indexed_graph` that binds one name catalog to the exact `ModuleTable`
allocation without an import cycle. Registration checks that exact table.
Issue 96 binds selected-module ID to the view and checks registration, state
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
The Issue 95 occupancy row summarizes current occupancy; it is not an ordered
candidate history and does not yet retain checked binding references. The
existing `import_bindings` inventory owns relative order in cut A; cut B
replaces that inventory with a candidate log, checked row references, and issued order for
**each** candidate. Neither order may be inferred from `SourceNameId` or a
single summary-row position. The alias-plus-selective variant is required
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

Issue 95 completed the single-relation occupancy replacement, overlap/conflict
semantics, and exact foreign-table rejection. Issue 96 binds selected-module
identity to the view and checks graph use against the active scope. The
API-adapted direct baseline comparison in [Issue 97](97-bound-visibility-width-probe.md)
exposed a resource regression. Removing the redundant row-list/index pair
improves the current representation, but mixed-width admissions still trail
the older three-map implementation. Cut A's performance gate therefore
remains open; its whole acceptance item below is deliberately unchecked.

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

The [Cut A width probe](97-bound-visibility-width-probe.md) found that
per-candidate immutable `ModuleView` publication retains the old occupancy
table and ordered inventories while COW updates run; these growing
collections are copied on admission. Cut B should therefore build within one
scope-local, uniquely owned candidate/occupancy owner and publish an immutable
view at the phase boundary, not add a second persistent list beside the old
inventories. Keep narrow and wide width runs in the inner loop, and reject a
change that improves wide latency by materially raising allocations or
small-workload cost. The paged-row trial documented there was reverted.
The first production slice now batches graph-local prescan rows and publishes
one immutable view before imports; the matched width fixture improves local-heavy
allocations and retired instructions. Import binding still updates the view
per candidate, so this slice is not Cut B completion. Its temporary local
candidate list must be accounted for in the accepted-stage resource screen.
The next bounded deletion removes the graph `module_aliases` inventory:
`GraphQualifiedModuleBinding` owns alias admission order, and early resolution
queries the keyed occupancy for an actual qualified name. It improves
direct-width allocations; the resolver first checks exact table and
selected-module ownership, including against equal-layout foreign views. It does
not yet batch import admissions or record rejected candidate provenance.
The next preparatory slice makes one `ImportDeclDecision` at the module
declaration boundary: missing, ambiguous, forbidden package, duplicate, or
selected. The source loop applies each decision immediately, so missing and
duplicate diagnostics remain in source order and only selected modules reach
symbol/alias registration. This removes a hidden admission branch and gives a
future import builder a precise input, but still retains no candidate/outcome
log and performs per-import immutable-view publication. The builder must next
represent symbol, alias, and local outcomes (including conflicts) in source
order and replace, not duplicate, the growing graph inventories.
The next deletion removes the second graph selective-name inventory:
`BoundNameOccupancy` owns exact current-name payloads and `import_bindings`
owns accepted source order. `module_view_imported_names` now projects an
ordered compatibility list only at named boundaries; header annotation
resolution uses keyed `module_view_find_imported_name` directly, and accepted
type-alias installation scans the binding log without building that list.
Standalone source bindings retain their own list. This reduces direct-width
admission work but still leaves per-candidate view publication and no rejected
candidate provenance. Before removing more compatibility storage, measure
actual selective-import fan-out through the accepted graph, not just the
qualified-only accepted-stage fixture.

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

Before cut A, add a genuine graph-mode binder fixture. The current
`test_module_view.brp` conflict/ordering cases predominantly use standalone
registration; its graph cases mainly reject standalone calls on a graph view.
The new fixture must cover same-source/same-target alias-plus-selective
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
removing selective/local rows. A structural check
must first fail on the three old graph dictionaries. Add the graph fixture,
declaration suite, and structural check to `module_view.brp`'s changed-owner
manifest, or run them explicitly as mandatory cut-A gates; the present owner
mapping selects only `test_compiler_module_view`.

```bash
python3 blorp/test/compiler/stage_06_typecheck/support/test_declaration_boundary.py
bin/blorp test blorp/test/compiler/stage_06_typecheck/test_module_view.brp
bin/blorp test blorp/test/compiler/stage_06_typecheck/test_typecheck_decl.brp
scripts/compiler-check --changed
```

Use one direct baseline/candidate counter pair before broad gates. Add a
retained visibility-width fixture varying module count, aliases, selective
imports, duplicate spellings, and query count; do not infer scaling from a
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
- [ ] One scope-issued bound graph visibility relation replaces the three
  graph occupancy dictionaries, with graph-mode source-order, reciprocal
  overlap/conflict, foreign-provenance, and equal-layout rejection tested.
- [ ] Candidate origin/order and accepted/conflict outcomes have one authority
  and preserve current precedence, privacy, overload, and diagnostics.
- [ ] Ordinary graph resolution consumes exact facts and displaced graph and
  category paths are deleted; a compiler query exists only for a named
  consumer, while LSP migration waits for a genuine Step 8 use.
- [ ] Accepted enrichment refers to the retained bound row owner without a
  second full bound-row copy; actual release waits for Step 7.
- [ ] The combined checkpoint improves a strict majority of applicable
  resource families under the parent roadmap's thresholds, with no material
  regression or unvalidated string-retention transfer.

No additional opportunistic Step 2e dictionary packet precedes cut A. After
each cut, update this checklist and the parent roadmap. If the proposed cut
requires a large preparatory refactor or fails its direct regression screen,
stop and report the obstacle instead of expanding Step 2e silently.
