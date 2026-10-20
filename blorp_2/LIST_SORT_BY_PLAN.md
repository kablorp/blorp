# Stable Int-key List.sort_by: architecture preview

Status: candidate API and sanitizer/native fixture checks passed; implementation
remains held and unmerged. The first shared-input instruction checkpoint rose
46.750012804%, exceeding its unchanged 10% hard ceiling; strict allocation calls
remain unrun. See the [measured result](../benchmarks/results/blorp_2_list_sort_by_2026-10-19.md).
Fixed B remains `a656f5ce1de963c8e9c162460e181d696b39c1d5`, including accepted Numeric Int.
No Float compiler/library, other held List, M3 or M7 hunks are included.
The contract below retains the original architecture and acceptance obligations;
this status update grants no further implementation or compiled calls.

## Exact required contract

Add only `pure func sort_by[T](values: List[T], key: pure (T) -> Int) -> List[T]`.
Ascending order is stable: equal keys preserve original occurrence order. Input
and aliases remain usable; returned managed elements survive temporary inputs.
Empty/singleton lists return the original value. Key is pure, may be evaluated
repeatedly, and has no exactly-once promise. No comparison via key subtraction.
The eventual host-compatible signature is generic `K:Orderable`; replace the
Int-only adapter only when generic ordering checking/library support is accepted
end to end. Put that temporary restriction/replacement condition beside the
source API and target README/parity, without claiming host/target signatures equal.
Update [GUIDE](../docs/GUIDE.md) and [GRAMMAR](../docs/GRAMMAR.md) target-subset
API crossrefs in the same feature commit, within the35-addition API-doc cap;
no grammar production changes.

Exactly three resolved uses are emit/emit.brp:2315–2317 at accepted B. They sort
ListLayout first by list_key_ordinal, then rank, then depth. runtime/list.brp:51,
74–88 declares each key function -> Int. Stability makes the final order
lexicographic (depth, rank, ordinal), keeping equal full keys adjacent for the
following deduplication and preserving the layout dependency/emission order.
ListLayout at emit:2197 contains TypeRef and ListElementKey, so managed generic
payloads must work; this is not an Int-element-only sort.
Those actual three clients currently use noncapturing pure lambdas. Library
implementation/native named-key tests need only accepted named/forwarded
callbacks; actual self-compilation still depends on accepted M7 noncapture.
The library does not wait for managed captures, M3 or source while; other
compiler-source blockers remain separate.

## Smallest sound ordinary path found

SOURCE_PREVIEW.patch is110ADD/1DEL/+109: imports IntOps/Bool, one private ordinary
MergedPrefix[T] record, three private functions, one public function. Compiler,
runtime, prelude, host and callback ABI change0. This is source data, not a
builder interface or compiler context. No callable is stored in the record.

Private MergedPrefix owns only emitted values and the two next input positions.
`merge_first` gets both current heads, evaluates left key then right key, and
chooses right only when right_key < left_key. Equality therefore chooses left.
One-sided exhaustion emits the other head without calling its key; both-empty
fallback is total but unreachable for a positive valid requested prefix.
`merge_prefix(count)` recursively produces half the output, then passes the
returned positions to produce the remaining half. It concatenates the two
balanced prefixes. This is one ordinary algorithm/state authority: no global
cursor, mutable capture, anonymous callback, fake type or synthesized source.
`sort_range` halves a source interval, sorts left then right, and merges exactly
the interval count. Public sort_by reuses empty/singleton values directly.
All recursion forwards unchanged T/key, satisfying the named finite-instance
policy documented in README.md. No tail annotation is used or promised.

Source interval invariant: 0<=start, 0<=count, start+count<=length. Positive split
counts are strictly smaller and partition the interval; start+left_count stays
within length, so Int64 index arithmetic never wraps. Merge positions advance
only after successful get; remaining output count equals remaining child values.
Each merge emits the stable left-to-right sequence independent of prefix grouping.
The full private result keeps prefix values/cursors explicit; ARC owns the managed
record/list results and releases predecessors through the existing pipeline.

runtime/list.brp:194–229 always allocates/copies for append, set and concat.
Naive insertion/set or a growing merge accumulator would copy quadratically;
head-recursive singleton concat also gives linear stack depth. Neither is used.
This balanced merge performs O(n log(n+1)) copied slots per merge and O(n) key
calls per merge, yielding O(n log(n+1)^2) copied slots and O(n log(n+1)) key calls
for the sort. Stack is O(log(n+1)); private result-record/list allocation count
is O(n log(n+1)). Element acquire/release work follows copied occurrences.
The current cheap compiler keys make repeated evaluation reasonable, not free.
No COW, linear-builder, host-cost-parity or measured performance claim is made.
A record-free binary-partition merge is possible but needs bounds/search logic
and does not clearly simplify the code or immutable copying cost. Caching keys
would add another retained element record/traversal without a current witness.
Prefer this bounded preview, or defer for a separately accepted linear builder
if actual cost is unacceptable. Do not create that facility inside this slice.

## Minimal proof and prospective bounds

Tests first: use exact seed `import:\n    list: sort_by\nfunc main() -> Int:\n    0\n`.
B must report `module list declares no public function or type sort_by`, help
`select a public function or type that list declares`, at2:11/[18,25), exit1,
stdout empty/no C. These spans/text are derived, UNOBSERVED until the genuine
RED; no setup failure counts. Freeze fixture/client/oracle bytes before calls.
Use accepted source-matched Numeric producers pinned before any native/setup
call; old1d02 A892/normal2bc cannot compile Numeric's int.less_than library.
One loaded API check verifies generic T, pure callback T->Int, List[T] result,
private helpers not exported. Exact typed negatives cover String key result and
impure compatible key from an impure caller. Preserve declaration diagnostics.
No new IR scaffold: ordinary source phases/components and native lifetime
oracles exercise existing callback erasure, generic records, Own and Verify.

One <=80-line real-main fixture: empty/singleton; odd unsorted values; records
with all equal keys and distinct labels; INT_MIN/INT_MAX/duplicate extremes;
three chained keys with equal higher-order keys; managed aliases/temporary-input
escape; generic String/record and Void elements as practical within the bound.
Use named keys, including constant key to expose stable order. Check exact bytes,
exit0/stderr0, strict compiler zero leaks and unmodified C11/O0/ASan/UBSan output.
Read generated direct calls and acquire-before-container-retirement/destruction.
Three independent source faults: reverse equality tie choice, reverse strict
comparison, reuse the initial positions for the second prefix. Each must produce
an exact real-main semantic mismatch, restore bytes/modes/semantic index, then
pass the same fixture. Setup/resource failure is not a semantic kill.

Proposed hard stops BEFORE implementation: production150ADD/+150 (preview110/1,
assess130); nonfixture tests300ADD (forecast180–240); fixture80physical lines;
API docs35ADD; canonical plan160lines; final evidence report80physical lines.
Publication approves these bounds only; code and each finite call still need
separate permission. No formatting compression/deleted coverage.
Only the new sorting fixture uses dedicated `SORT_LIMITS`: 160,000 allocations,
600M diagnostic instructions and 600M normal min3. The original 150,000 allocation
gate failed at 157,753; retain it as FAIL. All preexisting fixture and shared generic
caps stay unchanged. Full component/native gates remain.

First unchanged return/zero eight costs before expensive work. Then seven List
controls zero/literal_int/literal_empty/append_int/set_int/concat_int/entries, each
six normal B1C1B2C2B3C3 plus strict B/C at one physical full12-library/input/output/
CWD. Independently retain5% targets/10% hard for allocations and normal min3,
positive counters, strict balanced zero and exact C/status/ordinary streams.
No compiler data-model/HOST rebuild or new HOST campaign; existing HOST3% policy
remains unchanged, without a new measured pass claim. Exact unchanged CLI corpus
states remain; freeze new export/source-frontier transitions individually.
The known HOF/List declaration-cost failures are relevant warnings, not a reset
or evidence sorting fits. Stop on first hard/absolute/nonbudget failure, retain
all targets/FAILs, no retry, cap revision, baseline roll or budget offsets.
Retained Numeric producer roles and the fixed-B measurements are recorded in the
report. No new producer, baseline, cost ceiling or continued sampling is approved.

Integration merges only this list import/record/helper/API diff and docs with
then-accepted List work. Every composition is reviewed without rolling B.
No source migration, compiler model, trait/closure ABI, FFI, runtime primitive
or benchmark framework is in scope. Candidate implementation remains held;
all remaining calls and feature acceptance are ungranted.
