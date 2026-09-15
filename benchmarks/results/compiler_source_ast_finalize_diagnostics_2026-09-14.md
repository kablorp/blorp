# Source-AST Finalization Diagnostic Batching

## Decision

Accepted. `finalize_exprs` now appends each child diagnostic into its uniquely
owned result rather than concatenating every child list into the growing
prefix. Exact AST and diagnostic checksums match the baseline. The isolated
clean, dense, and heavy workloads all improved elapsed time; the clean path
also removed 28.48% of measured allocations.

Retired instructions were unavailable on the macOS measurement host. The
direct evidence is allocation/release counts, exact output checksums, produced
diagnostic counts, and the baseline prefix-copy model. The elapsed medians are
supporting evidence.

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
- Raw outputs:
  `/tmp/blorp-issue106-validation-{baseline,candidate}-{dense,clean,heavy}-{N}.out`
- Raw hash manifest: `/tmp/blorp-issue106-validation-raw-sha256.txt`, SHA-256
  `3890be7ceb916edb2471ab4fdf28b694861f6c622d3067a08032c392cc95b4a8`

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

for variant in baseline candidate; do
  exe="/tmp/blorp-issue106-validation-${variant}"
  for n in 1 2 3 4 5; do
    "$exe" 5 1024 2 4 1 > "/tmp/blorp-issue106-validation-${variant}-dense-${n}.out"
    "$exe" 5 1024 0 1 1 > "/tmp/blorp-issue106-validation-${variant}-clean-${n}.out"
  done
  for n in 1 2 3; do
    "$exe" 2 4096 3 8 1 > "/tmp/blorp-issue106-validation-${variant}-heavy-${n}.out"
  done
done
```

## Results

| Workload | Samples | Baseline median µs | Candidate median µs | Change | Baseline allocations | Candidate allocations | Change |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| clean | 5 | 4,753 | 3,679 | -22.6% | 35,950 | 25,710 | -28.48% |
| dense | 5 | 155,814 | 130,415 | -16.3% | 792,430 | 786,080 | -0.80% |
| heavy | 3 | 650,476 | 374,673 | -42.4% | 2,171,952 | 2,162,762 | -0.42% |

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
