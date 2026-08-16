# blorp Compiler Architecture

## Compilation Pipeline

```
Source (.brp)
    |
    v
+--------+
| Lexer  |  Tokenization (compiler/blorp/src/stage_02_lex/lexer.brp)
+--------+
    |
    v
+--------+
| Parser |  AST construction (compiler/blorp/src/stage_03_parse/language_parser.brp)
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
`core_json.brp`.
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
`compiler/blorp/src/stage_09_core/core_specialize.brp`,
`compiler/blorp/src/stage_09_core/core_tensor_specialize.brp`,
`compiler/blorp/src/stage_09_core/core_dce.brp`,
`compiler/blorp/src/stage_09_core/core_consume_specialize.brp`,
`compiler/blorp/src/stage_09_core/core_perceus.brp`,
`compiler/blorp/src/stage_09_core/core_reuse.brp`,
`compiler/blorp/src/stage_09_core/core_closure.brp`,
`compiler/blorp/src/stage_09_core/core_resource.brp`,
`compiler/blorp/src/stage_09_core/core_fairness.brp`,
`compiler/blorp/src/stage_09_core/core_prepare.brp`, and
`compiler/blorp/src/stage_10_backend/core_emit.brp` own the contiguous tail through C
artifact generation. CLI `dce`/`consume-specialize`/`perceus`/`reuse`/`closure`/`final`
dumps and stops render snapshots from the Blorp-owned pipeline. C artifact
emission is owned by the Blorp backend.

JSON is reserved for boundaries that actually require it: LSP JSON-RPC and
isolated benchmark replay workers. Compiler phases exchange typed Blorp values directly.
Debug AST output is rendered from those values and is not a serialization
contract.

Typed `debug:` blocks remain explicit through Blorp CTFE and Core lowering as
`DebugBlockExpr` nodes. Blorp `core_debug.brp` is the single
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
runner invokes the production Blorp executable for synthetic source; no
direct-source, preloaded-graph, or generated in-memory OCaml compilation
entrypoint remains.

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
+------------------+  --debug / blorp test (core_debug.brp)
    |
    v
+--------------------+
| Blorp desugar/SSA |  Eliminate sugar, then lower mutable locals
+--------------------+  (core_desugar.brp, core_ssa.brp)
    |
    v
+-----------------+
| Blorp Core mono |  Monomorphize generic functions and data at concrete
+-----------------+  uses, then refresh list storage layout annotations
                    (core_monomorphize.brp)
    |
    v
+------------------+
| Blorp Core synth |  Synthesize concrete builtin bodies and promote each
+------------------+  completed builtin to an ordinary Core function
    |
    v
+------------------+
| Blorp Core match |  Compile raw patterns into semantic decision trees
+------------------+  (core_match.brp)
    |
    v
+--------------------------+
| Blorp trait resolution   |  Rewrite trait calls and overloaded operators to
+--------------------------+  concrete impl functions (core_trait_resolve.brp)
    |
    v
+-----------------------+
| Blorp Core resolution |  Tag calls as user/foreign/builtin/intrinsic/closure;
+-----------------------+  resolve UFCS, imports, constructors, and selected IDs
                           (core_resolve.brp)
    |
    v
+--------------------------+
| Blorp Core std inline    |  Expand the narrow allowlist of compiler-owned
+--------------------------+  list/tensor wrappers (core_std_inline.brp)
    |
    v
+-----------------------------+
| Blorp Core tailrec       |  Lower supported @tail_recursive self-calls into
+-----------------------------+  explicit Core loops (core_tailrec.brp)
    |
    v
+--------------------------+
| Blorp string fusion      |  Fuse supported string producer/consumer pipelines
+--------------------------+  (core_string_pipeline.brp)
    |
    v
+----------------------------+
| Blorp collection fusion    |  Fuse supported list/range pipelines into loops
+----------------------------+  (core_collection_pipeline.brp)
    |
    v
+-------------------------------+
| Blorp parallel tensor fusion  |  Fuse scoped vector/matrix parallel pipelines
+-------------------------------+  (core_parallel_tensor_pipeline.brp)
    |
    v
+-------------------------------+
| Blorp tensor update fusion    |  Fuse supported add-scaled tensor updates
+-------------------------------+  (core_tensor_fusion.brp)
    |
    v
+-------------------------------+
| Blorp tuple SROA              |  Scalar-replace non-escaping local tuples and
+-------------------------------+  narrow tuple-return call sites
                                  (core_tuple_sroa.brp)
    |
    v
+-------------------------------+
| Blorp Core specialization     |  One indexed traversal dispatches primitive,
+-------------------------------+  value, collection/stream, and tensor runtime
                                  layouts (core_specialize*.brp)
    |
    v
+--------------------------+
| Blorp tensor specialize  |  Fold length; dispatch numeric checked access,
+--------------------------+  raw-scalar fills, unary math, and reductions; form guarded
                              raw views for bounds-proven loops
                              (core_tensor_specialize.brp)
    |
    v
+--------------------------+
| Blorp function refs      |  Adapt bare first-class function values into eta
+--------------------------+  closures before ownership insertion
                              (core_closure.brp)
    |
    v
+----------------+
| Blorp DCE      |  Prune unreachable emitted functions and projected type
+----------------+  declarations using explicit reachability
                    (core_dce.brp)
    |
    v
+-------------------------+
| Blorp consume-specialize|  Clone safe source-owned self-replacement callees
+-------------------------+  with explicit consumed parameters before Perceus
                            (core_consume_specialize.brp)
    |
    v
+--------------------------+
| Blorp ownership prepare  |  Lower dictionary literals to explicit boxed
+--------------------------+  construction so Perceus can assign entry owners;
                              all other backend preparation remains late
                              (core_prepare.brp)
    |
    v
+--------------+
| Blorp Perceus|  Insert CDup/CDrop for reference counting
+--------------+  Koka-style precise RC: branch-aware, last-use semantics
                  (core_perceus.brp)
    |
    v
+------------------+
| Blorp Core_reuse |  Rewrite proven post-Perceus allocation reuse candidates
+------------------+  (core_reuse.brp)
    |
    v
+--------------------+
| Blorp closure      |  Hoist lambdas and build closure values
+--------------------+  (core_closure.brp)
    |
    v
+---------------------+
| Blorp Core_resource |  Resource-scope break/continue cleanup exits
+---------------------+  (core_resource.brp)
    |
    v
+---------------------+
| Blorp Core_fairness |  Cooperative checkpoints at loop boundaries
+---------------------+  (core_fairness.brp)
    |
    v
+--------------------+
| Blorp Core_prepare |  Supported final Core representation preparation
+--------------------+  (core_prepare.brp)
    |
    v
+-------------------+
| Blorp C emission  |  C artifact generation for the supported subset
+-------------------+  (core_emit.brp)
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
  `core_prepare.brp` rewrites final Core to explicit box/unbox nodes
  before emission.

The emitter contract follows from those principles: backend-specific emission
must consume explicit Core nodes and metadata rather than recovering layout,
boxing, or ownership behavior from source spelling.

**Core IR key files:**

| File | Purpose |
|------|---------|
| `core_json.brp` | Core IR type definitions and serialization |
| `core_collection_plan.brp` | Recognition and validated plans for Blorp-owned list/range pipeline fusion |
| `core_collection_policy.brp` | Layout and ownership policy for Blorp-owned collection fusion |
| `core_collection_pipeline.brp` | Expression-local Blorp-owned collection pipeline lowering |
| `core_parallel_tensor_pipeline.brp` | Scoped `Vector.parallel` / `Matrix.parallel` pipeline fusion |
| `core_tensor_fusion.brp` | Tensor update fusion before ownership insertion |
| `core_specialize_layout.brp` | Final collection, tensor, option, and erased-storage layout selection |
| `core_c_type_layout.brp`, `core_result_layout.brp` | C layout selection for option/result values |
| `core_ownership.brp` | Ownership contracts for intrinsics, builtins, and synthesized helpers |
| `compiler/blorp/src/stage_05_types/dim_solver.brp` | Canonical dimension arithmetic solver |

**Blorp compiler key files:**

| File | Purpose |
|------|---------|
| `compiler/blorp/src/stage_12_cli/cli_main.brp` | Production CLI and compiler entry point |
| `compiler/blorp/src/stage_09_core/core_json.brp` | Typed Core model and dump codec |
| `compiler/blorp/src/stage_09_core/core_traverse.brp` | Shared shallow Core expression traversal helpers for Blorp-owned passes |
| `compiler/blorp/src/stage_09_core/core_match.brp` | Authoritative raw-pattern to semantic decision-tree compilation |
| `compiler/blorp/src/stage_09_core/core_trait_resolve.brp` | Authoritative trait-method and overloaded-operator resolution |
| `compiler/blorp/src/stage_09_core/core_resolve.brp` | Authoritative call-kind, import, constructor, UFCS, and callable-identity resolution |
| `compiler/blorp/src/stage_09_core/core_std_inline.brp` | Authoritative narrow expansion of compiler-owned list/tensor wrappers |
| `compiler/blorp/src/stage_09_core/core_tailrec.brp` | Authoritative supported self-tail-call lowering into explicit Core loops |
| `compiler/blorp/src/stage_09_core/core_tuple_sroa.brp` | Authoritative scalar replacement for non-escaping local tuples and narrow unmanaged tuple-return call sites |
| `compiler/blorp/src/stage_09_core/core_specialize.brp` | Single recursive specialization driver and primitive/reflection specialization |
| `compiler/blorp/src/stage_09_core/core_specialize_layout.brp` | Shared indexed alias, declaration, ownership, and runtime-layout facts |
| `compiler/blorp/src/stage_09_core/core_specialize_value.brp` | Stringification, equality, and value-box specialization |
| `compiler/blorp/src/stage_09_core/core_specialize_collection.brp` | Collection, hash-container, Option ABI, stream, and fallback specialization |
| `compiler/blorp/src/stage_09_core/core_specialize_tensor_dispatch.brp` | Residual tensor arithmetic, matrix, access, fill, and result-layout dispatch |
| `compiler/blorp/src/stage_09_core/core_tensor_specialize.brp` | Authoritative length folding, numeric checked tensor-access, raw-scalar fill, unary tensor-math and numeric reduction dispatch, plus guarded raw-view formation for bounds-proven tensor loops |
| `compiler/blorp/src/stage_09_core/core_resource.brp` | Supported-route resource cleanup-exit rewriting |
| `compiler/blorp/src/stage_03_parse/source_ast_finalize.brp` | Typecheck-source AST finalization for interpolation, nested functions, and subscript reads |
| `compiler/blorp/src/stage_09_core/core_fairness.brp` | Supported-route cooperative checkpoint insertion |
| `compiler/blorp/src/stage_09_core/core_prepare.brp` | Supported-route final Core representation preparation subset |
| `compiler/blorp/src/stage_10_backend/core_emit.brp` | Supported-route C artifact emission subset |

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
├── blorp/                 # Blorp-owned compiler and CLI slices
│   └── cli_main.brp # Public executable entry point
├── lib/                   # Native runtime implementation
│   ├── runtime.c          # Embedded C runtime (ARC, collections, IO)
│   ├── runtime_decl.c     # Runtime forward declarations
│   ├── runtime_raylib.c   # Raylib-specific runtime
│   └── minicoro.h         # Coroutine library (M:N fiber scheduling)
├── test/                  # Frozen, non-executable OCaml test archive
└── tools/                 # Small build-time source generators

compiler/blorp/            # Blorp-authored compiler implementation slices
├── src/
│   ├── stage_01_file_io/        # Source text, spans, and diagnostics
│   ├── stage_02_lex/            # Tokens and lexer
│   ├── stage_03_parse/          # Parser, parsed AST, and parser bridge
│   ├── stage_04_modules/        # Module surfaces and type identities
│   ├── stage_05_types/          # Type model, context, Env, and builtins
│   ├── stage_06_typecheck/      # Graph/module binding, exact declaration headers, inference, bridge
│   ├── stage_07_ctfe/           # Compile-time evaluation
│   ├── stage_08_core_lower/     # Typed frontend to Core lowering
│   ├── stage_09_core/           # Core model, traversal, passes, manifests
│   ├── stage_10_backend/        # C artifact model, emission, codegen renderers
│   ├── stage_11_format/         # Formatter implementation
│   ├── stage_12_cli/            # CLI and bridge entrypoints
│   ├── stage_12_lsp/            # Native LSP protocol, workspace, analysis, and process
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
    ├── lint/              # Typed lint finding/clean fixtures
    └── codegen_audit/     # Codegen correctness tests
```

---

## Frontend

### Blorp Lexer (`compiler/blorp/src/stage_02_lex/lexer.brp`)

Blorp source lexer that tokenizes source text and emits spans, comments, and
docstrings for the parser bridge:

**Key features**:
- Significant whitespace (Python-style indentation)
- indent / dedent tokens for blocks
- String interpolation (`"Hello ${name}!"`)
- All keywords and operators

Token and keyword shapes are defined in `compiler/blorp/src/stage_02_lex/token.brp`.

### Blorp Parser (`compiler/blorp/src/stage_03_parse/language_parser.brp`)

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

Parser results remain typed Blorp values throughout normal compilation.
`parsed_ast_json.brp` is retained only for explicit benchmark and diagnostic
protocols; it is not a production compiler phase boundary.

The production module graph carries the module-loading context used during
Blorp import discovery: explicit std override, source-package aliases, and
local `pkg/` roots. The Blorp CLI applies that context once when preparing the
graph, so compilation does not depend on a second configuration scan.

### Parsed AST (`compiler/blorp/src/stage_03_parse/parsed_ast.brp`)

The parser produces phase-specific Blorp values for expressions,
declarations, patterns, and type syntax. Source locations remain attached to
those values so later diagnostics do not need to recover provenance from text.
`parsed_ast_traverse.brp` owns structural traversal, while
`source_ast_finalize.brp` performs the parser-adjacent normalization required
before module loading. The JSON codec is an explicit tooling protocol, not an
internal compiler boundary.

---

## Type System

The production Blorp typechecking frontend admits modules through explicit
immutable phase products before body inference. `CompilerBoundModuleGraph`
owns import visibility, `CompilerDeclarationSkeletonGraph` reserves
category-safe declaration identities, `CompilerAcyclicTypeAliasDependencyGraph`
proves that alias headers are constructible, and
`CompilerResolvedTypeParameterGraph` replaces type-declaration trait-bound
spellings with exact `CompilerTraitId` values. `CompilerTypeHeaderGraph` then
owns accepted record, struct, union, enum, builtin/resource, and alias headers,
including exact constructor identities and completed resource containment.
Modules with parser errors do not enter declaration skeletonization. Their
recovery AST remains a diagnostics/tooling artifact and cannot reserve a
semantic identity or poison an unrelated valid module later in graph
construction. The importable-module boundary stores accepted semantic contents
and parser-recovery contents as distinct private variants; recovery accessors
expose no declarations, signatures, implementations, bodies, or exports.
`CompilerTraitTopologyGraph` resolves direct
supertraits, trait type-parameter bounds, and trait-method owners to exact IDs,
records required versus default methods explicitly, and proves that trait
inheritance is acyclic before any body can be materialized. Shared visible
trait resolution uses source skeleton IDs when their module is loaded and a
disjoint compiler-surface module identity for known prelude traits otherwise.
Compiler-installed traits retain their complete inheritance in one builtin
topology manifest, including internal supertraits that are not directly
source-visible. Registration consumes the same enum-backed manifest, whose
inventory is checked for parity, closure, and acyclicity; transitive queries
fail closed rather than truncate at the compiler-surface boundary. Trait-method
IDs contain their exact owner and source-order index;
skeletons and topology slots cannot retain a contradictory owner, and method
lookup indexes the owner's ordered slots before validating the full opaque ID.
Topology indexes use graph-wide source-definition integers only as lookup keys
and validate the complete opaque trait identity on every read. Resolved
inheritance edges retain the parsed reference that established them, so early
topology failures remain structured, located diagnostics through production
graph preparation, including the exact edge that closes an inheritance cycle.
Compiler-known builtin traits remain source-visible, including operator traits,
but fallback never overrides a local declaration or explicit imported name.
`CompilerCallableHeaderGraph` then resolves ordinary function,
foreign-function, annotated-global, and pending-global headers once per
definition; trait method slots already belong to the topology graph, and
implementation methods belong to the implementation graph. An absent source
return annotation is normalized to exact intrinsic `Void` through the same
unconditional return-slot resolver as an annotated return, keeping exact
callable-ID ownership independent of an `Option` branch.
`CompilerImplementationHeaderGraph` resolves exact implementation owners,
traits, receivers, method signatures, and a conservative trait/receiver-head
candidate index. Implementation methods cannot redeclare an
implementation-owned type parameter, so each resolved parameter has one exact
owner domain. Production local and imported registration consume these
accepted headers; parsed declarations remain provenance and body input rather
than being replayed to reconstruct semantic signatures per importer. A narrow
compatibility adapter projects resolved shapes into the legacy Env naming
model. Replacing Env's string-oriented trait references belongs to the later
body-context migration. Type-header and topology construction errors retain
their parsed source spans through the production bridge whenever a specific
declaration or reference caused the failure.
Body-bearing module projections remain a separate opaque
`CompilerImportableModuleGraph`, constructed once from the indexed graph.
`CompilerAcceptedTypecheckGraph` validates that those definition and body
products have compatible graph provenance before coupling them. A module
reaches graph-backed typechecking only through opaque
`CompilerAcceptedTypecheckModule`, which additionally validates that its exact
module identity belongs to the accepted bound graph, its selected binding has
compatible graph provenance, and its typecheck state is reserved for that
module scope. Ordinary typechecking selects the canonical graph binding by
identity. Reusable CTFE artifacts use a separately named constructor for their
deliberately narrower alternate binding; that constructor derives the binding
from the accepted graph's dependency-only inventory rather than accepting one
from its caller. The accepted module retains canonical versus artifact import
scope so body materialization cannot widen an artifact back to the target-aware
inventory.
Prepared typechecking contexts retain the strongest completed product; later
phases cannot mix graph products, mutate the opaque header graph, infer these
invariants from `Env` contents, or replay parsed imports.
`CompilerTypecheckTypeHome` entries are transient provenance for names
projected into one module's environment, not a second owner of definition
identity.

### Semantic Types and Environments

`compiler/blorp/src/stage_05_types/semantic_type.brp` defines the canonical
semantic type model. `env.brp` and `context.brp` own scoped values and the
context required to resolve them. Builtin declarations, generic parameters,
refinements, dimensions, and widening each have a focused module in the same
stage. These are Blorp data structures shared directly with typechecking; there
is no host-language projection to keep synchronized.

### Inference and Typechecking

Stage 06 performs bidirectional expression inference and declaration checking.
`infer.brp` owns expression inference, `typecheck_decl.brp` owns declaration
validation, and `frontend_graph_typecheck.brp` applies those operations to the
accepted module graph. `typecheck_state.brp` and `typecheck_types.brp` define
the state and typed products passed onward.

This stage validates purity, pattern exhaustiveness, tail-recursion
annotations, concurrency restrictions, and ordinary type compatibility. It
must preserve resolved identities from the frontend graph instead of
reconstructing declarations from strings or parsed source.

See [COMPILER_ROADMAP.md](COMPILER_ROADMAP.md) for the active path toward a
single semantic call-target model shared by `check`, `compile`, and `purify`.

---

## Modules

### Module Resolution (`compiler/blorp/src/stage_04_modules/`)

`project_source_catalog.brp` discovers project, standard-library, and package
sources. `frontend_import_plan.brp` resolves imports, and
`frontend_graph_service.brp` constructs the canonical graph consumed by
typechecking. `module_surface.brp` records importable declarations without
introducing a serialization boundary. `loaded_module.brp` is the explicit
phase carrier for source, parsed, and accepted module information.

Import discovery and semantic graph construction are separate operations so a
parser recovery value cannot accidentally become an accepted declaration.
The graph owns module identities and origins once; later phases consume those
facts rather than rescanning paths or AST text.

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

### Code Generator (Blorp Core IR)

Codegen runs entirely through the Blorp-owned Core IR pipeline. Core passes
(see "Core IR Pipeline" above) make representation decisions explicit before
the stage-10 backend renders the final C artifact.

**Key concepts**:

**Monomorphization** (`compiler/blorp/src/stage_09_core/core_monomorphize.brp`):
Generic functions are specialized per type:
```c
// blorp: func identity[T](x: T) -> T
// C: long identity_Int(long x)
// C: double identity_Float(double x)
```

**Closure formation** (`compiler/blorp/src/stage_09_core/core_closure.brp`): Bare
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

**Perceus RC** (`compiler/blorp/src/stage_09_core/core_perceus.brp`):
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
`compiler/blorp/src/stage_12_cli/cli_main.brp`. It performs
user-facing command planning, source discovery, source reads, parsing,
typechecking, Core preparation, backend coordination, and migrated host
effects. Compile, run, test, format, purify, lint, package, LSP, help, and
version reporting are Blorp-owned.

User-facing subcommands:

```bash
./blorp compile program.brp      # Compile to generated C
./blorp check file.brp           # Type check one file
./blorp check src/               # Type check .brp files recursively
./blorp compile --ast file.brp   # Print AST
./blorp run program.brp          # Compile and run quickly (-O0)
./blorp run --release program.brp # Compile and run optimized (-O2)
./blorp test tests/              # Run test suite
./blorp lint src/                # Report typed source findings
```

---

## How-To Guides

### Adding a New Keyword

1. **Lexer** (`compiler/blorp/src/stage_02_lex/lexer.brp`):
   - Add keyword handling.
   - Return the appropriate `compiler_token` value.

2. **Parser** (`compiler/blorp/src/stage_03_parse/language_parser.brp`):
   - Add grammar rules

3. **Shared language surface and editor metadata**:
   - If the keyword is user-facing, add it to
     `compiler/blorp/src/stage_05_types/language_surface_manifest.brp` for
     shared tooling metadata and native LSP completion. Do not add
     legacy/error-only tokens such as removed syntax.
   - Update shared TextMate and language-configuration metadata under
     `editor/`, then run `scripts/check-editor-drift`.

4. **Parsed AST** (`compiler/blorp/src/stage_03_parse/parsed_ast.brp`):
   - Add new variant to appropriate type

5. **Typecheck** (`compiler/blorp/src/stage_06_typecheck/`):
   - Add type checking for new construct

6. **Core lowering** (`compiler/blorp/src/stage_08_core_lower/core_lower.brp`):
   - Translate the new typed AST node into Core IR. If the construct desugars
     to existing Core, handle it in the owning Blorp middle-Core pass instead.
   - If the construct has build-mode semantics like `debug:`, represent it
     explicitly in Core and lower it in a dedicated pass before shared
     optimizations.
   - There is no OCaml lowering fallback; all source-to-Core behavior belongs
     on the contiguous Blorp path.

7. **Core emission** (`compiler/blorp/src/stage_10_backend/core_emit.brp`):
   - Emit C for the new Core node, if one was introduced.

### Adding a New Builtin Function

1. **Prelude** (`std/prelude.brp`):
   ```blorp
   pure func new_builtin(x: Int) -> Int:
       builtin
   ```

2. **Type metadata** (`compiler/blorp/src/stage_05_types/`):
   - Register the builtin type signature and effect behavior in the
     authoritative Blorp metadata.

3. **Compiler metadata and Core synthesis**:
   - Record compiler-visible inference/effect behavior in the authoritative
     Blorp builtin metadata under `compiler/blorp/src/stage_05_types/`.
   - Register compiler-owned Core intrinsics in `INTRINSIC_SPECS` in
     `compiler/blorp/src/stage_10_backend/codegen_intrinsic_renderer.brp` and
     synthesize their call sites through the Blorp `compiler_core_synth_*.brp`
     families.
   - Define managed-value contracts in
     `compiler/blorp/src/stage_09_core/core_ownership.brp`, the single
     source of truth consumed by the Blorp Core and backend stages.

4. **Runtime** (`runtime.c` and `runtime_decl.c`):
   - Add the C implementation **and** its forward declaration if the builtin
     is runtime-backed. Pure Core-synthesized helpers may not need a runtime
     entry.

### Adding a New Type

1. **Parsed and semantic types**:
   - Add type representation if needed

2. **Parser** (`compiler/blorp/src/stage_03_parse/language_parser.brp`):
   - Handle in type parsing rules

3. **Type rules** (`compiler/blorp/src/stage_05_types/` and
   `compiler/blorp/src/stage_06_typecheck/`):
   - Add semantic representation and equality/compatibility rules

4. **Representation and emission**:
   - Update the relevant Blorp Core layout/specialization pass and the stage-10
     emitter when the type needs a distinct runtime representation.

5. **Runtime** (`runtime.c`):
   - Add runtime support if heap-allocated

---

## Testing

### Test Organization

See the `tests/` layout in "Source Directory Structure" above for the full
list of subdirectories. The runtime tests are grouped under `tests/test_blorp/`
by domain (types, text, collections, numeric, sys, memory, functions,
concurrency, simd) and the compiler tests under
`tests/test_compiler/` by phase (parser, infer, typecheck, format, purify, lint,
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

# Build only the self-hosted compiler target
make build-blorp-cli
```

### Build Outputs

- `./blorp` - Main compiler executable (copied from `compiler/_build/`)
- `./blorp compile file.brp` writes generated C next to the source as
  `file.c` unless `-o PATH` is provided.
- `./blorp run` compiles, links, and executes through Blorp-owned temporary
  artifacts.
- `./blorp test` is fully Blorp-owned. It discovers TestSuite and doctest
  sources, loads each frontend graph once per bounded batch and repeat,
  combines compatible sources at explicit ownership boundaries, and executes
  generated artifacts through captured process sessions. It has no OCaml
  fallback route.
- OCaml test execution has been retired. `compiler/test/test_*.ml` remains only
  as a non-executable historical archive, with no Dune, Make, CMake,
  `scripts/test`, CI, or Alcotest wiring. The 19 production-marked compiler
  fixtures run through the Blorp-only `run_blorp_check_fixtures.py` runner in
  `compiler-blorp`.
- Public formatter, purify, and lint fixture coverage runs serially through production
  CLI commands in the explicit `compiler-tools` gate.

### Test Command Ownership

Focused compiler ownership is explicit in
`compiler/blorp/tests/compiler_test_ownership.json`. The versioned manifest
defines every suite and special-check identifier once, then assigns every
tracked production module under `compiler/blorp/src/` to exactly one stage,
one or more focused suites, optional special checks, and the `compiler-blorp`
integration gate. `scripts/compiler-check` validates and plans from those exact
entries; it never derives ownership from module names, imports, timing data, or
failure history. `make quality` rejects incomplete or unsupported manifests.

`scripts/compiler-check` prepares the current compiler at most once, batches
the selected suites through the ordinary `blorp test` path, and delegates
registered special gates to `scripts/test --no-build --log-dir`. Its focused
result does not replace the broader integration gate described below.

`blorp test` is serial and invocation-local. Discovery canonicalizes requested
paths before constructing frontend graphs. The default partition policy limits
each graph to eight roots and 512 KiB of retained source; a repeated root module
identity always starts a new partition. `--maximal-artifacts` removes the size
limits for a corpus already qualified to coexist, but is rejected for sanitizer
runs. Semantic compatibility is mandatory: roots with incompatible standard-
library or package contexts fail before execution. Capacity limits may split a
compatible corpus further but can never merge incompatible roots.

Each active partition owns its immutable parsed sources, resolved import graph,
generated doctest roots, and direct aggregate harness until that partition has
executed. Materialization may project the retained graph or add a harness, but
must not rediscover, reread, or reparse an original source. Generated TestSuite
and doctest calls use static module identities rather than runtime selectors.
Every artifact uses the ordinary compiler pipeline. Unsupported behavior fails
explicitly; test execution has no fallback or silent semantic downgrade.

One test invocation discovers the host toolchain, prepares runtime inputs, and
installs its signal broker once. Native subprocesses exist only for required C
compilation and compiled test execution. Output capture is bounded. Ordinary
test failures are aggregated while infrastructure failures and interruption
stop later artifacts; cleanup restores the signal broker and terminates the
owned process group. Linux CI retains process-session timeout coverage because
process-group and pipe-drain behavior differs from macOS.

The registered feedback and regression workloads live in
`scripts/bench-blorp-test-session`. Historical combined-artifact measurements
are recorded in
[`benchmarks/results/blorp_test_combined_artifacts_2026-08-08.md`](../benchmarks/results/blorp_test_combined_artifacts_2026-08-08.md).

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
