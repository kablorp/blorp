# Definition authority prerequisite probe

This is an experimental decision record at `ff4da4b31dc2f5e0e1b9425a2ac96c06f6399a63`,
not a production identity delivery. The owning [roadmap](IDENTITY_ROADMAP.md#definition-authority)
sets the acceptance gates. Native representation results below reject the
universal nested mint carrier in its current calling shape; no producer migration
is authorized by the existence of this note or the probe.

## Source issuer and adaptation

The active source authority is
`compiler_new/stage_01_discovery/tables/ids.brp`'s `DefinitionId`, the row of
the frozen discovery definition table. The module identity is the row's explicit
`module`, and members have an explicit `MemberRow { definition, owner, ordinal }`.
The separate `syntax/ids.brp` packed module/local ids describe redesign machinery;
they are not the production adapter's authority.

The adoption operation checks the active frontend/module-table association once,
then projects every source id into the artifact-local semantic relation. Storage
row numbers are an initial encoding, not permission to change identity when a
later view sorts, filters or compacts. Standalone parsed compilation has no
discovery issuer; a checked artifact-local catalog constructor owns admission
there. Callers do not provide arbitrary integers.

Discovery and legacy graph `ModuleId` types currently belong to different
modules. Establish a checked one-to-one issuer projection from the adapter's
already accepted module identity mapping; a raw row-number cast is insufficient.
The catalog's module and every child owner's module must agree after projection,
and admission rejects an unrelated module table even when counts match.

| Active discovery kind | Semantic family / legacy location | Owner rule |
| --- | --- | --- |
| FunctionDefinition | callable / function declaration | module |
| ForeignFunctionDefinition | callable / foreign-block child | module; block grouping is location, not identity |
| RecordDefinition, FixedRecordDefinition | nominal type / record declaration | module |
| UnionDefinition, FixedUnionDefinition, EnumDefinition | nominal type / union declaration | module |
| BuiltinTypeDefinition, ResourceTypeDefinition | nominal type / builtin-type declaration | module; resource cleanup is satellite data |
| TypeAliasDefinition, OpaqueTypeDefinition | nominal type / alias declaration | module |
| TraitDefinition | trait / trait declaration | module |
| ImplDefinition | implementation / impl declaration | module; trait spelling is not implementation identity |
| ConstantDefinition, MutableGlobalDefinition | global / variable declaration | module |
| FieldDefinition | field / record field child | exact MemberRow owner |
| VariantDefinition | constructor / union or enum child | exact MemberRow owner |
| TraitMethodDefinition | callable / trait method child | exact MemberRow owner; preserve declaration-only and default-body distinction |
| ImplMethodDefinition | callable / implementation method child | exact MemberRow owner |
| LocalFunctionDefinition | callable / body declaration site | enclosing executable owner from body admission, never module/name guessing |

The legacy adapter emits the top-level forms above at `discovery_adapter.brp:3409`.
It handles foreign functions/members through their owning declarations and local
functions through bodies; the top-level switch deliberately returns `None` for
those kinds. Their ids must be propagated through those same owner-directed
locations, not silently omitted from the source catalog.

Local functions are not members in the current table: `LocalFunctionNode.payload`
is the exact source DefinitionId, and `BodyRow.definition` supplies the containing
body owner. The existing adapter node/body walk must publish that ownership edge
while reconstructing the local declaration. A catalog cannot infer the owner
from name/span or assume the definition table's previous row is the owner.

The current Stage 6 enumerator (`graph/definition_index.brp:2030`) reserves only
top-level functions, foreign functions, nominal types and children, traits,
implementations, explicit implementation methods and globals. Declaration-only
trait methods instead use an owner-plus-slot `TraitMethodId`. Source local
functions are hoisted by `source_ast_finalize.brp:1486` into appended
`FunctionParsedDecl`s, so the legacy enumerator reserves the finalized form as an
ordinary callable. Its generated `__nested_...` spelling must not become a new
semantic authority: preserve the source DefinitionId and containing body owner
through finalization and publish the final declaration locator. Inference
explicitly rejects nested function declarations surviving finalization
(`infer.brp:24006`). Adoption must reconcile these consumers with discovery
authority in the production train. A second spelling resolver cannot fill that
gap.

Inherited default implementation methods are generated projections, not new
source declarations. Today Stage 6 inserts their callable rows at the impl span
before explicit methods. Their generated semantic authority must name the
implementation and source default owner explicitly; their compatibility order
must preserve that insertion. Builtin environment ids precede the graph seed and
remain an explicitly disjoint reserved authority. Neither kind can borrow a
discovery row merely because its spelling or span matches.

The adapter can publish normalized catalog columns while it already constructs
legacy declaration/child locations: semantic source id, module, category,
visibility, owner index, locator kind, declaration index, child index, span and
display-name reference. Spelling stays owned by the existing display/name table;
the catalog does not intern or re-resolve it. Freeze one checked equal-length relation with named absent-index
constants. Locators identify existing AST positions; they do not carry AST
bodies. Adoption replaces graph-time source minting and enumeration; that old
enumerator is deleted, not retained as a shadow source of truth.

## Frontiers and output order

Stage 6 currently reserves target first and canonical-path-sorted dependencies
(`definition_index.brp:2193`), which differs from discovery's source order.
Semantic ids adopt discovery; output compatibility ordinals preserve that old
reservation order. A source row slice/base permits subtraction only inside its
validated interval. Generated allocation frontiers are not table lengths or
evidence that a row exists. `definition_index_advance_to_env` already preserves
later body-local/generated allocations without adding source rows.

The first safe publication boundary is Stage 6's final definition authority into
`TypecheckedGraph`. Publish its checked scalar semantic frontier there, rather
than proving it from `next_id - 1`, a Core scan or maximum retained declaration.
That graph frontier, the source compatibility assignment, and standalone checked
catalog admission must exist before Stage 8 can mint a divergent pair correctly.

## Pair API representation under test

The probe uses a private existing owner record with two next-frontier scalars,
two explicit issued-result scalars and a managed program child. `Owner` and
`MintedDefinition` are distinct opaque views over that same private record.

```blorp
pure func mint(owner: Owner) -> MintedDefinition:
    rep = from_opaque Owner(owner)
    semantic = rep.next_semantic
    emission = rep.next_emission
    into_opaque MintedDefinition({ rep |
        next_semantic = semantic + 1,
        next_emission = emission + 1,
        issued_semantic = semantic,
        issued_emission = emission
    })
```

Typed getters accept only the minted view and return opaque scalar ids. The
caller reads both before returning the same updated owner to its orchestration
loop. There is no pair tuple, child receipt record, arithmetic reconstruction of
issued ids, packed handle or public raw receipt constructor. The default seeds
are deliberately divergent, 101 and 7; initial issued fields are inaccessible
through the unminted type. Those fixture seeds are not proposed production ids.

Three negative programs attempt cross-module `into_opaque`, one-sided field
update and use of an ordinary owner as a receipt. Existing opaque-conversion
fixtures promise defining-module-only conversion, but these concrete tests must
confirm it for this nested representation. The private module can still make a
bad state internally, and immutable owners can be reused to request duplicate
ids: Blorp has no linear types. A sole-issuer import/update ratchet and final
duplicate census are required alongside nominal privacy. Do not describe that
checker guarantee as a property enforced by the type alone.

Current `CorePassState` is a public record. Adding two independent fields there
cannot deliver this authority: producer code can reconstruct either separately.
Making all pass state opaque would span many consumers. Probe success therefore
does not authorize a broad opacity refactor; the integration design must select
the smallest existing orchestration owner with a private representation and a
paying consumer, or explicitly propose a reviewed preparatory boundary.

Candidate first consumer: Stage 8 program entrypoint synthesis. It currently
returns `(program, next_def_id)` and directly increments its frontier. The actual
delivery would mint a paired definition at the orchestration owner, put the
semantic id and emission ordinal on the generated wrapper, and remove the tuple
allocator/direct increment with the same source/output behavior. This follows
graph frontier publication; it cannot substitute for it. Every later mint must
use the shared API in the same integration train before divergent source ids
reach late Core.

### Checked frontier slice boundary

The exact existing path is `DefinitionIndexRep.next_def_id` through
`definition_index_next_def_id` into `bridge.TypecheckedGraph.next_def_id`, then
`pipeline.core_lowering_input` into its private `CoreLoweringInput`, then
`lower_prepared_core_request` into
`graph_prepare.prepare_core_graph_with_ctfe_replacements`. The last join checks
module and CTFE table provenance, but accepts a separately supplied raw integer
frontier without any authority check. The exploratory
`test_core_graph_rejects_frontier_before_admitted_definition` supplies an
already-admitted callable id as that frontier. Its contextual source is retained
in [the scratch reproduction](../benchmarks/identity_definition_probe/stale_frontier_repro.md),
with no owning-suite registration; it must not drive a new Stage 8 row-maximum
guard. Its native result is pending. The before-boundary illustration is
`negative_graph_raw_frontier.brp`: today a function can replace an ordinary graph
frontier with raw zero. That program typechecks. In the narrower whole-publication
design below, ordinary tooling views may still be edited, but callers must be
unable to certify that edited view or supply its independent frontier to Core.
Those are the regressions the eventual production slice must establish.

Replacing that integer with an opaque scalar would reject arbitrary raw integer
construction, but cannot prove it belongs to the adjacent table: equal integers
from different artifacts are indistinguishable, and the public graph record
permits field swapping. An exact-provenance join needs the existing issuing
authority, or the frontier must live implicitly inside a private checked graph
container. Making TypecheckedGraph opaque preserves its existing physical record
but touches its consumers: 12 source/test files reference that type. There are
three fresh graph-construction shapes and one target-view copy in bridge, two
Core prepare signatures, the private pipeline input and eight direct Core prepare
test calls. This is a proposed scope, not an approved preparatory refactor.

One sentence for a possible production slice: bind Stage 6's generated-definition
frontier to its exact source authority at the published graph/Core join so
lowering cannot accept an independently supplied stale or foreign allocator.
Stop rather than present a scalar rename as satisfying the foreign-authority
invariant. The existing `definition_tables_share_provenance` check compares exact
allocation identity, not table size or structural equality; any selected join
must retain that distinction without pointer packing or a new language feature.

A narrower alternative to full graph opacity is a `PublishedTypecheckedGraph`
opaque view over the existing graph record. Stage 6 alone constructs it after the
index/table join and installs the frontier from that index. The successful
compiler's existing `TypedFrontendCompilationRep` would carry that checked view
instead of the ordinary graph; pipeline unwraps it only while constructing the
existing private Core request. Tooling could retain ordinary graph access without
being able to rewrap a changed copy. This remains a design candidate: it must
replace the existing successful-path carrier, have an active Core consumer,
introduce no extra owner/child allocation, and trace all graph/standalone
publication routes. Wrapping the presently unchecked prepared request at its
last boundary does not prove issuer provenance and is not this alternative.

For that alternative, whole-container publication protects the pairing; a
separate opaque scalar does not strengthen issuer provenance by itself. Preserve
the ordinary graph's raw scalar field and defer nominal semantic/emission frontier
types to the real output-numbering split. Add no unused token accessor. Private
Stage 6 publication would have to check the final index's exact table provenance
and install its frontier. The sole successful compiler construction of
`TypedFrontendCompilationRep` is `typecheck_parsed_frontend_compilation`; swap its
existing graph field to the published view. Do not publish before the names and
identifier-spellings update unless the private update helper preserves the view.

Core modules would consume the whole published view and retain its scalar
in the existing private `CoreGraphModulesRep` with its existing definition table.
Remove the independent raw frontier from `CoreLoweringInput` and both Core prepare
arguments. Fixture modules consume a checked `DefinitionIndex`, taking table and
frontier from that one authority. A constructor that instead takes separately
extracted table and frontier recreates the foreign-token defect. Minimum proposed
production scope is `definition_index.brp`, `bridge.brp`, `pipeline.brp` and
`graph_prepare.brp`, plus bridge/Core fixture migration and proof tests; verify
the estimate before implementation.

Publication proof tests must cover:

- `typecheck_frontend_graph_ids_for_table` through `timed_module_bodies`, including
  its final name-table/identifier-spellings publication update, and rejection of
  a foreign issuing module table even when its shape matches.
- `typechecked_graph_from_prepared` through ordinary `typecheck_graph`, preserving
  CTFE replacements, module order and the final index frontier.
- `typecheck_graph_with_metrics`, whose separate graph constructor must certify
  the same table/frontier while preserving CTFE artifact reuse and metrics.
- Rejected graphs, checked empty standalone fixture authorities, source-hoisted
  locals, inherited default projections, and graph target-view selection.
- An external function that receives an ordinary graph, changes its frontier to
  another ordinary graph's typed scalar, then attempts `into_opaque
  PublishedTypecheckedGraph` on the changed copy: defining-module-only conversion
  must reject it. A caller must also be unable to import the private publication
  join or directly construct a private Core module representation.

The proposed published constructor would be private to Stage 6; it would accept
the completed source authority, validate exact frozen table provenance, and take
its frontier from that index. A public source-graph compilation entrypoint may return a published
view, but no public function may certify an arbitrary graph plus separately
supplied scalar. An ordinary-view accessor can return the existing graph value
because value semantics prevent mutation of the published owner's contents;
modified copies have no public route back into the published type.

Issuer completeness remains unproved. Both current body-completion graph joins
read the target's prepared DefinitionIndex after checking modules; their
`TypecheckedGraphModuleResult` carries no completed frontier. `infer.brp` has no
definition allocator, and finalized local functions are reserved before bodies;
private state claims mint only under extensible standalone scope, while reserved
scope rejects absent claims. These are useful negative facts, not a proof that
every Env callable/constructor projection or CTFE/generated path leaves the
prepared frontier sufficient. Trace those paths before selecting publication.
`definition_index_advance_to_env` copies only the index representation's scalar
frontier and keeps its exact `definition_table` pointer; table provenance survives
that advance. It does not by itself certify arbitrary Env arithmetic or show that
the current graph join consumed the advanced index.

## Probe and exact gates

Sources are in [the probe folder](../benchmarks/identity_definition_probe/).
The `control-consumer` and `receipt` workloads publish identical fields and read
identical issued scalars; only the minted opaque view/getters differ. Their
checksums must match at 0, 1, 40 and 1000 iterations. `nested-control` versus
`nested-receipt` stores the owner in a holder; `shared-control` versus
`shared-receipt` retains the prior owner until after minting, proving value
semantics under forced sharing. `program` measures ordinary program-only updates;
`control` isolates owner publication without the consumer's program update.
Initialization is inside the interval equally for each shape. Scalar memory
counter endpoints avoid MemStats record/reporting allocations in the interval;
counter-active must equal one. Run each shape in a separate diagnostic process.
`raw`, `raw-nested` and `raw-shared` run the same private record representation
directly, without opaque owner conversion, so the owner alias itself cannot hide
boxing or ownership overhead shared by the first pair of controls.

The exact scalar oracle is 219 at zero iterations. At a positive iteration count
`n`, consumer and nested shapes return `320 + 6*n`, shared shapes return
`219 + 320*n + 3*n*(n+1)`, the publication-only control returns `217 + 4*n`, and
program-only updates return `215 + n`. This checks divergent ids and preservation
of the old program child; merely matching allocation counts is insufficient.

Request the coordinator's native slot before these commands:

```bash
scripts/compiler-build-status
bin/blorp compile --no-format benchmarks/identity_definition_probe/probe.brp \
  -o /tmp/identity-definition-probe.c
bin/blorp run --memory-stats benchmarks/identity_definition_probe/probe.brp \
  receipt 40
```

Verify actual CLI flag/output behavior before invoking the retained recipe.
Compare allocation and release slopes, not just totals: receipt cannot add any
per-mint child allocation over matched control. Existing holder/owner publication
cost is retained and reported separately. Inspect emitted C for opaque casts,
record allocation size/count, COW checks, child retain/releases, and paired field
publication. Dynamic allocation/release counters do not count every retain; the
generated C is mandatory evidence for retain traffic. Compiler/input/toolchain
provenance and raw output hashes accompany any result. This is representation
evidence, not a compiler-speed claim.

Stop if opaque views introduce a receipt box, ownership differs from the matched
control, a getter accepts an ordinary owner, a cross-module constructor succeeds,
the pair can be advanced independently outside the authority, or the production
integration requires unrelated state migration. A failing representation returns
a bounded prerequisite/no-go result; it does not justify a new language-layout
feature. Full production acceptance still requires raw C and output metadata
identity, divergent function/global fixtures, duplicate emission rejection,
source module/owner/category invariants and quiet matched frontend measurements.

## Native result

The FRESH compiler was `ff4da4b31dc2-dirty`, pinned compiler
`dev-c3040e79c7d8`, CLI/runtime `-O2`, eight-way split, Apple clang 21.0.0,
normal compiler runtime. `run --memory-stats` built diagnostic produced programs.
The retained [raw result](../benchmarks/results/identity_definition_carrier_probe_2026-10-05.json)
contains compiler/input/generated-C hashes and all 44 observations at
0, 1, 40 and 1000 iterations. Every checksum and active-counter check passed.
Allocations and releases matched exactly at every endpoint.

| Workload | Raw record allocations | Opaque owner control | Mint receipt |
| --- | --- | --- | --- |
| Flat consumer | `2 + 2*n` | `2 + 2*n` | `2 + 2*n` |
| Nested owner | `3 + 2*n` | `3 + 3*n` | `3 + 3*n` |
| Shared old owner | `2 + 2*n` | `2 + 3*n` | `2 + 3*n` |

The scalar-only owner publication and program-only opaque update each stayed at
two allocations, independent of iteration count. The first matrix had a Bool
branch in the opaque loops but not the raw loops; corrected branch-free matched
loops produced the same slopes above. That initial matrix is retained only as
investigation history, not attribution evidence.

Generated C uses one owner type, `brp_ty0*`, with four `long` scalars and a managed
list pointer. Neither opaque view creates a receipt struct. The two issued-id
getters read owner scalar fields directly. However, `minted_owner` retains the
receipt owner, and the caller releases the receipt only after its program update.
The opaque control similarly retains its `from_opaque` representation while
passing the updated owner onward. Those retained aliases force an additional
owner COW publication in the nested/shared consumer shapes. The C evidence is
`/tmp/blorp-identity-authority-2026-10-05/carrier-excerpt.c.txt`; full emitted C and
logs are alongside it. This is an ARC cost, not a new physical wrapper box.

The three privacy probes rejected cross-module conversion, one-sided opaque-owner
update, and an ordinary owner passed to a receipt getter. The exact emitted
messages are in the retained JSON/logs. The before-slice
`negative_graph_raw_frontier.brp` typechecked successfully, establishing the
current independently writable raw-frontier boundary.

Recommendation: reject this shape as the universal nested mint carrier because
it adds one publication per iteration over raw records. Receipt conversion itself
adds no object relative to the opaque owner control. These results do not measure
the proposed read-only `PublishedTypecheckedGraph` use; accepting that separate
publication slice still requires its exact workload, complete frontier provenance
trace and review. No production source changed, no compiler-speed claim is made,
and no source workaround or language-layout feature is proposed from this probe.
