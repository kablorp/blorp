# Ordinary generic List callback helpers

Status: reviewed implementation contract; code and measurements are pending.
Root and independent architecture review approved this boundary. Publication
precedes a separate tests-first implementation grant and every compiled lease.
Fixed accepted B:1d02a670027ee05c2e18e0d19cbd22ac64ad23e4, selected by root.
Later documentation-only publications do not roll this B or add a held candidate.
Contains' +33.108888% allocation/+11.843529% instruction hard FAIL stays unchanged.

## API and accepted prerequisites

Add only target List.any[T](List[T], pure(T)->Bool)->Bool,
map[T,U](List[T], pure(T)->U)->List[U], and
filter[T](List[T], pure(T)->Bool)->List[T]. Fresh resolved demand is12/20/1 sites.
These are generic APIs, not concrete adapters. Their definitions use accepted
named/forwarded callbacks, get/length/concat and Int add/subtract/divide. No
lambda/capture machinery, source loop, tail annotation, M3 path, compiler model,
builtin/native callback ABI, prelude or host-library change. Some compiler clients
still require M7 lambda/capture support and explicit operation import closure.

Private helpers take an input, callback and valid start/count range. Public
wrappers supply0/length. Empty range returns False/[]; singleton uses get then
callback; larger ranges split count in half using Int.divide(count,2). Process
left before right. any returns immediately after a True left half; map/filter
concat left and right results. Filter preserves input order. Every nonempty
private subrange remains within the original List, with no overflowing index.
The reviewed source preview is84 lines/six functions, including a source comment
explaining unconditional copies and the temporary complexity tradeoff. Its lines
are charged normally against the110ADD ceiling.
No reusable traversal, callback carrier or alternate compiler execution path.

```blorp
pure func map[T, U](values: List[T], callback: pure (T) -> U) -> List[U]:
    map_range(values, callback, 0, length(values))
```

Each range helper is an ordinary recursive function with the unchanged named
choice forwarded to its children. Independent T/U remain rigid and no callback
is stored/returned. Bool/Option are imported from the existing _base owners.
No annotated callback recursion is assumed. A tiny normal-main prototype must
confirm this exact count-split/named-forwarding shape before library production.

## Algorithm choice and explicit temporary cost

Current runtime/list.brp:194-207 unconditionally allocates/copies append's prior
slots; there is no COW uniqueness fast path. A recursive growing accumulator
would therefore copy n(n-1)/2 slots for map, with linear O0 stack. Returning
singleton.concat(rest) has the same asymptotic copying problem. Do not silently
choose either or claim that last-use analysis makes append in-place.

The selected balanced traversal uses only existing concat. It copies O(n log n)
slots in the worst case, with O(log n) recursive C stack; output allocations,
managed acquisitions and empty intermediate roots still cost work. any performs
O(n) leaf checks in its worst case and uses O(log n) stack. These are algorithm
bounds, not a measured performance win or constant-stack/zero-allocation claim.
No arbitrary large-list safety threshold is promised. Fixture sizes stay small;
record actual C/runtime evidence before any wider stress claim. Replacement
condition: an accepted efficient builder/loop path with matching semantics and
measured evidence, not a runtime/COW optimization smuggled into this slice.

## Tests first and proportional oracles

Preview list_callbacks.brp is76 lines with exact EXPECTED_STDOUT.bin. It covers
empty/first/last/miss any, stable map/filter order, direct/UFCS/forwarded named
callbacks, distinct T/U, Int/String/Void/record values, mortal UTF8/NUL payloads,
alias survival, temporary record-parent escape and one printed eager input.
Use existing e2e/test_generics.suite/run_output_example and LIMITS150000/600M.
Real main exit0, exact stdout, stderr0, unchanged O0/C11/ASan/UBSan/strict-zero.
Before production, its old-library import must fail at any bytes18..21 with
`module list declares no public function or type any`, help
`select a public function or type that list declares`, no C. Setup failure is
not RED. Prototype GREEN is separate from the missing-export RED and metrics.

Owning tests use the actual loaded target module, not copied helper definitions.
Check all three Pure signatures, genuine type-parameter/union identities and
independent map result type. Exact kind/message/help/source/span/no-note negatives
cover wrong List/callback input, wrong predicate result, impure named callbacks
and written arity. Reuse current named-callable diagnostics and existing phase
helpers. One typed short-circuit oracle follows actual any/any_range identities:
its True-left arm contains no right recursion/callback. Native pure callbacks
cannot demonstrate dynamic callback count/order through side effects; do not
claim that typed invocation counts or exact output do so. Map/filter output
order and skipped/retained values are directly observable in the fixture.
No new malformed ownership IR scaffolding or compiler source fault is needed.
Existing full ownership/verifier/runtime gates remain mandatory.

Three individually restored target-only faults: empty-any False->True;
map concat(left,right)->concat(right,left); filter True/False leaf selection
reversed. Freeze exact well-typed bytes/named native failures before execution.
Each requires actual output failure, byte/mode/index restoration and same owner
GREEN; setup/resource failures are not kills. Inspect unmodified generated C
for direct callback targets, recursive calls, concat copies and managed cleanup.

## Fixed costs, corpus and finite acceptance

Compiler41 is unchanged. Reuse a fully source/C/tool/STD-matched normal0 and
diagnostic1 producer; no host regeneration or HOST metric campaign. Existing
HOST3% ceiling is retained, with no new host performance claim. Root freezes
actual accepted B/full-library C and complete original source/input provenance.
Use one physical active library/input/output/CWD with complete12-member payloads.
Early return/zero control gets exactly8 samples before extended test investment:
normal B1,C1,B2,C2,B3,C3, then strict diagnostic B/C. Full EXIT TOTAL allocations
and normal min3 independently retain5% targets/10% hard and tighter old absolutes.
Stop on first hard/absolute, setup, semantics, identity, accounting or pin failure.
No resampling, B roll, relaxed cap, cross-metric offset or cost-only runtime edit.

If early control passes, the unchanged shared controls are list/zero,
list/literal_int, list/literal_empty, list/append_int, list/set_int,
list/concat_int and list/entries, plus the already measured return/zero. Eight
original samples each, never repeat a successful original set. New fixture gets
one strict diagnostic and3 normal samples under its absolute150k/600M limits;
no successful B denominator. Record measured allocations/instructions separately
from theoretical copied-slot bounds. All frozen existing CLI inputs retain
exact status/streams/C-or-no-C states, and all existing native caps remain.
Full components/runtime/grammar, one full native umbrella and an actual frontier
are required. Disclose expected new-export/frontier transitions before execution.
Freeze literal commands/pins/oracles and finite leases with root before START.

## Physical forecast and stops

Production preview87ADD/1DEL/+86, target list only; assess95ADD/+95, hard110/+110.
Nonfixture tests forecast200-240ADD, assess250, hard300; one fixture hard80lines.
API docs hard45ADD, this plan hard140lines, eventual measurement report hard80.
Do not compress formatting or delete coverage to fit. Merge overlapping imports
and helper additions semantically; do not replace another worker's List file.
Every current-main composition requires review without rolling the fixed cost B.
No source/body migration, framework, build/install, commit or push is authorized.
Two independent final code/test-runner reviews precede root integration.
