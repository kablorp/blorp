# Blorp Compiler

The production compiler is implemented in Blorp under `compiler/blorp/`.
Normal `check`, `compile`, `run`, `test`, formatter, linter, package, and LSP
commands form contiguous call graphs through that compiler.

## Quick Start

```bash
# Build the compiler from the repository root with the pinned bootstrap.
make

# Exercise compiler implementation and public tooling behavior.
scripts/test compiler-blorp compiler-tools

./blorp check myfile.brp
./blorp compile myfile.brp
./blorp run myfile.brp
```

## Directory Structure

```text
compiler/
├── blorp/        # Compiler implementation, tests, and benchmarks
├── lib/          # C runtime, declarations, headers, and native stubs
├── tests/        # Compiler-local fixtures
├── tools/        # Blorp build-time source generator
├── bootstrap.env # Immutable compiler bootstrap release pin
└── VERSION       # Compiler version source
```

The source generator under `compiler/tools/` is compiled by the pinned Blorp
bootstrap and is not a compiler stage. Production compiler tests live under
`compiler/blorp/tests/`; public behavior fixtures live under
`tests/test_compiler/`.

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
`compiler/blorp/src/stage_01_file_io/embedded_std.brp` and compiles the current
CLI with the immutable compiler resolved by `scripts/blorp-compiler-bootstrap`.
