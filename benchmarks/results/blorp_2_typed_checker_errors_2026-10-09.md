# Blorp 2 typed checker failures

Checking now publishes either a complete `CheckedProgram` or an opaque
`CheckFailure`. The failure retains its original sealed `ParsedProgram` and
`CheckErrors { first, remaining }`, a nonempty collection of typed errors.
Checking still stops at the first failure and publishes a singleton; independent
error accumulation and recovery are future work. No partial checked program,
mutable inference state, or tentative builder escapes.

`CheckError` carries a primary span and one of 42 closed variants, including
`InternalInvariant` with 22 closed invariant cases. Human wording belongs only
to the renderer. Argument failures retain expected and actual types, actual
occurrence, parameter position and expected-type origin. Generic conflicts also
retain the parameter's owner, earliest inferred candidate and current candidate,
plus the complete outer argument obligation. Binding failures retain their
function-owned binding identity. Declaration duplicates retain both occurrences
when discovered, without querying declarations again for error facts.

`check_errors` exposes semantic data. `render_failure` renders every error using
that failure's original parsed authority and returns nonempty `Diagnostics`.
The main boundary explicitly wraps unchanged lexer, parser and later-phase
single diagnostics; prelude/program origin and the complete collection reach
the CLI. A synthetic two-error test proves ordering, full CLI formatting and
rejection by the semantic test helper's singleton projection. Success-only test
setup has an explicit test-local diagnostic for an unexpected error tail.

This increment changes neither accepted syntax nor generic inference. Inference
remains one-way with one type parameter. Bidirectional checking and structural
unification are separate follow-ups. The existing UFCS receiver occurrence-span
limit remains explicit: its mismatch occurrence uses the call span. Unary
primary mismatch spans remain on the callee; multiargument mismatches highlight
the offending argument.

## Direct tests and preserved diagnostics

The initial direct checker callback failed because the proposed typed exports
did not exist; `build/generic-expansion/typed-errors/tdd.log` retains that failure.
Checker-negative tests now assert closed kinds and semantic facts directly.
Preparation failures cannot satisfy a rejection test. No callback launches a
compiler process for its input.

`test_typecheck_programs.brp` contains 20 named callbacks with complete multiline
program strings: 10 accepted and 10 typed rejections. The separate typed-error
suite covers direct and UFCS argument positions; primary versus actual spans;
source annotations and runtime contracts; return mismatches; nominal owners;
three-argument structural inference preserving the earliest span across an
agreeing middle argument; uninferable parameter ownership; ordered missing
variants with equal ordinals in another union; duplicate occurrences; and a
shadowed immutable capture in the second function.

Renderer tests construct known typed errors independently of rejection checking.
One accepted setup provides valid opaque identities. A table preserves 52
distinct pre-migration message/help obligations and adds six other current
branches, for 58 exact span/message/help/note assertions. Three additional
renderer/collection callbacks cover expected-type spelling, structural conflicts
and complete collection presentation. Existing pipeline wording checks remain.
The accepted-arguments callback inventory contains no removed unit callback.

Retained mutations under `build/generic-expansion/typed-errors/` prove the oracles:

| Mutation | Specific failing callback(s) |
| --- | --- |
| Swap expected/actual types | UFCS obligation, unary occurrence, runtime contract, nominal mismatch |
| Replace argument position with zero | UFCS second argument |
| Replace missing variant with another owner's equal ordinal | Ordered nominal missing coverage |
| Drop earliest inference span | Three-argument structural conflict |
| Change wording only | Independent argument renderer; semantic callbacks still pass |
| Repeat expected/actual swap against the 20-program corpus | Exactly `second argument type`, 1/20 failures |

Each mutation restored the original source bytes. Logs are named
`mutation-*.log`, including `mutation-corpus-swap.log`.

## Validation

Final worker gates use the repository `bin/blorp` and the existing Makefile:

```sh
bin/blorp test --suite --timeout 180 \
  blorp_2/test/unit/test_checker_errors.brp \
  blorp_2/test/unit/test_check.brp \
  blorp_2/test/unit/test_typecheck_programs.brp \
  blorp_2/test/unit/test_prelude.brp
BLORP_LEAK_CHECK=strict bin/blorp test --suite --sanitize --leak-check \
  --timeout 180 blorp_2/test/unit
make -C blorp_2 test
```

Focused callbacks: **106/106**. Strict ASan/UBSan units: **432/432**, zero leaked
objects or bytes. Full gate: **589 leaf checks** = 432 units + 9 runtime + 84
end-to-end + 64 grammar. The log reports 591 passes because two wrapper callbacks
also report success. All existing native allocation/instruction caps pass;
this increment changes no cap. The e2e run builds the pilot once through the
Makefile and uses the existing strict C11 `-O0` sanitizer harness.

Logs: `final-focused.log`, `final-units-strict.log`, `final-full.log` and
`final-build.log` under `build/generic-expansion/typed-errors/`. The first full
attempt exposed an omitted integration consumer of the new diagnostic collection;
`test/e2e/test_frontend.brp` now explicitly requires a singleton for its exact
negative assertions and formats all diagnostics on unexpected positive failure.
No new host compiler defect was found.

All **68 valid fixtures** produce byte-identical C against accepted arguments.
Both sets remain inspectable under `typed-errors/identity/{arguments,typed}/`;
all compilations release every managed allocation. This includes the first/second
borrowed String returns, structural generic calls and evaluation-order examples.
The target C remains unchanged because typed failures never enter the successful
checked-product pipeline.

## Matched positive compilation proxy

These are pilot compilation proxies, **not self-compilation**. Building the
pilot and compiling/running its emitted C are outside the measured boundary.
Each sample uses the existing recorder path:

```sh
/usr/bin/time -l -o REPORT.time /usr/bin/env BLORP_LEAK_CHECK=strict \
  PILOT blorp_2/src/prelude_temp.brp FIXTURE OUTPUT.c
```

Six unchanged workloads have three quiet serialized samples for the original
baseline, accepted arguments and final candidate. Allocations are deterministic;
instructions use the minimum of three. Raw samples are in `typed-errors/matched/`
and the complete comparison is `matched.tsv`.

| Workload | Allocations accepted → final | Step change | Instructions accepted → final | Step change |
| --- | ---: | ---: | ---: | ---: |
| return_zero | 685 → 687 | +0.29% | 30,779,934 → 30,631,575 | -0.48% |
| nested_calls | 1,325 → 1,330 | +0.38% | 32,597,988 → 32,528,180 | -0.21% |
| mortal_string | 1,034 → 1,037 | +0.29% | 31,768,554 → 31,744,815 | -0.07% |
| generic_box | 2,164 → 2,154 | -0.46% | 34,985,855 → 34,843,044 | -0.41% |
| union_values | 3,641 → 3,633 | -0.22% | 39,074,095 → 39,018,539 | -0.14% |
| match_constructor_spine | 8,797 → 8,636 | -1.83% | 52,747,236 → 52,473,538 | -0.52% |

The largest cumulative increase against frozen `da8fa4c71` is
`match_constructor_spine`: 7,628 → 8,636 allocations (+13.21%) and
49,718,476 → 52,473,538 minimum instructions (+5.54%). Neither the cumulative
25% investigation threshold nor the additional 5% threshold is breached by
these final positive samples.

## Negative checker/render proxy and attribution

Two explicit workload adapters prepare the same three parsed programs once,
then check each 1,000 times: a second Int/String argument mismatch, a structural
P[Int]/P[String] conflict and missing match coverage. Lexing, parsing and prelude
checking occur outside the repeated boundary. The prepared inputs remain owned
and sealed. Baseline uses its Diagnostic result; candidate exposes typed failure
facts and, in the combined workload, renders the complete collection. Complete
source adapters and generated C remain under `typed-errors/negative/`.

The combined checksum is 925,000 in every version; the check-only occurrence
checksum is 692,000. Every run has zero leaks. Final quiet paired samples are in
`negative/final-matched/`; each has three samples per executable.

| Boundary | Accepted allocations | Initial typed | Final typed | Final step change |
| --- | ---: | ---: | ---: | ---: |
| Check-only occurrence consumption | 395,067 | 466,067 | 375,067 | -5.06% |
| Check and render wording | 395,067 | 511,067 | 414,067 | +4.81% |

The old checker **already renders its Diagnostic during checking**, so its
check-only boundary still includes old rendering work. The candidate check-only
proxy does not render. This is an API comparison, not a claim that equivalent
checking algorithms intrinsically differ by those percentages.

Initial combined instructions were 894,105,129 → 1,090,832,420 (+22.00%). The
additional error-path cost triggered investigation. Eleven eager Option error
arguments constructed managed typed invariants/errors even when lookups succeeded.
Direct owning Some/None matches retain the complete same errors and remove
91,000 allocations from both candidate workloads. Replacing the renderer's
empty-tail mapping closure with an ordered local list builder removes another
6,000 allocations. These are the only retained cost changes; no general lazy
error framework or optimizer was added.

Final paired minimum instructions are:

- Check-only: 894,043,010 → 847,899,759 (-5.16%).
- Check and render: 894,394,899 → 924,527,827 (+3.37%).

The complete typed failure plus rendering still costs more on invalid programs.
It now falls below the reviewed additional 5% threshold. Error records, owner-
qualified facts, retained parsed authority, nonempty collections and original-
program spelling lookup remain intact. The candidate was accepted with this
measured residual overhead; positive-path success alone was insufficient evidence.
Intermediate binaries/C and `*-lazy-*`/`*-loop-*` samples retain the attribution.

## Provenance and size

The cumulative baseline remains `da8fa4c7134e3c636fb7b67f35918f8d7cdc50b0`, frozen
under `arguments/baseline/`; it was not advanced. Its pilot SHA-256 is
`63bc41957cf2814feef10fee784ce97585340509636e99e45aae7b3361479990`.
Accepted arguments is frozen under `typed-errors/accepted-arguments/`:
source archive `bee8e5e1f31ce13380f27b25d121031c08ae890e6dafc830b64ced9d01598166`,
pilot `51a3f3fe859d8683c74d01c8fb4da42e9bec804943f38235b258de916be7bf1b`.

Final source/test/doc manifest is `typed-errors/final-sources.sha256`; the final
source archive, pilot and generated compiler C are under `typed-errors/final/`.
`final/artifacts.sha256` records their exact hashes and the negative adapter,
C and executable fingerprints. The measured final pilot is
`aeba97caf9ecd3aaa97f7e82273d546e4c5c10cef8acc5f08d9863e2560ab01e`; generated C is
`bbcc34df922fdc0c1bb90193e904f7cf9354b30391b090fd221d0ad16f87332c`.
The unchanged FRESH repository host is
`f6d946861a5a07faa506cb598e0e64d8af0f89289551737b5e0dc42443554a8c`.
Native compiler: Apple clang 21.0.0 (clang-2100.3.34.2), `-O0`, memory diagnostics
enabled for measured pilots and proxies.

Formatted physical production `.brp` lines: **9,693 → 10,266 (+573)**, including
main and the unchanged explicit prelude. Test `.brp` lines: **18,103 → 19,865
(+1,762)**. The initial +250 production estimate did not account for the complete
closed vocabulary and independent renderer. The coordinator approved a reviewed
+600 hard ceiling with a +550 aim. Final growth exceeds that aim by 23 lines and
stays within the hard ceiling; it retains complete typed facts and full error
collections without compressed formatting or deleted coverage. No commits,
host changes, persistent cache or additional compiler phase were introduced.
