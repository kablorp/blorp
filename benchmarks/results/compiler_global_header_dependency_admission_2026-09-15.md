# Global Header Dependency Admission

Issue 117 replaced growing-list membership scans with an invocation-local
`Dict[Int, Bool]` for initializers containing at least 16 free references.
Narrow initializers retain the original list path so they do not pay for a
dictionary allocation.

## Decision

Accept. The indexed path preserves exact resolved header-row identity and
first-reference order. The wide one-percent-duplicate workload reduced
modeled membership operations by 99.60% and median retired instructions by
10.75%. The four-reference control remained allocation-neutral and within the
3% retired-instruction guardrail.

## Boundary And Provenance

The fixture builds a real `CallableHeaderGraph` before measurement. The timed
window repeatedly calls `global_header_completion_plan_build`; graph setup,
warmup, and checksum observation are excluded. Modules deliberately define
same-named dependency globals, and the checksum covers ordered header and
dependency definition IDs.

- Base revision: `341d9443db6542a9b54722e120652d7f5ee4e387`.
- Platform: Darwin 25.6.0 arm64, Apple M4.
- Baseline binary SHA-256:
  `807c17bb54fd091b059daf52474d40d2260e03b337365881c065305feeaecd72`.
- Candidate binary SHA-256:
  `1b7c411dd37e663a6311eccb679b901f928999462fde3580940e5bfc05637bdd`.

All paired runs alternated execution order and required identical `checksum`
and `warmup_checksum` values.

## Results

The wide workloads used 64 initializers, 512 references per initializer, four
modules, fan-in 512, and five plan-build iterations.

| Workload | Metric | Baseline median | Candidate median | Change |
| --- | --- | ---: | ---: | ---: |
| 1% duplicate | modeled membership operations | 8,178,304 | 32,768 | -99.60% |
| 1% duplicate | retired instructions | 5,883,778,497 | 5,251,198,000 | -10.75% |
| all unique | retired instructions | 5,914,350,875 | 5,260,551,298 | -11.05% |
| all unique | elapsed | 507,637 us | 439,382 us | -13.45% |
| all unique | allocations | 1,014,455 | 1,014,775 | +0.03% |

The 320 additional allocations are exactly one dictionary per initializer per
iteration. No dictionary is allocated per reference.

The small control used 1,000 iterations of one initializer with four unique
references. Both variants reported 65,000 allocations and 64,993 releases.
Median retired instructions changed from 168,828,334 to 168,954,216 (+0.07%).
Elapsed medians differed by +3.96%, but the stable instruction and exact
allocation signals show no material regression in the retained linear path.

A duplicate-heavy 75% workload improved retired instructions by 3.78%. Its
legacy list searches usually found duplicates near the front, so it does not
represent the quadratic-width case. The retained one-percent-duplicate case
demonstrates that repeated references still clear the 10% instruction gate.

## Crossover

Nine alternating elapsed-time pairs used one all-unique initializer for 1,000
iterations. Candidate changes were -0.58% at 16 references, -2.32% at 32, and
-7.19% at 64. This supports the 16-reference cutoff without exposing tiny
initializers to the fixed dictionary cost.

## Reproduction

```bash
benchmarks/compiler_global_header_dependency_profile plain 5 64 512 1 4 512
benchmarks/compiler_global_header_dependency_profile plain 1000 1 4 0 1 4
```

Build baseline and candidate benchmark executables, then compare them with
`benchmarks/compiler_pass_compare`, using `GLOBAL_HEADER_DEPENDENCY_PROFILE` as
the prefix, `elapsed_microseconds` as the time field, `checksum` and
`warmup_checksum` as checksum fields, and `allocations` and `releases` as
metric fields. External instruction samples used `/usr/bin/time -lp` in seven
alternating pairs.
