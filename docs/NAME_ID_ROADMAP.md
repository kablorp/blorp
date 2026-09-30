# Name-to-Id Roadmap

Names in the compiler become ids. Two outcomes, two lanes:

- **Lane A, names to ids.** Every identifier's String content becomes its
  `NameId`, then an `Int`, passed along unchanged; spellings are looked up
  only where a human reads them. Every step is semantics-preserving and
  gated by byte-identical generated C.
- **Lane B, emission by id.** The emitter spells symbols from definition
  and binder ids instead of names, so the generated C shrinks. Steps change
  C by design and are gated by the codegen audit, the runtime and leak
  gates, and the normalized-C oracle showing that only spellings changed.

Measured facts that fix the order (all 2026-09-28):

- A spike that flipped `ParsedIdentifier.text` to the stringified id built
  the compiler, but the result could not typecheck hello world. Names are
  projected to plain Strings early and compared against literal
  vocabularies: typecheck 158 `==` sites and 231 `match` arms, CTFE 9/85,
  core lowering 123/8, Core passes 1,395/426, backend 179/12. The concrete
  walls are the builtin trait registry, the Equatable obligation checks, the
  ownership manifest, the builtin registry, the CTFE intrinsic table and the
  intrinsic/prelude type names. The compilation `NameTable` is reachable
  only during parsing, so nothing after parse can render a spelling. Lane A
  steps 1 to 5 are therefore prerequisites of the flip, not part of it.
- Mangled names do three jobs: Core identity (replaced by `def_id`, except
  that mono instantiations still share ids), classification by parsing
  (about 25 readers; replaced by an explicit origin attribute), and C
  spelling (replaced by symbol projection). Retiring mangling is Lane A
  step 3 and starts with instantiation-specific definition ids.
- Locals spelled from binder ids cut the self-compile C by 1.56%; variants
  spelled from definition ids cut it by 9.04%. About 402k binder
  occurrences still carry their synthetic spelling because their passes
  create them with id 0.

## Rules

- One landing at a time through `scripts/land` from the integration
  checkout; never set `BLORP_LEAK_TEST_TIMEOUT` there (a hygiene test pins
  the recorded environment).
- At most three workers; each brief cites one step below and owns the files
  that step lists. `emit.brp`, `lower.brp`, `infer.brp` and
  `match_projection.brp` have exactly one owner at a time.
- Lane A gate: `benchmarks/self_compile_measure --stage2 --require-identical`
  against a parent frozen at the branch base, self and `--program small`,
  plus the owning suites. Lane B gate: codegen audit with `EXPECT-C-REGEX`
  for projected families, `scripts/test runtime`, `scripts/test leak`,
  `benchmarks/normalize_generated_c_symbols --project-locals` identical,
  and emitted C bytes reported before and after.
- Replaced data is deleted in the same commit. A String that only carries
  what an id already carries does not survive the step that adds the id.
- Machinery cleanups that do not move a name to an id or shrink emission
  (CTFE `NameTable` plumbing beyond what Lane A needs, `ModuleId` in Core) wait until both
  lanes are done. Their censuses are kept in `benchmarks/results/`.

## Lane A: names to ids

| Step | What | Files | Gate | Status |
| --- | --- | --- | --- | --- |
| A0 | Compilation `NameTable`; `ParsedIdentifier.name: NameId`; holes and synthesized spellings interned; field identity `CoreFieldRef`; binder ids unified | stage_02_lex/name_table.brp, stage_03_parse, pipeline.brp, stage_09_core/ir.brp, pass_runner.brp | identical C | done (b6928bb0, 0b17137a, 8186f04c, 7792a130, aa5425ed4, 32307f0d) |
| A1 | Pinned `NameId` constants for the closed vocabulary; unseeded lookups fail loudly; the 43 literal `.text ==` compares use the constants; the compilation table is reachable from typecheck, Core input, `CorePassState`, the emission context, the formatter and the LSP through one boundary helper | name_table.brp, test_lexer.brp, infer.brp, lower.brp, decl.brp, typecheck result records, `CoreGraphUnit`, pass_runner.brp, format/projection.brp, lsp workspace records | identical C; typecheck fixtures unchanged; formatter idempotence | done (375d637a0) |
| A2 | Builtin vocabularies compared by id while the text is still real: trait registry (`type_system/builtins.brp`, 159 arms), Equatable obligations (`env.brp`), ownership manifest (`stage_09_core/ownership.brp`, 179 arms), builtin registry (97), CTFE intrinsics (74), `intrinsic_type`, `prelude_type` | those files; one worker per registry, disjoint | identical C; `scripts/test compiler-blorp` | after A1 |
| A3 | Retire magic spellings (expanded step by step in [`NAME_MANGLING_REMOVAL_ROADMAP.md`](NAME_MANGLING_REMOVAL_ROADMAP.md)): no reader learns a fact from the shape of a String. A3.0 census of every `starts_with`, `ends_with`, `split`, `parse_int` and literal-prefix concatenation on a name-like String, by file, with the record or enum that replaces it; a hygiene grep keeps the pattern from returning. A3.1 functions: every mono instantiation and synthesized function gets its own `def_id` (mono dedups by `(base, type_args)`; flatten's collision workaround goes), then `CoreFunction.origin` (`SourceFunction`, `ImplMethod`, `MonoInstance`, `PureVariant`, `UfcsWrapper`, `Synthesized(kind)`, `HoistedLambda`, `HoistedTask`, `EtaExpansion`, `StaticCallback`, `Entrypoint`, all payloads ids or types) replaces `mono_name_base`, `strip_pure_suffix`, the UFCS and module prefixes, the closure prefixes and the trait-method prefix; last commit deletes the producers and the name becomes display-only. A3.2 binders: a `CoreBinderOrigin` enum where Perceus and cleanup readers recognise their own temporaries by prefix today. A3.3 C type strings: payload `CoreType` rendered at emission replaces `blorp_StackOption_*`, inline-struct and boxed-element spellings and the three `resolved_*` parsers (census in the T6 report; `blorp_StackResult` is an ABI constant and stays) | mono.brp, mono_data.brp, synth_name.brp, the synth_* passes, closure.brp, resolve.brp, std_inline.brp, collection_plan.brp, string_pipeline.brp, flatten.brp, runtime_projection.brp, perceus/*, c_type_layout.brp, list_layout.brp, prepare.brp, emit.brp | identical C at every commit | A3.0 now; A3.1 after B1 and B2 land; A3.2 after B1; A3.3 after B2 |
| A1b | Parser-minted binder ids: the parser gives every binder a per-module counter id carried on the pattern node, replacing lowering's span-derived positive ids, so ids are stable across unrelated edits and fixtures can pin them | stage_03_parse/parsed_ast.brp, language_parser.brp, lower.brp binder sites | identical C up to local spellings (normalized oracle identical); audit fixtures | after A1 |
| A4a | Typecheck diagnostics render identifier spellings through the table: message renders in `decl.brp` (~32), `infer.brp` (~29), `implementation_headers.brp` (~6); the table reaches checking through one field on the checking context | stage_06 | the 860 `should_fail` messages byte-identical; identical C | after A1 |
| A4b | Lint finding messages render identifier spellings through the linted graph's spellings (6 sites in `lint/command.brp`); the ~20 `==` compares and ~6 key builders stay (class f). The census's LSP class (~17 sites) was source-file text (`source.text`), not identifiers, so nothing there converts; the one LSP identifier use is the `name_spelling_of_text` caller in `semantic_index.brp`, which stays until A5 | `lint/command.brp` | lint fixtures unchanged; `scripts/test lsp` unchanged | after A4a |
| A4c | `--dump-core`, AST JSON and typed dumps (~40) | `parsed_ast_json.brp`, `frontend_output.brp`, `stage_07_ctfe/ir.brp` | dump fixtures unchanged | after A4a |
| A4d | Formatter (~486) | `format/engine/*.brp`, `format/projection.brp` | formatter idempotence; own branch, after the formatter has a settled table parameter | after A4a |
| A5 | Flip `ParsedIdentifier.text` to the stringified id and delete `.text` readers; then String to `Int` one record family per commit (`CoreVar.name`, function names, field and variant spellings, type names) | frontend and Core records | identical C | after A2, A3, A4 and the standalone-graph precondition (standalone graphs share the discovery table) |

## A2b: trait identity

Census: [`benchmarks/results/trait_identity_census_2026-09-29.md`](../benchmarks/results/trait_identity_census_2026-09-29.md).
A trait's identity is the opaque `TraitId` (graph traits are their
`DefinitionId`; builtins are `-(registry_id + 1)`). The header graph already
holds it; the legacy `Env` layer and Core hold the trait's name as a String
(about 450 lines in typecheck and Core, 68 literal compares against builtin
spellings), which cannot tell two same-named traits from different modules apart
and cannot be compared by pinned id. `NameId` is the wrong identity (spelling,
not declaration); `TraitId` is right.

| Slice | What | Gate |
| --- | --- | --- |
| A2b.1 | leaf `type_system/trait_identity.brp` (opaque `TraitId`, 29 pinned builtin constants tested against `builtin_trait_registry_id`); mandatory `TraitDef.trait_id` and `ImplInstance.trait_id` written by the builtin registry and the accepted-header path; agreement test over `env.traits` and `env.impls` (including builtin `def_id` 100+ versus registry id) | typecheck stage; identical C |
| A2b.4a | every bound carries its identity: `make_resolved_bound_type_param` is the only constructor (`make_bound_type_param` and `TraitRef` deleted); accepted impl bodies take bounds from the implementation header; the remaining by-name resolution (test-only registration, standalone bodies, error-recovery signature) reports an unknown bound as a typecheck error. Accepted impl parameters now follow the header: order of appearance, dimension parameters included, duplicates once (previously inline-bounded parameters first, dimension parameters skipped, duplicates kept; `Pair[A, B: Eq]` was `[B, A]`, now `[A, B]`); `env_extend_type_param_bounds` looks parameters up by name, so only a same-named duplicate could tell the orders apart | typecheck stage; identical C; message fixtures |
| A2b.4b | option C: delete the test-only registration and standalone-infer path (`typecheck_register_*`, `register_*_decl`, `typecheck_check_standalone_program_bodies`, `typecheck_materialize_standalone_program_bodies`, `InferStandaloneFunctionBodies`, `impl_bounds_for_decl_type`, `bound_identity_for_trait_name`) and migrate its 139 test call sites to the accepted path: 60 `typecheck_register_program_signature_decls`, 41 `typecheck_check_standalone_program_bodies`, 19 `typecheck_materialize_standalone_program_bodies`, 16 `typecheck_register_program_impl_decls`, 3 `typecheck_register_impl_decls`, across `test_typecheck_decl`, `test_typecheck_impl_decl`, `test_typecheck_impl_defaults`, `test_typecheck_resource_decl` (`test_declaration_boundary.py` also names some) | typecheck stage; identical C |
| A2b.2 | obligation readers compare pinned ids; delete `TraitObligation.trait_name` (the Equatable/HasLength/Stringable arms and 23 `infer.brp` literal compares go) | 860 `should_fail` messages unchanged |
| A2b.3 | impl and supertrait walks by `TraitId`; delete `ImplInstance.trait_name`, `TraitDef.supertraits` Strings; authority dict keys by id | typecheck stage, sanitize |
| A2b.5 | resolved call targets, `TraitMethodCallee`, `trait_functions` by `TraitId` | typecheck stage |
| A2b.6 | typed trait and impl info carry `TraitId` for lowering | Core suites |
| A2b.7 | Core: impl and trait decls, trait calls, DCE keys, `synth_scalar_operator` and `trait_dispatch` literals by id; trait catalog for display; retire M2.3's `CoreImplMethodRole` (callback roles become pinned `(TraitId, NameId)` pairs) | `compiler-core-sanitize`, backend identity |

Order: A2b.1, A2b.4a, A2b.4b, A2b.2, A2b.3, A2b.5, A2b.6, A2b.7. The registration path
used only by tests (`register_trait_decl`, `register_impl_decl`,
`register_impl_with_id`; no production callers) resolves its `TraitId` by name
from the environment. Retiring it (about 75 test call sites) is a separate
cleanup, not part of these slices.

## Lane B: emission by id

| Step | What | Files | Gate | Status |
| --- | --- | --- | --- | --- |
| B0 | Callables and types projected to short symbols; locals with a binder id spelled `brp_v_<id>` / `brp_vn_<id>` | c_symbol_projection.brp, c_naming.brp, emit.brp | audit, oracle | done (f3d5780b, 32307f0d) |
| B1 | Mint binder ids in every pass that created binders with id 0 (Perceus result and view temps, borrow arguments, aggregate fields, tuple SROA, parallel tensor, record update, tensor specialize, match projection, option fusion, SSA, pipelines); then delete the id-0 spelling fallbacks | the passes; then c_naming.brp, c_symbol_projection.brp | audit, oracle, runtime, leak; C bytes | B1a landed (authored binders carry ids at lowering); B1b in review (Perceus and closure-drop temporaries carry an id and origin and are spelled once at creation; small-pass minting and D2 still open, see Interim states); known limitation: packed-loc ids are not unique once std_inline clones a body; the names collide identically, as before; dense ids under Perceus threaded state fix it |
| B2 | Variant constructors and tags spelled `brp_c_<id>` / `brp_t_<id>` from the variant's `def_id`; literal `TAG_` readers removed | c_naming.brp, lower.brp, flatten.brp, mono_data.brp, prepare.brp, emit.brp, specialize*.brp | audit, oracle, runtime, leak; C bytes | done (c19c3392a, self-compile C −9.04%) |
| B3 | Record members spelled by ordinal or field id for non-ABI records; `c_field_name` keeps only the ABI branch | emit.brp field sites, record layout, c_naming.brp | audit, oracle, runtime, leak; C bytes | in review: members are `f<ordinal>` for non-ABI records (`c_record_member_of` / `c_declared_record_member`, decided per record by `CRecordMemberSelector`; C bytes -0.91% against `brp_f_<b62 id>`'s -0.12%, so the ordinal won); ABI records (declared ABI type or reachable from a foreign signature) and `Range`'s `start`/`end` keep source names by design |
| B4 | Closure and task `c_name` / `static_name` deleted; the test-only unprojected emission mode retired | emit.brp, c_symbol_projection.brp, ir.brp closure records, closure.brp, test_core_emit.brp | audit, identical C | after B3 |
| B5 | Variant symbols computed at emission from `def_id` on constructs and match tests, deleting the Core `c_name` / `tag_c_name` Strings kept by B2; `__blorp_reuse_<Type>_` shortened | match_projection.brp, prepare.brp, reuse.brp, emit.brp | identical C | after B1 |

## Interim states on main

Every dual carry or bridge currently on main, with the step that deletes it.
A row leaves this table only when its deletion lands; nothing temporary
becomes permanent by being forgotten.

| Interim state | Introduced by | Deleted by |
| --- | --- | --- |
| `CoreFunction.name` still produced beside `CoreFunction.origin`; readers still parse it | M1.1 (5dfdf344b) | M2.1–M2.6 move readers, M3.1 deletes the producers |
| `origin_name_agreement.brp` invariant reads the mangled markers (`BLORP_ORIGIN_CONTRACT`) | M1.1 | M3.1 |
| `typed_name_identity.brp` census (`BLORP_NAME_IDENTITY`) counts `.text`/id mismatches | A0 (aa5425ed4) | A5, when `.text` is gone |
| `name_spelling_of_text(table, text)` bridge for Core and LSP names held as Strings | A1 (375d637a0) | A5 for Core names; LSP once it reads ids |
| Six temporary cross-owner import permissions for `stage_02_lex/name_table.brp` (format, lsp, test ×2, format/command, lint/command) | A0/A1 | a small step moving `name_table.brp` to `blorp/src/lib` |
| Variant `c_name` / `tag_c_name` Strings and `CoreUnionConstruct.tag_c_name`, spelled from `def_id` at Core construction | B2 (c19c3392a) | B5 computes them at emission from `def_id` |
| `SOURCE_VARIANT_TAG_PREFIX` fallback for a variant without a `def_id` | B2 | B5 |
| `MANGLED_DEF_ID_PREFIX` / `mangled_definition_name` in identity.brp for hoisted-closure names | T5 (f21b59a9d) | M3.1 |
| `c_local_name` escape branches and `c_binder_name`'s id-0 branch, still reached by the small-pass binders below | B0 (32307f0d) | D2, once the small passes mint ids |
| A Perceus or derived temporary's `CoreVar.name` IS its C spelling, built once at creation by `perceus_temporary_spelling`, `perceus_borrowed_result_spelling` and `derived_temporary_spelling`; emission passes it through and the identity contract recomputes it from `(id, origin)` | B1b | Perceus carrying threaded state (dense binder ids), or Phase 4 making names display-only |
| `__perceus_shadow_<name>_<id>_<branch>_<binding>` name of a freshened shadowing match binding (`perceus_shadow_var`, balance.brp): the name is a uniqueness key only, the binding keeps its id and origin so C spells it from the id | B1b | Perceus matching bound variables by id instead of by name |
| `c_naming.brp` imports `ir.brp` for `CoreBinderOrigin`, so a program importing `c_naming` carries the module table's foreign header; the codegen audit adds `-I blorp/src/compiler/stage_04_modules` | B1b | D2/Phase 4, when the spelling functions stop reading `CoreVar` (or `c_naming` splits from the origin type) |
| Small-pass binders still id 0 with a `PassTemporary` or `LoweringTemporary` origin: the `synth_*` passes, `specialize_collection`, `consume_specialize`, `match_projection`, `mono_option`, `record_update`, `ssa`, `tailrec`, `tensor_specialize`, `tuple_sroa`, `parallel_tensor_pipeline`, the tuple-destruct temporary in lowering; `synth_list`'s `Some(__value)` pattern | B1b | each pass mints from `CorePassState.next_binder_id` once it threads state; D2 then deletes the id-0 spelling |
| The unprojected test emission keeps source member names (`UnprojectedSourceMembers`), and `FieldExpr` / `CoreRecordFieldValue` / record-field decls / `CowFieldTakeRetainPolicy` still carry the field name String beside the ref, read only by that mode and by the ABI branch | B3 | B4 retires the unprojected mode; Phase 4 makes the names display-only |
| Synthesis passes read a function's source member name from a copy named after its declaration (`synthesis_declaration_view` in synth_name.brp); `CoreBaseDeclarations` and `CoreCopyDeclarationNames` are rebuilt per pass from the program's origins; the collection and string pipelines keep stripping the `list__` / `string__` module prefix and the UFCS prefix from that declared name | M2.1 | M2.2 (UFCS prefix), M2.4 (module prefix: `SourceFunction(NameId)` on the base declaration replaces the flattened name) |
| `ImplMethod(trait NameId, method NameId)` without impl/trait def ids and type key; program-wide hoist ordinals | M1.1 | M2.3 |
| `CoreFunction.source_module` path String beside `CoreFunction.module`, and `ModuleOrigin` beside the `ModuleId` in `SourceModule` (passes hold no module table); readers that compute flattened names from the path | M2.5a | after M2.4 (M2.5b deletes the String, renders paths from the module table, and decides whether the origin becomes a lookup once a table handle exists) |
| `CoreMonoInstanceIndex` buckets instances by a structural hash in a `Dict[Int, ...]` instead of keying a `Dict` by `CoreMonoInstanceKey`, because a `Dict` with custom `Hashable` keys bound to variables misses equal keys (filed as "Fix Dict lookup miss for custom Hashable keys bound to variables"; reproduction `/private/tmp/claude-501/scratch/dict_key_repro`) | M1.2 | Key the `Dict` by `CoreMonoInstanceKey` once that bug is fixed |
| `__ufcs_<module>__<name>` spelling still produced as the callee variable name (`core_ufcs_function_name` in `identity.brp`, `lower.brp`, `graph_prepare.brp`, flatten's alias names, the two pipeline prefix literals); no reader decodes it any more | M2.2 | M3.1 deletes the producers |
| `CoreImplMethodRole` on `ImplMethod` (and the pinned `NAME_ID_*` callback constants) stands in for the trait identity of Stringable, Hashable and Equatable | M2.3 | Typed impls carrying trait definition ids: the payload becomes `(trait DefinitionId, method NameId)` and the enum, `impl_method_role` and the constants go |
| `CoreRuntimeCallbackTable` keyed by the rendered `core_trait_impl_type_key` String | M2.3 | D9 (type ids): key on the target type's id |
| Origin payloads that hold a `CoreType` go stale when flatten renames types (precondition: write them after flatten, as `ProjectedImplMethod` and `MonoInstance` are, or use ids) | M2.3 | Type ids (D9) |
| Span-derived positive binder ids for authored binders | B0/B1a | A1b (parser-minted ids) |
| One sigil read left in `type_parameter_name_kind` (`List[String]` type parameters) | D7 (230835a0b) | type interning, when type-parameter lists carry kinds |
| `--dump-core` JSON carries both name Strings and ids | A0 | A5 |
| `.text` reads left after A4c: 13 name-data copies in `stage_07_ctfe/ir.brp` (CTFE IR bindings and assignment targets) and 2 key comparisons in `typed_ast_json.brp` | A4c | A5 (when CTFE IR and those keys carry ids) |
| Standalone graphs (`graph_source_name_table_for_programs`) give identifiers ids from private per-program tables; rendering there is `.text`-only (`SpellingsFromIdentifierText`) | A4a | before A5: standalone graphs share the discovery table |
| `.text` lookups in type header resolution (`declared_unqualified_type`, `type_header_graph_has_unqualified_type_name`, `resolve_named_type`) kept beside `identifier.name` for import, alias and parameter lookups keyed by String | A2 | A4/A5 |
| trait name Strings beside `TraitId` in `TraitDef`, `ImplInstance` (`TraitObligation.trait_name` unchanged; it waits for bound identities, A2b.4) | A2b.1 | A2b.2-A2b.3 |
| `BoundTypeParam.bounds` Strings derived from `bound_identities` (about 14 readers in env, authority, typed AST JSON, lower, mono, infer still read the spelling) | A2b.4a | A2b.2-A2b.3 |
| by-name bound resolution through `Env` (`bound_identity_for_trait_name`) for test-only registration and standalone bodies | A2b.4a | A2b.4b |

## Finished branches waiting to land

B1a (`core/t7-mint-synthetic-binders`, merging main). T10, T5, D7, the LSP
fix, A1 and M1.1 have landed.

## Appendix: the catalog

`benchmarks/results/name_string_catalog_2026-09-28.md` lists every
name-bearing String, derived name, string-keyed table and `.text` reader
found after A0, with the tidy-up tasks T1–T10, convertible items C1–C8 and
"dead after" items D1–D9. This roadmap supersedes its task order:

- T1, T4 and T9 are A1, A2 and A4/A5. T5 is landing. T2 and T3 landed.
- D1/D2 are B1; D5 is B4; D6 is B2; D4 is B3; D3 follows B1 and A3; D7 is
  landing; D8 is A4/A5; D9 belongs to the type-interning roadmap.
- T6 (payload `CoreType`) is A3.3. The rest of T10 (CTFE environment keys,
  `module_member_prefixes`), C6 and C8 wait until both lanes are done.
