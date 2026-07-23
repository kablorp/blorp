# Frontend Module Surface Roadmap

Status: implemented roadmap, prepared 2026-07-02 and executed in the parser
frontier migration branch.

This roadmap covers the next contiguous frontend migration slice after
Blorp-owned parsing and typecheck-source AST finalization: move syntactic module
surface extraction into Blorp, then make OCaml consume that surface at the
single frontend bridge boundary.

The purpose is narrow. Blorp should identify a parsed module's imports,
exports, private names, and export source references. OCaml should still own
semantic typechecking, environment construction, overload resolution, and typed
semantic export conversion until those stages migrate.

## Current OCaml Behavior Studied

The current implementation is spread across module loading, session state, and
typechecking:

- `compiler/lib/modules.ml`
  - `extract_export_names`
  - `collect_syntactic_exports_from_ast_for_fallback`
  - `collect_private_names_from_ast_for_fallback`
  - `import_module_names_from_ast_for_fallback`
  - `semantic_exports_from_program`
  - `cache_parsed_module_source`
  - `load_preloaded_source_module`
  - `load_preloaded_module_graph`
  - `preload_module_import_closure`
  - `parse_module_source`
  - `load_imports`
- `compiler/lib/modules.mli`
  - `preloaded_parsed_source`
  - `load_module`
  - `load_imports`
  - `load_preloaded_module_graph`
  - `semantic_exports_from_program`
  - `private_names_for_import_diagnostics`
- `compiler/lib/session.ml`
  - `parsed_module_cache_entry`
  - `loaded_module`
  - `import_binding`
  - `module_origin`
- `compiler/lib/typecheck.ml`
  - `module_exports_for_import`
  - `process_import`
  - `semantic_export_program`
  - `semantic_export_decl`
  - `register_module_impls`
  - `register_ufcs_methods_for_type`
  - `check_private_type_leakage`
- `compiler/lib/compiler_blorp_bridge.ml`
  - `parsed_source`
  - `cli_frontend_graph_source`
  - `cli_frontend_module_graph`
  - `cli_frontend_graph_source_field`
  - `parse_source_response_field`

The OCaml syntactic export rules are:

- Public top-level function declarations export the function name.
- Public top-level variable declarations export the variable name.
- Public union declarations export the union type name.
- Public record declarations export the record type name.
- Public builtin type declarations export the type name.
- Public type aliases export the alias name.
- Public traits export the trait name and each trait method name.
- Public impl declarations export each method as a function export.
- Import declarations are not re-exported.
- Private declarations are not exported.
- Impl methods for a private trait are not exported.
- the private-name fallback applies the same extraction rules to the inner
  declaration of each private declaration so import errors can distinguish
  "missing" from "private" when no Blorp surface is available.

The typed import path is intentionally different. After a module has typed
declarations, `typecheck.ml` uses `semantic_export_program` and
`semantic_export_decl` before calling `Modules.semantic_exports_from_program`.
That semantic export layer carries inferred type information and must stay in
OCaml until typechecking moves.

## Design Target

Add a Blorp-owned syntactic module surface that is produced from
`ParsedProgram` after `finalize_typecheck_source_program`. The surface should be
encoded once in parser bridge artifacts and carried through the existing CLI
frontend module graph.

The surface describes symbols by stable references into the decoded legacy
`Ast.program`, not by duplicating full declarations. This matters while the
bridge is mixed-language: OCaml's parsed-AST decoder expands `import:` blocks
and `foreign:` blocks into multiple legacy declarations, so source references
must use decoded-AST indexes rather than raw parsed declaration-group indexes.
OCaml can recover the current `(name * Ast.decl)` export pairs from the parsed
program while later frontend stages remain OCaml-owned.

Implemented Blorp model in `compiler/blorp/src/stage_04_modules/compiler_module_surface.brp`:

```blorp
enum ModuleSurfaceSymbolKind:
    FunctionSurfaceSymbol
    VariableSurfaceSymbol
    TypeSurfaceSymbol
    RecordSurfaceSymbol
    TypeAliasSurfaceSymbol
    TraitSurfaceSymbol
    TraitMethodSurfaceSymbol
    ImplMethodSurfaceSymbol

union ModuleSurfaceSymbolSource:
    DeclSurfaceSource(Int)
    TraitMethodSurfaceSource(Int, Int)
    ImplMethodSurfaceSource(Int, Int)
    PrivateDeclSurfaceSource(Int)
    PrivateTraitMethodSurfaceSource(Int, Int)
    PrivateImplMethodSurfaceSource(Int, Int)

record ModuleSurfaceSymbol {
    name: String,
    kind: ModuleSurfaceSymbolKind,
    source: ModuleSurfaceSymbolSource
}

record ModuleSurface {
    module_name: String,
    import_paths: List[String],
    exports: List[ModuleSurfaceSymbol],
    private_names: List[ModuleSurfaceSymbol],
    private_traits: List[String]
}
```

The important invariant is that export source identity is explicit and never
guessed from names. The OCaml bridge validates that each decoded symbol's
name/kind/source matches the referenced AST declaration or method before the
surface enters the module cache.

## Checkpoint 1: Pin Current OCaml Semantics

Add focused OCaml unit tests before changing behavior.

Files:

- Add `compiler/test/test_module_surface.ml`
- Register it in `compiler/test/run_tests.ml` as `ModuleSurface`

Test helpers:

- `parse_program : string -> Ast.program`
- `export_names : Ast.program -> string list`
- `private_names : Ast.program -> string list`
- `import_paths : Ast.program -> string list`

Tests:

- `exports_public_declarations`
  - Covers `func`, `var`, union, `record`, `struct`, `type alias`, and builtin
    type declarations where possible through parser fixtures.
- `exports_trait_name_and_methods`
  - Verifies `trait Eq` exports `Eq` plus method names.
- `exports_impl_methods_as_functions`
  - Verifies an `impl` method appears as a function export.
- `private_declarations_are_not_exports`
  - Verifies private function/type/trait names are absent from exports.
- `private_names_track_inner_decl_surface`
  - Verifies private trait methods and private impl methods appear in
    the old private-name scanner. These direct scanner tests were removed in
    checkpoint 9 after the Blorp surface became the production owner.
- `private_trait_suppresses_impl_method_exports`
  - Verifies an impl for a private trait does not export methods.
- `import_blocks_flatten_module_paths`
  - Verifies the old AST import scanner sees each import path in an import
    block. These direct scanner tests were removed in checkpoint 9 after the
    Blorp surface became the production owner.

Commands:

```bash
dune exec --profile=dev --root compiler -- ./test/run_tests.exe test ModuleSurface
scripts/test compiler-unit
```

Acceptance:

- Tests document the current OCaml behavior exactly.
- No production behavior changes.

## Checkpoint 2: Add Blorp Module Surface Extraction

Implement the pure Blorp extractor over the parsed AST.

Files:

- Add `compiler/blorp/src/stage_04_modules/compiler_module_surface.brp`
- Add `compiler/blorp/tests/test_compiler_module_surface.brp`

Functions in `compiler_module_surface.brp`:

- `module_surface_symbol_kind_name(kind: ModuleSurfaceSymbolKind) -> String`
- `module_surface_symbol_source_kind(source: ModuleSurfaceSymbolSource) -> String`
- `module_surface_import_paths(program: ParsedProgram) -> List[String]`
- `module_surface_private_trait_names(program: ParsedProgram) -> List[String]`
- `module_surface_symbols_from_decl(
    decl: ParsedDecl,
    decl_index: Int,
    private_traits: List[String],
    visibility: ModuleSurfaceVisibility,
) -> List[ModuleSurfaceSymbol]`
- `module_surface_exports(program: ParsedProgram) -> List[ModuleSurfaceSymbol]`
- `module_surface_private_names(program: ParsedProgram) -> List[ModuleSurfaceSymbol]`
- `module_surface_for_program(program: ParsedProgram) -> ModuleSurface`

Implementation notes:

- Match the OCaml behavior from the syntactic export and private-name fallback
  helpers that were public before module surfaces became authoritative.
- Do not inspect JSON in this module. It should use `ParsedProgram` and
  `ParsedDecl` directly.
- Preserve declaration indexes and method indexes so OCaml can map symbols back
  to the exact parsed declaration.
- Treat `PrivateParsedDecl` as a visibility wrapper; do not make later code
  infer privacy from symbol names or source spans.
- Exclude `ImplParsedDecl` methods when `impl.trait_name.name` is in
  `private_traits`.

Tests in `test_compiler_module_surface.brp`:

- `test_exports_public_declarations`
- `test_exports_trait_name_and_methods`
- `test_exports_impl_methods`
- `test_private_declarations_are_not_exports`
- `test_private_names_track_inner_decl_surface`
- `test_private_trait_suppresses_impl_exports`
- `test_import_blocks_flatten_module_paths`
- `test_symbol_sources_are_stable_indexes`

Commands:

```bash
./blorp test --no-format compiler/blorp/tests/test_compiler_module_surface.brp
scripts/test compiler
```

Acceptance:

- Blorp extractor has parity with the pinned OCaml tests.
- The extractor is pure and independent of CLI graph resolution.

## Checkpoint 3: Encode Module Surface In Parser Bridge Artifacts

Make the parser bridge artifact carry a `module_surface` field for
typecheck-source parsed programs.

Files:

- Update `compiler/blorp/src/stage_03_parse/compiler_parser_bridge.brp`
- Add `compiler/blorp/src/stage_04_modules/compiler_module_surface_json.brp`
- Update `compiler/blorp/tests/test_compiler_bridge.brp`

Functions in `compiler_module_surface_json.brp`:

- `module_surface_symbol_kind_to_json(kind: ModuleSurfaceSymbolKind) -> JsonValue`
- `module_surface_symbol_source_to_json(source: ModuleSurfaceSymbolSource) -> JsonValue`
- `module_surface_symbol_to_json(symbol: ModuleSurfaceSymbol) -> JsonValue`
- Import paths are projected to `{ "module_path": ... }` objects at the JSON boundary.
- `module_surface_to_json(surface: ModuleSurface) -> JsonValue`

Parser bridge changes:

- In `parsed_source_artifact`, after `final_program` is selected, compute:
  - `surface = module_surface_for_program(final_program)`
  - append `("module_surface", module_surface_to_json(surface))`
- Keep `ast_phase` as the source of truth. The CLI frontend graph must still
  request `typecheck_source`.

Tests:

- `test_parse_source_typecheck_artifact_includes_module_surface`
- `test_parse_sources_typecheck_artifacts_include_module_surface`
- `test_parse_source_module_surface_uses_finalized_ast`

Commands:

```bash
./blorp test --no-format compiler/blorp/tests/test_compiler_bridge.brp
scripts/test compiler
```

Acceptance:

- Parser artifacts include a stable, structured `module_surface`.
- Raw parse artifacts may include the field if the implementation is simpler,
  but frontend module graph decoding should continue requiring
  `typecheck_source`.

## Checkpoint 4: Decode And Validate Surface In OCaml

Teach the OCaml bridge to decode module surfaces, but keep OCaml export
collection authoritative for this checkpoint.

Files:

- Add `compiler/lib/module_surface.ml`
- Add `compiler/lib/module_surface.mli`
- Update `compiler/lib/compiler_blorp_bridge.ml`
- Update `compiler/test/test_compiler_blorp_bridge.ml`

Types in `module_surface.ml`:

- `type symbol_kind`
- `type symbol_source`
- `type symbol`
- `type import`
- `type t`

Functions in `module_surface.ml`:

- `symbol_kind_of_string : string -> (symbol_kind, string) result`
- `symbol_kind_name : symbol_kind -> string`
- `source_decl_index : symbol_source -> int option`
- `export_names : t -> string list`
- `private_names : t -> string list`
- `import_module_names : t -> string list`
- `validate_against_program : Ast.program -> t -> (unit, string) result`

Bridge changes:

- Extend `Compiler_blorp_bridge.parsed_source` with:
  - `parsed_module_surface : Module_surface.t option`
- Add decoder helpers:
  - `module_surface_symbol_kind_field`
  - `module_surface_symbol_source_field`
  - `module_surface_symbol_field`
  - `module_surface_import_field`
  - `module_surface_field`
- In `parse_source_response_field`, decode optional `module_surface`.
- In `cli_frontend_graph_source_field`, require a `module_surface` when
  `ast_phase` is `typecheck_source`.

Tests in `test_compiler_blorp_bridge.ml`:

- `parse_source response decodes module surface`
- `parse_source response rejects invalid module surface symbol kind`
- `CLI run response decodes frontend graph module surface`
- `CLI run response rejects typecheck frontend graph source without module surface`

Commands:

```bash
dune exec --profile=dev --root compiler -- ./test/run_tests.exe test CompilerBlorpBridge
scripts/test compiler-unit
```

Acceptance:

- OCaml can decode the Blorp-owned surface.
- Existing compiler behavior is unchanged except stricter frontend graph
  validation for typecheck-source graph sources.

## Checkpoint 5: Store Surface In Parsed Module Cache

Preserve Blorp-produced surfaces in the module cache so module loading no longer
needs to rediscover syntactic facts from parsed declarations.

Files:

- Update `compiler/lib/session.ml`
- Update `compiler/lib/modules.mli`
- Update `compiler/lib/modules.ml`
- Update `compiler/lib/pipeline.ml`
- Update `compiler/test/test_session.ml`
- Update `compiler/test/test_pipeline.ml`

Data model changes:

- Add to `Session.parsed_module_cache_entry`:
  - `parsed_surface : Module_surface.t option`
- Add to `Modules.preloaded_parsed_source`:
  - `preload_surface : Module_surface.t option`
- Optionally add to `Session.loaded_module`:
  - `surface : Module_surface.t option`

Function changes:

- `cache_parsed_module_source`
  - Accept `?surface`.
  - Validate `surface` with `Module_surface.validate_against_program`.
  - Continue storing exports from the AST fallback for this checkpoint.
- `load_preloaded_source_module`
  - Pass decoded `parsed_module_surface` from graph sources into
    `cache_parsed_module_source`.
- `parse_module_source`
  - Pass decoded `parsed_module_surface` from `Compiler_blorp_bridge`.
- `apply_module_parse_batch_response`
  - Pass decoded surfaces for batch-loaded imports.
- `load_module_inner`
  - Preserve `surface` on the loaded module if the field is added.

Tests:

- `preloaded parsed source stores module surface`
- `trusted preloaded module graph preserves surface`
- `module parse batch stores decoded surface`
- `surface mismatch reports bridge validation error`

Commands:

```bash
dune exec --profile=dev --root compiler -- ./test/run_tests.exe test Session
dune exec --profile=dev --root compiler -- ./test/run_tests.exe test Pipeline
scripts/test compiler-unit compiler
```

Acceptance:

- Surfaces flow through all existing parse-cache paths.
- Mismatches fail close to the bridge/cache boundary with useful diagnostics.

## Checkpoint 6: Use Surface For Import Discovery

Status: implemented. Production frontend graph and module preload paths prefer
the Blorp module surface for import names; the remaining AST import scanner is
private and named as a fallback for non-surface callers.

Replace syntactic import scanning in module preload with the decoded surface.

Files:

- Update `compiler/lib/modules.ml`
- Update `compiler/test/test_session.ml`
- Update `compiler/test/test_pipeline.ml`

Function changes:

- Replace uses of the AST import scanner in parse-cache preload paths with:
  - `Module_surface.import_module_names surface` when a surface is available.
  - `import_module_names_from_ast_for_fallback decls` only as a fallback for
    non-surface callers.
- In `preload_module_import_closure`, prefer cached entry surfaces for import
  closure expansion.
- In `load_imports`, use the loaded module surface where available for direct
  import module names.

Tests:

- `preload import closure uses module surface imports`
- `surface import discovery matches AST fallback`
- `missing surface falls back to AST import scan`

Commands:

```bash
dune exec --profile=dev --root compiler -- ./test/run_tests.exe test Session
dune exec --profile=dev --root compiler -- ./test/run_tests.exe test Pipeline
scripts/test compiler-unit compiler cli
```

Acceptance:

- Normal frontend graph/module preload paths do not need to scan parsed AST for
  imports.
- Fallbacks are isolated and named as transitional.

## Checkpoint 7: Use Surface For Syntactic Exports

Status: implemented on 2026-07-06. Cached/preloaded modules derive syntactic
exports from `Module_surface` when present, private import diagnostics go
through a surface-backed helper with an explicit legacy fallback, and tests
cover surface export mapping for trait methods, impl methods, selective imports,
and private-name diagnostics.

Make loaded module syntactic exports come from the Blorp surface while keeping
typed semantic exports in OCaml.

Files:

- Update `compiler/lib/module_surface.ml`
- Update `compiler/lib/modules.ml`
- Update `compiler/lib/typecheck.ml` only where needed to keep behavior clear.
- Update `compiler/test/test_module_surface.ml`
- Update `compiler/test/test_session.ml`
- Update `compiler/test/test_pipeline.ml`

Functions in `module_surface.ml`:

- `exports_as_ast_pairs : Ast.program -> t -> (string * Ast.decl) list`
- `private_names_as_ast_pairs : Ast.program -> t -> (string * Ast.decl) list`
- `decl_for_symbol_source : Ast.program -> symbol_source -> Ast.decl option`
- `impl_method_export_decl : Ast.decl -> method_index:int -> Ast.decl option`

Function changes:

- `cache_parsed_module_source`
  - If `surface` is present, set `exports` with
    `Module_surface.exports_as_ast_pairs decls surface`.
  - If no surface is present, use
    `collect_syntactic_exports_from_ast_for_fallback decls`.
- private-name fallback
  - Keep the AST fallback private for non-surface paths.
  - Add a surface-backed private-name helper for module import diagnostics.
- `typecheck.ml`
  - Keep `module_exports_for_import` semantic behavior:
    - typed module available: use `semantic_export_program` and
      `Modules.semantic_exports_from_program`.
    - untyped module with surface-backed exports: use `m.exports`.

Tests:

- Existing selective import, alias import, trait import, constructor import, and
  private import tests must pass unchanged.
- Add:
  - `surface backed exports support selective function import`
  - `surface backed exports support selective trait method import`
  - `surface backed exports support impl method import`
  - `surface backed private names improve private import diagnostic`

Commands:

```bash
dune exec --profile=dev --root compiler -- ./test/run_tests.exe test ModuleSurface
dune exec --profile=dev --root compiler -- ./test/run_tests.exe test Pipeline
scripts/test compiler-unit compiler cli
```

Acceptance:

- Untyped module syntactic exports no longer require OCaml AST export scanning on
  normal bridge paths.
- Typed semantic exports remain unchanged and explicit.

## Checkpoint 8: Move CLI Source Graph Import Discovery To Surface

Status: implemented on 2026-07-06. `compiler_cli_source_graph.brp` discovers
imports from `module_surface.imports` and threads missing/malformed surface
errors through source-graph discovery. `test_compiler_cli.brp` now covers
surface-based discovery, missing `module_surface` rejection, and independence
from parsed-AST import-block shape.

Stop the Blorp CLI source graph from extracting imports through ad hoc parsed
AST JSON walking.

Files:

- Update `compiler/blorp/src/stage_12_cli/compiler_cli_source_graph.brp`
- Update `compiler/blorp/tests/test_compiler_cli.brp`

Function changes:

- Replace `parsed_source_import_paths` JSON AST scanning with a surface-backed
  reader:
  - `parsed_source_module_surface(source: CliParsedSourceFile) -> Result[JsonValue, String]`
  - `module_surface_import_paths_json(surface: JsonValue) -> List[String]`
  - `parsed_source_import_paths(source: CliParsedSourceFile) -> Result[List[String], String]`
- Thread the `Result` through:
  - `discover_import_sources_for_parsed_source`
  - `discover_import_sources_for_parsed_sources`
  - `discover_source_graph_imports`

Tests:

- `frontend graph discovers imports from module surface`
- `frontend graph rejects parsed source missing module surface`
- `frontend graph no longer depends on parsed_ast imports shape`

Commands:

```bash
./blorp test --no-format compiler/blorp/tests/test_compiler_cli.brp
scripts/test compiler cli
```

Acceptance:

- CLI source graph import discovery uses the new bridge surface, not parsed AST
  declaration JSON.
- Remaining JSON access is limited to the parser artifact boundary.

## Checkpoint 9: Delete Or Narrow OCaml Fallbacks

Status: implemented on 2026-07-06. OCaml syntactic import/export/private-name
scanners are no longer exposed as ordinary module APIs. The remaining AST
scanners are private fallback helpers for modules without a surface, and typed
semantic export conversion is exposed separately as
`semantic_exports_from_program` while OCaml still owns typed exports.

After normal compile/check/run/test paths use surfaces, remove duplicated OCaml
code where it is no longer needed.

Files:

- Update `compiler/lib/modules.ml`
- Update `compiler/lib/modules.mli`
- Update `compiler/lib/typecheck.ml`
- Update `compiler/test/test_module_surface.ml`

Deletion/narrowing plan:

- Keep typed semantic export conversion separate from syntactic module surface
  discovery via `semantic_exports_from_program`.
- Keep fallback helpers private and explicitly named:
  - `collect_syntactic_exports_from_ast_for_fallback`
  - `collect_private_names_from_ast_for_fallback`
  - `import_module_names_from_ast_for_fallback`
- Remove direct production uses of AST import scanning when a module surface is
  available.
- Keep the Pipeline parsed-entry boundary single-source: callers pass the
  Blorp-produced `preloaded_module_graph`, not a separate parsed-source preload
  list.
- Remove tests that only duplicate the Blorp surface suite and keep cross-bridge
  parity tests.

Commands:

```bash
scripts/test compiler-unit compiler cli
git diff --check
```

Acceptance:

- The remaining OCaml scanning is either semantic typed export conversion or a
  named fallback with tests.
- The production path has one clear surface owner: Blorp.

## Checkpoint 10: Documentation And Architecture Update

Status: implemented on 2026-07-06. The architecture docs, Blorp compiler
README, session comments, and module interface comments now describe the parser
artifact/module-surface contract and the remaining OCaml typed-export boundary.

Document the new bridge contract and update stale comments.

Files:

- Update `docs/ARCHITECTURE.md`
- Update `docs/BLORP_COMPILER_PORT_ROADMAP.md`
- Update `compiler/blorp/README.md`
- Update stale comments in `compiler/lib/session.ml`
- Update stale comments in `compiler/lib/modules.mli`

Content to document:

- Parser bridge artifacts include:
  - `ast_phase`
  - `parsed_ast`
  - `module_surface`
  - optional `comments`
- `module_surface` is syntactic and typecheck-source based.
- Typed semantic exports remain in the OCaml typechecker until the typechecker
  moves.
- CLI frontend graph sources must use `typecheck_source` artifacts with module
  surfaces.

Commands:

```bash
scripts/test compiler-unit compiler cli
git diff --check
```

Acceptance:

- The architecture docs match the bridge contract.
- There is no stale comment claiming loaded module declarations are raw
  pre-finalization AST.

## Full Verification Gate

Run the focused checks after each checkpoint and this broader gate before
merging:

```bash
make
./blorp test --no-format compiler/blorp/tests/test_compiler_module_surface.brp
./blorp test --no-format compiler/blorp/tests/test_compiler_bridge.brp
./blorp test --no-format compiler/blorp/tests/test_compiler_cli.brp
dune exec --profile=dev --root compiler -- ./test/run_tests.exe test ModuleSurface
dune exec --profile=dev --root compiler -- ./test/run_tests.exe test CompilerBlorpBridge
dune exec --profile=dev --root compiler -- ./test/run_tests.exe test Session
dune exec --profile=dev --root compiler -- ./test/run_tests.exe test Pipeline
scripts/test compiler-unit compiler cli
git diff --check
```

Use the full local gate if any change touches general module loading,
typechecking, or runtime-visible behavior:

```bash
scripts/test
```

## Risks And Guardrails

- Do not infer export identity from names alone. Use explicit declaration and
  method indexes in the surface.
- Do not move `semantic_export_program` yet. It depends on typed declarations
  and belongs to the typechecker migration slice.
- Do not make CLI source graph code understand the parsed AST declaration JSON
  more deeply. The goal is to reduce that dependency.
- Keep the bridge strict once Blorp emits the surface. Silent missing-surface
  fallback would make the migration hard to reason about.
- Keep transitional OCaml fallbacks named and tested. They should be easy to
  delete when the next frontend stage moves.

## Completion Definition

This roadmap is complete when:

- Blorp computes module imports, exports, private names, and private trait names
  from `ParsedProgram`.
- Parser bridge artifacts carry `module_surface`.
- OCaml decodes and validates that surface.
- Module parse cache and loaded module syntactic exports use the surface on
  normal frontend paths.
- CLI source graph import discovery uses the surface instead of parsed AST JSON
  declaration walking.
- The remaining OCaml export code is only for typed semantic exports or an
  explicitly named fallback.
