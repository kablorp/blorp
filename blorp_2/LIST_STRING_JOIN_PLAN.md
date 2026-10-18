# Concrete target List[String].join

Status: implementation plan, not an implemented API or an acceptance result.
Root and an independent compiler/test reviewer approved the ignored design proposal
`d9e8a94522c86b9b33b9020865d4eb2f9698d917818a5528d5967bd6df657c3d`.
This maintained plan and its exact forecast require both reviews before plan commit.
Planning base: `5718945595e3ac457be31ebcb039dc48b28ef1d4` (current origin/main at creation).
It is NOT the cost baseline: name and review a fixed actual accepted B after required
predecessors land, BEFORE setup or samples; C is that B plus only this feature.
No implementation, compiled call, build or measurement is authorized by this plan alone.

## Problem and actual host contract
Host standard_library/src/list.brp:1338–1376 owns join(List[String], sep:String)->String.
Its empty result is ""; singleton equals its element; separators occur BETWEEN elements,
including empty elements. Counted UTF-8/NUL bytes and order are retained.
Actual host code at1351 is an ordinary loop with a private list.string_append builtin:
```blorp
pure func join(self: List[String], sep: String) -> String:
    var result: String = ""
    var first: Bool = True
    for s in self:
        if first:
            if s.length() > 0:
                result = result.string_append(s)
            first = False
        else:
            if sep.length() > 0:
                result = result.string_append(sep)
            if s.length() > 0:
                result = result.string_append(s)
    result
```
This quotation omits only blank lines; the private append is builtin("list.string_append").
Target standard_library_temp/list.brp:1–18 has only repeat/length/get/append/set/concat.
Compiler-shaped witnesses include emit/emit.brp fragment joins (for example :2462/2486/2550/2676),
main:126 (diagnostic lines), load:341 (import-cycle paths). These are source-inspected
List[String] reductions, not a fresh resolved-callee census or self-compilation proof.

## Choose the smallest bounded implementation
Propose one concrete pure native operation behind the ordinary public name:
```blorp
-- Add String to list.brp's existing explicit _base imports; no prelude change.
pure func join(values: List[String], separator: String) -> String:
    builtin("list.join")
```
Keep the host module/API unchanged. Target input programs import list: join for UFCS.
Do not migrate compiler-source calls/imports in this feature; later SOURCE import parity
must establish that their UFCS resolves to this same declaring module and signature.
An ordinary recursive helper can use get/equality today, but repeated concat copies
accumulated/tail payloads; balanced recursion adds another algorithm and allocations.
Host-style append requires its missing builder primitive and currently unavailable
managed-loop support. Neither meets a direct one-allocation linear join simply.
A two-pass counted helper is the bounded alternative; no builder/cache/iterator/framework.

## Exact typed contract, with no generic-element loophole
Existing namespace/builtins.brp:99 RuntimeType has primitive, Element and List[Element].
A parameterless StringListJoin operation needs precisely List[String], not arbitrary E.
Propose ONE concrete RuntimeType case, not recursive RuntimeType nesting:
```blorp
-- RuntimeType[Element]: add StringListRuntimeType
-- RuntimeOperation[Variant, Element]: add StringListJoin (no Element payload)
StringListJoin:
    { purity = Pure,
      parameters = [StringListRuntimeType, PrimitiveRuntimeType(BuiltinString)],
      return_type = ValueResult(PrimitiveRuntimeType(BuiltinString)) }
```
check/signatures.brp:332 and specialize/specialize.brp:181 project StringListRuntimeType to ListType(StringType).
Parsed ListJoinBuiltin maps once to StringListJoin; keep it OUT of generic_header's
six generic List operations. Exact nongeneric purity/arity/types use the sole contract.
Reject List[Int], List[List[String]], generic headers, wrong separator and result.
Do not use ListJoin(E) plus a runtime String assertion: malformed raw IR could claim E=Int.
No new semantic spelling checks, accepted per-call type table or repeated signature lookup.

## Fact owners and consumers
Parse/syntax own the closed label/help; namespace/builtins owns the operation/signature.
Checking seals the exact contract; specialization carries StringListJoin unchanged.
Existing lower preserves ordered operands; own borrows List root and separator and owns
the fresh String result. Children stay alive through the List root; acquire no child
per occurrence merely to read it. Independent verifier uses the existing runtime signature,
borrow and String-return rules; no new lower/own/verify production algorithm.
Emission maps the typed operation to one native callable and one reached requirement.
Derive String List's C pointer type from list_element_key(StringType)/list_c_type,
not parsed type names, prefixes or a hardcoded nominal ID. Generic List layout/ownership
stays authoritative. Emit the join fragment AFTER complete String/List declarations
(current emit/emit.brp:2489 aggregate assembly and :2643 append of aggregates), before user functions.
A small fragment renderer accepts that existing C ABI projection; it publishes no new facts.
Do not emit the helper for an unreachable declaration or for every List[String] use.

## Native contract and arithmetic
Proposed ABI, showing the current public factory output for StringType:
```c
struct blorp_string *blorp_string_list_join(
    const struct blorp_l_0_s *values,
    const struct blorp_string *separator);
```
The 0_s spelling is illustrative factory output; generate it through the typed projection.
Borrow root, children and separator; accept their valid-UTF-8/nonnegative-length invariants.
First pass counts EVERY child length, including index zero; add separator length ONLY
when index>0. Empty child elements still contribute their separating positions.
Guard EACH addition against both INT64_MAX and SIZE_MAX-sizeof(String)-1 BEFORE adding;
do not multiply (count-1)*separator_length or form pointers before checks.
Second pass copies exact counted bytes, separators only between elements, then terminates.
Allocate ONE fresh String root, reference count1, including empty/singleton/all-empty cases.
No output buffer/list, retain, input mutation, normalization, strlen or temporary String.
Use current string_concat.brp allocation/header policy: unrepresentable storage or malloc
failure aborts as infrastructure exhaustion, not Option/Result or a language panic adapter.
Time O(element occurrences + output bytes); input List construction cost is excluded.
This does not make List.append or source fragment collection linear.

## TDD and independent acceptance
Initial direct-label RED: list.join absent; exact current help/source/span retained.
Initial actual-module RED: list:join absent. Do not import new parsed variants into RED seed.
Granular callbacks: parser label; exact signature rejection message/help/SourceId/span;
concrete operation; ordered lower operands; two dependent borrows + owned String return;
ignored return drop and escaping return; raw verifier wrong List element/arity/borrow/owner;
emission reached-only once, real List ABI and correct operand order.
No repeated generic ownership tests where existing suites already prove the same invariant.
Extend an existing native runtime TestSuite/fixture using actual String and String-List
production fragments/helper factories and delegating allocation-occurrence wrappers.
Use the approved helper exception only: no generated language symbols/alternate main.
Native cases: empty/singleton fresh roots; empty elements/separator; Unicode/CRLF/BOM;
embedded NUL in a CHILD and a separate embedded-NUL SEPARATOR oracle;
repeated child aliases, separator aliasing a child, List aliases, input reuse; returned
root outlives all inputs and inputs survive result release. Observe per-object occurrence
destruction before further reads; one extra allocation exactly and balanced final frees.
Overflow guards need structural/mutation review; deterministic OOM only through existing
test-local allocation refusal if supported. Stop rather than add production test hooks,
fake huge valid buffers or a new failure-testing framework.
One <=30-line real-main fixture prints empty, singleton, Unicode/NUL joins and saved inputs.
Use a pure user wrapper for UFCS/type identity; impure operand makers prove left-to-right
List-before-separator evaluation through literal output order, not helper C argument order.
Mutants: missing/extra separator, strlen, wrong child/order, input retain/drop, skipped
fresh allocation/alias shortcut, and operand swap where type-correct; retain exact restores.
Run focused phases/native, full components/grammar, one pilot/all real-main e2e; inspect C.
No current result is claimed; literal expected bytes are independent of native helper code.

## Hard ceilings and forecast
Root and independent review prospectively approve target production150 gross/+140 net,
tests1000 gross/+1000 net excluding one fixture<=30 lines, and public API docs<=25 lines.
These are hard stops, not an implementation-size or performance prediction.
Production forecast: native fragment45–65; syntax/parse/contract/projections/emission and
wrapper40–65, combined85–130 gross. No lower/own/verify production edits are planned.
The maintained plan/ROADMAP evidence docs are reported separately from public API docs.
Do not delete assertions, compress formatting or add a mechanism to meet a ceiling.

Forecast below names new `test_list_string_join.brp` suites in each listed unit owner;
shared inputs live in `test/unit/list_string_join_inputs.brp`, native under `test/runtime/`.
Physical additions include imports, callbacks and their registration; all numbers are
estimates BEFORE drafting, not retained lines or executed-test counts.

| Boundary | Named callback facts | Forecast lines |
| --- | --- | ---: |
| Shared seed | Existing module/ownership builders, one explicit join call | 65 |
| Parse:2 | Quoted list.join label+independent SourceId/span; actual module/UFCS | 45 |
| Check:9 | Valid contract; impure, generic, missing/extra arg, List[Int], nested List, wrong separator/result | 125 |
| Specialize:2 | Closed concrete operation/signature; ordinary wrapper identity | 40 |
| Lower:2 | List-before-separator evaluation; original call span | 45 |
| Own:3 | Two dependent borrows; ignored result drop; escaping result transfer | 65 |
| Raw verify:8 | Wrong List/sep, missing/extra arg, wrong List/sep borrow, missing/duplicate retirement | 125 |
| Emit:3 | Reached helper once; unreachable absent; typed List ABI/operand order | 65 |
| Native:12 | Cases below, production fragments + occurrence counters | 240 |
| Existing observers | Closed-label helps, grammar, existing e2e registration | 45 |
| Total forecast | 41 new callbacks, shared/observer lines included | 860 |

Native callbacks: empty fresh; singleton fresh; empty children/separator positions;
Unicode/CRLF/BOM; NUL child; NUL separator; repeated child aliases; separator aliases child;
List-root alias; result outlives all inputs; inputs outlive released result; all-empty
elements with empty separator yield a fresh empty root. Every successful helper call
adds exactly one fresh allocation. Independent NUL expectations include child bytes
`61 00 62 7c 63` for ["a\0b", "c"] joined by "|", and separator bytes `61 00 62`
for ["a", "b"] joined by "\0". Guard review/mutations are separate from these12 callbacks.
Do not fabricate invalid huge String objects; if existing test-local allocation refusal
cannot safely exercise exhaustion, report that limit and retain independent arithmetic
review/mutants rather than inventing hooks.
Reuse existing generic call/owner tests for invariant facts, without deleting them.
Forecast860 leaves140 lines; report/review a prospective rescope BEFORE1000 if readable
independent coverage needs more. The one real-main fixture has its separate30-line cap.
Propose new-fixture compiler caps30000 allocations/120000000 normal min3 instructions:
codepoint historical11.2k–11.5k/38.6M is only a small owning-String precedent; this allowance
is prospective for List assembly, repeated calls, printing and aliases, not a prediction.
FEATURE: hard+3% allocations AND normal min3 instructions for EACH frozen shared
invocation and original schema1 artifact_construction_complete construction checkpoint.
The approved role is the original schema1 checkpoint, NOT exit TOTAL. Use
BLORP_MEMORY_STATS=1, BLORP_LEAK_CHECK unset, status0 and exact Generated-output LF
for that supporting checkpoint; retain full raw stderr/checkpoint records.
Root must name/review actual accepted B after predecessors land and BEFORE setup;
C=B+this feature/complete target library. No SOURCE R0/cumulative waiver or refreeze.
Freeze all current invocations/output states, full libraries, flags/artifacts and physical
paths. Strict pilot/native positive balanced zero; C-only fixture has no fabricated B.
Supporting SOURCE34ac/be31+original090 std is a distinct prospective producer/checkpoint role;
ROOT c04+explicit ROOT std is functional only. Neither silently replaces a frozen epoch.
Retain min3 raw alternating B/C samples and all failures; no aggregate offsets/retries.
Host strict leak99 remains FAILED separately; checkpoints cannot turn it into leak success.

## Dependencies and stop boundary
Builtin wiring has one writer; reconcile accepted slice/M2/other closed-label additions
before source/gate freeze. No host/library rebuild or source migration is authorized here.
This can later support path.normalize assembly: join an existing ordered component List
once rather than prepending growing payloads. Normalize semantics and List construction
cost remain a separate feature; no global linearity claim or adjacent path implementation.
Stop for contract-shape rejection, new mechanism, ABI ordering/ownership ambiguity,
unexpected C/diagnostics, missing tool provenance, policy decision or cost/LOC breach.
Plan commit follows root+independent plan review; a later explicit implementation/lane
grant precedes TDD/compiler jobs. Final code commit needs code-reviewer and test-runner
approval, maintained benchmark report, all raw/failed evidence and accepted-stack gates.

## Current change sites and acceptance commands
Current `standard_library_temp/list.brp:2–3` imports only `Int, List, Option`;
add `String` and the concrete wrapper shown above. Current `RuntimeType` at
`src/namespace/builtins.brp:99–102` is:
```blorp
fixed union RuntimeType[Element]:
    PrimitiveRuntimeType(PrimitiveType)
    ElementRuntimeType(Element)
    ListRuntimeType(Element)
```
After: retain those three cases and add `StringListRuntimeType`; map that case
in both existing runtime_type_ref projections to `ListType(StringType)`.
The contract specimen above is the sole new signature authority; no Element payload
or optional designation is needed. Extend the closed grammar/help observers together.
All source anchors are planning-base anchors; refresh bounded hunks before implementation.

Initial RED source (then use the target list import in a separate actual-module RED):
```blorp
pure func joined(values: List[String], separator: String) -> String:
    builtin("list.join")
func main() -> Int:
    0
```
Record existing unknown-label diagnostic/help and quoted span, then the missing public
list:join diagnostic before implementation. After implementation wrong headers must emit
`builtin declaration does not match its runtime contract`, with help
`declare a pure nongeneric function with List[String] and String parameters returning String`,
exact quoted-label span/SourceId and no incidental later diagnostic. Existing unrelated
closed-label help expectations change only by adding list.join and accepted predecessors.

The following are future correctness commands, NOT jobs executed for this plan.
At lane grant, bind ROOT to `/Users/keithphilpott/CLionProjects/blorp`, use only its
FRESH pinned c04 host with explicit ROOT std/default warmed test configuration; if
provenance no longer matches, stop for root instead of rebuilding shared binaries.
From the implementation worktree, first the new parse/check suite, then phase/native:
```sh
"$ROOT/bin/blorp" test --warmup-only --std-dir "$ROOT/standard_library/src"
"$ROOT/bin/blorp" test --std-dir "$ROOT/standard_library/src" --suite --timeout 180 \
  blorp_2/test/unit/test_parse/test_list_string_join.brp \
  blorp_2/test/unit/test_check/test_list_string_join.brp
# Add the named specialize/lower/own/verify/emit suites and runtime suite explicitly
# to the final recorded focused argv once written; no discovery wildcard as evidence.
"$ROOT/bin/blorp" test --std-dir "$ROOT/standard_library/src" --suite --timeout 180 \
  blorp_2/test/unit blorp_2/test/runtime blorp_2/test/test_grammar
```
Native build uses strict C11 O0 warnings-as-errors, ASan+UBSan/no-recovery and established
wrapping-integer flags; preserve true exits/streams, full sanitizer commands and default
compiler limits. Use Clang/GCC supported native gates where available, no suppression.
Generate one functional pilot with that pinned host/ROOT std, link unchanged C at O0,
then pass its exact binary to existing e2e TestSuite through BLORP2_COMPILER; functional
BLORP_2_INSTRUCTION_CHECK=disabled does not satisfy the separately frozen cost gate.
Bind all literal pilot paths/toolchain flags in a reviewed execution packet before calls.

Acceptance: both genuine missing-feature REDs; all41 forecast callbacks (or reconciled
actual inventory) GREEN; effective selected semantic faults fail their owning observer
and exact restored source returns GREEN; full component/grammar and all real-main e2e
GREEN; generated C independently inspected and strict/native lifetimes correct.
Per-input strict/output/diagnostic checks and fixed FEATURE3%/checkpoint/min3 gates must
pass under a separately reviewed quiet recipe. Shared target C/diagnostics remain exact;
expected own-compiler C changes are reviewed, not silently normalized. No selfcompile,
path.normalize or M6 completion is inferred. Return exact source/diff/LOC/tool/raw hashes,
integer verdicts, failures/limitations and one maintained report; root integrates/pushes.
