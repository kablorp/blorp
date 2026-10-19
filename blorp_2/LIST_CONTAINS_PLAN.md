# List[Int] membership through one borrowed runtime scan

## Status and problem

Root and independent architecture review approve this bounded plan before
publication. Implementation requires a separate explicit root authorization;
compiled work requires an explicit lane. Accepted B is
`5b5985ffc385c89541dee2d997c2d3c0ad53f65b`; C is exactly B plus this feature.
The current host builds A and all 41 source modules parse, but A's actual source
probe first rejects `list: contains` at `src/verify/verify.brp:8:8`.
The two current calls are `levels.contains(level)` at `lex/lex.brp:1156`, with
`levels: List[Int]`, and `seen.contains(field_number(field.field))` at
`verify/verify.brp:1080`, with `seen: List[Int]`. This is a source-inspected
census, not a new resolved-call dump. Correct the stale third site and M3
prerequisite in LIBRARY_PARITY's contains row; preserve unrelated historical rows.

Provide the concrete target-only signature `contains(List[Int], Int) -> Bool`.
No host library, generic equality/traits, lambdas, source loops, HOF removal,
compiler-source call migration or other missing List helper enters this slice.
Lower/Own/Verify production stays unchanged; tests may inspect their contracts.
Existing prelude `list: List methods_only` already offers receiver methods;
explicit imports offer direct calls. No prelude change is expected.
The unrelated numeric, M3 and lambda candidates remain held and unmodified.

## Current code and direct change

`standard_library/list.brp:2-3` currently imports:
```blorp
import:
    _base: Int, List, Option(Some, None)
```
Add Bool to that selection and one ordinary declaration, keeping every old API:
```blorp
pure func contains(values: List[Int], value: Int) -> Bool:
    builtin("list.contains")
```
This is nongeneric and pure. String/Float/Void/opaque elements are not silently
coerced to Int. An opaque wrapping Int remains distinct at Check; callers must
explicitly unwrap before constructing an accepted List[Int].

`namespace/builtins.brp:99-102` currently has:
```blorp
fixed union RuntimeType[Element]:
    PrimitiveRuntimeType(PrimitiveType)
    ElementRuntimeType(Element)
    ListRuntimeType(Element)
```
Add the precise nullary `IntegerListRuntimeType` alternative, not fake Element
metadata. Add `ListContainsInt(DesignatedBoolean[Variant])` to RuntimeOperation.
Its sole runtime_contract arm is Pure, with parameters
`[IntegerListRuntimeType, PrimitiveRuntimeType(BuiltinInt)]` and
`BooleanResult(boolean)`. Existing Check and concrete runtime_type_ref map the
new alternative to `ListType(IntType)`. All generic consumers then share this
contract, including borrowing and independent verification.

At `check/signatures.brp:337-390`, accepted_operation already constructs
`IntegerEqualsBuiltin: Ok(Builtins.IntEquals(boolean))`; add the analogous
ListContainsBuiltin arm with the actual site.designated.boolean. Default
nongeneric header validation at 422-425 must apply; do not place the new tag in
the generic List-tag exemption. Existing contract equality rejects wrong arity,
purity, generics, element types and foreign Bool identity at the builtin label.
Help: `declare a pure nongeneric function with List[Int] and Int parameters returning Bool`.

At `specialize/specialize.brp:2315-2322`, IntEquals translates its actual
constructors with translate_boolean. Add the same direct ListContainsInt arm;
retain both real VariantInstanceIds. No hard-coded union/variant ordinals or
spelling tests, no new semantic key or concrete layout.

At `emit/emit.brp:1342-1395`, append_equals already evaluates a binary condition
and selects c_union_value(boolean.true_variant/false_variant). Rename only this
internal concept to BooleanTest/append_boolean_test, retaining the existing
String/Int condition bytes, and add IntegerListContainsTest with condition
`blorp_list_contains_int(list_local, needle_local)`. No new comparison framework.

`runtime/list.brp:151` already emits the typed scalar list struct from its key:
`struct blorp_l_0_i{atomic_size_t references;int64_t length;int64_t values[];};`
The nullary list_contains_int_runtime() fragment derives its local Int key with
list_element_key(IntType), then list_c_type(key), whose spelling projection uses
list_suffix(key). It accepts no caller-supplied layout. The following C illustrates that current key,
not a hardcoded spelling in the generator. Emit the fragment once only when the
operation occurs, after complete typed list structs and before function bodies:
```c
static int blorp_list_contains_int(const struct blorp_l_0_i *values, int64_t value) {
    for (int64_t index = 0; index < values->length; index++) {
        if (values->values[index] == value) return 1;
    }
    return 0;
}
```
The predicate's C 0/1 is converted to the designated Bool by emission; it is
never used as a language tag. The bounded index cannot overflow: the last
increment is at most INT64_MAX. Empty lists never dereference a slot. The scan
has constant stack, no allocation, mutation, ARC operation or element callback.
Selection reads the existing ProgramInventory.runtime_calls; do not infer
membership demand from a type, path, helper name or generic element placeholder.
Keep aggregate_runtime and emit consistent; no helper on unchanged programs.

## Ownership, production and documentation budgets

| Production owner | Forecast ADD | DEL | Net |
| --- | ---: | ---: | ---: |
| utils/syntax.brp | 2 | 1 | 1 |
| parse/parse.brp | 5 | 2 | 3 |
| namespace/builtins.brp | 22 | 3 | 19 |
| check/signatures.brp | 7 | 3 | 4 |
| specialize/specialize.brp | 10 | 3 | 7 |
| runtime/list.brp | 16 | 0 | 16 |
| emit/emit.brp | 58 | 10 | 48 |
| standard_library/list.brp | 4 | 1 | 3 |
| Total point forecast | 124 | 23 | 101 |

Production expectation 110-150 ADD/+90-120 net; reassess before crossing
150 ADD or +120 net, hard 180 ADD/+150 net. Tests hard 650 ADD/+600 net,
excluding one real-main fixture of at most 60 physical lines. Forecast 520 test
ADD and 45 fixture lines; stop before writing beyond any bound, not afterward.
API docs hard 45 ADD, this plan forecast at most 220 physical lines, final
measurement report hard 80 physical lines, all counted separately. Preserve
readable formatting and existing coverage; no deletion/formatting budget tricks.
Docs: target library README, LIBRARY_PARITY, scoped README/grammar.ebnf builtin
label/help and narrow GUIDE/GRAMMAR API cross-references. No general stale-doc cleanup.
Parser/ergonomics review precedes the one new closed builtin label; generic
language syntax is unchanged. Root publishes the reviewed plan before code.

## Tests first and finite correctness acceptance

Start with the actual ordinary real-main fixture importing list.contains,
expecting exact missing-export diagnostic/help/source span, exit1 and no C on B.
A baseline-compatible parser/check TestSuite must also demonstrate the new
closed label's rejection before implementation, not missing enum/import setup.
After implementation, retain the exact unknown-label/help oracle for misspelling
and exact builtin contract message/help/label span for wrong list, second
argument, result, foreign Bool, opaque element, purity, generic header and arity.
Check actual designated IDs and accepted signature; Specialize checks translated
IDs and exact List[Int]/Int types. Swap the designated foundation Bool order
in a phase input to prove that emission selects identities rather than C tags.

Use existing owners: test_parse/test_parse, test_check/test_signatures,
test_specialize/test_specialize, test_own/test_generic_list_phases,
test_verify/test_boolean_contracts, test_emit/test_list_phases,
test_runtime/test_list, runtime/test_generic_list, e2e/test_lists. Reuse their
public phase helpers and normal RuntimeCase mechanism; no parallel harness.
Own must borrow the actual managed List, keep Int/Bool unmanaged, preserve
aliases and drop a fresh list once at last use. Verify independently rejects
a raw dead-owner borrow without consulting Own's schedule. Emit tests require
one selected helper after its struct, real argument order/occurrence identities,
actual Bool variants, and omission when unused. Read the emitted native C.

One <=60-line `fixtures/list/contains_int.brp` real main covers empty, first/last
hit, miss, duplicates, signed MIN/MAX and 32-bit narrowing guards, an alias, an eagerly
evaluated needle with one observable print, and repeat(7,65536) hit/miss.
Prewrite exact exit0/stdout bytes/empty stderr; prospective new fixture caps
45000 compiler allocations and 200M diagnostic instructions AND normal min3.
Existing caps never change. RuntimeCase observes allocation-counter endpoints
around the scan itself (zero new allocations/releases), preserved contents and
edge results; this approved helper test is separate from normal-main execution.

Require effective separately restored faults: hit test inverted (native exact
output FAIL), mapped true/false constructor choice swapped (phase/native FAIL),
and removed owner liveness/drop protection caught by the chosen typed ownership
oracle. Freeze exact minimal patches/required named failures before their leases;
setup/type/resource failure is not a semantic kill. Restore bytes and modes,
semantic index and all input pins, then run the same owner GREEN after each.
No generated C rewriting, fixture-main replacement or new runtime instrumentation.

Focused commands use absolute ROOT/bin/blorp test --suite --timeout180 with
explicit ROOT/standard_library/src and the existing owning paths. Then run the
whole unit/runtime/grammar gate, generate C once with ROOT/bin/blorp, link O0
normal0 and diagnostic1 from that same unmodified C, and run the full e2e umbrella
with explicit BLORP2_COMPILER and required instructions/strict0/C11/ASan/UBSan.
Reuse a verified exact producer only when its source matches; this feature
changes compiler source, so an old A is B evidence, never C validation.
Run the actual source frontier once after GREEN; a later missing helper is not
self-compile/fixpoint acceptance. Root leases finite literal commands separately.

## Frozen resource and identity boundary

Before implementation freeze B's 41 source modules, complete target library,
all 498 current e2e fixture .brp files, support inputs and every existing cap.
Freeze C's exact source/library scope and physical active paths before samples.
Supporting normal/diagnostic producers, clang, flags and explicit std directory
must match across B/C. ROOT974/STD91 is functional only, immutable and FRESH;
no install/rebuild of it. Root names matched B/C target pairs after source freeze.

Eight unchanged relative-cost controls: return/zero.brp; list/zero.brp;
list/literal_int.brp; list/literal_empty.brp; list/append_int.brp;
list/set_int.brp; list/concat_int.brp; list/entries.brp (under e2e/fixtures).
For EACH: +5% target, +10% hard independently for full EXIT TOTAL compiler
allocations and normal minimum of three retired-instruction samples, plus every
tighter old absolute. Report every 5% miss; stop at the first 10%/absolute breach.
Eight samples per control: B1,C1,B2,C2,B3,C3 normal, then strict diagnostic B/C;
positive counters, balanced strict0 and within-role/B-C target C identity required.
The new-only fixture has diagnostic plus three original normal samples against
its absolute caps; no fabricated successful B denominator.

For all 498 unchanged file inputs require exact CLI status/stdout/stderr/C and
output-presence identity (including rejection/no-C cases) with one normal B/C
pair per file. Same physical source/library/output path and CWD via owned
payloads, complete B/C libraries, explicit flags; never compare different paths,
normalize C or adapt B. Separate API RED/new input and actual-source frontier
have intentional transitions and do not enter this identity corpus. This is
996 identity calls, 64 control samples and four C-only samples; no claim that
all 498 inputs received relative samples. No SOURCE campaign or M7 baseline roll.

The supporting HOST proxy separately retains original normal34ac1a91 /
diagnosticbe31a5a3 / STD090ed68c and complete598 provenance, verified before
reuse. Eight original matched serial calls: diagnostic B/C and normal
B1,C1,C2,B2,B3,C3. Schema1 artifact_construction_complete.total_allocations and
normal min3 each have independent +3% hard limits; not full EXIT TOTAL and not
ROOT974 substitution. Target full EXIT TOTAL remains a distinct metric role.
Freeze literal argv/CWD/pins/expected output states before each finite lease.

Stop on semantic, setup, identity, accounting, provenance, scope or hard-cost
failure; retain original logs/samples, restore active C payloads/faults and return
the lane. No resample, baseline roll, cap change, hidden repair or new mechanism.
Two independent code/test-runner reviews and full current-source gates precede
root-only integration/push. This plan authorizes neither lambda nor loop work.
