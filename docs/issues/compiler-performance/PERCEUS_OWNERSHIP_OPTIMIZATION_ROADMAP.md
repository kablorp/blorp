# Perceus Ownership Optimization Roadmap

**Status:** Tranches 0–3 implemented; Tranches 4–9 proposed

## Objective

Reduce the compiler work, generated C, runtime ownership bookkeeping, and heap
allocation attributable to ownership without weakening Blorp's value semantics,
deterministic destruction, copy-on-write behavior, or cancellation safety.

The work is deliberately split into two programs:

1. make the existing ownership result cheaper to calculate while preserving the
   exact current Core and C output; then
2. use explicit ownership, cancellation, provenance, and escape facts to prove
   that selected runtime operations or allocations are unnecessary.

Every tranche must provide value independently. The roadmap does not require a
wholesale Perceus replacement before any improvement reaches production.

## Executive Decision

Do not attempt to decide every lifetime during one forward syntax walk. Clear
Core data flow lets the compiler collect every direct fact in one pass per
function, but recursive calls still require a fixed point and definite
termination often needs information flowing backward from uses.

The intended steady-state pipeline is:

```text
ownership-ready Core
        |
        v
one declaration/catalog scan
        |
        v
one direct-fact collection per function
        |
        +-- exact local values and use sites
        +-- parameter-flow equations
        +-- aliases, transfers, escapes, and direct effects
        +-- structured branch/repetition regions
        |
        v
graph fixed points over compact facts, never over Core bodies
        |
        v
one ownership plan per function
        |
        v
one mechanical DupExpr/DropExpr materialization
        |
        v
reuse -> closure -> resource -> fairness -> prepare -> prepared reuse
        |
        v
late cancellation-cleanup plan -> C symbol projection -> C emission
```

This interpretation makes "one walk" useful and precise: syntax is collected
once rather than rescanned once per value or once per fixed-point wave. Planning
and materialization remain separate so analysis facts do not become public Core
IR metadata.

## Why This Work Is Plausibly Valuable

### Current compiler structure

The current implementation contains several multiplicative scans:

- `infer_user_contract` in
  `blorp/src/compiler/stage_09_core/perceus.brp` scans a complete body once for
  each managed parameter. Contract worklist waves invoke inference again for
  affected callers.
- `rewrite_function` separately rewrites borrowed calls, borrowed aggregate
  transfers, borrowed results, referenced globals, owned result aliases,
  lexical balancing, and consumed parameters.
- several borrowed-value rewrites run once per parameter or referenced global;
- `OwnershipUseSummary` answers a query for one target value, so the same
  branch or subtree is summarized repeatedly for different owners;
- unsupported scalar summary cases can fall back to the independent
  `count_uses` traversal; and
- the backend scans let bodies per binding through
  `body_consumes_var_before_suspension`, `let_body_takes_cleanup_ownership`, and
  `body_consumes_var` before emitting cancellation cleanup.

The current source already demonstrates that all-value analysis is feasible.
`PerceusResolvedValueIndex` collects exact resolved-value information while the
main insertion traversal is active. The missing step is making one exhaustive,
phase-owned fact product authoritative instead of using it beside scalar
queries and repeated rewrites.

### Existing performance evidence

The following evidence establishes opportunity, not a current-main promise:

| Evidence | Observation | Limitation |
| --- | ---: | --- |
| 2026-08-26 production-shaped profile | Stage 09 was 34.68% of total compiler time | Several unrelated Core optimizations have landed since |
| Same profile | `summarize_linear_ownership_uses` alone held 1.11% of total samples | Sample attribution understates callers and reconstruction |
| 2026-08-13, 32 managed parameters | Narrow simple-balance path reduced isolated time from about 0.212 s to 0.107 s | Synthetic linear body only |
| Local generated compiler C census at `0e25482b` | 97,684,567 bytes and 1,378,578 lines | Orientation only; the generated file is not a durable benchmark artifact |
| Same local census | 48,720 `blorp_retain(`, 72,102 `blorp_release(`, and 2,200 `blorp_release_arc_only(` occurrences | Includes runtime source and cold paths; requires producer attribution |

The simple-balance result is especially relevant: avoiding repeated
parameter-oriented scans can halve work on the exact shape it recognizes. The
roadmap generalizes the scaling property rather than adding more shape-specific
shortcuts.

The local C census above can be reproduced after building the compiler with:

```bash
wc -c -l blorp/build/_build/blorp-cli/blorp_cli_main.c
rg -o 'blorp_retain\(' blorp/build/_build/blorp-cli/blorp_cli_main.c | wc -l
rg -o 'blorp_release\(' blorp/build/_build/blorp-cli/blorp_cli_main.c | wc -l
rg -o 'blorp_release_arc_only\(' blorp/build/_build/blorp-cli/blorp_cli_main.c | wc -l
```

Do not compare later output to these counts as though they were a controlled
baseline. Tranche 0 records a clean, reproducible artifact and separates
embedded runtime definitions from generated program statements.

### What definite termination does and does not prove

A definite endpoint does not by itself remove lifetime management. At a final
use, a managed value must normally do exactly one of the following:

```text
release      destroy the owned value
transfer     move the owned reference into a consuming destination
return       transfer it to the caller under the return contract
remain live  hand it to a cancellation/resource owner
disappear    only when the allocation itself was proven unnecessary
```

The early tranches therefore remove repeated *compiler reasoning*. Later
tranches use provenance to distinguish a release, a transfer, immortality, and
allocation elimination.

## Normative Constraints

The implementation must preserve the ownership ABI in
[`docs/OWNERSHIP_MODEL.md`](../../OWNERSHIP_MODEL.md). In particular:

1. local ownership identity is exact `CoreVar` identity, never spelling alone;
2. global and callable identity includes the exact definition identity;
3. a source copy may borrow only while a proven owner remains live;
4. ARC operations may affect COW uniqueness and are not generally cancellable
   as an adjacent retain/release peephole;
5. cancellation is a nonlocal exit and must be represented in lifetime facts;
6. dynamically constructed strings are mortal managed allocations, while
   `StaticStringLiteralExpr` values are artifact-lifetime immortal data;
7. other phases also produce `DupExpr` and `DropExpr`; and
8. reuse may consume a `DropExpr` as its proof that a record owner is dead.

The roadmap concretizes the ownership priorities already recorded in
[`docs/COMPILER_PRIORITIES.md`](../../COMPILER_PRIORITIES.md): exact ingress,
one-time fact collection, exhaustive summaries, explicit repetition,
consolidated borrowed normalization, a narrow ownership catalog, and only then
structural decomposition.

## Intended Internal Model

The examples in this document describe internal types and APIs. Exact field
names may change during implementation, but the represented distinctions must
not be collapsed into booleans or name-based heuristics.

### Exact program catalog

`PerceusEnv` currently mixes immutable program facts with function-local rewrite
configuration. Move immutable lookup products into a catalog only as a real
consumer is cut over:

```blorp
opaque type OwnershipValueId = Int
opaque type OwnershipSiteId = Int
opaque type OwnershipCallableId = Int

record OwnershipCallableEntry {
	id: OwnershipCallableId,
	identity: CoreDefinitionIdentity,
	contract: List[Int]
}

record OwnershipCallableIndex {
	entries_by_id: List[OwnershipCallableEntry],
	candidate_ids_by_name: Dict[String, List[OwnershipCallableId]]
}

record OwnershipConstructorEntry {
	name: String,
	callable_spelling_aliases: List[String],
	parent_type_name: String,
	def_id: Option[Int],
	contract: Option[OwnershipCallContract],
	is_nullary: Bool
}

record OwnershipConstructorIndex {
	entries_by_id: List[OwnershipConstructorEntry],
	candidate_ids_by_spelling: Dict[String, List[Int]],
	candidate_ids_by_def_id: Dict[Int, List[Int]],
	candidate_ids_by_parent_name: Dict[String, List[Int]]
}

record OwnershipGlobalEntry {
	value: CoreParam,
	is_mutable: Bool
}

union OwnershipGlobalLookup:
	UniqueOwnershipGlobal(Int, Int)
	CollidingOwnershipGlobals(Dict[Int, Int])

record OwnershipGlobalIndex {
	entries_by_id: List[OwnershipGlobalEntry],
	lookup_by_name: Dict[String, OwnershipGlobalLookup]
}

record OwnershipCatalog {
	managed_types: ManagedTypeIndex,
	callables: OwnershipCallableIndex,
	constructors: OwnershipConstructorIndex,
	globals: OwnershipGlobalIndex
}

record PerceusFunctionContext {
	catalog: OwnershipCatalog,
	return_type: CoreType,
	infer_unresolved_user_calls_as_borrow: Bool,
	transferable_result_vars: List[CoreVar]
}
```

Exact `CoreDefinitionIdentity` is stored or encoded in each compact entry, but
it is not used as a `Dict` key because it does not currently implement the
required dictionary key traits. Name lookup first retrieves candidate dense
IDs, then compares the candidate entry's complete `(name, def_id)` identity.
Specialized functions may retain the same `def_id` while their names and
contracts differ. The catalog retains compact metadata, not complete
`CoreFunction`, `CoreGlobal`, or expression bodies.

`OwnershipValueSet` in later signatures names a required phase-private
abstraction whose concrete representation is selected and documented in
Tranche 0. It may be a small ordered sparse set, a dense stamped set, or an ID
into an arena. An arena implementation must thread its state explicitly under
Blorp value semantics, for example:

```blorp
record OwnershipValueSetState {
	ordered_members_by_set_id: List[List[OwnershipValueId]],
	next_set_id: Int
}

record OwnershipValueSetResult {
	state: OwnershipValueSetState,
	set_id: Int
}
```

It must not imply hidden shared mutation. Tranche 1 introduces the concrete
`OwnershipValueSet` type chosen by the Tranche 0 scaling measurements.

Ownership ingress does not currently guarantee a definition ID for every
payload constructor. Until a separate ingress change establishes that
invariant, constructor lookup must preserve the current fallback: narrow by
result `parent_type_name` and callable spelling, then validate `def_id` when it
is present. `callable_spelling_aliases` includes the source and projected C
spellings currently registered by `build_env`. Global entries retain the
existing compact `CoreParam`, including exact `CoreVar`, type, and source
location, so ownership materialization remains byte-identical.

The catalog must be built in one declaration traversal. It replaces the extra
function/constructor captures in `build_env` and the linear nullary-constructor
lookup, but it must not become a permanent cache containing unused facts.

### Direct contract equations

Record parameter flow once while visiting the function body:

```blorp
record ParameterFlow {
	caller: OwnershipCallableId,
	caller_parameter_index: Int,
	callee: OwnershipCallableId,
	callee_argument_index: Int
}

record ReverseParameterFlow {
	caller: OwnershipCallableId,
	caller_parameter_index: Int
}

record FunctionContractEquation {
	function: OwnershipCallableId,
	directly_consumed_parameters: List[Int]
}

-- Collection-local only; forward flows are released after graph construction.
record CollectedContractEquation {
	equation: FunctionContractEquation,
	user_call_flows: List[ParameterFlow]
}

record OwnershipContractGraph {
	equations_by_callable_id: List[FunctionContractEquation],
	reverse_flows_by_callee_and_argument: List[Dict[Int, List[ReverseParameterFlow]]]
}
```

The solver propagates facts through edges rather than asking the caller's Core
body the same question again:

```text
when parameter i of callee becomes consuming:
    for each flow in reverse_flows[callee][i]:
        if the caller parameter is not already consuming:
            mark contracts[flow.caller][flow.caller_parameter_index] consuming
            enqueue edges depending on that caller parameter
```

The graph is finite and facts grow monotonically, so recursion converges. The
current public result is name-keyed. Tranche 1 must cut it over to dense
callable IDs plus exact candidate validation; otherwise specialized identities
remain ambiguous. A temporary name-directed adapter is acceptable only inside
the tranche while parity is measured, and must be deleted before landing.

### Values, sites, and structured regions

Assign dense local IDs once from exact `CoreVar` identity. A name index may
narrow candidates, but final resolution must compare exact identity.

```blorp
union OwnershipValueOrigin:
	BorrowedParameterOrigin(Int)
	BorrowedGlobalOrigin(CoreDefinitionIdentity)
	FreshOwnedOrigin
	OwnedMatchOrigin
	BorrowedMatchOrigin(OwnershipValueId)
	ImmortalOrigin

record OwnershipValue {
	id: OwnershipValueId,
	variable: CoreVar,
	typ: CoreType,
	origin: OwnershipValueOrigin
}

union OwnershipUseKind:
	BorrowUse
	ConsumeUse
	TransferUse
	ReturnUse
	InvalidateUse

record OwnershipOccurrence {
	site: OwnershipSiteId,
	value: OwnershipValueId,
	kind: OwnershipUseKind
}

union OwnershipRegionKind:
	LinearRegion
	BranchRegion
	RepeatedRegion
	CleanupRegion

record OwnershipRegion {
	id: Int,
	kind: OwnershipRegionKind,
	parent: Option[Int],
	child_regions: List[Int],
	occurrences: List[OwnershipOccurrence]
}
```

Deterministic site IDs are assigned in Core traversal order. A later
materializer walks the unchanged body in the same order and consumes actions
for each site. The public Core representation does not need analysis fields.

### Facts and plans

One value can carry more than one reference obligation, and different exits
from the same region may release, transfer, return, or preserve those
references. Facts are therefore recorded per region and exit rather than as
one termination label per value:

```blorp
union OwnershipExitDisposition:
	LiveAfterRegion(Int)
	ReleasedAtSite(OwnershipSiteId)
	TransferredAtSite(OwnershipSiteId)
	ReturnedAtSite(OwnershipSiteId)
	EscapedAtSite(OwnershipSiteId)
	UnusedOnExit

record OwnershipRegionExitFact {
	exit_site: OwnershipSiteId,
	remaining_references: Int,
	disposition: OwnershipExitDisposition
}

record OwnershipRegionDemand {
	region_id: Int,
	required_entry_references: Int,
	produced_references: Int,
	consumed_references: Int,
	exits: List[OwnershipRegionExitFact]
}

record OwnershipValueFacts {
	region_demands: List[OwnershipRegionDemand],
	aliases_owner_ids: List[OwnershipValueId],
	cancellation_sites_crossed: List[OwnershipSiteId],
	escapes_function: Bool
}

union PlannedOwnershipReason:
	LexicalFanoutOwnership
	BorrowedCallOwnership
	AggregateTransferOwnership
	ReturnAliasOwnership
	RepeatedRegionOwnership
	BranchBalanceOwnership
	MatchPayloadOwnership

union PlannedOwnershipTarget:
	NamedOwner(CoreVar)
	EvaluatedSiteResult(OwnershipSiteId, CoreVar)

union PlannedOwnershipAction:
	PlannedRetain(
		PlannedOwnershipTarget,
		CoreType,
		CoreRetainPolicy,
		PlannedOwnershipReason,
	)
	PlannedRelease(CoreVar, CoreType, CoreReleasePolicy, PlannedOwnershipReason)
	PlannedStabilizeAndOwnResult(
		OwnershipSiteId,
		CoreVar,
		CoreType,
		CoreRetainPolicy,
		PlannedOwnershipReason,
	)

record OwnershipSiteActions {
	before: List[PlannedOwnershipAction],
	after: List[PlannedOwnershipAction]
}

record FunctionOwnershipPlan {
	values: List[OwnershipValue],
	facts_by_value_id: List[OwnershipValueFacts],
	actions_by_site_id: List[OwnershipSiteActions]
}
```

The two final lists are dense tables indexed by their corresponding integer ID,
not dictionary maps. `PlannedStabilizeAndOwnResult` directs materialization to
wrap the expression at its site in one synthetic `BorrowLetExpr`, then retain
the resulting temporary. It represents the current evaluate-once behavior for
a computed result that might borrow different owners along different paths.

Provenance on planned actions is required for later simplification. Two
structurally adjacent operations are not necessarily redundant: a temporary
retain can deliberately make a COW value non-unique before a consuming call.

### Avoid an allocation-heavy analysis replacement

Do not return a persistent `Dict[OwnershipValueId, Summary]` from every leaf and
merge it at every parent. That can replace repeated AST scans with millions of
persistent-map allocations.

Prefer:

- a dense table for function-local values;
- mutable accumulators while walking straight-line regions;
- a trail or touched-ID list for branch snapshots and rollback;
- sparse materialization only at joins, repeated regions, and scope exits; and
- compact graph equations for interprocedural fixed points.

## Measurement Model

### Required counters

Add profiling-only counters before changing production behavior:

```blorp
record PerceusWorkMeasurement {
	program_declaration_visits: Int,
	function_body_collection_visits: Int,
	expression_node_visits: Int,
	scalar_summary_requests: Int,
	contract_equation_steps: Int,
	resolved_value_queries: Int,
	borrowed_origin_set_inserts: Int,
	borrowed_origin_set_merges: Int,
	borrowed_origin_members_visited: Int,
	borrowed_origin_storage_slots: Int,
	reconstructed_nodes: Int,
	planned_retains: Int,
	planned_releases: Int,
	materialized_retains: Int,
	materialized_releases: Int
}
```

The final ownership census must also count:

- `DupExpr` and `DropExpr` by policy;
- ownership nodes by producing phase;
- cleanup pushes, pops, and duplicate-slot updates;
- managed values by origin and terminal outcome;
- owners whose lifetimes cross a cancellation point; and
- allocation candidates rejected by each escape reason.

Runtime-changing tranches need executed-operation evidence as well as static C
counts. Add a benchmark-only native build mode, disabled in ordinary builds,
that counts entries to `blorp_retain`, `blorp_release`,
`blorp_release_arc_only`,
`blorp_task_cleanup_push`, `blorp_task_cleanup_pop_slot`, and
`blorp_task_cleanup_duplicate_slot`. Counters must be thread-safe because the
relevant fixtures include tasks. Use the instrumented binary for operation
counts only and a separate counter-disabled binary for timing; atomic counter
overhead must never be included in runtime speed claims.

Stack-result retain/release wrappers delegate to the underlying ownership
operations and are attributed there. If a wrapper bypasses those functions in
the current implementation, give it its own counter rather than silently
omitting it.

Counters, artifact hashes, elapsed time, peak RSS, revision, compiler binary,
C compiler, flags, and fixture checksum belong in durable benchmark results.
The existing harness already reports elapsed time, RSS, and optional `vmmap`
allocation count; Tranche 0 must extend its JSON result for the new logical
counters before any later tranche depends on them.

### Benchmark shapes

Extend `benchmarks/compiler_perceus_memory` rather than introducing a parallel
harness unless it cannot expose the required counters. In addition to the
existing managed-parameter matrix, add independently selectable bodies:

```text
linear
branch
constructor_match
loop
nested_user_call
mutually_recursive_calls
borrowed_return
aggregate_escape
referenced_global
lambda_borrowed_boundary
borrowed_boundary_fusion
task_and_select
```

Vary only one primary axis at a time:

- managed parameters or borrowed owners: `1, 8, 32, 128`;
- body nodes: `32, 128, 512`;
- distinct user-call edges per function: `1, 8, 32` (use at least 33
  mutually recursive functions so no repeated call site is counted as a new
  graph edge);
- branch or match arms: `2, 8, 32`; and
- referenced globals: `0, 8, 32`.

The existing runner's default window is not Perceus alone:
`run_perceus_stage` includes consume specialization, record-update lowering,
dictionary ownership preparation, and Perceus. Name that window
**ownership-preparation plus Perceus** in reports. Tranche 0 must additionally
add a worker action that performs those prerequisites outside its measured
window and times/counters the direct `CorePerceus.insert_drops_program` call.
That direct action is for generated fixtures; the controlled compiler
self-check below supplies the production-shaped net measurement.

Use paired baseline/candidate workers in alternating order with identical
artifacts. Seven warmed samples are the default timing set. Counter changes,
not noisy process or Core JSON time, are the primary fast proof.

### Forecasts versus acceptance gates

Rows not yet implemented are prioritization hypotheses rather than
production-current promises. Every row is relative to its immediate parent;
the cumulative statement following the table is relative to Tranche 0. The
Tranche 4 rows are stricter issue-level landing gates: their deliberately
dominant fixed-shape fixtures must expose an observable gain before the change
can merge. Production self-compilation percentages remain measurements, not
promises, because earlier tranches change the remaining Perceus denominator.

| Tranche | Direct work expected to disappear | Targeted benchmark forecast | Production self-compilation forecast |
| --- | --- | ---: | ---: |
| 0: census | None | Instrumented runs may be 1–5% slower | Production mode must be unchanged |
| 1: contract equations | Per-parameter body scans and per-wave body rescans | 30–70% faster contract-heavy Perceus fixture | 3–10% of Perceus time; whole-compiler effect likely below 2% |
| 2: all-owner call protection | One body reconstruction per borrowed owner | 15–40% faster owner-rich fixture | 2–8% of Perceus time |
| 3: all-owner aggregate protection | Another reconstruction per borrowed owner | 10–30% faster aggregate-heavy fixture | 1–5% of Perceus time |
| 4A–C: results, globals, and lambdas | Per-owner terminal walks and per-owner rewrite triples | At least 15% faster on each 32-owner focused fixture | Rebaseline after each issue; no percentage promised |
| 4D: borrowed-boundary fusion | Three overlapping all-owner reconstruction passes | At least 10% faster on the overlapping fusion fixture | Reprofile after fusion; no percentage promised |
| 5: all-value facts | Repeated scalar summaries and occurrence fallbacks | 20–50% faster branch/match/repetition fixtures | 8–25% of Perceus time |
| 6: plan/materialize | Per-value balancing rewrites and most repeated reconstruction | 25–60% faster complex ownership fixtures | 15–35% of Perceus time |
| 7A: cleanup-plan parity | Per-binding emitter body scans | 50–90% fewer relevant node visits | 2–8% of backend emission time |
| 7B: cancellation effects | Cleanup registration in proven noncancelling functions | Proportional to managed binding count in eligible functions | Unknown until census establishes eligible fraction |
| 8: plan simplification | Proven redundant ARC actions and associated cleanup updates | Exact operation-count reduction per rule | Feature-frequency dependent |
| 9: scalar replacement | Container allocation and its entire ownership interval | Near-total container allocation removal in eligible fixture | Escape-pattern frequency dependent |

The kind of improvement also changes at explicit boundaries:

| Completion point | Compiler work | Generated C | Executed ownership work | Heap allocations |
| --- | --- | --- | --- | --- |
| Tranche 0 | Measurement overhead only | Unchanged | Unchanged | Unchanged |
| Tranches 1–4 | Less contract and borrowed-boundary work | Byte-identical | Identical | Identical |
| Tranches 5–6 | Less summary, balancing, and reconstruction work | Byte-identical | Identical | Identical |
| Tranche 7A | Less backend ownership analysis | Byte-identical | Identical | Identical |
| Tranche 7B | Small effect-analysis cost | Fewer cleanup statements | Fewer cleanup-stack/TLS operations | Identical |
| Tranche 8 | Small plan-simplification cost | Fewer proven ARC/cleanup statements | Fewer targeted ARC/cleanup operations | Normally identical |
| Tranche 9 | Escape-analysis cost, offset by less later ownership work | Smaller eligible functions | No container ARC interval | One fewer allocation per accepted container |

The cumulative output-preserving target after Tranche 6 is a 25–50% reduction
in Perceus time on ownership-heavy fixtures and a measurable reduction on
compiler self-compilation. No whole-compiler percentage is a landing condition:
Perceus' current-main share must be measured first, and a strong isolated
improvement can legitimately be diluted by parsing, typechecking, other Core
passes, C emission, and the host C compiler.

## Tranche 0: Establish Current-Main Work And Output Baselines

### Implemented measurement boundary

Tranche 0 uses debug-erased function-profile markers rather than threading a
measurement record through the 19,000-line pure pass or maintaining a shadow
estimator. The separately configured `--debug --profile` worker reports exact counts
for operations that exist today: contract analyses and equations, scalar-summary
requests and visits, legacy count visits, borrowed-call/aggregate/result walks,
resolved-value queries, insertion visits/rebuild actions, and rewritten declarations.
The ordinary timing worker contains none of these marker calls. Blorp does not
currently have a profile-only source construct, so the narrowest available
compile-time boundary is `debug:`/`@debug_only`: arbitrary debug builds contain
the markers, while timing and production builds erase them completely. The
benchmark's dedicated counter worker always combines `--debug --profile` and
invokes marker registration only after opening the profile window.

Prospective counters for origin-set storage, planned actions, cancellation
crossings, and escape rejection remain intentionally absent until the tranches
that introduce those concepts. Reporting them as zero now would confuse “the
mechanism does not exist” with “the mechanism performed no work.” Runtime ARC
counters are likewise deferred until Tranche 7B/8 because the present harness
transforms Core without executing the emitted program.

The initial body catalog contains `linear`, `nested_user_call`, and
`mutually_recursive_calls`, which are the shapes consumed by Tranche 1. The
remaining shapes listed above enter with their first consuming tranche. This
keeps each generated Core shape covered by the production decoder and Perceus
before it becomes permanent benchmark surface.

### Change

Add the current-mechanism counters and the body shapes consumed by the next
tranche; extend both catalogs at each later mechanism boundary. Record:

1. the existing ownership-preparation-plus-Perceus worker window;
2. the new direct Perceus-only worker window;
3. backend-emission timing;
4. ownership-ready, post-Perceus, post-reuse, and prepared-Core event counts;
5. generated C ownership and cleanup statements; and
6. compiler self-compilation through Perceus and through C emission outside
   the worker.

Instrumentation must be compiled away from ordinary timing and production
builds. Adding a general profile-only language construct is outside the scope
of this ownership diagnostic.

### Independent value

This creates a permanent diagnostic that distinguishes algorithmic work from
wall-time noise and distinguishes Perceus ownership nodes from closure,
resource, collection, reuse, and backend cleanup behavior.

### Acceptance criteria

- A failing counter/fixture test is added before instrumentation.
- Every counter for a mechanism implemented at the current checkpoint is
  deterministic for a fixed artifact; future-mechanism fields are absent, not
  synthetic zeros.
- Counter-disabled output is byte-identical to the baseline.
- The benchmark varies parameters independently from body size and adds each
  later body shape with the first tranche that consumes it.
- Paired runs reject artifact-hash mismatches.
- Seven-sample baseline results are saved under `benchmarks/results/`.
- Reports label both measurement windows accurately and do not attribute
  prerequisite or Core JSON costs to Perceus.
- Work counters are available in paired JSON results; `vmmap` allocation count
  remains diagnostic rather than a hard paired-memory gate.
- The ordinary timing worker and counter-disabled production mode contain no
  work-counter marker symbols. The first optimizing tranche performs the clean,
  paired parent/candidate instruction comparison; Tranche 0 has no production
  ownership-algorithm change to compare.

### Reproducible production self-compilation

Tranche 0 records single-run production-shaped smokes because it changes no
production ownership algorithm and cannot be its own clean parent/candidate
pair before it is committed. Beginning with Tranche 1, every optimizing tranche
must use this reproducible paired protocol:

1. Build isolated control and candidate worktrees from the common parent and
   candidate revisions with `make -B build-blorp-cli`.
2. Create an explicit temporary output directory in each worktree:

   ```bash
   perceus_measurement_dir=$(mktemp -d "${TMPDIR:-/tmp}/blorp-perceus.XXXXXX")
   trap 'rm -r "$perceus_measurement_dir"' EXIT
   ```

3. Warm self-compilation stopped after Perceus by executing this command once
   with the `/usr/bin/time -lp` line omitted and a `warm-perceus.json` output.
   Then use the shown command for measured runs:

   ```bash
   /usr/bin/time -lp \
     blorp/build/_build/blorp-cli/blorp compile --no-format \
       --stop-after=perceus \
       --dump-core-file="$perceus_measurement_dir/perceus.json" \
       blorp/src/main.brp
   ```

4. Warm complete compiler C emission by executing this command once with the
   `/usr/bin/time -lp` line omitted and a `warm-compiler.c` output. Then use the
   shown command for measured runs:

   ```bash
   /usr/bin/time -lp \
     blorp/build/_build/blorp-cli/blorp compile --no-format \
       -o "$perceus_measurement_dir/compiler.c" \
       blorp/src/main.brp
   ```

5. Run three alternating control/candidate pairs for each command with no
   other compiler or benchmark process active. Use distinct control and
   candidate output names, compare their Perceus JSON and C artifacts with
   `cmp`, and record their hashes. An output mismatch blocks Tranches 0–7A.
6. Record all wall times, maximum RSS values, retired-instruction counts, and
   their medians. Maximum RSS is noisy and is reported, not compared with a
   synthetic paired 2% gate.

The candidate must retire no more instructions than its immediate parent in
the focused scalable fixture. For production self-compilation, stop for a clear
regression: all three candidate wall times above their paired controls by more
than 5%, or a repeatable retired-instruction increase not explained by the
profiling counters.

## Tranche 1: Collect User-Call Contract Equations Once

### Current shape

Conceptually, current inference does this:

```blorp
for parameter in managed_parameters(func_info):
	summary = summarize_function_return_ownership_uses(
		env,
		parameter.name.name,
		func_info.return_type,
		func_info.body,
	)
	if summary.consumed_refs > 0:
		mark_consuming(parameter)
```

Each worklist wave can repeat the loop after a callee contract changes.

### Target shape

```blorp
private pure func collect_function_contract_equation(
	catalog: OwnershipCatalog,
	func_info: CoreFunction,
) -> FunctionContractEquation

private pure func solve_user_call_contracts(
	graph: OwnershipContractGraph,
) -> List[List[Int]]
```

During collection, an expression can report all parameter aliases together:

```blorp
record ContractExprFacts {
	parameter_aliases: OwnershipValueSet,
	directly_consumed: OwnershipValueSet,
	deferred_user_call_flows: List[ParameterFlow]
}
```

`OwnershipValueSet` is an internal collection abstraction. It must not allocate
and copy a parameter list at every expression. Tranche 0 counters decide
between a dense stamped table and an ordered sparse representation; either
implementation must expose deterministic iteration and count inserts, merges,
members visited, and retained storage slots. `vmmap` supplies the independent
allocation-count and memory diagnostic.

Builtin, constructor, foreign, and known intrinsic contracts are resolved
immediately. Only user-call edges are deferred.

### Implementation sequence

1. Add exact callable identity and contract-equation types.
2. Build the minimum catalog needed to resolve those identities in one
   declaration pass.
3. Collect equations once per function body. A pre-closure `LambdaExpr` has no
   callable definition identity: collect its captures and local ownership in a
   nested lexical region, but do not add its body calls to the enclosing
   callable's contract equation. `ClosureBodyFunction` remains nonconsuming
   under the current inferred contract until a later, explicit ABI change;
   preserve the pre-existing direct-builtin-wrapper contract when present.
4. Add the graph solver beside the existing inference.
5. Compare every inferred contract on the maintained corpus.
6. Switch `infer_user_call_contracts` and its readers from name-keyed maps to
   the dense exact-identity contract table.
7. Delete the temporary name-directed adapter.
8. Remove the old body-rescanning inference before landing.

### Expected performance

For `P` managed parameters, `N` body nodes, and `W` contract waves, the relevant
syntax work changes from approximately `O(P * N * W)` to one `O(N)` collection
plus compact graph work. Each reverse flow is visited once, and each caller's
signature is scanned when that caller gains facts so consumed arguments retain
signature order. The strict solver term is therefore
`O(E + sum(updated caller arities))`, where `E` is the compact parameter-flow
edge count. A contrived caller that gains one parameter per wave can make the
signature-order term quadratic in its parameter count, but it never reopens
the caller's Core body.

The structural expectation is at least 75% fewer body-node visits at 32
parameters and no body-node growth across recursive fixed-point waves.

### Acceptance criteria

- Direct, transitive, recursive, and mutually recursive contracts match the
  baseline exactly.
- Specialized callables sharing a `def_id` retain distinct contracts.
- Contract collection visits every inferred function body with at least one
  managed parameter exactly once, regardless of the number of such parameters;
  zero-managed-parameter bodies are skipped. Functions containing incoming
  ownership nodes or unresolved-identity lexical shadowing are recorded as
  explicit scalar-compatibility equations after that visit.
- Fixed-point waves inspect only compact reverse edges and report actual wave,
  frontier-callable, edge-visit, and parameter-mark counts; they never inspect
  Core expressions for graph equations. Total and cause-specific counters
  report every scalar-compatibility analysis, and all must remain zero on
  ownership-ready benchmark inputs.
- At 32 managed parameters, contract-related node visits fall by at least 75%.
- The paired contract-heavy benchmark must not regress. Its realized median is
  recorded beside the Tranche 0 hypothesis; a result below timing noise is a
  stop/go signal, not grounds to ignore the structural improvement.
- Canonical ownership events, post-Perceus Core, and generated C remain
  byte-identical, including consumed-argument ordering across fixed-point
  waves.
- Direct contract counters must show that graph facts did not replace syntax
  visits with more retained slots or set operations. `vmmap` allocation count
  and maximum RSS are supporting diagnostics, not the structural gate.

## Tranche 2: Protect Borrowed Calls For All Owners At Once

**Implemented:** 2026-09-04. The implementation uses an ordered-min owner
semilattice rather than retaining complete origin sets. Call protection only
observes the earliest active owner: that owner determines the legacy synthetic
temporary name, and retaining the evaluated result makes it owned for every
later owner. Exact variables and projections use the name-candidate index;
explicit call contracts and conditionals combine minima without allocating
sets. Resolved match regions are traversed once with sparse shadow state.
Unresolved owner identities use indexed direct-variable/projection rules and
the exact name-summary predicate only at complex result boundaries, because
those semantics intentionally differ from definition-origin semantics.
Incoming ownership nodes and complex result expressions retain counted
compatibility islands. This preserves existing Core while avoiding origin-set
storage entirely in the measured ownership-ready path.

The focused 32-owner fixture reduced borrowed-call reconstruction visits from
8,378 to 256 (96.9%), direct-Perceus window allocations by 39.3%, and the direct
window median by 33.2%. The post-Perceus artifact was byte-identical. See
`benchmarks/results/compiler_perceus_tranche2_2026-09-04.md`.

### Previous shape

`protect_borrowed_param_calls_for_function` reconstructs the body once for each
nonconsumed managed parameter. Argument alias checks can also rescan the same
argument for each owner.

### Implemented shape

```blorp
record BorrowedOwnerCatalog {
	owners: List[CoreParam],
	candidate_ids_by_name: Dict[String, List[Int]],
	has_unresolved_identity: Bool
}

record BorrowedOwnerRewriteContext {
	env: PerceusEnv,
	owners: BorrowedOwnerCatalog,
	shadowed_owner_ids: Dict[Int, Bool],
	query_kind: BorrowedOwnerQueryKind
}

private pure func protect_borrowed_calls(
	context: BorrowedOwnerRewriteContext,
	expr: CoreExpr,
) -> CoreExpr

private pure func first_borrowed_owner_aliasing_expr(
	context: BorrowedOwnerRewriteContext,
	expr: CoreExpr,
) -> Option[Int]
```

The traversal reconstructs each region once. Entering a binder adds only the
exact shadowed owner identity to sparse context. A consuming boundary asks for
the earliest active owner that the evaluated result may borrow. This is the
only owner identity that affects output: the old owner-major traversal emitted
the first retain for that owner, and the retain made the value owned before any
later owner was considered.

Direct variables and transparent projections use the name-candidate index.
Resolved calls and conditionals combine the minimum owner ID without allocating
origin sets. Ordinary lowered parameters have name-only identities; their
complex result forms use the exact legacy scalar predicate at an explicit,
counted compatibility boundary because its summary semantics intentionally
differ from resolved definition-origin semantics.

A matching consuming boundary preserves the existing evaluate-once shape:

```blorp
match first_borrowed_owner_aliasing_expr(context, arg):
	Some(owner_id):
		retain_borrowed_aggregate_value_with_temp(
			context.env,
			context.owners.owners[owner_id],
			arg,
			Some(temp),
		)
	None:
		arg
```

For `if condition: p else: q`, the result is one
minimum owner, not two retains. Materialization emits one synthetic
`BorrowLetExpr(temp, argument, DupExpr(temp, ...))` so the argument is evaluated
once and only the selected result is retained. Complete origin sets are not
materialized or retained by this pass.

### Independent value

This replaces `O(B * N)` body reconstruction, where `B` is borrowed owners,
with one `O(N)` reconstruction plus catalog construction, indexed direct-owner
queries, actual transfer work, and the explicitly counted scalar compatibility
queries. The ownership-ready focused fixture has no scalar fallback requests.

### Acceptance criteria

- Start with a failing node-visit assertion at 1, 8, and 32 borrowed owners.
- The reconstruction traversal count is independent of borrowed-owner count
  for a fixed body. Scalar compatibility-query counts are reported separately.
- Exact local shadowing, global shadowing, nested lambdas, specialized calls,
  and unknown-call conservatism are covered.
- Conditional multi-origin results retain exactly one evaluated result.
- Computed borrowed-call results and field/list projections receive a
  synthetic evaluate-once binding, while owned-result near-misses do not.
- Ownership-event order matches the baseline exactly.
- Post-Perceus Core and generated C remain byte-identical.
- At 32 borrowed owners, call-protection node visits fall by at least 75%.
- Origin-set member visits and retained storage slots must not retain
  `O(B * N)` scaling when actual alias relationships remain fixed. `vmmap`
  allocation count and maximum RSS are supporting evidence.
- The focused paired fixture must not regress; record its realized median and
  compare it with the Tranche 0 hypothesis.

## Tranche 3: Normalize Aggregate Transfers For All Owners

**Implemented:** 2026-09-04. Function-parameter call protection and aggregate
normalization now share one ordered owner catalog. Aggregate normalization
reconstructs supported ownership-ready Core regions once, carries exact sparse
shadow state through binders and compiled matches, and asks for only the
earliest active owner at each transferring slot. The scalar aggregate pass
remains for globals, lambda-local borrowed values, and explicit local-binding
compatibility paths. Issues 49–50 move globals and lambda region owners onto
catalogs; local match/loop paths remain deferred to the later all-value fact
and planning tranches.

The aggregate boundary is contract-directed. Record and source-level tuple
fields transfer their children. Prepared boxed collection and union slots use
`needs_release`; list-set storage uses `transfers_ownership`; prepared tuple
pointer slots use the least-significant-first `retain_mask`, while struct slots
transfer and primitive, float, void, and stack-result slots do not. No
constructor spelling or broad expression-shape heuristic decides ownership.

The focused 32-owner fixture reduced aggregate reconstruction visits from
9,656 to 232 (97.6%), direct-Perceus window allocations by 60.3%, releases by
61.4%, and the paired direct-window median by 54.4%. The one-owner point was
neutral. Post-Perceus Core and generated C were byte-identical. See
`benchmarks/results/compiler_perceus_tranche3_2026-09-04.md`.

### Previous shape

`retain_borrowed_param_aggregates` reconstructed each function body once for
every nonconsumed managed parameter. Each transferring child then recursively
normalized nested aggregate members and ran a scalar alias query for that
owner.

### Implemented shape

The all-owner alias mechanism now covers ownership-transferring aggregate slots:

```blorp
private pure func retain_borrowed_aggregate_transfers(
	context: BorrowedOwnerRewriteContext,
	expr: CoreExpr,
) -> CoreExpr
```

Transfer decisions use explicit storage contracts:
`CoreBoxedStorageValue.needs_release` for boxed aggregate slots,
`CoreBoxedStorageValue.transfers_ownership` for list-set storage, and prepared
tuple retain masks. Do not infer transfer from constructor spelling or
expression shape.

### Independent value

This deletes a second parameter-multiplied reconstruction without depending on
the later general lifetime planner.

### Acceptance criteria

- Add a failing aggregate-escape work counter before implementation.
- Cover records, tuples, payload constructors, collection storage, closures,
  tasks, and borrowed match payloads where those forms are ownership-ready.
- The traversal count is independent of borrowed-owner count.
- Ownership-event order, post-Perceus Core, and generated C remain identical.
- At 32 borrowed owners, aggregate-normalization visits fall by at least 75%.
- Origin-set operations scale with actual escaping values, not owner count
  times body size.
- The aggregate-focused paired fixture must not regress. If timing is below
  noise, increase only aggregate density and use logical counters to decide
  whether the change has independent value.

## Tranche 4: Normalize Every Borrowed Boundary Once Per Ownership Region

Tranche 4 is split into four independently mergeable issues. The split first
removes the remaining owner-multiplied rewrites, then fuses the proven all-owner
passes. Each issue has a fixed-shape benchmark, exact logical counters, paired
immediate-parent workers, byte-identical Core/C requirements, and an observable
direct-Perceus performance gate.

### 4A: All-owner function results

[Issue 48](48-normalize-borrowed-results-for-all-owners.md) replaces the
per-parameter result-path loop with one branch-local all-owner result walk.
Result satisfaction is distinct from lexical shadowing: an existing `DupExpr`
may satisfy one owner's result obligation without hiding that owner from call
or aggregate analysis.

The exact result-carrier inventory comes from the current scalar authority.
Conditions, scrutinees, initializers, assignment right-hand sides, and currently
opaque loop/task forms must not become result paths during an output-preserving
optimization.

Implemented on 2026-09-04. The 32-owner focused fixture reduced result-path
visits by 97.9%, the paired direct-Perceus median by 27.5%, and allocations by
23.6%, with byte-identical Core and generated C. See
[`compiler_perceus_tranche4a_2026-09-04.md`](../../../benchmarks/results/compiler_perceus_tranche4a_2026-09-04.md).

### 4B: Exact referenced globals

[Issue 49](49-normalize-referenced-globals-as-owner-catalog.md) replaces the
per-global call/aggregate/result triples in function bodies and dynamic global
initializers. Only exact resolved, referenced, managed globals enter the
catalog. Parameter owners retain declaration order and referenced globals
retain existing sorted global-index order; the initialized global excludes
itself.

Global discovery may remain one separate read-only pass initially. The landing
property is one owner-independent reconstruction per operation family, not a
claim that catalog discovery itself is free.

Implemented on 2026-09-04. The 32-global focused fixture reduced
referenced-global normalization visits by 96.9%, the paired direct-Perceus
median by 41.1%, allocations by 41.2%, and releases by 42.5%, with
byte-identical Core and rooted generated C. The one-global allocation and
release controls remained within 0.4% of the immediate parent. See
[`compiler_perceus_tranche4b_2026-09-04.md`](../../../benchmarks/results/compiler_perceus_tranche4b_2026-09-04.md).

### 4C: Lambda ownership regions

[Issue 50](50-use-owner-catalogs-for-lambda-regions.md) applies the same
all-owner mechanisms to lambda parameters, runtime captures, and exact
referenced globals. A nested lambda is opaque to its outer region and is
normalized exactly once as its own ownership region.

This tranche is implemented. On the fixed 32-owner lambda fixture,
reconstruction visits fell 97.0%, the paired direct-Perceus median improved
63.1%, allocations fell 68.7%, and releases fell 69.7%, with byte-identical
post-Perceus Core and generated C. See
[`compiler_perceus_tranche4c_2026-09-04.md`](../../../benchmarks/results/compiler_perceus_tranche4c_2026-09-04.md).

Match, loop, resource, mutable-slot, and concurrency bindings introduced inside
a region remain on their existing lexical-balancing path. Their all-value
migration belongs to Tranches 5–6 rather than being hidden inside borrowed
boundary fusion.

### 4D: Fuse the boundary passes

[Issue 51](51-fuse-borrowed-boundary-normalization.md) combines the independently
validated call, aggregate, and result passes into one post-order reconstruction
per nonempty function, lambda, or dynamic-global-initializer region. It first
removes the transitional split between ordinary-function parameter and global
catalogs while retaining the three proven walkers. Boundary traversal domains,
lexical visibility, and result satisfaction are represented independently.

The fused action order is explicit: normalize children, apply consuming-call
ownership, apply contract-directed storage transfer, then apply terminal result
ownership. The implementation must model ownership transitions directly rather
than depending on a later pass observing wrappers inserted by an earlier pass.
Correctness is defined by identical resulting Core ownership order, generated C,
and action counts; a post-order fused walk is not required to preserve the
chronology of internal rewrite-helper calls from three whole-region passes.

Checkpoint A is complete: ordinary-function parameters and exact globals now
share one ordered catalog, reducing the measured high-owner direct-Perceus
window by 11.7% and allocations by 6.3% while preserving exact Core and C.
Checkpoints B–C remain proposed.

### Tranche-wide acceptance

- Issue 48 removes parameter-scaled result reconstruction.
- Issue 49 removes referenced-global-scaled reconstruction without considering
  unreferenced program globals.
- Issue 50 removes parameter/capture/global-scaled lambda reconstruction.
- Each of Issues 48–50 reduces relevant node visits by at least 75%, improves
  its 32-owner focused direct-Perceus median by at least 15%, and lowers focused
  direct-window allocations by at least 20%.
- Issue 51 visits each ownership region once, reduces overlapping traversal
  visits by at least 50%, improves the fusion fixture's direct-Perceus median by
  at least 10%, and lowers focused allocations by at least 15%.
- Low-owner/low-density controls remain neutral within specified paired noise
  and allocation bounds.
- Every checkpoint preserves exact ownership-event order, post-Perceus Core,
  and generated C against its immediate parent.
- The final fusion deletes the superseded traversal/helper families rather
  than retaining a second production compatibility path.
- Compiler self-compilation is reprofiled after 4D. Its result guides the
  Tranche 5 stop/go decision but is not substituted for the focused gates.

## Tranche 5: Build All-Value Ownership Facts Once

### Change

Lift the current scalar ownership algebra over all managed local IDs:

```blorp
record FunctionOwnershipFacts {
	values: List[OwnershipValue],
	regions: List[OwnershipRegion],
	facts_by_value_id: List[OwnershipValueFacts],
	referenced_globals: List[CoreDefinitionIdentity]
}

private pure func analyze_function_ownership(
	context: PerceusFunctionContext,
	body: CoreExpr,
) -> FunctionOwnershipFacts
```

This is initially allowed to inspect the already normalized body so individual
query families can move safely. It is a transitional second collection, not
the steady-state architecture. Preserve enough unresolved call and borrowed
boundary information that Tranche 6 can extend the Tranche 1 direct-fact
collector and delete this separate source walk.

The analysis must have explicit operations for sequencing, branching, and
repetition:

```blorp
private pure func sequence_value_facts(
	left: OwnershipFactSet,
	right: OwnershipFactSet,
) -> OwnershipFactSet

private pure func branch_value_facts(
	branches: List[OwnershipFactSet],
) -> OwnershipFactSet

private pure func repeat_value_facts(
	condition: OwnershipFactSet,
	body: OwnershipFactSet,
) -> OwnershipFactSet
```

There must be no catch-all that silently assigns zero ownership uses to a new
child-bearing Core variant. Exhaustiveness should make a new variant fail at
compile time or ownership ingress.

### Incremental consumers

Cut over and delete one old query family at a time:

1. unused managed-let detection;
2. single-direct-consume detection;
3. referenced borrowed match-binding detection;
4. whole-body legacy balance summaries;
5. nested branch summaries; and
6. repetition summaries and scalar `count_uses` fallbacks.

Each cutover is a mergeable checkpoint with its own counter improvement.

### Acceptance criteria

- Begin each query-family migration with a failing request-count assertion.
- Every ownership-ready Core variant is explicitly handled.
- Exact identity tests cover locals, globals, binders, lambda captures, tasks,
  resources, select receive variables, and embedded ownership variables.
- Deep Core remains stack bounded.
- Each migrated query family performs zero legacy scalar summary calls.
- The final implementation performs one fact-collection visit per expression
  node, plus documented control-flow join work.
- Branch/match/repetition fixtures must not regress after all query families
  are migrated; record realized medians against Tranche 0 hypotheses.
- Logical set-operation and retained-slot counters must show that fact
  collection did not replace removed scans with equivalent allocation-shaped
  work on the 32-owner fixture. Use `vmmap` allocation count and maximum RSS as
  supporting evidence. If they show a material regression, add the existing
  benchmark worker's exact `reset_mem_stats()`/`get_mem_stats()` measurement
  window before proceeding.

## Tranche 6: Separate Ownership Planning From Materialization

### Change

```blorp
private pure func plan_function_ownership(
	context: PerceusFunctionContext,
	facts: FunctionOwnershipFacts,
) -> FunctionOwnershipPlan

private pure func materialize_ownership_plan(
	body: CoreExpr,
	plan: FunctionOwnershipPlan,
) -> CoreExpr
```

Planning decides every lexical, branch, match, repetition, transfer, and return
action together. Materialization performs no ownership analysis; it advances a
deterministic site counter and inserts the prescribed nodes.

Example materialization logic:

```blorp
private pure func materialize_site(
	site: OwnershipSiteId,
	expr: CoreExpr,
	plan: FunctionOwnershipPlan,
) -> CoreExpr:
	actions = ownership_site_actions(plan, site)
	children = materialize_children(expr, plan)
	with_before = materialize_before_actions(actions.before, children)
	materialize_after_actions(actions.after, with_before)
```

The exact implementation should use the project's normal APIs and avoid
unnecessary `List` materialization; the example illustrates responsibility.

### Migration sequence

1. Plan and materialize simple immutable lets.
2. Add branches and short-circuit regions.
3. Add constructor and releasing matches.
4. Add repetition, tail recursion, break, and continue.
5. Add mutable places and invalidation.
6. Add resources, select, concurrency, and task capture.
7. Move borrowed call, aggregate, and result obligations from the temporary
   Tranches 2–4 normalizer into planning, then delete those rewrite passes.
8. Extend the Tranche 1 direct-fact collector with all-value occurrences and
   regions. Apply solved contracts to those compact facts and delete the
   transitional Tranche 5 source-body analysis.
9. Remove the broad-signature simple-balance shortcut once the general planner
   covers it with equal scaling.
10. Delete the old scalar insertion and balancing path.

Temporary fallback is allowed only while an explicit region is being migrated.
It must be selected by an explicit supported-region variant, never by catching
an analysis failure. No fallback remains when Tranche 6 lands complete.

### Acceptance criteria

- Each region migration begins with a failing ownership-event comparison.
- Materialization performs exactly one Core reconstruction.
- Planning performs zero target-specific body traversals.
- Final direct-fact collection visits the original function body once; contract
  solving and ownership planning operate only on collected regions and events.
- No separate borrowed-normalization or post-normalization analysis traversal
  remains.
- The 1/8/32/128 managed-parameter series remains approximately linear in body
  size and actual occurrences, not parameter count times body size.
- The general path meets or beats the old simple-balance path at 32 parameters.
- Canonical ownership-event streams and final C are identical across the
  counterexample ledger.
- Complex ownership fixtures and self-compilation must not regress relative to
  the Tranche 5 parent.
- Record cumulative direct-Perceus and ownership-preparation-plus-Perceus
  medians against Tranche 0. If the hypothesized 25% cumulative improvement is
  not approached, stop and determine whether decoding, other passes, origin
  sets, or analysis allocation dominate before beginning runtime-output
  changes.

## Tranche 7A: Precompute Existing Cleanup Decisions

### Placement

Perceus runs before reuse, closure conversion, resources, fairness insertion,
and final preparation. Exact cleanup facts therefore belong at the prepared
program boundary rather than in early Perceus output.

Construct the cleanup plan only after
`CoreReuse.rewrite_prepared_program`. This is the last transformation in
`run_post_closure_tail`, and `run_pre_dce_tail` wraps that result in
`PreparedCoreProgram`. The plan therefore observes final checkpoints,
resources, closure bodies, and prepared reuse.

Evolve the private opaque product:

```blorp
record FunctionCleanupPlan {
	tracked_bindings_by_site: List[Option[CleanupBindingPlan]],
	duplicate_slots_by_site: List[Option[CleanupDuplicatePlan]],
	terminal_pops_by_site: List[Option[CleanupPopPlan]]
}

private record PreparedCorePayload {
	program: CoreProgram,
	function_cleanup_plans_by_def_id: Dict[Int, FunctionCleanupPlan],
	global_initializer_cleanup_plans_by_def_id: Dict[Int, FunctionCleanupPlan]
}

opaque type PreparedCoreProgram = PreparedCorePayload

pure func prepared_core_program(final_program: CoreProgram) -> PreparedCoreProgram:
	into_opaque PreparedCoreProgram({
		program = final_program,
		function_cleanup_plans_by_def_id = plan_function_cleanup(final_program),
		global_initializer_cleanup_plans_by_def_id = plan_global_initializer_cleanup(
			final_program,
		)
	})
```

Final Core validates definition-ID uniqueness, so `def_id` is a stable
primitive key here. Backend C symbol projection changes callable names but
preserves definition IDs and expression shape; plans therefore survive
projection without a record-valued dictionary key. The production projected
emitter and the unprojected test emitter must both look up plans by `def_id`.
Dynamic global initializers also enter `emit_function_body` and require the
same cleanup analysis. They use the separate global-definition-ID table; a
function/global discriminator is structural rather than encoded into an
integer sentinel.

The first planner must reproduce the emitter's current decisions. C emission
becomes a lookup/materialization consumer rather than running
`body_consumes_var*` for each let.

### Acceptance criteria

- A failing counter demonstrates repeated emitter body scans before the change.
- Cleanup plans use exact binding and site identities.
- Every existing cleanup push, pop, and duplicate-slot update is reproduced in
  the same order.
- Both projected production emission and unprojected test emission consume the
  same `def_id`-keyed plans successfully.
- Dynamic global initializers reproduce their existing cleanup decisions and
  require no emitter body-scan fallback.
- Generated C is byte-identical.
- Emitter cleanup-decision expression visits fall by at least 80%.
- The cleanup-heavy emitter fixture and full backend emission must not regress;
  realized medians are recorded against Tranche 0 hypotheses.
- No old emitter scanning fallback remains.

## Tranche 7B: Prove Whole Functions Cannot Cancel

### Change

Introduce an explicit effect:

```blorp
union CoreCancellationEffect:
	CannotCancelCurrentTask
	MayCancelCurrentTask
```

Direct cancellation points include cooperative checkpoints and explicitly
catalogued blocking or yielding runtime operations. Unknown calls, unresolved
closure calls, and foreign calls are conservatively `MayCancelCurrentTask`.
User-call effects reach a fixed point over the exact call graph.

The first optimization is deliberately coarse:

```text
if function.effect == CannotCancelCurrentTask:
    emit ordinary ARC
    emit no task cleanup registration for local ownership intervals
else:
    use the exact Tranche 7A cleanup plan
```

Region-sensitive suppression may follow only after the whole-function rule is
validated.

### Expected performance

For an eligible function, nearly all local cleanup pushes, matching pops, and
duplicate-slot updates should disappear. Ordinary retain and release counts do
not change.

The compiler-wide result is proportional to the fraction of generated managed
bindings located in proven noncancelling functions. Tranche 0 must report that
fraction before an output-size promise is made.

### Acceptance criteria

- The effect inventory explicitly names every direct cancellation-capable Core
  or runtime operation.
- Recursive effects converge and unknown behavior fails closed.
- Cancellation tests interrupt at every affected blocking/yield boundary.
- Leak and sanitizer gates pass under cancellation.
- Ordinary ARC event counts remain unchanged.
- Eligible functions emit zero local cleanup push/pop/duplicate-slot calls.
- Generated cleanup statement count falls exactly by the predicted eligible
  count from the cleanup plan.
- The counter-instrumented runtime reports zero executed local cleanup
  operations for an eligible-function fixture; timing uses the separately
  rebuilt counter-disabled runtime.
- If fewer than 5% of self-compilation cleanup statements are removed, do not
  generalize to region-sensitive analysis until profiling identifies a
  representative workload where the added complexity pays for itself.

## Tranche 8: Simplify Proven Ownership Actions

### First rule

Resolve the documented managed-match payload case where conservative balancing
can add a retain/release pair even after another normalization supplied the
owned reference.

```blorp
private pure func simplify_redundant_match_payload_ownership(
	plan: FunctionOwnershipPlan,
) -> FunctionOwnershipPlan
```

The rule must match ownership obligation and provenance, not merely adjacent
syntax.

### Later rules

Land separately:

1. fresh owner transferred exactly once on every reachable path;
2. unused fresh owner released directly at the construction boundary;
3. borrowed protection already supplied by an enclosing owned transfer; and
4. equivalent branch-terminal actions hoisted only when destruction order and
   cancellation behavior remain unchanged.

Do not erase a terminal `DropExpr` that reuse currently consumes as proof. Such
an optimization must either preserve the witness through materialization or
first teach reuse to consume an explicit `DeadOwnerAt(site)` fact.

### Acceptance criteria per rule

- Add a regression that fails by exact ownership-event count before the rule.
- State the required provenance and rejected near-miss cases in the test.
- Predict the exact number and location of removed actions.
- Observed event and generated-C deltas match that prediction.
- COW uniqueness tests cover an intervening consuming update.
- Runtime, leak, sanitizer, and cancellation tests pass.
- The affected microbenchmark executes at least 90% fewer targeted redundant
  ownership operations; a rule with no measurable representative occurrence
  remains documented rather than adding production complexity.

## Tranche 9: Remove Nonescaping Container Allocations

### Start with scalar replacement

Prefer eliminating an object to putting a heap-compatible ARC header on the C
stack.

The lifetime facts produced inside Perceus cannot flow backward to the earlier
SROA boundary. Tranche 9 therefore adds a phase-specific, pre-Perceus escape
analysis owned by aggregate SROA. It may share exact-identity, region, and
occurrence utilities with the Perceus collector, but its facts are computed
from the post-projection early Core that it actually rewrites:

```blorp
opaque type AggregateSroaSiteId = Int

union AggregateEscapeReason:
	ReturnedAggregate
	StoredAggregate
	WholeAggregateCallArgument
	UnknownCallAggregate
	ClosureCaptureAggregate
	TaskCaptureAggregate
	ForeignBoundaryAggregate
	CowObservationAggregate

record AggregateEscapeFact {
	variable: CoreVar,
	escape_reasons: List[AggregateEscapeReason],
	projection_sites: List[AggregateSroaSiteId]
}
```

A safe first candidate is:

```blorp
point: Point = {x = x_value, y = y_value}
x = point.x
y = point.y
body(x, y)
```

when analysis proves that `point`:

- is not returned;
- is not stored in another aggregate;
- is not passed as a whole value to any call;
- is not captured by a closure or task;
- does not cross an FFI boundary;
- is observed only through exact field projections; and
- does not participate in a COW uniqueness test.

The replacement is conceptually:

```blorp
point_x = x_value
point_y = y_value
x = point_x
y = point_y
body(x, y)
```

Managed child fields retain their individual ownership plans. The container
allocation, container refcount, and terminal container release disappear.

In Core this is the corresponding `LetExpr` plus `RecordExpr` and `FieldExpr`
pattern. The rewrite belongs before Perceus, at the existing `tuple_sroa`
boundary in `finish_early_core_pipeline_after_projection`: generic templates have already
been projected, and ownership has not yet been inserted. Prefer extending and,
if its responsibility truly broadens, renaming `tuple_sroa` to an explicit
aggregate-SROA pass. Do not add a second overlapping scalar-replacement pass.

The rewrite must preserve source evaluation order for every field initializer
and destruction order for managed children. Hoist fields into fresh bindings
in their existing left-to-right order; do not group projections or reorder
initializers merely because the container itself disappears.

The first slice rejects every whole-aggregate call argument, including known
direct, builtin, borrowing, and consuming calls: the callee still expects the
record representation. Joint caller/callee scalarization or an explicit
noescape aggregate ABI is separate future work.

Progress from records to tuples, simple union payloads, and nonescaping
closures only after each representation's explicit escape contract exists.

### Acceptance criteria

- Begin with a failing allocation-count fixture for a nonescaping record.
- Every eligibility and rejection reason is represented explicitly and tested.
- Known direct, builtin, foreign, unknown, borrowing, and consuming whole-value
  call arguments all produce an explicit escape rejection in the first slice.
- Aggregate SROA computes escape facts at its own early-Core boundary; it does
  not consume facts produced later by Perceus.
- The implementation extends the current SROA authority at the post-projection
  early-fusion boundary rather than creating an overlapping pass.
- Generated C contains no allocation, retain, release, or cleanup slot for the
  eliminated container.
- Managed child values retain correct destruction order.
- Field initializer evaluation and managed-child destruction order are covered
  by side-effecting and ownership-event fixtures.
- Exact record/tuple/union semantics and COW behavior remain unchanged.
- The eligible microbenchmark removes 100% of targeted container allocations.
- Runtime, leak, sanitizer, cancellation, reuse, and generated-C audits pass.
- Self-compilation reports candidate and accepted counts. A zero or negligible
  acceptance rate blocks generalization to additional aggregate families.

## Fast Feedback Loop

During implementation, do not run the entire compiler and runtime matrix after
every local edit.

Use this loop:

1. Keep a baseline compiler or prepared Perceus worker from the parent commit.
2. Add the focused failing counter, contract, ownership-event, or allocation
   assertion.
3. Type-check the directly changed compiler module.
4. Run the narrow Stage 09 Perceus or Stage 10 emitter suite.
5. Run the affected paired benchmark and compare deterministic counters.
6. Compare the baseline and candidate ownership artifact hashes.

Representative commands are:

```bash
bin/blorp check --no-format blorp/src/compiler/stage_09_core/perceus.brp
bin/blorp test blorp/test/compiler/stage_09_core/test_core_perceus.brp
bin/blorp test blorp/test/compiler/stage_09_core/test_core_reuse.brp
bin/blorp test blorp/test/compiler/stage_10_backend/test_core_emit.brp
scripts/compiler-check --changed
```

Run broad gates once at the end of an output-preserving tranche, and again for
every runtime-output-changing tranche:

```bash
scripts/test compiler-blorp
scripts/test compiler-core-sanitize
scripts/test runtime
scripts/test leak
blorp/test/compiler/pipeline/codegen_audit/run_codegen_audit.sh bin/blorp
```

The counterexample obligations in
`blorp/test/compiler/perceus_cleanup_coverage_ledger.tsv` are the maintained
coverage inventory. Update its owning tranche and required test when a new
analysis boundary is introduced; do not remove a row merely because a new
implementation passes the current happy path.

## Merge And Rollback Discipline

Each tranche must:

1. start with a failing deterministic work or behavior assertion;
2. replace one authority or repeated traversal;
3. delete the superseded production implementation in the same merge;
4. preserve exact output until the roadmap explicitly permits a delta;
5. record paired raw measurements and artifact hashes;
6. avoid broadening the catalog or analysis beyond its immediate consumer;
7. receive code and performance review; and
8. remain independently revertible.

For Tranches 1–7A, use the parent compiler binary as the compatibility oracle.
Do not keep an entire legacy Perceus implementation in production merely for
comparison.

For Tranches 7B–9, the issue must enumerate expected output differences before
implementation. An unexplained retain, release, cleanup, allocation, ordering,
or artifact delta is a failure even if runtime tests pass.

## Stop/Go Checkpoints

### After Tranche 1

Proceed if contract inference no longer revisits bodies and the contract-heavy
fixture improves. If it does not, inspect fact-collection allocation before
building more shared analysis infrastructure.

### After Tranche 4

Reprofile compiler self-compilation. If borrowed normalization is no longer a
material part of Perceus, skip directly to whichever scalar-summary family is
measured hot rather than mechanically implementing every planned abstraction.

### After Tranche 6

Require a clear cumulative Perceus improvement and approximately linear
scaling. The explicit plan is still a cleanliness improvement, but it does not
justify further runtime optimization complexity unless it also exposes useful
provenance and cancellation facts.

### After Tranche 7B

Measure the eligible noncancelling fraction and actual cleanup-statement
reduction. Do not implement region-sensitive cleanup if whole-function effects
cover too little code and the profile does not show a runtime or C-size return.

### After each Tranche 8 or 9 rule

Require a representative occurrence count and measured effect. Prefer deleting
an unproductive rule to accumulating a general optimizer whose useful cases do
not occur in real programs.

## Completion Criteria

This roadmap is complete when:

- every function body is collected once for ownership facts;
- recursive contract and cancellation solving revisits compact graph facts,
  not Core bodies;
- borrowed normalization is independent of borrowed-owner count;
- scalar target-specific summary and fallback traversals are gone;
- Perceus produces one explicit ownership plan and materializes it once;
- the broad-signature shape shortcut is unnecessary and removed;
- backend cleanup decisions are precomputed once from final prepared Core;
- proven noncancelling code emits no unnecessary cleanup registration;
- every ARC simplification has explicit provenance and counterexample tests;
- allocation removal uses explicit escape facts rather than syntax heuristics;
- reuse retains a sound proof of exact owner death;
- compiler self-compilation has current paired performance, allocation, peak
  memory, ownership-event, cleanup, and generated-C measurements; and
- all compiler, runtime, leak, sanitizer, cancellation, and codegen audit gates
  pass at the final ownership boundary.
