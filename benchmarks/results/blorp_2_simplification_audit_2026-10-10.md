# Blorp 2 simplification audit, 2026-10-10

A separate compiler-expert agent audited `blorp_2/src` read-only after the
tail-recursion source was restored. All 16 source files matched the final
source inventory in `blorp_2/build/tail-recursion/worker/final-source.sha256`.
No source edits or compiled commands were performed for this audit.

The current organization remains sound: the pure pipeline publishes
phase-specific products, resolved identities survive translation, and ownership
insertion remains separate from independent verification. No correctness defect
surfaced in this targeted pass. The four recommendations below are proposed
bounded slices, not implemented changes or measured performance wins.

## 1. Render ownership operations directly

**Highest priority; high confidence; low risk.**

[emit.brp:384](../../blorp_2/src/emit.brp) converts all eight
`OwnedValueOperation` variants back into `Lower.ValueOperation` solely for
private text emission. Calls additionally map `OwnedArgument` into a temporary
`List[ValueId]`. The private renderer can instead consume the owned operation
and project each argument while rendering:

```blorp
CallDefinition(call, arguments):
    -- Append the target and opening parenthesis as today.
    for argument in arguments:
        value = match argument:
            UnmanagedArgument(id): id
            BorrowedArgument(borrow): borrow.value
        -- Append separators and c_value(value) directly.
```

Preserve both semantic IR types and every ownership check. Remove only the
temporary reverse translation and obsolete imports. Expected production
reduction: approximately **20–35 lines**. Traversal remains linear; temporary
call-argument lists disappear. Physical allocation/instruction gains remain
unmeasured.

Start with `test_emit.brp`, `test_record_emit.brp`, and tail-recursion phase
tests. Acceptance requires byte-identical C across existing valid fixtures,
including managed calls, retain/release ordering and loops, plus matched
allocation/instruction evidence and the normal e2e gate.

## 2. Return identity from name interning

**High confidence; low semantic risk; measure the result carrier.**

[names.brp:65](../../blorp_2/src/names.brp) searches the spelling table but
returns only the extended table. [parse.brp:248](../../blorp_2/src/parse.brp)
immediately searches again and handles an impossible lookup failure:

```blorp
names = intern_name(state.names, spelling)
match find_name(names, spelling):
    None: ...
    Some(id): ...
```

Let the existing interning operation publish its complete result:

```blorp
fixed record InternedName {
    names: NameTable,
    id: NameId
}
```

An existing spelling returns its known ID; a new spelling is appended once
and receives the previous table length as its ordinal, inside the authority
that owns the table. The parser consumes both fields directly. No new cache,
index or compatibility wrapper is needed.

Expected production LOC: roughly flat or slightly larger. Complexity remains
linear in table size, with one scan instead of two. Inspect host-generated C
and measure the result carrier before claiming a cost reduction.

Start with `test_names.brp`, `test_parse.brp`, then `test_prelude.brp` and grammar
tests. Preserve repeated-name identity, independently extended tables,
declaration order and exact spans. Update all callers in the same slice.

## 3. Give validation-only helpers a Void success result

**High confidence; very low risk; clarity improvement.**

Thirteen private helpers in [verify.brp](../../blorp_2/src/verify.brp), including
`verify_borrow` (line 179), `complete_owners` (682), and `verify_entry` (1225),
return `Result[Bool, Diagnostic]` but never `Ok(False)`. Callers discard success;
all rejection is represented by `Err`. `own.brp:require_unmanaged` (line 560)
has the same shape, while newer loop-admission helpers already use `Void`.

Use `Result[Void, Diagnostic]` and `Ok(void)` for these validation contracts.
This removes a misleading success state without removing checks. LOC and
algorithmic cost should remain essentially unchanged; no speedup is claimed.

Run `test_verify.brp`, `test_tail_recursion_verify.brp`, `test_record_verify.brp`,
`test_union_verify.brp`, and `test_own.brp`. Preserve every malformed-IR rejection
and exact diagnostic assertion.

## 4. Reuse the existing call accumulator throughout collection

**High confidence in redundant construction; physical cost needs measurement.**

[check.brp:3415](../../blorp_2/src/check.brp) already has `append_value_calls`,
which recursively accumulates calls in evaluation order. `assignment_calls`
(3446) and `exit_calls` (3398) instead construct per-expression lists and
concatenate them:

```blorp
-- Current
calls = calls.concat(value_calls(value))
-- Proposed
calls = append_value_calls(calls, value)
```

Pass an initial accumulator through assignment and exit helpers too, avoiding
separate prefix, scrutinee and arm lists in `function_calls` (3461). This is a
local collector cleanup; it needs no visitor framework or persistent call
inventory. `CheckedCall` remains authoritative.

Expected production LOC: neutral to a small reduction. Transient sublists
disappear; asymptotic improvement is not established and COW behavior must be
measured. Start with function-recursion, specialization and tail-checker unit
suites. Add a direct collection-order assertion covering initializers, record
children, UFCS arguments, scrutinee and arms. Preserve first-error diagnostics
and deterministic specialization order.

## Organization and sequencing

Keep these as separate slices, starting with direct ownership-IR emission.
Retain byte-identical C and matched allocation/instruction measurements for
representation or construction changes. Keep independent verification and
phase-specific identities; similar checks across those boundaries are
intentional safeguards.

Do not split `check.brp` or `parse.brp` solely because they are large. A broad
extraction would add import churn without resolving these concrete redundancies.
Reconsider module boundaries when an actual responsibility can move intact
with a smaller and clearer producer-to-consumer contract.
