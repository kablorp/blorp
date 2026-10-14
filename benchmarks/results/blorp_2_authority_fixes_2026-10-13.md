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
