# Blorp 2 expression synthesis/checking seam

The checker now names three substantive boundaries. `synthesize_value` owns
the existing shared recursive traversal and accepts only optional
constructor-directed context. `check_value` requires an `ExpectedValue`,
supplies its constructor context, and validates the final type with the
existing `ExpressionTypeMismatch` facts. `check_arguments` owns ordered child
elaboration, instantiation and argument obligations. New bindings and match
scrutinees synthesize; returns, arms and reassignment check their known types.

This follows the synthesis/checking distinction without introducing a solver.
Argument mismatch checks remain delayed until all children elaborate, preserving
later-child errors over earlier mismatches or generic conflicts. Outer postfix
contracts still resolve before base expressions. Concrete receivers supply
constructor context; generic receivers do not. Contracts are reused, rigid
parameters remain declaration-owned, and only complete checked products escape.
No public testing API, inference variables, unifier, syntax or generic capability
was added. Contextual inference and structural unification remain later slices.

Production changes are confined to `src/check.brp`; README explains the seam.
Root owns the accompanying approved sequence in `GENERICS_PLAN.md`.

## Test-first contracts

`test/unit/test_bidirectional.brp` adds 16 in-process TestSuite callbacks.
They separate synthesized binding/scrutinee facts from checked returns, arms,
concrete direct arguments and UFCS receivers; retain generic constructor payload
identity; reject constructor context leaking into synthesis or generic receivers;
check unused generic bodies rigidly; pin direct, UFCS and generic delayed-error
precedence; and pin outer-postfix preflight precedence. Arm/reassignment failures
assert primary and actual spans, Int/String types and exact annotation or
function-owned binding provenance.

All 16 pass against both baseline and candidate. Before production edits,
dropping constructor context from the old boundary failed exactly four of the
initial 13 callbacks: nominal binding/scrutinee setup, checked return, checked
arm and rigid generic constructor. Source restoration was byte-identical.
`tdd-contracts.log`, `tdd-context-drop.log` and
`tdd-all-contracts-baseline.log` retain this distinction; the three later
provenance/precedence cases have baseline-contract evidence rather than a claimed
mutation run.

Focused validation passed **204/204 callbacks**: 16 seam, 43 checker, 14 typed
errors, 23 arguments, 24 generics, 22 generic unions, 14 match, 28 bindings and
the existing 20-program corpus. `focused.log` retains results, including the
independent exact renderer obligations. Formatting and `git diff --check` pass.
All prior callbacks remain. Independent strict ASan/UBSan/leak validation passed
**451/451 unit callbacks**. The full pilot passed **610/610 callbacks**: 608 leaves
(451 unit, 9 runtime, 84 end-to-end and 64 grammar) and two wrappers. The
end-to-end run generated and linked the pilot once, passed every unchanged cost
cap and retained stress depth three. Both recorded gates exited zero without
timeout or sanitizer reports. All 133 frozen source/receipt entries stayed
unchanged during the gates. The compiler-expert/code-reviewer approved with zero
findings; the independent test-runner approved. Their reports and command packets
live under `build/bidirectional/{code-review.md,test-review.md,validation/}`.

## Identity, costs and size

All **68/68 unchanged fixtures emit byte-identical C** against the frozen
baseline. Outputs and zero-leak reports are under
`build/bidirectional/identity/{baseline,candidate}/`; `identity.log` records the
comparison. Generated constructor-spine C was inspected. Fixtures, e2e harness
and cost caps are unchanged. The first identity invocation used stale flat
fixture paths from an older packet; the completed comparison uses all 68 current
grouped fixture paths recorded in `baseline/workloads.txt`.

These are owned-input compilation proxies, **not self-compilation**. Three quiet
serialized samples use the existing recorder, with builds outside measurements:

```sh
/usr/bin/time -l -o REPORT.time /usr/bin/env BLORP_LEAK_CHECK=strict \
  PILOT blorp_2/src/prelude_temp.brp FIXTURE OUTPUT.c
```

Allocations are deterministic; instructions are minimum-of-three. Raw samples
are under `build/bidirectional/matched/`, extracted in `matched.tsv`.

| Fixture | Immediate baseline allocations / instructions | Candidate allocations / instructions |
| --- | ---: | ---: |
| return/zero | 687 / 30,722,337 | 687 / 30,721,237 |
| nested/calls | 1,330 / 32,624,714 | 1,330 / 32,538,487 |
| mortal_string/basic | 1,037 / 31,905,973 | 1,036 / 31,665,829 |
| generic/box | 2,152 / 34,950,582 | 2,152 / 34,823,703 |
| union/values | 3,639 / 39,009,888 | 3,634 / 39,022,543 |
| match/constructor_spine | 8,665 / 52,478,258 | 8,665 / 52,553,033 |

No allocation increases; maximum instruction increase **0.14%**, below 2%.
Original `da8fa4c71` samples were also refreshed; cumulative maxima are
**13.59% allocations / 5.66% instructions**, below 25%. All 54 runs release
every allocation. No optimization or cap change was made.

Production grows **10,234 → 10,241 (+7 physical formatted lines)**, below the
+80 investigation threshold. The flat/reduced aim was not achieved: explicit
reassignment branching and formatted checking calls account for the small
increase. Tests grow **19,985 → 20,393 (+408)**; none were removed or compressed.

## Frozen provenance and handoff

Immediate baseline: clean `a121b61b742e187fcf887bd65d0e14ca51da7086`.
Baseline sources, binary and C were frozen before production edits under
`build/bidirectional/baseline/`; source archive SHA-256
`00860c611719d5e46ea97a1757a461913623ca08e81f28b3659696cb7cfae898`.
The original cumulative baseline remains under
`build/generic-expansion/arguments/baseline/` and has not advanced.

Candidate pilot SHA-256:
`0968e5dc15e9c05b6416c3ec61a11043c08a623be095226dbfc483a4f2e5facb`;
generated compiler C:
`6ed9785282cc928a8f3ac772b31875c822163593e32d64512b935534a89abaa8`.
The repository host remains FRESH, SHA-256
`f6d946861a5a07faa506cb598e0e64d8af0f89289551737b5e0dc42443554a8c`.
Makefile builds use Apple clang 21.0.0, arm64 macOS, `-O0`, memory diagnostics,
`-lm -lpthread`. Build logs retain the normal toolchain provenance.

`build/bidirectional/final-sources.sha256` fingerprints source/tests/docs,
including all 16 callbacks, root's plan and this report; `final/sources.tar`
freezes them. `final/artifacts.sha256` fingerprints compared artifacts. No host
defect was found. The manifest/archive retain the pre-review receipt; the gate
results above and the plan's completed checkbox are the only subsequent
documentation updates. No commit or push was made. Later generic capabilities
remain separate slices.
