# Target write_file: counted bytes and ordinary Result ownership

Implementation and validation are complete at the frozen boundary below.
Coordinator owns landing and destination validation.
The fixed baseline is accepted main `e906b8104f269ace2ca990693a5bae417f73b006`.
The measured code, tests, fixtures and target library are fixed by write-only patch
`447e022744f559b0a84fc4d2013d56a096a2a76608689f628cd3d4c83b83f929`.
Final maintained status/report edits are separate from those measured bytes.
The final branch is `codex/bootstrap-write-file-final`; accepted HOF changes are
in its base, rather than duplicated in this feature. The [owning plan](../../blorp_2/TARGET_WRITE_FILE_PLAN.md)
retains the contract, ceilings and original design provenance. M6 and compiler
main/loader migration remain open.

## Behavior and ownership

`system.write_file(String, String) -> Result[Void, String]` is an impure,
nongeneric builtin with one typed designation and contract. Parsing maps the
closed label to its typed builtin variant; checking, specialization and emission
carry typed operations and constructor IDs. Ordinary lowering, ownership insertion and independent raw
verification handle two borrowed operands and one owning Result without a new IR.
The same String may supply both operands. Ok contains the actual uint8 Void value;
Err receives the fresh owned String scratch. No host Result adapter, semantic name
recovery, additional retain or fake String Ok is used.

The inspected host adapter remains upstream `891f64c989a9c0b30002c3e98d8fce028de1ddb1`,
`standard_library/src/system.brp` SHA256
`20d8b991feb384d3d4a4d1a11b4d203f67abd73deb37051e4f714ce8b6920459`.
The target intentionally teaches NUL paths with the more specific message in the
plan; no host API or runtime change is included.

The reached-only helper rejects counted NUL paths before allocation/open, privately
terminates the path, opens wb, writes exact counted contents once, and closes once.
Empty contents still create/truncate and close. It saves errors before cleanup;
a short-write error takes priority over a close failure. There is no retry or
atomic-publication promise. Success leaves error NULL; failure returns one fresh
String. UTF-8/BOM/CRLF/NUL content bytes are preserved, with no extra decoding.

## Correctness and sensitivity

| Gate | Actual result |
| --- | --- |
| Ordinary mixed Void/String Result prerequisite | 4 phase callbacks passed before wiring |
| Native prerequisite | 17 native cases plus wrapper passed before wiring |
| Missing builtin before wiring | semantic unknown-builtin rejection, CLI 1; not fourteen distinct checker reds |
| Final focused owning suites | 189 PASS, 0 FAIL; CLI 0, empty stderr |
| Full unit/runtime/grammar | 3258 PASS, 0 FAIL; CLI 0, empty stderr |
| Full functional real-main e2e | 467 passed, 0 failed; CLI 0, empty stderr; instruction checks disabled |
| Linux ARM64 Clang 18.1.3 / GCC 13.3 | 6 strict native links and 8 real-main cases passed |
| Hygiene and artifact scan | exit 0 |

Final functional commands and true exits are bound by
`current/functional/FUNCTIONAL_RECEIPT.json` (SHA256
`9df7db4eae42de4a0bcd007c5d8aaa44881f6f068bc4112c849554a19a036344`).
All 856 source/test/library inputs and 91 ROOT standard-library files match their
before/after pins. The one functional pilot generation/link and unchanged-C O0
links are retained. Its 87 inherited host-generated warnings are 28 pointer/integer,
56 parentheses-equality and 3 const-List warnings; none was suppressed. Target
native links retain strict C11/O0/Wall/Wextra/Werror/pedantic and ASan/UBSan with
no recovery. Linux uses the same three retained generated C files, a read-only
input mount and ephemeral executables, without a fixture rewrite or alternate main.

The bytes fixture stores exactly 16 bytes
`ef bb bf c3 a9 f0 9f 98 80 0d 0a 00 74 61 69 6c`, emits those bytes plus LF,
and exits 7; missing parent exits 1. The ownership fixture truncates to empty,
exercises ignored/duplicate Ok and Err Results and an escaping error payload.
The NUL fixture rejects before opening and preserves the existing prefix file.
Host read_bytes independently checks stored bytes; the same failed host operation
supplies the platform numeric errno oracle. Direct generated-C/native checks and
the independently generated full e2e checks both pass. Compiler-pilot strict
reports have positive balanced allocation/release counts and zero leaks. The 17
native helper
cases use independent allocation/free, reference and FILE/descriptor lifetime
oracles plus sanitizers. No target or native memory exception is allowed.

Independent raw verifier negatives cover ordered Void/String roles, either wrong
operand, malformed result/ownership and early or wrong-owner retirement. Generic
constructor membership and cross-owner cases are reused from existing Result
suites. Lower spans are checked against an independently minted root SourceId and
literal label bounds; a weak pairwise-only oracle mutant fails the wrong-both-span
callback, followed by the exact two-callback green restoration.

Nine preliminary mutations compile successfully and reach intended failing
assertions: NUL guard, wb truncation, counted length, short-write status, saved
write/close priority, path cleanup, saved open errno, emitted Ok and emitted Err.
Each native restoration has 17 native plus one wrapper passes; each emitter
restoration has three passes. The two emitter mutants are phase C-shape proofs,
not claimed native execution. Their original patches, streams, exact restorations
and results remain in `preliminary/mutations/`; results SHA256 is
`52f4ae85f58d1137195d3063e7df2f7e50065b9cf38f74b5b7a0b1b6b0e8dff4`.
These unchanged-code proofs retain their preliminary base, rather than claiming
fresh final-stack mutants. Earlier draft syntax/numbering errors remain separate.
The final reserved-word fixture correction is exactly two `alias` tokens changed
to `kept_result`; its original parser red and actual corrected real-main green
are retained. The later three-line duplicate-Err alias extension is disclosed in
the preserved patch lineage. No failed measurement was discarded, and no cost sample was rerun.

## Fixed FEATURE cost epoch

All 3932 fresh calls ran once in an exclusive quiet window, with no build,
resampling, source change or baseline roll. Freeze SHA256 is
`85ba1bdd5db654613412b011c404780cfef05e1731e12172540fe10655fc4bcf`.
The immutable command proposal is `a91e4dc69e4b481a2b393408b2682053be2bf5725edf1008cb619cdfdade084c`,
packet pins `e382959e25f9215b0eb6d1b3f31876f1a0ea6c19a19ae3982710b16f1e4da63c`,
and invocation manifest `284b55e9b63d3a84768a792ef186654ea0e2c386775f7adcb86288c711d9362d`.

The 489 shared states retain all predecessor inputs, argv, sentinels, output
preconditions and absolute caps, with only the two recorded owned-path translations.
Three new write states have no fabricated baseline. Complete source/library maps
are 40+9 per variant, fixture files 467, generated dependencies 150. Within-variant
normal/diagnostic C and all shared raw C/status/stdout/diagnostics/output states
match exactly, including rejections and preserved outputs. Every strict target
observation has positive balanced allocation/release counts and zero leaks.

| Metric | Baseline B | Candidate C | Change / result |
| --- | ---: | ---: | --- |
| Shared allocation worst, i0011 | 12339 | 12633 | +2.382689%; all 489 pass +5% |
| Shared normal min3 worst, i0012 | 41824555 | 42275556 | +1.078316%; all 489 pass +5% |
| Fixed host FULL exit TOTAL allocations | 23467257 | 23577429 | +0.469471%; passes +5% |
| Fixed host normal min3 instructions | 20876661351 | 20956202039 | +0.381003%; passes +5% |
| New bytes allocations / min3 instructions | — | 16879 / 47803845 | absolute caps pass |
| New ownership allocations / min3 instructions | — | 21103 / 54080063 | absolute caps pass |
| New NUL-path allocations / min3 instructions | — | 12819 / 42000216 | absolute caps pass |

There are 981 strict calls, 2943 normal calls and 8 fixed-host calls. All three
collectors exit 0. Normal pair order is B1,C1,C2,B2,B3,C3, with exactly three
positive samples per variant and minimum-of-three per input. All integer +5%
and tighter absolute gates pass independently; no aggregate replaces them.
The new-only absolute limits remain 205000 allocations / 600000000 instructions.

The target-pilot producer is read-only FRESH root c04
`c04f68ba64ac06f6cd3f924cdb4d87ce6b3d40d0f8fba2ef89b20e324b21ca57`,
O0 CLI/O2 runtime, Apple Clang 21, explicit ROOTstd91. B pilot C/normal/diagnostic
are the exact safe c04 functional predecessor artifacts (cdfee314/cc347e98/caae270a).
C uses C5508fac5, normal8c219d45 and diagnostic6e2880ad, unchanged O0 links with
memory diagnostics0/1 and -lm -lpthread. Complete hashes and commands are in the
immutable proposal; no shared host or standard library was rebuilt.

The fixed FEATURE supporting pair is normal34ac1a91/diagnosticbe31a5a3 with
explicit ROOTstd91. Its allocation metric is **full exit TOTAL with memory stats
unset**, not the SOURCE artifact_construction_complete checkpoint or old host/std
epoch. Both diagnostic host calls remain **FAILED status 99**: B leaks 516598
objects/35132595 bytes; C leaks 519346/35318626. Their complete C and full leak
tables satisfy only the already documented host-bootstrap exception. Nothing is
subtracted. Normal hosts exit 0, emit exactly Generated-owned-output-LF and have
empty stderr; all six complete C files match their respective diagnostic C.
Intentional compiler-source B/C C differences are retained without normalization.

These are owned-input and fixed-host source-to-C proxies, not self-compilation.
Historical SOURCE R0/D 9959 > 9923 remains FAILED under its separately published
one-time policy; this feature does not reuse, reset or waive that denominator.

## Physical scope and evidence preservation

| Category | Added / deleted | Net | Hard ceiling |
| --- | ---: | ---: | --- |
| Production | 114 / 9 | +105 | 190 gross / +175 net |
| Tests, excluding language fixtures | 1327 / 7 | +1320 | 1350 gross / net |
| Three language fixtures | 61 / 0 | +61 | 3 fixtures / 100 lines |
| Public API docs, including final roadmap status | 31 / 2 | +29 | 40 gross |

The 1350 test cap was independently reviewed and published prospectively, before
exceeding the former 1200 estimate. No other allowance changed. Accepted HOF
production/test lines belong to the baseline. Maintained plan/status and this
benchmark report are evidence documentation, counted separately in the final
handoff; no formatting compression or coverage deletion hides growth.

Raw evidence is safely copied under coordinator
`build/bootstrap-evidence/write-file-e906-01/`: `current/` (all functional/setup,
3932 raw calls and frozen inputs), `preliminary/` (original reds/mutations) and
`linux-arm64/`. The byte-verified 25254-file copy closure is
`6bc9a3426714a6bc35d6e13ee5d7b6c0360a12fee6ed11846f17b4e77b9a0ab2`.
Post-pins `97cf6fcc5254f10d80c9fc5c0159acb5d45ebd812d17d8c4e1e1540c1825dbed`
verify 2248 packet files, 12 artifact/tool files, complete canonical516 plus owned
output, generated150, functional856 and ROOTstd91. The independent raw audit
finds no duplicate key, incomplete min3 set, unexplained output or cap failure.
`current/cost-01/SUMMARY.json` SHA256 is
`2575b36376e348d05712dcf49bffeef3486c899d150803537beaaeb92f4ae2ed`.
Original worktree packets, prototype, historical failures and frozen epochs remain
untouched. No cleanup or archival preceded preservation.
