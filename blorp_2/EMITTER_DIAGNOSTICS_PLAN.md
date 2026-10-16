# Diagnose emitter invariants at their actual boundary

## Problem

The current emitter at c3b7e4294 has one private `internal_error()`
(`blorp_2/src/emit/emit.brp:93`). Every caller reports `invalid checked union
identity`, including missing record layouts, owner types and runtime arguments.
It always uses a compiler-origin span, even when the caller has an occurrence.
The quality roadmap's maintenance item requests meaningful errors without
changing the verified-product contract or adding late semantic validation.

Short module paths such as `emit/diagnostics.brp`, `own/own.brp` and
`emit.brp` refer to modules under `blorp_2/src/`; the last names the existing
`emit/emit.brp`. Runnable commands use repository-root paths. Line anchors
describe the initial c3b7e4294 tree; resolve the named declaration after moves.

## Ownership and solution for review

Keep these as emitter invariant failures, not new language rejections.
The independent verifier remains the only constructor of VerifiedProgram.
Use a small emitter-owned failure vocabulary and one diagnostic renderer.
Carry existing typed identities where available; list traversal indices remain
indices and are labelled as such. Do not look up source spellings or infer an
identity from a generated C name. A source occurrence is passed explicitly;
when the published input genuinely erased it, keep the compiler-origin span.

Use a small `emit/diagnostics.brp` module with the emitter-owned failure
vocabulary and a pure `render(span, failure)` factory. Independent plan review
and the coordinator agree this gives a useful narrow unit-test boundary
without exporting traversal implementation.
No generic error framework, registry, new pipeline product or public bypass of
VerifiedProgram is authorized.

## Concrete code shape

Existing `append_ownership_operation` at emit.brp:1614 discards the Span:

```blorp
AcquireOwner(owner, borrowed, _):
    match types.get(owner_number(owner)):
        Some(value_type): -- existing duplication
        None: Err(internal_error())
```

Its accepted occurrence already exists in `OwnershipOperation` at
own/own.brp:117. Preserve it and construct the diagnostic only on failure:

```blorp
AcquireOwner(owner, borrowed, span):
    match types.get(owner_number(owner)):
        Some(value_type): -- unchanged duplication
        None: Err(emission_failure(span, MissingOwnerType(owner)))
```

The diagnostic is, for example, `internal compiler error: missing emitted owner
type #3`, with the existing help to report the input program. DropOwner and
owner_types' borrowed-value lookup use their own supplied spans/identities.

`OwnedDefinition.span` exists at own/own.brp:108. Pass it into the value/runtime
helpers that currently receive only id/type/operation. Missing record or union
layouts at those call sites then report the actual definition occurrence.
Type/layout-only helpers have no occurrence at their construction boundary;
do not fabricate one or add spans to all concrete layouts for this cleanup.

The failure vocabulary must distinguish actual classes at the current sites:
missing union/record layout, missing owner/value type, missing runtime argument
(result ValueId and argument ordinal), a statement-only value reaching the
expression path, and aggregate traversal failures (missing work item/visit
state/layout child, or a cycle of by-value dependencies). Include the available
record/union kind and index in those traversal errors. Do not add variants for
hypothetical future failures or copy large expression trees into an error.
The reviewed census is 27 calls plus the definition, rather than the historical
roadmap's 28 calls. Ten calls are inside aggregate traversal. Keep these twelve
failure classes, with the existing typed identities or actual list indices:

| Failure | Payload |
| --- | --- |
| MissingUnionLayout | UnionInstanceId |
| MissingRecordLayout | RecordInstanceId |
| MissingOwnerType | OwnerId |
| MissingValueType | ValueId |
| MissingRuntimeArgument | result ValueId, argument ordinal |
| StatementOnlyValue | ValueId |
| MissingAggregateWorkItem | work index |
| MissingAggregateVisit | AggregateKind, index |
| CyclicByValueAggregate | AggregateKind, index |
| MissingAggregateLayout | AggregateKind, index |
| MissingAggregateMember | AggregateKind, index, member index |
| MissingUnionPayloadField | union index, variant index, field index |

`AggregateKind` has `RecordAggregate` and `UnionAggregate`. A missing member
renders a field for a record and a variant for a union. Do not manufacture an
instance identity from a traversal index or a ValueId from an argument ordinal.
This vocabulary describes current failure sites, not future possibilities.

For example, a missing argument in append_parse_number (emit.brp:1051) must not
report a union error. Existing `.to_result(internal_error())` constructs the
error eagerly on successful lookup. Replace those affected lookups with direct
Some/None, retaining the same first-failure ordering. Do not add lazy callbacks
or a second lookup solely to avoid constructing an error.

## Scope and risks

Only emitter diagnostics and necessary private helper parameters change.
No semantic checks move into emission; no ownership insertion, verifier,
specialization, runtime, source grammar or fixture entrypoint changes.
Do not repair adjacent unchecked access paths or emitter concatenation here;
report them separately. No mechanical source compression or test deletion.
In particular, `stored_by_value` currently conflates a missing layout with a
legitimate nonaggregate/pointer case; its contract is a separate finding.

The successful path must neither allocate failure variants nor render IDs.
Inspect generated C for eager construction after each changed lookup. Passing
a span must not start copying large phase products. Aggregate cycle messages
describe inconsistent accepted layouts; they do not imply cyclic values are
allowed. Existing BoxedRecursive pointer edges must remain legal.

## TDD and review

First write expected message/help/span tests for the reviewed precise vocabulary.
If the new unit boundary requires a preparatory extraction, make that a small
semantics-preserving source step with the old generic rendering first. Record
the tests' actual red outcomes before replacing that rendering, and preserve
the preparation's successful C identity. Do not call a missing-symbol compile
failure proof of the intended diagnostic regression.
Use Blorp TestSuite. Unit tests may construct failure data and call its renderer;
they may not forge VerifiedProgram or call generated functions. Exercise every
renderer case independently, numeric identity changes, actual occurrence and
compiler-origin paths. No source-text scanner tests pinning call counts.

Prove the renderer oracle by mapping a record failure back to the old union
message and by replacing an actual occurrence with compiler origin; the
appropriate named callbacks must fail. Existing malformed-ownership tests
must still reject before emission. Successful emitted C stays byte-identical
on the existing corpus. Read real generated C for managed records, unions,
String/List runtime operations, acquire/drop and recursive layout dependencies.

The sealed VerifiedProgram API intentionally makes most internal failure
call sites unreachable from valid public inputs. State this coverage limit;
do not add a test-only backdoor to claim execution coverage. Direct renderer
tests prove formatting, and source review checks each call site's identity and
span choice. Existing valid emitter/native tests prove normal behavior.

## Acceptance ceilings set before code

- Physical production net growth <=160; report additions/deletions/tests/docs
  separately. Stop before expanding the scope to meet a number.
- No allocation growth on any unchanged accepted frozen fixture/stress input;
  normal-mode min3 instructions <=+0.5% corpus and each retained stress.
- Matched canonical-path host-build allocations/instructions <=+1%.
- Full owning emitter suites, full make -C blorp_2 test, dynamic source frontier
  (same existing Char/function-type gaps), strict fixture zero leaks and C
  identity. Current published parser rule remains unchanged.

All compiled work requires root's exclusive slot and frozen host. Count leaks
and allocations in separate strict runs; measure retired instructions with
BLORP_LEAK_CHECK and BLORP_MEMORY_STATS unset. Retain exact source/binary/input/
toolchain provenance and raw samples. These are owned-input/build proxies,
not self-compilation evidence.

Root and an independent compiler expert review the settled plan before code.
Root plus independent expert review the patch and separate test-runner evidence
before commit. Root owns integration/publication; worker does not commit.
Stop and ask root on a missing fact, changed output, ceiling breach, unverifiable
invariant or need for another mechanism. Hand back exact census, chosen minimal
vocabulary, patch, tests/mutants, cost evidence, limitations and simplicity verdict.
