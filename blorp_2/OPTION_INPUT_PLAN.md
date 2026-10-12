# Library unions for conversion and input

Status: steps 5–7 are implemented, independently reviewed and validated by
granular phase/ownership tests and native calculator inputs. See the
[completion results](../benchmarks/results/blorp_2_calculator_2026-10-12.md)
for exact gates, mutation evidence and matched cost measurements.

## Problem

Calculator steps 5–7 need fallible conversion, input, and operation selection.
The pilot can declare generic unions, but imports currently select only
functions. Runtime contracts return only primitive types. This design adds one
ordinary library union path; it does not make Option or Bool compiler primitives.
The coordinator approved explicit constructor role references and flat C
projection on 2026-10-12. Step 5 is implemented and validated before step 6;
comparison and other integer arithmetic follow separately in step 7.

The desired step-5 program, compiled through the ordinary pilot entrypoint, is:

```blorp
import:
    option: Option(Some, None)
    string: parse_int
pure func parse_or_zero(text: String) -> Int:
    match parse_int(text):
        Some(value):
            value
        None:
            0
func main() -> Int:
    parse_or_zero("42")
```

It exits 42. Invalid and out-of-range strings exit 0. The helper is deliberate:
`lower.brp:451` lowers a match scrutinee into the prefix, and `own.brp:844`
rejects an owned managed prefix. Passing the literal to a helper keeps its
String parameter borrowed. Direct `match parse_int("42")` remains rejected with
the existing teaching diagnostic; this slice does not expand match ownership.

## Proposed solution and code

Current contracts (`src/prelude.brp:35`) are:

```blorp
fixed record RuntimeContract {
    purity: Purity,
    parameters: List[PrimitiveType],
    return_type: PrimitiveType
}
```

The shared closed operation metadata gains result shapes, with primitive
parameters unchanged:

```blorp
fixed record OptionalRoles[Variant] {
    present: Variant,
    absent: Variant
}
fixed record BooleanRoles[Variant] {
    equal: Variant,
    different: Variant
}
fixed union RuntimeResult[Variant]:
    PrimitiveResult(PrimitiveType)
    OptionalResult(PrimitiveType, OptionalRoles[Variant])
    BooleanResult(BooleanRoles[Variant])
```

Step 5 adds pure `string.parse_int(String) -> OptionalResult(Int)`. Step 6 adds
impure `io.read_line() -> OptionalResult(String)`. Step 7 adds pure
`string.equals(String, String) -> BooleanResult`. Boolean roles are a precise
separate carrier: both selected variants are empty, unlike Option's payload and
empty roles. Existing primitive calls retain their closed operation contracts.
No table, pass, framework, cache, or generalized foreign-call ABI is introduced.

Currently `syntax.brp:191` gives parsed operations four payload-free variants,
and `parse.brp:2106` accepts one quoted label. Add dedicated syntax variants
carrying two `WrittenName` constructor references for ADT-valued operations.
These are references only in builtin syntax, not general function values:

```blorp
-- standard_library_temp/option.brp: adapted ordinary declaration
fixed union Option[T]:
    Some(T)
    None

-- standard_library_temp/string.brp
import:
    option: Option(Some, None)
pure func parse_int(text: String) -> Option[Int]:
    builtin("string.parse_int", Some, None)

-- step 6, standard_library_temp/io.brp
import:
    option: Option(Some, None)
func read_line() -> Option[String]:
    builtin("io.read_line", Some, None)

-- step 7, ordinary fixed union Bool: True; False
pure func equals(left: String, right: String) -> Bool:
    builtin("string.equals", True, False)
```

At `check.brp:3169`, replace boolean builtin validation with construction of an
accepted checked runtime operation during declaration/signature acceptance.
A private accepted-function record carries the signature and its optional
accepted runtime operation; ordinary bodies carry None. This preserves builtin
signature errors before unrelated caller-body errors. Resolve the annotated return union, resolve
the references through visible constructor candidates in the function's module,
and require their owner to equal that return declaration. Require exactly two
distinct variants covering the whole union, the present variant's substituted
payload to equal the operation's primitive payload, and the absent variant to
have no payload. Require the existing purity/parameter contract and nongeneric
function rule. A concrete application of an ordinary generic union is allowed;
a generic builtin wrapper remains rejected. The accepted operation carries only
its typed roles; its result union owner derives from the present variant ID.
Primitive operations carry no fictitious roles. Boolean operations carry their
own two empty roles. Publish these accepted operations in checked calls, replacing
`RuntimeFunction(RuntimeOperation)` at `check.brp:134`; do not repeat resolution
in `resolve_body` (`check.brp:3194`). Ordinary wrapper callers remain
`UserFunction`, so normal checker purity validation remains authoritative.

At `specialize.brp:1025`, translate accepted declaration roles to
`VariantInstanceId` using the return union instance already prepared from the
function signature. Reuse `translate_variant` (`specialize.brp:1069`), which
checks declaration ownership before minting a concrete variant identity. Keep
the generic operation and result carriers instantiated with declaration
`VariantId` versus concrete `VariantInstanceId`; no generic cast can mix their
authorities. Downstream lowering and ownership carry
that concrete target unchanged. `verify.brp:268` independently validates the
concrete role membership, distinctness, complete coverage, payload and result
union contract before checking argument and result ownership. No spellings are
available or needed there. Forged owners, variant positions, payload types,
result types, and borrowed/owned result claims must fail verification.

Current `emit.brp:399` emits every runtime call as a C expression. For these
precise operations, `append_value` (`emit.brp:449`) instead emits flat scratch
declarations and one final value declaration. C runtime helpers remain independent
of nominal Blorp union layouts:

```c
int64_t blorp_runtime_value_3 = 0;
const uint8_t blorp_runtime_some_3 = blorp_string_parse_int(blorp_vl_0,
    &blorp_runtime_value_3);
const struct blorp_u_0 blorp_vl_3 = blorp_runtime_some_3
    ? (struct blorp_u_0){.tag=blorp_v_0_0,
        .payload.blorp_up_0=blorp_runtime_value_3}
    : (struct blorp_u_0){.tag=blorp_v_0_1};
```

The exact projected names and tags derive from accepted concrete IDs, including
reversed declaration order. Read-line's helper returns one owned String pointer
or internal C NULL; projection constructs the actual union and transfers that
pointer into its payload without retaining it. NULL is never a language value.
The existing ownership plan for `InlineOwningPayload` owns/drops the constructed
result, including no-op empty-variant cleanup. Conditional runtime fragments stay
before union definitions (`emit.brp:1054`); inline projection occurs after them.
No generated wrapper registry or C rewriting is needed.

## Imports and identity

Current `ParsedImport.symbols` (`parse.brp:84`) is `List[WrittenName]`, and
`consume_import_symbol` (`parse.brp:2343`) rejects parentheses. Replace that one
ordered selector list with explicit function versus union selections:

```blorp
fixed union ImportSelection:
    FunctionSelection(WrittenName)
    UnionSelection(WrittenName, List[WrittenName])
```

`option: Option(Some, None)` imports the union and only those constructors;
`option: Option()` imports its type alone. Bare identifiers keep their current
function meaning; capitalization does not decide semantics. This avoids a
function/type ambiguity when both namespaces contain the same spelling.
No aliases, wildcards, reexports, nested selectors, multiline selectors,
module-qualified value paths, or new record imports are required.

`namespace.brp:188` resolves selections against the target module's local
complete declarations. Import visibility rows retain the original `UnionId` and
`VariantId`; imports never mint declarations. Selected constructors must belong
to that selected union. Extend typed import problems and origins so duplicate or
conflicting type imports are rejected before `validate_signatures`
(`check.brp:3829`) can choose an arbitrary candidate. Preserve the existing
function/value conflict policy. Two visible same-spelling constructors from
different unions remain distinguishable by expected type; importing a constructor
under the wrong union is rejected. Local and imported type conflicts, repeated
selectors, missing constructors, and an ambiguous source declaration get explicit
errors with the current and previous occurrence spans. Do not silently choose the
first candidate or trust a directory/module spelling.

Ordinary local functions and explicit function imports shadow the input
prelude's function fallback through the existing namespace lookup order. This
supports module-specific `to_string` declarations without type-based overloads.
Unimported helpers do not become visible, and two selected function imports
still conflict. Union variants retain their existing prelude-name restriction.

| Fact | Authority and lifetime | Consumer and translation |
| --- | --- | --- |
| Written selector/role | Parser name table and occurrence span, one parsed compilation | Namespace/checker; diagnostics retain spelling authority only |
| Visibility | Frozen Namespace, original declaration IDs plus import origins | Signature/body checking; no reexports or new declarations |
| Accepted result/roles | Checker-owned typed operation in sealed CheckedProgram | Specialization resolves generic payload and mints instance roles |
| Runtime layout/roles | Specialization-owned UnionInstanceId and VariantInstanceId | Lowering, ownership, independent verification, emitter |
| Value and owner | Function-local ValueId/OwnerId, existing ownership products | Runtime calls borrow inputs; result ownership discharged by existing plan |

## Exact runtime behavior

ParseInt accepts an optional single ASCII `+` or `-`, followed by one or more
ASCII digits, and consumes the complete counted byte sequence. Leading zeros and
signed zero are valid. Empty/sign-only strings, whitespace anywhere, embedded
NUL, non-ASCII bytes, junk suffixes, and values outside signed Int64 are None.
Use explicit unsigned magnitude accumulation with a per-sign limit and a
pre-multiply bound check. Handle INT64_MIN without negating it or converting an
out-of-range unsigned value to signed. Parsing is locale-independent, borrows
String, and allocates no language result payload.

ReadLine strips exactly one trailing LF, retains a preceding CR, preserves all
other bytes including embedded NUL, returns Some("") for an empty LF line, and
returns Some(bytes) for a nonempty unterminated final line. Immediate EOF is None;
subsequent reads remain EOF. Proposed I/O-error behavior is None, discarding any
partial line. Use portable stdio and a temporary growing buffer with named initial
capacity, checked growth, one String allocation on success, and no surviving
buffer allocation on any path. Runtime String is already a counted byte carrier;
UTF-8 literal validation does not imply input repair. No terminal-specific EOF
clearing, prompts, global caches, or newline normalization is introduced.

Host precedents are references only: `standard_library/src/option.brp:38` declares
ordinary Option; `string.brp:372` and `io.brp:45` expose conversion/input. Host
`runtime.c:10155` uses strtol and does not meet this strict counted-byte/overflow
contract; `runtime.c:8915` uses getline plus terminal-specific EOF behavior.
Neither implementation is copied blindly. Target adapters retain upstream
revision/hash and comment out deferred declarations, transliterating non-ASCII
comment punctuation as in the existing io adapter.

## Scope, dependencies and risks

Step 5 touches syntax/parser, import loading/namespace/checking, runtime contract,
specialization, lowering visitors, verification/emission, target Option/String,
formal grammar, affected unit/grammar/e2e tests. Step 6 then adds the input helper
and io adapter. Step 7 reuses the same foundation for Boolean roles, equality and
closed arithmetic. Root owns public prose/roadmap/report and matched measurement;
independent reviewers own source and acceptance reviews. Float integration waits.

Keep main zero-argument returning Int. Preserve direct Void/String union payload
restrictions, managed-tail-match prefix restrictions, tail-loop limits, and
function generic restrictions. Calculator code uses borrowed-parameter helper
matches and performs later reads in the selected arms. Do not add nested matches,
if syntax, closures, operators, traits, FFI, Option primitive special cases,
unrelated string performance changes, or general host compiler changes.

## Testing and acceptance

Begin with baseline-compatible public-boundary callbacks and an ordinary native
fixture failing on constructor imports; retain behavioral red before production
edits. Add granular callbacks at parser, namespace, checker, specialization,
lowering, ownership insertion and independent verification. Important positives:
real imports, type-only import, arbitrary union/constructor names, reversed
variant order, two same-spelling unions remaining distinct, generic Option[Int]
and Option[String], primitive old calls unchanged. Important negatives: wrong
owner, swapped roles, duplicate roles, extra variants, wrong/missing payload,
wrong return type/purity/parameter/generic contract, unselected constructor,
import conflicts and unsupported syntax. Pin typed error, rendered message,
help and source span for each diagnostic boundary.

Native ParseInt fixtures expose exact decimal text through print (not truncated
process exit status): both bounds, adjacent overflow, long digit strings,
signs/zero/leading zeros, junk, whitespace, Unicode and NUL followed by digits.
ReadLine fixtures reuse one real executable across stdin cases: empty/EOF,
empty line, LF/CRLF, unterminated line, NUL/UTF-8, repeated reads, invalid input,
first/second-operand EOF and success `20\n22\n` -> `42\n`. Pin stdout/stderr/status.
Direct String-runtime C tests use the already-approved harness and allocator
wrappers; require borrow preservation and exact allocation/free obligations.
Forged ownership IR rejects unmanaged/borrowed managed results and wrong
union/tag contracts. Mutate one parse-boundary check and one role/tag projection
and require the relevant tests to fail; restore and rerun. Inspect flat generated
C and use strict C11 plus ASan/UBSan through existing e2e configuration.

Narrow commands after FRESH host verification are recorded under build/option_input:
`bin/blorp test --timeout 0 blorp_2/test/unit/test_option_input_phases.brp`, then
a build-once focused e2e wrapper using the normal `blorp_2/test/e2e/harness.brp`.
Final gates are unit, grammar, String runtime and the entire e2e suite, with
tooling, strict leak checks, ASan/UBSan and independent code-reviewer/test-runner
verdicts. Reuse the documented Make targets
and scripts/record-validation; do not introduce another test controller.

Proposed bounded production estimate: step 5 roughly +650–850 net lines, step 6
+100–180; report adapters separately from compiler production and tests. Stop
and consult root above +1,050 compiler/runtime production lines for steps 5–6,
excluding tests/docs and commented upstream source. Freeze current step-4 inputs
before editing; retain the prior generated-C oracle for unchanged fixtures and
require matched aggregate allocations/instructions no more than +10%. Individual
new fixture ceilings are set from retained samples. These are estimates and
acceptance ceilings, not performance claims.

Handback each increment with source fingerprint, exact changed files, red/green
and mutation receipts, generated-C inspection, costs/LOC, independent review and
remaining limits. Stop for ambiguous policy, ownership expansion, architecture
sprawl, a host compiler defect or an exceeded ceiling; report evidence and the
smallest direct alternative before proceeding.
