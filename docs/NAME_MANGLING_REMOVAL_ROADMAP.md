# Name Mangling Removal Roadmap

Goal: no reader in the compiler learns a fact from the shape of a String.
Every fact that a prefix, suffix, marker or embedded number carries today
lives in a record field, an enum or an id. Mangled names become display
text and then disappear.

This is Lane A step A3 of [`NAME_ID_ROADMAP.md`](NAME_ID_ROADMAP.md),
expanded into steps that are each small, independently reviewable and
provable. The families and the file:line inventory come from
`benchmarks/results/magic_spelling_census_2026-09-28.md`; the allowlist
of `scripts/check-magic-spellings` is the progress meter. A step is
complete when the allowlist lines it owns are deleted, `make
hygiene-check` passes, and the generated C is byte-identical.

## Why each step is easy

Three properties make the steps mechanical:

1. **Add the fact beside the name first, move readers, delete the name
   last.** Every function, binder and symbol is created at a known site,
   so recording the fact costs one field write per producer. Readers
   then move one family at a time while the name is still there, so a
   wrong conversion shows up as a test failure, not a silent change.
2. **Identity already exists.** `def_id`, binder ids, `CoreFieldRef`,
   `NameId` and `ModuleId` are in place. What mangling still carries is
   classification and, for mono instances, a missing fresh id.
3. **Byte-identical C is free for every step.** Emission spells symbols
   from ids, so nothing here touches the artifact until the deletion
   commits, and those delete Strings the emitter never read.

Gate for every step unless stated: owning suites, `scripts/compiler-check
--changed`, `benchmarks/self_compile_measure --stage2 --require-identical`
(self and `--program small`) against a parent frozen at the branch base,
and the allowlist delta named in the step.

## Phase 0: guard rails (landing)

| Step | What | Files | Evidence |
| --- | --- | --- | --- |
| M0.1 | Census of every shape reader and marker producer; `scripts/check-magic-spellings` with an allowlist, hooked into `make hygiene-check`, failing on any new shape test | `benchmarks/results/magic_spelling_census_2026-09-28.md`, `scripts/check-magic-spellings`, `scripts/check-magic-spellings.allowlist`, `Makefile`, `scripts/README.md` | `docs/magic-spelling-census` 8ef75d41f; 254 reader sites, 294 producers in 20 families |

## Phase 1: make the change easy

| Step | What | Files | Why it is easy | Allowlist |
| --- | --- | --- | --- | --- |
| M1.1 (done, 5dfdf344b) | `CoreFunction.origin: CoreFunctionOrigin`, written at every creation site while the name is still produced. `CoreFunctionOrigin` is `Declared(CoreDeclaredOrigin)` or `Synthesized(kind, declared_as: CoreDeclaredOrigin)`, so synthesis keeps how the function was declared and cannot nest. `CoreDeclaredOrigin` is `SourceFunction(name: NameId)`, `ImplMethod(trait, method: NameId, role)` (with `ProjectedImplMethod(trait, method, for_type, role)` once runtime projection has turned the impl into functions, M2.3), `PureVariant(base_def)`, `MonoInstance(base_def, arguments)`, `HoistedLambda(enclosing_def, ordinal)`, `HoistedTask(enclosing_def, ordinal)`, `EtaExpansion(target_def)` and `Entrypoint(kind)`. There is no `UfcsWrapper` or `StaticCallback` (no Core function is created for either) and no module payload yet (`SourceFunction` and `ImplMethod` are interim until M2.5 and M2.3). The JSON codec encodes and decodes it, so `--dump-core` prints it. A pass-runner invariant checks that `origin` and the mangled name agree while both exist | `ir.brp`, `lower.brp` (function lowering), `flatten.brp` (pure variant), `mono_specialize.brp`, `synth.brp`, `closure.brp`, `consume_specialize.brp` and `perceus.brp` (copy the origin), `entrypoint.brp`, `pass_runner.brp` | one write per producer; no reader changes; the invariant proves the field is right before anyone depends on it | none deleted |
| M1.2 | Mono instance identity by id. Fresh ids already existed (`CorePassState.next_def_id`); what landed: requests deduplicated by `CoreMonoInstanceKey` (base `def_id` plus the closed arguments by parameter position) in `mono_instance.brp`, kept across the mono fixpoint (11 duplicate instances gone); calls and self references retargeted by `SelectedDirectCall(instance.def_id)` with an id-less callee variable; the instance spelling is produced once at mint time. Flatten's `CallableRewriteIndex` name check was left for M2.2, which removed it (below) | `mono.brp`, `mono_instance.brp`, `mono_specialize.brp`, `early_invariants.brp` | self-compile instructions -0.43%, mono allocations -12%; C equal to the parent up to symbol renumbering and function order | none deleted |
| M1.3 | Pinned `(ModuleId, NameId)` constants for the qualified function literals the pipelines test (`vector__sqrt`, `float__abs`, ... nine) and the two module prefixes (`list`, `string`), from A1's constant module | `name_table.brp`, a small `stage_09_core/known_functions.brp` | constants only; readers move in M2.4 | none deleted |

## Phase 2: move readers, one family per step

Each step converts every reader of one family to `origin`, deletes that
family's allowlist lines, and leaves the producers alone.

| Step | Family | Readers to convert | Files | Allowlist lines |
| --- | --- | --- | --- | --- |
| M2.1 | F1 mono marker and pure suffix | `mono_name_base`, `strip_pure_suffix`, `is_pure_variant_name` and their calls in `resolve.brp` (`source_name_for_function`), `std_inline.brp` (`source_name`), `collection_plan.brp`, `string_pipeline.brp` | `synth_name.brp`, `resolve.brp`, `std_inline.brp`, `collection_plan.brp`, `string_pipeline.brp` | 12 |
| M2.2 | F3 UFCS prefix. Landed: every reader asks the definition id, and no new fact type was added, because the id already names the callee (a `CoreVar` field would touch about 559 literals; a probe found no id hit whose name differed, and no id shared by two rewrites, in the self-compile). Flatten's reference-side name check is gone (`CallableRewriteIndex` is `Dict[Int, CallableRewrite]`), `resolve.brp`'s `explicit_ufcs_call`, mono's UFCS callee-identity match, and the trait/impl name equalities are deleted, together with `is_core_ufcs_function_name` and `core_ufcs_source_name_for_module`. Function definition ids are unique by contract: `DuplicateFunctionDefinitionId` (early, under `--check-invariants`) and the always-on `DuplicateDefinitionId` (late) reject reuse, so the per-id collision lists in mono and flatten are deleted. Producers of the `__ufcs_` spelling (`core_ufcs_function_name`, `lower.brp`, the two pipeline prefix literals) stay until M3.1. Self-compile instructions -0.16%, allocations -0.18%, allowlist -11 | `flatten.brp`, `resolve.brp`, `mono_specialize.brp`, `mono_impl.brp`, `trait_resolve.brp`, `origin_name_agreement.brp`, `identity.brp`, `early_invariants.brp` | identical C | 11 allowlist lines |
| M2.3 (done) | F4 trait-method prefix. Landed: `CoreRuntimeCallbackRole` (Stringable.to_string, Hashable.hash, Equatable.equals) decided once in `lower.brp` from pinned `NAME_ID_*` constants and carried on `ImplMethod`; `ProjectedImplMethod` (adds the impl's target `CoreType`, written by runtime projection); `CoreRuntimeCallbackTable` in `runtime_callbacks.brp`, built once per program and read by `backend_projection.brp` and `prepare.brp`. Deleted: the `runtime_projection.brp` idempotence guard, `find_function_name`, the `Stringable_to_string_`/`Hashable_hash_`/`Equatable_equals_` lookup builders, the `function_names` scan. Duplicate implementations of one role on one type are rejected by the always-on definition-id check. Still open: the `HasLength_length_*` tests in the two pipelines (M2.1/M2.4), and the `Trait_method_TypeKey` producers (M3.1) | `runtime_projection.brp`, `backend_projection.brp`, `prepare.brp`, `runtime_callbacks.brp`, `lower.brp`, `ir.brp` | identical C; allowlist -2 | 2 readers deleted |
| M2.4 | F2 module-member prefix | `synthesis_source_name` / `is_synthesis_candidate` in the eleven `synth_*` passes and `synth.brp`, `parallel_tensor_pipeline.brp`; prefix strips in `identity.brp`, `resolve.brp`, `std_inline.brp`, `collection_plan.brp`, `string_pipeline.brp`, `synth.brp`; built-name equality in `mono_option.brp`, `mono_impl.brp`; the nine `vector__*` / `float__*` literals in `tensor_specialize.brp` | the eleven synth passes (one commit each is acceptable), `synth_name.brp`, the five strip sites, `tensor_specialize.brp` | 59 |
| M2.5a | F15 module origin, add beside | `CoreFunction.module: CoreModuleOrigin` (`SourceModule(ModuleId, ModuleOrigin)` or `NoSourceModule`) written at lowering, entrypoint and closure hoists and copied everywhere else; `SourceFunction` carries it; the agreement invariant checks it against the path String and, in the early passes, the module table (`CorePassControl.modules`); `std_inline.brp` `owned_module` reads it. The other F15 sites test import-request syntax (`pkg/`, `./`, `../`) or produce the origin from a request, so they stay, each with a one-line comment: `frontend_import_plan.brp`, `lib/source_graph.brp`, LSP `source_loader.brp`, `lint/command.brp` (a `.brp` file path test) | `ir.brp`, `lower.brp`, `entrypoint.brp`, `closure.brp`, `std_inline.brp`, `origin_name_agreement.brp`, `pass_runner.brp`, the five files above | the path String stays, so no other reader moves and the C is unchanged | 1 (`owned_module`) |
| M2.5b | F15 module origin, delete the String | delete `CoreFunction.source_module`; passes that spell flattened names from the path get them from `origin` (M2.1, M2.4) or the module table; `--dump-core` and diagnostics render the path from the module table | `ir.brp` and every reader of `source_module` | after M2.4 | 0 |
| M2.6 | F5 `__def_` reader and F16 builtin name prefixes | `variable_has_cleanup_slot` already reads `def_id` (landed in T5); `blorp_filter_map_parallel*`, `blorp_vector_get_opt_*`, `blorp_dict_get*` tests become rows of the builtin registry (`BuiltinFamily`) | `backend_projection.brp`, `specialize.brp`, `specialize_collection.brp`, `builtin_registry.brp` | 6 |

After M2.6 no production reader parses a function name. `synth_name.brp`
is reduced to the display renderer.

## Phase 3: delete the producers

| Step | What | Files | Evidence |
| --- | --- | --- | --- |
| M3.1 | Mono, identity, closure and lowering stop building marked names; `CoreFunction.name` is written from a single display renderer `core_function_display_name(origin, names)` used only by diagnostics, invariants and `--dump-core`. Delete `MONO_NAME_MARKER`, `CORE_PURE_OVERLOAD_SUFFIX`, `CORE_MODULE_NAME_SEPARATOR`, the UFCS prefix constants, the closure prefixes, and the M1.1 agreement invariant | `mono.brp`, `identity.brp`, `closure.brp`, `lower.brp`, `synth_name.brp`, `entrypoint.brp` (the two exported names stay, in fields named for it) | identical C; F1 to F5 producer lines gone from the allowlist |
| M3.2 | `CoreFunction.name` becomes `NameId` or is deleted where `origin` renders it; `--dump-core` joins the name table | `ir.brp`, JSON codec, dump tests | identical C; this is Lane A step A5 for functions |

## Phase 4: binders (after Lane B step B1)

| Step | What | Files | Allowlist |
| --- | --- | --- | --- |
| M4.1 | `CoreVar.origin: CoreBinderOrigin` (`Authored(NameId)`, `PassTemporary(pass)`, `DerivedFrom(binder_id)`, `LoweringTemporary(kind)`), written where B1 mints the id; the `$blorp$...`, `__cdrop_`, `__perceus_shadow_`, `__qb_`, `__td_`, `__loop_`, `__timeout_`, `__pattern_param_`, `__record_update_` spellings stop being built | the passes B1 touched, `lower.brp` binder sites, `closure.brp` | F7 22 producers, F8 9 producers |
| M4.2 | `c_local_name` and its escape branches deleted; `is_compact_temp_c_name`, `COMPILER_LOCAL_PREFIX`, `__blorp_internal_` go; `c_field_name` keeps `__blorp_field_` for ABI records only | `c_naming.brp`, `c_symbol_projection.brp` | F9 (catalog D2) |
| M4.3 | `__nested_<parent>_<name>_<id>` becomes `ParsedFunctionOrigin.NestedIn(parent_def)` with a fresh definition id | `source_ast_finalize.brp` | F8 remainder |

## Phase 5: types

| Step | What | Files | Allowlist |
| --- | --- | --- | --- |
| M5.1 | Payload `CoreType` in `CoreStackOptionRepresentation`, `StructBox`, the inline-struct and boxed-element storage variants; the emitter renders the C type; delete `resolved_stack_option_type_name`, `resolved_inline_struct_c_type`, `resolved_boxed_element_c_type` and the nine copies of the `blorp_StackOption_` spelling (census in the T6 report, `benchmarks/results/`; `blorp_StackResult` is an ABI constant and stays). The `StackOption*ConstructorTest(String)` variants in `match_projection.brp` carry the type | `c_type_layout.brp`, `list_layout.brp`, `prepare.brp`, `collection_pipeline.brp`, `specialize_collection.brp`, `specialize_layout.brp`, `synth_list.brp`, `match_projection.brp`, `emit.brp` | F11 (10 readers, 15 producers) |
| M5.2 | Packed-enum `to_string` becomes a `CoreCallKind` case carrying the enum type; the `_f64`/`_f32` width becomes a field of the checked-get call | `specialize_value.brp`, `specialize_tensor_dispatch.brp`, `emit.brp`, `ownership.brp` | F11 remainder |
| M5.3 | Qualified type names: type references carry the type's `DefinitionId` (or `ModuleId` plus `NameId`); the 98 literal triples (`Stream` / `stream::Stream` / `stream__Stream`) in `operation_metadata.brp`, `c_type_layout.brp`, `unmanaged_type.brp`, `type_policy.brp`, `type_name_metadata.brp`, `prepare.brp` become comparisons with pinned type ids; `split_canonical_module_type_name` and `identity.brp`'s second `::` parser delete | shared with the type-interning roadmap (D9); the pinned-id literal conversion can go first as its own step | F12 (101) |
| M5.4 | Dimension sigil: route `mono.brp:367` through the kind, then delete `type_parameter_name_kind`'s sigil read once `List[String]` type-parameter lists carry kinds | `mono.brp`, `semantic_type.brp` | F13 (32) |
| M5.5 | Tuple field access parsed as `NamedField(NameId) \| TupleIndex(Int)` by the parser; the five decimal readers go | `parsed_ast.brp`, `language_parser.brp`, `infer.brp`, CTFE `ir.brp`, `lower.brp`, formatter | F14 (5) |

## Phase 6: emitter temporaries

| Step | What | Files | Allowlist |
| --- | --- | --- | --- |
| M6.1 | The 169 `__x_<seed>` emitter temporaries use the existing compact temp scheme driven by an `EmitterTempKind` enum; `is_generated_temp_value` becomes an explicit field set where the temp is created | `emit.brp`, `prepared_*_renderer.brp` | F18 (169 producers, 1 reader) |

## Order and parallelism

- Phase 1 first, serial: M1.1 then M1.2 then M1.3. M1.1 is the enabling
  change; nothing in Phase 2 can start without it.
- Phase 2 steps are disjoint in files except `resolve.brp`, `std_inline.brp`,
  `collection_plan.brp`, `string_pipeline.brp`, which M2.1, M2.2 and M2.4
  all touch: run those three serially, M2.3 and M2.5 in parallel with them.
- Phase 3 after all of Phase 2.
- Phase 4 after Lane B step B1 lands; Phase 5 and 6 are independent of
  Phases 1 to 4 and can run whenever an emitter slot is free (M5.1 waits
  for B1 because of `match_projection.brp`).
- At most three workers at once; one landing at a time.

## Must stay

Exported entrypoints (`$blorp$program`, `$blorp$user_main_<id>`), FFI and
`builtin("...")` names, `c_identifier` escaping against the C vocabulary,
ABI record member names, static string literal contents, module file paths
and import request strings, diagnostic text, Core JSON field names. Each
lives in a field whose name says what it is (`c_name`, `abi_name`, `path`).
