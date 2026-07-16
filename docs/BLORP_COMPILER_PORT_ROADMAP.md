# Blorp Compiler Port Roadmap

Status checked against code on 2026-07-12.

This is the implementation roadmap for finishing the OCaml-to-Blorp compiler
migration. The plan moves from the left side of the production pipeline to the
right side: command/source frontier, parse/source model, module graph,
typechecking, typed AST, Core lowering, Core passes, ownership/backend, and
finally the remaining command/tool shell.

The goal of this document is mechanical execution. Each checkpoint names the
OCaml implementation to study, the Blorp implementation to extend, the edge
cases that must be preserved, the tests that should move or be added, and the
point where OCaml code can be deleted.

## Current Production Path

The current production `check`, `compile`, and `run` path already starts in
the Blorp executable and ends in Blorp, with an OCaml middle:

```text
Blorp executable / CLI planning / source graph discovery / source reads / parse
  -> JSON frontend module graph and Blorp typed-program/CTFE bridge
  -> OCaml host command execution / module-cache and coherence orchestration /
     typed-artifact decode
  -> decoded Blorp typed AST with CTFE evaluated -> OCaml Core lowering
  -> OCaml Core pipeline through specialization and function-reference adaptation
  -> JSON pre-DCE Core
  -> Blorp DCE / consume specialization / Perceus / reuse / closure / resource /
     fairness / prepare / prepared reuse
  -> Blorp C artifact emission
  -> OCaml artifact writing / C compiler invocation
```

Current source-frontier Blorp files:

- `compiler/blorp/src/stage_12_cli/compiler_cli_main.brp`
- `compiler/blorp/src/stage_12_cli/compiler_cli.brp`
- `compiler/blorp/src/stage_12_cli/compiler_cli_args.brp`
- `compiler/blorp/src/stage_12_cli/compiler_cli_plan.brp`
- `compiler/blorp/src/stage_12_cli/compiler_cli_source_graph.brp`
- `compiler/blorp/src/stage_12_cli/compiler_cli_artifact_json.brp`
- `compiler/blorp/src/stage_01_file_io/compiler_source.brp`
- `compiler/blorp/src/stage_02_lex/compiler_lexer.brp`
- `compiler/blorp/src/stage_03_parse/compiler_parser.brp`
- `compiler/blorp/src/stage_03_parse/compiler_parsed_ast.brp`
- `compiler/blorp/src/stage_03_parse/compiler_parsed_ast_json.brp`
- `compiler/blorp/src/stage_03_parse/compiler_source_ast_finalize.brp`
- `compiler/blorp/src/stage_04_modules/compiler_module_surface.brp`
- `compiler/blorp/src/stage_04_modules/compiler_module_surface_json.brp`

Primary typed-frontend and CTFE Blorp files used by normal source commands:

- `compiler/blorp/src/stage_05_types/compiler_env.brp`
- `compiler/blorp/src/stage_05_types/compiler_type.brp`
- `compiler/blorp/src/stage_05_types/compiler_type_metadata.brp`
- `compiler/blorp/src/stage_06_typecheck/compiler_imports.brp`
- `compiler/blorp/src/stage_06_typecheck/compiler_infer.brp`
- `compiler/blorp/src/stage_06_typecheck/compiler_typecheck_bridge.brp`
- `compiler/blorp/src/stage_06_typecheck/compiler_typecheck_decl.brp`
- `compiler/blorp/src/stage_06_typecheck/compiler_typecheck_state.brp`
- `compiler/blorp/src/stage_06_typecheck/compiler_typed_ast_json.brp`
- `compiler/blorp/src/stage_07_ctfe/compiler_ctfe_context.brp`
- `compiler/blorp/src/stage_07_ctfe/compiler_ctfe_eval.brp`
- `compiler/blorp/src/stage_07_ctfe/compiler_ctfe_globals.brp`
- `compiler/blorp/src/stage_07_ctfe/compiler_ctfe_ir.brp`
- `compiler/blorp/src/stage_07_ctfe/compiler_ctfe_materialize.brp`

Current production backend-tail Blorp files:

- `compiler/blorp/src/stage_09_core/compiler_core_json.brp`
- `compiler/blorp/src/stage_09_core/compiler_core_pipeline.brp`
- `compiler/blorp/src/stage_09_core/compiler_core_dce.brp`
- `compiler/blorp/src/stage_09_core/compiler_core_consume_specialize.brp`
- `compiler/blorp/src/stage_09_core/compiler_core_ownership.brp`
- `compiler/blorp/src/stage_09_core/compiler_core_perceus.brp`
- `compiler/blorp/src/stage_09_core/compiler_core_reuse.brp`
- `compiler/blorp/src/stage_09_core/compiler_core_closure.brp`
- `compiler/blorp/src/stage_09_core/compiler_core_resource.brp`
- `compiler/blorp/src/stage_09_core/compiler_core_fairness.brp`
- `compiler/blorp/src/stage_09_core/compiler_core_prepare.brp`
- `compiler/blorp/src/stage_10_backend/compiler_core_emit.brp`

Current OCaml bridge, orchestration, and production-middle files:

- `compiler/bin/blorp_ocaml_host.ml`
- `compiler/lib/compiler_blorp_bridge.ml`
- `compiler/lib/modules.ml`
- `compiler/lib/pipeline.ml`
- `compiler/lib/typecheck.ml`
- `compiler/lib/infer.ml`
- `compiler/lib/typed_ast.ml`
- `compiler/lib/core_lower.ml`
- `compiler/lib/core_pipeline.ml`
- `compiler/lib/core_ownership.ml`
- `compiler/lib/core_emit_blorp_c.ml`

`compiler/lib/core_pipeline.ml` still invokes the OCaml implementations of
Core lowering and the early/middle Core passes through specialization and
function-reference adaptation. The production JSON handoff to Blorp is exactly
before DCE. Blorp is authoritative for DCE, consume specialization, Perceus,
and the complete backend tail; the replaced OCaml implementations and their
implementation-only tests have been deleted.

The public executable is Blorp-owned through
`compiler/blorp/src/stage_12_cli/compiler_cli_main.brp`. `compiler/bin/blorp_ocaml_host.ml` is a
private execution shell for decoded Blorp plans, temporary typed-program
handoffs, artifact writing, host C invocation, and still-OCaml compiler stages.

## Migration Rules

1. Move one contiguous boundary at a time. Do not create new permanent islands.
2. Port direct behavior first. Keep the OCaml function split unless changing the
   type shape makes an illegal state unrepresentable without changing behavior.
3. Add or port tests before deletion. End-to-end tests are not enough for
   deleting an OCaml implementation.
4. Keep JSON at the boundary only. Inside Blorp, use typed records, enums, and
   unions.
5. Preserve phase boundaries. Parser work stays in parser/source-finalization,
   type work stays in typecheck/infer, Core work stays in Core passes.
6. Delete replaced OCaml in the same slice once the Blorp path is authoritative.
7. Keep compatibility shims only for pinned bootstrap requirements, and name the
   deletion condition in the code or this roadmap.

For every checkpoint, use this workflow:

1. Read the listed OCaml files and tests.
2. Add focused Blorp tests that fail against the missing Blorp behavior.
3. Port the data types and helper functions.
4. Add a parity path while OCaml still exists.
5. Route production through Blorp.
6. Delete the replaced OCaml implementation and OCaml-only tests.
7. Run the checkpoint validation commands and update this roadmap if the
   boundary changed.

## Checkpoint 0: Boundary Inventory And Cleanup

Goal: make every remaining OCaml-to-Blorp call explicit and prevent new bridge
side channels while the boundary moves.

OCaml references still needed at this checkpoint:

- `compiler/lib/compiler_blorp_bridge.ml`
- `compiler/lib/core_emit_blorp_c.ml`
- `compiler/bin/blorp_ocaml_host.ml`
- `compiler/lib/modules.ml`
- `compiler/lib/core_pipeline.ml`
- `compiler/lib/language_surface.ml`
- `compiler/lib/core_trait_resolve.ml`

Blorp references:

- `compiler/blorp/src/stage_12_cli/compiler_bridge.brp`
- `compiler/blorp/src/stage_12_cli/compiler_bridge_protocol.brp`
- `compiler/blorp/src/stage_12_cli/compiler_bridge_cli.brp`
- `compiler/blorp/src/stage_99_meta/ocaml_port_inventory.tsv`

Implementation steps:

- Maintain an allowlist of OCaml files that may call
  `Compiler_blorp_bridge`. Classify each call as production boundary,
  command perimeter, bootstrap exception, observability exception, or
  transitional table/diagnostic exception.
- Keep bridge request/response handling in `compiler_blorp_bridge.ml`.
  Compiler semantics should live on one side of the boundary, not in the
  bridge client.
- Keep `emit_core_c` and `run_core_pipeline` as the backend-tail
  boundary while OCaml still owns earlier Core stages.
- Keep the bridge `parse_source` / `parse_sources` actions as the frontend
  parser boundary while OCaml still consumes parsed AST values. OCaml raw
  parser consumers should go through `Modules.parse_raw_source*` so raw output
  is explicit at call sites.
- Prepared backend/list/tensor codegen renderers are typed-only. Call sites use
  `render_prepared_*_op` over explicit operation variants; do not reintroduce
  name/arity template registries or snippet-style adapters for those surfaces.
- Keep `BLORP_COMPILER_RENDERER_HELPER=1` limited to static bootstrap table,
  manifest, and diagnostic rendering support while those temporary callers
  remain.

Edge cases:

- Pinned bootstrap binaries may still require old bridge action names. Keep
  those shims only with a named bootstrap version/deletion condition.
- `--dump-core-after`, `--stop-after`, `--time-phases`, and
  `--check-invariants` must not force a duplicate OCaml backend tail.
- Bridge diagnostics must remain structured. Unsupported Core or parser shapes
  should return explicit errors, not partial output.

Tests:

- `compiler/test/test_compiler_blorp_bridge.ml`
- `compiler/blorp/tests/test_compiler_bridge.brp`
- `compiler/blorp/tests/test_compiler_bridge_protocol.brp`
- `compiler/test/test_core_observability.ml`

Validation:

```bash
rg "Compiler_blorp_bridge\\." compiler/bin compiler/lib -g '*.ml'
dune exec --profile=dev --root compiler -- ./test/run_tests.exe test CompilerBlorpBridge
git diff --check
```

Deletion point:

- Delete a bridge action when it has no allowlisted caller and no pinned
  bootstrap requirement.

## Checkpoint 1: Command Frontier For Source Commands

Goal: make `check`, `compile`, and `run` source command planning entirely
Blorp-owned up to the frontend module graph handed to the OCaml middle.

Status: closed for normal source commands. The OCaml shell validates and
executes a decoded `frontend_module_graph` for `check`, `compile`, and `run`;
it no longer rediscovers roots, rereads sources, reparses roots, or rebuilds
source-package context for those commands. The legacy `frontend_options`
artifact is rejected as an unsupported legacy artifact rather than decoded for
source execution.

OCaml references:

- `compiler/bin/blorp_ocaml_host.ml`
  - `apply_blorp_cli_frontier`
  - `cli_frontier_frontend_module_graph`
  - `finalize_cli_frontend_graph_source`
  - `finalized_cli_frontend_graph_sources_or_exit`
  - `apply_cli_frontend_graph_context`
  - `run_check_from_frontier_options`
  - `run_compile_from_frontier_options`
  - `run_file_from_frontier_options`
  - `compile_opts_of_cli_check`
  - `compile_opts_of_cli_compile`
  - `check_file_with_opts`
  - `compile_file_with_opts`
  - `run_file`
- `compiler/lib/pipeline.ml`
  - `typecheck_only_typed_with_blorp_bridge_policy`
  - `compile_preloaded_graph_with_blorp_bridge`
  - `compile_loaded_program`

Blorp references:

- `compiler/blorp/src/stage_12_cli/compiler_cli.brp`
- `compiler/blorp/src/stage_12_cli/compiler_cli_args.brp`
- `compiler/blorp/src/stage_12_cli/compiler_cli_plan.brp`
- `compiler/blorp/src/stage_12_cli/compiler_cli_source_graph.brp`
- `compiler/blorp/src/stage_12_cli/compiler_cli_artifact_json.brp`

Implementation steps:

- Keep CLI argument parsing in `compiler_cli_args.brp`; OCaml should not parse
  source-command flags except for hidden bridge/bootstrap commands.
- Keep root expansion, file reads, auto-format decisions, source graph
  discovery, package context discovery, and batch parse requests in
  `compiler_cli_source_graph.brp`.
- Ensure the Blorp graph carries:
  - roots and dependency modules,
  - source text,
  - module names,
  - module origins,
  - import edges,
  - std override,
  - source package aliases,
  - local `pkg/` roots,
  - parsed response at the requested AST phase.
- Make OCaml `apply_cli_frontend_graph_context` only apply already-discovered
  graph context to the current session. It should not perform independent
  filesystem discovery for normal source commands.
- Make `run_check_from_frontier_options`, `run_compile_from_frontier_options`,
  and `run_file_from_frontier_options` call the parsed/graph pipeline entry
  points only.
- Do not reintroduce `frontend_options` execution for source commands. Treat it
  as an unsupported legacy artifact at the bridge decoder boundary.

Edge cases:

- `--std-dir`, `BLORP_STD`, and `blorp.toml` std overrides must resolve to one
  graph context.
- `--no-format` and `BLORP_NO_FORMAT` must prevent source modification before
  parsing.
- `compile --ast`, `--dump-ast`, `--dump-typed-ast`, `--dump-core-after`,
  `--dump-core-file`, `--stop-after`, `--time-phases`, and
  `--check-invariants` must preserve current stdout/stderr behavior.
- `run` must preserve `--profile`, `--debug`, `--release`, sanitizer,
  leak-check, timeout, thread, and user-argument handling.
- Directory roots, empty roots, unreadable files, duplicate roots, and invalid
  parse responses need deterministic diagnostics.
- Source-package imports and local `pkg/...` imports must not be resolved by
  the same rule.

Tests:

- `compiler/blorp/tests/test_compiler_cli_args.brp`
- `compiler/blorp/tests/test_compiler_cli.brp`
- `compiler/test/test_compiler_blorp_bridge.ml`
- `tests/test_compiler/parser/*`
- `scripts/test cli`

Closed deletion point:

- OCaml root expansion, source reads, and parser fallback code for normal
  `check`, `compile`, and `run` have been deleted from the shell path. The
  remaining source-command shell code assumes a Blorp-produced graph before it
  enters `Pipeline.typecheck_only_typed_with_blorp_bridge_policy` or
  `Pipeline.compile_preloaded_graph_with_blorp_bridge`. The test-only
  `Pipeline.compile_parsed` compatibility API and its path-specific tests have
  been deleted, along with the redundant default-policy typecheck wrapper.

## Checkpoint 2: Source Model, Parser, And Source-AST Finalization

Goal: make the Blorp parsed/source AST the only source model for compiler
stages, formatting, and later tooling.

Status: parser ownership is mostly Blorp-owned. The remaining work is to keep
all parser consumers on the same Blorp source model and delete OCaml decoders or
adapters when the OCaml middle no longer needs them.

OCaml references:

- `compiler/lib/parsed_ast_json.ml`
  - `decode_program`
  - `decode_decl_group`
  - `decode_expr`
  - `decode_type_expr`
  - `decode_pattern`
  - `decode_import_decl`
  - `decode_foreign_block_decl`
  - `decode_parse_diagnostics`
- `compiler/lib/module_surface.ml`
  - `validate_against_program`
  - `exports_as_ast_pairs`
  - `private_names_as_ast_pairs`
- `compiler/lib/modules.ml`
  - `parse_source_artifact_with_blorp_bridge`
  - `parse_source_artifact_at_phase`
  - `parse_raw_source_artifact`
  - `parse_typecheck_source_artifact`
  - `parse_source_at_phase`
  - `parse_raw_source`
  - `parse_typecheck_source`

Blorp references:

- `compiler/blorp/src/stage_02_lex/compiler_token.brp`
- `compiler/blorp/src/stage_02_lex/compiler_lexer.brp`
- `compiler/blorp/src/stage_03_parse/compiler_parser.brp`
- `compiler/blorp/src/stage_03_parse/compiler_parsed_ast.brp`
- `compiler/blorp/src/stage_03_parse/compiler_parsed_ast_json.brp`
- `compiler/blorp/src/stage_02_lex/compiler_parse_diagnostic.brp`
- `compiler/blorp/src/stage_03_parse/compiler_source_ast_finalize.brp`
- `compiler/blorp/src/stage_04_modules/compiler_module_surface.brp`
- `compiler/blorp/src/stage_04_modules/compiler_module_surface_json.brp`
- `compiler/blorp/src/stage_11_format/compiler_format.brp`
- `compiler/blorp/src/stage_11_format/compiler_format_projection.brp`

Implementation steps:

- Keep two explicit parser phases:
  - raw parse for formatting/LSP/source-preserving tools,
  - `typecheck_source` for compile/check/run.
- Keep interpolation splitting, interpolation hole parsing, nested function
  hoisting, and subscript-read lowering in
  `compiler_source_ast_finalize.brp`.
- Keep subscript assignment in inference until it can be checked with
  mutability and type context.
- Preserve comments, docstrings, spans, raw strings, pipe strings, multiline
  strings, and source file names in the Blorp source model.
- Keep private wrappers explicit in the AST. Do not recover privacy from names
  or source order.
- Keep module surface generation in Blorp and validation strict at the OCaml
  boundary while OCaml still consumes the AST.
- Make formatter, LSP, and parser fixtures consume the same Blorp AST model
  instead of maintaining separate parser behavior.

Edge cases:

- Indentation, lambda-body newline behavior, grouping tokens, docstring
  attachment, comments around imports, and raw interpolation payloads.
- Current syntax only. Removed syntaxes should fail normally unless a targeted
  diagnostic improves first-time user experience.
- `typecheck_source` must reject or finalize all source-only nodes that Core
  lowering says should not survive: `EStringInterpRaw`, nested `EFuncDecl`,
  `ESubscript`, and `ESubscriptMulti`.
- `ESubscriptAssign` must remain typechecked in inference.
- Module surface symbol sources must point back to the exact declaration or
  method index they describe.

Tests:

- `compiler/blorp/tests/test_compiler_lexer.brp`
- `compiler/blorp/tests/test_compiler_parser.brp`
- `compiler/blorp/tests/test_compiler_parsed_ast.brp`
- `compiler/blorp/tests/test_compiler_source_ast_finalize.brp`
- `compiler/blorp/tests/test_compiler_module_surface.brp`
- `compiler/test/test_parsed_ast_json.ml` while OCaml decoding remains
- `tests/test_compiler/parser/should_pass`
- `tests/test_compiler/parser/should_fail`
- `tests/test_compiler/format`

Deletion point:

- Delete `parsed_ast_json.ml` and OCaml module-surface validation once no OCaml
  stage consumes parsed AST JSON.

## Checkpoint 3: Module Graph, Import Resolution, And Package Context

Goal: move authoritative module loading and import policy into Blorp over the
already-read frontend module graph.

Status: closed for the production `check`, `compile`, and `run` source-command
path. Blorp discovers roots, reads sources, resolves imports, parses the full
reachable source graph, and sends a `frontend_module_graph` artifact. The OCaml
middle now consumes that graph through `Modules.load_preloaded_module_graph`
instead of rediscovering graph-provided modules or rereading their files.
Graph-resolved modules are cached under both the canonical resolved module name
and the original import spelling so existing import/typecheck code sees the same
module identities that `load_module` used to provide.

Remaining compatibility: `Modules.load_imports` still owns import loading for
non-graph callers, LSP/tooling paths that have not been ported to the
source-command graph contract, and embedded std/bootstrap support. Its internal
import-closure preloader still batches source parsing through the Blorp parser
bridge, but it is no longer a separate CLI source handoff. This is a deletion
target for later checkpoints, not part of the production source-command
handoff.

OCaml references:

- `compiler/lib/modules.ml`
  - path/context helpers:
    - `canonical_dir`
    - `canonical_file`
    - `is_path_under_dir`
    - `relative_path_under_dir`
    - `module_name_for_source_file`
    - `module_origin_for_source_file`
    - `bridge_module_name_for_path`
  - package helpers:
    - `add_package_root`
    - `add_source_package`
    - `source_package_for_path`
    - `source_package_module_name_for_source_file`
    - `resolve_source_package_internal_import`
    - `resolve_source_package_alias`
    - `source_package_alias_load_error`
  - resolution/loading:
    - `resolve_module_file`
    - `resolve_non_source_package_module`
    - `load_module`
    - `load_module_inner`
    - `parse_module_source`
    - `load_imports`
    - `load_preloaded_module_graph`
    - `preload_module_import_closure`
    - `preload_module_parse_cache_with_blorp_bridge`
    - `import_preload_candidates`
  - caches:
    - `cache_parsed_module_source`
    - `cached_parse_entry`
    - `cached_filesystem_entry_is_current`
    - `prune_parse_cache_to_loaded_modules`
  - legacy syntactic fallback helpers:
    - `collect_syntactic_exports_from_ast_for_fallback`
    - `collect_private_names_from_ast_for_fallback`
    - `import_module_names_from_ast_for_fallback`
- `compiler/lib/session.ml`
  - `loaded_module`
  - `parsed_module_cache_entry`
  - `source_package`
  - `module_origin`
  - `module_cache`
  - `parse_cache`
  - `type_index`
  - `trait_index`

Blorp references:

- `compiler/blorp/src/stage_12_cli/compiler_cli_source_graph.brp`
- `compiler/blorp/src/stage_04_modules/compiler_module_surface.brp`
- future `compiler_module_graph.brp`
- future `compiler_module_resolution.brp`

Implementation steps:

- Introduce Blorp data for `ModuleOrigin`, `SourcePackage`, `ModuleGraphSource`,
  `ImportEdge`, `ResolvedModule`, and `ModuleGraph`.
- Split impure source discovery from pure graph validation:
  - discovery already happens in `compiler_cli_source_graph.brp`,
  - validation should run over graph data without reading files.
- Port resolution policy mechanically from `resolve_module_file` and
  `resolve_non_source_package_module`:
  - `std/...`,
  - source-package internal imports,
  - source-package alias exports,
  - local `pkg/...` native package imports,
  - `./...`,
  - `../...`,
  - bare local imports outside source packages.
- Port cycle detection, duplicate module detection, unresolved import
  diagnostics, and loaded-module ordering.
- Replace OCaml parse-cache preload policy with graph validation over sources
  already supplied by Blorp.
- Keep typed-module cache data separate from parsed-module graph data. Parsed
  modules are source facts; typed modules belong to the typecheck checkpoint.
- Make module syntactic exports/private names come only from Blorp module
  surface data.
- Preserve eager std support-module behavior only if still required by
  typecheck. Otherwise remove it when Blorp typecheck handles prelude/builtins
  directly.

Edge cases:

- Embedded std paths (`<embedded:std/...>`) versus filesystem std override.
- Source-package modules must not import arbitrary files outside their package
  source directory via `./` or `../`.
- Bare imports must not consult `pkg/` roots.
- Package aliases must respect the package's exported module list.
- Duplicate public type names across modules must be represented as ambiguous,
  not silently overwritten.
- Import diagnostics should preserve current help text where useful:
  unresolved module, package export missing, private import, and non-exported
  symbol.
- Caches must not trust stale filesystem source by hash.

Tests:

- `compiler/test/test_module_surface.ml`
- `compiler/test/test_module_type_identity.ml`
- `compiler/test/test_pipeline.ml`
- `compiler/test/test_package_config.ml`
- `compiler/test/test_package_check.ml`
- `compiler/test/test_package_cache.ml`
- `tests/test_compiler/typecheck/should_pass/pkg*.brp`
- `tests/test_compiler/typecheck/should_fail/visibility_*.brp`
- New Blorp tests under `compiler/blorp/tests/test_compiler_module_graph.brp`.

Deletion point:

- Delete OCaml module path resolution/loading/cache code after
  `Pipeline.compile_preloaded_graph_with_blorp_bridge` and
  `Pipeline.typecheck_only_typed_with_blorp_bridge_policy` consume a Blorp-validated
  module graph for every production/tooling caller and no longer need
  `Modules.load_imports` for non-graph entry points.

## Checkpoint 4: Diagnostics, Session, Types, Env, And Builtins

Goal: port the pure substrate needed by typecheck before moving declaration or
expression inference.

Status: complete for the pure frontend substrate. Production typecheck and
inference still switch over in later checkpoints, but the checkpoint-4 data
models and helper APIs now exist in Blorp with focused tests.
`compiler/blorp/src/stage_05_types/language_surface_manifest.brp` remains the source of truth for
source-language keyword and prelude UFCS tables, while Dune generates
`Language_surface_data` for OCaml consumers at build time. This removes the
runtime bridge call from `compiler/lib/language_surface.ml` and keeps the
renderer-helper bootstrap rows on the same generated data.
`compiler/blorp/src/stage_01_file_io/compiler_diagnostic.brp`
defines pure Rust-style diagnostic data and rendering over explicit source text,
with parity tests for tab padding, synthetic locations, notes/help, and
secondary labels. The semantic type slice is in place:
`compiler/blorp/src/stage_05_types/compiler_type.brp` defines the Blorp `CompilerType` model plus
pure display, structural equality, tensor-name normalization, array/tensor
decomposition, numeric predicates, dimension-form predicates, type-parameter
bound stripping, occurs checks, cycle-safe substitution, and dimension
arithmetic normalization. It also carries the first Blorp-owned array/tensor
dimension validator, including non-positive concrete dimension checks,
dimension-argument validation, and variadic-dimension placement rules. It
also has the first explicit Blorp context model in
`compiler/blorp/src/stage_05_types/compiler_context.brp`, covering module-origin policy, type-home
ambiguity, resource cleanup entries, trait-home conflict reporting, definition
ids, meta origins/bindings, head resolution, zonking, and Core lowering
counters as ordinary values. The context model now also owns the baseline
unifier: meta binding with occurs checks, one-way and symmetric type-variable
binding, explicit type-parameter binding, rigid variables, function purity,
tuple/array/tensor matching, range/Int compatibility, LiteralString/String
compatibility, and dimension arithmetic through the canonical solver in
`compiler/blorp/src/stage_05_types/compiler_dim_solver.brp`. That solver ports the
sum-of-products normalization from `compiler/lib/dim_solver.ml`, including
commutativity/associativity/distributivity, exact constant division,
contradictions, and simple meta or `#` dimension-variable bindings. It
also now includes `compiler/blorp/src/stage_05_types/compiler_type_widening.brp`, which ports the
explicit value-slot widening decisions from `compiler/lib/type_widening.ml` for
mutable bindings, arguments, collection elements, bitwise operands, method
receivers, and numeric operands. The pure
range/subscript proof substrate is also now covered by
`compiler/blorp/src/stage_05_types/compiler_refinement.brp`, which ports collection/dimension
identities, range upper bounds, subscript bounds, offset checks, proof sources,
binding/expr proof payloads, proof-env replacement, and branch narrowing. The
first module-loading identity helper is also in place:
`compiler/blorp/src/stage_04_modules/compiler_module_type_identity.brp` ports local type-name
collection from parsed declarations, including private-wrapper transparency and
sorted unique output for records, unions/enums, and type aliases. Structured
generic-parameter helpers are now also ported in
`compiler/blorp/src/stage_05_types/compiler_generic_params.brp`, covering trait refs, bounded type
params, parser-source spelling, and param-name extraction. The first
type-policy metadata slice is also available in
`compiler/blorp/src/stage_05_types/compiler_type_metadata.brp`, covering recursion storage,
primitive homes, struct scalar fields, native operator fast paths, builtin
to-string fallbacks, and constructor-space classification. The remaining
checkpoint-4 pieces are also now present: `compiler/blorp/src/stage_05_types/compiler_env.brp`
ports the lexical environment, symbols, aliases, type/record/constructor lookup,
trait functions, trait defs, impls, overloads, UFCS methods, resource policies,
proof metadata attachment points, and alias/nominal-dimension resolution;
`compiler/blorp/src/stage_05_types/compiler_builtins.brp` ports compiler-visible builtin metadata
and core Env population; and `compiler/blorp/src/stage_05_types/compiler_type_resolution.brp`
ports the named annotation-resolution entrypoints over module aliases, owner
qualification, nominal dimension disambiguation, and alias policy.

OCaml references:

- `compiler/lib/diagnostics.ml`
  - `diagnostic_of_error`
  - `render_diagnostic`
  - `format_error`
  - `format_errors`
- `compiler/lib/session.ml`
  - `create`
  - `with_current`
  - `reset_meta`
  - `mint_def_id`
  - module/type/trait/resource indexes
  - Core-lowering fresh counters
- `compiler/lib/types.ml`
  - `fresh_meta`
  - `lookup_meta`
  - `bind_meta`
  - `head_resolve`
  - `zonk_type`
  - `type_to_string`
  - `types_equal`
  - `apply_subst`
  - `unify`
  - `types_compatible`
  - `types_bidirectional`
  - `validate_array_dims`
  - `qualify_module_local_types`
  - `resolve_qualified_types`
  - `Types.Dim`
- `compiler/lib/dim_solver.ml`
- `compiler/lib/type_resolution.ml`
- `compiler/lib/type_widening.ml`
- `compiler/lib/refinement.ml`
- `compiler/lib/type_proof_metadata.ml`
- `compiler/lib/env_types.ml`
- `compiler/lib/env.ml`
- `compiler/lib/env_builtins.ml`
- `compiler/lib/builtin_metadata.ml`
- `compiler/lib/generic_params.ml`
- `compiler/lib/language_surface.ml`
- `compiler/lib/module_type_identity.ml`

Blorp references:

- `compiler/blorp/src/stage_05_types/language_surface_manifest.brp`
- `compiler/blorp/src/stage_05_types/compiler_type.brp`
- `compiler/blorp/src/stage_05_types/compiler_context.brp`
- `compiler/blorp/src/stage_05_types/compiler_dim_solver.brp`
- `compiler/blorp/src/stage_05_types/compiler_type_widening.brp`
- `compiler/blorp/src/stage_05_types/compiler_refinement.brp`
- `compiler/blorp/src/stage_04_modules/compiler_module_type_identity.brp`
- `compiler/blorp/src/stage_05_types/compiler_generic_params.brp`
- `compiler/blorp/src/stage_05_types/compiler_type_metadata.brp`
- `compiler/blorp/src/stage_05_types/compiler_env.brp`
- `compiler/blorp/src/stage_05_types/compiler_builtins.brp`
- `compiler/blorp/src/stage_05_types/compiler_type_resolution.brp`
- `compiler/blorp/src/stage_01_file_io/compiler_diagnostic.brp`

Implementation steps:

- Model a Blorp `CompilerContext` explicitly. It should replace ambient OCaml
  session coupling for:
  - type homes, trait homes, resource cleanup metadata, definition ids, meta
    ids, meta bindings, head resolution, zonking, and fresh lowering counters
    are covered by the baseline `compiler_context.brp` value,
  - baseline unification and type compatibility predicates are covered by the
    same context value,
  - module cache, parse cache, impl indexes, UFCS method indexes, and
    production pipeline integration remain to be modeled when the env/typecheck
    slices need them.
- Port semantic type representation and utilities over the Blorp parsed type
  model first:
  - type pretty-printing,
  - structural equality,
  - canonical module type names,
  - substitution,
  - baseline array/tensor dimension validation,
  - metavariables and zonking,
  - baseline unification and type compatibility,
  - type parameter syntax validation,
  - richer dimension solving is now covered by `compiler_dim_solver.brp`,
  - named primitive helpers.
- Port `dim_solver.ml` as a pure solver over canonical dimension expressions.
  This is implemented in `compiler_dim_solver.brp`; remaining work is to keep
  the production inference path on the Blorp context as later typecheck slices
  come online.
- Port `type_resolution.ml` use cases as named functions rather than boolean
  flags: value ascription, local binding annotation, function parameter,
  function return, record field, type alias target. This is implemented in
  `compiler_type_resolution.brp`; remaining work is production wiring once the
  declaration/typecheck slices move to Blorp.
- Port `type_widening.ml` before expression inference so source type,
  semantic type, and value-slot type remain explicit. This is implemented in
  `compiler_type_widening.brp`; remaining work is to thread value slots through
  Blorp-owned inference when that phase ports.
- Port `refinement.ml` and proof metadata before subscript/range inference.
  This is implemented in `compiler_refinement.brp`; remaining work is to attach
  these payloads to Blorp-owned inferred expressions and Env bindings when
  inference ports.
- Port tiny module identity helpers that do not require Env before larger module
  loading slices. `compiler_module_type_identity.brp` now covers
  `Module_type_identity.local_type_names_from_decls`; production module loading
  integration remains with the later Env/module-cache slice.
- Port generic-parameter helpers before Env. This is implemented in
  `compiler_generic_params.brp`; remaining work is to thread
  `CompilerBoundTypeParam` through Blorp-owned Env and typecheck signatures
  rather than carrying bounded params as decorated strings.
- Port type-policy metadata before typecheck/Core handoff decisions depend on
  it. This is implemented in `compiler_type_metadata.brp`; remaining work is to
  switch Blorp-owned typecheck/Core-resolution slices to query it instead of
  duplicating name checks.
- Port `Env` as an explicit value with lexical scopes and context-backed
  indexes. Do not hide context mutation behind global state. This is
  implemented in `compiler_env.brp` as a pure value model with scoped symbols,
  aliases, traits, impls, overloads, UFCS methods, and proof metadata slots.
- Port builtins from `Env_builtins`, `Builtin_metadata`, and
  `Generic_params`. Builtins carry purity, origin, resource policies, trait
  bounds, loop-producer metadata, and callable ids. They are not only docs.
  This is implemented in `compiler_builtins.brp` for the core builtin substrate.
- Replace the runtime `language_surface.ml` bridge facade with Blorp-owned data
  consumed directly by Blorp typecheck and, temporarily, by generated static
  OCaml data for remaining LSP users if needed.

Edge cases:

- Meta variables are per inference body, not process-global.
- Type/trait/impl indexes are per compilation context and shared across loaded
  modules in that compilation.
- Lexical overloads are env-local; impl and UFCS indexes are context-level.
- `Types.normalize_type_name` still maps legacy `Vector`/`Matrix` names to
  `Tensor`. Delete only after old nominal paths are proven gone or modeled
  explicitly.
- Module-local type names need owner qualification across module boundaries.
- Dimension variables (`#N`), dimension wildcards, negative dimensions, and
  variadic dims must preserve current validation behavior.
- Resource/source/stream capability types must remain explicit enough for
  later inference checks.

Tests:

- `compiler/test/test_types.ml`
- `compiler/test/test_dim_solver.ml`
- `compiler/test/test_type_resolution.ml`
- `compiler/test/test_type_widening.ml`
- `compiler/test/test_refinement.ml`
- `compiler/test/test_env.ml`
- `compiler/test/test_builtin_consistency.ml`
- `compiler/test/test_generic_params.ml`
- `compiler/blorp/tests/test_language_surface_manifest.brp`
- `compiler/blorp/tests/test_compiler_diagnostic.brp`
- `compiler/blorp/tests/test_compiler_type.brp`
- `compiler/blorp/tests/test_compiler_dim_solver.brp`
- `compiler/blorp/tests/test_compiler_context.brp`
- `compiler/blorp/tests/test_compiler_type_widening.brp`
- `compiler/blorp/tests/test_compiler_refinement.brp`
- `compiler/blorp/tests/test_compiler_module_type_identity.brp`
- `compiler/blorp/tests/test_compiler_generic_params.brp`
- `compiler/blorp/tests/test_compiler_type_metadata.brp`
- `compiler/blorp/tests/test_compiler_env.brp`
- `compiler/blorp/tests/test_compiler_builtins.brp`
- `compiler/blorp/tests/test_compiler_type_resolution.brp`

Deletion point:

- Delete each OCaml utility module only when all production callers use the
  Blorp equivalent or the module has become a narrow bridge decoder. Do not
  delete `types.ml` or `env.ml` wholesale until `typecheck.ml`, `infer.ml`,
  `typed_ast.ml`, and `core_lower.ml` no longer consume OCaml type/env values.

## Checkpoint 5: Declaration Indexing And Typecheck First Pass

Goal: port declaration-boundary checks and environment construction before
expression inference.

Status: complete for the Blorp-owned first-pass/indexing scope. The explicit
Blorp typecheck state substrate is in place in
`compiler/blorp/src/stage_06_typecheck/compiler_typecheck_state.brp`, with focused tests for
module-origin policy, import binding deduplication, module-alias/selective
import namespace collisions, known type/resource pre-scan state, type-home
precedence, callable ids, private impl tracking, type-home matching, and private
impl conflict lookup. The top-level pre-scan is also in place in
`compiler/blorp/src/stage_06_typecheck/compiler_typecheck_decl.brp`, covering known type/resource
names, constructor names, function/variable/trait namespace entries,
foreign-block functions, and private wrappers. Pure import registration is in
place in `compiler/blorp/src/stage_06_typecheck/compiler_imports.brp`, covering qualified aliases,
selective and renamed imports, private/missing symbol diagnostics, duplicate
local-name diagnostics, import bindings, and imported type homes over Blorp
module surfaces. Source type-expression projection is in place in
`compiler/blorp/src/stage_06_typecheck/compiler_typecheck_types.brp`. Semantic
declaration-registration slices are in place for local union/enum,
builtin/resource type, record/struct, type-alias, global variable, source
function, foreign function, trait, and source impl declarations. These slices
populate Env type/record/alias/constructor/function/variable/trait/impl facts,
record and trait type homes, callable ids, bare trait-method bindings, public
impl indexes, private impl indexes, simple enum/struct/trait boundary errors,
foreign-origin errors, source-level impl coherence errors, orphan impl errors
when both homes are known, conservative resource-containing aggregate metadata,
and first-pass resource function boundary diagnostics. Unannotated function
return and parameter slots currently project to `Void` until the inference slice
owns source signatures. Imported declaration Env effects that require full
typed export declarations remain part of the loaded-module/signature bridge
rather than the syntactic module-surface import slice.

OCaml references:

- `compiler/lib/typecheck.ml`
  - `check_state`
  - `init_state`
  - `validate_program_source_type_syntax`
  - `validate_source_type_decl`
  - `validate_type_params`
  - `register_module_alias`
  - `register_imported_name`
  - `add_import_binding`
  - `qualify_imported_type_expr`
  - `register_resource_cleanup_metadata`
  - `validate_foreign_metadata`
  - `validate_resource_result_annotation`
  - `validate_resource_signature_boundary`
  - `add_imported_type_alias`
  - `register_qualified_import_resource_types`
  - `make_impl_instance`
  - `try_add_source_impl`
  - `try_add_private_impl`
  - `register_module_impls`
  - `check_orphan`
  - `add_trait_function_checked`
  - `register_imported_trait_def`
  - `register_trait`
  - `register_module_trait_defs`
  - `register_ufcs_methods_for_type`
  - `first_pass`
  - `prepend_prelude_imports`
- `compiler/lib/modules.ml`
  - `get_typed_decls`
  - `set_typed_decls`
  - `get_typed_import_bindings`
  - `set_typed_import_bindings`
- `compiler/lib/pipeline.ml`
  - `typecheck_loaded_module`
  - `ensure_modules_typed`
  - `check_cross_module_coherence`
  - `check_modules`

Blorp references:

- `compiler/blorp/src/stage_06_typecheck/compiler_typecheck_state.brp`
- `compiler/blorp/src/stage_06_typecheck/compiler_typecheck_types.brp`
- `compiler/blorp/src/stage_06_typecheck/compiler_typecheck_decl.brp`
- `compiler/blorp/src/stage_06_typecheck/compiler_imports.brp`

Implementation steps:

- Port `check_state` as explicit Blorp data. Keep module aliases, imported
  names, import bindings, module origin, private impls, known type names,
  known resource types, top-level names, type homes, callable ids, and
  type-shape memo in one state value. This state substrate is implemented in
  `compiler_typecheck_state.brp`.
- Port top-level pre-scans before imports. This is implemented in
  `compiler_typecheck_decl.brp`:
  - known type names,
  - resource type names,
  - top-level namespace names,
  - foreign-block function names,
  - private-wrapper contents.
  Builtin/resource legality by module origin remains part of semantic
  declaration registration.
- Port import registration using the Blorp module graph:
  - qualified aliases,
  - selective imports,
  - renamed symbols,
  - private symbol rejection,
  - duplicate local names,
  - import bindings for Core flattening.
  This pure bookkeeping slice is implemented in `compiler_imports.brp`; imported
  declaration Env effects remain part of semantic declaration registration.
- Port declaration registration in the current `first_pass` order:
  - records/structs,
  - unions/enums/resource/builtin types,
  - type aliases and opaque aliases,
  - globals,
  - functions,
  - foreign functions,
  - traits.
  These local Env-registration slices are implemented in
  `compiler_typecheck_decl.brp`; source-signature inference remains part of
  checkpoint 6, and imported declaration Env effects require the loaded-module
  signature bridge.
- Port impl registration with context-owned indexes. Trait definition indexing
  and collision-checked bare method registration are covered by
  `compiler_typecheck_decl.brp`. Source impl headers now register public impl
  instances, private impl instances, source-level coherence conflicts, inline
  and implicit generic impl bounds collected from the `for` type, and orphan
  diagnostics when the trait and type homes are both known. Full default-method
  synthesis remains checkpoint 6 work, matching the OCaml second-pass boundary.
- Port orphan/coherence checks and cross-module coherence over source-level
  impls. Source-module orphan and structural generic/specific overlap checks
  are implemented for first-pass registration. Whole-graph cross-module
  coherence remains tied to typed loaded-module signatures.
- Port prelude import insertion with self-import guards.
- Keep typechecking loaded modules separate from typechecking the explicit
  target until the whole module graph is Blorp-owned.

Edge cases:

- Public versus private declarations, including private trait methods and
  private impl methods.
- Two modules with the same local type name need distinct owner-qualified type
  identities.
- Private impls emit C symbols but must not satisfy cross-module trait bounds.
- Builtin declarations are allowed only for std modules.
- Foreign declarations are allowed for user/native package modules, not source
  packages or std.
- Resource cleanup metadata must be registered before Core lowering.
- Debug-only functions are callable only in debug contexts unless explicitly
  allowed.
- Function callable ids must be stable enough for typed AST and Core lowering.
- Prelude import insertion must not create self-import cycles.

Tests:

- `compiler/test/test_typecheck.ml`
- `compiler/test/test_pipeline.ml`
- `compiler/test/test_trait_obligation_architecture.ml`
- `compiler/test/test_module_type_identity.ml`
- `tests/test_compiler/typecheck/should_pass/import*.brp`
- `tests/test_compiler/typecheck/should_fail/visibility_*.brp`
- `tests/test_compiler/typecheck/should_fail/orphan*.brp`
- `tests/test_compiler/typecheck/should_pass/std_builtin_declarations.brp`
- `compiler/blorp/tests/test_compiler_typecheck_state.brp`
- `compiler/blorp/tests/test_compiler_typecheck_types.brp`
- `compiler/blorp/tests/test_compiler_typecheck_decl.brp`
- `compiler/blorp/tests/test_compiler_typecheck_impl_decl.brp`
- `compiler/blorp/tests/test_compiler_typecheck_resource_decl.brp`
- `compiler/blorp/tests/test_compiler_imports.brp`

Deletion point:

- Delete OCaml first-pass declaration registration only after Blorp can
  typecheck loaded module signatures and produce the same env/import binding
  facts for the OCaml second pass or the Blorp second pass.

## Checkpoint 6: Expression Inference And Typecheck Second Pass

Goal: port expression inference, function/global body checking, purity,
tailrec, resources, concurrency, and final typed AST construction.

Status: closed at the typecheck boundary. Blorp owns the expression-inference
and second-pass typecheck substrate and can materialize a validated
typed-program artifact. Production `check`, `compile`, and `run` source
commands consume that artifact through the single frontend graph handoff before
Core lowering. Legacy direct `Pipeline.compile_legacy_direct_source`, reusable
compiler-fixture typechecking, and some tooling/test paths can still use the OCaml
parser/typechecker until their callers move to an explicit Blorp frontend graph.
`compiler/blorp/src/stage_06_typecheck/compiler_infer.brp` now covers literals, identifiers, local
`var` declarations, block scoping, expected value slots, value ascription flow,
primitive/logical operators, direct non-generic calls, tuples, lists, dicts,
basic vector/tensor literals, record literals, record updates, record/tuple
field access, typed string interpolation parts, lambdas with annotated or
expected parameter/return types, tuple destructuring, ranges, `if`, conservative
`match` inference for wildcard/name/literal patterns with Bool exhaustiveness,
constant-index tuple and tensor/array subscript reads, full-rank constant-index
tensor/array subscript assignment, `while`, simple `for`, tuple `for` binders,
debug blocks, and
`break`/`continue` loop-context checks. Direct `?=` statement inference now
validates Option/Result carrier compatibility against the enclosing block,
binds the unwrapped value for following statements, rejects loop-body and final
statement uses, and preserves continuation-shaped typed nodes for lowering.
Plain assignment support covers discard
assignment, implicit immutable local binding, mutable local reassignment,
annotated literal initializer widening, and assignment-target diagnostics for
immutable variables and non-variable symbols. Compound assignment desugars
through plain assignment before typed lowering, preserving the same target
diagnostics. Direct and subscript assignment now carry explicit local-vs-module
target metadata from inference so later purity checks do not guess from source
names. Opaque `into`/`from` conversions now validate source/target direction,
generic opaque alias substitution, aliases to opaque types, and module-private
opaque conversion boundaries. The current slices preserve
typed-expression metadata for source type, semantic type, value type, widening
decision, refinement proofs, and resolved-call placeholder data, and they
include explicit copy boundaries for type and infer-context values to avoid
generated ARC aliasing. Direct calls currently cover function-typed callees,
exact arity, expected argument slots, value-type argument checking, resolved
callable metadata for named functions, and simple type-variable substitution
from argument types into return types. Direct generic calls also enforce
callee-declared trait bounds for concrete substitutions and for caller type
parameters that already carry the required bound. Bare overload-only calls now
use Env's all-argument resolver when argument probing can disambiguate,
including structural matching under the overload entry's type parameters and
pure-callback-slot specificity, preserve selected callable id/purity metadata,
specialize generic returns, enforce selected overload entry trait bounds, and
use expected return type slots to bind otherwise-unconstrained generic return
parameters. Overload misses report targeted no-match diagnostics. UFCS method syntax now uses Env's receiver-type UFCS index,
including structural matching under the method entry's type parameters, binds
receiver-derived generic substitutions before checking explicit method
arguments, prepends the typed receiver as the first call argument, specializes
generic returns, enforces selected UFCS entry trait bounds, and checks
non-receiver arity. Imported trait methods also resolve through
receiver-method syntax and direct calls while preserving the concrete impl
method's compiler-owned resource-operation policy.
Module-qualified function calls through registered module aliases now resolve
before ordinary field access and preserve the selected callable id/purity
metadata. Module-qualified variable access now resolves through explicit
module ownership on Env variable symbols, so `Alias.value` does not fall back
to an unrelated unqualified local. Module-qualified impl-method calls now
resolve `Alias.method(value, ...)` through module-owned UFCS overload entries,
using the first call argument as the receiver and preserving the selected
callable id/purity metadata. Generic source impl bounds are now extracted from
inline `T: Trait` syntax and inferred from bare type variables in the impl `for`
type, stored on impl instances, checked against concrete substitutions during
structural trait obligation resolution, and used for generic versus specific
impl coherence checks. Direct and UFCS calls now check callee-declared generic
dimension constraints after argument and expected-return substitution, keeping
dimension literals exact instead of widening them through ordinary generic
binding.
Collection literals
currently support expected-type empty lists/dicts/sets/vector tensors, non-empty
inference, collection-element widening for singleton integer literals, and
explicit heterogeneous diagnostics. Vector/tensor literal support currently
covers scalar elements, expected empty tensors, nested literal dimension
flattening, ragged nested literal rejection through element type checking, and
rejection of multidimensional tensor construction from tensor variables. Record literals support expected-record checking,
unique field-set inference, field-wise expected typing/widening,
missing/unknown-field diagnostics, and ambiguous field-set diagnostics. Empty
`{}` record syntax now respects expected `Dict[K, V]` and `Set[T]` collection
types while continuing to require record context for empty record inference.
Record updates preserve the base record type, validate update fields, and apply
field-wise expected typing/widening. Branch/control-flow coverage currently
handles common const-int branch result typing, non-`Bool` conditions,
value-producing `if` without `else`, simple match branch convergence,
Bool, open-scalar, named-constructor, and list-pattern exhaustiveness,
constructor/tuple/list/or pattern binding,
simple loop-only `break`/`continue`
validation, name-bound `for` loops over `Range`, `List`, `Vector`, `Set`,
`String`, and array/tensor-shaped values, and tuple binders over `Dict` and
iterables of tuples. Tuple destructuring now validates RHS tuple shape, binds
names into block scope, and rejects arity mismatches, non-tuple RHS values, and
same-scope redeclarations. Subscript reads currently infer tuple literal-index
access, first-dimension tensor/array peeling, full multi-index tensor element
access, constant-index bounds diagnostics, and explicit List/String runtime
indexing guidance. Subscript assignment currently covers mutable-root checking,
full-rank tensor/array writes, constant-index bounds diagnostics, element type
checking, and unsupported-target diagnostics; range-refined loop-variable
proofs for reads and writes remain with the refinement/subscript slice.
`compiler/blorp/src/stage_06_typecheck/compiler_typecheck_decl.brp` now has an explicit second-pass
body-check API for source functions and global variables. Function bodies are
checked with parameters in a scoped body environment and declared return types
as expected value slots; value-producing functions without return annotations
are rejected. The body checker also validates `main` signatures, accepting
`func main(args: List[String]) -> Int`, omitted-return `Void`, and explicit
`-> Void`, while preserving the OCaml diagnostics for wrong parameter, return,
and arity shapes. Function symbol registration now deep-copies function type
payloads before storing them in Env so compound signatures such as
`List[String]` are owned by the Env entry. Global initializers are inferred
against declared annotations when present, and unannotated global variables are
re-registered with their inferred type after checking. Global variables retain
their module owner metadata through both first-pass registration and checked
body re-registration. Mutable global initializers also reject startup function
calls and subscript expressions while skipping lambda bodies, matching the
OCaml "work before main" boundary. This is intentionally still the
conservative body-check slice: it does not yet port full resource-body rules
or final typed AST materialization. Closure-capture restrictions for mutable
values, scoped resources, scoped-resource-derived values, one-shot streams,
and resource sources now live in inference.
The conservative purity slice is also in place: typed expression traversal now
collects resolved impure calls, pure source function body checking reports
direct impure calls by callee name after expression inference, pure callback
parameter types are rejected on pure functions, and pure lambdas nested inside
any function body are checked independently of the outer function's purity.
Impure lambda bodies are intentionally not traversed as pure work. Pure
functions now also reject direct and subscript assignment to module-level
mutable variables while allowing same-name local mutable shadowing. Lambda
inference now rejects closure capture of mutable outer variables, including
multiple captures and assignment to an outer mutable binding, while allowing
immutable captures and parameter/local shadowing. The parsed free-variable
walker used by closure/task capture checks now covers newer expression forms
including `select`, `with`, `concurrent`, `for ... concurrently`, `detach`,
and direct `?=` sequence bindings. Debug-block validation now rejects impure
calls and assignment work inside inferred `debug:` bodies.
`detach` and basic `concurrent:` block expressions now have explicit typed
expression nodes instead of falling through to unsupported expressions. The
Blorp inference pass type-checks `max_threads`/`timeout` concurrent parameters
as integer expressions, rejects unknown or duplicate concurrent parameter
names, rejects duplicate fixed-task result names, rejects sibling fixed-task
result references, rejects mutable/resource-like task captures for fixed
tasks and detached work, infers the nested body, returns `Void`, and keeps the
new nodes visible to impure-call, module-assignment, startup-call,
startup-subscript, tail-recursion, pure-lambda, and debug-block traversals.
Full concurrent binding result leakage, concurrent timeout lowering, and
deeper resource ownership transfer remain in later concurrency/resource
slices.
`select:` now has explicit typed select-arm nodes in the Blorp inference pass
for receive, sealed, and after arms. The first slice keeps `select` statement
only, rejects empty select blocks, validates receive/sealed waitables as
`Channel[T]`, binds receive values only inside the selected arm body, accepts
integer and `Duration` timeout expressions for after arms, returns `Void`, and
keeps select waitables and arm bodies visible to purity/startup/tailrec/debug
traversals. Resource-producing waitables, operation-result waitables, selected
branch resource ownership, and Core lowering remain in later
concurrency/resource slices.
`for ... concurrently` now has an explicit typed node in Blorp inference. The
first slice keeps it statement-only, checks `limit` as `Int`, accepts integer
and `Duration` timeout expressions, infers `List[T]`/`ResourceSource[T]`
element bindings in a scoped loop body, treats the construct itself as an
impure operation, returns `Void`, and keeps its iterable, params, and body
visible to the same purity/startup/tailrec/debug traversals. Task capture
checking now allows the loop item while rejecting mutable/resource-like
captures from the parent scope. Core lowering, resource-source ownership
details, and more precise data-race diagnostics remain in later
concurrency/resource slices.
`with` expressions now have explicit typed binding/error-map nodes in Blorp
inference. The first slice validates plain resource acquisitions against
known resource type names, unwraps `Option`/`Result` `with ?=` acquisitions
using the enclosing expected carrier, type-checks `Result` error mappers,
binds scoped resources only inside the body, rejects resource-containing body
results from escaping, and keeps acquisitions, mappers, and bodies visible to
purity/startup/tailrec/debug traversals. The resource hardening slice adds
stable typed-expression resource dependency metadata, marks immutable
locals initialized from scoped-resource-dependent expressions as derived,
rejects scoped-resource-derived final `with` results, enforces compiler-owned
resource-operation call boundaries, and shadows parent resources as unavailable
while dependent nested resources are in scope. Lambda inference now also
rejects captures of scoped resources, scoped-resource-derived values,
one-shot streams, and resource sources. Local binding checks now reject
one-shot stream/resource-source ordinary carriers, function carriers that hide
those carriers, mutable direct resource-source bindings, and copies of
existing resource-source bindings. Aggregate storage checks now reject
stream/source values in tuple/list/tensor/dict literals, record fields, and
record updates. Core resource lowering and deeper resource ownership rules
remain in later resource slices.
Impl method body checking now reuses the same function-body, purity, debug,
module-assignment, and tail-recursive validation path while deliberately
skipping `main` entrypoint signature validation for methods. Impl method body
checking also extends the method's scoped type parameters with the implicit
type parameters inferred from the enclosing impl `for` type. Impl declaration
validation now checks required trait methods, supertrait obligations, method
purity, arity, return types, and parameter types with `Self` resolved to the
impl receiver type. Missing concrete impl methods with trait default bodies
are checked directly from the parsed trait declaration using the same
function-like body path instead of synthesizing temporary parsed function
declarations. `Self` resolution now returns owned type copies so resolved
signatures do not retain aliases into resolver-local values. Supertrait
validation uses direct trait evidence so a candidate subtrait impl cannot
prove its own supertrait.
Tail-recursive validation is now also present for inferred
source function bodies: the typed expression traversal detects recursive calls
used outside tail position and reports `@tail_recursive` violations for
operands/arguments/non-tail block items while allowing direct tail calls.
Block expressions now preserve their final expression's full typed metadata,
including target-typed value slots, so function body checks can accept a block
ending in a target-widened literal. Function-body checks now consume a
finalized infer result: typed-expression finalization structurally zonks
source/semantic/value types, annotations, widening slots, resolved-call dim
constraints, patterns, and all nested typed child expressions through the
inference context's meta bindings. Bare overload resolution now ranks
compatible candidates by parameter specificity, preferring exact concrete
matches over concrete-compatible matches over generic matches, while keeping
the pure-callback preference as a tiebreaker. Bare union constructors now
participate in expression inference: nullary constructors use the expected
parent type when present, fielded constructors infer pure constructor
functions, generic field types specialize through ordinary call substitution,
and constructor calls preserve callable metadata for later handoff.
Module-qualified constructor expressions now resolve through module aliases
and recorded parent type homes, including collision cases where another type
has a same-named constructor.
Module-qualified constructor patterns use the same alias and type-home
ownership rule, so pattern matching no longer guesses from the first
same-named constructor in Env. Float literal match patterns now participate in
pattern inference for float-family scrutinee types. Raw nested function
declaration expressions now report a source-finalization invariant failure if
they reach expression inference; normal typecheck input hoists nested
functions before this phase. Program body checking now also has a
Blorp-owned typed-program artifact: checked function bodies and global
initializers are materialized with their finalized typed expressions; functions
carry source and semantic return metadata; records carry typed field metadata,
type aliases carry typed target metadata, impls carry typed explicit method
bodies, and private declarations wrap the typed inner declaration.
Trait/union/builtin/foreign/import/error declarations remain
intentional parsed passthroughs until a later consumer needs additional typed
metadata. Checkpoint 6 is closed at the typecheck boundary; the Core-lowering
handoff for this artifact belongs to checkpoint 7.

OCaml references:

- `compiler/lib/infer.ml`
  - context and expected types:
    - `infer_ctx`
    - `make_ctx`
    - `with_expected`
    - `with_expected_value_slot`
    - `fold_expected_context`
  - type resolution and annotations:
    - `resolve_value_ascription`
    - `resolve_local_binding_annotation`
    - `resolve_function_parameter_annotation`
    - `resolve_function_return_annotation`
    - `validate_value_ascription_type`
  - resources/capabilities:
    - `type_contains_one_shot_stream`
    - `type_contains_resource_source`
    - `type_capability_items_for_target`
    - `reject_scoped_resource_derived_escape`
    - `reject_one_shot_stream_storage`
    - `reject_resource_source_storage`
    - `reject_resource_assignment`
    - `reject_resource_collection_element`
    - `reject_discarded_resource_value`
    - `validate_with_binding_annotation`
    - `validate_question_bind`
  - concurrency:
    - `reject_concurrent_outer_mutation`
    - `reject_concurrent_mutable_capture`
    - `reject_duplicate_concurrent_bindings`
    - `reject_concurrent_sibling_binding_refs`
    - `classify_select_waitable`
  - module/record lookup:
    - `lookup_module_func_resolution`
    - `lookup_module_var_type`
    - `lookup_module_impl_method`
    - `resolve_record_field_types`
    - `resolve_record_field_type`
  - calls/operators:
    - `check_binop`
    - `check_unop`
    - `check_logop`
    - `build_subst`
    - `check_trait_bound_on_arg`
    - `check_callee_trait_bounds`
    - `resolved_call_metadata`
    - `attach_resolved_call_metadata`
    - `runtime_builtin_name_for_call_expr`
  - expression driver:
    - `infer_expr`
    - `zonk_expr`
    - `infer_expr_with_annotated_expected`
    - `infer_expr_with_return_annotation`
- `compiler/lib/typecheck.ml`
  - `second_pass`
  - `check_function_body`
  - `check_exhaustiveness`
  - `check_list_exhaustiveness`
  - `validate_debug_usage`
  - `validate_top_level_initializer_has_no_calls`
  - `check_nested_pure_lambdas`
  - `check_purity`
  - `check_tailrec`
  - `check_matches_in_expr`
  - `validate_impl`
  - `validate_main_signature`
  - `typecheck_global_var_decl`
  - `typecheck_with_state_and_source`
  - `typecheck_with_state_typed`
  - `typecheck_typed`
  - `typecheck_module_with_state_and_source`
  - `typecheck_module_with_state_typed`
- `compiler/lib/call_resolution.ml`
- `compiler/lib/purity_analysis.ml`
- `compiler/lib/unused_imports.ml`

Blorp references:

- `compiler/blorp/src/stage_06_typecheck/compiler_infer.brp`
- `compiler/blorp/src/stage_06_typecheck/compiler_typecheck_decl.brp`
- future `compiler_infer_call.brp`
- future `compiler_infer_resource.brp`
- future `compiler_infer_concurrency.brp`
- future `compiler_exhaustiveness.brp`
- future `compiler_purity.brp`
- future `compiler_tailrec.brp`
- future `compiler_unused_imports.brp`

Implementation steps:

- Port inference in slices that can each be parity tested:
  1. literals, identifiers, local bindings, blocks, and annotation flow;
  2. primitive operators and logical operators;
  3. direct calls, module-qualified calls, UFCS, overloads, and resolved-call
     metadata;
  4. generic substitution, trait bounds, and dim constraints;
  5. records, structs, unions, enums, aliases, opaque conversions, and field
     access;
  6. tuples, lists, dicts, sets, strings, tensors, ranges, and loop views;
  7. `if`, `while`, `for`, `match`, pattern binding, branch narrowing, and
     exhaustiveness;
  8. `?=`, `with`, resource sources, one-shot streams, and resource capability
     restrictions;
  9. `concurrent`, `detach`, `for concurrently`, `select`, timeouts, and task
     capture restrictions;
  10. globals, top-level initializers, `main`, debug blocks, pure lambdas,
      function bodies, impl bodies, purity, tailrec, and unused imports;
  11. final zonking and typed AST construction.
- Preserve the `source_ty`, `semantic_ty`, `value_ty`, `widening`, `proofs`,
  and `resolved_call` slots on every typed expression.
- Keep `?=` propagation explicit and expression-oriented. Do not introduce
  exception-like control flow.
- Continue tightening compile-time validation that rejects startup work outside
  `main`; mutable top-level initializer calls and subscript expressions are
  already covered in the Blorp declaration checker.
- Port error text and help for user-facing type errors before deleting OCaml
  diagnostics.

Edge cases:

- Local mutation is allowed in pure functions; impure calls are not.
- Closures and concurrent task boundaries cannot capture mutable variables.
  Blorp inference also rejects resource, resource-derived, stream, and source
  captures at closure/task boundaries; deeper resource transfer semantics
  remain in the resource slice.
- Pure callbacks and impure callback parameters affect purity.
- Exhaustiveness must cover wildcard, nullary constructors, list patterns,
  nested patterns, and unreachable cases.
- Range/subscript refinement proofs must survive through loop and branch
  inference.
- Empty list/dict literals need expected-type guidance.
- Function type parameter auto-generalization must not treat forward-declared
  local types as free type params.
- Opaque conversions are legal only at the home module boundary.
- Resource values cannot be copied, stored in ordinary containers, discarded,
  or escape scoped resource lifetimes.
- Concurrent blocks cannot mutate outer vars or capture scoped resource values
  unsafely.
- `Duration` timeouts must preserve microsecond rounding behavior.
- Type errors should include current help text where tests assert it.

Tests:

- `compiler/test/test_infer.ml`
- `compiler/test/test_purity_analysis.ml`
- Add focused unused-import tests if `unused_imports.ml` is split into its own
  port slice.
- `tests/test_compiler/infer/should_pass`
- `tests/test_compiler/infer/should_fail`
- `tests/test_compiler/typecheck/should_pass`
- `tests/test_compiler/typecheck/should_fail`
- `tests/test_blorp/concurrency`
- `tests/test_blorp/sys`
- New Blorp unit tests for each inference slice.
- `compiler/blorp/tests/test_compiler_infer.brp`

Deletion point:

- Delete `infer.ml`, `typecheck.ml`, `call_resolution.ml`,
  `purity_analysis.ml`, and `unused_imports.ml` only after normal
  `check`, `compile`, and `run` consume a Blorp typed-program artifact and the
  OCaml middle no longer typechecks source.

## Checkpoint 7: CTFE And Typed AST Boundary

Goal: make Blorp produce the final typed program consumed by Core lowering,
including compile-time evaluation results.

OCaml references:

- `compiler/lib/typed_ast.ml`
  - `make_program`
  - `type_info_to_ast`
  - `type_info_of_ast`
  - `validate_type_info`
  - `of_ast_expr`
  - `of_ast_expr_with_type_info`
  - `of_ast_program`
  - `of_ast_program_with_sources`
- `compiler/lib/typed_ast_debug.ml`
- `compiler/lib/type_metadata_format.ml`
- `compiler/lib/operation_result_metadata.ml`

Deleted at this checkpoint:

- `compiler/lib/ctfe*.ml`
- `compiler/test/test_ctfe_*.ml`

Blorp references:

- future `compiler_typed_ast.brp`
- `compiler_typed_ast_json.brp`
- `compiler_typecheck_bridge.brp`
- `compiler_ctfe*.brp`
- `compiler_type_metadata.brp`
- future `compiler_type_metadata_format.brp`

Implementation steps:

- Define a Blorp typed AST that is phase-specific, not just parsed AST with
  optional annotations.
- Preserve both source-shaped and semantic declaration trees where tooling
  needs source spelling but Core needs canonical typed facts.
- Port typed-AST validation before relying on typed output:
  - no missing expression type info,
  - no inference metas,
  - coherent source/semantic/value types,
  - coherent widening decisions,
  - resolved-call metadata where required.
- Port CTFE after expression inference but before Core lowering:
  - compile-time function execution,
  - global constant materialization,
  - std compile-time helpers,
  - pattern matching,
  - value materialization back into typed AST.
- Introduce a typed-program JSON artifact only for the temporary handoff from
  Blorp typecheck to OCaml Core lowering. Delete it when Core lowering moves to
  Blorp.

Current status:

- Blorp now exposes `compiler_typecheck_program` as the single declaration
  typecheck entrypoint for one parsed program: prescan, type declaration
  registration, signature registration, impl registration, body materialization,
  and typed-program validation.
- `CompilerTypedProgram` materialization validates that no `CompilerMetaType`
  values remain in typed declaration metadata or typed expression trees before
  the result is returned.
- Typed expression validation now also checks explicit source-origin coherence,
  semantic/value-slot coherence, widening-decision coherence, and resolved-call
  metadata propagation from typed callees to typed call expressions across typed
  expression trees.
- Blorp now has a structured frontend `CompilerType` JSON projection for the
  typed-program handoff, including function purity, dimension expressions,
  variadic dimension markers, and meta-type diagnostics.
- Blorp now has a structured typed-expression metadata JSON projection for the
  handoff, including origin, widening decisions, value slots, proof facts,
  resolved-call metadata, and resource dependencies. Resolved direct-call
  metadata now carries an explicit callable origin for local, imported,
  builtin, foreign, constructor, and impl-method calls so later Core and CTFE
  stages do not infer call provenance from names.
- Blorp now has structured typed expression, typed declaration, and
  `CompilerTypedProgram` JSON projections. The production source-command path
  now consumes this handoff artifact directly before Core lowering. Typed
  function metadata now carries the registered callable id, so decoded function
  declarations preserve the same direct-call identity Core lowering expects.
- The production typed handoff now preserves ordinary loop-view metadata and
  resource cleanup/dependency facts instead of reconstructing them in OCaml.
  Blorp inference also owns contextual lambda-purity promotion: an unannotated
  lambda is promoted only when a pure callback slot is expected and its typed
  body has no impure operation. This restores no-capture collection fusion
  without a backend special case.
- Symbolic tensor dimensions now survive callee type-parameter alpha-renaming
  and static dimension arguments. Dimension-aware subscript proof recognizes
  positive symbolic products, flattened `row * columns + column` indices, and
  immutable bounds guards while keeping ordinary runtime indices as `Int`.
- Blorp now has a dedicated `typecheck_source` bridge artifact producer in
  `compiler_typecheck_bridge.brp`. It typechecks a single finalized source
  program and returns `typed_program`, `type_errors`, and `module_surface`
  fields. The production source-command path uses this bridge through
  graph-aware request payloads; direct source/tooling APIs still need explicit
  frontend graphs before they can use the same boundary.
- OCaml now has a `Typed_ast_json` decoder layer for source spans, structured
  `CompilerType` JSON, typed expression metadata, proof facts, resolved-call
  bridge metadata including callable origin, value slots, and typed patterns
  emitted by Blorp. It now decodes a first typed-expression subset (names,
  literals, unary/binary/logical expressions, calls with direct-call metadata,
  tuples, tuple destructuring, assignment, subscripts, lists, vectors, dicts,
  opaque conversions, records, record updates, blocks, ifs, ranges, field
  access, ascriptions, debug blocks, local var declarations, question-bind,
  void/break/continue, and builtins), plus global-var, function, record,
  type-alias, and impl typed declarations in typed programs. Record, alias, and
  impl decoding validates source-shaped metadata against semantic typed
  metadata before materializing OCaml typed declarations, including impl method
  callable ids. Parsed passthrough declarations, including grouped import and
  foreign blocks, decode through the existing parsed-AST decoder and flatten
  into the OCaml typed-program declaration list. Direct-call bridge metadata now
  includes instantiated parameter and return types, and the OCaml decoder
  materializes legacy `Ast.resolved_call` values for the decoded subset. Full
  expression/declaration coverage remains.
  The OCaml decoder independently rejects incoherent explicit-origin and
  value-slot metadata before those artifacts can reach Core lowering.
- The OCaml typed-program decoder now also materializes typed string
  interpolation parts, lambdas, `select`, `while`, ordinary `for` loops
  including tuple binders, `for ... concurrently(...)`, `detach`, and `with`
  expressions. `concurrent:` block typed handoff now carries explicit
  concurrent binding records with result metadata; OCaml decodes the
  `bindings` field directly instead of reconstructing bindings from a body
  block shape.
- Resolved-call metadata now carries an explicit target object in the Blorp
  typed handoff: direct callable, trait method, or closure call. This removes
  the previous flat optional-field coupling for trait calls and makes closure
  calls first-class in the typed artifact instead of relying on the absence of
  direct-call metadata.
- Direct-call targets now require a concrete callable id in the Blorp typed
  handoff. Compiler-synthesized calls that do not yet have a callable id are
  represented as explicit intrinsic targets instead of overloading
  `direct.callable_id = null`; the OCaml decoder preserves intrinsic metadata as
  bridge-only facts and does not materialize fake legacy direct calls.
- The temporary OCaml typed-program decoder now requires the structured
  `resolved_call.target` object. It no longer accepts the older flat
  `callable_id`/`trait_name`/`origin` bridge shape.
- OCaml now also has an explicit `typecheck_source` bridge client path:
  request builders, typed-program artifact decoding through `Typed_ast_json`,
  path-only request helpers, and a dedicated prepared
  `compiler_typecheck_bridge_cli.brp` helper binary. `scripts/test` prepares
  this helper alongside the renderer and parser helpers, so typed-frontend
  bridge calls do not fall back to lazy helper compilation during test gates.
  The OCaml client also exposes command helpers for graph-style typed-source
  requests with explicit imported modules, with integration tests that execute
  the bridge and decode both standalone and imported-module typed artifacts.
  Typecheck response decoding surfaces `type_errors` even when the best-effort
  typed tree attached to an error artifact fails typed-AST validation;
  successful artifacts still must decode as coherent typed programs.
  The request protocol also has an explicit `import_modules` field for callers
  that already own graph context: each supplied module is parsed into a Blorp
  module surface and passed through `compiler_typecheck_program_with_import_surfaces`.
  This was the normal source-command handoff boundary for `check`, `compile`,
  and `run` before the source-command path moved to the frontend graph bridge.
  CTFE now runs in the Blorp typed-program bridge; Core lowering is the next
  OCaml-owned phase on the right side of that boundary.
- Blorp typechecking now centralizes import bookkeeping in
  `compiler_imports.brp`. The single-source typed bridge uses the explicit
  syntax-only import collector so it can report qualified module aliases,
  selective imported names, constructor imports, combined alias-plus-symbol
  imports, and canonical import bindings without pretending that a full module
  graph is available. `compiler_typecheck_program_with_import_surfaces` is the
  graph-aware entrypoint: after top-level name prescan it validates imports
  against supplied Blorp module surfaces, records imported type homes, and then
  runs declaration signatures and body materialization. The typed-source bridge
  now emits import bindings and the OCaml bridge decoder materializes them as
  `Session.import_binding` values, so the temporary typed-program handoff
  carries the metadata CTFE and Core flattening already consume.
  Constructor import bindings are preserved after the parent type export is
  validated; validating individual constructor names still belongs with typed
  loaded-module declarations because module surfaces do not currently expose
  variant lists.
- The typed bridge now parses supplied `import_modules` into paired module
  surfaces and public parsed declarations. Graph-aware typecheck registers
  those declarations with their owning module path and origin, so qualified
  calls such as `Dep.answer()` and explicitly imported calls such as `answer()`
  typecheck through the Blorp bridge. Bare lookup is scoped: declarations made
  available only through a module alias do not leak as unqualified values, and
  private imported declarations are skipped.
- `Pipeline.typecheck_only_typed_with_blorp_bridge_policy` is the graph-backed Blorp
  typecheck handoff used by source-command checks. It builds explicit
  import-module payloads from graph edges, materializes graph-loaded dependency
  module typed declarations/import bindings into `Modules`, and requires the
  decoded Blorp artifact to have already run CTFE before returning the target
  typed program or Blorp typecheck/CTFE diagnostics.
- `Pipeline.compile_preloaded_graph_with_blorp_bridge` is the source-command
  compile boundary: it consumes the same Blorp frontend graph, decodes the
  Blorp typed-program artifact, populates dependency typed-module caches, and
  then enters the shared OCaml Core/codegen handoff without
  returning to the OCaml typechecker.
- Direct-source `Pipeline.compile_legacy_direct_source`, reusable
  compiler-fixture typechecking, and module-only typecheck APIs are now
  documented in code as legacy/tooling routes. The REPL/test runner use the
  explicit legacy compile name where they intentionally still depend on OCaml
  parsing and typechecking. A compiler-unit regression pins that the
  graph-backed compile bridge consumes the preloaded target source rather than
  rereading a changed file from disk.
- The compiler port inventory hygiene check now rejects new references to
  legacy direct-source pipeline entrypoints outside the narrow allowlist
  (`pipeline`, the private OCaml host tooling commands, package checking, REPL,
  and test runner). This keeps normal source-command work on the Blorp frontend
  graph while the remaining tooling paths are migrated deliberately.
- Blorp builtin registration now includes the scalar-width conversions,
  bitwise operations, tensor constructors, and channel sealing used by the
  production backend surface. Bare-name lookup scans past declarations owned
  by unrelated, unimported modules before falling back to a builtin, while a
  visible local or explicitly imported declaration still wins. This repaired
  12 generated-C audit cases in the installed CLI. Tensor constructor
  signatures also bind their dimension arguments directly to `#N` parameters
  instead of returning unbound symbolic dimensions. Together these changes
  moved the 2026-07-11 generated-C audit baseline from `92/101` to `105/88`.
  CTFE now represents admitted compiler builtins as typed enum operations and
  evaluates deterministic `to_float16`/`to_float32` conversions with target
  precision before materialization; unsupported builtins remain explicit
  unsupported calls. Sized-float static constants brought the current audit
  baseline to `109/84`.
  Tensor arithmetic, structural `HasLength`/`Stringable` evidence, refined
  tensor `length`, checked N-D reads, and range-proven subscripts are now owned
  by Blorp inference. Range proofs remain semantic metadata while ordinary
  runtime and generic value flow uses `Int`; storing a proof in a tuple erases
  it instead of polluting the tuple's generic element type. Valid direct
  variable subscript writes now normalize during inference to
  `x = checked_set(x, ...)`, with rank selecting the matrix/tensor intrinsic,
  matching the old OCaml phase contract. The backend bridge also admits the
  runtime's existing boxed `blorp_vector_get_opt` and
  `blorp_matrix_get_opt` ABIs while retaining specialized handling for stack
  `Option` results. Tuple literals now keep singleton/range facts in their
  semantic type while recursively widening their stored value type; collection
  and generic element normalization uses that same recursive tuple rule.
  Scalar dimension refinements also widen to runtime `Int` whenever an `Int`
  slot is explicitly expected. These changes moved the 2026-07-11 generated-C
  audit to `128/65`; the previously regressed statement-level conditional,
  vector raw-storage, dimension-folding, and tuple-match fixtures generate C
  again. The compile-time collection fixture now advances beyond tuple/list
  inference to the separate CTFE `std/dict.from_list` coverage gap.
  The largest remaining audit clusters are aggregate/refined value widening,
  CTFE builtin coverage, generic collection inference, resource annotation
  validation, concurrency purity/effect modeling, and stale generated-C
  ownership expectations. Field-target subscript assignment intentionally
  remains explicit: rewriting `record.tensor[i] = value` as assignment to the
  record root would be incorrect without a record-update representation.
- The production `typecheck_graph` bridge streams one typed artifact at a time.
  Its graph context parses and finalizes each source module once, constructs
  the importable-module set once, and reuses those immutable values across
  target typechecks. Semantic type projection now owns names copied from parsed
  syntax, and unchanged type-resolution branches return deep copies, so reused
  parsed declarations remain valid. The full CLI clean build dropped from a
  typecheck helper exceeding 4.2 GB without completing to a successful roughly
  143 second build with a 1.76 GB process-tree peak on macOS arm64.
- **Compiler-graph closure closed (measured 2026-07-11):** the default CLI now
  typechecks `compiler/blorp/tests/test_compiler_core_perceus.brp` through the
  full Blorp graph in 9m54s with a 3.82 GB maximum resident set. The standalone
  `compiler_infer.brp` source graph also typechecks in 6m44s with a 2.57 GB
  maximum resident set. Closing the graph required canonical imported global
  annotations, contextual function-purity compatibility in list literals,
  CTFE function-reference values that preserve purity without invoking impure
  callbacks, explicit Core declaration imports, and concrete integer min/max
  helpers where the self-hosted graph cannot yet discharge the generic trait
  call. The remaining limitation is throughput rather than graph closure.
- **Graph CTFE dependency preparation is deduplicated (2026-07-11):** graph
  preparation now identifies direct user leaf modules needed by immutable
  globals across the requested module artifacts and target, typechecks each
  dependency once, and shares that bounded result with every artifact that
  explicitly imports it. Failed dependency preparation is cached as an
  explicit failure and remains isolated to artifacts that require that module.
  The production protocol still streams one artifact at a time, and the graph
  does not retain every completed typed artifact. A bridge regression verifies
  that a leaf shared by two module artifacts and the target appears once in the
  dependency plan while all three artifacts complete CTFE.
- Imported module bodies were already materialized once per requested module;
  retaining a second complete typed graph would increase the measured 3.82 GB
  peak rather than remove demonstrated duplication. The remaining repeated
  semantic work is construction of the imported declaration, signature, impl,
  and binding environment for each selected artifact. The next graph slice
  should factor that immutable import context into a reusable prepared value,
  with artifact-local bindings and diagnostics kept separate. It should not add
  a process-level cache or retain all serialized artifacts.
- **Full typecheck bridge graph closure is verified (2026-07-11):** a direct
  production `check` of `compiler_typecheck_bridge.brp` now succeeds across the
  complete imported graph. The closure pass replaced graph-order-sensitive
  record literals with typed constructors, reused one canonical optional-type
  copy helper from the owning type module, modeled inferred versus declared
  global types explicitly, qualified the colliding string `repeat` operation,
  and removed generic tuple-result matches the current backend cannot emit.
  Match-branch and call-argument mismatch diagnostics now preserve the source
  path, line, and column when crossing the streamed typecheck boundary. These
  changes also exposed and removed duplicate parameter-annotation conversion
  and enum membership that incorrectly relied on `Equatable`.
- Blorp now has the first CTFE value/operator foundation in
  `compiler_ctfe_value.brp`: typed compile-time values, constructor payload
  metadata, structural equality, expectation helpers, and primitive unary/binary
  operation semantics for Int, Float, Bool, and String values. This is
  deliberately not wired into production evaluation yet; it is the data/runtime
  surface the later Blorp CTFE evaluator and materializer should build on.
- Blorp now also has `compiler_ctfe_env.brp`, the first lexical/global
  environment layer for CTFE. It models global/local bindings, unavailable
  global reasons, immutable-assignment rejection, mutable local assignment as an
  explicit updated environment, and user-facing environment error messages
  without copying OCaml's mutable-cell implementation detail. It also provides
  scoped-env projection for loop and branch bodies, preserving updates to
  pre-existing bindings while dropping locals introduced in the scoped body.
- Blorp now also has `compiler_ctfe_context.brp`, the metadata context layer
  for CTFE. It indexes typed functions by callable id, imported function groups
  by module/source name, union constructor arities/nullary references, module
  aliases from import blocks, and module global environments from
  `CompilerTypedProgram` values. It deliberately does not evaluate expressions
  yet; it gives the upcoming evaluator a typed, test-covered lookup surface
  instead of reaching into the typed AST ad hoc.
- Blorp now also has `compiler_ctfe_globals.brp`, the source-order global
  availability layer for CTFE. It identifies typed global declarations,
  preserves private-global metadata, treats mutable top-level `var` bindings as
  runtime-initialized, binds immutable globals as later CTFE candidates, and can
  answer whether imported typed programs declare a global by module path/name.
  It also constructs the initial target CTFE environment from explicit
  `CompilerImportBinding` values, so selective imported constants are available
  by local name and selected runtime-initialized globals remain unavailable with
  an imported-global diagnostic.
- Blorp now also has `compiler_ctfe_value_ops.brp` for shared Option/Result
  carrier construction and state decoding over CTFE constructor values. This
  keeps `?=` and later std Option/Result intrinsic evaluation from duplicating
  constructor-shape checks in the evaluator.
- Blorp now also has `compiler_ctfe_intrinsic.brp` for centralized admission
  of compiler-owned std operations during CTFE. The supported subset covers
  deterministic calls over `std/string`, `std/list`, `std/option`, and
  `std/result`, including callback-taking list/Option/Result helpers when the
  callback is a named pure local function reference. Keeping intrinsic
  admission separate from evaluation keeps future expansion table-driven
  instead of scattering source-name checks through the evaluator.
- Blorp now also has `compiler_ctfe_pattern.brp` for matching typed patterns
  against CTFE values. It covers wildcard/name/literal patterns, tuple/list
  patterns with spread bindings, constructor and qualified-constructor patterns,
  nullary-constructor name patterns using `CompilerCtfeContext`, and or-pattern
  fallback without pushing pattern semantics into expression evaluation.
- Blorp now also has the first `compiler_ctfe_ir.brp` slice: a normalized,
  typed CTFE expression IR for literals, names/reference kinds, transparent
  wrappers, unary/binary/logical expressions, tuples, lists, vectors, records,
  dicts, block expressions with local `let`/`var` bindings and local
  assignment items, tuple-destructuring block items, `?=` block items, and
  field access classified as record, tuple, range, or imported-global access
  before evaluation. Imported-global access uses explicit module aliases
  collected from import blocks in `CompilerCtfeContext`; the evaluator reads
  those values from attached module-global environments instead of guessing
  from identifier names. It also translates match expressions into explicit
  CTFE IR match cases while preserving typed patterns for the dedicated pattern
  binder, translates `while`, `for`, tuple-binder `for`, `break`, and
  `continue` into explicit CTFE IR control forms, and translates call
  expressions into explicit local, imported, constructor, unresolved, impure, or
  unsupported CTFE call kinds. Unsupported forms fail at the
  translation boundary with a structured error, preserving the old evaluator
  boundary while giving later evaluator work a smaller target than
  `CompilerTypedExpr`.
- Blorp now also has the first `compiler_ctfe_eval.brp` slice: an evaluator for
  the supported CTFE IR subset. It evaluates literals, environment lookups,
  nullary constructors, transparent wrappers, unary/binary/logical expressions
  with short-circuiting, `if`, ranges, record/tuple/range field access, record
  updates, tuples, lists, vectors, records, dicts, block-local bindings, local
  assignment updates, tuple destructuring, `?=` continuation/propagation for
  Option and Result constructor values, finalized typed string interpolation
  over primitive CTFE values, match expressions with pattern-bound case scopes,
  local and imported pure source function calls with name/wildcard/tuple
  parameter binding, constructor calls, qualified imported-global reads, and
  module-global lookup for imported function bodies. It also evaluates the
  imported std intrinsic subset for strings, lists, Option, and Result while
  preserving separate translation, environment, value/operator, invalid-value,
  and unsupported error categories. Named pure local function references now
  materialize as CTFE function-reference values, so callback-taking std helpers
  can call them through the ordinary pure local function-call path. The
  evaluator now also handles `while`, range/list `for`, and tuple-binder
  list `for` loops with `break`/`continue`, threading explicit value
  environments through loop bodies so assignments to outer mutable bindings
  persist without leaking loop-body locals or loop binders. Builtins, trait
  calls, foreign calls, closures, impl-method calls, and captured lambda
  callbacks remain unsupported until their values have clean Blorp
  representations.
- Blorp now also has `compiler_ctfe_materialize.brp` for materialization from
  evaluated CTFE values back into source-shaped and typed expressions. It
  covers scalar literals, tuples, lists, vectors, dicts, records, ranges, void,
  nullary constructors, and synthesized constructor calls with direct
  constructor callable metadata. It also materializes named pure local function
  references back into coherent typed name expressions with direct-call
  metadata. It can also rebuild coherent `CompilerTypedGlobalVarInfo` values by
  updating both the parsed initializer and typed initializer.
- Blorp now also evaluates source-order global CTFE environments in
  `compiler_ctfe_globals.brp`. Immutable globals are evaluated against an
  environment that marks the current binding as self-unavailable, earlier
  evaluated globals as available, later globals as unavailable, and mutable
  top-level `var` bindings as runtime-initialized. Imported typed programs can
  be evaluated into module global envs and attached back to
  `CompilerCtfeContext`. Blorp also has a whole-program global rewrite helper
  that evaluates immutable global initializers in source order, materializes
  them back into typed declarations, and leaves mutable top-level `var`
  declarations on the runtime path. A higher-level helper owns the CTFE global
  boundary by building context from target/imported typed programs, evaluating
  imported module global environments, binding target import bindings, and
  rewriting the target program.
- The `typecheck_source` bridge now opportunistically runs the Blorp global
  CTFE rewrite after successful typechecking. It emits a `ctfe_status` protocol
  field with `evaluated` or `not_run`; successful source-command typecheck
  artifacts must report `evaluated`. Unsupported CTFE forms surface as Blorp
  typecheck diagnostics instead of falling back to OCaml. Self-contained
  immutable globals, selected constants from explicit leaf user-module imports,
  and imported pure function calls evaluate in Blorp.
- The Blorp executable (`compiler_cli_main.brp`) now runs CLI planning and
  source graph construction directly, writes the existing CLI plan JSON
  artifact to a temporary file, and invokes the private OCaml host only to
  execute that plan. The host no longer needs to ask a Blorp helper to interpret
  normal user CLI arguments.
- Immediate remaining checkpoint work is typed-frontier closure, broader
  import-aware CTFE parity, and final typed AST ownership. OCaml CTFE has been
  removed; legacy direct pipeline APIs now produce finalized typed ASTs without
  a compile-time global rewrite and should continue moving to explicit Blorp
  frontend graphs.
- The OCaml test runner still owns discovery, `TestSuite`/doctest harness
  generation, C compilation, and execution, but it no longer re-enters the
  OCaml source frontend. Generated suite, aggregate, and doctest harnesses use
  an explicit in-memory Blorp source-graph handoff with generated-source policy;
  standalone leak-baseline programs use the same handoff with ordinary user
  source policy. The remaining TestRunner migration is orchestration ownership,
  not parser/typechecker parity, and must preserve doctest location remapping,
  process cleanup, and filesystem-isolation behavior.

Typed frontier closure before CTFE:

- Close or explicitly classify residual OCaml typecheck/parser consumers:
  `Pipeline.compile_legacy_direct_source`,
  `Pipeline.typecheck_only_typed_reusing_session`,
  `Pipeline.typecheck_module_only_typed`, package/source-package checks, the
  LSP/tooling helpers, and the remaining package/REPL routes. TestRunner source
  compilation is closed; its OCaml work is post-frontend orchestration.
- Normal source execution must enter through the Blorp frontend graph and
  `typecheck_source` bridge. If a direct pipeline API remains, document it as a
  temporary legacy/tooling route with a deletion condition rather than allowing
  it to silently re-enter OCaml typecheck.
- Keep `concurrent:` typed handoff explicit: binding result metadata belongs in
  the `bindings` field and must not be inferred from body statements.
- Keep trait-dispatch and closure-call metadata represented explicitly in the
  typed artifact before relying on the handoff for Core lowering.

Edge cases:

- Compile-time values must preserve value semantics and no shared mutable
  state.
- CTFE must not evaluate impure functions.
- Global constants over records, generic records/unions, tensors, lists,
  strings, tuples, and float16/float32 values must remain materializable.
- Typed AST output must preserve callable ids and import bindings for Core
  flattening and call resolution.
- Trait-dispatch, closure-call, and intrinsic-call metadata must stay explicit;
  do not infer those targets from callee names or expression shapes.

Tests:

- `compiler/test/test_typed_ast.ml`
- `compiler/blorp/tests/test_compiler_ctfe_*.brp`
- `tests/test_compiler/typecheck/should_pass/compile_time_*.brp`
- `tests/test_compiler/codegen_audit/should_pass/global_constant_*.brp`
- `compiler/blorp/tests/test_compiler_typecheck_bridge.brp`
- `compiler/test/test_typed_ast_json.ml`
- New Blorp typed AST and CTFE tests.

Deletion point:

- Delete remaining OCaml typed AST construction after Blorp typed-program output
  is authoritative for all source/tooling paths and Core lowering consumes it.

## Checkpoint 8: Core Lowering, Flattening, FFI Boundary, And Layout Setup

Goal: move the boundary from typed AST to lowered Core.

Status: implementation parity is in progress, but the production boundary has
not moved. Normal source commands still decode the Blorp typed artifact into
OCaml `Typed_ast` and call `Core_lower.lower_typed_program` through
`Core_pipeline.compile_typed_with_modules`. The Blorp lowerer is currently a
directly tested implementation, not the production Core producer.

OCaml references:

- `compiler/lib/core_lower.ml`
  - `lower_typed_program`
  - `lower_typed_decl`
  - `lower_typed_expr`
  - `lower_typed_expr_core`
  - `lower_block`
  - `lower_with`
  - `lower_timeout_expr`
  - `lower_concurrently_loop`
  - `lower_duration_timeout_milliseconds`
  - `selected_direct_call_kind`
  - `resource_cleanup_call`
- `compiler/lib/core_flatten.ml`
  - `prefix_module_names`
  - `rewrite_main_imported_type_names`
  - `rewrite_canonical_module_type_names`
  - `build_import_tables_from_typecheck`
  - `register_types`
- `compiler/lib/core_ffi_boundary.ml`
  - `annotate_program`
- `compiler/lib/core_list_layout.ml`
  - `annotate_program`
- `compiler/lib/codegen/codegen_types.ml`
  - `create_registry`
  - `register_*`
  - `type_to_c`
  - alias/layout helpers used by lowering and later passes
- `compiler/lib/core_pipeline.ml`
  - `compile_typed`
  - `compile_typed_with_modules`

Blorp references:

- `compiler_foreign_validation.brp`
- `compiler_core_lower.brp`
  - `compiler_core_lower_type`
  - `lower_typed_expr`
  - `lower_typed_decl`
  - `lower_typed_program`
- `compiler_core_flatten.brp`
- future `compiler_core_ffi_boundary.brp`
- `compiler_core_list_layout.brp`
- existing `compiler_core_json.brp`

Implementation steps:

- Do not start Blorp Core lowering from an OCaml-reconstructed typed AST unless
  we deliberately accept another temporary bridge. Final typed-AST ownership is
  the step that keeps the source-to-Core boundary contiguous.
- Port `Core` data constructors needed by lowering before lowering logic.
- Port lowering mechanically from typed expression shapes to Core:
  identifiers, literals, calls, fields, control flow, matches, loops, blocks,
  assignments, data construction, lambdas, string interpolation, resources,
  select, concurrency, and detach.
- Keep lowering strict. Any parsed/source-only or untyped node reaching this
  stage is a compiler error.
- Port fresh-name generation as context state, not global counters.
- Port module flattening and import tables after lowering can produce Core for
  single modules.
- Port FFI boundary annotation and initial list layout annotation before
  running Core passes.
- Preserve foreign metadata collection for link flags/include dirs until the
  impure shell moves.

Current progress:

- `compiler_core_lower.brp` owns the first lowering slice for source
  locations, Core type conversion, expression value-type lowering after
  widening, function values as `Closure`, stable Core vars, scalar literal/name
  expressions, resolved local/trait/intrinsic/closure call expressions,
  resolved builtin direct-call expressions, unary/binary/logical expressions,
  tuple/list/vector/dict expressions, `if`, `while`, lambdas, blocks with local
  `LetExpr` bindings, tuple destructuring block items, ascriptions and opaque
  wrappers, assignment, record field access, tuple field access, ranges, record
  literals, and `detach`, no-parameter `concurrent:` blocks, simple
  literal/wildcard matches, simple `select:` expressions,
  simple named-binder
  range/List/String/Set `for` loops, and function/global/record/enum/union
  declarations with explicit lowering context state for Core def ids.
- Function-body classification is now shared at the parsed-AST boundary rather
  than being inferred independently by typecheck and Core lowering. Blorp Core
  lowering preserves legal forward declarations as bodyless user functions,
  preserves naked and `std/...` builtin declarations as bodyless builtin
  functions for later synthesis/resolution, and synthesizes named runtime
  helper bodies as parameter-forwarding `BuiltinCall` expressions. It rejects
  inconsistent typed payloads, such as a forward or builtin declaration that
  unexpectedly carries a typed source body. Concrete intrinsic-body synthesis
  and the post-monomorphization `Core_synth` retry are still required before the
  production lowering boundary can move across std modules.
- Unsupported typed AST shapes return `CompilerCoreLowerError` instead of
  dropping declarations or falling back implicitly. This keeps the next
  production boundary strict while expression coverage expands. Calls now
  preserve the same phase distinction as OCaml lowering: local callable ids
  become `SelectedDirectCall`, while imported, constructor, impl-method,
  foreign, builtin, intrinsic, closure, and unresolved targets remain
  `UnknownCall` until their owning middle-pipeline pass classifies them.
- `compiler_core_resolve.brp` owns the first post-lowering resolution slice.
  `resolve_callable_id_calls` resolves `SelectedDirectCall` and `UnknownCall`
  values carrying callable ids when the qualified callee name and carried def
  id agree with a function or constructor declaration in the assembled Core
  program. Numeric def ids are module-local, so
  unrelated declarations may reuse them, and repeated occurrences of the same
  qualified identity from module-graph assembly are equivalent. Only stale
  identities remain unresolved. Name-only `UnknownCall` resolution remains
  closed until module, builtin, foreign, trait, and bound-local registries have
  all been ported.
- The temporary OCaml `core_resolve.ml` handoff follows the same identity rule:
  a canonical post-flatten qualified name is resolved before consulting the
  reverse selected-id index. This prevents a module-local selected id from
  resolving to an unrelated same-signature function after flattening. The
  regression belongs to the boundary and can be deleted with OCaml resolve.
- `compiler_core_flatten.brp` now owns callable-name flattening for one lowered
  module. It sanitizes the module path, assigns distinct names to bodied
  pure/impure overloads, records module provenance on top-level functions and
  impl methods, and rewrites direct and closure references by the exact
  `(source name, module-local def_id)` identity. Builtins, foreign declarations,
  UFCS-mangled names, and impl method declaration names remain stable. Local
  variables without a callable id cannot be rewritten accidentally. Matching
  forward declarations converge on the bodied callable's qualified name and
  body-preference deduplication removes the declaration-only duplicate, which
  preserves the std pure/impure forward-declaration pattern.
- This is deliberately not presented as the complete flattening port. Global
  declarations, module-owned and imported types, canonical type names, import
  tables, non-callable duplicate declaration handling, and registry population
  still belong to later checkpoint 8 slices. Keeping those responsibilities
  explicit avoids reproducing the OCaml pass's name-based fallback before the
  necessary module and type ownership data is available in the Blorp Core
  boundary.
- `compiler_core_list_layout.brp` now owns list storage annotation over the
  shared Core model. It derives primitive and enum inline widths, value-record
  and stack-option inline structs, pointer storage, and element release facts
  from `CoreProgram` declarations. Alias expansion supports both ordinary and
  parameterized aliases and terminates safely on alias cycles. The pass walks
  function, global, and impl-method bodies and rewrites list construction,
  allocation, and handoff nodes bottom-up. It is available as the named
  `list_layout` Blorp Core stage, but is not redundantly rerun in the current
  production pre-DCE tail because that handoff still receives layouts attached
  by OCaml lowering.
- `CoreFunctionKind.ForeignFunction` now preserves the C name, includes,
  platform link flags, and checked argument-passing mode. The late OCaml Core
  projection populates and round-trips that payload instead of discarding it.
  `compiler_core_ffi_boundary.brp` classifies default String/Bytes arguments as
  defensive copies, unmanaged layouts as by-value, preserves explicit borrows,
  and returns structured errors for managed, unknown, or invalid default
  arguments. Foreign source blocks now materialize as one
  `CompilerTypedForeignFunctionDecl` per function, with callable identity,
  canonical parameter/return types, C name, includes, typed platform link
  flags, and explicit default-copy/borrow mode. Blorp Core lowering consumes
  that typed payload directly and collects ordered foreign includes. The
  temporary typed-AST bridge re-encodes each declaration as a one-function
  foreign block for the existing OCaml decoder, so this slice adds no new OCaml
  handoff model. `compiler_foreign_validation.brp` now owns source-level C-name,
  include-path, and link-flag validation, rejects unverifiable foreign return
  refinements, and rejects managed default-mode arguments before Core lowering;
  the existing compiler failure corpus exercises those production diagnostics.
  Before the production boundary moves, the lowered program must run FFI
  annotation before later Core passes. Do not reconstruct metadata from
  function names or call shapes.
- The shared `CoreDecl` model now preserves declaration type parameters and
  represents type aliases and impl containers directly. This follows the OCaml
  pipeline's single progressively refined Core IR instead of introducing a
  second lowered-declaration hierarchy. Core JSON round trips those early
  declarations, and the OCaml projection now sends explicit declaration
  `type_params` at the existing backend bridge.
- Typed record/enum/union lowering preserves generic parameter names in that
  shared model. Typed aliases now lower their semantic target type, opacity,
  generic parameters, and source location directly to `TypeAliasDecl`. Typed
  impls lower their semantic receiver type and thread lowering context through
  every method, preserving callable ids and minting missing ids in declaration
  order. The former erased-storage warning around these typed payloads is no
  longer reproducible in the current compiler and focused lowering tests now
  construct both shapes directly.
- Trait signatures no longer use parsed passthrough storage. Typecheck now
  materializes canonical method parameter/return types in
  `CompilerTypedTraitDecl`; lowering preserves generic parameters,
  supertraits, purity, parameters, and source locations in `TraitDecl`. Core
  JSON round-trips this phase-specific representation, callable flattening and
  later passes preserve it, and DCE keeps it for the future Blorp trait resolver.
  The temporary typed-AST bridge deliberately re-encodes the parsed declaration
  because OCaml still models traits as `DeclOther`; no semantic type facts are
  reconstructed from that bridge inside Blorp.
- Builtin type declarations and imports remain parsed passthrough production
  blockers because they contribute registry and module-resolution facts.
  Represent those facts at the typed/Core boundary before switching production
  lowering. Do not make `CompilerTypedParsedDecl` disappear by dropping these
  declarations: the late pre-DCE bridge can omit them only because OCaml has
  already consumed their semantics.
- `compiler/blorp/tests/test_compiler_core_lower.brp` covers the initial slice,
  including ordinary function bodies, forward declarations, deferred std
  builtins, and named runtime-helper forwarding bodies.
  Tensor-shaped type lowering exists in the helper, but the runtime test avoids
  constructing that metadata until backend test emission handles it cheaply.
- The lowering tests now include a fixture-shaped `CompilerTypedProgram` to
  Core JSON harness. It starts with a small function fixture and gives future
  slices a stable place to compare typed-program bridge artifacts against
  Blorp-lowered Core without threading through the whole production compiler
  path.
- `while` and lambda lowering now follow the OCaml lowering shape directly:
  `while` lowers to `WhileExpr(cond, body)` and lambdas lower to Core lambda
  nodes over typed lambda parameter records, explicit return type, body, and
  purity.
- Record declaration lowering maps typed `struct` declarations to
  `ValueRecordDecl` and heap `record` declarations to `HeapRecordDecl`.
  Heap-record field cleanup metadata is derived through the shared backend
  type-layout policy helper instead of duplicating release-policy logic in the
  lowerer.
- `detach` lowers to the pre-closure Core detach form so closure conversion
  remains the single place that turns detached bodies into task closures.
- No-parameter `concurrent:` blocks lower to the pre-closure Core concurrent
  form. When a concurrent block appears at the head of a block expression, the
  following block tail becomes the concurrent body so task-result bindings
  scope over their actual uses. Parameterized concurrent blocks stay closed
  until timeout and `max_threads` normalization are ported.
- `select:` receive, sealed, integer-timeout, and `Duration`-timeout arms lower
  to the prepared `SelectExpr` Core shape. Duration timeout lowering now
  mirrors OCaml's microsecond-to-millisecond conversion, including clamping
  non-positive values to zero and rounding positive sub-millisecond values up.
  `concurrent(...)` block parameters now lower `timeout` through that same
  normalization path and preserve positive-literal `max_threads` in the
  pre-closure concurrent block. Ordinary list-backed
  `for ... concurrently(limit: ..., timeout: ...)` loops now lower to the
  pre-closure concurrent-loop Core shape, preserving positive-literal `limit`,
  normalized optional timeout, copy-item mode, and discard-output semantics.
  Resource-source concurrent loops remain closed until the resource ownership
  lowering slice can port the cleanup-scope behavior from OCaml.
- Direct block `?=` bindings now lower to a temporary plus prepared
  `ConstructorMatchExpr` for both `Option[T]` and `Result[T, E]` carriers.
  The success arm binds the unwrapped payload and lowers the remaining block as
  the continuation; the failure arm rebuilds the enclosing carrier through the
  same stack/nullable/boxed carrier tests and accessors used by the backend
  layout code.
- Simple `for name in start..end` loops lower directly to the prepared
  `ForRangeExpr` Core form with a conservative `RangeMayRunBackward` loop
  binder. Simple `for name in items` loops over `Channel[T]`, `List[T]`,
  `Stream[T]`, `String`, `Dict[K, V]` keys, and `Set[T]` lower to the
  explicit prepared Core loop variants with iterable release policy attached
  where the Core shape requires it. Channel and Stream loops are marked
  impure during typed-expression purity scanning because they pull from their
  input source. Typed `indices(array)` loop views now lower directly to a
  prepared `ForRangeExpr` over `0..length(array)` and preserve the inferred
  range-refined binder type. Loop-view metadata is authoritative: malformed
  metadata and unported view kinds fail lowering instead of falling through to
  the producer function's nominal return type. Dict tuple-pair binders,
  resource-source, tensor, `windows`, and any remaining iterable families still
  need deliberate prepared-loop slices instead of a generic OCaml-style `CFor`
  node. Ordinary tuple binders over
  tuple-valued iterables now lower through one collision-free synthetic loop
  binder plus explicit tuple-field `LetExpr` bindings; Dict pairs select the
  existing prepared pair-iteration backend path. This work resumes after the
  ownership-hardening fixes that closed the earlier synthetic-tuple cleanup
  failure. The focused late-Core ASan/UBSan gate passes 672/672 with the tuple
  and loop-view lowering regressions included. One-dimensional tensor
  `enumerate` and matrix `enumerate2` now capture their source exactly once and
  lower directly to one or two prepared range loops. Tuple binders use the
  range variables directly
  and bind only the fetched element, avoiding a per-iteration tuple allocation;
  a single-name binder still materializes the language-level pair or triple.
  `enumerate2` uses the concrete column dimension when available and otherwise
  mirrors the production OCaml fallback of `tensor_capacity(source) /
  length(source)` for generic matrix dimensions. Multidimensional `enumerate`
  and `windows` remain closed.
- Literal-only matches lower directly to prepared `LiteralMatchExpr` nodes for
  literal arms plus a wildcard fallback. Binding, constructor, tuple/list, and
  or-pattern lowering remains deliberately closed until the full match
  decision-tree port is in place.
- Expression value-type lowering now treats `CompilerConstIntType` as a Core
  `Int` value while strict type lowering still rejects dimension literals as
  standalone Core types. This keeps literal-valued expression nodes from
  failing lowering before the remaining type-finalization paths are migrated.
- Enum and union declarations now materialize as `CompilerTypedUnionDecl`
  instead of parsed passthrough declarations. The typed shape carries canonical
  variant field types, tags, and constructor def ids from typecheck/env
  registration. Core lowering consumes that shape to emit `EnumDecl` and
  `UnionDecl`, including constructor C names, tag names, payload storage, and
  field release policies. CTFE context construction also reads typed union
  constructor metadata so compile-time constructor calls retain callable ids.
- Resource cleanup identity now crosses the typed-AST boundary explicitly.
  Builtin resource declarations register their cleanup function in the Blorp
  typecheck context, including canonical imported type names, and
  `CompilerTypedWithBinding` preserves the selected cleanup function. Core
  lowering no longer needs session-global resource metadata: plain `with`
  lowers directly to `ResourceScopeExpr`, while `with ?=` lowers to a prepared
  Option/Result constructor match whose success arm owns the resource scope and
  whose failure arm preserves ordinary or mapped error propagation. Resources
  without registered builtin cleanup retain the language-level `close`
  fallback. Focused tests cover registration, inference/JSON transport,
  builtin and fallback cleanup, mapped errors, and the downstream
  resource/Perceus passes.

Edge cases:

- `CompilerTypedWithBinding` still stores the parser's two-case binding-kind
  enum. A direct phase-specific enum split currently triggers the bootstrap
  compiler's duplicate nominal-module-identity failure in combined Blorp
  compiler tests (`expected X, got X` for the same qualified type). Keep the
  dependency isolated behind `compiler_typed_with_binding_is_try` until that
  compiler defect is fixed; do not duplicate the enum through import aliases.
- `Duration` timeouts must round microseconds up to milliseconds.
- Loop-view producers (`indices`, `enumerate`, `enumerate2`, `windows`) are
  internal and must only lower under `for`/tuple-for. `indices`, one-dimensional
  `enumerate`, and two-dimensional `enumerate2` are implemented with explicit
  collision-free Core identities. Keep multidimensional `enumerate` and
  `windows` closed until their row/slice operations have the same explicit
  ownership and identity treatment.
- Module alias calls use `TyNamed "Module"` sentinel today; replace with an
  explicit typed AST/Core representation when feasible.
- Callable ids from inference must remain authoritative over stale mangled
  names.
- Subscript reads should already be calls; subscript assignment should already
  be typechecked into an explicit call.
- Foreign string/bytes copy/no-copy metadata must be preserved.
- Record update lowering needs either an early Core sugar variant in the Blorp
  Core model or a direct lowering target that preserves update semantics across
  later ownership passes.

Tests:

- `compiler/test/test_core_lower.ml`
- `compiler/test/test_core_flatten.ml`
- `compiler/test/test_core_ffi_boundary.ml`
- `compiler/test/test_core_list_layout.ml`
- `tests/test_compiler/codegen_audit/should_pass/foreign_*.brp`
- `tests/test_compiler/codegen_audit/should_pass/concurrent*.brp`
- New Blorp lowering parity tests using typed AST JSON fixtures.

Deletion point:

- Delete `core_lower.ml`, `core_flatten.ml`, and OCaml lowering tests after
  `compile` starts the Core pipeline from Blorp-lowered Core.

## Checkpoint 9: Early And Middle Core Pipeline

Goal: move the lowered-Core pipeline stages into Blorp from left to right.

Status: Blorp DCE is authoritative on the normal production path and the
superseded OCaml DCE implementation and tests are deleted. The remaining early
and middle Core stages from debug/desugar through specialization are still
OCaml-authoritative. Stage parity modules must not be counted as migrated until
the production pass ordering invokes them and the replaced OCaml pass is
deleted.

OCaml references, in `Core_pipeline.run_core_passes` order:

- `compiler/lib/core_debug.ml`
  - `lower_program`
- `compiler/lib/core_desugar.ml`
  - `desugar_program`
- `compiler/lib/core_ssa.ml`
  - `desugar_mut_program`
- `compiler/lib/core_mono.ml`
  - `monomorphize_program`
- `compiler/lib/core_list_layout.ml`
  - `annotate_program`
- `compiler/lib/core_synth.ml`
  - `synthesize_program`
- `compiler/lib/core_match.ml`
  - `compile_program`
- `compiler/lib/core_trait_resolve.ml`
  - `resolve_program`
- `compiler/lib/core_resolve.ml`
  - `resolve_program`
- `compiler/lib/core_std_inline.ml`
  - `rewrite_program`
- `compiler/lib/core_tailrec.ml`
  - `lower_program`
- fusion cluster:
  - `core_string_pipeline.ml` / `fuse_program`
  - `core_collection_pipeline.ml` / `fuse_program`
  - `core_parallel_tensor_pipeline.ml` / `fuse_program`
  - `core_tensor_fusion.ml` / `fuse_program`
  - `core_tuple_sroa.ml` / `rewrite_program`
- `compiler/lib/core_specialize.ml`
  - `specialize_program`
- `compiler/lib/core_closure.ml`
  - `adapt_function_refs_program`

Blorp references:

- existing `compiler_core_traverse.brp`
- existing `compiler_core_json.brp`
- future `compiler_core_debug.brp`
- existing `compiler_core_desugar.brp` for the first prepared-Core-compatible
  desugar slice
- future `compiler_core_ssa.brp`
- future `compiler_core_mono.brp`
- future `compiler_core_synth.brp`
- future `compiler_core_match.brp`
- future `compiler_core_trait_resolve.brp`
- future `compiler_core_resolve.brp`
- future `compiler_core_std_inline.brp`
- future `compiler_core_tailrec.brp`
- future fusion modules
- future `compiler_core_specialize.brp`
- existing `compiler_core_dce.brp`

Implementation steps:

- Port stages in exact `run_core_passes` order. Move the production boundary
  left by one stage or a tightly coupled pair only after parity passes.
- `compiler_core_desugar.brp` currently ports the string binary-operator slice
  from `compiler/lib/core_desugar.ml`: string `+`, `==`, and `!=` become
  `blorp_string_concat`, `blorp_string_eq`, and `not blorp_string_eq`.
  It recursively traverses Core function/global bodies and the prepared
  container/control-flow nodes available through Core JSON. Record-update and
  string-interpolation desugaring remain closed until equivalent Blorp Core
  sugar nodes or direct lowering targets exist.
- Add `run_core_pipeline` support for each newly ported stage so tests can
  compare one Core JSON input against OCaml and Blorp outputs.
- Keep public stage names stable: lower, debug, desugar, mono, synth, match,
  trait_resolve, resolve, std_inline, tailrec, fusion, specialize, dce.
- Keep generated-name counters and registries explicit in stage input/output.
- Port diagnostic rendering with the stage that owns the diagnostic. For
  example, trait-resolution diagnostic helpers should disappear when
  trait resolve moves.
- Keep `Core_invariants` coverage available at the boundary until equivalent
  Blorp invariant checks exist.

Edge cases:

- Debug blocks are retained only for debug/test paths.
- Desugar and SSA must preserve mutable-local semantics without introducing
  shared mutable references.
- Monomorphization must use selected callable ids, module import tables, type
  aliases, dim constraints, and list layout facts.
- Match compilation must preserve pattern semantics, fallbacks, and source
  locations for diagnostics.
- Trait resolve must handle direct functions, UFCS, imported functions,
  operator methods, static-self returns, and builtin fast paths.
- Resolve must distinguish user, foreign, builtin, selected direct, closure,
  intrinsic, and unknown call kinds.
- Fusion passes must fail closed. They should not rewrite when ownership,
  shape, callback purity, or layout facts are incomplete.
- DCE must retain hash callbacks, task closures, global initializers, every
  reachable emitted function, and the transitive type graph used by retained
  code. The projected boundary no longer contains generic templates or impl
  containers; backend artifacts are derived from retained data declarations.

Tests:

- Existing OCaml tests to mirror where they exist:
  - `compiler/test/test_core_desugar.ml`
  - `compiler/test/test_core_ssa.ml`
  - `compiler/test/test_core_mono.ml`
  - `compiler/test/test_core_synth.ml`
  - `compiler/test/test_core_match.ml`
  - `compiler/test/test_core_trait_resolve.ml`
  - `compiler/test/test_core_resolve.ml`
  - `compiler/test/test_core_std_inline.ml`
  - `compiler/test/test_core_tailrec.ml`
  - `compiler/test/test_core_string_pipeline.ml`
  - `compiler/test/test_core_collection_pipeline.ml`
  - `compiler/test/test_core_parallel_tensor_pipeline.ml`
  - `compiler/test/test_core_tensor_type.ml`
  - `compiler/test/test_core_tuple_sroa.ml`
  - `compiler/test/test_core_specialize.ml`
- Add missing focused coverage for `Core_debug.lower_program` when that slice
  ports.
- `tests/test_compiler/codegen_audit/should_pass/core_dce_*.brp`
- Blorp stage parity tests under `compiler/blorp/tests`.
- `compiler/blorp/tests/test_compiler_core_desugar.brp`
- `compiler/blorp/tests/test_compiler_core_dce.brp`
- `tests/test_compiler/codegen_audit/should_pass/blorp_backend_dce.brp`

Deletion point:

- Delete each OCaml Core pass after the production boundary moves before that
  pass and stage observation reads the Blorp result.

## Checkpoint 10: Ownership, Perceus, Backend Tail, And Emission

Goal: finish the already-started backend ownership migration and remove the
post-Perceus OCaml boundary.

Status: the production boundary has moved from post-Perceus to pre-DCE. Blorp
DCE, consume specialization, and Perceus are authoritative on every normal compile,
the single `emit_core_c` bridge action runs the complete Blorp-owned tail, and
the replaced OCaml implementations and implementation-only tests are deleted.
The moved path has focused sanitizer coverage and has compiled the full Blorp
CLI; the formatter path is also ASan-clean through this boundary.

Current progress:

- `compiler_core_ownership.brp` now carries the intrinsic and runtime builtin
  contract families, polymorphic arities, constructor transfer contracts, and
  explicit pre-Perceus sentinels. Mechanical comparison against OCaml leaves
  only the intended tensor/equality sentinels outside direct contracts.
- `compiler_core_consume_specialize.brp` now keys clones by function name,
  definition id, and argument index; rewrites assignments through direct,
  literal, and length constructor-match bodies; handles branch-swapped
  recursive fields; and has a Perceus integration regression proving the clone
  suppresses the obsolete mutable-slot release.
- Perceus infers user-function ownership contracts from function bodies with a
  dependency worklist instead of relying solely on call-site metadata. The
  monotonic analysis may add consumed parameters but does not remove projected
  call-site consumes.
- Branch summaries and balancing cover `if` and compiled constructor decision
  trees, including nested literal and exact/minimum/fallback length matches,
  shadowing, and scrutinee aliases. Repeated consume protection covers while
  and every Core `for` family, traverses nested decision trees, and now applies
  to both borrowed and backend-managed owned match bindings. This closes the
  production `Result ?=` payload use-after-free exposed when CTFE repeatedly
  passed one matched value to a consuming pattern binder.
- Consumed-parameter balancing now keeps direct match scrutinee aliases live
  through tag selection and balances ownership only inside the selected branch.
  A recursive `Doc.cat(a, b)` regression covers returning either consumed
  parameter from nested matches or transferring both into `Concat`; the
  production formatter exercises the same shape and passes under ASan.
- Mutable assignments release replaced owners, retain alias installs, avoid a
  second release after COW consumption, and thread assignment state through
  compiled matches. Mutable result retention reconstructs matched `LetExpr`
  children before result-position recursion, avoiding parent-lifetime and C
  argument-order dependencies. Function finalization retains borrowed parameter
  and match binding returns, retains aggregate members, balances inferred
  consumed parameters, and recursively inserts drops through the exhaustive
  shared Core child mapper in `compiler_core_traverse.brp`.

Remaining cleanup after the ownership boundary move:

- **Blocking ownership stabilization (re-scoped 2026-07-10):** follow
  `COMPILER_OWNERSHIP_HARDENING_ROADMAP.md` to land the two confirmed Core
  lower/prepare fixes and the focused Core ASan gate as one narrow checkpoint.
  The Result `?=` and nullable-Option tuple regressions now pass individually
  under ASan on the working branch, and the combined focused Core surface has
  passed 588/588. The checkpoint is not complete until unrelated diff churn is
  removed and the documented merge gate passes.
- Do not require an exhaustive Core clone framework, a compiler-wide pass
  audit, or pre-Core ASan cleanup before resuming contiguous migration. The
  broad compiler-owned ASan run has separate dimension-solver, CTFE, inference,
  and typecheck-state debt; those failures do not invalidate a clean late-Core
  boundary.
- Defer the phase-explicit `UserCall` contract redesign until the next
  production boundary move requires it or a focused correctness regression
  proves the current state ambiguous. Do not mix that representation change
  into the narrow ownership checkpoint.
- Keep the conservative managed-return guard in `contract_for_call`. A broad
  switch to inferred borrowing is not sound yet: match binding modes in the
  projected callee body can still assume ownership even when both OCaml and
  Blorp infer a borrowing function parameter. Removing the guard requires
  Blorp to derive match-binding ownership from the finalized function contract
  in the same phase, then prove the compiler-owned Core suites under ASan.
- The narrow ownership merge gate must include the nullable-Option prepare
  case, Result `?=` Core lowering, owned-union reuse, channel receive, task
  result aliases, file-resource cleanup, and mutable aggregate assignment.
  A conservative consume-all fallback may hide a use-after-free while
  regressing reuse and leak coverage, so it is not an acceptable production
  fix.
- Keep extending runtime leak and sanitizer coverage as new ownership-bearing
  Core forms are introduced. New forms must be represented in the shared Core
  traversal and fail closed when their call contract is unknown.
- Delete the remaining OCaml ownership/layout facts and the Core JSON projector
  only when the left boundary reaches the corresponding earlier Core stages;
  they are still inputs to OCaml lowering and pre-DCE projection today.

Remaining OCaml references:

- `compiler/lib/core_ownership.ml`
- remaining metadata/layout helpers:
  - `core_layout_type.ml`
  - `core_hash_container_layout.ml`
  - `core_option_layout.ml`
  - `core_result_layout.ml`
  - `core_emit_layout.ml`
  - `core_emit_util.ml`
  - `codegen/codegen_names.ml`
  - `codegen/codegen_types.ml`
  - `codegen/codegen_builtins.ml`
- bridge projector:
  - `core_emit_blorp_c.ml`

Blorp references:

- `compiler/blorp/src/stage_09_core/compiler_core_dce.brp`
- `compiler/blorp/src/stage_09_core/compiler_core_consume_specialize.brp`
- `compiler/blorp/src/stage_09_core/compiler_core_ownership.brp`
- `compiler/blorp/src/stage_09_core/compiler_core_perceus.brp`
- `compiler/blorp/src/stage_09_core/compiler_core_reuse.brp`
- `compiler/blorp/src/stage_09_core/compiler_core_closure.brp`
- `compiler/blorp/src/stage_09_core/compiler_core_resource.brp`
- `compiler/blorp/src/stage_09_core/compiler_core_fairness.brp`
- `compiler/blorp/src/stage_09_core/compiler_core_prepare.brp`
- `compiler/blorp/src/stage_10_backend/compiler_core_emit.brp`
- `compiler/blorp/src/stage_10_backend/compiler_core_emit_type_layout.brp`
- `compiler/blorp/src/stage_10_backend/codegen_*_renderer.brp` for typed
  static data, diagnostics, and prepared-operation rendering

Implementation steps:

- Keep consume specialization immediately before Perceus and preserve the
  current direct clone eligibility rules.
- Move `core_layout_type`, option/result/hash-container layout, codegen names,
  and builtin mapping facts into Blorp as typed data rather than OCaml
  projection-time helpers.
- Shrink `core_emit_blorp_c.ml` to the temporary JSON projector while OCaml
  still owns earlier Core. Delete it when Core is Blorp-owned before the
  backend tail.
- Keep Blorp emission the only C artifact generator. Do not add new OCaml
  emission helpers.

Edge cases:

- Ownership must fail closed for repeated contexts, non-linear control flow,
  aliasing results, borrowed args, consuming calls, COW-consuming calls, and
  foreign/closure calls.
- Resource cleanup, structured concurrency, task closures, channels, and
  cancellation paths must not leak.
- Prepared Core must make layout, boxing, retain/release, option/result, tuple,
  hash container, and union representation explicit before emission.
- Generated C warning classes promoted by codegen audit must stay clean.

Tests:

- `compiler/test/test_core_ownership.ml`
- `compiler/blorp/tests/test_compiler_core_consume_specialize.brp`
- `compiler/blorp/tests/test_compiler_core_ownership.brp`
- `compiler/blorp/tests/test_compiler_core_perceus.brp`
- `compiler/blorp/tests/test_compiler_core_emit*.brp`
- `scripts/test leak`
- `tests/test_compiler/codegen_audit`
- runtime resource/concurrency tests under `tests/test_blorp`.

Deletion point:

- Completed for OCaml consume specialization and Perceus. Delete OCaml
  ownership/layout projection and Core-to-JSON modules after the contiguous
  left boundary moves before their last production consumers.

## Checkpoint 11: Artifact Writing, Host C Invocation, Runtime Packaging

Goal: keep the compiler semantics in Blorp while isolating the remaining
impure shell responsibilities.

The comprehensive implementation and deletion sequence for this checkpoint is
in `BLORP_OCAML_HOST_EXIT_ROADMAP.md`. It is also authoritative for replacing
the serialized CLI/module-graph plan with one phase-specific semantic-middle
worker. The summary below remains as an index of the affected compiler areas.

OCaml references:

- `compiler/bin/blorp_ocaml_host.ml`
  - `write_file`
  - `write_compile_output`
  - `run_file`
- `compiler/lib/test_runner.ml`
  - `compile_c_from_stdin`
  - `precompile_runtime`
  - `runtime_cache_key`
  - `cc_args_for_test_binary`
- `compiler/lib/runtime.c`
- `compiler/lib/runtime_decl.c`
- `compiler/lib/runtime_raylib.c`
- `compiler/lib/platform.ml`

Blorp references:

- `compiler/blorp/src/stage_10_backend/compiler_artifact_json.brp`
- `compiler/blorp/src/stage_10_backend/compiler_core_emit.brp`
- future `compiler_artifact_writer.brp`
- future `compiler_host_c.brp`

Implementation steps:

- Keep C artifact emission pure: generated C text, link flags, include dirs,
  runtime requirements, and diagnostics.
- Model artifact writing and host compiler invocation as explicit impure shell
  actions over the pure artifact.
- Preserve runtime embedding versus precompiled runtime object behavior.
- Preserve release/debug/sanitize/profile flag handling.
- Move runtime artifact manifest/hash calculation only after the Blorp std/file
  APIs and process APIs are adequate for robust impure shell code.

Edge cases:

- `--no-emit`, `-o`, temporary C output, binary output, and cleanup behavior.
- Host platform link flags and source-relative include dirs for foreign blocks.
- Raylib and TLS/native package link flags.
- Precompiled runtime cache invalidation by runtime source, compiler binary,
  C compiler identity, sanitizer mode, optimization, and TLS backend.

Tests:

- `compiler/test/test_test_runner.ml`
- `compiler/test/test_compiler_test_runner.ml`
- `scripts/test cli`
- `scripts/test runtime`
- preview smoke commands in `AGENTS.md`

Deletion point:

- Delete OCaml artifact writing and host-C wrapper only after the Blorp CLI can
  perform impure file/process actions directly and the preview smoke commands
  pass through the Blorp shell.

## Checkpoint 12: Tools, Test Runner, REPL, LSP, Packages, And Final OCaml Shell

Goal: remove the remaining OCaml compiler/tool shell after compiler semantics
are Blorp-owned.

OCaml references:

- `compiler/bin/blorp_ocaml_host.ml`
  - `purify_file`
  - package command helpers
  - `run_test_from_frontier_options`
  - `run_purify_from_frontier_options`
  - `run_package_from_frontier_options`
  - `run_delegate_command`
- `compiler/lib/test_runner.ml`
- `compiler/lib/repl.ml`
- `compiler/lib/line_editor.ml`
- `compiler/lib/lsp/*.ml`
- `compiler/lib/package_manifest.ml`
- `compiler/lib/package_check.ml`
- `compiler/lib/package_hash.ml`
- `compiler/lib/package_artifact.ml`
- `compiler/lib/package_cache*.ml`
- `compiler/lib/package_config.ml`

Blorp references:

- existing formatter files:
  - `compiler/blorp/src/stage_11_format/compiler_format.brp`
  - `compiler/blorp/src/stage_11_format/compiler_format_projection.brp`
- future shell/tool files:
  - `compiler_test_runner.brp`
  - `compiler_repl.brp`
  - `compiler_lsp*.brp`
  - `compiler_package*.brp`
  - `compiler_purify.brp`

Implementation steps:

- Port tools after the compiler library they depend on is Blorp-owned. Do not
  reimplement typecheck or parse paths inside tools.
- Keep formatter on the shared raw parse model.
- Port purify as a consumer of Blorp typecheck and purity analysis.
- Port the test runner by reducing work first:
  - shared compile artifacts,
  - suite batching,
  - no unnecessary subprocesses,
  - robust timeout/process cleanup.
- Port packages using the source-package dependency rules already used by the
  module graph:
  - manifest parsing,
  - package check,
  - BLAKE3 content hashing,
  - deterministic artifact pack/unpack,
  - cache install/fetch/vendor.
- Port LSP as a consumer of the shared parse/typecheck outputs:
  - diagnostics,
  - hover,
  - completion,
  - references,
  - definition/declaration/type-definition,
  - inlay hints,
  - formatting.
- Port REPL and line editor last unless they become necessary for dogfooding.
- Delete `compiler/bin/blorp_ocaml_host.ml` only after the Blorp executable
  handles all supported public commands and hidden bootstrap commands have
  retired.

Edge cases:

- LSP must support multiple open documents without session leakage.
- Test runner timeouts must clean up process groups and temp files.
- Doctest source remapping must preserve original file/line diagnostics.
- Package hashes are content-addressable over raw package file contents and
  relative paths; comments are included because they are file contents.
- Vendor/fetch must verify hash pins before making cache entries ready.
- Formatter must not require typecheck.

Tests:

- `compiler/test/test_lsp_*.ml` until LSP ports
- `compiler/test/test_package_*.ml`
- `compiler/test/test_doctest_remap.ml`
- `compiler/test/test_compiler_test_runner.ml`
- `compiler/blorp/tests/test_compiler_format.brp`
- `scripts/test doctest cli`
- manual package fetch/vendor tests with filesystem and local HTTP server

Deletion point:

- Delete OCaml tool modules after the corresponding public command uses Blorp
  and the OCaml tests have either moved to Blorp or become end-to-end CLI
  fixtures.

## Cross-Cutting Validation Matrix

Use this evidence before deleting OCaml:

| Slice | Required evidence |
| --- | --- |
| Parser/source model | Blorp parser tests, parser fixtures, formatter impact tests |
| Module graph | Blorp graph tests, package/import fixtures, no OCaml rediscovery |
| Type utilities/env | Direct unit parity for type/env/dim/refinement/builtin helpers |
| Typecheck/infer | Existing should-pass/should-fail fixtures and diagnostic text |
| CTFE/typed AST | Typed AST validation tests and compile-time fixture parity |
| Core lowering | Typed AST -> Core parity fixtures and generated-C audits |
| Core pass | Same Core JSON input, compare OCaml stage output to Blorp output |
| Ownership | Core parity, leak tests, resource/concurrency runtime tests |
| Emission | Generated C audit and runtime behavior |
| CLI/tooling | Exit codes, stdout/stderr, file artifacts, LSP protocol JSON |

Recommended local gate for small roadmap/code slices:

```bash
make
dune exec --profile=dev --root compiler -- ./test/run_tests.exe test <FocusedRegex>
./blorp test compiler/blorp/tests
git diff --check
```

Recommended gate before moving a production boundary:

```bash
scripts/test compiler-unit compiler cli
scripts/test runtime leak
```

Recommended gate before deleting OCaml Core or backend code:

```bash
scripts/test compiler-deep
BENCH_RUNS=5 BENCH_WARMUPS=1 bash benchmarks/bench.sh compiler_ast compiler_symbols compiler_emit
```

Recommended gate before removing OCaml shell/tooling:

```bash
scripts/test
make docker-premerge-gate
```

## Active Cleanup Notes

- `module_local_type_names_from_decls` was centralized as
  `Module_type_identity.local_type_names_from_decls`.
- Blorp module surfaces are the production owner for syntactic module
  imports, exports, and private names. OCaml AST scanners for those facts are
  private fallback helpers; typed semantic export conversion remains exposed
  while OCaml owns typecheck.
- The old `Types.validate_tensor_dims` alias was removed; callers use
  `Types.validate_array_dims`.
- Keep `Types.normalize_type_name` until legacy `Vector`/`Matrix` nominal
  paths are proven gone or represented explicitly.
- Keep `BLORP_FRONTEND_PARSER=ocaml` only while pinned external bootstrap
  binaries require the selector.
- Replace references to the old OCaml CLI filename with
  `compiler/bin/blorp_ocaml_host.ml`; the Blorp CLI executable is
  `compiler_cli_main.brp`, and the OCaml file is now only the private host
  shell.
- Prepared codegen renderers are typed-only. Do not reintroduce backend/list/
  tensor name/arity template registries.
- Older CLI-inward and frontend source-AST roadmaps are historical; use this
  roadmap as the current production-boundary source of truth.
- Align the opening pipeline diagram in `docs/ARCHITECTURE.md` with the current
  Blorp typecheck/CTFE production frontier. Its Core boundary is still correct,
  but its frontend summary still describes inference and typechecking as wholly
  OCaml-owned.
- Delete `language_surface.ml` when typecheck/LSP/tooling no longer need an
  OCaml facade over Blorp-owned language-surface data.
- Keep builtin effect/special-inference metadata and environment registration
  under a consistency test. A descriptor alone does not make a builtin name
  available to inference, and a module-scoped std declaration must not hide the
  corresponding builtin from source that has not imported that module.

## Definition Of Done

The migration is complete when:

- normal `check`, `compile`, `run`, `test`, `format`, `purify`, `package`,
  `repl`, and `lsp` commands execute through Blorp-owned compiler/tool code;
- OCaml no longer owns parser, module graph, typecheck, CTFE, typed AST, Core
  lowering, Core passes, ownership, C emission, CLI command execution, test
  running, package management, REPL, or LSP behavior;
- remaining OCaml, if any, is limited to a documented bootstrap wrapper with no
  compiler semantics;
- `scripts/test`, `compiler-deep`, leak/runtime gates, preview smoke commands,
  and Docker premerge gates pass.
