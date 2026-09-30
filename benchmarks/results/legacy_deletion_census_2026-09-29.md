# Legacy and test-only code census (2026-09-29)

Base: `origin/main` c47e62f23. Scope: every `.brp` under `blorp/src`
(compiler, lib, lsp, format, lint, purify, check, run, package, test). Rule 14
of `AGENTS.md` (pre-0.1: remove old forms, do not keep shims) is the standard
applied. Read-only analysis; nothing here was deleted.

The complete per-function inventory (1,088 production functions with no
production caller, with file, line, body size and test/bench reference counts)
is `legacy_deletion_census_2026-09-29_functions.tsv` next to this file.

## Headline numbers

| Bucket | Items | Src lines | Test/bench/doc work |
| --- | --- | --- | --- |
| Whole modules reachable only from tests/benchmarks | 6 files | 13,428 (13,367 deletable, 61 relocatable) | ~7.1k test/bench lines, 882 doc lines |
| Functions with no production caller, outside those modules | 980 functions | 17,877 (docstrings not counted) | see per-entry |
| of which Core JSON decoders (`ir.brp`) | 330 functions | 8,377 | 2 test files, 2 bench profiles |
| of which zero references anywhere (test, bench, src) | 263 (excluding decoders) | 5,339 (largest: `bridge.brp` serializer, `decl.brp` observation code) | none |
| Unused types and constants (zero references anywhere) | 12 declarations | ~120 | none |
| Live dual paths and misnamed "legacy" code (category 2) | 14 entries | ~1,100 touching, mostly not deletable at once | per entry |
| Malformed-input fallbacks (category 3) | 3 owners | ~250 | invariant prep step |

Total dead or test-only production source: roughly 31,000 of 395,862 lines in
`blorp/src` (about 7.9 percent), before counting the tests and benchmarks that
only exist to exercise it.

## Method and caveats

1. Every top-level `func` in `blorp/src` was indexed (12,731). Identifier
   tokens in each body (strings and comments stripped) form a name-keyed call
   graph. Roots are `main` (`main.brp` and `format/engine/formatter.brp`), every
   non-function top-level line (constants, records, impl bodies, trait
   defaults) and all impl methods. Import lists are not uses.
2. A function is dead when no root reaches it. Reachability is by name, so an
   overloaded or shared name makes a function look live: the numbers are a
   lower bound on dead code. Nothing was inferred from names (`test`,
   `legacy`); the graph decides.
3. Test/bench reference counts are identifier token counts in `blorp/test`,
   `blorp/benchmark` and `benchmarks/`. They over-count when another module
   reuses the name. Every entry below marked "confirmed" was re-checked with a
   whole-word grep across `blorp/src`, `blorp/test`, `blorp/benchmark`,
   `benchmarks`, `docs`, `scripts`.
4. Whole-module reachability was computed separately from import lists
   (relative and sibling-bare imports resolved).
5. Body line counts exclude the docstring above a function, so line totals
   understate deletions by roughly 10 to 15 percent.
6. Unused types/constants only cover column-0 `record|struct|union|alias|opaque|trait`
   and UPPER_CASE constants whose name appears once in `blorp/src`. Types used
   only by dead functions are not listed (they fall out when the functions do).
7. Overlap column: **EM** emitter owner (record-member, closure-symbol
   branches: `emit.brp`, `c_naming.brp`, `c_symbol_projection.brp`,
   `closure.brp`); **TI** trait-identity branches (`decl.brp`, `env.brp`,
   `infer.brp`, `generic_params.brp`, `types.brp`); **VO** vocabulary branch
   (`infer.brp`, `materialize.brp`, `typed_ast_json.brp`, `builtins.brp`,
   ctfe); **MM** module-member branch (synth passes, pipelines, `resolve.brp`,
   `std_inline.brp`, `mono_option.brp`, `mono_impl.brp`,
   `tensor_specialize.brp`). "none" means no listed file is touched.

Several of the largest items are prospective infrastructure rather than
leftovers (the compact-parser oracle, the backend helper mapping, the work
profiler, the Perceus occurrence index). They have no production caller today
and the owner's stated preference is deletion; the header comments say so
explicitly, and each entry is flagged "prospective" so the owner can decide.
Git history preserves them.

---

## Category 1: production code with no production callers

### 1.1 Whole modules reachable only from tests/benchmarks

| # | File | Lines | Callers (prod/test/bench) | Deleting requires | Overlap | Risk |
| --- | --- | --- | --- | --- | --- | --- |
| M1 | `blorp/src/compiler/stage_03_parse/compact_expression_product.brp` (header: "This module has no production callers") plus the two seam functions `raw_expression_parser_checkpoint` (language_parser.brp:7636) and `raw_expression_parser_batch_checkpoint` (:7667), 64 lines | 11,043 + 64 | 0 / 2 test files (`test_compact_expression_product.brp` 3,874 lines, `test_compact_expression_direct_parser.brp` 404) / 3 benches (`compact_expression_product_schema_probe` 684, `compact_expression_direct_parser_probe` 820, `compact_expression_direct_frame_probe` 25) | delete module, seam, 2 tests, 3 benches, 2 ownership entries in `compiler_test_ownership.json`, `docs/COMPACT_PARSER_MIGRATION.md` (882 lines) and the results docs that cite it | none | low; prospective (the parser does not own a compact representation) |
| M2 | `stage_10_backend/backend_helper_kind_mapping.brp` (header: a later helper-selection pass "is expected to call these"; no caller exists) | 1,573 | 0 / 1 (`test_backend_helper_kind_mapping.brp`, 258 lines) / 0 | delete module, its test, one ownership entry; `allocation_report.brp` header comment mentions the future wiring | none (backend dir, but not the EM files) | low; prospective |
| M3 | `stage_09_core/work_profile.brp` (measurement-only pass profiler) | 412 | 0 / 0 / 2 (`compiler_core_pipeline_work_profile_fixture` 289, `compiler_core_invariant_scan_profile` 129) | delete module and the two profiles, or move it under `blorp/benchmark/compiler/` (it is benchmark support, not compiler code) | none | low; moving preserves the benchmark |
| M4 | `stage_09_core/perceus/index.brp` (function-local occurrence index, "later bottom-up fact builders" not written) | 270 | 0 / `test_core_perceus.brp` / `benchmarks/blorp/profiles/perceus_allocations.brp` | delete module; remove its section of `test_core_perceus.brp`; edit one profile | none | low; prospective |
| M5 | `format/engine/document_json.brp` | 69 | 0 / `test_document_layout.brp` / 0 | delete module; trim one test | none | low |
| M6 | `stage_09_core/function_origin_fixture.brp` (header: "Hand-built Core for tests and benchmark fixtures") | 61 | 0 / 79 test files import it / 32 bench refs | not a deletion: move to `blorp/test/compiler/` (a shared test-support module) and update 79 imports; keeps test fixtures out of `blorp/src` | none | low, mechanical |

### 1.2 Core JSON decoders (`stage_09_core/ir.brp`)

**Kept by owner decision (2026-09-29).** The decoders and their replay tooling stay. Not a deletion candidate; the inventory below is kept for reference.

`decode_core_program_json` (ir.brp:16870) is the only entry; the decoder
cluster is 330 functions, 8,377 lines (`decode_core_*`, the `number_field` /
`kind_field` / `object_field` field readers, `core_json_error_to_string`,
`core_json_record_shapes`, `core_source_loc_decode_seed`, `decode_core_decls`,
plus `module_table.brp:module_id_from_serialized_index`). Confirmed callers:
0 production, 1 test file (`test_core_json.brp`, 6,857 lines, 22 decoder call
sites), 2 benchmarks (`compiler_backend_bridge.brp`, 4 sites;
`benchmarks/blorp/profiles/perceus_allocations.brp`, 2 sites). The JSON
**encoders** are live (`--dump-core`) and stay.

Deleting requires: remove the decode half of `test_core_json.brp` (keep the
encode assertions), move the two benchmarks to obtain Core by compiling source
(the backend-bridge profile currently decodes a stored Core JSON), remove the
`ir.brp` decoder region. Size 8,377 src lines, ~15 percent of `ir.brp`.
Overlap: `ir.brp` is not on any listed branch, but B4 (delete closure/task
`c_name` fields in `ir.brp`) would otherwise have to edit the decoders for
those records: deleting the decoders first shortens B4. Risk: low (the
benchmark migration is the only real work).

### 1.3 The typecheck JSON bridge protocol and typed-AST JSON emission

**Kept by owner decision (2026-09-29).** The bridge stays. Not a deletion candidate; the inventory below is kept for reference.

`stage_06_typecheck/bridge.brp` says "Production compilation consumes typed
values directly. Benchmarks and diagnostic tools use this adapter". The
serialization/handler half is dead in production: 51 functions, 1,699 lines
(`handle_request`, `stream_typecheck_graph_request_chunks*`,
`emit_typechecked_*`, `typed_source_artifact`, `prepare_typecheck_graph_*_with_trace`,
`import_binding_to_json`, `typecheck_graph_with_metrics`, ...; 45 have zero
test/bench references at all). With it: `bridge_protocol.brp` (10 functions,
103 lines, all dead), `typed_ast_json.brp` (13 functions, 141 lines:
`typed_program_to_json` and the `emit_compiler_typed_program_json_chunks*`
family), `inventory.brp` (6 functions, 216 lines, zero references anywhere),
and the callees only they use in `decl.brp` (9), `module_binding.brp` (6),
`definition_index.brp` (2). Dead closure: 97 functions, 2,451 lines. Confirmed
non-production callers: tests 102 sites in 8 files (largest
`test_typed_ast_json.brp`, 1,642 lines; also bridge tests), benchmarks 31
sites in 4 files.

Deleting requires: delete or migrate those 8 test files (the JSON shape tests
have no production behavior to protect once the adapter goes) and the 4
benchmarks; remove ownership entries; the live half of `bridge.brp`
(`TypecheckedGraph`, `TypecheckedModule`, `typechecked_module_identity`, used
by lint, purify, lsp, pipeline) stays. Overlap: `typed_ast_json.brp` is VO,
the 9 `decl.brp` functions are TI; the `bridge.brp`, `bridge_protocol.brp`
and `inventory.brp` part (2,018 lines) touches neither. Risk: medium-low
(`bridge.brp` has ~10 importers, so keep the live declarations when cutting).

### 1.4 The typecheck standalone registration and inference path

Confirmed test-only: `typecheck_register_program_signature_decls` (decl.brp:4671;
60 test sites, 4 files), `typecheck_check_standalone_program_bodies` (:6735; 41
sites, 3 files), `typecheck_materialize_standalone_program_bodies` (:6742; 19,
2 files), `typecheck_register_program_impl_decls` (:4713; 16, 3 files),
`typecheck_register_impl_decls` (:4700; 3, 1 file). Dead closure from those
entry points plus `typecheck_program_with_type_header_module*`,
`typecheck_bind_standalone_program_module_view*`, the `*_syntax` import
registrars and the `..._with_import_modules_with_trace` variant: 49 functions,
972 lines: `register_var_decl[_with_type]`, `register_function_signature[_with_semantic_types]`
(:2667, :2956), `register_function_with_id`, `register_function_decl`,
`register_foreign_function_decl`, `register_trait_decl` / `_with_id` /
`_with_identity`, `register_impl_decl[_with_info]`, `register_impl_with_id`,
`impl_method_info_from_decl(s)` / `_from_semantic_types`, `add_*_checked`,
`dim_constraint_from_parsed`, `env_find_conflicting_impl`,
`env_trait_function_collision`, `typecheck_state_find_private_impl_conflict`,
`typecheck_state_add_private_impl`, plus `module_binding.brp` register_import_*
(6 functions, 107 lines). Test sites: 154 in 7 files
(`test_typecheck_decl.brp` alone holds 105; `test_typecheck_impl_decl`,
`test_typecheck_impl_defaults`, `test_typecheck_resource_decl`,
`test_body_check_order`, `test_bound_module_graph`, `typecheck_test_support`).
Two docstrings already say "Test-only: production ..." (decl.brp:3574, :4565).

Deleting requires migrating those 7 test files onto the graph typecheck entry
(`typecheck_test_support` is the natural seam) so they exercise the production
path; that is the real cost (~154 call sites). Overlap: **TI** (decl.brp,
env.brp): land after or with the trait-identity branches. Risk: medium (test
migration); production behavior does not change.

### 1.5 Preparation observation, authority metrics and accepted-graph accessors

Benchmark-only observation code: `observe_accepted_body_module_preparation`
(decl.brp:10263, 111 lines), `frontend_preparation_unique_declaration_observation`
(:9488, 102), `accepted_typecheck_graph_{declaration,initializer,ctfe_artifact}_preparation_observation`
(44, 65, 53), `observe_call_resolve_env` / `observe_core_call_resolve_env`
(resolve.brp:893, :971), the `accepted_*_authority_metrics`,
`accepted_typecheck_graph_*_metrics` family and `accepted_semantic_catalog_table_counts`.
27 functions, 719 lines (observation) plus 12 functions, 205 lines (metrics).
Callers: 0 test, 8 bench sites in 2 benchmarks (observation); 6 test sites in
3 files (metrics). Deleting requires dropping two benchmarks and 6 assertions.
Overlap: **TI** (decl.brp) and **MM** (resolve.brp, 4 functions). Risk: low.

### 1.6 Bound-module-view candidate machinery

`module_view.brp` dead functions: `bound_import_candidate` (:656, 154 lines),
`bound_candidates_from_visibility` (:830, 135), `module_view_without_unqualified_names`
(:3260, 42; 9 test sites), `bound_visibility_without_unqualified_names`,
`bound_name_constructor`, `module_view_imported_constructors` (10 test sites),
`module_view_for_standalone_source_bindings`, plus 6 `*_without_visible_names`
accessors in the `accepted_*_authority.brp` files. 14 functions, 516 lines; 19
test sites in 2 files, 2 bench sites. Overlap: none. Risk: low.

### 1.7 Range/subscript proof machinery (`type_system/refinement.brp`)

44 of the file's 65 functions are unreachable from production (only
`UNREFINED_BINDING` and the binding types are used): `proof_sources_equal`,
`proves_direct_subscript_with_bounds`, `binding_add_*_proof`, `proof_env_add_*`,
`remove_*_proofs_for_var`, `make_branch_range_proof`, ... 358 lines; 117 test
sites in 1 file (`test_refinement.brp`). Deleting requires deleting that test
file. Overlap: none (the file is imported by infer/decl/typed_ast_json/env but
only for the retained binding types). Risk: low-medium: confirm no design
document treats the proof environment as planned work (`docs/GUIDE.md` range
types are enforced by the dim solver, not this module).

### 1.8 Backend/emission test entry points and profile helpers

Listed only for the emitter owner (`emit.brp`/`c_symbol_projection.brp`, **EM**):
`UnprojectedCEmissionSymbolsForTests` (emit.brp:1013, 14 match sites) with its
entry points `try_emit_unprojected_prepared_core_program_c_artifact_for_tests`
(:27618, 45 lines), `emit_unprojected_core_program_c_artifact_with_profile_for_tests`
(:27665), `emit_unprojected_core_program_c_artifact_for_tests` (:27690; 323 test
sites in `test_core_emit.brp`), `canonical_empty_lists_for_unprojected_program`
(c_symbol_projection.brp:1235), the `UnprojectedCallableValue` variant
(c_symbol_projection.brp:187), `is_unprojected_option_constructor_call`
(emit.brp:1057, 5 call sites). Also dead: `try_emit_prepared_core_program_c_split_artifact_with_profile`
(:28418; 14 test sites), `try_emit_core_program_c_artifact_with_profile` (:27681;
3 test, 2 bench), `error_artifact` (:27541, zero references).
`register_perceus_work_counters` (perceus/work_counters.brp:377, 93 lines, 1
bench) and `perceus.brp:448` wrapper are bench-only. Not touched by this plan
while the closure-symbols worker retires the unprojected mode.

### 1.9 Other test-only entry points and thin wrappers

Small clusters, each 0 production callers and only test (or bench) sites:

| Cluster | Files | Fns / lines | Test sites | Notes |
| --- | --- | --- | --- | --- |
| LSP body-string wrappers `decode_lsp_*_notification`, `handle_lsp_*_notification`, `decode_lsp_initialize_request`, `dispatch_lsp_lifecycle_body`, `position_to_source_offset`, server `*_analysis_for`/`find_document`/`is_loading` | `lsp/workspace/did_*.brp`, `lsp/protocol/*.brp`, `lsp/server/server_actor.brp`, `position.brp` | 18 / 187 | 154 in 10 files | production uses the envelope-level decoders; these are string-taking conveniences. Move to a test-support module rather than delete |
| Test-suite candidate runners with injected runners | `test/effect.brp` (3), `lib/run_effect.brp` (2) | 5 / 92 | 2 | |
| `prepare_compile_plan*`, `execute_compile_plan`, `finish_prepared_compile_execution` | `lib/compilation.brp` | 6 / 122 | 6 | the with-frontend-policy variants are the callers' path already |
| `ctfe_rewrite_program_globals*`, `ctfe_eval_program_global_env`, `ctfe_evaluate_program_globals` | `stage_07_ctfe/globals.brp` | 5 / 103 | 28 in 1 file | |
| `name_table_extension_*` | `stage_02_lex/name_table.brp` | 3 / 29 | 9 in 1 file | |
| Formatter JSON entries `render_{declaration,expression,type}_json`, `*_from_json_string`, `parse_width_args` | `format/engine/*` | 9 / 43 | ~110 in several | test conveniences; keep only if the format tests need them |
| Lexer/parser helpers `lex_ok` (54 test sites), `parsed_program_ok` (129), `token_kind_name`, `source_location_for_file` (80 test, 22 bench), `insert_drops_program` (142), `lower_typed_expr` (80), `lower_typed_decl` (27), `core_lower_context` (33), `rewrite_tuple_sroa_expr` (27), `inline_std_wrappers` (21), `run_early_core_pipeline` (11), `run_pre_dce_tail` (24) | many | ~35 / ~300 | many | test-facing convenience wrappers around live functions (or thin entry points tests prefer). These are the least valuable to delete; relocate to test helpers when touched |
| Core `clone_core_accessor`, `clone_core_literal`, `traverse.map_core_dict_literal_entry(ies)`, `core_flatten_error_to_string`, `clone_key_equal` | stage_09_core | 8 / 90 | few | |
| Typecheck accessors with 0-5 test uses (`env_add_record` 35, `env_add_func` 29, `env_add_var` 13, `widening_reasons_equal` 26, `binary_ops_equal`, `meta_*`, `typed_expr_*_widening`, accepted alias/record/union/global `*_exact`, `definition_index_*`, `type_header_dependencies` alias-cycle search) | stage_06_typecheck | ~190 / ~2,500 | ~600 | the residue of the accepted-authority migration. Delete alongside the entries in 1.4 to 1.6 |

The full list, with lines, is in the TSV.

### 1.10 Unused functions with zero references anywhere (category 4 overlap)

75 root orphans (no test, bench or src reference, not called by other dead
code), 642 lines, all with confirmed zero grep hits. Examples (file:line):
`pipeline.brp:1329 compile_typechecked_graph` (34 lines) and `:1477
run_late_core_compilation` (18), `token.brp:205 scalar_token` and
`token_keyword`/`token_symbol`/`token_string_literal_*`/`token_char_code_point`,
`parsed_ast.brp` `parsed_{decl,type_expr,expr,param_binder,pattern}_span`,
`definition_index.brp:646 definition_tables_are_compatible` (32) and `:1192
definition_index_func_callables_at_span` (35), `state.brp:838
typecheck_state_locate_diagnostics_since` (18), `trait_headers.brp:769`,
`type_header_graph.brp` `*_type_parameter_ids_equal`,
`accepted_trait_implementation_authority.brp` (3), `env.brp:3227
env_find_unsatisfied_trait_obligation`, `origin_name_agreement.brp:285
shape_label`, `pass_runner.brp:525 binder_identity_fault_message`,
`perceus/borrowed.brp:1570/1578`, `reuse.brp:777`, `traverse.brp:1576/1583`,
`source_graph.brp:988/1050`, `host_c.brp:261`, `program_runner.brp:92`, LSP
`module_store_length/is_empty`, `source_store_is_empty`,
`analysis_targets_for_workspace`, `diagnostic_clear_is_current`.
These need no test edits. Combined with the zero-reference members of the
larger clusters this is the 263-function, 5,339-line zero-reference set.

### 1.11 Unused types and constants (category 4)

Zero references anywhere: `DocumentEvent` (lsp/workspace/document_model.brp:60,
5 lines), `ServerWork` (lsp/server/server_work.brp:50, 3),
`FORMAT_USAGE` (format/command.brp:43, 8), `CliRunRequest`
(lib/cli_plan.brp:22, 4), `COMPLETION_KEYWORDS` (language_surface_manifest.brp:25,
46 lines) and `PRELUDE_METHOD_TYPE_IMPORTS` (:395, 23),
`ListHandoffBeginBorrowArgs` / `ListHandoffBeginReuseArgs`
(prepared_list_renderer.brp:206/217, 20), `TupleSroaExprsRewrite`
(tuple_sroa.brp:197, 5), `ETA_ARGUMENT_ORIGIN` (ir.brp:1098),
`CORE_FIELD_REF_RUNTIME_TAG` (ir.brp:3389), `RenderedHelper`
(backend_helper_catalog.brp:55, 4). About 120 lines; no tests. Constants
used only by tests (name-table constants `NAME_ID_*`, `COMPILER_PHASE_ORDER`,
`ALL_INTRINSICS`, `ALL_BACKEND_HELPER_KINDS`, `PROOF_ENV_EMPTY`,
`SINGLE_TRANSLATION_UNIT_POLICY`) are 26 more one-line declarations to relocate.

---

## Category 2: compatibility shims and dual paths

| # | Location | What it is | Callers | Deleting requires | Est. size | Overlap | Risk |
| --- | --- | --- | --- | --- | --- | --- | --- |
| C2-1 | `lib/cli_args.brp:570, 849, 972`; `main.brp:176, 208, 229` (usage text); `docs/DEVELOPMENT.md:495,507` | `--profile` "Temporary alias for --profile-mode exact" (3 parse sites, 3 usage lines) | 5 test files use it (`test_cli_args.brp`, `test_main.brp`, `test_cli.sh`, `test_runtime_profile_dense_ids.py`, `test_identity_work_counters.py`), docs, scripts | rewrite ~9 test invocations to `--profile-mode exact`; drop the alias, update docs; the `legacy_alias_ok` test (test_cli_args.brp:498) becomes a rejection test | ~15 src lines | none | low |
| C2-2 | `stage_03_parse/language_parser.brp:7005` `reject_removed_opaque_conversion` + its two call sites | migration diagnostic for the removed `into Type(...)` / `from Type(...)` syntax, 26 lines | `test_parser.brp:4348` asserts the message | delete; unknown-token diagnostic replaces it. Trade-off: this is the one migration message that helps first-time users (rule 7); keep unless the owner prefers removal | ~30 lines | none | low; UX trade-off |
| C2-3 | `stage_06_typecheck/type_system/semantic_type.brp:337` `is_legacy_single_letter_type_param`, `is_type_param_name` (:345); uses `infer.brp:8028`, `semantic_type.brp:1699` | any zero-argument named type `A`..`Z` is treated as a type variable: a name-shape heuristic that AGENTS.md "Do not rely on flimsy heuristics" forbids | 3 production sites; 4 test sites via `is_type_param_name` | needs the explicit type-parameter representation (`SemanticTypeVar`) to be the only carrier; find why a `NamedType("T", [])` still reaches these sites | ~10 lines plus semantic risk | TI (infer.brp, semantic_type.brp) | high (changes inference); investigate first |
| C2-4 | `infer.brp:7141` `symbol_from_imported_binding` | branch when `module_view_accepted_union_authority` is `None`, builds a "legacy_symbol" via `find_module_constructor` | production, reachable when no accepted union authority exists (standalone views, see 1.4/1.6) | dies with the standalone path (1.4) once every view carries authority | ~15 lines | TI/VO | medium |
| C2-5 | Perceus `count_uses` legacy name-matching walk (`perceus/uses.brp:3692`, 323 lines), `ownership_uses_from_legacy_count` (:367), two `legacy-count-fallback-site` fallbacks (uses.brp:2883, :3128), `perceus_work_legacy_count_node_visits` (work_counters.brp:89) | dual analysis: the id-based `summarize_*` summaries fall back to name counting for match/loop shapes; 5 other production callers (`balance.brp:797,862`, `borrowed.brp:1019`, `results_and_loops.brp:2631`, `ownership_contracts.brp:242`, `perceus.brp:348`) | live in production, plus 17 test sites | replace each call by the summary API; identical-C gate. Do not delete until the fallback sites are proven unreachable by a counter | ~400 lines | none | high (Perceus; identical C and leak gates) |
| C2-6 | `balance_let_body_legacy` (`balance.brp:3809`, 43 lines), `first_borrowed_owner_legacy` (`borrowed.brp:1394`, 44), `first_borrowed_result_owner_legacy` (:1646, 30) | live functions named "legacy": the only let balancer and the fallback arm of the borrowed-owner scans (LetExpr/BorrowLet/matches route to them) | production | rename, not delete (misleading names), or fold into their callers | 0 to ~120 | none | low if renamed |
| C2-7 | `emit.brp:1424` `ClosureEnvStorageKind::LegacyVoidPointerSlots` (`closure_env_storage_kind`, :12502) | closure environments still lay out as `void*` slots when `task_abi`, a non-struct capture, or an unsupported capture exists; `TypedInlineTail` is the other layout. 9 references | live | extend the typed tail to task closures and all capture kinds, then delete the variant | ~120 lines across 9 references | **EM** | high (ABI, leak gates); emitter owner's call |
| C2-8 | `ir.brp:3543` `core_program_max_declared_definition_id` | "kept only for tests and debug tooling"; production use only inside the `check_invariants` frontier check (`pass_runner.brp:234`) | 2 prod (invariant), 12 test/bench files | nothing to delete now; note only | 7 lines | none | none |
| C2-9 | Interim states already in `docs/NAME_ID_ROADMAP.md` / `NAME_MANGLING_REMOVAL_ROADMAP.md` (not re-deleted here): `origin_name_agreement.brp` (504 lines, `BLORP_ORIGIN_CONTRACT`), `typed_name_identity.brp` (211, `BLORP_NAME_IDENTITY`, `pipeline.brp:900`), `BLORP_IDENTITY_CONTRACT`, `BLORP_NODE_IDENTITY` (`pass_runner.brp:830-1071`), `name_spelling_of_text` (name_table.brp:176), `MANGLED_DEF_ID_PREFIX`/`mangled_definition_name` (identity.brp:12, :107; closure.brp:1782,1801,1820), `SOURCE_VARIANT_TAG_PREFIX` fallback (c_naming.brp:538), `c_local_name` id-0 branches, `ParsedIdentifier.text` (parsed_ast.brp:31), 6 temporary `name_table.brp` import permissions | scheduled by A5, M3.1, B1/B5, D2 | those roadmap steps | ~900 lines total | EM (c_naming, closure) | per roadmap |
| C2-10 | Stale-plan fallbacks: `c_symbol_projection.brp:519` `c_emission_type_naming` ("unreachable once `program_symbol_inventory` has walked every declaration; kept only so a caller cannot crash on a stale plan"), `c_naming.brp:494` `INVALID_PROJECTED_TEMPORARY_NAME` | defensive fallbacks for states the invariants exclude | live | replace by an invariant or unreachable-assert equivalent; keep only if a test proves reachability | ~15 lines | EM | low |
| C2-11 | `lsp/protocol/frame_codec.brp:50, 331` `CONTENT_TYPE_LEGACY_UTF8_CHARSET` | accepts `charset=utf8` as well as `utf-8` in Content-Type | LSP wire protocol (spec still lists `utf8`) | **Keep**: the LSP specification names this spelling; not our legacy | 2 lines | none | n/a |
| C2-12 | `lib/source.brp` `source_location` / `source_at_end`, `parsed_program_ok`, `lex_ok` | test-only conveniences in production modules | see 1.9 | relocate to test support | ~30 lines | none | low |
| C2-13 | `stage_09_core/closure.brp:7785` `convert_program` | non-minting shim over `convert_program_minting` (`FIRST_MINTED_BINDER_ID`); 0 production callers, 4 test / 2 bench sites (+ `work_profile.brp`) | | rewrite 6 call sites to `convert_program_minting`; delete 2 lines | 2 lines | **EM** | low |
| C2-14 | Closure function-index diagnostics `closure.brp:7452-7530` (`function_index_diagnostic_entry`, `_entries`, `_name_diagnostics`, `_id_diagnostics`, `_total_collision_entries`, `closure_function_index_diagnostic_snapshot`) | 7 functions, 70 lines, only 3 test and 2 bench refs | | drop with 3.2 below | 70 lines | **EM** | low |

No other flag or environment variable selects an old path: the
`BLORP_*` environment variables read in `.brp` are configuration
(`BLORP_STD`, `BLORP_CC`, `BLORP_TIMEOUT`, ...) or the strict-mode census
switches listed in C2-9. `docs/` mentions no other removed-syntax
diagnostic. `blorp/source_ownership.json` has `legacy_owner_paths` and
`legacy_source_roots` both empty and `legacy_owner_importers` empty: nothing
remains there to delete. `blorp/src/purify` has no dead functions at all.

---

## Category 3: tolerance for malformed input that invariants now exclude

The early invariant `DuplicateFunctionDefinitionId`
(`early_invariants.brp:33, 385-411`) rejects two functions or impl methods
sharing a `def_id`. It is part of `check_debug_invariants`, run by
`early_pipeline.brp:234` first, but only under `--check-invariants`
(`check_invariants` defaults to False in `cli_args.brp:315`; the gates that
pass it are `scripts/test-trait-operators` and `test_cli.sh`). Typecheck
already assigns unique ids, so removal is a correctness-neutral simplification
but the invariant is opt-in: making `duplicate_function_id_violations`
unconditional (one dict pass) is the honest prerequisite.

| # | Location | Tolerance | Invariant covers it? | Est. size | Overlap |
| --- | --- | --- | --- | --- | --- |
| C3-1 | `closure.brp:325, 601-610, 3402-3420, 7400-7450, 7452-7530, 7542` `function_collisions_by_id`, `collisions_by_id`, name tie-break among colliding candidates | same-id functions resolved by exact name | Yes for functions and impl methods (the invariant checks exactly that set) | ~150 lines including the diagnostic chain (C2-14) | **EM** |
| C3-2 | `dce.brp:5-10, 799, 853-864, 935-1017` `function_collisions_by_id`, "duplicate function IDs conservatively collect the dependencies of every collided body" | union of bodies of same-id functions | Yes | ~45 lines | none |
| C3-3 | `resolve.brp:255, 520, 591-833, 862, 898, 1312-1339, 1387, 1449, 2326` `colliding_definition_ids` (`Set[Int]`, ~13 `Sets.add` sites, 5 readers, one metric) | declines resolution when a function, foreign function, builtin, global or constructor id is shared across categories | **Partly**: same-category function duplicates are covered; cross-category sharing (function id equals a global or constructor id) is only rejected by `DuplicateDefinitionId` in `late_invariants.brp:303-335`, which runs after resolve | ~90 lines | **MM** |

For C3-3 the prep step is moving the `declared_definition_id_owners` check
(late_invariants.brp) to an early invariant covering all declaration kinds;
after that all three tolerances are unreachable and can be deleted together.
Dead-in-practice evidence: `flatten.brp:181`, `mono_specialize.brp:136` and
`resolve.brp:1929` already document "definition ids are unique" and carry no
tie-breakers, so the three collision tables are the only remaining holdouts.
`typecheck` side: `implementation_headers.brp:921` mentions a definition-id
collision guard; not investigated further (TI file).

---

## Category 4: unused exports

See 1.10 (75 root orphans, 642 lines) and 1.11 (12 types/constants, ~120
lines). The complete zero-reference set (263 functions outside decoders, 5,339
lines) is derivable from the TSV: rows with `test_refs = 0` and `bench_refs = 0`.

---

## Ranked deletion plan

Each step is one landable change; gate names are from `scripts/test`. All
steps also run `scripts/compiler-check --changed` and `git diff --check`.

| Rank | Step | Src lines deleted | Other churn | Gate | Overlap |
| --- | --- | --- | --- | --- | --- |
| 1 | M1: compact-expression product oracle and parser seam | 11,107 | 2 tests (4,278), 3 benches (1,529), 882 doc lines, 2 ownership entries | `scripts/test compiler-blorp`; check `compiler_test_ownership.json` | none. Owner decision: prospective work |
| 2 | Core JSON decoders (1.2) (kept by owner decision) | 8,377 | half of `test_core_json.brp`; 2 benchmarks moved to compile-from-source | `scripts/test compiler-blorp`, `bin/blorp test test_core_json.brp`, benchmark smoke run | ir.brp (coordinate with B4; do first) |
| 3 | Typecheck JSON bridge adapter, `bridge_protocol.brp`, `inventory.brp` (1.3, non-overlapping part) (kept by owner decision) | ~2,020 | 8 test files, 4 benchmarks | `scripts/test compiler-blorp`, `scripts/test lsp`, `scripts/test cli` | none (typed_ast_json.brp part, 141 lines, later, VO) |
| 4 | M2 backend helper mapping | 1,573 | 1 test (258), 1 ownership entry | `compiler-blorp`, codegen audit unaffected | none |
| 5 | Standalone typecheck registration (1.4) after migrating `test_typecheck_decl.brp` and 6 siblings onto the graph path | 972 | 154 test call sites in 7 files | `scripts/test compiler-blorp` then `compiler-check --stage typecheck` | TI: schedule after trait-identity merges |
| 6 | Preparation observation and authority metrics (1.5) | ~924 | 2 benchmarks, 6 assertions | `compiler-check --stage typecheck`, `compiler-blorp` | TI/MM (resolve.brp part last) |
| 7 | Bound-module-view machinery (1.6) and refinement proofs (1.7) | 516 + 358 | 3 test files (21+117 sites; delete `test_refinement.brp`) | `compiler-blorp` | none |
| 8 | Root orphans and unused types/constants (1.10, 1.11) | ~760 | none | `compiler-check --changed` (no tests reference them) | none (spot-check files against active branches; a few are in decl.brp/env.brp) |
| 9 | M3 work profiler, M4 Perceus index, M5 document_json, `register_perceus_work_counters` | ~850 | 4 benches/tests trimmed | `compiler-blorp`, `scripts/test compiler-core-sanitize leak` | none |
| 10 | Collision tolerance (Category 3): first make the duplicate-id invariant unconditional and early for all declaration kinds; then delete C3-1..3 and the closure diagnostics | ~285 | 7 test + 5 bench references | `compiler-blorp`, `compiler-core-sanitize leak`, `scripts/premerge-gate` sample; identical C | EM (closure.brp) and MM (resolve.brp): land after those branches |
| 11 | `--profile` alias (C2-1), `convert_program` shim (C2-13), `reject_removed_opaque_conversion` (C2-2, owner call) | ~50 | ~15 call sites | `scripts/test cli`, `compiler-blorp` | EM for convert_program |
| 12 | Relocate test conveniences (1.9, M6 fixture, LSP wrappers) into `blorp/test` support modules | ~1,300 moved, not deleted | ~150 imports | `scripts/test lsp`, `compiler-blorp` | none |
| Later | Remaining typecheck accessor residue (1.9 last row, ~2,500 lines), Perceus `count_uses` (C2-5), `LegacyVoidPointerSlots` (C2-7), `is_legacy_single_letter_type_param` (C2-3), unprojected emission (1.8) | ~3,500+ | | per owner | EM/TI/VO |

Top ten by source lines, for quick reference: (1) compact-expression oracle
11,107; (2) Core JSON decoders 8,377; (3) typecheck JSON bridge stack ~2,450
(2,020 non-overlapping); (4) accepted-graph residue and accessors ~2,500;
(5) backend helper mapping 1,573; (6) standalone registration path 972;
(7) preparation observation and metrics ~924; (8) work profiler / Perceus
index / document_json / counters ~850; (9) bound module view 516; (10)
refinement proofs 358.
