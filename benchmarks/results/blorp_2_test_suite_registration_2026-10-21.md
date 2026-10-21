# Blorp 2 constant TestSuite registration

Target `TestSuite` now holds `List[(String, () -> Bool)]`; `run_suite` accepts
the suite value. The existing compiler-owned `--test-suite` entry still calls
ordinary `run_suite(tests)` through normal names, accepted constant templates,
Specialize, ownership and emission. Only local assembly names changed; there is
no new entry representation, retained constant identity or compatibility
factory. Target TestCounts and result printing stay intact. The existing text
suite now exports a constant without changing its assertion.

Baseline is `48bc6aa49338e3a4d39b211edb001602ff050d2b`. Qualified baseline
normal role is `8d28c41693f66a3ffd234fc0c2b43525c2309a0e0e886d18fa33872eaa0fc330`;
diagnostic role is
`81f82c6c5579eba9c53aa27b075e738aa88140bdf38588afc55ececead9ef523`.
The retained registration-red01 source was rejected at 10:14 with the exact List
TestCase mismatch/help. The identical bytes now compile through `--test-suite`,
strict-C11 link and execute the one real callback: exit 0, expected output and
18 balanced runtime allocations/releases.

## Qualification

The owning Check 8, Parse 5 and text 1 callbacks all pass. Check rejection tests
retain singleton ordinary message/help, real root EOF span and absent note;
assembly tests preserve actual issued identity, configured-library authority,
existing aliases and foundation qualification. Old factory forms are not entry
compatibility paths.

The maintained E2e owner adds 5 regressions through existing harness operations:
private pure/impure callbacks, False→True→False order with continued execution
and exit 1, empty success, imported visible suite and ordinary run_suite_result
TestCounts 21. Twelve separate real native runs (strict plus ASan/UBSan for each
of those 5 fixtures and mandatory target text) verify exact output/status;
strict balances are 23/31/14/23/28/30, zero leaks/bytes throughout. Compiler-owned
entries exercise the first 4 cases; TestCounts uses the fixture's ordinary main.

A deliberate first-callback True→False mutation reaches actual native main:
`pure` fails, `effect` still executes/passes, summary 1 of 2 failed and exit 1,
25 balanced allocations/releases. The maintained owner fails exactly 2 of 5 cases
(the direct and imported routes); byte-exact fixture restoration passes all 5.

The full component run passes 3,994 maintained callbacks across 375 suites plus
334 nested runtime callbacks. The extra host text callback is intentional;
mandatory target text still runs separately and passes 1. The temporary observer
is fixed Root `bin/blorp` (16b0dc7e) with 163 explicitly pinned Root host std files;
no legacy rebuild or isolated-worktree Make freshness claim is involved.
One auxiliary wrapper setup failure (host counts are tuples) is retained
separately and gets no executed-oracle credit.

Current-source generation and both fresh normal/diagnostic strict-C11 links
pass. Each freshly linked compiler re-emits the same physical current source;
all 3 archives equal their input C, SHA256
`ba6393c4d54bf8ba9f7afa858ef747e10825b118c63d471905c50f5e2e95f3b9`.
This is also byte-identical to baseline compiler C: assembly alpha renames do not
change emitted C. Both strict generations balance 31,028,464 allocations/releases.
Existing fresh link receipts are reused for the fixpoint proof, avoiding
redundant relinks. Candidate normal SHA256 is
`3f18e330629cd21cea37aa5cbdae60504156d59836189971ec250bf72c799976`;
diagnostic SHA256 is
`4927d17de4749f0ed122f47eb159122a0e36e33fdebdf12653f3c88bf49b660f`.

## Matched full-compiler cost

Baseline and current roles compile the same 57-file frozen 48bc source/library
inventory at identical physical paths, cwd and output. Linking is outside the
measurement. Apple Clang 21/resolved SDK/time pins and causal normal/diagnostic
roles are retained; unmodified C links use strict C11 warnings, `-O0`, `BLORP_MEMORY_DIAGNOSTICS=0`
normal or `=1` diagnostics, `-lm -lpthread`. `/usr/bin/time -l` supplies hardware
retired instructions. Runs are serial; each role has one strict and 3 normal
samples. The predeclared ceilings are +3% allocations and +3% normal minimum.

| Metric | Baseline | Current | Change |
| --- | ---: | ---: | ---: |
| Strict allocations/releases |31,028,494|31,028,494|0%|
| Minimum normal retired instructions |901,231,811,602|901,219,304,491|−0.00139%|

Normal samples are baseline 901276214208/901231811602/901264934657 and
current 901254537740/901219304491/901419149377. All 8 compilations pass, strict
counts balance with zero leaks/bytes, and all outputs equal ba6393c4 above.
Both ceilings pass; no speedup is claimed. This is matched full-compiler input
cost, not an isolated native tuple-registry construction comparison.

The full self-built E2e invocation passes 580 maintained callbacks across 59
suites plus 786 nested native callbacks across 463 suites; the outer ordinary
observer passes its one callback. Printed status lines total 1,367, with zero
failures, no open frames, no timeout and stable guards. All five new registration
callbacks pass. Duration is 389.228 seconds, inner maintained timeout 0 and finite
outer process-group timeout 1,800 seconds. The compiler under test is the exact
fresh diagnostic role above, bound to successful current-source fixpoint/link
proofs; there is no fallback.

Existing CI settings remain `BLORP_2_RESOURCE_POLICY=record-allocation-debt` and
`BLORP_2_INSTRUCTION_CHECK=disabled`. All 117 FAIL allocation metric records are
retained separately in `e2e01/RESOURCE_DEBT.json`, the same count as the preceding
aggregate increment. No resource ceiling is raised, and behavioral/leak/sanitizer
failures still block. Native strict/sanitizer and matched normal instruction
proofs above are separate gates.

Source/library production is 11 added/17 removed (net −6); tests 123 added/30 removed;
README/library docs, AGENTS and Make comments 27 added/14 removed. This report is
counted separately. No public compiler datatype, callback/factory adapter,
registry, cache, hidden fallback or legacy compiler change is added.
Other utility-suite migrations and test-self-hosting completion remain separate.

Raw evidence and exact commands, input/member/Git/toolchain/role pins,
streams/durations and outputs are retained in the isolated worktree's ignored
`build/test-suite-registration/execution/`. `BUILD_ROLES.json`, `FIXPOINT.json`,
`NATIVE_RESULTS.json`, `MUTATION_RESULTS.json`, `components01/`,
`MATCHED_COST.json` and `e2e01/` identify the owning boundaries. Production/tests
were independently reviewed by code and test/protocol reviewers.
