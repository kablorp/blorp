# Function registration aggregate measurement

Date: 2026-07-29

## Verdict

Commit `5b2f847e` performs slightly less typechecker work than its parent
`3200b770`, but the improvement is too small to produce a measurable
end-to-end latency win for the production compiler CLI target.

- Production `compiler_cli_main` replay: 0.045% fewer retired instructions.
- Production `compiler_cli_main` wall time: statistically neutral.
- Registration-heavy `compiler_infer` replay: 0.149% fewer retired
  instructions and about 0.40% lower clean wall time.
- One cold `make install` pair was neutral in wall time.

The earlier synthetic slice measurements demonstrated that the individual
changes removed work. They did not prove that the squashed commit materially
reduced compiler build latency. The aggregate production measurements here do
not support such a claim.

## Revisions

| Variant | Revision |
|---|---|
| Parent | `3200b770cc75c1d44e0024219d92a5594d107f43` |
| Candidate | `5b2f847e4e930d64038b0c022f28ab626db0bf28` |

Both revisions used the pinned `dev-5331666d5ec5` bootstrap and equal-length
worktree paths. Revision-specific typecheck helpers and requests were prepared
before measurement.

## Method

Two exact production `typecheck_graph` requests were captured independently
from each revision:

- `compiler_cli_main.brp`, representing the compiler CLI target.
- `compiler_infer.brp`, concentrating the function-registration workload.

Each request was reduced with the existing `--target-only` projection. This
keeps the complete prepared graph context while emitting one target artifact.
The prepared typecheck helper was then executed directly under
`/usr/bin/time -lp`. Direct execution makes retired instructions a valid
process-level counter and excludes bridge preparation, request rewriting,
response validation, C compilation, rendering, and Make overhead.

The direct measurement used 10 order-alternated pairs per workload. Every
response was checked against the response hash produced by the verified replay
runner. Paired geometric-mean intervals are percentile bootstrap intervals
from 200,000 resamples.

Wall time for `compiler_cli_main` came from 15 clean order-alternated pairs
through `compiler_typecheck_replay`. A process monitor rejected pairs that
overlapped unrelated compiler activity; rejected pairs 2, 9, and 12 were
replaced by pairs 16, 17, and 18.

Host: Apple M4, 32 GiB RAM, macOS 26.5.1.

## Results

Negative deltas favor the candidate.

| Workload and metric | Parent mean | Candidate mean | Paired effect | 95% interval | Pairs |
|---|---:|---:|---:|---:|---:|
| CLI retired instructions | 83.6815 B | 83.6438 B | -0.045% | -0.062% to -0.030% | 10 |
| CLI wall time | 5.2430 s | 5.2461 s | +0.060% | -0.162% to +0.291% | 15 |
| CLI peak RSS | 740.207 MB | 740.248 MB | +0.005% | -0.043% to +0.049% | 15 |
| Infer retired instructions | 220.9319 B | 220.6031 B | -0.149% | -0.169% to -0.135% | 10 |
| Infer user CPU | 12.5813 s | 12.5363 s | -0.357% | -0.692% to -0.040% | 8 clean |
| Infer wall time | 12.6538 s | 12.6025 s | -0.404% | -0.842% to -0.050% | 8 clean |
| Infer peak RSS | 257.221 MB | 238.399 MB | -7.317% | -7.409% to -7.251% | 10 |

The candidate retired fewer instructions in all 10 direct pairs for both
workloads. The effect is therefore real, but its magnitude on the CLI target
is only 0.045%. The clean CLI wall-time interval includes both a small gain and
a small regression.

## Cold build

One isolated-cache `opam exec -- make install` pair was run with the parent
first:

| Metric | Parent | Candidate | Delta |
|---|---:|---:|---:|
| Wall time | 208.29 s | 208.45 s | +0.08% |
| User CPU | 213.88 s | 212.52 s | -0.64% |
| Peak RSS | 5.049 GB | 5.006 GB | -0.85% |

One pair is not enough for an interval and is reported only as an end-to-end
sanity check. It agrees with the replay conclusion: no material wall-time
change is visible.

## Interpretation

The function-registration changes are not a broad performance regression.
They remove a small, repeatable amount of typechecker work and produce a
larger memory reduction on the registration-heavy target. However, the
production CLI latency effect is effectively zero at this measurement
resolution.

The CI sample that looked slower is plausible ordinary run-to-run variation.
The correct statement for this commit is:

> Function registration performs slightly less work, but we have not measured
> a material compiler build speedup.

Future compiler-speed claims should pair an actual production request replay
with direct retired-instruction counts, then use repeated clean wall-time
pairs only to determine whether the work reduction is large enough to affect
latency.

## Raw data

- `compiler_function_registration_direct_2026-07-29.tsv` contains all direct
  helper measurements and contamination flags.
- `compiler_function_registration_cli_replay_2026-07-29.tsv` contains the
  replay wall-time rows, including rejected and replacement pairs.
