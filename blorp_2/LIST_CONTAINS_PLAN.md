# Supplied-equality List membership in ordinary Blorp

## Decision and scope

This revision replaces the native builtin design at root's/user's direction.
The earlier published plan remains in Git history; it is not implementation or
performance evidence. Root and an independent peer review/publish this revision
before a separate implementation grant. No compiled job follows plan approval.
Fixed B remains accepted `5b5985ffc385c89541dee2d997c2d3c0ad53f65b`;
its 41 compiler sources and target library equal the docs-only plan base.

Current main parses all 41 sources; A's source probe rejects `list: contains`
at verify/verify.brp:8:8. There are two current calls, levels:List[Int] at
lex/lex.brp:1156 and seen:List[Int] at verify/verify.brp:1080. Retain both calls.
Add permanent useful generic supplied-equality contains_with and a concrete Int
compatibility adapter contains. The temporary restriction is the Int adapter
and the indexed recursive implementation, not the generic supplied-equality API.
A unary predicate API is any; it would require captured needles at these calls.
Named binary equality avoids captures. Lambdas, traits and source loops stay out.

Production changes only standard_library/list.brp. Keep every old API and add
Bool(True, False) to its existing _base import plus `int as IntOps`.
The prelude already offers List methods; no prelude or host library change.
No compiler, builtin tag/contract, RuntimeType/Operation, runtime C, Lower/Own/
Verify/Emit, generic inference or callback-tail admission changes are permitted.

## Exact ordinary implementation

```blorp
pure func contains_with[A](values: List[A], needle: A, equals: pure (A, A) -> Bool) -> Bool:
    contains_from(values, needle, equals, 0)

private pure func contains_from[A](values: List[A], needle: A, equals: pure (A, A) -> Bool, index: Int) -> Bool:
    match get(values, index):
        None: False
        Some(element):
            match equals(element, needle):
                True: True
                False: contains_from(values, needle, equals, IntOps.add(index, 1))

pure func contains(values: List[Int], needle: Int) -> Bool:
    contains_with(values, needle, IntOps.equals)
```

Style may wrap signatures normally; physical budgets include that formatting.
Arguments evaluate once in written order. Each existing element is compared at
most once, in order; empty returns False, first True stops, exhausting returns
False. get validates the index before increment: index starts0 and the final
increment is at most length, hence at most INT64_MAX. The callback receives
borrowed values under existing contracts; get/Some/payloads incur ordinary ARC.
Use no slice/take/drop, unsupported if/while, fake callback or hidden builtin.

This is ordinary recursion: O(n) work and linear C stack at -O0. No bounded-stack,
zero-allocation, zero-ARC or 65k-list guarantee is claimed. Test a modest64-element
repeat and document this implementation limit. Annotation is not a fix: current
Check rejects generic/callable @tail_recursive headers, and Own rejects managed
source-tail state. Source-loop/callback-tail/capture work remains separate.

## Bounds, tests first and gates

Forecast production28 ADD/1 DEL/+27 in one target module, hard40 ADD/+40 net.
Tests hard500 ADD/+500 net; one real-main fixture <=60 physical lines;
API docs <=45 ADD, this plan <=140 physical lines, final report <=80 lines.
Preserve all old assertions and readable formatting; stop before any bound.
Update target README, parity's stale third-site/M3 dependency, scoped README and
narrow GUIDE/GRAMMAR API references; no new language syntax or general cleanup.

Root observed the exact private visitor/public forwarding shape GREEN on
unchanged A892c24a1: normal CLI compile, unmodified C11-O0 link and real main all
exited0 with empty stdout/stderr; all144 precompile pins matched.
Evidence: `build/bootstrap-evidence/list-contains-2026-10-19/source-prototype01/`.
This is correctness evidence, not a measurement.
Do not repeat that prototype. Before adding library helpers, compile the new
real-main fixture on B: exact missing-export message/help/source span, exit1,
empty stdout and no C. Only after observed API RED may library code be written.

Use existing test_check/test_generics and e2e/test_lists owners/public helpers.
Test actual API calls with named/imported predicates and exact wrong arity,
input/result/purity diagnostics (kind/help/span), retaining all old assertions.
Normal-main positives cover generic Int/String/managed values and supplied
asymmetric equality. Full existing ownership/verification/sanitizer gates protect
unchanged compiler algorithms; do not add malformed ownership IR, a callback-
count visitor, six-phase scaffolding or mirror helper implementation structure.
Add a focused phase assertion only for a necessary new fact. This pure API's
runtime call count is not claimed observable through output or a typed-tree count.

One normal fixture contains Int signed extrema/wide values, String UTF8/NUL,
managed record equality using a named callback, supplied custom equality,
empty/miss/first+last hits, aliases, a one-print eager needle and64-element repeat.
Freeze exact exit0/stdout/stderr before RED. New-only compile caps remain45000
allocations/200M diagnostic instructions AND200M normal min3. No successful B
is invented. Original caps/strict0/C11-O0/ASan/UBSan/required counters remain.
Prove two meaningful library oracles with separately restored source faults:
return True for exhausted/missing input, and reverse equals(element,needle).
An asymmetric supplied comparator must distinguish the latter from the correct
argument order; empty/miss output must distinguish the former. Freeze minimal
patches and required named semantic FAILs before leases. Setup/resource failure
is not a kill. Restore exact bytes/modes/pins and semantic index before
classification, then same-owner GREEN. No compiler-drop mutation/private hook.

After focused GREEN, run whole components/runtime/grammar and full native once
with unchanged real mains and harness. Reuse exact source-matched A for native;
compiler source is unchanged, so no fresh host generation or relink is required.
Read ordinary CLI fixture C for direct calls, forwarding and ARC. Run one actual
source frontier; the next missing helper is not self-compilation/fixpoint proof.

## Fixed costs and output identity

C is only the complete B target library plus these helpers, tests and docs.
Reuse verified A892c24a1 with source41/library12, retained generated C, toolchain,
flags/modes and ROOT974/STD91 provenance checked before/after. ROOT974 remains
immutable FRESH; no host rebuild/install or gratuitous HOST cost campaign.
The original supporting HOST+3% ceiling is preserved, but source/C/binary bytes
are unchanged and this slice claims no new host performance measurement.

Freeze the eight unchanged target controls: return/zero.brp; list/zero.brp;
list/literal_int.brp; list/literal_empty.brp; list/append_int.brp;
list/set_int.brp; list/concat_int.brp; list/entries.brp, under e2e/fixtures.
Each independently retains +5% allocation/normal-min3 targets, +10% hard ceilings
and all tighter old absolutes. Eight original samples per control: normal
B1,C1,B2,C2,B3,C3, then diagnostic B/C (64 total); positive counters, full EXIT
TOTAL, strict balanced0, within-role and B/C exact target C identity. Report each
5% miss, stop at first10%/absolute or semantic/accounting/provenance failure.
New fixture: one diagnostic plus three normal samples against its absolute caps.
Switch complete libraries only in one owned active physical path with the same
source/output/CWD/argv. No successful new-input B, resampling or baseline roll.

All498 unchanged current file inputs get one normal B/C identity pair (996 calls):
exact status/stdout/stderr/C/output-presence, including rejected/no-C states.
No claim of relative sampling all498. Existing finite command protocols own
execution; freeze literal commands/inputs/states and review before each lease.
Retain every old failure and native-plan draft. Stop for scope, stack, semantic,
setup, identity, provenance or hard-cost breach, restore C/faults and RETURN.
Two final independent code/test-runner reviews precede root-only integration.
