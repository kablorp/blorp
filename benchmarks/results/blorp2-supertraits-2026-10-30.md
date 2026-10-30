# Blorp 2 supertraits: frozen-input cost

Milestone 1 of the [supertraits plan](../../blorp_2/SUPERTRAITS_PLAN.md). The
plan set three ceilings: retired instructions at most +0.3%, allocations at
most +0.05%, and at most 300 production lines. The instruction and allocation
ceilings are met with byte-identical output C. `blorp_2/src` grows by 308 net
lines (341 added, 33 removed), down from 361 before review; the owner raised
the line ceiling to 310 on 2026-10-30.

## Setup

- **Frozen input:** `git archive 1d4f3c626 blorp_2`, compiled as
  `--library-root <frozen>/standard_library <frozen>/src/main.brp`. It declares
  two traits and six implementations, and no supertraits. The change can
  therefore only add cost: an empty supertrait list per trait, the cycle walk,
  and the obligation pass over the implementation rows.
- **Compilers:** the pinned seed `blorp2-seed-f426e350082c` (source
  `f426e350082c13645d304dae8441b89a1d60dd2a`) built each compiler's C from
  `blorp_2/src`: the baseline from `1d4f3c626` and the candidate from this
  change's working tree. Each was linked with Apple clang 21.0.0 at `-O0`, with
  `-DBLORP_MEMORY_DIAGNOSTICS=0` for instructions and `=1` for allocations.
  - baseline C `2911b264…7ad633`;
  - candidate C `add98fe4…459d94`.
- **Runs:** serial on one macOS 26.7.1 arm64 machine, one warmup each, then
  three timed runs alternating baseline and candidate under `/usr/bin/time -l`.
  One strict run of each diagnostic build (`BLORP_LEAK_CHECK=strict`) gave the
  allocation counts.
- **Raw samples:** `build/supertraits/` (ignored), with `measure.sh`, adapted
  from `build/orderable-sort/measure.sh`, and its log.

## Results

| Metric | Baseline | Candidate | Change |
| --- | ---: | ---: | ---: |
| Instructions retired, median of 3 | 70,472,860,308 | 70,428,566,042 | −0.063% |
| Instructions retired, range | 70,400,290,432 – 70,578,663,224 | 70,406,456,187 – 70,527,779,079 | |
| Allocations (strict, all released) | 25,602,541 | 25,602,563 | +22 (+0.0001%) |
| Output C SHA-256, all 10 runs | `1b57ad34…0ac3d1` | `1b57ad34…0ac3d1` | identical |

The instruction change is smaller than the run-to-run range of either
compiler. The two pre-review candidates measured −0.03% and +0.021% (+27
allocations), also within noise. Elapsed time and peak RSS varied within the
same band for both compilers and are not claimed.

## Production lines

| File | Added | Removed |
| --- | ---: | ---: |
| `check/traits.brp` | 106 | 15 |
| `check/supertraits.brp` (new) | 93 | 0 |
| `check/render.brp` | 54 | 5 |
| `parse/parse.brp` | 36 | 5 |
| `check/errors.brp` | 20 | 1 |
| `check/recursion.brp` | 19 | 2 |
| `check/check.brp`, `model.brp`, `utils/ids.brp`, `utils/syntax.brp` | 13 | 5 |
| Total | 341 | 33 |

Of the 341 added lines, 36 are blank and 42 are comments. Review removed 53
net lines: the access check moved into supertrait resolution, the original
admission loop was restored with a separate cycle loop, the cycle walk lost
its memo, the errors carry the written receiver instead of a head to spell,
one renderer replaced three, the parser reports a missing colon at the
newline, and the obligation message says "an implementation of Equatable"
rather than choosing an article from the trait's spelling. Test growth is
reported separately: 761 lines added and 2 removed,
in the two new unit suites, three native fixtures and their harness rows,
and a deferred grammar case.

## Mutation probes

Each mutation was applied, the test compiler rebuilt, `test_supertraits.brp`
run, and the source restored.

| Mutation | Tests that failed |
| --- | --- |
| `prove_trait` compares trait numbers again | 6: subtrait bound, receiver bound, transitive, diamond, one way, missing implementation. All three native fixtures stop compiling with "type does not satisfy the required trait bound". |
| `entails` walks downward | 8: the six above, unentailed receiver bound, and supertrait method placement |
| Entailment holds both ways | 1: entailment runs one way |
| Obligation pass skipped | 3: missing implementation, rejected automatic equality, unentailed receiver bound |
| Pass moved before finalization | Does not compile: the pass takes `FinalTraits` |
| Finalizer publishes the implementations it was given | 1: obligations read the final implementations |
| Cycle walk visits no supertraits | 2: self cycle, longer cycle. Neither run hung. |
| Private supertraits allowed | 1: a public trait cannot name a private supertrait |
| Canonical Equatable may declare supertraits | 1: its admission test |

The skipped-pass, placement, both-ways and canonical probes ran before
review; the others were re-run on the reviewed code.
