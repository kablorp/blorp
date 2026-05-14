# blorp Compiler

This directory contains the OCaml implementation of the blorp compiler.

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
scripts/run_tests.sh unit compiler
```

## Directory Structure

```
compiler/
├── bin/blorp.ml              # Main unified CLI
├── lib/
│   ├── ast.ml                # Source AST definitions
│   ├── lexer.mll             # OCamllex lexer
│   ├── parser.mly            # Menhir parser
│   ├── modules.ml            # Import resolution and module loading
│   ├── infer.ml              # Bidirectional type inference
│   ├── typecheck.ml          # Type checking, purity, exhaustiveness
│   ├── core.ml               # Core IR definitions
│   ├── core_pipeline.ml      # Core pipeline orchestration
│   ├── core_ownership.ml     # Ownership contracts for calls/intrinsics
│   ├── core_perceus.ml       # ARC insertion via CDup/CDrop
│   ├── core_reuse.ml         # Post-Perceus reuse rewrites
│   ├── core_codegen_prepare.ml # Final layout/boxing preparation
│   ├── core_emit*.ml         # Core → C emission helpers
│   ├── core_*.ml             # Other Core lowering, transforms, and layout passes
│   ├── codegen/              # Shared backend naming/type/builtin helpers
│   ├── fmt/                  # Formatter implementation
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
  → interpolation desugar + module loading
  → subscript desugar + infer/typecheck
  → Core lowering, FFI annotation, transforms, Perceus, reuse, closure conversion
  → Core codegen preparation and final invariants
  → C backend emission
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

# Check for type errors without full build
cd compiler && dune build @check

# Run OCaml unit tests
cd compiler && dune runtest
```

The default runtime is maintained as C source in `compiler/lib/runtime.c` with
forward declarations in `compiler/lib/runtime_decl.c`. Generated programs either
embed that runtime or link a precompiled runtime object, depending on the caller
and test-runner path. `compiler/lib/embedded_std.ml` is generated from
`std/**/*.brp`; do not edit it directly.
