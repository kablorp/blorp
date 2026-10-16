# A smaller compiler source language

This plan owns migrations of the compiler's **own source** into a smaller
bootstrap subset. [ROADMAP.md](ROADMAP.md) owns the remaining compiler features
and the A/B/C self-compilation proof. [LIBRARY_PARITY.md](LIBRARY_PARITY.md)
owns the required host/target library interfaces. These are separate questions:
removing a source dependency does not remove an already supported input feature.

The planning baseline is `78bc406d6646eb7a1b61700b71d1faa9e9eaca09`.
Quality-roadmap work is complete. No source migration below is complete yet.
The record/reference-constant implementation stopped after its first failing
test, before production edits. Other reviewed candidates and their evidence
remain preserved; their existence does not make them bootstrap prerequisites.

## Decisions and constraints

Keep typed declaration, binding, value, layout and ownership identities; complete
immutable published facts; local builders; purity after loading; generic functions
and data; ordinary nested value construction; opaque boundaries; recursive data
actually needed by the source; ARC and explicit loop ownership. No strings in
place of identities, callback registries, hidden adapters, alternate entrypoints,
speculative caches or partial accepted products.

The intended source migrations are:

| Migrate away from | Replacement | Capability avoided or narrowed |
| --- | --- | --- |
| Record/opaque constants and initializer dependencies | Named pure construction functions; retain literal Int/Float/String constants | M5a.2 closed terms, dependency DFS and M5b opaque constant initialization |
| Control blocks inside arguments and other expression children | A preceding binding at the same execution point, with an annotation when required | General compositional expression inference and the planned workloop relocation |
| Executable lambdas, callbacks and function-typed source parameters | Existing first-order operations, explicit matches and domain loops | M7, conditional on the complete migration and sorting pilot |
| Char-valued source operations and literals | Counted integer-byte access and checked scalar encoding through String APIs | Target Char and Bytes representations |
| General-purpose String character classification/search for parser alphabets | Parser-local ASCII byte predicates | Unicode case mapping and search dependencies that have no remaining callers |
| Flat managed recursive walks | Ordinary loops with local builders | Broader managed tail-call variants; genuine managed loop edges remain required |
| Nested constructor tests | Successive matches and small shared domain helpers | General nested-pattern compilation, conditional on a bounded source pilot |
| List and String literal patterns | Length/get, indexed walks and explicit equality where the pilot proves this clean | Their corresponding pattern mechanisms, conditional on pilot economics |
| Six executable range loops | Int while loops preserving evaluated-once bounds, direction, exclusive endpoints and wrapping arithmetic | First-class range values and a separate range-loop mechanism |

Retain statement, binding, function-tail and arm-tail control positions. Keep
qualified flat constructor heads. Preserve `and`/`or`/`not`, which already have
a reviewed complete path, and top-level `?=` with real function cleanup.

Do not force all patterns or conditionals out of source. Retain flat **non-binding
constructor alternatives**: nullary constructors or constructors whose fields
are all `_`, including qualified heads. They share one body. General or-pattern
binders remain deferred. Omitted `else` is permitted in explicit statement roles,
including inherited statement arms, and in the final control position of a
function whose accepted signature returns Void, including an omitted return
annotation. Every normally completing then-path must produce Void. Other value
positions require `else`; general VoidTail discard does not relax this branch
requirement. Position comes from the body context, never from a guessed branch
result type. Genuine break/continue edges cannot be replaced by a fabricated
Void yield.

Large migrations are targets with decision gates, not permission to produce
unbounded boilerplate. If a clean migration cannot meet its scope and costs,
stop and revise the decision with two independent reviewers. Do not silently
grow a substitute language mechanism or mark its old prerequisite discharged.

## Current evidence

All 38 source modules total 28,670 physical `.brp` lines at the baseline.
A fresh existing-host Core dump corroborates 99 globals and 53 pure lambda
nodes. Source inspection classifies the other counts below; it is not a
general syntax scanner. Core-generated forms must not be counted as source.

The frozen host binary SHA-256 is
`899e0a92cfe1bc91f992bd3ccdd0755448903eb91d91780ac4870bd13d8cfa17`.
The fresh `--no-format --stop-after=lower --dump-core-after=lower` dump of
`blorp_2/src/main.brp` has SHA-256
`b128555db994c7e6a4949190e9a7075576ce7d9f4f008c4b49fe1252955aa509`.
It is an inspection artifact, not a source acceptance run or a cost measurement.

| Dependency | Baseline and counting unit |
| --- | --- |
| Globals | 40 Int, 31 String, 22 ErrorText, three Utf8Form, two Span, one SourceId |
| Constants requiring migration | 27 record declarations and one opaque declaration; references occur in ten production modules and 20 test modules |
| Higher-order calls | 64 manually classified calls: seven fills, 12 other maps, 24 Option/Result adaptations, seven `any`, 11 translations, three sort passes |
| Function values | 53 pure lambdas; one function-typed helper parameter and indirect invocation; no stored/returned callable found in the reviewed census |
| Argument controls | 16 matches requiring lifting |
| Nested pattern tests | 236 source arm headers: 226 constructor-below-constructor cases plus ten host Bool-literal cases that denote target union constructors |
| Or-patterns | 106 groups/364 alternatives; 99 fit the retained flat subset; seven can factor a common outer constructor |
| Other patterns | 25 list arms, 71 String arms, 14 Char arms; 243 qualified arm headers contain 253 qualified heads |
| Omitted else | 189 statement candidates across 25 modules; retain the bounded statement form rather than adding hundreds of source lines |
| Char dependencies | 72 ASCII expression literals, three annotations, 13 String gets, 20 numeric projections, one byte-list iteration and one scalar encoder |

These counts replace the historical estimates for planning; they do not establish
whole-source acceptance or the next parse frontier. Every migrated category gets
a fresh resolved inventory before its bootstrap dependency is removed.

## Retained recursive types

The frozen inventory matches all 549 source type headers to host Core: 182
unions, 333 records and 34 aliases. Substituted fields and unfolded aliases yield
206 union instances with 112 distinct stored union edges. Record/List children
are examined independently and cut the union-only by-value question; phantom
arguments are not storage edges. The host Bool exclusion was checked separately
as a payload-free leaf. Root independently checked the cycle result.

No multi-instance union-only cycle or variant with multiple direct self slots
appears in that inventory. Five families have one direct self slot:
`check.model.TypeRef`, `InferenceType`, `PendingOperations`,
`specialize.TypeRef` and `PartialType`. Retain their existing unary recursion
and iterative chain release, plus the existing mixed record/union/List support.
The ten generic aggregate families supply no own-parameter recursion witness.

Therefore M4.2b union-only cycles and M4.2c own-parameter recursion leave the
bootstrap critical path. Preserve their designs/candidates and existing
rejections. A new source or library declaration reopens either step only with an
exact substituted stored-payload witness and independent review. This snapshot
does not establish future layouts or runtime destruction margins.

Ordinary opaque semantics remain required: nominal identities and declaring-
module authority survive checking and semantic instance-key construction;
specialization then substitutes representation. SourceId/ModuleId/FieldId do not
become interchangeable integers. An opaque/fixed wrapper can still allocate;
inspect actual C and measure it. No constant-only opaque mechanism is needed.

## Source shapes

Construction functions are an explicit bootstrap exception to the normal
preference for constants. For example, `lex/lex.brp`'s ErrorText value becomes:

```blorp
private pure func invalid_indentation() -> ErrorText:
    {
        message = "invalid indentation",
        help = "use tabs only, or spaces in groups of four; do not mix tabs and spaces"
    }
```

`compiler_source() -> SourceId` must return the existing reserved marker from
`utils/source.brp`, not issue a fresh identity. Both `internal_span()` helpers
call that authority. Construct Utf8Form once locally when several fields are
read. Measure global-versus-function physical storage; value equivalence alone
does not prove allocation equivalence.

Lift an argument control without changing when preceding arguments execute:

```blorp
pointer_carrier = match layout.representation:
    BoxedRecursive: True
    InlineUnmanaged | InlineOwningPayload: False
Ok(pointer_carrier)
```

The retained or-group checks every alternative's visibility, union membership
and arity once. It publishes a nonempty group of accepted VariantIds, no captures
or BindingIds, and one body through specialization, lowering and ownership;
emission may use several case labels for that body. Check alternatives left to
right. A repeated or previously covered canonical VariantId fails at the
offending alternative's span, including two qualifiers for the same variant.
Different payload arities/types are acceptable only when every field is ignored
and each alternative validates independently. Verification checks every label,
checks the body once and grants no payload-projection permission to a group.
Ordinary scrutinee destruction still releases the active payload.

Flatten `Ok(Some(value))` by matching `Ok(optional)` and then `optional`.
Preserve the next arm's fallback, loop ownership and non-shadowing names. Never
duplicate a substantial action merely to remove syntax. Six representative sites
must prove the migration before the other nested tests are changed.

For higher-order code, seven constant fills use existing `repeat`. Eleven
`translated_list` calls coalesce into eight typed domain traversals, retaining
the existing child translator and first-error order. Do not replace callbacks
with a task enum or dispatch framework.

The three layout sort passes become one stable domain ordering operation over
the existing key and its projections: depth is stored; rank and nominal ordinal
are derived from its typed terminal. No decorated-key cache is needed.
Preserve left-first ties and adjacent deduplication. Target List append/set
currently copy a fresh root; a linear comparison count does not establish linear
construction cost. Sorting is a separate pilot, not a mechanical rewrite.

## String and library boundary

Use two explicit, matching public interfaces in the host and temporary library:

```blorp
pure func byte_at(value: String, index: Int) -> Option[Int]
pure func from_codepoint(value: Int) -> Option[String]
```

`byte_at` returns an unsigned byte 0–255 or None outside the counted String.
`from_codepoint` rejects negative values, D800–DFFF and values above 10FFFF
**before narrowing**; every other scalar, including NUL and noncharacters,
produces its exact UTF-8 bytes. Host wrappers may use Char internally. Target
operations use existing String/Int/Option representations. An owning Some[String]
must use the ordinary union transfer/destruction path, not a numeric adapter.

Keep raw UTF-8 validation, exact error priority and half-open byte spans. Keep
existing unsupported Char-input diagnostics. Replacing source Char values does
not authorize ASCII-only text or reconstruction of raw byte slices as scalars.

All current String lower/index_of/contains source calls serve parser ASCII
alphabets. Two private digit-value helpers and the existing type-parameter
validator replace them; no shared classifier is needed. Preserve consumption of
a seventh hexadecimal digit and malformed-unit extents. A fabricated Float token
spelled "0" or "-0" currently gets the leading-zero diagnostic because an empty
substring passes contains. Preserve that absent-byte result explicitly at that
callsite, not in the digit helper. Preserve forged integer-token validation too.
Remove library search/lower requirements only after the source patch and a fresh
resolved call inventory; public String semantics do not change.

Byte-exact substring, starts_with, concatenation and large List[String].join
still need real library implementations. Host join uses a capacity-aware append
operation; naive immutable concat can restore quadratic copying. Measure a direct
Blorp candidate; if it fails the gate, review one concrete counted join operation
over the existing List[String] representation. No general String builder or new
managed buffer type follows automatically.

New library wrappers require a verified explicit host source-library selection.
Native helper additions require a supporting host with the new runtime and
ownership contracts embedded. `--std-dir` supplies source, not native runtime.
Validate that transition once, then freeze a single host/library/toolchain for
each matched baseline/candidate comparison.

## Delivery order and parallel ownership

1. **Scope and plan:** finish independent type/ownership and architecture review;
   update ROADMAP and parity requirements. Commit the reviewed plan first.
2. **Small source preparation:** construction functions and argument lifting as
   separate green refactors. No record/reference constant implementation.
3. **First-order pilots:** fills, a coalesced type translator and stable layout
   ordering. Then migrate remaining callbacks in bounded module groups.
4. **Library foundation:** host String wrappers/availability, two target String
   operations, ASCII predicates and the four-consumer Char migration.
5. **Retained control/ownership:** accept reviewed logical operators, restricted
   if, outer-variable joins, top-level propagation/local annotations and managed
   List/while loops. Follow [M3's carried-owner protocol](ROADMAP.md#m3-loops-and-tail-recursion):
   acquire borrowed entry values, track each carried ownership occurrence,
   acquire next values before retiring old ones, and verify condition-false,
   break, continue and backedge cleanup independently. An omitted-else branch
   updating an outer accumulator needs both normal edges to carry that binding;
   today's Void-only join cannot supply that contract by itself.
6. **Required type completion:** ordinary opaque admission/erasure over the
   retained recursive shapes. Recheck the post-migration and target-library
   stored graph; do not implement M4.2b/2c without a real witness.
7. **Pattern source pilot:** qualified flat groups and six nested-test rewrites;
   measure before migrating the remaining nested/list/String cases. Six range
   loops become Int while loops preserving ascending AND descending exclusive
   ranges: evaluate start then end once, choose the original direction, increment
   after the body, and preserve an error break that skips the increment. These
   six sites have no continue/captured binder; retain distinct cursor names and
   each managed operand cleanup. Flat recursive walks become ordinary loops.
8. **Library/shell parity:** remaining first-order numeric, String/List and the
   seven-function OS/path surface in ROADMAP. No new Path type, process API,
   directory traversal, environment API, FFI or atomic-publication mechanism.
9. **Actual bootstrap proof:** source inventory has no deferred requirement;
   run the unchanged M8 proof on real sources and the real temporary library.

This is dependency order, not an instruction to make unrelated writers wait.
Host-library/runtime work can overlap disjoint compiler-source preparations.
Compiler builtin/contract changes have one writer at a time; source changes in
shared check/specialize/emit owners land in a declared order. Every writing
subthread gets its own worktree and branch. Read-only threads can share a pinned
checkout. At most eight active subthreads; no forced parallelism. Coordinator
integrates; compiled tests, native builds and measurements remain serialized.

## Acceptance and cost boundaries

Before every code slice: exact fixture/contract, characterization or semantic red,
physical production/test/fixture budget, shortest owning test, declared failure
priority and two review assignments. Source refactors need passing baseline
characterization and sensitive mutations; do not manufacture a fake regression.
New input features need an actual callback/native behavioral red before code.

Source pilot ceilings (a brief may set stricter bounds; increases need review
before implementation):

| Pilot | Gross added production | Net production |
| --- | ---: | ---: |
| 28 construction functions and uses | 300 | +80 |
| 16 argument-control lifts | 250 | +60 |
| Six representative nested tests | 160 | +40 |
| Seven fill maps | 40 | +14 |
| Three type translations coalesced | 100 | +48 |
| Stable layout ordering decision | 250 | +100 |

The retained non-binding pattern-group feature has a separate ceiling of 650
gross added / +450 net production lines, not the six-site source pilot's budget.

Whole callback removal is estimated at +442–739 net; it needs a complete reviewed
patch estimate and cumulative ceiling before broad implementation. Do not stack
small pilot allowances to hide total growth. Full pattern migration similarly
needs a revised estimate after the six-site pilot; the old +1,300–2,300 estimate
included discarded no-else/or-duplication rules and is not an approved allowance.

Source refactors target and cap +3% allocations and normal minimum-of-three
instructions on every unchanged owned input and the frozen-host source-to-C
proxy, both locally and cumulatively against the frozen reset source baseline.
Use the immediately preceding accepted source for local comparisons, one physical input path,
strict leak/count runs separately, and one current full acceptance after source
integration. Preserve old measurements as historical rather than rerunning them
against obsolete bases. Feature slices keep their owning reviewed ceilings;
new library/runtime slices set numerical budgets before implementation.
A necessary host/runtime transition starts one explicit matched measurement
epoch: measure and report the transition cost separately, then rebuild both reset
baseline and candidate with that same frozen host. Changing epochs cannot hide
source-migration cost.

Report gross/net production, tests and fixtures separately. Reject compressed
formatting, deleted coverage, new tables without a measured query, or semantic
special cases intended only to move counters. A justified minor inefficiency
names its owner, observed cost and credible later remedy; it never waives an
existing hard ceiling silently.

Tests inspect identities, complete typed rows, scope and contextual types;
fallback and evaluation order; loop-carried owners and borrow dependencies;
acquire-before-retire, every exit, ignored managed payloads, and forged IR that
the independent verifier must reject. Runtime helpers need separate actual
destruction checks. E2e uses unchanged C and real main at O0 with sanitizers.
Preserve existing fixture C/diagnostics unless an intentional change is reviewed.

Scaling controls use N=16/32/64/128 with construction work, emitted size/depth and
default toolchain limits recorded. Inventory actual parsed, checked, pending,
specialized, lowered and owned product depths separately from construction and
traversal stack depth. Compare each retained shape/helper path with release
margins under matching stack, toolchain and sanitizer profiles; the historical
syntax-based "about 200" estimate cannot discharge this gate. Inadequate margins
stop for review; boxing alone does not prove constant stack. Run focused owners, then the pilot Make gate and
frontier. M8 still requires O2 A/B/C, B==C emitted C, A==B on all fixtures and the
full e2e suite under B. Parser coverage alone is not self-compilation.
