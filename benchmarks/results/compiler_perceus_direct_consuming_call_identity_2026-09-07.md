# Perceus Direct Consuming-Call Identity Checkpoint

Environment: macOS 26.6.2, arm64. Timing uses seven warmed, paired samples in
alternating parent/candidate order. Workers measure only the direct Perceus
window.

## Post-Tranche-4 profile

Compiler self-compilation through Perceus produced 46,417 native one-millisecond
samples. The largest mapped Perceus subtrees were:

| Function | Inclusive samples | Share of all samples |
| --- | ---: | ---: |
| `insert_drops_program` | 7,202 | 15.5% |
| `insert_drops_expr` | 4,646 | 10.0% |
| `insert_drops_expr_inner` | 3,073 | 6.6% |
| `insert_drops_non_binding_expr` | 1,582 | 3.4% |
| `insert_drops_ownership_node` | 1,173 | 2.5% |
| `balance_consumed_param_bodies` | 1,114 | 2.4% |
| `normalize_borrowed_owner_entries` | 483 | 1.0% |
| `summarize_linear_ownership_uses` | 155 | 0.3% |
| `count_uses` | 2 | negligible |

Borrowed normalization is no longer the primary target. General insertion and
consumed-parameter balancing dominate the remaining named ownership work.

## Fixed contract scaling

Before the checkpoint, the fixed 644-node nested-call series reported:

| Owners | Direct Perceus µs | Allocations | Summary requests | Summary visits |
| ---: | ---: | ---: | ---: | ---: |
| 1 | 46,830 | 613,644 | 697 | 112,363 |
| 8 | 1,826,011 | 25,659,213 | 37,201 | 5,692,209 |
| 32 | 6,777,236 | 94,913,671 | 162,625 | 21,103,425 |
| 128 | 20,718,717 | 272,985,290 | 871,681 | 60,347,649 |

Every point has exactly 5,159 insertion visits. At 32 owners, all eight worker
bodies contain zero parameter `DupExpr` and zero parameter `DropExpr` nodes.

## Paired result

The final 32-owner comparison used the same eight-function, 644-node fixture.
The benchmark's normal invocation path also calls the workers from `main`, so
its allocation totals are slightly larger than the counter-only contract row.

| Metric | Parent | Candidate | Candidate/parent |
| --- | ---: | ---: | ---: |
| Direct Perceus median | 6,760,080 µs | 13,410 µs | 0.001984 |
| Paired time-ratio median | — | — | 0.001963 |
| Window allocations | 94,920,801 | 125,079 | 0.001318 |
| Window releases | 94,915,263 | 119,541 | 0.001259 |

Candidate time samples in microseconds:
`[13380, 13236, 13236, 13611, 13481, 13668, 13410]`.

Parent time samples in microseconds:
`[6753466, 6742505, 6760080, 7043202, 7201200, 6924706, 6716965]`.

The parent and candidate artifacts are both 532,843 bytes with SHA-256
`26ac392372fda49d3f6f28ec1101f5fb96bdf47895827e5e8205466ca39db8a9`.

Final candidate timing worker SHA-256:
`6f598628cf4e8722bb4d03d3ce4c2679eb29617bca19bb8200c1b4efaaf37b6c`.

Parent timing worker SHA-256:
`9d46222b595e7d7e57abcc314afc9d96bbb010989a4b75604a8742cbff238d67`.

Final counter worker SHA-256:
`187e856c9a2314096a3d81995d22484201997537a50e83e047555212da819d3b`.

Benchmark harness SHA-256:
`a0f4207e0ef81bad24494ce79aac3ccba6ecfcfea00a28b2528d3779495077ed`.

With worker invocation disabled to match the contract matrix exactly, final
candidate counters are one linear-summary request and one visited summary node,
versus 162,625 requests and 21,103,425 visits in the parent. Insertion remains
5,159 visits and contract collection remains 5,113 visits.

## Same-source self compilation

Both compilers compiled the final candidate source through Perceus and produced
the same 313,653,142-byte snapshot with SHA-256
`e4eafdf3ede7a061c3863ebae1f09649f5051fc5860fd3651b7831e1c22ec3da`.

| Metric | Parent | Candidate | Change |
| --- | ---: | ---: | ---: |
| Frontend | 30.065 s | 30.689 s | +2.08% |
| Core backend through Perceus | 33.059 s | 33.703 s | +1.95% |
| Retired instructions | 1,062,747,081,145 | 1,065,196,542,876 | +0.23% |
| `/usr/bin/time` maximum RSS | 5,200,084,992 | 4,823,285,760 | -7.25% |

These are single runs and the phase timings include all work before Perceus.
The stable instruction count indicates near-neutral self-host impact, not a
current compiler speedup.

## Validation

- `perceus.brp` type-check: passed;
- focused Core Perceus suite: 345 passed, 0 failed;
- benchmark contract suite: 58 passed, 0 failed;
- fixed 32-owner Core artifact: byte-identical; and
- same-source compiler snapshot: byte-identical.

No broad runtime or compiler gate was run during this checkpoint's fast
feedback loop.
