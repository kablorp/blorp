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

Root's private visitor/public forwarding proof (correctness, not cost) was GREEN on
unchanged A892c24a1: normal CLI compile, unmodified C11-O0 link and real main all
exited0 with empty stdout/stderr; all144 precompile pins matched.
Evidence: `build/bootstrap-evidence/list-contains-2026-10-19/source-prototype01/`.
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
Freeze exact exit0/stdout/stderr before RED. New-only compile caps become52000
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

Original B and source41/library12 use archived ROOT974/STD91 and retained
normal2bc1d69e/diagnostic892c24a1/shared C76f0d23d; no host rebuild occurs.
The separate main70060 interaction uses current hostfbb/STD91 and accepted Result
normala0ee7632/diagnostic05266301/C98939c7b, with compiler41 unchanged B/C.
HOST+3% stays; no HOST claim or SOURCE/M3/Sort allowance is transferred.

Eight original controls are return/zero.brp; list/zero.brp; list/literal_int.brp;
list/literal_empty.brp; list/append_int.brp; list/set_int.brp;
list/concat_int.brp; list/entries.brp, under e2e/fixtures. Retain +5% targets.
Hard allocations are min(1.34*B, B+3600); normal-min3 instructions are
min(1.125*B, B+5000000), independently for each fixed input/metric.
These same bounds also cover the separate fixed70060 returnzero interaction.
Original eight prospectively adopt the named absolute fields in the amendment.
Only listed native fields change; all others and the new fixture's 200M remain. See the
[measurement report](../benchmarks/results/blorp_2_list_contains_2026-10-19.md).
Preserve original64 and current70060eight: positive full EXIT TOTAL balanced0,
normal-min3 and eight-way C identity. All original FAILs stay FAIL; no reselection.
New fixture: one strict plus normal3,52k/200M; no successful B denominator.
Use one physical full-library/input/output/CWD per comparison; no baseline roll.

Preserve all498 original file versions plus current502 shared files:503 distinct
versions need1006 normal B/C identity calls, prospectively replacing unrun996.
Check exact status/stdout/stderr/C/output-presence, including rejected/no-C states.
No relative-sampling claim: freeze/review future commands and version details first.
Retain every old failure and native-plan draft. Stop for scope, stack, semantic,
setup, identity, provenance or hard-cost breach, restore C/faults and RETURN.
Two final independent code/test-runner reviews precede root-only integration.

Cost-stop exception: after review, root may grant remaining planned finite correctness/cost calls once.
Keep B, semantics, amended limits and original samples/FAILs; no retries, resampling or merge.
Relative/absolute budget misses stay FAIL; the unchanged native umbrella may finish/report all fixed fields.
All non-budget failures still stop immediately; data serves only a bounded proposal, never budget acceptance.
