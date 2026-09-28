# Name-string catalog after the id work

Date: 2026-09-28. Read-only catalog; no compiler source changes. It is the
"after" view of
[`name_text_inspection_census_2026-09-28.md`](name_text_inspection_census_2026-09-28.md)
and feeds the tidy-up briefs for [`docs/CORE_ID_MIGRATION.md`](../../docs/CORE_ID_MIGRATION.md).

Base: `origin/main` `5e567133c`, which contains `b6928bb05` (compilation
`NameTable`), `0b17137aa` (`ParsedIdentifier.name`), `c6add3a92`
(type-parameter kinds), `8186f04c2` (`CoreFieldRef`), `b8eea81f2` (mono markers
in one place) and `b8178c20e` (lowering name parsers). `make` built `bin/blorp`
(`-O0`, 8-way split; `scripts/compiler-build-status` FRESH) but no new
measurement was taken: every allocation and byte figure below is quoted from a
named report or is arithmetic on one, and is marked as such.

In-flight branches read, not depended on:

- `backend/local-symbols-by-id` (`c1d5b2648`): binder ids come from one
  allocator (`3b57fd02b`), locals are spelled `brp_v_<base62 id>` /
  `brp_vn_<base62 -id>` in C (`8360b6657`, `c_binder_name`), pattern binders are
  pushed into the lowering scope (`db5ee4db3`). Name-unique synthetic binders
  deliberately take `id = 0` (`match_projection`, `mono_option`, `tuple_sroa`,
  `record_update`, `perceus/results_and_loops`, `tensor_specialize`,
  `parallel_tensor_pipeline`).
- `typecheck/source-name-table-view` (`a16b60ad1`): `SourceNameTable` /
  `SourceNameId` deleted; typecheck reads the compilation `NameTable`.
  It still resolves declared names by spelling; no `NameId` key is introduced.
- `backend/project-local-symbols` (`9ce27d58e`) is a sibling of the first branch
  (a pass that projects local C names ahead of emission); it rewrites 1,795 lines
  of `test_core_emit.brp`, which matters for the test-only emission mode below.

## What this decides

Legend: **dead now** = deletable today with byte-identical C. **convertible
now** = the id already exists at the reader; the type or the reader changes.
**dead after X** = blocked on a named in-flight or planned change. **must
stay** = the text is the product.

### Dead now (delete; C identical)

1. `synth_name.is_mono_specialization_name` (`stage_09_core/synth_name.brp`):
   zero callers anywhere in `blorp/`, `benchmarks/`, `standard_library/`.
   `is_pure_variant_name` then becomes private to `strip_pure_suffix`.
2. `split_var_callable_id`, `CALLABLE_ID_SEPARATOR`, the encoded-id argument
   of `resolve_name_expr_def_id` and its conflict diagnostic
   (`stage_08_core_lower/lower.brp:422,974,5314,5336`). Its own doc comment
   states no pass builds a `#<id>`-suffixed identifier, and a lexed identifier
   cannot contain `#`. Two tests pin the format
   (`test_lowers_matching_encoded_and_resolved_function_reference_ids`,
   `test_rejects_conflicting_function_reference_ids` in
   `test_core_lower.brp`) and go with it. Allocation weight: the split cost
   2 allocations per name reference, 543,738 over 271,869 references
   (`core_lowering_allocation_attribution_2026-09-22.md`, third pass; quoted,
   predates `b8178c20e`, re-measure before claiming).
3. `ctfe_ir_clean_source_name` (`stage_07_ctfe/ir.brp:453`): strips a `#...`
   suffix from a `ResolvedCallInfo.source_name`; same reason as item 2 (no
   producer). Verify by one `scripts/compiler-check --stage ctfe` run with the
   function replaced by identity.

Everything else the census called class 3 is live; see below. The name helpers
themselves are almost all called: a mechanical scan of 10,519 `pure func`s in
`blorp/src/compiler` for zero references (name/prefix/suffix/split/strip
spellings) found only item 1 plus seven unrelated leftovers
(`token_string_literal_text`, `register_source_name_catalog_work_counters`,
`match_body_context`, `bound_module_source_module_name`,
`bound_name_alias_row_id`, `bound_name_selective_row_id`,
`context_for_fresh_infer_session`, `borrowed_result_context_shadowing_*`).
The dead code is in **data fields and derived strings**, not helper functions.

### Convertible now (id exists at the reader)

| # | What | Readers that must change |
| --- | --- | --- |
| C1 | `== "_"` (30 `ParsedIdentifier` sites: `infer.brp` 16, `lower.brp` 13, `stage_07_ctfe/ir.brp` 1), `== "Self"`, `== "main"`, `"include"`, `"length"`: compare `.name` (a `NameId`) to a pinned constant. `"_"`, `Self`, `#_` are already in the seeded table (`name_table_synthesized_spellings`, 73 entries) but no constant pins their index; `synthesized_name_id` rebuilds a table per call and is documented test-only. `main` is not seeded. | Add named `NameId` constants plus a test pinning the seeded order (`name_table.brp`); then 25 `compare_literal` sites in `infer.brp` 18, `decl.brp` 4, `type_header_graph.brp` 1, `types.brp` 1, `foreign_validation.brp` 1 and the 13 in `lower.brp`. `CoreVar` sites (`emit.brp` 9, `cancellation_plan`) wait for D-list item 6. |
| C2 | Field-spelling compares that survived `8186f04c2`: `record_update.brp:288,632`, `prepare.brp:626` (`find_record_field(fields, name)`), `lower.brp:2429` (`updates.find(update.name == field.name)`), CTFE `ctfe_record_fields_equal` (`value.brp:528`), `ctfe_eval_record_field` / `ctfe_apply_record_updates` (linear name scans over `List[(String, CtfeValue, ResolvedFieldIdentity)]`). `CoreFieldRef` and `ResolvedFieldIdentity` are already on both sides. | Compare `core_field_refs_equal`; `find_record_field` takes a `CoreFieldRef`; `CtfeIrRecordField(String)` (`stage_07_ctfe/ir.brp:206`) gains the identity. Keep `ir.brp:15500` (JSON validation) on text. |
| C3 | `__def_<id>_<name>` prefix test as a cleanup-slot decision: `emit.brp:13443` `variable_has_cleanup_slot` calls `variable.name.starts_with(MANGLED_DEF_ID_PREFIX)` (its own comment: "replace this with an explicit JSON bit"). The constructor-value `VarExpr`s it recognises carry the definition id inside the string and `def_id = None`. | Producers (`constructor_c_name` in `lower.brp:6040` and its copy `prepare.brp:3565`, `closure.brp:583 mangle_by_def_id`) set `def_id = Some(id)`; the test becomes `def_id.is_some()` (already the first arm). |
| C4 | C type strings baked into Core and later re-parsed: `CoreStackOptionRepresentation.option_type`, `CoreStackResultRepresentation.result_type`, `struct_c_type`, `value_c_type`, `InlineStructListStorage(String)`, `TensorForInlineStructElement(String)`, `TensorForBoxedElement(String)`; parsers `resolved_stack_option_type_name`, `resolved_inline_struct_c_type`, `resolved_boxed_element_c_type` (`c_type_layout.brp:82-134`, 41 `struct_c_type`, 106 `option_type`, 30 `value_c_type` references). Flimsy by the AGENTS.md rule: the `Range` payload is special-cased in two places that disagree, and recovery is a `starts_with("blorp_StackOption_")` plus a dictionary hit. | Store the payload `CoreType`; render the C spelling in emit with the projected lookup. Readers: `emit.brp`, `prepared_*_renderer.brp`, `list_layout.brp`, `prepare.brp`, `collection_plan.brp`, `synth_list.brp`, `specialize_layout.brp`, JSON codec. Large; independent of the local-symbol work. |
| C5 | Record `CoreRecordFieldValue.name`, `CoreValueRecordField.name`, `CoreHeapRecordField.name`, `FieldExpr` spelling: after resolve, the only production readers are the emitter (`c_field_name`, 14 calls in `emit.brp`), `static_child_path` (2), and JSON. Before resolve, `FieldExpr`'s String is also a *module member* (`resolve.brp:1936-2517`, `resolve_qualified_value`), a constructor reference (`match_lowering.brp:700`) and a tuple index (`tuple_sroa.brp:288 field_index_in_bounds`, `parse_int` on the spelling). | Not a type change yet. Convertible piece: give the tuple-as-record sites a tuple index instead of a decimal spelling (deletes `field_index_in_bounds`, four readers in `tuple_sroa.brp`). The String itself goes when members are spelled by ordinal (D-list item 4). |
| C6 | `CtfeEnv = List[(String, CtfeBinding)]` (`stage_07_ctfe/value.brp:101`, 30 references in `env.brp`): linear lookup on a name. | `ParsedIdentifier.name` is available at binders; key the association list on `NameId`. Instruction win only. |
| C7 | Constructor/definition-name keys where a `def_id` sits next to the name: `Dict[String, ...]` in `resolve.brp` (`user_functions`, `module_functions`, `constructors`), `closure.brp:308 functions_by_name`, `dce.brp` (`function_ids_by_name`, `impl_method_ids_by_trait_method`), `flatten.brp` `find_callable_rewrite(rewrites, name, def_id)`, `CoreClosureCreate.function_name` / `CoreTaskClosure.function_name` (read only by flatten's rewrite lookup, projection diagnostics, JSON). | Key on `def_id`; keep name as diagnostic. See section 3. |
| C8 | `module_member_prefixes: Dict[String, String]` (127 references: `lower.brp` 87, `mono_specialize` 16, `resolve` 10, `graph_prepare` 8, `mono_option` 3, `identity` 2), keyed on the module-name string. | Key on `ModuleId`. Cleanliness; probes do not allocate. |

### Dead after X

| # | What dies | After |
| --- | --- | --- |
| D1 | The text of every name-unique synthetic binder and its derived spelling: SSA `name__v<n>` (`ssa.brp:1111`), `$blorp$tuple_sroa$`, `$blorp$parallel_tensor$`, `$blorp$record_update$`, `$blorp$collection_pipeline$`, `$blorp$string_pipeline$`, `$blorp$perceus$`, `$blorp$match_scrut$<owner>$<rows>$<depth>`, `__blorp_option_fusion_<seed>_<label>`, `__tensor_raw_view_<name>_<id>`, and the loc-baked `__qb_`, `__td_`, `__loop_<label>_<start>_<end>`, `__timeout_`, `__pattern_param_`, `__record_update_<offset>` in `lower.brp`. Nothing parses them back (grep below); each carries identity only in the text. | `backend/local-symbols-by-id` **plus** a follow-up that mints these from `CorePassState.next_binder_id` instead of `id = 0` (the branch leaves them at 0 on purpose). Roughly 10 passes, one file each. |
| D2 | `c_binder_name`'s `id == 0` fallback, `c_local_name`'s `$blorp$` branch and escape branch for locals, `is_compact_temp_c_name` (sole caller is `c_local_name`), `COMPILER_LOCAL_C_PREFIX` / `ESCAPED_SOURCE_LOCAL_C_PREFIX` for locals. | D1, plus globals projected by definition id (`c_symbol_projection.brp:708 c_local_name(global.name.name)` is the remaining user-spelled caller), plus `_` binders minted. Section 5 has the per-branch callers. |
| D3 | `CoreVar.name` as identity; `core_var_equal` = `name == name and id == id` becomes `id == id`; the six local `core_var(name)` constructors (`synth_nodes`, `synth_fixed`, `match_lowering`, `specialize_collection`, `collection_pipeline`, `string_pipeline`) and `closure.brp var_from_name`. | D1, all 46 `id = 0` sites minted, closure/free-var captures at id 0 (`closure.brp:1441`), pattern binders (`NamePattern(String)`, 23 sites in 7 files, no id) given ids, globals/callables read through `def_id` only. |
| D4 | `FieldExpr` spelling, `CoreRecordFieldValue.name`, record-field `name`, `CowFieldTakeRetainPolicy(CoreVar, String)`'s String, `c_field_name`'s reserved/escape branches for non-ABI records. | Struct members spelled by ordinal or field id in the emitter (`8186f04c2` names this "until members are spelled by ordinal"; not started); ABI records (`abi_type = Some`) keep their spellings. |
| D5 | `CoreClosureCreate.c_name` / `static_name`, `CoreTaskClosure.c_name` / `static_name`, `CoreClosureAbi.c_name`, `CoreClosureCreate.function_name`, `closure_env_type_name` derivations. Under validated symbols `selected_callable_c_spelling` already replaces `c_name` by the `def_id` symbol; the String only feeds `UnprojectedCEmissionSymbolsForTests` (14 arms in `emit.brp`, constructed only by the `*_for_tests` entry points) and the `original_c_spelling` equality check in `c_symbol_projection.brp:892`. | Retiring the test-only unprojected emission mode. `backend/project-local-symbols` rewrites `test_core_emit.brp`, the only user; do it there or right after. |
| D6 | `CoreUnionVariant.c_name` / `tag_c_name`, `CoreEnumVariant.c_name`, `CoreUnionConstruct.constructor_c_name`, `reuse_constructor_c_name`, `CoreOperationErrorCase.constructor_c_name` (164 `constructor_name` references), `TAG_<type>_<variant>` (3 producers: `lower.brp:6318`, `flatten.brp:3343`, `mono_data.brp:858`; a fourth spelling at `emit.brp:25088`). | Variants projected through `c_symbol_projection` like callables. Each variant already has a `def_id`. Not in flight. |
| D7 | `dim_var_name_without_sigil` (`decl.brp:2707`, `infer.brp:8031`), `is_dim_var_name` (44 uses in stage 06, `mono.brp:367 starts_with("#")`, `type_policy`). | `SemanticTypeVar` gains an explicit kind (its own doc comment names this). |
| D8 | `ParsedIdentifier.text` (675 readers in stages 03/04/06, 103 more in 07/08). | Typecheck and lowering read through the table (`typecheck/source-name-table-view` is the first consumer); diagnostics and the formatter render via `name_spelling(table, id)`. |
| D9 | Core type identity as `String` (`NamedType`, `HeapRecordType`, `UnionType`, `EnumType`, `ValueRecordType`, `TypeParameterType`: 1,000+ constructor/pattern sites) and the `Dict[String, CoreHeapRecordDecl]` family (30 + 20 + 20 + ...). | Type interning (`docs/TYPE_INTERNING_ROADMAP.md`). Not a name-id tidy-up; listed so nobody starts it here. |

### Must stay (and why)

| What | Reason |
| --- | --- |
| `ForeignCall(String, ...)`, `CoreForeignFunction.c_name`/`includes`, `ParsedForeign*` `c_name`, `BuiltinCall`, `IntrinsicCall`, `BuiltinFunction`, `CoreOperationResultBridge` / `CoreFallibleStreamTerminalBridge` runtime names | The C ABI is the user's or the runtime's own text (`builtin("...")` is 1,521 literals). Never id-substitutable. |
| `main`, entrypoint names `$blorp$program`, `$blorp$user_main_` | Exported/linked symbols; `entrypoint.brp`. |
| `c_identifier` and `C_RESERVED_IDENTIFIER_INDEX`, `c_field_name` for ABI records, static-string-literal pool contents (`ids_by_value`, `static_string_literals.brp`), `CoreLiteral` texts | They compare against a closed C vocabulary or are data, not names. |
| Diagnostic rendering (`type_to_string` 153 call sites, `display_type_name`, the `render` class of `.text` readers, `pass_runner.brp` invariant messages, `late_invariants` reports) | The spelling is the message. A `should_fail` typecheck fixture pins 860 of them. |
| Formatter (`blorp/src/format/projection.brp` reads `ParsedIdentifier.text`/`.span`) | Byte-for-byte source. May render through the table but the spelling must exist. |
| `type_name` / `is_heap` reflection (`infer.brp:10229,10295`, `lower.brp:4636`) | Produces a compile-time string constant from a type spelling. |
| Core JSON codec (`core_var_to_json` name field, `core_task_capture_to_json`, ...) | `--dump-core` output. The decoders are used only by `test_core_json.brp` and two benchmark profiles (about 248 `decode_core_*` functions in a 15,724-line `ir.brp`); the name fields stay for dumps and pinned tests. |
| Module paths, `import` resolution strings, `source_path_by_identity`, manifest keys | File-system text; `ModuleId` already exists for the resolved result, not for the request string. |
| Type-parameter names inside `CoreType` / `CoreTypeParam` / mono substitution keys | Belong to D9. |

### Ordered tidy-up tasks (file ownership)

Tasks with disjoint files can run in parallel. `lower.brp`, `emit.brp` and
`infer.brp` are single-owner hotspots: exactly one task touches each at a
time; the order column says who goes first.

| # | Task | Files (exclusive) | Starts | Gate |
| --- | --- | --- | --- | --- |
| T1 | Pin constant `NameId`s for the closed vocabulary (`_`, `Self`, `#_`, `include`, `length`, ...) and seed `main`; test that pins the seeded order | `stage_02_lex/name_table.brp`, `test_lexer.brp` | now | `bin/blorp test` on the lexer suite; formatter `--check` |
| T2 | Delete dead-now items 1-3 with their two tests | `stage_09_core/synth_name.brp`, `stage_07_ctfe/ir.brp`, `stage_08_core_lower/lower.brp` (region 415-425, 940-1000, 5300-5345 only), `test_core_lower.brp` | now | `scripts/compiler-check --changed`; identical C; re-measure `TypedNameExpr` allocations |
| T3 | C2: field compares to ids; give tuple-as-record fields an index | `record_update.brp`, `prepare.brp` (626), `tuple_sroa.brp`, `stage_07_ctfe/value.brp`, `stage_07_ctfe/eval.brp`; CTFE `ir.brp` after T2; `lower.brp:2429` after T2 | now (T2 for the two shared files) | Core suites, `scripts/test compiler-core-sanitize leak`, generated C identical |
| T4 | C1: `"_"`/`Self`/`main`/`include`/`length` compares to constants | `infer.brp`, `decl.brp`, `types.brp`, `headers/type_header_graph.brp`, `foreign_validation.brp` (typecheck owner); `lower.brp` compares after T2/T3 | after T1 | typecheck fixtures (`scripts/compiler-check --stage typecheck`); `.text` reader count in `infer.brp` drops by 18+16 |
| T5 | C3 + duplicate authorities: one `constructor_c_name`, one `MANGLED_DEF_ID_PREFIX`, one pure-overload suffix constant (`identity.brp` vs `synth_name.brp`), one `CoreVar` constructor (six copies), one `union_reuse_name` derivation (`reuse.brp:3599` and `c_naming.brp:261` compute the same C name in two stages, one applying `c_identifier`, one not) | `prepare.brp`, `closure.brp`, `identity.brp`, `synth_name.brp`, `synth_nodes.brp`, `synth_fixed.brp`, `match_lowering.brp`, `specialize_collection.brp`, `reuse.brp`, `c_naming.brp`; `emit.brp` last | now (emit after T7) | Core + emit suites, C identical |
| T6 | C4: payload `CoreType` instead of baked C type strings; delete the three `resolved_*` parsers | `c_type_layout.brp`, `stage_08_core_lower/list_layout.brp`, `stage_09_core/ir.brp` (records), `collection_plan.brp`, `synth_list.brp`, `specialize_layout.brp`, `prepared_*_renderer.brp`, `emit.brp` | after T5 (emit); coordinate with type interning | codegen audit, `EXPECT-C` fixtures (214), generated C identical |
| T7 | D1 wave: mint ids for the name-unique synthetic binders, one file per pass (`ssa`, `tuple_sroa`, `parallel_tensor_pipeline`, `record_update`, `perceus/results_and_loops`, `tensor_specialize`, `match_projection`, `mono_option`, `collection_pipeline`, `string_pipeline`, lowering loc-baked names in `lower.brp`); then delete D2 | listed files; then `c_naming.brp`, `c_symbol_projection.brp` | after `backend/local-symbols-by-id` lands | Perceus/emit suites; audit fixtures pin `__tensor_raw_view_` (branch already re-spells them `brp_v_`) |
| T8 | D5: retire `UnprojectedCEmissionSymbolsForTests`; delete closure/task `c_name`/`static_name` | `emit.brp`, `c_symbol_projection.brp`, `ir.brp` closure/task records, `closure.brp`, `test_core_emit.brp` | after `backend/project-local-symbols` lands | emit suite, generated C identical |
| T9 | D8 wave: `.text` key/lookup readers to `NameId`, per file, starting with the non-diagnostic ones (`source_ast_finalize.brp` `bound` lists, `module_prelude.brp`, `callable_headers.brp`, `implementation_headers.brp`, `type_header_dependencies.brp`) | one file per worker; `infer.brp` and `decl.brp` last | after `typecheck/source-name-table-view` lands | typecheck fixtures; formatter `--check` |
| T10 | C6 + C7 + C8: table keys | `stage_07_ctfe/env.brp`; `resolve.brp`, `closure.brp`, `dce.brp`, `flatten.brp`; `module_member_prefixes` users | any time, after T2/T3 for shared files | Core suites; instruction counts only |

## Method and greps

```
cd blorp/src/compiler
# section 1: name-bearing String fields, per record
awk '/^(record|union|enum|struct|opaque type|private record)/{hdr=$0; inb=1} inb && /String/ {print FILENAME":"NR": ["hdr"] "$0} /^$/{inb=0}' stage_09_core/ir.brp
grep -nE '\bString\b' stage_03_parse/parsed_ast.brp
sed -n 476,700p stage_06_typecheck/infer.brp | grep -nE 'String|record|union'      # typed AST
grep -nE '\bString\b' stage_07_ctfe/value.brp
# readers of CoreVar.name (lower bound: five receiver spellings only)
grep -rE '\b(variable|var|binding|binder|param|target|capture)\.name\b|\.name\.name\b' stage_08_core_lower stage_09_core stage_10_backend
grep -rE '\bfield\.name\b' stage_07_ctfe stage_08_core_lower stage_09_core stage_10_backend
grep -rE '\b(function_info|func_info|function|caller)\.name\b' stage_08_core_lower stage_09_core stage_10_backend
grep -rE '(variant|constructor)\.name\b'   stage_08_core_lower stage_09_core stage_10_backend
grep -rn 'constructor_c_name\|tag_c_name\|reuse_constructor_c_name' .
grep -rnE '\.c_name|\.static_name' stage_10_backend
grep -rn 'UnprojectedCEmissionSymbolsForTests' ../                      # 14 arms, emit.brp only
grep -rn 'CowFieldTakeRetainPolicy\|NamePattern(' .
# section 2: derived names
grep -rn '\$blorp\$' .                                                    # 11 sites
grep -rn '"__def_\|MANGLED_DEF_ID_PREFIX\|TAG_' .
grep -rn '__tensor_raw_view\|_blorp_clambda\|__blorp_option_fusion\|loop_view_internal_name\|question_bind_name\|tuple_destruct_name' .
grep -rn 'fresh_version\|pure func fresh_var\|pure func core_var(' stage_08_core_lower stage_09_core
grep -rnE '\bid = 0\b' stage_08_core_lower stage_09_core stage_10_backend   # 46 on main
for f in mono_name_base is_mono_specialization_name is_pure_variant_name strip_pure_suffix synthesis_source_name; do grep -rn "\b$f(" . ; done
grep -rn 'starts_with("blorp_StackOption_\|split_var_callable_id\|split_canonical_module_type_name\|dim_var_name_without_sigil\|core_ufcs_source_name_for_module' .
grep -rn 'field_index_in_bounds' stage_09_core/tuple_sroa.brp
git diff origin/main...backend/local-symbols-by-id -- blorp/src/compiler/stage_10_backend blorp/src/compiler/stage_09_core/ir.brp
# section 3: string-keyed tables
grep -rnE 'Dict\[String|Set\[String\]' stage_04_modules stage_06_typecheck stage_07_ctfe
grep -rnE '^\s*(private )?[a-z_0-9]+: (Dict|Set)\[String|type alias .*(Dict|Set)\[String' stage_08_core_lower stage_09_core stage_10_backend ../lsp
grep -rE 'Dict\[String, String\]' stage_10_backend | grep -c type_symbol_lookup   # 183
grep -rc module_member_prefixes .
# section 4: .text readers (heuristic classifier, /tmp/cat/text_readers.py, not committed)
grep -rE '\.text\b' stage_03_parse stage_04_modules stage_06_typecheck stage_07_ctfe stage_08_core_lower
grep -rn 'name_id_index(' ..                                               # 20, all in compact_expression_product.brp
# section 5
grep -rn 'c_local_name(\|c_identifier(\|c_field_name(\|is_compact_temp_c_name(\|c_var_name(' stage_10_backend
```

The `.text` classifier is line-based and approximate; counts are for sizing,
not proof. The "render" figure in particular is a floor, because most of
`concat` (76 of 675) is diagnostic message construction.

## 1. Name-bearing String fields

`Readers` classes: render (text becomes output), key (dictionary/set/list
membership), compare, concat, parse (substring/split/`parse_int`). Counts are
grep counts on the receiver spellings given in Method and are lower bounds.

### Parsed AST (stage 03)

`ParsedIdentifier { name: NameId, text: String, span }` is the only name carrier;
declarations, patterns, types and expressions all hold it. Other Strings in
`parsed_ast.brp` are literals, docs, `module_path`, `c_name` (FFI) and
`builtin_name`.

- `.name` (the `NameId`) has **no semantic reader outside stage 03**:
  `name_id_index(` appears 20 times, all in `compact_expression_product.brp`;
  `.name.name` appears 8 times in stages 03/06. Typecheck, CTFE and lowering
  read only `.text`. So the id is populated on every identifier and used by
  nothing yet.
- `.text` readers, stages 03/04/06: 675; stage 07: 25; stage 08: 78 (section 4).
- Disposition: **dead after D8**; `text` is duplicated by the table entry, so the
  field can go once diagnostics and the formatter render through
  `name_spelling`. Until then it is the only reader-facing spelling.
- Dynamic spellings still carry `name_id_pending_dynamic_intern()` (`-1`):
  dimension hashes (`"#" + current_text`, `language_parser.brp:1840,1906`),
  `synthesized_identifier(state, "#", ...)`, CTFE materialization. A `TODO` in
  `name_table.brp:257` names them. Any `NameId`-keyed table must reject `-1`.

### Typed AST (stage 06)

`TypedNameExpr(ParsedIdentifier, ...)`, `TypedAssignExpr(ParsedIdentifier, ...)`,
patterns and concurrent/with bindings hold the parsed identifier, so the id
rides along. Genuine Strings in `infer.brp:476-732`:

| Record.field | Readers | Disposition |
| --- | --- | --- |
| `TypedAssignTarget.name` | subscript-assign lowering | convertible now (`ParsedIdentifier`) |
| `ResolvedCallInfo.callee_name`, `.source_name` | lowering (`lowered_name_expr_name`, `resolved_imported_call_explicit_name`), CTFE IR (`ctfe_ir_direct_call`), `type_name`/`is_heap` reflection | callee: dead after D8 plus a definition id for the callee (`ResolvedCallTarget` carries `CallableId`); source_name: must stay for reflection and diagnostics |
| `TraitMethodCallee.{source_name, method_name, trait_name}`, `ResolvedSelectedTraitMethodCall(String, CallableId)` | trait dispatch keys | dead after trait id keys (`accepted_trait_implementation_authority` already has `trait_indices_by_semantic_name`) |
| `TypedConstructorPattern(..., String, Int)`, `TypedQualifiedConstructorPattern` | match lowering | convertible now: the `Int` is the constructor index, the String is the parent type name |
| `TypedWithBinding.cleanup_function`, `.resource_loop_item_name` | lowering of `with` | convertible now to a callable id / name id |
| `TypedExprInfo.resource_dependencies: List[String]` | capture analysis | convertible now (`NameId`) |
| `ExprTypeOrigin.SynthesizedOrigin(String)` | diagnostics | must stay |
| `VarSymbol.module_path: Option[String]` | import lookup | must stay (path text) |

### CTFE values (stage 07)

`CtfeRecordValue(List[(String, CtfeValue, ResolvedFieldIdentity)])`,
`CtfeIrField.name`, `CtfeIrRecordField(String)`, `CtfeIrTupleField(Int, String)`,
`CtfeEnv = List[(String, CtfeBinding)]`, `CtfeConstructorInfo.parent_type`,
`CtfeConstructorValue payload.name`. Readers: equality on the spelling
(`value.brp:528`), linear field lookup and update, `materialize.brp`
(rebuilds `TypedRecordExpr` from the spelling), error text. C2 and C6 above.

### Core IR (stage 09) and lowering (stage 08)

| Record.field | Readers, by class | Disposition |
| --- | --- | --- |
| `CoreVar.name` | 380 `variable.name` in stage 09 (perceus `balance` 84, `uses` 64, `mutable` 63, `ssa` 46, `results_and_loops` 32, `resolve` 31, `match_lowering` 25, `closure` 21, `dce` 15), 21 in `lower.brp`, 32 in `emit.brp`. Classified over five receiver spellings in 08/09/10: 199 compare (mostly `core_var_equal` = name + id), 48 key (`Dict`/`Set` scopes: perceus `scope`, `local_aliases`, `protections_by_name`, `candidate_ids_by_name`, `short_circuit` name sets), 31 copy, 4 concat, 1 parse, 329 forwarded to a helper (of which JSON, diagnostics, `var_from_name`). | **dead after D3**. It is identity today because 46 sites mint `id = 0` and `core_var_equal` includes the name; `emit` falls back to it for id 0 and for the `_` discard. |
| `CoreVar.def_id` + `name` for globals/callables | `resolve.brp`, `closure.brp:671 definition_identity_exists(definitions, name, def_id)`, `mono_impl.brp replacement_def_id(mapping, def_id, name)`, `dce.brp` | convertible now where `def_id` is `Some`: the name is validation data (`CoreDefinitionIdentity { name, def_id }`, "kept for validating phase-boundary identity") |
| `CoreParam.name: CoreVar`, `CoreClosureCapture.{name, id}` | free-var analysis (`add_free_var(name, id, typ)`), emit env slots (`c_binder_name` on the branch) | same as `CoreVar`; capture `name` is compared against `moved_captures: List[String]` (`emit.brp` 3 sites, 16 total references), so that list is convertible now to `List[Int]` for captures with an id |
| `CoreTaskCapture.name` (no id on main; `3b57fd02b` adds `id`) | `emit.brp` 12 capture sites | dead after `backend/local-symbols-by-id` + D3 |
| `CoreFunction.name` | 72 in stage 09 (`flatten` 18, `resolve` 10, `mono_specialize` 9), 19 in 08, 11 in 10. compare 13, key 11, copy 18, other 41. Keys of `functions_by_name`, `callable_names`, rewrite tables | must stay as display; **convertible now** as a key (there is `CoreFunction.def_id`) |
| `FieldExpr` String, `CoreRecordFieldValue.name`, `CoreValueRecordField.name`, `CoreHeapRecordField.name` | emit render (`c_field_name`, 14), `static_child_path`, JSON, the C2 compares, pre-resolve module-member/constructor/tuple uses | see C2, C5, D4 |
| `CowFieldTakeRetainPolicy(CoreVar, String)` | one reader: `emit.brp:13745` renders `record_c->field`; `reuse.brp:2086` matches it; JSON | dead after D4 (then `CoreFieldRef`) |
| `CoreUnionVariant.{name, c_name, tag_c_name}`, `CoreEnumVariant.{name, c_name}`, `constructor_name` (164 references), `CoreUnionConstruct.{type_name, constructor_name, constructor_c_name}`, `CoreConstructorMatchCase.constructor`, `CoreSemanticConstructorMatchCase.constructor` | `match_lowering` index by constructor name, `match_projection` `variants_by_name` (variant.name: compare 8, key 4), emit render (`c_name`, `tag_c_name`), `c_symbol_projection` preserved-name list | D6 for the C spellings; the constructor-name keys are convertible now to constructor `def_id` (each variant has one) |
| `constructor_c_name` production | two copies (`lower.brp:6040`, `prepare.brp:3565`) plus `mono_data.brp:857` and `closure.brp:583`, all `__def_<id>_<name>` | T5 |
| `CoreClosureCreate.{function_name, c_name, static_name}`, `CoreTaskClosure` same, `CoreClosureAbi.c_name` | see D5 | dead after T8 |
| `CoreStackOptionRepresentation.option_type` etc. | C4 | convertible now |
| `CoreType` names, `CoreTypeParam`, `CoreFunction.type_params: List[String]`, `CoreTypeAliasDecl.name` | 1,000+ sites | D9 |
| `CoreRuntimeUnionCase`, `CoreOperationErrorCase`, bridge records, `CoreDirectRuntimeCall.name`, `CoreHashContainerConstructor.CustomHash...(String, String, Bool)` | runtime ABI text | must stay |
| `CoreDefinitionIdentity.name` | validation only | must stay until validation compares ids only; then dead |
| `CoreSourceFile.{path, module_name}`, `CoreFunction.source_module: Option[String]` | flattening, `synth_name`, `identity.brp` | convertible to `ModuleId` (C8) |

### Backend records

`BackendTypeNaming` (nine derived C names per type, built once), `CCallableSymbol`
(`qualified_name`, `original_c_spelling`, `projected_name`),
`CCallableSymbolCandidate.original_c_spelling`, `FunctionEmissionContext`
tables. All are C-spelling products; the id-keyed precedent already exists
(`by_definition_id: Dict[Int, CCallableSymbol]` beside
`by_original_c_spelling: Dict[String, CCallableSymbol]`). Dead after D5/D6 for
the `original_c_spelling` half.

### LSP consumption

`blorp/src/lsp` reads no `ParsedIdentifier.text` and no `NameId`
(`grep ParsedIdentifier|NameId|name_table lsp` is empty). It keys
`definitions_by_symbol` / `references_by_symbol` on a string built from
artifact id + kind + `definition_id` (`analysis_model.brp:290`), i.e. an id
serialized to text; instruction/cleanliness work only, and the exported-symbol
key must remain cross-artifact text.

## 2. Derived names built from text

| Name | Where | Why unique today | Existing id | Parsed back? | Disposition |
| --- | --- | --- | --- | --- | --- |
| SSA `<name>__v<n>` | `ssa.brp:1111 fresh_version` | base name plus a threaded version counter; `id = 0` | binder id (would be minted) | no | D1 |
| `$blorp$tuple_sroa$<label>$<n>`, `id = n` | `tuple_sroa.brp:244` | pass-local counter in the text and the id | `next_binder_id` | no | D1 (branch sets `id = 0`) |
| `$blorp$collection_pipeline$<len>$<label>$<n>`, `id = band + n` | `collection_pipeline.brp:164` | counter + id band | same | no | D1 |
| `$blorp$string_pipeline$<len>$<prefix>$<n>` | `string_pipeline.brp:167` | counter (id band spelled in full) | same | no | D1 |
| `$blorp$parallel_tensor$`, `$blorp$record_update$`, `$blorp$perceus$owned_result` | `parallel_tensor_pipeline.brp:32,572`, `record_update.brp:65`, `results_and_loops.brp:3564` | counters / fixed name per scope | same | no | D1 |
| `$blorp$match_scrut$<owner_def_id>$<rows>$<depth>`, `id = depth` (0 on branch) | `match_projection.brp:1249,1256` | owner definition id + source rows + depth | `owner_def_id` is already an id | no | D1; `id = depth` on main is not unique across owners, the text is |
| `__blorp_option_fusion_<seed>_<label>` | `mono_option.brp:95` | per-site seed | minted id | no | D1 |
| `__tensor_raw_view_<name>_<id>` | `tensor_specialize.brp:1168` | source binder's name and id; the view **shares the tensor's id** on main, so the text is the only discriminator | minted id | no; audit fixtures pin the prefix (`tensor_loop_views_direct.brp`, `tensor_raw_view_loop.brp`) | D1 |
| `_blorp_clambda_<n>`, `_blorp_task_<n>` (`TASK_NAME_PREFIX`) | `closure.brp:215,1766,1780` | per-module counter, paired with a fresh `def_id` | `def_id` (allocated in the same call) | no | convertible now: the name is display; C symbol is projected by `def_id` |
| `__def_<id>_<name>` (`MANGLED_DEF_ID_PREFIX`) | `lower.brp:6043`, `prepare.brp:3569`, `mono_data.brp:857`, `closure.brp:583` (4 producers; constant duplicated in `closure.brp:221` and `emit.brp:993`) | the id in the text | the id | **yes**: `emit.brp:13443` `starts_with` | C3, T5 |
| `TAG_<type>_<variant>` | `lower.brp:6318`, `flatten.brp:3343`, `mono_data.brp:858`, re-derived at `emit.brp:25088` | concrete type name + variant name | variant `def_id` | no (but the fourth spelling can disagree with the field) | D6 |
| `__mono_<encoded>` / `__pure` | `mono.brp:1299,1357-1363`; `identity.brp:60` | encoded substitution text | function `def_id` | **yes**, through the single accessor set in `synth_name.brp` (5 call sites: `resolve` 377/391, `std_inline` 244/254, `collection_plan` 119/127, `string_pipeline` 413; plus 12 `synthesis_source_name` users) | the specialization has a `def_id`; parse-back is consolidated (`b8eea81f2`) but still real; dead after specializations publish `origin_name` structurally |
| UFCS `__ufcs_<module with $>__<name>` | `identity.brp:96-150` | module path + name | resolved call target id | **yes**: `core_ufcs_source_name_for_module` (`resolve.brp:1564`, `mono_specialize.brp:542`) | dead after Core carries the unflattened source name (the doc comment on the function says so) |
| `module::Type` canonical type name | `semantic_type.brp:637`; parsed by `split_canonical_module_type_name` (`:383`, called `:671,:780`) and `identity.brp flatten_canonical_core_type_name` | module path + type name | `DefinitionId` of the type | **yes** | D9 territory; `c6add3a92` left one parser each |
| qualified `alias.Type` | `type_resolution.brp:112 split_qualified_type_name` | source form | `ParsedQualifiedNamedType(ParsedIdentifier, ParsedIdentifier, ...)` already has both parts | yes, from a joined String | convertible now: the parsed AST keeps the two identifiers separate; the join-then-split is avoidable |
| `#N` dimension spelling | parser synthesizes `"#" + text`; `is_dim_var_name`, `dim_var_name_without_sigil`, `mono.brp:367` | sigil in the text | `ParsedTypeParamDecl.kind` (headers already read it) | yes | D7 |
| `runtime_projection` trait method `"<trait>_<method>_<type key>"` | `runtime_projection.brp:167` | `starts_with(trait_name + "_")` is an idempotence guard, not a parse | `CoreImplDecl` + method `def_id` | heuristic (a method named `Trait_x` is mistaken for already-projected) | convertible now: project once, keyed by `def_id`, no prefix test |
| `blorp_StackOption_<payload>` and pointer-suffixed C types | `c_type_layout.brp:55,82-134` | payload type name | `CoreType` payload | **yes** | C4 |
| `__blorp_closure_env_<c_name>` (+ `_destroy_`) | `emit.brp:12363` | callable C spelling | `def_id` | no | D5 |
| static storage `__blorp_static_{record,tuple,union,list}_<path>` | `c_naming.brp:224-258`, `static_child_path`, `c_symbol_projection.brp:591`, `emit.brp:24578` | root name + field spellings / indices | field id, global `def_id` | no | D4 for the field part; otherwise must stay (preserved-name set) |
| `__qb_`, `__td_`, `__loop_<label>_<start>_<end>`, `__timeout_`, `__pattern_param_<i>_<start>_<end>`, `__record_update_<start>` | `lower.brp:1634-1649,2474,2879,5581,5603` | source span offsets in the text | binder id (`core_binder_id` = start offset + 1: unique per file, not per artifact) | no | D1 |
| `__blorp_reuse_<type>_<c_name>` | `reuse.brp:3599` and `c_naming.brp:261` | type + variant C name | | no | two derivations of one C name in different stages (T5); I could not make them disagree with a union named `linux` (reserved word), so this is a duplicate-authority finding, not a demonstrated bug |

Class-3 survivors from the census, current state:

| Site | Status on `5e567133c` |
| --- | --- |
| `tuple_sroa.field_index_in_bounds` (`parse_int` on the field spelling) | live, C5/T3 |
| `runtime_projection` trait-prefix strip | live, heuristic, above |
| `core_ufcs_source_name_for_module` | live, above |
| `split_var_callable_id` | **dead in production**, dead-now item 2 |
| `split_canonical_module_type_name` | live, two call sites |
| qualified `.` split (`split_qualified_type_name`) | live, avoidable |
| `dim_var_name_without_sigil` | 2 callers left, D7 |
| `c_type_layout` C-string parsing | live, C4 |
| strip `__mono_`/`__pure` | five parsers deleted, one accessor set remains |
| `ctfe_ir_clean_source_name` | **dead in production**, item 3 (not in the census) |
| `variable_has_cleanup_slot` `__def_` prefix | live, C3 (not in the census) |

## 3. String-keyed tables

Counts are references, not tables. Keyword grouping (approximate; the file
lists are the reliable part).

| Stage | `Dict[String` / `Set[String]` refs | What is keyed | Key that could replace it |
| --- | ---: | --- | --- |
| 02 lex | 4 | the name table itself (`id_by_spelling`) | is the table |
| 04 modules | 15 | canonical path to `ModuleId`, requested path counts, manifest fields | must stay (path text): `module_table.id_by_canonical_path` *produces* `ModuleId` |
| 06 typecheck | 130 (about 76 declaration/callable/constructor/trait names, 20 module/path, 11 type names, 5 local/binder) | `accepted_{record,alias,union,trait_implementation}_authority` (`visible_*_by_source_name`, `canonical_*_by_name`, `constructors_by_module`), `declaration_skeleton.latest_skeleton_index_by_name`, `type_header_dependencies.node_indices_by_name`, `type_header_graph.header_indices_by_name`, `module_binding.*`, `module_view.standalone_*_by_local_name`, `env.symbols_by_name`, ten `names: Dict[String, Bool]` duplicate-parameter checks in `callable_headers`/`implementation_headers`, `module_prelude` `Set[String]` (`local_names`, `seen`) | source-name keyed: `NameId` (available on every `ParsedIdentifier`); canonical (`module::Type`) keyed: `DefinitionId`; `visible_names_by_field_key` is a joined-field-names key, needs a sorted `NameId` list key |
| 07 ctfe | 1 + the env association list | `group_indices_by_source`; `CtfeEnv` | `NameId` |
| 08 core lower | 64 | `module_member_prefixes` (87 refs), `list_layout` `aliases`/`declared_types`/`list_layouts`, `flatten` `name_facts`/`rewrites`, `callable_names` | `ModuleId`; `def_id` for callables; type keys wait for D9 |
| 09 core | 217 (about 93 declaration/callable/constructor/trait, 82 type names) | callables: `resolve` (six tables), `closure.functions_by_name`, `dce`, `std_inline.by_name: Dict[String, Dict[Int, ...]]` (already two-level with a def-id key), `consume_specialize.by_name`; types: `record_update.record_decls` (30), `mono_data.templates` (20 `CoreTypeAliasDecl`, 20 templates), `allocation_analysis`, `prepare.unions_by_name`, `match_projection.unions_by_name`, `reuse.variants_by_union_name`, `trait_resolve`; binders: perceus `env`, `mutable.local_aliases`, `short_circuit`, `borrowed.candidate_ids_by_name`, `cancellation_plan.let_protections_by_name`, `shadow_catalog`; constructors: `match_lowering.index_by_constructor`, `Sets` of constructor names | callables and constructors: `def_id`; binders: binder id (D3); types: D9 |
| 10 backend | 241, of which **183 are the single threaded parameter `type_symbol_lookup: Dict[String, String]`** | one table (Core type name to projected C symbol) mentioned on every emitter helper; `by_original_c_spelling` (parallel to `by_definition_id`), `preserved`/`taken` collision sets, `static_string_literal_pool.ids_by_value`, C reserved sets | the real table count is about 30; `type_symbol_lookup` is D9-keyed; `by_original_c_spelling` dies with D5; the rest must stay |
| lsp | 27 | uri/module/document stores, semantic symbol key | must stay (uris), symbol key is an id already serialized |

All of these are hash probes: converting them is instruction and
cleanliness work. The census counted backend `Dict[String` as 231; it is one
table plus about 48 others.

## 4. `.text` readers on `ParsedIdentifier`

Stage totals: 03: 67, 04: 17, 06: 591 (sum 675 vs the census's "about 655";
the difference is every textual `.text` read, including `source.text`
file-contents reads in `source_ast_finalize`); 07: 25; 08: 78.

Heuristic classes over stages 03/04/06 (`/tmp/cat/text_readers.py`):

| Class | Count | Notes |
| --- | ---: | --- |
| compare with a literal | 25 | listed below |
| compare with another value | 13 | listed below |
| dictionary/set/list key | 51 | listed below |
| concat (almost all diagnostic message text) | 76 | render |
| parse/inspect (`starts_with`, `substring`, `length`) | 11 | `compact_expression_product` 4, `bridge.brp` 4, `language_parser` 1, `foreign_validation` 1, `inventory` 1 |
| render (explicit error text) | 3 | |
| pass-through (argument or binding) | 496 | sampled: about 80% forwards the spelling into a typed-AST/header/decl String field or a lookup function (`env_lookup(..., name.text)`, `infer_session_accepted_callable(state, name.text)`, `claim_callable_id_from_span(state, method.name.text, ...)`); about 20% (95 lines matched by lookup keywords) are lookup arguments; 6 are diagnostics |

Per-file counts (total = compare_lit / compare_other / key / concat / parse / render / pass):

| File | Total | c_lit | c_oth | key | concat | parse | render | pass |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `stage_06/infer.brp` | 215 | 18 | 2 | 16 | 29 | 0 | 0 | 150 |
| `stage_06/decl.brp` | 121 | 4 | 3 | 0 | 31 | 0 | 1 | 82 |
| `stage_06/headers/declaration_skeleton.brp` | 40 | 0 | 2 | 0 | 0 | 0 | 0 | 38 |
| `stage_06/headers/implementation_headers.brp` | 38 | 0 | 0 | 6 | 6 | 0 | 0 | 26 |
| `stage_03/compact_expression_product.brp` | 26 | 0 | 0 | 0 | 0 | 4 | 0 | 22 |
| `stage_03/source_ast_finalize.brp` | 25 | 0 | 2 | 13 | 0 | 0 | 0 | 10 |
| `stage_06/graph/definition_index.brp` | 21 | 0 | 1 | 0 | 0 | 0 | 0 | 20 |
| `stage_06/headers/callable_headers.brp` | 17 | 0 | 0 | 2 | 2 | 0 | 0 | 13 |
| `stage_06/graph/source_name_table.brp` | 16 | 0 | 0 | 0 | 0 | 0 | 0 | 16 |
| `stage_06/modules/module_prelude.brp` | 16 | 0 | 0 | 11 | 0 | 0 | 0 | 5 |
| `stage_06/headers/type_header_graph.brp` | 15 | 1 | 0 | 0 | 0 | 0 | 0 | 14 |
| `stage_06/headers/trait_headers.brp` | 14 | 0 | 1 | 0 | 4 | 0 | 0 | 9 |
| `stage_04/module_surface.brp` | 13 | 0 | 0 | 1 | 0 | 0 | 0 | 12 |
| `stage_06/modules/module_binding.brp` | 13 | 0 | 0 | 0 | 0 | 0 | 0 | 13 |
| `stage_06/graph/semantic_occurrence.brp` | 11 | 0 | 0 | 0 | 0 | 0 | 0 | 11 |
| `stage_06/bridge.brp` | 9 | 0 | 0 | 0 | 1 | 4 | 0 | 4 |
| `stage_06/types.brp` | 9 | 1 | 0 | 0 | 0 | 0 | 0 | 8 |
| `stage_03/parsed_ast_json.brp` | 8 | 0 | 0 | 0 | 0 | 0 | 0 | 8 |
| `stage_03/language_parser.brp` | 7 | 0 | 0 | 0 | 1 | 1 | 0 | 5 |
| `stage_06/foreign_validation.brp` | 7 | 1 | 0 | 1 | 2 | 1 | 2 | 0 |
| other 14 files | 34 | 0 | 2 | 1 | 0 | 1 | 0 | 30 |

The compare and key sites, individually (line numbers on `5e567133c`):

- **compare with a literal (25):** `decl.brp:4969` (`!= "main"`), `:5760` (`== "Self"`), `:6212` and `foreign_validation.brp:256` (`== "include"`), `:12048` (`== "main"`); `type_header_graph.brp:1349` (`== "#_"`); `types.brp:81` (`== "Self"`); `infer.brp:13944,13972,19444,19475,19642,19665,20061,20285,20928,20978,21533,21543,21821,21880,21895,22001` (all `"_"`), `:18798` (`"length"`), `:18807` (`"length"`).
- **compare with another value (13):** `source_ast_finalize.brp:1058` (rewrite old name), `:3446` (file text, not a name); `decl.brp:3583,5507,5727`; `definition_index.brp:2103`; `declaration_skeleton.brp:1479,1532`; `trait_headers.brp:309`; `infer.brp:6065` (`field.name.text == field_name`), `:17493`; `typed_ast_json.brp:1761,1857`.
- **key (51):** `source_ast_finalize.brp` 13 (`bound: List[String]` free-identifier analysis at `:347-384,718,859,875,934,977,1004`); `infer.brp` 16 (`:3677,4281,11800,12065,12115-12138,12251,13630,13947,18454,18456,19447,21898`); `module_prelude.brp` 11 (`:41-58,177,179,209,211`); `implementation_headers.brp` 6 (`:435,443,491,603,611,613`); `callable_headers.brp` 2 (`:384,492`); `type_header_dependencies.brp:231`; `module_surface.brp:453`; `foreign_validation.brp:247`.

Stages 07/08: 14 literal compares (13 in `lower.brp` are `== "_"`, 1 in `ctfe/ir.brp`), 3 keys, 3 concat, 3 render, 80 pass-through.

## 5. Sanitization and escaping that becomes dead

Callers on `5e567133c` and, in parentheses, on `backend/local-symbols-by-id`:

- `c_var_name` (82 uses in `emit.brp`) calls `c_local_name(variable.name)` on main; on the branch it calls `c_binder_name(name, id)` for non-`def_id` vars.
- `c_local_name` direct callers, main: `c_var_name` (1), closure capture/env sites `emit.brp:12380,12538,12640,12829,16303` (5), `c_symbol_projection.brp:708` global names (1). Branch: `c_var_name` (only the `def_id.is_some()` arm), and `c_symbol_projection.brp:690`; the five capture sites move to `c_binder_name`.
- `c_identifier` callers: `emit.brp` 18, `c_symbol_projection.brp` 14, `c_naming.brp` 9, `canonical_empty_list.brp` 1.
- `c_field_name`: 14 calls, all `emit.brp`. `is_compact_temp_c_name`: 1 (inside `c_local_name`).

| Branch | Reachable after the two in-flight branches? | Remaining callers | Dead after |
| --- | --- | --- | --- |
| `c_local_name` `contains("$blorp$")` to `__blorp_internal_` | yes, for `id == 0` binders (every D1 class on the branch), for `def_id` vars, and `_` | synthetic binders with `id = 0` (about 9 pass classes), entrypoint refs | D1 |
| `c_local_name` escape (`__blorp_internal_`, compact-temp shape, canonical empty list, `__blorp_source_`) | yes, for *globals* (`c_symbol_projection.brp:690/708` passes `global.name.name`) and `id == 0` authored locals: closure free vars at id 0 (`closure.brp:1441`), pattern binders (no id), `_` | globals, captures, pattern binders | D2: globals projected by `def_id`; pattern binders and closure captures given ids |
| `c_local_name` `c_identifier(name)` | yes (same callers) | same | same |
| `is_compact_temp_c_name` | only via the escape branch | none independent | with the escape branch |
| `c_identifier` in general | yes | types, fields, callables' preserved spellings, variant `c_name`, static paths, `union_instance_name`/`_init_name`/`_reuse_name`, closure env names | never fully: foreign/exported names and type/variant symbols; shrinks with D5/D6/D4 |
| reserved-word suffixing for **locals** | dead once no local goes through `c_local_name` (D1, D2); `brp_v_...` and `brp_vn_...` cannot be a C keyword | | D2 |
| `c_field_name` `header` and `__blorp_field_` escapes, `c_identifier` on fields | live for every record; dead for non-ABI records once members are spelled by ordinal (D4) | ABI records (`abi_type = Some`) keep `c_identifier` only | D4 |
| `raw_view` names in `tensor_raw_view_decl`, `emit_tensor_raw_read/write` | the branch already routes them through `c_var_name` | | done on branch |

Two cautions for the branch:

1. `c_var_name` was measured at 1,050,677 calls in a small program and
   allocation-free on the common path (`backend_emission_attribution_2026-09-23.md`).
   The branch spelling is `"brp_v_" + encode_base62(id)`, and `encode_base62`
   builds the payload with `substring(digit, 1) + payload` per digit, so each call
   allocates several strings. That is a per-use cost where the old path was zero
   (unmeasured; 1.05M x a few allocations is the order of the emitted-line count's
   allocation budget of 12.86 per line). Precompute the local spelling once per
   binder (the `project-local-symbols` pass shape) instead of at each use.
2. `moved_captures: List[String]` (`emit.brp` `contains(capture.name)`) and every
   `Dict[String, Bool]` scope in Perceus still key on the spelling, so id-spelled
   C does not by itself make those readers id-based.

## 6. Allocation weight

Only three groups have a measured or arithmetic claim; the rest is cleanliness.
A field's *type* changing does not change allocation counts (the record is still
allocated; a `String` field is a retained pointer); only removing a
construction (concat, split, substring, tuple return, derived-name build) does.

| Item | Evidence | Worth an allocation/RSS claim? |
| --- | --- | --- |
| `split_var_callable_id` per name reference | 543,738 allocations, 14.29% of the 3.80M `TypedNameExpr` budget, about 2.9% of the 19.0M lowering allocations; `core_lowering_allocation_attribution_2026-09-22.md` | **yes**: dead-now item 2; re-measure (`b8178c20e` touched this file since) |
| `core_var` | 348,992 allocations, 1.83% of lowering (same report); one record per `CoreVar` | no: removing `CoreVar.name` does not remove the record; only a struct conversion would, and `struct_conversion_boxing_lesson` says record fields only |
| `TypedNameExpr` | 3.80M, 19.98%; `lowered_name` 343,458 (`core_ufcs_function_name` concatenation per reference), `resolved_definition_id` 469,963 | the UFCS-name concatenation is D-class (needs Core to carry the source name); the rest is not name text |
| mono/pure marker parsing | `b8eea81f2`: instructions -1.0%, RSS -0.8% (small program), a small allocation cost from the correct scan | already claimed; remaining accessor set is the last of it |
| `__blorp_internal_` compiler-binding spellings | `c_emission_bytes_2026-09-27.md`: 3,264,290 bytes over 76,632 occurrences (42.6 bytes each) of a 73.4 MB artifact (4.4%). Arithmetic, not a measurement: spelling them `brp_vn_<id>` (about 10 bytes) would remove roughly 2.4 MB (3.3%) of C text | **yes for C bytes and C-compile time**, unmeasured for compiler allocations; the report itself warns that compact-name work reduced size while regressing backend allocations, so a stage-2 measurement is required |
| `__t<kind>_<n>` compact temps | 4,365,711 bytes, 634,852 occurrences | not a Core name; out of scope here |
| id-spelled locals at emission | `c_var_name` 1.05M calls, currently allocation-free; branch makes each allocate (caution 1 above) | **risk**: measure before landing |
| Perceus/resolve/dce name-keyed dictionaries (48 key-class `variable.name` sites, section 3) | hash probes, no allocation | no: instruction and cleanliness only |
| `.text` readers (675), `ParsedIdentifier.text` | the field is a retained pointer into the table; the 496 pass-through sites forward it | no claim available; removal saves 8 bytes per identifier record at most |
| C-type strings baked in Core (C4) | not measured | unknown; the parsers run only under a non-empty `type_symbol_lookup`, i.e. in emit |
| static string pool, literal texts | data | none |

Existing measurement gaps worth filling before T7/T8: a per-pass count of
`id = 0` binders in a self-compile (the branch's contract counted 649 residual
report lines against 18,904 before, but not by class), and an emission
allocation attribution with the branch's `c_binder_name` in place.

## Rough edges surfaced

- `synthesized_name_id` rebuilds the seeded table on every call and its own
  comment says test-only; there is no production way to get the id of `_`,
  `Self` or `main` without one. That is the blocker for C1.
- `PURE_NAME_SUFFIX` (`synth_name.brp:24`) and `CORE_PURE_OVERLOAD_SUFFIX`
  (`identity.brp:60`) are the same marker with two owners despite `b8eea81f2`'s
  "one place"; `MANGLED_DEF_ID_PREFIX` is declared in `closure.brp:221` and
  `emit.brp:993`.
- Authored binder ids are `start_offset + 1` (`core_binder_id`): unique within a
  file, not within an artifact. Inlining a function from another file can collide
  them; the branch's allocator fixes the minted ones only. Any id-keyed table
  must be keyed per function, not global, until authored ids are re-minted.
- `--dump-core`'s JSON has about 248 decoders that only tests and two benchmark
  profiles use; they enlarge every field change in `ir.brp` (15,724 lines).
