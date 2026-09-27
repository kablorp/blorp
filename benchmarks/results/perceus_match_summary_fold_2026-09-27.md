# Perceus match-summary fold pilot (2026-09-27)

Three constructor-match summary helpers accumulated a temporary list of
`OwnershipUseSummary` values, then reduced it fieldwise. The pilot folds the
same case, geq, and fallback summaries into four local scalars in the original
order. Shadowed, absent, and fail branches retain the zero summary.

## Frozen comparison

- Source base and input revision: `35040738956ff6254e07b8669bf87dda160b82fd`.
- Both compilers: FRESH `-O2`, bootstrap `dev-2f1a59c43baa`, Apple clang 21.0.0.
- Baseline and candidate: `/private/tmp/blorp-summary-fold-base.json` and
  `/private/tmp/blorp-summary-fold-candidate.json`; each has three retired-
  instruction samples from `benchmarks/self_compile_measure lock --` with
  `--require-identical`.

| Measure | Baseline | Candidate |
| --- | ---: | ---: |
| Fused ownership/Perceus allocations | 43,569,705 | 43,447,685 |
| Whole-compile allocations | 191,938,542 | 191,816,522 |
| Retired instructions, minimum of three | 149,434,427,430 | 149,181,936,333 |

All candidate instruction samples were below all baseline samples. The
generated C is byte-identical (78,701,454 bytes, SHA-256
`421bc2f0025e0e295d62a559c32dbe9f2e1fea2c4470e4884b132cb218600340`).
Self-compilation's post-Perceus Core is byte-identical; a small program's
generated C is also byte-identical.
This saves 122,020 allocations in the fused pass and 0.17% of minimum sampled
instructions on this workload; it is not a general latency claim.

The focused Perceus suite passed 390/390. `scripts/compiler-check --changed
--base main` passed 2,566/2,566; explicit sanitizer and leak gates passed
3,153/3,153; `compiler-blorp` passed 5,171/5,171; and the codegen audit passed
221/221. Independent code and test reviews found no issue. Retained logs are
under `/private/tmp/blorp-perceus-summary-p1-*` and
`/private/tmp/blorp-summary-fold-gates/`. These measurements were made on
the isolated pilot branch before integration into `main`.
