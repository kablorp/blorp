# Typed tuple storage through managed records

Status: implementation and final validation complete. Tuples use the shared
managed-record storage path; ordinary tuple backend duplication is removed.
The full branch includes the independently validated
[record-construction prerequisite](tuple-record-construction.md), and is rebased
onto main `5e6ef4bcf`. All final checks pass: 4,831 runtime cases, 7,116 selected
compiler checks and 11,973 broad compiler/discovery/parity cases, plus hygiene,
generated-C review and the actual-source three-stage fixpoint. Independent review
accepts the measured full-branch cost of +15.23% retired instructions and +13.20%
allocations after removing three demonstrated quadratic copying mechanisms.
Bootstrap release/rotation and further product optimizations remain separate.

## Representation and ownership

Concrete tuple shapes receive explicit generated storage rows after local
flattening. Structural tuple identity remains in the semantic catalog; runtime
signatures and fields use managed record types. One managed-layout view supplies
source and generated records with typed fields, Unit omission and release
policies. Ordinary construction uses the checked Core product operation and
its field evaluation owners before Perceus. Inline fixed records and stack
Options remain typed fields rather than erased-slot boxes.

Dictionary entries, zip, enumerate, unfold and process interfaces use typed
native adapters. Borrowed container fields acquire owners before entering the
consuming constructor. Process result factories receive owned native outputs.
Unfold transfers owned value and successor state, installing the successor
before releasing the old state. Prepared artifacts reject inconsistent Option
representations and generated storage cycles rather than guessing a fallback.

Legacy generic tuple support remains at the pinned-bootstrap runtime boundary;
release validation and bootstrap rotation are separate work. The ordinary
compiler storage path retires tuple construction wrappers, preparation masks,
the prepared tuple renderer and duplicate dynamic/static slot emission.
Structural typing, tuple traits and local flattening remain necessary.

## Retained before evidence

The allocation controls require active counters, nonzero managed construction,
equal tuple/record costs, matching values and balanced final lifetimes. Before
this slice:

| Construction | Tuple allocations | Equivalent record allocations |
| --- | ---: | ---: |
| Two `(Int, Option[Int])` values in a list | 5 | 3 |
| Three `(Point, Int)` values in a list, with inline fixed `Point` | 7 | 4 |

The actual candidate count probe reports three versus three and four versus
four, with active counters on both sides, correct values and nine allocations
balanced by nine releases. The tuple-only element boxes have been removed.

Both value checks succeeded; the equal-cost assertions failed. The Unit tuple
construction/projection controls exposed invalid generated C before this slice.
The initial stored-tuple cancellation fixture retained 10 managed objects
(592 bytes) in an ordinary execution: 23 allocations and 13 releases. Its baseline ASan run
stopped in an internal sanitizer coroutine check, so it does not independently
establish an ownership diagnosis. Candidate ordinary and ASan execution must
both finish cleanly.

## Validation boundaries

The following entries retain the validation chronology, including intermediate
failures and incomplete snapshots. The status and final validation summary
identify the accepted source; earlier counts are not substitute final gates.

The hosted storage, native adapter and native plan suites pass 34, 17 and 20
cases respectively. Negative controls first failed before the Option replay
and generated-row cycle guards, then passed with those checks. The full compiler
source check reports no diagnostics. These results establish source and model
contracts. Actual generated native interfaces pass nine cases; allocation
equality passes two; Unit effects, updates, opaque aliases and dictionary
binder intent pass 12. The Unit trace suite also passes ASan, and the isolated
borrowed Unit projection changes from an ASan use-after-free to balanced
seven allocations/seven releases. Complex borrowed Unit receivers produce
statements without an invalid C `void` local.

Selected JSON round trips exposed a discriminator collision: product field
expressions, typed accessors and semantic accessors shared `product_field`.
The new recursive storage validator consequently required typed accessor
metadata on ordinary expressions. Typed accessors now use the explicit
`product_field_accessor` tag; expressions and semantic accessors retain their
context-owned spelling. Before the fix, seven existing round trips and two new
namespace controls failed (159/168 passed). Afterward, all 169 JSON cases pass,
including a further missing-semantic-ordinal control. Typed accessor receiver,
ordinal and field-type validation remain enforced. Preparation and final
invariant fixtures now construct lawful tuples through checked storage lowering;
their 53 and 59 cases pass with the fresh O2/O2 compiler.
The full batch of 73 selected owning suites subsequently passes all 2,703
cases with that compiler. The complete selected gate passes 6,962 checks
across 66 sources, 73 suites and six integration checks. Broader gates remain
separate requirements.
The leak gate then exposed a retained fixture that still required seven
allocations for three stored `(Point, Int)` tuples. It now requires four,
preserving active counters and the value assertion. All 16 fixed-record boundary
cases pass normal and ASan/UBSan execution. An independent counter probe reports
four allocations and the same value, with 10 allocations/10 releases overall;
its generated row stores `Point` by value. The passing selected gate includes
this fixture correction.

The broad compiler run subsequently passes 7,153 of 7,154 cases. Its only
failure describes tuple impl receivers as records after storage lowering;
the reported trait identities and call order are unchanged. Projected impl
targets must use physical types for runtime callback registration. The fixture
now recovers tuple origin from exact generated-row membership in a checked
catalog, only for `HeapRecordType` receivers. Its original tuple/tuple/record
expectations, source programs, target IDs and no-native-comparison assertion
remain intact. Both cases pass with the fresh compiler. The native planner,
adapter and Unit suites pass another 40 cases, and all nine actual native
interface cases pass. The final broad runs use that corrected source.

The pre-rebase ownership snapshot passes all 2,573 Core sanitizer cases and
1,235 leak cases, but runtime artifact generation exposes a bounded-integer
tuple mismatch.
Typecheck already widens tuple value slots to `Int`; Stage 08 retains `Range`
operands and declared tuple field types. The checked managed-layout validator
rejects those inconsistent types. The reproduction is a function returning
`(..#3, ..#3)` from two bounded indices, also reached by matrix `argmax` and
`argmin`. Stage 08 now lowers immediate tuple value slots using the accepted scalar
value rule and inserts explicit conversion nodes at bounded-value crossings,
preserving the original inner operation and its type. The six new lowering
controls fail before the repair and pass afterward; the full lowering suite
passes 168 cases, and the matrix reproduction passes all 33 cases with active
leak counters.

Native adapter planning applies the same rule to the original expected slot
before resolving aliases. This keeps nominal alias handling and exact container
matching separate from bare bounded scalar value conversion. Three added plan
controls fail before the repair; lowering, policy and planner suites pass all
205 cases afterward. Broader runtime compilation then isolates an opaque
bounded-scalar unwrap whose tuple field read was retagged to the unwrap result
type. Lowering now preserves the accepted child type and uses an explicit conversion;
exact physical identity casts disappear during runtime projection, before
ownership. The four new lowering/projection controls fail before this repair,
then all 185 cases pass. Imported inline records additionally require the
existing module-flattening type rewrite to cover cast result types. Native
planning must accept exact physical slot equality before the bounded scalar
value conversion fallback; an opaque slot can legitimately project to physical
`Range`. The imported-inline control fails before the cast rewrite, then passes with
both child and target qualified through the same authority. Exact physical
`Range` matching is a positive native-plan control; `Int` input to a `Range`
row and a still-named opaque bounded input to an `Int` row remain rejected.
All 258 lowering, flattening, projection, policy and native-plan cases pass.
The 19 actual source controls pass normal and ASan execution, including opaque
fields through direct dictionary iteration, entries, stream enumeration and
vector zip, and exactly one observable Unit call. Their leak counters balance.
The final generated C stores bounded tuple value slots as typed integers,
keeps opaque field reads at the registered type, and calls imported inline
record producers directly without a struct cast. The complete runtime gate
is a separate requirement on this frozen source.

The branch is rebased onto main `a1a960740`, including cooperative observation
of cancellation-test suspension. The pending storage implementation restored
cleanly; the inherited cancellation helpers and test registration remain in
the final validation scope. Earlier gate counts describe their recorded source
snapshots, and final validation must use the rebased source.

The next runtime artifact exposed tensor loops whose iterable was a native
typed zip call. The simple-expression emitter could not emit that adapter.
Tensor loops now evaluate their iterable through the existing scoped value
emitter, then register the iterator owner before entering the loop. All five
storage branches preserve its statements and fresh temporary sequence. The
final owning emitter controls change from 385/387 before to 387/387 after;
five zip source cases pass normally and under ASan. The cancellation control
balances 28 allocations and releases in both modes, with parent and vector
references restored. Its isolated dispatcher and explicit leak-gate launch
list both register the permanent regression.

The subsequent broad runtime artifact executes 4,172 assertions: 4,166 pass
and six dictionary ownership assertions fail before a separate null-pointer
crash. The new dictionary fixture incorrectly required allocation diagnostics
in ordinary runtime mode. Its reviewed repair keeps values and reference-count
checks unconditional, checks allocation growth and live-object restoration
when diagnostics are enabled, and rejects inconsistent diagnostic modes.
That repair still needs execution validation. Crash isolation reproduces the
failure in the validation suite; the previously suspected struct-vector suites
pass independently and together. These results are failure evidence, not a
passing runtime gate. At that historical checkpoint, fixpoint, cost and remaining broad validation were still pending.

The first parity run includes two deleted renderers because its corpus comes
from Git's index. Staging the intended additions and deletions excludes those
retired paths and includes the new fixtures; no parity-tool change is needed.

Hygiene passes after a reviewed census reconciliation: 23 added and 15 removed
identity sites, six budget increases and three owned reductions, and coverage
for the four new modules replacing the tuple renderer. Unrelated budgets,
boundary allowances and unsupported capabilities remain unchanged. Three
Stream ABI checks now delegate the existing Core type-policy classifier.
Five emitted-name producers have narrow documented spelling allowances;
three allowances for removed code are deleted. The resulting checks report
3,520 identity rows and 508 spelling findings with no stale entries.

The first integrated typed self-compile emits 84,419,060 bytes of C and builds
normal and diagnostic stage-2 compilers. It has no generic tuple storage or
preprocessor error directives. Stage 1 and stage 2 emit byte-identical C for
the retained native interface probe. Later ownership fixes require refreshed
self-compilation and the full fixpoint gate.

Dictionary entry cancellation exposed an inherited lifetime gap: the
prerequisite snapshot leaks one legacy tuple (48 bytes), while the typed
candidate leaks its entry and retained children (three objects, 155 bytes).
Direct `break` and `continue` also skip the old normal tail release. The
bounded repair gives the factory result its own backend owner, keeps the Core
binder borrowed, and closes ordinary exits with an ARC scope guard while
protecting cancellation before the first checkpoint. These direct before
runs use each compiler's runtime cache; they are reproduction evidence, not
a matched native cost measurement or current-main attribution.
The same candidate cancellation source now exits successfully with 23
allocations/23 releases and unchanged live objects and key/value references,
also under ASan. Both early-exit probes now balance lifetimes. Generated C
registers the distinct entry owner before the first body checkpoint and uses
the normal ARC guard instead of the skipped tail release. Six permanent
dictionary ownership cases pass normal and ASan execution; the native
contract controls pass seven cases in both modes.

The extended stored-tuple cancellation regression exposed another inherited
gap: List construction allocated its container before evaluating elements.
The exact final fixture leaked eight Lists and one completed tuple (496 bytes),
with 33 allocations and 24 releases. Normalizing nonliteral List elements into
owned Core bindings before container allocation repairs this at the existing
pre-Perceus evaluation boundary. Element storage metadata and static literal
trees remain intact. The same fixture now balances 26 allocations and 26
releases in normal and ASan runs; the completed first tuple receives a cleanup
frame before the later element parks. The owning normalizer suite passes 27
cases, and the record cancellation control still balances 17 allocations and
17 releases in both modes. Tuple/record allocation equality remains three
versus three and four versus four.

The broad runtime crash is traced to normalized function-valued List elements.
The shared indexed List layout policy omitted `FunctionType` from pointer
elements requiring cleanup. Individual element preparation required release,
but the List's release callback was absent. A newly named closure owner was
therefore released after a nonretaining append. The correction adds that type
to the existing container policy; alias resolution, transfer flags, normalizer
and emitter ownership paths stay in place. Four new direct, alias, construction
and allocation controls fail before it (23/27 pass). A three-case source fixture
fails with the preserved candidate compiler in ordinary and sanitizer execution,
while the current-main compiler passes it. Separately, current main's broader
validation suite passes all 93 value tests but fails lifetime checks in 21 cases.
Those are failing cases, not an aggregate object count. With the fresh candidate
compiler, the owning suite passes 27/27 cases and tuple storage passes 42/42.
The closure fixture passes 3/3 and validation passes 93/93 in normal, diagnostic
and ASan execution, with balanced diagnostic lifetimes. Generated C installs
the List release callback before borrowed appends, retains the elements and
preserves local cleanup; final Core metadata agrees. The complete runtime gate
then passes 4,831/4,831 cases. Remaining broad compiler and ownership gates are
separate requirements.

The final packet must include actual typed generated C, allocation counts,
Unit effects and sparse updates, opaque tuple captures/Options/unfold,
dictionary binder intent, process behavior, ordinary and sanitizer cancellation,
selected compiler checks, broad compiler/runtime/leak gates, hygiene, codegen
audit, fixpoint, matched O2 self-compile costs and separate production/test/doc
line accounting. No performance improvement is claimed at this checkpoint.

## Generated C review

The matched main input emits 84,239,845 bytes; the storage candidate emits
85,833,563 bytes. A structural inventory finds 169 added typed makers,
169 added reuse functions, 163 added destructors and five native factories,
accounting for all 506 added function definitions in the inventory. Seven
static typed headers replace the former erased tuple values in the invisible
codepoint range constant. Ordinary erased tuple construction, field access
and type mentions are absent from the candidate emission.

Raw scalar, managed, nested and static row exemplars have the expected typed
fields and release policies. The dictionary adapters retain borrowed managed
fields and their loop owners survive checkpoints and cancellation. Process
factories transfer owned outputs; process options preserve their snapshot
ownership. List callback installation precedes borrowed appends. This is a
structural inventory and targeted ownership review, not an authenticated
semantic correspondence proof for every generated line. Enumeration, vector
and unfold boundary coverage comes from their focused controls because those
factories are absent from this self-input emission.

The first frontier repair preserves this entire frozen-input C artifact
byte-for-byte. Further queue repairs must do the same; the actual worktree
fixpoint separately checks compiling and linking the compiler's own source.

## Matched cost measurement

The comparison compiles the same frozen main `5e6ef4bcf` input with baseline
and candidate normal/diagnostic stage-2 pairs, using Apple clang 21 and O2 for
both CLI and runtime. Each pair must emit identical C internally. The branch
comparison includes the construction prerequisite and storage implementation;
it does not isolate either change's cost. Two retired-instruction samples are
retained per compiler, with allocation counters from the diagnostic partner.
Runs are serialized; no machine-exclusive lock or wall-time improvement is
claimed.

The refreshed main baseline records 249,473,250 allocations, a minimum of
232,915,234,922 retired instructions across two samples, and 84,239,845 emitted
C bytes. Its normal and diagnostic stage-2 executables emit identical C. The
initial candidate measurement completed, but is rejected for excessive
backend cost. Allocations rise to 300,481,451 (+20.45%) and minimum retired
instructions to 1,503,667,595,231 (+545.59%). Peak RSS is 2,353,758,208 bytes
(+6.46%) and output is 85,833,563 bytes (+1.89%). The normal and diagnostic
outputs are identical within the candidate pair. These numbers include both
branch slices; they do not isolate tuple storage.

Phase timing localizes the dominant regression to backend emission, from
1,188 ms to 112,945 ms. A separate native sample and retained generated C show
the adapter planner copying and releasing its full pending-expression frontier
for every node, including leaves. `drop_last` copies a prefix, and `concat`
copies it again. The repair uses the backend's existing live-prefix stack
pattern while retaining depth-first visit order, callback order and the first
diagnostic. A direct scaling probe, unchanged emitted C and refreshed matched
costs are required before acceptance. No performance improvement is claimed.

The first queue repair passes all 32 native-plan controls. Its direct leaf
probe has balanced counters and zero live-object growth at 100, 1,000 and
5,000 nodes. At 5,000 nodes, process instructions fall from 868,315,394 to
22,257,212; these counts include process initialization and root construction,
while the allocation window covers planning alone. Planning allocations fall
from 10,002 to two, with matching releases.

The refreshed two-sample stage-2 measurement preserves the initial candidate
C byte-for-byte. Its minimum is 304,301,936,020 instructions (+30.65% against
main), with 297,159,967 allocations (+19.11%) and 2,347,876,352 bytes peak RSS
(+6.19%). Backend emission returns near baseline, but runtime projection and
late Core remain materially more expensive. This is still a cost blocker.

The cleanup-plan checkpoint includes storage validation before cleanup-plan
construction. Its allocation increase cannot be attributed to cleanup alone.
Before the second repair, two storage validation walks copied their pending expression prefixes.
A direct checked validator probe over a physical Core integer-list initializer
confirms quadratic growth: at 5,000 elements, it retires 1,624,272,873 process
instructions with 30,045 balanced window allocations. A bounded repair must
preserve collection order, first diagnostics and every representation check.

The second repair passes the extended 46-case storage suite and the 32-case
native-plan suite. Its unchanged 5,000-element validation probe reports
42,538,101 process instructions and 10,065 balanced window allocations,
with active counters and zero live-object growth. Actual C consumes the pending
owner through unique set/append operations without prefix copies.

The second-repair two-sample comparison again preserves the frozen candidate C
byte-for-byte. Minimum instructions are 281,723,208,027 (+20.96% against
main), allocations are 283,530,886 (+13.65%), and peak RSS is 2,363,015,168
bytes (+6.88%). Output remains 85,833,563 bytes (+1.89%). The storage pass
allocates 15,037,477 objects and the combined storage-validation/cleanup
checkpoint allocates 5,342,512, down from 22,106,008 and 11,903,062 before
this repair. The complete branch still has a measured compiler cost; the
comparison includes the committed construction prerequisite. Its earlier
measurement uses a different input and cannot be subtracted as a current
marginal estimate. At this second-repair checkpoint, acceptance review and final source gates remained.


A third bounded repair replaces growing breadth-first queue concatenations in
product evaluation with consuming append loops, and appends Lambda parameters
without rebuilding the previous local-variable list. The cursor and child order
stay unchanged. All 29 product-evaluation controls pass before and after, and the
combined final focused run passes 107 cases. At 5,000 elements, the unchanged
local-discovery probe falls from 483,883,250 to 67,931,479 process instructions,
and the nested-literal classifier falls from 875,215,219 to 55,824,343. Their
window allocations fall from 30,042 to 25,053 and from 10,015 to 5,027 respectively.
All six after runs have active counters, matching releases, zero live delta and
valid results. Setup and warmup lie outside the allocation window; instructions
cover the whole process. The final two-sample comparison preserves the same candidate C byte for byte.
Minimum instructions are 268,391,035,155 (+15.23% against main), allocations
are 282,412,122 (+13.20%), and peak RSS is 2,351,005,696 bytes (+6.33%). The
second retired-instruction sample is 268,956,932,477. Product evaluation allocates
3,511,644 objects, down from 4,630,408 before this repair. All three repairs retain
the initial candidate's 85,833,563-byte C artifact, SHA-256
`eb388ef942723ffa78b78da493e94753807747971de1e1015e88e77ffe976b06`.

This change intentionally adds checked storage translation and representation
validation. It has no zero-cost acceptance ceiling, and the measured remaining
cost is recorded rather than replacing those checks with guesses. Repeated
catalog/index construction and unchanged-type rebuilding are bounded follow-up
measurement candidates; sharing must preserve identity authority, diagnostic
order and validation coverage. No speed improvement is claimed. Independent review accepts the measured imposed cost after removing the three
demonstrated quadratic mechanisms. This does not establish that every residual
cost is linear or fully attributed. The refreshed final-source gates below pass.

The frozen input has a known emitted-output limitation: its absolute snapshot
module identity does not match the accepted LSP stdio bridge identity. Main
therefore emits two `#error` directives for the raw stdin/stdout wrappers.
This workload measures emitted C rather than linking it. These inherited
sites must remain the only such directives in the candidate measurement;
the actual worktree-source fixpoint must independently build and link later
compiler stages successfully. No wall-time speed improvement is claimed.

## Final source validation

The final source includes all three queue repairs. A fresh O2/O2 compiler runs
these gates serially; the earlier validation chronology remains separate.

| Check | Final result |
| --- | --- |
| Focused product/storage/native-plan controls | 107/107 |
| Selected compiler gate | 7,116/7,116; 68 sources, 78 suites, six special checks |
| Core sanitizer | 2,624/2,624, included in the selected gate |
| Leak | 1,239/1,239, included in the selected gate |
| LSP | 36/36, included in the selected gate |
| CLI / compiler tools | 158/158 and 260/260, included in the selected gate |
| Generated-C audit | 238/238 controls; one special check in the selected aggregate |
| Broad compiler, discovery and parity | 7,246/7,246; 1,060/1,060; 3,667/3,667 |
| Runtime | 4,831/4,831 |
| Hygiene | Pass |
| Actual-source compiler fixpoint | All three stages identical; both later compilers link |

Parity retains its existing bounded coverage and two known divergences; passing
this gate does not establish complete parser equivalence. The current isolated
tensor-zip cancellation case balances 30 allocations/30 releases, keeps live
objects at eight and preserves child/container reference counts. Its separate
retained sanitizer receipt is historical, while the final Core sanitizer and
leak gates above exercise the current compiler.

The actual-source fixpoint emits 84,839,168 bytes at each stage, SHA-256
`8757874b5036c1b1161f11f4a60b8eeec3bff8097e85373061d041d2d8591500`,
with no preprocessor errors. This is distinct from the frozen-main measurement
output. The measured normal stage-2 compiler is the same executable as the
actual-source fixpoint's stage 2. Compiler input hashes stay fixed during the
final gates; documentation progress edits are recorded separately. Independent
code review has no findings, and the compiler expert also audits test receipts,
counts and provenance. No merge, push or bootstrap release is part of this slice.

## Code accounting

The storage slice is measured against the committed record-construction
prerequisite; the full branch includes that prerequisite and the committed plan,
measured against main `5e6ef4bcf`. Counts include tracked and new files,
comments, blank lines and wrapping. They are physical lines, not executable LOC.

| Category | Storage added | Storage deleted | Storage net | Full branch net |
| --- | ---: | ---: | ---: | ---: |
| Production | 5,940 | 4,302 | +1,638 | +2,823 |
| Tests | 6,950 | 1,568 | +5,382 | +7,770 |
| Docs | 580 | 38 | +542 | +1,126 |
| Tooling | 77 | 28 | +49 | +390 |

Four new modules own the shared managed layout, checked tuple storage translation
and native adapter plans/emission. The ordinary tuple renderer, prepared
constructors and masks, tuple slot projections and static initializers are
removed. Logical tuple typing and flattening remain; the pin-required portion
of the legacy runtime ABI remains until bootstrap rotation. The result is a net production addition,
with most overall growth in tests. Later scalar replacement and multi-value
call designs remain in the roadmaps.

## Follow-up deletion

The next slice, based on storage commit `ce6e8156e`, removes nine dead static
tuple hex/float helpers, their private record and constants, and six unused
native tuple producers: dictionary entries, vector zip, stream unfold/enumerate
and simple process run/shell. Unfold and enumerate now require their typed
callbacks directly; successor-state installation, borrowed-field retention and
owned-pull release order are preserved. The empty dictionary native fixture
uses a typed Int/Int row factory and retains its original lifecycle assertions.

| Category | Added | Deleted | Net |
| --- | ---: | ---: | ---: |
| Production | 8 | 332 | -324 |
| Tests | 15 | 1 | +14 |

This brings production growth to +1,314 for storage and +2,499 for the full
branch against the same bases as the preceding table. Documentation changes
are additional. The cost measurements above belong to the accepted storage
commit; this deletion makes no new performance claim.

The unmodified pin `dev-dbc23276a2a6` still emits 2,402 tuple constructor calls,
2,375 release-mask setter calls and one call each to the raw command and session
wrappers while compiling the CLI. It emits no calls to the six deleted
producers. The tuple layout, destructor, constructor and setter, plus legacy
raw process option/result codecs, remain byte-identical. Their removal requires
the separately validated release and bootstrap rotation described in the plan.

The default pinned O2/O2 build passes and reports FRESH. The existing native
product harness passes all seven cases before and after deletion; the retained
after harness also passes seven ASan/UBSan cases with active allocation counters,
balanced allocations/releases and zero live delta. macOS LeakSanitizer is
unsupported, so that run disables its leak detector; managed-object leak
assertions remain active. Focused runtime and standard-library stream suites
pass 127 cases. The no-embedded-runtime static Float tuple C is byte-identical
before and after: 8,100 bytes, SHA-256
`88ac58d2df17dd5b4b912c9323780003c89aaa47200263000b29abd6dcf5be27`.
The selected gate passes 4,298 checks: 434 focused cases, 2,624 Core sanitizer
cases, 1,239 leak cases and one generated-C audit aggregate covering 238 controls.
Hygiene and artifact scan pass.

The follow-up broad compiler and runtime gates pass 7,246 and 4,831 cases.
The actual-source fixpoint links both later compilers and emits byte-identical
C in all three stages: 84,839,168 bytes, SHA-256
`9eff4f579a9e23dddbb5cb285bf0361cb43f7b83f05cdc467f6647cbd9749a13`,
with no preprocessor errors. All 3,905 frozen production and validation source
hashes remain unchanged through the gates.

Compared with the preceding storage fixpoint, compiler C has the same byte
count but a different hash. A strict comparison of 22,241,648 aligned tokens
accounts for every difference: 29,617 declared generated symbols are renamed
through a consistent bijection across 139,872 uses, and 186 diagnostic comments
change their declaration IDs. Declaration evidence covers 2,258 macros, 27,354
typed declarators and five typedefs. Strings, character and numeric literals,
punctuation, whitespace, token order and external names are otherwise exact;
there is no executable value or control-flow change. Native runtime source
deletions live in the separately linked runtime object. The original C files,
raw diff and checked symbol map are retained with the validation receipts.
