# Ordinary List membership — 2026-10-19

Candidate: generic pure `contains_with(values, needle, equals)` plus a temporary
Int `contains` adapter;28 ADD/1 DEL in target `list.brp`, compiler/runtime unchanged.
The callback receives element then needle and stops at the first match. Indexed
recursion does O(n) work with linear C stack at O0 and ordinary temporary ARC.
Generic equality traits, captured predicates and bounded-stack loops are separate.

Original fixed B: `5b5985ffc385c89541dee2d997c2d3c0ad53f65b`, compiler41/full12
libraries, archived host974/STD91, target normal2bc1d69e/diagnostic892c24a1,
shared C76f0d23d. All original64 control calls and C-only4 remain retained.
A separate accepted-main70060 interaction reuses Result compiler41, normal
a0ee7632/diagnostic05266301/shared C98939c7b, hostfbb/currentSTD91; only List
changes B/C. This is additional composition evidence, not a baseline roll.

Original counts; instructions are normal min3, with all raw samples retained:

| Input | B→C allocations | B→C instructions |
| --- | ---: | ---: |
| return/zero |10396→13838|37618525→42073886|
| list/zero |13308→16819|41702027→46326319|
| list/literal_int |16369→19884|46090183→50778042|
| list/literal_empty |16457→19972|46307265→51044021|
| list/append_int |19831→23275|50424688→55013670|
| list/set_int |22712→26157|54064977→58621713|
| list/concat_int |21345→24859|52238858→56911189|
| list/entries |20169→23612|51085355→55634694|

Current returnzero:15093→18534 allocations (+22.798648%) and43653133→48100504
instructions (+10.187977%). Every input misses the retained +5% targets. Original
returnzero also missed the old +10% hard bounds (+33.108888%/+11.843529%).
At the old +10% bound,8 allocation and4 instruction control rows failed.
All original failures remain FAIL; no retries, resampling or cost offsets occurred.

Human call5579 approved prospective per-input allocation hard
`min(floor(134*B/100), B+3600)` and instruction hard
`min(floor(9*B/8), B+5000000)` for the fixed8 and separate currentreturnzero.
Original8 also adopt the exact named current/amended absolute fields. Current
native changes are only45 existing allocation fields +3600,33 instruction fields
+8M, and Contains45000→52000 allocations (instructions stay200M). HOST/SOURCE/M3/
Sort bounds and every other field stay unchanged; no HOST measurement is claimed.

Direct original-role phase observations: Load+1477 and Check+1965 allocations;
Specialize/Lower/Own/Verify/Emit unchanged. Their sum is3442, but driver boundaries
prevent an exact EXIT TOTAL decomposition; no instruction-phase attribution exists.
Do not distort the ordinary library design to hide the measured checking cost.

Original native:604 semantic PASS,406 cost rows,55 allocation and0 instruction
misses. Pre-amendment current native:643 semantic PASS/416 rows,55 allocation and
38 instruction misses (overlapping); allocation-first reporting prints55 stderr
lines. These are distinct producer/source boundaries and both failures survive.

Post-approval current gates:3632 components and1151 native markers PASS, comprising
507 outer callbacks,643 semantic children and one umbrella;416 positive cost rows
pass every governing absolute. Compiler strict totals/leaks and real-main sanitizer
checks use the maintained harness; its temporary child reports are consumed.
Two restored source faults prove exhausted-input False and comparator argument
order using exact77/84-byte wrong output; the restored fixture produces84 bytes.
The Check owner has36 PASS. Original C-only46748>45000 and current51372>45000 remain historical failures.
Current fixture uses51372 allocations; normal samples
100335019/91579895/92330536 give91579895 min3<200M; all three C files equalf4ba51d4.
Generated C is unchanged from the reviewed ordinary direct-callback/ARC witness.

Identity closure PASS:1006 public normal CLI calls cover503 byte versions,
retaining original498 and current502 shared paths, replacing the unrun996 recipe.
All503 pairs match exact status/streams/C presence/bytes/mode:407 emit C,96 reject
with no C. Historical comment calls991/992 are retained; the current502 tree and
fullC12 restore exactly. These matched states are not503 accepted program roots.
The separate plain-main probe now stops at missing `list.join`, emit/emit.brp:28:8;
exit1, stdout0, no C. This is frontier progress, not self-compilation/fixpoint.

Evidence: `build/bootstrap-evidence/list-contains-2026-10-19/`: original early-control,
remaining-archive-alias, phase-attribution, current-main-readiness; human decision
in resource-amendment-proposal02/HUMAN_APPROVAL.md; applied registry8e561260;
final16 aggregate21928398, current gates87d5d439 and identity f770907b. Earlier classifier
STOPs remain beside DATA-only corrections; no test rerun earned those corrections.
Root and independent code/test reviews are complete; integration is pending.
