# Reduce Whole-Core Traversals And Superlinear Declaration Queries

**Status:** Ready for measurement-first implementation

## Issue Summary

Measure every production Core pass, remove any declaration lookup whose work is
superlinear in program size, then reduce redundant whole-program and
whole-expression traversals. Preserve exact Core stage semantics, diagnostics,
declaration order, ownership behavior, and generated C.

This issue is deliberately ordered:

1. instrument the real pipeline;
2. remove `O(nodes * declarations)` and `O(nodes * candidates)` work;
3. reuse phase facts only while their validity is explicit;
4. remove repeated validation walks;
5. avoid rebuilding unchanged trees; and
6. fuse traversals only when measurements and pass semantics prove it safe.

Do not begin by creating a generic pass manager or a universal visitor. The
first implementation commit must be measurement-only, and the first production
optimization must remove a measured superlinear path.

## Why This Is A High-Leverage Issue

The latest production-shaped self-compilation profile is
[`logs/compiler-self-profile-2026-08-26-aa269938/REPORT.md`](../../../logs/compiler-self-profile-2026-08-26-aa269938/REPORT.md).
It reports:

| Measurement | Result |
| --- | ---: |
| Frontend | 93.778 s |
| Backend | 33.168 s |
| Compiler total | 126.946 s |
| Stage 09 Core sample share | 34.68% |
| Stage 08 Core-lowering share | 9.63% |
| Stage 10 C-emission share | 3.25% |
| Allocations | 752.131 million |
| Generated C | 86.538 MB |

The Core stage is now much larger than C emission. Changing the output target
or optimizing string writing cannot address most of this cost.

The sampled profile identified repeated analysis and lookup callers:

| Caller | Sample share |
| --- | ---: |
| `type_policy.is_managed_type` | 2.21% |
| `closure.index_function` | 1.86% |
| `resolve.collect_call_resolve_env` | 1.84% |
| `closure.index_functions` | 1.83% |
| `match_projection.find_union_decl` | 1.47% |
| `mono_data.find_transparent_alias` | 1.34% |
| `perceus.summarize_linear_ownership_uses` | 1.11% |
| `reuse.find_union_decl` | 1.06% |
| `std_inline.find_target` | 1.02% |
| generic Core child mapping | about 0.83% directly attributed |
| immediate-child materialization | about 0.75% directly attributed |

Several narrow indexes have since landed, including closure indexing, managed
type membership, call-resolution environment construction, and direct
definition lookup. Their focused benchmarks prove those operations can be made
faster, but they do not establish how much current-main whole-Core work remains.
This issue therefore requires a new current-main baseline before selecting the
first production change.

## Verified Current Pipeline

The early pipeline in `blorp/src/compiler/stage_09_core/early_pipeline.brp` runs:

```text
lower
debug blocks
desugar
SSA / monomorphization
synthesis
match lowering
trait resolution
call resolution
std wrapper inlining
tail recursion lowering
string fusion
collection fusion
parallel tensor fusion
tensor update fusion
tuple SROA
```

The late pipeline in `blorp/src/compiler/stage_09_core/pipeline.brp` runs:

```text
function-reference adaptation
tensor specialization
ABI specialization
callable-ID resolution
backend-call projection
backend-match projection
DCE
consume specialization
record-update materialization
dict ownership preparation
Perceus ownership insertion
reuse
closure conversion
resource rewriting
cooperative checkpoint insertion
final Core preparation
prepared-union reuse
```

Many passes perform at least one of these operations:

- scan all declarations to build a local index;
- scan all expression roots for analysis;
- recursively rebuild every expression;
- scan declarations inside a recursive expression rewrite;
- validate the complete expression tree after a stage;
- rebuild a similar index that a previous pass just discarded.

Some repetition is required because declaration inventory and expression shape
change. The issue must make invalidation explicit instead of assuming one index
can remain correct through the whole pipeline.

## Known Repeated Validation Walks

`finish_stage` in `early_pipeline.brp` performs mandatory production invariant
checks even when `--check-invariants` is disabled:

- `check_resolve_invariants` after resolve;
- `check_resolve_invariants` plus `check_std_inline_invariants` after std inline;
- the same checks after tailrec; and
- the same checks after fusion.

With `--check-invariants`, additional complete stage-specific scans run after
most stages. Late Core keeps broad expression audits opt-in, but always performs
selected final ownership and definition-ID checks.

The production checks are correctness boundaries and must not simply be
deleted. The implementation must prove whether later stages can preserve a
validated property by construction, or consolidate multiple checks into one
complete traversal without changing failure behavior.

## Superlinear Work To Investigate First

The static call graph contains several functions that may scan declarations or
candidate lists from inside a query-heavy traversal:

- `match_projection.find_union_decl`;
- `reuse.find_union_decl`;
- `prepare.find_union_decl`;
- `mono_data.find_transparent_alias`;
- `std_inline.find_target`;
- any remaining constructor, function, global, trait, or alias lookup that
  loops over `program.decls` per expression/type query;
- any pass that repeatedly calls `immediate_core_expr_children` and appends to a
  growing pending list in a way that copies the pending prefix;
- any recursive analysis that concatenates growing lists of child results.

Do not assume every named function remains hot after recent changes. Slice 0
must count queries and candidates inspected on current main.

## Goals

1. Produce an exact per-pass inventory of declaration visits, expression-node
   visits, node reconstructions, index builds, and lookup candidates inspected.
2. Detect superlinear behavior independently along declaration count,
   expression-node count, function count, and lookup-density axes.
3. Replace measured nested linear declaration searches with phase-owned exact
   indexes.
4. Reuse declaration facts across adjacent passes only while a typed pipeline
   boundary proves they remain valid.
5. Consolidate redundant invariant walks while preserving fail-closed
   production behavior.
6. Avoid reconstructing unchanged expression trees where the pass can signal
   unchanged results without structural equality scans.
7. Fuse only compatible, measured-hot traversals whose ordering semantics are
   fully specified and tested.
8. Demonstrate improvement on current-main compiler self-compilation, not only
   synthetic pass repetition.

## Non-Goals

- Do not change Core semantics or pass order to make fusion easier.
- Do not parallelize Core functions in this issue.
- Do not introduce LLVM or change the C backend.
- Do not redesign Core identity.
- Do not cache facts through a pass that can invalidate them.
- Do not infer pass effects by function names.
- Do not add one permanent global index containing every possible fact.
- Do not combine fallible and infallible traversal APIs by discarding errors.
- Do not reimplement the already-completed C-symbol projection traversal fix.
- Do not retain a synthetic optimization that fails production self-compilation
  measurement.

## Slice 0: Build The Core Work Profiler

This slice must merge independently and must not change production Core output.

### New Benchmark Files

Create:

- `compiler/benchmarks/compiler_core_pipeline_work_profile_fixture.brp`;
- `compiler/benchmarks/compiler_core_pipeline_work_profile.brp`;
- `blorp/test/compiler/stage_09_core/test_core_pipeline_work_profile_benchmark.brp`;
- `benchmarks/compiler_core_pipeline_work_profile`; and
- a suite ownership entry in `blorp/test/compiler/compiler_test_ownership.json`.

Document the runner in `benchmarks/README.md`.

### Required Fixture Controls

The fixture must independently control:

- function count: `16, 64, 256, 1024`;
- expression nodes per function: `16, 64, 256`;
- union declaration count: `8, 32, 128, 512`;
- alias declaration count: `8, 32, 128, 512`;
- callable declaration count independent of function-body count;
- call density per function;
- union-match density per function;
- managed-type query density;
- unchanged-expression density;
- generated declaration density;
- duplicate-name pressure with distinct exact identities.

Use separate one-axis matrices. Do not increase functions, declarations, and
nodes together in the primary scaling series because that hides the responsible
dimension.

The fixture must include at least these program shapes:

- many declarations with tiny bodies;
- few declarations with deep bodies;
- many flat independent functions;
- call-heavy bodies;
- constructor-match-heavy bodies;
- alias-heavy types;
- a mostly unchanged program for rewrite-allocation measurement;
- a rewrite-dense control.

### Pass Modes

The runner must support the exact production entry point for each selected
pass or contiguous pipeline segment. At minimum:

```text
resolve
std_inline
match_projection
dce
consume_specialize
perceus
reuse_post_perceus
closure
resource
fairness
prepare
reuse_prepared
late_pipeline
full_core_pipeline
```

Add early passes only when they are present in the captured production Core
input or when a separate fixture can satisfy their required preconditions.
Never feed an arbitrary Core shape to a pass that assumes an earlier invariant.

### Required Work Counters

The observation schema must include:

```text
pass_name
pass_invocations
input_declarations
output_declarations
input_expression_roots
output_expression_roots
input_expression_nodes
output_expression_nodes
declaration_visits
expression_node_visits
expression_child_lists_materialized
expression_nodes_reconstructed
unchanged_nodes_returned
program_indexes_built
index_entries_built
declaration_lookup_queries
declaration_lookup_candidates_inspected
invariant_program_scans
invariant_expression_node_visits
workload_checksum
output_checksum
allocations
releases
retained_objects
allocator_bytes
elapsed_microseconds
```

It is acceptable to instrument only the first selected pass family in the
initial merge point, provided the schema and fixture permit later families to
be added without changing existing result meanings.

Counters must come from the exact production implementation. Do not preserve a
separate legacy traversal solely for benchmarking. A metrics-bearing private
result or a narrow diagnostic observation over the production builder is
preferred. Instrumentation must be disabled by default and must not add a
callback invocation to every Core node in normal compilation.

### Scaling Analysis

For each independent size axis calculate:

```text
doubling_ratio = metric(2N) / metric(N)
growth_exponent = log2(doubling_ratio)
normalized_work = metric(N) / input_expression_nodes
```

Classify a path as superlinear when deterministic work counters exceed a 2.20
doubling ratio for two consecutive doublings while only one size axis changes.
Elapsed time and allocations are supporting evidence; they are not sufficient
without deterministic work counts.

Expected signatures:

- one full traversal: node visits grow about 2x when nodes double;
- `find_union_decl` for every match: candidates may grow about 4x when both
  union count and match count double;
- repeated persistent append/concat: allocations or element copies may grow
  faster than node visits;
- fixed pass count: full-pipeline node visits grow linearly but with a large
  constant multiple.

### Current-Main Production Baseline

Generate a fresh full profile from current main before production edits. Follow
the existing profile contract in
`logs/compiler-self-profile-2026-08-26-aa269938/run_profile.sh`, but write a new
dated result directory and record the current revision and compiler binary
hash.

At minimum capture three unsampled runs of:

```bash
BLORP_COMPILER_MEMORY_PROFILE=1 \
  compiler/_build/blorp-cli/blorp compile \
  --no-format --no-embed-runtime --time-phases \
  -o /tmp/blorp-core-work.c \
  blorp/src/compiler/stage_12_cli/main.brp
```

Capture one externally sampled run and generate semantic, module, and stage
flamegraphs. Record frontend, backend, total, wall, peak RSS, allocations,
generated-C bytes and lines, and output SHA-256.

The initial report must rank passes by:

- elapsed envelope;
- expression-node visits;
- reconstructed nodes;
- allocations;
- lookup candidates inspected; and
- invariant-node visits.

Do not proceed to pass fusion until this report exists.

## Slice 1: Remove Superlinear Declaration Lookups

Select the highest-cost path whose deterministic work is superlinear. If no
path is superlinear, record that result and proceed to Slice 2 without inventing
an index.

### Preferred Index Shape

Create the narrowest phase-owned index needed by the measured query. Examples:

```blorp
opaque type CoreTypeDeclarationIndex = CoreTypeDeclarationIndexRep

private record CoreTypeDeclarationIndexRep {
	unions_by_name: Dict[String, CoreUnionDecl],
	records_by_name: Dict[String, CoreRecordDecl],
	aliases_by_name: Dict[String, CoreTypeAliasDecl]
}
```

When exact nominal IDs are available, use them. A name key is acceptable only
for Core categories whose current IR identity is explicitly the canonical name
and whose duplicate behavior is validated at construction. Never silently let
the last dictionary insertion win.

### Mechanical Migration Order

For each measured lookup:

1. Add a focused fixture with at least two same-spelling declarations or other
   ambiguity pressure appropriate to the category.
2. Record baseline query and candidate-inspection counts.
3. Build the index once before the recursive rewrite.
4. Reject duplicate keys or preserve the current deterministic ambiguity
   behavior explicitly.
5. Pass the index through the existing pass context rather than rebuilding it
   recursively.
6. Replace the linear lookup.
7. Assert `declaration_lookup_candidates_inspected` is zero or constant per
   query after index construction.
8. Rerun the one-axis matrix and calculate the new exponent.
9. Run the pass's complete focused suite before selecting another lookup.

Initial candidates to inspect in order of current sampled attribution:

1. `match_projection.find_union_decl`;
2. `mono_data.find_transparent_alias`;
3. `reuse.find_union_decl`;
4. `std_inline.find_target`;
5. `prepare.find_union_decl` and equivalent helpers;
6. any new current-main caller with greater measured candidate work.

Do not combine their indexes merely because they all inspect declarations. A
shared index is justified only if two adjacent passes consume identical facts
from the same declaration epoch.

## Slice 2: Introduce Explicit Declaration Epochs

After local superlinear lookups are removed, inventory which adjacent passes
rebuild equivalent indexes.

Define a small opaque pipeline product only if at least two measured-hot passes
can share facts safely:

```blorp
opaque type IndexedCoreProgram = IndexedCoreProgramRep

private record IndexedCoreProgramRep {
	program: CoreProgram,
	declaration_epoch: Int,
	facts: CoreProgramFacts
}
```

`CoreProgramFacts` must contain metadata that remains valid when bodies change.
Do not embed exact `CoreFunction` bodies if later passes rewrite them.

### Classify Pass Effects Explicitly

Use an enum or distinct functions, not boolean combinations:

```blorp
enum CoreDeclarationEffect:
	PreservesDeclarationInventory
	AddsDeclarations
	RemovesDeclarations
	ReplacesDeclarationMetadata
```

Document and test the effect of every pass that consumes the indexed product.
Likely invalidation boundaries include:

- monomorphization;
- synthesis;
- DCE;
- closure conversion; and
- any specialization that creates or removes declarations.

Body-only rewrites may preserve a declaration metadata index, but this must be
verified field by field. A pass that changes function kind, signature, union
layout, alias definition, or callable identity invalidates the relevant fact.

### Required Behavior

- index construction occurs once per declared epoch;
- invalidating passes cannot return a value typed as retaining old facts;
- index validation rejects stale declaration counts/identities;
- diagnostic and source-order projections remain deterministic;
- no pass can pair facts from one Core program with another program;
- stop-after and dump-after paths observe the exact same Core program as before.

This slice is complete only when counters show fewer production index builds.
Introducing the wrapper without removing measured builds is not progress.

## Slice 3: Consolidate Repeated Invariant Walks

Measure invariant-node visits separately before changing behavior.

### Default Compilation

The current default path repeatedly checks resolved-call and std-inline
properties after resolve, std inline, tailrec, and fusion. Replace this only
after classifying preservation:

1. Keep the first check immediately after the pass that establishes an
   invariant unless a checked opaque result makes invalid output
   unrepresentable.
2. Prove whether each later pass can introduce the forbidden Core variants.
3. Add focused negative tests that deliberately construct malformed input at
   each public boundary.
4. If later passes preserve the property, remove repeated default scans and
   keep one final fail-closed check at the last untrusted boundary.
5. If multiple properties must be checked at one boundary, evaluate them in one
   traversal without allocating a result record at every recursive node.

The previous typed-expression validation experiment regressed by 8.4% when two
specialized traversals were combined into a string-bearing aggregate result.
Do not repeat that design. Use a mutable local accumulator, fail-fast union, or
flat iterative worklist, then measure allocations and elapsed time.

### `--check-invariants`

The explicit debug flag must continue to audit every requested stage. It may
use a combined per-stage traversal, but it must not be weakened to final-only
validation.

### Acceptance

- default production invariant-node visits decrease by the measured repeated
  amount;
- malformed public pass outputs still fail before backend emission;
- exact violation precedence and messages remain stable;
- `--check-invariants --dump-core-after=...` behavior remains unchanged;
- no default compile time or allocation regression.

## Slice 4: Add Change-Aware Expression Rewriting

Only begin this slice when the baseline shows a pass that visits many nodes but
changes a small fraction while reconstructing most of the tree.

Do not detect unchanged nodes by recursively comparing rebuilt expressions.
The mapper must signal whether it changed a node:

```blorp
union CoreExprRewrite:
	CoreExprUnchanged
	CoreExprChanged(CoreExpr)

pure func map_core_expr_children_if_changed(
	expr: CoreExpr,
	mapper: pure (CoreExpr) -> CoreExprRewrite,
) -> CoreExprRewrite:
	...
```

The implementation must:

- preserve the original `CoreExpr` when every child and the current node are
  unchanged;
- allocate a new child list only after the first changed child;
- preserve source order;
- handle every `CoreExpr` variant covered by `map_core_expr_children`;
- have an exhaustiveness test that fails when a new Core variant is not mapped;
- provide a fallible counterpart only when a measured pass requires it;
- avoid callbacks or instrumentation in the normal unmeasured path when they
  measurably cost more than reconstruction.

### Pilot Selection

Choose the highest-allocation pass satisfying all conditions:

- at least 80% of visited nodes are unchanged in the production fixture;
- the pass is a body rewrite with no declaration creation/removal;
- it has focused Core and generated-C tests;
- it does not depend on a fixpoint traversal;
- it does not require later logic to revisit children introduced by an earlier
  rewrite.

Migrate one pass first. Require exact output JSON and C hashes before extending
the API to another pass.

If the pilot reduces reconstructed nodes but regresses production elapsed or
peak RSS, reject the abstraction and retain the measurements in this issue.

## Slice 5: Fuse Compatible Traversals

Traversal fusion is last because it has the largest semantic risk.

### Eligibility Checklist

Two adjacent traversals may be fused only when all answers are yes:

1. Both are measured-hot after Slices 1-4.
2. Both operate on the same declaration epoch.
3. Neither requires a complete global analysis produced by the other's full
   output.
4. Their pre-order/post-order semantics are documented.
5. The later transform's treatment of nodes introduced by the earlier transform
   is explicit.
6. Neither pass requires a fixpoint.
7. No CLI stop/observe boundary exists between them, or the fused implementation
   can still materialize the exact requested intermediate snapshot without
   affecting normal compilation.
8. Focused stage dumps and final generated C can be compared byte-for-byte.

### Implementation Shape

Prefer a specific combined traversal owned by the two passes over a generic
pipeline of dynamically dispatched mappers. The combined code must preserve the
named conceptual stages and their tests even if normal execution shares one
walk.

Do not fuse merely by calling two recursive walkers from one top-level loop.
That reduces declaration-list reconstruction but does not reduce expression
node visits. Counters must prove the expected walks disappeared.

### Observation And Stop Semantics

The CLI supports `--dump-core-after` and `--stop-after`. A fused normal path may
be used only when neither intermediate output is requested. When an
intermediate snapshot is requested, run the established separate stage path so
the user sees the exact historical boundary. Test both execution modes.

## Correctness Invariants

- Core declaration order and definition IDs are unchanged;
- function, global, type, constructor, trait, and implementation identities are
  unchanged;
- pass ordering and fixpoint behavior are unchanged;
- DCE roots, callbacks, function references, recursion, and closure entry
  points remain exact;
- Perceus retain/release and cleanup ordering is unchanged;
- resource cleanup and cancellation behavior is unchanged;
- source locations and invariant diagnostic precedence are unchanged;
- `--stop-after`, `--dump-core-after`, observations, and final completion remain
  exact;
- generated C is byte-identical for semantics-preserving indexing/traversal
  changes;
- malformed inputs fail closed rather than falling back to name scans;
- facts never cross a declaration-invalidating pass without rebuilding.

## Functional Test Matrix

At minimum cover:

- recursive and mutually recursive functions;
- overloaded and qualified calls;
- constructors with duplicate variant spellings in distinct unions;
- transparent and opaque aliases;
- generic monomorphization and generated functions;
- trait methods and default implementations;
- callbacks, custom hash/equality functions, and function values;
- closure captures and closure entry functions;
- record updates and managed constructor matches;
- resources, cancellation, cooperative checkpoints, and cleanup exits;
- DCE of unused functions, constructors, globals, and implementations;
- debug blocks and debug-only calls;
- stop/observe after every affected early and late stage;
- malformed invariant fixtures for each removed validation boundary.

Read generated C for representative recursion, callback, closure, resource, and
ownership fixtures. Final output checksums alone are not sufficient for
ownership-sensitive changes.

## Performance Acceptance Criteria

### Algorithmic

- no selected declaration lookup has a deterministic growth exponent above
  1.20 on a one-axis declaration-count series;
- candidate inspections per exact lookup are constant after index construction;
- program index builds occur once per explicit declaration epoch;
- any fused traversal removes the expected expression-node visits rather than
  only top-level loops;
- any change-aware rewrite reduces reconstructed nodes by at least 50% on its
  measured production-shaped workload.

### Production

- at least three alternating baseline/candidate self-compilation pairs;
- identical generated-C bytes and SHA-256 for semantics-preserving slices;
- no peak RSS or allocator-byte regression greater than 3%;
- no frontend phase regression greater than 3%;
- Core/backend median improves materially. Treat less than 10% for the full
  completed issue as insufficient for the scope unless a measured superlinear
  cliff was removed for larger programs;
- whole-compiler median improvement and confidence/noise are reported without
  extrapolating synthetic speedups.

The issue should aim to reduce total Core expression-node visits and
reconstructions by at least 30% on the compiler workload. If Slice 0 shows that
traversal counts are already modest and most time is inside necessary per-node
work, stop and open a narrower issue for that work instead.

## Fast Feedback Commands

During a single pass migration:

```bash
./blorp format --check \
  blorp/src/compiler/stage_09_core/traverse.brp \
  blorp/src/compiler/stage_09_core/pipeline.brp

./blorp test --timeout 180 blorp/test/compiler/stage_09_core/test_core_traverse.brp
./blorp test --timeout 180 blorp/test/compiler/stage_09_core/test_core_pipeline.brp
git diff --check
```

Run the focused suite for every changed pass. Examples include:

```bash
./blorp test --timeout 180 blorp/test/compiler/stage_09_core/test_core_resolve.brp
./blorp test --timeout 180 blorp/test/compiler/stage_09_core/test_core_dce.brp
./blorp test --timeout 180 blorp/test/compiler/stage_09_core/test_core_perceus.brp
./blorp test --timeout 180 blorp/test/compiler/stage_09_core/test_core_closure.brp
./blorp test --timeout 180 blorp/test/compiler/stage_10_backend/test_core_emit.brp
```

Use actual filenames from the ownership manifest when a listed suite has since
been renamed. Do not create duplicate broad suites merely to match this issue.

Before completion:

```bash
make
scripts/compiler-check --stage core
scripts/test compiler-core-sanitize
scripts/test compiler-blorp
scripts/test leak
blorp/test/compiler/pipeline/codegen_audit/run_codegen_audit.sh ./blorp
scripts/compiler-check --validate-manifest
git diff --check
```

## Expected File Changes

Measurement:

- new Core pipeline work fixture, benchmark, focused suite, and runner;
- `blorp/test/compiler/compiler_test_ownership.json`;
- `benchmarks/README.md`;
- a dated result under `benchmarks/results/`;
- a fresh self-profile directory under `logs/` only if repository policy retains
  the generated profile artifacts.

Production changes depend on measured results but will likely touch:

- `blorp/src/compiler/stage_09_core/pipeline.brp`;
- `blorp/src/compiler/stage_09_core/early_pipeline.brp`;
- `blorp/src/compiler/stage_09_core/traverse.brp`;
- a new narrow `program_index.brp` or equivalent;
- the measured lookup/pass modules, initially `match_projection.brp`,
  `mono_data.brp`, `reuse.brp`, `std_inline.brp`, or `prepare.brp`;
- `early_invariants.brp` only for measured repeated early checks;
- `late_invariants.brp` only if measured late checks are changed;
- `blorp/src/compiler/stage_12_cli/late_core.brp` when stop/observe execution needs an
  explicit unfused path.

Do not touch all listed files preemptively.

## Stop Conditions

Stop and report rather than expanding scope when:

- current-main counters do not show superlinear lookup or substantial traversal
  multiplication;
- the only measured win comes from repeating a once-per-compilation operation
  many times synthetically;
- an index would be stale across the intended consumer passes;
- preserving intermediate Core observations requires maintaining two divergent
  implementations;
- a combined traversal needs a large string-bearing result at every recursive
  node;
- node visits fall but allocations, peak RSS, or production time regress;
- generated C or ownership behavior changes unexpectedly;
- a proposed generic visitor becomes larger than the passes it replaces;
- a candidate wins a microbenchmark but loses current-main self-compilation.

## Completion Report Template

The implementing agent must provide:

1. current-main baseline revision, compiler hash, host, build flags, and commands;
2. per-pass table of declarations, node visits, reconstructions, index builds,
   lookup queries/candidates, allocations, and elapsed time;
3. one-axis scaling tables with doubling ratios and growth exponents;
4. selected superlinear paths and exact replacement indexes;
5. declaration-epoch/invalidation table for every shared fact;
6. invariant scans removed or consolidated and negative tests preserving the
   boundary;
7. unchanged-node and fused-walk counters where applicable;
8. production A/B self-compilation rows, medians, peak RSS, allocations, and
   generated-C hashes;
9. focused, sanitizer, leak, codegen-audit, and stage-gate pass counts;
10. rejected pilots and why they were rejected;
11. remaining hottest Core paths after the candidate profile.
