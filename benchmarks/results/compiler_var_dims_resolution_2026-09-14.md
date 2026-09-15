# Variable-Dimension List Resolution

Date: 2026-09-14. Former issue: variable-dimension list flattening (#101).
Baseline revision: `9ecb72e934c42f730fe15b5f3f05ee62a76db5f6`.
Candidate implementation: `5eb02186` plus the one-pass correction in
`8a5fab60`.

## Decision

Accepted with an explicit evidence substitution for the proposed hardware
counter gate. `resolve_var_dims_type_list` now appends each concrete dimension
to its uniquely owned result instead of concatenating each expansion into the
growing prefix. The final implementation remains one pass and performs one
substitution lookup per variable-dimension root; the rejected capacity
prepass is not part of the accepted change.

The wide workload reduces retired instructions by 8.52% and total allocations
by 0.06%, not the proposed 10%. The candidate is accepted with an explicit
evidence substitution because the isolated production path removes 100% of
the modeled old prefix recopy work, paired elapsed medians improve 9.78% to
11.95% across widths 1/4/16/64, width one improves, and exact resolved-type and
generated-C output identity hold. The direct eliminated-work model is the
operation the issue targets; timing corroborates that mechanism.

## Measurement

The retained driver constructs a mixed return type containing ordinary,
expanded, missing, and recursively nested variable-dimension types. Fixture
construction and warmup occur before the timing and allocation window. Seven
samples per variant were run in paired, alternating order from generated C
compiled with `cc -O2`.

```bash
# Build each variant from the same retained harness with the same fresh
# workspace compiler, then compile the emitted C with cc -O2 and the compiler
# native-header include paths.
/private/tmp/blorp-var-dims-interleaved-714f/baseline 500 64 16 2
/private/tmp/blorp-var-dims-interleaved-714f/candidate 500 64 16 2
```

| Expansion width | Baseline median µs | Candidate median µs | Change | Baseline allocations | Candidate allocations | Change | Old prefix elements recopied |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 24,202 | 21,310 | -11.95% | 261,000 | 246,500 | -5.56% | 265,000 |
| 4 | 29,424 | 26,545 | -9.78% | 325,000 | 312,000 | -4.00% | 445,000 |
| 16 | 50,335 | 45,371 | -9.86% | 575,000 | 568,000 | -1.22% | 1,165,000 |
| 64 | 140,843 | 124,457 | -11.63% | 1,544,000 | 1,543,000 | -0.06% | 4,045,000 |

Every sample reported `workload_valid=True`, balanced allocations/releases,
and the same checksum and warmup checksum within its width. The alternating
sample table is retained as
`benchmarks/results/compiler_var_dims_resolution_2026-09-14.tsv`, SHA-256
`2a48ff2b1381ff5781b4241b4df8cfa18ba20a867aa5d3db9af00de182775f51`
and raw outputs remain under
`/private/tmp/blorp-var-dims-interleaved-714f/`. Their hash manifest has SHA-256
`3a61ca90ecd5168802651449accd7dafa4b73cb5790bf49906e0b4e6593f9f02`.

Seven additional alternating pairs under `/usr/bin/time -lp` produced these
process-level counters:

| Expansion width | Baseline median retired instructions | Candidate median retired instructions | Change |
| ---: | ---: | ---: | ---: |
| 1 | 438,018,452 | 397,380,199 | -9.28% |
| 64 | 2,613,372,896 | 2,390,841,565 | -8.52% |

Those samples are retained as
`benchmarks/results/compiler_var_dims_resolution_instructions_2026-09-14.tsv`,
SHA-256 `858c8745acbc9a3de3c8c2cf48c22afedb6086fa8c89c12ccf7b0394261c653d`.
The 28 corresponding raw counter files are covered by
`/private/tmp/blorp-var-dims-interleaved-714f/retained-instructions-sha256.txt`,
whose SHA-256 is
`7ba6370da14e41be9d260ea5bac2e33c82e3116fbc63abd7db726bdeb2004459`.

Three alternating self-compiles were also recorded in
`/private/tmp/blorp-var-dims-one-pass-self-714f/times.tsv`: baseline times were
60.23/76.21/73.13 seconds and candidate times were 67.88/71.97/63.42 seconds,
for medians of 73.13 and 67.88 seconds (-7.18%). Because this is a noisy,
three-pair end-to-end sample, it is corroborating rather than acceptance
evidence. Each variant produced a stable compiler C hash across all three
runs.

The baseline and candidate compilers emitted byte-identical C for
`vardims_tuple_return_resolution.brp`, SHA-256
`a44d6d6649f202c20c0b7d607048004a3e31d9e539d0536d77b3b88182167dbb`.
The focused inference suite passed all 311 tests, including mixed ordering,
missing substitutions, recursive types, and the newly added empty expansion.

## Caveats

- The old prefix-copy count is a deterministic model of the baseline concat
  operations, not a hardware counter.
- The retained timing matrix varies expansion width at fixed input count; a
  future list-builder experiment should also hold total output size constant.
- The first width-one sample from an earlier non-alternating run was a warmup
  outlier and is intentionally excluded from the retained alternating matrix.
