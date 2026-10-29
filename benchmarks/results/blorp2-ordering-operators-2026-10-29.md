# Blorp 2 ordering operators: frozen-input cost

Step 2 of the [ordering operators plan](../../blorp_2/ORDERING_OPERATORS_PLAN.md).
The ceilings were +0.5% retired instructions and +0.5% allocations on a frozen
input, with byte-identical output C. Both are met, and the output C is identical.

## Setup

- **Frozen input:** `git archive c45796a03 blorp_2`, compiled as
  `--library-root <frozen>/standard_library <frozen>/src/main.brp`. It uses no
  ordering operators, so the change can only add cost, not remove it.
- **Compilers:** the pinned seed `blorp2-seed-bc0444ee40b2` (source
  `bc0444ee40b299f5de6799c6233f8af0c16f617a`) built each compiler's C from
  `blorp_2/src`: the baseline from `c45796a03` and the candidate from this
  branch. Each was linked with Apple clang 21.0.0 at `-O0`, with
  `-DBLORP_MEMORY_DIAGNOSTICS=0` for instructions and `=1` for allocations.
  - baseline C `c271043a…af2bfd`, binary `b4a232a4…e970e5`;
  - candidate C `daf2a983…df943`, binary `5ec5d26a…bd3b9e3`.
- **Runs:** serial on one macOS arm64 machine, one warmup each, then three
  timed runs alternating baseline and candidate under `/usr/bin/time -l`. One
  strict run of each diagnostic build (`BLORP_LEAK_CHECK=strict`) gave the
  allocation counts.
- **Raw samples:** `build/ordering-step2/` (ignored), with the setup and run
  scripts' outputs.

## Results

| Metric | Baseline | Candidate | Change |
| --- | ---: | ---: | ---: |
| Instructions retired, median of 3 | 69,895,717,035 | 70,124,043,277 | +0.327% |
| Instructions retired, range | 69,890,339,549 – 69,913,778,428 | 70,047,654,658 – 70,160,166,927 | |
| Allocations (strict, all released) | 25,342,748 | 25,342,477 | −271 (−0.001%) |
| Output C SHA-256, all 10 runs | `1338d53e…d3e719` | `1338d53e…d3e719` | identical |

Elapsed time (10.3 to 12.4 s) and peak memory (227 to 236 MB) varied within
the same band for both compilers and are not claimed.

## Attribution

- **First lexer.** The first lexer tested each new two-byte spelling in its
  own `else if`, each evaluating two byte tests for every non-identifier
  token. That measured +0.576% (median 69,848,773,625 to 70,251,197,128).
  Grouping the tokens that start with `=`, `<` or `>` into one branch per
  first byte, as shipped, brought the total to +0.327%.
- **Lexer probe.** The candidate rebuilt with `c45796a03`'s lexer measured
  +0.296% against a matched baseline (69,862,705,108 to 70,069,315,110). The
  shipped lexer therefore accounts for about 0.03%.
- **Unattributed.** The remaining ~0.30% lies in parsing, naming or checking
  and was not attributed further. The emitted C carries no function names to
  map samples to. The baseline median moved by 0.07% across the three sessions.
  This is an open follow-up: attribute it at the owning phase, for example by
  bisecting the parser's six-way `comparison_operator` and the name seeding,
  before the migration step adds the operators to the frozen source.
- **Allocations.** The likeliest source of the 271 fewer allocations is that
  the "no canonical trait" error is now built only when the prelude selects no
  trait. The old equality dispatch built it eagerly for every `==` and `!=`.
  This is not verified: the frozen source has 333 `==` and 69 `!=` outside
  comments, which does not match 271 exactly.
