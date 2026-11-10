# blorp

A compiler for a functional programming language with pure/impure function tracking, algebraic data types, and pattern matching.

## Where Things Live

The compiler, standard library, tests and tooling live in [`blorp/`](blorp/).
Read [`blorp/AGENTS.md`](blorp/AGENTS.md) next: it owns the build, test and
validation commands, the test layout and the compiler's design principles.
[`blorp/README.md`](blorp/README.md) defines the supported language and
[`blorp/grammar.ebnf`](blorp/grammar.ebnf) its grammar. The rest of this
file holds the language principles and development rules that apply to every
change. [`docs/CODE_STYLE.md`](docs/CODE_STYLE.md) owns code style and
[`docs/HANDOFF_SPEC.md`](docs/HANDOFF_SPEC.md) owns the shape of a brief.
`scripts/README.md` describes the remaining repository scripts.
[`blorp/NEXT.md`](blorp/NEXT.md) indexes the open workstreams, each with its
status, next step and owning plan.

## Language Principles

The priorities of the language, in order: **safe, understandable, expressive, simple, fast, easy to learn,
predictable for tools to generate and humans to debug.**

All work on the compiler, standard library, and documentation should uphold these principles.

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

When choosing implementation strategies:

- Do not rely on flimsy heuristics. If correctness depends on a distinction, represent it explicitly in the AST/IR/data model, a parser or type-checker rule, or a named configuration point. Avoid guessing from names, shapes, string prefixes, source formatting, or "usually true" patterns unless there is no better representation; if a heuristic is unavoidable, isolate it, document the tradeoff, and cover failure modes with tests.
- Avoid magic values. Give non-obvious numbers, strings, limits, sentinel values, and protocol constants meaningful names at the narrowest useful scope. If a literal is required by an external format, ABI, wire protocol, or compiler invariant, name it or document that source of truth near the value.
- Prefer types that cannot disagree with themselves. A variant with a payload, or a phase-specific product, is worth it when a `Bool` plus an `Option` (or two flags) could be true together in a way that is nonsense. Two empty tags used only as a switch are usually a named `Bool`: the field name is the concept, and a first-time reader should not have to open a type to learn it has two cases and no data. Do not mint a union just to avoid writing `True`/`False`.

---

## Development Rules

How we work on blorp. These apply to every change — features, bug fixes, refactors.

### Make it work, make it right, make it fast

We usually work in that order, and a change must be right before it merges to
main. Review (rule 12) checks this.

- **Work**: the behavior is correct and covered by tests.
- **Right**: the code follows [`docs/CODE_STYLE.md`](docs/CODE_STYLE.md) and
  rule 15, and its data model does not encode the same fact twice in ways
  that can disagree.
- **Fast**: optimize afterward, guided by measurement.

Do not bend a design to avoid a cost the compiler imposes today. Measure the
cost instead (allocations and retired instructions, per rule 9). Record it in
the change's design document or as one markdown summary in
`benchmarks/results/`, so that compiler work can remove it. Raw samples stay
under the ignored `build/` directory, and a report is deleted when the decision
it supports is superseded. A change still stays within any cost ceiling its
spec sets.

Any compiler data-model refactor in `blorp/` requires matched
before/after self-compile allocations and retired instructions, with
production and test line counts reported separately. Significant regressions
in allocations, retired instructions, or production line count are not
acceptable merely because the model is cleaner or another metric improves.
Necessary correctness-test growth is allowed; do not hide growth through
compressed formatting or deleted coverage. Set numerical cost ceilings before
implementation, investigate repeatable increases at the owning phase, and
reject or rescope a change that exceeds them. Keith has given the coordinating
agent a standing delegation for routine budget corrections (confirmed
2026-11-09). The coordinator, not the implementer, makes such a correction, and
records it in the owning plan or results file with the old and new figures and
the reason.

### Naming

Function, parameter and binding shape follow [`docs/CODE_STYLE.md`](docs/CODE_STYLE.md).

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
  confusion, for example distinguishing parsed, checked, specialized, lowered IR, and emission data.

### Before you write code

**1. Write a failing test first.** We strongly prefer TDD. Define what success looks like
before writing implementation. Where each kind of test lives, and how to run it,
is in [`blorp/AGENTS.md`](blorp/AGENTS.md). For bug fixes, add a regression
test that fails before the fix and passes after.

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

**7. Optimize for the first-time user.** If a feature requires reading the README to use correctly,
it needs a better error message. If an error says "unexpected token" with no hint, it's incomplete.
Think about what a programmer coming from Python, JS, or Rust would try first, and make that
either work or produce a helpful message.

**8. Respect phase boundaries.** Lexing and parsing (`lex`, `parse`), module loading
(`load`, `namespace`), checking (`check`), specialization (`specialize`), lowering
(`lower`), ownership insertion (`own`), verification (`verify`) and C emission (`emit`)
have different responsibilities. The exact current order is owned by
[`blorp/README.md`](blorp/README.md) and `blorp/src/main.brp`; do not duplicate it
here. Don't put type-checking logic in lowering or ownership passes, or parsing
constraints in checking. If a check belongs earlier, move it there. If it must stay late
(for example because specialization provides the needed facts), document why.

**9. Measure, don't guess.** If there's any doubt about efficiency, use Blorp's measurement
tools: `BLORP_ALLOCATION_SITES` with `blorp/scripts/allocation-sites` for where allocations
come from, `blorp/scripts/attribution/run` for reference-count and copy attribution, and a
`-DBLORP_MEMORY_DIAGNOSTICS=1` build with `BLORP_LEAK_CHECK=strict` for memory;
`blorp/README.md` documents them. Claims like "this is
faster" require before/after evidence.
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
in `benchmarks/results/` and the plan documents.

**12. Get it reviewed.** Every change gets reviewed before commit. Use the code-reviewer and
test-runner agents. No exceptions for "trivial" changes — trivial changes have trivial reviews.

**13. Update docs with the code.** If your change is user-facing (syntax, API, error message),
update `blorp/README.md` and `blorp/grammar.ebnf` in the same commit. Documentation drift is a bug.
The formal grammar must stay in sync with the parser.

**14. Prefer coherent pre-0.1 behavior over backwards compatibility.** Blorp is pre-0.1.0, so
do not preserve old syntax, APIs, or compatibility shims merely to avoid breaking users. If the
new behavior is clearer, safer, or simpler, remove the old form and make the current language
coherent. Breaking changes still require updating all call sites in
`blorp/standard_library/`, tests and docs in the same change. Add migration-style error messages only when they
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

## Commands, Validation And Repository Boundaries

[`blorp/AGENTS.md`](blorp/AGENTS.md) owns them: the build and test commands,
which gates a change runs, and the test layout. `make -C blorp test` is the
default gate. Iterate with the narrowest test that exercises the change, then run
the broader gates before review. Keep large dumps and gate logs on disk and share
the relevant excerpt and the path.

## Agent Coordination

The main task owns integration and passes bounded context to specialists.
Every handoff (usually the brief in a message to an agent) follows
[`docs/HANDOFF_SPEC.md`](docs/HANDOFF_SPEC.md): a problem with its
reproduction, the proposed solution, literate code examples whenever code
changes, and runnable acceptance criteria, plus the other sections its
heuristics call for, in at most 3,000 words of prose. Preserve the
specialist responsibilities:
new syntax needs parser-specialist and ergonomics-expert input before
implementation and documenter review after; API/user-facing design needs
ergonomics-expert and data-engineer validation; performance work needs a
code-optimizer hypothesis and measured
verification. One worker may carry several roles when qualified; do not spawn
separate agents merely to reproduce a fixed chain. Run a quick `make -C blorp`
directly rather than spawning an agent for build status.

Subagent definitions live in `.claude/agents/`. Use `compiler-expert` as the
default implementer for compiler, runtime and code-generation work; the
specialist roles above add their input to it rather than replacing it. Run
subagents on Sonnet by default. Choose Opus only when a task is demanding
enough to need it, such as a design that spans several phases or a subtle
ownership or miscompilation investigation, and say why when you do.

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
