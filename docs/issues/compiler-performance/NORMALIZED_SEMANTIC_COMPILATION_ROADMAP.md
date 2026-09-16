# Normalized Semantic Compilation

**Status:** Active. The accepted semantic catalog, Step 2e visibility
convergence, Step 3 body-outcome completion, Step 4A solved-body/session
boundary, and Steps 7A–7B are in production. Later product completion remains
sequenced below.

**Current state:** The compilation has graph-local `ModuleId`, `DefinitionId`,
category-safe accepted tables, and an `AcceptedSemanticCatalog` with checked
provenance. `ModuleView` has one scope-issued bound occupancy/candidate owner;
accepted imports share its exact `ModuleId`/`DefinitionId` payload column and
accepted alias/union construction no longer regroups by path or spelling. A validated `BodyOutcomeTable`
survives CTFE handoff, including empty partial tables for bodyless dependencies;
ordinary materialization requires a `CompleteBodyOutcomeTable` with exact
coverage, compatible `main` validation policy, and explicit source order. The broad
`TypecheckedGraph` and late Core name projection remain. Each
`TypecheckedModule` now owns one source-faithful `TypedProgram` plus sparse
parsed/typed initializer replacements keyed by graph-issued definition ID;
Core consumes those rows directly without constructing or retaining a second
complete program. Graph import binding now batches admission under one
scope-local builder and publishes explicit accepted/rejected candidate rows.
`IndexedGraph` now owns compact
module-scoped selective export demand, and downstream import/type-fact paths
consume its `ModuleId`/`DefinitionId` facts instead of rebuilding graph-wide
name unions and path-to-surface joins.

**Next actions:** Step 2e is complete; use its
[completion screen](../../../benchmarks/results/compiler_step2e_visibility_completion_2026-09-14.md)
as the visibility baseline. Step 3 is also complete; use its
[completion screen](../../../benchmarks/results/compiler_step3_body_outcome_completion_2026-09-15.md)
and [implementation packet](145-step3-complete-body-outcome-publication.md)
as the body-product baseline. Step 4A is complete via the
[session-owned meta completion packet](141-step4a-meta-session-issuer-preflight.md).
Step 7A is complete via the
[keyed CTFE replacement completion packet](146-step7a-keyed-ctfe-replacements.md).
Step 7B is complete via the
[last-use and release packet](137-codegen-input-last-use-and-release.md): the
compile command now drops its rich frontend owner before Core and the retained
measurement shows a 17.0 MB net allocator release before Core begins.
Proceed to Step 9's compact Core and C identities.

**Read first:** [Compiler Architecture](../../ARCHITECTURE.md#frontend),
[Compiler Priorities](../../COMPILER_PRIORITIES.md#1-finish-the-typechecking-product-boundaries),
the Step 2e issue, and the Phase 8–10 issues under `docs/issues/typechecking/`.

## Product Rules

1. One issuer owns each identity domain. Products exchanging IDs prove shared
   `ModuleTable`/`DefinitionTable` provenance before positional access.
2. One authoritative row or edge owns each semantic fact. A query index may
   accelerate it but cannot become a second independently reconstructed truth.
3. Builders append privately and publish immutable validated products. Reject
   duplicate, foreign-key, source-order, and acceptance-state violations at
   publication.
4. Accepted, rejected, and recoverable facts have distinct product types. A
   status Boolean or an empty error list is not codegen admission.
5. Expression trees may remain payloads. Flatten stable entities and reusable
   relations only where consumers and measurements justify it.
6. Source names, display strings, paths, and C symbols are boundary projections,
   not join keys when graph-issued identities exist.
7. Compile, check, lint, and LSP retain only products they actually consume.
   A new table must displace its superseded carrier or scan at cutover.
8. Diagnostics retain deterministic source order and exact semantic origins;
   a table-build or worklist order must not choose public output order.

## Execution Order

| Cut | First production consumer and exit condition |
| --- | --- |
| 2e visibility, complete | One phase-correct ordered candidate/accepted relation serves graph lookup. The [resource gate](94-step2e-visibility-convergence.md) is complete; displaced name dictionaries, the successful-only graph inventory, and accepted alias/union reconstruction paths are deleted. |
| 3 body outcomes, complete | CTFE and ordinary compilation read the same exact row. Direct ordinary rows, explicit source order, complete-body coverage, linear seed admission, and bodyless-module behavior are protected by the [completion packet](145-step3-complete-body-outcome-publication.md). |
| 4A solved/validated bodies, complete | [Phases 8 and 9](../../COMPILER_PRIORITIES.md#phase-8-constraint-solving-and-type-finalization) publish meta-free solved and accepted validated facts. Accepted bodies retain exact session-owned solver identity through validation; raw cross-session slots and unscoped meta issuance are rejected. Optional semantic-type interning remains a separate experiment. |
| 7A keyed CTFE, complete | One source-faithful typed program owns semantic bodies. Sparse initializer payloads are keyed by exact definition ID and consumed directly by Core; full evaluated programs exist only as transient presentation projections. See the [completion packet](146-step7a-keyed-ctfe-replacements.md). |
| 7B codegen-ready, complete | The compile command constructs an opaque accepted input and releases compile-only recovery/analysis state before Core. [Phase 10](../typechecking/phase-10-checked-codegen-graphs.md) owns the remaining raw typed-tree replacement; the [last-use and release issue](137-codegen-input-last-use-and-release.md) owns the proof and retained measurement. |
| 9 Core identities | Preserve IDs into one measured Core declaration/relation pass cluster at a time after 7B; do not wait for all tooling queries. This includes classifying ABI exposure, assigning exact nominal type/specialization IDs, and deriving compact internal C type/helper spellings from those IDs. |
| 5–6, 8, 7C analysis/final retirement | Add accepted call/dependency edges and required diagnostic ownership; publish source occurrences and optional explanations only for named tool consumers. Move check/lint/LSP queries, then delete the remaining broad graph. |

The compiler-latency path is **3 → 4A → 7A → 7B → 9**. Visibility and tooling
cuts proceed independently unless a Core-input audit names an exact missing
fact. A cut cannot merge a public empty table and promise a consumer later:
it must name the first production reader and the old path it deletes.

The [zero-copy callable-emission issue](136-zero-copy-callable-symbol-emission.md)
is complete. That independent backend-memory packet removed the duplicate
final-Core owner without changing semantic products or generated C, and did
not reorder the semantic critical path above. Its retained profile reports
zero reconstructed Core nodes; the opaque plan's compiler-checked payload owns
only symbol metadata and canonical-list rows, not a second Core root.

## Completed Step 3 Contract

The validated `BodyOutcomeTable` may be partial for a CTFE request; its type
alone does not claim all bodies have been checked. Ordinary compilation now
publishes one `CallableId`-keyed accepted/rejected outcome for each required
source body and refines it to `CompleteBodyOutcomeTable`, with source order
separate from scheduling order. Plan provenance, module ownership, duplicate
checks, `main` validation-policy compatibility, and valid empty tables for
bodyless dependencies remain enforced.
Generated C has one local row writer and publishes the table only after
insertion, avoiding a retained COW alias.

Bodyless, duplicate, missing, wrong-kind, recursive, method, default-method,
foreign, graphless, and shuffled-order fixtures protect the boundary. CTFE and
ordinary materialization share the row without a per-module outcome-list copy
or source-body recheck, and no scheduling choice changes public order or IDs.
The accepted resource screen characterizes the final slice as neutral: a
single exact-source point sample was favorable, but repeated nearby samples
did not reproduce a material instruction win. Allocations, peak, RSS, and
code-size changes remain below their guards. The slice is accepted because it
deletes the ordinary outcome-list replay and dictionary-order projection,
makes seed admission linear, and gives those products immediate consumers.

## Completed Step 4A Contract

One host-issued compilation run owns every solver session for an accepted
typecheck graph. Module, global, ordinary-body, selective-CTFE, and eager-CTFE
work project checked table-local owners into explicit session keys; eager
artifact-to-bound retry uses a distinct invocation. Semantic and dimension
metas carry the flat session-plus-slot payload, and solver operations reject a
foreign session before positional binding access. Accepted body, CTFE, and
Core products remain protected by meta-free finalization/validation.

The completion packet records focused identity, body-order, inference,
dimension, sanitizer, and retained-resource evidence. Its 1,024-body selected
CTFE scaling screen stayed within the allocation guard (+0.3715%) and retained
exactly one 64-byte object, matching the prior retention result. Step 7A may
therefore consume the validated body products without reconstructing solver
identity or preserving a raw-index compatibility path.

The optimized compiler worker is the explicit exception: it grew 2.14%, above
the 1% investigation guard. The completion investigation found diffuse text
growth from carrying and validating exact session identity, while the standard
screen improved retired instructions about 0.14%, kept allocation growth to
0.127%, and held peak-memory growth below 1%. This correctness trade is
accepted for 4A; subsequent size cleanup should deduplicate session-purpose
mapping and parallel body-attempt wrappers, then measure worker text directly.

## Measurement And Acceptance

Each packet states its current authority, target row/edge, first reader, old
carrier deleted, failing test, focused command, primary resource hypothesis,
and rollback decision. A baseline/candidate pair must preserve accepted and
rejected outcomes, exact identities, diagnostics, replay checksum, and C or
runtime behavior. A semantic mismatch invalidates its timing result.

Measure the affected phase and production replay with separate uninstrumented
timing and instrumented work/resource runs. Report median/p95 latency,
allocation calls/bytes, peak RSS and retained product bytes, retired
instructions, hashes/string materializations/traversals, product/generated-C
size, and tooling query cost when affected. Classify each as primary, guard,
or inapplicable *before* measuring. Investigate regressions beyond 2% median
latency, 5% p95, 0.5% allocations, or 1% peak memory/instructions/size; host
noise and an explicitly accepted measured trade are the only exceptions.
The combined checkpoint must improve a majority of applicable metric families
without a material guard regression. Neutral enabling slices must delete a
real old authority and have an immediate consumer.

Use clean matched baseline/candidate worktrees, warm and alternate runs, save
raw evidence in `benchmarks/results/`, and keep the first loop narrow:

```bash
scripts/compiler-check --stage typecheck
benchmarks/compiler_ctfe_typecheck_profile 3 24 32 retained
benchmarks/compiler_typecheck_profile 2 2 64 128 retained
```

Then run the owning compiler, sanitizer, leak, runtime, and LSP gates for the
changed boundary. Do not substitute a benchmark checksum for correctness
tests. The exact production pipeline is in [Architecture](../../ARCHITECTURE.md);
this issue tracks only not-yet-authoritative semantic products.
