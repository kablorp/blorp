# Fixed records: the first increment

Status: Int-only implementation complete, validated and independently reviewed.
Read [AGENTS.md](AGENTS.md) and the parent instructions first.
[README.md](README.md) describes the supported
pilot, [grammar.ebnf](grammar.ebnf) owns its syntax, and
[MEMORY_PLAN.md](MEMORY_PLAN.md) owns the memory contracts.

## Problem and working example

At the frozen e553b5c04 baseline, the pilot has nominal unions and managed String
leaves, but no product type. It cannot compile the following program. This increment establishes record
identity, construction, projection, and value semantics before adding managed
fields or recursive data.

```blorp
fixed record Pair { first: Int, second: Int }
pure func make_pair() -> Pair:
    { first = 7, second = 9 }
pure func read_first(value: Pair) -> Int:
    value.first
func main() -> Int:
    pair = make_pair()
    read_first(pair)
```

The end-to-end fixture is `test/e2e/fixtures/record/basic.brp`. Its real `main`
must exit 7 with empty stdout and stderr. Before implementation, add its Blorp
TestSuite case and demonstrate that the unchanged pilot rejects the record
declaration. A lex/parse rejection is the initial red result; subsequent
phase tests must fail for their own missing behavior rather than setup errors.

After adding the fixture, reproduce from the repository root:

```sh
make -C blorp_2 test-compiler
blorp_2/build/compiler blorp_2/src/prelude_temp.brp \
  blorp_2/test/e2e/fixtures/record/basic.brp blorp_2/build/record-basic.c
```

The unchanged pilot rejects the opening brace at byte span `[18,19)`, line 1
column 19, exits 1, and creates no C:

```text
error: unsupported character
help: use ASCII function declarations and Int literals, parameter names, or calls; keep -> adjacent
```

After implementation, the compiler must succeed and the existing native
harness must run the unmodified output's main with the outcome above.

The syntax follows the main language's record declaration and typed literal
rules in [the Guide](../docs/GUIDE.md#records). A helper's declared return type
provides the literal's nominal type. Existing unannotated bindings can then
infer their type from the call; this example does not require typed bindings.

## Scope and grammar

Support nonempty, nongeneric `fixed record` declarations whose fields are all
`Int`. Use single-line declarations and single-line literal expressions first:

```blorp
fixed record Pair { first: Int, second: Int }
pure func reversed() -> Pair:
    { second = 9, first = 7 }
func main() -> Int:
    reversed().first
```

Field names bind to the expected record, so literal order may differ from
declaration order. `reversed().first` is a field read; `reversed().read_first()`
is an ordinary UFCS call. Parentheses distinguish these syntactically. Do not
guess which operation a spelling denotes during emission.

Add braces and the needed declaration/literal/postfix alternatives to the
restricted EBNF and its conformance tests. Keep `fixed record` contextual like
`fixed union`, with ordinary uses of these words tested. Follow the existing
spaces, comma, LF and identifier rules; do not introduce multiline brace
layout, comments, a general expression parser, or new whitespace rules.

Records may appear before or after functions. Their names share the existing
type namespace with builtins and unions and must be unique. Fields are unique
within a record; different records may use identical field names. Two records
with identical fields are distinct nominal types.

Preserve existing prelude-conflict priority and union-only diagnostics. Merge
record/union declaration checks in source order using their name spans, without
another published catalogue. A duplicate involving a record highlights the
later written name and notes the earlier one. Type parameters also conflict
with record names; fields do not conflict with functions or other records'
fields.

Records work as helper parameters/results, inferred local bindings, ordinary
reassignment of `var`, and arguments/results of existing generic functions
when their current inference rules suffice. Literal construction receives a
concrete expected record type from a function return, a concrete parameter,
or reassignment to a binding of that type. It never infers a record from field
shape. A new unannotated literal binding has no receiving type and rejects.
Do not extend generic result inference or accept a literal against an
uninferred rigid parameter.

Preserve the current constructor-hint rules for mixed postfix chains. With no
postfix, use the enclosing return, argument or reassignment expectation. Only
an immediate first nongeneric UFCS call can supply its first parameter type
as a base literal hint. A first field read or generic UFCS call supplies no
hint; never propagate a later call or final result expectation backward across
a field read. Explicit call arguments use their original concrete annotations;
an earlier argument's inferred generic substitution does not contextualize a
later literal against a rigid parameter. Tests must distinguish these cases:

```blorp
-- With ordinary read_first(Pair) and generic identity[T](T) -> T:
identity(make_pair()).first        -- accepted
{ first = 7, second = 9 }.read_first() -- accepted: immediate concrete hint
{ first = 7, second = 9 }.first    -- rejected: no nominal receiving type
```

Defer ordinary managed `record`, String/union/record fields, recursive and
empty records, record type parameters, record patterns, updates such as
`{ value | first = 42 }`, field assignment, typed bindings, and general nested
aggregate shapes or multiline brace layout. Existing nested calls and literals
in concrete arguments remain supported. Parse `{}` as a literal and reject its
missing fields semantically; it does not introduce empty record types.
Reject unsupported field types at declaration
checking, even if no value of that record is constructed. Existing union
payload restrictions remain unchanged.

Freeze literal-error priority: require a concrete expected record; resolve
written field names left to right, rejecting unknown/duplicate names; check the
complete field set; synthesize children left to right with Int context; then
check field type obligations in written order. Structural errors precede child
errors, and child errors precede sibling type mismatches, matching current call
checking. Missing fields report the first declaration field at the whole literal
with a declaration note. Duplicate fields highlight the second name and note
the first. Wrong values highlight the complete child and note its field
annotation. Projection errors highlight the requested field name. Missing
context help suggests a concrete parameter or helper returning the record,
never unsupported typed locals. Unknown annotations remain UnknownType.

## Identity, authority, and published facts

Start with a bounded read-only map of the existing union path through
`syntax`, `parse`, `check`, `specialize`, `lower`, `own`, `verify`, and `emit`.
Reuse its boundaries, not union-specific representations or string tricks.
State each new identity's owner and lifetime before implementation:

| Question | Authority |
| --- | --- |
| Which written name and source span? | Parsed name table and syntax occurrences |
| Which nominal record declaration? | Checker-owned record declaration identity within its sealed program |
| Which field of which record? | Checked field identity containing record owner and declaration position |
| Which concrete record layout? | Specializer-owned record instance and checked declaration-to-instance translation |
| Which computed record or field value? | Existing function-scoped lowered ValueId |
| Who must release it? | Existing ownership classification; this increment's record values are unmanaged |

Keep declaration and instance domains distinct even though records have no
type parameters yet. Do not assume equal numeric positions establish a
translation between stages. Field identity must preserve its owner through
translation. No new global registry, cache, acceptance facade, or general
layout solver is needed.

Checking publishes complete typed record declarations, literal fields, and
field reads. Each literal field carries its resolved field identity and
checked value. Preserve written field order and source spans. A field read
carries the resolved field identity and exact result type. Downstream stages
must neither recover field names from strings nor repeat type/name checking.
Diagnostics look up spellings through the originating parsed authority in
`check_render`, following the current checker/rendering boundary.

Use local builders and freeze at existing publication boundaries. Avoid
duplicating signatures or field types in competing catalogues. Reuse current
sealed construction APIs; do not expose unchecked products to make tests easy.
Use Option for a true optional value rather than inventing a two-case carrier.

## Baseline code and carrier design

The excerpts and line references in this section describe frozen baseline
`e553b5c04`; the carrier sketches record the implementation design.
At that baseline, `src/syntax.brp:114-125` has a call-only postfix list:

```blorp
fixed record ReceiverApplication {
    callee: WrittenName,
    arguments: List[ValueExpression]
}
fixed record ValueExpression {
    base: ExpressionBase,
    base_span: Span,
    applications: List[ReceiverApplication],
    span: Span
}
```

Replace its element type in the same path; retain the existing call carrier:

```blorp
fixed union PostfixApplication:
    ReceiverInvocation(ReceiverApplication)
    FieldAccess(WrittenName)
-- ValueExpression.applications becomes List[PostfixApplication].
-- ExpressionBase gains a record literal with written name/value/span fields.
```

Preserve outer-call preflight of global targets, arity and purity before
children, in written postfix order. Resolve fields once their receivers have
types. A transient closed call-or-pending-field variant avoids parallel lists
of optional contracts. Existing call-only error priority must stay unchanged.

Baseline `src/check.brp:159-169`:

```blorp
fixed union CheckedBase:
    ReturnInteger(Int)
    ReturnVariant(VariantId)
    ReturnBinding(BindingId)
    ReturnCall(CheckedCall, List[CheckedValue])
fixed union CheckedOperation:
    InvokeFunction(CheckedCall, List[CheckedValue])
    ConstructVariant(VariantId)
```

Add `ReturnRecord(RecordId, List[CheckedRecordField])` and
`ReadRecordField(FieldId)`. Each field contains its owner-qualified identity,
checked child and source span. Existing CheckedValue/CheckedStep types remain
the occurrence type/span authorities; field types belong to declarations.

One bounded preparation is part of this design. Baseline
`src/check.brp:1113-1119` allows any checked step in a transient call contract:

```blorp
private fixed record CallContract {
    type_parameters: List[TypeParameterId],
    operation: CheckedOperation,
    parameter_types: List[TypeUse],
    return_type: TypeRef,
    span: Span
}
```

Narrow that private field before adding projection:

```blorp
private fixed union CallOperation:
    FunctionCall(CheckedCall)
    VariantConstruction(VariantId)
-- CallContract.operation becomes CallOperation.
```

This excludes impossible field-read call contracts and removes the transient
empty argument list. Convert to CheckedOperation after child checking; validate
existing call/generic/bidirectional/UFCS tests independently before records.

Current `src/lower.brp:38-51`:

```blorp
fixed union ValueOperation:
    ParameterValue(Int)
    IntegerValue(Int)
    VariantValue(VariantInstanceId)
    CallValue(ConcreteCall, List[ValueId])
    ConstructValue(VariantInstanceId, ValueId)
    PayloadValue(ValueId)
fixed record ValueDefinition {
    id: ValueId,
    value_type: TypeRef,
    operation: ValueOperation,
    span: Span
}
```

Extend that flat operation model:

```blorp
fixed record RecordFieldValue {
    field: FieldInstanceId,
    value: ValueId
}
-- ValueOperation gains:
-- ConstructRecordValue(RecordInstanceId, List[RecordFieldValue])
-- ReadRecordFieldValue(FieldInstanceId, ValueId)
```

These names illustrate the contracts. Translate fields through their owner's
declaration-to-instance mapping; a projection's Int result cannot identify its
receiver layout. Extend existing recursive expression observers for cycle
checking, specialization requests and type occurrences to visit literal
children; do not redesign their collectors.

## Lowering, ownership, verification, and C

Literal field expressions evaluate exactly once, in written order. Lower
each expression to the existing ordered values, then construct the record
using resolved fields. Mapping to declaration/layout order must not reorder
evaluation or evaluate a field twice. The receiver of a projection evaluates
once. Unused record construction still evaluates all field expressions.

For `reversed()`, the essential facts look like:

```text
v0: Int = 9                         -- written second field
v1: Int = 7                         -- written first field
v2: Pair = construct { first: v1, second: v0 }
return v2
```

Represent construction and projection as explicit typed operations in the
existing phases, with exact input ValueIds and output types. No CFG, phi,
general borrow graph, or second lowering/emission path is justified here.
If a small preparatory refactor is essential, propose it to the coordinator
before it grows beyond a bounded, independently validated change.

All supported fields are unmanaged Int values. Emit a C struct by value,
using identity-derived record and field names, before functions that use it.
Parameters, calls, returns, copies, whole-binding reassignment and field reads
must require no target heap allocation, retain, release, or destructor.
Avoid statement expressions and growing nested initializers; existing flat
value temporaries are sufficient. Read the emitted C and compile it with the
existing strict C11, O0, ASan/UBSan fixture harness.

Ownership classification is explicit, not inferred from C spelling or the
absence of runtime calls. Extend the independent verifier for construction
and projection: value-use availability, record/field owner, exact field set,
field/result types and unmanaged ownership obligations. Reject malformed IR
through existing verification boundaries without trusting planner metadata.
This proves the unmanaged aggregate path; it is not a claim about managed
records, exhaustive managed destruction, or recursive layouts.

## TDD and acceptance matrix

Use Blorp TestSuite callbacks at each affected boundary. Keep source programs
readable with multiline host strings. Multiline String literals remain outside
the pilot input syntax until their separate increment.

| Boundary | Required independent observations |
| --- | --- |
| Lex/parse/EBNF | Braces, declaration/literal/field spans; reordered fields; field read versus UFCS; malformed commas/braces/names; contextual words; intentionally deferred syntax rejected |
| Checker/errors/rendering | Nominal identity; duplicate type/field/literal field; missing/unknown field; wrong field value type; missing expected record type; nonrecord receiver; unknown field; unsupported declaration field type; exact kind, span, help and relevant declaration note |
| Accepted facts | Resolved field owners/positions and complete types; no partial accepted result on error; no spelling-driven consumer behavior |
| Generic checking/specialization | Existing identity[T] accepts a synthesized Pair; same-layout records remain distinct; declaration-to-instance field ownership; repeated instance reuse and complete signatures |
| Lowering | Written evaluation order versus layout order; exactly-once field expressions and receiver; precise full Int64 values; unused initializer retained; stable alias and var reassignment value semantics |
| Ownership | Unmanaged construction, copy, projection, argument and return; no dup/drop or retain/release introduced; neighboring String obligations unchanged |
| Independent verifier | Missing/duplicate/wrong-owner field, unavailable input, wrong field/result type, and invalid managed treatment rejected independently of planner output |
| Emission/native | By-value layout and identity-derived fields; strict C11/sanitizers; normal-main exits for first/second/reordered fields, passing/returning, old alias and var reassignment |

Do not create an entire process per semantic error or lower every unit test
through the full compiler. Granular negatives may exercise existing exposed
verification readers/constructors, but must not weaken sealed phase products.
If a malformed-IR case cannot be reached at the current boundary, report the
specific gap and propose the narrow test seam before implementing it.
The current public OwnershipProgram plus opaque IDs obtained from sealed
producers already supports these negative tests. Extend the existing seed with
two records and same-position fields; no unchecked identity constructors are
needed.

Prove at least the field-owner/layout-position oracle and evaluation-order
oracle by temporary implementation mutations that cause the intended callback
to fail. Restore exact source before final gates. Native exits are limited to
small observable results; full-width values and effects/order are checked
directly from typed/ordered data, not by extra C drivers.

## Feedback, performance, and stop rules

Use the repository host compiler; check freshness before direct tests. The
coordinator serializes compiled commands and measurements on this machine.
Start with the new focused parser/checker tests, then owning phase suites.
For example:

```sh
bin/blorp test --suite --timeout 180 blorp_2/test/unit/test_records.brp
bin/blorp test --suite --timeout 180 blorp_2/test/unit/test_parse.brp
```

Final commands, using the existing recorder for evidence:

```sh
scripts/compiler-build-status
bin/blorp test --suite --timeout 180 blorp_2/test/unit
bin/blorp test --suite --timeout 180 blorp_2/test/test_grammar
bin/blorp test --suite --sanitize --leak-check --timeout 180 blorp_2/test/unit
make -C blorp_2 test
git diff --check
```

The end-to-end run builds one fresh pilot at O0 at its start. Do not add a
compiler cache, fixture-specific build, generated-symbol driver or output
rewriter. The e2e wrapper runs with `--timeout 0`, as in the Makefile; existing
unit-test timeouts and fixture cost ceilings remain unchanged.

Freeze the reviewed source baseline and toolchain before production edits.
Measure matched baseline/candidate compilation on the existing eleven-workload
cleanup corpus and the new fixtures, three serialized samples per workload.
Label these as owned-input proxies, not self-compilation or a whole-pipeline
speedup. Old fixture C must remain byte-identical; the new feature needs no
change to existing runtime code or old C output.

Use [the retained cleanup measurement recipe](../benchmarks/results/blorp_2_compiler_cleanup_2026-10-10.md)
with these eleven `.brp` paths under `test/e2e/fixtures/`:
`return/zero`, `nested/calls`, `mortal_string/basic`, `generic/box`,
`union/values`, `match/constructor_spine`, `generic/union_parameters/ok`,
`generic/union_parameters/err`, `generic/union_parameters/third`,
`generic/union_parameters/unwrap_or`, `generic/union_parameters/phantom_keys`.
For each frozen baseline/candidate pair, run the same command three times:

```sh
/usr/bin/time -l -o SAMPLE.time env BLORP_LEAK_CHECK=strict \
  COMPILER blorp_2/src/prelude_temp.brp FIXTURE OUTPUT.c
```

Record source/binary/input hashes, compiler flags and toolchain with raw
samples. Compare corresponding emitted C and matched samples together.

Investigate repeatable increases above 10% allocations or 5% minimum retired
instructions on any old workload. Initial new-fixture limits are 10,000
compiler allocations and 100,000,000 retired instructions, with strict zero
compiler leaks. Target record operations have zero heap allocation by design;
inspect generated C to establish that separate claim. Track production/test
formatted physical lines separately; stop for coordinator review if production
growth exceeds the final reviewed 1450-line threshold below. These are scope/investigation stops, not permission
to compress code, remove coverage, or increase ceilings silently.

The existing union_values instruction ceiling has marginal headroom and
previously needed one unchanged rerun. Final validation preserved another
40M failure; coordinator and independent review explicitly approved a
union_values-only 45M ceiling, with its 4000 allocation limit and all other
caps unchanged. The retained report records historical and current matched
evidence; the separate 10%/5% investigation stops remain unchanged.

## Handoff and completion

The compiler-expert implementer also supplies parser-specialist, ergonomics
and data-model input before editing: confirm the syntax, expected-type rules,
identity map, error priority and operation contracts against the current code.
Send the coordinator a bounded proposal if any agreed boundary cannot carry
complete data without broader changes. Then implement in small TDD slices.

Update this plan's status, README and restricted EBNF with the implementation.
Keep retained evidence in `benchmarks/results/` and scratch/logs under ignored
`build/`, with one navigator and the existing validation recorder. Return a
concise report with changed files, red/green and mutation evidence, exact
gates, generated-C observations, matched costs/LOC, and unresolved limitations.

Independent compiler-expert code-reviewer and test-runner approval is required,
including an explicit judgment that the project is better. Do not commit or
push without a later user request. Managed fields are a separate next spec;
do not quietly begin them after this slice passes.


Implementation size review (2026-10-10): the original +900 formatted physical
production-line stop was invoked at the parser/checker checkpoint (+802 at
initial review). The coordinator and independent compiler reviewer reviewed
the necessary typed diagnostics, source-order/error priority, explicit Result
loops, cross-phase identity translation, and independent public-layout checks.
They approved investigation stops of +1250, then +1350, and finally +1450
formatted physical production lines relative to e553b5c04. The downstream
forecast underestimated the verifier and carrier growth; this does not add
functionality or waive measured regressions. Scope, formatting, coverage,
mechanisms, allocation/instruction investigation stops, new record fixture
ceilings and leak thresholds are unchanged. The explicit union-only fixture
budget review above is separate. Final actual counts
and validation belong in the retained implementation report.

Current implementation and focused/mutation/cost evidence are retained in
[the fixed-record report](../benchmarks/results/blorp_2_fixed_records_2026-10-10.md).
The local [evidence navigator](build/records/README.md) links all raw packets,
source snapshots, samples and mutation receipts.

Independent validation passes 657/657 strict unit/grammar callbacks and
667/667 normal unit/runtime/grammar callbacks. The first full Makefile gate
failed on the retained frontend oracle and union budget issues documented
above. After their reviewed e2e-only corrections, the
[final end-to-end packet](build/records/validation/final-independent-e2e-corrected/metadata.json)
passes 104/104 including its wrapper. The unchanged green unit/grammar results
are reused; all required gate components now pass. Independent compiler/code
and test-runner reviews approve the completed increment. No commits or pushes
were made.
