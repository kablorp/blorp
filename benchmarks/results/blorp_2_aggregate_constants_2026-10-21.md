# Blorp 2 closed aggregate constants

Closed constant initializers now use the ordinary checker and retain one checked
expression template. Reads construct fresh runtime values through existing
Specialize/Lower/Own machinery. Records, unions, Lists, tuples, Void and named
function values are accepted; calls, references to other constants, lambdas,
control expressions and postfix operations remain excluded. There is no global
initialization, constant evaluator, cache or synthetic function owner.

Constant annotations precede accepted signatures and entrypoint diagnostics;
initializers precede function bodies. Annotation/initializer child spans survive
materialization; the root takes the read span. Direct and qualified callable
constant calls share existing stored-call preparation, including ordinary arity,
purity and argument checks. Scalar constant-call errors remain unchanged.

## Matched costs

Baseline is accepted tuple commit `9c12cc79e3b7b919af93debde139595b4288e42e`.
Baseline, behavior-preserving preparation and feature compilers compiled the same
frozen baseline compiler and target library at identical physical input, cwd and
output paths. All control C archives are byte-identical, SHA256
`46c041be4c5be389cd5e6b6d288f5abd8e673ca78b003914849232ac456ee4e3`.
The cost ceiling fixed before implementation was +3% allocations and +3% minimum
of three normal retired-instruction samples, independently for preparation and
feature. Linking is outside the measurement boundary; no speedup is claimed.

| Role | Strict allocations/releases | Normal minimum retired instructions | Allocation change | Instruction change |
| --- | ---: | ---: | ---: | ---: |
| Baseline | 30,783,201 | 886,354,803,231 | — | — |
| Preparation | 30,806,576 | 886,394,791,688 | +0.07593% | +0.004512% |
| Feature | 30,796,495 | 886,491,831,332 | +0.04319% | +0.01546% |

All strict runs balanced with zero leaks/outstanding bytes. Normal samples were
baseline 886354803231/886460424000/886492732656; preparation
886394791688/886396083145/886402745220; feature
886501019876/886491831332/886518499557. Each role passes both ceilings.
Apple Clang 21 and the resolved SDK/toolchain are pinned; unmodified generated C
was linked with `-std=c11 -Wall -Wextra -Werror -pedantic -O0`,
`BLORP_MEMORY_DIAGNOSTICS=0` for normal and `=1` for strict, plus `-lm -lpthread`.
`/usr/bin/time -l` supplies retired instructions. Runs were serial.

The qualified baseline diagnostic producer is tuple fixpoint `stage_b`, SHA256
`08da7db066e80e3c041060f7c8e5c751af6811eccc5ed95f4bdd4961ee56da9c`.
Normal binary hashes are baseline
`dbd373cb17d813aa3f2e0bd37e9692a5d567a711c55293b95c9c4b5f706ea969`,
preparation `4a91398d0b5d46370dbdb2d7709b0872a60b27a9fee88d06aab972d9af91dd26`
and feature `ddd1174c7a0e46b6fc0969d6a5ecccd73c25f94deb72278847831df9d1ac1150`.
The raw samples, exact argv arrays, source/library/membership/private-environment
pins and causal generation/link receipts are retained under the isolated
worktree's ignored `build/aggregate-constants/execution/`, notably
`RUN_COST02.py`, `BUILD_ROLES.json` and `MATCHED_COST.json`.

## Correctness and limits

The accepted baseline rejects the new aggregate fixture with its exact scalar-only
message/help. Focused owning suites pass 55 callbacks. Hosted components pass
3,993 maintained plus 334 nested runtime callbacks; the separately compiled target
text suite passes 1 callback. The fixed external host observer is SHA256
`16b0dc7ed23d8066ec3ff8ff5983850e0e7a02bf65579871e78f2f2cfeb87cb6`
with explicit frozen host standard-library inputs; this is authorized recipe
isolation, not a claim that the isolated worktree's legacy Make build is fresh.

Native strict and ASan/UBSan runs print exactly `seven/right/7` (three lines),
`40/40/node λ` (three lines), and return 15 with empty stdout for selected plus
qualified generic callable-constant calls. Runtime strict allocations/releases
are respectively 14/14, 162/162 and 0/0, all zero leak. The nested fixture has 40
actual constructor levels; emitted C has maximum lexical parenthesis depth 3,
brace depth 4 and bracket depth 1, excluding comments/literals. This does not
claim a new physical ABI. Unmodified strict C11 links are used throughout.

Two source-valid faults prove oracle sensitivity: replacing the materialized
callable target produces exactly 2 intended failures among 8 callbacks; dropping
record-payload ownership produces exactly 1 intended failure among 3 callbacks.
Byte-exact restoration passes all 8 and 3 respectively.

Current-source real-CLI self-compilation emits four identical C archives, SHA256
`ba6393c4d54bf8ba9f7afa858ef747e10825b118c63d471905c50f5e2e95f3b9`.
Fresh normal/diagnostic links emit the same archive; both strict runs balance
31,028,464 allocations/releases with zero leaks/bytes. Fresh diagnostic binary
`81f82c6c5579eba9c53aa27b075e738aa88140bdf38588afc55ececead9ef523`
is the full end-to-end compiler under test, with no fallback.

The full self-built end-to-end invocation exits 0 in 379.517 seconds: 58
maintained suites pass 575 callbacks, and 463 nested native suites pass 786
callbacks. The outer ordinary aggregate observer passes its one callback; printed
status lines total 1,362. No callback fails, no suite frame remains open, no
1800-second outer timeout fires, and source/library/role/Git guards are stable.
The maintained inner timeout remains 0. Existing CI policy is explicitly
`BLORP_2_RESOURCE_POLICY=record-allocation-debt` and
`BLORP_2_INSTRUCTION_CHECK=disabled`; native/strict and matched instruction gates
above are independent. All 117 allocation-debt FAIL metric records are retained
in `e2e01/RESOURCE_DEBT.json`, rather than interpreted as behavioral success or
suppressed. The new 40-level fixture compiles with 196,527 allocations against
the existing 140,000 constant-group ceiling; no threshold is raised. This is
recorded resource debt, while runtime strict/sanitizer balance passes. Commands,
streams and exact nesting reconciliation remain in `e2e01/`.

Production is 441 added/279 removed (+162 net); tests are 773 added/41 removed;
README/grammar are 30 added/14 removed. This report is counted separately.
Initial setup failures and the initial incorrect newly authored Own oracle remain
in ignored evidence; they receive no passing-gate credit. Final exact source and
test reviews by independent code and protocol reviewers report zero findings.

This increment does not change TestSuite factory/registration API, finish test
self-hosting, admit sets/dictionaries, permit initializer calls or allow constant
references/cycles. It adds no global initialization or evaluator.
