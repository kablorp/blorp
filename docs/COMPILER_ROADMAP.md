# Compiler Roadmap

Status: active, reviewed 2026-08-13.

This document contains current compiler priorities only. It is not an
implementation diary. Completed experiments and superseded plans belong in Git
history, benchmark result files, issues, or pull requests.

Use:

- [ARCHITECTURE.md](ARCHITECTURE.md) for the production pipeline and ownership
  of each stage;
- [OWNERSHIP_MODEL.md](OWNERSHIP_MODEL.md) for the compiler/runtime ownership
  ABI;
- [MEMORY_MODEL.md](MEMORY_MODEL.md) for user-facing value semantics; and
- [BLORP_COMPILER_PORT_ROADMAP.md](BLORP_COMPILER_PORT_ROADMAP.md) for the
  detailed OCaml-to-Blorp migration sequence and deletion points.

## Outcomes

The compiler work should produce four outcomes:

1. Compiler semantics and tools move to one Blorp-owned production path.
2. Blorp programs become materially faster without changing source semantics.
3. Compilation and test feedback become faster by doing less duplicate work.
4. Semantic, ownership, representation, and native-boundary facts remain
   explicit and mechanically checked.

## Priority 1: Finish The OCaml-To-Blorp Migration

Status: complete. The production compiler, public tools, and deterministic
build-source generator are Blorp-owned. OCaml remains only in the frozen test
archive and optional cross-language benchmark inputs.

Rules:

- Move one contiguous production responsibility at a time.
- Delete the replaced OCaml implementation in the same change when its last
  production and test caller is gone.
- Do not add an optional Blorp path beside an authoritative OCaml path.
- Keep compilation typed and in-process; remaining command delegation must not
  reintroduce a Core boundary.
- Port tools only after the parser, typechecker, and compiler services they
  consume are Blorp-owned.
- Keep the immutable released bootstrap separate from the compiler being
  built.

The current boundary, exact checkpoints, tests, and deletion conditions live
only in
[BLORP_COMPILER_PORT_ROADMAP.md](BLORP_COMPILER_PORT_ROADMAP.md).

## Priority 2: Runtime Performance Without Surface Changes

Blorp's existing surface already provides strong optimization facts:
monomorphized generics, purity, immutable values, explicit local mutation,
structured concurrency, static tensor shapes, and ownership-aware Core. The
performance plan should exploit those facts rather than add user-visible
optimization syntax.

### Planning Targets

These are targets, not measured claims:

| Workload | Realistic improvement over the current compiler |
| --- | ---: |
| Broad mixed benchmark suite | 1.5-2x |
| Strong broad-suite stretch | 2-2.5x |
| Tight scalar and numeric loops | 1.05-1.3x |
| String and collection pipelines | 1.5-3x |
| Closure and higher-order-function-heavy code | 1.3-2.5x |
| Persistent records, trees, and AST rewrites | 2-5x |
| Pathological allocation or nonlinear work | 5x or more |
| Allocation-heavy peak memory | 30-70% lower |

Do not turn these ranges into release claims until the audited benchmark suite
has comparable before/after results.

### Measurement Contract

Before the first optimization slice:

1. Record release-mode baselines for the comparable rows in
   `benchmarks/bench.sh`, including `compiler_ast`, `compiler_symbols`, and
   `compiler_emit`.
2. Use at least five timed runs after warmup for latency decisions.
3. Record output checksums, allocation/release counts where available, peak
   memory for allocation-heavy rows, generated-C size, compiler revision,
   target, C compiler, and relevant thread settings.
4. Store durable raw measurements under `benchmarks/results/`.
5. Compare one optimization at a time. Do not attribute a combined result to
   several unmeasured changes.

The broad planning target is a 1.7x mixed-suite improvement with 40-60% fewer
allocations in allocation-heavy programs. A measured 2x broad-suite
improvement is a strong result. Larger wins should be described as
workload-specific.

### Workstream A: Ownership-Aware Reuse

This is the highest-value first target for compiler-shaped programs.

The detailed cleanup and sequencing plan for the Perceus ownership pass lives
in [PERCEUS_CLEANUP_ROADMAP.md](PERCEUS_CLEANUP_ROADMAP.md).

Current foundations:

- Perceus inserts explicit `CDup` and `CDrop`.
- Read-only parameters borrow rather than retaining on entry.
- COW-consuming operations use explicit ownership contracts.
- The reuse pass can consume proven drops and upgrade narrow list, dict, set,
  and producer-handoff allocations.

Next steps:

1. Move legacy global-reference repair out of Perceus and into
   `compiler_core_resolve`.
2. Carry exact per-body and per-lambda global-reference facts so ownership
   scans visit only referenced values.
3. Re-profile call-contract annotation, borrowed-call protection,
   aggregate/result retention, summaries, drops, consumed-value balancing,
   and nested-lambda normalization. Consolidate a traversal only when measured
   evidence shows it is material.
4. Make managed allocation sites explicit before reuse analysis.
5. Specialize calls where an owned argument is dead immediately after the
   call.
6. Add owned match and field-move semantics when the source owner is dead.
7. Reuse compatible record and union storage when type, layout, liveness, and
   destructor facts are explicit.
8. Broaden collection handoffs only when Core can state read/write order,
   element ownership, capacity, and fallback behavior.

Public borrow-preserving operations must not secretly consume their receivers.
Reuse is an internal optimization guarded by compile-time liveness and runtime
uniqueness.

### Workstream B: Escape Analysis And Scalar Replacement

Heap allocation remains conservative: non-self record updates generally
construct fresh records, captured closures allocate, and vectors are
heap-backed. Canonical uniquely owned heap-record self-replacements can already
reuse their allocation. Post-Perceus reuse also eliminates a same-type fresh
record when its source is dropped immediately after field evaluation, covering
dead intermediates in chained updates without escape analysis.

Implement escape facts for:

- nonescaping records, unions, tuples, and closures;
- short-lived aggregate temporaries;
- captured values whose closure does not escape;
- fixed-shape tensor/vector temporaries; and
- aggregate values immediately destructured by a match or field read.

Use those facts to stack-allocate, scalar-replace, or eliminate values. Keep
resource values, task captures, foreign-visible values, recursive storage, and
unknown closure escapes as barriers.

### Workstream C: Inlining And Closure Devirtualization

Monomorphization already supplies concrete function bodies, but ordinary std
inlining is narrow and first-class calls often retain the general closure ABI.

Add:

1. direct-call conversion for statically known closure targets;
2. cost-based inlining for small monomorphic pure functions;
3. specialization of callback-heavy collection operations; and
4. post-inline cleanup so C receives simple loops and scalar expressions.

Inlining should be budgeted by generated-C growth. Compile time and artifact
size are acceptance metrics, not afterthoughts.

### Workstream D: Pipeline And Loop Optimization

Extend the existing string, collection, tensor, and tuple optimization passes
instead of adding a second optimizer.

Targets:

- fuse common `map`/`filter`/`filter_map`/`fold`/`zip` combinations;
- remove intermediate strings and builder copies;
- eliminate proven bounds checks and repeated length reads;
- hoist loop-invariant ownership and layout checks;
- expose vectorizable loops and static tensor kernels to C;
- add Float32/Float16 vector paths where target support justifies them; and
- avoid fairness work in loops that cannot participate in concurrent
  scheduling, while preserving structured-concurrency semantics.

Each fusion must preserve callback count, callback order, error behavior,
resource cleanup, and source-level ownership.

### Workstream E: Representation And Runtime

Continue representation work only when it removes measured traffic:

- inline concrete values across currently erased storage boundaries;
- compact eligible scalar union payloads;
- avoid boxes for concrete generic values;
- improve fixed-shape vector/tensor storage;
- use thread-local or non-atomic ownership operations only when escape facts
  prove that an object cannot cross a concurrency boundary; and
- consider LTO or profile-guided native compilation after generated C is
  structurally sound.

Allocator tuning, larger freelists, or arenas are not the first lever. Prior
memory investigations found low fragmentation and excessive object creation;
reducing work and allocations had much larger impact than changing the
allocator.

### Evidence That Guides This Plan

Existing compiler workloads show the expected range:

- Removing an irrelevant-global whole-body multiplier made the bounded
  Perceus fixture about 86% faster and reduced peak RSS about 81%.
- Cached nominal containment summaries improved repeated deep-type probes by
  7.7-37.1%.
- Proven-empty resource scan preflights improved focused probes by 9.5-12.1%.
- Reusing already-typechecked CTFE artifacts reduced a measured compiler slice
  by 11.8% and peak RSS by 19.2%.

The lesson is consistent: ordinary local improvements are usually incremental,
while removing structural rebuilding, intermediate collections, and ownership
churn can produce multi-fold gains.

## Priority 3: Compilation And Test Feedback

Compiler and test performance must improve without hiding work behind stale
caches or weakening coverage.

The Blorp-owned, invocation-local `test` session is described in
[`ARCHITECTURE.md`](ARCHITECTURE.md#test-command-ownership). Its registered
performance workloads live in `scripts/bench-blorp-test-session`; this section
retains the cross-cutting performance policy.

Current direction:

The incremental plan to separate typechecking into indexed, module-binding,
header, body-inference, validation, and typed-graph phases is tracked in
[`TYPECHECKING_ROADMAP.md`](TYPECHECKING_ROADMAP.md). That plan includes the
measured work to replace repeated imported-declaration reconstruction with
definition-owned semantic headers.

1. Measure cold build, warm build, source check, compiler-owned suite compile,
   and default/deep gate times from a clean revision.
2. Use phase timings to identify graph construction, parsing, typechecking,
   Core stages, JSON/process boundaries, C emission, and native compilation.
3. Remove duplicate graph preparation, typechecking, serialization, and helper
   startup where one typed in-process value can cross the next phase.
4. Complete the compiler migration so large JSON bridge payloads and helper
   processes disappear rather than optimizing the bridge indefinitely.
5. Keep normal gates focused and keep expensive coverage explicit in
   deep/premerge gates.
6. Batch compiler-owned test suites only at semantic isolation boundaries, not
   arbitrary file-count thresholds.
7. Preserve visible cache keys, invalidation inputs, and uncached correctness
   paths.

When a profile identifies nonlinear symbol, type, or Core traversal, fix the
algorithm before tuning allocation. Function-body materialization, recursive
type-shape work, call lookup, and repeated immutable tree rebuilding deserve
focused scaling fixtures.

### Compiler Developer Experience

The supported workflow should make the shortest sound feedback loop obvious.
A developer should not need to understand test sharding, bootstrap helper
installation, temporary C paths, or Core JSON plumbing to investigate one
compiler change. Broad gates remain the integration proof; they are not the
first debugging tool.

#### Target workflow

Add one `scripts/compiler-check` entry point with three explicit modes:

```bash
scripts/compiler-check compiler/blorp/tests/test_compiler_type_header_graph.brp
scripts/compiler-check --stage typecheck
scripts/compiler-check --changed
```

- A file argument runs that suite with the current built compiler.
- `--stage` runs the registered suites and production-source checks owned by
  one compiler stage.
- `--changed` reads changed paths and resolves them through a checked-in
  source-to-suite ownership manifest. It must fail if a changed compiler source
  has no owner; it must not guess from filenames, imports, or historical timing.
- The command prepares or rebuilds the current compiler once, then uses the
  equivalent of `scripts/test --no-build` for all selected work.
- Success prints the selected scope and elapsed time. Failure prints the exact
  rerun command and retained artifact directory.
- This must be a thin planner over the existing `blorp test` and `scripts/test`
  execution paths, not another compiler or test runner.

Measure current timings before setting the enforced budget. The initial design
targets are a warm single-suite result within 15 seconds, a normal stage result
within 60 seconds, and an unchanged compiler readiness check within 5 seconds
on the reference development machine. If those targets are not initially
reachable, record the measured baseline and require each infrastructure slice
to improve or preserve it.

#### Explicit test ownership

Create one machine-checked manifest that assigns every production compiler
module to:

- its owning pipeline stage;
- one or more focused compiler suites;
- any required generated-C, sanitizer, leak, or end-to-end fixture; and
- the broader gate that owns final integration coverage.

The manifest should drive `--stage`, `--changed`, and CI shard inventory
validation. A source may name several required suites, but a suite must not be
copied into several independent manifests. `make quality` must reject unowned
production modules, missing suites, duplicate suite IDs, and references to
nonexistent paths.

#### Typed lint analyzer (initial report-only slice complete)

The Blorp-owned CLI now provides `blorp lint <paths>` as a report-only analyzer
over the existing source graph and `CompilerTypecheckedModule` values. Findings
have stable rule IDs, severities, source spans, deterministic human and
versioned JSON renderers, and optional CI failure through
`--fail-on-findings`. Parsing or typechecking errors suppress all findings for
the invocation.

The first rule set covers narrow structural declarations, callback-aware pure
functions without parameters, immediate `Option` parameter matching, typed
list lookups in loops, canonical list accumulators, and a closed-world
constant-parameter fixed point for private non-escaping functions. Repeatable
`--disable RULE_ID` options provide strict rule-specific suppression. Public
behavior and clean/finding fixtures are owned by `scripts/test compiler-tools`;
focused lint does not replace compiler integration gates. Rule contracts and
confidence levels are documented in [`LINT.md`](LINT.md).

#### Failure artifacts

Every compiler-check failure should retain one self-contained bundle under the
ignored `logs/` tree containing:

- the exact command, compiler revision, bootstrap revision, target, and
  relevant environment;
- complete stdout/stderr and structured diagnostics;
- phase timings and the last successfully completed phase;
- generated C and native compiler diagnostics when C compilation was reached;
- requested Core snapshots and invariant failures; and
- a short `rerun` command that reuses the same source and options without
  relying on the retained build artifact.

Passing runs should delete temporary artifacts. Console output should remain a
compact summary; the bundle is the durable debugging record. This behavior
should be shared by local checks and CI rather than implemented twice in shell
and workflow YAML. Extend the existing `scripts/test --log-dir` ownership model
rather than creating a second artifact lifecycle.

#### Focused compiler inspection

Build three filtered views on the existing stage-dump, timing, and ownership
infrastructure:

1. `--trace-definition=module::name` limits stage observations and Core dumps
   to the exact source definition family. Overloads must be resolved by stable
   definition ID rather than source order. Monomorphized instances, hoisted
   closures, and synthesized helpers remain linked to that source identity by
   an optional specialization key and generated-definition parent. When a name
   selects several source definitions, report their stable selectors instead
   of guessing; suffix or substring matching is not acceptable.
2. `--explain-type='module::Type[arguments]'` reports canonical identity,
   accepted header category, type parameters, alias expansion,
   managed/unmanaged storage, selected Core representation, and final C type
   for one concrete type expression in module context. If arguments are omitted
   from a generic declaration, report declaration-level facts and explicitly
   mark instantiated layout and C type as dependent on arguments rather than
   inventing one answer. Each row must identify the compiler phase that owns
   the fact.
3. `--dump-ownership=module::name` uses the same exact definition selector and
   projects the existing canonical ownership events for its selected instance,
   including argument/result contracts, `CDup` and `CDrop` paths, match-binding
   ownership, closure captures, and the pass that introduced each event.

Each view should have one structured internal result with text and JSON
renderers. Tests should assert the structured result; snapshotting large human
text dumps is secondary. These tools must query compiler facts rather than
reimplement name resolution or ownership classification for display. Pass
provenance should be collected by the debug observation pipeline from stage
snapshots; it must not add permanent provenance fields to production Core. The
trace-only lineage table should be keyed by source definition ID,
specialization key, and generated parent and should exist only when tracing is
enabled.

#### Phase contracts and errors

Make invalid intermediate states harder to construct:

- Give each major phase an opaque accepted input and output type where a
  meaningful invariant has been established, such as accepted type headers,
  typed module graphs, resolved Core, monomorphic Core, ownership-annotated
  Core, and backend-ready Core.
- Keep constructors at the validating phase boundary. Tests that need valid
  input should use shared builders that execute the real earlier boundary;
  tests of invalid input should target that boundary directly.
- Run inexpensive structural invariants whenever a phase completes. Reserve
  graph-wide or repeated deep checks for `--check-invariants`, sanitizer gates,
  and premerge coverage.
- Carry phase, module identity, and definition identity in internal compiler
  errors. An ICE must report the last accepted phase and the relevant Core or
  declaration path; callers should not reconstruct this context from strings.
- Remove older entry points once their callers use the accepted phase type.
  Do not preserve raw and validated routes for convenience.

The immediate phase-contract work is the accepted-header and Core
nominal-representation migrations documented in
[OWNERSHIP_MODEL.md](OWNERSHIP_MODEL.md).

#### Module cohesion

Large files should be split only around an owned compiler responsibility, not
at arbitrary line counts. A successful extraction must reduce the original
module's public imports or API surface and must not introduce cyclic imports or
a generic helper bucket. Prefer these boundaries:

- phase data and opaque accepted values;
- validation and diagnostic rendering;
- analysis/index construction;
- transformation;
- invariant checking; and
- backend projection.

Continue deleting single-use wrappers, copied values, and parallel legacy
implementations when the call site remains clearer. Keep a small helper when it
encodes a reused invariant, is a required callback, or gives a recursive
algorithm a coherent boundary; the function name alone is not sufficient
justification.

#### Delivery order

Implementation status (2026-08-13): items 1 and 2 are complete. Baselines are
recorded in
`benchmarks/results/compiler_developer_experience_baseline_2026-08-13.json`;
the versioned ownership manifest, strict quality validator, and focused
`scripts/compiler-check` workflow are active. The command retains exact-rerun
logs for its own failures, while the broader local/CI artifact unification in
item 3 remains open.

1. Measure the current single-suite, stage, unchanged-build, and failure-rerun
   loops and store the raw baseline under `benchmarks/results/`.
2. Add the source-to-suite ownership manifest and `scripts/compiler-check`
   without changing compiler semantics.
3. Unify retained local/CI failure artifacts and exact rerun reporting.
4. Establish trace-only source/specialization/generated-definition lineage and
   add filtered definition tracing. This first view may report identity and
   stage structure only; it must not expose transitional layout guesses.
5. Complete the accepted-header and Core type-representation migrations.
6. Add concrete type-layout explanation and ownership projection using the
   authoritative structured compiler facts established in the preceding step.
7. Use the resulting dependency and timing data to split oversized modules and
   delete superseded entry points, registrars, classifiers, and adapters.

This workstream is complete when a developer can select a changed compiler
module, receive a deterministic focused result and useful failure bundle from
one command, inspect one definition's type/Core/ownership history without
searching a full-program dump, and rely on the same phase invariants in unit
tests, local integration, and CI.

## Priority 4: Semantic And Boundary Cleanup

These remain active but should not grow separate roadmap files.

### Stable Call Identity

- Treat inference/typecheck as the source-level call resolver.
- Carry direct callable identity through typed metadata and Core.
- Keep closure and first-class calls explicit.
- Remove name-only and generated-name-suffix fallbacks once coverage proves
  that ordinary source calls carry definition identities.
- Make diagnostics and `purify` consume resolved facts rather than re-resolve
  names.

### Constants And CTFE

- Keep ordinary immutable top-level bindings as the only CTFE surface.
- Extend static emission for dicts, sets, tensors, inline-struct lists, and
  explicitly typed erased-boundary values.
- Keep unsupported constant evaluation as a compile error rather than a hidden
  runtime fallback.
- Move semantic normalization into typed CTFE IR instead of inspecting source
  spelling.

### Native Boundary

- Keep runtime ownership contracts and operation metadata exhaustive.
- Reject embedded NULs and invalid FFI metadata before C emission.
- Preserve generated-C escaping, identifier hygiene, sanitizer coverage, and
  platform-specific ABI tests.
- Keep security work in `make security-check`; do not mix a broader sandbox or
  package-trust design into compiler optimization work.

## Known Holes

- The project does not yet have a retained, current broad-suite geometric-mean
  runtime baseline. The performance ranges above are planning estimates until
  that baseline exists.
- `std/parser.brp` keeps `Span` fields flattened because nested record payloads
  previously corrupted values across generic closure/list boundaries. Do not
  restore nested cursors without a minimized compiler regression and ownership
  fix.
- The production typecheck command still returns rendered diagnostic strings
  at some tool boundaries. Structured source spans are required before doctest
  and LSP remapping can be fully Blorp-owned.
- Closure calls, loop/try/detach liveness, and structured-concurrency result
  handoff remain conservative ownership boundaries. General reuse or
  non-atomic RC must not cross them without explicit escape facts.
- Perceus still performs legacy global-reference repair internally. Resolution
  should own that fact, and ownership passes should consume exact per-body and
  per-lambda reference sets instead of rediscovering them.
- Compile and run now remain in one contiguous Blorp pipeline through C
  emission. Keep future optimization in that typed path rather than
  reintroducing a serialized Core boundary.

## Completed Foundations

The following are current architecture, not active roadmaps:

- Blorp-owned parsing, source-AST finalization, and module-surface extraction;
- the cursor/span parser API;
- focused late-Core ownership stabilization and sanitizer coverage;
- compact internal Boolean and explicit-enum field storage with foreign ABI
  preservation;
- the bounded irrelevant-global Perceus multiplier correction, while phase
  ownership of global-reference repair remains active work;
- explicit normal versus deep test gates and reusable typecheck sessions; and
- released immutable bootstrap toolchains with checksummed target artifacts.

Maintain their contracts in architecture, ownership, benchmark, and test
documentation. Do not recreate implementation diaries for them.

## Slice Acceptance

Every roadmap slice must:

1. State one behavioral invariant or measured bottleneck.
2. Add a failing regression first when behavior changes.
3. Preserve one authoritative production implementation.
4. Inspect generated Core or C for ownership, representation, or codegen work.
5. Record comparable before/after numbers for performance claims.
6. Pass focused tests, relevant sanitizer/leak gates, `make quality`, and
   `git diff --check`.
7. Update current reference documentation in the same change.

If a proposed optimization cannot meet those conditions, narrow it before
implementation.
