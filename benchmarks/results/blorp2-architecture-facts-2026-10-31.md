# Accepted-fact cleanup: F1

F1 removes the second proof of trait-default written header bounds. Trait
contracts remain the proof authority; ordinary free/implementation headers
still validate under their own requirements. Default body annotations and
signature normalization are unchanged. No new representation is retained.

Implementation follows [F1 in the reviewed plan](../../blorp_2/ARCHITECTURE_FACTS_PLAN.md#f1-prove-a-defaults-written-header-once).
The role dispatch is inline in the existing callback, avoiding a single-use
helper. Production: **16 added / 1 deleted / +15 net lines**. Tests:
**28 added / 0 deleted / +28 net lines**. Documentation is separate.
F2–F4 are not implemented by this change.

## Provenance and measurement boundary

Baseline: `395731510` (current main after arithmetic operators), not the
earlier `51d98be37` audit snapshot. The initial build at the older snapshot
was superseded before final measurement. Evidence is under
`build/architecture-facts/f1-current/`; the older setup remains under `f1/`.

Pinned seed: `blorp2-seed-9df029bac05b`, full source
`9df029bac05b0d0a39d65325049eaceac1305330`. The seed builds baseline A; A
emits baseline B. Baseline B compiles the candidate compiler source. Each
normal/diagnostic executable pair links the same generated compiler C with
Apple Clang `21.0.0 (clang-2100.3.34.2)`, `-std=c11 -O0 -lm -lpthread`,
differing only in `BLORP_MEMORY_DIAGNOSTICS=0/1`.

Both variants compile the same frozen baseline `src/main.brp` and its complete
import graph with the same frozen target library. Source/library/test hashes,
compiler C and binary hashes, toolchain details and the exact production diff
hash are retained in `frozen-hashes.json` and `provenance.json`.

Three normal CLI samples run serially, alternating baseline/candidate order;
`/usr/bin/time -l` records retired instructions. Separate strict diagnostic
runs record allocations/releases. No Clang compilation/linking or test
execution is inside the measured boundary. The ordinary compiler argv is:

```sh
--library-root build/architecture-facts/f1-current/frozen/blorp_2/standard_library \
build/architecture-facts/f1-current/frozen/blorp_2/src/main.brp OUTPUT.c
```

## Results

| Metric | Baseline | Candidate | Change |
| --- | ---: | ---: | ---: |
| Allocations | 17,277,990 | 17,277,974 | −16 (−0.000093%) |
| Retired instructions, minimum of 3 | 49,625,222,134 | 49,620,960,551 | −0.00859% |
| Normal peak RSS, maximum of 3, bytes | 296,943,616 | 294,092,800 | −0.96% |

The instruction difference is noise, not evidence of a speedup. Allocation
and instruction results meet the plan's unchanged +1% ceilings. Every strict
measurement balances allocations/releases with zero live allocations/bytes.

All normal instruction samples:

| Variant | Sample 1 | Sample 2 | Sample 3 |
| --- | ---: | ---: | ---: |
| Baseline | 49,625,320,281 | 49,627,725,770 | 49,625,222,134 |
| Candidate | 49,643,995,846 | 49,642,915,679 | 49,620,960,551 |

All eight frozen-input C outputs (six normal, two diagnostic) are
byte-identical. The candidate also compiles its own changed source:
17,281,556 allocations, strict zero leaks, and 49,628,988,959 retired
instructions in one normal observation. Its own-source normal/diagnostic C
matches baseline B's emission for that same changed source. Own-source counts
are a different workload, not the matched improvement row above.

## Correctness and oracle evidence

- Baseline and candidate each pass all **19 declaration-bound callbacks**;
  both strict runs report zero leaks. Positive behavior is preserved rather
  than presenting the refactor as a new language feature.
- The three new callbacks cover bounded default parameter/return signatures,
  missing default supertrait entailment, and independent authored-method
  header validation. Existing free-header and default-body checks remain.
  Rejections compare the sole diagnostic's message, help, span and absent note.
- In a scratch source copy with F1 applied, bypassing trait-header proof
  produces **17 passes / 2 failures**, exit 1, with zero leaks. The new
  default-header rejection and existing abstract-method rejection fail;
  default body and authored implementation rejections still pass.
  No production source is mutated for this check.
- Generated C inspection confirms the default-role branch returns `Ok(Void)`
  before reading accepted function rows; ordinary roles read the row and call
  the unchanged signature proof, with an invariant error for a missing row.
  A readable inspection excerpt is retained as `header-lambda-readable.txt`.

## Final gate and review

The independent test runner's single `scripts/blorp2-fixpoint --prove` run
passes: B/C compiler-source identity, all **649** candidate A/B fixture
comparisons, **693** component callbacks across 85 suites, and **122**
runtime/native callbacks across five suites. Broader deferred native suites
remain deferred and receive no PASS credit.

A separate baseline-395/candidate comparison also passes **649/649** unchanged
fixtures: exact exit status, stdout, stderr and C, with no normalization.
It compiles each fixture once with baseline B and reuses the candidate B
outputs already retained by the final gate. All 665 fixture/library hashes
match before/after manifests. Evidence: `baseline-fixture-parity.json` and
`baseline-fixture-inputs-{before,after}.json` in the evidence directory.

Code-reviewer and independent test-runner both approve F1 with no blockers.
No resource limits, deferred-suite policy or bootstrap pin change is included.
The previous fixpoint evidence was preserved by move with matching before/after
manifests (4,856 entries, 141,936,550 bytes); it was not used as this baseline.
