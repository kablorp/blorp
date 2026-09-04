# Perceus Tranche 3 — Aggregate Transfer Normalization

This report compares the Tranche 3 candidate with its immediate parent,
`72bea3da`, using separately compiled production and debug/profile backend
workers. Samples alternated parent/candidate order. The focused matrix measures
direct Perceus over decoded ownership-ready Core; process startup and JSON
transport are outside the reported inner window.

## Change

Function-parameter aggregate transfer normalization now reuses the ordered
borrowed-owner catalog introduced for call protection and reconstructs each
supported Core region once. Exact variables and transparent projections use
the name-candidate index. Complex aliases use the existing exact scalar
predicate only at an explicit, counted compatibility boundary.

Transfer decisions remain driven by prepared-Core contracts. Record and
source-level tuple fields transfer their children. Boxed list, tensor, dict,
and union slots use `needs_release`; list-set storage uses
`transfers_ownership`; and prepared tuples use their least-significant-first
`retain_mask` plus explicit element variants. The pass does not infer transfer
from constructor names or general expression shape.

The scalar aggregate traversal remains for globals, lambda-local borrowed
values, and other compatibility paths outside the function-parameter slice.
Those paths are assigned to Tranche 4 rather than being silently broadened here.

## Fixture

The `aggregate_escape` shape declares a heap-record owner with one managed
`String` field. Each of two functions has an exact 128-node body, 1, 8, or 32
ordinary name-only heap-record parameters, and twelve record-storage sites that
store a field projection from owner zero. Extra parameters therefore grow the
owner catalog without adding syntax or real escaping values.

The fixture includes one fully traversable even-sized control expression. This
keeps the exact 128-node target without letting generic parity padding wrap the
body in a `CastExpr`, which is intentionally opaque to the current aggregate
pass.

```text
globals=1
functions=2
body_leaves=128
body_shape=aggregate_escape
parameter_type=HeapRecord(BenchBorrowOwner { BENCH_PAYLOAD: String })
aggregate_escape_sites_per_function=12
params_per_function=1,8,32
samples=7
warmup=true
measurement_window=perceus-direct
```

## Paired results

| Owners per function | Parent visits | Candidate visits | Visit reduction | Inner-time ratio | Allocation ratio | Release ratio |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 232 | 232 | 0.0% | 1.041 | 1.000 | 1.000 |
| 8 | 2,360 | 232 | 90.2% | 0.793 | 0.742 | 0.733 |
| 32 | 9,656 | 232 | 97.6% | 0.456 | 0.397 | 0.386 |

At 32 owners, the direct Perceus window improved by 54.4%, allocations fell
from 25,088 to 9,964 (60.3%), and releases fell from 24,650 to 9,526 (61.4%).
The one-owner point is within noise and adds four allocations and four releases,
showing no material fixed penalty.

The candidate counters were constant at all three owner counts:

```text
borrowed_aggregate_node_visits=232
borrowed_aggregate_owner_candidate_visits=24
borrowed_aggregate_alias_fallback_requests=0
borrowed_aggregate_rewrite_actions=24
borrowed_origin_member_visits=24
borrowed_origin_storage_slots=0
```

Owner-catalog slots alone scale with the inputs: 2, 16, and 64. The matrix
rejects owner-scaled aggregate traversal, fallback, candidate, rewrite, and
origin-set work. At 32 owners it also requires at least a 75% traversal
reduction against an explicit parent worker.

## Correctness

For every matrix point, parent and candidate post-Perceus Core hashes were
identical. A separate seven-pair 32-owner backend-emission check produced the
same 143,207-byte generated C artifact with SHA-256
`f81c9397897887c9af3eaa8f6f1b4ca934e6fdc4d8ee25b8e7a7afc5fb050269`.
That full-backend window was neutral at 0.981 paired median ratio with 0.005
MAD, and both workers performed exactly 96,298 measured allocations.

The focused Perceus suite passed 314/314 tests. It includes a new two-owner
record fixture requiring exactly one retained projection from each owner, plus
the existing prepared-tuple masks, boxed storage, list-set transfer, compiled
match shadowing, resource scope, nested aggregate, and borrowed payload cases.
Benchmark contract tests passed 35/35.

## Reproduction details

The focused matrix used harness SHA-256
`e55c287093c17b95e24eb1d66b1adb47ae63b28f7bf72b443ac5c1581ff16c6d`,
candidate worker SHA-256
`bf551106ccc7967c743307b44ec68afec0d36197863839a24b2e81a9c65a9169`,
candidate counter-worker SHA-256
`f5ea6b8daf477534e4628342603176977c9babc6ae7b3de057f95a4199284f14`,
parent worker SHA-256
`603a6eee006f5c76776c40825c28707c951dad4d83c39f407b126be01d5c4b8e`,
and parent counter-worker SHA-256
`9b1d12f02287c82bd229ca04cb6ad0716b31009f9047a29e59797dff3ff0f4ba`.

The seven parent/candidate direct-window samples in microseconds were:

| Owners | Parent samples | Candidate samples | Paired-ratio median ± MAD |
| ---: | --- | --- | ---: |
| 1 | 1225, 1176, 1204, 1224, 1256, 1241, 1403 | 1316, 1224, 1322, 1211, 1237, 1351, 1300 | 1.041 ± 0.051 |
| 8 | 1544, 1544, 1597, 1649, 1740, 1555, 1546 | 1210, 1224, 1328, 1289, 1304, 1256, 1333 | 0.793 ± 0.015 |
| 32 | 3605, 2812, 2763, 2882, 2763, 2686, 2796 | 1690, 1243, 1249, 1261, 1260, 1353, 1487 | 0.456 ± 0.014 |

The corresponding post-Perceus artifact byte counts and SHA-256 hashes were:

| Owners | Bytes | SHA-256 |
| ---: | ---: | --- |
| 1 | 43,330 | `853dc2c17bc32a69f0b85d7ae52f14fdcf30fa4c870587dbe54b239bd13bc072` |
| 8 | 45,528 | `5040bc3e42fe4a1127a286f7e6871c9a36796c83d244b1bf01b43804aaab8c00` |
| 32 | 53,064 | `8be6264eff3bf9b63d7052e132b94e5271dcc53792e0b4feed8ae9e16aaac2bf` |
