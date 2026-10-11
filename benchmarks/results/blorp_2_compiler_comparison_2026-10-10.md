# Blorp compiler fixture comparison, 2026-10-10

Base revision: `49dbb089122685b479459ad37a874c754dbe0544`, branch `blorp-2`.
The measured working tree adds user-approved zero-argument `main` support to
the existing compiler, the comparison command and tests. Pilot production
sources and all 95 fixture inputs are unchanged.

## Command and boundary

```sh
scripts/compiler-build-status
blorp_2/scripts/compare-compilers --samples 3 \
  --output blorp_2/build/comparison-new
```

Every output directory must be new. The retained run used
`blorp_2/build/comparison-validation/corpus`. The macOS command builds the
pilot once per run, then alternates serial compiler order for each sample.
Both compilers receive the same original fixture file; the pilot also receives
its explicit input-program prelude. No input adaptation or alternate entrypoint
is used. Setup, target C compilation and target execution are outside measurement.

Elapsed time covers whole compiler processes through C emission, including
startup, input/library loading and time/env wrapper overhead. Retired
instructions come from macOS `time -l`. Allocation counts are unavailable:
both measured compilers have memory diagnostics disabled. The existing host
has CLI `-O0` and runtime `-O2`; the pilot and its runtime use `-O0`.
These small-fixture results do not isolate a phase or establish self-compile,
full-language equivalence or future compiler performance.

## Results

The run retained 570 attempts: 564 succeeded. The pilot succeeded on all 285
samples; the existing compiler succeeded on 279. There are 93 complete
fixtures and 279 successful paired samples. Source, binary, script and input
stability checks passed; recorder source drift was false. Repeated successful
C outputs were byte-identical within each compiler/fixture. Different compilers'
C outputs are not expected to match.

For the 93 complete fixtures, sums of per-fixture minima across three samples:

| Metric | Existing compiler | Pilot | Existing / pilot |
| --- | ---: | ---: | ---: |
| Elapsed seconds | 19.515857 | 0.468168 | 41.686 |
| Retired instructions | 300,797,241,874 | 3,258,325,402 | 92.317 |

Per-fixture elapsed ratios range from 13.945 to 45.801, median 42.746.
Instruction ratios range from 13.802 to 107.435, median 99.888. Minima reduce
launch noise but do not replace repeated independent runs. The one-sample
smoke showed that first-launch wall time can obscure instruction differences.

The command exits 1 because the existing compiler rejects two fixtures in all
three samples. Both ratio columns are withheld for these fixtures:

- `mortal_string/alias.brp`: `-7.to_string()` reports
  `Negation requires an implementation of Negatable for String`, followed by
  cascading type errors.
- `mortal_string/minimum.brp`: the host rejects positive magnitude
  `9223372036854775808` before negation, followed by UFCS type errors.

These are additional language-compatibility gaps, not measured successful
compilations. They were retained without rewrites, skips or additional fixes.

## Validation

- Comparison command TestSuite: 7/7 pass; independent leak-checked rerun also
  7/7, zero leaks. Tests cover exact inputs/order, failure receipts, missing or
  empty C, binary drift, ratio suppression and output-directory preservation.
- Mutation checks: removing alternation causes the intended one failure;
  bypassing ratio suppression causes exactly the two failure/drift tests to
  fail. The script was restored byte-identically before measurements.
- Existing-compiler change: 480/480 callbacks across 10 selected importing
  Blorp suites; four exact error/help rejections and accepted zero-arg fixture.
- Native `-O0` ASan/UBSan checks: zero-arg Int exits 7, Void exits 0, custom
  ExitStatusAble exits 9 with exact stderr; argument-taking main preserves
  argv including spaces. Representative one-argument C is byte-identical.
  ASan leak detection was disabled on macOS; this is not a native leak proof.
- Independent affected Core suite with ASan/UBSan: 171/171 pass.
- Broad `compiler-core-sanitize` is **not green**: two attempts exhaust the
  host backend's stack while emitting the 59-suite harness, before callbacks.
  Matching macOS crash reports identify excessive recursion. Baseline status
  remains unproved; no unrelated backend repair was attempted.
- Existing Python-owned `compiler-blorp` fixture orchestration and
  `typecheck-body-metrics` were excluded under the user's no-Python testing
  constraint. The entire generated-C audit was not rerun.

Independent compiler-expert review approves the bounded implementation and
comparison design with no actionable findings. `git diff --check` passes.

## Provenance and retained evidence

The host was FRESH before and after the run, Apple Clang 21.0.0, macOS arm64.

| Artifact | SHA-256 |
| --- | --- |
| Source snapshot | `e73bce80378cae3c2bc792ac58c50747d55ac64de2207bfce7b05a5d564bdef0` |
| Existing binary | `ab0f9087e4fee0ac877e636c6fc9dd446be3b691e98fc4abb938946bb1f0f780` |
| Pilot binary | `3b0ddc7d585d203c949d53a550e3b039296cdf22d3798dd95003722d91328749` |
| Comparison script | `7c704b9bb097999e0a322bf620f5b6ef85a6596f767a2788fee3ac806b55b342` |

The single local evidence entrypoint is
[`blorp_2/build/comparison-validation/README.md`](../../blorp_2/build/comparison-validation/README.md).
It links frozen sources, binaries, raw samples/C, setup commands, recorder
packets, mutation tests and host-main validation. These large artifacts are
ignored local evidence; this report retains the conclusions and limitations.
The separate [architecture audit](blorp_2_architecture_audit_2026-10-10.md)
records the immutable-facts and identity assessment and its bounded findings.
