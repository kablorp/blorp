# Accepted Semantic Catalog — Step 1 Evidence

Date: 2026-09-10

## Comparison contract

The baseline is immutable `main` revision `66d510c9`, after the unrelated
runtime checkpoint landed. The candidate is the final pre-commit Step 1
worktree. Executable and input hashes below identify the exact artifacts.

The closure screen used the same accepted-stage fixture and five measured
iterations with eight modules, 32 shapes per module, 64 probes per module, and
import fan-out four. One alternating warm pair confirmed that the final sealed-
proof representation retained the directional counter wins. This is a bounded
regression screen rather than a wall-time study.

Function-profile instrumentation is compiled at `-O0`. Its wall clock was
retained only as raw evidence, not as an acceptance metric. Retired
instructions, exact ARC counters, RSS, and artifact sizes are the decision
inputs. Raw counters, row counts, byte sizes, input hash, and executable hashes
are in
`compiler_accepted_semantic_catalog_step1_2026-09-10.tsv`.

## Focused accepted-stage result

Every sample produced semantic checksum `1286981124350644793` and constructor-
lookup checksum `8938789772392276139`. The candidate additionally observed 40
accepted constructor rows and 537 accepted field rows through the catalog's
zero-copy logical views.

| Metric | Baseline | Candidate | Change |
| --- | ---: | ---: | ---: |
| retired instructions | 127,076,367,886 | 124,673,487,328 | -1.8909% |
| allocations per five iterations | 1,684,396 | 1,684,391 | -5 |
| releases per five iterations | 1,565,183 | 1,565,180 | -3 |
| retained objects | 119,213 | 119,211 | -2 |
| allocated bytes | 8,839,080 | 8,839,016 | -64 bytes |
| peak RSS | 83,050,496 | 83,312,640 | +0.3156% |

The RSS movement is below the roadmap's 1% investigation threshold. The
focused profiled worker grew from 9,114,848 to 9,166,432 bytes (+0.5659%), also
below its 1% threshold. That `-O0` profiler contains the newly exposed row
observation paths, so its size is a conservative guard rather than the
production artifact result.

## Artifact guard

| Metric | Baseline | Candidate | Change |
| --- | ---: | ---: | ---: |
| native compiler executable | 19,248,856 bytes | 19,173,184 bytes | -75,672 bytes (-0.3931%) |

Net production Blorp source grows by 864 lines. It includes the catalog
capability, scalar completeness counts, logical row queries, production
consumer migration, category-table accessors, and replacement of three
allocating one-field carrier records with zero-cost sealed aliases. This first
publication slice intentionally favors an explicit boundary; later roadmap
steps must earn their additional representation with consumer cuts.

## Metric-family decision

| Family | Classification | Result |
| --- | --- | --- |
| allocation / ARC work | primary | win: allocations, releases, retained objects, and allocator-reported bytes all decrease |
| retired instructions | primary | win on the focused affected path; no whole-compiler counter claim is made for the final representation |
| retained / peak memory | primary | retained objects decrease; allocated bytes improve and RSS stays inside the guard |
| native artifact size | primary | win: production compiler shrinks 0.3931% |
| compiler latency | guard | unavailable for a directional claim; no counter evidence of a regression |
| semantic work | guard | constructor/field rows are queried without graph-wide reconstruction or duplicate payload ownership |

Step 1 therefore improves every primary family, with no guard exceeding its
investigation threshold. Wall time remains explicitly unclaimed.

## Feedback-loop note

The final representation was screened once after it was frozen. Future roadmap
work should preserve this cadence: smallest correctness fixture, one paired
counter screen, review, then a three-pair acceptance sample only when counters
are close to noise. Do not use additional repetitions to investigate a known
regression or a design that has not completed review.
