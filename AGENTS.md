# blorp

A compiler for a functional programming language with pure/impure function tracking, algebraic data types, and pattern matching.

## Language Principles

The priorities of the language, in order: **safe, understandable, expressive, simple, fast, easy to learn,
predictable for tools to generate and humans to debug.**

All work on the compiler, standard library, documentation, and examples should uphold these principles.

### Safety

**1. No runtime panics — operations succeed by design.**
Division by zero returns 0, integer overflow wraps, there is no null. The runtime should never
surprise you with a crash. Reserve `Option`/`Result` for genuinely fallible operations. Infrastructure
exceptions (OOM, fiber stack overflow) are acceptable but language-level operations must be infallible.

**2. Value semantics — no shared mutable state, no cyclic data.**
Assignment copies. Closures capture by value. Record update creates new records. ARC works without
a cycle collector because cycles are structurally impossible. This is the architectural foundation
that makes everything else work — thread safety, deterministic memory, local reasoning.

**3. Thread-safe by default.**
Atomic reference counts. Value semantics. Channels for communication. The language does not give you
shared mutable references. You don't opt into thread safety — it's the only option.

### Understandability

**4. Purity tracking — the compiler tells you what has side effects.**
`pure func` is enforced by the compiler. Pure functions cannot call impure functions. Local mutation
is allowed in pure functions (pragmatic — it doesn't affect determinism). This enables safe
parallelization, caching, and equational reasoning.

**5. Immutability by default.**
`x = 5` is immutable. `var x = 5` is explicit opt-in to mutation. You see at a glance what can change.
Closures cannot capture mutable variables.

**6. Pattern matching with exhaustiveness checking.**
The compiler tells you when you've missed a case. Impossible states become compile errors.
Pattern matching is the primary control flow mechanism for conditional logic.

### Expressiveness

**7. Expressions over statements — everything returns a value.**
`if` and `match` are expressions. The last expression in a function body is the return
value. `?=` provides explicit Option/Result propagation without exceptions.

**8. UFCS for composition — any function is a method.**
`x.f(args)` desugars to `f(x, args)`. Enables left-to-right method chaining without OOP.
This is the primary composition mechanism — it replaces pipeline operators, method chains,
and nested function calls with a single, readable syntax.

**9. Traits for polymorphism — no class inheritance.**
Operator overloading via `Addable`/`Equatable`/etc. Generic bounds via `T: Orderable`.
The type system is flat and predictable. Trait method imports should work for any type
that implements the trait, not just the module they were imported from.

### Simplicity

**10. Minimize ceremony — don't force unwrapping things that can't fail.**
`length` returns `Int` not `Option[Int]`. If an operation can be made infallible by design,
do that instead of forcing error handling. The goal is less boilerplate, not less safety.

**11. Readable syntax — indentation-based, keyword operators, minimal noise.**
`and`/`or`/`not` instead of symbols. Colon + indent for blocks. Braces for records/dicts/vectors
(not for control flow). The code should read close to pseudocode.

### Speed

**12. Deterministic resource management — ARC, no GC.**
No garbage collector. No GC pauses. Predictable performance. Objects are freed when their reference
count drops to zero. COW makes "immutable" collections fast when uniquely owned.

**13. Compiles to C — native performance, any platform.**
The compilation target is the performance strategy. SIMD for vectors, direct C interop via
`foreign func`, and the entire C optimizer toolchain. The generated C should be clean enough
for the C compiler to optimize well.

**14. Compile-time safety with graduated escape hatches.**
Tensor dimensions verified statically. Range types (`..#N`) for proven-safe indexing with
zero runtime cost. `get()` for runtime-checked access when compile-time proof isn't possible.
Static where we can, dynamic where we must, infallible by default.

### Easy to Learn / Tool-Friendly

**15. Structured concurrency.**
`concurrent:` blocks auto-join all spawned work. No orphaned tasks. `detach` for explicit
fire-and-forget. Simple mental model that's hard to misuse.

**16. Clean C interop.**
`foreign func` is one declaration. Any C library is accessible. Low barrier to extending
the language with existing ecosystems.

### For Agents

When making decisions about the language, compiler, or standard library, use these principles
as a tiebreaker:

- If a change makes the language safer but more verbose, prefer safety (principles 1-3).
- If a change makes the language more expressive but harder to understand, prefer understandability (principles 4-6).
- If a change improves performance but adds complexity, prefer simplicity (principles 10-11) unless the performance gain is substantial.
- When in doubt, ask: "Would this make generated code easier to write correctly and human-written code easier to read and debug?"

When documentation, tests, and implementation disagree:

- Trust the relevant tests and current implementation first, then update the stale docs in the same change.
- For pipeline questions, start with `compiler/lib/core_pipeline.ml`, `compiler/lib/core_stage.ml`, `docs/ARCHITECTURE.md`, and `compiler/bin/blorp.ml`.
- For tensor questions, start with `std/tensor.brp`, `std/vector.brp`, `std/matrix.brp`, `compiler/lib/dim_solver.ml`, `compiler/lib/infer.ml`, `compiler/lib/core_specialize.ml`, `compiler/lib/runtime.c`, and the matching `tests/test_compiler` / `tests/test_blorp` cases.

When choosing implementation strategies:

- Do not rely on flimsy heuristics. If correctness depends on a distinction, represent it explicitly in the AST/IR/data model, a parser or type-checker rule, or a named configuration point. Avoid guessing from names, shapes, string prefixes, source formatting, or "usually true" patterns unless there is no better representation; if a heuristic is unavoidable, isolate it, document the tradeoff, and cover failure modes with tests.
- Avoid magic values. Give non-obvious numbers, strings, limits, sentinel values, and protocol constants meaningful names at the narrowest useful scope. If a literal is required by an external format, ABI, wire protocol, or compiler invariant, name it or document that source of truth near the value.
- Make illegal states unrepresentable, especially in compiler code. Prefer precise variants, phase-specific types, explicit enums, and smart constructors over boolean flag combinations, stringly typed tags, nullable fields with hidden coupling, or comments that describe invariants the type system could enforce. Push validation to construction boundaries so later phases can rely on well-formed inputs.

---

## Development Rules

How we work on blorp. These apply to every change — features, bug fixes, refactors.

### Naming

Names are part of the design. Files, modules, functions, datatypes, variants, fields, variables,
compiler passes, helper utilities, tests, and documentation examples should use names that are
meaningful, clear, and proportional to their scope.

- Prefer names that explain the concept or invariant, not the implementation accident.
- Avoid cryptic abbreviations, single-letter names, and overloaded shorthand unless the convention
  is universal in the local context (`i` for a short loop index, `T` for a type parameter).
- Avoid names that are so long they hide the structure of the code. If a name needs a sentence,
  the concept may need a smaller helper, a clearer type, or a comment.
- Match existing naming style in the surrounding subsystem unless the existing style is clearly
  misleading; if you introduce a new convention, document it near the boundary where it matters.
- Tests should name the behavior or regression they protect, not just the API they call.
- Internal compiler names should expose phase and ownership of responsibility when that prevents
  confusion, for example distinguishing parser, typed AST, Core, specialization, and emission data.

### Before you write code

**1. Write a failing test first.** We strongly prefer TDD. Define what success looks like
before writing implementation. For parser changes: `should_pass/` and `should_fail/` cases. For
type system changes: `infer/` and `typecheck/` cases. For runtime behavior: `test_blorp/` tests.
For bug fixes: a regression test that fails before the fix and passes after.

**2. One change per change.** Fix the bug, add the feature, or refactor — not all three.
If you discover adjacent work, note it separately. If you can't describe your change in one
sentence, it's too big.

**3. Check for precedent.** Before implementing, look at how blorp already handles similar things.
Follow existing naming conventions, error styles, and API patterns. If you're establishing a
new pattern, call it out explicitly.


### While you write code

**4. Catch mistakes at compile time, not runtime.** Reject errors at the earliest phase where
the necessary information exists. Syntax errors in the parser. Name errors after parsing.
Type errors in type-checking. Never add semantic checks in codegen unless monomorphization
forces it. Every compile error should include a help suggestion that teaches the user what
to do instead.

**5. Optimize for the first-time user.** If a feature requires reading the GUIDE to use correctly,
it needs a better error message. If an error says "unexpected token" with no hint, it's incomplete.
Think about what a programmer coming from Python, JS, or Rust would try first, and make that
either work or produce a helpful message.

**6. Respect phase boundaries.** The compiler pipeline is:

    lex → parse → interp desugar → module load →
    subscript desugar → infer/typecheck →
    core_lower + core_ffi_boundary + core_list_layout →
    core_debug → core_desugar + core_ssa →
    core_mono + core_list_layout → core_synth → core_match →
    core_trait_resolve → core_resolve → core_std_inline → core_tailrec →
    core_string_pipeline + core_collection_pipeline + core_parallel_tensor_pipeline +
    core_tensor_fusion + core_tuple_sroa →
    core_specialize → core_dce → core_consume_specialize → core_perceus → core_reuse → core_closure →
    core_resource → core_fairness → compiler_core_prepare → core_reuse(prepared unions) → backend emit

Don't put type-checking logic in Core IR passes or parsing constraints in
type-checking. If a check belongs in an earlier phase, move it there. If it must stay in a
later phase (e.g., monomorphization in `core_mono`), document why. See
`docs/ARCHITECTURE.md` for the current pipeline reference.

**7. Measure, don't guess.** If there's any doubt about efficiency, use `--profile` for runtime
cost and `--leak-check` for memory. Claims like "this is faster" require before/after numbers.
Improve the profiling and memory tools when you find gaps.

### After you write code

**8. Prove it works.** Every change must include evidence: passing tests, benchmark numbers,
or before/after error message comparison. "It compiles" is not proof. For error paths, verify
the error message content — a `should_fail` test that doesn't check the message is incomplete.
For codegen changes, read the generated C.

**9. Get it reviewed.** Every change gets reviewed before commit. Use the code-reviewer and
test-runner agents. No exceptions for "trivial" changes — trivial changes have trivial reviews.

**10. Update docs with the code.** If your change is user-facing (syntax, API, error message),
update `docs/GUIDE.md` and `docs/GRAMMAR.md` in the same commit. Documentation drift is a bug.
The formal grammar must stay in sync with the parser.

**11. Prefer coherent pre-0.1 behavior over backwards compatibility.** Blorp is pre-0.1.0, so
do not preserve old syntax, APIs, or compatibility shims merely to avoid breaking users. If the
new behavior is clearer, safer, or simpler, remove the old form and make the current language
coherent. Breaking changes still require updating all call sites in std/, tests/, examples/, docs,
and formatter expectations in the same change. Add migration-style error messages only when they
meaningfully improve first-time user experience or prevent confusing parser/typechecker failures.

**12. Focus on quality.** If your code is not ready to pass a review for production, then your
work is incomplete. Do not settle for ad-hoc hacks or incoherent architecture.

**13. Document the "Why"s.** When your code is read in the future, readers need to understand why
any non-obvious solutions exist.

**14. Keep Track of Rough Edges.** If you run into obstacles, confusion, or bugs, surface them. We
don't want subtle bugs to remain simmering under the surface.

---

## Build Commands

```bash
# Build the compiler (outputs ./blorp in project root)
make

# Run default local tests (compiler-unit + compiler + runtime + leak + doctest + cli)
scripts/test

# Run specific test gates
scripts/test compiler-unit      # Compiler-internal OCaml/Alcotest unit-shaped tests
scripts/test compiler-unit-deep # Compiler-internal integration-shaped Alcotest tests
scripts/test compiler           # Fast compiler surface tests
scripts/test compiler-deep      # Generated-C audit, format/purify, compiler/blorp
scripts/test compiler-core-sanitize # Focused Core .brp tests under ASan + UBSan
scripts/test compiler-blorp-sanitize # Compiler-owned .brp tests under ASan + UBSan
scripts/test std-check          # Broad std/ typecheck sweep
scripts/test runtime            # Runtime .brp tests
scripts/test leak               # Focused leak-check baselines
scripts/test doctest            # Doctests (std/ library)
scripts/test cli                # CLI smoke and exit-code checks
scripts/test compiler-unit compiler  # Multiple gates
scripts/test --serial           # Run selected gates one at a time
scripts/test --coverage         # Compiler-unit coverage report
scripts/test --no-build         # Test the existing installed toolchain
scripts/test --timings          # Print unit cases and generated-suite phases
scripts/test --verbose          # Print pass-by-pass child-runner output
scripts/test --log-dir logs     # Save complete gate logs with compact console output

# Run individual test files
./blorp test tests/test_blorp/factorial.brp

# Makefile shortcuts
make test                         # Top-level local test gate
make runtime-test                 # Runtime tests only
make compiler-core-sanitize-test  # Late-Core Blorp suites under ASan + UBSan
make compiler-unit-test           # Compiler-internal OCaml/Alcotest unit-shaped tests
make compiler-unit-deep-test      # Compiler-internal integration-shaped Alcotest tests
make coverage                     # Compiler-unit coverage
make quality                      # Hygiene + C static analysis
make docker-gate                  # Normal test gate in Ubuntu Docker (linux/amd64)
make docker-premerge-gate         # Premerge gate in Ubuntu Docker (linux/amd64)
make docker-premerge-gate-all     # Premerge gate in Ubuntu Docker (linux/amd64 + linux/arm64)
```

### Preview Gate

Before cutting a preview build, run the normal build/test gates plus any
README-supported examples currently restored under `examples/`. A nonzero exit,
timeout, leaked background process, or untriaged generated-C warning is a gate
failure.

```bash
make
scripts/test compiler-unit
scripts/test compiler-unit-deep
scripts/test compiler
scripts/test compiler-deep
scripts/test std-check
scripts/test runtime
scripts/test leak
scripts/test doctest
scripts/test cli
```

The runtime gate uses `BLORP_TEST_TIMEOUT` when set and otherwise runs with a
30-second per-test timeout. The compiler gate defaults each individual compiler
invocation and codegen-audit case to 30 seconds, while grouped compiler-owned
Blorp suites default to 180 seconds; set
`BLORP_COMPILER_TEST_TIMEOUT` to override only compiler tests, or
`BLORP_TEST_TIMEOUT` to share one timeout across compiler/runtime gates.
Compiler sanitizer gates default to 180 seconds per generated test binary;
`BLORP_COMPILER_SANITIZE_TEST_TIMEOUT` overrides that measured ASan allowance.

When preview examples are restored, list their exact check/run/format commands
here. Do not gate preview on ignored `scratch/` files.

CLI smoke for preview builds:

```bash
tmpc=$(mktemp "${TMPDIR:-/tmp}/blorp-preview.XXXXXX.c")
smoke=$(mktemp "${TMPDIR:-/tmp}/blorp-preview.XXXXXX.brp")
trap 'rm -f "$tmpc" "$smoke" /tmp/blorp-repl-smoke.out /tmp/blorp-lsp-smoke.out' EXIT

cat > "$smoke" <<'BRP'
func main(args: List[String]) -> Int:
	print("preview smoke")
	0
BRP

./blorp check --no-format "$smoke"
./blorp compile --no-format -o "$tmpc" "$smoke"
./blorp run --timeout 5 --no-format "$smoke"
./blorp test --no-cache --timeout 5 tests/test_blorp/types/test_bool.brp
./blorp test --warmup-only
./blorp test --leak-check --suite --timeout 5 \
  tests/test_blorp/memory/leak_check_baselines/empty_main.brp
./blorp test --sanitize --timeout 5 tests/test_blorp/types/test_bool.brp
printf ':quit\n' | ./blorp repl >/tmp/blorp-repl-smoke.out
./blorp lsp </dev/null >/tmp/blorp-lsp-smoke.out
```

Environment smoke for preview builds:

```bash
env BLORP_TIMEOUT=5 ./blorp test tests/test_blorp/types/test_bool.brp
env BLORP_STD=std BLORP_NO_FORMAT=1 ./blorp check tests/test_blorp/types/test_bool.brp
env BLORP_SANITIZE=1 ./blorp test --timeout 5 tests/test_blorp/types/test_bool.brp
```

Default generated-C compile/test paths suppress noisy generated-code warnings.
The codegen audit suite performs the preview warning sweep; any warning promoted
there is a gate failure and must either be fixed or explicitly documented as
benign before preview release.

For local Linux architecture parity, use Docker:

```bash
scripts/docker-gate --premerge-gate --platform linux/amd64
scripts/docker-gate --premerge-gate --platform linux/arm64
scripts/docker-gate --premerge-gate --all-platforms
```

The Docker premerge gate runs `scripts/premerge-gate --no-docker` inside the container
to avoid nested Docker. Cross-architecture runs require Docker support for the
requested platform, for example Docker Desktop or configured QEMU/binfmt.

Current triage: Clang `-Wparentheses-equality` warnings from generated
comparisons with extra defensive parentheses are benign. `-Wunsequenced` and
`-Wincompatible-pointer-types` warnings are not accepted in the preview warning
sweep; regressions for those classes live in the codegen audit suite.

`./blorp test --warmup-only` must succeed before parallel gates. Warmup compiles
a minimal program through the production Blorp executable, populating the same
Blorp-owned runtime cache used by subsequent test artifacts.

## CLI Usage

The compiler uses subcommands. Run `./blorp --help` for full usage.

```bash
# Compile a .brp file
./blorp compile program.brp

# Type check only (no codegen)
./blorp check program.brp

# Show AST only
./blorp compile --ast program.brp

# Dump Core after specific stages
./blorp compile --dump-core-after=lower,mono,closure program.brp

# Stop after a stage and auto-dump that snapshot
./blorp compile --stop-after=resolve program.brp

# Debug Core invariants
./blorp compile --check-invariants --dump-core-after=match program.brp

# Compile and run
./blorp run program.brp

# Compile and run with optimized generated C
./blorp run --release program.brp

# Compile and run with CLI arguments
./blorp run program.brp -- arg1 arg2 arg3

# Run with profiling
./blorp run --profile program.brp

# Run a single test file
./blorp test tests/test_blorp/types/test_accessor.brp

# Run all tests in a directory
./blorp test tests/test_blorp/

# Run tests with profiling
./blorp test --profile tests/test_blorp/functions/

# Format source files
./blorp format file.brp           # Format in place
./blorp format --check file.brp   # Check without modifying (exit 1 if unformatted)
./blorp format --check --diff dir/ # Show diff for unformatted files

# Auto-mark pure functions
./blorp purify file.brp           # Modify file in place
./blorp purify --dry-run file.brp # Show what would change

# Start LSP server (used by editor extensions)
./blorp lsp

# Interactive REPL
./blorp repl
```

Notes:

- `--dump-ast` and `--dump-typed-ast` print summaries, not a full expression tree.
- For compiler debugging, prefer `--dump-core-after=...` and reading the generated C.

## Project Structure

```
compiler/            # OCaml compiler implementation
  blorp/          # Blorp-owned compiler frontend/backend slices
  bin/            # CLI executables
    blorp.ml      # Main unified CLI
  test/           # Compiler-internal OCaml/Alcotest tests
    run_tests.ml  # Test runner
    test_types.ml # Types module tests
    test_env.ml   # Env module tests
  lib/            # Compiler library
    ast.ml        # AST type definitions
    typecheck.ml  # Type checker
    infer.ml      # Type inference
    types.ml      # Type utilities
    env.ml        # Environment/symbol tables
    env_builtins.ml  # Builtin function environment
    modules.ml    # Module/import system
    pipeline.ml   # Compilation pipeline orchestration
    diagnostics.ml  # Rust-style error formatting
    interp_parser.ml  # String interpolation parser
    embedded_std.ml   # Embedded std library (generated by make)
    test_runner.ml    # Test execution and caching
    repl.ml           # Interactive REPL
    line_editor.ml    # REPL line editing
    runtime.c         # Embedded C runtime
    runtime_decl.c    # Runtime forward declarations
    runtime_raylib.c  # Raylib-specific runtime
    minicoro.h        # Coroutine library (M:N fiber scheduling)
    core.ml           # Core IR type definitions and traversal helpers
    core_lower.ml     # Typed AST → Core IR lowering
    core_ffi_boundary.ml  # Checked FFI argument-boundary policies
    core_debug.ml     # debug: block erasure/retention by build mode
    core_desugar.ml   # Core IR sugar elimination
    core_ssa.ml       # Mutable-local lowering used by core_desugar
    core_mono.ml      # Core IR monomorphization
    core_list_layout.ml  # List storage layout annotation
    core_synth.ml     # Post-mono body synthesis for concrete builtins
    core_match.ml     # Core IR pattern match → decision tree
    core_trait_resolve.ml  # Trait-method and overloaded-operator rewrite
    core_resolve.ml   # Core IR call kind resolution
    core_std_inline.ml  # Narrow call-site expansion for compiler-owned std wrappers
    core_tailrec.ml   # @tail_recursive self-call lowering
    core_string_pipeline.ml  # Core IR string producer/consumer fusion
    core_collection_pipeline.ml  # Core IR collection pipeline fusion
    core_parallel_tensor_pipeline.ml  # Scoped vector/matrix pipeline fusion
    core_tensor_fusion.ml  # Core IR tensor update fusion
    core_tuple_sroa.ml  # Core IR non-escaping local tuple scalar replacement
    core_specialize.ml  # Core IR type-dispatch builtins → CCast / concrete names
    core_consume_specialize.ml  # Core IR consuming-call specialization before Perceus
    core_perceus.ml   # Core IR Perceus RC insertion
    core_reuse.ml     # Core IR post-Perceus reuse analysis and prepared union reuse
    core_resource.ml  # Resource-scope cleanup-exit lowering
    core_fairness.ml  # Cooperative loop checkpoint insertion
    core_emit_blorp_c.ml  # Core JSON projection and Blorp bridge client
    core_pipeline.ml  # Core IR pipeline orchestration
    core_emit_util.ml, core_emit_layout.ml  # Shared late-backend helpers
    core_intrinsics.ml  # IR body synthesis for builtins/intrinsics
    core_intrinsic_registry.ml  # Intrinsic manifest and contracts
    core_invariants.ml  # Stage-boundary invariant checks
    core_error.ml     # Core IR structured errors
    language_surface.ml  # Shared source-language surface facts for tooling/typecheck
    codegen/      # Shared codegen utilities used by the core-emit pipeline
      codegen_names.ml     # C name mangling (UFCS, modules)
      codegen_types.ml     # Type classification and AST → C type mapping
      codegen_builtins.ml  # Builtin function registry
    lsp/          # Language Server Protocol
      lsp_server.ml     # LSP main loop
      lsp_completion.ml # Autocomplete
      lsp_hover.ml      # Hover information
      lsp_signature.ml  # Signature help
      lsp_symbols.ml    # Document symbols
      lsp_state.ml      # Server state
      lsp_protocol.ml   # LSP message types
      lsp_rpc.ml        # JSON-RPC transport
      lsp_json.ml       # JSON parsing
      lsp_position.ml   # Source position utilities

std/              # Standard library (.brp files)
  prelude.brp     # Documents builtins available without imports
  test.brp        # Test framework
  traits.brp      # Core traits
  option.brp      # Option[T] type
  result.brp      # Result[T,E] type
  list.brp        # List[T] operations
  dict.brp        # Dict[K,V] operations
  set.brp         # Set[T] operations
  bytes.brp       # Bytes type
  heap.brp        # Priority queue (min-heap)
  deque.brp       # Double-ended queue
  sorted_map.brp  # Sorted key-value map
  int.brp, float.brp, bool.brp, char.brp  # Primitives
  int8.brp, int16.brp, int32.brp, int128.brp  # Sized signed integers
  uint8.brp, uint16.brp, uint32.brp, uint64.brp, uint128.brp  # Sized unsigned integers
  float16.brp, float32.brp, fixed.brp  # Sized floats and fixed-point decimals
  string.brp, slice.brp  # String ecosystem
  parser.brp, regex.brp  # Text processing
  math.brp, tensor.brp, vector.brp, matrix.brp, stats.brp, units.brp  # Numeric
  parallel_vector.brp, parallel_matrix.brp  # Scoped vector/matrix parallel views
  geometry.brp, geographic.brp, geojson.brp, physics.brp  # Spatial
  dsp.brp, fft.brp, noise.brp  # Signal/procedural helpers
  random.brp, crypto_random.brp  # Random
  io.brp, file.brp, system.brp, debug.brp, memory.brp, instrumentation.brp, time.brp  # System
  path.brp, process.brp, log.brp, terminal.brp  # OS/terminal
  csv.brp, html.brp, json.brp, toml.brp, xml.brp, yaml.brp  # Format parsers
  argparse.brp, hash.brp, uuid.brp  # Utilities
  codec.brp, codec_bridge.brp, validation.brp  # Encoding/validation
  cache.brp, parallel_list.brp, property.brp, stream.brp, channel.brp  # Infrastructure
  net/            # Portable networking/protocol helpers (tcp, http, url, mime)

pkg/              # Optional native-backed packages and third-party bindings
  compress.brp, crypto.brp, sqlite.brp
  net/            # Native DNS, HTTP client, SMTP, TLS, UDP, WebSocket

examples/           # Curated preview examples restored intentionally

tests/
  test_blorp/     # Runtime tests (TestSuite-based)
    types/        # Type system tests
    text/         # String/text tests
    collections/  # List/dict/set tests
    numeric/      # Arithmetic/tensor/vector tests
    sys/          # I/O, system, debug tests
    memory/       # ARC, leak detection, COW tests
    functions/    # Closures, generics, HOF tests
    concurrency/  # Concurrent blocks, detach, channels tests
    simd/         # SIMD tests (skipped by default)
    tools/        # Tooling/runtime helper tests
  test_std/       # Runtime tests for std modules
  test_compiler/  # Compiler behavior tests
    parser/       # Parser/lexer tests
      should_pass/
      should_fail/
    infer/        # Type inference tests
      should_pass/
      should_fail/
    typecheck/    # Type checking tests
      should_pass/
      should_fail/
      pkg/
      helpers/
    format/       # Formatter tests (should_pass/should_fail/should_error)
    purify/       # Auto-purify tests (should_purify/should_not_purify/should_rewrite)
    codegen_audit/  # Codegen correctness tests

editor/             # IDE/editor support
  vscode/           # VSCode extension (TextMate grammar, language config)
  intellij/         # IntelliJ plugin (TextMate grammar, language config)
```

## Language Syntax (Quick Reference)

See `docs/GUIDE.md` for the complete language reference with all features.
See `docs/GRAMMAR.md` for the formal EBNF grammar.

### Essentials
```
-- Functions
func name(param: Type) -> ReturnType:
    body
pure func name(x: Int) -> Int: x * 2

-- main function (required for programs)
func main(args: List[String]):
    print("hello")

-- main with explicit exit code
func main(args: List[String]) -> Int:
    0

-- Lambdas (always require func keyword)
func(x: Int): x + 1
func(x): x + 1                     # Type inferred from context

-- Pattern matching
match value:
    Some(x): x
    None: default

-- String interpolation uses ${expr}
greeting: String = "Hello, ${name}!"

-- Records and record update
record Point {x: Int, y: Int}
p: Point = {x = 1, y = 2}
q: Point = { p | x = 10 }

-- Visibility: public by default, use private to hide
private func helper(x: Int) -> Int: x + 1

-- Imports (import: block with ':' for selective, as for qualified)
import:
    option: Option(Some, None)
    dict as D

-- ?= bindings propagate Option/Result failure from the enclosing function
func process() -> Option[Int]:
    x ?= get_value()
    y ?= get_other()
    Some(x + y)

-- Concurrency (structured)
concurrent:
    a = compute_a()
    b = compute_b()
detach detach()
ch: Channel[Int] = channel(10)
_ = send(ch, 42)
```

### @tail_recursive
Marks a function for tail call optimization. The compiler verifies all recursive calls are in tail position and transforms them into efficient loops.

### Struct vs Record
- **Structs**: `struct Name {field: Type}` — stack-allocated, no ARC/COW
- **Records**: `record Name {field: Type}` — heap-allocated, ARC-managed, COW
- Both support update syntax: `{ base | field = val }`

## Key Conventions

### Purity Rules

**Pure functions cannot call impure functions** - this is the core rule. However, pure functions CAN use local mutable state:

```blorp
-- ALLOWED: Local mutation in pure function
pure func sum(nums: List[Int]) -> Int:
    var total: Int = 0      -- local var is fine
    for n in nums:
        total = total + n   -- local mutation is fine
    total

-- NOT ALLOWED: Calling impure function
pure func bad(x: Int) -> Int:
    print(x)    -- ERROR: print is impure
    x
```

**What makes a function impure:**
- Calling impure functions: `print`, imported `system` file APIs, imported `process` APIs, blocking channel operations
- Calling any impure function (transitively impure)
- Taking an impure callback parameter

**What does NOT make a function impure:**
- Local `var` declarations and mutation
- For loops with local accumulators
- Calling pure functions
- Pure callbacks

**Closures cannot capture mutable variables:**
Closures can only capture immutable values (function parameters, let bindings). Capturing `var` is a compile error. For stateful computations, use explicit state threading with union types.

**Iterators and purity:**
Pure iterator factories create deterministic sequences. Use explicit state (union types) instead of captured mutable variables for pure lazy evaluation.

See `docs/GUIDE.md` for full purity documentation.

### Other Conventions

- All lambdas require `func` keyword: `func(x): x + 1`
- Tests use `TestSuite` type from `test`

### Standard Library / Package Boundary

- `std/` is the portable, shipped, always-available library. It may use `builtin` only for compiler/runtime primitives.
- New explicit `foreign` declarations and native `_ffi.h` headers should not be added under `std/`. Existing std FFI modules are tracked by an explicit unit-test inventory and should move to `pkg/` or be rewritten in Blorp source.
- `pkg/` is the intended home for optional native bindings, C/system headers, native link flags, and third-party packages. Bare imports should continue to resolve only local modules or `std`, not packages.

### Tensor Work

- `Tensor` is the builtin runtime container. Source code writes fixed-shape tensors with postfix dimensions:
  `T[#N]` for vectors and `T[#M, #N]` for matrices.
- Storage is flat row-major. Single-index subscript peels one dimension, so `m[i]` on a matrix yields a row tensor while `m[i, j]` yields a scalar.
- `#Ds...` means "caller-supplied concrete dimensions", not runtime-sized data. Use `List[T]` for data whose size is only known at runtime.
- `assert_shape` is a narrow runtime refinement. It checks `length(t) == N` for the first dimension and refines the type on success; it does not reshape or copy data.
- Before changing tensor behavior, cover all three layers: dimension solving / inference tests, runtime tests, and generated Core or C.

### Cleanup

**Do not leave compilation artifacts in the repo.** The compiler generates intermediate `.c` files during compilation. These are gitignored in `tests/` and `std/` directories, but you should still clean up after manual runs:

- `./blorp test` - Uses system temp directory, auto-cleans
- `./blorp run` - Uses system temp directory, auto-cleans
- `./blorp compile file.brp` - Generates `file.c` in same directory - **delete manually**

If you see `.c` files appearing in the repo, delete them. Generated files have a `/* Generated by blorp OCaml compiler */` header.

## Testing

Test files use `TestSuite`:
```
import:
    test: TestSuite

func test_something() -> Bool:
    actual == expected

tests: TestSuite = {
    description = "My Tests",
    tests = [
        ("test name", test_something)
    ]
}
```

Run with: `./blorp test path/to/test.brp`

**Doctests**: Functions with `---` docstring blocks containing `>>>` examples can be run with `./blorp test --doc file.brp` (single file) or `./blorp test --suite dir/` (directory).

See Development Rule 3 (write a failing test first) for the TDD workflow.
Do not write tests arbitrarily — understand what is already tested before adding new ones.

### Compiler Unit Tests

Compiler-unit tests live in `compiler/test/`. They use [Alcotest](https://github.com/mirage/alcotest) and test compiler internals directly in OCaml.

**Structure:**
- `compiler/test/run_tests.ml` — Main runner, aggregates default unit-shaped suites and named deep/internal-integration suites
- `compiler/test/test_*.ml` — Focused suites for compiler internals such as types, environments, Core passes, layout, resources, pipeline behavior, CLI bridges, and LSP behavior

**Running:**
```bash
make compiler-unit-test      # Run phase-local compiler-internal OCaml/Alcotest tests
make compiler-unit-deep-test # Run internal integration-shaped Alcotest tests
make coverage                # Run default compiler-unit coverage, report in compiler/_coverage/index.html
```

**Writing new tests:**
1. Add test functions in the appropriate `test_*.ml` file (or create a new one)
2. Each test is a `unit -> unit` function using `Alcotest.(check ...)` assertions
3. Register tests in the file's `suite` list as `(group_name, [test_case ...])` pairs
4. If creating a new file, add it to `run_tests.ml`'s aggregation

**When to add unit tests:**
- Pure utility functions (type manipulation, substitution, env operations)
- Edge cases that are hard to trigger via `.brp` integration tests
- Regression tests for specific compiler bugs
- Any function exposed via `.mli` interface

**Coverage:**
- Uses [bisect_ppx](https://github.com/aantron/bisect_ppx) for instrumentation
- Only the `blorp` library is instrumented (not the test code itself)
- Run `make coverage` to see current coverage; focus new tests on uncovered paths

**Failures:**
- All tests should pass
- Diagnose thoroughly why tests are broken
- Determine if the tests or the implementation is wrong
- Bias toward trusting tests

### ORGANIZATION
Keep the project organized in a way that is intuitive. Use subdirectories when a group of files forms a coherent subsystem (e.g., `std/net/`, `pkg/net/`, `tests/test_blorp/tools/`).

**Note**: For quick build verification during iteration, use direct bash commands (`make`) rather than spawning an agent. Reserve agents for tasks requiring analysis.

### Specialized Workflows

**For new syntax/features:**
```
parser-specialist → ergonomics-expert → [implement] → test-runner → documenter
```

**For performance work:**
```
code-optimizer → [implement] → test-runner → code-reviewer → code-optimizer (verify)
```

**For API design:**
```
ergonomics-expert → [design] → code-reviewer → documenter
```

**For user-facing features:**
```
data-engineer → ergonomics-expert → [design] → data-engineer (validate) → [implement]
```

### Agent Output Contracts
All agents return structured output:

- **test-runner**: Build status + pass/fail counts + failure table
- **code-reviewer**: Summary counts + issues by severity + verdict
- **type-checker**: Problem + reproduction + root cause + fix
- **parser-specialist**: Problem + reproduction + root cause + fix + test cases

### Agent Communication
- Agents return findings directly in their response (no intermediate files)
- Agents cannot talk to each other directly - main conversation orchestrates
- Flow: Main → Agent A → Main → Agent B → Main
- Each agent verifies prerequisites before proceeding
- Context hints help agents focus based on prior agent results
