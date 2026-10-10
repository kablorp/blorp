# Blorp 2 fresh String tail arms — 2026-10-09

The working examples select either tail arm through ordinary source `main`
functions. Each selected arm creates and returns a fresh String; the caller
borrows it for length and drops its owner. A third fixture retains an alias
while dropping an unused result and a replaced local.

## Boundary and identities

`ReturnTransfer` is shared by straight-line returns and owned match arms.
`OwnedMatch` replaces the raw unmanaged match in ownership IR; its arms carry
inserted operations and one typed transfer. Insertion, verification and emission
use the same operation/return path for scalar and String bodies. ValueIds and
OwnerIds remain function-wide, while last-use positions are local to a block.
Unmanaged prefix values remain visible; sibling values and owners do not.
The verifier uses explicit unavailable owner entries and absent value entries
for earlier sibling ordinals, then independently checks each selected exit.

Parameters and the pre-match prefix remain unmanaged. This slice adds no
managed outer borrow, non-tail match, join, generic machinery or runtime change.

## Frozen matched input-compilation proxy

Baseline: `bb0b28d1edbd3ff5d3f010b25eec24cd815a9a4c`. Host build status was
FRESH; host `bin/blorp` is the same binary for baseline and candidate, reporting
`49d480ea5d30-dirty`, CLI `-O0`, runtime `-O2`, 8-way split. Pilot compilers
are both compiled with Apple Clang 21.0.0 at `-O0`, with
`BLORP_MEMORY_DIAGNOSTICS=1`, `-lm -lpthread`.

The unchanged source/prelude inputs are frozen by SHA-256 before editing. Three
alternating baseline/candidate runs per input use `/usr/bin/time -l` and
`BLORP_LEAK_CHECK=strict`; allocations are deterministic and instruction columns
are minimum-of-three. Each run emits new C. Every compilation has zero leaked
objects/bytes and empty stdout.

| Input | Baseline allocations | Candidate allocations | Baseline instructions | Candidate instructions | Identical C |
| --- | ---: | ---: | ---: | ---: | --- |
| return_zero | 623 | 624 | 31,448,039 | 31,381,126 | yes |
| match_value | 1,476 | 1,517 | 34,004,238 | 34,033,406 | yes |
| match_many_arms | 61,887 | 66,760 | 303,377,267 | 314,025,358 | yes |
| mortal_string | 919 | 920 | 32,275,805 | 32,204,567 | yes |

The largest repeatable allocation increase is 7.9% on 256 arms; its instruction
increase is 3.5%. Both are below the 25% stop ceiling, and existing e2e limits
are unchanged. These are owned-input compilation proxies, including startup,
I/O and diagnostics; the pilot does not self-compile and this is no bootstrap
performance claim.

The new fixtures use the existing 20,000-allocation / 200,000,000-instruction
String ceilings. Single fresh input-compilation samples:

| Input | Allocations | Instructions | Native exit |
| --- | ---: | ---: | ---: |
| match_string_first | 1,788 | 34,857,795 | 1 |
| match_string_second | 1,789 | 34,824,716 | 2 |
| match_string_cleanup | 2,422 | 36,725,064 | 1 |

Native programs compile unmodified generated C with strict C11, warnings as
errors, `-O0` and UBSan; the cleanup fixture also passed ASan. All produce empty
stdout/stderr. Generated C inspection confirms allocation remains inside each
case, unused/replaced arm owners drop before transfer, and the caller drops
its returned owner once after length. All four unchanged outputs remain byte
identical in every paired sample.

## Direct tests and evidence

The new named pipeline regression failed before implementation and now passes.
Focused final suites pass: ownership insertion 25, independent verifier 51,
lowering 16, emitter 15, source integration/diagnostics 4 (111 callbacks total).
Direct malformed ownership inputs reject missing arm transfer, leaked owner,
double drop, dead borrow, transferred/dropped return, sibling value/owner escape
and reuse of sibling ordinals at exact spans. They are independent of insertion;
the missing-transfer/leak cases establish that the oracle detects the omitted
operation. All six existing malformed match-coverage/structure negatives remain.
Source negatives pin message, help and span for managed prefixes and borrowed
String parameters. Emitter tests use independently expected complete small raw
ownership bodies, including arm-only String runtime selection and caller cleanup.

Affected production files: 2174 → 2221 lines (net +47). Affected test
files: 3253 → 4330 lines (net +1077),
including the three new executable fixtures. Documentation is counted separately.
Growth introduces the needed typed arm product and direct boundary regressions;
no prior coverage is removed.

Raw retained evidence: `blorp_2/build/string-tail-match/`. `baseline/` contains
source/binary fingerprints, frozen executable, generated C and build log;
`candidate/` contains matching samples, C, native binaries/output and current
fingerprints. `summary.json` records all three samples, hashes and toolchain
identity. `failing-before.log`, `focused-final.log`, and the focused stage logs
retain the regression history.

Independent review approved the slice with zero blockers or required fixes.
The final test runner verified a FRESH host and unchanged source fingerprints
through both gates. Strict ASan/UBSan/leak unit validation passed all 307
callbacks with no failures, sanitizer reports or reported leaks.
`make -C blorp_2 test` passed 307 unit callbacks, 57 grammar callbacks,
9 runtime C cases and 68 e2e cases, plus the runtime/e2e wrappers: 443 passes
and zero failures. All 52 fixture compilations remained within their existing
cost limits; the 256-arm C retained brace depth 3. The run generated and linked
the pilot exactly once. Fresh candidate output matched all four frozen prior
C files byte-for-byte. The three new fixtures returned 1/2/1 with empty streams
through the ordinary O0/UBSan harness. `git diff --check` passed.

Full independent reports are retained in
`blorp_2/build/string-tail-match/review.md` and
`blorp_2/build/string-tail-match/test-runner-report.md`. These gates validate
the tail-String slice before the separately handed-off generics work begins.
