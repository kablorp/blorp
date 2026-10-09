# Blorp 2 scalar bindings and ordered values

Status: implementation, matched measurements and integration validation pass.
Branch `blorp-2`, baseline HEAD
`afe38d0465a353146423dab8140feeef0e4134b8`.

The measurements and 224-test validation below retain the initial implementation
snapshot. The user subsequently requested replacing the C assertion drivers
with ordinary source fixtures. The completed [test cleanup](#source-fixture-test-cleanup)
passed 248 tests in each mode. Earlier native-driver observations are retained
as history and are not coverage claims for the simplified tests.

The subsequent [e2e orchestration correction](#e2e-orchestration-correction)
removes the persistent compiler cache and repeated fixture compilations.
The earlier cache and `-O2` measurements below are retained historical evidence.

## Scope and hypothesis

Add immutable local bindings and explicit `var` reassignment before a mandatory
final expression or tail match. Establish function-owned binding identities,
typed expression occurrences, and a pure ordered-value lowering boundary before
introducing managed values. Aliases retain their computed value; reassignment
updates the binding-to-value map after evaluating its RHS. Emission consumes
one sealed lowered program and projects immutable C locals.

For `original = 1; var current = original; current = identity(42); original`,
lowering defines constant 1, constant 42, and the call result, then returns the
first value. No runtime mutable cell or target allocation is introduced.
Branch computations stay inside their selected match arms.

[BINDINGS_PLAN.md](../../blorp_2/BINDINGS_PLAN.md) records scope, contracts,
tests and ceilings set before implementation: each frozen old input at most
+100% allocations and +10% minimum retired instructions; new bindings fixture
at most 10,000 allocations/100M instructions; formatted production at most 5,500
lines. Managed layouts, ownership insertion, ARC/COW, destructors and verifier
implementation remain future work. Interning and cycle-check optimizations
are separate slices.

## Matched compiler-process costs

These are owned-input compilation proxies, not pilot self-compilation. Both
versions compile the identical frozen pre-binding fixture path. One strict
diagnostic process measures allocations/releases; three normal processes
measure retired instructions, using their minimum. Startup and I/O are
included. Building the pilot, Clang and native execution are outside the
measurement. Baseline and candidate run serially. No speedup is claimed.

| Frozen input | Allocations before / after | Instructions before / after | Instruction change |
| --- | ---: | ---: | ---: |
| return_zero |134 /160 |18,928,403 /18,991,357 |+0.333% |
| call_one |254 /307 |19,094,854 /19,125,668 |+0.161% |
| pure_calls |400 /480 |19,231,163 /19,333,089 |+0.530% |
| nested_calls |467 /574 |19,306,365 /19,469,830 |+0.847% |
| nested_order |516 /662 |19,323,637 /19,520,595 |+1.019% |
| ufcs_calls |469 /576 |19,372,546 /19,508,421 |+0.701% |
| ufcs_chain |520 /665 |19,361,773 /19,596,668 |+1.213% |
| return_42 |137 /163 |18,979,846 /19,049,734 |+0.368% |
| union_values |1072 /1290 |19,936,890 /20,152,035 |+1.079% |
| match_value |753 /902 |19,647,729 /19,751,322 |+0.527% |

All ten relative budgets pass. Maximum allocation growth is 28.295%
(`nested_order`); maximum instruction growth is 1.213% (`ufcs_chain`). All 20
native baseline/candidate programs pass strict C11/O2 compilation and expected
exit/silent-stream checks. Each diagnostic run has balanced releases and zero
leaks. Within each compiler version, diagnostic and all normal runs emit
identical fresh C. Baseline/candidate C intentionally differs because lowering
materializes operations as ordered value definitions.

All raw retired-instruction samples, in execution order:

| Input | Baseline samples | Candidate samples |
| --- | --- | --- |
| return_zero |18942338,19020499,18928403 |18991357,19065607,19085257 |
| call_one |19144395,19094854,19141174 |19227797,19125668,19196226 |
| pure_calls |19273472,19231163,19299642 |19359129,19333089,19405293 |
| nested_calls |19388546,19306365,19324308 |19469830,19520335,19528580 |
| nested_order |19438830,19323637,19370059 |19530650,19520595,19553656 |
| ufcs_calls |19402590,19422833,19372546 |19613911,19508421,19526797 |
| ufcs_chain |19394201,19383152,19361773 |19676958,19606288,19596668 |
| return_42 |19163960,18979846,19001935 |19089539,19049734,19063655 |
| union_values |20009944,20011902,19936890 |20196051,20152035,20169391 |
| match_value |19817136,19647729,19657314 |19788297,19777496,19751322 |

## Maintained fixtures and deliberate ceilings

The user requested standalone companion entrypoints that exercise their
helpers. `binding_values.main` now calls its 11 case functions, covering the
remaining helpers transitively, and returns the preserved original 1.
`union_values.main` calls all five helpers and matches the receiver result,
returning 0. Independent C drivers still assert every full Int64/union result;
an exit code alone cannot establish those values.

The expanded maintained union input differs from the frozen matched input.
Its separate measurement is 2,082 allocations/releases, zero leaks, and
20,989,028 instructions (samples 21,118,473 /20,989,028 /21,120,274). Do not use
it as the candidate half of the old-input comparison. The new `bindings`
example measures 824 allocations and 19,917,821 instructions in the entrypoint
check (samples 20,471,229 /19,917,821 /19,934,602).

Reviewed allocation ceilings are now zero 200, call 350, pure 550, nested 650,
order 750, UFCS 650, chain 750, return_42 230, expanded union 2,500, match 5,000,
bindings 10,000. Instruction ceilings remain unchanged. Seven original allocation
caps would fail the frozen candidate; return-zero exactly met its old 160 cap.
The adjusted caps give explicit headroom rather than changing automatically.

## Implementation validation before test cleanup

- Before implementation, all seven initial binding checker regressions failed.
- Direct parser-token tests check binding prefix shape, initializer placement,
  mandatory tails and exact diagnostics. Lexer tests check whole-word `var`.
- Checker cases inspect function-owned definitions and read identities, origins,
  mutability, type/span facts, initializer scope, type-preserving reassignment,
  pure mutation, unused impure/cyclic initializers, and direct-call versus UFCS
  shadowing.
- Lowerer tests directly inspect ordered definitions, old aliases,
  self-assignment, unused-call order, parameter initialization, function-wide
  branch identities, and intermediate Int/union types and spans. No C emitter
  or CLI participates in these assertions.
- Deliberately corrupting the binding map fails four of six lowerer tests,
  including the old-alias oracle. Reversing assignments fails four of six,
  including the order oracle. The first order fixture was palindromic; it was
  strengthened before claiming mutation detection. Original source was restored.
- Native ASan/UBSan binding drivers check full-width endpoints, aliases,
  self-assignment, shadowing, union reassignment, unused initializer execution,
  and call order/counts. Unchanged assertions reject deliberately wrong aliases
  and omitted initializers. The CLI test pins exact immutable-assignment
  location/message/help and requires absent/existing outputs to be preserved.
- Existing golden C and native collapse/endpoint injections were updated to
  target immutable definitions. Full-value native assertions remain independent.

Final independent validation passed:

| Gate | Result |
| --- | --- |
| Normal `make -C blorp_2 test` |224/224 callbacks in 24 suites |
| Full UBSan/leak run on unit/e2e/grammar roots |224/224 callbacks in 24 suites |
| Frozen matched compilation proxy |10/10 pairs |
| Formatting |36/36 files |
| Diff and whole-file whitespace checks |Pass |
| Host freshness and warm compiler cache reuse |FRESH; zero generations/links |

The final suites contain 149 unit, 31 e2e and 44 grammar callbacks. Native binding
drivers run ASan/UBSan; other retained native checks include UBSan.
UBSan instrumentation applies to the host-built TestSuite executables and
selected native drivers. The cached pilot compiler children retain their
recorded normal/diagnostic `-O2` builds without native UBSan instrumentation.
The normal and strict diagnostic compiler modes are separate from those
sanitizer-instrumented executables. Compiler
diagnostic runs on `bindings`, `binding_values` and expanded `union_values`
report 824, 7,838 and 2,082 allocations respectively, with exactly matching
releases and zero leaks. Their diagnostic and normal C outputs are identical.

The first full normal attempt passed 221/224: three older call-one structural
assertions still expected pre-lowering C. Their expected immutable definitions
were corrected without changing production code or native assertions; the
focused suite then passed 4/4 and both full final gates passed 224/224.

Including untracked additions, physical production lines grew 3,786→4,540
(+754), test/support lines 6,691→7,822 (+1,131), and raw fixture lines 121→218
(+97). Production remains below the predeclared 5,500-line ceiling. These are
feature-growth counts, not a claim of source reduction or improved efficiency.

Final independent logs, source/cache fingerprints, per-file LOC and retained
emitted C are under `blorp_2/build/bindings-independent-YOL7c1/`:
`normal-final.log`, `sanitize.log`, `warm-final.log` and the runner report.
All 57 frozen validation input hashes remained unchanged during those gates;
manifest SHA256
`0e60976c77cb5576c476f9bd42410d15fcd57712f901e773af7ce26a2e2629d6`.
Host/cache SHA and mtime/ctime/size/inode remained unchanged; warm setup log
is empty. The final doc-only status update occurred after executable validation.

## Provenance and reproduction

Apple clang 21.0.0, arm64 macOS. Pilot modes use the same generated C with
`-O2 -DBLORP_MEMORY_DIAGNOSTICS=0/1 -lm -lpthread`. The unchanged host is FRESH
(CLI-O0/runtime-O2), SHA256
`c67d5bb315a67999ec5d608eaa41aab83f8d75e6220b44b936ea2a4849b7ba0a`.

| Artifact | SHA256 |
| --- | --- |
| Baseline normal |070b88da7841797cb24a7cf9cb448a59eb25603ec980bd7a668687cdc552ac4d |
| Baseline diagnostic |fbead65059ed3315e4a74bdbf5f7759766b492cdf73ff875d606b8ca44140c26 |
| Candidate normal |0f4300c7cf7fde171929b74b49f914c2c3e4106e2cd0784cfb7bb132f103d917 |
| Candidate diagnostic |2a3d8ccc363250657f4510f0e6647232cc86b402c6f5927b825819ebb284572a |
| Candidate generated compiler C |8d41680633365dbd174258db270371fde0a6ba0b2e6813f0909b57b7c79112f9 |
| Candidate cache input manifest |b395a5d2b743cac6611c54bb7fed552634fb3f027cedc79b1e8b7b5e18601f2c |

Ignored retained evidence lives under `blorp_2/build/`: frozen baseline source,
fixtures, host and compiler modes in `bindings-baseline/`; matched TestSuite,
helper copies, 60 raw samples, generated artifacts and complete manifests in
`bindings-cost-validation/first-matched/`; original red, mutation and direct
green logs named `bindings-*.log`. Warm cache setup generated and linked nothing;
host/cache SHA, mtime/ctime/size/inode were unchanged during the matched gate.
One initial ignored-probe invocation failed before callbacks because it lacked
process stdout/stderr imports; only that probe import was corrected.

```sh
scripts/compiler-build-status
bin/blorp test --suite --timeout 180 blorp_2/test/unit
make -C blorp_2 test
bin/blorp test --suite --sanitize=undefined --leak-check --timeout 180 \
  blorp_2/test/unit blorp_2/test/e2e blorp_2/test/test_grammar
bin/blorp test --suite --timeout 180 \
  blorp_2/build/bindings-cost-validation/test_cost_pairs.brp
```

Host compiler sources are unchanged. Broad legacy compiler gates and the
separate opaque-append fix are outside this pilot slice; their previously
reported aggregate host sanitizer limitation is not presented as passed here.

## Source-fixture test cleanup

The user requested simpler end-to-end execution and an explicit approval rule
for additional complexity or implicit behavior. A subagent removed C assertion
drivers, entrypoint-renaming macros, generated-symbol calls, emitted-C fault
injection and runtime stress-source generation from the binding, union,
integer and match suites. Production, grammar and Makefile sources did not
change during this cleanup.

The shared `run_source_example` helper takes the fixture path, expected exit
status and cost limits explicitly. It runs the cached pilot on that source,
freezes the emitted bytes for diagnostic/normal identity checks, reuses the
existing strict diagnostic plus three-sample cost measurement, compiles the
unmodified C with UBSan, and runs the fixture's real `main`. Tests require the
expected exit status and empty stdout/stderr. There is no alternate assertion
program, target import support, new test framework, or new compiler cache.

Primary examples retain their ceilings. Small companion fixtures use explicit
10,000-allocation/100M-instruction limits; the two structural stress inputs use
100,000/500M. The largest small companion measured 1,294 allocations and about
20.3M instructions. The checked-in 256-arm match measured 53,161 allocations
and about 94.1M instructions, emitted all 256 cases with brace depth 3, and
returned 42 through its normal entrypoint. The 32-pair constructor/call spine
measured 4,400 allocations and about 23.6M instructions, returning 42. Exact
samples and release counts are retained in the independent gate logs.

Observable source cases cover original/current aliases, self-assignment,
parameter shadowing, pure mutation, union replacement, capture shadowing,
distinct nullary variants, direct/receiver calls, payload preservation,
whole-value/wildcard matches and sibling capture scope. Exact CLI diagnostics
and absent/existing-output preservation checks remain. Two direct lowerer
tests additionally assert full-width alias preservation and branch-local calls.

Native full-width equality, effect counters and C fault-injection observations
were removed. The minimum/maximum fixtures are native UBSan smoke tests;
process exit status exposes only the platform's low byte. Exact Int64 facts
remain phase-test assertions. Likewise, direct lowerer tests establish ordered
definitions and branch-local calls; the current source language cannot expose
native effect counts. This cleanup does not claim those native measurements.
The complete prior-observation mapping is retained in
`blorp_2/build/source-fixture-cleanup/coverage.md`.

The new [AGENTS rule](../../blorp_2/AGENTS.md#get-approval-before-adding-mechanisms-or-implicit-behavior)
requires explicit approval for mechanisms beyond the agreed design: additional
frameworks/layers/caches/controllers, alternate test execution, hidden inputs,
fallback repair and inferred conventions. It requires a concrete need, simpler
option, scope, cost and validation. Existing explicit authorization, ordinary
helpers and direct tests within the approved design do not require repeated
approval. The default end-to-end path is stated in the same file. README and
the binding/memory plans now follow that contract.

| Final cleanup gate | Result |
| --- | --- |
| Normal full unit/e2e/grammar run |248/248 callbacks in24 suites |
| Full UBSan/leak run |248/248 callbacks in24 suites |
| Callback ownership |151 unit /53 e2e /44 grammar |
| Formatting |36/36 files |
| Wrapper/injection and fixture-import scans |Clear |
| Diff and whole-file whitespace checks |Pass |
| Host freshness and unchanged warm cache |FRESH; zero generations/links |

All native fixture binaries use unmodified C with UBSan in both runs. The
sanitizer command also instruments the host-built TestSuite executables;
cached pilot normal/diagnostic children remain their unchanged recorded `-O2`
builds. Diagnostic children require balanced releases and zero leaks. The
host test teardown reports 3 allocations/3 releases/zero leaks/zero bytes.

| Physical lines | Before cleanup | After cleanup | Change |
| --- | ---: | ---: | ---: |
| Production |4540 |4540 |0 |
| Unit tests |3871 |3982 |+111 |
| E2e test mechanism |2045 |1770 |-275 |
| Grammar tests |1906 |1906 |0 |
| Source fixtures |218 |859 |+641 |
| All test/support/fixture lines |8040 |8517 |+477 |

The 517-line static large-match input accounts for most fixture growth. The
cleanup reduces execution machinery, not total test lines; explicit source
examples and phase coverage increase the latter. No production or performance
gain is claimed. All ten production module hashes and the cached host/C/binary
fingerprints match the preceding implementation validation, so the frozen
matched compiler-process costs remain reusable and were not rerun.

Independent evidence is under
`blorp_2/build/driver-cleanup-validation/final-yN48g9/`, mirrored at
`/tmp/blorp-2-driver-cleanup.yN48g9/`. Its `report.md`, normal/sanitizer logs,
line inventories and SHA/stat manifests retain the final results. Of 82 frozen
inputs, 80 stayed identical; README and BINDINGS_PLAN had the announced
doc-only review corrections. Host/cache SHA, mtime/ctime/size/inode stayed
unchanged, and setup/warm logs are empty. No broader host compiler gate was
added during this cleanup.

## E2e orchestration correction

The default `bin/blorp test blorp_2/test/e2e` command reproduced the user's
30-second timeout (31.00 seconds wall). Persistent compiler reuse was unnecessary:
even a cache-hit Make invocation cost 0.62 seconds and preparation ran repeatedly
inside fixtures. Removing that cache and building once still took 43.20–46.89
seconds with the old repeated cost measurements; the diagnostic timeout override
used to measure this was not accepted as a fix.

Temporary stage timing, restored byte-for-byte afterward, measured:

| Stage | Calls | Seconds |
| --- | ---: | ---: |
| Generate/link both old `-O2` pilot modes | 1 build | 9.211 |
| Allocation measurements | 39 | 3.237 |
| Instruction measurements | 117 | 7.359 |
| Initial compilations and rejected inputs | 62 | 5.167 |
| Native C compilation with UBSan | 39 | 4.339 |
| Native execution | 39 | 8.742 |
| Temporary directory shell commands | 47 | 3.671 |

There were 186 successful fixture compilations and 32 rejection invocations.
Direct components were 0.66 seconds for source-to-C, 4.61 for the normal link,
and 4.02 for the diagnostic link. A Blorp probe running `/usr/bin/true` 100
times measured 6.669 seconds in `process.run`; a direct process-launch comparison
measured 0.17 seconds. Representative generated programs took 0.18–0.19 seconds
on first execution and rounded to 0.00 on repeated execution of the same binary.
These are wall times with process/startup overhead, not function-body timings.
The host runtime's polling behavior is a separate follow-up; it was not changed.

The replacement uses one explicit build at the beginning of the sole e2e entry
suite, one executable path passed to all groups, one measured compilation per
valid fixture, and existing scoped filesystem APIs instead of directory utility
subprocesses. Per user direction, both pilot and native fixture C use `-O0`.
Native UBSan and strict compiler allocation/leak checks remain enabled. The
instruction counter now includes allocation diagnostics; it is not comparable
to the old minimum of three uninstrumented `-O2` samples.

The first single-pass `-O0` run finished in 25.66 seconds and ran all 53 cases;
50 passed, with three old instruction ceilings failing: return_zero 30,858,861
over 22M, call_one 29,446,044 over 26M, and return_42 28,938,137 over 26M.
All allocation ceilings, native outcomes and diagnostics passed. The small
fixtures' instruction ceilings are deliberately rebased to 40M, including the
previously 32M pure_calls ceiling, with other instruction/allocation ceilings
unchanged. This is a measurement-basis change, not evidence of a compiler
performance regression or gain.

Raw timing and failure evidence: `build/e2e-timing/` under the repository root;
the original timeout and cache-hit measurement are in `blorp_2/build/e2e-timing/`.
The implementer's final default command passed 53/53 cases and all 39 cost
checks in 26.71 seconds, with one C generation and one link. All 39 allocation
counts and allocation ceilings match the prior diagnostic mode exactly.
The largest stress case measured 53,161 allocations and 272,831,083 instructions,
within its unchanged 100,000/500M ceilings. Child process calls fell from 344 to
150: 39 valid fixture compilations, 32 rejection invocations, 39 native links,
39 native executions and one Make build. Makefile plus e2e mechanism lines fell from 1,827
before this correction to 1,760; production, unit, grammar and source fixtures
were unchanged by this slice.

Independent validation passed the exact default command twice, in 26.15 and
26.19 seconds, each with 53 nested assertions, 39 counter pairs, one generation
and one link. The combined UBSan/leak gate passed in 26.87 seconds: 151 unit,
44 grammar and 53 nested e2e assertions, plus the outer orchestration callback
(248 substantive assertions, 249 raw PASS lines including the aggregator).
The host remained FRESH; its generated test code uses `-O0` by default and
sanitizer builds force `-O0`. Its separate runtime dependency remains `-O2`.
No native UBSan errors or strict allocation leaks were reported; final host
teardown was 3 allocations/3 releases/0 leaks/0 bytes. Formatting and whitespace
checks passed. Logs and the independent report are under
`blorp_2/build/e2e-timing/independent-single-O0.ezVSzf/`.

A subsequent unconditional `make -C blorp_2 test-compiler` component timing
took 1.72 seconds at `-O0`, versus 9.21 seconds for the old two-mode `-O2`
build. Log: `blorp_2/build/e2e-timing/fresh-build-O0.log`. Generated C remained
SHA256 `8d41680633365dbd174258db270371fde0a6ba0b2e6813f0909b57b7c79112f9`;
this later executable is `611af3e2ddc5ef03971b7e33f06d3055e9e721f83fa59e34aeea33d57621e344`.
The independent report identifies the executable used during its gates.

A temporary failed-link mutation proved that existing executables do not let
fixtures run after build failure: only generation/link and outer failure were
observed. The Makefile was restored byte-for-byte. Static review approved with
no findings. Scoped temporary-directory cleanup uses the existing host-library
finalizer; successful deletion is not independently asserted by this suite.

The complexity review also identified follow-ups, left outside this change:
generic entrypoint rejection checks repeated across examples, duplicated exact
C expectations in e2e/phase tests, repeated interning searches in parsing,
eager discarded diagnostics in binding lowering, and duplicate match-capture
definition construction. The typed checking/lowering boundaries have current
consumers and remain. The temporary input prelude is still staged rather than
loaded, as documented in the README.
