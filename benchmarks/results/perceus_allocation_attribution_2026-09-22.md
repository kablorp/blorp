# Perceus allocation attribution (2026-09-22)

Step 0 of `docs/CORE_ID_MIGRATION.md`: a per-helper allocation profile of the
Perceus pass on the real frozen self-compile, to size steps 3 and 5.
Measurement only; no production code changed (confirmed below with
`--require-identical`).

## Go / no-go for steps 3 and 5

- **Which helpers exceed 5% of the `pass_perceus_complete` row (59,724,735
  allocations, measured by the harness on this same input):**
  `infer_user_call_contracts` alone, at **5.36%** (3,198,836 allocations, one
  real call on the real self-compile program -- not a sample). `build_env`
  (0.12%) and every other helper measured, including the ones the roadmap
  names as step 3/5 candidates, are each under 0.2% of the total, whether
  measured directly (`build_env`) or as a per-call rate from a real-data
  sample scaled to the sample's own call count (see the table and its
  caveats).

- **Is identity resolution (name-keyed lookups, catalogs, fallbacks) or a
  synthetic name string among the helpers that exceed 5%?** No.
  `infer_user_call_contracts` is the only helper over 5%, and it is not a
  step 3 or step 5 target: it builds `OwnershipCallableIndex` and
  `UserCallContractTable`, which are keyed by **definition ID**
  (`candidate_ids_by_def_id: Dict[Int, List[OwnershipCallableId]]`,
  `perceus.brp:676`), and runs the contract-solver fixpoint (the
  `perceus_work_contract_solver_*` counters in `perceus.brp:216-300`) --
  declaration-graph work, not variable-identity resolution. The roadmap's
  own step 3 text says as much: "Do not convert `PerceusEnv`'s global and
  constructor lookups here; they are keyed by declaration names, not
  variables, and they are built once." The step 3 candidates that *are*
  variable-identity-keyed by name (`count_uses`, the
  `summarize_linear_ownership_uses` family, `rewrite_mutable_assignments`,
  `protect_repeated_consumes`, `BorrowedOwnerCatalog.candidate_ids_by_name`)
  each show low per-call and low sampled-aggregate allocation counts (well
  under 1% of the total at the sampled scale -- see caveats below on why
  that is not the same claim as "under 1% of the total pass"). The step 5
  synthetic-name-string constructors (`synthetic_binding_var`,
  `mutable_assignment_temp_var`) cost exactly 3 and 4 allocations per call
  respectively, matching the roadmap's "one to three per synthetic binder"
  prediction, and are real, measured, unconditionally-incurred allocations
  that step 5 removes -- worth doing regardless of aggregate share, since
  every synthetic binder today pays for a string plus its `String`/record
  boxing that has no reason to exist once names come from a shared
  allocator.

**Recommendation:** step 3 is not shown by this profile to move the needle
on raw allocation count in aggregate (the identity-keyed helpers are cheap
per call), so its value is the correctness argument the roadmap already
makes (shadowing bugs in the name-only fallback), not an allocation win.
Step 5's per-binder saving is real but small in aggregate share; still
worth landing since it is unconditional (every synthetic bind pays it) and
composes with step 6. Neither is contraindicated by this data. A precise
full-pass call count for the identity-keyed helpers (as opposed to this
profile's real-data sample) would need internal instrumentation beyond a
public-entry or one-line-visibility measurement; see "What this profile
could not measure" below.

## How the late Core was obtained

The roadmap's suggested command,
`bin/blorp compile --dump-core-after=dict_literal_ownership --dump-core-file <path> ...`,
does not work: `dict_literal_ownership` is not one of the CLI's exposed
`--dump-core-after` stage names (`CORE_STAGE_NAMES` in
`blorp/src/compiler/stage_09_core/stage_manifest.brp` only exposes the
coarser names: `lower, debug, desugar, mono, synth, match, trait_resolve,
resolve, std_inline, tailrec, fusion, specialize, dce, consume_specialize,
perceus, reuse, closure, final`).

This profile instead drives the pipeline itself, per the roadmap's other
option ("or drive the pipeline inside the profile program to that point").
It dumps Core once, right after DCE (`--dump-core-after=dce
--dump-core-file=<path>`, the last stage name before Perceus that the CLI
does expose), decodes that JSON with `decode_core_program_json`
(`ir.brp:15065`), and then advances it through the exact same public pass
functions `stage_09_core/pipeline.brp` calls in production order --
`run_consume_specialize_pass`, `run_static_string_literals_pass`,
`run_record_update_ownership_pass`, `run_dict_literal_ownership_pass` -- to
reach the Core state immediately before Perceus. This is the DCE profile's
own model (`benchmarks/blorp/profiles/dce_facts_builder_allocations.brp`
drives `value_references`, a production entry point, in-process) extended
to reach a pipeline point the CLI cannot dump directly, rather than
reimplementing any pass logic.

## Table

Frozen input: `benchmarks/self_compile_measure freeze --rev origin/main`
(commit `afd0d6f6899294a7ca015b922fa2fa659fb61ff1`). Program: the full
self-compile (`blorp/src/main.brp`), 18,561 post-DCE declarations, 18,633
declarations and 15,270 functions (1,640 lambdas, 60 global initializers;
functions + lambdas + global initializers = 17,984 "regions") at the point
immediately before Perceus.

Reference row from the harness, same input:
`pass_perceus_complete` = **59,724,735** allocations
(`benchmarks/self_compile_measure --input-rev origin/main --samples 1`).
This profile's own whole-pass measurement of the identical computation
(`insert_drops_program` called directly on the same late Core) reported
**59,724,731** -- four fewer, which is noise from where each harness starts
counting around the call, and itself confirms this profile's
pipeline-reconstruction of the late Core is faithful to production's.

| Helper | Calls | Allocations | Allocations/call | Share of 59,724,735 | Measured how |
| --- | ---: | ---: | ---: | ---: | --- |
| `insert_drops_program` (whole pass) | 1 | 59,724,731 | 59,724,731 | 100.00% | Real, single call, real data |
| `infer_user_call_contracts` (`perceus.brp:21236`) | 1 | 3,198,836 | 3,198,836 | **5.36%** | Real, single call, real data |
| `summarize_linear_ownership_uses` + non-binding variant + `summarize_linear_call` (`perceus.brp:4887/4286/2730`) | 731 | 104,313 | 142 | 0.17% *(sample only, see caveats)* | Real calls, sampled |
| `build_env` (`perceus.brp:1479`) | 1 | 69,917 | 69,917 | 0.12% | Real, single call, real data |
| `rewrite_mutable_assignments` (`perceus.brp:11337`) | 873 | 63,696 | 72 | 0.11% *(sample only)* | Real calls, sampled |
| `stabilize_nested_assignment_rhs` (`perceus.brp:10239`) | 873 | 36,074 | 41 | 0.06% *(sample only)* | Real calls, sampled |
| `protect_repeated_consumes` (`perceus.brp:13467`) | 873 | 32,816 | 37 | 0.05% *(sample only)* | Real calls, sampled |
| `mutable_assignment_temp_var` (`perceus.brp:8703`) | 2,000 | 8,000 | 4 | n/a (synthetic) | Synthetic loop, exact per-call cost |
| `synthetic_binding_var` (`perceus.brp:14216`) | 2,000 | 6,000 | 3 | n/a (synthetic) | Synthetic loop, exact per-call cost |
| `count_uses` (`perceus.brp:5032`) | 731 | 294 | 0 | 0.0005% *(sample only)* | Real calls, sampled |
| `build_borrowed_owner_catalog` (`perceus.brp:22156`) | 1 | 3 | 3 | n/a (1 sample of 17,984 real calls) | Real call, 1 of 17,984 regions |
| `count_uses_in_*` (13 helpers, `perceus.brp:2308-2539`) | -- | -- | -- | -- | Reached only inside `count_uses`; no public entry to isolate them further (see below) |
| `CoreVar` constructors other than the two above (`perceus.brp:5435, 14929, 14937`) | -- | -- | -- | -- | Static sites only, not separately measured (see below) |
| `OwnershipUseSummary` records (`perceus.brp:2000-2005`) | -- | -- | -- | -- | 4-scalar-field record; cost folded into `summarize_linear_ownership_uses` above (see below) |

`build_borrowed_owner_catalog`'s row is one representative call (the first
function in the program with parameters), not a trace: production calls it
once per region, and this run found 17,984 regions. Multiplying the
per-call cost by the region count gives a rough estimate of order 54,000
allocations (0.09% of the total) for that helper across the whole pass --
small, and explicitly an estimate, not a measured total.

### `perceus_work_*` fallback counters (`perceus.brp:216-300`, consumed by `work_profile.brp`)

These are `@debug_only` marker functions; the roadmap's own comment on them
says the dynamic call counts come from "a separately built benchmark worker
[using] the ordinary function profiler's exact call counts" -- a
`--profile-mode`/`FunctionProfileExact` instrumented build measuring
production's own emitted C, a different measurement path from the
`MemStats` allocation counters this profile uses. Getting dynamic counts
for them was out of scope for this pass; they were enumerated statically
and classified by cause instead:

- **Missing identity** (the `has_unresolved_identity` / alias-fallback
  path this migration removes): `perceus_work_borrowed_call_alias_fallback_requests`,
  `perceus_work_borrowed_aggregate_alias_fallback_requests`,
  `perceus_work_borrowed_result_alias_fallback_requests`.
- **Unsupported expression shape**: `perceus_work_contract_scalar_fallback_analyses`,
  `perceus_work_contract_dup_fallback_analyses`,
  `perceus_work_contract_shadow_fallback_analyses`,
  `perceus_work_legacy_count_node_visits`.
- **Missing ownership summary** (the "no contract, fall back to full
  ownership-use summary" path in `summarize_linear_call`): the `None` arm
  of `summarize_linear_call` (`perceus.brp:2730`), which is the same call
  this profile already samples through `summarize_linear_ownership_uses`
  above; not separately counted by a dedicated marker.

## What this profile could not measure, and why

- **Exact full-pass call counts for the per-node helpers** (`count_uses`,
  the `summarize_linear_ownership_uses` family, `rewrite_mutable_assignments`,
  `protect_repeated_consumes`, `stabilize_nested_assignment_rhs`,
  `build_borrowed_owner_catalog`). These are called from deep inside
  Perceus's own per-function traversal, not once per program; reproducing
  their exact call frequency would mean either instrumenting the real call
  sites inside `perceus.brp` (a larger, more invasive temporary change than
  the one-line-per-declaration visibility edit this profile used) or
  reimplementing Perceus's own dispatch (which would measure this profile's
  copy, not production's). This profile instead calls each helper on real
  arguments from the real decoded program -- real names, real function
  bodies, real `CoreVar`/`CoreType` values -- for up to 400 real functions
  (`SAMPLE_FUNCTION_LIMIT`) or every `AssignExpr` found in those functions
  (capped at 3 per function), which gives a true per-call allocation rate
  but not a true total. A linear extrapolation from the 400-function sample
  to all 15,270 functions (roughly 38x) would put
  `summarize_linear_ownership_uses` at very approximately 4,000,000
  allocations (~6.7% of the total) and the others proportionally lower;
  this is not reported as a table row because nothing here established
  that call frequency scales linearly with function count.
- **`count_uses_in_*` (13 helpers)**: reached only through `count_uses`'s
  own internal dispatch on specific expression shapes (dict entries, match
  cases, etc.); there is no public entry that calls them individually, and
  making 13 more declarations temporarily public to call them with
  hand-built matching sub-expressions was judged not worth the risk of
  further destabilizing measurement given the two real correctness/perf
  traps this pass already hit (below). Their cost is included in
  `count_uses`'s row above.
- **`OwnershipUseSummary` records** (`perceus.brp:2000-2005`): a 4-scalar
  `record` (`required_refs, consumed_refs, touched, returns_alias`); its
  allocation cost is inseparable from the traversal that builds it
  (`summarize_linear_ownership_uses`) and is folded into that row.
- **`CoreVar` constructors other than `synthetic_binding_var` and
  `mutable_assignment_temp_var`** (`perceus.brp:5435, 14929, 14937`): these
  are inline record-literal sites inside other private helpers already
  covered above (e.g. inside `rewrite_mutable_assignments`'s own rewrite
  logic), not separately callable; their cost is folded into those rows.
- **Dynamic `perceus_work_*` counts**: see above -- needs the
  `FunctionProfileExact` instrumented-build path, not this profile's
  `MemStats` approach.

## Two things this measurement found the hard way

1. **A closure passed to a generic higher-order function defeats Perceus's
   own reuse/uniqueness fast path at that closure's call site.** The first
   version of this profile measured every helper by wrapping its call in a
   `pure () -> T` closure and passing that closure to a generic `measured[T]`
   helper (`reset_mem_stats(); f(); get_mem_stats()`). For `insert_drops_program`
   specifically, called that way on the real 18,633-declaration self-compile
   program, the run did not finish in over 30 minutes (confirmed twice, with
   the child process still consuming CPU after `timeout` killed its wrapper).
   Calling `insert_drops_program` directly, as an ordinary statement with no
   enclosing closure, on a `late_core` value with no other live reference,
   finished in line with the production harness (as the table's near-exact
   match to `pass_perceus_complete` shows). The likely mechanism: Perceus's
   ownership analysis of a callee's own body can tell whether a *directly
   passed* argument is the call's last use, but a variable captured by a
   closure that is itself passed across a generic function boundary is not
   analyzable the same way, so the argument is treated as shared and every
   downstream record update takes the copying path instead of the in-place
   one -- turning a several-second pass into one that does not finish.
   Every measurement in the final table above uses a direct
   `reset_mem_stats()`/`get_mem_stats()` bracket around an ordinary call,
   never a closure, for this reason.
2. **A closure created inside a `0..N` range `for` loop and passed to a
   generic function crashes this compiler at compile time** (confirmed
   independent of anything specific to this profile -- reduced during this
   measurement to a four-line repro: a `pure () -> CoreVar` closure created
   inside `for index in 0..N:` and passed to a one-line generic `measured[T]`
   wrapper segfaults `bin/blorp compile`; the same closure created inside
   `for index in [0, 1, ..., N]:` over a materialized list does not). The
   synthetic-constructor loops in this profile build the index list first
   and iterate that, to avoid the crash. This is a real compiler bug, out of
   scope to fix here (measurement only); worth a follow-up issue.

## Exact commands

```bash
# Freeze and dump post-DCE Core for the frozen self-compile
base=$(git rev-parse origin/main)
input_dir=$(benchmarks/self_compile_measure freeze --rev "$base")
bin/blorp compile --no-format --no-embed-runtime \
  --std-dir "$input_dir/standard_library/src" \
  -o /tmp/self.c \
  --dump-core-after=dce --dump-core-file=/tmp/post_dce_core.json \
  "$input_dir/blorp/src/main.brp"

# Reference row from the harness, same input
benchmarks/self_compile_measure lock -- \
  benchmarks/self_compile_measure --input-rev origin/main --samples 1
# -> pass_perceus_complete allocs + 59,724,735

# This profile, same input (driver also freezes/dumps on its own if
# BLORP_PERCEUS_DUMP_FILE is not set)
BLORP_PERCEUS_DUMP_FILE=/tmp/post_dce_core.json BLORP_PERCEUS_SKIP_BUILD=1 \
  benchmarks/compiler_perceus_allocations

# No-production-change confirmation (parent baseline taken before any edit)
benchmarks/self_compile_measure lock -- \
  benchmarks/self_compile_measure --program small --input-rev origin/main \
  --samples 1 --baseline /tmp/parent_small.json --require-identical
# -> output C : IDENTICAL (45827 vs 45827 bytes); every alloc row +0.00%
```

The private-helper numbers in the table (`infer_user_call_contracts`,
`build_borrowed_owner_catalog`, the `summarize_linear_ownership_uses`
family, `rewrite_mutable_assignments`, `protect_repeated_consumes`,
`stabilize_nested_assignment_rhs`, `synthetic_binding_var`,
`mutable_assignment_temp_var`, and the `BorrowedOwner*` types they need)
were captured with those fifteen declarations in
`blorp/src/compiler/stage_09_core/perceus.brp` temporarily changed from
`private` to non-private (a one-line-per-declaration edit: dropping the
leading `private ` token, nothing else), so a variant of
`benchmarks/blorp/profiles/perceus_allocations.brp` with more imports could
call them directly, then reverted (`git checkout --
blorp/src/compiler/stage_09_core/perceus.brp`) before committing. The
committed profile program only imports and calls what is public today
(`insert_drops_program`, `build_env`, `count_uses`), plus a static traversal
of the decoded program for the region count. Reproducing the full table
means re-applying that same visibility change locally; the exact
declarations are: `BorrowedOwnerOriginKind`, `BorrowedOwnerOrigin`,
`BorrowedOwnerEntry`, `BorrowedOwnerRegionKind`, `BorrowedOwnerCatalog`,
`MutableAssignmentRewrite`, `summarize_linear_call`,
`summarize_linear_ownership_uses_non_binding`,
`summarize_linear_ownership_uses`, `mutable_assignment_temp_var`,
`stabilize_nested_assignment_rhs`, `rewrite_mutable_assignments`,
`protect_repeated_consumes`, `synthetic_binding_var`,
`infer_user_call_contracts`, `build_borrowed_owner_catalog`.

## Note for the perceus.brp module split

A separate worker is splitting `perceus.brp` into `stage_09_core/perceus/`
modules on another branch. This task made no production change (the
temporary visibility edit was fully reverted before committing), so there
is nothing to merge on that front. If a future step needs the private-helper
measurement to become a standing, re-runnable benchmark rather than a
one-time documented run, the smallest hook consistent with "keep the
production hot path free of new branches" would be a handful of `@debug_only`
public re-export functions (one per helper, each a one-line forwarding
call), analogous to the existing `perceus_work_*` markers -- not a change
to the helpers' own visibility or logic.
