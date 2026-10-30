# Blorp 2 library builtin simplification

Baseline: `01846d70a04a0b7ddda51ccfefe0895fb61ee63a`.

`float.is_nan` and `float.is_finite` are now ordinary Blorp functions. The
former negates self-equality; the latter compares self-subtraction with zero.
The current binary64 contract exposes no floating-point environment controls.
Self-subtraction of infinity may set the native invalid-operation flag; this
does not change an observable language result under the current contract.

Both operation labels and their parsed/runtime variants, signature checks,
specialization cases and dedicated emitter were removed. Native classifiers
remain in C parsing/formatting helpers where those helpers still need them.
The target library has 38 operation builtins, down from 40. Production Blorp
source decreases by 48 lines; test source grows by 5 lines. Removed tests
describe the deleted intrinsic representation; general malformed Float/Bool
contract tests retain their coverage through surviving comparisons.

## Functional evidence

- Before implementation, the updated parser suite produced the expected
  three passes and two failures on the removed-label rejection cases.
- The final self-hosted proof passed 431 component checks in 58 suites and
  98 native checks. These are the active selections, not all deferred tests.
- A and B agreed on all 626 fixtures: 512 accepted and 114 rejected each.
  Every result was additionally checked for a valid status and output shape;
  equality of abnormal exits was not accepted as proof.
- A, B and C emitted identical compiler C, SHA256
  `3f2c6d916a0c1d8fc007b6cac81fa96cc44d34e31ea5224fbe131d1f2abcdfa7`.
- All 13 classification cases passed with strict accounting, normally and
  under ASan/UBSan. They include signed zeros, finite extremes, subnormals,
  signed infinities and NaNs.
- Independent source mutations returning constant False for `is_nan` or
  constant True for `is_finite` caused exactly two and four expected failures.
  The mutation runs also passed sanitizer and strict-accounting checks.
- All 1,303 guarded source/library/test/Make inputs stayed unchanged during
  proof and measurement. All reported strict balances had zero leaks.

## Matched self-compile costs

Ceilings set before implementation: at most 3% more allocations or normal
retired instructions, 5% more peak RSS, and no production-line growth.
Both actual self-built B compilers compiled the same final source/library
input. Baseline B was built from a Git snapshot of the baseline using its
seed-built A; candidate B came from the maintained fixpoint proof. The
pinned producer was `blorp2-seed-f426e350082c`. All links used the Makefile's
Clang `-O0` recipes, with memory diagnostics disabled for normal samples and
enabled for strict allocation samples.

| Metric | Baseline B | Candidate B | Change |
| --- | ---: | ---: | ---: |
| Normal retired instructions | 67,295,579,516 | 67,277,405,055 | -0.027% |
| Strict allocations/releases | 21,396,370 | 21,396,370 | unchanged |
| Normal peak RSS, bytes | 320,438,272 | 329,859,072 | +2.94% |
| Strict peak RSS, bytes | 317,669,376 | 320,192,512 | +0.79% |

All ceilings pass. These are one serial normal and one serial strict sample
per version; instruction differences this small establish no speed gain.
All four outputs have the identical compiler-C hash above. Strict allocations
and releases balance, with zero leaks.

## Integer parsing experiment: not integrated

An isolated ordinary Blorp parser uses negative accumulation and checks
before multiplication/subtraction, preserving both Int64 endpoints. Its
12 ordinary TestSuite callbacks pass, including overflow, NUL, Unicode,
sign handling and 8,192 leading zeroes.

A matched ordinary program preconstructs 24 inputs, then performs 10,000
rounds through the native or draft parser. The two sources differ only in
the parser call, use the same compiler and strict C11 `-O0` flags, and both
produce `130000\n910000\n`. The normal native workload retires 360,147,999
instructions; the draft retires 2,906,622,145: **8.07 times as many**. Both
strict workloads allocate/release 35 objects with zero leaks. This is one
sample per version and includes identical input setup and checksumming.

That local instruction regression is disproportionate. `string.parse_int`
remains native; no parser migration or new optimization mechanism is included.
The rejected prototype is preserved as evidence, not production code.

Raw artifacts, commands, toolchain fingerprints and hashes are under ignored
`build/builtin-migration/`: `float/functional-results.json`,
`float/measurement/results.json`, `float/mutations/`, `baseline/`, and
`parse-int-draft/local-cost-results.json`. The maintained proof retains its
raw outputs under `blorp_2/build/fixpoint/`.
