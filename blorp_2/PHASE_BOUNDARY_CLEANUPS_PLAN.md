# Remove three unnecessary phase-boundary carriers

## Scope and sequence

This implements audit findings F3, F4 and F5 after the accepted F1/F2 work.
Initial main is `eb7b9fe1bd5dec40a8a2dd8acfae27fd02b53e6e`. Each finding is
an independently reviewed, measured and publishable change, in that order.
The compiler architecture and language semantics do not change.

Plan the slices in parallel; serialize production edits, compilation and
measurements. Each slice's before-image is its immediately preceding accepted
compiler. Record the exact revision, all 41 source hashes, libraries, tools,
flags and binaries before reuse. The original initial-main image remains the
baseline for any explicitly cumulative claim; do not label it an incremental
baseline after another slice changes production.

Root integrates and owns the compiled lane. F3's implementer is the
specialization/lowering agent, F4's the frontend agent, and F5's the backend
agent, acting as compiler experts. The other two agents independently review
each slice, including code-reviewer and test-runner responsibilities, before
commit. Both review the design early. No worker commits, switches branches or
pushes. Root lands each green approved slice on main and pushes origin/main.

## F3: choose the callee anchor once in Lower

Before Lower, `ConcreteExpr.span` and `ConcreteCall.span` are distinct useful
facts. Keep both, and leave Specialize's production representation unchanged.
Lower currently chooses the callee anchor for a definition but also embeds the
entire `ConcreteCall` in its operation. Own retains both spans. Verify reads the
nested span for target errors and the definition span for argument/result
errors. This permits contradictory raw IR after the choice is already made.

Current code (`src/lower/lower.brp:84,459`, `src/own/own.brp:101`):

```blorp
CallValue(ConcreteCall, List[ValueId])
Ok(define_value(children.builder, CallValue(call, children.values), value.value_type, call.span))

CallDefinition(ConcreteCall, List[OwnedArgument])
```

Proposed:

```blorp
CallValue(CallTarget, List[ValueId])
Ok(define_value(children.builder, CallValue(call.target, children.values), value.value_type, call.span))

CallDefinition(CallTarget, List[OwnedArgument])
```

The existing definition owns the sole callee anchor after Lower. Own preserves
that anchor and forwards the existing target and arguments. Verify's
`call_signature` (`src/verify/verify.brp:409`) takes `target: CallTarget` and
`span: Span`; its caller passes `definition.span`. Runtime-contract and unknown
user-target errors use that span. Argument, result, ownership, layout and
backedge validation remain independent and retain their current checks.
Emit's three call consumers match the target directly and keep their existing
enclosing diagnostic span. No wrapper, registry or general span erasure.

Production scope is exactly Lower, Own, Verify and Emit, with necessary import
changes. Migrate raw call constructors and observers in owning unit suites and
shared ownership/file/current-directory helpers. Keep genuine pre-Lower
`ConcreteCall` helpers in Specialize and reachable-specialization tests.

Forecast: production about 20–35 ADD / 20–35 DEL, near-neutral; **hard at most
60 ADD and +2 net**. Tests about 180–260 ADD / 300–420 DEL; **hard at most
350 ADD and at least 50 net lines removed**. No fixtures. Do not compress
formatting, delete coverage or perform unrelated cleanup to meet the limits.

### F3 correctness and cost oracles

First strengthen any incomplete baseline-compatible anchor assertion and run
the existing ordinary-call Lower, Lower write-file, Own file-read and Verify
file-read/write-file suites. Ordinary-call tests distinguish callee spans from
whole-expression spans; builtin bodies can legitimately give them equal spans.
A semantics-preserving representation change does not manufacture semantic RED:
API-incompatible migrated constructors are a type-level difference, not a
runtime regression reproduction.

Preserve exact message, help, notes, source and byte spans for malformed target,
arguments and results. Keep Lower's callee-versus-whole-occurrence distinction,
its shifted-anchor negative oracle, and Own's exact definition-anchor assertion.
Add a small unknown-user-target rejection with an authority-issued function ID
absent from the supplied vector, asserting the definition's anchor. Retain
pre-Lower occurrence/callee tests.

Prove the oracles with two bounded mutations, separately: make Lower use the
whole expression span; then shift the span supplied to Verify's call-signature
check. Named callee-anchor and malformed-target/runtime-contract assertions
must fail. Restore exact source bytes/hashes and rerun the narrow suites green.

```sh
bin/blorp test --suite --timeout 180 \
  blorp_2/test/unit/test_lower/test_lower.brp \
  blorp_2/test/unit/test_lower/test_write_file.brp \
  blorp_2/test/unit/test_own/test_file_read.brp \
  blorp_2/test/unit/test_verify/test_file_read.brp \
  blorp_2/test/unit/test_verify/test_write_file.brp
```

Retained target controls: `call/one.brp`, `ufcs/chain_64.brp`,
`generic/named/managed.brp`, `option_input/parse_int.brp`,
`file_read/ownership.brp`, `file_write/ownership.brp`.

## F4: remove the unread purity parameter

`src/check/expressions.brp` forwards a separate purity value through five
private helpers without consulting it. Real call enforcement reads
`ResolutionContext.caller`; named callback enforcement reads the accepted
signature. Neither authority nor its enforcement changes.

Current (`expressions.brp:446,636,1288`):

```blorp
private pure func resolve_postfixes(purity: Purity, scope: List[ScopedValue], body: ValueExpression, context: ResolutionContext) -> Result[List[ResolvedPostfix], CheckError]:
match resolve_postfixes(purity, scope, written, context):
elaborate_value(context.caller.purity, scope, body, constructor_type, None, context)
```

Proposed:

```blorp
private pure func resolve_postfixes(scope: List[ScopedValue], body: ValueExpression, context: ResolutionContext) -> Result[List[ResolvedPostfix], CheckError]:
match resolve_postfixes(scope, written, context):
elaborate_value(scope, body, constructor_type, None, context)
```

Apply only the same mechanical removal to `plan_base`, `plan_expression`,
`pending_receiver_contract` and `elaborate_value`: five parameter declarations
and six forwarding calls. Preserve the public `synthesize_value`/`check_value`
interfaces, `Purity(Pure), same_purity`, callback guard and call scheduling.
One production module; no replacement context, new API or adjacent cleanup.

Forecast **10 production ADD / 11 DEL, net −1**; hard **at most 12 ADD and
at least one net line removed**. Tests/fixtures **0 ADD / 0 DEL**. Most edits
shorten existing lines; do not promise a material runtime/RSS win or reformat
to manufacture a larger LOC reduction.

Existing callables, named-callback diagnostics, method resolution, match and
contextual-inference suites cover direct/transitive/unreachable rejection,
containing-function purity for nested arguments, permitted impure callers,
UFCS, arity-before-purity, callback compatibility and exact diagnostic order.
Run them before and after; add no test mirroring unused parameters.

```sh
bin/blorp test --suite --timeout 180 \
  blorp_2/test/unit/test_check/test_callables.brp \
  blorp_2/test/unit/test_check/test_named_callable_diagnostics.brp \
  blorp_2/test/unit/test_check/test_method_resolution.brp \
  blorp_2/test/unit/test_check/test_match.brp \
  blorp_2/test/unit/test_check/test_contextual_inference.brp
```

For a bounded enforcement-oracle mutation, temporarily bypass the existing
named-callback purity guard. Ordinary named-callback assertions must fail;
restore exact bytes/source hash and rerun green. This validates the real rule,
not the spelling or count of private parameters. Retained cost controls:
`pure/calls.brp`, `ufcs/chain_64.brp`, `generic/named/identity.brp`,
`generic/named/ordered.brp`, `generic/named/managed.brp`, `return/zero.brp`.
Rejection paths remain in full-corpus identity and exact checker diagnostics;
these six cost controls all compile successfully.

## F5: stop publishing the unused concrete field span

`src/specialize/specialize.brp:206–210,2425–2427` has one concrete field
constructor, shared by record literals and update replacements. It needs the
checked span for field-identity translation, then publishes an unread copy.
Lower reads only the field identity and child expression.

Current:

```blorp
fixed record ConcreteRecordField {
    field: FieldInstanceId,
    value: ConcreteExpr,
    span: Span
}
id ?= translate_field(field.field, owner, records, field.span)
child ?= translate_expr(opaques, field.value, substitution, callables, keys, unions, records)
Ok({ field = id, value = child, span = field.span })
```

Proposed:

```blorp
fixed record ConcreteRecordField {
    field: FieldInstanceId,
    value: ConcreteExpr
}
id ?= translate_field(field.field, owner, records, field.span)
child ?= translate_expr(opaques, field.value, substitution, callables, keys, unions, records)
Ok({ field = id, value = child })
```

Keep `CheckedRecordField.span` for translation errors, child occurrence spans,
and `ConcreteRecordUpdate.base_expression_span` for inherited projections.
Migrate only `test_specialize/test_record_update.brp` assertions from the
removed span to `field.value.span`, dropping impossible duplicate equality and
its unused import. Preserve exact source/start/end, order, values, ordinals,
nominal owners and types. No Lower/Own/Verify/Emit production changes.

Forecast **production 2 ADD / 3 DEL, net −1; tests 7 ADD / 8 DEL, net −1**.
Hard production **at most 3 ADD, at least one net line removed**; tests **at
most 8 ADD and no net growth**. No new helper, type, test or fixture.

Run migrated assertions on B before production edits: they must pass. Prove
the preservation oracle by shifting both endpoints of the translated child
span by one; the existing written-replacement order/value/type/span callback
must fail. Restore exact source bytes/hash and require green.

```sh
bin/blorp test --suite --timeout 180 \
  blorp_2/test/unit/test_specialize/test_record_update.brp \
  blorp_2/test/unit/test_specialize/test_record.brp \
  blorp_2/test/unit/test_lower/test_record_update.brp
```

Retained controls: `record/wide.brp`, `record/generic/phantom_arguments.brp`,
`record/update/order.brp`, `record/update/managed_reorder.brp`,
`record/update/escaped_children.brp`, `return/zero.brp`.

## Shared acceptance, evidence and stop conditions

All commands above are documented equivalents: this worktree borrows the
verified FRESH primary repository host with explicit `--std-dir`. Record the
actual absolute commands. Build each candidate pilot once, using the same
generated C at O0 for normal and diagnostic images. Reuse only source- and
tool-matched predecessor images; do not relabel stale images as the new base.

Reuse the existing local measurement runner, not a new framework. Take fresh
matched host source-to-C construction-proxy samples and six target controls
per slice, fixed source/library/output paths within each comparison. Use one
diagnostic sample and normal order B1,C1,C2,B2,B3,C3. Preserve every original;
report normal min3 retired instructions and median3 peak RSS separately from
diagnostic allocations/checkpoints. Require positive counters, balanced strict
target accounting and within-role normal/diagnostic output identity. Whole
compiler-source C may change; all frozen fixture outcomes and successful C
bytes must match exactly across roles. Inspect representative generated C.

The host construction workload omits linking, target self-compilation and its
unavailable later-stage lifetime measurements. Carrier removal does not prove
early physical retirement: existing outer phase roots remain a separate L1
investigation. Do not claim an elapsed-speedup or retained-byte win without
the appropriate matched evidence.

Judge overall simplification/resource direction, as the user requested; every
metric need not fall. Attention: increases above **0.5% whole construction**
or **1% per target control** allocations/instructions. Hard: **+1% whole**,
**+3% target**, plus all tighter existing native caps. Investigate RSS growth
above the greater of **1% or 1 MiB**. One complete additional matched batch may
resolve ambiguity; retain originals. A breach prompts owning-phase
investigation and rejection/rescoping, never unrelated tuning, rolling the
baseline forward or silently relaxing caps. Reassess uncertain directions.

For every slice, run focused owners, then full unit/runtime/grammar components,
tooling and the sole native umbrella with required instructions, unchanged
caps, strict accounting and existing C11/O0 ASan/UBSan checks. An empty
`compiler-check --plan` is not validation. Require independent code-reviewer
and test-runner approval of code, tests, costs and final report before commit.
Keep production/test/fixture/doc counts separate; keep raw samples under
ignored build directories and one concise report per slice under
`benchmarks/results/`. Preserve and hash-verify borrowed evidence in the primary
checkout before any archival. Verify the actual remote main SHA after push.
