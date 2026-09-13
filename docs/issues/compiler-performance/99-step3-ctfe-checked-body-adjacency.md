# Step 3b: Group CTFE Checked Bodies Once

**Status:** Implemented and screened in the current worktree. Step 3's
validated-table handoff remains open.

## Why this cut

The CTFE body worklist returns checked bodies in scheduling order. Before this
cut, the typecheck bridge filtered and mapped that flat list for the target
and again for every dependency. It also retained an optional outcome list in
each selective dependency and a separate target outcome field. The cost of
preparing *M* dependencies from *B* checked bodies was proportional to
*M × B*, even though each checked body has one exact module owner.

The bridge now builds one private graph-scoped adjacency from the worklist's
checked rows:

```blorp
private record CtfeCheckedBodyGroupsRep {
	rows: List[CtfeCheckedBody],
	chain_by_module_id: Dict[Int, CtfeModuleBodyChain],
	next_row_index: Dict[Int, Int]
}
```

Each module chain stores its first row, last row, and count. For a checked row,
construction links the previous tail to the new row and updates the tail. It
does not append to a list still retained by a dictionary: that would force
copy-on-write prefix copies and become quadratic for a wide single module.
The flat list is the one retained `BodyCheckOutcome` carrier; adjacency holds
only row indices and counts. Reading one module follows its links in worklist
order and creates a transient outcome list for the existing materializer. The
target and dependency contexts no longer own their own outcome-list fields.

The adjacency is derived from worklist-accepted rows and does **not** itself
prove `BodyOutcomeTable` provenance, ownership, or complete source-body
coverage. `body_check_registry_materialize_subset` still validates and builds
a module outcome table, and ordinary seeded completion validates again. This
is a scan-elimination packet, not the final validated-table handoff. No
parallel *retained* outcome authority is introduced, but transient outcome
lists and validation table rebuilds remain.

## Fast feedback and guards

- A failing-first structural check requires one grouping call, no per-module
  filter of `checked`, and no target/dependency outcome-list fields.
- The CTFE profile suite includes selected-module reuse of two bodies and a
  16-body single-module chain. The latter catches missing adjacency links and
  exercises the COW-sensitive shape missed by a one-body-per-module profile.
- Existing recursive, rejected, unresolved-dispatch, no-callable-root, and
  selected-module fixtures preserve fallback and reuse behavior.
- Use `scripts/compiler-check --changed` for the owning typecheck/CTFE suites,
  then `scripts/test compiler-blorp runtime leak` after the cut is stable.

The final 17-case CTFE suite and `scripts/compiler-check --changed` (8 suites)
pass after the adjacency revision. The broad serial compiler/runtime/leak gate
also passed 9,916/9,916, but began before the final adjacency edit, so it is a
provisional broad snapshot rather than final verification of that edit.

## Paired resource screen

Both workers used the same `compiler_ctfe_typecheck_profile.brp` source, Apple
clang 21.0.0 with `-O2 -fwrapv`, and Darwin 25.6.0 arm64. The immediate Step 3a
worker is SHA-256
`527a8347681f52ed8c7e66f319be351c998518ef1930eeeb392341148a60a2ca`
(6,354,784 bytes); the Step 3b worker is
`90b622c94e7e1a052bdbc6ef7089e1dc248119dc36dbcfbda69981678a213b69`
(6,355,184 bytes). The selected 3 × 24 × 32 retained workload kept checksum
2,538, 72 dependency body checks, three reused bodies, and 3 / 192 retained
objects/bytes. Managed allocations/release calls fell from
772,599 / 772,596 to 770,802 / 770,799: 1,797 fewer allocations (0.233%).

Direct workers were run in alternating order with `/usr/bin/time -l`:

| Pair | Order | Step 3a instructions | Step 3b instructions | Step 3a peak footprint | Step 3b peak footprint | Step 3a RSS | Step 3b RSS |
| ---: | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Cold | 3a → 3b | 1,593,034,543 | 1,569,690,385 | 14,975,288 | 15,024,440 | 19,972,096 | 20,004,864 |
| Warm 1 | 3b → 3a | 1,572,795,108 | 1,569,326,810 | 15,024,464 | 15,040,848 | 20,004,864 | 20,004,864 |
| Warm 2 | 3a → 3b | 1,572,585,471 | 1,569,689,542 | 15,024,464 | 15,090,000 | 20,004,864 | 20,054,016 |

The cold run had 295 baseline page faults versus 10 candidate faults; its
instruction delta is not used to claim a larger win. The two warm pairs show
0.18–0.22% fewer instructions. Peak footprint is 0.11–0.44% higher, maximum
RSS is flat to 0.25% higher, and worker size is 0.006% higher, all below the
roadmap investigation thresholds. In-process elapsed values favored the
candidate in these short runs, but no latency win is claimed. The non-selected
3 × 24 × 32 retained guard kept checksum 2,916 and 3 / 192 retention while
allocations fell 766,338 → 764,535; it does not exercise seeded completion.

## Next cut and acceptance boundary

Step 3c should make validated module-scoped `BodyOutcomeTable` rows the CTFE
handoff product, then have subset materialization and ordinary seeded
completion consume those rows without rebuilding the table. The worklist's
schedule order and source output order remain distinct; source-order rows and
complete-body coverage must be explicit before Step 3 can close. Accept this
packet only if paired resource measurements show no guard regression; do not
count its scan deletion alone as Step 3's majority-metric resource win.
