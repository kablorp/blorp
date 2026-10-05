# Matched Cursor pilot measurements

Current baseline input 06f4a18da9aae41f767d6dd56865c67693500080, archived before
production edits, same frozen input path and candidate worktree cwd for every
baseline/candidate run. Three normal instruction samples and one diagnostic
allocation process each, through emitted C only. Host inventory quiet before
measurements; coordinator sole slot, harness lock itself is passthrough.
Archived source.brp remains SHA f9dbd39bd1805311f5f3b13eb1f4cea5c1ff8f56725c719297421b3d27f5b470,
byte-hash identical to Git06 source. The candidate implementation hash below
is distinct and never substituted into the frozen benchmark input.

Self allocations 271,597,490 -> 233,762,850, saving 37,834,640 (-13.9304%).
Typed frontend phase -151,098; Core lowering phase -37,683,542; every other
phase allocation delta zero. Instructions minimum 231,999,385,548 ->
212,987,194,147 (-8.1949%). Candidate samples 213,436,682,569 /
213,356,508,760 / 212,987,194,147. Self C 77,337,791 bytes identical,
SHA 86a0e602be71622012bffada0ea7340e13dd6615c65f512b80ab880e8cd13ea0.

Small allocations 2,131,517 -> 1,693,224, saving 438,293 (-20.5625%), entirely
Core lowering. Instructions minimum 1,770,318,221 -> 1,555,287,529 (-12.1464%).
Candidate samples 1,556,515,509 / 1,556,675,092 / 1,555,287,529. Small C 39,575
bytes identical, SHA 3f4e7cf0fbabc5459ba7802a4fc5cb69a20d0699e4c19991f19dcf374cce4abe.

All baseline/candidate normal/diagnostic sample outputs matched within and
across pairs. Both candidate recorders exit 0, source_changed_during_run=false.
Raw baseline-{self,small}.json and candidate-{self,small}.json, C outputs and
their recorder packets are retained in this directory. The workspace census
270,348,690 is a different input/boundary and never used in this subtraction.
No wall-clock or instrumented-census performance claim is made.

Candidate FRESH installed generator fb3dec235569db01ffd62da34e6e9d417350047babdf4e5150f1cf0ed5dbd6f5.
Candidate stage2 normal 93d8ca70238d3fea1a67890c33ca2b9e8e1b378b2961269953517df5617f391c;
diagnostic bc095c408e9630b5aec259022f39f4357a74b334162b605b219e3a67cef43cef.
Same candidate source body C d48f3b23bf737096b63824f236fe145d28c1c40c9cc9fbf3121b91855dbb8bfe.
Normal/diagnostic runtime objects 17dfa45eb223216e295d294304fdba662e7d3ff1e593ceab283efc202b115957 /
3442491ce67875efe3f8850d9fd98aa32526f7bd0858352d0f0412750aff1220 unchanged.
Apple clang 21.0.0, CLI/runtime O2, split 8, modes 0/1, bootstrap dev-8228a8fa12e3.
Expected stage2 self stamp 681 -> 06 difference documented; no mismatch override.
External scratch compiler_stage 1/rootless metadata is the harness invocation
limitation, not a false claim that these exact stage2 binaries are stage1.

Source scalar scanner 447a42e9832277e9fdd3c7044690012deb198e8605725d95702b3842b647ad89;
test 88453217e7400b98ab6da4f5a02f4432197c5879deb71d336279ef15b178ada6.
O2 make and paired build recorders both exit 0/source_changed=false. Main read-only
control remains clean 06. Correctness verdict PASS: 10,001 integration checks,
17 owning ASan+UBSan/leak tests, two dynamic-child temporary ASan+UBSan/leak
tests, full O2 quality and reused-stage2/stage3 fixpoint. Every final recorder
completed exit 0/source_changed=false. Fixpoint emitted C all has workspace
candidate-body SHA d48f3b23bf737096b63824f236fe145d28c1c40c9cc9fbf3121b91855dbb8bfe;
this is distinct from frozen old06 input self output SHA86a0e602... by design.
Code review APPROVE; test-runner PASS; recommend ACCEPT bounded Cursor pilot.
Wider S5 remains open. No source edits, commits or pushes by this reviewer.
