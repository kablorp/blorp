# Blorp 2: own constructor carriers and specialize's instance tables (2026-11-04)

## Summary

Specialize copied its function table on almost every instance it added. The
cause was an ownership inference gap, not specialize's code alone. The stack
lands as four changes:

- **Rule A.** A construction carries a stored parameter's obligation.
- **Rule B.** A loop exit links its carried outputs.
- **A requeue fix** in the label solver.
- **Brief I's Landing 1.** The specialize restructure, with fix (b).

**Final stack against main `a112fb1cd`:**
- -O2 instructions fall 1.20%.
- Strict allocations rise 0.76%, within the +0.8% bound Keith accepted
  2026-11-04.
- Function-table copies fall 84.60%.
- RC operations could not be measured at this base; see below.

The sections below record how this was reached.

**Earlier combined set (spike shape, before fix (b)) against base
`fc91dc310`:**
- -O2 instructions fall 0.83%.
- Atomic RC operations fall 6.5%.
- List copy volume falls 60–67%.
- Strict allocations rise 0.99%, which misses their ceiling. `own`'s extra
  inference work accounts for about 85% of the rise.

The function table's own copies fall 99.3%. Counting the Dict instance it
shares with the type tables whole, as brief I specifies, the fall is 84.6%:
just under the 85% target. The type tables still copy, and that is brief I's
Landing 2.

Rerun at `29c8fd40d`, with F2 merged:
- -O2 instructions: −1.11%;
- RC operations: −6.56%;
- allocations: +0.92%;
- function-table copies: −84.63%.

The allocation-site split and two bounded fixes are below. Keith chose fix
(b) and accepted the rest (2026-11-04), then asked for a proper Landing 1.
Landing needs his approval.

## Changes

| Commit | Change | Production lines |
| --- | --- | ---: |
| `e089000cc` | Rule A, in `reached_parameters` and `call_facts`: constructions (record, variant, list, closure environment) carry the one parameter obligation their stored owners carry | +41 (Keith accepted the +40 ceiling's overrun) |
| `70cc4af5e` | Rule B: `ExitLoop(Break)` links the loop's carried outputs, as a join yield does; the walk carries `Option[OwnedLoop]` | −1 |
| `769f1b16a` (also `28e54dc47` on base alone) | `requeue_callers` inlined into `solve_labels`, its only caller, so the worklist lists are updated in place instead of being copied through a record on each flip | −24 |
| `61533afa2` | Brief I's Landing 1. `append_entry` reads first. `expand_instances` and `prepare_function` thread their `Result` through owning steps. `prepare_user_call` defers static operand requests and passes the callee's request to `request_calls` directly (fix (b)). Written UFCS-first after main's `a112fb1cd`. | +54 (brief ceiling +60) |
| Own changes, against `fc91dc310` | | +16 (+84/−68); tests +292 |

The specialize restructure was first measured as a stacked spike on branch
`blorp2/i2-stacked-spike`, which does not land. Its commits there are
`d48156eaf` and `9aaa8ca0e`, with the requeue fix as `208aaf540`; the
originals are `c556e381c` (brief I's measured shape) and `4cbccc17d`.
Landing 1 replaces the spike.

**Merge with main's UFCS conversion (`a112fb1cd`).** `1382db073` merges it
into the pre-Landing branch. Only `own.brp` conflicted, in 5 hunks. The
resolutions keep the branch's semantics and use main's spelling.

That merge, plus Landing 1, was checked for spelling-only changes:
- The pinned seed's `compiler.c` for the merged tree matched the pre-merge
  branch's (`90fbc49d3`), once `expand_request`'s deliberate parameter
  reorder (now `outcome` first) was undone.
- One library function still differs, `dict.dict`. Main's own commit
  rewrote `max(0, min(…))` as `….min(…).max(0)`, which changes the order a
  literal is evaluated in.

## Correctness

Each tree passed `make -C blorp_2 test`:
- A on `cfe6f5827`;
- A+B;
- A+B+requeue;
- the requeue fix alone;
- the stacked set.

A, A+B and A+B+requeue also passed `scripts/blorp2-fixpoint --prove`.

**Own tests: 22 inference cases and 12 verifier cases.**
- Rule A's variant and record-update cases fail without A.
- The list and closure cases each fail when their arm is removed.
- The two loop cases (one loop, and nested loops) fail without B.
- The cases that must stay borrowed pass both ways:
  - a stored value read after the call;
  - a source dropped between the store and the call (a known limit);
  - two parameters in one container;
  - a loop output that is only returned.
- The verifier mutation (a moved owner dropped again) is rejected.

**Output identity.**
- The requeue fix alone produces byte-identical output against base.
- The stacked set produces byte-identical output against A+B.
- Rules A and B change the emitted C by design, because they change
  labels.

## Measurements

Fixed workload: each side's stage-2 compiler compiles the base source. The
best of three interleaved -O2 runs is used. Apple clang 21. The script is the
coordinating session's `measure_fixed_workload.sh`. Atomic RC operations come
from `blorp_2/scripts/attribution/run --stage rc` on each checkout's own
source, so the inputs differ by the diff under test (a proxy).

| Set, against its base | Strict allocations | -O2 instructions | RC operations | Output |
| --- | ---: | ---: | ---: | --- |
| A against `cfe6f5827` | 13,357,469 → 13,476,042 (+0.89%) | 11.365 G → 11.466 G (+0.89%) | 234.01 M → 236.02 M (+0.86%) | differs (labels) |
| A+B against A (`fa10edda4`) | 13,497,261 → 13,503,540 (+0.05%) | 11.468 G → 11.466 G (−0.02%) | 236.09 M → 236.36 M (+0.12%) | differs (labels) |
| Requeue fix alone against `fc91dc310` | 13,359,818 → 13,358,583 (−0.01%) | 11.358 G → 11.334 G (−0.21%) | 234.08 M → 233.87 M (−0.09%) | identical |
| Stacked (A+B+specialize) against A+B | 13,504,294 → 13,513,390 (+0.07%) | 11.482 G → 11.297 G (−1.61%) | — | identical |
| Stacked against `fc91dc310` | 13,359,818 → 13,493,757 (+1.00%) | 11.354 G → 11.282 G (−0.63%) | 234.08 M → 219.14 M (−6.38%) | differs (labels) |
| **Combined (stacked + requeue) against `fc91dc310`** | **13,359,818 → 13,492,318 (+0.99%)** | **11.348 G → 11.254 G (−0.83%)** | **234.08 M → 218.96 M (−6.46%)** | differs (labels) |

The ceilings came from the I2 brief. Instructions (≤ +0.5%) and RC operations
(≤ +0.2%) pass on the combined set. Allocations (≤ base) do not.

Combined list copies, by the raw script rows:
- fallback: 20.71 M → 8.20 M slots;
- borrowed: 27.80 M → 9.18 M slots.

### Function-table copies (brief I's definition)

The counted rows are:
- `specialize.append_entry` for `IndexedList[FunctionRequest]`: the entries
  append and its bucket;
- the positions Dict's `dict.appended` and `dict.set`.

That Dict instance is shared with the union and record tables, so it is
counted whole.

| Row | A+B | Stacked |
| --- | ---: | ---: |
| Entries append | 5,292,631 | 3,013 |
| Bucket append | 34,115 | 34,115 |
| `dict.appended`, positions instance | 13,192,715 | 2,906,861 |
| `dict.set` | 1,469,662 | 139,215 |
| **Total** | **19,989,123** | **3,083,204 (−84.58%)** |

- After the change, the function table's entries are unique when they
  grow: 3,254 appends, and 2 copies.
- The bucket residual (34 K slots) is the `get` reference into the Dict,
  which brief I accepted.
- The 2.9 M left in the shared Dict instance comes from the union and
  record tables, which are still borrowed: 1,255 `dict.appended` copies.

The same measurement against `fc91dc310` gives 19,952,300 → 3,079,449
(−84.57%).

### Where the allocation overrun comes from

These figures come from the attribution allocation stage on each checkout's
own source, so the total is +149,812 here against +132,500 on the fixed
workload.

| Module | Base | Combined | Change |
| --- | ---: | ---: | ---: |
| `own` | 1,620,593 | 1,733,658 | +113,065 |
| `specialize` | 2,356,440 | 2,379,176 | +22,736 |
| `dict` | 51,043 | 41,928 | −9,115 |

**`own`.**
- More labels mean more analyses and insertions.
  - Inference counters on `main.brp`, base → A (on `cfe6f5827`): seeds
    264 → 287, analyses 480 → 545, flips 344 → 384, owned labels 366 → 409,
    instances owning a parameter 335 → 372.
  - These were counted with a scratch patch that was not landed.
- `carried_union` adds 15.6 K. `Carried` is a boxed union, so each
  `CarriesParameter` built in the new fold allocates.

**`specialize`.** The threaded loops of the specialize shape add allocations
of their own. That shape measured +20.5 K by itself on `df06da9aa`.

**Not done** (needs owner approval): narrowing the scan, so that unmanaged
or multi-parameter containers do not seed provisional analyses.

## Rerun at `29c8fd40d` (F2 merged)

F2 was merged into the branch as `8559a68fe` and into the stacked spike as
`b1a5e3e80`. Resolving the stacked merge needed one change: F2's
`converted_parameter_environments` step became a `?=` step between the
creations loop and the calls loop. The base worktree is at `29c8fd40d`.

**Gates at the new base.**
- The brief's repro rows match its table: the base is unchanged, and on the
  branch `start`, `relabel` and `fill` are owned while cases 3, 3b and 4 stay
  borrowed.
- On the branch, `make -C blorp_2 test` and `scripts/blorp2-fixpoint --prove`
  pass.
- On the stacked set, `make -C blorp_2 test` passes, and its output is
  byte-identical to the branch's.

| Against `29c8fd40d` | Strict allocations | -O2 instructions | RC operations (proxy) | Function-table copies |
| --- | ---: | ---: | ---: | ---: |
| Combined (stacked + requeue) | 12,529,688 → 12,644,841 (+0.92%) | 11.060 G → 10.937 G (−1.11%) | 234.22 M → 218.86 M (−6.56%) | 20,093,674 → 3,088,130 (−84.63%) |

List copies on the combined set:
- fallback: 20.85 M → 8.23 M slots;
- borrowed: 27.99 M → 9.22 M slots.

### Allocation sites on the fixed input

Each side's measured stage-2 compiler was built with `BLORP_ALLOCATION_SITES`
and run on `29c8fd40d`'s source. All three runs are leak-balanced.

| Compiler | Allocations | Step |
| --- | ---: | ---: |
| Base | 12,529,688 | |
| Branch (own A + B + requeue) | 12,635,745 | +106,057 |
| Stacked (+ specialize shape) | 12,644,841 | +9,096 |

**Own, +106,057.**

| Site | Change | Cause |
| --- | ---: | --- |
| `own.carried_union` | +15,754 (56,309 → 72,063) | Tuple: `match (left, right)` builds a heap tuple per call (`blorp_record_make_539`). Rule A's scan and walk call it more often. |
| `own.build_definition` | +11,755 | |
| `own.insert_steps` | +11,030 | |
| `list.map` | +7,200 | |
| `own.leave_with` | +6,771 | |
| `own.solve_labels` | +5,267 | |
| `own.pass_arguments` | +5,229 | |
| Other own insertion sites | about +43,000 | |

Every row except `carried_union` is insertion work for the extra analyses
(480 → 545 on `main.brp`).

**Specialize, +9,096 net.**
- **New costs, +21,761:**
  - 11,065 `CallRequest` records (`blorp_record_make_524`);
  - 10,696 appends to the requests list, one per user call: the callee's
    request.
- **Savings, −12,665:** the copies removed save −7,916 in `dict.appended`,
  −3,474 in `append_entry` and −1,275 in `dict.set`.
- The `PreparedInstances` records are unchanged: 137,125 before and after.

### Bounded fixes inside the brief's scope (not done)

**`carried_union` without a tuple.**
- Use nested matches on `left` and `right`.
- It removes all 72,063 of these allocations, including base's 56,309.
- It is about +4 lines in `own.brp`.

**Request the callee directly in `prepare_user_call`.**
- Pass the callee's key and span to `request_calls` beside the operand
  requests, instead of appending it to the list.
- It removes about 10,700 `CallRequest` records, and the list allocation
  for every call without callable operands: about −21,000.
- It is about +3 lines in specialize.

**No bounded fix for the rest of own's +90 K.** It is the price of 43 more
owned labels: more provisional analyses and insertions. Reducing it means
narrowing the scan (option 3), which needs approval first.

**With both fixes, estimated against `29c8fd40d`:**

| Base used | Estimate |
| --- | ---: |
| Base without the tuple fix | 12,644,841 − 72,063 − ~21,000 ≈ 12,551,800, which is +22 K (+0.18%) |
| Base with the same tuple fix | 12,473,379, which makes it +78 K (+0.63%) |

The fixes leave allocations above base either way.

## Final measurement at main `a112fb1cd`

Branch tip `61533afa2`. The base worktree is at `a112fb1cd`; the pre-Landing
worktree is at `1382db073`.

**Gates on the branch.**
- `make -C blorp_2 test` passes, with all 118 suites.
- `scripts/blorp2-fixpoint --prove` passes.

| Set | Strict allocations | -O2 instructions | Output | Function-table copies |
| --- | ---: | ---: | --- | ---: |
| Landing 1 against `1382db073` | 12,446,039 → 12,434,141 (−0.10%) | 10.959 G → 10.759 G (−1.82%) | identical | 20,017,283 → 3,076,314 (−84.63%) |
| Whole stack against `a112fb1cd` | 12,326,514 → 12,420,652 (+0.76%) | 10.869 G → 10.738 G (−1.20%) | differs (labels) | 20,006,427 → 3,081,637 (−84.60%) |

**Function-table rows.**

| Row | Before | After |
| --- | ---: | ---: |
| Entries append | 5,260,146 | 3,005 |
| Bucket append | 32,512 | 32,512 |
| Shared positions Dict (`dict.appended`) | 13,251,135 | 2,904,055 |
| `dict.set` | 1,462,634 | 142,065 |

Fix (b) turned Landing 1's own allocation cost from +9 K into −12 K.

**RC operations at this base could not be measured.** The attribution
script's marker step (`patch_emit_markers`) anchors on emit source text that
main's emit-writer and UFCS changes rewrote. It fails on the base as well
("anchor found 0 times"). This is tooling breakage on main, reported rather
than worked around. RC measured −6.46% at `fc91dc310` and −6.56% at
`29c8fd40d`.

## Raw data

Raw data lives in the I2 session's scratchpad (`a_run/`, `s_run/`, `r_run/`,
`alloc_*`) and is not committed. Each fixed-workload directory holds
`summary.txt`, `self.c`, `out.c` and `copies/prof.tsv`. Each RC directory
holds `tables/rc.md`.
