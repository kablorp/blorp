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
+------------------+
| Core Preparation |  Blorp lowering, graph flattening, checked FFI boundary,
| + Early Pipeline |  debug, desugar/SSA, mono, list layout, synthesis,
|                  |  pattern/trait/call resolution, std wrapper inlining,
|                  |  tail-recursive loop lowering, string/collection fusion,
|                  |  parallel-tensor fusion, tensor-update fusion, runtime
|                  |  declaration projection, and tuple scalar replacement
|                  |  (stage_08_core_lower, stage_09_core)
+------------------+
    |
    v
+------------------+
| Late Core        |  Blorp specialization, DCE, ownership, reuse, closure,
| + preparation    |  resource/fairness, and final representation preparation
|                  |  (stage_09_core)
+------------------+
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

Codegen is a pipeline over the typed `CoreProgram` representation defined in
`compiler_core_json.brp`.
Most stages read Core IR and produce Core IR; final codegen preparation makes
late representation choices explicit in Core before C artifact emission. The
Core path is the compiler's codegen path.

The production route lowers and assembles the
typed module graph, lowers debug blocks and mutable locals, desugars Core,
monomorphizes generic declarations, annotates list layouts, synthesizes
concrete builtin bodies, compiles raw matches to semantic decision trees,
resolves trait dispatch and ordinary call kinds, inlines narrow std wrappers,
lowers supported self-tail-calls, fuses supported string, collection,
parallel-tensor, and tensor-update pipelines, projects runtime declarations,
and scalar-replaces eligible tuples in Blorp. The same typed `CoreProgram`
continues directly into value, collection/stream, and tensor specialization;
no process or JSON boundary exists inside compilation. A shared specialization
layout builds alias, declaration, ownership, and runtime-layout facts once per
program. Independent current-node specialization families compose under one
recursive traversal. Length folding and raw-view formation remain one coherent
pass because the folded static dimension is the fact that proves loop accesses
in bounds. On the current backend route,
`compiler/blorp/src/stage_09_core/compiler_core_specialize.brp`,
`compiler/blorp/src/stage_09_core/compiler_core_tensor_specialize.brp`,
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
dumps and stops render snapshots from the Blorp-owned pipeline. C artifact
emission is owned by the Blorp backend.

Typed `debug:` blocks remain explicit through Blorp CTFE and Core lowering as
`DebugBlockExpr` nodes. Blorp `compiler_core_debug.brp` is the single
production stage that either erases each node or retains its body according to
the request's debug mode. The post-debug invariant rejects any node that
survives that decision.

Resource-source loops acquire and scope each resource in Blorp inference and
Core lowering. The compiler records the exact synthesized loop-item identity
on the typed scope rather than recognizing generated names. Blorp Core lowering
consumes that tagged identity, keeping one cleanup owner per resource without a
name-based heuristic.

The late-Core projection preserves scoped `let`/`borrow` expressions inside
closure-call arguments. The Blorp-owned closure and preparation stages, rather
than the projection boundary, own their final normalization for C emission.

Record updates remain explicit `RecordUpdateExpr` nodes until ownership
normalization. Lowering evaluates the source receiver once, binds it
to a temporary, and stores that variable plus the complete checked field list
in declaration order. This preserves update provenance and makes ownership
normalization total after monomorphization without rediscovering record shape.
At Perceus ingress, a canonical mutable self-replacement becomes
`RecordReuseExpr`; every other carrier becomes ordinary fresh record
construction. Perceus transfers the replaced binding's owner into the reuse
node and retains managed field aliases as needed. Exhaustive top-level `if`,
literal-match, and constructor-match results transfer the owner only when every
returning branch independently qualifies, the condition cannot replace that
owner, and a match scrutinee cannot touch it. The post-Perceus reuse pass also
recognizes an adjacent same-type `RecordExpr`/ARC-drop pair, where the source
owner is provably dead after every replacement field has been evaluated, and
replaces that pair with `RecordReuseExpr`. This covers dead chained-update
temporaries without guessing about source syntax or liveness. The backend
evaluates fields before consuming the source and reuses the old allocation only
when its runtime reference count is unique; otherwise it constructs a fresh
record. This changes allocation counts without changing source-level value
semantics.

The Blorp CLI is built by invoking the pinned release's public `blorp compile`
command. That immutable release binary is build trust-root material, not a
second bootstrap-only implementation and not a runtime fallback. The test
runner and REPL invoke the production Blorp
executable for synthetic source; no direct-source, preloaded-graph, or generated
in-memory OCaml compilation entrypoint remains.

```
Blorp Typed AST graph
    |
    v
+----------------------+
| Core graph prepare   |  Blorp typed AST -> Core, module flattening,
+----------------------+  checked FFI policies, and initial list layout
    |
    v
+------------------+
| Blorp Core debug |  Erase debug: blocks for normal builds, retain for
+------------------+  --debug / blorp test (compiler_core_debug.brp)
    |
    v
+--------------------+
| Blorp desugar/SSA |  Eliminate sugar, then lower mutable locals
+--------------------+  (compiler_core_desugar.brp, compiler_core_ssa.brp)
    |
    v
+-----------------+
| Blorp Core mono |  Monomorphize generic functions and data at concrete
+-----------------+  uses, then refresh list storage layout annotations
                    (compiler_core_monomorphize.brp)
    |
    v
+------------------+
| Blorp Core synth |  Synthesize concrete builtin bodies and promote each
+------------------+  completed builtin to an ordinary Core function
    |
    v
+------------------+
| Blorp Core match |  Compile raw patterns into semantic decision trees
+------------------+  (compiler_core_match.brp)
    |
    v
+--------------------------+
| Blorp trait resolution   |  Rewrite trait calls and overloaded operators to
+--------------------------+  concrete impl functions (compiler_core_trait_resolve.brp)
    |
    v
+-----------------------+
| Blorp Core resolution |  Tag calls as user/foreign/builtin/intrinsic/closure;
+-----------------------+  resolve UFCS, imports, constructors, and selected IDs
                           (compiler_core_resolve.brp)
    |
    v
+--------------------------+
| Blorp Core std inline    |  Expand the narrow allowlist of compiler-owned
+--------------------------+  list/tensor wrappers (compiler_core_std_inline.brp)
    |
    v
+-----------------------------+
| Blorp Core tailrec       |  Lower supported @tail_recursive self-calls into
+-----------------------------+  explicit Core loops (compiler_core_tailrec.brp)
    |
    v
+--------------------------+
| Blorp string fusion      |  Fuse supported string producer/consumer pipelines
+--------------------------+  (compiler_core_string_pipeline.brp)
    |
    v
+----------------------------+
| Blorp collection fusion    |  Fuse supported list/range pipelines into loops
+----------------------------+  (compiler_core_collection_pipeline.brp)
    |
    v
+-------------------------------+
| Blorp parallel tensor fusion  |  Fuse scoped vector/matrix parallel pipelines
+-------------------------------+  (compiler_core_parallel_tensor_pipeline.brp)
    |
    v
+-------------------------------+
| Blorp tensor update fusion    |  Fuse supported add-scaled tensor updates
+-------------------------------+  (compiler_core_tensor_fusion.brp)
    |
    v
+-------------------------------+
| Blorp tuple SROA              |  Scalar-replace non-escaping local tuples and
+-------------------------------+  narrow tuple-return call sites
                                  (compiler_core_tuple_sroa.brp)
    |
    v
+-------------------------------+
| Blorp Core specialization     |  One indexed traversal dispatches primitive,
+-------------------------------+  value, collection/stream, and tensor runtime
                                  layouts (compiler_core_specialize*.brp)
    |
    v
+--------------------------+
| Blorp tensor specialize  |  Fold length; dispatch numeric checked access,
+--------------------------+  raw-scalar fills, unary math, and reductions; form guarded
                              raw views for bounds-proven loops
                              (compiler_core_tensor_specialize.brp)
    |
    v
+--------------------------+
| Blorp function refs      |  Adapt bare first-class function values into eta
+--------------------------+  closures before ownership insertion
                              (compiler_core_closure.brp)
    |
    v
+----------------+
| Blorp DCE      |  Prune unreachable emitted functions and projected type
+----------------+  declarations using explicit reachability
                    (compiler_core_dce.brp)
    |
    v
+-------------------------+
| Blorp consume-specialize|  Clone safe source-owned self-replacement callees
+-------------------------+  with explicit consumed parameters before Perceus
                            (compiler_core_consume_specialize.brp)
    |
    v
+--------------------------+
| Blorp ownership prepare  |  Lower dictionary literals to explicit boxed
+--------------------------+  construction so Perceus can assign entry owners;
                              all other backend preparation remains late
                              (compiler_core_prepare.brp)
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
| Blorp closure      |  Hoist lambdas and build closure values
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
+-------------------------+
| run_core_pipeline_stage |  Direct Blorp pipeline call for requested
+-------------------------+  reuse/closure/final snapshots and CLI stop/dump behavior
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
  explicit in Blorp Core layout and specialization policy.
  `compiler_core_prepare.brp` rewrites final Core to explicit box/unbox nodes
  before emission.

The emitter contract follows from those principles: backend-specific emission
must consume explicit Core nodes and metadata rather than recovering layout,
boxing, or ownership behavior from source spelling.

**Core IR key files:**

| File | Purpose |
|------|---------|
| `compiler_core_json.brp` | Core IR type definitions and serialization |
| `compiler_core_collection_plan.brp` | Recognition and validated plans for Blorp-owned list/range pipeline fusion |
| `compiler_core_collection_policy.brp` | Layout and ownership policy for Blorp-owned collection fusion |
| `compiler_core_collection_pipeline.brp` | Expression-local Blorp-owned collection pipeline lowering |
| `compiler_core_parallel_tensor_pipeline.brp` | Scoped `Vector.parallel` / `Matrix.parallel` pipeline fusion |
| `compiler_core_tensor_fusion.brp` | Tensor update fusion before ownership insertion |
| `compiler_core_specialize_layout.brp` | Final collection, tensor, option, and erased-storage layout selection |
| `compiler_core_c_type_layout.brp`, `compiler_core_result_layout.brp` | C layout selection for option/result values |
| `compiler_core_ownership.brp` | Ownership contracts for intrinsics, builtins, and synthesized helpers |
| `dim_solver.ml` | Canonical dimension arithmetic solver |

**Blorp compiler key files:**

| File | Purpose |
|------|---------|
| `compiler/blorp/src/stage_12_cli/compiler_parser_bridge_cli.brp` | Remaining parser and CLI-planning worker for OCaml-hosted commands |
| `compiler/blorp/src/stage_09_core/compiler_core_json.brp` | Typed Core model and dump codec |
| `compiler/blorp/src/stage_09_core/compiler_core_traverse.brp` | Shared shallow Core expression traversal helpers for Blorp-owned passes |
| `compiler/blorp/src/stage_09_core/compiler_core_match.brp` | Authoritative raw-pattern to semantic decision-tree compilation |
| `compiler/blorp/src/stage_09_core/compiler_core_trait_resolve.brp` | Authoritative trait-method and overloaded-operator resolution |
| `compiler/blorp/src/stage_09_core/compiler_core_resolve.brp` | Authoritative call-kind, import, constructor, UFCS, and callable-identity resolution |
| `compiler/blorp/src/stage_09_core/compiler_core_std_inline.brp` | Authoritative narrow expansion of compiler-owned list/tensor wrappers |
| `compiler/blorp/src/stage_09_core/compiler_core_tailrec.brp` | Authoritative supported self-tail-call lowering into explicit Core loops |
| `compiler/blorp/src/stage_09_core/compiler_core_tuple_sroa.brp` | Authoritative scalar replacement for non-escaping local tuples and narrow unmanaged tuple-return call sites |
| `compiler/blorp/src/stage_09_core/compiler_core_specialize.brp` | Single recursive specialization driver and primitive/reflection specialization |
| `compiler/blorp/src/stage_09_core/compiler_core_specialize_layout.brp` | Shared indexed alias, declaration, ownership, and runtime-layout facts |
| `compiler/blorp/src/stage_09_core/compiler_core_specialize_value.brp` | Stringification, equality, and value-box specialization |
| `compiler/blorp/src/stage_09_core/compiler_core_specialize_collection.brp` | Collection, hash-container, Option ABI, stream, and fallback specialization |
| `compiler/blorp/src/stage_09_core/compiler_core_specialize_tensor_dispatch.brp` | Residual tensor arithmetic, matrix, access, fill, and result-layout dispatch |
| `compiler/blorp/src/stage_09_core/compiler_core_tensor_specialize.brp` | Authoritative length folding, numeric checked tensor-access, raw-scalar fill, unary tensor-math and numeric reduction dispatch, plus guarded raw-view formation for bounds-proven tensor loops |
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
│   ├── core_result_layout.ml # Result representation selection
│   ├── core_type_layout.ml  # Managed/unmanaged Core type classification
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

Blorp parser that builds the parsed source AST consumed by module loading,
typechecking, Core lowering, and compiler tooling:

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

Remaining delegated OCaml tools can receive serialized parsed source artifacts
through `compiler_parsed_ast_json.brp`. Each artifact carries `ast_phase`,
`parsed_ast`, a Blorp-owned syntactic `module_surface`, and optional `comments`;
`parsed_ast_json.ml` and `module_surface.ml` decode that tool boundary. Normal
`check`, `compile`, and `run` keep parsed values inside the Blorp pipeline.

The production module graph carries the module-loading context used during
Blorp import discovery: explicit std override, source-package aliases, and
local `pkg/` roots. The Blorp CLI applies that context once when preparing the
graph, so compilation does not depend on a second configuration scan.

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

**Monomorphization** (`compiler/blorp/src/stage_09_core/compiler_core_monomorphize.brp`):
Generic functions are specialized per type:
```c
// blorp: func identity[T](x: T) -> T
// C: long identity_Int(long x)
// C: double identity_Float(double x)
```

**Closure formation** (`compiler/blorp/src/stage_09_core/compiler_core_closure.brp`): Bare
first-class function values become eta closures before Perceus. Lambdas are
then hoisted into helper functions in the Blorp-owned backend tail and use the
runtime closure ABI:
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
`compiler/blorp/src/stage_12_cli/compiler_cli_main.brp`. It performs
user-facing command planning, source discovery, source reads, parsing,
typechecking, Core preparation, backend coordination, and migrated host
effects. Compile and run remain in Blorp through Core specialization, C
emission, artifact publication, and optional execution. Test commands and
other unmigrated non-source commands still delegate to
`compiler/bin/blorp_ocaml_host.ml`.

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

6. **Core lowering** (`compiler/blorp/src/stage_08_core_lower/compiler_core_lower.brp`):
   - Translate the new typed AST node into Core IR. If the construct desugars
     to existing Core, handle it in the owning Blorp middle-Core pass instead.
   - If the construct has build-mode semantics like `debug:`, represent it
     explicitly in Core and lower it in a dedicated pass before shared
     optimizations.
   - There is no OCaml lowering fallback; all source-to-Core behavior belongs
     on the contiguous Blorp path.

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
     builtin.
   - Register compiler-owned Core intrinsics in `INTRINSIC_SPECS` in
     `compiler/blorp/src/stage_10_backend/codegen_intrinsic_renderer.brp` and
     synthesize their call sites through the Blorp `compiler_core_synth_*.brp`
     families.
   - Define managed-value contracts in
     `compiler/blorp/src/stage_09_core/compiler_core_ownership.brp`, the single
     source of truth consumed by the Blorp Core and backend stages.

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
- `./blorp run` compiles, links, and executes through Blorp-owned temporary
  artifacts. The OCaml test runner still orchestrates `./blorp test`, but each
  test or generated harness is compiled to an executable by the invoking
  production Blorp binary.

### Compiler Flags

```bash
./blorp compile [options] input.brp

Options:
  --ast        Print AST and exit
  --profile    Emit function-level profiling instrumentation
  -o PATH      Write generated C to PATH

./blorp run input.brp
  --profile    Run with timing

./blorp test path/
  --profile    Run tests with timing
```
