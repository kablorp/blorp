# Change-Aware Perceus Aggregate Checkpoint

Date: 2026-09-08

## Scope

This checkpoint lets Perceus retain an immediate aggregate source node when
recursive insertion leaves every aggregate child and every ownership-relevant
storage bit unchanged. It covers the aggregate forms accepted at the Perceus
boundary:

- tuple and vector item lists;
- record fields, record reuse fields, and record construction fields;
- record copy-on-write sources and optional replacement fields;
- pointer-list and boxed-tensor elements;
- dictionary keys and values; and
- typed union arguments.

Each collection helper returns a fieldless `Unchanged` variant or a `Changed`
variant carrying the replacement collection. The unchanged path therefore
retains the source collection and source aggregate. A changed child updates
the original collection at its exact index; traversal order and existing
direct-field retain behavior are unchanged.

Boxed storage has an additional identity obligation. The source boxed value
is retained only when recursive insertion reuses its value and the inferred
`transfers_ownership` bit is already equal to the source bit. Direct managed
field aliases remain conservative and force the existing `BorrowLetExpr` plus
`DupExpr` protection.

Three debug counters partition every aggregate visit into source reuse or
reconstruction.

## Behavioral matrix

The benchmark has a closed `aggregate_change_matrix` fixture. Each worker
contains one neutral and one ownership-sensitive example for every aggregate
root. Dictionaries add separate sensitive-key and sensitive-value examples.
A second two-field heap record makes the copy-on-write case valid while
retaining one field and replacing the other.

The bridge validates the post-Perceus tree, not just the input fixture. For
each root it requires the neutral child to remain direct and the sensitive
child to contain the established borrowed-field ownership wrapper. Dictionary
key and value decisions are checked independently. The two-worker gate also
requires exactly 50 aggregate decisions: 26 reused and 24 reconstructed.

`RecordUpdateExpr` is included in the input census but is intentionally absent
from the measured Perceus input. `prepare_perceus_input` lowers it to
`RecordExpr` before beginning the direct-Perceus measurement window. The output
matrix locks that phase boundary by requiring the two update cases per worker
to appear as the corresponding additional record decisions.

## Direct Perceus measurements

Platform: `macOS-26.6.2-arm64-arm-64bit-Mach-O`.

Candidate timing worker SHA-256:
`87f7c313ab8d68298d469258dbeee75cec358af5040f32a41bf451435a658d6e`.
Candidate counter worker SHA-256:
`f2687ebb7f5301b7f2311926aaa284b0c1b7b74663667ec6294a247a8a46b1c8`.
The immediate-parent timing and counter workers were
`350bc4710db71d0712afb7145f122d9abcd860e9170088912226f856d53766e3`
and
`862eea766a0b6492b0355b0f29d463cb66111017ff8a93d6f390b592d4f939ee`.

The focused workload contains two aggregate-escape workers, 128 borrowed
owner parameters per worker, and 12 ownership-sensitive record constructions
per worker:

```bash
benchmarks/compiler_perceus_memory \
  --body-shape aggregate_escape \
  --functions 2 \
  --globals 1 \
  --body-leaves 256 \
  --global-reads-per-function 0 \
  --params-per-function 128 \
  --parameter-type String \
  --measurement-window perceus-direct \
  --baseline-bridge <parent-timing-worker> \
  --baseline-counter-bridge <parent-counter-worker> \
  --samples 7 \
  --no-warmup \
  --json
```

| Metric | Parent | Candidate | Change |
| --- | ---: | ---: | ---: |
| measured-window allocations | 28,811 | 28,061 | -2.60% |
| measured-window releases | 27,080 | 26,330 | -2.77% |
| aggregate roots reused | 0 | 256 | +256 |
| aggregate roots reconstructed | 280 | 24 | -256 |
| paired measured-window time | — | ratio 1.0163, MAD 0.0340 | neutral/noisy |
| paired whole-worker time | — | ratio 1.0084, MAD 0.0155 | neutral |
| peak RSS | 23,396,352 bytes | 23,461,888 bytes | +0.28% |

The 750 removed allocations and releases are deterministic. Parent and
candidate post-Perceus artifacts were byte-identical with SHA-256
`85814dcda70cfe2caf3874260e513832d446c469007c4126068ce5e6efa76eb8`.
Timing and RSS do not show a measurable change.

The behavioral matrix independently completed with 50 visits, 26 source
reuses, 24 reconstructions, and deterministic post-Perceus SHA-256
`73ba7ca010813b74b629a53cc1354af2485bf7372b2660dea3ed2b1900996fa2`.

## Acceptance result

- exact aggregate decisions are mechanically partitioned by debug counters;
- every aggregate reconstruction family has neutral and sensitive behavioral
  coverage at its real pipeline boundary;
- dictionary keys and values are covered independently;
- direct-field protection and boxed transfer-bit changes remain conservative;
- the focused direct window has a deterministic allocation and release win;
- post-Perceus Core is byte-identical to the immediate parent; and
- the full Perceus suite and changed-source sanitizer gate pass.

## Next boundary

Change-aware insertion now composes through leaves, simple shells, managed
lets, calls, and aggregates. Completed Issue 60 was the final automatically
admitted checkpoint and covers only the fixed-arity
unbox, binary, field-projection, and tuple-field-projection roots.

Match ownership nodes are deliberately excluded. Their branch bindings,
fallbacks, and result ownership overlap with the all-value facts and ownership
plan proposed by Tranches 5–6. A standalone match-identity checkpoint would be
throwaway machinery unless the post-Issue-60 profile demonstrates a material,
independent reconstruction cost and the design can be retained by Tranche 6.
