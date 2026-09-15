# Step 3c: Retain the Validated Body Table Across CTFE Handoff

**Status:** Implemented in the current worktree; Step 3 remains open.

## Context and invariant

Step 3a made `BodyOutcomeTable` the validated, module-scoped row store inside
the body materializers. Step 3b grouped CTFE worklist results once, but its
bridge still converted each group's checked rows to an outcome list for subset
materialization, then retained checked-row adjacency so ordinary seeded
completion could build another table. The same admitted outcomes therefore
crossed the bridge as a list and were validated twice.

This cut makes a table an explicit handoff product. Its representation carries
the accepted `BodyPlanProvenance` alongside definition-ID rows. A table
consumer checks that provenance against its registry's accepted body plan;
the table cannot silently be used with another graph/plan. The table is a
validated *partial* relation: it says each present row belongs to the plan,
not that every source body has been checked. Ordinary completion supplies
missing or policy-incompatible bodies from fresh contexts.

```blorp
private record BodyOutcomeTableRep {
	plan_provenance: BodyPlanProvenance,
	by_definition_id: Dict[Int, BodyCheckOutcome]
}

-- In the BodyOutcomeTableAccepted(table) branch of the table builder:
subset = body_check_registry_materialize_subset_from_table(registry, table)
ordinary = body_check_registry_materialize_complete_with_seed_table(
	registry, table, main_policy,
)
```

The bridge builds one table for **every** registered module, including a
module with zero checked bodies. An empty table is a valid partial CTFE
subset; omitting it incorrectly turns declaration-only/constructor-only
dependencies into eager fallback. A failing-first two-dependency fixture
protects this case. Tables are keyed by explicit module ID, not inferred from
names or source text. Once CTFE preparation finishes, the prepared graph
retains only the validated module tables; `CtfeCheckedBodyGroups` and their
worklist-order adjacency are transient.

Subset and seeded table consumers are direct APIs. The existing list APIs
remain boundary adapters and retain their established validation/error
ordering. For seeded completion, a reusable accepted row stays in the table;
only a missing or context-incompatible row is checked and replaced. Parsed
declaration order, rather than dictionary iteration or CTFE schedule order,
still drives ordinary output and diagnostics. The transient typed-function
projection for selective CTFE follows table insertion order, which is checked
worklist order as before.

## Implementation and fast feedback

1. Add direct table builder and consumers in `decl.brp`, with plan provenance
   checked at consumption and one shared complete-from-validated-seed loop.
2. Replace bridge-held checked-body outcome adjacency with graph-scoped
   `Dict[Int, BodyOutcomeTable]`; build each table once after worklist grouping.
3. Use the same table for CTFE subset and ordinary seeded completion. Keep
   empty tables, and release grouping after preparation.
4. Check accepted/rejected parity and cross-plan rejection in the focused
   body-order suite; check selected body reuse, declaration-only dependency,
   constructor, fallback, and CTFE counters in the CTFE profile suite.

Repeat during implementation:

```bash
bin/blorp test blorp/test/compiler/stage_06_typecheck/test_body_check_order.brp
bin/blorp test blorp/test/compiler/stage_07_ctfe/test_ctfe_typecheck_profile_benchmark.brp
python3 -m unittest blorp.test.compiler.stage_06_typecheck.support.test_declaration_boundary
scripts/compiler-check --changed
benchmarks/compiler_ctfe_typecheck_profile 3 24 32 retained selected
```

The structural suite guards the intended handoff directly: no retained
`CtfeCheckedBodyGroups` in the prepared context and direct table consumers
in both paths. The
failing-first bodyless-dependency fixture failed under a map that skipped
empty tables and passed once empty validated tables were retained.

## Resource screen and acceptance

The same-source committed Step 3b worker (SHA-256
`90b622c94e7e1a052bdbc6ef7089e1dc248119dc36dbcfbda69981678a213b69`,
6,355,184 bytes) and the final empty-table-corrected Step 3c worker (SHA-256
`b8255f9f21e526d26142316e739250822a35b354556b5d786f44efcdc4a91764`,
6,355,632 bytes) ran the
selected retained 3 × 24 × 32 workload. Checksum 2,538, 72 dependency body
checks, three reused checks, and 3 / 192 retained objects/bytes were unchanged.
Managed allocations/releases were 770,802 / 770,799 → 770,952 / 770,949:
150 more calls, or 0.020%. The later experiment retaining only selected
modules cost another 72 calls and introduced a seed-coverage risk, so it was
reverted. The empty-table correction is outside this workload's bodyless
case; the final worker retained the initial candidate's allocation counts.

Two warm direct `/usr/bin/time -l` pairs, in B → C then C → B order, gave:

| Pair | Step 3b instructions | Step 3c instructions | Step 3b peak footprint | Step 3c peak footprint | Step 3b RSS | Step 3c RSS |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 1,569,752,096 | 1,571,064,353 | 15,008,056 | 14,942,520 | 19,988,480 | 19,972,096 |
| 2 | 1,568,261,173 | 1,568,478,232 | 15,024,440 | 15,073,592 | 20,004,864 | 20,103,168 |

Instructions are 0.014–0.084% higher. Peak footprint and RSS split directions
within 0.5%. Worker size rose 448 bytes (0.007%). These samples remain within
the roadmap's guards, **not** evidence of a latency or majority-metric win.
There is no clean wall-time claim.

The 22-case body-order suite, 18-case CTFE suite, 56 structural checks, and
post-fix `scripts/compiler-check --changed` (8 suites) pass. The final
`scripts/test --no-build --serial compiler-blorp runtime leak` gate passed
4,555 compiler, 4,474 runtime, and 890 leak tests (9,919 / 9,919) in 5m25s.
The empty-table fallback is protected, parity/reuse counters hold, and the
final candidate stays below the roadmap's regression investigation thresholds.
The goal of this cut is one authoritative validated handoff; it does not meet
Step 3's full resource-win acceptance alone.

## What remains

`CtfeCheckedBodyGroups` still constructs transient per-module outcome lists
before table admission. Step 3 still needs an explicit source-order row
projection and a complete-body coverage contract, so schedule order cannot
be mistaken for output order and missing bodies cannot be treated as a
complete relation. A next bounded experiment can publish validated rows
directly from the CTFE worklist into module tables, removing the transient
group lists, but should retain the same provenance and empty-table tests and
be kept only if paired resource evidence justifies it.
