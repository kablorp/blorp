# Struct Payload Roadmap

Goal: a `struct` value stays a value wherever it lives. It is inline as a
record field, a local, a list element, an `Option` payload, a closure
environment capture and a source-union payload whose union is otherwise typed;
it is still copied into a heap box when it enters a tuple, a dictionary, a
closure's call ABI, or an erased union variant. This roadmap holds the open
steps; the landed ones (the census, typed payload storage for struct and enum
fields of source unions, typed closure environments) and the measurements
behind every decision are in `benchmarks/results/` and Git history.

Read [`WORKER_CHECKLIST.md`](WORKER_CHECKLIST.md) first. Every step here changes
emitted C on purpose, so the oracle is behavioural (runtime, leak, sanitizer,
codegen-audit and compiler suites) plus the measured effect, never byte
identity, except where a step says otherwise.

## What the layout looks like

- **Struct semantics.** `struct` fields must be scalars, fieldless enums or
  other structs; no type parameters. The backend emits a plain `typedef struct`
  with no object header and a by-value maker. Structs are unmanaged, so
  Perceus emits no retain or release for one
  (`blorp/test/runtime/types/test_struct_value_no_retain.brp`).
- **Where a struct is boxed.** `blorp_box_struct(data, size)` allocates a
  `blorp_Object` plus a `memcpy`. Remaining sites: erased union variant
  payloads (the slot is `void*`), tuple elements (`blorp_Tuple` is
  `void* elem[]`), dictionary keys and values (`void** keys; void** values`),
  closure call arguments and returns (`ClosureAbiStruct`), explicit `CoreBoxOp`
  markers from `specialize_layout.brp`, and the list-store fallback.
- **Union layout is the lever.** A union is a header, an `int tag`, an optional
  `release_mask`, and a C union of per-variant structs, each field typed by
  `union_field_storage_type` in `emit.brp` as typed
  (`TypeLayout.c_type_name(field.typ)`) or erased (`void*`). A source union
  gets typed storage only if `lower_union_payload_storage` in `lower.brp`
  accepts every field of every variant
  (`source_union_typed_payload_field_supported`: scalars, structs and fieldless
  enums); one `String` field erases every variant. Monomorphized generic unions
  (`mono_data.brp`) are already typed for every field type, so the emitter,
  destructor emitter and reuse constructor handle typed pointer fields with
  static release policies; the restriction on source unions is a conservative
  predicate, not a backend limitation. `CoreExpr`, `SemanticType`, `ParsedExpr`
  and `TypedExpr` are erased: every `Int` payload is cast through
  `(void*)(intptr_t)` and every read goes through `ErasedVariantFieldAccessor`.
- **The SourceSpan lesson.** Converting `SourceSpan` to a struct cut discovery
  -5.5% but raised typed-frontend allocations +2.0%: 662 of 903 box sites in the
  candidate's C were spans entering union payloads, each a fresh copy of a value
  that had been shared by pointer. Count where a value lives before converting
  it.

## Measurement

- `benchmarks/self_compile_measure` on the frozen input, three samples, from a
  stage-2 compiler (the union layout reaches `bin/blorp` only after a stage-2
  build or a bootstrap rotation; see
  [`PER_NODE_CODEGEN_ROADMAP.md`](PER_NODE_CODEGEN_ROADMAP.md#the-stage-2-rule)).
  Report per-phase allocation rows, retired instructions, peak RSS and the
  `blorp_box_struct` count in the emitted self-compile C.
- Gates: `scripts/test --serial compiler-blorp compiler-tools`,
  `scripts/test runtime`, `scripts/test leak`,
  `scripts/test compiler-core-sanitize`, `scripts/test compiler-blorp-sanitize`,
  `bash blorp/test/compiler/pipeline/codegen_audit/run_codegen_audit.sh bin/blorp`,
  `make hygiene-check`, `scripts/compiler-check --changed --base origin/main`.
- Codegen-audit fixtures that pin current boxing
  (`compiler_record_layout.brp`, `process_session_typed_union_payloads.brp`,
  `list_option_int_inline_stack.brp`) are updated deliberately in the step that
  changes them, with the new expectation stated in the commit body.
- Changing a union layout in emitted C does not need a bootstrap rotation to
  land; rotation is needed only for the layout to speed up `bin/blorp` itself.

## Open steps

### S2. Typed payloads for managed fields (parked)

Extending the predicate to every field type the monomorphized path accepts
(records, unions, `String`, lists, dictionaries, functions, tensors, tuples,
with the release policy derived the way `mono_data.brp` derives it) was built
and passed every gate (codegen-audit 220/220), then parked on stage 2: retired
instructions -0.04% (noise), total allocations +0.33% (typed frontend +2.39%, mono
+1.77%), emitted C -2.10%, peak RSS -0.81%.

A broader accessor reach (three stage-2 pairs on a later base) improved median
retired instructions by only 0.1052%, below the predeclared 2% bar; evidence in
[`struct_payload_managed_union_s2b_probe_2026-09-23.md`](../benchmarks/results/struct_payload_managed_union_s2b_probe_2026-09-23.md)
and [`STRUCT_PAYLOAD_S2A_OUTCOME.md`](../benchmarks/results/STRUCT_PAYLOAD_S2A_OUTCOME.md).
An erased scalar payload is one cast and a release is one mask test; neither is
measurable against the rest of a node visit. **Do not reopen for
instructions.** Reopen only if emitted C size becomes the target metric, and
fix the allocation regression first: cache the kind lookups per union, and find
out why `typed_frontend_complete` moved at all for a lowering-side change.
Opaque types blocked 143 of the 495 non-generic erased unions in the census;
any reopening must resolve an opaque type to its representation before
classifying the field. Oracle if reopened: all behavioural gates including
`compiler-blorp-sanitize`; the runtime's generic union helpers (JSON dumps, the
leak checker's live-object summary, foreign marshalling) must not assume
`void*` slots.

### S4. Hot records become structs

Needs a fresh census after the identity work in
[`IDENTITY_ROADMAP.md`](IDENTITY_ROADMAP.md) lands, and a fresh decision about
the S2 dependency (a struct in an erased union payload is still boxed, so the
SourceSpan lesson still applies). `CoreVar` and `CoreSourceLoc` are not
candidates here: the identity roadmap's "Delete strings from Core variables"
step replaces `CoreVar` with a spelling-free value id, and `CoreSourceLoc` is
already an opaque `Int`. `CoreParam { name, typ, loc }` stays a record while it
holds a `CoreType` pointer, until expression and parameter types become type ids
("Core types as type ids" in the identity roadmap). `SourceSpan` is worth
converting only if a fresh census still shows material cost.

One type per commit, each with the SourceSpan probe's method: count where the
value lives, convert, and measure every phase row. Do not introduce sentinel
encodings where a typed id or precise variant already represents the state.
Oracle: byte-identical C for compiler-internal representation cuts unless the
change names a layout change; exact diagnostic fixtures for any display-span
carrier.

### S5. Struct values in erased dictionary storage

`blorp_Dict` uses erased key and value slots shared with the runtime's generic
helpers. A struct key or value entering those slots needs a box. A prior
inspection of generated dictionary C found no such boxes; that static
observation does not establish the dynamic cost. After S4, count actual
`blorp_box_struct` calls at dictionary boundaries on a current workload.
Consider typed dictionary storage for struct keys and values only if the
dynamic count and a stage-2 measurement justify it; otherwise park S5.

Tuple storage layout belongs to
[`VALUE_TUPLES_AND_STATE_HANDOFF.md`](VALUE_TUPLES_AND_STATE_HANDOFF.md#increment-7-stored-tuples),
increment 7, including tuple fields, `List[(A, B)]`, `Option` payloads and
`List.enumerate`. An experimental build counted 123 *static* tuple box sites;
the older self-compile's dynamic tuple census (built at `9172b35e0`;
value-tuple plan, appendix B) attributed 1,052,834
*executed allocations* to stored list tuples. These measure different things
on different revisions, so neither substitutes for a census after increment
1. Increment 1 removed local/match tuple boxes, not these stored tuples.
Increment 7 needs a fresh dynamic census after increment 2 before choosing
any layout change.

## Not in this roadmap

Struct fields of non-scalar type (the language rule stays), generic structs,
stored tuple layout (increment 7 of the value-tuple plan), changing `List` or
`Option` runtime representations, changing `Dict` beyond S5's struct-key and
struct-value storage, and bootstrap rotation. Files this roadmap touches (`lower.brp`
`lower_union_payload_storage`, union emission in `emit.brp`,
`match_projection.brp`, `specialize_layout.brp`, codegen fixtures) are disjoint
from the identity roadmap's except `ir.brp`; merge main before every gate run.
