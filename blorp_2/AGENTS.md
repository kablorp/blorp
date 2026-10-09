# Blorp 2

Before working here, read the repository's parent [AGENTS.md](../AGENTS.md)
in full, then this file. Both apply. This file supplements the parent's
language principles, development rules, review requirements, and handoff
instructions with the pilot's boundaries.

Read [README.md](README.md) for the current supported increment and
[grammar.ebnf](grammar.ebnf) for its restricted grammar. Supporting a feature
in the existing compiler does not put it in this pilot's scope.

## Start with a working example

Each increment starts with a small executable fixture and its expected
behavior. Define only the grammar and semantic rules that example needs,
including rejection cases. Introduce infrastructure when a working example
needs it. Migrate one complete producer-to-consumer path at a time, removing
the replaced representation in the same slice.

The existing compiler builds this compiler until self-hosting is possible.
Compiler source stays within the agreed eventual subset in the README.
Concurrency, parallelism, tensors and dimension types, tuples, debug blocks,
numeric widths other than Int64 and Float64, traits, doctests, channels, and
FFI are excluded. Use concrete functions such as `add` and `concat` instead
of trait-dispatched operators. Existing host-library dependencies and the
host TestSuite API are temporary dependencies; they do not establish
bootstrap readiness or expand the input language.

## Get approval before adding mechanisms or implicit behavior

Use the smallest direct implementation that satisfies the agreed working
example. A request for tests, robustness, or an architectural foundation does
not authorize additional infrastructure by itself.

Get explicit user approval before adding a mechanism beyond the agreed design
that introduces any of the following:

- Another framework, pipeline layer, registry, cache, controller, or parallel
  implementation path.
- Test execution that bypasses the fixture's normal entrypoint, rewrites emitted
  code, calls generated internal symbols, or adds a second assertion
  program in another language.
- Hidden inputs, automatic fallback or repair, environment-dependent semantics,
  or conventions that a consumer must infer instead of receiving as explicit
  typed data or configuration.

Before asking, give a concrete example of the need, the simpler direct option,
and the proposed mechanism's scope, cost and validation. Approval must cover
that mechanism; do not infer it from a general desire for quality or possible
future requirements. Existing explicit authorization still counts. Small local
helpers, direct phase tests and routine changes within the approved design do
not need repeated approval. If no approved mechanism can meet the requirement,
report the limitation instead of silently adding one.

## Establish identity, authority, and lifetime first

Before changing a fact's representation or moving it between phases, state:

- What question its consumers need to answer and which identity answers it.
- Which program, scope, or specialization owns that identity.
- Which producer establishes the fact and validates its invariants.
- When it is built, published, borrowed, and discarded.
- Which checked translation connects it to another authority, if needed.

Apply these lessons to every increment:

1. **Carry meaning explicitly.** Resolve distinctions once through typed
   variants and identities. After parsing and interning, do not recover
   semantics from spellings, prefixes, or sigils. Keep spelling lookup for
   diagnostics and external-name projection. Emission can derive internal
   C names from resolved identities.

2. **Use the right identity domain.** A spelling ID does not identify a
   shadowed binding; a declaration ID does not identify every specialized
   runtime layout. Keep spelling, binding, declaration, and layout identities
   distinct as they become necessary. Equal raw IDs across authorities do
   not establish identity. Preserve ownership through sealed products and
   checked translations rather than assuming a lookup validates it.

3. **Publish complete typed facts.** Each boundary exposes a complete,
   immutable result with one authority per semantic fact. A resolved call
   carries the contract needed by its consumer; later code must not repeat
   name resolution, rejoin its signature, or recheck established arity and
   purity. Transient contracts may be discarded after validation, leaving
   one authoritative published signature.

4. **Separate phases and lifetimes.** Frozen namespace and import-visibility
   facts, accepted semantic facts, and body-local inference state are
   different products. Do not combine them in a bag of optional authorities.
   Syntax belongs in parsing; type-directed UFCS and pattern decisions belong
   in checking; emission consumes validated facts. Introduce additional
   products and passes when the supported example needs them.

5. **Build locally, freeze once.** Use local, uniquely owned builders and
   immutable published results. Downstream readers borrow facts where
   supported. Avoid threading growing collections through shared state in
   ways that repeatedly copy, reconstruct, retain, or release them.

6. **Prove a table or cache is useful.** Identify the expensive repeated
   query before adding an index or cache, and store the narrow facts it
   needs. Specify the complete key, including occurrence and environment
   where relevant, plus ownership, lifetime, and invalidation. Measure
   construction and lookup together against the simpler alternative.

7. **Check physical representation.** An opaque wrapper, record, or precise
   variant can still allocate, box, or impose ownership traffic. Probe
   representative construction and access patterns and inspect generated C
   before spreading a carrier through the compiler. Do not distort a sound
   model to avoid an unmeasured host-compiler cost.

8. **Find the causal boundary.** A parser or checker failure can originate
   in generated ownership code. Reduce it to a small reproduction and check
   sanitizer results before attributing the failure to the subsystem where
   it surfaced. Independently verify ownership transitions when they are
   introduced or changed, and report host-compiler defects explicitly.

9. **Test backend structure as it grows.** Read generated C for codegen
   changes. When an increment introduces potentially accumulating nesting,
   add a moderately sized stress case and compile it with supported C
   toolchains using their default limits. Track emitted structural depth;
   readable C formatting is not a goal.

10. **Prove the test's oracle.** Passing tests establish only what their
    assertions observe. Deliberately break the protected behavior and require
    the relevant regression test to fail. Use independent native checks for
    values that process exit status cannot faithfully represent. Where
    timing or ownership matters, require exact outcomes and readiness
    handshakes rather than relying on sleeps or any error being sufficient.

11. **Bound inventory claims.** Scanners must cover every supported
    declaration form, including `fixed record` and `fixed union` when those
    are in the scanned language. Test that coverage and report unsupported
    syntax explicitly. An empty inventory proves nothing about omitted
    syntax. Prefer compiler-produced inventories when a working use case
    justifies them.

12. **Keep evidence comparable and reusable.** Freeze workload and toolchain
    identity before editing. Automate matched baseline/candidate pairs
    against one frozen baseline, run on a quiet machine, and make each
    worktree's provenance explicit. Serialize measurements on the shared
    machine and assess both the targeted boundary and whole compilation.
    Record source, binary, flags, inputs, raw samples, and output identity.
    Extend repository-owned
    validation with explicit fingerprints, component results, and reuse
    rules instead of building bespoke controllers or publication machinery.
    Run cheap publication checks early when publication is in scope.

## Keep the pipeline pure

After loading all source inputs and explicit configuration, the entire
compilation pipeline, including diagnostic rendering, is pure. Local `var`
and builders are allowed. The surrounding shell owns filesystem access,
environment reads, clocks, process execution, and printing. Future import
loading supplies a complete source bundle to the pipeline. Reports and
measurements produced inside a phase return as data; shared mutable caches
are not implicit inputs.

## Validation for this pilot

Compiler tests are written in Blorp and use `TestSuite`, not a test `main` or
Python. The explicitly approved exception is direct C unit tests of the
target String runtime under `test/runtime/`, compiled and run by a Blorp
`TestSuite`. They use the same runtime fragment as emission and small
test-local allocator wrappers that delegate to actual allocation/free.
This does not authorize production tracing or alternate language-fixture
entrypoints. Every host-compiled source module has a matching unit suite under
[test/unit/](test/unit/). Grammar conformance cases live under
[test/test_grammar/](test/test_grammar/); update them and the EBNF together.
Check exact diagnostic text, help, and spans for rejected inputs. End-to-end
suites live under [test/e2e/](test/e2e/), with input programs in
[test/e2e/fixtures/](test/e2e/fixtures/). Their default path is explicit: the
pilot compiles a small Blorp fixture, the C compiler builds its unmodified
output, and the host TestSuite runs the fixture's real `main` and checks its
exit status, stdout and stderr. Each fixture should expose its tested behavior
through that entrypoint. Precise phase facts belong in direct unit tests;
native probes outside this path require approval under the rule above.

Memory-management increments require granular unit tests at every affected
phase boundary, including intermediate analyses, and separate runtime tests.
Test each invariant with a named `TestSuite` callback using small typed inputs
and observable outputs; do not make every phase test run the whole compiler.
Test ownership insertion and independent verification separately, including
malformed ownership IR that the verifier must reject. End-to-end success,
sanitizers, balanced RC totals and line coverage do not replace these tests.
The [memory test matrix](MEMORY_PLAN.md#phase-level-test-contract) defines the
required cases as each feature enters the supported subset; future rows are
requirements, not claims of implemented coverage.

Use the narrowest repeatable check while iterating, then the relevant
integration and sanitizer checks. Follow the parent instructions for host
build freshness. Build the pilot once at the beginning of each end-to-end run
via `make -C blorp_2 test-compiler`, then pass its executable path explicitly
to the tests. Do not add a persistent compiler cache or prepare the compiler
separately for each fixture. The README owns runnable commands. Keep generated
artifacts under the ignored `build/` directory or temporary directories. Build the pilot
and fixture programs at `-O0` for these development tests. Compile each valid
fixture once, collecting allocation and instruction counters from that run.

End-to-end tests own their allocation and retired-instruction ceilings.
Adjust limits deliberately with retained evidence. Prioritize doing less
work and keeping the code clear; small allocation changes do not justify
special cases. Follow the parent's measurement requirements for data-model
refactors. Until self-compilation is supported, label owned-input compilation
measurements as proxies and state what they do not cover.

Both code-reviewer and test-runner review still apply. For a docs-only change,
check links, path examples, and `git diff --check`; no compiler rebuild or
compiled gate is needed solely because instructions changed.
