# blorp Compiler Architecture

## Compilation Pipeline

```
Source (.brp)
    |
    v
+--------+
| Lexer  |  Tokenization (compiler/blorp/src/stage_02_lex/compiler_lexer.brp)
+--------+
    |
    v
+--------+
| Parser |  AST construction (compiler/blorp/src/stage_03_parse/compiler_parser.brp)
+--------+
    |
    v
+---------+
| Modules |  Import resolution and module loading
|         |  (compiler/blorp/src/stage_04_modules/)
+---------+
    |
    v
+-----------+
| Frontend  |  Blorp source-AST finalization, inference, and typechecking
| Typing    |  (stage_03_parse, stage_05_types, stage_06_typecheck)
+-----------+
    |
    v
+----------------+
| Typed AST JSON |  Temporary production bridge into the OCaml Core pipeline
+----------------+
    |
    v
+------------+
| Core IR    |  OCaml lowering and early/middle transforms, then the Core JSON
| pipeline   |  handoff into the supported Blorp-owned backend tail
+------------+
    |
    v
+------------+
| C Emission |  Blorp C artifact path; unsupported Core is a compiler error
+------------+
    |
    v
+------------+
| C Compiler |  clang/gcc with optimization
+------------+
    |
    v
Native Binary
```

### Core IR Pipeline

Codegen is a pipeline over a typed intermediate representation (`core.ml`).
Most stages read Core IR and produce Core IR; final codegen preparation makes
late representation choices explicit in Core before C artifact emission. The
Core path is the compiler's codegen path.

During the OCaml-to-Blorp port, the production route first decodes the
Blorp-owned typed-program artifact into the remaining OCaml Core pipeline. It
then crosses the Core JSON bridge after OCaml specialization and
function-reference adaptation. Checkpoint 8 in
`docs/BLORP_COMPILER_PORT_ROADMAP.md` removes the first temporary boundary by
making Blorp Core lowering authoritative. On the current backend route,
`compiler/blorp/src/stage_09_core/compiler_core_dce.brp`,
`compiler/blorp/src/stage_09_core/compiler_core_consume_specialize.brp`,
`compiler/blorp/src/stage_09_core/compiler_core_perceus.brp`,
`compiler/blorp/src/stage_09_core/compiler_core_reuse.brp`,
`compiler/blorp/src/stage_09_core/compiler_core_closure.brp`,
`compiler/blorp/src/stage_09_core/compiler_core_resource.brp`,
`compiler/blorp/src/stage_09_core/compiler_core_fairness.brp`,
`compiler/blorp/src/stage_09_core/compiler_core_prepare.brp`, and
`compiler/blorp/src/stage_10_backend/compiler_core_emit.brp` own the contiguous tail through C
artifact generation. CLI `dce`/`consume-specialize`/`perceus`/`reuse`/`closure`/`final`
dumps and stops observe the Blorp-owned tail as Core JSON through the bridge;
OCaml program callbacks stop at the pre-DCE handoff. C artifact emission is
owned by the Blorp backend bridge.

```
Typed AST
    |
    v
+------------+
| Core_lower |  Mechanical AST → Core IR translation (core_lower.ml)
+------------+
    |
    v
+-------------------+
| Core_ffi_boundary |  Attach checked FFI argument-boundary policies
+-------------------+  before downstream Core passes
    |
    v
+------------------+
| Core_list_layout |  Annotate list literals/allocations/handoffs with
+------------------+  concrete storage layout facts used by later passes
    |
    v
+------------+
| Core_debug |  Erase debug: blocks for normal builds, retain for
+------------+  --debug / blorp test (core_debug.ml)
    |
    v
+--------------+
| Core_desugar |  Eliminate sugar, then lower mutable locals through
+--------------+  core_ssa.ml (desugar stage snapshot)
    |
    v
+-----------+
| Core_mono |  Monomorphize generic functions at concrete call sites
+-----------+  and refresh list storage layout annotations
              (core_mono.ml, core_list_layout.ml)
    |
    v
+------------+
| Core_synth |  Re-synthesize monomorphized builtin bodies that became
+------------+  concrete after mono (core_synth.ml)
    |
    v
+------------+
| Core_match |  Compile pattern matches to decision trees (core_match.ml)
+------------+
    |
    v
+--------------------+
| Core_trait_resolve |  Rewrite trait methods / overloaded operators to the
+--------------------+  matching impl function (core_trait_resolve.ml)
    |
    v
+--------------+
| Core_resolve |  Tag CCall nodes with concrete kinds: user/foreign/builtin/
+--------------+  closure. UFCS + builtin + import alias resolution (core_resolve.ml)
    |
    v
+-----------------+
| Core_std_inline |  Expand compiler-owned std wrappers at call sites
+-----------------+  (core_std_inline.ml)
    |
    v
+--------------+
| Core_tailrec |  Lower supported @tail_recursive self-calls into explicit Core loops
+--------------+  (core_tailrec.ml)
    |
    v
+-------------+
| Core_fusion |  Fuse supported string/collection/scoped tensor pipelines and tensor updates;
+-------------+  scalar-replace non-escaping local tuples and narrow
                 tuple-return call sites
                 (core_string_pipeline.ml, core_collection_pipeline.ml,
                 core_parallel_tensor_pipeline.ml, core_tensor_fusion.ml,
                 core_tuple_sroa.ml)
    |
    v
+-----------------+
| Core_specialize |  Type-dispatch polymorphic builtins (to_int, to_float,
+-----------------+  to_string) → CCast nodes or concrete names; adapt
                   function references before ownership insertion
                   (core_specialize.ml, core_closure.ml)
    |
    v
+--------------------------+
| JSON handoff (supported) |  Supported pre-DCE Core enters the
+--------------------------+  contiguous Blorp-owned backend
    |
    v
+----------------+
| Blorp DCE      |  Prune unreachable emitted functions and projected type
+----------------+  declarations using explicit function/type reachability
                    (compiler_core_dce.brp)
    |
    v
+-------------------------+
| Blorp consume-specialize|  Clone safe source-owned self-replacement callees
+-------------------------+  with explicit consumed parameters before Perceus
                            (compiler_core_consume_specialize.brp)
    |
    v
+--------------+
| Blorp Perceus|  Insert CDup/CDrop for reference counting
+--------------+  Koka-style precise RC: branch-aware, last-use semantics
                  (compiler_core_perceus.brp)
    |
    v
+------------------+
| Blorp Core_reuse |  Rewrite proven post-Perceus allocation reuse candidates
+------------------+  (compiler_core_reuse.brp)
    |
    v
+--------------------+
| Blorp Core_closure |  Hoist lambdas and build closure values
+--------------------+  (compiler_core_closure.brp)
    |
    v
+---------------------+
| Blorp Core_resource |  Resource-scope break/continue cleanup exits
+---------------------+  (compiler_core_resource.brp)
    |
    v
+---------------------+
| Blorp Core_fairness |  Cooperative checkpoints at loop boundaries
+---------------------+  (compiler_core_fairness.brp)
    |
    v
+--------------------+
| Blorp Core_prepare |  Supported final Core representation preparation
+--------------------+  (compiler_core_prepare.brp)
    |
    v
+-------------------+
| Blorp C emission  |  C artifact generation for the supported subset
+-------------------+  (compiler_core_emit.brp)
```

Blorp-owned final-tail route:

```
Post-Perceus Core
    |
    v
+-------------------+
| run_core_pipeline |  Bridge action used for requested reuse/closure/final
+-------------------+  Core JSON snapshots and CLI stop/dump behavior
    |
    v
+-------+
| Final |  Snapshot after final preparation, emitted as Core JSON when asked
+-------+
    |
    v
Observed Core snapshot
```

**Design principles:**
- **No implicit type erasure as the target** — generic functions are
  monomorphized at call sites, and ordinary user generic records/structs are
  rewritten toward concrete instantiated layouts before codegen. Ordinary user
  generic unions now get concrete instantiated type identities and typed
  payload fields before codegen, which lets supported global constants over
  those layouts emit as static objects. Runtime storage, channel receive
  attempts, and closure boundaries still use explicit `void*` shims. Those
  boundaries must carry explicit layout and ownership metadata in Core.
- **Phase discipline** — each pass reads Core and produces Core. No pass needs
  information from a later pass.
- **Flat namespace** — module functions are prefixed (`std_list__map`) early.
  After prefixing, no downstream pass needs module awareness.
- **Explicit erased-storage boundaries** — intentionally dynamic runtime slots
  use `void*`, but the choice of how a typed value crosses that boundary is
  centralized in `core_layout_type.ml`. `compiler_core_prepare.brp` rewrites
  final Core to explicit box/unbox nodes before emission; the JSON bridge gets
  the remaining projection-time layout facts from `core_emit_layout.ml`.

The emitter contract follows from those principles: backend-specific emission
must consume explicit Core nodes and metadata rather than recovering layout,
boxing, or ownership behavior from source spelling.

**Core IR key files:**

| File | Purpose |
|------|---------|
| `core.ml` | IR type definitions, traversal helpers, pretty-printer |
| `core_lower.ml` | Typed AST → Core lowering |
| `core_ffi_boundary.ml` | Checked FFI argument-boundary policies attached before Core transforms |
| `core_debug.ml` | `debug:` block erasure/retention after lowering |
| `core_desugar.ml` | Sugar elimination |
| `core_ssa.ml` | Mutable-local lowering used inside the desugar stage |
| `core_mono.ml` | Monomorphization with worklist drain |
| `core_synth.ml` | Post-mono body synthesis for concrete builtins |
| `core_match.ml` | Pattern match → decision tree compilation |
| `core_trait_resolve.ml` | Trait-method and overloaded-operator rewrite |
| `core_resolve.ml` | Call kind resolution (builtins, UFCS, closures) |
| `core_std_inline.ml` | Narrow call-site expansion for compiler-owned std wrappers |
| `core_tailrec.ml` | `@tail_recursive` self-call lowering into explicit Core loops |
| `core_string_pipeline.ml` | Expression-local string producer/consumer fusion |
| `core_collection_pipeline.ml` | Expression-local collection pipeline fusion |
| `core_collection_producer.ml` | Shared producer metadata for fused collection construction |
| `core_list_pipeline.ml` | List-specific pipeline rewrite helpers used by collection fusion |
| `core_list_layout.ml` | Final list storage layout annotations used by specialization and emit |
| `core_parallel_tensor_pipeline.ml` | Scoped `Vector.parallel` / `Matrix.parallel` pipeline fusion |
| `core_tensor_fusion.ml` | Tensor update fusion before ownership insertion |
| `core_tensor_type.ml` | Tensor type/dimension utilities for Core passes |
| `core_tuple_sroa.ml` | Scalar replacement for non-escaping local tuple bindings and narrow tuple-return call sites |
| `core_specialize.ml` | Type-dispatch builtins → CCast / concrete names |
| `core_layout_type.ml` | Shared layout metadata and erased-storage release policy classification |
| `core_hash_container_layout.ml` | Dict/set constructor and storage layout selection |
| `core_option_layout.ml`, `core_result_layout.ml` | Stack/nullable/boxed layout selection for option/result values |
| `core_ownership.ml` | Ownership contracts for intrinsics, builtins, and synthesized helpers |
| `core_closure.ml` | First-class function reference eta-adapter synthesis before the Blorp closure tail |
| `core_emit_blorp_c.ml` | Core JSON projection and bridge client for the Blorp-owned tail C path |
| `core_emit_util.ml`, `core_emit_layout.ml` | Shared late-backend representation and bridge projection helpers |
| `core_flatten.ml` | Module prefixing and import-table assembly |
| `core_invariants.ml` | Stage-boundary invariant checks |
| `core_pipeline.ml` | Pipeline orchestration, module assembly |
| `core_error.ml` | Structured errors with phase/location/hint |
| `dim_solver.ml` | Canonical dimension arithmetic solver |

**Blorp compiler key files:**

| File | Purpose |
|------|---------|
| `compiler/blorp/src/stage_12_cli/compiler_bridge.brp` | Pure bridge dispatcher for compiler JSON actions |
| `compiler/blorp/src/stage_09_core/compiler_core_json.brp` | Typed Core JSON model at the current OCaml-to-Blorp boundary |
| `compiler/blorp/src/stage_09_core/compiler_core_traverse.brp` | Shared shallow Core expression traversal helpers for Blorp-owned passes |
| `compiler/blorp/src/stage_09_core/compiler_core_resource.brp` | Supported-route resource cleanup-exit rewriting |
| `compiler/blorp/src/stage_03_parse/compiler_source_ast_finalize.brp` | Typecheck-source AST finalization for interpolation, nested functions, and subscript reads |
| `compiler/blorp/src/stage_09_core/compiler_core_fairness.brp` | Supported-route cooperative checkpoint insertion |
| `compiler/blorp/src/stage_09_core/compiler_core_prepare.brp` | Supported-route final Core representation preparation subset |
| `compiler/blorp/src/stage_10_backend/compiler_core_emit.brp` | Supported-route C artifact emission subset |
| `compiler/blorp/src/stage_10_backend/compiler_artifact_json.brp` | Structured C artifact JSON codec |

### Inspecting the Pipeline

For compiler debugging, prefer Core dumps:

```bash
./blorp compile --dump-core-after=lower,mono,closure file.brp
./blorp compile --stop-after=resolve file.brp
./blorp compile --check-invariants --dump-core-after=match file.brp
```

`--dump-ast` and `--dump-typed-ast` are useful for summaries, but they do not print a full expression tree.

---

## Source Directory Structure

```
compiler/
├── bin/                   # CLI executables
│   └── blorp_ocaml_host.ml # Private host shell for decoded Blorp CLI plans
├── blorp/                 # Blorp-owned compiler and CLI slices
│   └── compiler_cli_main.brp # Public executable entry point
├── lib/                   # Compiler library
│   ├── ast.ml             # AST type definitions
│   ├── types.ml           # Type utilities (substitution, equality)
│   ├── env.ml             # Symbol table / environment
│   ├── env_builtins.ml    # Builtin type/function registration
│   ├── infer.ml           # Expression type inference
│   ├── typecheck.ml       # Type checking driver
│   ├── modules.ml         # Module/import resolution
│   ├── codegen/              # Shared codegen utilities used by core_emit
│   │   ├── codegen_names.ml     # C name mangling (UFCS, modules)
│   │   ├── codegen_types.ml     # Type classification and AST → C type mapping
│   │   └── codegen_builtins.ml  # Builtin function registry
│   ├── core.ml            # Core IR type definitions and traversal helpers
│   ├── core_lower.ml      # Typed AST → Core IR lowering (require_type invariant)
│   ├── core_ffi_boundary.ml # Checked FFI argument-boundary policies
│   ├── core_debug.ml      # debug: block lowering by build mode
│   ├── core_desugar.ml    # Core IR sugar elimination
│   ├── core_ssa.ml        # Mutable-local lowering used by core_desugar
│   ├── core_mono.ml       # Core IR monomorphization
│   ├── core_list_layout.ml # List storage layout annotation
│   ├── core_synth.ml      # Post-mono body synthesis for concrete builtins
│   ├── core_match.ml      # Core IR pattern match compilation
│   ├── core_trait_resolve.ml # Trait-method and overloaded-operator rewrite
│   ├── core_resolve.ml    # Core IR call kind resolution (UFCS, builtins, closures)
│   ├── core_std_inline.ml # Narrow call-site expansion for compiler-owned std wrappers
│   ├── core_tailrec.ml    # @tail_recursive self-call lowering
│   ├── core_string_pipeline.ml # Expression-local string fusion
│   ├── core_collection_pipeline.ml # Expression-local collection fusion
│   ├── core_collection_producer.ml # Shared collection producer metadata
│   ├── core_list_pipeline.ml # List-specific pipeline rewrite helpers
│   ├── core_parallel_tensor_pipeline.ml # Scoped vector/matrix pipeline fusion
│   ├── core_tensor_fusion.ml # Tensor update fusion
│   ├── core_tensor_type.ml # Tensor type/dimension utilities
│   ├── core_tuple_sroa.ml # Local/call-site tuple scalar replacement
│   ├── core_specialize.ml # Type-dispatch builtins → CCast / concrete names
│   ├── core_ownership.ml  # Ownership contracts for calls/intrinsics
│   ├── core_closure.ml    # Function-reference eta adapters
│   ├── core_hash_container_layout.ml # Dict/set layout selection
│   ├── core_layout_type.ml # Layout metadata and erased-storage policy
│   ├── core_option_layout.ml # Option representation selection
│   ├── core_result_layout.ml # Result representation selection
│   ├── core_type_layout.ml  # Managed/unmanaged Core type classification
│   ├── core_emit_blorp_c.ml # Core JSON projection and Blorp bridge client
│   ├── core_emit_util.ml  # Shared late-backend helper utilities
│   ├── core_intrinsics.ml # IR body synthesis for builtins/intrinsics
│   ├── core_intrinsic_registry.ml # Intrinsic manifest and contracts
│   ├── core_invariants.ml # Stage-boundary invariant checks
│   ├── core_pipeline.ml   # Core IR pipeline orchestration
│   ├── core_error.ml      # Core IR structured errors
│   ├── language_surface.ml # Shared source-language surface facts
│   ├── pipeline.ml        # Top-level compilation pipeline orchestration
│   ├── runtime.c          # Embedded C runtime (ARC, collections, IO)
│   ├── runtime_decl.c     # Runtime forward declarations
│   ├── runtime_raylib.c   # Raylib-specific runtime
│   ├── minicoro.h         # Coroutine library (M:N fiber scheduling)
│   ├── embedded_std.ml    # Embedded std library (generated by make)
│   ├── diagnostics.ml     # Error messages, suggestions
│   ├── test_runner.ml     # Test execution engine
│   ├── repl.ml            # REPL implementation
│   ├── line_editor.ml     # Terminal line editor for REPL
│   └── lsp/               # Language Server Protocol
│       ├── lsp_server.ml      # LSP main loop
│       ├── lsp_completion.ml  # Autocomplete
│       ├── lsp_hover.ml       # Hover information
│       ├── lsp_signature.ml   # Signature help
│       ├── lsp_symbols.ml     # Document symbols
│       ├── lsp_state.ml       # Server state
│       ├── lsp_protocol.ml    # LSP message types
│       ├── lsp_rpc.ml         # JSON-RPC transport
│       ├── lsp_json.ml        # JSON parsing
│       └── lsp_position.ml    # Source position utilities
└── dune                   # Build configuration

compiler/blorp/            # Blorp-authored compiler implementation slices
├── src/
│   ├── stage_01_file_io/        # Source text, spans, and diagnostics
│   ├── stage_02_lex/            # Tokens and lexer
│   ├── stage_03_parse/          # Parser, parsed AST, and parser bridge
│   ├── stage_04_modules/        # Module surfaces and type identities
│   ├── stage_05_types/          # Type model, context, Env, and builtins
│   ├── stage_06_typecheck/      # Imports, inference, typecheck state, bridge
│   ├── stage_07_ctfe/           # Compile-time evaluation
│   ├── stage_08_core_lower/     # Typed frontend to Core lowering
│   ├── stage_09_core/           # Core model, traversal, passes, manifests
│   ├── stage_10_backend/        # C artifact model, emission, codegen renderers
│   ├── stage_11_format/         # Formatter implementation
│   ├── stage_12_cli/            # CLI and bridge entrypoints
│   └── stage_99_meta/           # Migration inventory metadata
└── tests/                 # Blorp TestSuite coverage for compiler slices

std/                       # Portable standard library (.brp files)
├── prelude.brp            # Auto-imported declarations
├── traits.brp             # Core traits (Stringable, Equatable, Orderable, HasLength)
├── test.brp               # Test framework (TestSuite)
├── option.brp, result.brp # Error handling types
├── int.brp, float.brp, bool.brp, char.brp  # Primitive type utilities
├── int8.brp, int16.brp, int32.brp, int128.brp  # Sized signed integers
├── uint8.brp, uint16.brp, uint32.brp, uint64.brp, uint128.brp  # Sized unsigned integers
├── float16.brp, float32.brp, fixed.brp  # Sized floats and fixed-point decimals
├── range.brp, ptr.brp, tuple.brp, void.brp  # Core helper/value types
├── string.brp, slice.brp, bytes.brp  # String ecosystem
├── list.brp, dict.brp, set.brp  # Core collections
├── cache.brp, deque.brp, heap.brp, sorted_map.brp  # Extended collections
├── parallel_list.brp, property.brp, stream.brp  # Infrastructure helpers
├── tensor.brp, vector.brp, matrix.brp, parallel_vector.brp, parallel_matrix.brp  # Numeric arrays
├── math.brp, stats.brp, fft.brp, dsp.brp  # Math and signal processing
├── io.brp, file.brp, system.brp, debug.brp, memory.brp, instrumentation.brp, time.brp, channel.brp  # System
├── path.brp, process.brp, log.brp, terminal.brp  # OS/terminal
├── random.brp, crypto_random.brp, hash.brp  # Random/crypto helpers
├── parser.brp, regex.brp  # Text processing
├── csv.brp, toml.brp, xml.brp, yaml.brp, html.brp, json.brp  # Format parsers
├── argparse.brp, uuid.brp, validation.brp  # Utilities
├── physics.brp, geometry.brp, geographic.brp, geojson.brp  # Spatial helpers
├── units.brp, noise.brp, codec.brp, codec_bridge.brp  # Misc
├── net/                   # Networking primitives and pure protocol helpers
└── README.md              # Standard library module inventory

pkg/                       # Optional native packages and third-party bindings
├── compress.brp           # zlib compression package surface
├── compress_ffi.h         # zlib C FFI wrapper
├── crypto.brp             # AES/PBKDF2 package surface
├── crypto_ffi.h           # CommonCrypto/OpenSSL C FFI wrapper
├── net/                   # Native-backed DNS, HTTP client, SMTP, TLS, UDP, WebSocket
├── sqlite.brp             # SQLite package surface
└── sqlite_ffi.h           # SQLite C FFI wrapper

tests/
├── test_blorp/            # Runtime tests (TestSuite-based)
│   ├── types/             # Type-specific tests (ADTs, records, structs, conversions)
│   ├── text/              # String/text tests (regex, parsers, XML, YAML, TOML)
│   ├── collections/       # List/dict/set/cache tests
│   ├── numeric/           # Arithmetic, tensor, vector, FFT, signal tests
│   ├── sys/               # I/O, system, debug, time tests
│   ├── memory/            # ARC, leak detection, COW tests
│   ├── functions/         # Closures, generics, HOF, FFI, tailrec tests
│   ├── concurrency/       # Concurrent blocks, detach, channels tests
│   ├── tools/             # Tooling/runtime helper tests
│   └── simd/              # SIMD tests
├── test_std/              # Runtime tests for std/ modules
└── test_compiler/         # Compiler behavior tests
    ├── parser/            # Parser/lexer tests (should_pass/ + should_fail/)
    ├── infer/             # Type inference tests (should_pass/ + should_fail/)
    ├── typecheck/         # Type checking tests (should_pass/ + should_fail/)
    ├── format/            # Formatter tests (should_pass/ + should_fail/ + should_error/)
    ├── purify/            # Auto-purification tests
    └── codegen_audit/     # Codegen correctness tests
```

---

## Frontend

### Blorp Lexer (`compiler/blorp/src/stage_02_lex/compiler_lexer.brp`)

Blorp source lexer that tokenizes source text and emits spans, comments, and
docstrings for the parser bridge:

**Key features**:
- Significant whitespace (Python-style indentation)
- indent / dedent tokens for blocks
- String interpolation (`"Hello ${name}!"`)
- All keywords and operators

Token and keyword shapes are defined in `compiler/blorp/src/stage_02_lex/compiler_token.brp`.

### Blorp Parser (`compiler/blorp/src/stage_03_parse/compiler_parser.brp`)

Blorp parser that builds the parsed source AST used by the OCaml middle
pipeline:

**Key rules**:
- `program` - Top-level declarations
- `expr` - All expressions
- `func_decl` - Function declarations
- `type_expr` - Type annotations
- `match_expr` - Pattern matching

**Operator desugaring**: Binary operators become function calls:
```blorp
a + b -> add(a, b)
```

The parser helper serializes parsed source artifacts through
`compiler/blorp/src/stage_03_parse/compiler_parsed_ast_json.brp`. Each artifact carries
`ast_phase`, `parsed_ast`, a Blorp-owned syntactic `module_surface`, and
optional `comments`. OCaml decodes the AST in
`compiler/lib/parsed_ast_json.ml`, decodes and validates the module surface in
`compiler/lib/module_surface.ml`, then continues with module loading,
typechecking, Core lowering, and later stages. CLI frontend module graph
sources are required to use `typecheck_source` artifacts with module surfaces.
The graph also carries the module-loading context used during Blorp-side import
discovery: explicit std override, source-package aliases, and local `pkg/`
roots. The OCaml CLI frontier applies that context before seeding its parse
cache so graph-driven `check`, `compile`, and `run` do not depend on a second
config scan for the same policy.
Typed semantic exports remain in the OCaml typechecker until that stage moves.

### AST (`ast.ml`)

OCaml type definitions for the abstract syntax tree:

```ocaml
type expr_desc =
  | EIdent of string
  | ELiteral of literal
  | EBinary of binop * expr * expr
  | ECall of expr * expr list
  | EIf of expr * expr * expr option
  | EMatch of expr * match_case list
  | EBlock of expr list
  | ELambda of func_decl
  (* ... many more *)

type decl_desc =
  | DFunc of func_decl
  | DType of type_decl
  | DRecord of record_decl
  | DVar of var_decl
  | DImport of import_decl
  (* ... *)
```

---

## Type System

### Environment (`env.ml`)

Symbol table managing scoped lookups:

```ocaml
type symbol_kind =
  | VarSymbol of { var_type: type_expr; is_mutable: bool }
  | FuncSymbol of { func_type: type_expr; type_params: string list; is_pure: bool }
  | TypeSymbol of { type_params: string list; variants: variant list }
  | RecordSymbol of { type_params: string list; fields: field_decl list }
  | ConstructorSymbol of { parent_type: string; field_types: type_expr list; tag: int }
```

**Key functions**:
- `lookup` - Find symbol by name across scopes
- `add_var`, `add_func`, `add_type` - Register symbols
- `push_scope`, `pop_scope` - Scope management
- `with_builtins` - Initialize with built-in types and functions

### Types (`types.ml`)

Type manipulation utilities:

```ocaml
type subst_entry = { var_name: string; concrete_type: type_expr }
type subst_map = subst_entry list

val apply_subst : subst_map -> type_expr -> type_expr
val types_equal : type_expr -> type_expr -> bool
val types_compatible : type_expr -> type_expr -> bool
```

### Inference (`infer.ml`)

Bidirectional type inference for expressions:

```ocaml
val infer_expr : infer_ctx -> expr -> (type_expr * expr) infer_result
```

**Key features**:
- Expected type propagation (bidirectional)
- Lambda parameter inference from context
- Constructor return type inference
- Pattern binding in match cases

### Type Checker (`typecheck.ml`)

Main type checking driver:

```ocaml
val typecheck_program : Ast.program -> check_result
```

**Validations**:
- Purity constraints (pure functions cannot call impure)
- Pattern match exhaustiveness
- @tail_recursive tail position validation
- Nested parallelism detection
- If condition must be Bool

See [COMPILER_ROADMAP.md](COMPILER_ROADMAP.md) for the active path toward a
single semantic call-target model shared by `check`, `compile`, and `purify`.

---

## Modules

### Module Resolution (`modules.ml`)

Handles imports and module loading:

```ocaml
val init_module_paths : ?sess:Session.t -> string -> unit
val parse_raw_source_artifact :
  ?sess:Session.t ->
  ?filename:string ->
  ?bridge_read_file:bool ->
  string ->
  (parsed_source_artifact, Ast.compiler_error) result
val parse_typecheck_source_artifact :
  ?sess:Session.t ->
  ?filename:string ->
  ?bridge_read_file:bool ->
  string ->
  (parsed_source_artifact, Ast.compiler_error) result
val load_imports :
  ?sess:Session.t ->
  ?surface:Module_surface.t ->
  Ast.program ->
  string ->
  loaded_module list
val load_module : ?sess:Session.t -> string -> string -> loaded_module option
val get_all_modules : ?sess:Session.t -> unit -> loaded_module list
```

Parser artifact helpers preserve the Blorp parser bridge's module surface
alongside the AST. Raw parser callers use `parse_raw_source*`; typecheck-facing
callers use `parse_typecheck_source*`. Callers that parse and immediately load
imports should pass that surface to `load_imports`, so import discovery and
parsed-module exports come from the authoritative Blorp surface instead of
fallback AST scanning.

Loaded modules store parsed declarations, an optional module surface, and an
optional typed program in `loaded_module.typed_decls`; `Pipeline` is responsible
for ensuring loaded modules are typed before Core lowering.

**Import types** (all inside `import:` block):
- Selective: `std/option: Option(Some, None)`
- Qualified: `std/list as L`
- Combined qualified/selective: `std/heap as H: Heap`

**Path resolution**:
- `std/` prefix resolves to standard library
- `pkg/` prefix resolves to an explicit local package root, usually
  `<project>/pkg`; `pkg/foo/bar` loads `<root>/foo/bar.brp` with package
  origin `foo`
- Relative paths (`./`, `../`) from current file
- Automatic `.brp` extension

Loaded modules carry an explicit origin: standard library, package, or user
module. Later phases must use that origin for policy decisions such as whether
`builtin` declarations are legal, rather than re-deriving privileges from path
strings. Bare imports may resolve standard library modules, but they never
resolve local packages; package code must be imported through `pkg/...`.

---

## Backend

### Code Generator (Core IR + `codegen/` helpers)

Codegen runs entirely through the Core IR pipeline. The Core passes
(see "Core IR Pipeline" above) transform the typed AST into a C string.

Shared utilities live in `compiler/lib/codegen/`:
- `codegen_names.ml` — C name mangling (UFCS, module prefixing)
- `codegen_types.ml` — Type classification and AST → C type mapping; final
  erased-storage boxing decisions are represented in Core before emission
- `codegen_builtins.ml` — Builtin function name registry

**Key concepts**:

**Monomorphization** (`core_mono.ml`): Generic functions specialized per type:
```c
// blorp: func identity[T](x: T) -> T
// C: long identity_Int(long x)
// C: double identity_Float(double x)
```

**Closure conversion** (`compiler/blorp/src/stage_09_core/compiler_core_closure.brp`): Lambdas are
hoisted into helper functions in the Blorp-owned backend tail and use the runtime
closure ABI:
```c
typedef struct {
    blorp_Object header;
    void* func;
    void* env;
    long env_count;
    unsigned long env_release_mask;
} blorp_Closure;
```

Zero-capture closures are emitted as immortal file-scope
`static blorp_Closure` values. Closures with captures allocate
`blorp_closure_new_inline`, store captures in the inline environment, and set
`env_release_mask` so closure destruction releases retained managed captures.

**Perceus RC** (`compiler/blorp/src/stage_09_core/compiler_core_perceus.brp`):
Precise reference counting via
`CDup`/`CDrop` nodes. Perceus consumes the ownership ABI defined in
`docs/OWNERSHIP_MODEL.md`: read-only parameters borrow, owned managed returns
must cross source-level function boundaries as owned values, and COW-consuming
calls consume the receiver owner while preserving source-level value semantics.

**SIMD optimization**: Float64 and Int64 vectors use SSE2/NEON SIMD for
element-wise and scalar broadcast operations. Float32/Float16 use scalar
loops due to void*-boxed storage. All vectors are currently heap-allocated.

### Runtime (`runtime.c`, `runtime_decl.c`, `runtime_raylib.c`)

Embedded C runtime compiled into the generated binary:

**Includes**:
- ARC functions (`blorp_alloc`, `blorp_retain`, `blorp_release`) — atomic refcounts
- String, list, dict, set, bytes, tensor/vector operations with COW
- SIMD vector operations (SSE2/NEON with scalar fallback)
- Fixed-point arithmetic
- Thread pool + M:N fiber scheduling (`minicoro.h`), channels, structured concurrency

The runtime, cancellation, and resource direction is tracked in
[CONCURRENCY_AND_RESOURCES.md](CONCURRENCY_AND_RESOURCES.md).

When adding a new runtime function, declare it in **both** `runtime.c` and
`runtime_decl.c` — the latter holds forward declarations used by generated
translation units.

---

## CLI

### Main Entry Point

The public `./blorp` executable is built from the Blorp CLI entry point in
`compiler/blorp/src/stage_12_cli/compiler_cli_main.brp`. It performs user-facing command
planning, source discovery, source reads, parsing, and current frontend graph
handoffs before invoking the private OCaml host shell
`compiler/bin/blorp_ocaml_host.ml` for the compiler stages and impure host
actions that have not yet migrated.

User-facing subcommands:

```bash
./blorp compile program.brp      # Compile to generated C
./blorp check file.brp           # Type check one file
./blorp check src/               # Type check .brp files recursively
./blorp compile --ast file.brp   # Print AST
./blorp run program.brp          # Compile and run quickly (-O0)
./blorp run --release program.brp # Compile and run optimized (-O2)
./blorp test tests/              # Run test suite
```

---

## How-To Guides

### Adding a New Keyword

1. **Lexer** (`compiler/blorp/src/stage_02_lex/compiler_lexer.brp`):
   - Add keyword handling.
   - Return the appropriate `compiler_token` value.

2. **Parser** (`compiler/blorp/src/stage_03_parse/compiler_parser.brp`):
   - Add grammar rules

3. **Shared language surface and editor metadata**:
   - If the keyword is user-facing, add it to `language_surface.ml` for LSP
     completions. Do not add legacy/error-only tokens such as removed syntax.
   - Update shared TextMate and language-configuration metadata under
     `editor/`, then run `scripts/check-editor-drift`.

4. **AST** (`ast.ml`):
   - Add new variant to appropriate type

5. **TypeCheck** (`typecheck.ml`, `infer.ml`):
   - Add type checking for new construct

6. **Core lowering** (`core_lower.ml`):
   - Translate the new AST node into Core IR. If the construct desugars
     to existing Core, handle it in `core_desugar.ml` instead.
   - If the construct has build-mode semantics like `debug:`, represent it
     explicitly in Core and lower it in a dedicated pass before shared
     optimizations.

7. **Core emission** (`compiler/blorp/src/stage_10_backend/compiler_core_emit.brp`):
   - Emit C for the new Core node, if one was introduced.

### Adding a New Builtin Function

1. **Prelude** (`std/prelude.brp`):
   ```blorp
   pure func new_builtin(x: Int) -> Int:
       builtin
   ```

2. **Environment** (`env_builtins.ml`):
   - Register the builtin type signature for inference

3. **Codegen registry** (`codegen/codegen_builtins.ml`):
   - Map the blorp name to its C function name when this is a direct runtime
     builtin. Compiler-owned helper operations should usually be registered as
     Core intrinsics in `core_intrinsic_registry.ml`, implemented or
     synthesized through `core_intrinsics.ml`, and covered by
     `core_ownership.ml` if they touch managed values.

4. **Runtime** (`runtime.c` and `runtime_decl.c`):
   - Add the C implementation **and** its forward declaration if the builtin
     is runtime-backed. Pure Core-synthesized helpers may not need a runtime
     entry.

### Adding a New Type

1. **AST** (`ast.ml`):
   - Add type representation if needed

2. **Parser** (`compiler/blorp/src/stage_03_parse/compiler_parser.brp`):
   - Handle in type parsing rules

3. **Types** (`types.ml`):
   - Add type equality/compatibility rules

4. **Codegen** (`codegen/codegen_types.ml`):
   - Add C type mapping in `classify_type` and AST → C type emission.

5. **Runtime** (`runtime.c`):
   - Add runtime support if heap-allocated

---

## Testing

### Test Organization

See the `tests/` layout in "Source Directory Structure" above for the full
list of subdirectories. The runtime tests are grouped under `tests/test_blorp/`
by domain (types, text, collections, numeric, sys, memory, functions,
concurrency, simd) and the compiler tests under
`tests/test_compiler/` by phase (parser, infer, typecheck, format, purify,
codegen_audit), with `should_pass/`, `should_fail/`, or phase-specific
subdirectories as appropriate.

### Running Tests

```bash
# All runtime tests
./blorp test tests/test_blorp/

# Single test file
./blorp test tests/test_blorp/collections/test_list_fundamentals.brp

# Type check only
./blorp check tests/test_compiler/infer/should_pass/generics.brp
```

### Writing Tests

**Runtime tests** (TestSuite):
```blorp
import:
    std/test: TestSuite

func test_something() -> Bool:
    actual == expected

tests: TestSuite = {
    description = "My Tests",
    tests = [("test name", test_something)]
}
```

---

## Build System

### Building

```bash
# From project root
make           # Build compiler, outputs ./blorp

# Or directly with dune
cd compiler && dune build
```

### Build Outputs

- `./blorp` - Main compiler executable (copied from `compiler/_build/`)
- `./blorp compile file.brp` writes generated C next to the source as
  `file.c` unless `-o PATH` is provided.
- `./blorp run` and `./blorp test` compile through temporary artifacts managed
  by the test runner.

### Compiler Flags

```bash
./blorp compile [options] input.brp

Options:
  --ast        Print AST and exit
  -o PATH      Write generated C to PATH

./blorp run input.brp
  --profile    Run with timing

./blorp test path/
  --profile    Run tests with timing
```
