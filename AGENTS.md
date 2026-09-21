# blorp

A compiler for a functional programming language with pure/impure function tracking, algebraic data types, and pattern matching.

## Find The Right Boundary First

This file contains binding principles and development rules. Read the
task-specific reference below rather than loading every guide, roadmap, source
file, or test log. [`docs/DEVELOPMENT.md`](docs/DEVELOPMENT.md) owns detailed
commands and efficient investigation/handoff examples; [`docs/README.md`](docs/README.md)
routes the maintained references. Performance and other compiler tasks should
start with [`docs/WORKER_CHECKLIST.md`](docs/WORKER_CHECKLIST.md) for the
setup/measure/land loop before reading a roadmap.

| Task | Start with | First feedback |
| --- | --- | --- |
| Syntax or diagnostic | `blorp/src/compiler/stage_03_parse/`, matching compiler fixture, [`GRAMMAR`](docs/GRAMMAR.md) | Exact fixture and expected message; `scripts/compiler-check --changed` |
| Inference or typecheck | `blorp/src/compiler/stage_06_typecheck/`, matching compiler fixture | Exact suite; then `scripts/compiler-check --stage typecheck` |
| Core/ownership | [`pipeline.brp`](blorp/src/compiler/stage_09_core/pipeline.brp), [`ARCHITECTURE`](docs/ARCHITECTURE.md), owning Core suite | Before/after Core, focused suite, relevant sanitizer |
| Backend/runtime | `blorp/src/compiler/stage_10_backend/`, `blorp/src/lib/runtime/native/`, codegen audit | Focused emitter/runtime test and generated C |
| Standard library/package | `standard_library/src/` or `pkg/`, matching tests | Exact module test; `std-check` or runtime/package gate |
| CLI/LSP | `blorp/src/main.brp` or `blorp/src/lsp/` | `scripts/test cli` or `scripts/test lsp` |
| Build/bootstrap/release | `blorp/build/bootstrap.env`, [`RELEASES`](docs/RELEASES.md), [`scripts`](scripts/README.md) | `make` and focused build checks; not `compiler-check --changed` |
| Performance | Production function, [`profiling guide`](docs/DEVELOPMENT.md#function-profiling-and-flame-graphs), retained benchmark | Direct same-boundary baseline/candidate measurement; output identity |
| Docs-only | Owning reference document | Link/path examples and `git diff --check`; no automatic full gate |

These are starting points, not substitute gates. `scripts/compiler-check`
selects manifest-owned compiler checks, builds once when checks are selected,
and does not cover a docs-only or bootstrap-manifest edit. Run broader gates
proportionate to the change before review.

For common requests, the first command and final gate are concrete:

```bash
# Parser diagnostic: inspect the exact expected message, then owner checks.
bin/blorp check --no-format \
  blorp/test/compiler/stage_03_parse/fixtures/parser/should_fail/subscript_missing_close.brp
scripts/compiler-check --changed
scripts/test compiler-blorp

# Core ownership: run the owning suite, then ownership-sensitive gates.
bin/blorp test --timeout 180 \
  blorp/test/compiler/stage_09_core/test_core_match.brp
scripts/compiler-check --changed
scripts/test compiler-core-sanitize leak

# Bootstrap pin: verify release tag and all target digests before changing the
# manifest; compiler-check --changed does not select this build input.
scripts/blorp-compiler-bootstrap --print-id
make
bash blorp/test/build/test_build_configuration.sh
bash blorp/test/build/test_release_toolchain.sh
scripts/test package
```

The parser's `should_fail` check is expected to exit nonzero; compare its
diagnostic text with the fixture expectation, not its status alone. For Core
codegen changes also inspect generated C and run the codegen audit. For a
preview/bootstrap release, use the full gate in
[`docs/RELEASES.md`](docs/RELEASES.md#preview-validation).

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
- For pipeline questions, start with `blorp/src/compiler/stage_09_core/pipeline.brp`, `blorp/src/compiler/stage_09_core/pipeline_stage.brp`, `docs/ARCHITECTURE.md`, and `blorp/src/main.brp`.
- For tensor questions, start with `standard_library/src/tensor.brp`, `standard_library/src/vector.brp`, `standard_library/src/matrix.brp`, `blorp/src/compiler/stage_06_typecheck/type_system/dim_solver.brp`, `blorp/src/compiler/stage_06_typecheck/frontend_graph_typecheck.brp`, `blorp/src/compiler/stage_09_core/tensor_specialize.brp`, `blorp/src/lib/runtime/native/runtime.c`, and the matching `blorp/test/compiler` / `blorp/test/runtime` cases.

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
before writing implementation. Compiler implementation tests and public parser,
inference, and typechecking fixtures belong in `blorp/test/compiler/`; format,
purify, and lint fixtures live under their matching owners in `blorp/test/`.
Runtime behavior belongs in `blorp/test/runtime/`. For bug fixes, add a regression test that fails before
the fix and passes after.

**2. One change per change.** Fix the bug, add the feature, or refactor — not all three.
If you discover adjacent work, note it separately. If you can't describe your change in one
sentence, it's too big. A bounded preparatory refactor may precede the main change when it makes
the target change substantially easier to reason about, implement, or verify. Keep that refactor
semantics-preserving, validate it independently, and do not use it as permission for unrelated
cleanup.

**3. Check for precedent.** Before implementing, look at how blorp already handles similar things.
Follow existing naming conventions, error styles, and API patterns. If you're establishing a
new pattern, call it out explicitly.

**4. Design the fast feedback loop.** Before broad implementation, identify the shortest repeatable
command that exercises the behavior or cost under investigation. Prefer a properly scoped unit
test, a small scratch reproduction, a custom harness that tightly isolates the subject, a retained
benchmark script, or a reusable profiling command. Keep setup and unrelated pipeline work outside
the measured or tested boundary. Use the narrow loop while iterating, then run broader integration
and regression gates once the change is stable.

**5. Make the easy change so the change is easy.** When a small, opportunistic refactor will expose
the right boundary, remove incidental complexity, or make the main change mechanical, do that
refactor first. The preparation must be bounded, independently reviewable, and protected against
regression. Stop and reassess if the preparation grows into an architectural project or becomes
larger than the problem it was meant to simplify.


### While you write code

**6. Catch mistakes at compile time, not runtime.** Reject errors at the earliest phase where
the necessary information exists. Syntax errors in the parser. Name errors after parsing.
Type errors in type-checking. Never add semantic checks in codegen unless monomorphization
forces it. Every compile error should include a help suggestion that teaches the user what
to do instead.

**7. Optimize for the first-time user.** If a feature requires reading the GUIDE to use correctly,
it needs a better error message. If an error says "unexpected token" with no hint, it's incomplete.
Think about what a programmer coming from Python, JS, or Rust would try first, and make that
either work or produce a helpful message.

**8. Respect phase boundaries.** Lexing/parsing, module loading, inference and
typechecking, Core lowering/passes, ownership/resource preparation, and backend
emission have different responsibilities. The exact current order is owned by
`docs/ARCHITECTURE.md` and `stage_09_core/pipeline.brp`; do not duplicate it
here. Don't put type-checking logic in Core passes or parsing constraints in
typechecking. If a check belongs earlier, move it there. If it must stay late
(for example because monomorphization provides the needed facts), document why.

**9. Measure, don't guess.** If there's any doubt about efficiency, use `--profile` for runtime
cost and `--leak-check` for memory. Claims like "this is faster" require before/after evidence.
Elapsed latency matters, but it is often noisy and can hide the mechanism. During investigation,
also prefer direct and repeatable signals such as allocation and release counts, retired
instructions, peak and retained memory, deterministic work counters, and native samples. Use the
metrics that best isolate the claimed change, then confirm user-visible latency when that is the
claim. Improve the profiling and memory tools when you find gaps.

### After you write code

**10. Prove it works.** Every change must include evidence: passing tests, benchmark numbers,
or before/after error message comparison. "It compiles" is not proof. For error paths, verify
the error message content — a `should_fail` test that doesn't check the message is incomplete.
For codegen changes, read the generated C.

**11. Keep commit messages short.** A one-line subject and a body of a few
lines at most: what was wrong, what changed, and one or two headline numbers.
No issue numbers or names, no pasted tables or gate lists; that detail lives
in `benchmarks/results/` and the issue docs.

**12. Get it reviewed.** Every change gets reviewed before commit. Use the code-reviewer and
test-runner agents. No exceptions for "trivial" changes — trivial changes have trivial reviews.

**13. Update docs with the code.** If your change is user-facing (syntax, API, error message),
update `docs/GUIDE.md` and `docs/GRAMMAR.md` in the same commit. Documentation drift is a bug.
The formal grammar must stay in sync with the parser.

**14. Prefer coherent pre-0.1 behavior over backwards compatibility.** Blorp is pre-0.1.0, so
do not preserve old syntax, APIs, or compatibility shims merely to avoid breaking users. If the
new behavior is clearer, safer, or simpler, remove the old form and make the current language
coherent. Breaking changes still require updating all call sites in standard_library/, tests/, examples/, docs,
and formatter expectations in the same change. Add migration-style error messages only when they
meaningfully improve first-time user experience or prevent confusing parser/typechecker failures.

**15. Focus on quality.** If your code is not ready to pass a review for production, then your
work is incomplete. Do not settle for ad-hoc hacks or incoherent architecture.

**16. Document the "Why"s.** When your code is read in the future, readers need to understand why
any non-obvious solutions exist.

**17. Surface rough edges promptly.** Fast iteration depends on making friction visible. If you run
into an obstacle, confusing boundary, unreliable tool, missing probe, or likely compiler bug,
report it while the context is fresh. Explain its effect on the current task and suggest a bounded
solution when one is apparent. Do not silently route around recurring friction or spend a long time
building a workaround without reassessing the task with the user.

---

## Daily Commands And Validation

Use the repository's `bin/blorp`, not a separately installed release, for
source-checkout validation. `make` rebuilds it from the immutable bootstrap;
a direct `bin/blorp` test can otherwise exercise an older executable.
[`docs/DEVELOPMENT.md`](docs/DEVELOPMENT.md) has the full build, focused-test,
profiling, CI, cleanup, and diagnostic recipes. [`scripts/README.md`](scripts/README.md)
defines test gates and timeouts; `bin/blorp <command> --help` defines current CLI
flags.

```bash
scripts/compiler-check --changed --plan  # Read-only selection and next-gate guidance
scripts/compiler-build-status     # Verify bin/blorp matches current build inputs
make                              # Build/install when inputs changed or status is uncertain
scripts/compiler-check --changed  # Build once and run manifest-owned checks
bin/blorp test path/to/test.brp    # Narrow behavior loop after a known build
scripts/test                      # Default compiler/runtime/leak/doctest/CLI gates
scripts/test compiler-core-sanitize
scripts/test --no-build --log-dir /tmp/blorp-gates compiler-blorp
```

An empty `--plan` is a no-op explanation, not validation. Build status reports
`FRESH`, `STALE`, or `UNKNOWN` without rebuilding; check it before direct
`bin/blorp` tests, and run `make` then recheck if not fresh. Use the Developer
Guide for details.

Use the smallest test or production-pass benchmark while iterating, then the
relevant broad gates. `--no-build` is only for a toolchain already built from
the intended sources. `bin/blorp test --warmup-only` must succeed before
parallel gates; a failed warmup is not an acceptable warning. For preview and release work,
follow [`docs/RELEASES.md`](docs/RELEASES.md#preview-validation) and
`scripts/premerge-gate`; do not substitute the default local gate for those
broader checks.

Search for a symbol and read bounded source regions before loading a very
large module. Keep full Core/C dumps and gate logs on disk; share the relevant
excerpt, artifact path, and hashes with reviewers. The precise examples and
handoff format live in
[`docs/DEVELOPMENT.md`](docs/DEVELOPMENT.md#efficient-agent-investigation-and-handoff).
This reduces repeated context, not the required tests or review.

## Language And Repository Boundaries

[`docs/GUIDE.md`](docs/GUIDE.md) is the current language reference and
[`docs/GRAMMAR.md`](docs/GRAMMAR.md) is the formal syntax. The Developer Guide
maps production sources and tests. In particular:

- Pure functions may mutate local `var` state but cannot call impure functions
  or capture mutable variables in closures. Lambdas use `func`; use explicit
  state threading for pure lazy iterators.
- `struct` values are stack-allocated without ARC/COW; `record` values are
  heap-allocated and ARC/COW-managed. Both support value-preserving update
  syntax. Verify current behavior in tests before changing layout or ownership.
- `standard_library/src/` is portable and always available. Do not add new
  explicit `foreign` declarations or native `_ffi.h` headers there. Optional
  native bindings, link flags, and third-party packages belong in `pkg/`.
  Bare imports resolve local or standard-library modules, not `pkg/`.
- Tensor work must cover dimension solving/inference, runtime behavior, and
  generated Core or C; use the source route above for the first files.
  `#Ds...` denotes caller-supplied concrete dimensions, not dynamic length;
  `assert_shape` checks the first dimension and refines without copying.
- New compiler implementation and public parser/inference/typecheck fixtures
  live under `blorp/test/compiler/` and are registered in
  `blorp/test/compiler/compiler_test_ownership.json`. Format, purify, and lint
  fixtures retain their matching owners; runtime behavior belongs in
  `blorp/test/runtime/`. Tests use `TestSuite` from `test`; see the Developer
  Guide for placement and the Guide for syntax.
- `bin/blorp test` and `run` use temporary artifacts. A bare
  `bin/blorp compile file.brp` may write `file.c` beside its input. Prefer
  `-o` with a temporary path and clean up generated files you created; do not
  delete unrelated user files. Read generated C for codegen changes.

## Agent Coordination

The main task owns integration and passes bounded context to specialists:
question, base revision/worktree, first source and test, fast loop, scope
boundary, and expected evidence. Preserve the specialist responsibilities:
new syntax needs parser-specialist and ergonomics-expert input before
implementation and documenter review after; API/user-facing design needs
ergonomics-expert and data-engineer validation; performance work needs a
code-optimizer hypothesis and measured
verification. One worker may carry several roles when qualified; do not spawn
separate agents merely to reproduce a fixed chain. Run a quick `make` directly
rather than spawning an agent for build status.
Every change still gets code-reviewer and test-runner review before commit.
A worker should ask for guidance when a boundary or result is ambiguous, and
a negative performance experiment is a valid result.

Agent reports should be concise and reproducible:

- Test-runner: build status, pass/fail counts, and failure table.
- Code-reviewer: issue counts by severity, evidence, and verdict.
- Diagnostic specialist: reproduction, root cause, proposed fix, and tests.
- Performance worker: hypothesis, exact workload and commands, source/binary
  provenance, raw sample location, output identity, caveats, and accept/reject
  recommendation.

Pass findings through the main task for integration; do not make each agent
reread the full conversation or every roadmap. Preserve complete artifacts
when a reviewer needs them, but report only the relevant excerpt and path.
