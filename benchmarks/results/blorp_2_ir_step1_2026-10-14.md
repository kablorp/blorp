# Blorp 2 IR step 1: one concrete expression tree, 2026-10-14

Specialization publishes `ConcreteExpr` (a form, a type and a span) instead of the
base-plus-steps `ConcreteValue` chain, and lowering walks it with one flat match.
The lowered program, the emitted C and every diagnostic are unchanged. This is the
consumer end of the plan in `blorp_2/build/ir_design.md`; the checked tree is step 2.

## Provenance

- Baseline: `origin/main` `02317bf8e`, `blorp_2/` exported with `git archive`, compiled with the same
  `bin/blorp` and `clang -O0 -DBLORP_MEMORY_DIAGNOSTICS=1`. SHA-256 of the compiler binary:
  `5b748445159d9bdd3c2e2fc7e4ae637ee19bbd0d4ac15166bb1d910b9605e610`.
- Candidate: the step 1 commit on that base. Sources `specialize.brp`
  `b73208e245e466c0e2b367776902041d680090998f5b8e00b037b41bc3890ac8`, `lower.brp`
  `edb5c55ac3b72654d39e028a0c0df02b657b7bc12f4004cc3797bcc6c8c5b92d`.
- Toolchain: Apple clang 21.0.0, arm64, macOS 26.7.1. Runs were serial and alternated baseline/candidate,
  three each; allocations are the portable signal, retired instructions (`/usr/bin/time -l`, minimum of three)
  are a local proxy that CI disables.
- Scripts and raw outputs: the session scratchpad (`compare.py`, `cost.py`, `chains/`); the numbers below are
  copied from those runs.

## Output identity

All 333 `.brp` files under `blorp_2/test/e2e/fixtures` were compiled by both compilers: 298 compile and
35 are rejected. Generated C, stdout, stderr and exit status are byte-identical in every case (0 differences).
`make -C blorp_2 test` passes (335 e2e cases). The lowered `ValueDefinition` spans are unchanged (lowering reads a
call's callee anchor from the call), pinned by `test_chain_definitions_keep_the_callee_anchor_of_each_call` and the
existing `constructor and call keep types and spans`; reading the node span there makes five `test_lower` callbacks fail.

## Cost, with the per-link constant

Receiver chains `1.step().step()...` (`step` adds one). Allocations per compile, baseline then candidate:

| links | baseline | candidate | candidate - baseline | marginal per link vs 1 link (base / cand) |
| --- | --- | --- | --- | --- |
| 1 | 7,999 | 7,993 | -6 | |
| 8 | 9,169 | 9,162 | -7 | 167.1 / 167.0 |
| 16 | 10,496 | 10,488 | -8 | 166.5 / 166.3 |
| 32 | 13,136 | 13,127 | -9 | 165.7 / 165.5 |
| 64 | 18,400 | 18,390 | -10 | 165.1 / 165.0 |
| 128 | 28,912 | 28,901 | -11 | 164.7 / 164.6 |

The cost is linear in chain length in both builds and the per-link constant is the same (about 165 at 64 links,
a difference of -0.1 allocations per link). An earlier candidate that built each argument list as
`[receiver].concat(values)` measured +1.9 allocations per link (+118 at 64 links); starting the list with the
receiver removed that cost. Whole-compile deltas elsewhere are within +-0.4% on the sampled fixtures
(return/zero 0.00%, ufcs/calls -0.04%, constructor_spine -0.36%, record/update/order -0.18%). Retired
instructions fall 1.1% to 2.6% across them (for example chain_64 74.64M to 73.51M, return/zero 48.24M to 47.27M).

`chain_64` measured 18,399 allocations and 75.1M instructions in the e2e harness; its ceilings are 24,000
and 100M (about 30% headroom), set from that run rather than copied from the one-link fixtures. The README
ceiling table (lines 343-360) already disagrees with `test_ufcs.brp` for the one-link fixtures; that predates this
change and is a follow-up.

## Nesting depth

The emitted C for the 64-link chain is flat: 66 `blorp_f_1(` calls as sequential definitions, maximum brace
depth 1 and parenthesis depth 1; it compiles with `-std=c11 -Wall -Wextra -Werror -pedantic -O0` and exits 65.
Host recursion depth is 64 links in `lower_value`; translation and the checker's fold stay iterative.

## Size

Production lines (raw, the sources are not formatter-clean on main either): `specialize.brp` 1,939 to 1,931,
`lower.brp` 682 to 636, a net **-54**. Tests change by 554 lines added and 243 removed across 24 files, mostly
rewrites of assertions to the new shape plus the oracles below.

## Oracles

- Reversing the fold (`value.operations.reverse()`) fails `UFCS chain nests each receiver as the first argument`
  and `chain node span is the occurrence and the anchor stays on the call`.
- Appending the receiver instead of putting it first fails `direct and UFCS calls share one argument order`
  (`7.pair(9)` and `pair(7, 9)` must both give `[7, 9]`).
- Giving a call node the anchor instead of its own span fails the span test.
- Visiting a call's arguments before its own type in `append_value_types` (step 2's rule) fails
  `nested call prepares the call type before its argument type`, the only callback that changes.
- Step 2 flips two pins: that one and `nested direct self call in an initializer reports the outer call`. The
  receiver-chain tail pin (61..72) is an invariant guard that arguments-first keeps.
