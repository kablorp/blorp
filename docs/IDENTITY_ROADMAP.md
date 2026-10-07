# Identity And Tables Roadmap

Goal: after the compiler resolves a source name, every later phase works on a
typed, compilation-wide identity, and facts that outlive the walk that finds
them live in id-keyed tables published once. Spellings live once in immutable
display tables and are consulted only for diagnostics, dumps, reflection,
foreign and exported ABI, and optional readability of generated C. No later
phase reconstructs semantic identity from a `String`, and no hot path keys a
table by `String` where an id exists.

This is the one live plan for that work: names to ids, retiring magic spellings,
emission by id, value identity through the front end and Core, type identity,
Core node tables and frontend facts. It holds only open work. Completed steps,
measurements and rejected experiments are in Git history and `benchmarks/results/`;
the `scripts/check-magic-spellings.allowlist` and `scripts/compiler-identity-census`
reports are the progress meters. Read [`WORKER_CHECKLIST.md`](WORKER_CHECKLIST.md)
first; its setup, measurement, foreground-gate and landing rules apply.

## Current guarantees and remaining boundaries

The source owners are the authority; the census and allowlist measure migration,
not a second semantic model.

The [2026-10-05 audit](IDENTITY_ROADMAP_AUDIT_2026-10-05.md) pins the inspected
state to `ff4da4b31dc2`. The subsequent
[census reconciliation](../benchmarks/results/compiler_identity_reconciliation_2026-10-05.md)
records the historical drift, retained debt and frozen candidate provenance;
both strict checks now pass through `make hygiene-check`. See
[Strict hygiene](#strict-hygiene) for tooling limits and required invocations.
Recheck this state before each delivery.

| Landed boundary | Remaining work |
| --- | --- |
| Compilation `NameTable`, `ParsedIdentifier.name`, pinned vocabulary ids; call diagnostics and partial lint/dump rendering by table | Semantic lint, builtin source effects, formatter and other `.text` readers; shared table for standalone graphs |
| `TraitId` through headers, bounds, obligations and supertraits | Exact resolved trait targets, lowering and Core trait dispatch |
| `CoreFunction.origin`/module, id-deduplicated mono instances, known-function and runtime callback catalogs | Remove path/name dual carries, complete callback trait/type identity |
| Callable/type/variant/member/closure/task and authored-local C projection by id; `CoreFieldRef` and typed `ResolvedFieldIdentity` | Every synthetic binder gets an authoritative id; nullary references and remaining semantic consumers use it; reuse the field authority |
| `CoreSourceLoc` opaque `Int`, packed module and line/column coordinates; negative pass-minted ids with `minted_origins`, zero synthetic | Verify uniqueness on duplication before node-keyed memoization; preserve source ownership |
| Default discovery node/definition tables, `ModuleId` lookups, per-module header builder, no-meta zonk skip | Propagate discovery's definition authority through the legacy adapter and typed front end |

These are prerequisites, not instructions to repeat completed migrations. The
[interim states](#interim-states-on-main) name the remaining bridges and their
removal owners.

## Principles

**One entity identity.** Every semantic entity is nameable uniquely across one
compilation artifact. A local ordinal, dense row, source-name id or Core-only
counter is not an entity identity by itself. Logically, an entity is
`(domain, owner, domain_key)`, injective within an artifact, and every public id
(`ModuleId`, `DefinitionId`, a resolved value id, `FieldId`, name-site ids, node
ids) has exactly one checked projection into that relation; reordering,
compacting or rebuilding a storage table never changes it. A family may use a
more compact physical form when its domain or owner is implicit in its type, but
no delivery may mint a temporary id that cannot be projected losslessly into
the final relation. The order is: define the relation and its issuing authority;
make every producer issue or preserve an id; propagate ids across phase
boundaries and make consumers authoritative on them; only then delete the
redundant names and name-keyed indexes. Do not use one untyped `Int` for
unrelated domains.

| Identity | Issuer | Meaning |
| --- | --- | --- |
| `ModuleId` | module discovery | one validated module in a graph |
| `NameId` | compilation `NameTable` | one spelling, never one entity: two shadowed locals and two overloads share a spelling and differ in entity |
| `DefinitionId` | discovery, or the checked post-discovery generator | callable, type, constructor, field, global, trait, implementation or generated definition |
| value id | definition projection, binder admission, or Core minting | one definition value or one authored or synthetic local binder, as `(owner definition, domain, key)` |
| name-site ids | source or body occurrence catalog | one identifier occurrence; never a binder target by itself |
| node id | Core construction | one Core expression occurrence |
| `TraitId`, `FieldId`, `TypeId`, `ConstructorId` | the graph's definition index | nominal families |

For values the logical schema is `ResolvedValueId { owner_definition_id, domain, key }`.
The owner is a checked graph definition. The domain separates the definition value
(key 0), an authored local (key from the binder's authored source site) and a
synthetic local (a deterministic owner-scoped minted key). Equality compares the
whole identity. A use token's location, a spelling and a dense row are never
substitutes; two bodies may share an authored site key because their owners
differ; a cloned definition gets a new owner and so a new namespace; copying a
binder inside one owner mints a new key. Constructors and projections live in one
identity module with no public sentinel or domain manipulation, and the
unchecked raw constructor is private to it.
Select the physical scalar carrier by the probes below: `record`, `fixed record`
and an opaque alias over a record do not promise inline or allocation-free storage
([record representation](FIXED_LAYOUT_ROADMAP.md)). The notation specifies identity,
not a new source-level layout contract.

**Strings stop at resolution.** Module discovery issues `ModuleId`s and installs
every module-visible declaration; every declaration has a typed definition id
before any body is inferred; while a body is inferred, each existing
binder-admission site mints the local's id and the existing lexical lookup copies
the binder's id to each use; every later phase consumes ids. A spelling may be
carried temporarily during migration as display or assertion data, never as the
authority. Unresolved lookup, diagnostics and formatting, reflection and explicit
ABI projection are the only string boundaries that remain.

**Normalized tables.** Data that outlives the walk that discovers it is a
logical table with typed keys:

1. One table is authoritative per entity or fact; a consumer's derived index
   stores row numbers or ids and can be rebuilt from the authority.
2. Keys use the narrow typed id of their domain; a spelling, location or
   traversal position is never a substitute once an id exists.
3. One-to-many data is an owner range or edge table; many-to-many is an explicit
   edge table whose key states the cardinality; optional facts for a minority of
   entities are sparse satellite tables, not several `Option` fields on a hot row.
4. Builders are local and uniquely owned; publication freezes columns, ranges and
   derived indexes together, and readers borrow the result.
5. Logical normalization comes before physical layout; measure row records,
   parallel columns and dense or sparse indexes behind one API. Denormalize only
   for a named hot query with retained generated-C and allocation evidence, and
   document the duplicated fact, its authority and the check that keeps it in
   step.
6. **A table holds ids and indices, never declaration or expression bodies.**
   Three attempts to publish indexes of declaration objects (program facts, a
   definition table built inside the per-module lowering loop, and a callable
   facts table) failed for the same reason: a consumer that reads the body pays an
   indexed lookup that costs more than the fused scan it replaced, and the table's
   own build is a fixed cost an id-only consumer does not repay. Do not reopen
   without a consumer whose scan is itself over 1% of its row and is body-free.
   Node-keyed tables built inside one pass that replace repeated walks are a
   different case.
7. A display lookup is legal only at a named display, diagnostic, serialization,
   reflection or ABI boundary; a missing display row is an internal defect with
   the numeric id and provenance, never a fall back to name-based resolution.

**Binding rules** that become strict before strings leave Core: one `DefinitionId`
per source definition, issued by discovery (post-frontend generated definitions
use a shared later allocator in the same relation; typecheck never re-mints a
source definition); one authored-domain key per local binder within its owner;
every local use carries the id lexical resolution chose and never repeats a
scope-chain lookup; every synthetic binding's id is minted by the owning Core
pass; cloning into a new definition remaps the owner, cloning within a definition
uses the synthetic domain and a fresh key; no semantic comparison combines a
spelling with an id; ids are compilation-local and never persisted.

**What must stay as text:** exported entrypoints (`$blorp$program`,
`$blorp$user_main_<id>`), FFI and `builtin("...")` names, `c_identifier` escaping
against the C vocabulary, ABI record member names, static string literal contents,
module file paths and import request strings, diagnostic text, Core JSON field
names. Each lives in a field named for what it is (`c_name`, `abi_name`, `path`).

## Rules for every change

- Follow [Worker Checklist](WORKER_CHECKLIST.md) for setup, serialized gates,
  review and landing, and the
  [self-compile protocol](../benchmarks/README.md#self-compile-measurement-protocol)
  for baseline/candidate provenance. `emit.brp`, `lower.brp`, `infer.brp` and
  `match_projection.brp` each have one owner during overlapping slices.
- Replaced data is deleted in the same commit: a String that only carries what an
  id already carries does not survive the step that adds the id. Add the fact
  beside the name first, move readers one family at a time, delete the name last.
  Every migrated consumer reads exactly one path and never falls back from id to
  name.
- Start each slice with its failing identity test and exact family census.
  Name the old/new authority, deleted lookup/copy/fallback, logical schema,
  acceptance and stop conditions; probe an unknown representation before edits.
- Numeric workloads and expected gains below are historical measurements or
  hypotheses. Remeasure the current boundary before reopening an experiment;
  shorter source or generated C alone does not establish a compiler-resource win.
- **Identity oracles.** Byte-identical generated C until output spelling changes
  (`benchmarks/self_compile_measure --stage2 --require-identical` against a parent
  frozen at the branch base, on `--program self` and `--program small`, plus the
  owning suites). For id-derived symbols, normalized C
  (`benchmarks/normalize_generated_c_symbols`; `--project-locals` where no
  sidecar exists, a strictly weaker oracle) plus `scripts/test runtime`,
  `scripts/test leak`, `scripts/test compiler-core-sanitize` and the codegen audit
  with `EXPECT-C-REGEX` for projected families. Exact diagnostic, reflection and
  formatter output. `--dump-core` JSON compared with `cmp` where its schema is
  unchanged. Use stage 2 on both sides for any change whose benefit depends on
  generated-C or runtime representation, and never compare stage 1 with stage 2.
- **Budget.** A performance cut is kept only with mechanism-matched evidence. A
  flat correctness or enabling cut may land if it regresses neither retired
  instructions nor allocations by more than 0.5% across matched samples; the
  budget is not a licence to compound it, and a neutral enabling cut names the
  paying consumer in the same wave. Key replacement alone does not allocate less
  (dictionary probes do not allocate); claim instructions, not allocations, for
  it. Wall time is never the evidence.
- **Stop and redesign** when a second permanent string and id representation
  appears instead of replacing the first; a display lookup enters a per-node hot
  loop; an immutable catalog field adds retain or release traffic to every
  recursive call or pass-state update; an id is inferred from a string prefix,
  hash, formatting or pointer; a pass rescans the program to find a frontier that
  should have been carried; a dense list must allocate in proportion to a sparse
  id range; C differs before the named projection step without a regression test
  explaining why; diagnostics lose provenance; or a compatibility wrapper has no
  scheduled deletion. A negative experiment is valid evidence: record it and keep
  the prior authoritative path.
- Machinery cleanups that neither move a name to an id nor shrink emission wait
  until the name and emission work is done.

## Names

The remaining name-to-id work. Every step is semantics-preserving and gated by
byte-identical C unless it says otherwise.

### Builtin and intrinsic vocabularies by id

The source-name vocabularies (`builtin_special_inference`, the compile-time
intrinsic tables) are keyed by `NameId`. What remains:

- **Effect table, source half.** `builtin_runtime_effect` in
  `type_system/builtins.brp` has 127 String arms: 48 are runtime ABI names
  (`blorp_tcp_read_raw`) and 79 are source names (`print`, `yield_now`). Convert
  the 79 source-name arms once their readers hold the identity at the typecheck
  effect sites (`ResolvedCallInfo.source_name_id` already exists).
- **`core_builtin_name`** and `prelude_builtin_name` in
  `stage_09_core/builtin_registry.brp` (about 126 arms plus 14 module tables;
  the values are `blorp_*` runtime names and stay Strings): needs `CoreVar` to
  carry its declaration's `NameId`, or resolution through `CoreFunction.origin`
  where a declaration exists. The registry also serves sentinels that have no
  declaration to read an origin from. Do last. It retires `builtin_is_registered`'s
  `synthesized_name_id(name)` lookup.
- **Runtime operation ids.** `IntrinsicCall(String)` and `BuiltinCall(String)`
  carry runtime and compiler-internal operation names, and `ownership.brp` (about
  190 contract arms) plus the 48 ABI arms of the effect table key on them. They are
  not identifiers and must not become `NameId`s: they become a closed enum or id of
  runtime operations, written where the call kind is created (lowering, synthesis,
  backend projection), with the ABI spelling kept in one named field for the
  emitter; the C symbol for a runtime operation is then computed from the id.
  Not started. It changes the payload of `CoreCallKind.BuiltinCall` and
  `IntrinsicCall`, so it touches every pass that matches those kinds; adjacent to
  "Emission by id".

Strings kept beside ids until these land (see "Interim states"):
`ResolvedCallInfo.callee_name` and `.source_name`, `TraitMethodCallee.source_name`
and `.method_name`, `CtfeIrDirectCall.source_name`,
`AcceptedCallableBinding.source_name`, and the String arms the two registries
still key on. Their deletion is a separate step after the readers move.

### Trait identity through typecheck and Core

A trait's identity is `TraitId`; `NameId` is the wrong identity (spelling, not
declaration). The header graph and the environment, obligations and supertraits
carry it. What remains, in order:

1. **Resolved call targets**, `TraitMethodCallee` and `trait_functions` by `TraitId`;
   retires the spelling-only entry points (`accepted_trait_id_for_spelling`,
   `accepted_find_impl_method_info`, `accepted_trait_find_method`, the
   `env_find_*` and `env_trait_*` by-name walks, the by-name obligation built for
   calls resolved only by trait spelling) and the linear scan in
   `env_get_trait_by_id` (use a catalog lookup by id). Gate: typecheck stage;
   identical C; message fixtures.
2. **Typed trait and impl info carries `TraitId` for lowering**; the entrypoint
   check takes `ExitStatusAble` by id from the standard-library declaration
   instead of `typecheck_find_trait(state, EXIT_STATUS_TRAIT_NAME)`;
   `find_prelude_trait_decl` reads the definition table's prelude-traits module
   id instead of deriving "is the prelude traits module" from an importable
   module's origin, path and name; `BoundTypeParam.bounds` Strings (remaining
   readers: typed AST JSON, the empty-bounds test in `infer.brp`,
   `bound_type_param_to_parser_string`, Core lowering and Core JSON) are deleted
   in favour of bound identities. Gate: Core suites.
3. **Core by id.** Impl and trait decls, trait calls, DCE keys, `synth_scalar_operator`
   and `trait_dispatch` literals by id; a trait catalog for display; retire
   `CoreImplMethodRole` (callback roles become pinned `(TraitId, NameId)` pairs
   and the enum, `impl_method_role` and the `NAME_ID_*` callback constants go).
   Gate: `compiler-core-sanitize`; backend identity.

### Diagnostics, dumps and the formatter through the name table

Table-based identifier rendering is partly landed in diagnostics, lint, AST JSON
and frontend summaries. Remaining readers must be classified as semantic lookup,
copy or display before deletion; the following inventory is not a completeness
proof:

- **Formatter** (about 500 `.text` reads in `blorp/src/format/`). Own branch,
  after the formatter has a settled table parameter; the oracle is formatter
  idempotence and `bin/blorp format --check blorp/src standard_library/src`. The
  formatter must keep operating on source text and the recovery AST alone, never
  depending on a typecheck graph.
- Remaining `.text` reads: semantic lint retains readers alongside its table
  renderer. Preserve the owning diagnostic tests.
  The CTFE IR has 13 matching lines (bindings, assignment targets and some semantic
  lookups), and `typed_ast_json.brp` has 2 key comparisons;
  type header resolution's `.text` lookups (`declared_unqualified_type`,
  `type_header_graph_has_unqualified_type_name`, `resolve_named_type`) kept beside
  `identifier.name` for import, alias and parameter lookups keyed by String; the
  one LSP identifier use (`name_spelling_of_text` in `semantic_index.brp`).

### Identifier text becomes the id

Flip `ParsedIdentifier.text` to the stringified id and delete the `.text` readers;
then convert String to `Int` one record family per commit (`CoreVar.name`, function
names, field and variant spellings, type names). Preconditions: the builtin
vocabularies, magic-spelling retirement and formatter steps above, and the
standalone-graph precondition (standalone graphs, `graph_source_name_table_for_programs`,
currently give identifiers ids from private per-program tables and render with
`.text` only; they must share the discovery table). Gate: identical C. It also
settles body-environment lexical lookup: the unresolved lookup key stays `String`
until the one documented projection between lexer text and `NameId` exists, and
the last local-string key path is converted with it.

The census counter `typed_name_identity.brp` (`BLORP_NAME_IDENTITY`) counts
`.text` and id mismatches and is deleted when `.text` is gone. Once the downstream
frontier is id-only, the strict hygiene check (see "Strict hygiene") also rejects
`Dict[String, ...]` for semantic entities in migrated directories, direct `.name`
semantic comparisons in Core and the backend, display-name accessors outside
allowlisted boundaries, binder constructors that do not receive or mint identity,
and backend predicates that recognize semantics from a source spelling.

### Parser-minted versus inference-minted binder ids

Define the stability contract before selecting the authored issuer. Ids must be
deterministic for identical input; rebuilds preserve them and clones obey the
owner/key remapping rules below. Fixtures pin them against frozen input.
Stability across edits to earlier source
is a separate incremental-identity requirement: counters, source offsets and
discovery row ids do not establish it, and compilation-local ids are not persisted.
Do not add persistent identity machinery just to stabilize fixture numbers.
Two designs are on file and have to be reconciled before either starts:
a per-module counter id minted by the parser and carried on the pattern node
(replacing lowering's span-derived positive ids; gate: identical C up to local
spellings, normalized oracle identical, audit fixtures), and an id minted at the
existing inference binder-admission site from the checked body owner and the
binder's source site ("Authored locals", below). The discovery stage now stamps
node ids on its own tables, which may make the first cheaper than it was. Decide
which authority mints, and delete the other, before opening either step.

## Retiring magic spellings

No reader learns a fact from the shape of a String: every fact a prefix, suffix,
marker or embedded number carries lives in a record field, an enum or an id.
The inventory by family is `benchmarks/results/magic_spelling_census_2026-09-28.md`;
`scripts/check-magic-spellings.allowlist` (hooked into `make hygiene-check`) is the
meter, and a step is complete when the allowlist entries it owns are deleted,
`make hygiene-check` passes and the generated C is byte-identical. The gate for
every step is the owning suites, `scripts/compiler-check --changed` and the
identical-C measurement, plus the allowlist delta the step names.

### Function names and module origins

- **Module origin as an id only.** Delete `CoreFunction.source_module` and
  `CoreGlobal.source_module`. A global needs a module origin of its own first
  (`CoreGlobal` carries only the path String, and a function hoisted out of a
  global initializer is `NoSourceModule` because of it); the module table is
  threaded through every Core pass state, `CoreDeclarationIndex.modules`,
  `prepared_core_program_module_table` and `CoreStandardModules`, so readers
  compare ids and render paths from the table; passes that spell flattened
  names from the path take them from `origin` or the table; `--dump-core` and
  diagnostics render the path from the table. `CoreKnownFunction` then
  recognizes a function by `ModuleId` plus `NameId` and only
  `known_functions.brp` changes. Also deletes
  `ModuleOrigin` beside the `ModuleId` in `SourceModule` once a table handle exists.
- **Builtin prefix tests as registry rows.** `blorp_filter_map_parallel*`,
  `blorp_vector_get_opt_*` and `blorp_dict_get*` prefix tests in
  `backend_projection.brp`, `specialize.brp` and `specialize_collection.brp`
  become `BuiltinFamily` rows of the builtin registry (4 allowlist lines remain).
- **Every call site reaches `resolve` with its callee's definition id.** Lowering
  gives each call site a def id; this retires `dce.brp`'s `function_ids_by_name`
  (before `resolve` runs, a function-typed `UnknownCall` callee names its target
  by spelling only, and the early prunes root it through that index), and
  `resolve.brp`'s `foreign_functions`, `builtin_functions` and `user_call_by_name`
  (they answer call sites that carry only a spelling: an unresolved `VarExpr`
  callee, a `SelectedDirectCall` whose id has no target). The UFCS alias names
  (`__ufcs_...`) become a lowering-owned fact instead of a spelling; `flatten.brp`
  and `c_symbol_projection.brp` work by definition id. `trait_resolve.brp` keys on
  trait, method and type spellings and moves with "Trait identity".
- **Data-type instance identity.** `mangle_generic_data_name` (`Pair__mono_Int`)
  stops being a marked String: the instance type carries its base type and
  arguments (`mono_data.brp`, `mono_impl.brp`, `mono.brp`, `identity.brp`). The
  same work as the qualified type name steps below, done once.
- **Delete the producers.** `MONO_NAME_MARKER`, `CORE_PURE_OVERLOAD_SUFFIX`,
  `CORE_MODULE_NAME_SEPARATOR`, the UFCS prefix constants (`core_ufcs_function_name`
  in `identity.brp`, `lower.brp`, `graph_prepare.brp`, flatten's alias names, the
  two pipeline prefix literals; no reader decodes them any more), the closure
  prefixes, the agreement invariant (`origin_name_agreement.brp`,
  `BLORP_ORIGIN_CONTRACT`) and `fixture_member_spelling`. `CoreFunction.name` is
  then written from one display renderer `core_function_display_name(origin, names)`
  used only by diagnostics, invariants and `--dump-core`. Then `CoreFunction.name`
  becomes `NameId` or is deleted where `origin` renders it, and `--dump-core` joins
  the name table (the function half of "Identifier text becomes the id").
- **Origin payloads that hold a `CoreType`** go stale when flatten renames types;
  write them after flatten, as `ProjectedImplMethod` and `MonoInstance` are, or use
  type ids. `ImplMethod(trait NameId, method NameId)` still lacks impl and trait
  definition ids and a type key, and hoist ordinals are program-wide; the runtime
  callback table is keyed by the rendered `core_trait_impl_type_key` String until
  types have ids.

### Binders

`CoreVar.origin: CoreBinderOrigin` currently has `AuthoredBinder`,
`LoweringTemporary(kind)`, `PassTemporary(kind, Int)`, `PerceusTemporary(kind, Int)`,
`PerceusBorrowedResultTemporary(kind, Int, Int)` and `DerivedFrom(String, kind, Int)`.
The derived String is an anchor key; authored origin does not carry a `NameId`.
Perceus and closure-drop temporaries already carry an id and origin.
Remaining:

- Stop building the `$blorp$...`, `__cdrop_`, `__perceus_shadow_`, `__qb_`,
  `__td_`, `__loop_`, `__timeout_`, `__pattern_param_` and `__record_update_`
  spellings; a Perceus or derived temporary's name is still its C spelling, built
  once at creation (`perceus_temporary_spelling`, `derived_temporary_spelling`).
  Gate: the allowlist families for binders (about 22 and 9 producers).
- Delete `c_local_name` and its escape branches, `is_compact_temp_c_name`,
  `COMPILER_LOCAL_PREFIX` and `__blorp_internal_`; `c_field_name` keeps
  `__blorp_field_` for ABI records only. Needs every pass to mint ids, so it
  follows "Synthetic binders".
- `__nested_<parent>_<name>_<id>` (`source_ast_finalize.brp`) becomes
  `ParsedFunctionOrigin.NestedIn(parent_def)` with a fresh definition id.

### Types

- **Payload `CoreType` for stack-option and storage representations.** Payload
  `CoreType` in `CoreStackOptionRepresentation`, `StructBox`, the inline-struct
  and boxed-element storage variants; the emitter renders the C type; delete
  `resolved_stack_option_type_name`, `resolved_inline_struct_c_type`,
  `resolved_boxed_element_c_type` and the nine copies of the `blorp_StackOption_`
  spelling (`blorp_StackResult` is an ABI constant and stays; census in
  `benchmarks/results/name_string_catalog_2026-09-28.md`). The
  `StackOption*ConstructorTest(String)` variants in `match_projection.brp` carry
  the type. Files: `c_type_layout.brp`, `list_layout.brp`, `prepare.brp`,
  `collection_pipeline.brp`, `specialize_collection.brp`, `specialize_layout.brp`,
  `synth_list.brp`, `match_projection.brp`, `emit.brp`.
- Packed-enum `to_string` becomes a `CoreCallKind` case carrying the enum type; the
  `_f64`/`_f32` width becomes a field of the checked-get call.
- **Dimension sigil.** Route `mono.brp`'s dimension handling through the kind, then
  delete `type_parameter_name_kind`'s sigil read once `List[String]` type-parameter
  lists carry kinds.
- **Tuple field access** parsed as `NamedField(NameId) | TupleIndex(Int)` by the
  parser; the five decimal readers (`infer.brp`, CTFE `ir.brp`, `lower.brp`, the
  formatter) go.
- **Qualified type names.** See "Qualified type names" under "Type identity".

### Emitter temporaries

The 169 `__x_<seed>` emitter temporaries (`emit.brp`, `prepared_*_renderer.brp`)
use the existing compact temp scheme driven by an `EmitterTempKind` enum;
`is_generated_temp_value` becomes an explicit field set where the temp is created.

## Emission by id

Emission spells symbols from definition and binder ids, so the generated C
shrinks. These steps change C by design and are gated by the codegen audit, the
runtime and leak gates, and the normalized-C oracle showing only spellings
changed; report emitted C bytes before and after. Done: callables, types,
variants (self-compile C -9.04%), non-ABI record members (`f<ordinal>`; ABI
records keep source names), closures and tasks, and locals with a binder id
(-1.56%).

- **Binder ids in every pass that created binders with id 0.** Perceus and
  closure-drop temporaries mint ids. Still id 0 with a `PassTemporary` or
  `LoweringTemporary` origin: the `synth_*` passes (`synth_list` builds its
  `Some(__value)` pattern binder at id 0; `run_synth_pass` does not thread
  `next_binder_id`), `specialize_collection`, `consume_specialize`,
  `match_projection`, `mono_option`, `record_update`, `ssa`, `tailrec`,
  `tensor_specialize`, `parallel_tensor_pipeline`, and the
  tuple-destruct temporary in lowering (about 402k binder occurrences carried a
  synthetic spelling for this reason when last counted). `next_binder_id` is the
  legacy frontier. This is the same work as "Synthetic binders" under value
  identity: every future producer uses the checked owner/domain/key mint and remap
  API, never a direct counter. Cloning remaps introduced binders and their uses;
  packed locations alone cannot establish uniqueness. Preserve legacy emission
  ids and spellings during the raw-C-identical transition, then delete the id-0
  spelling fallbacks in the separate emission slice after coverage is complete.
- **Variant constructor references by id alone.** A nullary constructor's
  `VarExpr` name is rewritten to its projected symbol in `backend_projection.brp`
  (`indexed_constructor_c_name`) and matched by that spelling or the source name in
  `closure.brp` (`capture_constructor_definitions`) and `perceus/env.brp`, each
  recomputing `variant_constructor_symbol(def_id)`; recognise a constructor
  `VarExpr` by `def_id` alone and let emission spell it. `operation_metadata.brp`
  finds the declared variant of a runtime error or payload union by case name
  (`declared_variant_lookup`) because the operation specs name their cases; key the
  specs by variant id. The variant reuse helper name is unchanged (shortening it is
  a separate change).
- **Record field names** still carried beside the ref (`FieldExpr`,
  `CoreRecordFieldValue`, record-field decls, `CowFieldTakeRetainPolicy`), read
  only by the ABI branch and diagnostics, become display-only with "Identifier text
  becomes the id".
- **Emitted value symbols from identity.** See "Emitted value symbols" under value
  identity.
- `c_naming.brp` imports `ir.brp` for `CoreBinderOrigin`, so a program importing
  `c_naming` carries the module table's foreign header (the codegen audit adds
  `-I blorp/src/compiler/stage_04_modules`); split `c_naming` from the origin type
  or stop the spelling functions reading `CoreVar`.

## Value identity through the front end and Core

The plan for the identity relation above, applied to values, with the thin-spine
approach: mint authoritative ids at the earliest phase that can know the entity,
propagate them to C emission while strings still exist as a checked compatibility
representation, make emission and late Core consume ids, then move backward one
phase boundary at a time, deleting strings and name-keyed indexes only after every
consumer on the later side has moved. Do not start by deleting strings from
parsing or typechecking, and do not start at emission alone.

Delivered as short vertical slices: each is landable only if it removes a repeated
lookup, string comparison, allocation or ARC path, replaces a name-based semantic
decision with a checked id decision, makes an invariant strict for another
producer or consumer family, adds an oracle or ratchet that catches a regression,
or deletes a compatibility path. An API, field or table with no active consumer is
not a delivery; production scaffolding lands in the same short integration train as
its first consumer. After each landing the remaining workers rebase before final
measurement, and a cumulative result from the green start is kept so a series of
neutral cuts cannot hide a material regression.

### Rejected designs (do not repeat)

- **A pre-inference body resolver** (a per-body syntax census, semantic work tape
  and freeze step before normal inference) was identical in C and diagnostics but
  added 4.03M typed-frontend allocations (+18.55%) and 2.59% retired instructions;
  the resolver-only fixture measured 27/56/182 allocations for 0/1/40 binders. Do
  not split out its unused tables: the active-consumer rule forbids it.
- **Parallel typed variants** (three new `TypedExpr` variants beside the legacy
  ones for migrated names, assignments and declarations) grew to 1,035 insertions
  across 13 files for one narrow slice, needed duplicate arms in every typed
  traversal, CTFE adapter, JSON renderer, inventory and lowering match, and the
  candidate then failed a basic test. Extend the existing narrow payload with a
  fixed-layout identity, or replace its positional fields with one small record,
  and accept the representation only if generated C shows no per-node boxing and no
  second semantic arm in any traversal. If no carrier meets the limits, stop after
  the definition-authority step instead of forcing local propagation.

### Definition authority

- **Separate output numbering from semantic identity.** `def_id` is both semantic
  identity and an observable output ordinal (symbols, ordering and binning,
  comments, symbol maps, profile correlation), so discovery source order cannot
  replace it without changing raw C and every later generated id. Introduce a
  checked scalar `EmissionCompatibilityId` at Core declaration and program and
  backend candidate boundaries (semantic maps stay keyed by semantic id; only
  rendering, ordering and correlation read the compatibility id), carried only on
  declarations with a named output consumer (`CoreFunction`; `CoreGlobal` for
  owner-derived match-projection and option-fusion temporary names; never
  `CoreVar` or recursive pass contexts). Then split the generated-definition
  frontier into `next_semantic_definition_id` and `next_emission_compatibility_id`,
  every Stage 8 and 9 mint consuming both exactly once through one pair-mint API,
  initially in lockstep. Before editing producers, choose and probe how the API
  returns or publishes both results without a new heap record or tuple: scalar
  fields in an existing owner or a checked scalar handle are candidates, not
  selected representations. Prove atomic frontier advancement, lossless identity
  projection and nested ownership behavior in generated C; a `fixed record` or
  opaque-over-record spelling alone proves none of them. If no supported carrier
  meets the cost gates, stop and redesign this slice. The
  [2026-10-05 carrier probe](IDENTITY_DEFINITION_AUTHORITY_PROBE.md#native-result)
  rejects the proposed nested/shared opaque-owner calling shape: retained aliases
  add one owner allocation per iteration over matched raw controls, despite a
  neutral receipt/control comparison. A replacement needs the same nested and
  shared oracles before producer migration. Publish the semantic frontier with
  its exact Stage 6 table authority. A checked whole-graph publication may first
  remove the independent raw Core join; distinct scalar frontier types belong at
  the semantic/output split where they prevent wrong-domain use. Do not add an
  unused token accessor or retype ordinary tooling views for nominal proof alone.
  Production code never proves a frontier by
  looking up `next_def_id - 1` or scanning Core. Oracle: raw-identical C, symbol
  maps, comments, split ordering and profile metadata; divergent semantic and
  emission fixtures for both the function and global paths; symbol projection
  rejects duplicate compatibility ids. Stop if compatibility ids enter semantic
  equality, lookup, dispatch or diagnostics, or if any producer can advance only
  one frontier.
- **Discovery issues source-definition ids; Stage 6 adopts them.** The discovery
  stage already mints `DefinitionId`s, but the legacy adapter does not pass them on
  (the old parsed AST carries none) and typecheck's graph-time definition index
  still mints its own. Moving the final-form `DefinitionId` primitive to a
  phase-neutral module, publishing the ordered source-definition catalog as
  normalized per-module columns (kinds, visibilities, owner indexes, locator kinds,
  declaration and child indexes, spans, display names; one equal-length invariant;
  named absent-index constants; no per-definition record or locator union),
  adopting it in the definition index, indexed graph, prepared module scopes and
  header builders, and deleting the graph-time source-definition mint and
  enumeration path land as one production delivery coordinated with
  [`DISCOVERY_ACCEPTANCE_ROADMAP.md`](DISCOVERY_ACCEPTANCE_ROADMAP.md)'s adapter
  shrinkage. Reserved builtins and post-frontend generated definitions keep
  explicit disjoint authorities; standalone compilation owns a small
  artifact-local catalog builder (callers never supply a raw integer); inherited
  default-method projections use the checked post-discovery generator. The old
  enumerator is not kept as a shadow verifier. Define and test the source-category,
  child/owner and module-issuer mapping before adoption, including inherited
  defaults, overloads, builtins, standalone catalogs and mismatched tables.
  Discovery row order differs from Stage 6 target/dependency reservations: semantic
  ids adopt discovery authority while compatibility ids preserve existing output
  order. Oracle: raw-identical C, diagnostics and import behavior; checked source
  identity mapping and compatibility ordering; discovery plus typed frontend flat
  or better; one source-definition authority after landing. This slice uses the
  raw-C oracle even where the discovery roadmap permits normalized ids.
- **Rows and frontiers.** A frozen source table has its own checked contiguous
  slice and base; only within that slice may a row index be `definition_id - base`.
  `definition_index_advance_to_env` already permits generated/body-local allocation
  frontiers beyond source rows without creating rows. Keep generated allocation
  frontiers, generated-overlay rows and current-program views distinct; retained
  declarations need not occupy every allocated id. Sparse views use explicit dense
  id-to-row maps, never a list sized to a sparse maximum or a `next_id - 1` proof.

### Authored locals

Mint at the existing inference binder-admission site and reuse the lexical walk
inference already performs. The checked graph definition table projects the body
owner, which is installed in the inference session; each admission derives
`ResolvedValueId(owner, authored domain, binder_site_key)` and stores it beside the
`VarSymbol`; lexical lookup stays the one authority for shadowing, and once it
chooses a binding it copies that exact id into the typed name or assignment
payload; refinement preserves the id, shadowing mints a new one. Authored binder
site constructors are private to the identity authority and validate a real
authored `SourceLocation`; a recovery or compiler-prelude binder that cannot prove
its inputs stays on an explicit legacy path and never fabricates an id. Do not put
growing identity columns in the threaded inference context (repeated COW); the hot
path carries only fixed-layout scalar identity on the relevant symbol or node.

Slices: one complete binder family first (named parameters or straight let and var
bindings, chosen by a carrier representation probe that rejects `Option` or union
payload boxing), consumed directly in lowering with its use and assignment shapes
so one lowering lookup is deleted; then the other of the two; then lambda
parameters, tuple destructures, blocks and loop binders; then match patterns,
question-bind, select, concurrent and with/resource binders. After the last, delete
lowering's scope and name walk (`CoreLowerScopeEntry { name, id }`,
`resolve_local_id`). Tests: a binder at source offset zero, two same-spelled
bindings with distinct owners, parameter shadowing, a mutable binding plus
assignment, refinement, a function-valued local call, one unmigrated binder
exercising only the legacy arm; every use of a binding carries the same complete
id and shadowed binders differ. Fast loop: identity unit test, focused Stage 6 and
Stage 8 fixtures, `scripts/compiler-check --stage typecheck`, `--stop-after=lower`
Core JSON `cmp` against the parent for the first self-compile comparison; count
direct-id and legacy lowering paths (the direct count rises, the fallback falls).
Oracle: C, diagnostics and formatter output identical; no per-use `Option`, tuple,
record or collection allocation; allocations and instructions within 0.5%, no
full-body traversal and no growing collection in the inference session. Until the
spans are removed from the id, `core_binder_id` and `core_question_bind_var` derive
ids from the construct's span start (start offsets must stay below 2^31).

Normalized publication of name-site and binding tables
(`NameUseSite(name_site_id, location)`,
`ResolvedValueUse(name_site_id, value_id)`,
`AuthoredBindingDisplay(value_id, source_name_id, location)`) may return only when
a named paying consumer exists, built as graph-wide or batch parallel columns after
typed bodies exist; a dense row key is never the value id. The first scalar spine
does not build a per-body census merely to prepare for those tables. Their later
delivery must define the authority and transfer contract below and delete a named
lookup rather than add a second target resolver.

### Core carrier

Extend the typed spine so every successful local inference result exposes its
value id, then carry it to Core without making every producer supply one at once:
a tagged inline transition (`TransitionalValueIdentity`, an enum state plus the
three raw scalars; a pending constructor for not-yet-migrated producers, a resolved
one requiring a checked id, private smart constructors only; no `Option` or wrapper
allocation) on `CoreVar` beside the legacy `name`, `id` and `def_id`; versioned Core
JSON with an explicit `identity_state` (compared with a tested
`benchmarks/compare_core_identity_transition` tool that proves the legacy fields
match the parent and validates tags, pairs, the pending and resolved census and the
round trip). Land the carrier, the typed spine and the lowering switch as one atomic
train (do not expose a main revision in which every Core variable carries unused
transition state). Lowering: graph preparation initializes a uniquely owned
identity build state from the frozen definition table and the authored identity
facts, kept at the module and declaration orchestration loop; never put the managed
state in the recursive expression-lowering context. `CoreLowerContext.next_def_id`
goes; a declaration lacking a graph id gets a minted `DefinitionValueId` from the
orchestration loop before lowering. `CorePreparedGraph { program, next_def_id }`
becomes `{ program, identity }`, and standalone Core tests use a checked fixture
constructor. Acceptance: zero string-keyed local resolution in lowering, zero
authored or definition-valued `CoreVar` pending, every remaining pending site in an
exact synthetic-constructor census, no regression above 0.5%. A constructor census
test fails when any `CoreVar` initializer bypasses a smart constructor.

### Synthetic binders

Make one persistent identity authority the owner on the pass state: it holds the
definition frontier, each executable owner's synthetic-key frontier (starts at one;
non-body rows hold zero and reject local minting), and the generated-definition and
synthetic-binding display rows. It replaces `CorePassState.next_def_id`; every
state-reconstruction adapter and the early-to-late handoff carries it; no pass
increments a counter directly or rescans functions to recover a frontier. The three
operations are `mint_generated_definition`, `mint_local_value` and
`state_with_program`; helpers may own and update the state locally but return the
whole state. Choose the carrier by probe (frontiers and catalogs directly in the
record, a small frontier record plus one nested immutable catalog, or flat parallel
columns): it must add no per-pass allocation and no material retain or release
traffic to ordinary program-only state updates; if none does, stop and redesign the
carrier rather than add a parallel catalog and pass-local allocator.

Cloning is driven by binder introduction, never by rewriting every matching name:

| Operation | Locally bound values | Free or global values | Capture slots | Recursive reference |
| --- | --- | --- | --- | --- |
| structural rebuild | preserve | preserve | preserve | preserve |
| duplicate subtree in one owner | freshen each binder and its uses | preserve | n/a | preserve unless retargeted |
| inline callee into caller | freshen params and locals under the caller, remap uses | preserve | arguments use caller ids | per the inliner |
| clone or specialize function | rehome under the new definition | preserve | preserve until closure conversion | retarget through the definition map |
| extract or lift closure | rehome binders of the extracted body | preserve until captured | mint one fresh parameter per capture, rewrite captured uses | per the extraction policy |

Two clones of one function share neither definition nor local ids; a capture slot is
distinct from the value it carries. Use match lowering as the first producer pilot,
then standard inlining, SSA and tail recursion, specialization and synthesis,
Perceus, and closure conversion, one family per merge in that risk order (they may
be developed in parallel after the mint and remap API freezes). A pass may not
fabricate uniqueness in a name such as `"__tmp_" + counter`. `direct_constructor_payload`
recognises a discarded payload by the name `_` on a `NamePattern`; lowering emits
`WildcardPattern` for `_` name patterns and the name test goes. When the pending
count reaches zero, make the id required on `CoreVar`, version Core JSON to the final
fixed-layout form, and make the report-only binder-identity check validate exact ids
and lexical binder and use consistency, strict by default once the frozen
self-compile reports zero violations after every pass. Tests: per-pass clone and
freshen cases, two clones of one function, repeated synthetic construction in one
owner, closure extraction, the same authored key under two owners, free-variable
preservation, capture-slot distinction, recursive clone retargeting, a missing
display row, a pipeline test in which two passes mint binders in one original
function (the second receives a higher key without a rescan) and one where the first
pass creates a definition that the later pass adds a binder to (both overlay rows
survive the handoff). Oracle: C byte-identical while names still drive output;
strict invariant and pending counts zero.

### Emitted value symbols

Callable projection is already id-keyed. Before extending the rule to globals and
locals, prove complete declaration and reference coverage for one family and
measure an actual repeated construction or lookup that a table removes: for ordinary
names `c_local_name` returns the existing string without allocation, so a new table
adds storage and lookups; if the zero-allocation fast path remains, retain direct
rendering and proceed with the upstream identity work instead. The shared
`c_var_name` path serves locals and cleanup helpers, so a present id must be
validated against the declared name and an unresolved reference never mistaken for a
local; final Core defines local occurrence identity as `(name, id)` until synthetic
binders are complete. Extend the normalizer first to canonicalize the old and
proposed local families (`brp_v<owner>_a<key>`, `brp_v<owner>_s<key>`), with paired
fixtures where old and new spellings normalize identically and where a collision,
missing occurrence, declaration and reference mismatch or structural change does not.
Two cuts: an id-keyed emission table reproducing today's spellings (raw C identical,
direct renderer name projection deleted), then ordinary rows become id-derived
symbols (`brp_g<definition-id>`, `brp_v<owner>_a<key>`, `brp_v<owner>_s<key>`;
normalized C and runtime behavior are the oracle). Model symbol policy as two
domains (a value symbol table with an `EmittedValueSymbolPolicy`: derived, foreign,
exported, platform entrypoint; a builtin symbol table with its own policy; builtins
are never fabricated value ids), decided once per id, with explicit exceptions for
foreign C names, exported ABI symbols, runtime-mandated builtin symbols, `main` and
reflection whose result is a source name. Compare a dense id-indexed symbol column
with direct rendering from the fixed-layout id and keep the table only if it repays
its strings and capacity. Both performance comparisons use stage-2 compilers.
Acceptance: no ordinary callable, global or local output symbol depends on a source
string, all access by id, the chosen representation better or flat on instructions
and allocations, backend pass row not regressed. Tests: same-spelled locals,
reserved C words, compiler-generated prefixes, two modules with one declaration name,
every ABI exception, split-C emission, symbol-map and profile rendering.

### Backend semantic decisions

Classify every backend `.name`, string literal comparison and name-keyed dictionary
as identity (replace with `DefinitionId`, a value id, `TypeId` or a member id),
intrinsic or runtime policy (resolve upstream into an explicit call or policy
variant), display (use the display table at the rendering boundary), foreign or
exported ABI (retain an explicit spelling fact), a template-local C temporary or
user data (leave). Convert value and callable decisions whose exact definition ids
already exist, one decision family per commit; the cut introducing a resolved variant
deletes the old spelling predicate and fallback in the same change. Named types and
members are classified and deferred to "Nominal types and members". Oracle: raw or
normalized-identical C according to whether spelling changes; exact runtime and
diagnostic behavior; no unclassified backend semantic name read in the census.

### Late-Core consumers by exact id

Remove operational dependence on compatibility `CoreVar.name`, `.id` and `.def_id`.
Land final preparation, cancellation plans and backend projection first (they own the
shared projection seam); then, one family per cut in this risk order: closure
capture and free-variable sets; Perceus ownership-use, borrowed-owner, mutable and
repeated-consume catalogs (`PerceusResolvedValueIndex` is keyed by the transitional
`(id, def_id)` pair; its collision fixtures prove neither component suffices alone);
reuse and field-take alias catalogs; DCE value and reachability indexes; match
projection and tail-recursion helpers; specialization, synthesis, mono and earlier
Core rewrites. For each: replace private equality with value-id equality, name-keyed
exact-variable collections with id-keyed ones, keep name-keyed declaration overload
groups only until exact definition selection moves upstream, remove name-only
fallbacks (leave unsupported-expression fallbacks and count them separately), add a
shadowing test that gives the wrong answer under name equality. Publish closure
capture as an edge table (`closure_definition_id`, `capture_slot`,
`captured_value_id`; dense ABI-significant slots, display name joined only for
diagnostics) rather than copying the captured variable into each consumer; Perceus,
DCE and reuse tables key their narrow decision fact by value id or an explicit edge
key, never owning a second variable catalog, and a relation two consumers need is
published once by the pass that owns the decision. Dictionary-to-dense-list is a
separate measured choice: use a dense list only when ids are compact in that
consumer, otherwise the exact typed id key if the standard dictionary supports it or
a nested owner, domain and key index, never a flattened magic integer. Oracle:
byte-identical C (a changed answer is retained only when a test proves the old name
result wrong); report phase rows and string hash and equality counters, and promise
no allocation saving from key replacement alone. For the Perceus resolved-value
index, preserve the three collision and occurrence-count fixture families in
`test_core_perceus.brp`: byte-identical self/small C, no increase in
`pass_perceus_complete` or total allocations, and at most +0.3% retired
instructions. These stricter slice gates override the general 0.5% budget.
If counters do not show paying index work, describe the cut as semantic cleanup,
with no speed claim.

### Delete strings from Core variables

Start gate: the late-Core consumer cuts are complete, strict identity is green,
emission is id-derived, and the final census finds no semantic `CoreVar.name`, `.id`
or `.def_id` read. Replace `CoreVar { name, id, def_id, identity }` with the
fixed-layout value id (or its zero-cost opaque representation) everywhere closure
captures, parameters, loop binders, pattern binders, cancellation plans and
ownership facts store it; remove the three fields and the compatibility wrapper
together. Diagnostics, Core JSON, dumps and optional symbol-map readability resolve
through the identity facts; JSON includes the numeric id and, where useful, the
display name, but decoding never uses the name to establish identity (the schema is
the one installed at the zero-pending gate). This is the first cut expected to remove
the broad ARC and record cost: variable occurrences no longer retain a heap record
holding a `String`; inspect generated C to prove passing and comparing a value id
introduces no allocation. Tests: Core JSON round trip, every diagnostic naming a
variable, profile and symbol maps, display-row loss, shadowing, the complete Core
suite. Oracle: normalized C plus compiler, runtime, leak and sanitizer gates, exact
diagnostic text. Acceptance: zero `String` field in Core variable identity, zero Core
semantic name fallback, at most one display lookup per rendered item, positive
allocation or instruction evidence or stop and investigate. Remeasure the whole series cumulatively; allocation savings come from removed
carriers/ARC paths, not merely integer equality or renamed keys.

### Typed frontend values

Prerequisite: choose whether the site satellites replace or supplement the direct
typed value id, name the one authoritative target mapping and the lowering accessor,
and specify which existing body/global outcome owns and transfers the artifact.
Reuse accepted callable/global/trait/builtin and field identities; preserve explicit
closure, standalone and recovery provenance. No table lands without a paying
consumer and a concrete lookup or carrier deletion in the same slice.

Prevent typechecking and lowering from retaining a source spelling on every resolved
identifier occurrence. Keep the parser and formatter recovery AST unchanged
initially; publish successful typed resolution in side tables, not another record on
each node: a name-site table per body, and two disjoint sparse target satellites
(`LocalNameUseTarget`, `NonLocalNameUseTarget`; a typed success occurs in exactly one,
unresolved and recovery sites stay in the site table without a sentinel id, and one
accessor reads the right satellite). The composite site key `(owner_definition_id,
site_id)` is stored as two scalar fields in the existing typed record; a standalone
managed record inside the erased typed-expression union is rejected if
the allocation census rises per name occurrence. Inference owns a distinct, initially empty
builder for the non-local satellite (never appending into the borrowed local table
and never part of the per-body seed), consumed once at the body-outcome boundary;
accepted and recovered outcomes and completed global headers store the finalized
artifact, and seeded reuse borrows it unchanged. Measurement must show the local
input rows, order and content hash unchanged, no local-table COW, builder appends
equal to the published row count, and one existing reference transferred rather than
columns copied when nesting. Then the resolved side of the body environment narrows
(symbol row identity is the value id, resolved-use table ids only, diagnostics id to
display facts, no later scope-chain walk by source name); the unresolved lookup key
stays `String` until "Identifier text becomes the id". Do not mint local `NameId`
values beyond the compilation table. Do not combine this with an environment
ownership rewrite; measure string hashing and scope lookup separately from state-copy
behavior. Oracle: exact typed diagnostics and byte-identical lowered Core and C;
formatter remains the parser-spelling oracle.

### Nominal types and members

Variables are the pilot. Freeze the common type and member identity and display
schema, then apply the pattern one family per cut (the order is a risk order, not a
dependency; disjoint families may be developed in parallel, rebased, measured and
merged one at a time): named types (`TypeId`); constructors and variants; record and
union fields (`FieldId`); traits and trait methods; globals and module-qualified
imports not already covered; intrinsic and runtime operations as explicit enums.
Use separate module-local site-id namespaces for type and member occurrences
(`TypeNameSite`, `ResolvedTypeTarget`, `MemberNameSite`, `ResolvedFieldTarget`,
`ResolvedCallableTarget`, one target satellite per successful member site or an
explicit family tag); `FieldId` joins the canonical definition table row, whose
name remains the display authority. Typed fields already use scalar
`ResolvedFieldIdentity` with explicit missing-state semantics for tuple, module,
synthetic and recovery selections; reuse that issuer and state distinction.
Each issue names the issuer and display table,
the first phase at which the reference is resolved, every downstream representation
that duplicates the string, the ABI and reflection exceptions, the exact string-keyed
indexes deleted, and the oracles. Coordinate named types with "Type identity": do not
change type interning, type equality and emitted C naming at once. Tests and
acceptance per family: same-spelled entities in two modules, qualification, imports,
generic specialization, diagnostics, reflection, foreign ABI; the census shows no
semantic spelling lookup for that family after its resolution point; C raw or
normalized-identical as declared; diagnostic and reflection text exact; phase and
whole-compile allocations and instructions flat or better.

### Strict hygiene

The `owner` labels in `scripts/compiler-identity-census` and its baseline (`C1b`, `C2a`,
`C3c`, `C4a`, `C5a`, `C6x`, `C7a`-`C7d`, `C9`, `C11b`) are historical codes from the
retired identity plan (see Git history); they are kept unchanged so the baseline stays
stable. They map to this document's sections: `C1b` to "Definition authority", `C2a` to
"Authored locals", `C3c` and `C4a` to "Core carrier" and "Synthetic binders", `C5a` to
"Emitted value symbols", `C6x` to "Backend semantic decisions", `C7a`-`C7d` to
"Late-Core consumers by exact id", `C9` to "Typed frontend values", `C11b` to this section.

The [reviewed reconciliation](../benchmarks/results/compiler_identity_reconciliation_2026-10-05.md)
restores the green start that the audited revision lacked. Every later update
classifies added and removed exact sites, boundary changes and budget increases;
do not blindly regenerate the baseline or hide unsupported capabilities. Preserve
evidence of accepted changes.
The current census is lexical, covers stages 6, 8, 9 and 10, and checks path/count
coverage; heuristic member reads and unsupported-static rows do not establish
semantic coverage or identity continuity. Strict completion needs typed/dynamic
oracles for each migrated family, with unverified scope reported explicitly.

Run `scripts/compiler-identity-census --check` and
`scripts/check-magic-spellings --strict` explicitly at the start and end of each
slice, plus the owning Python tests through `scripts/test compiler-tools` when
tooling changes. `make hygiene-check` now runs both strict checks; existing CI
Quality invokes it through `make quality`, and premerge selects the owning Python
tests. Default `scripts/test` routing remains separate. A green lexical scanner
is a migration check, not semantic completion; exact projection-site fingerprints
do not verify enclosing guards, so boundary-owned output tests remain necessary.

Keep `scripts/compiler-identity-census` (and its baseline) as a ratchet by family and
directory: unresolved identity constructors, legacy-consumer local name uses grouped
by binder family, semantic reads of compatibility `name`/`id`/`def_id`, string-keyed
semantic maps and spelling predicates, display lookups outside allowed boundaries.
Every merged slice keeps unrelated budgets flat and reduces the one it owns; a slice
cannot add an allowlist entry merely to pass hygiene. At the end the migrated budgets
flip to zero and the report becomes a strict check that prints exact file and line
violations with a narrow boundary-owned allowlist (not a broad grep that flags
ordinary rendering strings); hygiene tests include one rejected violation and one
accepted example per allowlist class.

### Completion criteria

Every semantic entity downstream of its resolution point is referenced by a typed id;
`CoreVar` has no `String`, optional definition record or name-derived identity; every
binder and use has a strict validated value id; ordinary emitted names are derived
from ids and built once; spellings live only in canonical display tables; persisted
facts have one normalized logical authority with typed keys; all spelling reads are
confined to documented display, reflection or ABI boundaries; no Core or backend
name-only fallback affects semantics; diagnostics, formatting, reflection and ABI
remain exact; and the final frozen self-compile records generated-C identity, tests,
allocations, instructions and limitations in a retained benchmark result.

## Type identity and interning

Goal: one table of types per compilation, so structurally equal types are one row,
equality is an integer compare, a substitution that changes nothing returns its
input, and mono, trait dispatch and lowering key by type id instead of rendered
strings or scans. Names follow where a measured cost remains. Each step lands alone
with a measurement taken before it starts; every step here is byte-identical C (a step
that changed mangled names would be a different roadmap) and uses a stage-2 build for
instruction claims. Rows to watch: `typed_frontend_complete`, `core_lowering_complete`,
`pass_mono_complete`, `pass_trait_resolve_complete`. `test_immutable_sharing.brp` pins
allocation ceilings on shared type fixtures; preserve those ceilings unless the
change's evidence justifies updating them. Typecheck diagnostic fixtures pin
`type_to_string`; the `type_name` intrinsic makes
`core_type_to_string` user-visible.

**Two representations.** `SemanticType` (`type_system/semantic_type.brp`, metas as
`SemanticMetaType(MetaSessionId, Int)`) and `CoreType` (`stage_09_core/ir.brp`).
Lowering converts one to the other in `core_lower_type_with_prefixes_impl`: the
[2026-09-22 histogram](../benchmarks/results/core_lowering_type_histogram_2026-09-22.md)
recorded 1.27M calls per self-compile for about 22k distinct shapes. Six arg-less
scalars are module constants; other shapes are generally reconstructed.
Mono substitution already returns the input for unchanged shapes in several arms;
preserve that behavior. There is no type scheme; generalization is by name at zonk time.
`core_type_equal` and `core_mono_type_equal` (with its own dim normalization) have no
`same_object` short-circuit; `MetaSessionId` already does pointer-first equality.

Keep the domains explicit: graph `TypeId` identifies a nominal declaration;
interned `SemanticTypeId`/`CoreTypeId` identifies a complete structural
instantiation under its table authority. Concrete specialization, ABI/storage
layout and occurrence release facts are separate. A generic source declaration
can have several layouts; its nominal id alone cannot key them.

- **Callee type memo.** `CallExpr.callee_type_lowering` was 852,492 allocations (33%
  of call lowering's budget): the callee's function type is lowered fresh at every call
  site. First add tests for one generic at two parameter types and one with identical
  parameter types but different return instantiations (`list[T](Int) -> List[T]`).
  Current resolved calls keep declaration identity separately from instantiated
  parameters and return. Key the complete instantiated callee type, including
  return, dimensions and purity, under the relevant lowering authority; a def id
  or `(def_id, argument types)` alone is insufficient. Type lowering also reads
  `module_member_prefixes`. Select an explicit memo owner and publication path:
  recursive lowering returns only the expression result, so adding a dictionary to
  its immutable Reader context cannot publish sibling entries. A prepared immutable
  catalog or bounded state-threading probe must repay its build/ownership cost and
  delete repeated type lowering; no unused pre-walk or managed per-call carrier.
  Remeasure the current lowering boundary before implementation.
- **Interned `SemanticType`.** A `SemanticTypeTable` on the typecheck `Context`
  interning at the hot producers (`localize_module_types`, qualify, `apply_subst`,
  unify's rebuilds); exclude metas and compound meta-bearing trees until zonked and
  proved meta-free (`types_equal` distinguishes meta sessions; `test_type.brp` pins
  that two sessions with the same slot stay unequal);
  the six scalar constants are the first rows. Expected typed frontend -2M to -4M.
  Oracle: C, the marked diagnostic fixtures owned by `scripts/test compiler-blorp`,
  typed-AST JSON tests; use the runner's current fixture count.
- **Core type table, re-scoped.** Construction-time interning (a `CoreTypeTable`
  threaded through type lowering and mono substitution) was parked on measurement:
  lowering +41.6% allocations, mono +12.1%, instructions +3.3%, because expression
  lowering is a stateless descent whose helpers do not return the lowering context, so
  the forty-odd call sites outside the closed type-lowering subsystem could read the
  table but not publish rows; equality short-circuits alone were +0.00% (without
  interning upstream, equal types are almost never the same allocation;
  `benchmarks/results/type_interning_i3_equality_identity_2026-09-23.md`). The next
  attempt is mono-scoped: a table on the specialization state, interning substitution
  results only (mono's loop already threads state across its `apply_type_substitution`
  sites and accounts for about a quarter of the constructions), then re-enable the
  short-circuits and resolve the `normalize_dim` difference between the two equalities
  first. A structural hash over the children's ids replaces any transitional
  shape-string key before it is called done (rendering types to strings is the
  recorded instrumentation trap). Expected: mono -1M to -3M allocations, instructions
  -1% to -2%. Oracle: C, `test_core_mono*.brp`, `test_core_specialize*.brp`,
  `test_core_trait_resolve.brp`.
- **Dispatch and layout keyed by type id.** `core_trait_impl_type_key` (used from
  `resolve.brp`, `runtime_projection.brp`, `backend_projection.brp`) renders a type
  per lookup; `CoreLayoutTypeIndex` and `BackendTypeNaming` key by type name. With a
  type table use a checked id for the complete instantiation; layout queries retain
  concrete specialization and ABI/storage facts. Delete the rendering helpers and
  convert every lookup on the data source in one task (grep for stragglers).
  Expected: trait resolve
  instructions -10% to -20% of its row, allocations flat; report `blorp_string_eq`
  and `blorp_dict_hash_string` samples before and after. Needs the Core type table.
- **Definition lookup views.** Do not build a second definition table after lowering;
  the frozen frontend definition authority plus the append-only generated overlay
  ("Definition authority", "Synthetic binders") own definition identity. If a consumer
  still needs a current-program declaration lookup, publish a clearly named view
  (such as `CoreDeclarationRowIndex`: definition id to current row index and scalar
  facts only) that does not duplicate display rows, own the definition frontier,
  retain declaration bodies or compete with the identity facts, built and measured
  with its first active consumer, deleting that consumer's private scan in the same
  cut; each consumer's pass row must fall or the view is removed. The earlier DCE
  conversion to ids measured -0.32% instructions: a reason to measure a view, not to
  publish another authority.

### Qualified type names

Why the current shape exists: a standard-library type is bare inside its own module and
for names on `is_global_abi_type_name`, `module::T` in an importer (typecheck), and
`module__T` after `lower.brp` flattens it (Core). Readers accept all three;
`type_name_metadata.brp` lists all three because pre-flatten and post-flatten readers
share it. `TypeId` plus `owner_module_id` exist in header resolution and are dropped when
`type_header_install.brp` builds the `SemanticNamedType` String; `SemanticNamedType`
(255 source, 457 test uses) and `NamedType` (465 and 1,000) carry only a String, so no
reader can compare identities until a field is added. Pins are `(std module origin,
NameId)` resolved to a `KnownStdlibType` once per declaration, not a literal
`DefinitionId`. Every slice is byte-identical C and deletes Strings or comparisons in
its own commit. Use `scripts/check-magic-spellings --report` for the current
`stdlib_type_name_literal` and `qualified_name_literal` inventories; keyed allowlist
entries, scanner findings and deduplicated report sites are different counts.

1. **`KnownStdlibType` enum** and one `known_stdlib_type_of_semantic_name` and
   `known_stdlib_type_of_core_name` pair in one new module (the only file with type-name
   literals). Typecheck-side readers first (the 4 `type_name_metadata` predicates, 15
   `infer.brp` uses, `decl.brp` 2, `env.brp` 1, `lower.brp` 4, the two `Duration`
   readers, `CANONICAL_PARALLEL_*`; about 25 call sites, 12 literals; gate
   `scripts/compiler-check --stage typecheck`), then Core readers (`type_policy` 11,
   `c_type_layout` 13, `unmanaged_type` 13, `prepare` 6, `desugar` 2, `late_invariants`
   1, `specialize_collection` 1; 47 literals; gate `compiler-core-sanitize leak` and
   the codegen audit), then `operation_metadata.brp` (`accepted_type_names` lists
   become `List[KnownStdlibType]`, 38 literals, 24 lists; the two compiler-private LSP
   types become a `ModulePathType(canonical path, name)` case, not a stdlib pin;
   operation-metadata suites). Each reader converts exactly once, to an enum whose
   constructor the identity step later swaps.
2. **Identity beside the String.** `SemanticNamedType` and `NamedType` gain a
   nominal-identity field (`NoNominalIdentity`, `DeclaredNominal(TypeId)`,
   `IntrinsicNominal(IntrinsicType)`) written by header install (the four accepted
   graphs, `type_header_install.brp`) and by lowering copying it from the semantic
   type; a mechanical arity change done with a script and a smart constructor,
   equality stays String-only in this slice; producers without an id
   (`types.brp`, `qualify_module_local_types`, `type_resolution.brp`) get it from one
   env lookup. About 720 source and 1,457 test occurrences, about 14 producers. This is
   the named-types family of "Nominal types and members": do not run a second
   migration, and land it as its own change before the dispatch-key and interned
   `SemanticType` steps above. Gates: all compiler-check stages, typed-AST JSON tests,
   allocation counts (a wider variant is a measured cost: stop and reassess if
   `core_lowering_complete` moves as in the parked table attempt).
3. **Readers read the identity.** `known_stdlib_type_of_*` classify from the stored
   identity instead of the String; the string-to-enum constructors, the
   `is_global_abi_type_name` list, `normalize_type_name`'s `Vector`/`Matrix` fold and the
   60-name list's readers go; `net_*` and other `pkg/` types classify by module origin
   through the same path, not a stdlib enum. This fixes the open collision: a module's
   own type whose name is on `is_global_abi_type_name` (`Stream`, `FallibleStream`,
   `Channel`, `Directory`, `FileReader`, `Port`, ...) is spelled bare, exactly like the
   stdlib type, so the typechecker treats a user `record FallibleStream[T, E]` as the
   stdlib stream (pinned by
   `typecheck/should_fail/user_fallible_stream_named_like_stdlib.brp`, which moves to
   `should_pass` then). Add same-named-type-in-two-modules fixtures, and a fixture with
   a generic user record whose name spells a stdlib type (mono-specialized data types
   use `mangle_generic_data_name`).
4. **Delete the parsers.** `SemanticQualifiedNamedType(alias, name)` replaces
   `alias.Name`; `display_type_name` renders from identity plus the module table;
   `split_canonical_module_type_name`, `split_qualified_type_name`,
   `owner_local_type_name` and the `::` parse in `identity.brp` go with "Function names
   and module origins" (Core stops flattening by String). Needs that step and the
   offset-returning split already in `semantic_type.brp`. Gates: the marked diagnostic
   fixtures owned by `scripts/test compiler-blorp`, `type_name` intrinsic tests;
   move the `"Tuple"` comparison in `core_type_to_string` to a variant match first.

Risks and catches: a dead-looking arm that is live (an arm with any hit stays and is
listed); a bare spelling that collides with a user type (the fixtures above); flat names
for builtins, tensors and tuples (explicit `IntrinsicNominal` and `NoNominalIdentity`
cases, and a pinned reader receiving `NoNominalIdentity` fails a Core invariant rather
than falling back to the String); `net_*` and `pkg/` types (`scripts/test package`);
compiler-private LSP types (`scripts/test lsp`).

## Core node tables

Goal: stop rebuilding the Core tree once per pass. Packed source handles and the
pass-mint API are landed; fresh expression-occurrence uniqueness is not yet proved.
The current node invariant covers function bodies, is report-only unless
`BLORP_NODE_IDENTITY=strict`, and deduplicates shared semantic-match DAG subtrees
while ordinary expression traversal visits each occurrence. Facts about nodes
will live in id-keyed tables published once on the pass state, and
only a pass that genuinely rewrites a node allocates a new one. This is the end point the
late-Core pass fusions and "Value identity" are walking toward. It is not a rewrite of
Core into a flat arena in one step; each step changes one representation fact, is
measured, and is parked with its numbers if negative. The traversal already preserves
identity (`traverse.brp` rebuilds only when a child changed), but private per-pass
walks remain. Instrumentation must be allocation-neutral with its flag off.
Replacing child-list construction pays only if it avoids extra per-call overhead:
closure-callback per-node visitors (+6% instructions) and a fold replacing a list
walk (-0.08% allocations, +0.6% instructions) were rejected. Keep direct `match`
on hot paths. Use the canonical frozen self/small measurement protocol and stage 2
for instruction claims; require identical C unless a slice says otherwise, the
owning traverse/JSON/pass suites, leak, sanitizer and hygiene gates.

### Perceus summaries by node id

`summarize_linear_ownership_uses` is 28.6% of the Perceus row (4.8M calls) and returns a
fresh `OwnershipUseSummary` record per visit (11M records) plus a frame stack (4.3M
pushes); 14.1% of its calls repeat a pair already summarized in the same
`rebuild_managed_let`, but the census shows only 2.60% of the walk's own allocations come
from those repeats within one managed let, and the wider per-function repeat is about 7M
allocations (past the 5M go/no-go floor). A first memo was never landed. **Parked after a
second attempt** (a live entry memo keyed by `(node id, variable name)`, gated to the one
call tree analysis said was environment-invariant, with correct retain and release on the
cached name): it produced non-identical C on the frozen self-compile (hundreds of
thousands of diff lines) and an ASan heap-use-after-free in the compiler's own test suite,
so a real correctness bug survives both the environment-invariance and the retain and
release fixes. The likeliest cause is a node id that is not as unique as the node-id
invariant assumes inside `rebuild_managed_let`'s shadowed-match-binding freshening (a
subtree can be duplicated across match arms; whether every duplication mints a fresh id
was not verified). The measurement hooks (`BLORP_PERCEUS_ENGINE_METRICS`,
`perceus_engine_summary_function_begin`, the per-function table in `runtime.c`) remain.
To reopen: first define the exact analyzed body scope and verify every eligible
packed or minted memo key after shadowed-match-binding freshening. Exclude zero or
loc-less handles unless a separate checked identity is supplied; distinguish shared
physical nodes from duplicated occurrences, and extend coverage explicitly before
analyzing globals or other executable owners. Key the memo on `(node, variable id)`
and prove which `PerceusEnv` fields the summary reads (key on them or show they are
constant within that scope). A table built once per function body in one bottom-up
walk replaces repeated walks. Remeasure the historical census before reopening.
Go/no-go: at least -5M on the Perceus row or park again. Oracle: byte-identical C,
`scripts/test leak`, `test_core_perceus.brp`, the sanitizer gate.

### Core types as type ids

Typed Core expressions carry a `CoreType`; mono substitution rebuilds changed trees
and preserves unchanged shapes; the two equalities compare structurally. Depends on
the Core type table ("Type identity and interning"); the field on each expression becomes a `CoreTypeId`, type
substitution in mono becomes a remap over the table, the equalities become integer
compares, and the codec renders the resolved type so dump JSON is unchanged. Widest
mechanical change in this section (every arm and every private match that reads `typ`):
do it after the scalar-column pattern of the source-location handle is established, and
only once the table is stable. Expected: mono -5M to -8M allocations, instructions -2% to
-3%. Oracle: byte-identical C.

### Blocks instead of let nesting

A function body of n lets is n nested `LetExpr` nodes; every pass that touches one let
rebuilds the chain above it, Perceus's `LetExpr` arm alone is 8.8% of its row, and the
emitter derives statement order and tail position from the nesting. Change:
`BlockExpr(List[CoreStmt], CoreExpr)` with `CoreStmt` `LetStmt | AssignStmt | ExprStmt`;
lowering emits blocks; `LetExpr` and `SeqExpr` are removed from late Core by a checked
invariant; the emitter iterates the list. Statement order is the same but temporaries may
renumber, so the oracle is normalized C plus the runtime, leak, sanitizer and codegen-audit
gates. Largest blast radius here (the emitter's `LetExpr` arms, every pass matching
`LetExpr`, the ownership passes' notion of scope): start only after the pass list has
stopped moving, and measure a prototype on the small program first. Estimate (soft): late
Core -5% to -10% allocations and a comparable instruction gain. The only step that changes
the emitter's structure; it is last.

Not here: Perceus as a single liveness pass (a separate design once the node-id summaries
and the Perceus cleanup issues settle), parallel late passes (blocked on task-fiber cost),
and the emitted-C shape ([`PER_NODE_CODEGEN_ROADMAP.md`](PER_NODE_CODEGEN_ROADMAP.md)).

## Frontend facts

Apply the [normalized-table principles](#principles) at each frontend stage:
local uniquely owned builders publish immutable id-keyed facts once; later stages
reuse them rather than rebuilding indexes. Convert every lookup on a migrated data
source and delete its old accessor in the same slice.

The fast loop is `--stop-after=lower --dump-core-after=lower`, compared by `cmp`
against the frozen base. Generated C remains byte-identical. Measure the changed
phase's allocations, whole retired instructions and the corresponding string/hash/
copy samples (`blorp_string_eq`, `blorp_dict_hash_string`, `blorp_dict_copy`,
`blorp_dict_get_nullable`, `memcmp`) using the canonical self/small protocol.
A key-change claim must move its sampled lookup category; dictionary probes do not
allocate.

### Typecheck state ownership (two gated probes)

The broad `TypecheckState -> ModuleFacts + BodyBuilder` rewrite is closed: the body boundary is
already split (`InferModuleFacts` holds immutable body facts, `InferSession` the accumulators,
recursive inference threads `InferContext`; the header-install builder hoists `type_homes` and
`known_type_index` into local owners), and another managed facts record would recreate the
ownership failure seen in Core lowering. Blorp has no source-level borrowed record field, so a
facts value can stay outside the returned state only as a function parameter, safe only if
generated C proves recursive calls add no retain or release traffic. Two bounded cuts remain,
each behind a capability gate:

- **Immutable inference facts outside returned state (probe).** Remove `facts` from the state
  returned by recursive inference and pass one facts value separately. The characterization
  test comes first: extend
  `blorp/test/test_compiler/test_pipeline/test_infer_session_reconstruction_profile_benchmark.brp` with a
  nested inference-shaped probe that returns only the accumulator, checks a facts-dependent
  checksum and exposes publication and allocation counts; inspect generated C around the probe
  and recursive call before touching `infer_expr`. Proceed only if the probe removes at least one
  managed publication and its matching allocation and release per modeled recursive update, adds
  no retain or release pair per recursive call, preserves zero retained objects and bytes and
  gives byte-identical replay responses. Reject if passing facts retains them on every call, if
  counts are flat or higher, or if three alternating self-compile pairs regress minimum retired
  instructions by more than 0.5%; that means the compiler needs an explicit borrow capability,
  not another managed carrier.
- **Graph import admission owned locally, module view published once.** Each successful graph
  import registration republishes the whole 14-field `TypecheckState`
  (`register_program_imports`, `apply_import_decl_decision`, the `typecheck_state_*graph*admission`
  adapters, `GraphImportAdmissionRep`). The prerequisite: the admission stores no active
  `ModuleTable`, `DefinitionTable` or `ModuleId`, so every registration re-accepts caller-supplied
  current authority and moving the admission into a local would leave a stale-pair hazard. Add the
  already-validated active `DefinitionTable` to the private admission; a batch constructor
  accepts `(view, active_definition_table)`, derives the issuer module id from the view,
  validates compatibility once and stores the table only on success; registration then reads that
  authority, issuing target tables stay explicit and are still checked, and a stale pairing is
  unrepresentable after construction. Tests first in `test_module_view.brp` (a table from graph A
  cannot begin admission on a view from graph B, no API accepts replacement active authority,
  mismatched issuing tables stay rejected, finish preserves the original view owner); inspect
  generated C and the allocation fixture because retaining a table inside the admission is a new
  managed field that may erase the win (if it does, stop and require a compiler borrow
  capability). The cut then keeps the admission as the loop's single owner, threads only
  registration decisions and cold-path diagnostics, and updates `module_view` once; preserve the conflict and reentry cases in `test_typecheck_state.brp`. Add a deterministic
  counter for successful admission mutations and whole-state publications. Accept only if each
  nonempty graph import block has one admission construction and one final publication,
  diagnostics and accepted binding order are byte-identical, allocations and releases fall by at
  least the eliminated publication count, and retained objects and bytes do not rise; reject on
  any replay identity difference or a more than 0.5% minimum-retired-instruction regression
  across three alternating pairs.

### Lowering tables keyed by definition and type id

`lower.brp` has nineteen `Dict[String, String]` tables (name renames and prefixes) and
`list_layout.brp` keys type aliases, storage layouts and core types by type name.
`module_member_prefixes` (`graph_prepare.brp`) is built once and threaded through 19
signatures; it needs only the module id key (a `ModuleId -> C prefix` list), with copies in
`resolve.brp`, `mono_specialize.brp`, `mono_option.brp` and `parallel_tensor_pipeline.brp`.
`CoreLayoutTypeIndex` is built for FFI annotation and again for list annotation
(`ffi_boundary.brp`, `list_layout.brp`, back to back in `graph_prepare.brp`, with
`annotate_list_layouts` also called from `early_stages.brp`). Share the initial build
only after proving FFI annotation preserves every indexed fact; later rewritten
programs need their own validity decision. A table keyed by complete type/instance
identity, carrying narrow alias, declared-type and layout facts, would retire
`CoreLayoutTypeIndex`, `mono_data.brp`'s `templates` and `transparent_aliases` (threaded through
about 20 signatures), `record_update.brp`'s `record_decls` (about 25 signatures),
`emit_record_layout.brp`'s three tables and `flatten.brp`'s `type_rewrite_index`. Where a table
maps names to sanitized C identifiers, compute the identifier once per definition id.
`CoreLowerCallableNameRegistry` (already `Int`-keyed, built once per module) is the target shape.
Acceptance: identical C; `core_lowering_complete` allocations down; `blorp_string_eq` and
`blorp_dict_hash_string` samples down; lowering suites and compiler-check green. Realistic gain
0.5 to 1% each; the C identifier table (`DefinitionId -> C identifier` for every concat-on-call
helper in `c_naming.brp`, `c_symbol_projection.brp` `by_original_c_spelling`) is the same idea
for the backend (1 to 1.5%).

### Cacheable header completion (design)

`graph_completion` re-derives every module's accepted record, union, alias and global headers on
every compile (`global_header_completion`, 834 to 927 ms on the self-compile); for an editor it
must be cacheable per module, keyed by a hash of the module's declarations. Deliverable is a
design note, not code: what the per-module header product is, what it depends on (imports'
surfaces), how it is keyed and invalidated, and how `PreparedCanonicalModuleEnvironment` can load a
cached header product without reconstructing module facts. Distinguish reuse within
one compilation from reuse across compilations: persisted products must rebind
definition/module/type identities and session-sensitive meta facts under the current
authorities, never persist live compilation ids. Include compiler/policy provenance
and imported/prelude/default-method surfaces in invalidation. Write it after the module-view
publication cut above proves the final publication boundary. Cold-compile gain is 0%; the value is
per-edit latency. Related typecheck allocation work: `prepared_module_environments` rebuilds the
same per-module setup once per module and per header.

### Body checking follow-ups

Resolve each occurrence once by definition id instead of repeating `scope_lookup`,
`env_lookup` and `lookup_bare_value` by spelling (the typed-values slice above).
Before more environment ownership plumbing, attribute its allocation sites: the
single-owner Env builder measured flat. Separately remove repeated id indirection
through `source_name_id_table_index`, `definition_id_runtime_value` and
`definition_table_rep_row`, shared with header completion. Scope insertion is a
small lead, only alongside the first.

Owned-call specialization for `Dict`/`List` helpers with tail-position propagation
was rejected at **+2.2% stage-2 instructions**: hot retargets received borrowed
arguments that never became unique. Reopen only with proof that the caller owns the
argument and that the clone's pass-through costs no more than the original.
That rejection has no linked durable report; retain this stop condition until
a new measured experiment supersedes it.

## Interim states on main

This index routes live bridges to their detailed removal tasks above; it does not
repeat their designs. Named symbols were checked in the current checkout. Delete
a row only after its bridge is removed; verify behavior before treating a renamed
symbol as completed work.

| Interim state | Removal task |
| --- | --- |
| `CoreFunction.name` beside `origin`; `origin_name_agreement.brp` and UFCS spelling producers | [Function origins](#function-names-and-module-origins): delete producers |
| Function/global `source_module`, `SourceModule(ModuleId, ModuleOrigin)`; path-based known functions | Module origin as id only |
| `typed_name_identity.brp`, dual name/id Core JSON | [Identifier text](#identifier-text-becomes-the-id) |
| `DiscoveryNames.SeededTableOnly` adopts only the first finalized root's table; generated root keeps own-table ids | Share one append-only table across root parses; standalone precondition below, coordinate old-front-end removal |
| `name_spelling_of_text` Core/LSP bridge; cross-owner name-table imports | Identifier text; move shared name-table owner to `blorp/src/lib` |
| `graph_source_name_table_for_programs`, `SpellingsFromIdentifierText` standalone rendering | Share discovery's compilation table before identifier text removal |
| Call diagnostics, semantic lint, type-header, CTFE and typed-AST JSON `.text` readers | [Display/formatter boundary](#diagnostics-dumps-and-the-formatter-through-the-name-table) |
| `ResolvedCallInfo`, `CtfeIrDirectCall`, `AcceptedCallableBinding`, `TraitMethodCallee` spelling fields; CTFE `source_name_id = None`; `builtin_is_registered` synthesized-name lookup | [Builtin vocabularies](#builtin-and-intrinsic-vocabularies-by-id), then string deletion |
| `infer_source_name_id` reconstructs imported original/accepted names; `ctfe_imported_intrinsic` selects by module path | Shared compilation name ids on bindings; module ids for intrinsic table selection |
| `TraitDef.name` beside `trait_id`; by-name accessors, linear `env_get_trait_by_id`, entrypoint/prelude path checks | [Trait identity](#trait-identity-through-typecheck-and-core) |
| `CoreImplMethodRole`, callback name constants, incomplete `ImplMethod` origin; String-keyed `CoreRuntimeCallbackTable`; type-carrying origins | Core trait/type ids with callback identity invariants |
| DCE `function_ids_by_name`; resolve `foreign_functions`, `builtin_functions`, `user_call_by_name` | Every call site reaches resolve with definition id |
| Synthesis/resolve/std-inline member vocabularies via `CoreDeclarationIndex.names`; work-profile's empty name table | Builtin vocabularies and module-scoped resolve by id |
| `core_empty_declaration_index`, `core_synth_context_empty` remain functions because cross-module global initializers are unsupported | Emitter capability, not an identity cut |
| `CoreMonoInstanceIndex` structural-hash buckets despite the custom-key dictionary fix | Key by `CoreMonoInstanceKey`; delete bucket layer |
| `c_local_name` escapes/id-zero fallback; creation-time Perceus/derived C spellings and shadow-match uniqueness names | [Synthetic binders](#synthetic-binders) and [binder producers](#binders) |
| Small-pass id-zero binders and span-derived authored/`?=`/`with` ids (`core_binder_id`, `core_question_bind_var`) | Synthetic/authored issuer decision; span offsets remain below 2^31 |
| Field spelling beside `CoreFieldRef` | Identifier text, retaining explicit ABI/display facts |
| Projected nullary `VarExpr` spelling; case-name lookup in operation metadata | [Constructor references](#emission-by-id) by exact id |
| `c_naming` imports `ir` for `CoreBinderOrigin` and inherits foreign-header requirement | Split origin/spelling boundary |
| `type_parameter_name_kind` sigil read | Dimension kind instead of spelling |
| `direct_constructor_payload` checks `NamePattern("_")` | Lower wildcard explicitly in synthetic-binder slice |

## Order and parallelism

- Reconcile the census before using it as a green ratchet; run the explicit checks
  until the enforcement delivery lands. The identity relation, source/generated
  issuer mapping, paired-frontier API and carrier probes come first; the
  authored-locals pilot, the Core carrier and the synthetic-binder families follow in that order
  and share the inference and lowering authority, so they normally integrate serially. Producer
  families are the first broad parallel wave once the mint and remap API freezes.
- Names steps (builtin vocabularies, trait identity, formatter) are independent of the value-identity
  spine and can run beside it with disjoint files; flipping identifier text waits for all of them
  and for the standalone-graph precondition.
- Magic-spelling steps are disjoint in files except `resolve.brp`, `std_inline.brp`,
  `collection_plan.brp` and `string_pipeline.brp`; run those serially. Binder steps follow the
  small-pass minting. Types and emitter temporaries are independent of the others and can run
  whenever an emitter slot is free (the stack-option payload type waits for the small-pass binders
  because of `match_projection.brp`).
- Type identity: the callee memo first freezes its complete key and publication owner;
  it and the semantic type table can then run beside each other; the Core
  type table follows; dispatch keyed by type id follows it; named-type identity lands before the
  dispatch and semantic type steps and is the named-types family of the nominal step.
- The Core node steps do not touch union layout; "Core types as type ids" waits for the Core type
  table; blocks come last. The former struct-payload work is retired under
  [record simplification](FIXED_LAYOUT_ROADMAP.md); any new union-emission
  work needs its own owner and must coordinate the shared `ir.brp` seam.
- Frontend facts steps own the typecheck state files and are independent of the rest.
- Coordinate the discovery-authority step with the old front end's removal
  ([`DISCOVERY_ACCEPTANCE_ROADMAP.md`](DISCOVERY_ACCEPTANCE_ROADMAP.md)) so only one front end
  issues definition ids.
