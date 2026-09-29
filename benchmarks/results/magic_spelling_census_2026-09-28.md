# Magic-spelling census

Date: 2026-09-28. Roadmap step A3.0 (`docs/NAME_ID_ROADMAP.md` on
`docs/name-id-roadmap`). Read-only pass over `blorp/src` at `origin/main`
`6c9f72c62`, refreshed after D6 (`c19c3392a`, variant symbols from definition ids); no compiler source changed. Line numbers are for that commit.
Folds in `name_text_inspection_census_2026-09-28.md` and sections 2 and 5 of
`name_string_catalog_2026-09-28.md`; several of their rows no longer exist
(see "Already dead or gone").

Rule under test: no reader may learn a fact from the shape of a String. A
prefix, suffix, marker or embedded number that a name-like String carries must
be a record field, enum or id.

## Reproduce

```bash
python3 scripts/check-magic-spellings            # exit 0 on origin/main; 1 on a new finding
python3 scripts/check-magic-spellings --report   # the counts below
python3 scripts/check-magic-spellings --update   # regenerate the allowlist after deleting a reader
```

The script is read-only Python, scans `blorp/src/**/*.brp`, and compares
findings with `scripts/check-magic-spellings.allowlist` (583 lines: file, role,
rule, line text). It is wired into `make hygiene-check`, next to
`scripts/check-std-builtins`. A probe `name.starts_with("__probe_")` appended to
`stage_09_core/dce.brp` made it exit 1 and print the file, line and rule; the
probe was reverted.

Rules (a finding is one line matching one rule):

- readers: `starts_with`, `ends_with`, `raw_index_of`/`last_index_of`, `split`,
  `parse_int`, `contains(<literal or CONSTANT>)`, `drop_left`/`substring` sized
  by a `*prefix*`/`*MARKER*`/`*SUFFIX*` value, a `"module::Type"` or
  `"module__Type"` literal, and `==` against a `core_*_name(...)` builder.
- accessor calls (readers by proxy): the 22 named decoders in `ACCESSOR_NAMES`
  (`mono_name_base`, `strip_pure_suffix`, `synthesis_source_name`,
  `is_synthesis_candidate`, `is_dim_var_name`, ...). Keyed by accessor name, so
  reformatting a call does not churn the allowlist. A twelfth synthesis pass
  calling `synthesis_source_name` is therefore a new finding.
- producers: `*PREFIX/SUFFIX/MARKER/SEPARATOR` constants and their
  concatenation, bare name-shaped literals starting `__x`, `$blorp$`, `_blorp_`,
  `TAG_`, `blorp_StackOption_`, `blorp_vector_to_string_` joined to another
  value, `name = "__..."` binders, `"TAG_..."` literals, `"#" +`.

Skipped on purpose: generated build inputs (`compiler/stage_01_generated_inputs/`, which embeds the standard library and build info and is absent in some checkouts; excluded by path in `IGNORED_FILE_PATTERNS`, not by allowlist), files whose Strings are host paths, CLI text, wire
protocol, layout text, manifests, tests or the CTFE interpreter's user-string
builtins (`IGNORED_FILE_PATTERNS`), and calls whose argument is a file
extension, `"/"`, a newline, a space or C punctuation (`TEXT_ARGUMENT`).

### Precision and blind spots

- 190 readers reported; 23 are not name-shape tests: 10 dictionary or list
  membership calls with a literal (`identities.contains("traits")`, F0) and 13
  integer-literal `parse_int` calls (F17). Reader precision is 167/190 = 88%.
  Producers: 2 of 294 are producer-only keys that nothing parses (F19).
- `c_naming.brp:273` (`contains(COMPILER_LOCAL_PREFIX)`) is a real marker
  reader that the `contains` rule finds; the report files it under F9, not F0.
  `emit.brp:2824` scans emitted C text and stays (F0, must stay).
- Not detected, deliberately: `==` and `match` arms against a closed literal
  vocabulary (typecheck, Core, backend; roadmap A2 owns them) and
  `blorp_*` runtime names compared for equality (builtin registry, A2).
- Not detected, by construction: a decoder that is not in `ACCESSOR_NAMES`
  and does not use one of the string operations above. Add new decoders to the
  list when a step introduces them.
- Producer count includes 169 lines (F18) that only spell emitted-C temporaries;
  they are display-only today and listed for completeness.

## 1. Families

Owners use the roadmap's step names: A3.1 functions, A3.2 binders, A3.3 C type
strings, B5 variant symbols, TI type interning (the `docs/` type-interning
roadmap; D9 in the catalog). Where no roadmap step exists a new step is
proposed and marked NEW.

### F1 mono marker and pure suffix

Fact encoded: "this function is a monomorphic instance of base X" and "this is
the pure overload of X".

| Marker | Producers | Readers |
| --- | --- | --- |
| `__mono_` (`MONO_NAME_MARKER`), then `sig_` + encoded | `mono.brp:1299,1357,1360,1363`; constant `synth_name.brp:23` | `synth_name.brp:37,57` (`last_index_of`, `mono_name_base`); accessor calls `resolve.brp:377`, `std_inline.brp:245`, `collection_plan.brp:119`, `string_pipeline.brp:413`, `synth_name.brp:99` |
| `__pure` (`PURE_NAME_SUFFIX`, `CORE_PURE_OVERLOAD_SUFFIX`, two copies) | `identity.brp:99,106`; constant `synth_name.brp:28` | `synth_name.brp:69` (`ends_with`), `strip_pure_suffix` calls `resolve.brp:391`, `std_inline.brp:255`, `collection_plan.brp:127`, `synth_name.brp:99` |

Replace with: `CoreFunction.origin` cases `MonoInstance(base_def_id, type_args)` and
`PureVariant(base_def_id)`, plus an instantiation-specific `def_id`. Readers
ask `origin`, not the name. Two markers with one encoded suffix also lose the
"a name can carry the marker twice" rule in `synth_name.brp:46`. Owner: A3.1.

Temporary readers (M1.1): `origin_name_agreement.brp` calls `mono_name_base`,
`strip_pure_suffix` and `is_core_ufcs_function_name`, and tests the closure and
entrypoint prefixes, to prove `CoreFunction.origin` agrees with the name on the
frozen self-compile. Its 11 allowlist lines and the `USER_MAIN_NAME_PREFIX`
export die in M3.1 with the markers.
Delete both duplicated suffix constants in the last A3.1 commit.

### F2 module-member prefix and flattened names

Fact encoded: "this Core function is member `m` of module `M`", written
`<sanitized M>__m`, with `list__` and `string__` as the two module prefixes the
pipelines test.

| Producers | Readers |
| --- | --- |
| `identity.brp:10,85` (`CORE_MODULE_NAME_SEPARATOR`, `core_module_member_prefix`, `core_module_member_name*`); `string_pipeline.brp:170` (unrelated local prefix) | prefix strips: `identity.brp:137,140`, `collection_plan.brp:104,105`, `resolve.brp:381`, `std_inline.brp:247`, `string_pipeline.brp:401`, `synth.brp:105`, `synth_name.brp:92` |
| | accessor calls: `synthesis_source_name` and `is_synthesis_candidate` in eleven passes (`synth_bytes:867/872`, `synth_fixed:314/319`, `synth_float:92/97`, `synth_forward:503/507`, `synth_hash_collections:2961/2969`, `synth_list:5694/5699`, `synth_parallel_tensor:79/84`, `synth_scalar_operator:276/279`, `synth_slice:500/505`, `synth_string:3454/3459`, `synth_tensor:697/702`), `synth.brp:65`, `parallel_tensor_pipeline.brp:179`; `source_name_for_function` `resolve.brp:413,446,601,652`; `collection_pipeline_base_name` `collection_plan.brp:158`; `base_string_function_name` `string_pipeline.brp:432,441`; `strip_prefix`/`strip_supported_prefix` `collection_plan.brp:121,125`, `string_pipeline.brp:415,419` |
| | equality against a built name: `mono_option.brp:50,52,54,56`, `mono_impl.brp:562` |
| | qualified-function literals: `tensor_specialize.brp` `"vector__sqrt"`, `"vector__norm"`, `"vector__log"`, `"vector__exp"`, `"vector__abs"`, `"float__sqrt"`, `"float__log"`, `"float__exp"`, `"float__abs"` (9) |

Replace with: `CoreFunction.origin = SourceFunction{ module: ModuleId, name: NameId }`
(and `ImplMethod{ module, trait, method }`). Synthesis, resolve, std_inline and
the two pipelines match on `origin` plus an id-keyed builtin table, so the
eleven `synthesis_source_name` calls become one `origin` read each and
`synth_name.brp` shrinks to `is_synthesis_candidate`. The nine `vector__*` /
`float__*` literals become `(ModuleId, NameId)` constants (A1 pinned ids).
Owner: A3.1, with the literal table on A2.

### F3 UFCS prefix

Fact: "this call target is a UFCS wrapper of module M's function f", written
`__ufcs_<M with / -> $>__f`.

| Producers | Readers |
| --- | --- |
| `identity.brp:12,14,85`; use at `lower.brp:1000,1061` | `identity.brp:117` (`starts_with`), `is_core_ufcs_function_name` `flatten.brp:400`, `resolve.brp:1558`; `core_ufcs_source_name_for_module` `resolve.brp:1564`, `mono_specialize.brp:543`; equality against the built name `trait_resolve.brp:671`, `mono_impl.brp:563`; prefix literals `collection_plan.brp:125`, `string_pipeline.brp:419` |

Replace with: `CoreFunction.origin = UfcsWrapper{ target_def_id }`; call targets
already resolve to a `def_id`, so `mono_specialize`, `resolve` and
`trait_resolve` compare ids. The identity.brp doc comment already says the
unflattened source name should travel with Core. Owner: A3.1.

### F4 trait-method prefix

Fact: "method `m` of trait T for type K", written `<T>_<m>_<K>`.

| Producers | Readers |
| --- | --- |
| `runtime_projection.brp:169` (`"${trait}_${method}_${type_key}"`); lookup builders `backend_projection.brp:399-400`, `prepare.brp:3192-3201` (`"Hashable_hash_" + name`, `"Equatable_equals_" + name`) | `runtime_projection.brp:167` (idempotence guard `starts_with(trait_name + "_")`, misfires on a method literally named `Trait_x`); `backend_projection.brp:152` (`ends_with("_" + expected)`); `collection_plan.brp:133`, `string_pipeline.brp:423` (`starts_with("HasLength_length_List"/"..._String")`) |

Replace with: `CoreFunction.origin = ImplMethod{ impl_def_id, method_def_id }`.
The runtime projection is keyed by `def_id` (idempotent by construction, no
prefix test); the hash/equals lookups and the `length` pipelines match on the
method's `def_id`. Owner: A3.1.

### F5 hoisted callables and definition-id spellings

Fact: "this function is a lifted lambda / task / eta wrapper / static closure",
and "this name is a constructor or function value projected as a C rvalue".

| Marker | Producers | Readers |
| --- | --- | --- |
| `_blorp_clambda_<n>`, `_blorp_task_<n>`, `_blorp_eta_<n>` | `closure.brp:215-219,1748,1765,1782` | none in the compiler (the C symbol is projected by `def_id`); the strings are display only |
| `__sc_<c_name>` (static closure) | `closure.brp:223,587`, `c_naming.brp:291` | none (`c_symbol_projection.brp:251` re-derives via `static_closure_name`) |
| `__def_<id>_<name>` | `lower.brp:6030`, `prepare.brp:3572`, `mono_data.brp:857`, `closure.brp:221,583`, `emit.brp:996` (constant duplicated) | `emit.brp:13450` (`variable_has_cleanup_slot`: `not name.starts_with("__def_")`) |
| `__eta_arg_<i>` | `closure.brp:3390` | none |
| `__blorp_task_window_cleanup_<n>` | `emit.brp:16207` | none |

Replace with: `CoreFunction.origin` cases `HoistedLambda`, `HoistedTask`,
`EtaExpansion`, `StaticCallback` (payload `def_id` of the enclosing function
and a per-function ordinal); `variable_has_cleanup_slot` reads
`CoreVar.def_id.is_some()` or a `CoreVarKind` (`Local | DefinitionValue`)
instead of a prefix (the code comment at `emit.brp:13448` already asks for an
explicit bit). The name strings become display-only, then are deleted. Owners:
A3.1 (callables), B4 (`static_name`, `c_name`), A3.2 (`__def_` reader).

### F6 entrypoints

`$blorp$program` (`entrypoint.brp:23`) and `$blorp$user_main_<def_id>`
(`entrypoint.brp:25,219`). No reader by shape. "Must stay" (exported).

### F7 pass-created binder names

Fact carried: pass identity and, for several, another binder's name and id
(`__cdrop_<x>`, `__perceus_shadow_<x>_<id>_<i>_<j>`), so a reader could
recover them; none does except the C-name collision guard in F9.

| Marker | Producers |
| --- | --- |
| `$blorp$collection_pipeline$<len>$<label>$<n>` | `collection_pipeline.brp:105,168` |
| `$blorp$string_pipeline$...` | `string_pipeline.brp:65,170` |
| `$blorp$tuple_sroa$<label>$<n>` | `tuple_sroa.brp:169,248` |
| `$blorp$parallel_tensor$<label>$<n>` | `parallel_tensor_pipeline.brp:32,575` |
| `$blorp$record_update$field$<x>$<id>$<i>` | `record_update.brp:65,523` |
| `$blorp$perceus$owned_result` | `perceus/results_and_loops.brp:3564,3566` |
| `$blorp$match_scrut$<owner_def_id>$<span>$<depth>` | `match_projection.brp:1249,1256` |
| `__blorp_option_fusion_<seed>_<label>` | `mono_option.brp:97` |
| `__tensor_raw_view_<x>_<id>` | `tensor_specialize.brp:1168` |
| `__cdrop_<x>` | `closure.brp:3240`, `perceus/balance.brp:289` |
| `__perceus_shadow_...`, `__assign_<x>_<id>_<i>` | `perceus/balance.brp:1749`, `perceus/mutable.brp:340` |
| `__std_inline_<x>`, `__consume_result_<x>`, `__tailrec_list_index_<n>` | `std_inline.brp:424`, `consume_specialize.brp:1390`, `tailrec.brp:830` |

Replace with: `CoreVar.origin: CoreBinderOrigin` (`Authored`, `PassTemporary(pass)`,
`DerivedFrom(binder_id)`, ...) and a minted binder id (B1). The spelling is
then display-only and the C name comes from the id. Owner: A3.2 after B1.
The roadmap text says "Perceus and cleanup readers recognise their own
temporaries by prefix"; on this commit no such reader exists. The only reader
of the `$blorp$` shape is `c_local_name` (F9), so A3.2 reduces to minting
origins and deleting producers.

### F8 front-end and lowering temporaries

| Marker | Producers |
| --- | --- |
| `__nested_<parent>_<name>_<id>` | `source_ast_finalize.brp:1505` |
| `__resource_<label>_<start>` | `infer.brp:19599` |
| `__qb_`, `__td_`, `__loop_`, `__timeout_`, `__pattern_param_<i>_<start>`, `__record_update_<start>` | `lower.brp:1555,1561,1567,2394,2868,5568,5590` |

No readers. Uniqueness comes from a source offset in the text
(`core_binder_id` = start offset + 1: unique per file). Replace with a minted
binder id and `CoreBinderOrigin.LoweringTemporary(kind)`; `__nested_` becomes
`ParsedFunctionOrigin.NestedIn(parent_id)` with a fresh definition id.
Owners: A3.2 and B1.

### F9 C local spelling guards

| Marker | Producers | Readers |
| --- | --- | --- |
| `$blorp$` (`COMPILER_LOCAL_PREFIX`) -> `__blorp_internal_` | `c_naming.brp:113,115,274` | `c_naming.brp:273` (`contains`) |
| `__t<kind>_<n>` compact temp | `c_naming.brp:122` | `c_naming.brp:138,279` (`is_compact_temp_c_name`) |
| `__blorp_canonical_empty_list_`, `__blorp_source_` | `c_naming.brp:117,124,283`, `canonical_empty_list.brp:41,47,53` | `c_naming.brp:280,281` |
| `__blorp_field_` | `c_naming.brp:111,193` | `c_naming.brp:191` |
| any `__...` C temp | (F18) | `emit.brp:13165` (`is_generated_temp_value`, then eight character scans), `emit.brp:13186` |

Replace with: after B1 every local has a binder id and is spelled
`brp_v_<id>`/`brp_vn_<id>`, so `c_local_name` and its four escape branches
delete (D2 in the catalog). `is_generated_temp_value` becomes an explicit
`FunctionBodyC.value_is_temp` field set where the temp is created. Owner: B1
for locals, and NEW step B6 for the emitter temp field. `c_field_name` keeps
`__blorp_field_` only for ABI records (B3).

### F10 variant, reuse, static and closure-env symbols

After D6 (`c19c3392a`) variant constructors and tags are spelled from the
variant's `def_id` as `brp_c_<id>` / `brp_t_<id>`; the `TAG_<type>_<variant>`
producers in `lower.brp`, `flatten.brp` and `mono_data.brp`, the `__def_`
variant spellings, and the `TAG_Some` / `TAG_Option_Some` literals are gone.

| Marker | Producers | Readers |
| --- | --- | --- |
| `TAG_<type>_<variant>` fallback (`SOURCE_VARIANT_TAG_PREFIX`) for variants without a `def_id` | `c_naming.brp:286,302` | none by shape |
| `__blorp_reuse_<type>_<ctor>` | `reuse.brp:3600`, `c_naming.brp` (two authorities) | none |
| `__blorp_static_{record,tuple,union,list}_<path>` | `c_naming.brp` | none |
| `__blorp_closure_env_[destroy_]<c_name>` | `emit.brp` | none |

Replace with: reuse names from `(type def_id, variant def_id)` computed once at
emission, deleting the `TAG_` fallback once every variant carries a `def_id`
(B5); static and closure-env names from `def_id` plus child ordinal (B3/B4).

### F11 C type strings

Fact: "this C type is `Option` of payload P", "this element type is boxed
(`*`)", "this enum has a packed vector `to_string`", "this scalar builtin is
the f64/f32 variant".

| Marker | Producers | Readers |
| --- | --- | --- |
| `blorp_StackOption_<payload>` | `c_type_layout.brp:55`; `collection_pipeline.brp:706,719`, `prepare.brp:3493,3498`, `specialize_collection.brp:211,215`, `specialize_layout.brp:325,329`, `synth_list.brp:277,281` (nine independent copies) | `c_type_layout.brp:82,85,109` and their callers `resolved_stack_option_type_name`/`resolved_inline_struct_c_type`/`resolved_boxed_element_c_type` (`emit.brp` about 60 call sites) |
| trailing `*` | `c_type_layout.brp` boxed element types | `c_type_layout.brp:131` |
| `blorp_vector_to_string_<enum>` | `specialize_value.brp:113`, `specialize_tensor_dispatch.brp:292`, `c_naming.brp:322`, `emit.brp:1158` | `emit.brp:1175,1178`, `ownership.brp:2027` |
| `_f64`, `_f32` builtin suffix | runtime name tables | `emit.brp:8691,8699` |

Replace with: payload `CoreType` in `CoreStackOptionRepresentation` and the
inline-struct/boxed element records; the emitter renders the C type from it
(`blorp_StackResult` is an ABI constant and stays). `to_string` of a packed enum
vector becomes a `CoreCallKind` case carrying the enum's type id (no prefix
test in `emit.brp` or `ownership.brp`), and the scalar width becomes a field of
the ranked-checked-get call. Owner: A3.3 (the `_f64/_f32` reader is the
exception: it belongs to A2, the builtin registry).

### F12 qualified type names

Fact: "this type is `Type` of module `M`", spelled `M::Type` (typecheck and Core
lowering), `M__Type` (flattened Core), or bare for prelude types; and "this
type expression is `alias.Type`".

| Marker | Producers | Readers |
| --- | --- | --- |
| `::` (`CANONICAL_MODULE_TYPE_SEPARATOR`) | `semantic_type.brp:58` | `semantic_type.brp:384`; `split_canonical_module_type_name` `:671,:780`; `identity.brp:173` (independent second parser) |
| `.` (`QUALIFIED_TYPE_NAME_SEPARATOR`) | `semantic_type.brp:403` | `semantic_type.brp:422`; `split_qualified_type_name` `type_resolution.brp:112` |
| literal spellings | n/a | 98 lines matching `"stream::Stream"`, `"stream__Stream"`, `"fs::FileReader"`, `"fs__FileReader"`: `operation_metadata.brp` 38, `c_type_layout.brp` 13, `unmanaged_type.brp` 13, `type_policy.brp` 11, `type_name_metadata.brp` 8, `prepare.brp` 6, `desugar.brp` 2, `lower.brp:429,433` (`vector::ParallelVector`), `specialize_collection.brp:169`, `late_invariants.brp:574` |

Replace with: semantic and Core type references carry a `ModuleId` plus
`NameId` (or the type's `DefinitionId`); the alias qualifier is a
`SemanticQualifiedNamedType(alias, name)` (the parse tree already has both
parts). The three-spelling literal lists become comparisons with pinned type
ids for the prelude/`stream`/`fs`/`vector`/`matrix` types; the
"`Stream`, `stream::Stream`, `stream__Stream`" triples exist only because the
same type reaches a pass in three spellings today. Owners: TI (`DefinitionId`
on type references, D9) and A2 (`intrinsic_type`/`prelude_type`); the
`identity.brp:173` parser deletes with A3.1's Core type flattening.

### F13 dimension sigil `#`

Fact: "this type variable is a dimension variable", written by a leading `#`.

| Producers | Readers |
| --- | --- |
| `language_parser.brp:1093,1862,1878`, `semantic_type.brp:838`, `type_policy.brp:261`, `lexer.brp` (1), `format/engine/type_documents.brp` (1); `builtins.brp` `"#N"`, `"#M"`, ... literals (vocabulary) | `is_dim_var_name` 31 calls (`infer.brp` 12, `semantic_type.brp` 9, `context.brp` 4, `dim_solver.brp` 3, `decl.brp` 2, `type_widening.brp` 2) plus `dim_var_name_without_sigil` and `is_legacy_single_letter_type_param`; `mono.brp:367` (`starts_with("#")`, the only reader outside the shared helper) |

Replace with: `SemanticTypeVar { name, kind: SemanticTypeVarKind }` with kinds
`Type | Dimension | VariadicDimensions` (D7 landing; `ParsedTypeParamDecl.kind`
already exists). Then the three helpers and `mono.brp:367` delete and the
sigil is a display concern. Owner: D7, then TI. `mono.brp:367` is the one
reader that bypasses the helper; route it through `is_dim_var_name` now or
delete it with D7.

### F14 tuple field decimal names

Fact: "field `1` of this tuple", spelled by the decimal digit String.

Readers: `infer.brp:15582`, `stage_07_ctfe/ir.brp:669`, `lower.brp:2544,2560`,
`format/engine/expression_documents.brp:2524`. No producers (the digits come from
the source spelling).

Replace with: a `ParsedFieldAccess = NamedField(NameId) | TupleIndex(Int)`
decided by the parser (a numeric token after `.` is lexically distinct), carried
unchanged to Core (`TupleFieldExpr` already takes an `Int`). Owner: A0 field
follow-up / A5 (`CoreFieldRef` exists; extend it, no new roadmap step needed).

### F15 module-name origin and extension

Fact: "this module comes from a package" (`pkg/` prefix), "this import is
relative" (`./`, `../`), "this path is a Blorp source" (`.brp`).

Readers: `frontend_import_plan.brp:46,54`, `std_inline.brp:399`
(`owned_module`), `lib/source_graph.brp:324,604,605,713`,
`lsp/workspace/source_loader.brp:290,948`, `lint/command.brp:155`
(`ends_with("/" + module + ".brp")`). `stage_04_modules/source_name_table` and
the package catalog only see paths and are excluded.

Replace with: `ModuleOrigin` (`StdlibModule | NativePackageModule(id) |
SourcePackageModule(...)`) already exists in the frontend; carry it and a
`ModuleId` to Core (`CoreFunction.source_module: Option[ModuleId]`) and let
`std_inline`, LSP and lint ask `origin`. Owners: A0/A1 (ModuleId reach), then
A3.1. The `.brp` and `./` tests on import paths are module file paths and stay.

### F16 builtin runtime-name prefixes

Readers: `backend_projection.brp:215,228` (`blorp_filter_map_parallel*`),
`specialize.brp:696` (`blorp_vector_get_opt_*`), `specialize_collection.brp:541`
(`blorp_dict_get*`), `backend_projection.brp:152` (`find_function_name`,
`ends_with("_" + expected)`). Producers are the runtime vocabulary itself.

Replace with: builtin registry entries carry a `BuiltinFamily` (or the exact
list of names) so a prefix is a data row, not a `starts_with`. Owner: A2 (builtin
registry). The `find_function_name` suffix lookup belongs to F4.

### F17 integer literal text (not a name)

13 `parse_int` readers on a literal's spelling (`infer.brp:6712,10117,16038,19264`,
`types.brp:101`, `type_header_graph.brp:1376`, `lower.brp:2086,2742`,
`stage_07_ctfe/pattern.brp:67`, `ir.brp:3119`, `format/projection.brp:380,459,1645`).
These decode a value that the lexer delivered as text; they are not names and no
name-id step touches them. They are allowlisted; a separate literal-value task
(`IntLiteral(Int)` in the parsed AST) would remove them.

### F18 emitter C temporaries (display only)

169 producer lines: `emit.brp` 56, `prepared_backend_renderer.brp` 40,
`prepared_tensor_renderer.brp` 40, `prepared_list_renderer.brp` 28, others 5.
Names like `__lg_list_<seed>`, `__fill_value_<seed>`, `__blorp_cleanup_<var>`.
One reader (`is_generated_temp_value`, F9). Replace with the emitter's
existing compact temp scheme (`__t<kind>_<n>`) driven by an `EmitterTempKind`
enum, then drop the `__x_<seed>` spellings. Owner: NEW step B6; not urgent.

### F19 producer-only keys (no reader)

`INTERPOLATION_WRAPPER_PREFIX = "x="` (`source_ast_finalize.brp:148,2413`, a
parse wrapper the parser strips structurally) and `TRAIT_METHOD_KEY_SEPARATOR`
(`dce.brp:926`, a Dict key). No shape is recovered. Keep, or key DCE by
`(trait_id, method_id)` under A3.1.

### F20 projected symbols (target state)

`brp_`, `brp_ty`, `brp_v_`, `brp_vn_`, `brp_c_`, `brp_t_`
(`c_symbol_projection.brp:195,204,213,217`, `c_naming.brp` local and variant prefixes): spelled from ids, never parsed. Listed so the check
does not re-flag them when B-lane grows; no action.

## 2. Counts

Reader = a shape-testing operation; accessor = a call to a named decoder;
producer = a line that builds a marked name. One line counts once per role.
`stage_0x` labels are the directories; "other" is lib, lsp, lint, format.

| Family | Readers | Accessor calls | Producers | Stages (findings) | Owner |
| --- | ---: | ---: | ---: | --- | --- |
| F1 mono / pure | 4 | 8 | 7 | 08:1, 09:18 | A3.1 |
| F2 module-member prefix | 23 | 36 | 3 | 08:4, 09:58 | A3.1, A2 |
| F3 UFCS | 3 | 4 | 3 | 08:5, 09:5 | A3.1 |
| F4 trait-method | 3 | 0 | 1 | 09:4 | A3.1 |
| F5 hoisted / `__def_` | 1 | 0 | 17 | 08:1, 09:13, 10:4 | A3.1, A3.2, B4 |
| F6 entrypoints | 0 | 0 | 2 | 08:2 | must stay |
| F7 pass temporaries | 0 | 0 | 22 | 09:22 | A3.2 (after B1) |
| F8 front-end / lowering temps | 0 | 0 | 9 | 03:1, 06:1, 08:7 | A3.2, B1 |
| F9 C local guards | 7 | 2 | 12 | 10:21 | B1, B3, B6 |
| F10 variant / static symbols | 0 | 0 | 11 | 09:1, 10:10 | B2, B3, B4, B5 |
| F11 C type strings | 9 | 1 | 15 | 09:19, 10:6 | A3.3, A2 |
| F12 qualified type names | 98 | 3 | 2 | 06:15, 08:3, 09:85 | TI, A2 |
| F13 dimension sigil | 1 | 31 | 8 | 02:1, 03:3, 06:32, 09:3, format:1 | D7, TI |
| F14 tuple field names | 5 | 0 | 0 | 06:1, 07:1, 08:2, format:1 | A5 |
| F15 module origin | 8 | 2 | 0 | 04:2, 09:1, lib:4, lint:1, lsp:2 | A0/A1, A3.1 |
| F16 builtin name prefixes | 5 | 0 | 0 | 09:5 | A2 |
| F17 int literal text | 13 | 0 | 0 | 06:6, 07:1, 08:2, 09:1, format:3 | not a name |
| F18 emitter temps | 0 | 0 | 169 | 10:169 | B6 (new) |
| F19 producer-only keys | 0 | 0 | 2 | 03:2 | keep |
| F20 projected symbols | 0 | 0 | 8 | 10:8 | none |
| F0 vocabulary membership (false positives) | 10 | 0 | 0 | 06:4, 09:1, 10:5 | none |
| **Total** | **190** | **87** | **288** | | |

Twenty families (F1 to F20) plus the F0 false-positive class. Real name-shape
readers (excluding F0, F17): 167 readers plus 87 accessor calls, that is 254
reader sites.

By stage, all roles (571 distinct lines): stage_09_core 240, stage_10_backend
220 (169 are F18 temporaries), stage_06_typecheck 59, stage_08_core_lower 29,
stage_03_parse 6, format 5, lib 4, stage_04_modules 2, stage_07_ctfe 2, lsp 2,
stage_02_lex 1, lint 1.

Top five families by reader count (readers plus accessor calls):
F12 qualified type names 101, F2 module-member prefix 59, F13 dimension sigil
32, F1 mono/pure 12, and F11 C type strings 10 (tied with F15 module origin
10).

## 3. Must stay

| Item | Where | Reason |
| --- | --- | --- |
| `builtin("...")` and `foreign` names, `blorp_*` runtime symbol equality | `builtin_registry.brp`, `ownership.brp`, `emit.brp` name tables, `specialize_*.brp` | External ABI / runtime vocabulary; A2 turns them into id-keyed tables, but the spellings remain the ABI |
| `$blorp$program`, `$blorp$user_main_<def_id>` | `entrypoint.brp:23,25` | Exported entrypoints |
| C reserved-word escaping, `c_identifier` against the C vocabulary, `C_RESERVED_*_INDEX` | `c_naming.brp` | Compares against C, not Blorp |
| `blorp_StackResult` and other `blorp_*` C type names | `c_type_layout.brp`, `prepare.brp` | ABI constants shared with `runtime.c` |
| Static string literal pool contents and `__blorp_string_literal_<id>` | `emit_literal.brp`, `static_string_literals` | Literal data, spelled from the pool id |
| Module file paths and extensions, `pkg/` and `./` on import paths in the module loader | `stage_04_modules`, `lib/source_graph.brp`, `lsp/workspace` | File-system text. Only the `pkg/` reads that recover an origin (`std_inline.brp:399`, `source_graph.brp:604`, `source_loader.brp:290,948`) are F15 |
| Diagnostic message text, `error: ` prefix, help strings | `lib/diagnostic.brp`, checker messages | Rendered output |
| Core JSON codec field and tag names (`*_TAG`, `__core_source_loc_ref__`, `parsed_program`, ...) | `ir.brp`, `parsed_ast_json.brp`, `typed_ast_json.brp`, `bridge.brp` | Wire format between stages and to tooling |
| C text scans of emitted bodies (`function_c.contains(CURRENT_TASK_LOCAL)`, `C_FUNCTION_BODY_OPEN`, `emit_literal.brp` `contains("e")`) | `emit.brp:2824,2825`, `emit_literal.brp` | Operate on C source or float text, not names |
| CTFE string builtins (`starts_with`, `split`, ...) | `stage_07_ctfe/eval.brp` | The interpreter's implementation of the user-level String API |
| CLI, LSP protocol, package manifest, formatter layout, test harness text | `lib/cli_args.brp`, `lsp/protocol`, `stage_04_modules/package_*`, `format/engine`, `test/` | Not compiler names (excluded from the scan) |
| Dictionary or list membership with a literal (F0) | `bridge.brp:2444`, `module_binding.brp:605`, `accepted_alias_authority.brp:347,356`, `mono.brp:662` | Vocabulary lookup, converted with A2 |
| `"Int64"`, `"TaskResult"`, `"prelude"`, `"traits"` vocabulary | same | A2 |

## 4. Allowlist and precision

`scripts/check-magic-spellings.allowlist` is the current findings verbatim, 583
lines (577 after D6; see below). The report counts 571 distinct (file, line, role) sites; 12 producer
lines match two rules (`marker_binder` and `marker_concatenation`) and appear
twice in the allowlist. The check passes on this tree and fails on the
probe described above. Stale lines (code deleted or reformatted) are reported
on stderr and fail only with `--strict`; use `--update` after each deletion so
the allowlist shrinks with the code. Line text is the key, so reformatting a
listed line shows up as one new plus one stale finding; accessor calls are keyed
by name and do not.

False positives that had to be allowlisted rather than fixed: the 10 F0
membership calls, the 13 F17 literal parses, 2 F19 producer-only keys, the
display string `owner.name + "#" + def_id` (`allocation_report.brp:420`), and
`builtins.brp` `"#N"` style vocabulary is not matched (no concatenation). The
whole-file and argument exclusions described under Reproduce cover the rest
(about 130 path and CLI operations that the raw `starts_with`/`split` grep
returns).

## 5. Already dead or gone

Found while folding the earlier census in; all checked with `grep` on
`6c9f72c62`.

- `TAG_Some` at `specialize.brp:304`, `"TAG_Option_Some"` at
  `specialize_collection.brp:837,891`, the `TAG_`/`__def_` producers and the
  `emit.brp` static initializer: deleted by D6 (`c19c3392a`); their 10
  allowlist lines were removed in the refresh.
- `bound_type_param_to_parser_string` (`generic_params.brp:80`, producer of the
  `T:Bound+Bound` shape): no production caller, only
  `test_typecheck_types.brp:21,172`. Delete function and assertion.
- Rows from the task list or the earlier catalog with no occurrence in
  `blorp/src` on this commit (grep count 0): `__view`, `__borrow_arg_`,
  `__aggregate_field_`, `split_var_callable_id`, `CALLABLE_ID_SEPARATOR`,
  `ctfe_ir_clean_source_name`, `strip_type_param_bounds`, the four
  independent `__mono_`/`__pure` parsers (only `synth_name.brp` remains) and
  the `TAG_` re-derivation at `emit.brp:25088` (now a comment-free storage name
  at `:25095`).
- Duplicate constants to delete with their step: `MANGLED_DEF_ID_PREFIX`
  (`closure.brp:221`, `emit.brp:996`), `PURE_NAME_SUFFIX` versus
  `CORE_PURE_OVERLOAD_SUFFIX`, `COMPILER_LOCAL_PREFIX` defined in six modules
  (each pass's own value, none read outside `c_naming.brp:113`).
- Dead the moment its producer step lands: F5 readers other than
  `emit.brp:13450` do not exist; the `_blorp_clambda_`, `_blorp_task_` and
  `_blorp_eta_` strings and `__sc_` are display-only already (`def_id` projects
  the C symbol), so their producers can be deleted as soon as diagnostics stop
  printing them.

## Rough edges

- The roadmap's A3.2 description ("Perceus and cleanup readers recognise their
  own temporaries by prefix") does not match this commit: the only reader is
  `c_local_name`. A3.2 is a producer-and-origin change plus deleting
  `c_local_name`'s escape branches.
- `mono.brp:367` tests `starts_with("#")` directly although the sigil accessor
  exists; it is the one F13 reader outside the helper.
- F12's 98 literal lines are the largest single family and belong to no
  Lane-A step today (A2 covers builtin registries, not the prelude type-name
  triples). Suggest a bounded task: pin type ids for `Stream`, `FallibleStream`,
  `ResourceSource`, `fs::*`, `process::*`, `vector::Parallel*`, then delete the
  triples.

## Refresh after D6

Allowlist delta against the first census commit: 10 lines removed (the
`flatten.brp`, `lower.brp` (2), `mono_data.brp` (2), `prepare.brp` and
`emit.brp` producers plus the three `TAG_` literals) and 4 added
(`PROJECTED_VARIANT_CONSTRUCTOR_PREFIX` `"brp_c_"` and
`PROJECTED_VARIANT_TAG_PREFIX` `"brp_t_"` in F20; `SOURCE_VARIANT_TAG_PREFIX`
`"TAG_"` and its concatenation at `c_naming.brp:302` in F10, owner B5). 583
became 577 lines.
