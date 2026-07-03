# Blorp Compiler Port Roadmap

Status checked against code on 2026-07-03.

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
Blorp and ends in Blorp, with an OCaml middle:

```text
Blorp CLI planning / source graph discovery / source reads / parse
  -> JSON frontend module graph
  -> OCaml command shell / module validation / typecheck / CTFE
  -> OCaml typed AST -> Core lowering
  -> OCaml Core pipeline through Perceus
  -> JSON post-Perceus Core
  -> Blorp reuse / closure / resource / fairness / prepare / prepared reuse
  -> Blorp C artifact emission
  -> OCaml artifact writing / C compiler invocation
```

Current source-frontier Blorp files:

- `compiler/blorp/compiler_cli.brp`
- `compiler/blorp/compiler_cli_args.brp`
- `compiler/blorp/compiler_cli_plan.brp`
- `compiler/blorp/compiler_cli_source_graph.brp`
- `compiler/blorp/compiler_cli_artifact_json.brp`
- `compiler/blorp/compiler_source.brp`
- `compiler/blorp/compiler_lexer.brp`
- `compiler/blorp/compiler_parser.brp`
- `compiler/blorp/compiler_parsed_ast.brp`
- `compiler/blorp/compiler_parsed_ast_json.brp`
- `compiler/blorp/compiler_source_ast_finalize.brp`
- `compiler/blorp/compiler_module_surface.brp`
- `compiler/blorp/compiler_module_surface_json.brp`

Current backend-tail Blorp files:

- `compiler/blorp/compiler_core_json.brp`
- `compiler/blorp/compiler_core_pipeline.brp`
- `compiler/blorp/compiler_core_consume_specialize.brp`
- `compiler/blorp/compiler_core_ownership.brp`
- `compiler/blorp/compiler_core_perceus.brp`
- `compiler/blorp/compiler_core_reuse.brp`
- `compiler/blorp/compiler_core_closure.brp`
- `compiler/blorp/compiler_core_resource.brp`
- `compiler/blorp/compiler_core_fairness.brp`
- `compiler/blorp/compiler_core_prepare.brp`
- `compiler/blorp/compiler_core_emit.brp`

Current OCaml bridge and orchestration files:

- `compiler/bin/blorp.ml`
- `compiler/lib/compiler_blorp_bridge.ml`
- `compiler/lib/modules.ml`
- `compiler/lib/pipeline.ml`
- `compiler/lib/typecheck.ml`
- `compiler/lib/infer.ml`
- `compiler/lib/typed_ast.ml`
- `compiler/lib/core_lower.ml`
- `compiler/lib/core_pipeline.ml`
- `compiler/lib/core_emit_blorp_c.ml`

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

OCaml references:

- `compiler/lib/compiler_blorp_bridge.ml`
- `compiler/lib/core_emit_blorp_c.ml`
- `compiler/bin/blorp.ml`
- `compiler/lib/modules.ml`
- `compiler/lib/core_pipeline.ml`
- `compiler/lib/language_surface.ml`
- `compiler/lib/core_trait_resolve.ml`
- `compiler/lib/core_profile.ml`

Blorp references:

- `compiler/blorp/compiler_bridge.brp`
- `compiler/blorp/compiler_bridge_protocol.brp`
- `compiler/blorp/compiler_bridge_cli.brp`
- `compiler/blorp/ocaml_port_inventory.tsv`

Implementation steps:

- Maintain an allowlist of OCaml files that may call
  `Compiler_blorp_bridge`. Classify each call as production boundary,
  command perimeter, bootstrap exception, observability exception, or
  transitional table/diagnostic exception.
- Keep bridge request/response handling in `compiler_blorp_bridge.ml`.
  Compiler semantics should live on one side of the boundary, not in the
  bridge client.
- Keep `emit_post_closure_c` and `run_core_pipeline` as the backend-tail
  boundary while OCaml still owns earlier Core stages.
- Keep `parse_source` and `parse_sources` as the frontend parser boundary while
  OCaml still consumes parsed AST values.
- Delete snippet-style bridge renderers once their OCaml callers disappear.
- Keep `BLORP_COMPILER_RENDERER_HELPER=1` limited to static bootstrap table
  support.

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
artifact may still be decoded as protocol compatibility, but the shell rejects
it for normal source execution.

OCaml references:

- `compiler/bin/blorp.ml`
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
  - `typecheck_only_typed_parsed`
  - `compile_parsed`
  - `compile_loaded_program`

Blorp references:

- `compiler/blorp/compiler_cli.brp`
- `compiler/blorp/compiler_cli_args.brp`
- `compiler/blorp/compiler_cli_plan.brp`
- `compiler/blorp/compiler_cli_source_graph.brp`
- `compiler/blorp/compiler_cli_artifact_json.brp`

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
- Do not reintroduce `frontend_options` execution for source commands. If the
  bridge decoder must accept that artifact for pinned bootstrap compatibility,
  reject it at the OCaml shell boundary.

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
  enters `Pipeline.typecheck_only_typed_parsed` or `Pipeline.compile_parsed`.

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
- `compiler/lib/parse_comments.ml`
- `compiler/lib/module_surface.ml`
  - `validate_against_program`
  - `exports_as_ast_pairs`
  - `private_names_as_ast_pairs`
- `compiler/lib/modules.ml`
  - `parse_source_artifact_with_blorp_bridge`
  - `parse_source_with_blorp_bridge`
  - `parse_source_at_phase`
  - `parse_typecheck_source`

Blorp references:

- `compiler/blorp/compiler_token.brp`
- `compiler/blorp/compiler_lexer.brp`
- `compiler/blorp/compiler_parser.brp`
- `compiler/blorp/compiler_parsed_ast.brp`
- `compiler/blorp/compiler_parsed_ast_json.brp`
- `compiler/blorp/compiler_parse_diagnostic.brp`
- `compiler/blorp/compiler_source_ast_finalize.brp`
- `compiler/blorp/compiler_module_surface.brp`
- `compiler/blorp/compiler_module_surface_json.brp`
- `compiler/blorp/compiler_format.brp`
- `compiler/blorp/compiler_format_projection.brp`

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

- Delete `parsed_ast_json.ml`, `parse_comments.ml`, and OCaml module-surface
  validation once no OCaml stage consumes parsed AST JSON.

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

Remaining compatibility: `Modules.load_imports` and the old parse-cache preload
helpers still exist for non-graph callers, LSP/tooling paths that have not been
ported to the source-command graph contract, and embedded std/bootstrap support.
Those are deletion targets for later checkpoints, not part of the production
source-command handoff.

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
    - `preload_parsed_sources`
    - `preload_module_import_closure`
    - `preload_module_parse_cache_with_blorp_bridge`
    - `import_preload_candidates`
  - caches:
    - `cache_parsed_module_source`
    - `cached_parse_entry`
    - `cached_filesystem_entry_is_current`
    - `prune_parse_cache_to_loaded_modules`
  - legacy syntactic exports:
    - `collect_exports`
    - `collect_private_names`
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

- `compiler/blorp/compiler_cli_source_graph.brp`
- `compiler/blorp/compiler_module_surface.brp`
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
  `Pipeline.compile_parsed` and `Pipeline.typecheck_only_typed_parsed` consume
  a Blorp-validated module graph for every production/tooling caller and no
  longer need `Modules.load_imports` for non-graph entry points.

## Checkpoint 4: Diagnostics, Session, Types, Env, And Builtins

Goal: port the pure substrate needed by typecheck before moving declaration or
expression inference.

Status: complete for the pure frontend substrate. Production typecheck and
inference still switch over in later checkpoints, but the checkpoint-4 data
models and helper APIs now exist in Blorp with focused tests.
`compiler/blorp/language_surface_manifest.brp` remains the source of truth for
source-language keyword and prelude UFCS tables, while Dune generates
`Language_surface_data` for OCaml consumers at build time. This removes the
runtime bridge call from `compiler/lib/language_surface.ml` and keeps the
renderer-helper bootstrap rows on the same generated data.
`compiler/blorp/compiler_diagnostic.brp`
defines pure Rust-style diagnostic data and rendering over explicit source text,
with parity tests for tab padding, synthetic locations, notes/help, and
secondary labels. The semantic type slice is in place:
`compiler/blorp/compiler_type.brp` defines the Blorp `CompilerType` model plus
pure display, structural equality, tensor-name normalization, array/tensor
decomposition, numeric predicates, dimension-form predicates, type-parameter
bound stripping, occurs checks, cycle-safe substitution, and dimension
arithmetic normalization. It also carries the first Blorp-owned array/tensor
dimension validator, including non-positive concrete dimension checks,
dimension-argument validation, and variadic-dimension placement rules. It
also has the first explicit Blorp context model in
`compiler/blorp/compiler_context.brp`, covering module-origin policy, type-home
ambiguity, resource cleanup entries, trait-home conflict reporting, definition
ids, meta origins/bindings, head resolution, zonking, and Core lowering
counters as ordinary values. The context model now also owns the baseline
unifier: meta binding with occurs checks, one-way and symmetric type-variable
binding, explicit type-parameter binding, rigid variables, function purity,
tuple/array/tensor matching, range/Int compatibility, LiteralString/String
compatibility, and dimension arithmetic through the canonical solver in
`compiler/blorp/compiler_dim_solver.brp`. That solver ports the
sum-of-products normalization from `compiler/lib/dim_solver.ml`, including
commutativity/associativity/distributivity, exact constant division,
contradictions, and simple meta or `#` dimension-variable bindings. It
also now includes `compiler/blorp/compiler_type_widening.brp`, which ports the
explicit value-slot widening decisions from `compiler/lib/type_widening.ml` for
mutable bindings, arguments, collection elements, bitwise operands, method
receivers, and numeric operands. The pure
range/subscript proof substrate is also now covered by
`compiler/blorp/compiler_refinement.brp`, which ports collection/dimension
identities, range upper bounds, subscript bounds, offset checks, proof sources,
binding/expr proof payloads, proof-env replacement, and branch narrowing. The
first module-loading identity helper is also in place:
`compiler/blorp/compiler_module_type_identity.brp` ports local type-name
collection from parsed declarations, including private-wrapper transparency and
sorted unique output for records, unions/enums, and type aliases. Structured
generic-parameter helpers are now also ported in
`compiler/blorp/compiler_generic_params.brp`, covering trait refs, bounded type
params, parser-source spelling, and param-name extraction. The first
type-policy metadata slice is also available in
`compiler/blorp/compiler_type_metadata.brp`, covering recursion storage,
primitive homes, struct scalar fields, native operator fast paths, builtin
to-string fallbacks, and constructor-space classification. The remaining
checkpoint-4 pieces are also now present: `compiler/blorp/compiler_env.brp`
ports the lexical environment, symbols, aliases, type/record/constructor lookup,
trait functions, trait defs, impls, overloads, UFCS methods, resource policies,
proof metadata attachment points, and alias/nominal-dimension resolution;
`compiler/blorp/compiler_builtins.brp` ports compiler-visible builtin metadata
and core Env population; and `compiler/blorp/compiler_type_resolution.brp`
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

- `compiler/blorp/language_surface_manifest.brp`
- `compiler/blorp/compiler_type.brp`
- `compiler/blorp/compiler_context.brp`
- `compiler/blorp/compiler_dim_solver.brp`
- `compiler/blorp/compiler_type_widening.brp`
- `compiler/blorp/compiler_refinement.brp`
- `compiler/blorp/compiler_module_type_identity.brp`
- `compiler/blorp/compiler_generic_params.brp`
- `compiler/blorp/compiler_type_metadata.brp`
- `compiler/blorp/compiler_env.brp`
- `compiler/blorp/compiler_builtins.brp`
- `compiler/blorp/compiler_type_resolution.brp`
- `compiler/blorp/compiler_diagnostic.brp`

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
`compiler/blorp/compiler_typecheck_state.brp`, with focused tests for
module-origin policy, import binding deduplication, module-alias/selective
import namespace collisions, known type/resource pre-scan state, type-home
precedence, callable ids, private impl tracking, type-home matching, and private
impl conflict lookup. The top-level pre-scan is also in place in
`compiler/blorp/compiler_typecheck_decl.brp`, covering known type/resource
names, constructor names, function/variable/trait namespace entries,
foreign-block functions, and private wrappers. Pure import registration is in
place in `compiler/blorp/compiler_imports.brp`, covering qualified aliases,
selective and renamed imports, private/missing symbol diagnostics, duplicate
local-name diagnostics, import bindings, and imported type homes over Blorp
module surfaces. Source type-expression projection is in place in
`compiler/blorp/compiler_typecheck_types.brp`. Semantic
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

- `compiler/blorp/compiler_typecheck_state.brp`
- `compiler/blorp/compiler_typecheck_types.brp`
- `compiler/blorp/compiler_typecheck_decl.brp`
- `compiler/blorp/compiler_imports.brp`

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
  instances, private impl instances, exact source-level coherence conflicts, and
  orphan diagnostics when the trait and type homes are both known. Full impl
  method validation and default-method synthesis remain checkpoint 6 work,
  matching the OCaml second-pass boundary.
- Port orphan/coherence checks and cross-module coherence over source-level
  impls. Source-module orphan and exact duplicate checks are implemented for
  first-pass registration. Whole-graph cross-module coherence remains tied to
  typed loaded-module signatures.
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
- `compiler/blorp/tests/test_zz_compiler_typecheck_resource_decl.brp`
- `compiler/blorp/tests/test_compiler_imports.brp`

Deletion point:

- Delete OCaml first-pass declaration registration only after Blorp can
  typecheck loaded module signatures and produce the same env/import binding
  facts for the OCaml second pass or the Blorp second pass.

## Checkpoint 6: Expression Inference And Typecheck Second Pass

Goal: port expression inference, function/global body checking, purity,
tailrec, resources, concurrency, and final typed AST construction.

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

- future `compiler_infer.brp`
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
- Port compile-time validation that rejects startup function calls outside
  `main`.
- Port error text and help for user-facing type errors before deleting OCaml
  diagnostics.

Edge cases:

- Local mutation is allowed in pure functions; impure calls are not.
- Closures cannot capture mutable variables.
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
- `compiler/lib/ctfe*.ml`
  - `ctfe.ml`
  - `ctfe_context.ml`
  - `ctfe_env.ml`
  - `ctfe_error.ml`
  - `ctfe_intrinsic.ml`
  - `ctfe_ir.ml`
  - `ctfe_materialize.ml`
  - `ctfe_operator.ml`
  - `ctfe_pattern.ml`
  - `ctfe_std_eval.ml`
  - `ctfe_value.ml`
  - `ctfe_value_ops.ml`
- `compiler/lib/type_metadata_format.ml`
- `compiler/lib/operation_result_metadata.ml`

Blorp references:

- future `compiler_typed_ast.brp`
- future `compiler_typed_ast_json.brp`
- future `compiler_ctfe*.brp`
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

Edge cases:

- Compile-time values must preserve value semantics and no shared mutable
  state.
- CTFE must not evaluate impure functions.
- Global constants over records, generic records/unions, tensors, lists,
  strings, tuples, and float16/float32 values must remain materializable.
- Typed AST output must preserve callable ids and import bindings for Core
  flattening and call resolution.

Tests:

- `compiler/test/test_typed_ast.ml`
- `compiler/test/test_typed_ast_debug.ml`
- `compiler/test/test_ctfe_*.ml`
- `tests/test_compiler/typecheck/should_pass/compile_time_*.brp`
- `tests/test_compiler/codegen_audit/should_pass/global_constant_*.brp`
- New Blorp typed AST and CTFE tests.

Deletion point:

- Delete OCaml typed AST construction and CTFE after Blorp typed-program output
  is authoritative and Core lowering consumes it.

## Checkpoint 8: Core Lowering, Flattening, FFI Boundary, And Layout Setup

Goal: move the boundary from typed AST to lowered Core.

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

- future `compiler_core_lower.brp`
- future `compiler_core_flatten.brp`
- future `compiler_core_ffi_boundary.brp`
- future `compiler_core_list_layout.brp`
- existing `compiler_core_json.brp`

Implementation steps:

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

Edge cases:

- `EQuestionBind` lowering needs block continuation context.
- `with` resource blocks need cleanup metadata from typecheck.
- `Duration` timeouts must round microseconds up to milliseconds.
- Loop-view producers (`indices`, `enumerate`, `enumerate2`, `windows`) are
  internal and must only lower under `for`/tuple-for.
- Module alias calls use `TyNamed "Module"` sentinel today; replace with an
  explicit typed AST/Core representation when feasible.
- Callable ids from inference must remain authoritative over stale mangled
  names.
- Subscript reads should already be calls; subscript assignment should already
  be typechecked into an explicit call.
- Foreign string/bytes copy/no-copy metadata must be preserved.

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
- `compiler/lib/core_dce.ml`
  - `prune_unreachable_declarations`

Blorp references:

- existing `compiler_core_traverse.brp`
- existing `compiler_core_json.brp`
- future `compiler_core_debug.brp`
- future `compiler_core_desugar.brp`
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
- future `compiler_core_dce.brp`

Implementation steps:

- Port stages in exact `run_core_passes` order. Move the production boundary
  left by one stage or a tightly coupled pair only after parity passes.
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
- DCE must retain backend-required artifacts, destructors, constructors, enum
  helpers, stack option/result layouts, hash callbacks, tasks, and global
  initializers.

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
  - `compiler/test/test_core_dce.ml`
- Add missing focused coverage for `Core_debug.lower_program` when that slice
  ports.
- `tests/test_compiler/codegen_audit/should_pass/core_dce_*.brp`
- Blorp stage parity tests under `compiler/blorp/tests`.

Deletion point:

- Delete each OCaml Core pass after the production boundary moves before that
  pass and stage observation reads the Blorp result.

## Checkpoint 10: Ownership, Perceus, Backend Tail, And Emission

Goal: finish the already-started backend ownership migration and remove the
post-Perceus OCaml boundary.

Status: `Core_consume_specialize` is partially ported, ownership contracts are
partially ported, Perceus is partially ported, and the post-Perceus tail through
C artifact emission is Blorp-owned for the supported route.

OCaml references:

- `compiler/lib/core_consume_specialize.ml`
  - `rewrite_program`
- `compiler/lib/core_ownership.ml`
- `compiler/lib/core_perceus.ml`
  - `insert_drops_program`
  - branch/match ownership joins
  - loop/repeated-context consume protection
  - borrowed-result retention
  - final drop insertion
  - checker diagnostics
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

- `compiler/blorp/compiler_core_consume_specialize.brp`
- `compiler/blorp/compiler_core_ownership.brp`
- `compiler/blorp/compiler_core_perceus.brp`
- `compiler/blorp/compiler_core_reuse.brp`
- `compiler/blorp/compiler_core_closure.brp`
- `compiler/blorp/compiler_core_resource.brp`
- `compiler/blorp/compiler_core_fairness.brp`
- `compiler/blorp/compiler_core_prepare.brp`
- `compiler/blorp/compiler_core_emit.brp`
- `compiler/blorp/compiler_core_emit_type_layout.brp`
- `compiler/blorp/codegen_*_renderer.brp`

Implementation steps:

- Finish Perceus in Blorp before moving the production boundary left of
  Perceus:
  - branch balancing,
  - match decision tree balancing,
  - loop consume protection,
  - concurrent ownership handling,
  - borrowed-result retention,
  - aggregate member retention,
  - assignment alias retention,
  - consumed parameter balancing,
  - final drop insertion,
  - checker diagnostics.
- Keep consume-specialize before Perceus and preserve the current direct clone
  eligibility rules.
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

- `compiler/test/test_core_consume_specialize.ml`
- `compiler/test/test_core_ownership.ml`
- `compiler/test/test_core_perceus.ml`
- `compiler/blorp/tests/test_compiler_core_consume_specialize.brp`
- `compiler/blorp/tests/test_compiler_core_ownership.brp`
- `compiler/blorp/tests/test_compiler_core_perceus.brp`
- `compiler/blorp/tests/test_compiler_core_emit*.brp`
- `scripts/test leak`
- `tests/test_compiler/codegen_audit`
- runtime resource/concurrency tests under `tests/test_blorp`.

Deletion point:

- Delete OCaml consume-specialize, ownership, Perceus, layout projection, and
  Core-to-JSON projection modules after the full Core pipeline runs in Blorp
  before ownership insertion.

## Checkpoint 11: Artifact Writing, Host C Invocation, Runtime Packaging

Goal: keep the compiler semantics in Blorp while isolating the remaining
impure shell responsibilities.

OCaml references:

- `compiler/bin/blorp.ml`
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

- `compiler/blorp/compiler_artifact_json.brp`
- `compiler/blorp/compiler_core_emit.brp`
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

- `compiler/bin/blorp.ml`
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
  - `compiler/blorp/compiler_format.brp`
  - `compiler/blorp/compiler_format_projection.brp`
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
- Delete `compiler/bin/blorp.ml` only after an equivalent Blorp CLI handles all
  supported public commands and hidden bootstrap commands have retired.

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
- The old `Types.validate_tensor_dims` alias was removed; callers use
  `Types.validate_array_dims`.
- Keep `Types.normalize_type_name` until legacy `Vector`/`Matrix` nominal
  paths are proven gone or represented explicitly.
- Keep `BLORP_FRONTEND_PARSER=ocaml` only while pinned external bootstrap
  binaries require the selector.
- Delete `language_surface.ml` when typecheck/LSP/tooling no longer need an
  OCaml facade over Blorp-owned language-surface data.

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
