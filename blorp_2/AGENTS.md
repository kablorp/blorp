# Blorp 2

Read the repository's parent [AGENTS.md](../AGENTS.md) in full, then this
file; both apply. [README.md](README.md) defines the supported increment and
owns runnable commands; [grammar.ebnf](grammar.ebnf) is its grammar.
Supporting a feature in the existing compiler does not put it in scope here.

## Scope

The pinned Blorp 2 seed builds the current compiler. All active Blorp 2 tests
are self-hosted. Unported suites remain in source and are explicitly deferred;
never run them through the legacy compiler. Compiler source stays
within the eventual bootstrap subset in the README: no
concurrency, parallelism, tensors or dimension types, debug blocks,
numeric widths other than Int64 and Float64, doctests, channels or FFI.
Tuples and static traits are supported by the current seed; their use in compiler
implementation remains bounded by each reviewed task. Production library trait
activation does not authorize a general compiler-source comparison rewrite.
Use concrete functions such as `add` and `concat`, and pattern matching,
not trait-dispatched operators such as `==`. Dependencies on the old host library or TestSuite API mark deferred tests;
port bounded suites incrementally without expanding the input language.

Each increment starts from a small executable fixture and its expected
behavior, including rejections. Define only the grammar and rules that
example needs. Migrate one complete producer-to-consumer path at a time and
remove the replaced representation in the same change.

## Principles

These govern design and review. A change that breaks one is incomplete.

1. **Establish each fact once, at the right stage, and never recompute it.**
   The earliest phase with the information produces the fact, validates it
   and publishes it immutably in that phase's sealed product, with one
   authority per fact. Consumers read it: they do not repeat name
   resolution, rejoin a signature, or recheck established arity, purity or
   types. Transient facts may be discarded after validation. A change to a
   fact's representation names its producer, owner, lifetime and consumers.
2. **Make illegal states unrepresentable, with the smallest direct design.**
   Prefer precise variants, opaque identities and construction-time checks
   over flags, parallel lists, optional fields with hidden coupling and
   invariant guards. A guard for a state the types permit marks a model to
   fix. Guard against over-modelling: add no type, helper, layer or
   abstraction beyond what the current example needs; single-use
   indirection and speculative generality count against a design.
3. **Keep code readable and structure discoverable.** Module and type names
   state their phase and concept, so a reader finds where a fact lives
   without searching. Each concept has one home; public surfaces are as
   narrow as their users; functions follow
   [CODE_STYLE](../docs/CODE_STYLE.md).
4. **Carry meaning in types and identities, never in spellings.** After
   parsing and interning, do not recover semantics from names, prefixes,
   sigils or source positions; spelling lookup is for diagnostics and external
   names. Keep spelling, binding, declaration and layout identities
   distinct; equal raw ids from different authorities prove nothing.
5. **Phases flow one way through sealed products.** Each phase consumes its
   predecessor's published product and publishes its own; no module depends
   on a later phase. Frozen namespace facts, accepted semantic facts and
   body-local inference state are separate products, not one bag of
   optional authorities. After loading, the whole pipeline, including
   diagnostic rendering, is pure: the shell owns filesystem, environment,
   clock, process and printing; loading publishes the complete parsed
   program and source inventory; reports and measurements return as data.
6. **Do no needless work.** This is not optimization: avoid repeated scans,
   per-byte allocation, copying a growing collection per step, and
   rebuilding what a phase already published. Build locally, freeze once and
   borrow downstream. Add a table or cache only for a measured repeated
   query, with its complete key, lifetime and cost measured against the
   simpler alternative. An opaque wrapper or record can still allocate;
   check generated C before spreading a carrier. Never special-case code
   to move a counter, and never distort a sound model to avoid an
   unmeasured host-compiler cost.
7. **Reject errors at the earliest phase that can detect them,** in the
   phase that owns the rule, with exact message, help and span.

## Get approval before adding mechanisms or implicit behavior

A request for tests, robustness or a foundation does not authorize extra
infrastructure. Get explicit user approval before adding, beyond the agreed
design:

- another framework, pipeline layer, registry, cache, controller or parallel
  implementation path;
- test execution that bypasses a fixture's normal entrypoint, rewrites
  emitted code, calls generated internal symbols, or adds an assertion
  program in another language;
- hidden inputs, automatic fallback or repair, environment-dependent
  semantics, or conventions a consumer must infer instead of receiving as
  typed data or configuration.

When asking, give a concrete example of the need, the simpler direct option,
and the mechanism's scope, cost and validation. Approval covers that
mechanism only; existing explicit authorization still counts. Local helpers, direct phase tests and routine changes within
the approved design need no further approval. If no approved mechanism meets
a requirement, report the limitation instead of adding one.

## Validation

**Tests.** Compiler tests are Blorp `TestSuite`s, not a test `main` or Python.
Every compiler source module has a unit suite under
[test/unit/](test/unit/), in the `test_<stage>/` folder that mirrors the module's
folder under `src/`. Grammar cases live under
[test/test_grammar/](test/test_grammar/) and change with the EBNF.
Target component suites export ordinary `tests: TestSuite` constants.
`make -C blorp_2 test` builds Blorp 2 and runs only the explicit
`TARGET_COMPONENT_SOURCES` selection through its ordinary TestSuite entries.
`test-components` and `test-target-components` run that selection with an
already-built B2 compiler. Unported unit/runtime/grammar/tooling suites are
DEFERRED, preserved for incremental migration, and receive no PASS credit.
Rejections check exact message, help and span. Embedded programs use aligned
multiline strings with exact contents; keep quoted escapes where they make
the bytes clearer, such as CRLF or malformed indentation. Using multiline
literals in tests does not add them to the pilot's input grammar.

**End-to-end.** Sources remain under [test/e2e/](test/e2e/), with programs in
[test/e2e/fixtures/](test/e2e/fixtures/). The existing driver depends on process,
filesystem and bytes APIs not yet available to self-hosted tests. Full native
e2e execution is DEFERRED; `make -C blorp_2 test-e2e` rejects with an explicit
message. Do not substitute the legacy host or a replacement test framework.
Port bounded suites incrementally through ordinary target TestSuites and real
fixture mains. Existing fixture parity checks compare compiler outputs only;
they do not establish native execution. Keep artifacts under ignored `build/`.

**The direct C exception.** Unit tests of target runtime helpers under
`test/runtime/` may be C, compiled and run by a Blorp `TestSuite`. This includes
String and generated concrete aggregate helpers for supported records, unions
and collections, as explicitly approved on 2026-10-13. Tests use the same pure
production runtime/emission fragments as normal compilation and test-local
allocator wrappers that delegate to actual allocation/free. Observe allocation
occurrences independently; never dereference freed objects. This permits
runtime-helper tests, not calls to generated language functions or a language
fixture's alternate main, and authorizes no production tracing.

**Memory management.** Each memory increment adds granular unit tests at
every affected phase boundary, including intermediate analyses, plus
separate runtime tests, per the
[memory test matrix](ROADMAP.md#phase-level-test-contract). Test
ownership insertion and independent verification separately, including
malformed ownership IR the verifier must reject. Test each invariant in a
named `TestSuite` callback with small typed inputs and observable outputs;
phase tests do not run the whole compiler. End-to-end success,
sanitizers, balanced counts and coverage do not replace them.

**Oracles and evidence.**

- Prove each regression test's oracle by breaking the protected behavior and
  watching it fail. Require exact outcomes, not "some error". Use an
  independent native check for values exit status cannot represent, and
  readiness handshakes rather than sleeps.
- When an increment adds accumulating nesting, add a moderately sized stress
  case, compile it with supported C toolchains at default limits, and
  record emitted nesting depth. Readable C is not a goal.
- Inventory claims cover every supported declaration form and report
  unsupported syntax; an empty inventory proves nothing.
- Reduce a failure to a small reproduction before blaming the phase where it
  surfaced, and report host-compiler defects explicitly.

**Costs.** E2e tests own their allocation and retired-instruction ceilings;
change a ceiling only with retained evidence, and do not special-case code
for a small allocation change. Every cost claim follows the parent's
measurement rules: matched, serial baseline and candidate runs against one
frozen baseline on a quiet machine, covering the targeted boundary and the
whole compilation, with source, binary, flags, inputs, raw samples and
output identity recorded in a `benchmarks/results/` report. Check an
artifact's inputs and toolchain before reusing it, and run cheap publication
checks early. Until self-compilation works, label owned-input measurements
as proxies and say what they omit.

Code-reviewer and test-runner review apply to every change. A docs-only
change needs link and path checks and `git diff --check`, not a compiled
gate.

Archiving a chat can also archive its managed worktrees. Git snapshots exclude
ignored build evidence. Before archiving, preserve and verify every artifact
still borrowed by another task in the main checkout's ignored evidence directory.
