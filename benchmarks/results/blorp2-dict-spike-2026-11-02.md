# Blorp 2 Dict phase 0 spike, 2026-11-02

Measures the prototype `blorp_2/standard_library/dict.brp` against the design in
`blorp_2/DICT_PLAN.md`, the compiler's `HashMap` (`blorp_2/src/utils/hash_map.brp`)
and the legacy compiler, then proposes the phase 1 ceilings.

## Provenance

- Base `616961cba` (origin/main); the spike is commit `f342a8039` on branch `blorp2-dict-spike`. Its prototype, port and unit suite land in phase 1, so the files named below are not on main yet. Apple M-series macOS, Apple clang.
- Blorp 2 compiler: `make -C blorp_2 compiler` from this tree (`-O0` compiler, seed-built). Legacy compiler: `make` from this tree.
- Every program is compiled to C by its compiler, then `cc -fwrapv -O2 -march=native -flto -pthread`, no timing wrapper (so the numbers cover `main` plus process start, about 12 M instructions for Blorp 2 and 15 M for legacy).
- **Instructions:** `/usr/bin/time -l` retired instructions, one unrecorded warmup then three recorded rounds in which the subjects of a workload alternate, all serial; the table shows the minimum.
- **Allocations:** `BLORP_MEMORY_DIAGNOSTICS=1` build under `BLORP_LEAK_CHECK=strict`. Every run balanced (allocs = releases, 0 leaked). Blorp 2 counts allocator calls; legacy counts managed objects. The interposer's malloc-call column agrees within 1% for both.
- **Peak heap:** an interposer (`malloc`/`realloc`/`free`, `malloc_size`-rounded, includes runtime headers and about 15 KB of process start) on the diagnostics-off binary. One method for all three subjects.
- Raw samples, programs, scripts and the interposer: `build/spike/` (ignored, not retained in the repository). The series output is `build/spike/raw/series/*.json`.
- The spread prototype is the committed source. The "identity" variant is the same file with `HASH_SPREAD = 1`.

## What was built

- `blorp_2/standard_library/dict.brp`: 258 lines (170 without comments and blanks). `DictKey: Hashable + Equatable`, `empty`, `with_capacity`, `get`, `get_or`, `contains`, `set`, `remove`, `length`, `keys`, `values`; bodyless `DictKey` for `Int` and `String`. No equality, `entries` or `is_empty` yet, which the plan puts in phase 1 (about 40 more lines).
- `blorp_2/standard_library/string.brp`: `Hashable for String`, the `names.brp` formula (+16 lines).
- `benchmarks/blorp_2/dict_ops.brp`: port of the legacy workload. Output matches `bench_run.EXPECTED_OUTPUTS["dict_ops"]` exactly. Iterating walks `D.values(d)` because a Dict has no `for` yet (the legacy loop yields a tuple per entry and sums only the values).
- `blorp_2/test/unit/test_library/test_dict.brp`: 11 cases (order, remove-then-set, missing keys, value semantics, growth, remove-all-then-reuse, compaction, strides 1024 and 7 with `INT_MIN`, absent sequential keys, String keys, constant-hash keys). All pass under strict accounting. Mutating `remove` to write `EMPTY_SLOT` instead of `DELETED_SLOT` fails the constant-hash case. It is not in the Makefile selection (phase 1). A 3-seed model fuzz (600 to 700 operations against a linear-search model, checked after every operation) also agreed; it is a scratch program, not committed.
- Everything compiled with no compiler change, and the prototype is strict-clean.

## Findings that contradict or extend the plan

1. **Identity hash with linear probing and sequential Int keys is pathological.** The keys `0..n-1` fill one run of slots, so a lookup that starts inside the run walks to its end. `dict_ops` miss lookups cost 133 k instructions each in today's `HashMap` (16,384 slots, 10,000 keys) and the same cluster hit the plan-as-written prototype: 125.0 G instructions against 3.84 G. The fix is local to `dict.brp`: multiply the hash by an odd 64-bit constant before taking the remainder (`HASH_SPREAD`, one line). `Hashable for Int` stays identity. Without the spread the design misses any sensible ceiling on sequential Int keys; with it, it does not. The plan's "sequential ids land in distinct slots" is true but is the case that makes misses and tombstones expensive. Phase 1 needs the spread and a test that fails without it (`test_absent_sequential_keys_are_not_found` only bounds time through the suite, so use an allocation or step budget).
2. **A DELETED slot does not need reusing.** The rebuild trigger counts entries (`keys.length()`, dead included), not slots, so reusing a DELETED slot never delays a rebuild. Dropping the reuse removes the `first_deleted` bookkeeping from the probe and the "fewer DELETED slots than dead entries" case from the invariant: every entry owns exactly one non-EMPTY slot until the next rebuild. `dict.brp` does this.
3. **A record literal built from the fields of the old record copies every List; a record update does not.** `{ keys = c.keys.append(k), ... }` in the append helper gave 5 allocations per `set` and quadratic instructions (238 M at 4,000 keys, 3.46 G at 16,000). `{ c | keys = c.keys.append(k), ... }` gives 1 allocation per `set` and linear cost. `hash_map.brp`'s append branch uses the literal form, but its quadratic cost (below) comes from `reindexed`, not from this: a scratch copy using the update form there stays quadratic.
4. **Today's `HashMap` build is quadratic.** See the linearity table.

## Measurements

### dict_ops (build 100 x 10,000, hit 100 x 10,000, miss 100 x 10,000, remove, iterate 1000 x 10,000)

| Subject | Instructions (min of 3) | Allocations | Peak heap (rounded) |
| --- | ---: | ---: | ---: |
| Prototype, spread hash | 3,843 M | 3,017,317 | 1.34 MB |
| Prototype, identity hash (plan as written) | 124,962 M | 3,017,317 | 1.34 MB |
| `HashMap`, no `remove` | 273,449 M | 5,184,814 | 0.90 MB |
| Legacy | 5,969 M (5,251 M in an earlier session) | 10,000,212 | 1.39 MB |

The `HashMap` row has no remove section, so it does less work than the other rows and is still the slowest. Legacy instruction counts differ by 14% between two sessions of the same binary; both are shown. Legacy's allocations are the iterate loop's tuples (10,000,000); its table allocates nothing per operation.

Per operation, net of process start (`ops_modes` programs, `build/spike/raw/sections*.txt`):

| Operation | Prototype | Legacy | Prototype / legacy | `HashMap` |
| --- | ---: | ---: | ---: | ---: |
| set, growing from empty | 1,182 | 210 | 5.6x | 139,867 |
| lookup hit | 196 | 64 | 3.1x | 113 |
| lookup miss | 154 | 77 | 2.0x | 133,493 |
| remove | 1,166 | 81 | 14.3x | none |
| iterate, per element | 1.1 | 460 | 0.002x | 1.2 |

Without the iterate section, the prototype is about 5.9 times legacy (3,832 M against 643 M by section sums). The plan's "within 4x legacy on `dict_ops`" passes (0.64x) only because legacy's iterate allocates a tuple per entry. The `HashMap` hit is the no-collision case (identity hash, sequential keys); the prototype's 196 includes about 1.8 probes per hit at 61% load plus the spread multiply.

### Mixed workload: 100,000 operations (set 25,000, get 25,000, remove 12,500, set 12,500, get 25,000), net of key generation

| Keys | Subject | Instructions | Allocations | Peak heap |
| --- | --- | ---: | ---: | ---: |
| Int | Prototype, spread | 76.3 M (763/op) | 50,070 | 2.13 MB |
| Int | Prototype, identity | 16,005 M | 50,070 | 2.13 MB |
| Int | `HashMap` (set and 2 gets only) | 20,225 M | 162,386 | 2.08 MB |
| Int | Legacy | 14.1 M (141/op) | 1 | 3.16 MB |
| 16-byte String | Prototype, spread | 84.9 M (849/op) | 50,070 | 2.13 MB |
| 16-byte String | Prototype, identity | 99.1 M | 50,070 | 2.13 MB |
| 16-byte String | Legacy | 19.2 M (192/op) | 1 | 3.16 MB |

The prototype is 5.4 times legacy on Int keys and 4.4 times on Strings. Allocations are exactly one per update (37,500 sets and 12,500 removes). Peak heap is the run minus the key-generation control; legacy is higher because its table over-allocates. All four checksums are 468,850,000.

### Unknown 1: record reallocation per update

One allocation per `set` and per `remove` (1.016 per set in the build section, including the rebuilds' Lists). The field Lists are updated in place: no list copy appears in the allocation counts. The cost of the record itself, from `helper_accumulators record_helper` (131,072 updates of a record with one List field, `build/spike/raw/record_update_cost.txt`): 527 instructions per update, against 42 for the equivalent bare `append`. That is about 45% of a `set` or `remove` (1,182 and 1,166), the part O3 cell reuse can remove.

### Unknown 2: String hashing

**Zero allocations.** Hashing a 16-byte String 10,000, 20,000, 100,000 and 1,000,000 times leaves 8 allocations (the process total) at every count. `byte_at` returns the `Option[Int]` as an inline tagged union, so no per-byte boxing. Cost is about 91 instructions per hash (5.7 per byte; `build/spike/raw/strhash.txt`). No `string.hash` builtin is needed. String keys cost 849 instructions per mixed operation against 763 for Int keys.

### Unknown 3: linearity, rebuilds included (local `var` Lists in `rebuilt`)

Build n Int keys, net of process start (12.22 M):

| n | Prototype instr/key | Prototype allocs/key | Rebuilds | `HashMap` instr (total) | `HashMap` allocs |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 4,096 | 1,297 | 1.013 | 10 | 360 M | 23,219 |
| 16,384 | 1,333 | 1.004 | 12 | 5,301 M | 92,853 |
| 65,536 | 1,310 | 1.001 | 14 | 83,365 M | 371,383 |
| 262,144 | 1,253 | 1.000 | 16 | n/a | n/a |

The prototype is linear: instructions per key move within 6% from 4,096 to 262,144 and allocations stay at one per key (the O2 `record_loop` limit does not bite because `rebuilt` fills locals). Today's `HashMap` grows 14.7x then 15.7x for each 4x of keys, quadratic, with 5.7 allocations per set; `reindexed` is the plan's named cause.

### Churn rebuild count

Fixed live count, then 100,000 times: remove the oldest key, set a brand new one (instrumented copy with a rebuild counter, `build/spike/lib_counted`):

| Live | Rebuilds in the churn phase | Cycles per rebuild | Instructions per cycle |
| ---: | ---: | ---: | ---: |
| 10 | 10,000 | 10 | 2,904 |
| 1,000 | 273 (547 at 200,000 cycles) | 366 | 2,340 |
| 100,000 | 1 | 100,000 | 1,885 |

Bounded and amortized: one rebuild per about 0.37 x live cycles (minimum 10), and the instruction cost per cycle at live 1,000 is 2,341 at both 100,000 and 200,000 cycles (linear). A cycle is a remove plus a set, so it costs about the sum of the two (1,166 + 1,182).

## Phase 2: known-callee path in `check/` (read only)

The path exists in miniature for operators: `plan_body_base` (`check/expressions.brp:~656`) turns `ComparisonExpression` and `ArithmeticExpression` into `PlannedCall(contract, [left, right], ReturnPlacement(...), expectation)`, where the contract comes from a known `TraitMethodId` through `method_id_contract` (`check/callables.brp:340`) and the `CanonicalContracts` product built at admission (`check/model.brp:433`, `check/traits.brp:479`). A `FunctionId` analogue needs:

| Piece | Where | Lines |
| --- | --- | ---: |
| `declared_id_contract(span, function, signatures)` (the `accepted_function` plus `declared_call_target` pair `function_contract` already uses, minus name and arity checks) | `check/callables.brp` near `function_contract` | 12 |
| Dict ids (`empty`, `with_capacity`, `set` as `FunctionId`s of the module that declares the prelude's `Dict`) located once at admission, like `CanonicalContracts`, with accessors | `check/model.brp`, `check/traits.brp` or `check/declarations.brp` | 50 to 70 |
| A planned literal: nested `set` calls cannot be written as `ValueExpression` arguments (no known-callee expression exists), so a `PlannedDictLiteral` base and a worklist step in the style of `CheckList` that schedules each call | `check/expressions.brp` (`plan_base`, the work union at ~295, `ScheduleCall` at ~1453) | 60 to 90 |
| Empty-literal-needs-a-type error and its `render.brp` text | `check/errors.brp`, `check/render.brp` | 15 |

Estimate: about 140 to 190 production lines in `check/`, plus parser and lexer work and tests, which the plan already lists. The new surface is one planned-base variant and one admission product; no new resolution machinery. The risk is the nested chain, not the call: it needs the new planned base because the existing call arguments are parsed expressions.

## Proposed phase 1 ceilings

Set from the numbers above; the prototype is the baseline. Stop and rescope on a miss.

| Ceiling | Value | Justified by |
| --- | --- | --- |
| Build linearity | instructions per key at 65,536 at most 1.15x the figure at 4,096; allocations per key at most 1.02 at 4,096, 16,384 and 65,536 | 1.01x and 1.013 measured |
| Slot spread | sequential Int keys 0..n-1 and strides of 7 and 1,024 keep average probes per miss below 8 at 61% load (assert through a step budget or the instruction bound below) | identity hash: 133 k instructions per miss |
| Set | at most 1,400 instructions (1.18x 1,182) and 1.02 allocations | build section, 1,182 and 1.016 |
| Remove | at most 1,400 instructions and 1.02 allocations | 1,166 and 1.005 |
| Lookup hit, miss | at most 230 and 185 instructions, 0 allocations | 196 and 154 measured |
| `dict_ops`, whole | at most 4,300 M instructions, 3.1 M allocations, 1.5 MB peak heap | 3,843 M, 3,017,317, 1.34 MB |
| Against legacy | report only: 0.64x on `dict_ops`, 5.9x without iterate, 5.4x and 4.4x on the mixed workload. Replace the provisional "within 4x" with "at most 7x on the sections other than iterate" | the 4x ceiling passes only through legacy's iterate tuples |
| Against `HashMap` | replace "no slower, +-5%" with: hit at most 2x `HashMap`'s (113, so 226), everything else absolute | `HashMap`'s hit is the no-collision case; its build and miss are 100x to 1000x slower |
| String keys | at most 1.2x the Int cost per mixed operation (measured 1.11x); hashing 0 allocations | 849 against 763; 0 allocations |
| Churn | churn-phase rebuilds at most 3 x cycles / live + 1 for live above 24, and at most cycles / 8 below that; at most 3,100 instructions per cycle, and 2.1 allocations per cycle for live of 1,000 or more (2.6 below) | 273 against 300 at live 1,000; 10,000 against 12,500 at live 10; 2,904 instructions and 2.5 allocations per cycle at live 10 (the worst); 2.02 and 2.00 at live 1,000 and 100,000 |
| `dict.brp` size | at most 300 lines including equality, `entries` and `is_empty` | 258 now, about 40 to add |

Phases 3 to 5 ceilings stay as the plan states (self-compile instructions +0.5%, allocations +1%).

## Not done

- Record-key (`implements DictKey for` an opaque or fixed record) was not tried beyond the ordinary record `Flat` in the unit suite, which was accepted.
- `bench.sh dict_ops` itself was not run (the other languages are outside this spike); the port's output was compared to `EXPECTED_OUTPUTS`.
- No attempt to optimize the prototype beyond the single probe rewrite; remove at 14x legacy and set at 5.6x are the obvious targets, and O3 removes about 45% of both.
