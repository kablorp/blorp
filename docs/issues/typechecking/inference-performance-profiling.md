# Inference Performance Harness And Counterfactual Profiling

## Issue Summary

Build a deterministic benchmark and profiling laboratory around the complete,
pure body-check boundary so inference performance work can be ranked by
evidence before production code is changed.

The benchmark input is `BodyCheckContext` directly. Do **not** introduce an
`InferInput`, a second context wrapper, a partial inference product, or a
benchmark-specific mode in production inference.

The work has four deliverables:

1. a reusable matrix of independently prepared `BodyCheckContext` values;
2. an isolated timing harness for `check_body_context`;
3. inclusive and exclusive function-level attribution inside the timing
   window; and
4. a disposable-worktree experiment driver for estimating the upper bound of
   candidate optimizations without retaining mock behavior in production.

This is an investigation and measurement issue. It does not authorize a solver
redesign or any optimization whose correctness is not subsequently established
through normal tests.

## Why This Issue Exists

Whole-compiler profiles establish that body inference is important, but they
do not answer which work inside inference is avoidable. They also mix parsing,
module loading, accepted-graph construction, body-context planning, inference,
finalization, validation, Core preparation, and process startup.

The existing `CompilerProfileCheckedBodies` stage narrows the envelope, but it
still constructs an accepted module and schedules all bodies inside each timed
stage execution. It is the correct broader Phase 6 baseline, not an isolated
inference benchmark.

The compiler now has a narrower and safer boundary:

```blorp
pure func check_body_context(context: BodyCheckContext) -> BodyCheckOutcome
```

`BodyCheckContext` is opaque and contains only:

- exact `CallableId` identity;
- an immutable `BodyInferSessionSeed`;
- the parsed source declaration;
- the accepted function-body signature;
- main-function validation policy; and
- stable source order.

Every call to `check_body_context` constructs a fresh `InferSession`. A context
therefore cannot retain substitutions, diagnostics, memoized type-shape facts,
or other mutable progress from a previous body check. The same context can be
reused across warmups, samples, repetitions, and order permutations without
changing the semantic input.

That contract is the reason this issue should use `BodyCheckContext` directly.
Wrapping it in `InferInput` would add no information and would create another
state whose relationship to the authoritative body context would need to be
maintained.

## Goals

- Measure complete body checking without measuring graph or context setup.
- Keep the benchmark boundary pure and identical to production behavior.
- Cover both workload size and distinct semantic pressure.
- Preserve complete outcomes until the timing window has ended.
- Detect accidental result, ordering, or input mutation differences.
- Report enough structural work to compare results across revisions.
- Distinguish inclusive time from exclusive/self time.
- Estimate candidate upper bounds without introducing permanent mock flags.
- Turn measured candidates into ordinary TDD production changes one at a time.

## Non-Goals

- Do not expose `BodyInferSessionSeed`, `InferSession`, or partial inference
  state.
- Do not add a public API for checking a fragment of an expression.
- Do not add dependency-injection callbacks or strategy flags to
  `InferContext` or `BodyCheckContext`.
- Do not redesign unification, constraint solving, or finalization in this
  issue.
- Do not add global inference caches.
- Do not time parsing, module loading, graph acceptance, body-context planning,
  output fingerprinting, JSON encoding, or result printing as inference.
- Do not use one synthetic syntax shape as evidence for a general optimization.
- Do not treat destructive mock results as predicted production speedups.
- Do not retain any counterfactual/mock patch in the production branch.

## Existing Boundaries And Files

The implementer should read these before editing:

- `blorp/src/compiler/stage_06_typecheck/decl.brp`
  - `BodyCheckContext`
  - `BodyCheckContextBuild`
  - `BodyCheckPlan`
  - `BodyCheckOutcome`
  - `accepted_typecheck_module_body_plan`
  - `accepted_typecheck_module_body_context`
  - `body_check_context_callable_id`
  - `check_body_context`
  - `body_check_outcome_callable_id`
  - `body_check_outcome_typed_function`
  - `body_check_outcome_errors`
  - `body_check_outcome_diagnostics`
- `blorp/src/compiler/stage_06_typecheck/infer.brp`
  - `infer_expr`
  - `finalize_infer_result`
- `compiler/benchmarks/compiler_typecheck_phase_profile.brp`
- `compiler/benchmarks/compiler_typecheck_phase_profile_fixture.brp`
- `compiler/benchmarks/compiler_typecheck_name_lookup_profile.brp`
- `std/instrumentation.brp`
- `compiler/lib/runtime.c`
- `compiler/lib/runtime_decl.c`
- `tests/test_cli.sh`
- `blorp/test/compiler/compiler_test_ownership.json`
- `benchmarks/README.md`

The existing phase profile remains authoritative for the wider accepted-module
body stage. This issue adds a narrower benchmark because that profile cannot
exclude accepted-module and body-planning work.

## Required Semantic Boundary

### Input

The input to one measured operation is exactly one `BodyCheckContext`.

Do not create this:

```blorp
record InferInput:
    context: BodyCheckContext
```

Do not copy fields out of the opaque context into a benchmark-owned record.
Doing either would weaken the guarantee that the benchmark calls the same
facade as production.

### Kernel

The measured operation is:

```blorp
check_body_context(context)
```

If the fixture uses the word `infer` to make the benchmark intent explicit, it
may define only this private benchmark-local alias:

```blorp
private pure func infer(context: BodyCheckContext) -> BodyCheckOutcome:
	check_body_context(context)
```

Do not add that alias to production source. It must not accumulate policy,
configuration, conditionals, or transformed inputs. Calling
`check_body_context` directly is also valid and should be preferred if the
alias does not improve the generated function profile.

### Output

The output is exactly `BodyCheckOutcome`:

```text
BodyCheckAccepted(CheckedBodyArtifact)
BodyCheckRejected(RecoveredBodyArtifact)
```

The timed code must retain complete outcomes. It must not reduce each outcome
to a callable ID, count, or Boolean while still in the timing window. Such a
reduction could allow code generation or the C optimizer to avoid work whose
result appears unused.

### Freshness Invariant

For any reusable context `c`:

```text
fingerprint(check_body_context(c))
    == fingerprint(check_body_context(c))
```

The equality must hold across:

- repeated calls;
- separate timed samples;
- source, reverse, and deterministic shuffled schedules; and
- execution after another context succeeds or fails.

A failing freshness test is a compiler correctness bug, not benchmark noise.

## Proposed File Layout

Add these files:

```text
compiler/benchmarks/compiler_infer_profile_fixture.brp
compiler/benchmarks/compiler_infer_profile.brp
blorp/test/compiler/test_compiler_infer_profile.brp
scripts/compiler-infer-profile
scripts/compiler-infer-profile-experiment
```

Record retained baseline and experiment evidence under:

```text
benchmarks/results/compiler_infer_profile_<YYYY-MM-DD>.md
benchmarks/results/compiler_infer_profile_<YYYY-MM-DD>.tsv
```

Update:

- `blorp/test/compiler/compiler_test_ownership.json`;
- `benchmarks/README.md`; and
- `docs/COMPILER_PRIORITIES.md`.

Do not put fixture generation, timing, result formatting, and experiment
worktree management in one source file. The fixture must be importable by the
focused compiler test without invoking timers or printing.

## Benchmark Data Model

Use explicit variants rather than strings or coupled Booleans.

The exact names can follow local naming conventions, but the model should have
this shape:

```blorp
enum CompilerInferProfileScale:
	InferProfileSmall
	InferProfileMedium
	InferProfileLarge


enum CompilerInferProfileFamily:
	InferTraversal
	InferLexicalScopes
	InferCalls
	InferGenerics
	InferTraitDispatch
	InferDataAndControlFlow
	InferClosuresResourcesAndConcurrency
	InferErrorRecovery


record CompilerInferProfileConfig {
	scale: CompilerInferProfileScale,
	family: CompilerInferProfileFamily,
	initial_repetitions: Int
}


opaque type CompilerInferProfileFixture = CompilerInferProfileFixtureRep


union CompilerInferProfileFixtureBuild:
	InferProfileFixtureReady(CompilerInferProfileFixture)
	InferProfileFixtureRejected(List[String])
```

The private fixture representation should contain at least:

- `contexts: List[BodyCheckContext]`;
- exact callable IDs in stable source order;
- expected accepted and rejected outcome counts;
- parsed expression/body-node count;
- named-family structural counters;
- fixture source fingerprint;
- context/callable-identity fingerprint; and
- enough accepted graph/module ownership to keep all referenced immutable facts
  alive for the fixture lifetime.

Do not represent fixture validity as a `Bool` beside a possibly invalid fixture.
Construction returns `InferProfileFixtureReady` only after all requested
contexts have been built and all structural expectations have been checked.

Use a positive repetition smart constructor or an `Option`-returning plan so
zero and negative repetition counts cannot enter execution.

The execution and observation products should remain distinct:

```blorp
opaque type CompilerInferProfileExecution = ...

union CompilerInferProfileRun:
	CompilerInferProfileCompleted(CompilerInferProfileObservation)
	CompilerInferProfileInvariantFailed(List[String])
```

`CompilerInferProfileExecution` owns retained outcomes. The observation step,
which runs after timing, computes fingerprints, counts, and invariant failures.
This prevents an execution with missing or discarded outcomes from masquerading
as a valid sample.

## Fixture Matrix

The benchmark must vary two independent axes: scale and semantic family.
“Small, medium, large” alone is not enough because equal node counts can stress
very different inference paths.

### Scale Definitions

Define scale with deterministic structural work, not source line count or a
target elapsed time.

Initial targets:

| Scale | Body target | Parsed body-node target | Purpose |
| --- | ---: | ---: | --- |
| Small | 16 | 300-500 | startup/editor-like latency and harness tests |
| Medium | 128 | 5,000-8,000 | routine optimization feedback |
| Large | 512 | 40,000-60,000 | asymptotic behavior and native sampling |

The fixture builder must report actual counts. If syntax generation changes,
update the named expected counts deliberately. Do not silently classify a
fixture by whatever count it happens to produce.

Calibration changes the number of whole-matrix repetitions. It must never
change the number, depth, or semantics of bodies in a named scale.

### Semantic Families

Each family should have one deterministic source generator and explicit
structural counters.

#### 1. Traversal

Exercise expression-tree walking without expensive name or trait ambiguity:

- integer, Boolean, string, tuple, list, and record literals;
- wide arithmetic and logical expressions;
- deep but non-pathological nested expressions;
- `if`, `match`, and block expressions; and
- expected-type propagation through nested values.

Counters: expressions, maximum expression depth, branch arms, and literals.

#### 2. Lexical Scopes

Exercise environment and scope operations:

- parameters and local immutable bindings;
- explicit local `var` mutation;
- nested blocks and shadowing;
- hit and miss lookups where misses are semantically valid; and
- closures capturing immutable values.

Counters: declared names, lookup references, scope depth, shadowed names, and
captures.

#### 3. Calls

Exercise callable resolution without making trait dispatch the only cost:

- direct monomorphic calls;
- overload candidate sets of controlled width;
- higher-order parameters;
- typed lambdas and context-inferred lambdas;
- default and named arguments if supported at the body boundary; and
- calls whose expected return type disambiguates resolution.

Counters: call sites, overload candidates considered by construction,
callbacks, and inferred lambda parameters.

#### 4. Generics

Exercise metas, substitution, bounds, and dimensions:

- generic identity and container helpers;
- nested generic records and unions;
- generic callbacks;
- bounded type parameters;
- generic calls requiring inference from multiple arguments; and
- representative static dimension/range constraints.

Counters: type parameters, generic call sites, nested semantic-type nodes,
dimension constraints, and expected meta-producing sites.

#### 5. Trait And UFCS Dispatch

Exercise semantic method resolution:

- direct trait calls;
- UFCS calls;
- multiple imported implementations with an unambiguous winner;
- default trait methods;
- generic trait bounds; and
- operator syntax resolved through traits.

Counters: trait call sites, UFCS sites, available implementations, selected
defaults, and bound checks.

#### 6. Data And Control Flow

Exercise expected types and exhaustiveness-related body work:

- record construction and update;
- unions with managed and unboxed payloads;
- nested `Option` and `Result` matches;
- collections with inferred element types;
- loop bodies and break values where legal; and
- branch joins requiring type reconciliation.

Counters: constructions, updates, match arms, patterns, collection elements,
and joins.

#### 7. Closures, Resources, And Concurrency

Exercise the rules that require additional semantic validation:

- immutable closure captures;
- pure and impure callbacks;
- resource `with` scopes;
- resource method calls;
- `concurrent:` result bindings;
- channels and cancellation-point calls; and
- legal nested control flow that cannot let scoped resources escape.

Counters: closures, captures, resources, concurrent tasks, channel operations,
and cancellation points.

#### 8. Error Recovery

Keep rejected bodies separate from accepted workloads so diagnostic recovery
cost cannot distort normal-path claims.

Cover deterministic examples of:

- unknown names;
- type mismatch;
- ambiguous call or trait selection;
- invalid resource escape;
- purity violation;
- non-exhaustive match; and
- invalid main signature where the context policy applies.

Counters: expected errors, expected diagnostics, recovered typed bodies, and
source spans. The fixture must assert exact normalized diagnostic identity, not
only the number of errors.

### Required Control Pairs

At minimum, add these pairs so a measured effect can be interpreted:

- many small bodies versus one large body at comparable total node count;
- accepted versus rejected bodies at comparable node count;
- monomorphic versus generic bodies;
- direct calls versus trait/UFCS calls; and
- resource-free versus resource-heavy bodies.

The regular benchmark matrix may use one family per run. A separate aggregate
“representative” invocation should use documented fixed weights and must not
change those weights automatically based on timing.

## Fixture Construction Pipeline

All setup occurs before warmup or timing. Use the production Phase 1-6 APIs.

For each requested scale/family:

1. Generate deterministic target and dependency module source.
2. Parse the sources through the production parser bridge.
3. Build indexed, importable, bound, skeleton, alias, resolved-parameter,
   type-header, trait-topology, callable-header, implementation-header, and
   accepted graph products through their production constructors.
4. Construct the target `AcceptedTypecheckModule` once.
5. Call `accepted_typecheck_module_body_plan` once.
6. Retain contexts from `BodyCheckPlanReady` and require its recoverable
   implementation-rejection list to match the fixture expectation. Reject the
   fixture with the exact structural failures from `BodyCheckPlanRejected`.
7. Verify exact context count, exact callable identities, stable source order,
   expected accepted/rejected counts, and family-specific structural counters.
8. Store only complete `BodyCheckContext` values and immutable fixture facts.
9. Compute and retain the input fingerprint before any warmup.

Do not call `accepted_typecheck_module_body_plan` in the timed loop. Context
planning includes graph/header work and is measured by the broader phase
profile.

Do not manually construct a `BodyCheckContext`; its opacity is part of the
correctness contract.

## Timed Execution Contract

One timed repetition does this and only this:

```blorp
contexts.map(check_body_context)
```

An explicit loop is acceptable if it produces the same retained
`List[BodyCheckOutcome]`. Do not repeatedly append to a list if the standard
library's `map` expresses the exact operation and avoids avoidable list-copy
noise.

For multiple repetitions, retain every repetition's observations until the
window ends, or retain a representation that still forces every complete
outcome to be produced. Do not compute a checksum inside the timed loop merely
to reduce memory. If retaining all large results changes the production
question materially, record per-repetition wall time and let each sample own
one complete result list rather than batching many repetitions in one window.

Recommended sequence for one sample:

1. Obtain an already-built fixture.
2. Begin wall-clock timing.
3. Begin the function profile window when running an instrumented sample.
4. Call `check_body_context` for every context.
5. End the function profile window.
6. End wall-clock timing.
7. Compute the output fingerprint and invariants.
8. Release outcomes before the next sample.

Function-profile and uninstrumented timing runs are separate. Do not publish
instrumented wall time as representative compiler latency.

## Result Consumption And Fingerprints

The benchmark must prove that it consumed semantically complete output without
serializing it inside the timed window.

Add the narrowest pure fingerprint helper required by the fixture. Prefer a
benchmark-local recursive structural fingerprint built from existing public
typed AST fields. If opacity prevents complete observation, add one production
query beside the opaque artifact implementation:

```blorp
pure func body_check_outcome_fingerprint(outcome: BodyCheckOutcome) -> Int
```

Only add this query if it represents a generally useful identity/equality
contract for a complete body outcome. Do not add broad artifact accessors for
the benchmark. The fingerprint must include:

- exact callable identity, including module and definition identity;
- accepted versus rejected variant;
- typed function declaration and body structure;
- semantic parameter and return types;
- inferred callable identities at call sites where represented;
- error text;
- diagnostic kind/message and source span; and
- the presence or absence of a typed body.

The fingerprint is not cryptographic. It must be deterministic, order-aware
where source order is semantic, and sensitive enough for the focused tests to
show that changing a literal, callable identity, semantic type, error, or span
changes the result.

Before and after each sample, compare the fixture input fingerprint. A change
means the supposedly reusable input was mutated or reconstructed incorrectly
and invalidates the measurement.

## Calibration And Sampling Policy

Follow the calibrated structure in
`compiler/benchmarks/compiler_typecheck_name_lookup_profile.brp`, with these
inference-specific
rules:

- release build for wall-clock evidence;
- `BLORP_NUM_WORKERS=1` unless concurrency itself is the named experiment;
- one unmeasured warmup after fixture construction;
- double repetitions until the uninstrumented sample reaches at least 50 ms;
- cap calibration with a named constant and report cap exhaustion;
- seven measured samples for routine local evidence;
- report every raw sample, median, minimum, maximum, and median absolute
  deviation;
- run baseline and candidate in alternating order for production comparisons;
- use the same bootstrap compiler, generated-C compiler, flags, environment,
  fixture fingerprint, and worker count; and
- reject comparison when output fingerprints differ for a
  semantics-preserving candidate.

Do not automatically subtract harness overhead. Add a control kernel that walks
the same context list and observes `body_check_context_callable_id` without
checking bodies. Report this separately. It indicates when the fixture is too
small, but subtraction is valid only if a later analysis explicitly justifies
it.

## Required Observation Schema

Emit one stable, machine-readable line per sample in TSV or JSON form and a
compact human-readable summary. Include:

### Reproducibility

- Git revision;
- dirty-worktree status;
- bootstrap/compiler binary hash;
- generated-C compiler identity and flags;
- platform and architecture;
- worker count;
- profile mode: uninstrumented, exact, or native sample;
- fixture source fingerprint; and
- context identity fingerprint.

### Workload

- scale;
- semantic family;
- repetitions;
- body count;
- accepted and rejected body counts;
- parsed body-node count;
- typed body-node count after observation;
- maximum expression depth; and
- all family-specific structural counters.

### Timing

- setup microseconds, reported separately;
- warmup microseconds, reported separately;
- control-kernel microseconds;
- raw inference sample microseconds;
- median, minimum, maximum, and median absolute deviation; and
- per-body and per-node derived rates.

### Correctness

- output fingerprint;
- accepted/rejected counts;
- error and diagnostic counts;
- pre/post input fingerprints;
- workload-valid status; and
- all invariant-failure messages.

Where the existing memory instrumentation can isolate it without changing the
kernel, also report allocations, releases, current retained bytes, peak bytes,
and process peak RSS. Keep unavailable values explicit rather than printing
zero as though zero had been observed.

## Exclusive/Self-Time Profiler Slice

The current function profiler records only inclusive time. Nested and recursive
calls overlap, so summing inclusive time produces a misleading total and
percentage. Exact profiling is not adequate for ranking leaf work until it can
also report self time.

Implement this as an independently reviewable runtime slice before using exact
profile percentages for candidate selection.

### Runtime Representation

Extend the profile entry and frame conceptually as follows:

```c
typedef struct blorp_ProfileEntry {
    const char* name;
    atomic_long inclusive_ns;
    atomic_long self_ns;
    atomic_long call_count;
} blorp_ProfileEntry;

typedef struct blorp_ProfileFrame {
    blorp_ProfileEntry* entry;
    long start_ns;
    long child_ns;
} blorp_ProfileFrame;
```

On a normally matched profile end:

1. calculate `inclusive = max(0, end - start)`;
2. calculate `self = max(0, inclusive - child_ns)`;
3. add `inclusive` and `self` to the ended entry;
4. add `inclusive` to the immediate surviving parent frame's `child_ns`; and
5. increment the ended entry's call count.

Recursion is valid: each recursive invocation owns its own frame and contributes
its inclusive elapsed time to its immediate parent invocation.

The existing tolerant name-matching behavior can find a non-top frame after a
non-local exit skipped one or more inner profile-end probes. Make that behavior
explicit: discard the abandoned inner frames without incrementing their entry
counters, subtract the interval from the matched frame's immediate child's
start to the common end timestamp from the matched frame's self time, remove
the matched frame and all frames above it, and add only the matched frame's
inclusive interval to its surviving parent. This avoids double-counting nested
abandoned intervals while ensuring the matched frame cannot claim abandoned
child execution as self time. Add a focused synthetic test for this unwind
case; do not rely on it occurring nondeterministically through cancellation.

### Window And Thread Invariants

- Beginning a window resets inclusive time, self time, and call counts.
- Epoch changes invalidate thread-local frames from the previous window.
- A call crossing a window boundary contributes to neither window unless the
  existing documented window semantics deliberately state otherwise.
- Ending the window waits for in-flight end commits before snapshotting.
- Every snapshot satisfies `0 <= self_ns <= inclusive_ns`.
- The sum of self time is used for the percentage denominator.
- The report retains inclusive time because it remains useful for call-tree
  envelopes.
- The profiler report labels both columns unambiguously.

### Profiler Tests

Extend the existing CLI profile-window fixture or add a focused runtime fixture
covering:

- one leaf call: inclusive approximately equals self;
- one parent with a child: parent inclusive exceeds parent self;
- two nested children: parent self excludes both;
- direct recursion: each call is counted and self never exceeds inclusive;
- begin/end window crossing behavior;
- counter reset between windows;
- concurrent profiled calls from multiple scheduler workers; and
- signal delivery after window end remains intact.

Timing assertions must use inequalities/invariants, not narrow elapsed-time
tolerances. Validate report headers and parseable columns in `tests/test_cli.sh`.

## Native Sampling

Exact probes add overhead to every function entry and exit. High-call-count
functions may look different under instrumentation. For every large workload
used to rank a candidate, collect a complementary optimized native sample:

- macOS: `sample` or Instruments Time Profiler;
- Linux: `perf record`/`perf report`; and
- preserve symbols and the exact optimized binary used.

Use native samples to validate broad call-stack attribution, not exact call
counts. A candidate is stronger when uninstrumented wall time, exact self time,
and native samples all point to the same subsystem.

## Counterfactual Experiment Driver

The purpose of counterfactuals is to estimate how much total time a region
could possibly save. They are not production implementations.

Add `scripts/compiler-infer-profile-experiment` with this lifecycle:

1. Require a named experiment manifest and a clean base revision.
2. Acquire the repository's normal build/benchmark contention lease.
3. Create a detached temporary worktree at the exact base revision.
4. Verify the pinned bootstrap/compiler configuration.
5. Apply one checked-in experiment patch from an explicit path or generate one
   from an exact, revision-bound patch definition.
6. Build the benchmark binary.
7. Run the same fixture matrix and sampling policy as baseline.
8. Capture stdout, stderr, exit status, fixture/output fingerprints, raw timing,
   and environment metadata.
9. Classify the experiment as semantics-preserving or destructive.
10. Remove the temporary worktree even after failure.

Do not edit and then revert the developer's active worktree. Do not use source
function-name search-and-replace as a patch mechanism. A patch must fail closed
when its expected source context no longer matches.

Retain the experiment manifest, exact patch, and measured result when the data
is referenced in an optimization decision. The mock implementation itself
never enters production history.

### Counterfactual Classes

#### A. Semantics-Preserving On A Constrained Fixture

These experiments may be compared by wall time only when the fixture proves
the simplifying precondition and the output fingerprint is unchanged.

Examples:

- make `type_contains_meta` constant false only on a fixture that contains no
  meta-producing syntax;
- make meta resolution an identity only on a fixture proved meta-free;
- make final zonking an identity on a monomorphic, meta-free fixture;
- make resource scanning constant false on a resource-free fixture; and
- make generic type instantiation an identity on a non-generic fixture.

The fixture proof must be a structural assertion or instrumentation counter,
not an assumption based on the generated function names.

#### B. Destructive Knockout

These experiments deliberately change results and only estimate an Amdahl-style
upper bound:

- replace broad trait/UFCS resolution with a preselected result;
- skip semantic validation;
- skip diagnostic localization;
- skip finalization; or
- replace a complete recursive subsystem with fixture-owned precomputed output.

Label these results `destructive_upper_bound`. Never require matching output
fingerprints, never describe the delta as an expected speedup, and never use a
destructive knockout alone to justify production complexity.

### Initial Experiment Clusters

Probe broad clusters before leaf helpers:

1. final recursive zonking;
2. meta detection and resolution;
3. environment/name/scope lookup;
4. generic substitution and binding;
5. trait, UFCS, and overload resolution;
6. resource-capability traversal;
7. diagnostic source-span localization on rejected bodies; and
8. repeated typed-AST validation walks.

Within a cluster, use the exact self-time profile to choose the next narrower
knockout. Stop splitting a cluster when its upper bound is too small to clear
the production threshold.

## Candidate Ranking

Rank candidates with recorded factors, not intuition alone:

```text
expected value =
    exclusive time share
    * realistically removable fraction
    * representative workload coverage
    * evidence confidence
    / implementation cost and correctness risk
```

Do not turn this expression into a spurious precise score. Record the inputs
and use it to explain ordering.

A production candidate should normally satisfy all of these:

- at least a 5% median improvement on medium or large representative workloads,
  or a compelling measured whole-compiler impact;
- no material small/editor workload regression (treat more than 2% as a reason
  to investigate, not automatic noise);
- identical output and fixture fingerprints;
- benefit in more than one semantic family unless the target family is itself
  an important compiler workload;
- corroboration from self-time or native samples;
- no new invalid state, partial type, cache-coherence obligation, or hidden
  phase coupling; and
- a maintainability story stronger than the code it replaces.

Leaf helpers whose full destructive upper bound is below the threshold should
not be optimized merely because they have high call counts.

## Ordered Implementation Plan

Each numbered section is a mergeable checkpoint. Do not combine the first
harness implementation with a production inference optimization.

### 1. Characterize The Existing Body Context Contract

Add failing tests first for:

- one prepared context can be checked repeatedly;
- repeated outcomes have the same complete fingerprint;
- accepted and rejected contexts do not contaminate one another;
- source, reverse, and deterministic shuffled context order produce the same
  per-identity outcomes;
- `accepted_typecheck_module_body_context` rejects unknown and foreign exact
  identities; and
- checking contexts does not change their input fingerprint.

Reuse Phase 6 fixtures where possible. Add new assertions rather than another
parallel body-context builder.

Checkpoint proof:

```bash
./blorp test blorp/test/compiler/stage_06_typecheck/test_typecheck_decl.brp
./blorp test blorp/test/compiler/stage_06_typecheck/test_typecheck_phase_profile.brp
```

### 2. Implement The Pure Fixture And Execution Boundary

Create `compiler_infer_profile_fixture.brp` with:

- scale/family enums;
- validated configuration and plan constructors;
- deterministic source generators;
- production graph/module/context setup;
- opaque ready fixture;
- direct `BodyCheckContext` execution;
- retained `BodyCheckOutcome` execution product;
- post-execution observation/fingerprinting; and
- explicit invariant failures.

Start with small traversal, lexical, generic, and error-recovery fixtures. Add
the other families only after the common construction/execution model is
covered. Do not make invalid placeholders legal to simplify incremental work.

Checkpoint proof is the new focused TestSuite with no timer dependency.

### 3. Add The Benchmark CLI And Sampling

Create `compiler_infer_profile.brp` and `scripts/compiler-infer-profile`.

The CLI must:

- parse scale and family into explicit enums;
- reject unknown or non-positive controls;
- construct setup once;
- warm up once;
- calibrate whole repetitions;
- collect seven uninstrumented samples;
- run the separate control kernel;
- observe results outside timing; and
- emit stable machine-readable records plus a concise summary.

Do not infer workload validity from process exit alone. Invalid fingerprints,
counts, or fixture mutation must produce a nonzero exit with exact errors.

### 4. Complete The Workload Matrix

Add every family, scale, control pair, and structural counter listed above.
Keep the focused compiler test bounded to small fixtures. Smoke medium fixtures
in the test only when execution time remains appropriate; validate large
fixtures through the benchmark script and retained baseline.

Checkpoint proof includes a checked-in baseline TSV/Markdown pair.

### 5. Add Exclusive/Self-Time Profiling

Implement and test the runtime changes above. Update report parsing and
documentation. Run the inference matrix once with exact profiling and retain
the raw report.

This slice is complete only when nested and recursive tests establish the
self-time accounting invariants.

### 6. Capture The Baseline Attribution Matrix

For every medium family and the representative large aggregate:

- collect uninstrumented samples;
- collect exact inclusive/self time and calls;
- collect an optimized native sample;
- record memory counters where available; and
- identify broad clusters, without yet proposing code changes.

Document any disagreement between measurement modes.

### 7. Implement Disposable Counterfactual Experiments

Add the worktree driver and one revision-bound experiment manifest. Prove that:

- the active worktree is unchanged;
- failed patches fail closed;
- cleanup runs after build or benchmark failure;
- semantics-preserving experiments require matching fingerprints; and
- destructive experiments are labeled as upper bounds.

Run the initial cluster matrix and retain raw results.

### 8. Produce A Ranked Optimization Backlog

For each viable cluster, record:

- representative exclusive share;
- native-sample corroboration;
- counterfactual upper bound;
- realistically removable fraction;
- affected semantic families;
- allocation/memory effect;
- likely implementation shape;
- phase/invariant risks;
- expected tests; and
- reason to proceed, defer, or reject.

Prefer changes that remove complete traversals, repeated reconstruction, or
linear work from common paths. Do not prioritize a helper merely because it has
a dramatic call count.

### 9. Implement One Production Optimization Separately

Choose the highest-confidence candidate. Start a separate change with a failing
semantic or performance characterization test. Remove the counterfactual patch
and implement the real invariant-preserving design.

Validate both:

- the isolated inference matrix; and
- representative end-to-end compiler checks.

A microbenchmark improvement that does not survive end-to-end compilation is
not a successful compiler optimization.

## Focused Test Requirements

Add `blorp/test/compiler/test_compiler_infer_profile.brp` and register it under
the typecheck stage. It should cover:

- valid config construction and invalid repetition rejection;
- exact small-fixture body and node counts;
- all requested contexts are `BodyContextReady`;
- contexts are reused rather than reconstructed per execution;
- two executions produce identical fingerprints;
- source/reverse/shuffled schedules match by exact callable identity;
- accepted and rejected outcomes fingerprint differently;
- changing a literal changes the output fingerprint;
- changing a source span changes the diagnostic fingerprint;
- fixture input fingerprint is stable before and after execution;
- execution retains one complete outcome per context per repetition;
- observation rejects missing, duplicate, or foreign outcomes;
- timing/setup APIs are absent from the pure fixture module; and
- each semantic family reports nonzero values for its defining counters.

Tests should inspect exact error text for fixture-construction and invariant
failures.

## Validation Commands

Use a fast loop while implementing:

```bash
make
./blorp test blorp/test/compiler/test_compiler_infer_profile.brp
scripts/compiler-check --stage typecheck
```

Before completing the harness:

```bash
make
make fmt-check
scripts/test compiler-blorp
scripts/test compiler-blorp-sanitize
scripts/test runtime
scripts/test leak
scripts/test cli
make quality
git diff --check
```

Run and retain the baseline with an explicit clean revision and environment:

```bash
BLORP_NUM_WORKERS=1 scripts/compiler-infer-profile --matrix
BLORP_NUM_WORKERS=1 scripts/compiler-infer-profile --matrix --profile exact
BLORP_NUM_WORKERS=1 scripts/compiler-infer-profile --scale large \
  --family representative --profile native
```

The exact command syntax may follow established repository script conventions,
but the three modes and their metadata must remain distinct.

## Review Requirements

Request independent review of:

1. whether setup can enter the timed window;
2. whether every outcome is forced and retained;
3. whether `BodyCheckContext` freshness is genuinely preserved;
4. whether fixture families represent their claimed semantic pressure;
5. whether self-time accounting is correct under nesting, recursion, windows,
   and multiple workers;
6. whether counterfactual patches can affect the active worktree;
7. whether destructive results are clearly separated from
   semantics-preserving evidence; and
8. whether the first proposed optimization preserves phase boundaries and
   makes illegal states unrepresentable.

The reviewer should reject the work if the harness introduces a second
inference context model, times setup, fingerprints only IDs/counts, or leaves a
production mock switch behind.

## Definition Of Done

- [ ] `BodyCheckContext` is the direct and only measured input; no `InferInput`
      exists.
- [ ] `check_body_context` is the production kernel used by the benchmark.
- [ ] Context construction, graph setup, warmup, and observation are outside
      the timed window.
- [ ] Complete `BodyCheckOutcome` values are retained through each timed
      sample.
- [ ] Small, medium, and large workloads have fixed structural definitions.
- [ ] All eight semantic families and required control pairs are represented.
- [ ] Fixture and output fingerprints detect identity, typed-body, error, and
      diagnostic changes.
- [ ] Repeated and reordered checks prove fresh-session determinism.
- [ ] Raw sample metadata and structural counters are retained under
      `benchmarks/results/`.
- [ ] Function profiles report both inclusive and exclusive/self time with
      nesting, recursion, window, and multi-worker tests.
- [ ] Optimized native samples corroborate the broad attribution.
- [ ] Disposable counterfactual experiments cannot modify the active worktree
      or survive into production.
- [ ] At least one semantics-preserving and one explicitly destructive cluster
      experiment demonstrate the classification rules.
- [ ] A ranked optimization backlog cites wall time, self time, native samples,
      output parity, workload coverage, and correctness risk.
- [ ] Any production optimization begins as a separate TDD change and is
      verified against both the isolated harness and end-to-end compiler.

## Handoff Checklist

- [ ] Read the Phase 6 implementation status and current body-context APIs.
- [ ] Confirm the branch's exact bootstrap/compiler configuration.
- [ ] Write freshness and fingerprint tests before fixture implementation.
- [ ] Implement the small pure fixture using `BodyCheckContext` directly.
- [ ] Get fixture architecture reviewed before adding workload breadth.
- [ ] Add calibrated uninstrumented timing and the control kernel.
- [ ] Complete semantic families and scales.
- [ ] Add and independently review self-time profiler accounting.
- [ ] Record the first complete baseline matrix.
- [ ] Add the disposable experiment driver and cleanup tests.
- [ ] Run broad cluster counterfactuals.
- [ ] Publish the evidence-backed candidate backlog.
- [ ] Open the first production optimization as a separate change.
