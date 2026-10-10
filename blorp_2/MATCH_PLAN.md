# First match increment with payloads

Status: implemented and validated; results are recorded in the
[measurement report](../benchmarks/results/blorp_2_match_2026-10-09.md).
This is the retained pre-implementation design, researched 2026-10-09;
imperatives and baseline descriptions below preserve that design context.
Read [AGENTS.md](AGENTS.md) and the parent instructions first. The starting
payload-free union working tree was uncommitted, so HEAD alone cannot identify
the frozen baseline. [README.md](README.md) and [grammar.ebnf](grammar.ebnf)
own the current supported language and contracts.

## Working example and scope

Proposed first fixture, `test/e2e/fixtures/match/value.brp`:

```blorp
fixed union Value:
    Empty
    Number(Int)
pure func unwrap(value: Value) -> Int:
    match value:
        Empty: 0
        Number(number): number
func main() -> Int:
    unwrap(Number(42))
```

Expected exit status: 42, with empty stdout and stderr. An independent native
driver must exercise `Empty` and several `Number` values, including Int64
endpoints; executing `main` alone cannot establish payload preservation.

The increment adds a match as the complete function body. The scrutinee and
each inline arm body use the existing single-line expression language,
including nested direct calls, constructor applications, and function UFCS.
A variant has no field or one `Int` field. Functions still take zero or one
parameter; constructor arity is a separate fact. A helper's declared result
may be `Int` or a declared union. The matched union and result union
can differ. `Bool`, if declared, follows this same ordinary union path.

Support bare names, `_`, and explicit constructor patterns with zero or one
field pattern. A field pattern is a binder or `_`. Whole-value bare binders
are included so Blorp's existing type-and-scope rule remains coherent.
Require a nonempty, exhaustive match with useful arms. Evaluate the scrutinee exactly once and
execute only the first matching arm's body. Check every source arm, including
ones that a constant scrutinee would never select.

Defer multiple fields, non-Int fields (including other unions), managed or
recursive payloads, generics, literal/range patterns, nested constructor
patterns and matches, multiline arm bodies, guards, or-patterns, qualified
constructors, constructor UFCS, match in call arguments, imports, and general
recursion. Existing purity, nominal typing, and acyclic-function-call rules
remain in force. This adds construction, binding, and extraction without
requiring ARC/COW or recursive layout analysis for target values yet.

## Cross-language implementation references

These are primary implementation sources, not a proposal to copy another
language's semantics. Upstream branch links describe sources inspected on
the research date; the Elm references identify release 0.19.1.

| Reference | Observed strategy | Application to Blorp 2 |
| --- | --- | --- |
| Haskell / GHC | Coverage checking lowers patterns to guard trees and checks uncovered, redundant, and inaccessible cases. Runtime matching has a separate desugaring path into Core. | Keep coverage acceptance distinct from execution lowering. GHC's guard/refinement machinery and Haskell's lazy matching semantics exceed this strict, finite-union increment. [Coverage checker](https://ghc.gitlab.haskell.org/ghc/doc/libraries/ghc-9.15-inplace/GHC-HsToCore-Pmc.html), [match desugaring](https://downloads.haskell.org/ghc/10.0.0.20260917/docs/libraries/ghc-10.0.0.20260917/src/GHC.HsToCore.Match.html). |
| OCaml | `typing/parmatch.ml` checks partial and unused cases. `lambda/matching.ml` separately groups and specializes pattern rows, compiles submatches, and combines their control flow. | Separate the correctness question from code selection. Preserve source priority and avoid duplicating arm bodies as richer patterns arrive. Irrefutable Int fields need no recursive matrix compiler yet. [Analysis](https://raw.githubusercontent.com/ocaml/ocaml/trunk/typing/parmatch.ml), [compilation overview](https://raw.githubusercontent.com/ocaml/ocaml/trunk/lambda/matching.ml). |
| Rust | Usefulness asks whether an arm covers a value absent from earlier arms; testing a wildcard against all arms establishes exhaustiveness. This runs before MIR construction. MIR lowering evaluates the scrutinee before building its decision tree and arm execution. | Use the same two correctness questions, specialized to nominal variants with irrefutable fields. Preserve scrutinee evaluation and branch execution explicitly. Rust's borrow/place machinery is not needed for these unmanaged values. [Usefulness guide](https://rustc-dev-guide.rust-lang.org/pat-exhaustive-checking.html), [MIR match builder](https://raw.githubusercontent.com/rust-lang/rust/master/compiler/rustc_mir_build/src/builder/matches/mod.rs). |
| Scala 3 | The space engine models sets of values and subtracts covered pattern spaces from the scrutinee space. A separate matcher builds and optimizes a decision plan, with switches among its output forms. | Start with finite set difference for coverage and a direct tag switch for execution. Defer subtype spaces, extractors, and decision-graph optimization. [Space engine](https://raw.githubusercontent.com/scala/scala3/main/compiler/src/dotty/tools/dotc/transform/patmat/Space.scala), [matcher](https://raw.githubusercontent.com/scala/scala3/main/compiler/src/dotty/tools/dotc/transform/PatternMatcher.scala). |
| Elm | `Nitpick.PatternMatches` simplifies canonical patterns for Maranget-style redundancy/exhaustiveness checking and produces missing-pattern witnesses. `Optimize.DecisionTree` independently chooses tests and leaves identifying source branches. | Resolve constructors before coverage analysis; report concrete missing variants. Keep arm bodies separate from coverage state. Decision-tree path selection becomes relevant when refutable nested fields introduce multiple things to inspect. [Checks](https://raw.githubusercontent.com/elm/compiler/0.19.1/compiler/src/Nitpick/PatternMatches.hs), [decision trees](https://raw.githubusercontent.com/elm/compiler/0.19.1/compiler/src/Optimize/DecisionTree.hs). |

All five references handle constructor fields. Rust's constructor/field
model and Elm's recursive pattern specialization give a direct path from
this slice to nested payload patterns. For the proposed irrefutable fields,
`Number(number)` and `Number(_)` each cover the entire `Number` constructor;
coverage still reduces to remaining variant identities. `Number(0)` would
cover only part of it and is explicitly unsupported. This specialization is
our design inference; it is not a general exhaustiveness algorithm for
payloads. Runtime execution adds a saved scrutinee and field projection to
the tag switch. Analysis and emission remain separate responsibilities.

## Grammar and layout

Use existing Blorp spelling and inline-arm syntax from
[GUIDE.md](../docs/GUIDE.md#5-pattern-matching) and
[GRAMMAR.md](../docs/GRAMMAR.md#39-patterns). The proposal below extends the
pilot's [grammar.ebnf](grammar.ebnf); it is not an implementation claim.

```ebnf
indent_one   = "\t" | "    " ;
indent_two   = "\t\t" | "        " ;
variant      = indent_one identifier spaces
               [ "(" spaces identifier spaces ")" spaces ] ;
field_pattern = "_" | identifier ;
pattern      = "_" | identifier
               | identifier spaces "(" spaces [ field_pattern ] spaces ")" ;
match_arm    = indent_two pattern spaces ":" spaces expression spaces ;
match_body   = indent_one "match" required_spaces expression spaces ":" spaces
               newline match_arm { newline match_arm } ;
body         = indent_one expression spaces | match_body ;
```

Variant annotations accept type-name syntax; checking requires `Int` for
the one-field shape. Constructor application reuses the existing zero/one
argument expression grammar; checking distinguishes it from a function call
and validates arity. A nullary constructor remains a bare expression value,
not `Empty()`. In pattern position `Empty` and `Empty()` can denote the same
nullary constructor; `Number()` is parsed but fails semantic arity checking.
Nested field patterns and field literals fail as unsupported syntax.

The function production replaces its existing indented expression with
`body`. Reserve the whole identifier `match`, alongside `func` and `pure`.
Make lone `_` a dedicated wildcard token and exclude it from identifiers,
matching the production grammar's identifier rule; `_name` remains an
identifier. Pattern names carry no parser claim that they denote
constructors. Existing ASCII, LF, byte-span,
declaration-spacing, EOF, and complete-consumption rules continue to apply.

This deliberately tightens two previously accepted identifier spellings.
The pre-increment conformance suite even accepted `func _()->_:`; replace
that synthetic acceptance case with an identifier such as `_name` and add
explicit rejections of lone `_` as a function, parameter, type, or variant
name. Add corresponding `match` keyword tests and update diagnostic help.
Reserving `_` coherently prevents an existing named constructor from
becoming impossible to select when `_` gains wildcard syntax. This is an
intentional pre-0.1 grammar change, not a compatibility shim.

Extend lexing to publish an indentation depth with its span, replacing the
single undifferentiated `Indent` symbol. A prefix is all tabs or all spaces;
space indentation uses multiples of four. Parsing requires depth one for
function bodies and union variants, and depth two for match arms. Reject
mixed prefixes and misplaced depths with exact help. No indentation stack
or synthetic DEDENT token is needed for this grammar: depth and newline
lookahead delimit arms and the next top-level declaration.

This intentionally changes lexer token traces and the owner of some layout
errors: two tabs or eight spaces previously failed in lexing, whereas a valid
depth-two prefix outside match arms will now fail in parsing. Migrate those
exact lexer/parser oracles deliberately and document the changed diagnostic
and help. Preserve unrelated semantic diagnostics and valid-program C.

Tests must cover a following function and a following union, final LF and
EOF, tab and space forms, missing or extra indentation, empty matches,
missing colons/results, and extra tokens. Unsupported block arms and nested
matches must fail without consuming a following declaration as an arm.

## Producer-to-consumer contracts

The frozen pre-increment shape was flat: `ReturnExpression` held a base,
unary-call list and span, `ParsedFunction.body` contained it directly, and
checking published `CheckedReturn`. Parsing consumed exactly one body line.
The final carriers are `ValueExpression.applications`, `CheckedValue.operations`
and the parsed/checked body sums. `ParsedMatch.keyword_span` additionally
retains the exact keyword location for coverage diagnostics. See the current
[syntax](src/syntax.brp), [checking](src/check.brp) and [parser](src/parse.brp).

Introduce a structured body with the existing straight-line expression as
its leaf. Rename the leaf to describe its broader use, without rewriting
the unary-call spine. Proposed parsed shapes:

```blorp
fixed union ParsedPattern:
    PatternName(WrittenName)
    PatternWildcard(Span)
    PatternConstructor(WrittenName, PatternFields, Span)
fixed union PatternFields:
    NoPatternFields
    OnePatternField(FieldPattern)
fixed union FieldPattern:
    FieldName(WrittenName)
    FieldWildcard(Span)
fixed record ParsedMatchArm {
    pattern: ParsedPattern,
    body: ValueExpression,
    span: Span
}
fixed record ParsedMatch {
    scrutinee: ValueExpression,
    arms: List[ParsedMatchArm],
    span: Span,
    keyword_span: Span
}
fixed union ParsedBody:
    ParsedValueBody(ValueExpression)
    ParsedMatchBody(ParsedMatch)
```

Parsed variants additionally distinguish absent payload syntax from one
written payload-type name. Checking accepts only the canonical `Int` type
identity and publishes ordered `NoPayload | IntPayload` shapes in
`CheckedUnion`, replacing `variant_count`; count is derived. `VariantId`
continues to identify owner and position. Shape, arity, and field type have
one declaration authority, not separate signature/layout registries.

The parser validates layout and nonempty arms and publishes through the
existing sealed `ParsedProgram`. Written names retain only `NameId` and
span. Parenthesized application syntax makes no claim that a target is a
function or constructor. Rename call-specific leaf carriers to application
carriers where necessary. Preserve the existing linear unary spine.

Checking returns a private resolved value containing checked code and its
`TypeRef`, shared by expected-type checking and scrutinee synthesis.
Function and constructor operations have distinct typed variants. A
transient constructor contract proves `VariantId`, arity, input field type,
and result union; it is inherently pure and is not a function signature.
Constructors never receive fabricated `FunctionId`s or enter the call graph.

Expectations flow outside-in: in `unwrap(Number(42))`, `unwrap`'s parameter
type selects `Number`'s owner, then that constructor requires an `Int`.
Resolve unambiguous function contracts once in their established diagnostic
order; complete contextual constructor contracts in an outer-to-inner walk,
then validate the spine inside-out. Represent a pending constructor with a
precise private variant until its context is available. Never publish it or
resolve a complete function contract again to recover types. Evaluation
order remains inside-out, independently of expectation propagation.

For synthesis, parameters and function results provide types. A unary call's
parameter contract still directs its argument's constructor resolution.
A constructor with no receiving type has insufficient information:
reject `match Empty:` and `match Number(42):` with help to use a typed
parameter or helper returning the union. Never guess the scrutinee union
from its first pattern or from
the containing function's result type. A synthesized `Int` scrutinee is
rejected because integer matching is outside this increment, even with `_`.

Introduce opaque, function-owned `BindingId`, distinct from `NameId`,
`VariantId`, and `FunctionId`. Its private identity can distinguish
`SoleParameter` from `ArmBinding(ordinal)` without raw integer sentinels.
Every arm binding gets a fresh identity, including the same spelling reused
in sibling arms. Parameter type remains authoritative in the signature;
arm binding origin/type is established at the checked pattern (whole
scrutinee or the constructor's Int field). A transient immutable scope maps
`NameId` to complete binding identity/type facts; checked reads contain
`BindingId`, not names. There is no second published binding registry.

Publish a checked body sum. Its match owns the checked scrutinee, resolved
`UnionId`, and ordered arms. Checked patterns distinguish a constructor case
with discarded/bound field, a wildcard, and a whole-value binding. Every
constructor belongs to the scrutinee union, arity is established, and every
arm result matches the containing function's declared return type. The
opaque `CheckedProgram` seals these guarantees. Function signatures remain
the sole authority for callable contracts and function result types.

Do not publish coverage sets, parsed names, duplicate signatures, a second
tag-to-arm table, or an `is_exhaustive` boolean. The emitter consumes checked
cases without repeating constructor resolution, type acceptance, or
coverage analysis. Builders and coverage state are local to checking and
discarded at publication.

## Pattern resolution, coverage, and diagnostic order

Follow full Blorp's type-and-scope rule, verified in
[infer.brp](../blorp/src/compiler/stage_06_typecheck/infer.brp) at
`infer_pattern`: an unshadowed constructor of the matched type denotes that
constructor; other bare names bind the whole value. A bare payload
constructor reports missing field patterns. Explicit `Number(field)` must
resolve to an unshadowed constructor; a shadowing local name is an error,
with help to rename it. Do not guess from capitalization or silently choose
a global constructor over a local name.
Shared constructor spellings across unions resolve to the scrutinee's
owner; equal variant ordinals across unions are not interchangeable.

Inside an Int field, every permitted name is a binder; `Number(Number)` is
valid and introduces a new local identity. Resolve the constructor before
introducing that arm's bindings. Bindings shadow outer names only inside
their arm; no binding leaks into sibling arms or later functions. Directly
calling a binding rejects; function UFCS still resolves its target globally
and reads its receiver in local scope. Constructor applications use direct
syntax only; a constructor UFCS target receives help to use `Number(value)`.

Coverage uses the scrutinee union's existing declaration authority:

1. Start with its complete variant identities as the remaining set.
2. A constructor arm with only binder/wildcard fields is useful only if its
   identity remains; remove it. These fields impose no additional test.
3. A wildcard or whole-value binder is useful only if some variants remain;
   it covers all of them.
4. Remaining identities after the last arm are missing cases. Render their
   names in declaration order from the existing parsed/name authority.

Begin with a local list implementation; measure representative larger
unions before introducing a set/index. Keep the coverage operation separate
from C code selection. No general pattern matrix, solver, or decision DAG
is justified yet. Before allowing nested or literal field patterns, replace
this specialized coverage operation with structural usefulness analysis;
marking an entire constructor covered by one refutable field is unsound.

Non-exhaustive matches and useless arms are compile errors in this pilot.
This is an explicit pilot acceptance policy, rather than a claim that all
five reference compilers reject them or that the old compiler already does.
A useful catch-all is consequently last; that is established by checking,
not imposed as a parser rule. Two `Number` arms are redundant even when
their binder spellings differ. Arms after a catch-all and a catch-all after
all constructors are errors. A misspelled bare name can be a binder under
full Blorp's semantics; characterize that rule instead of inventing an
uppercase-name heuristic or an unknown-pattern error for valid binders.

Preserve existing declaration/signature validation order. Within a match:
resolve/check the scrutinee first, then each arm's pattern, usefulness, and
body in source order; report missing coverage after all arms pass. Existing
call diagnostics within each leaf keep their current order. Highlight a bad
pattern at its span, a bad arm result at its expression span, and missing
coverage at the match keyword. Pin message, help, and spans in tests; for
example, missing `Number` reports `non-exhaustive match` with help
`add an arm for the missing variant: Number(_)`.

Purity checking includes scrutinee and every arm. Extend the baseline acyclic-edge
inspection in [check.brp](src/check.brp) to visit both the
scrutinee and all arm leaves, including constructor arguments. Construction
itself adds no call edge. A cycle or impure call hidden in a branch
must remain an error, even when a constant scrutinee selects another arm.

## C emission and evaluation

Keep enum storage for entirely payload-free unions. For a payload-bearing
union, emit a distinct C struct containing its enum tag and one `int64_t`
payload slot. All supported fields have this same type, so no C union of
fields is needed. Initialize both fields for every constructor, including
zero for a nullary variant's unused payload. Construction evaluates its
argument once. Source-level `fixed union` alone makes no storage or ABI
promise; this is the pilot's explicit Int-only representation choice.

Save every scrutinee in one local, then switch on its tag (or the saved
enum value for a payload-free union).
Project a field only inside its selected constructor arm. Whole-value
binding copies that saved value, including for scalar unions; it never
re-evaluates the source expression. Wildcard does not read a field. The tail-position
body still needs no result temporary, statement expression, goto, or ARC
join. These unmanaged values copy by value; this does not establish safety
or cost for future managed payloads.

Illustrative helper output, with ordinary pilot identity projection:

```c
enum blorp_tag_0{blorp_v_0_0,blorp_v_0_1};
struct blorp_u_0{enum blorp_tag_0 tag;int64_t payload;};
int64_t blorp_f_0(struct blorp_u_0 blorp_p_0){struct blorp_u_0 blorp_m_0=blorp_p_0;switch(blorp_m_0.tag){case blorp_v_0_0:return INT64_C(0);case blorp_v_0_1:default:{const int64_t blorp_b_0=blorp_m_0.payload;return blorp_b_0;}}}
```

When there is no catch-all, the final constructor arm may share its case with C's
default because checking has already proved it covers all remaining valid
values. With a wildcard or whole-value binder, only that arm emits default.
Case-local binding declarations use blocks to remain strict C11. This ensures
total C return paths without inventing
a fallback value or emitting an unreachable intrinsic or runtime panic.
Retain every explicit constructor case label. Invalid tags supplied
by external C are outside this pilot's callable contract; FFI is excluded.
This lowering must never make a non-exhaustive source program acceptable.

Preserve the previous C bytes for existing payload-free programs. Project
`SoleParameter` to the current `blorp_p_0` name and arm bindings to names
derived from their identities; no spelling lookup is needed in emission.
Only these representation/projection rules own native layout. Additional
layout identities become necessary when specialization introduces multiple
layouts for one source type, which is outside this increment.

Whitespace remains minimal. A switch adds constant structural depth as arm count grows;
do not emit a nested conditional per arm. The current unused-parameter
logic in [emit.brp](src/emit.brp) must cover match bodies. Either inspect
scrutinee and arm reads or emit a harmless `(void)` cast for every parameter
of a match-body function, and discard unused arm bindings similarly. This
needs no published usage registry and leaves prior output unchanged.

## Tests and numerical guardrails

Use Blorp `TestSuite` throughout. Extend each touched module's unit tests and
the handwritten EBNF conformance suite. Add `test/e2e/test_match.brp`; helper
modules, if genuinely needed, get their own unit suites.

- Positive cases: nullary and payload constructors, shared constructor
  spellings under different expected unions, nested function/construction
  applications and function UFCS, reversed arms, single-variant unions,
  field wildcards, whole-value binders, and ordinary declared `Bool`.
  Exercise payload-bearing union arguments/results and whole-value returns.
- Binding cases: the same name in sibling arms has distinct IDs; captures
  shadow parameters only in their own arm; a whole-value capture denotes
  the scrutinee rather than a same-named function parameter; a field named
  like a constructor is still an Int binder. Reads outside the defining arm
  reject. Direct calls to bindings reject while function UFCS still works.
- Negative cases: incomplete/duplicate coverage, wrong constructor and
  pattern arity, non-Int payload annotations, wrong payload argument type,
  shadowed explicit constructor patterns, ambiguous constructor scrutinees,
  `Int` scrutinees, nominal result mismatches, impure calls and cycles inside
  constructor arguments/scrutinees/arms, and each deferred syntax form.
  Rejection must publish no C and
  preserve an existing output file.
- Native values: strict C11 with warnings as errors, `-O2`, and UBSan;
  independent drivers compare tags and preserved payloads including zero,
  negative values, and both Int64 endpoints, plus nullary values of the
  same payload-bearing union.
- Evaluation: instrument the generated scrutinee/arm helpers in the native
  test driver with counters, asserting one scrutinee call and only the
  selected arm call. Include a payload-free union returned by a helper and
  captured by a whole-value binder, so recovering that value cannot call
  the helper again. This is test-only C instrumentation and does not add
  side-effect syntax to the pilot. Assert the instrumentation changed exactly
  the intended helpers before trusting its result.
- Oracle proofs: swap tags/results, drop or change a payload, confuse a
  captured binding with a shadowed parameter, duplicate constructor-argument
  or scrutinee evaluation, and execute both arms. Require unchanged native
  assertions to fail for each mutation. Temporarily bypass coverage acceptance and require the
  negative regression to fail too; restore the implementation afterward.
- Structure: generate 16-, 64-, and 256-variant matches in a Blorp suite,
  compile with default supported toolchain limits, run a driver over every
  variant. Include Int-payload arms with simple captured-value bodies; their
  generated helper has constant brace depth at most three (function,
  switch, and case block). Separately exercise moderately sized alternating
  construction/function spines. Record byte growth and compilation cost.

Before implementation, freeze the complete current union-source baseline,
fixture bytes, host compiler and C toolchain provenance. Run matched quiet
baseline/candidate pairs on the same existing fixtures. Planning ceilings:

- Existing fixture instruction minima: at most +5% versus that frozen
  baseline, while retaining their absolute instruction ceilings.
- Existing fixture allocations: at most +35% versus baseline; revise an
  absolute allocation ceiling only deliberately with the recorded cause.
  This allowance reflects the user's preference for clear code over small
  allocation savings, not a target to consume.
- New first fixture: at most 5,000 managed compiler allocations and
  100,000,000 retired instructions. Set these in its end-to-end test before
  implementation; report actual values and all instruction samples.
- Formatted production source: at most 3,800 lines, from the current 2,424.
  Report production, test support, and raw fixture counts separately;
  necessary correctness-test growth is allowed.
- Every normal/diagnostic pair emits identical C; all prior payload-free
  fixtures remain byte-identical; all compiler and test runs have zero leaks
  and sanitizer errors. Warm unchanged setup generates/links nothing.

The new-fixture and production-line proposals replace the earlier
constructor-only estimates (2,500 allocations / 60 million instructions /
3,100 production lines). The added constructor contracts, scope/binding
identities, and payload representation justify revisiting the estimate;
they do not justify unmeasured complexity. No existing test limits have
been changed by this plan.

These are proposed pre-implementation limits, not measured results. If a
bounded representation probe exceeds them, investigate the owning boundary
and revise or reduce the design before broad implementation. Never compress
formatting, drop coverage, or automatically raise limits to satisfy a gate.
Self-compilation is unsupported; these workload measures are explicit
owned-input proxies, not self-compile evidence.

## Implementation order and acceptance

1. Snapshot the baseline and add the first failing payload-match fixture
   plus grammar/rejection cases. Probe the host's new body/application
   carriers and the target tagged struct before broad implementation.
2. If needed, make a separately reviewed preparatory change introducing the
   body sum/value leaf, binding reads, and shared value resolution. Existing behavior, C,
   diagnostics, and costs must pass before adding match behavior. Keep the
   intentional `match`/`_`, payload syntax, and indentation-token changes in
   the feature slice.
3. Implement the complete lexer/parser/checker/emitter path. Update the
   pilot README and actual EBNF with supported rules, diagnostics, and tests.
   The production compiler's language reference remains the syntax precedent;
   do not claim this pilot increment changed production support.
4. Run focused suites while iterating, then the complete pilot gates below,
   native mutation checks, structural cases, and matched cost comparison.
   Get compiler/parser/ergonomics input and code-reviewer/test-runner review
   under the parent handoff rules before committing implementation.

Commands from the repository root, once the new suite exists:

```sh
scripts/compiler-build-status
bin/blorp test --suite --timeout 180 blorp_2/test/unit/test_check.brp
bin/blorp test --suite --timeout 180 blorp_2/test/test_grammar
make -C blorp_2 test-compiler
bin/blorp test --suite --timeout 180 blorp_2/test/e2e/test_match.brp
make -C blorp_2 test
bin/blorp test --suite --sanitize=undefined --leak-check --timeout 180 \
  blorp_2/test/unit blorp_2/test/e2e blorp_2/test/test_grammar
git diff --check
```

If host freshness is not FRESH, follow the parent rebuild instructions.
Run compiled gates serially and reuse the shared compiler. Before handback,
retain the exact source/toolchain fingerprints, normal and sanitizer logs,
generated C and mutation results, all cost samples, and separate line counts
using the repository's existing validation/cost record conventions.

Done means the example, every variant, and full-width payload results are correct;
coverage and usefulness diagnostics have exact regression oracles;
constructor-argument, scrutinee, and arm execution counts pass mutation
proofs; arm bindings have correct scope and identity; hidden arm calls
still obey purity and acyclicity; the published body contains only resolved
facts; existing C and semantic diagnostic contracts hold, and reserved-name
and layout-oracle changes are explicitly reviewed; structural and cost limits
pass; and independent reviews approve. A follow-on example such as
`Wrapped(On)` versus `Wrapped(Off)` would require union-valued payloads and
nested refutable patterns. That is the point to introduce structural
usefulness and typed projection paths. Managed payloads separately require
an ownership contract before ARC/resource preparation is added.
