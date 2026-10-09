# Blorp 2: Int payloads and tail match

Date: 2026-10-09. Worktree: `/Users/keithphilpott/.codex/worktrees/1332/blorp`,
branch `blorp-2`, starting HEAD `275fd3b530473f306b683dd91a64134a53a34898`.
The baseline includes the uncommitted payload-free union increment; HEAD alone
is not its source identity. Its complete source/test snapshot, patch, fingerprints,
compiler binaries and logs are retained under `blorp_2/build/match-baseline/`.

## Design and scope

Hypothesis: a typed body sum, function-owned binding identities and explicit
constructor contracts extend the pure unary-expression pipeline without another
global registry or compiler pass. Syntax resolves to complete checked facts;
emission consumes those facts without repeating resolution or semantic checks.
The retained [design](../../blorp_2/MATCH_PLAN.md) compares the implementation
strategies in Haskell, OCaml, Rust, Scala and Elm.

The first example is [match_value.brp](../../blorp_2/test/e2e/fixtures/match_value.brp):
`main` constructs `Number(42)`, calls `unwrap`, and returns 42. Unions can have
zero fields or one `Int` field. Tail matches have inline value leaves, constructor
patterns, field binders/discards and whole-value binders/discards. Checking owns
nominal constructor resolution, binding scope, usefulness, exhaustiveness,
purity and acyclic calls. Local builders publish immutable checked results.

Payload unions emit an inline C tag plus an initialized `int64_t` field;
nullary values initialize their unused field to zero. Each match saves its
scrutinee once. A flat switch selects an arm before projecting the payload.
Existing payload-free unions retain their enum representation and C bytes.
General bindings, mutable bindings, nested/refutable patterns, managed payloads,
SSA and CPS remain outside this increment.

Pre-implementation ceilings: old fixture instruction minima at most +5% and
allocations at most +35%; first match fixture at most 5,000 allocations and
100,000,000 retired instructions; formatted production at most 3,800 lines;
zero leaks/UBSan errors. These are owned-input compilation proxies. The pilot
cannot self-compile, so they do not establish self-compilation cost.

## Toolchain and source identity

Host `bin/blorp` was FRESH, compiled by immutable bootstrap `dev-0e1598ed616e`,
CLI `-O0`, runtime `-O2`, split 8. Host binary SHA256:
`c67d5bb315a67999ec5d608eaa41aab83f8d75e6220b44b936ea2a4849b7ba0a`.
Apple Clang 21.0.0 (`clang-2100.3.34.2`), arm64 macOS. Pilot normal and diagnostic
executables use `-O2`, respectively `BLORP_MEMORY_DIAGNOSTICS=0` and `=1`,
with `-lm -lpthread`. Native oracles compile strict C11 with warnings as errors;
payload drivers also use UBSan with recovery disabled.

Frozen baseline SHA256:

| Artifact | SHA256 |
| --- | --- |
| Normal compiler | `8c9083d6e2455388058fe0e65bfae66611d2ad2dc5bb8fa40ceef7f0d1900f90` |
| Diagnostic compiler | `13764b5e89e54acf24b4a75ad42c95fb9f56056f8217629440d3fcb7f0d28b91` |
| Generated compiler C | `c9feb7893a586ddb7045f684eecd83ca3e7ecee5530442681e09455be67199c8` |

Final candidate SHA256 (full source/config fingerprints retained as
`match-baseline/final-candidate.sha256` and `final-candidate.inputs`):

| Artifact | SHA256 |
| --- | --- |
| Normal compiler | `070b88da7841797cb24a7cf9cb448a59eb25603ec980bd7a668687cdc552ac4d` |
| Diagnostic compiler | `fbead65059ed3315e4a74bdbf5f7759766b492cdf73ff875d606b8ca44140c26` |
| Generated compiler C | `bcce9650ad3d14e4725acdc00b3ce5c2aaf025e99836991488891c5f1bd1ae69` |

Formatted production is 3,786 lines versus 2,424 (+1,362), below the agreed
3,800 ceiling. TestSuite/support source is 6,691 versus 4,595 (+2,096); raw
fixture source is 121 versus 59 (+62). Counts use physical lines, include
comments/blank lines and exclude generated artifacts. Production counts include
the two-line input prelude; tests/support include the shared Blorp harness.

## Validation and independent oracles

The frozen baseline passed 154 callbacks across 19 suites. New grammar and
payload fixture checks were demonstrated failing before implementation.
Final normal validation passes **190/190 callbacks across 21 suites**:
125 unit, 27 end-to-end and 38 grammar callbacks. Log:
`match-baseline/final-normal.log`.
Final integration caught two stale test expectations: the new match-gap case
had an off-by-one byte span, and the frontend cases still expected the old
indent diagnostic. The latter now agree with the documented whole-prefix
validation (`invalid indentation`, spanning the entire malformed prefix).
No production change was needed for either repair; exact grammar/unit
diagnostic assertions and the focused frontend callback pass.

The native companion fixture tests both constructors, full-width signed Int64
endpoints, copied union values, field and whole-value bindings, parameter
shadowing and sibling scope. Independent counters check exactly-once payload
arguments, payload/scalar scrutinees, selected arms and unselected arms.
Eight deliberately incorrect generated-C mutations must fail the unchanged
native assertions: payload loss, wrong tag, wrong selected result, wrong shadowed
binding, repeated payload/scalar scrutinees, repeated constructor arguments and
eager execution of an unselected arm.

CLI negatives pin complete diagnostics and require rejected input to publish
no fresh C and preserve an existing output sentinel. Every compile used by the
native structural tests first removes its old output and requires a fresh,
silent result. Generated 16/64/256-variant programs check every payload and every
explicit case label exactly once, and require maximum brace depth three. A
32-layer alternating construction/call spine is compiled and executed separately.

The first match fixture uses 753 managed allocations. Final normal-run retired
instruction samples are 19,833,029, 19,865,331 and 19,852,662 (minimum 19,833,029),
within its 5,000 / 100,000,000 limits. These include executable startup and I/O;
they are not a per-phase instruction measurement.

## Matched compilation work

Commands, run serially against the frozen binaries after all source restoration:

```sh
bin/blorp test --suite --timeout 180 blorp_2/build/match_cost_pairs.brp \
  blorp_2/build/match_stress_costs.brp
```

These two retained Blorp probes reuse `test/e2e/harness.brp`. Baseline and
candidate compile the same original fixture paths. Each diagnostic run requires
zero leaks; each of three normal runs must emit the baseline's exact C bytes.
All nine pairs passed the agreed +5% instruction / +35% allocation ceilings.
No host builds or competing compiled gates ran during measurement.

| Fixture | Allocations before → after | Instruction minimum before → after | Instruction change |
| --- | ---: | ---: | ---: |
| return_zero | 129 → 134 | 18,895,494 → 18,875,044 | -0.108% |
| call_one | 244 → 254 | 18,991,896 → 19,042,324 | 0.266% |
| pure_calls | 385 → 400 | 19,145,720 → 19,233,513 | 0.459% |
| nested_calls | 445 → 467 | 19,202,418 → 19,250,566 | 0.251% |
| nested_order | 492 → 516 | 19,278,794 → 19,279,273 | 0.002% |
| ufcs_calls | 447 → 469 | 19,206,483 → 19,297,131 | 0.472% |
| ufcs_chain | 496 → 520 | 19,243,057 → 19,276,915 | 0.176% |
| return_42 | 132 → 137 | 18,866,925 → 18,931,716 | 0.343% |
| union_values | 999 → 1072 | 19,832,188 → 19,910,982 | 0.397% |

Allocation increases range from 3.8% to 7.3%; maximum instruction increase is
0.472%. Startup and system work dominate these small compilations, so no speed
improvement is claimed. All old fixture C is byte-identical. The nested-order
allocation ceiling changes from 500 to 550 and union from 1,000 to 1,150, with
measured increases 492 → 516 and 999 → 1,072. Absolute instruction ceilings stay
unchanged; every other old allocation ceiling stays unchanged.

All instruction samples, in baseline/candidate order:

```text
return_zero baseline: 18895494, 18908643, 18898889
return_zero candidate: 19101138, 18924577, 18875044
call_one baseline: 19082266, 19007246, 18991896
call_one candidate: 19091795, 19126344, 19042324
pure_calls baseline: 19210533, 19145720, 19185636
pure_calls candidate: 19320047, 19244358, 19233513
nested_calls baseline: 19263457, 19202418, 19260307
nested_calls candidate: 19292685, 19250566, 19296011
nested_order baseline: 19301497, 19278794, 19491793
nested_order candidate: 19348309, 19290074, 19279273
ufcs_calls baseline: 19338474, 19218465, 19206483
ufcs_calls candidate: 19338020, 19318598, 19297131
ufcs_chain baseline: 19265030, 19243057, 19349558
ufcs_chain candidate: 19324604, 19318140, 19276915
return_42 baseline: 18866925, 18875755, 18906918
return_42 candidate: 18969838, 18931716, 18944403
union_values baseline: 19899872, 19848966, 19832188
union_values candidate: 19995107, 19910982, 19915125
```

Structural compilation workloads have no additional cost ceiling; their
correctness/depth oracles live in the permanent end-to-end suite. These are
whole-compilation measurements of the generated stress sources, not C compiler
latency or self-compilation:

| Variants | Emitted C bytes | Brace depth | Allocations | Instruction minimum | All instruction samples |
| ---: | ---: | ---: | ---: | ---: | --- |
| 16 | 2165 | 3 | 3271 | 21,940,469 | 21990279, 22008256, 21940469 |
| 64 | 7493 | 3 | 11762 | 31,557,057 | 31562858, 31582508, 31557057 |
| 256 | 29585 | 3 | 46390 | 88,191,429 | 88830133, 88712337, 88191429 |

## Host compiler defect

The first full pilot build exposed a source-accepted host defect:
`List[Id].append(into_opaque Id({value = 0}))` lost `Id` during Core lowering and
reported conflicting generic arguments for `list__append`. A seven-line repro,
red output and lower snapshot are retained in the baseline artifact directory.
An explicitly typed local `VariantId` preserves the pilot's intended identity
and unblocks this build. This is not a relaxation of generic type checking.

The user authorized a separate bounded host repair. It is prepared in
`/Users/keithphilpott/.codex/worktrees/opaque-append-fix/blorp`: retain the nominal
opaque conversion with the existing `CastExpr`, then let runtime projection erase
its physical identity cast. The production change is +3 lines. Host validation
and evidence belong to that separate worktree and `/tmp/blorp-opaque-append/`;
the pilot's cost pairs use the unchanged original host binary above.

The host repair passes 195 focused tests normally and with ASan/UBSan,
238/238 generated-C audits, and static review with no findings. Compiler
fixpoint passes: all three stages emit identical C, SHA256
`fc92e8fbdef0636858bf363210aa898c40d671bad60db59b54fc5bed7a07fdf4`.
Its broad Core sanitizer driver overflows the compiler's stack before any test
executable runs. The unchanged FRESH host reproduces exit 139 against the exact
same 59 suite paths, with the same recursive `emit_let_body` /
`emit_function_body` stack. This is a pre-existing host validation limitation,
not a passing sanitizer gate or a failure of the pilot's 190-test sanitizer run.
Baseline/candidate logs and macOS crash excerpts are retained in the separate
host evidence directory.
The broader `compiler-blorp` suite driver also overflows in the same emitter
family; its remaining check-fixture component was stopped after those failures.
That gate is partial/failed, and only the exact 59-suite sanitizer command has
the complete matched baseline reproduction. These are not full broad-gate passes.
The repair is retained separately and uncommitted. Its runnable handoff is
`/tmp/blorp-opaque-append/HANDOFF.md`, with independent validation in
`INDEPENDENT_REVIEW.md` beside it.

## Final gates and oracle checks

```sh
scripts/compiler-build-status
make -C blorp_2 test
bin/blorp test --suite --sanitize=undefined --leak-check --timeout 180 \
  blorp_2/test/unit blorp_2/test/e2e blorp_2/test/test_grammar
make -C blorp_2 test-compiler
```

Normal and UBSan/leak runs both pass **190/190 across 21 suites**. Final leak
summary is 3 allocations / 3 releases / 0 leaked objects / 0 leaked bytes.
This is UBSan plus ARC leak checking, not an ASan claim. Independent evidence,
all native cost samples, fixture-C hashes and cache SHA/stat details are retained
in `match-baseline/independent-ZbtP7j/report.md`; full logs are
`final-normal.log` and `final-sanitize.log` beside it.

The final source change initially refreshed one compiler C file and linked the
two compiler modes once. After that setup, both full gates and another warm
`test-compiler` invocation reused exactly the same binaries: unchanged hashes,
sizes, mtimes, ctimes and inodes; zero further Generate/Link output. The host
remained FRESH and unchanged. Formatting and tracked/untracked whitespace checks
pass. Raw input fixtures are intentionally excluded from host source formatting.

A temporary bypass of the checker's final exhaustiveness acceptance produced
13/14 passing match unit callbacks: the intended missing-coverage diagnostic
regression failed. Restoring the exact original source returned 14/14 green.
Logs: `coverage-bypass-red.log`, `coverage-restored-green.log`; restoration also
passes every source/config/binary fingerprint in `final-candidate.sha256`.
The eight native mutations independently fail their protected assertions.

Compiler/parser/ergonomics/documenter and code-reviewer input was used; final
static review found no blockers or should-fix findings. Independent test-runner
validation owns the complete normal/sanitizer/cache evidence above. No commit or
push is included in this increment's execution.

## Unit-test feedback time

For the user's exact unit command, one run with a warm runtime cache measured
1.47 seconds wall time, 1.99 seconds user CPU and 0.30 seconds system CPU:

```sh
BLORP_TEST_TIMINGS=1 /usr/bin/time -p bin/blorp test blorp_2/test/unit
```

The 125 callbacks in 11 suites form one aggregate harness and one native
execution (confirmed by the session counters). The phase probe reports frontend
graph 1 ms, pipeline 615 ms, host C compile/link 322 ms and execution 306 ms;
remaining wall time includes other command setup/reporting outside those phase
windows. Execution includes native process startup and supervision, not only
callback bodies. Log: `match-baseline/unit-timings.log`.

Default generated test artifacts use `-O0`; `--release` selects `-O2`.
The pilot's separate cached end-to-end compiler uses `-O2`. A unit invocation
rebuilds its temporary test artifact while reusing the runtime cache; it does
not rebuild `bin/blorp` or use the pilot's end-to-end compiler cache. This single
sample supports compilation being the largest cost here, not a performance
regression or optimization claim.

The user set an eventual goal of roughly **5× faster compilation through C
emission** versus the existing compiler on matched workloads. Applying that goal
to this measured 615 ms pipeline gives about 123 ms, saving 492 ms and reducing
the 1.47-second command to about 0.98 seconds if the other costs stay unchanged.
This is a projection, not an achieved speedup. The new compiler must first
support the unit-harness workload; making the current limited pilot faster does
not accelerate the existing host compiler used by this command.
