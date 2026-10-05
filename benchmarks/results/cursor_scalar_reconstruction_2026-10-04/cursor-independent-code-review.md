# Cursor scalar reconstruction review

Verdict: APPROVE. Blockers: 0. Should-fix: 0. Performance acceptance pending.

Production diff: source.brp +43/-21; only two reconstruction-loop consumers,
one private four-parameter scanner, shared four-column tab formula, and three
stale representation comments. Scalar locals preserve the existing byte-wise
newline/tab/default transitions. Both callers clamp the target and supply a
valid start offset/line; indexed binary search and public record API are intact.
No return record stores the borrowed text. No ownership pass/runtime change.

Ordinary owning suite: 17/17 pass, recorder cursor-candidate-fast exit0 and
source_changed_during_run=false. The new allocation contracts are exact 1/3/3;
the exhaustive oracle independently uses unchanged source_advance over negative,
clamped, EOF, empty, tabs, newlines, CR, NUL and UTF-8 byte offsets.

Fresh-temporary scratch proof: cursor-temporary-sanitize-packet-v2 passes 2/2
with ASan+UBSan and leak checking, zero leaked bytes. The literal SourceFile and
unindexed SourceTable constructor temporaries do not outlive the borrowed call.
The stronger cursor-temporary-sanitize-dynamic packet repeats both with text
constructed by runtime Int.to_string plus a tab/newline suffix: 2/2 pass,
zero leaked bytes, exit 0 and source_changed_during_run=false. This exercises
owned dynamic child text rather than only immortal static literals.

Full candidate C SHA d48f3b23bf737096b63824f236fe145d28c1c40c9cc9fbf3121b91855dbb8bfe.
Scanner brp_7fc at lines320594-320638 owns three long locals, uses stack OptionChar,
contains zero record-maker/retain/release calls inside its loop, and calls the
Cursor maker exactly once after the loop. Direct wrapper brp_7fe borrows parent
text for its tail call without releasing parent. Indexed source_table wrapper
loads text at320452 then calls scanner; retained SourceFile is released only
after completion (320477-320479). None branch similarly calls the unindexed
wrapper before parent release. Exact C excerpts are retained separately.

Setup failures are not acceptance: compiling the module directly had no main;
the first scratch import traversed a dot component; the scratch main initially
had wrong signature/arity; first scratch TestSuite used name instead of
description. Corrected scratch probes do not modify production sources.

Approved proportional integration gates: cursor-broad-gates passes 10,001/10,001
(compiler-blorp 6,394; compiler-new-parity 3,425; CLI 146; LSP 36), exit 0 and
source_changed_during_run=false. Parity log retains existing known divergences
and diagnostic differences; mismatched_files=0. Owning Source suite ASan+UBSan
and leak packet cursor-source-sanitize passes 17/17 with zero leaked bytes.
Full O2 quality passes, recorder cursor-quality exit 0/source_changed=false.
The subsequently corrected lossless version-output packaging has independently
passing manifest, gzip/raw-byte, local-link and staged whitespace checks; no
full quality repeat is necessary for that evidence-only packaging correction.

Fixpoint passes using the already measured stage2 candidate: one stage3 native
build then stage3 emission, all maintained repository recipes. Stage1-emitted
candidate-stage2-main.c, stage2-emitted fixpoint-stage2-output.c and stage3-emitted
fixpoint-stage3-output.c are each 75,403,731 bytes, identical SHA
d48f3b23bf737096b63824f236fe145d28c1c40c9cc9fbf3121b91855dbb8bfe. Compare exit 0.
Stage3 binary SHA 5d6363319a957a7fcbd4bfefd72f766db38593345e860ddb3f968309767ada63.
Build, emission and compare recorders each exit 0/source_changed=false. Main
end control remains clean06. All jobs completed; sole compiled slot released.

Final separate verdicts: CODE REVIEW APPROVE (0 blockers, 0 should-fix),
TEST-RUNNER PASS, PERFORMANCE ACCEPT for this bounded source-owned pilot.
Matched self/small allocations and instructions materially decrease while
all C samples remain identical. No latency/RSS/general S5 closure claim.
