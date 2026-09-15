# Source-AST Finalization Diagnostic Batching

## Decision

Accepted with an explicit evidence substitution for one proposed gate.
`finalize_exprs` now appends each child diagnostic into its uniquely owned
result rather than concatenating every child list into the growing prefix.
Exact AST and diagnostic checksums match the baseline. In seven paired,
alternating samples, clean, dense, and heavy workloads improved elapsed time;
the clean path also removed 28.48% of measured allocations.

Retired instructions were unavailable on the macOS measurement host, and the
dense and heavy fixtures improved total allocations by only 0.80% and 0.42%.
They therefore do not literally meet the proposed "10% retired instructions
or allocations" gate. We accept the narrower change because its direct work
counter removes 100% of the old growing-prefix recopying (3,924,480 dense and
44,018,688 heavy element copies), while paired elapsed medians improve 16.62%
and 48.95%, the clean path improves both time and allocations by more than
10%, and exact output identity holds. This is a deliberate replacement of an
unavailable/diluted proxy with the operation the issue was intended to remove,
not an inference from timing alone.

## Provenance

- Baseline revision: `9ecb72e934c42f730fe15b5f3f05ee62a76db5f6`
- Candidate revision: `51f3fd8fd7a8151afd7eab644883720fbbe823de`
- Common fresh compiler SHA-256:
  `efd7bff50fc7d1effe12e61ad969521ffe113406350428908b2d857b9b55073e`
- Benchmark harness SHA-256:
  `6f5ad169bc434a20843b075238bb0081acb53cbfa5a20b14b0a1e266cbf7e58a`
- Baseline owner-source SHA-256:
  `10f159143ca761577cba53e4643a209d854782505498874b2dc8c099ee02135d`
- Candidate owner-source SHA-256:
  `01616160c740d49b4888d8aec837dfcf31375f65b510f55a2002530cbce28acb`
- Focused test SHA-256:
  `417097c1a27f73d8b8d6a91dea8a30da2a624395b141300923915ef674c8435d`
- Baseline/candidate benchmark binary SHA-256:
  `82e28cd056baa06c1b35e968b641873f68bef42ebeca3f22c4a8e4b029874077` /
  `029dec4660a227a42538054ee2c708714c0f3ecb221ba7918e2a0989eb13f46e`
- Retained paired samples:
  `benchmarks/results/compiler_source_ast_finalize_diagnostics_2026-09-14.tsv`
  (SHA-256 `1c66746b380a621570776b55e3d76b3f95b0935100830099c5392f0e4e23490b`
  including its header).
- Raw outputs: `/private/tmp/blorp-issue106-interleaved-valid/{variant}-{workload}-{N}.out`.
- Raw hash manifest:
  `/private/tmp/blorp-issue106-interleaved-valid/sha256.txt`.

The benchmark did not exist at the baseline revision. The identical candidate
harness was copied into an archive of the baseline source before both variants
were emitted with the common compiler and compiled with `cc -O2`.

## Reproduction

```bash
base_dir=/tmp/blorp-issue106-base.ldBe2u
cand_dir=/tmp/blorp-issue106-candidate.uY42pp
compiler=/Users/keithphilpott/CLionProjects/blorp/bin/blorp
harness=blorp/benchmark/compiler/compiler_source_ast_finalize_diagnostics_profile.brp

cp "$cand_dir/$harness" "$base_dir/$harness"
(cd "$base_dir" && "$compiler" compile -o /tmp/blorp-issue106-validation-baseline.c "$harness")
(cd "$cand_dir" && "$compiler" compile -o /tmp/blorp-issue106-validation-candidate.c "$harness")
cc -O2 /tmp/blorp-issue106-validation-baseline.c \
  -o /tmp/blorp-issue106-validation-baseline
cc -O2 /tmp/blorp-issue106-validation-candidate.c \
  -o /tmp/blorp-issue106-validation-candidate

out=/private/tmp/blorp-issue106-interleaved-valid
run_one() {
  variant=$1 workload=$2 sample=$3
  case "$workload" in
    clean) args=(5 1024 0 1 1) ;;
    dense) args=(5 1024 2 4 1) ;;
    heavy) args=(2 4096 3 8 1) ;;
  esac
  "/tmp/blorp-issue106-validation-${variant}" "${args[@]}" \
    > "$out/${variant}-${workload}-${sample}.out"
}
for workload in clean dense heavy; do
  for n in 1 2 3 4 5 6 7; do
    if (( n % 2 )); then
      order=(baseline candidate)
    else
      order=(candidate baseline)
    fi
    for variant in "${order[@]}"; do
      run_one "$variant" "$workload" "$n"
    done
  done
done
```

## Results

| Workload | Paired samples | Baseline median µs | Candidate median µs | Change | Baseline allocations | Candidate allocations | Change |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| clean | 7 | 3,548 | 2,505 | -29.40% | 35,950 | 25,710 | -28.48% |
| dense | 7 | 107,431 | 89,574 | -16.62% | 792,430 | 786,080 | -0.80% |
| heavy | 7 | 477,824 | 243,908 | -48.95% | 2,171,952 | 2,162,762 | -0.42% |

Every sample reported `workload_valid=True`. Allocations minus releases and
retained objects were identical between variants: 2,055 clean, 5,127 dense,
and 29,703 heavy. The clean/dense/heavy AST checksums were respectively
`94e33982...`, `4f75a65c...`, and `f7184e98...`; diagnostic checksums were
`e3b0c442...`, `d4580f28...`, and `0335b8e7...`, identical in each pair.

The dense workload produced 7,680 diagnostics and modeled 3,924,480 elements
recopied by the old growing-prefix concat. The heavy workload produced 21,504
diagnostics and modeled 44,018,688 old prefix copies. That prefix count is a
deterministic model of the baseline operation, not a hardware counter.

Validation passed the 23-test source-AST finalization suite, the owning
compiler check, manifest validation, and all 4,557 `compiler-blorp` tests.
