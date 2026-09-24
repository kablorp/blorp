# Struct Payload Roadmap

Goal: a `struct` value stays a value wherever it lives. Today it is inline
as a record field, a local, a list element and an `Option` payload, but it
is copied into a heap box the moment it enters a union variant, a tuple, a
closure environment or a dictionary. Removing the box for union payloads,
then for closures, then converting the compiler's hottest small records to
structs is the one change in this set that lowers allocations in every phase
at once.

Each step lands on its own with a measurement taken before it starts. Read
[`WORKER_CHECKLIST.md`](WORKER_CHECKLIST.md) first. There is no measurement
lock; run gates directly. Every step here changes emitted C on purpose, so
the oracle is behavioural (runtime, leak, sanitizer, codegen-audit,
compiler suites) plus the measured effect, never byte identity, except where
a step says otherwise.

Historical source anchors are against main at `dab2f490` (2026-09-23). The
original hypotheses and estimates below are preserved for context; for S1-S3
they are superseded by the measured status and decisions that follow. S4 and
S5 remain proposals requiring their stated dependencies and fresh evidence.

Companions: [`CORE_NODE_TABLE_ROADMAP.md`](CORE_NODE_TABLE_ROADMAP.md) (N1
owns the `CoreSourceLoc` conversion; S4 here does not repeat it) and
[`TYPE_INTERNING_ROADMAP.md`](TYPE_INTERNING_ROADMAP.md) (I6 provides the
name id that lets `CoreVar` become a struct in S4).

## Current status and decisions (2026-09-24)

These decisions reflect the reviewed outcomes on their recorded bases. The S3
result is an explicit current-base comparison against `b72b0c7c`; S2's results
remain older-base experiments. Each future performance acceptance must use
the then-current integrated base.

| Step | Current status / decision |
| --- | --- |
| S0 | Landed on `main` at `e4c1b505`; the ownership fix passed focused, generated-C, broad, leak, and sanitizer gates. |
| S1 | `main` has its own struct/enum typed-storage change at `5cf87a20`. This is distinct from the experimental S1a candidate at `4fb…`; do not describe that candidate as landed. |
| S2a | The isolated S2a report is correctness evidence plus a small older-base measurement, not accepted/current-main performance evidence. Keep it experimental. See [`S2a outcome`](STRUCT_PAYLOAD_S2A_OUTCOME.md). |
| S2b / S2 | S2b broadened typed accessor reach, but its three-pair stage-2 comparison on base `a1fb8e6a` improved median retired instructions by only 0.1052%, below the predeclared ≥2% bar. Park S2; S2a/S2b remain experimental and neither report is a measurement against current `main`. See the [S2b negative experiment](../benchmarks/results/struct_payload_managed_union_s2b_probe_2026-09-23.md). |
| S3 | Accepted at `41592efd` following current-base evidence. The focused fixture reduced allocations 2,048→1,024 with checksum/live-object parity. Self-compile allocations fell 89,125 (-0.0388%); median retired instructions were effectively flat (+21,524), so there is no speed or latency claim. See the [current-base S3 outcome](../benchmarks/results/struct_payload_closure_env_current_base_2026-09-24.md). |
| S4 | Wait for I6 before the name-id-dependent `CoreVar` conversion. N1's `CoreSourceLoc` work is already on `main`; do not repeat it in S4. |
| S5 | Dictionary storage is parked: the inspected experimental C had 0 static dictionary boxing sites. Tuple storage remains only a future probe: 123 static sites in experimental C, not dynamic allocation/execution counts and not a post-S4 census. Recount after S4 before proposing implementation. |

S2a's report compares its candidate with an older `2bb45f3f` base and measured
median retired instructions +0.23%; S2b compares on the later `a1fb8e6a` base.
These are separate experiments, not a single cumulative or current-main
comparison. S3's 2026-09-24 measurement compares exact base `b72b0c7c` with its
candidate on the same frozen `d5fe8d9d` input; see the current-base outcome for
the full provenance and limitations.

## Historical baseline architecture snapshot (main at `dab2f490`)

The architecture, source anchors, and emitted-C counts in this section describe
the baseline named above, not present-day `main`; they are retained to explain
the original proposals. In particular, later main changes make some statements
below stale. For the present step status and decisions, use the table in
[Current status and decisions](#current-status-and-decisions-2026-09-24).

**Struct semantics.** `struct` fields must be scalars, fieldless enums or
other structs (`type_header_graph.brp:2536`, error
`TypeHeaderInvalidStructField`); no type parameters. The backend emits a
plain `typedef struct { ... }` with no object header, a `static inline`
by-value maker, `.` field access, and bools sunk to bitfields
(`emit.brp:24501`). Structs are not managed: `is_managed_type_in_set`
answers `False` for `ValueRecordType`, so Perceus emits no retain or
release for a struct value, pinned by
`blorp/test/runtime/types/test_struct_value_no_retain.brp`. The compiler has
116 structs and 1,491 records.

**Where a struct is already inline.**

- `List[S]`: `InlineStructListStorage` (`list_layout.brp:495`); the runtime
  list has `elem_size` and `storage_mode` and the element store is
  `blorp_list_set_raw_copy`. The `blorp_box_struct` on the list path is a
  probe-fallback only.
- `Option[S]`: a generated `typedef struct { int tag; S value; }
  blorp_StackOption_S` (`emit.brp:25267`); `match` reads `.tag` and `.value`
  through `StackOptionPayloadAccessor` (`match_projection.brp:601`).
- Record fields, locals, parameters, returns.

**Where a struct is boxed.** The helper is `blorp_box_struct(data, size)`:
`blorp_alloc(sizeof(blorp_Object) + size)` plus `memcpy`. Ten emit sites:

| construct | site | mechanism |
| --- | --- | --- |
| union variant payload | `emit.brp:7373` via `emit_generic_union_arg` (`:10278`) | the union is erased, so the slot is `void*` |
| tuple element | `emit.brp:7037`, `7198` (`TupleStructElement`) | `blorp_Tuple` is `void* elem[]` |
| dict key and value | `emit.brp:9488` | `void** keys; void** values` |
| closure argument, capture, return | `emit.brp:11587`, `11841`, `12089` (`ClosureAbiStruct`) | `blorp_Closure.env` is `void*` |
| explicit `CoreBoxOp` | `emit.brp:11431` | erased-slot marker from `specialize_layout.brp` |
| list store fallback | `emit.brp:9576`, `prepared_list_renderer.brp:477` | probe failed |

**Union layout is the lever.** A union is emitted as a header, an `int tag`,
an optional `release_mask`, and an anonymous C union of *per-variant
structs* (`emit.brp:24756`). Each variant field is typed by
`union_field_storage_type` (`emit.brp:24745`):

```
TypedUnionPayloadStorage:  TypeLayout.c_type_name(field.typ)
ErasedUnionPayloadStorage: "void*"
```

Which storage a *source-declared* union gets is decided in
`lower_union_payload_storage` (`lower.brp:5939`): typed only if the union
has no type parameters, is not a runtime-erased name, and **every field of
every variant is an arg-less scalar** (`source_union_typed_payload_field_supported`,
`lower.brp:5905`: `Int`, sized ints, `Float`, `Bool`, `Char`, `Fixed`,
`Range`). One `String` field anywhere erases every variant of the union. A
struct field erases it too. Erased unions carry a `release_mask` and release
by bit test; typed unions release per field by static policy
(`typed_union_field_release_statement`, `emit.brp:24803`: `NoReleasePolicy |
ArcReleasePolicy | ArcReleaseOnlyPolicy | StackResultReleasePolicy`).

**Monomorphized generic unions are already typed for every field type.**
`mono_data.brp:861` sets `TypedUnionPayloadStorage` on every concrete
instantiation unless the name is runtime-erased. So the emitter, the
destructor emitter and the reuse constructor already handle typed pointer
fields with static release policies; the scalar-only rule for source unions
is a conservative predicate, not a backend limitation.

**Consequences in the compiler's own IR.** `CoreExpr` (89 variants, all
with a `String`-carrying `CoreSourceLoc` or a `CoreType` somewhere) is
erased: every `Int` payload is cast through `(void*)(intptr_t)`, every
pointer payload is a `void*`, and every read goes through
`ErasedVariantFieldAccessor` with a cast. The same holds for `SemanticType`,
`ParsedExpr`, `TypedExpr` and every other source union with one non-scalar
field. Two hot frontend types were flattened to `Int` specifically to dodge
this: `SourceLocation` (`source.brp:37`: "a struct here is boxed by the
backend") and `Token` (`token.brp:154`).

**The SourceSpan lesson.** Converting `SourceSpan` to a struct (2026-09-16,
`git show 45c81b41:benchmarks/results/source_span_struct_probe_2026-09-16.md`)
cut discovery -5.5% but raised typed frontend +2.0%: 662 of 903 box sites in
the candidate's C were spans entering union payloads, each a fresh copy of a
value that had been shared by pointer. The rule it left: count where the
value lives before converting. The original roadmap expected later payload
steps to reduce that pressure; the measured scope and current decision are in
the status table above.

**Pre-census stale-C sample.** The original plan recorded 137
`blorp_box_struct` calls in a stale emitted-C artifact, dominated by
`blorp_StackOption_Int` (82), then frames and scanner structs. This is not a
current count. The later S0 census reports 247 static sites for its own
frozen-input artifact ([census report](../benchmarks/results/struct_payload_census_2026-09-23.md));
the two counts use different artifacts and are not directly comparable.

## Measurement

- `benchmarks/self_compile_measure` on the frozen input, three samples, from
  a stage-2 compiler for any step whose effect is in the compiler's own
  runtime behaviour (all of them: a union layout change reaches `bin/blorp`
  only after a stage-2 build or a bootstrap rotation).
- Report per-phase allocation rows, retired instructions, peak RSS, and the
  `blorp_box_struct` count in the emitted self-compile C.
- Gates: `scripts/test --serial compiler-blorp compiler-tools`,
  `scripts/test runtime`, `scripts/test leak`, `scripts/test
  compiler-core-sanitize`, `scripts/test compiler-blorp-sanitize`,
  `bash blorp/test/compiler/pipeline/codegen_audit/run_codegen_audit.sh
  bin/blorp`, `make hygiene-check`, `scripts/compiler-check --changed --base
  origin/main`.
- Codegen-audit fixtures that pin the current boxing (`compiler_record_layout.brp`
  lines 8 and 53, `process_session_typed_union_payloads.brp`,
  `list_option_int_inline_stack.brp`) are updated deliberately in the step
  that changes them, with the new expectation stated in the commit body.

Bootstrap: changing union layout in emitted C does not require a pin
rotation to land; the pinned compiler compiles the new sources and emits the
new layout. Rotation is only needed for the new layout to speed up
`bin/blorp` itself, and rotation is coordinator-directed.

## Steps

| step | what lands | expected effect | oracle |
| --- | --- | --- | --- |
| S0 | census of erased unions and box sites on the current build; a `BLORP_EMIT_PAYLOAD_CENSUS` report | numbers for S1 and S2 | none (report) |
| S1 | source unions with struct or enum payload fields get typed storage | struct payloads inline; `blorp_box_struct` count down; unlocks S4 | behavioural + codegen-audit updates |
| S2 | **parked 2026-09-24** (see below): typed storage for managed fields, built and gated green | measured on stage 2: instructions -0.04%, allocations +0.33%, emitted C -2.1%, RSS -0.8% | behavioural; stage-2 instructions |
| S3 | closure environments as a typed struct per closure instead of `void*` slots | struct captures inline; capture reads lose the unbox | behavioural |
| S4 | convert hot records to structs: `CoreVar`, `SourceSpan`, `CoreParam` shape, small type nodes | lowering -0.35M (`CoreVar`) and downstream; discovery -5%; typed frontend no longer +2% | behavioural + allocation rows |
| S5 | tuple elements and dictionary slots typed by monomorphized layout | remaining box sites gone | behavioural |

### S0: census

**Change.** A read-only report, in the shape of
`benchmarks/results/emitted_c_pattern_census_2026-09-23.md`: for the
self-compile C, how many source unions are erased and why (which field
type blocked typed storage, per union), how many `(void*)(intptr_t)` casts
and `ErasedVariantFieldAccessor` reads exist, and the `blorp_box_struct`
count by boxed type. Committed under `benchmarks/results/`.

**Expected ROI.** None; it sets S1's and S2's targets. Estimate before
measuring: nearly every compiler union is erased, so S2's reach is most of
the IR.

### S0 result (2026-09-23)

`benchmarks/results/struct_payload_census_2026-09-23.md`. Of 532 source
unions, S1 as written unlocks 8; S2 as written unlocks 352 (71% of the 495
non-generic erased unions), including `CoreExpr`, `SemanticType`,
`ParsedExpr` and `TypedExpr`. The remaining 143 are blocked, all but three of
them, by an **opaque type** field (`opaque type X = Rep`): the predicate
matches the field's own type name and never unwraps to the representation,
so a union carrying an `AnalysisPurpose`- or `DocumentUri`-shaped id stays
erased although the payload is an `Int` or a `String`. S2 must resolve
opaque types to their representation before classifying the field (25 of the
182 opaque field instances resolve to `Int`, 15 to `String`; the rest to
records and unions that S2 accepts anyway). The runtime audit found no
helper that walks a union payload as `void*`; the S2 risk surface is the
emitter's release-policy derivation and destructor emission, not
`runtime.c`. No dynamic counter attributes allocations to `blorp_box_struct`;
the census counts are static.

### S1: typed payloads for struct and enum fields

**Context.** `source_union_typed_payload_field_supported` accepts scalars
only. Structs and fieldless enums are values with no ownership, exactly what
a typed slot needs, and `List[S]` and `Option[S]` already prove the layout
code handles them.

**Change.** Extend the predicate:

```
-- lower.brp, source_union_typed_payload_field_supported
ValueRecordType(_): True      -- a struct: inline, no release
EnumType(_): True             -- a fieldless enum: an int tag
```

and give those fields `NoReleasePolicy` in the typed release table. With the
predicate still all-or-nothing per union, a union whose fields are all
scalars, structs and enums becomes typed; the variant struct holds the
struct by value:

```c
/* before: union Shape: Circle(Vec2, Float) | Square(Vec2, Float) */
struct { void* field0; void* field1; } Circle;           /* field0 boxed Vec2 */
/* after */
struct { Vec2 field0; double field1; } Circle;
```

Construction takes `Vec2` by value; `match` reads `.data.Circle.field0`
directly through `VariantFieldAccessor`. Update `compiler_record_layout.brp`
lines 8 and 53 to `EXPECT-NOT-C` the box.

**Expected ROI.** Small on the self-compile today (few struct payloads
exist because they were avoided); measurable on `compiler_record_layout`
and `test_struct*` programs. The value of S1 is that S4 becomes possible.

**Risks.** Copy semantics: a struct payload is copied on construction and
on read, which is what a struct means everywhere else in the language.
Unions containing themselves recursively through a struct cannot occur
(struct fields cannot be unions).

**Oracle.** Runtime, leak, codegen-audit, compiler suites;
`test_core_emit.brp` union fixtures updated where they pin the erased form.

### S2: typed payloads for managed fields

**Parked 2026-09-24 with numbers** (branch `backend/s2-typed-managed-payloads`,
all gates green, codegen-audit 220/220). The predicate was extended to every
field type the mono path accepts, with the type-kind table gaining record and
union names; release policies needed no change because
`cleanup_release_policy_for_type` already derived them per field regardless
of storage. Two hand-written runtime-bridge emitters that hardcoded the erased
two-argument convention for native error unions were found and fixed. Stage-2
measurement on the frozen self-compile:

| metric | parent | candidate | delta |
| --- | --- | --- | --- |
| instructions retired (min of 3) | 284,992,725,939 | 284,871,812,592 | -0.04% (noise band) |
| total allocations | 181,837,033 | 182,433,234 | +0.33% (typed frontend +2.39%, mono +1.77%) |
| emitted C | 112,309,349 | 109,945,309 | -2.10% |
| peak RSS | 2,073,034,752 | 2,056,339,456 | -0.81% |

The instruction estimate in this roadmap was wrong: an erased scalar payload
is one cast and a release is one mask test, and neither is measurable
against the rest of a node visit. What S2 buys is smaller C and lower RSS,
and the allocation rise (the widened predicate's per-field lookups and the
canonical-field work for 352 newly typed unions) would have to be removed
before even that is a clean win. Do not reopen for instructions. Reopen only
if emitted C size becomes the target metric, and then fix the allocation
regression first (cache the kind lookups per union, and check why
`typed_frontend_complete` moved at all for a lowering-side change).

The original text follows for the record.


**Context.** The mono path already emits typed storage for pointer fields
with static release policies and no `release_mask`. Source unions are held
to scalars only by the predicate. Every IR union in the compiler pays a cast
per read and a mask test per release.

**Change.** Extend the predicate to every field type the mono path accepts:
records, unions, `String`, lists, dictionaries, functions, tensors, tuples,
with the release policy derived the same way `mono_data.brp` derives it. The
predicate then reduces to "no type parameters and not a runtime-erased name",
and `lower_union_payload_storage` and `mono_data.brp:861` should share one
function. Emitted shape for one `CoreExpr` variant:

```c
/* before */
struct { void* field0; void* field1; void* field2; void* field3; } BinaryExpr;
/* construct: ..._BinaryExpr((void*)(intptr_t)op, left, right, (void*)typ, (void*)loc), release_mask = 0b01110 */
/* after */
struct { long field0; CoreExpr* field1; CoreExpr* field2; CoreType* field3; long field4; } BinaryExpr;
/* destructor: if (self->data.BinaryExpr.field1) blorp_release(self->data.BinaryExpr.field1); ... */
```

Transfer-out semantics: an erased union clears a mask bit when a payload is
moved out; typed unions in the mono path express this through the ownership
passes' release policies (`ArcReleaseOnlyPolicy` for fields whose payload
may have been consumed). Reuse the mono path's rules; do not invent new
ones. The union reuse constructor (`emit.brp:25019`) already handles typed
fields.

**Expected ROI.** This is the instruction step. Every union read in the
compiler drops a cast and every union release drops a mask test; estimate
retired instructions -3% to -6% on the self-compile from a stage-2 build,
allocations flat, emitted C smaller (no mask field, no cast text). Go/no-go:
instructions must fall by at least 2% or the step is parked with numbers.

**Risks.** The widest behavioural change in the roadmap: every source union
in every program changes layout. The runtime's generic union helpers (JSON
dumps, the leak checker's live-object summary, foreign marshalling at
`runtime.c:29932`) must not assume `void*` slots; audit them in S0. Union
destructors for recursive unions (`IterativeUnionCleanup`, 38 in the
self-compile) cast fields to the union pointer type; with typed fields the
cast is exact.

**Oracle.** All behavioural gates, including `compiler-blorp-sanitize` and
`runtime-tsan` if present; codegen-audit fixtures updated;
`process_session_typed_union_payloads.brp` becomes the general case.

### S3: closure environments as structs

**Context.** `blorp_Closure.env` is a `void*` array with a release mask;
struct captures are boxed (`emit.brp:11841`) and read back with a cast and
copy (`test_core_emit.brp:10505`).

**Change.** Closure conversion (`closure.brp`) already knows every capture's
type. Emit one `typedef struct { blorp_Object header; T0 c0; T1 c1; ... }
__env_N` per closure, capture structs by value, and generate the env
destructor per closure like a heap record's. Calls and returns of struct
type through a closure (`ClosureAbiStruct`) keep boxing in this step; that
is an ABI change for a later step if S0 shows it matters.

**Expected ROI.** Removes the capture box sites; per-closure destructors
replace the mask loop. Allocations: one box per struct capture per closure
creation; instructions modest. Measure on stage 2.

**Risks.** The closure ABI is shared with the runtime's task and channel
machinery; keep the `blorp_Closure` header and function slot, change only
what `env` points at.

**Oracle.** Behavioural gates; `test_struct_value_no_retain.brp`.

### S4: hot records become structs

**Context.** Original premise, conditional on the required S1 and S2 union-
layout changes being landed: the SourceSpan rule no longer applies to a struct
in a union payload. S2 is currently parked, so that premise does not hold;
S4 remains gated on I6 and a fresh decision about its S2 dependency. Candidates
from the lowering type histogram and the allocation census:

| type | today | as a struct | needs |
| --- | --- | --- | --- |
| `CoreVar { name: String, id: Int, def_id: Option[Int] }` | record, 349k allocations in lowering, rebuilt by every pass | `struct { name: NameId, id: Int, def_id: Int }` with `-1` for none | `TYPE_INTERNING_ROADMAP` I6 (name id) |
| `SourceSpan { path: String, module_name: String, 6 x Int }` | record | `struct { path: NameId, module: NameId, 6 x Int }` | I6 |
| `CoreParam { name: CoreVar, typ: CoreType, loc }` | record | stays a record (holds a `CoreType` pointer) unless N5 gives it a type id | N5 |
| `CoreLowerScopeEntry { name: String, id: Int }` | record; struct explicitly rejected at `lower.brp:508` | struct with a name id | I6 |
| `CoreSourceLoc` | union with a `String` | owned by `CORE_NODE_TABLE_ROADMAP` N1 | N1 |

**Change.** One type per commit, each with the SourceSpan probe's method:
count where the value lives, convert, measure every phase row. The
`CoreVar` conversion also lets `core_var_equal` become two integer compares
and removes one allocation from every binder in every rebuild.

**Expected ROI.** `CoreVar`: -0.35M in lowering and a comparable amount in
each pass that rebuilds binders (estimate -1M to -2M total). `SourceSpan`:
discovery -5% as measured, without the +2% typed-frontend penalty.
`CoreLowerScopeEntry`: the record box per scope entry gone. Across the
pipeline, estimate -2% to -4% of total allocations, plus the instruction
savings of value copies over retain and release pairs.

**Risks.** Each conversion changes many call sites mechanically; the
formatter and compiler suites catch shape errors, the leak gate catches
ownership ones. `Option[Int]` to a sentinel is a semantic choice; document
`-1` in the struct's docstring.

**Oracle.** Byte-identical C is expected for `CoreVar` and
`CoreLowerScopeEntry` (they are compiler-internal); `SourceSpan` changes
diagnostics only if a caller drops the path, so the 860 fixtures are the
oracle there.

### S5: tuples and dictionaries

**Context.** `blorp_Tuple` and `blorp_Dict` are erased and shared with the
runtime's generic helpers. Most local tuples are removed by SROA, so the
remaining boxes are few.

**Change.** Only if S0's census shows a measurable count after S1 to S4:
monomorphized tuple layouts (a per-shape C struct chosen in
`specialize_layout.brp`) and typed dictionary storage for struct keys and
values, in that order.

**Expected ROI.** Small; this step exists to finish the job, not for the
numbers. Park it if S0 says so.

## Parallelism

S0 and S1 start now. S2 follows S1 in the same files (`lower.brp`
`lower_union_payload_storage`, `emit.brp` union emission,
`match_projection.brp`, `specialize_layout.brp`, codegen fixtures) and should
be the same worker or a sequential handoff. S3 is independent of S2 and can
run alongside it (`closure.brp` and the closure emission in `emit.brp`). S4
waits for S1, and for I6 for the types that need a name id; the `CoreVar`
row is the first S4 task once I6 lands. None of S0 to S3 touch the files the
node or interning roadmaps own; merge main before every gate run because all
three roadmaps land into `emit.brp` and `lower.brp` in different functions.

## Not in this roadmap

Struct fields of non-scalar type (the language rule stays); generic structs;
changing `List`, `Dict` or `Option` runtime representations beyond what S5
names; bootstrap rotation.
