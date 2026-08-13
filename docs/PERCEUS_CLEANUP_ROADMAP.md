# Perceus Cleanup Roadmap

Status: in progress.

Completed implementation checkpoints:

- Slice 1 feedback-loop infrastructure and dead-linearity removal: `47c27ce4`.
- Slice 12 explicit balancing strategy: `c3530d2c`.
- Slice 5 partial: exact compact global lookup is implemented while the
  declaration-ordered list remains the event-order source. Conflicting exact
  duplicate validation remains owned by the future ingress boundary.

This document is the execution plan for simplifying Blorp's ownership pass
without weakening ownership correctness or hiding phase assumptions. It is
intentionally more detailed than `COMPILER_ROADMAP.md`: each numbered slice is
small enough to review, benchmark, and merge independently.

The goal is not merely to rename functions containing `legacy`. The goal is a
Perceus stage that:

- accepts one explicit, validated ownership-ready Core form;
- consumes resolved identities and ownership contracts instead of repairing
  earlier stages;
- performs no fallback analysis whose answer depends on an unhandled Core
  variant;
- indexes immutable program facts by exact identity;
- avoids whole-body traversals multiplied by unrelated globals or borrowed
  values;
- exposes distinct contract-analysis, ownership-summary, balancing, and
  rewrite responsibilities; and
- owns general lexical ARC balancing and borrowed-to-owned normalization while
  preserving protocol-specific ownership nodes inserted by other Core passes.

This work does not change source-language value semantics, runtime ownership
ABI, or post-Perceus reuse rules. It does not move ownership retains into
resolution. It does not require a new serialized Core boundary.

## Verified Current State

The following facts were checked against the production pipeline and current
tests before writing this plan.

### Production boundary

`core_early_pipeline.brp` resolves global references early. Several lowering,
specialization, projection, DCE, consume-specialization, record-update, and
dict-preparation passes then run before Perceus. At its own entry,
`insert_drops_program` calls `resolve_global_value_refs` again.

The second call is therefore duplicate whole-program work, but it is not safe
to delete merely because an earlier call exists. Intervening passes construct
new `CoreVar` values. Most observed `def_id = None` constructions are fresh
locals, for which `None` is correct. The required invariant is narrower:

> Every occurrence that refers to a declared global has its exact global
> identity, unless a lexically visible local binding shadows that name.

An invariant that requires every variable to have a definition id would be
wrong.

Perceus is not the only legitimate producer of ownership nodes. Consume
specialization inserts ownership for consuming-call protocols, resource
lowering inserts cleanup ownership, and collection lowering can insert
protocol-specific ownership. Perceus must account for and preserve incoming
`DupExpr` / `DropExpr` nodes without duplicating their effect. The cleanup
should inventory these producers rather than force all ownership construction
into one module.

### Identity semantics

Definition ids are module-local. `CoreDefinitionIdentity` and
`core_vars_have_same_definition` identify a global by qualified name and
definition id together. A future global catalog keyed only by `def_id` would
alias unrelated globals from different modules.

The current Perceus environment stores globals in a list plus a
name-to-list-index map. Candidate lookup still filters by exact identity and
sorts indices. Mutable-global target lookup still scans the global list.

### Active legacy analyses

`ownership_uses_from_legacy_count` remains reachable from:

- repeated-body handling for the supported `for` forms;
- `while` handling when a condition or body consumes the value; and
- the catch-all arm of `summarize_linear_ownership_uses_non_binding`.

The conversion loses borrow-versus-consume, returned-alias, and user-call
dependency facts. It also performs an additional recursive traversal.

More importantly, the catch-all is not conservative. `count_uses` itself has a
default zero arm. Some Core variants not named by the structured ownership
summary contain child expressions, so a newly reachable or newly added form
can silently report no use. The cleanup must replace the catch-all with an
exhaustive ownership-ingress contract, not with another generic default.

`balance_let_body_legacy` is also active, but it already receives a structured
`OwnershipUseSummary`. It handles ordinary managed lets, concurrent bindings,
and match cases for which specialized balancing is unavailable or unsafe. It
is a misleading name, not deletable legacy behavior. Releasing matches need
special care because the backend releases the scrutinee root after the branch.

### Traversal multiplication

For each function, the current rewrite pipeline separately:

1. annotates user-call contracts;
2. determines consumed parameters;
3. protects borrowed parameter calls;
4. retains borrowed parameter aggregate members;
5. retains borrowed parameter result aliases;
6. discovers unshadowed referenced globals;
7. repeats the three borrowed-value normalizations for referenced globals;
8. normalizes owned-result aliases;
9. inserts drops; and
10. balances consumed parameters.

Several borrowed normalizers traverse the body once per managed borrowed
parameter or global. Contract inference similarly summarizes a function body
per managed parameter. These are credible allocation and latency targets, but
they should be consolidated only after the existing ownership behavior is
represented by exhaustive summaries and explicit ingress invariants.

### Coupling outside Perceus

`core_match_projection.brp` and `core_late_invariants.brp` import
`PerceusEnv`, `build_env`, and `contract_for_call`. They build or accept the
large Perceus environment when they only need ownership-contract lookup. The
environment currently mixes:

- immutable program facts;
- inferred user-call contract state;
- global lookup state;
- local balancing mode; and
- local transferable-result variables.

This coupling should be removed before splitting `core_perceus.brp` into
modules, or a module split will encode the current dependency problem as
cycles.

### Dead production surface

`is_linear` and its private helpers have no production caller. Two Perceus
unit tests are their only users. They can be deleted as a first mechanical
cleanup. `perceus_env_for_managed_types` is likewise a test-construction API,
but it has many test callers and should move only after a narrower contract
catalog and rewrite context exist.

### Existing feedback loop

The focused resolver and Perceus suites currently pass 346 tests:

```text
./blorp test \
  compiler/blorp/tests/test_compiler_core_resolve.brp \
  compiler/blorp/tests/test_compiler_core_perceus.brp
```

The existing `benchmarks/compiler_perceus_memory` fixture exercises the full
production `emit_core_c` path. Single exploratory samples on this machine were:

| Globals | Reads per function | Elapsed | Peak RSS | Generated C |
| ---: | ---: | ---: | ---: | ---: |
| 32 | 0 | 0.466 s | 40.5 MB | 109,694 B |
| 32 | 32 | 0.591 s | 41.5 MB | 154,750 B |
| 384 | 0 | 0.523 s | 45.4 MB | 170,590 B |
| 384 | 32 | 0.648 s | 46.7 MB | 215,646 B |

These are smoke measurements, not performance claims. They include stages
outside Perceus and only one sample per point. A decision baseline requires
warmup and at least seven paired, alternating samples.

The version 3 fixture also has a bounded parameter matrix. It keeps two
uncalled worker bodies at 128 leaves and replaces literals with one exact read
per parameter, so the expression tree remains at 516 nodes. Each 1/8/32 point
runs both primitive `Int` parameters and managed borrowed `String` parameters;
the primitive control includes the same parameter-list and Core JSON growth
without entering managed ownership normalization. Seven warmed samples on the
same worker established this pre-consolidation baseline:

| Parameters per function | Primitive median | Managed median | Managed / primitive |
| ---: | ---: | ---: | ---: |
| 1 | 0.1040 s | 0.1067 s | 1.03x |
| 8 | 0.1043 s | 0.1067 s | 1.02x |
| 32 | 0.1059 s | 0.4132 s | 3.90x |

Primitive and managed samples alternate within each count; the median paired
32-parameter ratio is 3.89x. The isolated worker still includes Core JSON
decode and encode, so absolute times are not subphase timings. The flat
primitive control shows that the managed high-point result is not explained by
parameter metadata or bridge serialization alone. Full provenance, execution
order, artifact hashes, and raw paired samples are in
`benchmarks/results/compiler_perceus_parameter_control_2026-08-13.tsv`. Run
`benchmarks/compiler_perceus_memory --parameter-matrix` for the canonical fast
loop; compiler-change claims still require paired explicit baseline and
candidate workers with at least seven samples.

Exploratory diagnostic runs localized the parameter cost more narrowly. An
exact one-pass replacement for user-contract inference alone and a separate
skip of the identity rebuild in repeated-consume protection both produced
byte-identical Core but no measurable improvement. These exploratory runs were
used to locate the next experiment, not retained as decision baselines. The
material cost was the complete parameter-by-parameter consumed-owner balancing
operation.

For the deliberately narrow post-insertion grammar made only of literals,
parameter reads, sequences, immutable literal bindings, and unrelated local
drops, a single proof can establish that every consumed parameter occurs
exactly once and balancing would emit no ownership nodes. Calls, branches,
aliases, repetition, parameter ownership nodes, shadowing, duplicate reads,
resolved parameter identities, and managed returns all reject the proof. At
the 32-parameter point this reduced the isolated-stage median from 0.2119 s to
0.1066 s; the median paired ratio was 0.503, a 49.7% reduction. The 1- and
8-parameter controls remained neutral because the proof is enabled only at 16
consumed parameters. Every compared post-Perceus artifact was byte-identical.
An explicit threshold run measured paired candidate/baseline medians of 1.012
at 15 parameters, 0.500 at 16, and 0.338 at 24, validating the chosen boundary
and the expected scaling trend.
The four-point global matrix remained within 0.6% by paired median. Full raw
parameter samples and provenance are in
`benchmarks/results/compiler_perceus_simple_balance_2026-08-13.tsv`; the global
control is in
`benchmarks/results/compiler_perceus_simple_balance_global_control_2026-08-13.tsv`,
and the threshold run is in
`benchmarks/results/compiler_perceus_simple_balance_threshold_2026-08-13.tsv`.

## Target Architecture

The desired ownership tail has these boundaries:

```text
resolved and lowered Core
  -> mandatory OwnershipReadyCoreProgram validation and fact collection
  -> static ownership contracts
  -> summary algebra parameterized by a contract view
  -> user-contract fixed point
  -> ownership rewrite subsystem:
       borrowed normalization + balancing + lexical CDup/CDrop insertion
       while preserving protocol ownership and current event order
  -> post-Perceus reuse and later Core stages
```

The rewrite subsystem is not initially three sequential passes. Managed-let
balancing occurs during recursive insertion today, while consumed-parameter
balancing runs afterward. Keep those ordering relationships until canonical
ownership-event parity demonstrates that two operations commute; only then may
they become separate passes.

The data model should converge on these responsibilities:

- `OwnershipContractCatalog`: managed-type policy, constructor contracts, and
  direct call contracts. It has no dependency on summary or inference code.
- `OwnershipContractView`: the narrow lookup interface supplied to summaries;
  inference can provide provisional layers and rewriting can provide the
  completed catalog.
- `PerceusProgramFacts`: exact global identities, mutability, callable
  identities, constructor identities, and body-local reference facts.
- `PerceusContractState`: only the mutable/iterative state needed by recursive
  user-call contract inference.
- `PerceusRewriteContext`: local balancing strategy and transferable owners,
  with variants rather than coupled Boolean flags.
- `OwnershipUseSummary`: exhaustive sequential, branch, repetition, transfer,
  alias-return, and dependency facts for every Core form admitted at ingress.

Exact global lookup should use qualified name followed by module-local
definition id, for example `Dict[String, Dict[Int, PerceusGlobal]]`. If the
language gains a hashable definition-identity key, that explicit key can
replace the nested dictionaries. A plain `Dict[Int, ...]` is forbidden.

## Execution Rules

1. Each slice must preserve one production route and be independently
   mergeable.
2. Add a characterization or failing regression before changing ownership
   behavior. Mechanical dead-code removal needs compile and focused-test
   evidence, not invented tests for deleted APIs.
3. Do not combine a semantic change with a module move.
4. Compare generated Core or generated C whenever `CDup` / `CDrop` placement
   could change. Use a canonical ownership-event projection containing the
   tree path/control-flow arm, operation, exact `CoreVar`, type, and retain or
   release policy. Text equality is appropriate for behavior-preserving
   slices; counts are supplemental and cannot prove placement or identity.
5. Treat sanitizer, leak, and runtime execution as correctness gates. A lower
   compiler time does not justify a retain/release regression.
6. Performance claims use at least seven warmed, paired, alternating samples
   and report median ratio, MAD or IQR, peak RSS, input shape, request/worker
   hashes, compiler revision, generated artifact checksum/size, and run count.
7. New Core variants must either receive explicit ownership semantics or be
   rejected by the ownership-ingress invariant in the same change.

## Ordered Implementation Slices

### 1. Freeze the baseline and remove proven dead helpers

1. Inventory every pass that constructs or structurally preserves `DupExpr`
   and `DropExpr`. Classify each producer as pre-Perceus protocol ownership,
   Perceus lexical ARC, post-Perceus resource ownership, or structural
   preservation. Add regressions for incoming nodes that Perceus must preserve
   and account for.
2. Add a canonical ownership-event test projection containing structural path,
   control-flow arm, operation, exact variable identity, type, and policy.
3. Record at least seven warmed paired samples for the four global benchmark
   points above under `benchmarks/results/`. Alternate explicit baseline and
   candidate worker binaries and report median ratio plus MAD or IQR.
4. Add benchmark cases for parameter count, call-contract dependency depth,
   nested branch depth, repeated loops, and nested lambdas. Keep body size
   fixed while varying one axis.
5. Add a benchmark worker action that stops after Perceus, before reuse and C
   emission. Keep `emit_core_c` as the end-to-end integration benchmark.
6. Prefer deterministic operation counters at phase boundaries. If subphase
   timing is still needed, distinguish
   environment construction, contract inference, borrowed normalization,
   ownership summary/balancing, and drop insertion.
7. Record request hash, worker hash, compiler revision, build mode, platform,
   output artifact hash, timeout, memory limit, and run count. Add unit tests
   for fixture generation and result parsing.
8. Remove `is_linear`, `exprs_are_linear`,
   `boxed_values_are_linear`, `record_fields_are_linear`, and their two tests.
9. Run the dead-code audit and record any additional test-only exports without
   deleting helpers whose construction semantics are still useful to tests.
10. Convert the counterexample matrix below into an executable coverage ledger
    with current test name, required new test, owning slice, oracle, and gate.
    A slice may not begin until its applicable rows have concrete test names.

Exit condition: benchmark inputs and checksums are durable, the focused tests
pass, and production behavior is unchanged.

Pitfall: instrumentation can itself allocate or perturb pure compiler code.
Counters should be opt-in at the benchmark boundary, not stored in every
recursive result.

### 2. Define the ownership-ingress Core contract

1. Inventory every `CoreExpr` variant and classify it as:
   `AllowedWithOwnershipSemantics`, `AllowedOwnershipNeutral`, or
   `ForbiddenAtPerceusIngress`.
2. Include non-expression declarations and embedded variable positions such
   as `CDup`, `CDrop`, assignment targets, raw tensor views, match owners, task
   captures, and resource binders.
3. Introduce an `OwnershipReadyCoreProgram` boundary in a neutral lower-level
   module that neither imports Perceus nor optional CLI invariant machinery.
   Its smart constructor validates and returns a typed failure. A wrapper that
   merely relabels a `CoreProgram` does not satisfy this requirement.
4. In that mandatory validator, detect a reference to a declared global
   without exact identity unless a lexical binder shadows it.
5. Model all binders while checking: parameters, lets, match bindings, loop
   variables, resource bindings, select/channel bindings, lambda parameters,
   and global-initializer self-scope.
6. Add tests proving that valid locals with `def_id = None` remain valid.
7. Test validation directly at the pre-Perceus boundary and test typed failure
   propagation through every production pipeline entry point. Catalog
   construction conflicts use this same mandatory failure path.
8. Add a compile-time exhaustiveness mechanism or test inventory so a new
   Core variant cannot bypass classification.

Exit condition: the exact program accepted by Perceus is documented and
machine-checked, without changing Perceus output.

Pitfall: name-only checking misclassifies shadowed locals. Conversely, checking
only `def_id` misses module-local collisions. The checker needs exact global
identity plus lexical scope.

### 3. Characterize and relocate global-reference resolution

1. Capture Core at the real production point immediately before Perceus.
2. Apply `resolve_global_value_refs` a second time and assert idempotence on
   representative compiler, std, package, nested-lambda, and mutable-global
   fixtures.
3. Add negative fixtures for any intervening pass that constructs a global
   reference without identity. Fix that pass at its construction boundary.
4. Propagate the typed ownership-ingress result through `run_perceus_stage`,
   every `run_core_pipeline_stage` route, backend preparation, benchmark
   workers, and CLI error rendering before deleting repair behavior.
5. Make the internal Perceus entry accept only the validated artifact. Do not
   expose a raw `CoreProgram` entry that silently repairs its input.
6. Remove the resolver import and call from `insert_drops_program` only after
   all characterization fixtures and the ingress invariant pass.
7. Inventory every test that calls `insert_drops_program` directly. Move tests
   of unresolved-reference repair to the resolver or pipeline suite, keep
   declaration-canonicalization behavior at the ownership-ready constructor,
   and turn unresolved direct Perceus input into a rejection test.
8. Update remaining direct Perceus tests to use one helper that constructs and
   validates ownership-ready Core. Do not silently pre-resolve fixtures whose
   purpose was to characterize old repair behavior.

Exit condition: global resolution has one production owner and Perceus fails
early on unresolved global references instead of repairing them.

Counterexample: a pass may introduce a fresh local named like a global with
`def_id = None`. That is correct and must not be "fixed" into a global.

### 4. Establish callable identity and extract static ownership contracts

1. Define exact callable identity before copying the current name-keyed maps.
   Resolved user calls require qualified name plus definition id; builtin,
   intrinsic, foreign, and closure calls remain explicit call kinds.
2. Migrate direct/inferred contract maps, reverse dependency edges, worklist
   entries, and specialized call lookup from string names to callable identity.
3. Cover equal display names with distinct ids, equal numeric ids in different
   modules, and specialized functions with shared numeric ids.
4. Specify the minimal static data required by `contract_for_call`.
5. Create a lower-level ownership module for contract types, constructor,
   builtin, intrinsic, and direct user-call lookup. It must not import summary
   or inference code.
6. Define a narrow `OwnershipContractView` consumed by summaries. The
   fixed-point driver may provide provisional inferred layers; rewriting must
   provide completed inferred contracts.
7. Keep inference policy explicit. Do not encode "unresolved means borrow" as
   an unnamed Boolean or a missing map entry.
8. Migrate `core_match_projection.brp` and `core_late_invariants.brp` to the
   appropriate contract view without importing `PerceusEnv`.
9. Migrate Perceus contract annotation and balancing to the same API.
10. Add tests for direct calls, specialized names, constructor identities,
   unresolved calls, recursive inference, and missing contracts at ingress.

Exit condition: ownership-contract consumers no longer construct the full
Perceus environment, and contract lookup has one implementation.

Pitfall: match projection runs before final contract inference in some stage
entry points. The catalog type must distinguish direct known contracts from
inferred contracts and from a deliberate inference-time provisional policy.

### 5. Introduce an identity-safe global catalog

1. Add an explicit global identity lookup keyed by qualified name and
   definition id.
2. Store each declaration's ordinal in the catalog and preserve current
   declaration-ordered ownership wrapping. Remove ordering only after
   multi-global event-parity tests prove it unobservable.
3. Define construction behavior for duplicate exact identities. Identical
   duplicates may deduplicate; conflicting type or mutability metadata must
   produce a typed ownership-ingress failure rather than last-write-wins
   behavior.
4. Replace candidate-list filtering with exact lookup while retaining ordinal
   ordering.
5. Replace mutable-global target scans with exact lookup.
6. Do not retain parallel list/index structures once the catalog provides both
   exact lookup and deterministic order.
7. Cover cross-module numeric-id collisions, same-name/different-id globals,
   duplicate exact identity, mutable assignment, and shadowing.

Exit condition: global lookup is exact and expected constant time, with no
parallel indexes that can diverge.

### 6. Make every ownership target identity-safe

Global catalogs alone do not fix identity handling. The current ownership
summary accepts a target `String`, and several shadow, task-capture, match
binding, and borrowed-normalization queries compare names. Introduce an
explicit ownership target before deleting `count_uses`:

1. Define a target identity that distinguishes a local value by name plus
   hygiene `uniq` from a resolved definition by qualified name plus `def_id`.
2. Provide one target-construction and equality API. Do not let callers infer
   identity kind from an empty id or compare only a shared string.
3. Migrate ownership summaries and their recursive helpers from `String` to
   the explicit target.
4. Migrate one analysis family at a time: alias queries first, then summaries,
   shadow checks, task captures, match-binding lifetime checks,
   borrowed-value normalization, assignment targets, and `DupExpr` /
   `DropExpr` accounting.
5. Migrate per-parameter user-contract summaries to value identity; callable
   dependency identity remains the distinct responsibility of slice 4.
6. Add regressions for same-name/different-`uniq` locals,
   same-name/different-`def_id` definitions, and equal numeric ids in different
   modules.
7. Compare canonical ownership-event projections after each analysis family,
   not only after the final migration.

Exit condition: no ownership decision aliases values merely because their
display names match.

Pitfall: global definition identity and local variable identity intentionally
have different equality rules. A single tuple with optional fields would make
illegal mixed states representable; use explicit variants.

### 7. Collect per-body referenced-global facts once

1. Move the general value-reference facts and traversal currently owned by
   `core_dce` into a neutral lower-level module such as
   `core_value_references`. DCE, ownership ingress, and Perceus must share it;
   do not add a second recursive walker.
2. At ownership ingress, collect exact resolved global reads and writes for
   each function and global initializer from that shared analysis.
3. Make the fact distinguish read, assignment target, and ownership-bearing
   occurrence where Perceus behavior differs.
4. Preserve lexical shadowing even when a local shares a qualified spelling.
5. Feed the referenced subset directly to borrowed-global normalization.
6. Initially allow nested lambdas to retain their existing local scan if a
   stable structural key is not yet available. Do not key facts by source
   location: synthetic nodes and repeated locations are valid.
7. Compare outputs with the old discovery path, then remove
   `unshadowed_global_values` whole-body rediscovery for top-level bodies.

Exit condition: value-reference facts are computed once by shared
infrastructure, no ownership-specific duplicate body scan remains, unrelated
globals do not cause borrowed-global passes, and output is unchanged.

Pitfall: a read set alone is insufficient for mutable assignments and
returned borrowed aliases. Preserve occurrence roles needed by ownership.

### 8. Extend body facts through nested lambdas

1. Choose a phase-local structural identity for nested lambda bodies or make
   the main traversal produce lambda facts as it visits them.
2. Include captures, shadowed parameters, nested matches, and globals used only
   by an inner lambda.
3. Ensure rewrites that rebuild expressions cannot leave facts attached to an
   obsolete node.
4. Replace nested-lambda global rescans only after old/new fact parity tests
   pass.

Exit condition: every body and lambda consumes exact facts collected once,
without relying on unstable source positions or source names.

### 9. Make ownership summaries exhaustive

1. Add explicit summary cases for every Core variant allowed at ingress.
2. Give ownership-neutral leaves explicit zero-use cases.
3. Give child-bearing forms explicit sequential, branch, or transfer
   composition. Do not apply one generic child fold to forms with different
   evaluation or lifetime semantics.
4. Reject forbidden forms before summary rather than handling them in a
   default arm.
5. Remove the catch-all call to `ownership_uses_from_legacy_count`.
6. Add a test that fails when the Core variant inventory and summary inventory
   diverge.

High-risk variants include tuple/tensor construction, packed/raw tensor
operations, dict/set/list operations, union reuse construction, ranges, raw or
semantic matches, and cooperative-control forms. Their correct disposition may
be "forbidden here", but it must be explicit.

Exit condition: adding a new Core variant produces a compile or inventory-test
failure until ownership behavior is chosen.

### 10. Represent repetition in structured ownership summaries

1. Add an explicit repetition mode or summary combinator for zero-or-more and
   one-or-more execution.
2. Characterize condition-versus-body consumes for `while`.
3. Characterize every supported `for` representation, including indexed,
   range, iterator, and collection forms.
4. Preserve `protect_repeated_consumes`: a value consumed in a repeated body
   needs a retained owner on every execution, not merely enough references for
   one linear evaluation.
5. Migrate `while` first, then one `for` family at a time.
6. Delete repetition call sites of `ownership_uses_from_legacy_count` once all
   forms use structured summaries.

Exit condition: loops preserve zero-iteration and repeated-consume semantics
without raw occurrence counts.

Counterexample: `max(branch uses)` is valid for mutually exclusive branches,
but not for a loop body that may execute repeatedly.

### 11. Retire the raw `count_uses` subsystem

1. List remaining callers after slices 9 and 10.
2. Replace Boolean "is touched" queries with the exhaustive summary's
   `touched` fact where scopes and call contracts match.
3. Where a caller needs syntactic occurrence rather than ownership use, add a
   narrowly named scope-aware occurrence query instead of retaining the full
   ownership count model.
4. Migrate task capture and borrowed-binding checks with dedicated regressions.
5. Replace the `count_uses` oracle in
   `test_compiler_match_owner_alias_liveness.brp` with the canonical
   ownership-event projection or a test-local scope-aware occurrence helper.
   Keep the semantic liveness regression.
6. Delete `count_uses`, its recursive helper tree, legacy conversion, and
   tests that assert only the obsolete implementation.

Exit condition: no ownership decision depends on an independent raw recursive
count, and one exhaustive summary model owns ownership-use semantics.

### 12. Make balancing strategies explicit

1. Replace `balance_nested_matches: Bool` with a variant such as
   `LinearBalance` / `DivergentBranchBalance`.
2. Rename `balance_let_body_legacy` to describe its actual linear balancing
   semantics only after the raw-count fallback is gone.
3. Migrate ordinary straight-line lets first.
4. Migrate concurrent bindings with task-capture and completion-lifetime tests.
5. Migrate non-releasing matches.
6. Migrate releasing constructor matches last, including cases where the
   owner is aliased, returned, consumed in one branch, or touched by a nested
   match.
7. Replace fallback-to-linear behavior with an explicit strategy decision at
   each caller.

Exit condition: balancing mode is visible in types and no function name or
Boolean implies obsolete behavior.

Pitfall: branch balancing can double-drop a releasing match owner because the
backend already releases the scrutinee root after branch execution.

Measured follow-up: broad generated signatures now avoid the balancing loop
only after an all-or-nothing post-insertion proof shows that the loop would be
an identity operation. This is intentionally not a second general balancing
algorithm. Extending its accepted grammar requires a counterexample where the
old balancing path materially emits an ownership node, plus exact artifact
parity.

### 13. Consolidate borrowed-value normalization

1. Measure traversal and allocation counts for 1, 8, and 32 managed borrowed
   parameters on an otherwise identical body.
2. Add event-parity cases with at least two borrowed parameters and two globals
   whose aliases interact. Record the current declaration-ordered,
   owner-by-owner global event order.
3. Build one set/catalog of borrowed owners with exact local or global
   identity, type, consumed status, and result policy.
4. First consolidate analysis into one traversal that produces an edit plan;
   replay edits in the current owner and declaration order.
5. Combine borrowed-call protection for all owners without changing event
   order.
6. Combine aggregate-member and returned-alias analysis only when their edit
   plans preserve the established order.
7. Only combine all three transformations into one visitor if ordering
   dependencies are represented explicitly and generated Core parity can be
   proved. Three body-wide passes are acceptable; three passes per owner are
   not.
8. Preserve shadowing independently for each owner and preserve aggregate
   transfer masks, call argument positions, result alias contracts, and match
   binding lifetimes.

Exit condition: borrowed normalization scales primarily with body size plus
number of referenced owners, rather than body size multiplied by owners.

Counterexample: two source variables with the same name but different hygiene
or definition identity cannot share one name-keyed borrowed-owner entry.

### 14. Consolidate user-call contract inference if measurements justify it

1. Benchmark functions with many managed parameters, long call chains,
   recursion, and strongly connected call cycles.
2. If per-parameter rescanning is material, collect per-variable ownership and
   dependency facts in one body traversal.
3. Preserve the current dependency-limited monotone worklist. Do not replace
   it with repeated whole-program rescans or an arbitrary iteration cap.
4. Preserve specialized callable identity and distinguish unresolved
   provisional borrow policy from final inferred contracts.
5. Compare inferred consumed-argument sets and dependency edges exactly before
   replacing the old implementation.

Exit condition: inference performs less repeated traversal with identical
fixed-point results. If measurements show it is not material, stop after the
benchmark and keep the simpler current worklist.

Measurement status (2026-08-13): replacing contract inference for the simple
parameter fixture did not move isolated-stage latency. Keep the current
worklist until call-chain, recursion, or strongly connected fixtures identify
a separate inference bottleneck. The measured 32-parameter cost was consumed
parameter balancing, addressed by the narrow proof documented above.

### 15. Split the environment into phase-specific contexts

1. Separate immutable program facts from inferred contract state.
2. Separate rewrite-local state from program-wide catalogs.
3. Replace remaining coupled flags with explicit variants.
4. Pass the narrowest context each helper needs.
5. Keep context records stack-friendly or borrowed where possible. Benchmark
   before introducing nested heap records merely for conceptual tidiness.
6. Move `perceus_env_for_managed_types` into test support and replace direct
   production-environment mutation in tests with focused constructors.

Exit condition: helpers cannot accidentally depend on unrelated Perceus state,
and tests construct only the facts relevant to their behavior.

### 16. Split the monolithic module along established dependencies

Perform this only after the APIs above are stable. A reasonable final layout
is:

1. ownership ingress validation and shared fact collection;
2. contract types and static lookup, with no inference dependency;
3. ownership-use summary algebra parameterized by a contract view;
4. fixed-point user-contract inference depending on summaries;
5. repetition and branch balancing;
6. mutable-assignment normalization;
7. borrowed/owned-result normalization;
8. drop insertion traversal; and
9. a small Perceus program orchestrator.

Move one responsibility per commit without semantic edits. Static contract
types and lookup feed the parameterized summary interface; fixed-point
inference depends on both; rewriting consumes the completed contract view and
summaries. It must not create a reverse dependency into inference. Shared
ownership ABI facts belong with `core_ownership`, not in a new generic utility
module.

Exit condition: `core_perceus.brp` is an orchestrator rather than a 19,000-line
ownership subsystem, and no import cycle or duplicated helper has been
introduced.

### 17. Remove compatibility surface and close the roadmap

1. Remove old names, adapters, fixture constructors, inventories, and comments
   that describe deleted paths.
2. Update `ARCHITECTURE.md`, `OWNERSHIP_MODEL.md`, and
   `COMPILER_ROADMAP.md` to describe only the final production boundary.
3. Run the dead-code audit and compilation checks over all compiler modules.
4. Run focused, sanitizer, leak, compiler, std, runtime, CLI, LSP, and package
   gates required by the touched boundaries.
5. Record final benchmark medians against the slice-1 baseline, with the same
   compiler mode and fixture checksums.

Exit condition: no production symbol or documentation refers to legacy
Perceus repair/count paths, and the measured result is reported without
combining unrelated compiler changes.

## Required Counterexample Matrix

Slice 1 must turn this planning matrix into a coverage ledger with exact test
names. `Existing` names are verified anchors, not proof that the full row is
covered. Rows marked `gap` need a failing or characterization test in the
owning slice.

| Area | Required counterexample | Existing anchor or gap | Slice / oracle |
| --- | --- | --- | --- |
| Global identity | Equal numeric ids in different modules | `test_qualified_global_names_isolate_module_local_ids` | 2-6 / exact identity |
| Global ambiguity | Same qualified name with distinct ids | `test_leaves_distinct_same_named_globals_ambiguous` | 2-6 / typed result |
| Duplicate identity | Exact duplicate agrees; conflicting metadata rejects | Dedup test exists; conflict is a gap | 5 / catalog result |
| Local identity | Same name with different hygiene `uniq` | Partial shadow tests; exact pair is a gap | 6 / ownership events |
| Parameter shadowing | Parameter shares a global spelling | `test_function_parameter_shadows_global_value` | 2-7 / resolved Core |
| Nested shadowing | Let, match, loop, resource, select, and lambda binders | `test_let_lambda_and_resource_scopes` plus resolver scope tests | 2, 6 / resolved Core |
| Global initializer | Self-reference differs from another global | `test_global_initializer_uses_declaration_scope` | 2-7 / exact identity |
| Mutable global | Exact assignment releases previous owner | `test_mutable_managed_global_assignment_releases_previous_owner` | 5-7 / ownership events + leak |
| Nested lambda | Global read plus captured same-named local | gap | 6, 8 / ownership events |
| Borrowed aggregate | Borrowed owner is stored and escapes | `test_managed_global_is_retained_when_stored_in_record` | 13 / events + runtime |
| Returned alias | Direct and contracted aliases become owned | `test_borrowed_managed_parameter_return_is_retained` | 9, 13 / events + leak |
| Branch ownership | One arm borrows, another consumes or aliases | `test_if_borrowed_branch_and_cow_consuming_branch_balance_independently` | 9, 12 / branch events |
| Repetition | Zero, one, and many iterations; consume in condition/body | Repeated-consume tests exist; zero/one split is a gap | 10 / events + runtime |
| Tail recursion | Loop/rebind aliases and consumes remain balanced | traversal scope test only; ownership output is a gap | 9-12 / events + runtime |
| Short circuit | Right arm ownership occurs only when evaluated | gap | 9 / branch events + runtime |
| Break/continue | Cleanup and post-loop ownership stay balanced | invariant tests only; ownership output is a gap | 9-12 / events + leak |
| Releasing match | Backend release and nested branch touch do not double-drop | `test_releasing_constructor_match_with_borrowed_literal_fallback_does_not_double_drop` | 12 / events + leak |
| List handoff | Source/result/length/output binders remain distinct | resolver scope test only; ownership output is a gap | 6, 9 / events |
| Select | Wait expressions differ from the selected arm; recv binder shadows | count-only test exists; ownership output is a gap | 6, 9 / events + runtime |
| Pre/post closure tasks | Both task representations preserve capture lifetime | count-only/late-invariant anchors; output is a gap | 6, 9, 13 / events + runtime |
| Recursive contracts | Direct and consuming mutual cycles reach one fixed point | Direct read-only recursion exists; consuming cycle is a gap | 4, 14 / exact contracts |
| Specialized calls | Specialized names retain distinct contracts | `test_specialized_functions_with_shared_def_id_keep_distinct_contracts` | 4, 14 / exact contracts |
| New Core form | Child-bearing variant cannot use a zero default | gap | 2, 9 / ingress rejection or events |
| Deep Core | Deep lets/sequences remain stack bounded | `test_deep_managed_let_chain_inserts_drops_without_stack_growth` | all / focused suite |
| Embedded variables | Dup/drop, assignment, tensor view, and match owner count | `test_raw_tensor_view_drops_source_after_body` plus assignment tests | 2, 6, 9 / events |

## Verification Ladder

Use the smallest useful gate continuously, then broaden at slice boundaries.

1. During editing, compile the touched module or run the smallest of the four
   resolver, Perceus, match-projection, and late-invariant suites.
2. After an ownership rewrite, run all four focused normal suites and compare
   canonical ownership-event projections.
3. Inspect pre/post-Perceus Core and generated C for representative changed
   cases.
4. Run focused source-level runtime and leak regressions whenever retain or
   release placement changes.
5. Run focused Perceus/pipeline tests under sanitizers after ownership
   rewrites, then run `scripts/test compiler-core-sanitize --serial` before
   each ownership merge.
6. Run `scripts/test compiler-blorp`, `make quality`, `git diff --check`, and
   the dead-code audit at merge boundaries rather than in the edit loop.
7. At milestones 3, 9, 13, and 17, run the full premerge gate plus
   `scripts/test compiler-core-sanitize --serial`. The premerge gate does not
   itself include the compiler Core sanitizer.
8. Run earlier broad gates when a slice changes shared Core types, ownership
   ABI, or pipeline routing.

Benchmark results should be considered actionable only when repeated samples
exceed run-to-run noise. A default guardrail is no more than a 5% median
regression in unchanged fixture dimensions, unless the slice intentionally
buys correctness and documents the tradeoff.

## Completion Criteria

The cleanup is complete when:

- Perceus accepts a validated ownership-ready Core artifact and performs no
  global-reference repair;
- exact identity catalogs replace parallel global list/index structures;
- ownership targets use exact local or definition identity, never name alone;
- other ownership-node producers are inventoried and their protocol nodes are
  preserved without duplicate balancing;
- every admitted Core form has explicit ownership-summary semantics;
- raw occurrence counting and legacy count conversion are deleted;
- balancing and inference modes are explicit variants, not Boolean policy;
- borrowed normalization is not multiplied by every irrelevant owner;
- contract consumers outside Perceus depend on a narrow ownership catalog;
- the module dependency graph follows the target architecture;
- focused, sanitizer, leak, and full production gates pass; and
- final benchmark results are recorded against a reproducible baseline.

The work should stop short of later ownership optimizations such as new field
moves, record/union reuse classes, non-atomic reference counts, or escape
analysis. Those depend on this cleanup but have distinct behavior and evidence
requirements.
