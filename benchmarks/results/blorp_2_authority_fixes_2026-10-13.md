# Blorp 2 authority and admission fixes

Baseline: local `blorp-2` at `a16328a59`. Work is isolated on
`codex/blorp-2-authority-fixes`; the preserved dirty checkout remains untouched.
This plan follows the current-code audit, not the earlier unported tree.

## Approved scope and order

1. Remove nine actual tuple matches from production compiler source. Equality
   dispatch must exhaust the left-hand variants so additions cannot silently
   compare unequal. Preserve evaluation order and exact diagnostics.
2. Repair concrete instantiation admission and diagnostic provenance. Check
   known invalid nominal applications even in unused declarations. Preserve
   useful Void arguments such as Maybe[Void]; do not ban Void generically.
3. Publish validated namespace facts and create declaration identities once.
   Keep type-directed UFCS selection in checking, separate from name visibility.
   Establish the inventory's owner before changing declaration carriers.
4. Establish ownership facts before insertion, and consume them in insertion
   and independent verification. Retain transformed-IR integrity checks.
5. Strengthen specialization's preparation contract and its direct tests where
   a concrete gap is demonstrated. A one-pass rewrite is not an acceptance goal.

The first and second slices start independently in design, with tuple edits
settled before overlapping checker edits. Namespace design can proceed while
admission is implemented; shared model/signature edits are serialized. Ownership
design is independent, but specialization edits coordinate with admission.
Every slice is reviewed by a different compiler expert before commit.

For example, `builtins.brp` currently ends role equality with a wildcard:

```blorp
match (left, right):
    (IntegerType, IntegerType): True
    (FloatType, FloatType): True
    (StringType, StringType): True
    (VoidType, VoidType): True
    (ListType, ListType): True
    _: False
```

The replacement exhausts the left domain, making a future role require a case:

```blorp
match left:
    IntegerType:
        match right:
            IntegerType: True
            _: False
    FloatType:
        match right:
            FloatType: True
            _: False
    StringType:
        match right:
            StringType: True
            _: False
    VoidType:
        match right:
            VoidType: True
            _: False
    ListType:
        match right:
            ListType: True
            _: False
```

Exhaustive dispatch may add a small number of production lines; report the
necessary subset/correctness growth rather than compressing it to hide the cost.

## Reproductions and intended behavior

The retained eight Blorp observations are in
`build/audit-current/test_findings.brp` (receipt `findings-5`). They exercise the
real parser/check/specialization APIs, not separate fixture entrypoints.

```blorp
fixed record Values[T] { items: List[T] }
func unused(value: Values[Int]) -> Int:
    0
func main() -> Int:
    0
```

Currently checking and specialization both accept this invalid concrete type
because specialization never visits the unused function. Checking must reject
its known String-only List requirement at the written application.

```blorp
fixed union Values[T]:
    Empty
    Items(List[T])
pure func make() -> Values[Int]:
    Empty
func main() -> Int:
    saved = make()
    0
```

Currently checking accepts and specialization rejects. The same admission rule
must reject while checking. Nested record/union requirements, symbolic forwarding
and phantom parameters require distinct positive and negative tests.

```blorp
pure func identity[T](value: T) -> T:
    value
func discard[T](value: T) -> Int:
    saved = identity(value)
    0
func main() -> Int:
    discard(void)
```

The existing specialization rejection points at identity's return T. Preserve
the pure-result rule and improve instantiation provenance. A symbolic requirement
may survive until concrete substitution supplies the missing fact; represent
that contract explicitly rather than deleting the final guard prematurely.
No public inference variables or second monomorphizer may be introduced.

The bounded admission implementation derives String-element requirements while
the existing finite-declaration walk completes each nominal declaration, then
freezes a checking-local summary. It admits every written concrete annotation
and newly closed generic call against that summary, without expanding all field
trees at every use. It is not a generic call-graph constraint solver: transitive
pure-result requirements that become concrete only during specialization retain
their existing guard, using the already-carried instantiating request location.

## Authority contracts

Declaration identity belongs to one program inventory, independently of whether
a declaration is visible or semantically accepted. Its producer publishes rows
with identity and declaration; consumers retain that identity through checking.
Namespace construction reports visibility/name conflicts and returns a validated
product or typed failure. Accepted signatures and receiver compatibility stay in
checking. Preserve definition-site resolution, import provenance and deterministic
error order; any intentional priority change gets exact diagnostic tests.

Concrete layout facts precede ownership insertion. The trusted producer owns
storage/child-ownership classification and is tested across all supported shapes.
Insertion plans owners and borrows from those facts; verification independently
simulates actual ownership operations against the same published contracts.
Sharing insertion policy or its intended edits is forbidden. Unknown shapes reject.
Do not duplicate semantic fields into a second managed-field inventory.

The current concrete representation fields already contain that fact. Relocate
`ValueOwnership` and its read-only projection from `own` to the existing
`specialize` authority; both insertion and verification import it there. Add no
catalogue or representation fields. Preserve exact diagnostics, and test the
producer separately from independent owner-transition corruption tests.

Verification also checks raw transformed-IR membership, value/operation and
call contracts, projections, arm coverage and layout consistency. These checks
validate compiler transformations against accepted facts; they do not become a
second source-language acceptance authority. Do not remove existing independent
negative tests to make the implementation easier.

## Tests and performance acceptance

Use Blorp TestSuite unit tests first, with exact typed errors/message/help/span,
plus normal-main e2e rejections/positives. Preserve the approved runtime-helper C
tests and actual allocator/free oracles. Add producer tests, independent raw-IR
negative tests and mutation oracles for ownership. No host compiler edits, general
List/updates/recursion feature, runtime tracing, framework or cache is authorized.
The suspected ordinary/applied-union equality bug remains reproduction-gated;
do not change equality merely to accept a noncanonical raw representation.

Freeze the current same-host O0 diagnostic pilot, source, actual target library
and all 36 existing controls/features under `build/authority-fixes/`. Both sides
must compile unchanged inputs against the same frozen library. Use three paired
samples with stable allocations, minimum retired instructions, strict balance,
identical executed/output paths, input/C/binary hashes and sampled machine activity.
This whole-CLI proxy compares against the accepted current feature set, unlike
the earlier pre-feature baseline. Self-compilation remains unavailable.

Refactor-only slices allow at most +3% allocations and +3% retired instructions
per common input, require identical emitted fixture C, and aim to reduce production
lines. Admission correctness allows at most +5% in each metric for necessary new
checks, targeting +3%; investigate repeatable excess and reject/rescope above the
ceiling. Combined acceptance uses the +5% ceiling, with each refactor assessed
separately where its effect is separable. Keep all existing e2e caps. No new
superlinear algorithm, per-use declaration reconstruction or repeated growing
collection copying is acceptable. Record production and test LOC separately.

Serialize compiled commands on macOS. The root coordinator owns the lane unless
explicitly handed to a test-runner. Before integration: focused suites, complete
sanitized unit/runtime/grammar, real-main e2e, generated C/ownership inspection and
matched costs. Reviewers inspect exact source and executable provenance, rather
than treating a green source check as native acceptance.

## Release and handback

Commit this reviewed plan before implementation. Implement and independently
review bounded slices; do not merge or push automatically. Handbacks identify
exact files, semantics, tests, red/green evidence, remaining uncertainty and costs.
Stop and consult the coordinator if a private builder would leak into public
facts, a proposed remedy needs a new mechanism, a phase owner is ambiguous, or a
gate/ceiling fails. Adjacent desirable changes remain separate work.

## Tuple slice evidence

Nine actual tuple matches were replaced; two remaining parenthesized production
matches contain scalar calls. Closed role/type-candidate dispatch exhausts its
left domain. Six production files grow by 54 physical lines; two test files grow
by 55. This is the subset/correctness growth anticipated above.

The seven focused native suites pass 176 callbacks (`tuple-green`). The new
candidate matrix was independently exercised through a single-callback Blorp
suite: changing Int self-equality to False fails exactly that callback
(`tuple-matrix-oracle-3`); restoring the frozen source passes
(`tuple-matrix-restored-2`). Earlier broad mutation attempts broke namespace
closure convergence, and earlier scratch harness attempts failed authoring;
those retained receipts are excluded from acceptance evidence.

The frozen baseline binary is SHA-256
`2f6c8a0f5188336ccb944281dcdd2d4e4a661802d80d66168f89c36b7ae3b508`;
the host is `7c28b09440cfabed7bd4140f6dd46287f9fe82be43f1cec56cc6156ba712c900`.
The tuple candidate was generated with that host and linked at `-O0` with
`BLORP_MEMORY_DIAGNOSTICS=1`. Its build receipts, frozen patch/hashes, all raw
samples and sampled process activity are under `build/authority-fixes/`.

`tuple-cost-receipt` records 216 paired samples over all 36 frozen unchanged
inputs, three per binary/input. Allocations were stable, balanced and unchanged;
the largest minimum-retired-instruction increase was 0.139%, within the 3%
ceiling. Every input emitted byte-identical C across both binaries and all
samples. The command uses the same executed binary and output path on both
sides. This measures the complete pilot CLI on owned inputs, not self-compilation.

An independent compiler expert approved the exact frozen production/test patch
with zero findings. Broader sanitized and e2e gates remain integration work for
the combined changes; no final release acceptance is claimed by this slice.

## Reviewed namespace implementation contract

Two compiler experts approved the detailed inventory/namespace design. Implement
it as two separately green parts after admission's checker edits settle.

Part A issues identities in `declarations.issue_inventory` once during assembly
sealing. Parser module syntax remains raw. One opaque DeclarationInventory owns
issued function, record and union rows; ParsedContents holds that inventory
instead of three raw declaration vectors. Function/record rows pair their ID
with raw syntax. A union row owns its metadata and ordered issued variant rows,
replacing the raw variant vector rather than retaining both copies.

```blorp
fixed record FunctionRow {
    id: FunctionId,
    declaration: ParsedFunction
}
fixed record VariantRow {
    id: VariantId,
    declaration: ParsedVariant
}
```

Raw function/record/union/variant ID constructors become private to the issuing
module. Accepted and checked rows carry those issued references; no consumer
reconstructs them from vector positions. Specialization keeps its separate
concrete instance domain. A read-only two-vector nominal-order query replaces
the current checker merge without storing another index. Small direct test
fixtures use the real inventory producer with actual syntax, not unchecked
count-based ID minting or opaque casts.

Part B makes `build_namespace` return `Result[Namespace, NamespaceFailure]`.
Successful namespace facts contain no import problems. Namespace-owned typed
failures retain source/previous-declaration provenance and map into existing
CheckError categories at a short adapter; namespace never imports checking.
Module-level function/type/variant and import visibility clashes move into this
producer. Generic parameter/binding uniqueness, field labels, annotations,
receiver compatibility and expected-type constructor selection stay in checking.

Preserve foundation-first and existing import-group priority, then validate
local type/variant clashes in nominal order and duplicate functions in inventory
order. Local visibility errors intentionally precede annotation/body errors;
exact mixed-error tests establish that priority. Same-spelled function/type
declarations and constructors in distinct unions remain valid where they are
valid today. Forwarded type/variant identities and definition-site scope remain
unchanged, and ordinary function imports remain non-reexporting.

Unique direct function/type lookups return Options from validated namespace
facts, eliminating duplicate direct visibility/uniqueness work. UFCS retains
its accepted receiver view, with named/local origin preference over method-only
selection; no accepted signature table enters namespace. Remove its now-redundant
direct-visibility discriminator in that same producer-to-consumer change.

Issuance is linear in declarations plus variants; use local unique builders and
freeze once. Do not add growing-vector threading, a graph solver or cache. Part
A estimates +100–190 production lines; B estimates −180–280, with combined target
−40–130. Report actual production/test counts separately, without deleting
coverage or compressing formatting. Stop for review on substantial combined
growth. Each refactor separately retains the +3% frozen-input allocation and
instruction ceiling and identical emitted fixture C; all combined changes retain
the original +5% ceiling.

## Ownership fact boundary evidence

ValueOwnership and its read-only projection now belong to specialization's
concrete representation authority. Insertion and independent verification both
import them there. Raw verification's operation, type, layout, arity, coverage
and borrow checks remain intact. There is no compatibility re-export, extra
catalogue or duplicate child inventory. Production shrinks by six physical
lines; tests grow by 384, including twelve producer/query callbacks and one
corrupted-insertion-output callback with an independently valid baseline.

Two separate compiler experts approved the final source/test packet
`d472abd07e3004ff5ae98d232cdb6ef768a18e5ba950fe19be9ae7473dead95a`
with zero findings. The nine focused native suites pass 256 callbacks
(`ownership-green`, no source drift). The String fact oracle fails exactly its
callback when the upstream query is changed to NoOwnership in an isolated source
copy (`ownership-fact-mutation`) and passes after restoration
(`ownership-fact-restored`). The verifier test separately removes only the real
insertion output's acquisition, retaining its exact transfer, and requires the
undefined-owner diagnostic and span.

An isolated ownership-only compiler was built from the committed tuple tree plus
that reviewed patch, using the same fresh host and O0 diagnostic flags. The
source snapshot, patch, C, binary and build receipts are retained under
`build/authority-fixes/ownership-only*`. Its 216 paired samples against the frozen
tuple candidate cover the same 36 input/library bytes and executed/output paths.
Allocations are stable, balanced and unchanged; the maximum minimum-instruction
increase is 0.125%, within the separate 3% ceiling. All emitted fixture C is
byte-identical (`ownership-cost-receipt`). Broader combined acceptance remains
pending.

That receipt reports working-tree drift while other workers edited the active
checker/tests. The measured executable, input files and target library were
isolated prebuilt/frozen artifacts; active source was not compiled during the
samples. Per-sample binary/input/C hashes and the frozen library/input manifest
in `ownership-cost/provenance.json` are the provenance authority for this
comparison, rather than the changing
working-tree fingerprint. The retained recipe and build patch identify the
measured source; this distinction does not waive any frozen-artifact check.
All eight frozen target-library files byte-match their committed `a16328a59`
versions; the provenance packet also fingerprints the recipe and both binaries.

## Rejected initial admission measurement

The initial admission implementation passed its first 59 callbacks but exceeded
the predeclared 5% ceiling: nested wrap-128 grew 19.424% in allocations and
8.188% in retired instructions; wrap-64 grew 14.472%/7.992%, and wrap-32
8.897%/4.910%. Other workloads remained below 0.90%/0.60%. All 216 raw samples,
stable balanced counts and unchanged C are retained in `combined-initial-cost`;
this is a rejected result, not acceptance evidence.

The cause is repeated admission of fully substituted nested caller arguments.
The reviewed remedy checks written signature structure against already-created
concrete types, treating supplied parameter replacements as terminal. Child-first
freezing and accepted annotations establish those supplied types' validity;
newly written nominal heads still consult the declaration's String requirements.
Thus Box[T] does fixed written work while Marker[Values[T]] still rejects Int.
No cache, extra substitution walk, proof carrier or constraint solver is needed.
The ceiling remains unchanged, and this remedy requires fresh native and matched
cost evidence before admission can be accepted.

## Specialization preparation contract

A separate compiler expert found no valid-source unprepared-instance failure.
Parameter types come from prepared signatures; local/var types come from their
prepared initializers; payload captures come from the complete prepared scrutinee
layout; whole captures have that scrutinee type; projections collect their step
types; generic request arguments are prepared before enqueueing. The existing
unused nested-payload test already covers required layout closure. This does not
justify replacing specialization's passes without a demonstrated gap.

One missing test now exercises an unused whole capture of an inline owning generic union
containing another String-owning generic union. It asserts complete child-first
layouts, absence of phantom runtime fields, exactly three reachable instances,
and the published binding's identity/type/origin/span despite no arm read.
This adds 60 test lines and no production changes.

The unchanged-producer owning suite passes 8 callbacks (`whole-capture-green`).
Changing only copied checking's whole-capture type to Void makes exactly the new
callback fail (`whole-capture-mutation`); byte-for-byte restoration passes
(`whole-capture-restored`). Receipts, hashes, bounded source map and excerpts are
retained in `build/authority-fixes/whole-capture-handback.md` and
`preparation-review.md`. The active source was untouched during that oracle.
An independent compiler expert approved both the test and all three receipts
with zero findings. General List[Nominal] will require recursive element-layout
preparation when that separate capability is introduced; current List[String]
does not have that dependency.

## Admission component acceptance

Known concrete record/union applications now reject their String-only List
requirements during checking, even in unused signatures. The finite declaration
walk freezes dense per-parameter requirements once. Generic call admission walks
written signature structure paired with already-instantiated types; supplied
parameters are terminal, including deeply nested types already accepted from
children/context. No inference slots, second substitution walk or constraint
solver escape. Declaration requirements use depth-first source order. Each
request argument's caller-dependency fact is computed once for its diagnostic
span and the request-chain origin; nongeneric callers skip that tree query.

Void arguments and phantom parameters remain valid. Body-only constraints still
become known during specialization; the retained List rejection points at its
written field annotation. Late pure-Void diagnostics retain an instantiation
chain's call origin, with documented mixed fixed/symbolic granularity rather
than per-argument causal provenance. New nominal admission is child-first at
freeze; existing direct List/pure-result readiness priority remains unchanged.
These limitations are executable controls, not claims that a general generic
constraint solver or argument-specific provenance was implemented.

Final source `specialize.brp` is SHA-256
`ee478f01031900af2ce4c77cc4b5664d6a827061c0cdd597f002195463292c6a`.
Two independent compiler experts approved the complete code/test change with
zero remaining findings. Production grows by 270 physical lines; tests grow by
761, including 51 fixture/registration lines. Tests require typed errors plus
exact message/help/source/span and separately exercise the requirement producer.
The initial 18 failing cases became green; later source-order and nongeneric
wrapper regressions were captured before their repairs. The initially wrong
hidden-body call-span expectation was corrected only after a diagnostic probe;
it is a deferred-behavior control, not another source bug fixed.

Final focused suites pass 195 callbacks (`admission-fact-reuse-focused`); strict
ASan/UBSan/leak unit/runtime/grammar passes 2,085 callbacks in 137 suites
(`admission-accepted-strict`, 25.360s). Both receipts have no timeout or source
drift. The e2e run built the compiler exactly once and passed 324/325 cases;
the only failure was an updated test's off-by-one location, 3:23 versus actual
3:24. Only that expectation changed. The complete direct-union group then passes
11/11 against the same actual compiler and unchanged fixture mains
(`admission-direct-union-e2e`). The original whole-e2e receipt remains red; a
fresh complete combined e2e is still required after namespace integration.

The actual e2e compiler, frozen as `admission-accepted-candidate/compiler`, is
SHA-256 `82591956c1260f238d519c0a4319bdf1d6595ace1109ebd68c15dc3c7d02e662`;
its C is `fef1d202060948d560a6d894a4390aab01fb88c15e28579fa424637250e800d3`.
Against the original frozen a163 baseline, its final 216 samples/36 inputs are
stable, strictly balanced and emit identical C. Maximum allocation increase is
2.144281%; maximum minimum-instruction increase is 1.162158%, within the original
5% ceiling and the 3% target (`admission-accepted-cost-receipt`, no source drift).
Earlier intermediate green cost series are retained separately from this final
source/executable evidence.

A separate 24-sample proxy varies an unused generic record's List[T] fields over
16/32/64/128. Added allocations are 189/238/335/528; maxima are 3.979% allocations
and 2.309% instructions, within 5%, with balanced counts and identical C. This
tests the unchanged worklist in the prior repaired binary, not the final whole
compiler (`requirements-width`). Generated-C inspection independently shows
consuming root transfer, no per-push root retain and geometric capacity reuse;
it does not assert global compiler linearity. Raw inputs/samples and bounded C
excerpts are retained with the admission handback. The rejected original
superlinear supplied-type rescanning result remains documented above.

## Declaration inventory acceptance (namespace part A)

Assembly now issues one opaque declaration inventory from actual syntax. Its
function, record, union and owner-qualified variant rows carry their issued IDs
through namespace, signatures, checked bodies, nominal checking and diagnostics.
All 17 external raw-ID construction calls are removed; the four constructors
are private. The shared read-only nominal projection retains the previous
module/source ordering. Visibility and rejection priority are unchanged in A;
three frozen CLI priority controls have byte-identical diagnostics.

Production grows by 81 physical lines. Tests grow by 269: the producer/model/
assembly/namespace tests and direct syntax helper add 262, and 28 migrated
reader files add seven while preserving all 555 registered callbacks and their
assertions. Readers filter issued rows locally instead of manufacturing partial
ParsedContents products. README grows by five lines. Two independent experts
approve the final production/core-test patch; reader review is separate.

The valid pre-change API probe rejects the unavailable DeclarationInventory;
earlier test-authoring parser failures are retained and excluded. Four import
probes change from acceptance to exact private-import diagnostics. The actual
issuer's function-ID length changed to zero in an isolated copy makes the dense
ID callback fail; byte-for-byte restoration passes. Five producer callbacks and
31 focused callbacks pass. The initial source check found two loop-local `?=`
uses, the initial focused run found one misindented test fallback, and the first
broad check found six unmigrated grammar readers plus duplicate imports. Those
setup failures are preserved, not counted as regression or acceptance evidence.
The final strict ASan/UBSan/leak run passes 2,090 callbacks in 137 suites in
27.838s, with no source drift or timeout (`namespace-a-strict-complete`).

The native pilot is SHA-256
`cba669e4e34e505e25b78e06e47f176a95113694c182e044263a34b09c3abd67`;
its C is `88c211bfdcf97033c53864aaa104fc16c88a039125a8e220495e51cdb4e52e45`.
Its 42 source/library artifacts are frozen separately. Against accepted admission
compiler `82591956`, 216 samples over the same 36 frozen programs are balanced
and emit identical C; maximum allocation increase is 0.466125%, and maximum
minimum-instruction increase is 0.297684%, below the unchanged 3% ceiling
(`namespace-a-cost-receipt`). These remain owned-input CLI proxies.

Actual generated C maps inventory issuance to `brp_j9`: four local vector
builders transfer their roots into capacity growth without retaining them on
each append. The final row publication acquires its fields once. Source syntax
rows incur the expected managed wrappers; no duplicated raw union variant vector
is published. This supports the narrow construction claim, not global compiler
linearity. Full normal-main e2e remains the final combined gate after part B.

## Final landing through declaration inventory

The user selected landing all completed Blorp 2 work on main. Main and both
remote branches were at `3f98023dc`; local blorp-2 contained the accepted aggregate
milestone at `a16328a59`. The completed repair branch includes that milestone,
tuple cleanup, upstream ownership facts, concrete admission, the preparation
test and declaration inventory. Namespace part B was not implemented and remains
a separate follow-up. This final gate supersedes the earlier plan to wait for B
before the combined e2e run; it does not claim validated namespace publication.

A small port onto main's older model was reviewed and passed 115 focused checks,
then preserved under `build/main-tuple-ownership/` when the user clarified the
landing scope. That port is excluded from the landing and these final counts.
Its unrelated older representations are not mixed into the accepted milestone.

Fresh validation on clean `cc47af75b` passes 2,090 sanitized unit/runtime/grammar
callbacks in 137 suites (29.615s) and all 325 normal-main e2e cases (179.378s).
The e2e run generates and links its compiler exactly once. Both receipts have
no source drift or timeout; the strict receipt reports balanced allocations,
and e2e stderr is empty (`final-strict`, `final-e2e`). Two independent compiler
experts checked the component-review correspondence and final test receipts;
neither claims an independent review of their own implementation.

The actual compiler produced by that e2e run is SHA-256
`a70b0f147a73d02034c4b4e92c48768fb3c80ea687291ae224b9c98f39282146`.
Its C remains exactly `88c211bfdcf97033c53864aaa104fc16c88a039125a8e220495e51cdb4e52e45`;
the final cost run uses this freshly linked binary, not the earlier binary.
Against the original frozen a163 compiler, 216 paired samples over all 36 frozen
inputs are strictly balanced and emit identical C. Maximum allocations increase
by 2.397525%, and maximum minimum retired instructions increase by 1.243547%,
below the unchanged 5% ceiling and the 3% target (`final-cost-receipt`). Source,
library, input and binary hashes are retained; these are owned-input CLI proxies,
not self-compilation measurements.

The complete branch descends from main, so landing preserves the reviewed history
with a fast-forward. Host compiler, standard library and scripts are unchanged;
the diff is confined to Blorp 2 and its retained benchmark reports.
