# Early-Core Invariant Scan Consolidation

Issue 134 consolidated compatible resolve and synth invariant families into
one breadth-first walk of each immutable post-stage Core program. The baseline
was `ac4a1a9c`; the candidate changed only invariant traversal, its focused
tests, and the retained benchmark and result artifacts.

## Decision

Accept. Resolve invariant node visits fall from two full-program walks to one
(-50%), and synth visits fall from three walks to one (-66.67%) on the
all-monomorphic compiler-shaped fixture. Median resolve latency fell 76.51%
and allocations fell 81.28%. Synth latency fell 72.71% and allocations fell
87.51%. The unchanged debug and mono single-family controls stayed within the
3% latency guardrail and allocated exactly the same number of objects.

Separate result buckets preserve the existing family-major diagnostic order.
Synth carries root eligibility through its shared worklist so generic
functions and impl methods remain excluded from mono checks. No result is
cached or reused across Core transformations, and the specialized std-inline
invariant remains a separate traversal.

## Paired optimized-build results

The dedicated benchmark constructs and counts its 64-function, 40,768-node
fixture before the measured window, then calls the production invariant entry
point 100 times. Seven alternating pairs were retained for resolve and five
for synth and the controls. Every row reported `workload_valid=True`, zero
violations, identical ordered diagnostic checksums, and workload checksum
`-5493477679518498366`.

| Family | Baseline median | Candidate median | Change | Allocations | Allocation change |
| --- | ---: | ---: | ---: | ---: | ---: |
| Resolve | 1,259,667 us | 295,873 us | -76.51% | 13,033,500 to 2,440,000 | -81.28% |
| Synth | 2,075,344 us | 566,327 us | -72.71% | 19,550,300 to 2,441,700 | -87.51% |
| Debug control | 632,212 us | 627,829 us | -0.69% | 6,516,700 to 6,516,700 | 0.00% |
| Mono control | 636,618 us | 644,370 us | +1.22% | 6,516,700 to 6,516,700 | 0.00% |

The paired rows are retained in
`compiler_core_invariant_scan_consolidation_2026-09-15.tsv`.

A single external `/usr/bin/time -lp` resolve sample reported 34,885,926
retired instructions for baseline and 35,298,868 for candidate (+1.18%). This
counter did not reproduce the large allocation and latency change, so
acceptance rests on the deterministic 81.28% allocation reduction rather than
an instruction claim.

## Exact traversal attribution

Ten resolve checks called baseline `check_expr_roots` 20 times. The candidate
composite owns one traversal directly, so it called the old helper zero times
and completed ten walks. Ten synth checks similarly moved from 30 helper calls
to ten direct walks. Candidate inclusive composite time fell from 412.093 ms
to 171.207 ms for resolve and from 674.471 ms to 251.479 ms for synth.

The exact rows are retained in
`compiler_core_invariant_scan_consolidation_exact_2026-09-15.tsv`. Both
profiles reported zero invalid starts/ends, unmatched or out-of-order ends,
metadata failures, stack-growth failures, cancellation abandonment, signal
abandonment, and recovered nonlocal exits. Each reported the same four
profile-window boundary abandonments.

## Correctness and output identity

- Focused invariant tests explicitly preserve resolve-before-string-add and
  debug-before-string-equality-before-mono ordering even when expression or
  root traversal order conflicts with that priority.
- Root tests cover generic top-level functions, globals, concrete impls, and
  mixed generic/concrete impl declarations.
- Baseline and candidate compilers emitted byte-identical C for the current
  compiler source, SHA-256
  `49fa491a51c6805751a413ccec9240c11e54bdece857ed2d2b6aea3ddd775efa`.

## Provenance and reproduction

The shared benchmark source SHA-256 was
`45734309d2f889e69c6de71cb8ea864d280d235debb980d5730abd2dbe87bef7`.
Baseline and candidate `early_invariants.brp` hashes were
`8e580ef5efbc93d8f222231218dcb35002c16eb11a561343548829a82d69e20d`
and
`d8ff1251e3cd15b6aa35ee39cb6cd8e9ed5c7b91b025f183556c8c7a58d0bf02`.

```bash
benchmarks/compiler_core_invariant_scan_profile plain 100 resolve 64 256
benchmarks/compiler_core_invariant_scan_profile plain 100 synth 64 256
benchmarks/compiler_core_invariant_scan_profile plain 100 debug 64 256
benchmarks/compiler_core_invariant_scan_profile plain 100 mono 64 256

benchmarks/compiler_core_invariant_scan_profile profile 10 resolve 64 256 \
  2>/tmp/blorp-core-invariant-resolve-profile.txt
benchmarks/compiler_core_invariant_scan_profile profile 10 synth 64 256 \
  2>/tmp/blorp-core-invariant-synth-profile.txt
```
