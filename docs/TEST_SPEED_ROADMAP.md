# Test Speed Roadmap

Status checked against code on 2026-07-15 at commit `41d48dfd`.

This roadmap captures the current test-speed diagnosis and the intended path to
make normal test runs faster by doing less duplicate work. The goal is not to
hide failures behind caches or looser gates. The goal is to keep the normal loop
focused, move expensive broad sweeps to explicit deep/premerge gates, and remove
test harness structure that repeatedly crosses process, compiler, and bridge
boundaries without adding proportional signal.

## Current Diagnosis

The default local gate is slow for two related reasons: it does too much broad
integration work by default, and running every top-level gate at once
oversubscribes the machine.

Recent measurements on this branch showed:

- A warm default `scripts/test` run took 9m15s wall time. Individual gate times
  were much worse under contention: compiler-unit 8m55s, runtime 6m59s,
  compiler 6m16s, CLI 4m19s.
- The same gates are materially faster in isolation. Runtime alone took 2m07s
  gate time. Compiler alone took 4m17s gate time. Compiler-unit alone took about
  4m18s.
- The compiler fixture gate is highly CPU-bound: the isolated compiler gate used
  about 2034 seconds of user CPU for 4m17s of wall time. Running it beside
  runtime and compiler-unit slows the other gates substantially.
- Compiler-unit used to be one serial Alcotest executable containing both
  phase-local unit tests and broader internal integration tests. It is not the
  only problem, but it became the longest tail when run under full-gate
  contention.
- Before the CLI split, CLI smoke was broader than command-surface smoke: it
  covered package fetch/vendor flows, compile/run/test, formatter tooling, REPL,
  and LSP.
- Bridge helper preparation still costs roughly 16-21 seconds per `scripts/test`
  run when helper binaries are prepared into a fresh startup directory.

### 2026-07-15 Whole-Compiler Baseline

The most recent compiler migration work changed the dominant cost. Fresh
measurements at `41d48dfd` showed:

- `scripts/test compiler-unit compiler --serial`: 3,104 tests passed in 5m36s.
  Compiler-unit took 2m40s and compiler took 2m53s.
- `scripts/test compiler-deep --serial`: 1,999 tests passed in 37m39s wall
  time, with 37m33s attributed to the gate.
- The deep run reached roughly 3.7 GB resident memory in the OCaml host.
- Generating the self-hosted CLI C during `make` took roughly 6-8 minutes.
  Once generated C existed, the host C compiler completed in roughly 7
  seconds.

Another checkout ran a full test command during approximately the final four
minutes of the deep measurement. Re-baseline in isolation before using these
numbers for a before/after claim. That contention does not explain the full
regression, and the observed phase split rules out Dune and the host C compiler
as the primary causes.

Before P1, the broad compiler-owned Blorp sweep discovered 94 top-level test
files and `try_run_suite_selector_tests` compiled at most four suites per
generated harness. This rebuilt and typechecked the compiler module graph
roughly two dozen times in one sweep. The limit was documented as a correctness
workaround for three typecheck declaration suites, but the focused
reproductions below showed that those exceptions had become stale.

The immediate performance problem is therefore repeated whole-program work:

1. `Test_runner` discovers tests and generates several run-all harnesses.
2. Each harness re-enters `Pipeline.compile_generated_test_harness`.
3. The OCaml host sends an in-memory source through the Blorp CLI/frontend
   bridge, decodes and finalizes the graph, then invokes the Blorp typecheck
   bridge and remaining compilation stages.
4. The host C compiler and harness process are invoked for every compiled
   group.

The roadmap below removes that accidental repetition, then removes algorithmic
work inside the remaining compile. It does not add a result cache or hide the
deep coverage.

## Principles

- Prefer doing fewer things over adding opaque caches.
- Keep fast local checks semantically meaningful, not merely shallow.
- Keep expensive coverage available, but make it explicit when it is broad,
  redundant, or premerge-oriented.
- Do not weaken failure checks just to reduce wall time.
- Avoid hidden duplicate sweeps, especially when one gate silently retests a
  corpus already owned by another gate.
- When a test shells out, it should be because the process boundary is the
  behavior under test or because no in-process interface exists yet.

## Target Test Shape

`scripts/test` should become the normal fast confidence gate:

- Compiler unit tests that are genuinely unit-level.
- Parser, infer, and typecheck compiler tests through in-process runners.
- Runtime/std tests, with slow process-heavy tests kept narrow and intentional.
- CLI smoke for public command behavior.
- A small, representative codegen audit subset.
- A small, representative formatter/purify CLI surface check.

Deep or premerge gates should own broad sweeps:

- Full codegen audit.
- Full formatter corpus validation if it remains useful.
- Broad package lifecycle integration.
- Any large generated-C warning sweep.
- Expensive `compiler/blorp/tests` subsets that are not needed in every local
  iteration.

## Active Roadmap

### 1. Split Fast and Deep Compiler Gates

Add explicit gate names instead of making `compiler` mean every compiler-related
thing.

Proposed shape:

- `scripts/test compiler` runs parser, infer, and typecheck surface fixtures.
- `scripts/test compiler-deep` runs full codegen audit, formatter/purify tool
  fixtures, and broad compiler-owned integration sweeps.
- `scripts/test premerge` or the existing premerge script runs both fast and deep
  gates.

Expected impact: minutes saved on local runs, because full codegen audit is one
of the largest sources of subprocess and C compiler work.

Correctness guardrail: every test removed from the default compiler gate must
move to a named deep/premerge gate unless it is obsolete or duplicate.

### 2. Remove Hidden Formatter Duplication

Formatter coverage should have one clear owner.

Keep:

- Focused `format/should_pass`, `format/should_fail`, and `format/should_error`
  fixtures.
- A small CLI smoke proving `blorp format` formats a representative file and
  `--check` accepts it.
- Formatter tool command parsing tests if the standalone tool remains supported.

Avoid:

- Running formatter roundtrip over every parser fixture.
- Running full std formatting from CLI smoke.
- Running full formatter-source formatting from CLI smoke.
- Running corpus-level formatter checks in both compiler and CLI gates.

Expected impact: fewer `blorp format` subprocesses and a clearer ownership model.

Follow-up quality issue: `format/should_fail/wrapped_string_literals.brp`
exposed a formatter idempotence bug where the first format wraps strings and the
second format inserts blank lines. Fix that as a formatter behavior change, not
as part of test harness cleanup.

### 3. Move Formatter and Purify Tests In Process or Batch Them

Formatter and purify tool fixtures live in `compiler-deep`, not the default
compiler gate. They still shell out because the public CLI is the available
interface.

Preferred long-term shape:

- Expose formatter check/format entry points to the compiler test runner without
  launching `./blorp` per file.
- Expose purify dry-run/rewrite entry points similarly, or add a batch command
  that handles many files in one compiler process.
- Keep only a few CLI-level formatter/purify checks in `tests/test_cli.sh`.

Expected impact: reduces hundreds of small compiler subprocesses while retaining
the same fixture coverage.

### 4. Make Codegen Audit Two-Tiered

Full codegen audit is valuable, but expensive.

Fast default:

- Select a representative subset covering the warning classes and codegen areas
  most likely to regress.
- Keep the subset explicit and named, not random.

Deep/premerge:

- Run the full codegen audit corpus.
- Keep the full generated-C warning sweep here.

Expected impact: large local speedup. Full codegen audit remains available before
merge and release.

### 5. Batch Compiler Blorp Bridge Work

`compiler/blorp/tests` are architecturally important, but expensive because they
exercise the Blorp-owned compiler surface through parser, CLI frontier,
bridge/rendering, and Core-tail paths.

The typecheck bridge now accepts one explicit graph request and streams one
artifact per requested module plus the target. The request separates all import
modules from the ordered `module_targets` that actually need artifacts. This
preserves the old pipeline rule that embedded std modules can supply signatures
without being redundantly typechecked and decoded.

Implemented shape:

- Batch all module typecheck requests into one helper process.
- Stream artifacts so the Blorp helper does not retain one giant response tree.
- Keep module selection and typechecking semantics in Blorp; OCaml only builds
  the request, decodes responses, and populates its transitional module cache.
- Keep the bridge protocol explicit and deterministic.

Measured impact for generating `compiler_cli_main.brp`: 43 typecheck helper
calls became one. Typecheck bridge time fell from 145.0s to 112.9s and total C
generation fell from 175.7s to 141.1s.

Known hole: parsed `CompilerImportableModule` values cannot yet be reused across
multiple typecheck calls in one generated helper. The first call invalidates
shared nested data and the second crashes in
`compiler_resolve_qualified_type_name`. The graph helper therefore prepares
imports independently for each artifact, matching the proven `typecheck_source`
ownership boundary. Reusing parsed imports requires a dedicated ownership
lowering fix and a production-sized regression; it must not be restored as a
local bridge optimization.

The transitional OCaml process runner still captures the streamed stdout as one
string before decoding lines. Removing that final response buffer belongs with
deleting the OCaml host or replacing its process transport; it is not a reason
to add a second cache or protocol implementation there.

### 6. Reuse Prepared Bridge Helpers

The bridge helper content-addressed cache already exists. The explicit
`__compiler-bridge-prepare` path now uses it instead of recompiling helper
binaries into a fresh startup directory on every `scripts/test` invocation.
Preparation still copies verified helpers into the run-local directory so the
test harness can set explicit prepared-helper paths and fail loudly if those
paths are lost.

Expected impact: roughly 16-21 seconds saved on warm test runs.

Correctness guardrail: helper reuse must be keyed by helper source, compiler
binary, relevant std/compiler sources, compile flags, and platform facts that
affect the helper binary.

### 7. Reduce Full-Run Oversubscription

The full gate used to run every selected top-level gate in parallel, while some
of those gates also ran internal workers. That was simple in the shell but
expensive in practice: runtime and compiler-unit became several times slower
when competing with the CPU-heavy compiler fixture runner.

The current approach is deliberately simpler than a scheduler:

- Run selected gates in fixed waves: `compiler-unit`, `compiler-unit-deep`,
  `compiler`, `compiler-deep`, `runtime`, then `leak + doctest + cli`.
- Keep each gate responsible for its own internal strategy.
- Do not infer CPU needs from names, timings, or machine load.

Expected impact: more predictable full-run behavior and fewer timeout flakes
under load. This may trade some best-case wall time for clarity until the
default gate is slimmed down further.

### 8. Keep Runtime Process Tests Narrow

Runtime/std tests currently have a small number of subprocess call sites. Most
are justified because they test process, system, signal, or IO behavior.

Keep them narrow:

- Process API tests should cover behavior directly, not compiler behavior.
- IO tests that need stdin/stdout should use one generated program where possible.
- Avoid nested `./blorp` calls in runtime tests unless the CLI/process boundary is
  genuinely the behavior under test.

Expected impact: keeps runtime tests from regrowing the previous nested compiler
property-test problem.

## Whole-Compiler Performance Recovery Roadmap

This is the active performance track. Complete the checkpoints in order unless
a checkpoint explicitly says it can proceed independently. Each measured
change should be a coherent commit so regressions can be bisected without
untangling unrelated migration work.

### P0. Add Phase Accounting and Re-Baseline

**Status:** implemented on 2026-07-15; the isolated post-P1 compiler-owned
sweep is the retained comparison log.

**Goal:** make every expensive compiler-deep minute attributable to a named
operation before changing behavior.

**Implementation:**

- Extend `scripts/test --timings` to request and retain generated-suite compile
  timings, not only Alcotest case timings.
- In `compiler/lib/test_runner.ml`, record test discovery, run-all eligibility,
  isolation-group planning, generated-harness compilation, host C compilation,
  and harness execution separately.
- In `compiler/lib/pipeline.ml`, expose timing for in-memory frontend graph
  construction, graph finalization, graph typechecking, the OCaml-owned
  semantic middle, and Blorp-owned backend emission. Reuse the existing
  `BLORP_COMPILER_BRIDGE_STATS` records in
  `compiler/lib/compiler_blorp_bridge.ml` instead of creating a competing
  bridge timer.
- Emit stable machine-readable records containing the group identity, suite
  count, source count, elapsed time, and peak memory when available. Keep the
  normal console summary compact; full records belong in `--log-dir` output.
- Count frontend graph builds, typecheck requests, generated C compilations,
  and executed harnesses. Counts are as important as elapsed time because they
  distinguish repeated work from a slow individual phase.

**Tests:**

- Add focused parser/format tests for the timing records in
  `compiler/test/test_test_runner.ml` and `compiler/test/test_pipeline.ml`.
- Add a shell-harness assertion that `scripts/test --timings --log-dir ...`
  preserves the records without changing test selection or exit status.
- Run compiler-deep alone at least twice and retain both logs. Use the second
  isolated run as the comparison baseline if the first includes bootstrap
  preparation.

**Implemented shape:** `Pipeline.phase_timing` reports the source-to-C phase
boundaries without retaining IR or introducing another pipeline. The semantic
middle/backend split uses the existing `Core_stage.Dce` handoff: work before
that event is the transitional OCaml-owned middle, while work after it is the
Blorp-owned backend. `Test_runner.timing_event` adds discovery, harness
planning, total pipeline, host-C, and execution records. `scripts/test
--timings` retains the machine-readable records in gate logs and prints compact
phase totals.

The final 94-suite validation produced 10 records for every generated-harness
phase and passed all 1,700 contained tests. Its phase totals were 108.396s for
frontend graph construction, 0.006s for graph finalization, 432.459s for graph
typechecking, 15.456s for the OCaml-owned semantic middle, 254.831s for
Blorp-owned backend emission, 18.584s for host C, and 16.798s for test
execution. A separate `compiler-deep` run in another checkout overlapped this
measurement, so retain the operation counts and phase proportions but do not
use these elapsed totals as an uncontended before/after speed claim.

**Exit condition:** one compiler-deep log accounts for all generated harnesses
and separates Blorp frontend/typecheck time, semantic-middle time, backend
time, host C time, and execution time. The sum may differ slightly from wall
time because total and child phases intentionally overlap, but no multi-minute
interval is unclassified.

**Pitfalls:** timing must not serialize work that is normally parallel, retain
large graphs solely for reporting, or introduce a second source of truth for
phase names.

### P1. Remove the Four-Suite Correctness Workaround

**Status:** implemented on 2026-07-15 with a resource-bound correction to the
original one-unbounded-group proposal.

**Goal:** remove the arbitrary suite-count limit and stale path-specific
correctness exceptions. Compile as much compatible source work together as is
currently memory-safe, with additional groups only for an explicit execution
isolation rule or an explicit source-work budget.

**Investigation:**

- Reproduce groups of 5, 16, and all eligible compiler TestSuites outside the
  runner's four-suite chunking.
- Distinguish compilation failure, failure before `main`, test failure, failure
  during global teardown, leak-check failure, and sanitizer failure. Do not
  classify all nonzero exits as a batch-size problem.
- Inspect Core and generated C for `tests: TestSuite`,
  `__blorp_init_globals`, and global cleanup. Relevant implementation and tests
  begin in:
  - `compiler/blorp/src/stage_10_backend/compiler_core_emit.brp`
  - `compiler/blorp/src/stage_09_core/compiler_core_perceus.brp`
  - `compiler/blorp/src/stage_09_core/compiler_core_prepare.brp`
  - `compiler/blorp/src/stage_09_core/compiler_core_closure.brp`
  - `compiler/blorp/tests/test_compiler_core_emit.brp`
- Determine whether immutable TestSuite globals should be materialized by CTFE
  or require runtime initialization. Fix the earliest stage that owns the
  violated invariant; do not special-case test names or generated harnesses in
  codegen.

**Investigation result:**

- A five-suite harness passed all 11 contained tests.
- A 16-suite, approximately 232 KiB source group passed all 131 contained
  tests.
- The formerly conflicting `typecheck_decl + infer` group passed 304 tests.
  The formerly conflicting `impl_decl + resource_decl + state + types` group
  passed 26 tests. No initialization, early-exit, or teardown defect remained
  to fix, so the three path exceptions were removed.
- One unbounded 94-suite harness was not viable: the OCaml host reached roughly
  7.3 GB RSS and the Blorp bridge roughly 8.7 GB RSS before the probe was
  stopped to avoid exhausting the machine. This is retained-graph pressure,
  not a semantic isolation requirement. Treating "one group" as an invariant
  would make P1 less reliable and would work against the planned move of test
  planning into Blorp.

**Implementation:**

- Correct global ownership, initialization, or teardown only if a focused
  reproduction demonstrates a defect. Do not create speculative Core or
  codegen changes when current behavior is correct.
- Replace `run_all_suite_batch_size` and `test_compilation_isolation` with a
  stable accumulated source-byte partition. Suite count is not a useful proxy:
  compiler-owned test files differ by more than an order of magnitude in size.
- Use a named 256 KiB source budget, based on the successful 16-suite probe.
  A source larger than the budget forms a one-item group, and no item is
  dropped or reordered. This is a resource policy, not a correctness
  distinction.
- Detect doctests only inside actual `---` docstring blocks. This keeps parser
  fixtures containing escaped `doctests:` source text in the normal TestSuite
  groups instead of silently compiling them through a separate path.
- Re-evaluate the three currently isolated compiler typecheck declaration
  suites. Keep isolation only when a focused regression demonstrates an
  inherent process-level requirement and documents it next to the declaration.
- Compile one run-all harness per source-work group and run each group's tests
  in one process. Keep the grouping function pure and independent of OCaml
  compiler state so it can move with test planning into Blorp.

**Tests:**

- Add a runtime regression with more than four modules whose globals contain
  TestSuites and closure-valued test cases.
- Cover successful initialization, an unused imported global, deterministic
  cleanup, and a failing test that still exits cleanly.
- Run the focused generated-harness tests under ASan, UBSan, and leak-check.
- Assert in `test_test_runner.ml` that five small compatible suites remain one
  group, ordering is stable, accumulated work respects the budget, and one
  oversized source forms a one-item group.
- Run the full `compiler/blorp/tests/` sweep before and after and compare phase
  counts from P0.

**Exit condition:** normal run-all coverage performs one graph build, one
typecheck request, and one generated-C compile per explicit source-work or
execution-isolation group. There is no arbitrary suite-count threshold and no
path-specific workaround for the compiler test directory.

**Expected impact:** the 94-suite compiler-owned sweep produces 10 source-work
groups instead of roughly 24 four-suite groups. P3 and P4 must reduce graph
duplication and representation lifetime before one whole-corpus group is a
safe target. The actual speed claim uses the P0 records rather than the group
count alone.

**Verification and hardening:**

- The normal 10-group sweep passed all 1,700 tests. The full ASan/UBSan sweep
  also passed all 1,700 tests with the same group plan.
- Sanitized phase totals were 117.464s for frontend graph construction, 0.010s
  for graph finalization, 542.001s for graph typechecking, 19.614s for the
  semantic middle, 343.033s for backend emission, 90.109s for host C, and
  57.534s for execution. These totals are validation evidence, not a speed
  baseline, because sanitizer instrumentation changes both compile and runtime
  cost.
- A normal compiler-owned Blorp group can exceed the ordinary 30-second
  single-test budget, so grouped compiler suites use a measured 60-second
  default. The largest healthy sanitizer group takes about 107 seconds to
  execute on the measured macOS ARM host, so compiler sanitizer gates use a
  separate 180-second default. `BLORP_COMPILER_TEST_TIMEOUT` and
  `BLORP_COMPILER_SANITIZE_TEST_TIMEOUT` remain the explicit overrides.
- The sanitizer sweep exposed a runtime teardown defect independent of grouping:
  Apple ASan attempted to unmap each worker's malloc-backed alternate signal
  stack at thread exit. ASan builds now rely on ASan's stack-overflow reporting
  and do not register those worker signal stacks; ordinary and UBSan builds
  retain Blorp's alternate-stack handler.
- The expanded leak-check integration exposed ambient host mutation:
  `run_test_infos` set `BLORP_LEAK_CHECK=strict` globally, contaminating later
  compiler tests. Leak mode is now passed only to generated child processes,
  and the regression asserts that the long-lived OCaml host environment is
  unchanged.
- `scripts/test compiler-unit-deep --serial --timings` passed all 343 tests after
  the hardening fixes. This covers repeated test-runner use in one process and
  the source-to-C pipeline callback surface.

### P2. Index Name Candidates in the Compiler Environment

**Status:** implemented and verified on 2026-07-15.

**Goal:** remove expression-count times environment-size scans from inference
without changing lookup precedence or overload behavior.

**Current issue:** `CompilerScope` in
`compiler/blorp/src/stage_05_types/compiler_env.brp` had an ordered symbol list
and a latest-symbol dictionary. Exact lookup used the dictionary, but history,
module-qualified, constructor, and UFCS queries repeatedly scanned every symbol
in every scope. Whole-compiler graphs make those expression-count times
environment-size scans a material cost.

**Implementation:**

- Change the existing per-scope `symbols_by_name` dictionary to map each name to
  one newest-first list of positions in the scope's canonical symbol list. The
  first position names the latest symbol. This avoids retaining a second copy of
  every symbol and its nominal type graph merely to accelerate lookup.
- Keep the canonical symbol list in declaration order for deterministic full
  enumeration, record-field shape matching, callable-id lookup, and fuzzy
  diagnostics. Resolve indexed positions only at the lookup boundary.
- Update `compiler_scope_add_symbol` once so the ordered list and candidate
  index cannot diverge. Centralize candidate and latest lookup in private scope
  helpers.
- Preserve current ordering exactly: innermost scope before outer scopes and
  newest declaration before older declarations within one scope.
- Rewrite these functions to start from indexed candidates:
  - `compiler_env_symbols_named`
  - `compiler_env_get_module_var_symbol`
  - `compiler_env_get_module_func_symbol`
  - `compiler_env_get_constructors`
  - `compiler_env_lookup_function_ufcs_methods`
  - `compiler_env_lookup_module_function_ufcs_methods`
  - `compiler_env_has_ufcs_method`
- Keep module, import, lexical, concrete-vs-generic, and declaration-order
  ranking in their existing named policies. The index narrows candidates; it
  must not decide semantic precedence.

**Tests:**

- Protect same-scope shadow history, cross-scope candidate ordering, and
  latest-symbol lookup.
- Cover lexical symbols shadowing explicit imports, module-qualified variable
  and function lookup, constructors with the same name in several types,
  regular function symbols participating in UFCS, module/receiver filtering,
  and concrete UFCS methods outranking generic methods.
- Add deterministic counters or a compiler benchmark showing that a lookup
  visits candidates for the requested name rather than all symbols. Do not put
  wall-clock assertions in unit tests.
- Re-run the compiler-oriented AST, symbols, inference, and full CLI-generation
  benchmarks.

**Exit condition:** no exact-name candidate query performs an unconditional
full scan of each scope. All precedence tests pass and P0 reports a measurable
reduction in graph typecheck time or demonstrates that another phase dominates.

**Focused measurement:** two uncontended helper-only A/B pairs held the
renderer, parser, semantic middle, backend, host C compiler, and test workload
constant while swapping only `BLORP_COMPILER_TYPECHECK_BRIDGE_BIN`. The old
environment took 18.091s and 19.342s to typecheck the combined inference/types
workload; the indexed environment took 16.788s and 18.151s. The averages are
18.717s and 17.470s respectively, a 6.7% typecheck improvement. This is a
measurable but modest win, below the original 20-40% working estimate, so later
work should follow P0 evidence rather than extending environment indexes
speculatively.

**Verification:** all ten compiler-owned source-work groups passed, totaling
1,703 tests. The indexed environment, inference, and type suites also passed
259 tests under ASan/UBSan. An aggregate invocation was terminated when an
independent automatic `make install` rebuilt the whole compiler concurrently;
rerunning every existing source-work group explicitly produced the complete
passing result without changing selection or assertions.

### P3. Keep Generated-Test Frontend Work in Blorp

**Goal:** stop the OCaml TestRunner from generating source and then re-entering
the Blorp CLI/frontend through a second process and serialized module graph.

**Target architecture:**

1. Blorp discovers or receives the selected TestSuite modules.
2. Blorp constructs the generated run-all module in memory and adds it to the
   already loaded frontend graph.
3. Lexing, parsing, module loading, graph finalization, and graph typechecking
   remain one contiguous Blorp operation.
4. One typed semantic-middle request crosses the transitional OCaml boundary.
5. The Blorp backend emits C; the command compiles and executes the harness.

**Implementation:**

- Move the behavior of `generate_suite_selector_harness` and
  `generate_suite_run_all_harness` from `compiler/lib/test_runner.ml` to the
  Blorp test-command/compiler modules. Preserve deterministic module aliases,
  test ordering, filtering, and source diagnostics.
- Add an explicit in-memory module constructor to the Blorp module graph. A
  generated module must have a real source identity and import edges; do not
  infer generated status from a filename or source prefix.
- Reuse the CLI graph built for the test command. Do not call
  `Pipeline.compile_generated_test_harness` or
  `compile_in_memory_source_with_blorp_bridge` for the normal path.
- Narrow OCaml `Test_runner` to the responsibilities still on the OCaml side,
  then delete the superseded generation and bridge entry points once no
  production caller remains.
- Preserve one bridge: the typed semantic-middle request. Do not introduce a
  test-only parser bridge or a second graph protocol.

**Tests:**

- Port selector, run-all, duplicate-name, filtering, diagnostics, and exit-code
  regressions to Blorp-owned tests before deleting their OCaml equivalents.
- Add an integration assertion from bridge statistics that one test command
  performs one frontend graph construction and one semantic-middle request for
  each explicit isolation group.
- Compare generated Core and C for a representative harness before and after.
- Verify source spans in failures still point to the user test module rather
  than the generated harness wherever possible.

**Exit condition:** the production `blorp test` path does not serialize a
generated source string to an OCaml TestRunner and then invoke the Blorp
frontend again. Deleted OCaml APIs have no test-only callers left behind.

### P4. Reduce Graph Copies, Serialization, and Peak Retention

**Goal:** after compile count is fixed, reduce the cost and memory footprint of
the one remaining whole-compiler compile.

**Implementation:**

- Use P0 allocation and phase data to identify which graph representation is
  simultaneously live at peak RSS: source, parsed modules, JSON projection,
  decoded OCaml graph, typed graph, Core JSON, or generated C.
- Release each phase-owned representation immediately after the next owner has
  accepted it. Express ownership in phase-specific types or function
  boundaries rather than setting unrelated fields to sentinels.
- Stream module artifacts at existing protocol boundaries where the consumer
  can process them incrementally. Do not retain a giant response tree merely
  to split it into modules afterward.
- Remove decode/re-encode cycles that cross no architectural ownership
  boundary. Prefer deleting the transitional OCaml representation as the
  Blorp footprint advances over optimizing its JSON parser in isolation.
- Audit large `List.append` construction, repeated string concatenation, and
  full-list `map` chains in graph projection and Core serialization. Use the
  existing string builder and single-pass folds only where profiles show a
  material producer cost.

**Tests:**

- Keep protocol roundtrip and malformed-input tests at every surviving bridge.
- Add production-sized ownership/leak regressions under sanitizer gates.
- Compare output hashes or normalized Core/C for representative compiler
  inputs to prove that streaming and early release do not reorder artifacts.
- Record peak RSS and per-phase request/response byte counts in the same
  isolated benchmark used for P0.

**Exit condition:** peak live representations are documented, avoidable graph
copies are removed, and peak RSS falls materially from the isolated P0
baseline without weakening diagnostics or deterministic output.

### P5. Delete Superseded Work and Duplicate Coverage

**Goal:** turn every boundary movement into less production and test code, not
another permanent implementation layer.

**Implementation:**

- After P1-P4, run reference searches from the production CLI inward and list
  OCaml functions with no production callers, then test-only callers, then
  compatibility wrappers around removed paths.
- Delete old generated-harness builders, old in-memory frontend bridge entry
  points, redundant graph decoders, and tests that only assert substrings in
  Blorp source.
- Retain OCaml tests only for production OCaml responsibilities. Move behavior
  tests to Blorp before deleting an implementation, then remove duplicated
  OCaml assertions in the same change.
- Review compiler Blorp tests for duplicate fixture coverage made unnecessary
  by the unified run-all path. Prefer one semantic regression over several
  transport-shape tests.
- Update `docs/ARCHITECTURE.md`, the migration roadmap, and gate ownership in
  `AGENTS.md` whenever a production boundary is deleted.

**Tests:**

- Run unused-code tooling and `rg` call-site audits for both OCaml and Blorp.
- Run the focused owner gate after each deletion, then all normal gates before
  combining the cleanup with later migration work.
- Compare gate test counts and document every removed case as duplicate,
  obsolete, or transferred. A lower count without that accounting is not a
  performance result.

**Exit condition:** no superseded API survives solely for its old tests, and
the architecture documentation names only production paths that still exist.

### P6. Consider Separate Compilation Only After Duplication Is Gone

**Goal:** decide from evidence whether a stable compiler-library artifact is
needed after P1-P5.

Do not start here. Separate compilation adds artifact identity, ABI/versioning,
linking, invalidation, diagnostics, and ownership questions. It is justified
only if P0 still shows one unavoidable whole-compiler compile dominating the
feedback loop after repeated harness compilation and environment scans are
removed.

If needed, scope it as an explicit compiler feature:

- Define the typed/Core artifact boundary and content identity.
- Compile stable compiler modules once per command invocation, not through a
  hidden cross-run cache.
- Compile only generated harness code against that artifact.
- Validate deterministic linking, global initialization order, diagnostics,
  sanitizer behavior, and bootstrap compatibility.

**Exit condition:** either measurements reject separate compilation as needless
complexity, or a separate design document establishes its semantics before
implementation.

### P7. Validate the New Feedback Loop

Run these checkpoints in an otherwise idle checkout:

1. `make`
2. `scripts/test compiler-unit compiler --serial --timings --log-dir ...`
3. `scripts/test compiler-deep --serial --timings --log-dir ...`
4. `scripts/test compiler-blorp-sanitize --serial --log-dir ...`
5. `scripts/test leak --serial --log-dir ...`
6. The full normal and premerge gate sets.

Report before/after values for graph builds, typecheck requests, generated C
compiles, host C compiles, wall time, user CPU, and peak RSS. The first milestone
is at least a 50% reduction in the compiler-owned Blorp portion of
compiler-deep from the isolated P0 baseline. The prior approximately four-minute
deep measurement is useful context, but not a hard target because the compiler
surface and test count have grown.

Do not claim a speedup from a warm cache, a contended baseline, fewer selected
tests, or a run that skipped sanitizer/leak behavior required by its gate.

## Completed Slice

The first high-leverage split is implemented:

1. `scripts/test compiler` runs fast parser, infer, and typecheck surface
   fixtures without bridge-helper preparation or the broad std typecheck
   preflight.
2. `scripts/test compiler-deep` runs the full generated-C audit, formatter and
   purify tool fixtures, and compiler-owned Blorp TestSuites explicitly.
3. `scripts/premerge-gate` includes both gates, so premerge coverage still pays
   for the full audit, format/purify coverage, and compiler-owned Blorp
   coverage.
4. The runner docs and command references expose the distinction.
5. `tests/test_compiler/run_compiler_tests.sh` is now a thin wrapper around a
   test-only Dune executable; the shipped `blorp` CLI no longer exposes
   compiler fixture plumbing.
6. The compiler runner now terminates active worker processes on SIGTERM/SIGINT,
   and `scripts/test` failure excerpts include infrastructure errors such as
   `Error:` lines instead of printing an empty failure block.
7. Multi-gate `scripts/test` now uses fixed waves instead of launching every
   selected gate at once. The reason is predictability: the heavyweight gates
   already perform internal parallel work, so the top-level harness should avoid
   making contention worse instead of becoming a second scheduler.
8. `scripts/test cli` is now smoke-only, while `scripts/test cli-deep` preserves
   the full package lifecycle and formatter-tool integration coverage for
   premerge. The reason is ownership clarity: checking public command contracts
   is a different job from exercising package cache/vendor workflows and
   compiling the self-hosted formatter tool.
9. `__compiler-bridge-prepare` now resolves renderer/parser helpers through the
   shared content-addressed cache before copying them into the run-local startup
   directory. The cache key now also includes `std/` sources, because helper
   generated C can depend on shipped std code as well as compiler-owned Blorp
   sources. A warm `scripts/test cli` run after this change reported `bridge
   prepare 0s`, down from a 19s cold prepare after the cache-key change.
10. `scripts/test compiler-unit` now runs only phase-local, unit-shaped
    Alcotest suites. Session, LSP, package, pipeline, test-runner, compiler
    fixture-runner, and compiler bridge suites moved to the explicit
    `compiler-unit-deep` gate. The reason is not deletion of coverage; it is
    ownership clarity. These tests cross process, session, module graph,
    runtime execution, or bridge boundaries and belong in an internal
    integration gate that premerge still runs.
11. `scripts/test --timings` now enables opt-in per-case timing for
    `compiler-unit` and `compiler-unit-deep`. The runner prints the slowest
    cases and writes stable `BLORP_COMPILER_UNIT_TIMING` records into logs, so
    future speed work can be based on measured slow cases instead of moving
    suites by intuition.
12. Package-cache tests now build valid `.blorpkg` fixtures directly from
    package entries instead of first running full source-package validation and
    then asking `Package_cache.fetch` to validate the unpacked cache contents
    again. The cache behavior is still covered by `Package_cache.fetch`; the
    removed work was duplicate setup.
13. Several compiler-unit inventory tests now share source walks/parses inside
    the test executable. This keeps the broad architecture assertions intact
    while avoiding repeated fixture work in `TypeBoundaryHygiene`,
    `BuiltinConsistency`, and `OperationResultMetadata`.
14. The std inventory in `BuiltinConsistency` now uses the existing parser
    bridge batch API, so it parses all std sources in one request instead of one
    bridge call per file. The `TypeBoundaryHygiene` source-scan helper now
    compares tokens in place instead of allocating a fresh substring at every
    candidate offset.
15. Compiler surface typecheck fixtures now reuse one worker-local frontend
    session per runner worker. Each case resets all semantic compilation state
    before typechecking, but preserves the validated parse cache, so std and
    imported module parse artifacts can be reused without leaking impls, UFCS
    methods, module caches, package config, std override state, inference metas,
    or fresh ids across independent fixtures.
16. The broad `./blorp check --no-format std` sweep is no longer a hidden setup
    preflight. It is an explicit `scripts/test std-check` gate, and
    `scripts/premerge-gate` names that gate directly. The reason is clarity:
    setup should prepare shared infrastructure, while broad source validation
    should be visible as coverage with its own result row.
17. Ordinary `make` no longer hides a full formatter warmup. `make warm` owns
    that explicit operation, while `make build` asks Dune for only
    `bin/blorp_ocaml_host.exe`. A warm `make build` now takes about 0.08s instead
    of roughly 2s.
18. Dune artifact caching is owned explicitly by CI workflows rather than being
    mixed into the opam action cache. Cache keys include OS, architecture, OCaml
    compiler, and commit, with platform/compiler restore prefixes. Generated
    CLI fingerprints include the pinned bootstrap script and resolved compiler
    binary.
19. Runtime tests now model execution isolation separately from compilation
    isolation. Concurrency, memory, and system suites compile one selector per
    explicit isolation domain, then each suite still runs in a fresh process.
    The full uncached runtime/std corpus fell from 353.3s to 179.9s; five
    uncached concurrency repeats passed 1,060 tests.
20. Compiler graph typechecking now crosses the JSON bridge once per graph and
    streams results. It retains independent per-artifact import preparation
    because shared prepared imports currently expose the ownership bug recorded
    above.
21. The default runtime gate no longer runs `tests/test_blorp/memory` before the
    leak gate runs the same suites with leak instrumentation. The leak gate is
    now the sole owner of those assertions, removing one isolated selector
    compilation from the default runtime sweep without dropping coverage.
22. Exact-duplicate and overlapping test cleanup removed the duplicated DSP
    runtime suite, duplicate directory and assignment suites, a superseded
    geographic suite, duplicate formatter and parser fixtures, an orphaned
    package helper, and redundant standalone string-repeat and character-trait
    suites. Obsolete SIMD compatibility/demo suites were removed while the
    distinct tier, operation, and function-boundary suites remain. Unique edge
    cases moved into the canonical string and character suites. The codegen
    audit now checks static list and derived-string constants in one fixture
    instead of compiling the same source twice.
23. CLI smoke now keeps one representative success/failure contract per public
    command. Detailed multi-file dumps, repeat/timeout behavior, parse-error
    variants, and uncommon option combinations remain in `cli-deep`, where the
    process boundary is intentional. Tests for two long-removed formatter flags
    and a removed formatter command were deleted instead of preserving
    migration-specific behavior. Generic unknown-command behavior remains
    covered at the parser boundary.

Verification for this cleanup slice:

- Runtime/std without the memory suites: 4,802 passed in 4m18s before the
  final obsolete SIMD fixture removals.
- The memory suites owned by the leak gate: 77 passed in 3.64s without leak
  instrumentation; omitting their duplicate runtime execution is a modest but
  direct saving.
- CLI smoke: 28 passed in 30.82s, down from the previously recorded 2m10s
  broad CLI gate.
- CLI deep: 77 passed in 1m54s, confirming that detailed command integration
  coverage remains available.
- Retained SIMD suites: 53 passed in 4.4s.

This removes the largest redundant default-local sweep without deleting the
coverage.

Latest measurement after moving formatter/purify tool fixtures out of the
default compiler gate:

- `BLORP_TEST_LOCK_HELD=1 scripts/test compiler --serial`
- 1,483 passed, 0 failed
- 3m35s compiler gate time
- 4m39s wall time, including 1m04s std preflight
- 0s bridge-helper preparation

Follow-up after dropping std preflight from compiler-only runs:

- `BLORP_TEST_LOCK_HELD=1 scripts/test compiler --serial`
- 1,483 passed, 0 failed
- 3m05s compiler gate time
- 3m06s wall time
- 0s bridge-helper preparation
- 0s std preflight

Deep compiler gate measurement:

- `BLORP_TEST_LOCK_HELD=1 scripts/test compiler-deep --serial`
- 981 passed, 0 failed
- 3m45s compiler-deep gate time
- 4m03s wall time, including 16s bridge-helper preparation and 1s cached std
  preflight

Post-wrapper-simplification verification:

- `BLORP_TEST_LOCK_HELD=1 scripts/test compiler --serial`
- 1,483 passed, 0 failed
- 3m35s wall time
- 0s bridge-helper preparation
- 0s std preflight

Compiler-unit split verification:

- `scripts/test compiler-unit --timings --log-dir scratch/test-unit-timings-default-20260706-final`
- 1,847 passed, 0 failed
- 1m55s compiler-unit gate time
- 0s bridge-helper preparation
- 0s std preflight
- Current slowest cases are inventory-style assertions over std/builtins/type
  boundaries. They should stay measured before any further cleanup, because they
  are validating broad compiler invariants rather than ordinary local helpers.

Compiler-unit verification after shared inventory fixtures:

- `scripts/test compiler-unit --timings --log-dir scratch/test-unit-timings-inventory-cache-20260706`
- 1,847 passed, 0 failed
- 1m55s compiler-unit gate time
- `OperationResultMetadata.std_operation_result_builtins_are_public_direct`
  dropped out of the slow-case list after caching parsed std declarations. The
  remaining top cases still perform one broad std parse or one broad compiler
  source scan, so the total wall time did not materially move.

Targeted inventory follow-up:

- `BuiltinConsistency.prelude_entries :: public ABI types have std anchors`
  dropped from about 2.2s to about 1.47s after switching the std inventory to
  the parser bridge batch API.
- `TypeBoundaryHygiene.boundaries :: late layout fallbacks stay inventoried`
  dropped from about 1.7s to about 0.48s after removing allocation-heavy
  substring checks from the source-scan helper.

Compiler-unit verification after batched std inventory and faster source scans:

- `scripts/test compiler-unit --timings --log-dir scratch/test-unit-timings-batch-and-token-20260706-final`
- 1,847 passed, 0 failed
- 1m54s compiler-unit gate time
- `TypeBoundaryHygiene` dropped out of the top slow-case list. The broad std
  inventory still appears around 2.2s in the full run, likely because it still
  performs one real parse of every std source file.

Compiler fixture batching probe:

- A worker-local parser-batch cache for compiler surface fixtures passed all
  1,483 tests, but measured `real 253.94s`, `user 1979.01s`, `sys 74.57s`.
- A parent-level parser-batch cache also passed all 1,483 tests, but measured
  `real 276.93s`, `user 2172.11s`, `sys 79.51s`.
- Both are worse than the prior `scripts/test compiler` checkpoint around
  3m05s wall time. Parser batching alone is therefore not the right lever for
  this runner: it reduces bridge request count but loses too much parallelism
  and leaves typecheck/module work dominant.
- Do not reintroduce fixture parser batching unless it is paired with a larger
  in-process batch typecheck/module-loading design and measured against the
  full compiler surface gate.

Compiler fixture reusable typecheck-session verification:

- `scripts/test compiler --log-dir scratch/test-compiler-reusable-typecheck-20260706`
- 1,483 passed, 0 failed
- 1m15s compiler gate time
- 1m16s wall time
- 0s bridge-helper preparation
- 0s std preflight
- Direct runner measurement for the same surface corpus:
  `real 74.38s`, `user 570.31s`, `sys 22.13s`.
- This is the batching boundary that paid off. Parser-only batching reduced
  bridge calls but regressed wall time; reusing the typecheck session preserves
  parallel workers while avoiding repeated parse/module setup inside each
  worker.

Explicit std-check verification:

- `scripts/test std-check --log-dir scratch/test-std-check-explicit-20260706`
- 1 passed, 0 failed
- 1m15s std-check gate time
- 1m16s wall time
- This replaces the hidden std typecheck setup stage with visible coverage that
  premerge names directly.

Compiler-unit deep verification:

- `scripts/test compiler-unit-deep --log-dir scratch/test-unit-split-deep-20260706`
- 309 passed, 0 failed
- 4m21s compiler-unit-deep gate time
- 0s bridge-helper preparation
- 0s std preflight

Compiler-unit deep timing after direct package-cache artifacts:

- `scripts/test compiler-unit-deep --timings --log-dir scratch/test-unit-deep-timings-package-cache-after-20260706`
- 309 passed, 0 failed
- 1m57s compiler-unit-deep gate time
- The previous package-cache slow cluster moved from roughly 2.0-2.4s per case
  to roughly 1.2-1.6s per case.
- The current slowest cases are LSP/module/package source-policy integration
  coverage and one combined TestSuite harness regression. Those remain explicit
  deep coverage until there is a narrower in-process assertion that preserves
  the behavior being tested.

Compiler-unit deep verification after reusable typecheck-session coverage:

- `scripts/test compiler-unit-deep --log-dir scratch/test-unit-deep-reusable-session-20260706`
- 312 passed, 0 failed
- 1m48s compiler-unit-deep gate time

## Recommended Next Slice

Execute the recovery track in this order:

1. Retain the P0 timing log and P1 reproduction results as the comparison
   baseline. Re-run the same isolated sweep after each whole-compiler change.
2. Implement P2 as a separate measured commit. The candidate index is a
   generally useful compiler improvement independent of test-harness policy.
3. Move generated harness construction into the existing Blorp graph in P3.
   Do not optimize or retain the transitional OCaml round trip.
4. Use the new phase and memory data for P4, then delete superseded paths and
   duplicate tests in P5.

Keep formatter/purify fixtures in `compiler-deep` until an in-process or batched
interface reduces actual work. Keep the codegen audit split explicit. Those
remain valid gate-shaping improvements but are not the current 37-minute
bottleneck.

## Success Metrics

- Normal `scripts/test compiler` avoids full codegen audit, bridge-helper
  preparation, std-check, format/purify tool fixtures, and broad
  compiler-owned Blorp sweeps.
- Default full `scripts/test` avoids pathological gate contention without adding
  adaptive scheduling logic.
- Deep/premerge still runs the expensive coverage explicitly.
- Test summaries make it obvious which expensive coverage did or did not run.
- Runtime/std tests do not contain broad nested compiler tests.
- CLI smoke remains focused on public command behavior instead of corpus sweeps.
- Compatible compiler-owned TestSuites compile in source-work groups; no group
  exists because of suite count or a path-specific compiler workaround.
- Timings expose graph-build, typecheck, semantic-middle, backend, host-C, and
  execution counts and durations.
- The normal test command builds each generated frontend graph once and crosses
  the semantic-middle bridge once per explicit isolation group.
- Name candidate lookup scales with matching candidates rather than all symbols
  in every scope.
- Peak compiler memory is measured and materially lower than the isolated P0
  baseline after representation-lifetime work.
- No speedup depends on skipping coverage, weakening assertions, or preserving
  a superseded OCaml path solely for its tests.
