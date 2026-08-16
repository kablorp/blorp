# Blorp Compiler Implementation

This directory contains the production compiler, command-line tools, language
server, focused implementation tests, and compiler benchmarks. The public
compiler is one contiguous Blorp program built from
`src/stage_12_cli/cli_main.brp`.

## Source Stages

Source code lives under `src/` in numbered directories so filesystem order
mirrors the compilation frontier:

- `stage_01_file_io`: source text, spans, embedded sources, and diagnostics.
- `stage_02_lex`: tokens, lexical diagnostics, and tokenization.
- `stage_03_parse`: parsed AST models and parsing.
- `stage_04_modules`: module loading, surfaces, visibility, and source catalogs.
- `stage_05_types`: semantic types, environments, builtins, and type policies.
- `stage_06_typecheck`: indexing, inference, checking, and typed graph services.
- `stage_07_ctfe`: compile-time IR, values, environments, and evaluation.
- `stage_08_core_lower`: typed frontend to Core lowering.
- `stage_09_core`: Core IR, optimization, ownership, and resource passes.
- `stage_10_backend`: C emission and code-generation renderers.
- `stage_11_format`: formatter projection and source formatting.
- `stage_12_cli`: CLI, package, LSP, execution, and public entry points.
- `stage_99_meta`: compiler inventory metadata that is not a pipeline stage.

The exact production pass order and phase contracts are documented in
`docs/ARCHITECTURE.md`.

## Ownership

Each stage should consume explicit products from the preceding stage. Do not
reconstruct earlier semantic facts from names, formatted source, or generated C.
Shared traversal belongs in the narrowest common stage; phase-specific rules
remain with the phase that owns their invariants.

The CLI surface is split by responsibility: argument parsing and planning,
source graph loading, compiler execution, artifact writing, package commands,
and LSP dispatch. Internal serialization exists for explicit diagnostic and
benchmark protocols; it is not a second compiler path.

Renderer argument bundles use records where they carry managed compiler values.
Do not mechanically convert them to structs unless every field has a valid
stack representation.

## Tests And Benchmarks

Focused TestSuite coverage lives under `tests/` and runs with:

```bash
scripts/test compiler-blorp
```

Public parser, typechecking, code-generation, formatter, purify, and lint
fixtures live under `tests/test_compiler/` at the repository root. Standalone
compiler benchmark entry points live under `benchmarks/`; they may import
production modules but are not shipped as compiler workers.

New compiler work should update the production path directly, preserve stage
boundaries, and add focused coverage at the owning layer.
