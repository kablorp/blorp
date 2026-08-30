# Blorp Compiler

For the complete build, test, diagnostics, and profiling workflow, see the
[Developer Guide](../docs/DEVELOPMENT.md).

The production compiler is implemented in Blorp under `blorp/src/compiler/`.
Normal `check`, `compile`, `run`, `test`, formatter, linter, package, and LSP
commands form contiguous call graphs through that compiler.

## Quick Start

```bash
# Build the compiler from the repository root with the pinned bootstrap.
make

# Exercise compiler implementation and public tooling behavior.
scripts/test compiler-blorp compiler-tools

bin/blorp check myfile.brp
bin/blorp compile myfile.brp
bin/blorp run myfile.brp
```

## Directory Structure

```text
blorp/
├── src/compiler/ # Numbered production compiler stages
└── test/compiler/# Focused compiler tests and registered fixtures
compiler/
├── benchmarks/   # Compiler-specific benchmark entry points and fixtures
├── testdata/     # Compiler-local integration fixtures
├── lib/          # C runtime, declarations, headers, and native stubs
├── tools/        # Blorp build-time source generator
├── bootstrap.env # Immutable compiler bootstrap release pin
└── VERSION       # Compiler version source
```

The source generator under `compiler/tools/` is compiled by the pinned Blorp
bootstrap and is not a compiler stage. Production compiler tests and public
parser, inference, typecheck, and codegen fixtures live under
`blorp/test/compiler/`. Public format, purify, and lint fixtures remain under
`tests/test_compiler/` until those command owners are extracted.

## Source Stages

Production source lives under `blorp/src/compiler/` in numbered directories so the
filesystem mirrors the compilation frontier:

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
- `stage_12_cli`: CLI, package, execution, and public entry points.
- `stage_12_lsp`: language-server protocol, workspace, analysis, capabilities, and server
  integration.

Each stage should consume explicit products from the preceding stage. Shared
traversal belongs in the narrowest common stage; phase-specific rules remain
with the phase that owns their invariants. Do not reconstruct earlier semantic
facts from names, formatted source, or generated C.

The CLI surface is split by responsibility: argument parsing and planning,
source graph loading, compiler execution, artifact writing, package commands,
and LSP dispatch. Internal serialization exists for explicit diagnostic and
benchmark protocols; it is not a second compiler path.

## Pipeline

```text
source
  -> lex / parse / module graph
  -> infer / typecheck / CTFE
  -> Core lowering and optimization
  -> ownership and resource passes
  -> C emission
  -> host C compiler
  -> native executable
```

The exact pass order and ownership boundaries live in
[docs/ARCHITECTURE.md](../docs/ARCHITECTURE.md).

The default runtime is maintained in `compiler/lib/runtime.c`, with forward
declarations in `compiler/lib/runtime_decl.c`. `make` generates the canonical
embedded standard-library source at
`blorp/src/compiler/stage_01_file_io/embedded_std.brp` and compiles the current
CLI with the immutable compiler resolved by `scripts/blorp-compiler-bootstrap`.
