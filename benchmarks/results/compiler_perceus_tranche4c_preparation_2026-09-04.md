# Perceus Tranche 4C Preparation Baseline

> Correction: the one-sample preparation harness used an odd-node `CastExpr`
> around the complete non-result work sequence. The aggregate traversal treats
> that wrapper as opaque, so the initial smoke numbers below did not exercise
> the advertised aggregate sites. Issue 50 moved the odd padding onto a
> dedicated literal and remeasured the preserved `b181d6ba` workers. Only the
> corrected seven-pair measurements in
> [`compiler_perceus_tranche4c_2026-09-04.md`](compiler_perceus_tranche4c_2026-09-04.md)
> are performance acceptance evidence.

**Date:** 2026-09-04

**Purpose:** Establish the scalar lambda-owner baseline and fixture before the
Issue 50 owner-catalog cutover. These are one-sample smoke measurements, not
performance acceptance results.

## Fixture

- two uncalled, parameterless outer functions;
- one 256-node outer lambda body per function;
- 1, 8, or 32 managed lambda parameters;
- twelve consuming calls, twelve transferring record fields, and twelve
  managed result terminals per outer lambda;
- one nested lambda with one managed parameter per outer lambda; and
- no captures, referenced globals, or outer-function borrowed parameters.

The complete fixture has four lambda regions. Expected managed parameter slots
and scalar owner normalizations are `2 * B + 2` for outer-owner count `B`.

## Command

```bash
benchmarks/compiler_perceus_memory \
  --lambda-owner-matrix \
  --samples 1 \
  --json
```

Environment: macOS 26.6.2, arm64. The source tree was based on merge commit
`16c74c99`; the benchmark reported compiler revision `5454a4bd` because the
preparation changes were intentionally measured before commit.

## Results

| Outer owners | Regions | Parameter slots | Scalar normalizations | Boundary visits | Allocations | Releases | Direct window |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 4 | 4 | 4 | 660 | 13,862 | 13,208 | 1,777 us |
| 8 | 4 | 18 | 18 | 5,470 | 18,520 | 17,866 | 2,366 us |
| 32 | 4 | 66 | 66 | 21,678 | 35,212 | 34,558 | 4,325 us |

Timing worker SHA-256: `b8c9d042fbebee08f79c63891062e1b9799f69d2c373ff257a3f36489a929437`

Counter worker SHA-256: `a0ffc96e2172194e92109e1cf30eeef580f2d8f4da3bf6b74608b0af47395a95`

Harness SHA-256: `084657973e81cc25628e4c7bed0d62753d1c9c17f3a07b201e383c1b9686079d`

## Interpretation

The fixed four-region fixture shows the intended scalar baseline: borrowed
boundary visits and direct-window allocation/release work increase strongly
with owner count while emitted ownership operations remain constant. The
Issue 50 comparison must use the committed preparation revision as its
immediate parent and collect seven warmed alternating samples before making a
speed claim.

Capture/global source-mix timing remains deliberately deferred. Current
runtime-capture discovery is name-based and may overlap exact global discovery,
while capture fixtures also introduce managed ownership in the enclosing
function.
