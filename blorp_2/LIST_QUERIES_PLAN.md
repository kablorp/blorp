# Ordinary generic List queries

Status: proposed; publish after root and independent review, before implementation.
Fixed B: `1d02a670027ee05c2e18e0d19cbd22ac64ad23e4` (2026-10-19).
Owned branch: `codex/list-query-helpers` in the supplied isolated checkout.
M7 checkpoint04 and its over-cap Specialize draft remain separate and unchanged.

## Scope and semantics

Add only target `standard_library/list.brp` get_or, is_empty and last. Keep every
existing API, host library, compiler41, runtime, prelude and builtin contract.
These three helpers remain generic; no concrete adapter, HOF, loop or recursion.
Merge `_base` Bool and `int as IntOps` with concurrent contains imports semantically;
never replace its whole file. Later List slices have separate plans and grants.

```blorp
pure func get_or[T](values: List[T], index: Int, default: T) -> T:
    match get(values, index):
        Some(value): value
        None: default
pure func is_empty[T](values: List[T]) -> Bool:
    IntOps.equals(length(values), 0)
pure func last[T](values: List[T]) -> Option[T]:
    get(values, IntOps.subtract(length(values), 1))
```

The existing checked get owns a successful managed child independently of its List.
get_or preserves that selected payload; its ordinary default argument is eager
on both arms. is_empty returns designated `_base.Bool`. last delegates empty and
bounds behavior to get: length0 subtract1 is -1, so None. No equality/sign hack.

## Test first and precise phase oracles

One real-main fixture `generic/managed/list_queries.brp` has50 physical lines.
Its exact107-byte stdout is retained as EXPECTED_STDOUT.bin; exit0, empty stderr.
It covers Int selection, direct and UFCS calls, eager printed defaults exactly once
on hit/miss, negative and length indices, empty last/is_empty, nonempty Bool,
List[Void] get_or/Some/None, temporary managed payload escape, old List alias and
unselected managed-default survival. Generic native LIMITS remain150k/600M.

Before source implementation, add the existing-style TestSuite/file registration.
The old library must fail semantically at fixture import get_or bytes18..24:
`module list declares no public function or type get_or`, help
`select a public function or type that list declares`, no note; no target C.
A test setup/parser/host failure earns no RED. Check exact diagnostic before GREEN.

| Owning test work | ADD forecast | Exact oracle |
| --- | ---: | --- |
| Check, actual loaded library |70| all3 pure, each genuine function-owned rigid; get_or [List[T],Int,T]->T; is_empty List[T]->baseBool; last List[T]->baseOption[T] |
| Specialize |40| distinct Int/String/Void get_or and last instances, correct Option payload/layout and ordinary direct calls |
| Own plus independent Verify |55| get_or Some child acquired before Option retirement; None default acquired/transferred; last payload owner survives List death; valid resulting program verifies |
| Typed client negatives |40| bad String index expectedInt/actualString/argument1; mismatched String default expectedInt/actualString/argument2, GenericArgumentConflict; exact message/help/source/span/no-note |
| Native registration |7| maintained test_generics suite run_output_example, existing LIMITS |
| Total nonfixture forecast |212| no new runner, phase framework or compiler model |

New negative sources load actual target modules with existing temporary-directory
precedent, not copied library bodies. Both mismatch messages are `argument type
does not match the parameter type`; help `use an expression of type Int here`.
Each actual `"bad"` extent/source and typed expected/actual facts remain asserted.
Independently mutate Some->default, is_empty zero->one, and last length-1->length;
each must fail its real-main exact output and restore exact bytes/modes before
classification/restored GREEN. No setup-error credit or generated-C rewriting.

## Acceptance and costs

Under an exclusive lease, use ROOT FRESH bin/blorp and explicit ROOT STD91:
`ROOT/bin/blorp test --std-dir ROOT/standard_library/src --timeout 180 blorp_2/test/unit/test_check/test_list_queries.brp`.
Run the changed Specialize/Own owners, full unit/runtime/grammar and maintained
full e2e `--suite --timeout 0` with explicit source-matched diagnostic compiler,
BLORP_2_INSTRUCTION_CHECK=required, strictzero, real mains and O0/C11/ASan/UBSan.
The new checkout has no private bin: root freezes faithful direct equivalents,
not a WT-Make PASS claim. Reuse current accepted normal/diagnostic producers only
after all41 source/C/binary/STD/tool provenance matches; no gratuitous rebuild.

Before samples bind unchanged return/zero, list/zero, list/literal_int,
list/literal_empty, list/append_int, list/set_int, list/concat_int, list/entries.
Use one physical active library/input/output/CWD; freeze full12 files B/C/B.
Eight original samples/input: normal B1,C1,B2,C2,B3,C3; strict diagnostic B,C.
Each retains5% allocation/normal-min3 target and10% hard, plus tighter old absolutes.
Require positive counters, strict balanced0, normal/diagnostic and B/C target-C
identity. No repeat/rebaseline/successful B denominator for the new API fixture.
New fixture gets one strict plus3 normal samples under unchanged150k/600M.
Full existing source/input oracle closure and native outputs remain; disclose any
new export/frontier transition, never silently repin. No host metric campaign is
needed for unchanged compiler/data model; existing independent HOST3% stays fixed.

## Bounds and stop

Production forecast13ADD/1DEL/+12; hard30ADD/+30, list only. Nonfixture tests hard250,
one fixture hard60lines, API docs hard30ADD (README/GUIDE/GRAMMAR, no syntax change).
This plan hard100lines. Stop before forecast/cap breach, semantic/accounting/
provenance failure or10%/absolute miss; retain5% misses, no cap edits or retries.
Read generated C/selected managed returns; independent code+test-runner reviews
precede root integration. New main composition requires explicit source/provenance
validation, not a B roll. No commit, push or compiled call follows plan approval.
