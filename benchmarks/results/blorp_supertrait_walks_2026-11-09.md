# Blorp supertrait walks visit each trait once (2026-11-09)

Check's two supertrait walks in `blorp/src/compile/check/traits.brp` followed
every route through the supertrait graph. Repeated supertraits and diamonds
are valid, so a ladder `LayerN: LayerN-1 + LayerN-1` of N + 1 short traits
gave 2^N routes.

- `supertrait_cycle` walks up from each trait to find a cycle back to it.
  Its per-root walk now skips any trait it has already entered. Every trait
  reachable from a trait entered earlier and left is either on the walk or has
  had all its edges checked. So no closing edge lies beyond it, and the first
  closing edge and its reported path are unchanged.
- `entails` asks whether a held bound reaches a required trait. It is now one
  worklist with a queued flag per trait. Its `held == required` case still
  allocates nothing.

## Ladder fixtures

The fixtures are generated: `Layer0` declares `base`, each later layer names
the one below it twice, and `Other` is unrelated.

- **accept:** `reach[T: LayerN]` calls `base`, so the program compiles. Every
  trait's cycle walk covers the ladder below it.
- **reject:** `reach[T: LayerN]` calls `other`. The failed entailment covers
  the whole ladder before reporting the missing bound.

Each figure is retired instructions for one `blorp compile` from
`/usr/bin/time -l`. Runs were serial, and both compilers came from `make -C
blorp compiler`.

| Depth | accept, before | accept, after | reject, before | reject, after |
| ---: | ---: | ---: | ---: | ---: |
| 12 | 508,671,330 | 455,852,081 | 214,472,426 | 155,571,096 |
| 16 | 1,524,944,659 | 456,756,468 | 1,307,902,870 | 156,470,294 |
| 18 | 5,143,838,008 | 457,313,846 | 5,173,027,207 | 157,132,955 |
| 20 | 20,844,059,763 | 457,452,342 | 21,860,377,203 | 158,927,896 |
| 40 | not run (2^40 routes) | 463,747,145 | not run | 164,558,577 |
| 200 | not run | 804,254,275 | not run | 506,336,228 |

Before the change, the unit suite with the two 40-layer tests was still
running after 120 s and was stopped. After it, the suite passes in seconds.

## Self-compile cost

Both compilers were generated from their sources by the candidate compiler
and linked with `clang -O2 -DBLORP_MEMORY_DIAGNOSTICS=1`. Each one compiled
the candidate's `blorp/src/main.brp` under `BLORP_LEAK_CHECK=strict`. The
three rounds alternated before and after.

| Metric | Ceiling | Before | After |
| --- | --- | ---: | ---: |
| Allocations | at most +0.1% | 13,615,420 | 13,615,442 (+22) |
| Retired instructions, best of 3 | at most +0.5% | 13,224,100,601 | 13,215,108,315 (−0.07%) |
| Self C | identical | 25,255,921 bytes | identical |
| Production lines (`traits.brp`) | | | +52 / −19 |
| Test lines (`test_supertraits.brp`) | | | +75 |

Host: Apple M4, macOS 26.7.1, with other sessions sharing the machine. The
base is `43ab27609`.
