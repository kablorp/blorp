# Variable-Dimension List Resolution Experiment

Date: 2026-09-15. Former issue: variable-dimension list flattening (#101).
Baseline revision: `9ecb72e934c42f730fe15b5f3f05ee62a76db5f6`.
Rejected candidate: replace each `result.concat(concrete_dims)` with an inner
append loop while retaining one substitution lookup per root type.

## Decision

Rejected. The one-pass append candidate was semantically safe and encouraging,
but it did not meet the issue's quantitative admission gate. At expansion
width 64, total allocations improved only 0.06% and median retired instructions
improved 8.52%, below the required 10% on either metric. The candidate is not
in the final tree.

The isolated elapsed median improved 11.63% at width 64 and a noisy three-pair
self-compile median improved 7.18%. Those signals make this worth revisiting
after a better builder or exact-capacity strategy exists, but they are not a
reason to change the gate after seeing the result. A two-pass exact-capacity
prototype was also rejected because it doubled substitution lookups.

## Evidence and caveats

The experiment varied expansion widths 1/4/16/64 at fixed root input count.
All paired runs produced matching semantic checksums, balanced
allocations/releases, and exact generated-C identity for
`vardims_tuple_return_resolution.brp`. The width-64 medians were:

| Metric | Baseline | Candidate | Change |
| --- | ---: | ---: | ---: |
| elapsed microseconds | 140,843 | 124,457 | -11.63% |
| allocations | 1,544,000 | 1,543,000 | -0.06% |
| retired instructions | 2,613,372,896 | 2,390,841,565 | -8.52% |

The benchmark's modeled prefix-copy count showed 4,045,000 old prefix elements
at width 64, but that implementation-derived counter does not replace the
material-benefit gate. The process-level instruction comparison also used
baseline and candidate harness revisions with different output-field labels,
so it is supporting evidence only. Raw measurements remain under
`/private/tmp/blorp-var-dims-interleaved-714f/` on the measurement host.

The prototype benchmark was not retained because its `workload_valid` check
did not independently validate the resolved output shape and its reproduction
recipe depended on prebuilt temporary binaries. A future attempt should first
add a fail-closed expected semantic type, use an identical harness overlay for
both revisions, hold total output size constant in a second matrix, and record
the full archive/build/alternating-sample procedure.

The focused inference suite passed all 311 tests, the typecheck stage passed
38 suites and 2 checks, and `compiler-blorp` passed all 4,558 tests. The useful
mixed-order, repeated-expansion, missing-substitution, recursive-type, and
empty-expansion regression tests remain even though the optimization was
reverted.
