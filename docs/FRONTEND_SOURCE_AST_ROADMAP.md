# Frontend Source-AST Ownership Roadmap

Status: historical roadmap. It records the source-AST ownership slices that led
to the current frontend graph and typed-program bridge; use
`BLORP_COMPILER_PORT_ROADMAP.md` as the current production-boundary source of
truth.

Last checked against code on 2026-07-02.

This is the next contiguous OCaml-to-Blorp compiler chunk. The goal is to finish
the source parser and source-AST ownership boundary from the Blorp CLI/source
graph inward, without starting type inference yet.

The immediate target is:

```text
Blorp CLI args/source graph/source reads
  -> Blorp lexer/parser
  -> Blorp source-AST finalization for compile/check/run
  -> one frontend_module_graph JSON handoff
  -> OCaml module validation and typecheck
```

Formatter and LSP still need raw parse data. Compile/check/run need a
typecheck-ready source AST. The roadmap therefore introduces an explicit source
AST phase instead of hiding transformations in OCaml helpers or typecheck.

## Current Boundary

Production `check`, `compile`, and `run` already use Blorp to plan the command,
read roots, discover source imports, parse sources, and emit a
`frontend_module_graph` artifact.

Current active functions:

- `compiler/blorp/compiler_cli.brp`
  - `run_cli`
  - command branches that call `frontend_module_graph_for_roots`
- `compiler/blorp/compiler_cli_source_graph.brp`
  - `frontend_module_graph_for_roots`
  - `parse_source_request_value`
  - `parse_source_item_request_value`
  - `parse_sources_request_value`
  - `parser_artifact`
  - source/import discovery helpers feeding the graph
- `compiler/blorp/compiler_parser_bridge.brp`
  - `handle_parse_source`
  - `handle_parse_sources`
  - `parsed_source_artifact`
  - `parse_source_item`
  - `source_comment_jsons`
- `compiler/blorp/compiler_parser.brp`
  - `parse_compiler_source`
  - parser helpers that emit `ParsedProgram`
- `compiler/blorp/compiler_parsed_ast_json.brp`
  - `parsed_program_to_json`
  - `parsed_expr_to_json`

The graph is decoded by OCaml and then consumed by the OCaml middle:

- `compiler/lib/compiler_blorp_bridge.ml`
  - `parse_source_request_json_at_phase`
  - `parse_sources_request_json`
  - `parse_source_via_command_at_phase`
  - `parse_source_file_via_command_at_phase`
  - `parse_sources_via_command`
  - `cli_frontend_module_graph_response_field`
- `compiler/bin/blorp_ocaml_host.ml`
  - `cli_frontier_frontend_module_graph`
  - `finalize_cli_frontend_graph_source`
  - `finalized_cli_frontend_graph_sources_or_exit`
  - `module_origin_of_cli_frontend_module_origin`
- `compiler/lib/modules.ml`
  - `parse_source_artifact_with_blorp_bridge`
  - `parse_raw_source_artifact`
  - `parse_typecheck_source_artifact`
  - `parse_raw_source`
  - `parse_typecheck_source`
  - module parse-cache preload and validation helpers
- `compiler/lib/typecheck.ml`
  - `typecheck_with_state_and_source`
  - `typecheck_module_with_state_and_source`

The parser-adjacent OCaml semantics targeted by this roadmap have moved:

- String interpolation raw text is now split in Blorp, and interpolation holes
  are parsed during the Blorp `typecheck_source` finalization phase.
- Nested function declarations are now hoisted in Blorp before the OCaml
  typechecker consumes the source AST.
- Subscript reads are now rewritten by the Blorp typecheck-source finalizer.
  Subscript assignment remains in inference because it needs type and
  mutability context.

Current remaining OCaml ownership starts after this source-AST boundary:
module validation, type environment construction, inference/typechecking,
typed-AST validation, and Core lowering still consume OCaml `Ast.program` /
`Typed_ast.program` values.

## Completion Criteria

This chunk is complete:

- `frontend_module_graph` sources for `check`, `compile`, and `run` carry an
  explicitly typecheck-ready source AST.
- Raw parse output still exists for formatter, LSP, parser tests, and source
  tooling.
- OCaml no longer owns interpolation splitting/hole reparsing, nested function
  hoisting, or subscript-read desugaring for production compile/check/run.
- `compiler/lib/interp_parser.ml`, `compiler/lib/interp_parser.mli`,
  `compiler/lib/nested_hoist.ml`, and `compiler/lib/subscript_desugar.ml` have
  been deleted.
- The old `Modules.finalize_blorp_parsed_source*` helpers are gone; remaining
  module parse entry points request either raw parse or `typecheck_source`
  explicitly.
- No new bridge action was introduced. The existing `parse_source` and
  `parse_sources` payloads carry the explicit AST phase.

## Non-Goals

- Do not start porting inference/typecheck in this chunk.
- Do not move subscript assignment out of `infer.ml`; assignment has semantic
  checks that belong with typechecking until the typechecker ports.
- Do not redesign module validation, package policy, import cycles, or std
  loading here.
- Do not remove the OCaml `Ast.program` type yet. The OCaml middle still needs
  an input type until Checkpoint 9 starts.
- Do not preserve old syntax for compatibility. Blorp is pre-0.1.

## Source-AST Phases

Use explicit phases so raw source consumers and typecheck consumers do not
accidentally share the wrong representation.

Proposed Blorp model:

```blorp
enum ParsedProgramPhase:
    RawParsedProgram
    TypecheckSourceProgram
```

Raw parsed source permits:

- `ParsedStringInterpolationExpr(String, Bool, CompilerSourceSpan)`
- `ParsedFunctionDeclExpr(ParsedFunctionDecl)`
- `ParsedSubscriptExpr(ParsedExpr, List[ParsedExpr], CompilerSourceSpan)`

Typecheck source should not permit:

- raw string interpolation
- nested function declaration expressions
- subscript-read expressions

Typecheck source may still permit:

- `ParsedSubscriptAssignExpr`, because assignment lowering depends on
  inference/typecheck state.

The JSON should carry the phase near the parsed AST:

```json
{
  "path": "...",
  "module": "...",
  "ast_phase": "typecheck_source",
  "parsed_ast": { ... }
}
```

Raw tools use `"ast_phase": "raw_parse"` or omit the field only during a short
transition. Compile/check/run should require `"typecheck_source"` before OCaml
typecheck is called.

## Slice 0: Guard The Boundary Before Moving It

Status: implemented on 2026-07-02. Parser bridge artifacts now carry
`ast_phase`, raw parser consumers default to `raw_parse`, and compile/check/run
frontend graphs request and are validated as `typecheck_source`.

Purpose: make the current and target source-AST phases observable before any
semantic porting.

Stages:

- Blorp raw parse: source text -> `ParsedProgram`
- Blorp parser bridge: `ParsedProgram` -> JSON artifact
- OCaml bridge decode: JSON artifact -> `Compiler_blorp_bridge.parsed_source`
- OCaml CLI frontier: graph source -> parsed/preloaded source

Functions to change or add:

- `compiler/blorp/compiler_parsed_ast.brp`
  - add `ParsedProgramPhase`
  - add helpers such as `parsed_program_phase_name`
- `compiler/blorp/compiler_parsed_ast_json.brp`
  - add `parsed_program_phase_to_json`
  - add `parsed_program_artifact_to_json` if keeping phase outside
    `ParsedProgram`
- `compiler/blorp/compiler_parser_bridge.brp`
  - add request decoding for `ast_phase`
  - thread phase through `parsed_source_artifact`
  - keep raw as the default only for parser/formatter callers during transition
- `compiler/blorp/compiler_cli_source_graph.brp`
  - update `parse_source_request_value`
  - update `parse_source_item_request_value`
  - update `parse_sources_request_value`
  - compile/check/run graph requests should request `TypecheckSourceProgram`
- `compiler/lib/compiler_blorp_bridge.ml`
  - add a `parsed_source_phase` type
  - decode and validate `ast_phase`
  - update `parse_source_request_json_at_phase`
  - update `parse_sources_request_json`
  - update `cli_frontend_graph_source_list_field`
- `compiler/bin/blorp_ocaml_host.ml`
  - make `finalize_cli_frontend_graph_source` reject raw parse artifacts for
    compile/check/run once the typecheck phase exists

Tests to add or update:

- `compiler/blorp/tests/test_compiler_parsed_ast.brp`
  - phase name round trips
- new `compiler/blorp/tests/test_compiler_parsed_ast_json.brp`
  - raw artifact includes `ast_phase`
  - typecheck artifact includes `ast_phase`
- `compiler/blorp/tests/test_compiler_bridge.brp`
  - `parse_source` accepts raw phase
  - `parse_source` accepts typecheck phase
  - `parse_sources` preserves per-request phase or shared phase
- `compiler/blorp/tests/test_compiler_cli.brp`
  - `frontend_module_graph_for_roots` requests typecheck source for
    check/compile/run
- `compiler/test/test_compiler_blorp_bridge.ml`
  - `test_parse_source_request_uses_bridge_envelope`
  - `test_parse_sources_request_uses_bridge_envelope`
  - add phase decode tests for frontend graph sources

Validation:

```bash
./blorp test --no-format compiler/blorp/tests/test_compiler_bridge.brp
./blorp test --no-format compiler/blorp/tests/test_compiler_cli.brp
dune exec --profile=dev --root compiler -- ./test/run_tests.exe test CompilerBlorpBridge
git diff --check
```

Exit criteria:

- Phase appears in parse artifacts.
- Compile/check/run graph path asks for typecheck source.
- Raw parser consumers can still ask for raw parse output.
- No OCaml semantic finalizer has moved yet.

## Slice 1: Port String Interpolation Finalization

Status: implemented on 2026-07-02. Typecheck-source parse artifacts now
rewrite raw interpolation into finalized interpolation parts in Blorp. Raw parse
artifacts still expose raw interpolation for formatter/parser consumers.

Purpose: move raw string interpolation splitting and hole parsing into Blorp so
OCaml no longer reparses interpolation holes.

Current OCaml entry points:

- `Interp_parser.split_interpolated_string`
- `Interp_parser.requests_for_raw_string`
- `Interp_parser.collect_program_requests`
- `Interp_parser.parse_batch_checked`
- `Interp_parser.transform_expr_consuming_batch`
- `Interp_parser.transform_program_with_expr_batch_parser`
- `Modules.parse_interpolated_exprs_with_blorp_bridge`
- `Modules.interp_wrapper_var_name`
- `Modules.interp_wrapper_var_index`
- `Modules.interp_error_loc_for_diagnostic`

Proposed Blorp data and functions:

- `compiler/blorp/compiler_parsed_ast.brp`
  - add `union ParsedStringInterpolationPart`
    - `ParsedInterpolationLiteral(String)`
    - `ParsedInterpolationExpr(ParsedExpr)`
  - add `ParsedStringInterpolationPartsExpr(List[ParsedStringInterpolationPart], Bool, CompilerSourceSpan)`
    or replace the existing raw interpolation variant with separate raw/final
    variants
- new `compiler/blorp/compiler_source_ast_finalize.brp`
  - `split_interpolated_string`
  - `interpolation_hole_requests_for_raw_string`
  - `collect_interpolation_hole_requests`
  - `parse_interpolation_hole_program`
  - `parse_interpolation_holes`
  - `rewrite_interpolation_expr`
  - `rewrite_interpolation_decl`
  - `rewrite_interpolation_program`
  - `finalize_interpolation_program`
- `compiler/blorp/compiler_parser_bridge.brp`
  - `parsed_source_artifact` should call interpolation finalization when the
    requested phase is `TypecheckSourceProgram`
- `compiler/blorp/compiler_parsed_ast_json.brp`
  - encode final interpolation as `"kind": "string_interp"` with `"parts"`
  - keep raw interpolation as `"kind": "string_interp_raw"` only for raw parse
- `compiler/lib/parsed_ast_json.ml`
  - `decode_expr` should decode `"string_interp"` into `Ast.EStringInterp`
  - it should continue decoding `"string_interp_raw"` only for raw consumers
    until direct OCaml raw parse tests are migrated

Tests to add or update:

- new `compiler/blorp/tests/test_compiler_source_ast_finalize.brp`
  - split literals and one hole
  - split multiple holes in source order
  - escaped braces remain literal
  - escaped string content matches current OCaml behavior
  - nested braces inside interpolation holes
  - quoted strings inside interpolation holes
  - unclosed interpolation reports a parse diagnostic at the containing string
  - nested interpolation inside parsed hole is finalized recursively
  - duplicate/equivalent hole text does not reorder parsed expressions
- `compiler/blorp/tests/test_compiler_parser.brp`
  - raw parse still emits raw interpolation for raw phase/parser tests
- `compiler/blorp/tests/test_compiler_bridge.brp`
  - typecheck phase returns final interpolation parts
  - raw phase returns raw interpolation
- `compiler/test/test_parser.ml`
  - temporarily keep `test_interpolation_bridge_preserves_hole_order_in_nested_blocks`
    until Blorp tests and parser fixtures prove parity, then delete the OCaml
    unit test when `Interp_parser` is gone
- `tests/test_compiler/parser/should_pass/string_interp_basic.brp`
- `tests/test_compiler/parser/should_pass/string_interp_expr.brp`
- `tests/test_compiler/parser/should_pass/string_interp_escape.brp`
- `tests/test_compiler/parser/should_pass/nested_interp_quotes.brp`
- `tests/test_compiler/parser/should_fail/string_interp_unclosed.brp`
- `tests/test_compiler/parser/should_fail/string_interp_unterminated.brp`
- `tests/test_compiler/infer/should_pass/string_interp_types.brp`
- `tests/test_compiler/infer/should_fail/string_interp_not_stringable.brp`

Validation:

```bash
./blorp test --no-format compiler/blorp/tests/test_compiler_source_ast_finalize.brp
./blorp test --no-format compiler/blorp/tests/test_compiler_parser.brp
dune exec --profile=dev --root compiler -- ./test/run_tests.exe test Parser
dune exec --profile=dev --root compiler -- ./test/run_tests.exe test ParsedAstJson
scripts/test compiler
git diff --check
```

Exit criteria:

- Typecheck-phase JSON contains no raw interpolation nodes.
- Compile/check/run do not call `Modules.parse_interpolated_exprs_with_blorp_bridge`.
- Interpolation diagnostics remain user-facing parse diagnostics.

## Slice 2: Port Nested Function Hoisting

Status: implemented on 2026-07-02. Typecheck-source parse artifacts now hoist
nested function declarations in Blorp, emit deterministic mangled top-level
helpers, rewrite in-scope call sites, and report parent-capture diagnostics
before the OCaml typechecker consumes the program.

Purpose: make nested function declaration finalization Blorp-owned before the
OCaml typechecker sees a program.

Current OCaml entry points:

- `Modules.finalize_parsed_program`
- `Nested_hoist.hoist_program`
- `Nested_hoist.hoist_func`
- `Nested_hoist.hoist_impl_method`
- `Nested_hoist.hoist_body`
- `Nested_hoist.rewrite_ident`
- `Nested_hoist.free_idents_of`
- `Nested_hoist.find_capture`
- `Nested_hoist.capture_error`
- `Nested_hoist.mangle`

Proposed Blorp functions:

- `compiler/blorp/compiler_source_ast_finalize.brp`
  - `mangle_nested_function_name`
  - `rewrite_identifier_expr`
  - `pattern_bound_names`
  - `free_identifiers_of_expr`
  - `find_nested_capture`
  - `nested_capture_diagnostic`
  - `hoist_nested_body`
  - `hoist_nested_function_decl`
  - `hoist_nested_impl_method`
  - `hoist_nested_program`
  - `finalize_nested_functions_program`
- `compiler/blorp/compiler_parse_diagnostic.brp`
  - add structured diagnostic helpers if needed for capture errors

Implementation notes:

- Preserve the current semantic behavior first. Do not trust stale comments in
  `nested_hoist.ml` over current tests and observed behavior.
- Keep mangling deterministic per program so fixture expectations remain stable.
- Continue forbidding captures from parent locals and params.
- Preserve sibling declaration-order behavior.
- Preserve private function doc handling if current behavior depends on it.
- Keep nested function hoisting in the typecheck-source phase only; raw parse
  should still expose `ParsedFunctionDeclExpr` for formatter/LSP if they need it.

Tests to add or update:

- `compiler/blorp/tests/test_compiler_source_ast_finalize.brp`
  - simple nested function hoists with deterministic name
  - nested function call is rewritten to mangled name
  - nested function inside private function preserves parent declaration shape
  - nested function inside impl method hoists to top-level helper
  - nested function inside nested function is handled according to current
    implementation behavior
  - earlier nested sibling can be referenced by later nested body if current
    behavior supports it
  - capture of parent param reports a diagnostic with captured name
  - capture of parent local reports a diagnostic with captured name
  - lambda scope is not rewritten by nested function identifier replacement
- `compiler/blorp/tests/test_compiler_bridge.brp`
  - typecheck phase returns no nested function declaration expressions
  - raw phase still returns nested function declaration expressions
- `tests/test_compiler/parser/should_pass/nested_func_basic.brp`
- `tests/test_compiler/typecheck/should_fail/nested_func_captures_parent_local.brp`
- `compiler/test/test_pipeline.ml`
  - migrate or delete `test_imported_module_runs_nested_hoist` after an
    equivalent Blorp/source-graph test exists

Validation:

```bash
./blorp test --no-format compiler/blorp/tests/test_compiler_source_ast_finalize.brp
./blorp test --no-format compiler/blorp/tests/test_compiler_bridge.brp
dune exec --profile=dev --root compiler -- ./test/run_tests.exe test Pipeline
scripts/test compiler
git diff --check
```

Exit criteria:

- Typecheck-phase JSON contains no `function_decl` expression nodes.
- `Nested_hoist.hoist_program` is no longer used by production compile/check/run.
- Nested function diagnostics still appear before or at typecheck with clear
  source locations.

## Slice 3: Port Subscript-Read Desugaring

Status: implemented on 2026-07-02. Typecheck-source parse artifacts now rewrite
subscript reads in Blorp, compile/typecheck/module-loading paths explicitly
request `typecheck_source`, the OCaml typecheck entry no longer runs a subscript
fallback, and the unused OCaml `subscript_desugar.ml` module has been removed.

Purpose: remove the last parser-adjacent syntactic transform from OCaml while
leaving semantic subscript assignment checks in inference.

Former OCaml entry points:

- `Subscript_desugar.nd_get_name`
- `Subscript_desugar.mk_call`
- `Subscript_desugar.rewrite_node`
- `Subscript_desugar.transform_expr`
- `Subscript_desugar.transform_func`
- `Subscript_desugar.transform_trait_method`
- `Subscript_desugar.transform_impl`
- `Subscript_desugar.transform_trait`
- `Subscript_desugar.transform_decl`
- `Subscript_desugar.transform_program`
- `Typecheck.typecheck_with_state_and_source`
- `Typecheck.typecheck_module_with_state_and_source`

Proposed Blorp functions:

- `compiler/blorp/compiler_source_ast_finalize.brp`
  - `subscript_get_builtin_name`
  - `make_untyped_call_expr`
  - `rewrite_subscript_read_node`
  - `rewrite_subscript_read_expr`
  - `rewrite_subscript_read_func`
  - `rewrite_subscript_read_trait_method`
  - `rewrite_subscript_read_impl`
  - `rewrite_subscript_read_trait`
  - `rewrite_subscript_read_decl`
  - `rewrite_subscript_read_program`

Implementation notes:

- Only rewrite reads:
  - `x[i]` -> `checked_get(x, i)`
  - `x[s..e]` -> `checked_slice(x, s, e)`
  - `m[i, j]` -> `matrix_checked_get(m, i, j)`
  - `t[i, j, k]` -> `tensor3_checked_get(t, i, j, k)`
  - `tensor4_checked_get` and `tensor5_checked_get` for arity 4 and 5
  - synthesize `tensorN_checked_get` for arity above 5 to preserve current
    downstream diagnostic behavior unless tests justify a better parse diagnostic
- Do not rewrite `ParsedSubscriptAssignExpr`.
- Raw parse must still expose subscript syntax for formatter/LSP.
- The typecheck-source phase may rewrite subscript reads because the current
  OCaml typecheck entry already does that before inference.

Tests to add or update:

- `compiler/blorp/tests/test_compiler_source_ast_finalize.brp`
  - one-index read rewrites to `checked_get`
  - range read rewrites to `checked_slice`
  - two-index read rewrites to `matrix_checked_get`
  - three/four/five-index reads rewrite to tensor builtins
  - six-index read preserves synthetic `tensor6_checked_get` behavior
  - nested subscript rewrites bottom-up
  - subscript in lambda/match/trait default/impl method rewrites
  - subscript assignment remains `ParsedSubscriptAssignExpr`
- `compiler/blorp/tests/test_compiler_bridge.brp`
  - typecheck phase returns calls for reads
  - raw phase returns subscript nodes
- `tests/test_compiler/parser/should_pass/subscript_desugar.brp`
- `tests/test_compiler/parser/should_pass/subscript_basic.brp`
- `tests/test_compiler/parser/should_pass/subscript_chained.brp`
- `tests/test_compiler/parser/should_pass/subscript_assign.brp`
- `tests/test_compiler/infer/should_pass/subscript_array.brp`
- `tests/test_compiler/infer/should_pass/subscript_tensor_2d.brp`
- `tests/test_compiler/infer/should_pass/subscript_tensor_3d.brp`
- `tests/test_compiler/typecheck/should_fail/subscript_too_many_dims.brp`
- `tests/test_compiler/typecheck/should_fail/immutable_subscript_assign.brp`

Validation:

```bash
./blorp test --no-format compiler/blorp/tests/test_compiler_source_ast_finalize.brp
scripts/test compiler
scripts/test compiler-unit
git diff --check
```

Exit criteria:

- Typecheck-phase JSON contains no subscript-read nodes.
- `Typecheck.typecheck_with_state_and_source` and
  `Typecheck.typecheck_module_with_state_and_source` no longer call
  `Subscript_desugar.transform_program`.
- `ESubscriptAssign` remains visible to inference.

## Slice 4: Make The Frontend Graph Authoritative

Status: implemented on 2026-07-02. Normal check/compile/run paths consume
phase-validated `typecheck_source` graph artifacts, direct typecheck/module
paths explicitly request `typecheck_source`, raw parser users request raw parse,
and OCaml no longer performs source-AST semantic finalization on graph-provided
programs.

Purpose: route normal compile/check/run through the Blorp finalized source graph
with no OCaml finalization pass.

Functions to change:

- `compiler/blorp/compiler_cli_source_graph.brp`
  - `frontend_module_graph_for_roots`
  - all graph parsing helpers should request typecheck source
- `compiler/blorp/compiler_cli_artifact_json.brp`
  - `cli_frontend_module_graph_artifact_json` should emit phase-bearing sources
- `compiler/lib/compiler_blorp_bridge.ml`
  - `cli_frontend_module_graph_response_field` should validate graph source phase
  - `validate_cli_frontend_import_edges` remains edge validation only
- `compiler/bin/blorp_ocaml_host.ml`
  - `finalize_cli_frontend_graph_source` should become strict decode and
    diagnostic rendering, not semantic transformation
  - `cli_frontier_frontend_module_graph` should preserve preloaded finalized
    programs exactly as provided by the graph
- `compiler/lib/modules.ml`
  - `parse_source_artifact_at_phase` should request the correct AST phase based
    on caller intent and preserve the parser-produced module surface
  - direct typecheck callers should request typecheck source
  - raw parser/tooling callers should request raw parse

Tests to add or update:

- `compiler/blorp/tests/test_compiler_cli.brp`
  - graph sources are phase-bearing
  - graph module imports preserve phase
  - roots and modules do not mix raw and typecheck phases for compile/check/run
- `compiler/test/test_compiler_blorp_bridge.ml`
  - frontend module graph rejects raw source for compile/check/run
  - frontend module graph accepts typecheck source
  - import edge validation still works with phase-bearing sources
- `compiler/test/test_session.ml`
  - `test_trusted_preloaded_parse_cache_skips_source_reread`
  - add or update a test proving preloaded typecheck-source programs are used
    directly
- `compiler/test/test_pipeline.ml`
  - imported modules use graph-provided finalized source

Validation:

```bash
./blorp test --no-format compiler/blorp/tests/test_compiler_cli.brp
dune exec --profile=dev --root compiler -- ./test/run_tests.exe test CompilerBlorpBridge
dune exec --profile=dev --root compiler -- ./test/run_tests.exe test Session
dune exec --profile=dev --root compiler -- ./test/run_tests.exe test Pipeline
scripts/test cli
scripts/test compiler
git diff --check
```

Exit criteria:

- Normal `check`, `compile`, and `run` do not run OCaml source-AST finalization.
- Preloaded graph modules are trusted only after phase and import-edge
  validation.
- Synthetic/direct parser tests have an explicit raw/typecheck choice.

## Slice 5: Delete Replaced OCaml Code

Status: implemented on 2026-07-02. `interp_parser.ml`,
`interp_parser.mli`, `nested_hoist.ml`, and `subscript_desugar.ml` have been
deleted; the old `Modules.finalize_blorp_parsed_source` helper was removed;
OCaml parser-finalizer unit tests were removed or renamed to current phase
ownership.

Purpose: pay down the migration debt immediately after production no longer uses
the OCaml finalizers.

Deletion candidates:

- `compiler/lib/interp_parser.ml`
- `compiler/lib/interp_parser.mli`
- `compiler/lib/nested_hoist.ml`
- `compiler/lib/subscript_desugar.ml`

Functions to remove or shrink:

- `compiler/lib/modules.ml`
  - remove `parse_interpolated_exprs_with_blorp_bridge`
  - remove `interp_wrapper_var_name`
  - remove `interp_wrapper_var_index`
  - remove `interp_error_loc_for_diagnostic`
  - remove `compiler_error_of_interp_parse_error` if it has no other caller
  - reduce or delete `finalize_parsed_program`
  - reduce `finalize_blorp_parsed_source_for_bridge`
- `compiler/lib/typecheck.ml`
  - remove `Subscript_desugar.transform_program` calls
  - update comments that say subscript desugar is an OCaml typecheck-entry pass
- `compiler/lib/ast.ml`
  - keep raw source variants while formatter/LSP/typecheck still need the OCaml
    AST, but update comments that name deleted OCaml passes
- `compiler/lib/typed_ast.ml`, `compiler/lib/core_lower.ml`,
  `compiler/lib/ctfe_ir.ml`, and invariant comments
  - keep defensive checks for impossible raw nodes if they still protect the
    OCaml middle
  - update messages to name the Blorp source finalizer instead of deleted OCaml
    modules

Tests to delete or migrate:

- OCaml interpolation unit tests in `compiler/test/test_parser.ml` once covered
  by `compiler/blorp/tests/test_compiler_source_ast_finalize.brp`
- OCaml pipeline tests that only prove imported modules run `Nested_hoist`, once
  graph finalization tests prove imported modules are already finalized
- Any OCaml unit tests whose only subject is deleted finalizer implementation
  detail

Tests to keep:

- Parser should-pass/should-fail fixtures
- Infer/typecheck subscript fixtures
- Formatter comment/interpolation fixtures
- LSP/source-position tests
- Bridge decoder tests around strict phase validation

Validation:

```bash
rg "Interp_parser|Nested_hoist|Subscript_desugar" compiler
make
scripts/test compiler-unit compiler cli
./blorp test --no-format compiler/blorp/tests/test_compiler_source_ast_finalize.brp
git diff --check
```

Exit criteria:

- `rg "Interp_parser|Nested_hoist|Subscript_desugar" compiler` has no
  production references.
- Deleted modules are removed from Dune/library lists.
- Remaining references are only historical docs, if any.

## Slice 6: Raw Parser Consumer Hardening

Status: implemented on 2026-07-02. Compile/check/run and typecheck-facing
tests request `typecheck_source`; parser tests, LSP, REPL classification,
package inspection, and parse-only compiler tests remain raw parser consumers.

Purpose: ensure formatter, LSP, and source tooling intentionally consume raw
parse output rather than depending on the compile/typecheck source phase.

Functions to audit:

- Formatter bridge/code in `compiler/blorp/compiler_format.brp`
- Formatter tests in `compiler/blorp/tests/test_compiler_format.brp`
- OCaml LSP callers:
  - `compiler/lib/lsp/lsp_state.ml`
  - `compiler/lib/lsp/lsp_position.ml`
  - `compiler/lib/lsp/lsp_completion.ml`
  - `compiler/lib/lsp/lsp_references.ml`
  - `compiler/lib/lsp/lsp_inlay_hint.ml`
- Shared raw parse entry:
  - `Modules.parse_raw_source`
  - `Modules.parse_raw_source_artifact`
  - direct callers that need raw source should make that raw phase visible in
    the helper name at the call site

Tests to add or update:

- `tests/test_compiler/format/should_pass/comment_interp.brp`
- `tests/test_compiler/format/should_pass/comments_with_imports.brp`
- `tests/test_compiler/format/should_pass/wrapped_string_literals.brp`
- `tests/test_compiler/parser/should_pass/comment_between_if_else.brp`
- LSP tests covering comments/spans/nested function symbols if present
- `compiler/test/test_parser.ml`
  - keep only raw parser integration tests that cannot live in Blorp yet

Validation:

```bash
scripts/test compiler cli
./blorp test --no-format compiler/blorp/tests/test_compiler_format.brp
git diff --check
```

Exit criteria:

- Raw parser users are explicit.
- Compile/check/run are not raw parser users.
- Comments and spans still flow as data, not global parser state.

## Slice 7: Docs, Benchmarks, And Regression Gates

Status: implemented on 2026-07-02. Architecture and parser roadmaps document the
raw/typecheck-source split, the deleted OCaml finalizers are absent from
production code, and the bridge/unit tests enforce phase labels for frontend
graph artifacts. No parser benchmark was added because this change only moves
the existing finalization work across the bridge; add one later if profiling
shows source-AST finalization as a measurable frontend cost.

Purpose: make the completed chunk reviewable and keep future changes from
reintroducing parser-adjacent OCaml.

Docs to update:

- `docs/ARCHITECTURE.md`
  - source frontend stage ownership
  - raw parse vs typecheck-source phase
- `docs/BLORP_COMPILER_PORT_ROADMAP.md`
  - mark Checkpoint 10 slices completed as they land
- `docs/PARSER_API_ROADMAP.md`
  - replace remaining cleanup list with final status
- `docs/GRAMMAR.md`
  - only if syntax behavior changes
- `docs/GUIDE.md`
  - only if user-facing behavior changes

Optional benchmark work:

- Add parser/source-AST timing to `benchmarks/bench.sh` only if the finalization
  pass has measurable cost.
- Candidate benchmark subjects:
  - lex only
  - raw parse
  - typecheck-source finalization
  - JSON encode/decode
  - complete frontend module graph construction

Regression checks:

- Add a hygiene check if practical:
  - compile/check/run graph artifacts must request `typecheck_source`
  - raw parse artifacts must not enter `Typecheck.typecheck*`
  - no production references to deleted finalizer modules

Validation:

```bash
make
scripts/test compiler-unit compiler cli
./blorp test --no-format compiler/blorp/tests
git diff --check
```

## Suggested Merge Order

1. Slice 0: phase guardrails only.
2. Slice 1: interpolation finalization.
3. Slice 2: nested function hoist.
4. Slice 3: subscript-read desugar.
5. Slice 4: make frontend graph authoritative.
6. Slice 5: delete OCaml finalizers.
7. Slice 6: harden raw parser consumers.
8. Slice 7: docs/bench/hygiene cleanup.

Each slice should be self-contained and mergeable. Do not leave the branch in a
state where compile/check/run depend on a planned later slice for correctness.

## Review Checklist

- Does each source consumer request the right AST phase explicitly?
- Is the transformation implemented once, in Blorp, with tests?
- Are diagnostics still structured with source spans?
- Did we preserve formatter/LSP raw parse behavior?
- Did we avoid a new bridge action?
- Did we delete the replaced OCaml implementation and OCaml-only tests?
- Did `scripts/test compiler-unit compiler cli` pass?
- Did `git diff --check` pass?
