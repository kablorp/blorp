# Compiler-source interpolation pilot

This bounded batch replaces 64 fixed String constructions in `main.brp` and
`check/render.brp` with quoted interpolation. It preserves diagnostic wording,
escaped LF bytes, String expressions, explicit numeric conversions and their
written evaluation order. The source edit changes no helpers, models, tests,
libraries, emitter, launcher or Make logic. The landing also pins the published
interpolation-capable Blorp 2 seed described below.

For example, the main headline changes from
`": error: ".concat(diagnostic.message).concat("\nhelp: ").concat(diagnostic.help)`
to `": error: ${diagnostic.message}\nhelp: ${diagnostic.help}"`. A diagnostic
such as `"constant '".concat(name).concat("' cannot be called")` becomes
`"constant '${name}' cannot be called"`. The whole sentence is now visible
without reading through repeated calls.

Production physical lines are +57/-84, net **−27**. Tests are unchanged.
The isolated pilot source was frozen at base `6ef8b68296ee70e63fcee18b7cedce23e1720b48` plus
these two-file edits; the exact 64 original/replacement pairs are retained.

## Matched cost and identity

The baseline source and library were frozen before edits. Root's qualified
local stage B matches that base's compiler inputs and generated C; it was
explicitly used to compile the isolated migrated source. Each role's normal
and diagnostic binaries share that role's C and are linked by the existing
Make recipes at `-O0` with memory diagnostics 0/1. This is an
explicit local experiment, not a published seed.

Both roles compiled the same frozen 6ef source/library with the same captured
environment. Strict allocation runs and six interleaved normal runs
(baseline, candidate, candidate, baseline, baseline, candidate) retained full
source, role, tool and driver guards. Actual macOS `/usr/bin/time -l` counters
are reported as minima of three samples.

| Whole frozen-input compiler cost | Baseline | Migrated | Change |
| --- | ---: | ---: | ---: |
| Allocations | 31,123,934 | 31,123,934 | 0% |
| Minimum retired instructions | 920,159,442,362 | 920,057,429,260 | −0.011% |

The instruction ranges overlap; this is no speedup claim. Both strict reports
release all allocations with zero leaked bytes. The prospective +3% allocation
and instruction ceilings passed. Every one of the eight outputs is the same
19,131,451 C bytes, SHA-256
`18de404e94f2f10be33031ddcd246b1b867296fead0942d2755fc124781988d9`.

The isolated migrated compiler also compiled its own frozen source, reproducing exactly
its 19 MB generated compiler C, SHA-256
`2af58370ccc2058507272fb389d0621910799c7bf352be5de016ea6aff07b138`,
with 31,108,474 allocations/releases and zero leaks. This uses different input
from the matched table above and is recorded separately.

## Validation and integrated qualification

Existing exact diagnostic/main suites passed 23/23 before the pilot, after its
three conversions and after the full batch, with byte-identical stdout and
empty stderr. Independent code review approved all 64 conversions with no
findings, reconstructing both files from the frozen originals and edit list.

The ordinary 581-fixture CLI parity check passed: 486 successful compilations
and 95 located rejections with help. Baseline/candidate exit, stdout, stderr,
C presence and C bytes all match, with no crashes or internal errors. Full host components passed 4,347/4,347, and native components passed 188/188
across 27 unchanged suite sources with complete balanced zero-leak reports.
The full real-main e2e suite passed all 584 aggregate cases, 1,371 raw PASS
rows and zero failures. The interpolation suite and each fixture cost appear
once. All 117 allocation-debt FAIL markers are retained with unchanged limits
under the accepted policy. Broad instruction checking is disabled, so broad
instructions are unmeasured; this is not an instruction PASS. Every gate
retained complete before/after source, tool, role and environment guards.

The original pinned seed `1686659309e5` predates interpolation and blocked the
unchanged authoritative proof. That dependency is now resolved by the published
[seed a4ab4b163756](https://github.com/kablorp/blorp/releases/tag/blorp2-seed-a4ab4b163756),
whose source is `a4ab4b16375674f008c98328d9206a64a8ce5b52` and compiler C is
`18de404e94f2f10be33031ddcd246b1b867296fead0942d2755fc124781988d9`.
All eight published assets and seven checksum rows were verified, including
all three platform binaries and their retained qualification provenance. The
pin records the exact three binary digests. The release API reports
`immutable=false`; checksum enforcement and the never-overwrite policy do not
constitute server-enforced release immutability.

A clean managed checkout at accepted E1 parent
`e515d85690baff3b09e4479224256dca968c0946`, with only the new pin applied, ran the
unmodified default Make compiler target from an empty seed cache. It downloaded
and verified the macOS seed, generated canonical E1 compiler C `2188ad20…`, and
linked successfully. No legacy executable or compiler build existed in that
checkout, and no legacy host or build command was invoked.

Final local qualification composes the unchanged source packet with E1 and the
new pin. The unmodified authoritative proof emits identical seed/A/B/C compiler
C: 19,135,150 bytes, SHA-256
`aea7b5ba3bc4819a02cc36aad7b857a22df92f13719b45d3376c1062c24af9ad`.
All 581 fixture contracts pass and are byte-identical to accepted E1, including
the 95 located rejections. Stage B passes all 584 native cases; its complete
1,371-PASS log is also byte-identical to E1, including the same 117 allocation
debt records and unchanged limits. Broad instructions remain unmeasured.

The complete component gate passes 4,537 callbacks (4,349 hosted plus 188 under
actual self-built stage B), with 27 positive balanced strict target reports.
The existing fake-bootstrap shell gate passes all 24 checks. Ordinary stage B
and its ASan/UBSan image each compile the whole current source with 31,113,911
allocations and releases, zero leaks, empty stdout and no other diagnostics;
both reproduce the canonical C above. All input guards match. This current-source
workload is separate from the isolated frozen-input cost table. Two independent
final reviews bind the complete source, pin, report and raw evidence.

## Skips and problem log

No compiler bug, unsupported selected template or host TestSuite incompatibility
has been observed. The run stops at 64 useful conversions. The 53 remaining
concat call lines in the two files include Lists, incremental builders, simple
additions and unselected fixed templates; they are not 53 proven migration
problems. Four deferral groups remain unchanged: List/incremental construction,
the nested empty-String `append_int` location idiom, the next Emit inventory,
and further diagnostic templates beyond this batch. No issue was fixed by
expanding interpolation or adding a helper.

An extra cross-cwd receipt comparison against Root's archived e2e marker
values failed: 109 counts differ by +24 and eight by +12, with unchanged
limits. That comparison is retained and excluded from matched cost claims;
path-normalization context is the apparent cause, without a narrow cause
proof. The same-cwd matched runs above remain the resource oracle.

A setup-only linking orchestration error briefly overlapped three initial
commands. Those receipts are retained, and all three roles were linked again
serially before qualification or resource samples. No cost sample was discarded.

The continuously maintained log is ignored
`build/interpolation-source-migration-2026-10-21/worker/PROBLEMS.md`. Each entry records
its category, location, original/proposed form, command or static deferral,
evidence, skip reason and smallest follow-up. The same evidence directory holds
`PLAN.json`, `CHANGES.json`, `SOURCE_REVIEW.json`, `baseline-source.tar`,
`ROLES.json`, generation/self-compile receipts, `measurement/` raw samples and
independent reviews, all preserved with exact membership, bytes and modes. The
published release verification is under
`build/string-seed-rotation-2026-10-22/release/`. The clean seed-only build and
final composed proof, archived fixture contracts, components, strict/sanitizer
runs, exact final packet and reviews are under
`build/string-integration-2026-10-22/`. The temporary legacy TestSuite observer
is still used for untranslated hosted suites; production compiler construction
uses only the pinned Blorp 2 seed and C toolchain.
