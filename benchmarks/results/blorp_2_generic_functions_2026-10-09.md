# Blorp 2 generic functions: checked once, specialized before lowering

One declared function type parameter now works with argument-driven direct
calls, UFCS and generic forwarding. Every body is checked once with a rigid,
declaration-owned parameter, including unused bodies. Expected return types
do not infer substitutions. Generic main/prelude declarations, type-name
collisions and uninferable calls have exact-span diagnostics and help.

`specialize` publishes a sealed concrete program before lowering. Function,
union and variant instance identities are distinct from checked declaration
identities. Ordinary functions/unions remain emitted; generic instances expand
from those roots and reuse declaration/type keys. Complete translated binding
tables remain instance-qualified, and no downstream reader uses the checked
declaration as a fallback. Checked and concrete signatures are separate phase
authorities. Runtime call variants cannot carry generic substitutions.

Generic unions are the next separately reviewed slice. Managed union payloads,
multiple parameters, explicit function type arguments, recursion and managed
tail-match prefixes remain outside this increment. The host compiler and
target String runtime are unchanged.

## Provenance and comparison

The frozen baseline is the exact uncommitted post-tail tree atop
`bb0b28d1edbd3ff5d3f010b25eec24cd815a9a4c`, not HEAD alone. Its source archive,
dirty patch, host/pilot fingerprints and all samples are retained under
`blorp_2/build/generics/baseline/`. This same baseline remains the overall
generics baseline for the subsequent union slice.

Host `bin/blorp` was FRESH throughout, SHA-256
`f6d946861a5a07faa506cb598e0e64d8af0f89289551737b5e0dc42443554a8c`.
Baseline pilot SHA-256:
`a470cffab70ad57d94866b7ad69c5a0bb7c7ae5fd86136bbbb5b4d5914e5ec1b`.
Function candidate pilot SHA-256:
`a5ebd774404e58cdbc9e7e8e3349808b063a98b82233ca881edb8bb8b62d10f1`.
Apple clang 21.0.0 (`clang-2100.3.34.2`), arm64 Darwin, links the pilot at
`-O0 -DBLORP_MEMORY_DIAGNOSTICS=1 -lm -lpthread`. The same host binary and
unchanged source workloads produced both measurements. Source/test fingerprints
before and after the full gate are identical.

Three serialized samples per input/version use `/usr/bin/time -l` and
`env -u BLORP_MEMORY_STATS BLORP_LEAK_CHECK=strict`, invoking the frozen
executable with the explicit prelude, source and fresh C output path. The table
reports deterministic allocations and minimum retired instructions from the
three samples; all raw samples are in `costs.json` and the version directories.

| Unchanged input | Baseline allocations | Candidate allocations | Baseline instructions | Candidate instructions | C identity |
| --- | ---: | ---: | ---: | ---: | --- |
| return_zero | 624 | 652 (+4.49%) | 30,422,601 | 30,488,029 (+0.22%) | exact |
| mortal_string | 920 | 975 (+5.98%) | 31,254,472 | 31,449,028 (+0.62%) | exact |
| match_string_first | 1,788 | 1,921 (+7.44%) | 33,696,362 | 34,048,576 (+1.05%) | exact |
| match_many_arms | 66,760 | 71,464 (+7.05%) | 313,151,365 | 323,088,350 (+3.17%) | exact |

All twelve candidate C files are byte-identical to corresponding baseline
files. Every compilation has zero leaked allocations/bytes and empty stdout.
No metric reaches the 25% investigation threshold, and no existing e2e ceiling
changed. These are owned-input compilation proxies; the pilot cannot compile
itself, so they are not self-compilation or host-compiler performance claims.

## Behavior and gates

The initial two pipeline tests failed at the intended `[` lexical diagnostic,
not at an import/module error; see `failing-before-tests.log` and
`failing-before.stderr.txt`. With implementation restored after both mutations:

```sh
scripts/compiler-build-status
bin/blorp test --timeout 180 blorp_2/test/unit
make -C blorp_2 test
git diff --check
```

The full pilot gate passes 349 unit callbacks, 9 runtime C cases, 72 e2e cases,
61 grammar cases and two wrappers: 493 total. Its e2e entrypoint builds the
pilot once, compiles each fixture once, builds unmodified C at `-O0` with strict
C11 warnings and UBSan, and invokes each fixture's real main. All 56 measured
fixture reports stay within their caps. New generic examples retain the
20,000-allocation / 200,000,000-instruction ceilings:

| Fixture | Allocations | Instructions in full gate | Native exit |
| --- | ---: | ---: | ---: |
| generic_identity | 1,880 | 34,602,914 | 1 |
| generic_forward | 1,444 | 33,733,676 | 42 |
| generic_forward_string | 2,184 | 35,650,585 | 1 |
| generic_bindings | 2,049 | 35,197,965 | 2 |

All native outputs are empty. Separate retained inspection builds under
`candidate/native/` use the same real main and strict C11/O0/UBSan flags.
String forwarding retains the borrowed parameter in the identity instance,
transfers the call's owner through the forwarding instance, and establishes
the caller's result owner before releasing its earlier argument obligation.
The unchanged 256-arm fixture still has maximum brace depth 3.

Direct tests cover caller-owned symbolic substitutions, same-key reuse,
distinct declarations/types/nominal unions, complete binding/reassignment and
match-arm substitution, entrypoint remapping, and unused ordinary roots.
Granular Int/String lowering, ownership insertion, independent hand-written
verifier inputs and emission checks assert exact values/obligations.

Deliberately ignoring argument equality in instance keys fails three named
specialization tests: distinct argument instances, per-instance binding types
and distinct nominal union arguments. Deliberately deleting String-return
acquisition fails the exact borrowed-return ownership test and the specialized
emission test. Both mutations are restored; logs/status are retained in
`mutation-instance-key.*` and `mutation-string-return.*`. Existing malformed
ownership and match tests remain green with their rejection oracles intact.

## Size and review boundary

Against the frozen post-tail source archive, affected handwritten production
files are 7,151 → 8,319 physical lines (net +1,168), or 6,051 → 7,019 excluding
blank and `--`/`//` comment lines (net +968). Affected test/fixture files are
9,031 → 10,521 physical lines (net +1,490), or 8,236 → 9,524 nonblank/noncomment
lines (net +1,288). Documentation is separate. `loc.json` lists the exact files.
Most production growth is the 804-line concrete product and translation pass;
the remaining growth adds rigid checking and bounded parser rules. No generic
IR framework, persistent cache, additional runtime mechanism or coverage
deletion was introduced.

Raw evidence is under `blorp_2/build/generics/`, especially `full-gate.log`,
`candidate-hashes.txt`, matching input fingerprints, `costs.json`, `loc.json`,
`native-results.json`, frozen baseline and candidate artifacts. The approved
design map is `design.md`. This record describes worker validation; final
independent review found no production correctness issues and requested one
additional match-discovery regression. The independent runner passed all 349
unit callbacks under strict ASan/UBSan and leak checking, and verified reuse of
the frozen 493-report full gate from matching production/test fingerprints.

## Test-only review addendum

The added specialization callback gives each match position a distinct generic
request: `identity[Flag]` in the scrutinee, `save[Int]` in an arm assignment,
and repeated `identity[Int]` calls in the other arm body. It asserts concrete
call targets, same-key reuse and the translated saved binding type. Three
separate deliberate mutations omit discovery only in the scrutinee, only in
arm assignments or only in arm bodies. Each fails this callback alone (1/10).
After restoration, all ten specialization callbacks pass strict ASan/UBSan
and leak checking with zero leaked allocations/bytes and no source changes
during execution. The packet is `match-discovery-refined-sanitized/`; mutation
logs/status are `mutation-match-{scrutinee,assignment,arm-body}.*`.

Only `test/unit/test_specialize.brp` differs from the original full-gate input
manifest: +63 physical lines and +59 nonblank/noncomment lines. Production
inputs and host/pilot binaries match that snapshot exactly. The current unit
inventory is 350 callbacks; the old full gate ran 349, and the additional
callback is covered by the focused ten-callback sanitized rerun. The 493-report
full gate was not repeated for this test-only change. Current fingerprints,
the updated source/test archive and exact count summary are under
`function-addendum/`; the original full-gate archive and fingerprints remain
unchanged. Final acceptance of this addendum precedes generic-union edits.
