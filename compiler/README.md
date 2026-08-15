# blorp Compiler

This directory contains the compiler implementation. Normal `check`,
`compile`, and `run` commands use the contiguous Blorp-owned frontend, Core
pipeline, and backend under `compiler/blorp/`. Purify and test execution also
run entirely in Blorp. The production LSP is Blorp-owned. OCaml remains as a
private host for package commands and compiler-bridge preparation.

## Quick Start

```bash
# Build the compiler (from project root)
make

# Or build directly with dune
(cd compiler && dune build)

# Compile a .brp file
./blorp compile myfile.brp

# Type check only
./blorp check myfile.brp

# Compile and run
./blorp run myfile.brp

# Run the compiler-owned and public tool fixture suites
scripts/test compiler-blorp compiler-tools
```

## Directory Structure

```
compiler/
├── bin/blorp_ocaml_host.ml   # Private host for remaining delegated commands
├── blorp/                    # Blorp-owned compiler slices and TestSuites
├── lib/
│   ├── ast.ml                # Source AST definitions
│   ├── modules.ml            # Import resolution and module loading
│   ├── infer.ml              # Bidirectional type inference
│   ├── typecheck.ml          # Type checking, purity, exhaustiveness
│   ├── core_result_layout.ml # Remaining host-side Result layout facts
│   ├── core_type_layout.ml   # Remaining host-side ownership/layout facts
│   ├── codegen/              # Remaining shared compiler registries/helpers
│   ├── compiler_json.ml      # Generic JSON codec for private bridges
│   ├── runtime.c             # Embedded default C runtime
│   ├── runtime_decl.c        # Runtime forward declarations
│   ├── runtime_raylib.c      # Optional Raylib runtime support
│   └── embedded_std.ml       # Generated from std/**/*.brp by make
├── test/                     # Frozen, non-executable OCaml test archive
├── tests/                    # Compiler-local fixture files
├── tools/                    # Build-time helper tools
└── dune-project              # Dune project configuration
```

The OCaml library is private compiler-host implementation. It is not an
installed compatibility API; source files and interfaces may be removed as
their responsibilities move into the self-hosted compiler.

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
(cd compiler && dune build)

# Run production compiler implementation tests
scripts/test compiler-blorp compiler-tools
```

The default runtime is maintained as C source in `compiler/lib/runtime.c` with
forward declarations in `compiler/lib/runtime_decl.c`. Generated programs either
embed that runtime or link a precompiled runtime object, depending on the caller
and test-runner path. `compiler/lib/embedded_std.ml` is generated from
`std/**/*.brp`; do not edit it directly.
