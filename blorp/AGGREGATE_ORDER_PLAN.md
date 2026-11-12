# Emit aggregates in the order Verify proved

Status: approved by Keith on 2026-11-10, with the recommended answer to each
of K1–K4. Landed on 2026-11-10 as `bcc6bfdb1`.
Test lines came to +461 against the +450 ceiling; self-compile allocations
13,563,081 to 13,563,080 and retired instructions −0.02%. Written against
`ce8753b6f` on 2026-11-09.

## Problem

Verify and Emit each walk the same aggregate dependency graph, the by-value
storage edges between records and unions. They walk it in the same order.
Verify proves that the graph has no by-value cycles and then throws the walk
away. Emit walks the graph again so that every by-value child's C definition
comes before its parent's.

This is not a miscompilation. It breaks the compiler's first principle in
[AGENTS.md](AGENTS.md): establish each fact once and never recompute it. The
duplicate also costs about 280 lines of Emit. That code includes a second
cycle check and five failure variants that can only fire if Verify is wrong.

Both walks on current `main`:

- **Verify.** [`verify_layout_graph`](src/compile/verify/verify.brp:943),
  lines 943–1218, returns `Result[Void, Diagnostic]`. It uses `LayoutVisit`
  states (line 899), a `LayoutVisitStep` worklist (line 905), cycle detection,
  and storage-summary checks at `FinishRecordLayout`. The union finish is at
  line 1140 and the record completion at line 1207. Its only caller,
  [`verify`](src/compile/verify/verify.brp:4555), discards the result at
  line 4586 as
  `complete_layouts: Void`.
- **Emit.** [`append_aggregate_definitions`](src/compile/emit/emit.brp:915),
  lines 915–1145, is called from
  [`aggregate_runtime_contents`](src/compile/emit/emit.brp:3780). It has its
  own `AggregateVisit` states and `AggregateVisitStep` worklist (lines
  869–882), a dependency classifier, `stored_by_value` (lines 889–911), and
  five traversal-only failures in
  [`diagnostics.brp`](src/compile/emit/diagnostics.brp:27):
  `MissingAggregateWorkItem`, `MissingAggregateVisit`,
  `CyclicByValueAggregate`, `MissingAggregateMember` and
  `MissingUnionPayloadField`.

There is no input or command that reproduces this. The evidence is the two
walks cited above. Done means one walk, in Verify, and Emit producing
byte-identical C.

## Background

This is item 4 of the compiler phase-responsibility audit. Items 5 and 7
have landed (`95e86ab87` and `ce8753b6f`). Items 1–3, 6 and 8 are deferred
until a profile justifies them. Keith asked for item 4 as a planned change
with cost ceilings.

An earlier draft, milestone F4 of `blorp/ARCHITECTURE_FACTS_PLAN.md`
(deleted in `df452788e`; read it with
`git show df452788e^:blorp/ARCHITECTURE_FACTS_PLAN.md`), proposed this shape.
Each of its points was re-checked against `ce8753b6f`:

| Draft point | Status now |
| --- | --- |
| Both walks follow inline/by-value records and unboxed unions, skip pointer edges, root every catalogue row, same stack order | **Holds.** Verify follows `InlineFields`/`ValueFields` records and `PlainCases`/`OwningCases` unions. Emit's `stored_by_value` follows the same cases (`union_is_boxed` is exactly `BoxedCases`, emit.brp:360). Both push unions and then records in reverse, so record 0 is on top. Both push children in reverse field and variant order. The order section below explains why the completion orders are identical. |
| Verify appends each row when its finish step succeeds | **Holds.** A union completes at `FinishUnionLayout` (line 1140), with no check. A record completes inside `if matches:` (line 1207), after its storage-summary check. Any failure stops the loop and fails `verify`, so a sealed program has every row exactly once. |
| `VerifiedProgram` is sealed with the order | **Needs a change.** Today it is `opaque type VerifiedProgram = OwnershipProgram` (line 103). `check.brp`'s `FailureContents` and `traits.brp`'s `AvailabilityContents` show the private-record-behind-opaque shape. |
| `aggregate_runtime_contents` takes `VerifiedProgram` | **Holds.** It is private and takes `OwnershipProgram`. Both callers (`aggregate_runtime`, line 3850, and `emit`, line 3876) hold a `VerifiedProgram`. |
| Emit loops over the order; its traversal is deleted | **Holds.** |
| Forward declarations, helper prototypes and renderer checks are kept | **Holds.** Typedefs, record prototypes and boxed-union prototypes are emitted per catalogue row before the definitions (lines 3792–3808). `append_record` and `append_union` keep their own failures. |
| Port bounded cases from deferred `test_recursive_aggregates.brp` | **Stale.** It was deleted in `824f3d4ee`. Drop this point. |
| Activate `recursive/group.brp` and `kinds.brp` in the native selection | **Stale.** Both are already active, in [`self_hosted_calls.brp`](test/e2e/self_hosted_calls.brp:518) at lines 518 and 566. Drop this point. |
| Production lines fall by 80–130 | **Too low.** The deletable code is about 280 lines (see ceilings). |

No existing test checks Verify's by-value cycle rejection. Searching `test/`
for `aggregate layouts form a by-value cycle` finds nothing.

## Proposed solution

Verify publishes the fact it already proves. It returns the walk's
completion order from `verify_layout_graph` and seals the order with the
program it describes. Emit renders definitions in that order and deletes
its own walk.

**Why Verify owns it.** Verify is the earliest phase that has proved the
graph acyclic. A topological order is the constructive form of that proof.
Specialize chooses the layouts but does not check the graph, and Emit should
only project.

**Why the seal carries it.** A `List[AggregateDefinition]` holds catalogue
indices, and an index only means something for the program it was computed
from. Keeping the order inside the opaque `VerifiedProgram`, and passing
`VerifiedProgram` rather than `OwnershipProgram` into Emit's aggregate code,
means no caller can pair a program with an order from a different program.

**Why indices and not typed ids.** `RecordInstanceId` and `UnionInstanceId`
are opaque in Specialize (specialize.brp:90–93), and Verify cannot mint
them. Verify could only get them by asking Specialize for a public
index-to-id constructor, which would make ids manufacturable from an Int.
Catalogue indices under a seal are the honest representation. See decision
K1 for the alternative of carrying layouts in the order.

**Why the order is identical, not just valid.** Both walks are the same
depth-first search with the same roots and the same push order. Verify
pushes a `VisitStoredType` for every field. When popped, it immediately
pushes the child's visit on top, which is popped next. Emit pushes a
`PrepareAggregate` only for by-value fields. In both, the first field's
child subtree finishes before the second field is looked at, and a
re-encounter of a finished row is skipped. So every row finishes in the same
sequence. A byte-identical C check confirms this empirically. After the
change Emit has no walk, so there is no second order to drift from later.

**Alternatives rejected.**
- *Keep Emit's walk and drop Verify's cycle check.* This moves a
  verification into codegen, against rule 8 and principle 7.
- *Let Emit sort by checking each row's dependencies against an emitted
  set.* This is a third traversal under another name.
- *A public `VerifiedContents` record, as with `SpecializedContents`.* This
  changes `verified_contents`'s result type for its two Emit callers and two
  runtime tests for no benefit. The private record keeps today's
  `verified_contents` signature. See K2.

## Code

### Verify: the published order

Current (verify.brp:99–107):

```blorp
-- This seal belongs to the exact operations and contracts checked below.
opaque type VerifiedProgram = OwnershipProgram


pure func verified_contents(program: VerifiedProgram) -> OwnershipProgram:
    from_opaque VerifiedProgram(program)
```

After:

```blorp
-- A record or union of a verified program, by its catalogue position in that
-- program. Positions mean nothing apart from the program, so the order
-- below is published only inside the seal.
union AggregateDefinition:
    RecordDefinition(Int)
    UnionDefinition(Int)


-- The order lists every record and union exactly once, each after every
-- aggregate it stores by value: the completion order of the layout walk.
private record VerifiedContents {
    program: OwnershipProgram,
    aggregate_order: List[AggregateDefinition],
}


-- This seal belongs to the exact operations, contracts and layout order
-- checked below.
opaque type VerifiedProgram = VerifiedContents


pure func verified_contents(program: VerifiedProgram) -> OwnershipProgram:
    from_opaque VerifiedProgram(program).program


pure func aggregate_order(program: VerifiedProgram) -> List[AggregateDefinition]:
    from_opaque VerifiedProgram(program).aggregate_order
```

The variant names are Emit's today (emit.brp:869), so `RecordDefinition` and
`UnionDefinition` keep one meaning while moving to their producer.

### Verify: recording completion

`verify_layout_graph` (line 943) changes its result to
`Result[List[AggregateDefinition], Diagnostic]` and gains one local. Its doc
comment adds: "It returns the layouts in the order the walk completed them."

```blorp
    var completed: List[AggregateDefinition] = []
```

Current union finish (line 1140):

```blorp
                    FinishUnionLayout(index):
                        union_visits = union_visits.set(index, CompleteLayout)
```

After:

```blorp
                    FinishUnionLayout(index):
                        union_visits = union_visits.set(index, CompleteLayout)
                        completed = completed.append(UnionDefinition(index))
```

Current record finish (line 1206):

```blorp
                                    if matches:
                                        record_visits = record_visits.set(index, CompleteLayout)
```

After:

```blorp
                                    if matches:
                                        record_visits = record_visits.set(index, CompleteLayout)
                                        completed = completed.append(RecordDefinition(index))
```

The tail returns `Ok(completed)` instead of `Ok(void)`. The function has no
`?=`, so the host's copy-on-append-after-`?=` rule does not apply to
`completed`.

In `verify` (line 4586), `complete_layouts: Void ?=` becomes
`layout_order ?=` (named apart from the `aggregate_order` projection), and
the seal at line 4648 becomes:

```blorp
                Ok(valid_entry):
                    Ok(into_opaque VerifiedProgram({ program = program, aggregate_order = layout_order }))
```

The visit vectors and the worklist stay local to the walk. Only the order
survives Verify.

### Emit: render in the verified order

Delete `AggregateDefinition`, `AggregateVisit`, `AggregateVisitStep`,
`stored_by_value` and the body of `append_aggregate_definitions` (emit.brp,
lines 869–1145). Import `AggregateDefinition(RecordDefinition,
UnionDefinition)` and `aggregate_order` from `../verify/verify`. The
replacement:

```blorp
-- Verification sealed every record and union in an order that puts each
-- by-value child first, so each C definition follows the definitions it
-- stores. Pointer edges need only the forward declarations emitted earlier.
private pure func append_aggregate_definitions(
    program: VerifiedProgram,
) -> Result[String, Diagnostic]:
    checked = program.verified_contents()
    var fragments: List[String] = []
    var failure: Option[Diagnostic] = None

    for definition in program.aggregate_order():
        rendered = match definition:
            RecordDefinition(index):
                match checked.records.get(index):
                    Some(layout): "".append_record(layout, index, checked.unions)
                    None: Err(render(compiler_span(), MissingAggregateLayout(RecordAggregate, index)))
            UnionDefinition(index):
                match checked.unions.get(index):
                    Some(layout): "".append_union(layout, index, checked.unions)
                    None: Err(render(compiler_span(), MissingAggregateLayout(UnionAggregate, index)))
        match rendered:
            Ok(text):
                fragments = fragments.append(text)
            Err(error):
                failure = Some(error)
                break

    match failure:
        Some(error): Err(error)
        None: Ok(fragments.join("\n"))
```

`fragments.join("\n")` keeps today's separator, which the byte-identity check
covers.

Current caller (emit.brp:3772–3780):

```blorp
private pure func aggregate_runtime_contents(
    checked: OwnershipProgram,
    ...
    ordered ?= checked.records.append_aggregate_definitions(checked.unions)
```

After:

```blorp
private pure func aggregate_runtime_contents(
    program: VerifiedProgram,
    ...
    checked = program.verified_contents()
    ordered ?= program.append_aggregate_definitions()
```

`aggregate_runtime` and `emit` pass `program` instead of `checked`. The rest
of `aggregate_runtime_contents` is unchanged: typedefs, record prototypes,
boxed-union prototypes, ownership helpers, list runtime and callable ops.

In `diagnostics.brp`, delete `MissingAggregateWorkItem`,
`MissingAggregateVisit`, `CyclicByValueAggregate`, `MissingAggregateMember`,
`MissingUnionPayloadField` and their render arms. Keep `AggregateKind` and
`MissingAggregateLayout`. Change the comment on `AggregateKind` (line 9)
from "Aggregate worklists hold…" to say that the verified aggregate order
holds catalogue indices. Drop the five deleted names from emit.brp's import
list (lines 157–162).

### README

In the Verify entry ([README.md](README.md:1141)), say that Verify also
publishes the aggregate definition order inside `VerifiedProgram`. Say that
Emit renders definitions in that order. The grammar does not change.

## Scope and non-goals

The change may touch `src/compile/verify/verify.brp`,
`src/compile/emit/emit.brp`, `src/compile/emit/diagnostics.brp`,
`README.md`, the two new suites, and `test/e2e/self_hosted.brp`
(`COMPONENT_SOURCES`). It must not touch Specialize's layout choice, the
forward declarations, the renderers, ownership helpers, Own, or any other
Verify rejection.

Not in scope:

- Verify's other checks. One example: the return-type membership failure in
  `verify`'s function loop does not `break`. That is noticed, not fixed here.
- Audit items 1–3, 6 and 8.
- The draft's other milestones, F1–F3.
- The untracked `src/compiler/stage_01_generated_inputs/embedded_std.brp`,
  a leftover of the retired compiler layout in this checkout.

## Risks and unknowns

- **Order drift.** If the two walks differ in some case nobody has noticed,
  the C would change order but stay valid. The byte-identity check over
  self-compile and every e2e fixture is what catches this. Any difference
  stops the work: report the input and both orders rather than accepting
  new C.
- **Host copy rules.** Building `VerifiedContents` adds one managed record
  per compile, which is negligible. `completed` is appended in a loop
  without `?=`. Check the generated C of `verify_layout_graph` for a
  per-append copy if allocations unexpectedly rise.
- **Formatter width.** The `None:` arms in the new loop exceed 100 columns.
  Let `blorp format` wrap them rather than hand-shortening names.

## Dependencies

None. No seed rotation: the change uses only constructs the pinned seed
already compiles. Keith decided K1–K4 on 2026-11-10.

## Testing

Both suites build programs from source through the real phases
(`lowered(...)` from `test/unit/list_update_inputs.brp`, then `own`,
`verify`, `emit`). Each case first asserts the catalogue shape it relies
on: a pattern match on the specialized program's record and union rows. A source that
stops producing the intended layouts then fails loudly instead of passing
vacuously. Each source's `main` constructs every record, union and callable the case
relies on, since Specialize only catalogues what the program builds.
Oracles are properties, not pinned lists:

- **once:** every record index and every union index of the catalogue
  appears exactly once in `aggregate_order`;
- **dependencies first:** for every entry, each field stored by value
  (`InlineFields`/`ValueFields` record, `PlainCases`/`OwningCases` union)
  names an entry earlier in the order.

**Verify,** `test/unit/test_compile/test_verify/test_aggregate_order.brp`:

1. *Empty catalogues.* `func main() -> Int: 0` has no records or unions,
   and its order is empty.
2. *Diamond.* `fixed record Leaf { value: Int }`, `fixed record Left { leaf:
   Leaf }`, `fixed record Right { leaf: Leaf }` and `fixed record Top { left:
   Left, right: Right }`, all inline. `Leaf` appears once, before both
   `Left` and `Right`, and `Top` comes last.
3. *Mixed records and unions stored across kinds.* A union whose payload
   is a fixed record that itself stores a fixed union, all stored in a
   record. Assert as a precondition that some record stores a union by
   value and some union stores a record by value. Then neither all records
   first nor all unions first can define every child before its parent.
   (The draft asked for an edge to a higher catalogue index instead.
   Specialize numbers a by-value child before its parent within each kind,
   whatever the declaration order, so source cannot produce one.)
4. *Boxed and managed roots.* A recursive union (`BoxedCases`), a managed
   record holding a fixed record and a `List` of itself, and a callable
   field. Each boxed or managed row is still in the order exactly once, and
   pointer edges do not have to be satisfied.
5. *By-value cycle rejected.* From case 2's owned program, replace
   `Leaf`'s fields with `Left`'s `RecordType`, copied from `Top`'s first
   field so no id is minted. That makes `Leaf -> Left -> Leaf`, rewritten the
   way `test_inline_union_fields.brp`
   rewrites layouts. `verify` fails with exactly `ownership verification
   failed: aggregate layouts form a by-value cycle` and help `report this
   compiler error with the input program` (K3).

**Emit,** `test/unit/test_compile/test_emit/test_aggregate_order.brp`. For
cases 2 and 3, emit C and check that the C definition markers
(`struct blorp_r_N{`, and `enum blorp_tag_N{` or `enum blorp_u_N{`) appear
in the same sequence as `aggregate_order`. Also check that each record's
`typedef` comes before every definition. Positions come from
`text_search.find_text`. The markers are the C names Emit gives each
definition, a structural dependency rather than pinned source text; if the
naming changes, this test changes with it.

**How a broken change is caught** (temporary edits, never committed):

- Reverse `completed` before sealing: the Verify "dependencies first"
  cases fail. The Emit cases still pass, since Emit follows whatever order
  it is given.
- Reverse the order inside Emit's loop: both Emit sequence cases fail.
- Drop the union append: "once" fails in cases 3 and 4.
- Make the `Some(VisitingLayout)` arm `void`, so the walk accepts a cycle:
  `verify` returns `Ok` and case 5 fails. (Making it fall through like
  `UnvisitedLayout` would loop forever rather than fail.)

Record which tests failed for each mutation.

**Byte identity.** Build the base compiler (`ce8753b6f` or the rebased base)
and the candidate with `make -C blorp compiler`. Each compiles the base
revision's `blorp/src/main.brp` with `--library-root
blorp/standard_library`, and every `func main` file under
`test/e2e/fixtures/`. Diff the C, and for rejecting fixtures diff stdout,
stderr and exit status. Keep the loop and its outputs under ignored
`blorp/build/aggregate-order/`. This is a one-off landing check, not a
retained test.

**Commands,** with the narrowest first and nothing started until the
machine is idle (other sessions share it, and compiled binaries must not run
in parallel on macOS):

```bash
make -C blorp compiler
make -C blorp test-target-components TARGET_COMPONENT_SOURCES='blorp/test/unit/test_compile/test_verify/test_aggregate_order.brp blorp/test/unit/test_compile/test_emit/test_aggregate_order.brp'
make -C blorp test
scripts/blorp-fixpoint --prove
```

Add both suites to `COMPONENT_SOURCES` in `test/e2e/self_hosted.brp`.

## Cost ceilings

These are set before implementation, per [AGENTS.md](../AGENTS.md). Measure
with `blorp/scripts/self-compile-cost`.

The reference at `95e86ab87` was 13,615,420 allocations and 13.22 G retired
instructions. Re-measure the base and do not reuse those figures.

| Metric | Ceiling | Expected |
| --- | --- | --- |
| Self-compile allocations | no increase over base (strict counts are deterministic) | a small decrease: Emit's two visit vectors and worklist go, and the order list and one seal record arrive |
| Self-compile retired instructions, best of 3 | at most +0.3% | about −0.1% or flat |
| Self C and every e2e fixture's C or diagnostics | byte-identical to base | identical |
| E2e allocation and instruction ceilings | unchanged | pass |
| Production lines (`src/`), net | at most −150 | about −230: −277 in emit.brp, −20 in diagnostics.brp, +25 in verify.brp, +40 for the new loop |
| Test lines (`test/`), added | at most +450 | about +300 |

Report production and test additions, deletions and net counts separately,
from `git diff --numstat`. Repeat an apparent miss before believing it. Bring
a repeatable miss back to the coordinator, who may correct a routine budget
and record it under the standing delegation. Do not shorten tests to meet a
line figure. Record the evidence in this plan.

## Decisions

Keith approved the recommendation for each of these on 2026-11-10: index-only
entries, a private seal record, the cycle-rejection test in this change, and
the ceilings as set.

- **K1. What an order entry holds.**
  - Recommended: a catalogue index (`RecordDefinition(Int)`), as above.
  - Alternative: an index plus its layout (`RecordDefinition(Int,
    ConcreteRecord)`). This removes Emit's last "missing layout" failure,
    but stores each layout twice and adds a retain per entry.
- **K2. The seal's shape.**
  - Recommended: a private `VerifiedContents` with two projections, keeping
    `verified_contents(program) -> OwnershipProgram`.
  - Alternative: a public record, as with `SpecializedContents`.
- **K3. Cycle-rejection coverage.**
  - Recommended: add test case 5 in this change. It covers existing
    behaviour that no test checks, and the order's guarantee rests on it.
  - Alternative: leave it to a separate change.
- **K4. The ceilings above.** Approve them as set, or amend them.

## Acceptance criteria

- [ ] Both new suites pass under `make -C blorp test-target-components`.
      Each mutation above makes its named tests fail.
- [ ] `make -C blorp test` passes, with both suites in `COMPONENT_SOURCES`.
- [ ] `scripts/blorp-fixpoint --prove` passes.
- [ ] Base and candidate compile the base `src/main.brp` and every e2e
      fixture to byte-identical C, or to identical diagnostics and exit
      status.
- [ ] `grep -n "AggregateVisit\|stored_by_value\|CyclicByValueAggregate\|MissingAggregateWorkItem" blorp/src -r`
      prints nothing.
- [ ] `verify_layout_graph` returns the order, and `VerifiedProgram` is the
      only carrier of it.
- [ ] Every ceiling in the cost table is met, and this plan records
      source, binaries, flags, inputs and output identity.
- [ ] A code-reviewer and a test-runner have each approved the final diff.

## Release strategy

One squash commit on `main` after review, with no seed rotation. To back it
out, revert the commit as a unit. Do not keep both walks as a fallback. Ask
Keith before pushing.

## Handback

Return:

- the branch and commit;
- the mutation table;
- the byte-identity summary, with counts of inputs compared;
- the cost table, with the base and candidate figures;
- production and test line counts.

Stop and ask the coordinating session if:

- any C differs;
- the walks turn out not to be equivalent;
- a ceiling is missed twice;
- the change needs anything beyond the files in scope.
