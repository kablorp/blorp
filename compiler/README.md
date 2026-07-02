# blorp Compiler

This directory contains the compiler implementation. The frontend, middle
pipeline, and runtime shell are still largely OCaml, while the formatter,
bridge, and growing backend-tail slices live in `compiler/blorp/`.

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
├── bin/blorp.ml              # Main unified CLI
├── blorp/                    # Blorp-owned compiler/frontend/backend slices
├── lib/
│   ├── ast.ml                # Source AST definitions
│   ├── modules.ml            # Import resolution and module loading
│   ├── infer.ml              # Bidirectional type inference
│   ├── typecheck.ml          # Type checking, purity, exhaustiveness
│   ├── core.ml               # Core IR definitions
│   ├── core_pipeline.ml      # Core pipeline orchestration
│   ├── core_ownership.ml     # Ownership contracts for calls/intrinsics
│   ├── core_perceus.ml       # ARC insertion via CDup/CDrop
│   ├── core_closure.ml       # Function-reference eta adapters
│   ├── core_codegen_prepare.ml # Final layout/boxing helper logic
│   ├── core_emit_blorp_c.ml  # Bridge projection for Blorp-owned C emission
│   ├── core_*.ml             # Other Core lowering, transforms, and layout passes
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
  → interpolation desugar + module loading
  → subscript desugar + infer/typecheck
  → Core lowering, FFI annotation, transforms, Perceus
  → Blorp-owned reuse, closure conversion, final preparation, and C emission
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
