# Compiler Roadmap

Status: active, reviewed 2026-07-29.

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

The migration remains the first architectural priority. It removes duplicated
implementations, JSON/process boundaries, and the need to reason about two
ownership models while changing the compiler.

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

The current boundary, remaining OCaml inventory, exact checkpoints, tests, and
deletion conditions live only in
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
