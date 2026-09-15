# Step 2e Cut A performance gate, 2026-09-14

Decision: **do not close Cut A's resource gate.** The current one-occupancy-table
design substantially reduces allocations, and a real selective-import
accepted-stage guard preserves semantic products, but the 320-name direct
worker still retires about 11% more instructions than the pre-Cut-A design.
The real selective-import bound stage also retains 1,032 more objects and
53,200 more bytes in its one-iteration window. These are scaling and retention
obstacles, not evidence that the normalized ownership design should be
abandoned. Investigate them before extending Step 2e's candidate/outcome log.

This is a stop screen, not a complete Cut A scorecard: generated-C identity,
worker executable size, actual string-hash/index-probe counts, and a stable
latency distribution were not collected. The gate already fails on direct
instructions and bound retained memory; collect those remaining families
when evaluating a corrective representation change.

## Matched setup

- Historical pre-Cut-A source: `cb716ccf`; current clean source: `b158072a`
  (after merging main). The already-committed Cut B admission builder is
  included in the current candidate. Both fixture workers were built with the
  **same pre-Cut-A compiler executable**, Clang `-O2`, on the same arm64 host.
  This scorecard pins the direct fixture as it stood at `b158072a`; the later
  [fail-fast driver refactor](compiler_visibility_width_fail_fast_2026-09-14.md)
  is measured separately and must not be spliced into this historical pair.
- The retained `compiler_visibility_width_profile` fixture was API-adapted in
  the historical worktree: old graph-scope construction and registration
  signatures, sequential local/import publication, and an expected distinct
  row count in place of the current bound-row count accessor. Accepted binding,
  duplicate, and query checks were unchanged. `batch_initial_locals=0` and
  `batch_graph_imports=0` denote historical behavior; both are `1` for current.
- Fixture setup, compiler execution, and C compilation are outside the
  measurement window. Counters are from cached worker binaries. One-shot
  elapsed time and RSS are context, not a latency or peak-memory claim.
- The exact historical API-adapted
  [direct fixture source](compiler_step2e_cut_a_baseline_fixture_2026-09-14.brp.txt)
  is retained. To reproduce the pair, copy that source into
  `blorp/benchmark/compiler/compiler_visibility_width_profile_fixture.brp`
  in a worktree at `cb716ccf`, and copy the direct profile entry from
  `b158072a` into that worktree. Build both worker binaries using the
  historical `bin/blorp`. The accepted
  fixture/profile changes in this packet were applied identically to both
  worktrees. Use the shared runner with
  `BLORP_COMPILER_BENCHMARK_WORKSPACE_ROOT=<worktree>`,
  `BLORP_COMPILER_BENCHMARK_COMPILER=<baseline>/bin/blorp`, and
  `BLORP_COMPILER_BENCHMARK_SKIP_BUILD=1`.

## Direct graph-bound visibility

Each row uses 100 iterations and 16 modules. Baseline and candidate returned
`status=OK`, identical final bound/import counts, duplicate counts, query hits,
and query checksums. Retained objects were one (96 bytes) in every direct run.

| Case (aliases/selectives/locals/duplicates/queries) | Baseline allocations | Current allocations | Baseline instructions | Current instructions | Outcome |
| --- | ---: | ---: | ---: | ---: | --- |
| 32/32/16/16/128 (80 names) | 56,101 | 45,501 | 217,939,436 | 213,163,554 | narrower case improves both |
| 128/1/1/0/0 (130 names) | 90,901 | 78,301 | 340,164,625 | 309,244,664 | alias-heavy case improves both |
| 1/128/1/0/0 (130 names) | 103,601 | 91,001 | 393,622,621 | 331,456,011 | selective-heavy case improves both |
| 64/64/32/32/256 (160 names) | 112,101 | 90,301 | 385,927,863 | 385,979,498 | same-mix instruction parity |
| 128/128/64/64/512 (320 names) | 224,101 | 179,901 | 819,656,832 | 915,915,493 | allocations -19.7%; instructions +11.7% |
| 128/128/64/64/0 (320 names) | 224,101 | 179,901 | 800,166,275 | 883,612,960 | query-free instructions +10.4% |

A second full 320-name pair retired 821,004,963 baseline versus 913,614,401
current instructions (+11.3%). Thus query projection is not the primary source
of the regression; it is already present during admission. The 80-, 160-,
and 320-name rows retain the same alias/selective/local/duplicate/query ratio;
instruction parity at 160 and regression at 320 suggest a width-sensitive
cost, but do not yet prove a dictionary-capacity mechanism. In one full pair,
baseline/current peak footprints were 1,868,064/1,917,216 bytes and RSS
3,358,720/3,473,408 bytes; these small single-run differences need a more
isolated memory measurement before treating them as an independent regression.

## Real selective-import accepted-stage guard

The retained phase fixture now has an optional `selective` target-import mode.
It selects one uniquely named shape from every imported module and uses that
name in target annotations. The phase fixture is validated through the full
graph before the accepted-stage measurement window. The structural test
`test_selective_import_phase_profile_reaches_accepted_graph` passed, together
with the other eight tests in its suite.

Command shape: `compiler_blorp_benchmark_runner selective-accepted
blorp/benchmark/compiler/compiler_typecheck_phase_profile.brp plain accepted
1 64 1 1 4 memory 100 selective`, with the matching workspace root, one shared
historical compiler path, and `BLORP_COMPILER_BENCHMARK_SKIP_BUILD=1`.

| 64-module accepted stage, 1 iteration | Baseline | Current | Delta |
| --- | ---: | ---: | ---: |
| Allocations / releases | 350,170 / 233,680 | 351,616 / 235,060 | allocations +0.41% |
| Retained objects | 116,490 | 116,556 | +66 (+0.06%) |
| Allocated bytes | 8,194,224 | 8,192,272 | -0.02% |
| Retired instructions | 1,700,145,863 | 1,694,843,400 | -0.31% |
| Peak footprint / RSS (bytes) | 37,126,456 / 41,107,456 | 36,979,024 / 40,910,848 | single-run context |

Both returned `primary_outputs=1161`, `secondary_outputs=129`,
`accepted_constructor_rows=264`, `accepted_field_rows=321`,
`checksum=9051196322135327782`, and
`constructor_lookup_checksum=-1538987862295765844`, with no graph-wide
constructor projection. The accepted-stage checksum does not fingerprint
individual import bindings or callable signatures; matched *bound* and
*callable-header* observations below provide those checks. A 16-module
selective run also matched all accepted-stage checksums; current allocations
were +0.5% and instructions -0.5%.

| Same 64-module selective fixture, 1 iteration | Baseline | Current |
| --- | ---: | ---: |
| Bound checksum (includes selected import bindings) | -2,147,185,015,783,105,813 | -2,147,185,015,783,105,813 |
| Callable-header checksum (includes resolved signatures) | -5,507,584,145,912,170,774 | -5,507,584,145,912,170,774 |
| Bound allocations / releases | 181,513 / 180,241 | 180,315 / 178,011 |
| Bound retained objects / allocated bytes | 1,272 / 123,352 | 2,304 / 176,552 |
| Bound retired instructions | 1,257,212,038 | 1,247,961,946 |

The bound stage shows a **material retention regression** despite fewer
allocation calls and instructions. The accepted-stage measurement is a
different isolated phase and cannot substitute for this bound-stage check. The
structural fixture test also checks that selective and qualified sources have
different bound-import fingerprints but identical callable and accepted
fingerprints. Both the bound retention change and the direct wide instruction
change keep Cut A's resource gate open.

## Next bounded action

Profile or instrument occupancy admission between 160 and 320 distinct names
at the same operation mix, and trace why bound selective-import output retains
an additional 1,032 objects/53,200 bytes. Compare one-table lookup/set and
publication against the old three-map owner; dictionary capacity is a
hypothesis, not yet a diagnosis. Do not add a second retained index or a
general-purpose integer dictionary on speculation. Change one concrete owner
at a time, then rerun the direct wide pair and the 64-module bound and accepted
selective guards. Keep exact semantic checksums and the parent roadmap's
resource thresholds.
