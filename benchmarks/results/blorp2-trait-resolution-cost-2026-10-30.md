# Blorp 2 trait-method resolution cost

Arithmetic milestone 1 (`f42eeccd4`, not yet on main) turns Int, Float and
String arithmetic into trait-method implementations. With the main compiler,
self-compiling that source cost 5.0% more retired instructions and 1.4% more
allocations than compiling its parent, `a5785d3fd`
([arithmetic traits report](blorp2-arithmetic-traits-2026-10-30.md), "Input
effect"). This change removes most of that cost in Check. Diagnostics and
generated C do not change.

## Causes

A compiler cut short after a chosen phase (a temporary edit to `main.compile`,
kept only under `build/`) showed that all of the input effect was in Check.
Specialize, lower, own, verify and emit cost the same on both inputs, within
0.03G instructions. Within Check there were two causes:

1. **Linear scans of `AcceptedTraits.implementations` on every trait-method
   call.** About 300 rows in a self-compile, mostly automatic equalities.
   `provider_owns_method` scanned every row for each method import edge that
   offers the name, and the prelude gives each user module eight `_base` type
   edges that all offer `add`. Each row it passed also allocated a closure.
   `method_body` (contract proof and recursion analysis),
   `prove_family`/`family_for` and recursion's origin scan made further full
   scans per call.
2. **Repeated family checks in `receiver_clashes.reject_module_families`.**
   For every method edge, it collected the target's method names, duplicates
   included, and ran `visible_method` once per occurrence. The eight `_base`
   edges list `_base`'s names eight times, so the six new arithmetic method
   names cost 6 × 8 visible-method queries per module, each over all edges.
   This cost 1.37G of the 3.07G that Check grew by. The synthetic probe has
   only one module, so it did not show this cause.

The growth in `validate_recursive_instantiation` came from cause 1 alone,
through `append_method_dependencies` calling `method_body` and scanning again.
An Int receiver has no type arguments, so these calls add no dependency edges,
and no edge deduplication was needed.

## Change

- `check/model.brp`: `AcceptedTraits.implementations` becomes an opaque
  `ImplementationTable`. It holds the rows in acceptance order and an `IntMap`
  index from a receiver-head hint to that head's rows; the hint follows the
  digest-as-hint precedent in `specialize/indexed_list.brp`. Only
  `implementation_table(rows)` builds a table. It returns `None`, which every
  caller reports as a checker invariant, if two rows implement one trait for
  one head, or if a row holds a member of another trait. Both invariants were
  already true after acceptance (`DuplicateImplementation`, members drawn from
  the trait's own declaration), and family lookup depends on them.
  `family_for` (moved here from `traits.brp`) is now a lookup.
  `method_body`, `provider_owns_method` and recursion's origin search read the
  one family of the method's own trait. All three construction sites rebuild
  through the constructor: authored acceptance, automatic equality and final
  pruning.
- `check/receiver_clashes.brp`: each distinct method name is checked once per
  module, in first-occurrence order, keeping the first `WrittenName`. The
  result of `visible_method` depends only on (module, name), so the first
  error is the same.

Production `blorp_2/src`: +151 / −66 lines, net +85, after review fixes:
named hint constants, one `checked_implementation_table` helper in
`traits.brp`, a named pruning predicate and pruning that again keeps the
table untouched when nothing is unavailable. The table accounts for +136/−61
and the deduplication for +15/−5. Tests: a new 180-line active suite,
`test_check/test_implementation_table.brp`, plus a one-line Makefile
registration and 18/13 lines of mechanical updates in deferred check suites.
Those suites already failed to compile before this change, because they use `+`.

## Setup

- Baseline compiler: `9df029bac` (origin/main). Candidate: this working tree.
  The pinned seed `blorp2-seed-f54f9f45f914` generates both. Both are linked
  with Apple clang at `-O0`, with `-DBLORP_MEMORY_DIAGNOSTICS=0` for
  instructions and `=1` for strict allocation counts.
  - Baseline C: `87de5cfb…a8d02c`.
  - Candidate C before the review fixes: `92c6b623…cf966774`. After them:
    `2cfe46fb…7659fa`, which is also the fixpoint B/C C.
- Inputs: A = `git archive 9df029bac blorp_2`, B = `git archive f42eeccd4
  blorp_2`, and A0 = `git archive a5785d3fd blorp_2` (B's parent).
  - B lacks main's three later commits, so A→B also contains those reverted
    commits. A0→B isolates milestone 1.
- Runs: serial, on one macOS arm64 machine. For each input, one warmup, then
  three alternating runs per compiler under `/usr/bin/time -l`, then one
  strict diagnostic run per compiler.
- Script and raw samples are under `build/trait-resolution/` (ignored):
  `measure.sh`, `measure.log` and `runs/`.

## Results (medians of 3)

| Input | Baseline instructions | Candidate instructions | Change |
| --- | ---: | ---: | ---: |
| A (frozen main) | 63,152,682,148 | 61,115,442,177 | −3.23% |
| B (milestone 1) | 65,856,728,177 | 61,428,585,439 | −6.72% |
| A0 (milestone parent) | 62,711,458,710 | 60,974,684,486 | −2.77% |

| Input | Baseline allocations | Candidate allocations |
| --- | ---: | ---: |
| A | 19,064,021 | 18,966,600 (−97,421, −0.51%) |
| B | 19,325,278 | 19,013,451 |
| A0 | 19,051,888 | 18,962,763 |

Every run released all of its allocations. Each input's output C is
identical across all eight runs of both compilers:

| Input | Output C |
| --- | --- |
| A | `87de5cfb…` |
| B | `bfec7080…` |
| A0 | `3bcf62b7…` |

Run ranges were within 0.07% of the medians.

### Input effect

| Pair | Baseline instructions | Candidate instructions | Baseline allocations | Candidate allocations |
| --- | ---: | ---: | ---: | ---: |
| A0 → B (milestone only) | +5.02% | **+0.74%** | +273,390 (+1.43%) | **+50,688 (+0.27%)** |
| A → B (main to milestone, includes reverting main's last three commits) | +4.28% | **+0.51%** | +261,257 (+1.37%) | **+46,851 (+0.25%)** |

The targets, set in the task brief before implementation, were at most +1.0%
instructions and +0.5% allocations for the input effect, no regression on A,
and at most 120 production lines. Both pairs meet the cost targets. The line
target is met as net growth (+85) but not as added lines (+151).

Intermediate result, from single runs before the deduplication: with the
table alone, A0 → B was +2.54% instructions. Check-only builds then showed
Check's growth fall from +1.58G to +0.43G with the deduplication.

### Synthetic probe

The probe is `steps.brp`: 600 functions × 20 chained `step.add(n)`, which is
12,000 calls, compiled with input A's library and then with input B's.

| Compiler | Instructions per extra call |
| --- | ---: |
| Baseline | 220K |
| Candidate | 97.5K |

The probe's remaining per-call cost has two parts:
- `visible_method` still looks up a family once for each of the eight `_base`
  edges that offer the name, now at a few thousand instructions each.
- Inference of a call whose signature contains `Self` (`admit_call_type`,
  `call_argument_hints`, `finish_pending_call`) costs more than a call to a
  monomorphic free function. This is inherent to calling a generic signature.

After the review fixes, one recipe A pair: baseline 63,211,436,882 and
candidate 61,137,781,129 instructions (−3.28%). Candidate allocations were
18,965,300, and the output C was `87de5cfb…`, identical to the baseline's.

## Proposed commits

1. Implementation table (model, callables, traits, recursion, supertraits,
   the new suite and Makefile row, deferred-suite updates). Measured alone, in
   single runs: A0 → B input effect +2.54% instructions; A 62.64G against the
   baseline's 63.52G.
2. One family check per method name in `receiver_clashes`. Check-only builds
   showed Check's A0 → B growth fall from +1.58G to +0.43G; with both, A0 → B
   is +0.74%.

## Not done

- `equality_body` (read by Specialize) still scans the rows; it is a
  Specialize cost and outside this Check task.
- Recursion analysis of a method called on a type-parameter receiver still
  visits every row per call. It is unchanged by milestone 1.
- Per-call family lookups over the `_base` edges could be removed by caching
  visibility per (module, name). That is a new cache and needs approval; it
  was not needed to meet the targets.
