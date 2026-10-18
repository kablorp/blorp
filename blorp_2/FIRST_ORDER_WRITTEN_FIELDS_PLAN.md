# First-order written record fields: first bounded proposal

Proposal only, separate from the ledger documentation review. Root/peer review,
a frozen exact composition and a test-only lane
are required before writing or running anything. This document implements no
source/test change and grants no resource-policy exception. The
[callback ledger](REMAINING_CALLBACK_LEDGER.md) owns the **combined future hard
ceiling 1,000 production added/+530 net/930 test added, including propagation**.
This slice consumes at most **50 production added/+40 net and 60 test added**
inside that one ceiling; fixtures 0. These amounts are not added to the ledger.

The chosen source is accepted main commit
`6e6c3fb0a571dd632bfd0ad9991419f7d72d26a6`, not the advancing main checkout or
the unlanded opaque composition. A later separate worktree must start at this
commit; this documentation branch is not the implementation composition.
These SHA256 pins refer to the committed bytes:

| Path under `blorp_2/` | SHA256 |
| --- | --- |
| `src/specialize/specialize.brp` | `ef7e2ec38ec9df04b02ee37d0c345e7df1ed2e15b09beec55e95ef01bd0ed081` |
| `src/check/expressions.brp` | `ecc472ba913f69653a62a8fd00524164b0f1404fab614df4f817f9b272f51f69` |
| `test/unit/test_specialize/test_record.brp` | `7177a6d4d704b823258905d0c9ad6ceb49aebddf4f0c8a813519e979e1086fb3` |
| `test/unit/test_specialize/test_record_update.brp` | `67fa69aee6cf775f0f94dc07d84d09642ad5184b0ff23dcb021b13728e379bc5` |

## Two sites, one existing child

In accepted main `6e6c3fb`, `specialize/specialize.brp:2336` translates written
update replacements; `:2375` translates written record literals. Both pass the
same typed fields/context to existing `translate_record_field:2282`. That child
first resolves its canonical field instance at 2291, then translates the value
at 2292, retaining the field's span. In this source, checking assigns
that span from `field.value.span` (`check/expressions.brp:148`).

Current update site, with the literal site identical apart from `fields`:

```blorp
match translated_list(
    update.replacements,
    pure func(
        field: Checked.CheckedRecordField,
    ): translate_record_field(field, owner, constants, substitution, keys, unions, records),
):
```

Proposed call boundary:

```blorp
match translate_record_fields(update.replacements, owner, constants, substitution, keys, unions, records):
```

A private typed loop next to the existing child calls it once per written field,
appends only successful results, stops on the first error and publishes the
complete List only on success. Keep the existing child unchanged and pass its
actual required facts, with no argument-context bag, dispatch union or generic
callback replacement. The prior readable forecast 42 added/8 deleted/+34 net must
be rechecked on the exact chosen composition; the 50/+40 bound remains hard.

Do not touch inherited-field translation at 2343 or the other six generic callers.
After this slice, six callbacks and the function-typed helper still remain.
The already first-order type-argument translation remains unchanged. The one
loop is the written-fields row of the ledger's seven-domain 420/+260 forecast,
not an eighth loop or another additive allowance. The opaque audit's corresponding
sites at 2409/2448 and child at 2347 have the same field-ID-before-child authority
plus an explicit opaque-facts argument; future composition must preserve that
equivalence without importing opaque code into this slice.

## Characterization first

This preserves behavior; it needs baseline GREEN characterization, not a fake
feature RED. Before production, add at most 60 physical test lines, including
imports and registration, to existing
`test/unit/test_specialize/test_record_update.brp`. Use one named callback and
the existing `specialized` / `returned_update` helpers. No new fixture/harness.

The embedded normal source is:

```blorp
fixed record Triple { first: Int, middle: Int, last: Int }
pure func change(value: Triple) -> Triple:
    { value | last = 9223372036854775807, first = -9223372036854775808 }
func main() -> Int:
    changed = change({ first = 1, middle = 2, last = 3 })
    changed.middle
```

The callback must observe exactly one returned update, replacement order
`[last, first]` with field ordinals `[2,0]`, exact full-width values MAX/MIN,
one inherited middle field ordinal 1, the same concrete owner for all three and
the base, and preserved Int types. Assert replacement value/field spans against
the two unique authored integer literals, including the minus sign for MIN;
do not guess a field-name span. Checking has already established these facts.

The existing eight `test_record.brp` callbacks already cover literal written
order with a second concrete record owner, full-width fields, nested types and
calls in record children. Existing four update callbacks cover generic/phantom
owners, inherited nested Lists and generic calls in the base/RHS. Retain them.
With the new callback the two owning suites are **8+5 = 13** for baseline and candidate.
Record exact registered names/counts and unchanged diagnostics before claiming
the new characterization GREEN. Additional coverage needs review before 60 lines;
do not compress formatting or delete old coverage.

## Oracles, order and next gate

The implementation must keep literal owner-before-fields, and update
owner→base→written replacements→inherited order. The existing child retains
field-ID lookup before value translation and each child's diagnostic span.
Preserve the first child error and discard unpublished partial results. Do not
manufacture an invalid public source, forge a checked product or add an export
merely to force an internal-only error; preserve that branch through source
review and existing owning error tests, stating any oracle limit explicitly.

Before mutation execution, review exact type-correct patches and mandatory
witnesses. Reversing successful accumulation must fail the new `[2,0]` update
oracle and existing literal-order oracle. Omitting a successful field must fail
their exact shapes/values. Shifting the forwarded span must fail the new exact
literal-span assertions. Use a valid wrong field ordinal only in the existing
translator's module if separately approved; the existing second-owner literal
oracle is the witness. No compiler/setup-error kill claim.

Each run retains true status and complete streams. Restore exact candidate
production/test source bytes and modes, then verify all source/library/test/producer
pins before classifying results. Retain emitted C unmodified, then require
restored owning GREEN. Do not predeclare an exhaustive mutation failure set.
Stop on setup failure, source drift, surviving witnesses, unexpected errors or
failed restoration. Root owns all serial leases; no compiled job is authorized.

First next gate, after test-only change review: one explicit c04/std91 ordinary
TestSuite call over the two existing owning paths, expected 13 PASS/exit 0/empty
stderr on unchanged production. Implementation then needs actual root/peer
diff/count review before candidate 13, mutations and integration gates. Do not
replay other held source slices or use a retained B binary as changed-source C
proof. Loop cleanup/native ownership gates remain proportionate integration
work; target append copying supplies no performance claim.

The user-approved [SOURCE fixed-baseline contract](BOOTSTRAP_SOURCE_PLAN.md#source-cost-acceptance)
owns the +3% comparison and historical R0 reporting. Exact C, zero leaks, all
absolute limits and frozen producer/checkpoint metrics remain. No cost setup,
sampling, baseline roll, source implementation, commit or landing follows from
this proposal. Return the exact test diff, source composition/pins, baseline
characterization, then bounded production diff and its independent evidence.
