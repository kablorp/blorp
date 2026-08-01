# blorp Compiler

This directory contains the compiler implementation. Normal `check`,
`compile`, and `run` commands use the contiguous Blorp-owned frontend, Core
pipeline, and backend under `compiler/blorp/`. OCaml remains as a private host
for delegated test, package, REPL, LSP, and purify commands.

## Quick Start

```bash
# Build the compiler (from project root)
make

# Or build directly with dune
cd compiler && dune build

# Compile a .brp file
./blorp compile myfile.brp

# Type check only
./blorp check myfile.brp

# Compile and run
./blorp run myfile.brp

# Run the fast compiler-focused suites
scripts/test unit compiler
```

## Directory Structure

```
compiler/
├── bin/blorp_ocaml_host.ml   # Private host for remaining delegated commands
├── blorp/                    # Blorp-owned compiler/frontend/backend slices
├── lib/
│   ├── ast.ml                # Source AST definitions
│   ├── modules.ml            # Import resolution and module loading
│   ├── infer.ml              # Bidirectional type inference
│   ├── typecheck.ml          # Type checking, purity, exhaustiveness
│   ├── core_result_layout.ml # Remaining host-side Result layout facts
│   ├── core_type_layout.ml   # Remaining host-side ownership/layout facts
│   ├── core_stage.ml         # Shared Core stage names for CLI tooling
│   ├── codegen/              # Shared backend naming/type/builtin helpers
│   ├── lsp/                  # Language server implementation
│   ├── runtime.c             # Embedded default C runtime
│   ├── runtime_decl.c        # Runtime forward declarations
│   ├── runtime_raylib.c      # Optional Raylib runtime support
│   └── embedded_std.ml       # Generated from std/**/*.brp by make
├── test/                     # OCaml unit tests
├── tests/                    # Compiler-local fixture files
├── tools/                    # Build-time helper tools
└── dune-project              # Dune project configuration
```

## Compilation Pipeline

```
Source (.brp)
  → lex/parse
  → module graph + infer/typecheck + CTFE
  → Core lowering, desugaring, specialization, and resolution
  → DCE, Perceus, reuse, closure conversion, and final preparation
  → C emission
  → C compiler
  → native binary
```

The detailed Core stage list lives in
[docs/ARCHITECTURE.md](../docs/ARCHITECTURE.md). Keep that document as the
source of truth for pass order and backend boundaries.

## Development

```bash
# Build
cd compiler && dune build

# Run OCaml unit tests
cd compiler && dune runtest
```

The default runtime is maintained as C source in `compiler/lib/runtime.c` with
forward declarations in `compiler/lib/runtime_decl.c`. Generated programs either
embed that runtime or link a precompiled runtime object, depending on the caller
and test-runner path. `compiler/lib/embedded_std.ml` is generated from
`std/**/*.brp`; do not edit it directly.
