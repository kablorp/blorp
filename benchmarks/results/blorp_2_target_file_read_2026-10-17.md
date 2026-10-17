# Target file reading: implementation and matched costs

The bounded `system.read_file(String) -> Result[String, String]` implementation
passes correctness, mutation, matched-cost and final destination gates, with
root and independent compiler-expert review complete. This does not
establish compiler self-compilation, loader migration, bootstrap or M6 completion.
The [owning plan](../../blorp_2/TARGET_FILE_READ_PLAN.md) defines the contract.

## Identity and ownership boundary

Discovery recognizes the closed `ReadFileBuiltin` variant. Checking publishes
`ReadFile` with the designated Result constructor identities; specialization
translates those identities once into the concrete runtime operation. Lowering,
ownership and verification consume that typed operation. Emission uses its actual
constructor IDs and emits the native label/runtime bytes. No later phase recovers
semantics from a String name; ordinary path, contents and diagnostic Strings remain
program data. The path is borrowed, and either native status publishes one fresh
owned String into the ordinary union's active payload. No host Result box enters
the target runtime.

Native reading preserves valid counted UTF-8, including empty contents, CRLF,
BOM and embedded NUL. NUL paths fail before open. The implementation attempts
regular-file seek/tell/seek/read once, saves errno before cleanup, attempts close
once, preserves primary-error > close-error > encoding-error priority, and frees
private path/staging storage. The LP64 static assertion documents why the size
representability error cannot be dynamically reached on this supported platform.

## Provenance

Raw evidence is ignored under `build/target-file-read/` in
`/Users/keithphilpott/.codex/worktrees/target-file-read/blorp`.
The matched packet is `cost-891-01/`; it retains source maps, concrete commands,
raw C, all process outputs/statuses, counters, times and before/after pins.

Cost B is accepted main `891f64c989a9c0b30002c3e98d8fce028de1ddb1`.
Cost C is the actual reviewed feature source snapshot on base
`c67a8ec49ea7078ea3d76a9e7038775834b27d2f`, before the post-cost test-only
dedup below. Each variant freezes 39 compiler-source and 9 temporary-library files.
Aggregate SHA256 is over compact sorted JSON mapping relative paths to file SHA256:

| Map | SHA256 |
| --- | --- |
| B source | `6c78e3feaab57852d2f4087e29ef07c086453722aeee23b3476e79a9a05f7d00` |
| C source | `3153aa5302108b1469e86f2f57a45c7fc2305686f9e037b0ca9450c5984962dd` |
| B target library | `1d59c28f3279be54d4186809d0c1d6363910b25c5538b299250c469ce1815679` |
| C target library | `3bb309e9a8dfb48caf9caae4edea7b7909d90b96dabf184457832a449eabea87` |

The borrowed producer was the explicit main-checkout
`/Users/keithphilpott/CLionProjects/blorp/bin/blorp`, SHA256
`c04f68ba64ac06f6cd3f924cdb4d87ce6b3d40d0f8fba2ef89b20e324b21ca57`.
It was verified fresh by root for its own source checkout, not claimed fresh for
the feature worktree. Every invocation explicitly used main's
`standard_library/src`; all 91 files were pinned to accepted main. Its system
module, also pinned by the temporary adapter's provenance, is
`20d8b991feb384d3d4a4d1a11b4d203f67abd73deb37051e4f714ce8b6920459`.

Exactly two cost C generations used the same canonical physical source/argv
boundary, with B/C source and library installation outside the invocation.
Each unchanged C file was linked twice with `/usr/bin/clang -O0`,
`-DBLORP_MEMORY_DIAGNOSTICS=0` or `1`, and `-lm -lpthread`.
Clang's SHA256 was
`5b1ddb7e9c11b87a034fc88b212e8ac243cfe2b4db696d767aa44c79595fc09a`.

| Artifact | SHA256 |
| --- | --- |
| B C (7,951,506 bytes) | `975ead5abf08ce3870c614ec0690c9459c27dd7acaa9f163e44f05c46a0829ab` |
| B normal | `ad7994b2e763f387cccc18dd53a834b26490b4147e9880b4d6d2021cfbe06ca7` |
| B diagnostic | `854d480db6102d9aa28047d2bc9574f2d2b7f058b81e1db61517d971579f8e6c` |
| C C (7,976,895 bytes) | `6d16a0759ce59dafeb326d1a7808a2d4e9b9d7ce390e2682ffe42f25bab9d512` |
| C normal | `c996926711c577618bd868e1cb0c77651437bd5e6ced3639a96e8958ef818236` |
| C diagnostic | `b1081b57b638c28b3145d89134a179acea1b1a65a6bf93149933316781e8b1cf` |

The C candidate is byte-identical to the separately retained functional pilot C;
that functional diagnostic executable is
`c848a89cc5f9792abcb1ba1e0905fb5bb8b97107a2ee04b4e235e4e904c9d6f8`.
Both variants/modes produced the same 83 inherited warning causes: 3 discarded
List const qualifiers, 52 extraneous parentheses and 28 pointer/long comparisons.
Actual paired expressions were reviewed: 47 identical, 36 differing only in
generated local/enum identities; renamed enum literal values were checked. No new warning cause.

The supporting host proxy reused the accepted O2 pair, without reconstruction,
from `host-dirname/blorp/build/host-file-errors/cost-721-01/`:
normal `4cc4b91240e8bb02fbfbe44a6bdecca8df3085874ad138cfbaa196500a98d78c`,
diagnostic `485a9dc4257b3f5c5a54f843129b42037962a0084b154c3bf616881f3b6259bb`.
Its older printed metadata remains literal. Retained pair provenance proves the
compiler body and accepted runtime source relationship to main 891; the host
system-module change is comments only. Actual calls still used explicit std20d8.

## Correctness and deliberate negative checks

The initial parser/checker witnesses each failed before implementation with
`unknown builtin operation`, existing supported-operation help, and label span
`64..82`. Their borrowed producer was the earlier e74 epoch, SHA256
`e74cd095ab86d1d0035c6a9b319167bd17988fda061fb91dd9a2eb44ca9fdaf1`;
these historical red/early-green logs were not relabeled as c04 evidence.

| Gate | Observed result |
| --- | --- |
| Focused checker/parser | 11 / 1 passing tests |
| Specialize/lower/own/verify/emit | 2 / 1 / 5 / 12 / 4 passing tests |
| Native runtime | All 19 cases pass; strict C11, warnings-as-errors, ASan/UBSan/no-recovery |
| Full unit/runtime/grammar | 3,069 PASS events, no failure, empty stderr |
| One functional pilot build and real-main e2e | 461 fixture groups pass, no failure, required instruction checks |
| Root cheap publication checks | Hygiene/artifact scan pass; 6 tooling checks, C-symbol boundary, manifest 374 modules/256 suites/8 checks |

The native tests independently check saved errno, EOF classification, encoding,
physical staging/path frees, unchanged borrowed path, one close attempt and FD
closure, plus active Ok/Err payload destruction. The full actual first new
fixture C was inspected; root independently inspected all three fixture bodies,
including escaping-payload retention before parent drop and argv cleanup.

Each mutation retained original and mutant source, exact patch, hashes, red
output/status and restored green output/status. Restoration was byte-exact.

| Mutation | Intended failing callbacks | Restored owning gate |
| --- | ---: | --- |
| Saved read errno captured after ferror | 3 of 19 native | Green |
| EOF classified by stale errno | 1 of 19 native | Green |
| UTF-8 gate inverted | 1 of 19 native | Green |
| Successful staging free removed | 3 of 19 native | Green |
| Private path free removed | 18 of 19 native | Green |
| Duplicate close | 6 of 19 native | Green |
| Emitted success constructor changed to Err | 2 of 4 emit | Green |
| Scheduled unused-result drop removed | 1 of 5 own | Green |
| Test-local acquired child changed to parent | 1 of 5 own | Green |

The last oracle was strengthened after independent review to compare the acquired
value's actual child identity as well as parent/returned identities. Its sequence
was 5 pass, then 4 pass/1 intended failure, then 5 pass after restoration.
All eight production mutations and the strengthened ownership oracle received
independent compiler-expert review with no remaining findings.

Focused/full commands are retained in `full/commands.txt`; representative gates:

```sh
HOST=/Users/keithphilpott/CLionProjects/blorp/bin/blorp
STD=/Users/keithphilpott/CLionProjects/blorp/standard_library/src
"$HOST" test --suite --timeout 180 --std-dir "$STD" blorp_2/test/unit blorp_2/test/runtime blorp_2/test/test_grammar
BLORP2_COMPILER="$PWD/build/target-file-read/full/compiler" BLORP_CC=/usr/bin/clang BLORP_2_INSTRUCTION_CHECK=required "$HOST" test --suite --timeout 0 --std-dir "$STD" blorp_2/test/e2e
```

Earlier test-only setup failures remain recorded: multiline tuple syntax,
opaque SourceId equality, a seed's forbidden shadowing, two stale builtin-help
expectations, and host loop propagation in the fixture-data setup. Root reviewed
each bounded repair. The last became a direct Result accumulator preserving the
first write error. These failures do not constitute phase-correctness evidence;
the accepted results above are the later explicit greens.

## Matched costs

The frozen corpus contains 461 fixture files and 150 generated dependencies.
The accepted prior CWD registry supplies 483 shared invocation/output-state cases;
the old two CWD inputs are shared B/C inputs, and three read-file compiler inputs
are C-only. Native argv scenarios do not add compiler workloads.
Only configuration path fields were translated to the new canonical/generated
prefixes. Two initially stale metadata-only paths were corrected under review
(111 to 113 translated fields); raw BRP bytes and compiler outputs were unchanged.
Final manifest SHA256 is
`86468636879c8c9dbca21360bb86dc9ff08fc84817a443cc91e4a97fc6cd0190`;
prepared commands SHA256 is
`0a0c935edbf6741e031ee4f85f3cfbebebada864db6998be374fca66c92168b5`.

Each shared input ran strict B/C first, checked total allocation growth, then
normal B1,C1,C2,B2,B3,C3 with `/usr/bin/time -l`. Input/library/output-state setup
occurred outside each measured call. C-only inputs ran strict C and three normal
calls. All 3,876 target calls passed exact frozen status/stdout/stderr/output-state
oracles and applicable absolute caps. All 969 target strict calls had positive,
balanced allocations/releases and zero leaks; 2,907 normal samples had positive
retired-instruction counts. Unchanged-input C/diagnostics and within-variant
normal/diagnostic raw C identity held, without normalization.

| Workload/metric | B | C | Change |
| --- | ---: | ---: | ---: |
| Worst shared allocations, i0011 | 11,785 | 12,014 | +1.943148% |
| Worst shared min3 instructions, i0012 | 50,586,569 | 50,983,390 | +0.784439% |
| New basic allocations / min3 instructions | — | 14,497 / 55,530,591 | C-only |
| New ownership allocations / min3 instructions | — | 14,847 / 55,865,335 | C-only |
| New NUL-path allocations / min3 instructions | — | 12,370 / 51,085,880 | C-only |
| Host proxy TOTAL allocations | 23,328,557 | 23,418,243 | +0.384447% |
| Host proxy min3 instructions | 20,724,974,101 | 20,796,084,088 | +0.343113% |

Every shared input/proxy metric stays within +5%; each new fixture stays below
205,000 allocations and 600,000,000 instructions. Original source R0 and the local
and cumulative 3% packets were not reset or modified. These are owned-input and
supporting-host proxy costs, not a performance or self-compilation claim.

## Failed supporting-host strict checks and retained corrections

Both host diagnostic proxy calls completed valid C and failed strict ownership
with exit 99 under the existing [host-only limitation](../../blorp_2/HOST_BOOTSTRAP_LIMITATIONS.md):

| Host observation | B | C |
| --- | ---: | ---: |
| Allocations | 23,328,557 | 23,418,243 |
| Releases | 22,813,226 | 22,900,706 |
| Leaked objects | 515,331 | 517,537 |
| Retained bytes | 35,048,857 | 35,197,619 |

No leaked allocation was subtracted. These memory verdicts remain FAILED,
separate from the passing cost thresholds. Pilot/native strict gates have no waiver.
All six normal proxy calls exited 0 with exact `Generated <requested path>\n`
stdout and empty stderr. Each variant's four output C files exactly match its
approved producer C. The intentional B/C compiler-C delta was reviewed against
the typed builtin/operation, contract, parser label/help, emission and embedded
runtime changes; the raw diff is retained.

Sampling retained all first attempts. An automatic setup rejection executed zero
samples; the incorrect `/usr/bin/unlink` setup path executed no additional sample.
The original i0001 strict-B sample was reused, never rerun, after switching to
verified `/bin/unlink` for the one owned output outside measurement.

The first host strict-B stopped on an initially incorrect Generated-line oracle.
Root/peer proved the exact frozen diagnostic binary's strict leak branch calls
`_exit(99)`, suppressing buffered native print output. They approved exact empty
stdout only for host strict99; normal0 still requires the exact Generated line.
That sample and the original stop remain intact. A later table-row validator
omitted digits from type names such as `stage_09`; its stop is also retained.
The approved repair added digits only to the anchored type-name character class,
validated both existing complete leak reports, and resumed the six normal calls.
No sample was excluded, resampled, normalized or silently relabeled green.

Final `sample-pins.after.json` closes producer/proxy/target artifacts, all host
standard-library files, source/library snapshots, registry, fixtures and generated
dependencies unchanged. `sample-receipt.json` links the raw stops and corrections.

## Post-cost test change and remaining gate

After closing costs, root and peer approved moving the basic missing-argument
native case to `first_case` and deleting its duplicate list entry. Empty-file
coverage remains once; all eight distinct basic oracles are preserved, with total
native scenarios reduced from 12 to 11. Production, library, three fixture bytes
and limits are unchanged. Frozen cost registry/order pins remain literal;
`post-cost-test-dedup.json` and its patch record the later test-only registry delta.
Root's destination `BLORP_CC=/usr/bin/clang BLORP_2_INSTRUCTION_CHECK=required make -C blorp_2 test`
passed unit/runtime/grammar and all 461 e2e cases after this change, with exit 0.
Logs are `build/target-file-read-integration/{full,static}.log` in the main checkout;
hygiene/artifact checks passed. Destination pilot C has the same `6d16a075...` hash.

Implementation/test counts before this report/status documentation: production
144 added / +134 net (130 code, 8 comments, 6 blanks); tests 1,298 added / +1,293
net (1,122 code, 5 comments, 171 blanks); three fixtures 47 added lines (44 code,
3 blanks). All remain below the preapproved budgets. Evidence/status documentation
is reported separately in the final staged handoff. No source cohort merge,
commit or push was performed by the worker.
