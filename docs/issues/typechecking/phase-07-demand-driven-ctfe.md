# Phase 7: Materialize CTFE Bodies On Demand

## Implementation Status

The accepted-graph production path is implemented as of 2026-08-25:

- immutable completed globals seed an exact definition-identity worklist;
- resolved direct, trait, implementation, recursive, and function-reference
  dependencies are discovered from accepted typed bodies;
- target-local helper bodies participate in discovery without being emitted as
  imported CTFE programs;
- non-source callables are represented as no-body work items, while unresolved
  trait dispatch requests conservative eager preparation;
- closure calls do not invent module-body dependencies because named function
  values retain direct metadata and lambda bodies remain embedded typed trees;
- CTFE imports use an opaque complete-or-selective representation, preventing a
  selective callable set from masquerading as a complete `TypedProgram`;
- selected ordinary modules and target-local helpers reuse CTFE-checked body
  outcomes;
- reusable body outcomes carry opaque provenance for the accepted indexed graph,
  selected module, and semantic body-check options, so incompatible graph or
  policy contexts cannot reuse stale typed bodies;
- prepared dependencies represent selective, eager, reusable, and failed modes
  as distinct variants, with selective seed outcomes confined to the selective
  variant;
- dependency shapes represented by the exact worklist stay selective, while
  unsupported accepted shapes take an explicit, measured module-wide fallback
  rather than producing a partial typed program; fallback metrics preserve the
  exact cause and distinguish target discovery checks from dependency checks.

The maintained 24-by-32 workload now checks 24 bodies per graph rather than
768. Its final five-sample median improved from 208,294 us to 120,881 us
(42.0%). The 24-by-1 control improved from 103,764 us to 64,336 us (38.0%). Raw
samples are recorded in
[`benchmarks/results/compiler_ctfe_typecheck_profile_2026-08-25.md`](../../../benchmarks/results/compiler_ctfe_typecheck_profile_2026-08-25.md).

Recoverable graphs retain complete diagnostic materialization. The traced
bridge path also retains its existing per-module trace adapter until trace
events can be emitted directly by the Stage 07 worklist without falsifying
event timing. Accepted graphs with dependency shapes that the worklist cannot
yet represent also retain a conservative eager fallback. Accepted graphs with
no callable CTFE roots currently use that explicit eager mode rather than
constructing an empty body schedule. Production metrics distinguish selective,
eager, and failed dependency modules. None of these fallback paths is used by
the accepted production benchmark above; removing them remains Phase 7 closure
work.

## Issue Summary

Replace module-wide CTFE dependency typechecking with an exact,
definition-identity worklist that checks only reachable bodies and reuses the
same accepted body artifacts for ordinary compilation.

This issue implements
[Phase 7 of the typechecking migration](../../COMPILER_PRIORITIES.md#phase-7-demand-driven-ctfe-body-materialization).

## Context

CTFE evaluates immutable globals before Core lowering. Module discovery and
dependency selection are already explicit, but body preparation remains eager.

Current production behavior, verified on 2026-08-23:

- `ctfe_dependencies_for_graph` and related bridge code choose dependency
  modules.
- `prepare_ctfe_dependency_program` typechecks a selected dependency into a
  complete `TypedProgram`, using a reusable artifact when possible and otherwise
  materializing the complete module.
- `ctfe_imported_programs_from_dependencies` collects those complete programs.
- `ctfe_context_from_program` walks the target and every imported program to
  collect constructors and functions.
- `ctfe_evaluate_program_globals` evaluates globals only after the complete
  imported-program context has been assembled.
- The maintained width/depth fixture records expected reachable and irrelevant
  body counts, but those counts are modeled rather than observed from
  production materialization.

The recorded 24-module by 32-function profile materialized 768 dependency
function bodies while the evaluated call chain used 24. The result and raw data
are in `benchmarks/results/compiler_ctfe_typecheck_profile_2026-08-10.md` and
the adjacent TSV.

## Relationship To Other Issues

### Prerequisites

- [Phase 5: Global Header Completion](phase-05-global-header-completion.md)
  provides typed initializer roots and complete global facts.
- [Phase 6: Independent Body Checking](phase-06-independent-body-checking.md)
  provides the only body-check facade CTFE may call.

### Later Consumers

- [Phase 8](phase-08-solver-finalization.md) and
  [Phase 9](phase-09-semantic-validation.md) strengthen the internals of the
  accepted body artifact without changing this worklist API.
- [Phase 10](phase-10-checked-codegen-graphs.md) assembles CTFE outcomes and
  reused body artifacts into checked/codegen-ready graph products.

Phase 7 deliberately precedes solver/validation restructuring because eager
CTFE body materialization is a measured large cost. It must nevertheless use
the complete Phase 6 facade so it cannot observe partial inference state.

## Problem Statement

Current CTFE dependency preparation uses module reachability as a proxy for
body reachability. Once a module is selected, every body is checked and retained
even if CTFE calls only one function from that module.

This causes:

1. work proportional to unrelated declaration width;
2. duplicate checking when ordinary output later needs the same body;
3. complete dependency `TypedProgram` allocation and retention;
4. bridge ownership of semantic scheduling that belongs to Stage 07; and
5. no production counter proving how many bodies were requested or reused.

## What This Solves

- CTFE work scales with the exact reachable definition closure.
- Each required body is checked at most once per graph.
- Recursive and cross-module calls terminate through explicit work states.
- Higher-order/dynamic cases are conservative by explicit typed facts, not
  names or depth limits.
- Ordinary compilation reuses CTFE-checked body artifacts.
- Complete imported typed programs are no longer required for CTFE context.
- The existing 768-versus-24 problem becomes directly measurable and testable.

## Expected Performance And Cleanup Impact

This phase has the strongest existing quantitative case. The recorded
24-module by 32-function workload:

- materialized 768 dependency function bodies;
- reached 24 functions during CTFE;
- spent 0.702 seconds in body materialization and 0.183 seconds in imported
  registration within a 1.057-second instrumented run; and
- attributed roughly 90-93% of wide-workload growth to unreachable sibling
  width in the tested configurations.

Those percentages are an upper bound, not a promised end-to-end speedup: real
programs may reach more bodies, instrumentation times are inclusive, and other
compiler phases remain. The concrete target is to move the representative body
count from 768 toward 24 plus explicitly recorded conservative dynamic-call
candidates.

Expected impact is **high for CTFE-heavy projects with wide dependency
modules**, including substantial allocation and peak-memory reduction from not
building complete imported `TypedProgram` values. Low-CTFE and narrow-module
projects should see little benefit, so fixed worklist overhead must be measured
with a control workload.

This phase also enables:

- reuse of CTFE-checked bodies by ordinary output;
- definition-level CTFE/body caching;
- incremental invalidation by exact dependency edges; and
- later parallel checking of independent worklist branches.

Expected cleanup includes complete CTFE dependency-program preparation,
imported-program constructor/function scans, duplicate body stores, and bridge
scheduling logic. Success is primarily an observed-work contract: irrelevant
module width must not increase checked-body counts, duplicate checks must be
zero, and result/checksum, wall time, and peak memory must be recorded against
the maintained baseline.

## Proposed Architecture

```text
BodyWorkState =
    Unseen
    Queued
    Checking
    Accepted
    Rejected

BodyWorklist {
    states: CallableId -> BodyWorkState,
    queue: deterministic queue of CallableId
}

CtfeBodySet {
    bodies: CallableId -> CheckedBodyArtifact,
    failures: CallableId -> diagnostics,
    counters: CtfeMaterializationCounters
}
```

Constructors and non-body declaration facts should come directly from accepted
headers/identity indexes. Do not materialize a body merely to rediscover a
constructor or signature.

The worklist is compilation-scoped. Output order and diagnostic order are
separate stable projections; they must not depend on queue insertion timing.

## Implementation Plan

The numbered sections are ordered work, not necessarily one commit each. Form
mergepoints from vertical slices that include a focused test, a production
consumer, and deletion of the replaced path. Do not merge a dormant parallel
model.

### 1. Add Observability Before Optimization

Add production counters to the current eager path:

- CTFE root requests;
- body requests;
- first-time queue/check events;
- accepted/rejected bodies;
- reused artifacts;
- duplicate requests;
- candidate expansion for conservative dynamic calls; and
- complete dependency bodies materialized by the legacy path.

Expose counters through the existing benchmark-only/profile mechanism, not
ordinary user output. Update
`compiler/tests/test_compiler_ctfe_typecheck_profile_benchmark.brp` so it
asserts observed materialization rather than only fixture expectations.

This instrumentation slice is required. Do not claim selective materialization
from wall time alone.

### 2. Characterize CTFE Reachability

Write focused cases for:

- immutable global initializer roots;
- direct, recursive, and mutually recursive calls;
- cross-module and selectively imported calls;
- function values and callbacks;
- generic/overloaded calls after resolution;
- trait dispatch and implementation methods;
- constructors and builtin functions;
- rejected body dependencies;
- repeated requests from multiple roots; and
- dependency cycles.

For every case, identify the exact typed metadata that names the target. If a
dynamic call has no exact target, define an explicit conservative candidate set
owned by typechecking. Do not fall back to source names, generated C names,
module strings, or arbitrary recursion limits.

### 3. Introduce The Deterministic Worklist

Seed the queue from exact typed initializer roots produced by Phase 5. Use
nominal definition/callable identities as keys.

Required invariants:

- one state entry per identity;
- no duplicate queue entries;
- `Checking` breaks recursion without pretending the body is accepted;
- rejection remains explicit and memoized;
- roots and discovered targets have stable ordering; and
- graph/category mismatches fail closed before checking a body.

### 4. Discover Dependencies From Accepted Typed Bodies

For each queued callable:

1. request its body through the Phase 6 facade;
2. memoize the complete accepted/rejected outcome;
3. traverse resolved call and function-reference metadata;
4. enqueue exact newly discovered callable identities;
5. read constructor/global/type facts from accepted headers; and
6. attach deterministic diagnostics for failed dependencies.

Use the shared typed-expression child/traversal infrastructure when it preserves
exact metadata and avoids another recursive expression walker. Do not force
unrelated validation facts into the CTFE dependency traversal.

### 5. Reuse Accepted Artifacts

Make ordinary selected-module materialization consult the same body-artifact
store before invoking the Phase 6 checker. Preserve module and declaration
source order when assembling output, independent of CTFE discovery order.

Prove with a counter that a body reached by CTFE and ordinary output is checked
once.

### 6. Replace Complete Imported Programs

Refactor CTFE context construction to consume:

- accepted constructor/signature/header indexes;
- the exact `CtfeBodySet`;
- typed global initializers and values; and
- exact import bindings required for diagnostics/resolution.

It must no longer require a complete `CtfeImportedProgram` for every dependency
module. Keep source provenance needed for errors without retaining unrelated
body trees.

### 7. Move Scheduling Into Stage 07

Move worklist ownership and dependency expansion out of
`stage_06_typecheck/bridge.brp`. The bridge may request CTFE and transport its
outcome, but Stage 07 owns CTFE roots, scheduling, evaluation, and CTFE-specific
diagnostics.

Avoid a large mechanical move before the worklist has one production vertical
slice. Move code with ownership, then delete forwarding wrappers.

### 8. Delete The Eager Path

Remove:

- complete dependency-module body materialization for CTFE;
- `prepare_ctfe_dependency_program` and related typed-program reconstruction
  once no caller remains;
- legacy imported-program function/constructor scanning;
- duplicate body stores; and
- modeled-only benchmark assertions superseded by observed counters.

Do not retain eager fallback for unsupported dynamic calls. Represent and test
the conservative candidate set instead.

## Likely Files To Touch

- `compiler/src/stage_06_typecheck/bridge.brp`
- Phase 6 body artifact/store modules
- `compiler/src/stage_06_typecheck/graph/typed_expr_children.brp`
- `compiler/src/stage_07_ctfe/context.brp`
- `compiler/src/stage_07_ctfe/globals.brp`
- `compiler/src/stage_07_ctfe/env.brp`
- `compiler/src/stage_07_ctfe/eval.brp`
- `compiler/src/stage_07_ctfe/materialize.brp`
- `compiler/benchmarks/compiler_ctfe_typecheck_profile.brp`
- `compiler/benchmarks/compiler_ctfe_typecheck_profile_fixture.brp`
- `compiler/tests/test_compiler_ctfe_typecheck_profile_benchmark.brp`
- `compiler/tests/test_compiler_ctfe_context.brp`
- `compiler/tests/test_compiler_ctfe_globals.brp`
- `compiler/tests/test_compiler_ctfe_materialize.brp`
- compiler-test ownership manifest entries for new modules and suites

Suggested new ownership, if it forms an acyclic Stage 07 subsystem:

```text
stage_07_ctfe/body_worklist.brp
stage_07_ctfe/body_dependencies.brp
stage_07_ctfe/body_set.brp
```

## How To Test

### TDD Feedback Loop

Start by changing the benchmark contract so the current eager implementation
fails the observed-count assertion.

```bash
make
./blorp test --timeout 180 compiler/tests/test_compiler_ctfe_typecheck_profile_benchmark.brp
./blorp test --timeout 180 compiler/tests/test_compiler_ctfe_context.brp
./blorp test --timeout 180 compiler/tests/test_compiler_ctfe_globals.brp
./blorp test --timeout 180 compiler/tests/test_compiler_ctfe_materialize.brp
./blorp test --timeout 180 compiler/tests/test_compiler_typecheck_bridge.brp
```

Add focused worklist tests for recursion, repeated roots, rejection, dynamic
candidates, and deterministic ordering.

### Known Performance Contract

Run `benchmarks/compiler_ctfe_typecheck_profile` with the maintained fixture and
same checksum/toolchain as the recorded baseline. For the representative
24-by-32 case, assert:

- 24 exact reachable dependency bodies, plus documented conservative
  candidates, are checked rather than 768;
- duplicate requests do not cause duplicate checks;
- the evaluated result/checksum is unchanged;
- widening irrelevant module bodies does not increase checks;
- a low-CTFE control does not regress materially; and
- wall time and peak memory are recorded, not inferred from counters.

### Ownership And Sanitizers

```bash
scripts/test compiler-blorp-sanitize
scripts/test leak
```

Exercise recursive worklists and retained artifacts under ASan/UBSan and leak
checking. Ensure rejected/cyclic work does not retain queues or complete module
programs.

### Gates

```bash
scripts/compiler-check --stage typecheck
make quality
git diff --check
```

## Acceptance Criteria

- CTFE reachability is keyed by exact identities and deterministic.
- Every required body is checked at most once per graph.
- CTFE and ordinary output reuse the same accepted artifact.
- Recursion, rejection, callbacks, and conservative dynamic candidates are
  explicit and tested.
- The maintained 24-by-32 fixture observes approximately 24 dependency checks,
  not 768.
- CTFE no longer requires complete dependency `TypedProgram` values.
- Scheduling ownership has moved from the typecheck bridge to Stage 07.
- The eager path and superseded adapters are deleted.
- Focused, sanitizer/leak, benchmark, stage, and quality gates pass.

## Pitfalls And Non-Goals

- Do not build a CTFE-only inference engine.
- Do not infer reachability from parsed names, function spelling, module path
  strings, or generated C identifiers.
- Do not treat constructors as bodies merely because the old context collected
  them alongside functions.
- Do not use a depth limit to terminate recursion.
- Do not optimize solver internals here; Phase 8 owns solver representation.
- Do not return bodies in worklist order when source-order output is required.
- Do not leave the eager module fallback after the candidate model is explicit.

## Handoff Checklist

- [ ] Verify Phase 5 typed initializer roots and Phase 6 body facade exist.
- [ ] Add observed counters before changing scheduling.
- [ ] Make the current 768-body behavior fail a focused test.
- [ ] Inventory every typed call/function-reference form.
- [ ] Implement one exact direct-call vertical slice.
- [ ] Add recursion, rejection, callback, and conservative-candidate coverage.
- [ ] Prove artifact reuse with counters.
- [ ] Delete complete imported-program preparation and scanning.
- [ ] Store before/after raw benchmark data in `benchmarks/results/`.
