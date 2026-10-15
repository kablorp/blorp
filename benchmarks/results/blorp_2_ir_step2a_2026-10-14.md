# Blorp 2 IR step 2a: one checked expression tree, 2026-10-14

Checking publishes `CheckedExpr` (a form, a type and a span) instead of the
base-plus-steps `CheckedValue` chain. A receiver is the first argument of its
call, so `a.f(x)` and `f(a, x)` are one node, and a payload-free variant is
`ConstructVariant(id, [])`. Specialization translates the tree node for node;
the fold that turned the checked chain into `ConcreteExpr` in step 1 is gone.
Emitted C and every e2e diagnostic are unchanged.

## Provenance

- Baseline: `origin/main` `a121b5425`, `blorp_2/` exported with `git archive`, compiled with the same
  `bin/blorp` (build status FRESH, commit `02317bf8e140`) and `clang -O0 -DBLORP_MEMORY_DIAGNOSTICS=1`.
  Compiler binary SHA-256 `3bcc9c6fb46e2b4f669d8629d2dfef501766b6a454faa4eabbbbd25e58be94d0`.
- Candidate: the step 2a commit on that base. Binary SHA-256
  `8fb865598fba06114a99f783a540ae4e1a1f086a78605f5421b6548634c8e710`; sources `check_model.brp`
  `983597ac…`, `check_values.brp` `4fc6b4fe…`, `check_recursion.brp` `6baac01a…`, `check_bodies.brp`
  `9599dfba…`, `specialize.brp` `b15f6ab5…`.
- Toolchain: Apple clang 21.0.0, arm64, macOS 26.7.1. Runs were serial and alternated baseline/candidate, three
  each. Allocations (`BLORP_LEAK_CHECK=strict`) are deterministic and portable; retired instructions
  (`/usr/bin/time -l`, minimum of three) are a local proxy that CI disables.
- Method and scripts: step 1's `compare.py` (compiler exit status, stdout, stderr and generated C for every
  fixture) and `cost.py`, kept in the session scratchpad with the raw outputs.

## Output identity

All 333 `.brp` files under `blorp_2/test/e2e/fixtures`: 298 compile and 35 are rejected. Generated C, stdout,
stderr and exit status are byte-identical in every case (0 differences), so every rejected fixture's
diagnostic is unchanged. All 143 unit, runtime and grammar suites pass, run file by file.

## Behaviour that changes

- **Non-tail self calls are reported in evaluation order** (owner decision 5): a call's arguments, receiver
  first, before the call. Two user-visible diagnostics move, both to the inner call:
  - `unused = loop(loop(value))` reports 66..77 (was the outer call, 61..78);
  - `unused = left.loop(loop(left, right))` reports the self call in the UFCS argument, 82..99 (was the
    outer call, 72..100).

  `loop(value).loop()` reports its base call, 61..72, before and after this change. All three are pinned in
  `test_tail_recursion_check`; making `self_call_in` visit a call before its arguments fails all three. No
  e2e fixture contains a nested non-tail self call, so the e2e comparison cannot see this change.
- **Receiver-chain type preparation is node first.** `append_value_types` visits a node's type before its
  children's for every form, as it already did for direct calls and aggregates. Only receiver chains change
  order: `integer().text()` now numbers `text`'s instance first, as `text(integer())` always did. Pinned by
  the new `receiver chain prepares the call type before its receiver type`, which fails on the baseline.

- **The canonical void of a discarded Void tail takes the root's span.** `normalize_void_exit` gives the
  synthesized `LiteralVoid` the discarded expression's own span. For a tail that is a receiver chain or field
  read, that is the whole extent rather than the written base's span. The span reaches only the lowered
  definition of that void, read by internal-error diagnostics; emitted C is unchanged.

The rejected alternative visited a call's arguments before the call (the design note's rule). It flips
`nested call prepares the call type before its argument type` and `test_emit`'s nominal-enums expectation,
and renames union and list instances in the C of four e2e fixtures (`calculator/float`,
`calculator/integer`, `list/nested`, `owned_prefix/union_escape`): same behaviour, different C. Uniform
children-first was also measured: it additionally flips `test_emit`. Node first changes no existing
expectation and no emitted C.

## Cost, with the per-link constant

Receiver chains `1.step().step()...` (`step` adds one). Allocations per compile:

| links | baseline | candidate | candidate - baseline | marginal per link vs 1 link (base / cand) |
| --- | --- | --- | --- | --- |
| 1 | 7,997 | 7,987 | -10 | |
| 8 | 9,166 | 9,169 | +3 | 167.0 / 168.9 |
| 16 | 10,492 | 10,510 | +18 | 166.3 / 168.2 |
| 32 | 13,131 | 13,180 | +49 | 165.6 / 167.5 |
| 64 | 18,394 | 18,506 | +112 | 165.0 / 167.0 |
| 128 | 28,905 | 29,144 | +239 | 164.6 / 166.6 |

Cost stays linear in chain length; the per-link constant rises by about 1.9 allocations. Freezing a UFCS
call now builds its argument list starting with the receiver (one list per call that the old chain did not
need when the call had no other arguments) and validates the receiver from its published type, wrapped in
`AcceptedType` (one allocation). Passing the receiver's inference type alongside its frozen node instead
measured 64 fewer allocations at 64 links, but needs two coupled parameters for one fact, so it was not adopted.

Sampled fixtures (allocations; instructions):

| fixture | allocations | instructions |
| --- | --- | --- |
| return/zero | 6,904 -> 6,902 (-0.03%) | +0.02% |
| ufcs/calls | 7,678 -> 7,673 (-0.07%) | -0.04% |
| record/update/order | 14,324 -> 14,281 (-0.30%) | -0.18% |
| ufcs/chain_64 | 18,399 -> 18,511 (+0.61%) | +0.55% |
| match/constructor_spine | 18,220 -> 18,086 (-0.74%) | -0.48% |

All are within the ±1% ceiling; e2e ceilings are unchanged and pass.

## Nesting depth

Emitted C is byte-identical, so the 64-link chain stays flat as in step 1. The checker's freeze still folds a
chain iteratively; `append_value_calls`, `self_call_in`, `append_value_types` and `translate_expr` now recurse
once per link (64 frames for `chain_64`), as `lower_value` already did.

## Size

Production lines, formatted copies (`bin/blorp format`), non-blank and non-comment:

| file | before | after | delta |
| --- | --- | --- | --- |
| check_model.brp | 402 | 387 | -15 |
| check_values.brp | 3,625 | 3,606 | -19 |
| check_recursion.brp | 312 | 294 | -18 |
| check_bodies.brp | 669 | 655 | -14 |
| specialize.brp | 1,739 | 1,708 | -31 |
| total | 6,747 | 6,650 | -97 |

`check_values` adds five flat `Accepted*` leaf variants with their freeze arms, and its receiver-led
argument loop in `freeze_pending_call`. That loop seeds the argument list with the receiver instead of
reusing `freeze_pending_values` and concatenating; the concatenating version measured one more allocation
per UFCS call (18,570 against 18,506 at 64 links, 29,272 against 29,144 at 128). The file loses the
payload-free special case, `ResolvedValue` (whose `value_type` duplicated the root node's) with
`freeze_expression`, and `ResolvedBase`, whose two fields are now `PlannedLeaf`'s payload. Tests change in
35 files, mostly rewrites of assertions to the tree shape plus the oracles above.
