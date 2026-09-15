# Prove Codegen Input Last Use and Release Frontend-Only Data

**Status:** Ready for the bounded inventory, liveness harness, and first
pre-Core release slice. Full cutover remains owned by Steps 7A/7B and Phase 10.

**Current state:** `TypecheckedModule` retains parsed source, module surface,
source-faithful and CTFE-rewritten `TypedProgram` values, diagnostics, import
bindings, errors, and status. The compile path projects a narrower
`CoreLoweringInput`, but that input still contains raw typed programs and the
CLI compile plan can keep the source graph reachable around the projection.
Core and artifact construction also retain some legitimate source/debug and
foreign-build facts. We have not proved a field-by-field last-use boundary.

**Next action:** Produce a checked-in consumer/lifetime matrix for every field
reachable from `TypecheckedGraph`, `CoreLoweringInput`, and the compile plan,
then add the proposed boundary-liveness harness below. Use it to move
`prepare_core_graph` into a scope that no longer owns
`TypedFrontendCompilationRep`; do not introduce a replacement graph yet.

**Read first:**
[`phase-10-checked-codegen-graphs.md`](../typechecking/phase-10-checked-codegen-graphs.md),
the [normalized compilation roadmap](NORMALIZED_SEMANTIC_COMPILATION_ROADMAP.md),
`blorp/src/compiler/stage_06_typecheck/bridge.brp`,
`blorp/src/compiler/pipeline.brp`,
`blorp/src/compiler/stage_08_core_lower/graph_prepare.brp`, and
`blorp/src/compiler/stage_10_backend/build_artifact_builder.brp`.

**Fast loop:** First implement the proposed
`benchmarks/compiler_codegen_input_lifetime` harness and its counter schema.
Then run its small multi-module fixture after each edit and assert owner counts
at frontend projection and Core entry. The first slice must preserve Core and
generated-C hashes while reducing a deterministic retained-owner/node/byte
count. Use three alternating production pairs for the merge decision.

**Decision:** Release data only when every production consumer is classified
and an explicit projection owns all later-required facts. Accept a slice only
when its old owner becomes unreachable before Core and output/diagnostics stay
identical. Stop if a field has a conditional diagnostic, dump, profile,
foreign-build, or runtime consumer that the proposed product does not model.

## Objective

Prove the exact last use of frontend compilation data and establish one real
lifetime boundary where the current rich typechecked owner dies before Core
preparation. Hand the resulting inventory and measurements to Phase 10 for the
accepted-product cutover.

## Why This Issue Exists

Step 7B says to construct a narrow codegen-ready input and release compile-only
recovery/analysis state. That direction is correct, but “Core probably does
not need it” is not sufficient evidence. Some strings and tables do have valid
late consumers:

- source locations for late invariant failures and requested Core dumps;
- logical names for profiling, diagnostics, leak tags, and readable comments;
- foreign includes, link flags, and ABI spellings for artifact construction;
- actual program string literals and enum-to-string display values; and
- identity tables or allocation frontiers needed to validate exact IDs.

Other owners appear frontend-only—parsed recovery trees, rejected alternatives,
complete typecheck diagnostics after successful admission, source-oriented
semantic programs in compile mode, and module surfaces after exact Core inputs
are projected—but those are hypotheses until their last consumers are traced.

This issue is the proof and lifetime packet for Roadmap Step 7B. Phase 10 still
owns the final `CheckedGraph`/`CodegenReadyGraph` product design. Do not create a
third broad graph here.

## Required Consumer/Lifetime Matrix

Add a concise table to this issue or, if it becomes shared architecture, to
`docs/ARCHITECTURE.md`. Each row must name:

| Column | Required content |
| --- | --- |
| Owner/field | Exact record and field or reachable product family |
| Producers | Exact constructors |
| Consumers | Production functions and command modes |
| Last use | Before/within/after Core, including conditional flags |
| Later fact | Exact smaller fact needed later, if any |
| Disposition | Keep, project, conditional sidecar, or release |
| Proof | Test, counter, output hash, or diagnostic fixture |

At minimum inventory:

- `CliCompilePlan.graph` and source graph ownership;
- every `TypecheckedGraph` and `TypecheckedModule` field;
- both `semantic_program` and `typed_program`;
- `CoreLoweringInput` and `CoreGraphUnit` fields;
- `DefinitionTable`, `ModuleTable`, and `next_def_id`/allocation frontier;
- parsed/source locations and module surfaces;
- imports, include directories, foreign link metadata, and target metadata;
- typed/Core summaries, observations, dumps, and profile configuration.

Prepared Core retained after emission for artifact construction is a separate
backend-lifetime concern. Record it as adjacent work if discovered, but do not
expand this pre-Core issue to own it.

Search all compile, run, test, check, lint, LSP, package, JSON/dump, profile,
and error paths. A consumer hidden behind a debug flag still counts. Separate
command products rather than retaining the union of all command needs.

## Classification Rules

Use four explicit outcomes:

```text
Keep
  The later phase consumes the complete value as semantic input.

Project
  A smaller exact table/value is constructed before the old owner dies.

Conditional sidecar
  A requested debug/profile mode retains a bounded projection; normal compile
  does not pay for it.

Release
  No later consumer exists after successful codegen admission.
```

“Might be useful,” “the type is already available,” and “shared by COW” are not
valid reasons to keep a field. Conversely, deleting source names globally is
not a goal: keep one exact display/source catalog when a named later consumer
requires it.

## First Slice Target

The current private `core_lowering_input` already projects the smaller value
shape required by `prepare_core_graph`. The missing property is lifetime:
`lower_typed_frontend_compilation` unwraps `TypedFrontendCompilationRep`, calls
`prepare_core_graph`, then reads policy fields from the representation.

Introduce a bounded preparation result that contains `CoreLoweringInput` plus
the exact early-Core policy fields needed after lowering. Its constructor is
the final reader of `TypedFrontendCompilationRep`. A separate function accepts
only that result and invokes `prepare_core_graph`:

```blorp
private record PreparedCoreLoweringRequest {
	input: CoreLoweringInput,
	policy: PreparedEarlyCorePolicy
}

private pure func prepare_core_lowering_request(
	typed: TypedFrontendCompilation,
) -> Result[PreparedCoreLoweringRequest, List[String]]

private pure func lower_prepared_core_request(
	request: PreparedCoreLoweringRequest,
) -> Result[LoweredCoreCompilation, List[String]]
```

Exact names may change, but `lower_prepared_core_request` must be unable to
reach `TypedFrontendCompilation`, `TypecheckedGraph`, or the source graph. The
slice is incomplete if the caller, a closure, or a wrapper keeps the old owner
live while Core runs.

## Implementation Milestones

### 1. Static Last-Use Inventory

Trace constructors and consumers with bounded `rg` searches and record exact
function names. Include ownership through wrapper records, closures, results,
and observations—not only direct field reads. Confirm the matrix against
compile/run/test and the optional summary/dump/profile paths.

Deliverable: every field is classified; disputed or unknown rows block release
but not completion of the inventory.

### 2. Boundary Liveness Instrumentation

Add the proposed
`benchmarks/compiler_codegen_input_lifetime` harness with deterministic
counters or uniqueness/liveness probes at:

1. accepted frontend completion;
2. immediately after `CoreLoweringInput` projection; and
3. immediately before and after `prepare_core_graph`.

Its schema must include workload hash, compiler/binary hash, the uniqueness or
reachability of the `TypedFrontendCompilation`/`TypecheckedGraph` owner at each
boundary, retained typed/parsed node and byte counts, duplicate complete
program roots, Core nodes, elapsed window, and output hashes. Keep measurement
output opt-in and stable so normal diagnostics do not change. Label these
counters as structural retained-data proxies unless they directly measure heap
reachability.

### 3. Establish The Pre-Core Owner Boundary

Use the `PreparedCoreLoweringRequest` split above as the first vertical release
slice. It should let the broad typechecked owner die before Core without
changing which raw typed programs Core consumes. This is deliberately smaller
than Phase 10 and should be output-identical.

The slice must:

- introduce the exact smaller projection, if one is required;
- cut one production consumer to it;
- end the old owner's scope before `prepare_core_graph`;
- delete the old access path; and
- prove a lower retained-node/byte count at Core entry.

### 4. Hand Off The Proven Matrix

Update Phase 10 with the verified matrix, counter schema, and boundary result.
Rows classified `Project` or `Conditional sidecar` become Phase 10 inputs.
Rows classified `Release` identify the old fields/accessors Phase 10 should
delete when its prerequisites are authoritative. This issue does not construct
`CheckedGraph`/`CodegenReadyGraph`, migrate commands, or delete the dual typed
programs.

## Tests And Measurement

Create focused fixtures for:

- accepted multi-module compile with CTFE and imports;
- bodyless dependencies;
- rejected/recovery modules used by check and LSP but forbidden from Core;
- source includes and foreign link metadata;
- requested typed/Core summaries and observations;
- late invariant diagnostics with exact source location;
- profile labels and leak/debug names; and
- compile/run/test output identity.

For each release slice compare:

| Metric | Role | Requirement |
| --- | --- | --- |
| Retained parsed/typed nodes at Core entry | Primary | Lower by the removed owner |
| Retained source/display bytes | Primary | Lower or explicitly sidecar-owned |
| Duplicate complete program roots | Primary | Eventually one, then zero at Core boundary where possible |
| Allocation calls/bytes | Outcome | Lower or neutral |
| Peak RSS | Outcome | Lower; investigate any increase |
| Retired instructions | Guard/outcome | Lower or within roadmap threshold |
| Frontend/Core/backend latency | Guard | No material regression |
| Core/C hashes and runtime output | Correctness | Identical for representation-only slices |
| Check/lint/LSP diagnostics | Correctness | Exact deterministic match |

Start with one warmup and three alternating baseline/candidate pairs through
the new harness. Expand to five only to resolve a decision-changing noisy
metric. Store raw evidence under `benchmarks/results/`; include source revision,
binary hash, workload hash, execution order, and counter schema. Use direct
counters as the primary fast loop and production peak RSS as confirmation.

Run the owning focused typecheck/Core suites after each slice, then compiler,
Core sanitizer/leak, CLI, lint/LSP (when touched), package/foreign, codegen
audit, and `git diff --check` gates before merge.

## Acceptance Criteria

- The consumer/lifetime matrix covers every field reachable from the compile
  plan, typechecked graph/modules, and Core-lowering input through Core entry.
- Every released field has no late consumer, or an explicit smaller projection
  with tests for every conditional consumer.
- `prepare_core_graph` runs in a function/scope that cannot reach
  `TypedFrontendCompilation`, `TypecheckedGraph`, or the source graph.
- The current raw typed-program inputs remain behaviorally unchanged; their
  replacement is explicitly left to Phase 10.
- Source locations, ABI/build metadata, program literal data, and requested
  human-facing labels remain exact through their documented last use.
- The old owner becomes unreachable before Core according to the harness's
  direct owner/reachability signal; a wrapper around the old graph does not
  qualify.
- Deterministic retained-node/byte counters improve, production peak memory
  trends down, and no roadmap regression threshold is crossed.
- Representation-only slices preserve Core/C hashes, runtime behavior, and
  command diagnostics.

## Stop Conditions And Non-Goals

- Do not infer last use from field names or current happy-path control flow.
- Do not discard a table before its exact later projection exists.
- Do not move check/lint/LSP onto a codegen-only product.
- Do not introduce `CheckedGraph` or `CodegenReadyGraph` here; Phase 10 owns
  both products.
- Do not combine this work with ID compaction inside Core; Roadmap Step 9 owns
  that later measured migration.
- Stop and request design guidance for any field whose later semantic need
  cannot be represented without pulling the broad frontend owner across Core.
