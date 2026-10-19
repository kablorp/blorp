# Remove unused call-contract payloads

## Scope and boundary

Accepted baseline is `bc6168b483a6680628a2d915ff18f22bd314ab69`, including
ordinary opaque support. This implements only F1 of the phase-boundary audit.
The checker constructs `ArgumentSlot` vectors that no consumer reads and a
`ReceiverContract` whose receiver field is unread. Consumers already retain
actual arguments and use the accepted signature for argument checking.

Remove `ArgumentSlot`, `FunctionContract.arguments`, `paired_arguments` and
`ReceiverContract`. Keep `FunctionContract.target`, `.signature` and `.span`.
Replace pairing with numeric arity validation in the same producers; return
`FunctionContract` directly for receiver calls. Update only the corresponding
consumers in `check/inference.brp` and `check/expressions.brp` and the owning
README description. No new representation, pass, cache, source migration,
unrelated unused-parameter cleanup or other audit finding is included.

For example, the direct-call producer currently pairs arguments before purity:

```blorp
arity = arity_mismatch(name, DirectCall, arguments.length(), DeclaredTarget(callee), signature)
slots ?= paired_arguments(signature.parameters, arguments, []).to_result(arity)
pure_call ?= validate_purity(caller, name, callee, signature)
```

It becomes:

```blorp
arity ?= validate_arity(name, DirectCall, arguments.length(), DeclaredTarget(callee), signature)
pure_call ?= validate_purity(caller, name, callee, signature)
```

Signature lookup still precedes arity, which still precedes purity. UFCS counts
the receiver in actual arity, so a zero-parameter target still rejects. Preserve
receiver synthesis and delayed overload selection at their existing scheduling
points; overloaded UFCS can synthesize its receiver before selecting a target.
Preserve exact diagnostic kind, target, notation, counts, help and span.

## Prospective budget and stop rule

Forecast across three existing production modules: 35–55 ADD, 105–125 DEL,
50–90 net lines removed. Hard scope limits are 65 production ADD and at least
40 net lines removed; reassess before exceeding either. Tests may add at most
70 lines, reusing existing suites and helpers; no fixture growth is expected.
Report physical production, test and documentation changes separately. Do not
compress formatting or delete coverage to reach a limit.

Freeze source, libraries, fixtures, tools and paired compiler artifacts before
production edits. Require allocation nonincrease on every measured input and a
strict decrease for the compiler-source construction proxy and call-heavy
controls. Require normal min-of-three retired instructions nonincrease on every
measured input, with a strict decrease on at least two call-heavy controls.
The frozen controls are `call/one.brp`, `nested/order.brp`, `ufcs/chain_64.brp`,
`generic/contextual/partial_ufcs.brp`, `generic/named/ordered.brp` and
`generic/named/managed.brp`. The UFCS chain and both named controls require
strict allocation decreases; all six require nonincrease. Any positive instruction delta is
inconclusive until one additional complete matched batch; an increase above
0.5% triggers immediate investigation. Median peak RSS is secondary; investigate
increases, immediately above the greater of 1% or 1 MiB, using the same bounded
repeat rule. Retain all original samples and explain smaller consistent RSS
increases too. Repeatable regressions or output drift stop acceptance for
reassessment; do not expand scope to compensate or silently reset the baseline.

## Validation and delivery

Strengthen existing behavior tests before production edits. Check zero-parameter
UFCS and competing arity/purity errors with exact diagnostics. These should pass
on B: this is a semantics-preserving refactor. Kill and restore a bounded arity
fault to demonstrate the existing/new oracles detect it.

Run focused checker suites, then full unit/runtime/grammar/tooling suites. Build
the candidate compiler once and run full native e2e with required instruction
checks, unchanged cost caps, strict zero accounting and existing sanitizers.
Compare ordinary B/C CLI results over every frozen fixture root: status, stdout,
stderr, C presence and successful C bytes must agree. Inspect representative C
and unchanged call targets/evaluation order. Do not normalize discrepancies.

The normal repository commands are:

```sh
bin/blorp test --suite --timeout 180 blorp_2/test/unit/test_check/test_callables.brp blorp_2/test/unit/test_check/test_named_callable_diagnostics.brp
bin/blorp test --suite --timeout 180 blorp_2/test/unit blorp_2/test/runtime blorp_2/test/test_grammar
make -C blorp_2 test-compiler test-e2e
bin/blorp test --suite --timeout 180 blorp_2/test/tooling
```

`test/e2e/test_end_to_end.brp` is the sole native suite entrypoint; group modules
forward through it. This worktree lacks a host binary. A verified FRESH repository
host may be borrowed with explicit `--std-dir`; record those equivalent direct
commands and the once-only compiler build rather than claiming Makefile success.

Measure both the host compiling B/C compiler sources to C and B/C pilots
compiling existing direct, receiver, generic and named-callback fixtures. Use
the same physical input/library paths, compiler flags and output path within
each comparison; retain diagnostic counts and three serial normal instruction/
RSS samples in alternating B/C order. Require identical C within each source
role across normal/diagnostic runs, and across roles for unchanged fixtures.
The compiler-source proxy omits target self-compilation and linking; current
self-compilation is blocked before complete checking, as recorded in the
[accepted opaque validation](../benchmarks/results/blorp_2_opaque_types_2026-10-18.md).
Label that limitation.

Root owns integration and serialized compiled jobs. Independent code-reviewer
and test-runner review the plan before its separate commit and the final code,
tests and evidence before implementation commit. Land only a green accepted
result on main and push origin/main, preserving unrelated work. Raw evidence
stays under ignored `build/`; one concise results report records the decision.

## Acceptance after reassessment

On 2026-10-18 the user accepted the measured 16-KiB UFCS and 32-KiB ordered-
callback peak-RSS increases and authorized landing. The user clarified that the
goal is a better overall direction, without requiring every metric to improve.
The original prospective checks and all samples remain recorded; the accepted
result reduces production LOC, allocations and instructions while disclosing
these small RSS costs. Existing fixture allocation/instruction caps are unchanged.
See the [results](../benchmarks/results/blorp_2_unused_call_contracts_2026-10-18.md).
