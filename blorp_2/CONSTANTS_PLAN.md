# M5 constants: fresh producer-to-consumer plan

Proposal for root and independent compiler-expert review; no implementation is
authorized by this document. Baseline is main
`e24ca0f251fa3a7b63990141c3352df8097848f8`, plus the accepted quality contracts.
The old `blorp2/constants` tip `cc07e5f19` is a read-only design reference:
its obsolete namespace and unfinished expression/lowering path will not land.

## Inventory and prerequisite

A preliminary source-form census finds **99 annotated declaration candidates** across
34 source modules: 40 Int, 31 String, 22 ErrorText records, three Utf8Form
records, two Span records and one SourceId. Two String constants use pipe
multiline literals. These supersede the roadmap's stale 64/89 estimates, but
99 is presently a source-form census, not a parser-complete inventory.
The immutable base above identifies the inspected source. Optional raw local
census/manifests remain under ignored `build/roadmap-constants/`; this plan
does not depend on those files to resume work.

The existing `test_parse/test_source_tree.brp` approach must be extended in a
temporary Blorp TestSuite probe to enumerate `module_contents(...).constants`
for every accepted module, retaining first diagnostics for rejected files.
Do not report a complete total from the accepted subset alone. Source audit
of the two known parser gaps finds 34 candidates in `lex/lex.brp` (22 ErrorText,
three Utf8Form, nine Int), with Char syntax later in that file; and zero in
`specialize/specialize.brp`, whose function-type parameter is at line 487.
The proposed parser inventory remains an explicit prerequisite before coding.

**M5a** implements the 96 nonopaque shapes and the entire reference-to-runtime
path. **M5b depends on M4's ordinary opaque semantics** for
`COMPILER_SOURCE: SourceId = into_opaque SourceId(COMPILER_SOURCE_NUMBER)` and
both `INTERNAL_SPAN` constants. The Span fields reference the opaque SourceId.
There is no SourceId-specific exception, erased TypeHead, manufactured function
identity, or constant-only opaque representation. Public opaque type references
must cross modules; M4 must settle that only construction/projection authority
is restricted to the declaring module. Its current wording is ambiguous here.
Do not call M5 complete until all inventoried shapes pass after M4, and refresh
the inventory at that point.

## First complete example and semantics

```blorp
ANSWER: Int = 23

func main() -> Int:
    ANSWER
```

The ordinary main must exit 23 with empty stdout/stderr. The test must fail on
the frozen baseline with its exact ModuleConstant error before implementation.
The next complete examples add typed Strings and records, then references:

```blorp
fixed record Pair { left: Int, right: Int }

private PAIR: Pair = { left = ANSWER, right = 17 }
ANSWER: Int = 23

func main() -> Int:
    PAIR.left
```

Explicit annotations are required and fully resolved, including applied record
arguments. Constants have no parameters or function context. Initializers are
only parsed Int/Float/String literals, record literals of admitted closed terms,
and bare/qualified constant references. M5b also admits ordinary checked opaque
wrapping of such a term. Grouping is transparent; postfix field/call/update,
lists, variants, Void, match/if/logical expressions, functions and closures are
outside this increment. Pure calls are not constant expressions. Unknown names
and unsupported initializer forms are typed rejections, not evaluation attempts.

All declarations, including unused constants, are checked. All annotations are
accepted before initializers, permitting forward references. Initializer errors
are selected in module/source order; after they pass, dependency cycles report
the first deterministic closing read. Only reachable runtime uses materialize.

```blorp
-- config.brp
VALUE: Int = 23
private HIDDEN: Int = 17

-- main.brp
import:
    ./config as Config: VALUE

func main() -> Int:
    Config.VALUE
```

Selections and qualified reads denote the same ConstantId. They obey current
visibility, no-reexport, prelude and import-origin rules. Constants share the
value space with functions/constructors, are not callable or UFCS methods, and
participate in the accepted no-shadowing rule. A public constant annotation
cannot expose a private type, using the accepted TypeScope access check.

## Fact ownership and one-way pipeline

1. **Parsing/assembly:** reuse ParsedConstant and already-decoded literal values.
   Assembly issues dense opaque ConstantId values alongside FunctionId/RecordId
   in DeclarationInventory, once per compilation. Add ConstantRow and an accessor;
   remove the parallel raw constants list from sealed ParsedContents. Parsing's
   per-module raw syntax and the assembly builder are temporary construction data.
2. **Namespace:** add Entity.Constant, NamedConstant and OfferedConstant to the
   existing value-space projections. Extend the existing source-order cursor merge
   to include constants; `enter` remains the only collision authority and `offer`
   the only export authority. No second registry, import scan or spelling lookup.
   Include every exhaustive Entity/NamedValue consumer, diagnostic and binding check.
   In particular, exercise a same-spelling type and constant import: the existing
   Ambiguous diagnostic must not assume the value declaration is a function.
   Keep one namespace authority and reuse the existing diagnostic design.
3. **Checking:** temporary headers resolve every annotation through existing
   resolve_type/TypeScope and declaration facts. A narrow closed-initializer
   checker consumes those complete types. It reuses parser-decoded numbers/Strings,
   same_type and record type substitution. Extract only record field admission
   (known names, duplicate/missing fields, written evaluation order and FieldIds)
   from current record planning; only missing-field selection follows declaration
   order. Prove that preparation semantics-preserving with paired written-order
   and error-priority tests before using it for constants. Do not
   construct a fake Caller.FunctionId or add another record field solver.
4. **Checked publication:** one dense CheckedConstant table owns the accepted
   annotation and closed term; bodies contain CheckedForm.ReadConstant(ConstantId)
   with their own TypeRef and use span, like other checked expressions. A closed
   term's precise form admits only integer/float/String, ordered record fields and
   ConstantId references; it cannot store calls or bindings. References are resolved
   once and carry their source occurrence for errors. Temporary header/type builder
   state is discarded when the complete table freezes. No optional accepted rows.
5. **Dependency validation:** a local dense visit builder and explicit DFS frames
   validate ConstantId edges once, with stable source-order roots/children. Edges
   come from the closed reference terms; they are not reconstructed from text.
   Temporary edge/visit/work data is discarded; the published typed term graph is
   acyclic. Self and multi-node cycles carry declaration IDs plus the closing-read
   span; diagnostics can recover declaration names/spans from the parsed inventory.
6. **Specialize → lower (proposed simplification):** specialization projects a
   ReadConstant's sealed closed term into existing ConcreteExpr literal/record
   forms, using accepted RecordId→RecordInstanceId translation. It substitutes no
   new semantic facts or source strings. Concrete nodes carry the read occurrence's
   span. Lowering's existing literal/record path then creates fresh ValueIds for
   each use. There is no concrete constant identity/table or new lower value form.
   This is a deliberate roadmap delta from the unimplemented ConstantReference
   and placeholder identity `evaluate` phase; both would add indirection here.
7. **Ownership/verify/emit:** unchanged semantic forms. Existing literal and managed
   record ownership inserts dup/drop, independent verification checks it, and C
   emission projects it. Each String/managed record use has ordinary scoped lifetime.
   There is no global owner, immortal storage, startup evaluation or new runtime ABI.

Projection/materialization does work proportional to the expanded value and
emitted program: repeated reads can repeat allocations and expansion. A declaration
DAG can denote a much larger expanded value. Measure that limitation explicitly;
do not disguise it with a cache or silently cap valid source. Static data/CTFE and
shared dependency materialization remain separate designs requiring approval.
Do not publish duplicate dependency tables with no downstream consumer.

## Diagnostics and examples to pin

```blorp
A: Int = B
B: Int = A                  -- cycle at the B initializer's A read
BAD: Int = "wrong"           -- exact ordinary annotation mismatch
CALL: Int = helper()         -- closed-initializer rejection, even if pure
```

Reuse ordinary unknown-name/type, record-field, qualified visibility and annotation
mismatch errors. Add only these constant-specific cases to a typed ConstantError
union; these are proposed exact renderings for review:

| Typed kind | Exact message | Exact help | Primary span and note authority |
| --- | --- | --- | --- |
| `CyclicInitialization(reached: ConstantId)` | `constant initialization contains a dependency cycle` | `remove a constant reference from the cycle, or compute the value in a function` | Full closing-read occurrence, including its SourceId, from the closed term; existing `Declaration(span)` note at the reached constant's declaration-name span from inventory. Its existing shell text is `note: declared here`; no custom-note framework or unused cycle-path list. Applies in M5a.2. |
| `NonClosedInitializer` | `constant initializer is not a closed value` | M5a.1: `use an Int, Float, or String literal` | Full offending ValueExpression.span, including grouping and SourceId; recurse into admitted records in M5a.2 so a nested call points at that child's complete expression. No note. |
| `NonClosedInitializer` | `constant initializer is not a closed value` | M5a.2: `use an Int, Float, or String literal, a record of closed values, or a constant reference` | Same authority and no-note policy. M5b separately updates the admitted-form help after opaque support. |
| `ConstantCalled(ANSWER)` | `constant 'ANSWER' cannot be called` | `read the constant without parentheses, such as ANSWER` | Full WrittenName.span of the callee, including SourceId; for `Config.ANSWER()`, the member's WrittenName.span as in existing qualified-call diagnostics. Name spelling comes from ConstantId's inventory row at rendering. No note. |

For `CALL: Int = helper()` the nonclosed-form error wins without evaluating or
resolving the call. For body `ANSWER()` the ConstantCalled error applies. In the
two-node cycle above, the primary is the A read in B's initializer and the note
is A's declaration name, never a guessed span or a synthetic compiler source.
Do not infer a constant from uppercase spelling. Tests distinguish equal NameIds
in different modules from declaration ConstantIds, and same spelling with unrelated
module ownership. `private` and shadowing tests use the accepted quality contracts.

## Bounded delivery and numerical acceptance

Two full-path feature slices, each red→green and independently reviewed before
landing. Any necessary record-admission extraction is a separate, reviewed and
gated semantics-preserving preparatory commit, included in the combined caps;
it is not a third feature slice or permission for broader constructor cleanup.

1. **M5a.1:** scalar/String declarations, inventory/namespace/annotation authority,
   body reads, specialization projection, ordinary lower/ownership path, exact
   nonclosed errors. Goal +280 net production; hard +360 net / 440 added.
   Body ReadConstant is needed here; do not publish unused initializer-reference
   variants, dependency rows or DFS scaffolding until M5a.2 needs them.
2. **M5a.2:** semantics-preserving record admission preparation, closed records,
   forward/imported dependencies and cycle verification. Combined M5a goal
   +500 net production; hard +600 net / 750 added. Tests excluding fixtures are
   estimated +1,100; fixtures +180, reported separately with actual physical counts.
   Exceeding a hard cap requires root/expert rescoping, not compressed formatting.

Freeze the host, base/candidate inputs and binaries before any measurements.
On every unchanged accepted/rejected input, normal minimum-of-three serial
retired instructions target ≤+5%, hard ≤+10%; strict allocation runs separately
target ≤+5%, hard ≤+10%. Frozen-host build of base/candidate compiler sources is
an explicitly labelled selfcompile proxy: hard +8% instructions/+10% allocations.
Investigate repeatable increases at their owner; root may rescope before approval.
Accepted old C must remain byte-identical; only the explicit constant rejection
cases change outcomes. New feature inputs have no old successful compile baseline:
do not compare candidate success cost with baseline rejection cost.

Use explicit paired literal/reference fixtures only as declared controls, never
rewrite normal e2e inputs. Record 16/32/64/128 declarations and references, forward
chains, wide records and a small shared-dependency DAG; distinguish input size,
expanded term size and generated C size. Expected constant work is linear in
syntax plus reference edges plus expanded output. Investigate near-quadratic
dense-table lookups or retained builder copying before landing. Record C structural
depth and compile with default Clang limits; preserve and report any failure before
proposing backend scope expansion.

## Tests and review

Use TestSuite callbacks and aligned multiline source strings; no process per
semantic test. Granular suites cover IDs/assembly, namespace conflicts/origins,
closed terms/types, graph cycles/forward imports, expression reads, specialization
layout identity/spans, lower fresh ValueIds and owner obligations, independent
malformed-IR negatives, and emission fragments. Check exact error kind, full Span
including SourceId, message/help and note. No integration-only proof of phase facts.

E2e cases run real main, unchanged C, -O0/ASan/UBSan: Int/Float exact outcomes,
String bytes including Unicode/multiline, scalar and managed records, imported and
forward references, aliasing/reassignment/drop of materialized String values, two
uses with distinct ownership, and precise rejected cycles/calls/private access.
Read C and require strict zero leaks. Existing runtime helpers need no new ABI.

Record coverage includes an outer record containing `Cell[String]`, a repeated
reference to that constant and exact concrete layout identity. Reuse the existing
root-TypeRef `prepare_record` path to reach nested layouts; add no constant-only
layout collector. Preserve the existing written-field-order test and add paired
field-error-priority checks around the preparatory extraction.

Kill at least: wrong ConstantId resolution, skipped cycle edge, bypassed annotation
mismatch, lost use span, incorrectly reused materialized ValueId, and omitted
managed-field drop. Restore and rerun owning tests. Root plus a separate compiler
expert review each commit, with an independent test-runner and doc/grammar review.
Broad owning unit/e2e, accepted C identity, rejected diagnostics, shared-input costs
and host-build proxy gate follow the focused loops. M5b gets its own reviewed
delta after M4, not unused scaffolding in M5a.

## Established practice and deliberate limits

[Rust constants](https://doc.rust-lang.org/reference/items/constant-items.html)
have explicit types, occupy the value namespace and behave as values substituted
at uses, including managed values whose destruction follows the use scope.
This supports the bounded Blorp materialize-at-use policy; it does not require
Rust's runtime representation. [rustc's const-eval design](https://rustc-dev-guide.rust-lang.org/const-eval.html)
separates checked representation from evaluation and keeps declaration/instance
identity explicit. The inference for this increment is narrower: closed literal
terms need typed admission and an acyclic reference graph, not an interpreter,
MIR evaluator or query/cache infrastructure.

## Handoff and stop conditions

Root owns integration and shared documentation. A compiler expert implements
each bounded slice after the inventory prerequisite; root and a separate expert
review its resulting code, and an independent test runner verifies the final
tree. All compiled commands require root's serialized slot and the frozen host.
Return precise production/test/fixture counts, source and toolchain identities,
focused red/green and mutation outcomes, C identity, cost evidence and remaining
limits. Stop on an unresolved authority, host fault, repeated cost breach or
need to expand the model; do not add an unreviewed mechanism or silently weaken
the acceptance criteria. The existing M5 WIP remains untouched.
