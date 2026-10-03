# Fixed Layout Roadmap

Status: R1 `fixed record` syntax is implemented with the existing unmanaged
value layout; managed fixed fields and fixed unions remain open. R0 has a
measured baseline checkpoint, but its dynamic placement census is incomplete,
so R2/R3 go/no-go thresholds remain open. Implement the **record** slices
first, measure them, and decide whether to proceed to unions. This is not a
mandate to unify every aggregate under one IR type. Retain measurements for
later slices in `benchmarks/results/`.

Read [WORKER_CHECKLIST](WORKER_CHECKLIST.md) before implementation. The
[Language Guide](GUIDE.md) and [Grammar](GRAMMAR.md) describe *current*
behavior; this roadmap also includes later proposed syntax below. The existing
[Struct Payload Roadmap](STRUCT_PAYLOAD_ROADMAP.md) records narrower layout
experiments and their negative results; the
[Value Tuple and State Handoff](VALUE_TUPLES_AND_STATE_HANDOFF.md) plan owns
the already-started multi-value tuple work. Neither should be silently
replaced by this document.

## Outcome and boundaries

The language should have `record`/`fixed record` for named products and
`union`/`fixed union` for named sums. A tuple is a structural product with
ordinal fields, not another nominal declaration. A fieldless `fixed union`
replaces `enum`. `fixed record` and `fixed union` **cannot declare type or
dimension parameters**. Ordinary records and unions remain generic. The
generic standard-library unions `Option[T]` and `Result[T, E]` keep their
compiler-specialized representations; they may reuse product/tagged-aggregate
layout operations without being declared generic fixed unions.

`fixed` promises a statically known **shallow** value layout and no separate
ARC header for the value in a typed inline-capable position. It does not
promise literal stack placement, no child allocation, or no ARC on a field.
For example, a future `fixed record` with a `String` field has an inline root
and an ARC-managed string child. Typed locals, direct parameters/results and
typed fields are the target inline-capable positions. Erased collection,
closure, generic-call or foreign ABIs may need an explicit transport box;
document and test each such boundary instead of silently weakening `fixed`.
`fixed` and the numeric `Fixed` type are unrelated.

These examples mix current R1 syntax with future targets: `fixed record Point`
(with unmanaged fields) and ordinary `record Box[T]` are valid today;
`fixed union` and managed fixed fields are not. Parameterized fixed
declarations remain errors:

```blorp
fixed record Point {x: Float, y: Float}

record Box[T] {value: T}                  -- still generic and heap-backed by default

fixed union Signal:
    Ready
    Value(Int)

union OptionLike[T]:
    Some(T)
    None

fixed record Header {name: String}       -- after managed inline fields land
fixed union Reply:                      -- after managed inline payloads land
    Empty
    Data(String)

fixed record GenericBox[T] {value: T}   -- error: fixed declarations have no parameters
fixed union GenericChoice[T]:           -- the same error
    Some(T)
    None
```

These are **different axes**:

| Type | Source identity | Declared layout contract | Ownership of contents |
| --- | --- | --- | --- |
| `record R` | nominal product | default heap object; compiler may eliminate its allocation when sound | ARC root and managed fields |
| `fixed record R` | nominal product | by-value, known shallow layout | initially trivial fields; later field-wise ownership |
| `(A, B)` | structural product | local/return multi-value where possible; stored representation depends on its sink | per element |
| `union U` | nominal sum | ordinary boxed representation, with existing specializations | active payload and ARC root when boxed |
| `fixed union U` | nominal sum | tag and inline active payload | initially trivial payloads; later active-variant ownership |
| `Option[T]`, `Result[T, E]` | generic standard-library unions | selected per concrete instantiation/ABI, not one universal layout | active payload only |

Keep fixed layout separate from trivial ownership. Current `struct` is both
inline and unmanaged; that coincidence must not become the permanent meaning
of `fixed`. Reject by-value cycles through fixed records/unions at type-header
validation. A reference-valued field can break a layout cycle, subject to
Blorp's existing no-cyclic-values rule.

## Current starting point

- The parser represents `record`/`struct`/`fixed record` as one declaration
  with `RecordDeclarationForm` variants, and `union`/`enum` as one with
  `is_enum`, in `blorp/src/compiler/stage_03_parse/parsed_ast.brp`. The newer
  discovery parser also distinguishes these declaration forms in
  `blorp/src/compiler_new/stage_01_discovery/parse/declaration_parser.brp`.
  `blorp/src/format/` has its own declaration representation. A syntax change
  must reach both parsers and the formatter while both front ends exist.
- `stage_06_typecheck/headers/type_header_graph.brp` already distinguishes
  `ValueStruct`, `FixedValueRecord`, and `HeapRecord`, alongside `FieldlessEnum`
  and `TaggedUnion`; it rejects parameters on both value-record forms and
  detects infinitely sized inline cycles.
  Extend that boundary rather than guessing from names in lowering.
- `stage_09_core/ir.brp` currently distinguishes `ValueRecordType`,
  `HeapRecordType`, `EnumType`, `UnionType` and `TupleType`; the C type and
  ownership policies in `stage_09_core/c_type_layout.brp`, lowering in
  `stage_08_core_lower/lower.brp`, and backend emission consume those facts.
  Do not collapse all five variants as a prerequisite to the first pilot.
- The runtime has tagged stack `Option` values, a tagged stack `Result` with
  overlapping variant storage, nullable managed `Option`, and boxed forms.
  A logical `Result` has a tag and two *alternative* payloads, not three
  simultaneously initialized ordinary record fields. Existing specialized
  layouts remain until a candidate proves a better replacement.
- Current `struct` values may be boxed at erased union/tuple/dictionary or
  closure-call boundaries. A prior `SourceSpan`-as-struct pilot cut discovery
  allocations but increased typed-frontend allocations because struct values
  were boxed in union payloads. Count dynamic placements before converting a
  hot declaration. See the Struct Payload Roadmap for that evidence.
- Local/match tuple flattening is already implemented. On a matched
  stage-2 self-compile it saved about 1.36 million total allocations (0.63%);
  the instruction change was too small to claim a latency improvement.
  A new product abstraction must preserve this path rather than turn tuples
  back into heap records. See
  `benchmarks/results/tuple_flatten_increment1_2026-10-02.md`.

## Record-first implementation sequence

Each numbered slice is independently reviewable. The record decision gate
below precedes any production fixed-union or enum-removal implementation.

### R0. Freeze the baseline and classify placements

On a clean main-derived branch, record the exact base SHA, bootstrap pin,
toolchain, optimization level and frozen input. Census the current `struct`
declarations, their dynamic constructions, and every destination: local,
record field, union payload, tuple, list, dictionary, closure, call/result,
foreign boundary. Separately census freshly nested `record` constructions
whose child never has an independent use. Static grep is only a candidate
finder; generated C or an isolated allocation counter must confirm the
dynamic number. Retain at least three small fixtures: trivial fixed value,
managed-field fixed value, and fresh nested heap records with an escaping
control. Do not assert a self-compile payoff from source counts.

Suggested source census and fast probe loop:

```bash
rg -n '^\s*(struct|enum|record|union) ' blorp/src standard_library/src pkg
scripts/compiler-build-status
bin/blorp compile --stop-after=lower --no-format /tmp/layout-probe.brp
bin/blorp compile --dump-core-after=perceus --no-format -o /tmp/layout-probe.c /tmp/layout-probe.brp
```

Confirm the `compile` flags against `bin/blorp compile --help` on the branch.
Use a disposable input/output path; do not leave generated C beside a source
fixture. Save the measured baseline, raw artifacts and commands under
`benchmarks/results/` when the pilot begins. The baseline must be a stage-2
compiler for any Core/backend change to affect the compiler's own execution.

**Exit:** reproducible baseline counts, exact placement examples, and a
predeclared go/no-go threshold for R2 and R3 based on the reachable dynamic
allocations and instruction-sample spread. No production change in this slice.

### R1. `fixed record` syntax and current value layout — implemented

Both parsers and the formatter accept contextual `fixed record Name { ... }`.
Finalized declarations and type headers preserve its explicit form; R1 maps
it to the existing unmanaged value-record Core/C layout. `struct` remains
accepted for the coordinated bootstrap/source migration. Type or dimension
parameters, empty declarations, managed fields, and by-value cycles have
specific diagnostics; managed fixed fields remain R2 work.

Evidence: dual-parser parity and formatter round-trip pass; trivial and nested
fixed/struct cases have matching generated-C value layouts and zero root
allocations/releases; direct and indirect layout cycles are rejected; the
compiler reaches a stage-2/3 C fixpoint. This is a correctness and syntax
slice, not a compiler performance claim.

### R2. Make fixed records with managed fields correct

Prerequisite complete: Core now preserves legacy-struct versus fixed-record
origin and records an explicit trivial inline-field ownership fact. This
metadata does not yet admit managed fixed fields or change ownership/codegen;
see the [R2 Core metadata checkpoint](../benchmarks/results/fixed_layout_r2_core_metadata_2026-10-03.md).

Policy-authority checkpoint complete: Core can distinguish a declaration-tagged
owned inline `String` field from existing managed values, but production
ownership inference and all C-emitter entries reject that Core until
field-wise copy/drop and erased-placement rules are implemented. The public
managed-field restriction remains in force; this is not runtime owned-field
support. See the [R2 inline policy checkpoint](../benchmarks/results/fixed_layout_r2_inline_policy_2026-10-03.md).

**R2 decision checkpoint (2026-10-03).** R1 syntax and Core declaration
metadata are landed. The accepted emitter callback-pairing and heap/typed-union
destructor `Result` preparations preserve existing generated C; none admits a
managed fixed field. A separate, unmerged Core policy experiment contains
declaration-aware selectors intended to assign inline-owned retain/release
policies to a synthetic direct local; its tests remain unverified because the
new variants exposed nine backend/cancellation exhaustiveness sites. The
backend also makes 21 cleanup-policy decisions from type alone, Perceus has
widespread `is_managed_type` checks, and recursive function-body emission has
91 call expressions across 61 owning helpers, most of which return `Option`.
Those boundaries prevent a bounded, fail-closed negative-only cut. A preflight
cannot make the remaining `String`/`Option` matches return a typed error, and an
empty, ARC, or no-release arm would hide an ownership bug.

Keep the public managed-field gate closed; do not merge the experimental policy
variants or add placeholder emitter arms. The next architecture choice is a
broader `Result`-bearing function emitter, or a prepared backend ownership
action/slot authority built from the exact final Core program and projected C
symbols. Prefer investigating the prepared authority first: it can resolve
declaration identity, address-based helper/thunk calls, and backend-created
temporary cleanup before a `String` renderer runs, without making a missing
dictionary entry look like an ordinary policy. It is a substantial backend
preparation change, not a small preflight or permission to open source
admission. Stop if it cannot cover every generated cleanup site and both
single- and split-unit emission paths.

Before admission, require source diagnostics for unsupported erased, foreign,
collection, nested-aggregate, global, capture, parameter, and result placements;
verify direct-local copy, move, branch/drop, and cancellation behavior through
Core and generated C. Then run native address/undefined sanitizers on a
*dynamically allocated* `String` owner (not an immortal literal), asserting
one allocation/one release/zero live after copy-and-drop, plus a two-owned-
field case with two/two/zero. Keep a comparable heap-record control, verify
ordinary-program generated-C identity and stage-2 compiler allocations and
retired instructions, and do not claim a feature or performance win from the
existing helper-only oracle or preparatory measurements.

Implement one vertical slice for a direct `String` or heap-record field in a
non-generic fixed record, then expand to nested fixed records and other
managed fields. A value has no ARC header of its own; its fields still have
ownership obligations. The semantic operations need explicit behavior:

```blorp
fixed record Header {name: String, code: Int}
record Envelope {header: Header}

first: Header = {name = "alpha", code = 1}
second: Header = first                      -- retain the String for a second owner
third: Header = {first | code = 2}         -- do not steal from `first`
wrapped: Envelope = {header = third}       -- parent owns the inline Header fields
```

The constructor takes ownership of its fields. A by-value copy creates
independent field ownership; a move transfers it; a drop releases it. A field
read borrows from the aggregate until an independent value is required. A
record update must evaluate replacements once in source order and must not
release an old field before its last borrow. The same rules apply across
branch joins, return, closure capture and cancellation cleanup. Encode
trivial inline value, inline value with owned fields, and managed reference
as distinct representation/ownership facts; the existing blanket
`ValueRecordType => no release` rule cannot survive this slice.
The destructor and COW-copy path of an ordinary heap record that embeds a
managed fixed field must recursively copy/release that field's contents;
releasing only ARC-pointer fields would leak `Envelope.header.name`.

Do not immediately rewrite `List`, `Dict`, closure or generic-call storage.
When their erased ABI requires a box, make that box and its destructor an
explicit Core/backend boundary, with a codegen fixture and dynamic allocation
count. Never treat a `memcpy` of managed fields as an owned copy. Check the
foreign ABI separately; reject unsupported by-value exposure before C
emission rather than guessing its calling convention.

**Exit:** tests cover copy, move, partial update, nested fixed field,
an ordinary heap record containing a managed fixed field (construct, copy,
update and drop), branch/match, escape, each explicit boxing boundary,
and leak/sanitizer
behavior. The targeted fixture removes the fixed record's root allocation
where a comparable heap record had one, without missing or duplicate
retains/releases. Stage-2 self-compile phase allocations, retired
instructions, peak RSS and C size are recorded; a static reduction of
`blorp_box_struct` sites alone is not sufficient evidence.

### R3. Pilot inlining an ordinary record inside its parent

This is a separate optimization, not a new source promise. A C `Parent`
type has **one field layout for every instance**: an individual constructor
cannot choose inline `Child` storage while another constructor keeps a
`Child*`. Start only with a closed, non-foreign parent type for which *every*
construction supplies a fresh child that is not independently used:

```blorp
record Child {items: List[Int], count: Int}
record Parent {child: Child, stamp: Int}

pure func make_parent() -> Parent:
    {child = {items = [], count = 0}, stamp = 1}
```

Publish an explicit per-type field-layout decision before ownership
insertion; the backend and every construction, projection, copy and
destructor consume that same decision. The first pilot rejects the candidate
if *any* constructor supplies a separately owned child or an erased/foreign
boundary requires the old field layout. It then flattens the child's body
into the parent's allocation at every construction site. A
`parent.child.count` read can borrow from the parent. Producing an
independently owned `Child` must either transfer from a consumed parent or
materialize/copy it; never return a pointer into a parent that may die. Test
`child = parent.child` followed by parent release, child update, shared
parent COW, nested managed fields, and a branch that conditionally escapes
the child. Also test two `Parent` constructors, one with a fresh child and
one with a separately owned child: this initial pilot must keep the ordinary
pointer field for **both**. If the all-fresh restriction excludes the useful
production sites, a later pilot may consider one uniform inline field with
explicit conversion at separately owned inputs; measure that cost before
expanding. Do not introduce a per-constructor representation or redesign the
whole record ABI for the first experiment.

**Exit:** the eligible nonescaping fixture uses exactly one aggregate
allocation instead of two; the escaping fixture materializes only when
needed; the mixed-construction fixture keeps one consistent layout and
falls back safely; emitted C and ownership events explain all three. A
paired stage-2 self-compile reports
dynamic allocations, retired instructions and per-phase rows. If the
production result does not clear R0's threshold, park broader record
inlining even if the microfixture succeeds.

#### R3 decision checkpoint (2026-10-03)

Park the strict R3 implementation pilot on the [retained R0 diagnostic
census](../benchmarks/results/fixed_layout_r0_2026-10-03.md#bounded-callsite-census-checkpoint).
Its predeclared admission bar is at least **1,069,159 reachable removable
child roots** (approximately 0.5% of 213,831,836 baseline allocations), with net savings
of at least 80% of that reach. The one instrumented fresh nested site,
[`PerceusGlobal.value: CoreParam`](../blorp/src/compiler/stage_09_core/perceus/env.brp),
ran **3,178** times. Even all **295,205** measured `CoreParam_make` calls
would reach only 0.138% of baseline if each removed one root; that is a broad
upper bound for this child type, **not** an eligible-parent count or an
all-parent census. The measured transport-box calls do not identify removable
R3 child roots.

The selected child is also used independently: `global.value` is copied into
`BorrowedOwnerEntry.value` and returned as `Some(global.value)` on guarded
paths in [`borrowed.brp`](../blorp/src/compiler/stage_09_core/perceus/borrowed.brp).
Thus this parent's no-independent-use condition is not established. Reopen a
strict pilot only after a newly identified parent passes constructor and
escape closure and its frozen stage-2 diagnostic count demonstrates at least
1,069,159 reachable removable child roots. This checkpoint neither completes
R0's all-parent census nor closes R2's managed-fixed-record gate.

### Record decision gate

Review R1-R3 together before opening union work. Keep the syntax
simplification if it is correct and understandable, but do not generalize
record inlining on an unmeasured promise. Specifically decide from evidence:

1. Which typed positions preserve a fixed value without boxing, and which
   still require an explicit transport box?
2. Does field-wise ownership lower allocations without shifting more cost
   into retains, copies, retired instructions or cleanup frames?
3. Does the R3 opportunity occur often enough in the compiler to justify the
   parent-backed borrow/materialization complexity?
4. Which small layout/ownership helpers were useful in both R2 and R3? Share
   those; do not introduce a universal aggregate IR merely for symmetry.

Record the accept/park/revise decision and raw metrics. A negative pilot is
a valid result. Do not proceed to managed fixed unions on the assumption
that the record experiment succeeded.

## Conditional work after the record gate

### U1. Fieldless and trivial-payload `fixed union`

Add non-generic `fixed union` syntax in both parsers and the formatter. Type
headers reject all declaration parameters and inline-layout cycles before
inference. Preserve nominal variant identity, exhaustiveness and constructor
imports. First admit nullary variants and current struct-compatible scalar
or trivial fixed-record payloads. A union whose **every variant is nullary**
keeps the existing scalar enum layout (normally a C `long`, except the
explicit `Bool` ABI's `int`, with current record-field packing retained);
it needs no payload struct. A union with any
payload uses a tag plus overlapping active-variant storage. For that case,
use the C compiler's `struct`/`union` layout for size and alignment, not a
hand-computed largest-payload-plus-one-byte formula. Tag shrinking is a
separate measured change. Carry the scalar-versus-payload layout as an
explicit type fact through Core and C type selection, rather than inferring
it from a name or using one representation at construction and another at
parameter/return sites. No generic fixed declaration is needed for this.

**Exit:** no allocation for typed local construction/match of a trivial
fixed union; correct scalar fieldless and tagged-payload size/alignment;
deterministic constructor order, exhaustive matches, no
uninitialized-payload reads, and exact diagnostics for parameterized or
infinitely sized declarations. Exercise both layouts across local,
parameter/result, record field and foreign/runtime boundaries.

### U2. Active-variant ownership for managed fixed unions

After R2's inline owned-field rules are sound, allow concrete managed
payloads such as `Data(String)`. Only the active variant is initialized,
copied, moved or destroyed. Reuse the field-copy/drop primitives that proved
useful for fixed records, but keep sum-specific tag and match logic. Include
nested match borrows and cancellation cleanup in the ownership tests.
Generic, erased and foreign boundaries still require explicit representation
choices. Do not repeat the parked typed-source-union-payload change from the
Struct Payload Roadmap as a standalone optimization: it reduced emitted C
but regressed stage-2 allocations without material instruction gain.

**Exit:** allocation and ownership oracle for `Data(String)` and a
two-managed-payload union, ASan/leak and codegen audit, and paired stage-2
self-compile with no unexplained phase regression.

### U3. Retire `enum` only after equivalent fixed unions work

Convert a fieldless enum declaration to a fieldless fixed union without
changing constructor tags, equality/hash/to-string behavior, import
visibility, matching or foreign/runtime ABI. `Bool` and other special
runtime-facing names require explicit ABI facts, not spelling heuristics.
Before deleting `EnumType`, make `UnionType`'s representation fact supply
the same scalar C type and context-specific field storage at every use,
including generated signatures and runtime helpers; a tagged C struct is
not an ABI-equivalent substitute.
Migrate compiler, standard library, packages, tests, examples and docs;
then delete `enum` parsing, diagnostics and the distinct Core enum path.
Count and inspect declaration users before a mechanical rewrite. Avoid a
permanent `enum` compatibility shim in this pre-0.1 language.

**Exit:** old `enum` syntax receives a useful migration diagnostic; all
current sources use fixed unions; aggregate compiler/runtime, formatter,
parity, leak and release gates pass; generated C changes are inspected and
the stage-2/3 fixpoint holds.

### P1. Tuples as structural products, without undoing multi-values

Share ordinal field identity and product-type reasoning with records where
that reduces duplicate logic. `(A, B)` stays structural; `record Pair` stays
nominal, with no implicit conversion. `pair[0]` resolves to a constant
ordinal, not a string-key lookup. Preserve the tuple plan's flattening of
locals and results, and its distinct stored-tuple work. Do **not** turn a
local tuple into a heap `record` to achieve conceptual unification.

**Exit:** existing tuple allocation fixtures and stage-2 self-compile do
not regress; each shared helper removes a real duplicate consumer. P1 is
not a dependency of U1 or U2 and may be parked if it is only cosmetic.

### O1. Optional `Option`/`Result` machinery reuse

The standard-library unions remain generic. For a concrete instantiation, they may use a
tag and payload area assembled by the same proven aggregate-layout helpers.
`Option` may keep its nullable-pointer representation; `Result`'s Ok/Err
payloads are alternatives in overlapping storage, not two ordinary live
record fields. Only share layout, construction, projection or ownership
helpers when doing so simplifies code or improves measured behavior. Do
not force one physical shape on every `T`/`E` or lose a specialized fast
path to make the model look uniform.

**Exit:** no ABI or allocation regression for current stack, nullable and
boxed cases; active-payload ownership tests, especially managed closures;
explicit evidence before replacing any existing specialization.

## Bootstrap and source migration

The pinned bootstrap builds the compiler source. It cannot compile source
spelled with `fixed record` or `fixed union` until it recognizes that syntax.
Therefore:

1. Land new syntax and equivalent lowering while compiler source still uses
   `struct`/`enum`. Keep both parsers and formatter in sync, update the Guide
   and Grammar with the code, and run `compiler-new-parity`.
2. Build and validate a stage-2 compiler, establish a stage-2/3 generated-C
   fixpoint for codegen changes, and prepare a multi-platform bootstrap pin
   through the release process in [RELEASES](RELEASES.md). Do not assume a
   local `make` proves the next bootstrap asset exists.
3. Only after the pin can compile the new syntax, migrate compiler source
   and the rest of the tree in bounded, behavior-preserving cuts. Keep old
   spelling accepted temporarily for the transition.
4. Once no current source needs it, remove old `struct`/`enum` support and
   run the full release/preview gate. Record the pinned compiler provenance.

No roadmap step authorizes an opportunistic bootstrap rotation, push or
release; those are separate coordinated operations.

## Verification protocol for every implementation slice

Fast loop: one focused source fixture, an exact expected diagnostic if it
should fail, Core before/after when ownership changes, and inspected C.
`scripts/compiler-check --changed --plan` is only selection guidance;
compiler-new source requires its own gate. Run the owning focused suites,
`scripts/compiler-check --changed`, `scripts/test compiler-new
compiler-new-parity compiler-blorp runtime leak`, codegen audit,
`compiler-core-sanitize` and `compiler-blorp-sanitize` as relevant, and
`make hygiene-check` before a production cut lands. For C-changing cuts,
run `scripts/compiler-fixpoint`. Check `scripts/compiler-build-status` before
direct `bin/blorp` tests. Keep compiled test runs serial on macOS.

Measure a paired baseline/candidate using identical frozen source and
toolchain, both `-O2`, and stage-2 compilers. The harness records exact
allocations and phase rows, retired instructions, peak RSS and generated-C
identity *within* each revision. A layout change is expected to alter C
*between* revisions, so compare behavior and inspect the new C rather than
requiring cross-revision byte identity. Retain raw output and C hashes.

```bash
export BLORP_CLI_C_OPTIMIZATION=-O2
make
scripts/compiler-build-status
benchmarks/self_compile_measure --stage2 --input-rev <frozen-sha> \
  --label fixed-layout-baseline --samples 5 --output /tmp/fixed-layout-baseline.json
benchmarks/self_compile_measure --stage2 --input-rev <frozen-sha> \
  --label fixed-layout-candidate --samples 5 \
  --baseline /tmp/fixed-layout-baseline.json --output /tmp/fixed-layout-candidate.json
scripts/compiler-fixpoint
```

Run the baseline in a separate clean baseline checkout; do not invoke both
commands against one edited tree. Serialize measurements and compiled gates.
The benchmark report must state input/compiler revisions, bootstrap pin,
compiler build freshness, toolchain, optimization, dynamic allocation
counts, instruction sample spread, per-phase allocations, C hashes,
identity/correctness oracle, and any tradeoff. Wall-clock alone is not
acceptance evidence. Never treat a static box-site count, a microbenchmark
or a passing build as proof of a self-compile win.

## Stop rules

- Stop a syntax migration if the new and legacy parsers or formatter disagree;
  do not shift a syntax distinction into typechecking for convenience.
- Stop a managed-value slice at the first unexplained retain/release,
  leak, use-after-free or cancellation difference. Isolate a minimal fixture
  before expanding the supported field set.
- Stop a layout pilot that merely moves allocations into boxing, copying or
  cleanup work elsewhere. Compare *whole-pipeline* stage-2 numbers and the
  targeted phase, not only its constructor count.
- Stop at the record decision gate before scheduling union and tuple rewrites.
  A shared representation helper is earned by at least two real consumers,
  not by an aesthetic desire for one data model.
