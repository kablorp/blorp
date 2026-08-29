# Compiler Type Authority Revalidation

## Scope

This revalidates the graph-owned type alias, record, union, and constructor
vertical slices against current `main` (`3963664d`). It deliberately excludes
the later callable, global, trait, and implementation authority experiments.
The final candidate tip is `045cd41c`.

## Method

- Target: `compiler/src/stage_12_cli/main.brp`
- Request SHA-256: `e90627815eb8d83e346448d9cafa71bf729aa07886c2a85fa6171c7e818354bd`
- Baseline worker SHA-256: `73dbc10d99cb21843441f7ce49afcd10409714ed0a9cf2f854335875d6f00532`
- Candidate worker SHA-256: `a7992a3d77ea4f7182d082ab47f946f6e1fa5e2e8edfb5eccdaa0a0e62083d9d`
- Selection: `--target-only --timeout 180 --memory-limit 4G --no-inventory`
- One warmup per worker, then three order-balanced pairs.
- Allocation counters were collected in a separate perturbative run.

All measured runs were verified and returned 2,029,527 bytes with SHA-256
`e542dd0fe0c4b585a679890da073643f9f955c9c999c29c3b082a7e4f0bd1813`.

## Latency Results

| Run | Baseline | Candidate |
| --- | ---: | ---: |
| Pair 1 | 46.590 s | 40.897 s |
| Pair 2 | 46.933 s | 40.680 s |
| Pair 3 | 46.920 s | 40.702 s |
| Median | 46.920 s | 40.702 s |

Median named typecheck checkpoints fell from 25.321 s to 19.139 s. Median peak
sampled RSS rose from 1,074,741,248 bytes to 1,091,141,632 bytes. That is a
13.25% end-to-end latency reduction, a 24.41% named-typecheck reduction, and a
1.53% peak-RSS increase.

## Allocation Evidence

The per-object memstats replay is not a trustworthy production gate for this
workload: the baseline did not complete even with a 420-second timeout. The
focused mechanism fixture below provides allocation evidence without making a
claim from that perturbative whole-compiler mode.

## Focused Mechanism Check

For the dense 16-module, 16-declaration, fanout-four fixture, accepted
declaration preparation fell from 3,182,473 us and 938,705 allocations to
1,427,428 us and 724,676 allocations. This fixture is supporting mechanism
evidence; the production replay above is the acceptance measurement.
