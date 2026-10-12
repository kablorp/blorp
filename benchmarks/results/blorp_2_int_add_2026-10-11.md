# Blorp 2 target library and Int addition

Baseline: `7cb72f355a82474c386cb95f524f6fe98612624d`, branch `blorp-2`.
The [design](../../blorp_2/INT_ADD_PLAN.md) owns phase contracts and the
predeclared cost bounds. This completes step 2 of the
[calculator roadmap](../../blorp_2/CALCULATOR_PLAN.md).

## Result and boundaries

An explicit `--library-root DIRECTORY` enables selective bare imports such as
`int: add`. Relative paths still resolve beside their importer. Both paths use
the same normalized module inventory, namespace facts, declaration identities
and checking pipeline. Missing roots never select a local or host-library file.

The temporary target library retains a commented copy of upstream `int.brp`;
only concrete `pure func add(a: Int, b: Int) -> Int` is active. Its explicit
`builtin("int.add")` body selects a closed, typed compiler operation. Parsing
establishes that distinction once. Checking validates the exact concrete ABI
before caller bodies and elaborates the declaration into an ordinary checked
runtime call. Consumers retain the ordinary function identity. Runtime
contracts now own ordered parameter lists, including existing unary operations.
Ownership and verification require no new production representation or pass.

The conditional C helper performs unsigned modular addition and reconstructs
the signed result using representable conversions and signed arithmetic.
Library origin grants no semantic trust, and arbitrary C symbols remain
unavailable. Traits, operators, String literals, IO and Float are later work.

## Tests and independent review

The frozen baseline rejects the first library import at line 2 with
`expected an explicit relative import path`. The direct builtin-body acceptance
regression also failed before implementation: `build/int-add/phase-red/` under
`blorp_2/`, one failing callback without compilation errors.

Final commands, each wrapped by `scripts/record-validation --output DIR --`:

```sh
bin/blorp test --suite --timeout 180 --sanitize --leak-check \
  blorp_2/test/unit blorp_2/test/runtime \
  blorp_2/test/test_grammar blorp_2/test/tooling
bin/blorp test --suite --timeout 0 blorp_2/test/e2e
```

The first passed **1,173 callbacks across 75 suites**, including 34 builtin
declaration callbacks, in **14.816 seconds**. Sanitizers and strict leak checking
passed; stderr contains only the balanced harness allocation summary. The
second passed **168/168 e2e cases**, plus its orchestration callback, in
**76.414 seconds**, with empty stderr. The pilot is built once at the start of
the e2e run; pilot and native fixture builds use `-O0`. Fixture C runs unchanged
through the normal main with ASan/UBSan.

Receipts: `blorp_2/build/int-add/independent-tests/strict-final/` and
`end-to-end-final/`. Both record unchanged source fingerprint
`e073e22877faa9ebae114fd9ce329d4fadcf43826a9b2f282c38540ea8dccad1`.
Subsequent tracked edits only update this report and roadmap/README prose.

Tests cover typed import origins and grammar, explicit roots and absence of
fallback, library-relative imports and deduplication, contextual builtin syntax,
exact purity/arity/ordered type contracts, actual parameter and declaration
identities, invalid declarations before caller checking, concrete binary
signatures, malformed ownership call rejection, conditional helper emission,
and ordinary functions named `builtin`. Managed unary builtin cases pin borrowed
parameters, fresh owned String result transfer, caller cleanup and independent
verification. The eight native fixtures cover direct calls, UFCS, nested calls,
negative values, cancellation and both signed-limit wrap directions. Three CLI
cases protect omitted roots and incomplete flags.

A deliberate `+` to `-` mutation of the helper makes the native add regression
fail its expected exit 42 through the existing Blorp TestSuite harness. Receipt:
`blorp_2/build/int-add/mutation-oracle-native/`. The emitter was restored
byte-for-byte before final native validation, SHA256
`1edec9db1f74261aba1a61c53671488d9d345dedf80a8e37bf784a541df5de05`.
The earlier `mutation-oracle/` packet failed to compile its scratch test and is
not a behavioral oracle.

Boundary fixtures observe signed decimal length using existing `to_string` and
`length`, avoiding reliance solely on a truncated process status. They distinguish
the tested wrap directions and run under UBSan, but do not compare every decimal
digit. An exact full-width native value oracle awaits String comparison or IO.

Independent compiler-expert implementation, code/test review and test-runner
validation found no remaining implementation or test blockers. Final review
includes the matched costs and explicit comparison/size limitations below.

## Matched costs and ceiling changes

The same fresh repository host built both pilot executables. Apple Clang 21,
arm64 macOS; generated pilot executables use `-O0` and allocation diagnostics.
The host CLI/runtime build settings are `-O0`/`-O2`.

The frozen workload is 134 existing fixture roots plus 5 valid local-module
roots, with their dependencies and prelude retained. Three serial paired samples
alternate compiler order. Both executables receive identical frozen inputs via
the existing three-path CLI, without the new optional root flag. The boundary is
the whole pilot process through C emission under strict leak diagnostics and
`/usr/bin/time -l`; it excludes pilot building, target C compilation and native
execution. This remains an owned-input proxy; self-compilation is unsupported.

| Sum over 417 compilations per compiler | Baseline | Candidate | Change | Hard ceiling |
| --- | ---: | ---: | ---: | ---: |
| Allocations | 1,523,079 | 1,527,291 | +0.28% | +10% |
| Retired instructions | 16,738,880,581 | 16,716,791,802 | -0.13% | +10% |

Instructions are effectively flat; this is not an improvement claim. All **139
generated C outputs are byte-identical** in every pair, and all compiler samples
report balanced releases and zero leaks. `build/int-add/` under `blorp_2/`
retains `measure.sh`, `costs.tsv`, per-sample C/counters under `samples/`, frozen
inputs under `baseline/` and the `matched-costs/` recorder packet.

The e2e harness explicitly supplies the target-library root for all fixtures.
On the same return-zero input, adding that optional configuration costs 31
allocations (792 without, 823 with), with identical C. Raw evidence is retained
as `with-root.*` and `without-root.*` below the same artifact root. These counts
use different input paths from the frozen matched proxy and are not mixed into
its aggregate comparison.

The first integrated e2e run passed 166/168 cases; only two older allocation
ceilings failed. Instruction limits, sanitizer checks and all 11 new cases
passed. Two more cases had effectively no allocation headroom. Deliberate
ceiling adjustments, followed by the complete green rerun:

| Existing case | Observed allocations | Old ceiling | New ceiling |
| --- | ---: | ---: | ---: |
| return/zero | 823 | 800 | 900 |
| return/42 | 826 | 800 | 900 |
| nested/calls | 1,500 | 1,500 | 1,600 |
| ufcs/calls | 1,499 | 1,500 | 1,600 |

Receipt: `independent-tests/end-to-end-fixed/` under the artifact root. The eight
new native fixtures observed 16,444–16,804 allocations and 67.5–68.5 million
instructions in the final run; their ceilings are 22,000 and 150 million.
These costs include reading the retained commented target library. Existing
instruction ceilings are unchanged.

## Provenance and size

| Frozen artifact under `blorp_2/build/int-add/` | SHA256 |
| --- | --- |
| `baseline/compiler` | `e8e10c564bee320d449b4b1309a61df9a8ec67259c993e9d224e2bd1e2742e84` |
| `baseline/compiler.c` | `19edfc6c5e732df3e4873d5d5e0e04592b8c1e07b4f4436176edf0257b07ea46` |
| `baseline/inputs.tar` | `12be9bca43661ebb011e339372f4106710e3b74e02324d2adb74e83f0565a495` |
| `baseline/fixtures.txt` | `492f92057f034d97a4e603a9418b4f4219d2c6912d894804beaba2c7e20d62a3` |
| `candidate/compiler` | `615e8ab7cb3095216a91f7077355659e169ec2497bc2b89dc4f5fae266442dd9` |
| `candidate/compiler.c` | `d6f9b7dea00f4e1b2c638ef902c18965ae98ed05fb3c7cbdb8e31ff8385b94f6` |
| `candidate/production.tar` | `bdcc4446166b70f86601238aaa99c2cd819450a0b93479c334a700e41031bc52` |
| `candidate/tests.tar` | `2522315284e9c6d0ed41a84d2280fb4e690d418b34e2bc0d954d06e7d503dd7f` |

Repository host `bin/blorp` is FRESH, SHA256
`4dd4a29a428d7fa8ecd40068f043d8a7ee910df0c6272ba3062c97dfebf938ec`.
Final e2e rebuilt the pilot once, producing executable SHA256
`c1253956de058b278bb813313fac0ac0c45e971f7052c83cf999f7dd86707c08`.
Its C matches the frozen measured candidate exactly. Raw Mach-O comparisons in
`independent-tests/end-to-end-final/binary-provenance/` establish that every
native binary difference is confined to UUID and code-signature bytes; machine
code matches. Measurements keep their own frozen executable.

Physical lines include comments and blanks; tracked deltas come from
`git diff --numstat 7cb72f355`, and new files from `wc -l`:

| Owner | Net physical lines |
| --- | ---: |
| Compiler implementation (`src/`) | +219 |
| Comparison tool | +2 |
| Requested retained target-library copy | +683 |
| All production above | **+904** |
| Tests/helpers, excluding fixture inputs | +1,532 |
| Fixture inputs | +40 |

The 700-production-line aim was missed by 204 physical lines. The 683-line
library file retains the 672-line upstream source with provenance and only
three active function lines; the requested retained copy accounts for the bulk
of growth. This is feature growth, with no line-reduction claim. The compiler
adds no new production module or ownership representation. Copied declarations
stay commented until their own supported increment.

## Existing-compiler comparison limit

The comparator now passes the explicit target-library root, records it in
provenance and snapshots the temporary library. All seven tooling callbacks
pass. A real unchanged `return/42.brp` smoke succeeds in both compilers;
`independent-tests/comparator-return42/` and `comparison-return42/` retain the
commands, source identities and results. One sample establishes tool operation,
not a performance ratio claim.

The new unchanged `int/add.brp` fixture is not yet a common workload: the
existing compiler reports `Unbound value add`. Upstream `int.brp` declares `add`
inside `implements Addable`, whereas this approved subset lifts it to a concrete
top-level function. The pilot compiles the fixture successfully. The tool
correctly marks the pair incomplete and publishes no paired ratio; evidence is
in `independent-tests/comparator-add/` and `comparison-add/`. No fixture rewrite,
alternate entrypoint or host-library shim was added.

The previously recorded comparator executable-root inventory and dependency
fingerprinting limitations remain separate follow-ups. They do not affect the
explicit frozen manifest used for the 139-input baseline/candidate comparison.
