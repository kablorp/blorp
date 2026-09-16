# Phase 10: Separate Checked And Codegen-Ready Graphs

## Issue Summary

Replace the broad `TypecheckedGraph` contract with explicit checked/recovery and
codegen-ready graph products, attach CTFE outcomes by exact identity, and make
Core lowering accept only a fully validated codegen refinement.

This issue implements
[Phase 10 of the typechecking migration](../../COMPILER_PRIORITIES.md#phase-10-checked-graph-and-codegen-ready-graph).

## Context

The frontend serves commands with different correctness and recovery needs:

- compile/run/test require complete accepted semantics and CTFE results;
- check requires complete diagnostics and may retain recovery artifacts;
- lint requires source-faithful semantic bodies and exact occurrence facts;
- LSP requires recoverable, source-oriented module and semantic indexes; and
- Core lowering requires only accepted typed declarations, exact import
  bindings, includes, identity allocation state, and selected summaries.

Current production behavior, verified on 2026-09-15 after Roadmap Step 7B:

- `TypecheckedModule` in `stage_06_typecheck/bridge.brp` stores parsed source,
  module surface, one source-faithful `typed_program`, sparse CTFE initializer
  replacements keyed by definition ID, errors, diagnostics, import bindings,
  and `ctfe_evaluated: Bool`.
- `TypecheckedGraph` stores target/modules, `next_def_id`, and optional analysis
  context.
- lint and LSP consume the source-faithful `typed_program`; compilation passes
  that program and its replacement table to Core lowering. Typed JSON and
  summary output materialize the historical evaluated view only on demand.
- `prepare_core_lowering_request` is the last reader of the rich
  `TypedFrontendCompilation` and returns opaque `PreparedCoreLoweringRequest`.
  The command and top-level CLI also transition to narrow preparation variants,
  so no caller frame retains `CliCompilePlan` or `TypecheckedGraph` while Core
  runs. `core_lowering_input_ready` measures that production release boundary.
- codegen admission clears `TypedProgram.source.text`; Core retains the
  canonical module name, paths and compact span coordinates but cannot reach
  the source file contents. Check, lint and LSP keep their separate
  source-oriented products.
- `CoreGraphUnit` and the production
  `prepare_core_graph_with_ctfe_replacements` path still accept raw
  `TypedProgram` values, so the Core boundary does not encode semantic
  acceptance even though it no longer needs a second complete program.
- `TypedParsedDecl(ParsedDecl)` is a broad catch-all. Core intentionally treats
  only import blocks and builtin type declarations as compile-time-only and
  rejects other parsed declarations.

## Relationship To Other Issues

### Prerequisites

- The completed Phase 5 boundary provides completed/recoverable header
  outcomes.
- The completed Phase 6 boundary provides per-definition body outcomes and
  exact artifacts.
- Demand-driven CTFE provides explicit outcomes and a shared body store.
- [Phase 8](phase-08-solver-finalization.md) ensures accepted body facts are
  meta-free.
- [Phase 9](phase-09-semantic-validation.md) provides validated/rejected body
  products.

This issue must not begin semantic cutover before those products are
authoritative. Assembly scaffolding may be tested earlier, but it must not wrap
the current broad graph and call that completion.

### Downstream Coordination

This issue changes contracts consumed by:

- Stage 08 Core lowering;
- CLI compile/check/lint commands;
- LSP compiler service and semantic index;
- typed AST/semantic JSON projections;
- package/test command paths; and
- profiling and memory checkpoints.

Coordinate with concurrent LSP work. Do not force LSP onto a codegen-only
product or remove source recovery facts it needs.

## Problem Statement

`TypecheckedGraph` currently combines accepted and recoverable concerns in one
large record. Validity is encoded through error lists, optional/context fields,
and a CTFE Boolean. Modules retain two complete typed programs so tools can use
source-faithful semantics while compile uses evaluated values.

This causes:

1. Core accepting a raw typed program without a type-enforced acceptance proof;
2. tools and compilation retaining fields they do not need;
3. ~~duplicated full typed programs after CTFE;~~ completed by Step 7A;
4. status fields whose valid combinations are conventional rather than
   representable by variants;
5. bridge code owning semantic assembly and reconstruction; and
6. broad graph lifetime/memory pressure despite the later CLI projection.

## What This Solves

- Recovery/tool output and valid Core input become different types.
- Core cannot run unless required headers, bodies, validation, and CTFE have
  accepted.
- CTFE replacements attach by exact identity instead of duplicating complete
  typed programs.
- Each command retains only the graph product it needs.
- Assembly validates completeness once and does not recompute semantics.
- Bridge code returns to orchestration and transport responsibilities.
- The intended early-release boundary for rich typecheck state is established
  and measured rather than assumed from the narrower read shape.

## Expected Performance And Cleanup Impact

This phase is expected to deliver its largest benefit in **peak memory and
retained object count**, not raw type inference speed. Before Step 7A,
`TypecheckedModule` structurally retained both a source-faithful
`semantic_program` and a CTFE-rewritten `typed_program`. Step 7A deleted that
dual owner. The remaining opportunity is releasing parsed/module, diagnostic,
import, status, and other recovery-only data before Core.

The direct optimization mechanisms are:

- retain one authoritative source-faithful artifact and sparse CTFE
  replacements by exact identity;
- project command-specific checked or codegen products instead of one broad
  graph for every consumer;
- release recovery, diagnostics, and source-only data before Core when compile
  no longer needs them;
- stop rescanning graphs to rediscover completeness/status; and
- avoid rebuilding Core input from broad typed modules.

Expected impact is **high for frontend peak memory on large compiler/project
graphs** and **low to moderate for CPU time**, primarily from fewer allocations,
copies, and graph traversals. The existing private `CoreLoweringInput`
projection shows that a narrow Core read shape is practical. It does not prove
that the rich owner dies before Core; this issue must establish that lifetime
while strengthening the semantic products on either side.

This phase enables:

- command-specific caching and serialization of checked artifacts;
- incremental codegen refinement from changed accepted bodies;
- earlier release of LSP/lint recovery data in compile commands;
- stable sparse CTFE replacement caches; and
- Core/backend execution without retaining frontend recovery structures.

Step 7A completed the dual-program cleanup. Remaining cleanup includes
`ctfe_evaluated` and coupled status/options, broad graph accessors, repeated completeness scans, raw
`TypedProgram` Core entry points, and semantic fallback through parsed
declarations. Success requires before/after retained typed-node/object counts
at each compiler memory checkpoint, no overlapping old/new graph peak, fewer
assembly scans, unchanged Core/C output, and lower or equal wall time.

## Proposed Architecture

```text
CheckedGraph {
    modules: checked/recovered module products,
    headers: accepted/rejected header outcomes,
    bodies: accepted/rejected body outcomes by identity,
    ctfe: accepted/rejected/not-required outcomes by identity,
    diagnostics: deterministically ordered diagnostics,
    source_provenance: tool-facing source facts
}

opaque CodegenReadyGraph {
    target,
    selected accepted headers and validated bodies,
    exact CTFE replacements,
    exact import bindings,
    include directories,
    identity allocation/generation state
}

refine_for_codegen(CheckedGraph, target) ->
    Result[CodegenReadyGraph, CodegenReadinessFailure]
```

Do not represent CTFE state as a Boolean plus related optional values. Use
explicit variants such as not required, accepted value/replacement, and
rejected with diagnostics.

## Command Ownership

- **compile/run/test:** require `CodegenReadyGraph`.
- **check:** consumes `CheckedGraph` and diagnostics; it must not invoke Core on
  rejection.
- **lint:** consumes source-faithful accepted/recovered body artifacts and exact
  semantic occurrences from `CheckedGraph`.
- **LSP:** consumes a recoverable source-oriented projection. It may cache that
  projection, not the codegen graph.
- **Core:** accepts only `CodegenReadyGraph` or a narrower projection whose sole
  constructor requires it.

## Implementation Plan

The numbered sections are ordered work, not necessarily one commit each. Form
mergepoints from vertical slices that include a focused test, a production
consumer, and deletion of the replaced path. Do not merge a dormant parallel
model.

### 1. Write Failing Boundary Tests

Add:

- `test_compiler_checked_graph.brp` for mixed accepted/rejected graph assembly,
  deterministic diagnostics, and source provenance;
- `test_compiler_codegen_ready_graph.brp` for fail-closed refinement; and
- Core-lowering tests proving raw `TypedProgram` and recovery products cannot
  enter `prepare_core_graph`.

Cover missing/rejected global headers, rejected bodies, required CTFE failure,
irrelevant rejected modules, mismatched identities, duplicate artifacts, and
parser-recovery declarations.

### 2. Inventory Current Assembly And Consumers

Trace every construction and consumer of:

- `TypecheckedModule` and `TypecheckedGraph`;
- the source-faithful `typed_program` and sparse CTFE replacement table;
- CTFE status/error fields;
- `CoreGraphUnit` and `prepare_core_graph`;
- CLI graph validation and projection;
- lint semantic-program traversals;
- LSP compiler-service and semantic-index graph access;
- typed summary/JSON output; and
- source include/import-binding projection.

For every field, identify its owning command and last use. Do not migrate a
field into both checked and codegen graphs by default.

### 3. Introduce Exact Assembly Inputs

Graph assembly consumes only Phase 5-9 outcomes keyed by exact module and
definition identities:

- completed/recoverable header outcomes;
- validated/rejected body outcomes;
- CTFE value/replacement/failure outcomes;
- accepted import/module views;
- source provenance and diagnostics; and
- selected target requirements.

It must not reparse declarations, reinstall headers, recheck bodies, rerun
CTFE, or reconstruct identity from names.

### 4. Construct `CheckedGraph`

`CheckedGraph` may contain mixed accepted/rejected modules because check, lint,
and LSP need useful recovery. Use variants for coupled states rather than
optional fields plus flags.

Required invariants:

- every artifact identity belongs to the graph/module/category claimed;
- duplicate accepted artifacts are rejected unless they are the exact same
  canonical artifact;
- diagnostics are aggregated in stable module/definition/source order;
- parser recovery cannot become accepted semantic inventory;
- source provenance is retained without being rematched for semantic facts; and
- rejected artifacts cannot be projected as accepted by convenience accessors.

### 5. Replace Parallel Complete Typed Programs — Complete

Production now keeps one authoritative source-faithful typed program and a
sparse map whose rows contain only parsed and typed initializer payloads keyed
by exact definition ID. Core lowering consumes a row while lowering its owning
global and never materializes another `TypedProgram`. JSON and summary adapters
may construct a transient evaluated projection because their output contract
requires the complete view. See the
[Step 7A completion packet](../compiler-performance/146-step7a-keyed-ctfe-replacements.md)
for tests and measurements.

### 6. Refine To `CodegenReadyGraph`

Define target completeness exactly:

- all selected type/callable/global/implementation headers accepted;
- every selected body accepted and validated;
- every required immutable initializer has an accepted CTFE outcome;
- mutable/runtime initializers are represented according to current semantics;
- import bindings and include directories are complete;
- no unsupported `TypedParsedDecl` remains; and
- identity allocation/generation state is coherent.

The refinement validates this once and returns structured failures with source
diagnostics where possible. `CodegenReadyGraph` construction must be opaque.

### 7. Change The Core Boundary

Replace `prepare_core_graph(target: TypedProgram, modules: List[CoreGraphUnit],
...)` with an entry accepting `CodegenReadyGraph` or a narrow
`CoreLoweringInput` constructible only from it.

Establish the intended lifetime boundary: the rich checked graph must reach its
last use before Core preparation, with direct ownership/retained-memory
evidence. Do not store `CheckedGraph` inside the codegen-ready projection.

Read the generated Core/C in focused tests to verify CTFE replacements, imports,
globals, functions, and compile-time-only declarations lower identically.

### 8. Cut Over Commands Independently

Recommended order:

1. compile/run/test to codegen refinement;
2. check to checked diagnostics;
3. lint to source-faithful checked artifacts;
4. LSP to its recovery/source projection;
5. typed summaries and semantic occurrence inventories; and
6. package/other command adapters.

Each command slice must delete its old `TypecheckedGraph` accessors. Avoid one
temporary mega-adapter that reproduces the broad graph indefinitely.

### 9. Narrow Parsed Provenance

Replace broad `TypedParsedDecl(ParsedDecl)` catch-all with exact source-only
variants or provenance records for imports, builtin types, and any other
intentionally compile-time-only forms. Recovery declarations remain in
`CheckedGraph` recovery data, never codegen-ready semantic declarations.

Delete semantic consumers that rematch raw parsed declarations after accepted
headers/bodies exist.

### 10. Move Assembly Ownership And Delete The Broad Graph

Move semantic assembly out of `stage_06_typecheck/bridge.brp` into a cohesive
assembly owner only after the product inputs are stable. The bridge should
decode requests, invoke phases, trace, and return results.

Delete:

- broad `TypecheckedGraph`/`TypecheckedModule` production contracts;
- duplicate complete semantic/CTFE-rewritten programs;
- `ctfe_evaluated` and coupled optional/status fields;
- raw `TypedProgram` Core entry points;
- command adapters that retain the rich graph after projection; and
- parsed-declaration semantic fallback.

## Likely Files To Touch

- `blorp/src/compiler/stage_06_typecheck/bridge.brp`
- `blorp/src/compiler/stage_06_typecheck/frontend_graph_typecheck.brp`
- `blorp/src/compiler/stage_06_typecheck/graph/semantic_occurrence.brp`
- Phase 5-9 product modules
- `blorp/src/compiler/stage_08_core_lower/graph_prepare.brp`
- `blorp/src/compiler/stage_08_core_lower/lower.brp`
- `blorp/src/compiler/pipeline.brp`
- `blorp/src/lib/compilation.brp`
- `blorp/src/lint/command.brp`
- `blorp/src/lsp/compiler_service.brp`
- `blorp/src/lsp/semantic_index.brp`
- `blorp/src/lsp/analysis_model.brp`
- focused CLI/LSP/Core/typecheck suites and public fixtures
- compiler-test ownership manifest entries for new modules and suites

Suggested ownership if it remains cohesive:

```text
stage_06_typecheck/assembly/checked_graph.brp
stage_06_typecheck/assembly/codegen_ready_graph.brp
stage_06_typecheck/assembly/diagnostics.brp
```

If codegen refinement depends only on accepted typecheck products, Stage 08 may
own its narrow projection constructor while Stage 06 owns `CheckedGraph`. Do not
create a reverse dependency from Stage 06 into Core.

## How To Test

### Focused Product Tests

```bash
make
./blorp test --timeout 180 blorp/test/compiler/test_compiler_checked_graph.brp
./blorp test --timeout 180 blorp/test/compiler/test_compiler_codegen_ready_graph.brp
./blorp test --timeout 180 blorp/test/compiler/stage_06_typecheck/test_typecheck_bridge.brp
./blorp test --timeout 180 blorp/test/compiler/stage_06_typecheck/test_frontend_graph_typecheck.brp
./blorp test --timeout 180 blorp/test/compiler/legacy/stage_12_cli/test_cli_frontend_graph_adapter.brp
```

Add focused Core lowering tests for successful refinement and every fail-closed
case. Read generated Core/C for representative globals, CTFE replacements,
imports, methods, and compile-time-only declarations.

### Command Contracts

```bash
scripts/test compiler-blorp
scripts/test compiler-tools
scripts/test cli
scripts/test lsp
scripts/test package
```

Check that:

- compile/run/test reject recovery graphs before Core;
- check still reports complete deterministic diagnostics;
- lint sees source-faithful semantic bodies;
- LSP retains recovery and source occurrence information; and
- no command accidentally triggers body checking or CTFE during assembly.

### Ownership And Memory

```bash
scripts/test compiler-blorp-sanitize
scripts/test leak
```

Use compiler memory checkpoints for frontend completion, backend completion, and
artifact writing. Add counters for:

- checked and codegen graph nodes/artifacts;
- retained typed nodes at the Core boundary;
- CTFE replacement count;
- body artifact reuse;
- graph scans; and
- duplicate reconstruction attempts.

Compare peak memory against the current dual-`TypedProgram` representation.
The issue is not complete if old and replacement graphs overlap long enough to
move or increase peak RSS.

### Determinism

Compile the same graph with different module/body scheduling orders and compare:

- diagnostics;
- checked/codegen graph stable projections;
- Core output;
- generated C; and
- final executable behavior.

Session-local IDs must not leak into serialized artifacts or cache keys.

### Gates

```bash
scripts/compiler-check --stage typecheck
scripts/test compiler-core-sanitize
make quality
git diff --check
```

## Acceptance Criteria

- `CheckedGraph` and `CodegenReadyGraph` are explicit, distinct products.
- Core accepts only a codegen-ready refinement or a projection whose constructor
  requires it.
- Rejected/recovered bodies and headers cannot reach Core.
- Check/lint/LSP retain the source and recovery facts they require.
- CTFE results attach by exact identity without duplicate complete programs.
- Assembly does not reparse, recheck, rerun CTFE, or reconstruct semantic
  identity.
- The rich-graph lifetime ends before Core preparation and that boundary is
  verified by direct ownership/retained-memory evidence.
- Broad graph contracts, status booleans, raw Core entry points, and semantic
  parsed fallbacks are deleted.
- Focused, command, sanitizer/leak, determinism, memory, stage, and quality
  checks pass.

## Pitfalls And Non-Goals

- Do not wrap `TypecheckedGraph` in a new opaque type and call that refinement.
- Do not force LSP or lint to consume a codegen-only graph.
- Do not retain `CheckedGraph` inside `CodegenReadyGraph`.
- Do not represent coupled state with Booleans and unrelated `Option` fields.
- Do not duplicate full typed programs merely for CTFE replacements without
  current measurement.
- Do not reconstruct identities from module/name strings.
- Do not delete source provenance needed by diagnostics and tools.
- Do not move Stage 08/Core dependencies into Stage 06.

## Handoff Checklist

- [ ] Verify Phases 5-9 products are authoritative in production.
- [ ] Inventory every `TypecheckedGraph` field and consumer.
- [ ] Add fail-closed refinement and mixed-recovery tests first.
- [ ] Baseline retained typed nodes and peak memory.
- [ ] Build `CheckedGraph` from exact outcomes without semantic recomputation.
- [ ] Replace dual programs with measured identity-based CTFE attachment.
- [ ] Cut Core over to the opaque codegen-ready boundary.
- [ ] Migrate commands one at a time and delete old accessors.
- [ ] Confirm LSP/lint recovery behavior and deterministic diagnostics.
- [ ] Delete broad graph/status/raw Core paths and update architecture docs.
