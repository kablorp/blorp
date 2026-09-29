# Name text render census

Date: 2026-09-29. Lane A step A4 (`docs/NAME_ID_ROADMAP.md`): every place that
shows a human an identifier's spelling reads it from the compilation
`NameTable` by id, so A5 can delete `ParsedIdentifier.text`. Read-only census at
`origin/main` `ca153cc76`; refreshes the class 1-3 counts of
`name_text_inspection_census_2026-09-28.md`.

## Heuristic

Every line of `blorp/src/**/*.brp` matching `\.text\b` (generated
`embedded_std.brp` and the C runtime excluded): 1,377 lines in 66 files. The
match also catches non-identifier `.text` (token text, document text), so it
overstates `ParsedIdentifier.text` readers. Lines are classed by file and
keyword:

- (b) formatter: file under `format/`.
- (c) LSP: file under `lsp/`.
- (d) JSON / dump: `parsed_ast_json.brp`, `stage_07_ctfe/ir.brp`, `frontend_output.brp`.
- (a) message render: `.text` inside a string interpolation or concatenated into a string literal.
- (f) key or lookup: the line has `==`, `.get`, `.set`, `contains`, `match`, `find_`, `_by_name`.
- (g) unclassified: everything else, mostly a spelling passed to a function.
  Each slice reads its sites before converting; a site that is a key stays
  (belongs to A2b/A5) and is counted in that slice's report.

## Table

Counts are pre-conversion estimates. A line that both renders a spelling and uses
it as a key can be classed (a) or (f) by the keyword rule, so a class count can
misstate by a few lines either way.

| Class | Lines | Main files |
| --- | --- | --- |
| (b) formatter output | ~486 | `format/engine/expression_documents.brp` 279, `declaration_documents.brp` 120, `format/projection.brp` 60, `type_documents.brp` 24 |
| (a) message render (detected) | ~94 | `decl.brp` 32, `infer.brp` 29, `lint/command.brp` 9, `implementation_headers.brp` 6 |
| (f) key or lookup (detected) | ~128 | `infer.brp` 46, `lint/command.brp` 18, `decl.brp` 12, `lexer.brp` 10 |
| (d) AST, Core JSON, dumps | ~40 | `frontend_output.brp` 19, `stage_07_ctfe/ir.brp` 13, `parsed_ast_json.brp` 8 |
| (c) LSP text | ~17 | `workspace_source.brp` 7, `position.brp` 4, `analysis_model.brp` 2 |
| (e) `type_name` reflection | 0 | see below |
| (g) unclassified | ~612 | `infer.brp` 122, `decl.brp` 73, `lower.brp` 50, `declaration_skeleton.brp` 38, `implementation_headers.brp` 38 |

## Class (c) correction

The ~17 LSP `.text` lines counted above are source-file content (`source.text`
fingerprints, comparisons and byte conversion in `workspace_source.brp`,
`position.brp`, `analysis_model.brp`, `frontend_graph.brp`), not identifier
spellings, so there is nothing to convert in the LSP. Its one identifier use is
the `name_spelling_of_text` caller in `semantic_index.brp` (see below). In
`lint/command.brp`, 6 of the 37 lines render a message and were converted in
A4b; about 20 are `name.text == expected` comparisons and about 6 build
`name:`/`index-name:` keys (class f, counted for A5).

## Class (e)

The compile-time `type_name(x)` string is built in `infer.brp` (~10339) by
`type_to_string(arg_type)` from a `SemanticType`, not from `.text`.
`type_name_metadata.brp` holds predicates over type-name Strings and has no
`.text` read. The Strings inside `SemanticType` (`NamedType(String, ...)`) are
type-interning work (D9), not A4.

## `name_spelling_of_text`

The A1 bridge has 3 callers, all holding a String: `lsp/analysis/semantic_index.brp:104`
and `stage_09_core/pass_runner.brp:523,536` (`CoreFunction.name`). It is deleted
by A5 when Core names become ids.

## Per-file counts

| File | `.text` lines |
| --- | --- |
| `format/engine/expression_documents.brp` | 279 |
| `compiler/stage_06_typecheck/infer.brp` | 197 |
| `format/engine/declaration_documents.brp` | 120 |
| `compiler/stage_06_typecheck/decl.brp` | 117 |
| `format/projection.brp` | 60 |
| `compiler/stage_08_core_lower/lower.brp` | 59 |
| `compiler/stage_06_typecheck/headers/declaration_skeleton.brp` | 40 |
| `compiler/stage_06_typecheck/headers/implementation_headers.brp` | 38 |
| `lint/command.brp` | 37 |
| `compiler/stage_02_lex/lexer.brp` | 28 |
| `compiler/stage_03_parse/compact_expression_product.brp` | 26 |
| `test/doctest.brp` | 25 |
| `compiler/stage_03_parse/source_ast_finalize.brp` | 25 |
| `format/engine/type_documents.brp` | 24 |
| `compiler/stage_06_typecheck/graph/definition_index.brp` | 21 |
| `compiler/frontend_output.brp` | 19 |
| `compiler/stage_06_typecheck/headers/type_header_graph.brp` | 17 |
| `compiler/stage_06_typecheck/headers/callable_headers.brp` | 17 |
| `compiler/stage_06_typecheck/modules/module_prelude.brp` | 16 |
| `compiler/stage_06_typecheck/graph/source_name_table.brp` | 16 |
| `compiler/stage_06_typecheck/headers/trait_headers.brp` | 14 |
| `compiler/stage_07_ctfe/ir.brp` | 13 |
| `compiler/stage_06_typecheck/modules/module_binding.brp` | 13 |
| `compiler/stage_04_modules/module_surface.brp` | 13 |
| `compiler/stage_06_typecheck/graph/semantic_occurrence.brp` | 11 |
| `lib/source.brp` | 9 |
| `compiler/stage_06_typecheck/bridge.brp` | 9 |
| `compiler/stage_06_typecheck/types.brp` | 8 |
| `compiler/stage_03_parse/parsed_ast_json.brp` | 8 |
| `lsp/workspace/workspace_source.brp` | 7 |
| `compiler/stage_06_typecheck/type_occurrence.brp` | 6 |
| `compiler/stage_06_typecheck/headers/type_decl_analysis.brp` | 6 |
| `compiler/stage_06_typecheck/foreign_validation.brp` | 6 |
| `compiler/stage_03_parse/language_parser.brp` | 6 |
| `compiler/stage_10_backend/emit.brp` | 5 |
| `purify/command.brp` | 4 |
| `lsp/protocol/position.brp` | 4 |
| `compiler/stage_07_ctfe/pattern.brp` | 4 |
| `compiler/stage_06_typecheck/headers/type_parameter_headers.brp` | 4 |
| `compiler/stage_06_typecheck/headers/type_header_dependencies.brp` | 4 |
| `compiler/stage_04_modules/module_type_identity.brp` | 4 |
| `compiler/stage_07_ctfe/globals.brp` | 3 |
| `compiler/stage_07_ctfe/eval.brp` | 3 |
| `compiler/stage_06_typecheck/typed_name_identity.brp` | 3 |
| `lsp/analysis/analysis_model.brp` | 2 |
| `lib/source_graph.brp` | 2 |
| `format/engine/document_layout.brp` | 2 |
| `compiler/stage_08_core_lower/graph_prepare.brp` | 2 |
| `compiler/stage_06_typecheck/typed_ast_json.brp` | 2 |
| `compiler/stage_06_typecheck/headers/type_parameter_discovery.brp` | 2 |
| `compiler/stage_06_typecheck/headers/callable_signature.brp` | 2 |
| `test/command.brp` | 1 |
| `lsp/workspace/source_loader.brp` | 1 |
| `lsp/workspace/document_store.brp` | 1 |
| `lsp/analysis/frontend_graph.brp` | 1 |
| `lsp/analysis/diagnostic.brp` | 1 |
| `lib/cli_plan.brp` | 1 |
| `format/command.brp` | 1 |
| `compiler/stage_07_ctfe/context.brp` | 1 |
| `compiler/stage_06_typecheck/inventory.brp` | 1 |
| `compiler/stage_06_typecheck/graph/indexed_graph.brp` | 1 |
| `compiler/stage_06_typecheck/frontend_graph_typecheck.brp` | 1 |
| `compiler/stage_03_parse/parsed_ast.brp` | 1 |
| `compiler/stage_02_lex/token.brp` | 1 |
| `compiler/stage_02_lex/name_table.brp` | 1 |
| `compiler/pipeline.brp` | 1 |
