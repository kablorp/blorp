# Record Simplification Roadmap

Status: S4 semantic convergence and old value-record pipeline deletion are
complete. The original checkpoint is `83a9c1082811`; the prepared squash based on
main `4535746a6a21` passes 25,438 checks across 13 gates, the three-stage C
fixpoint, the 228-fixture stage-2 codegen audit, full quality, and stage-2
runtime/layout controls. This is correctness acceptance, not release or
performance acceptance.
`record`, `struct`, and `fixed record` follow ordinary managed-record semantics;
native snapshot boundaries use explicit adapters. See the
[repair checkpoint](../benchmarks/results/record_s4_repair_checkpoint_2026-10-03.md)
and [remaining-gate results](../benchmarks/results/record_s4_remaining_gates_2026-10-03.md)
for provenance, commands, ownership oracles, and bounded validation repairs.

Regain inline placement later as an optimization of records, not as a
prerequisite for a coherent source model. The verification checkout uses main's
syntax-capable bootstrap and migrates 317 declarations to `fixed record`.
The legacy `struct` keyword remains accepted and has an explicit parser fixture;
keyword retirement is still a separate cut after S4 validation and integration.

Read [WORKER_CHECKLIST](WORKER_CHECKLIST.md) before compiler work. The
[Language Guide](GUIDE.md), [Grammar](GRAMMAR.md), and
[Memory Model](MEMORY_MODEL.md) describe what the compiler accepts today.
Retained experiments and rejected layout cuts are in `benchmarks/results/`
and Git history; this file holds the open sequence.

## Decision and evidence

`record` already supplies the desired value semantics: an immutable logical
value, ARC/COW implementation, and ownership-aware reuse when sound. A
separate `struct`/fixed-record semantic category makes type headers, Core,
Perceus, C emission, boxing, and tests carry a second product representation.
The special category is justified only where an actual ABI or measured inline
benefit pays for it. It should not be retained merely because source text
spells `struct` or `fixed record`.

The [accepted-semantic-catalog pilot](../benchmarks/results/record_unification_catalog_counts_pilot_2026-10-03.md)
converted one non-ABI, scalar-only compiler `struct` to `record`. Focused,
compiler, leak, sanitizer, hygiene, and stage-2/3 fixpoint gates passed.
For the same frozen self-compile input, both compilers emitted identical C.
The first cross-worktree comparison showed +6,302 allocations, but an A/A
control with the **same baseline binary from the candidate cwd** reproduced
+6,300 of them. The residual same-cwd candidate delta was **two
typed-frontend allocations**; retired-instruction ranges overlapped. This
proves the first
conversion is viable, not that all 153 remaining production `struct`
declarations are safe or cheap to convert.
The [next scalar-only metric pair](../benchmarks/results/record_unification_metric_pair_2026-10-03.md)
changed retaining-fixture Core/C but not the production stage-2 binary;
its self-compile is **not exercised** evidence, not a zero-cost result.
The [embedded type-header count cut](../benchmarks/results/record_unification_header_counts_2026-10-03.md)
does execute in the self-compile: its one converted nested product adds
exactly one typed-frontend allocation, with identical frozen-input C and
overlapping retired-instruction ranges.

The earlier R1 pilot implemented `fixed record` syntax with unmanaged layout.
That pilot rejected managed fixed fields; its attempted owned-inline policy was
not admitted. S4 supersedes that restriction with ordinary managed-record
semantics. The old R2 ownership-authority and R3 all-fresh nested-child
pilots are no longer prerequisites to simplification. A bounded nested R3
site fell far below the predeclared admission bar; no production candidate
was selected. See [R0 evidence](../benchmarks/results/fixed_layout_r0_2026-10-03.md).
Do not restart an inline-ownership backend project to make a source spelling
useful before the product model is simplified.

Inline construction alone does not prove a win at erased storage boundaries:
spans boxed into union payloads previously moved costs into typechecking.
The [managed-union pilot](../benchmarks/results/STRUCT_PAYLOAD_S2A_OUTCOME.md)
and [accessor follow-up](../benchmarks/results/struct_payload_managed_union_s2b_probe_2026-09-23.md)
missed their instruction admission bars; typed dictionary storage had no
measured dynamic reach. Reopen those representation cuts only with fresh
dynamic evidence, not a static box count or a smaller emitted-C file.

## Target model and non-goals

```blorp
record Point {x: Int, y: Int}
record Header {name: String, code: Int}
record Box[T] {value: T}
```

- A nominal product has one source-level value model and one general
  typecheck/Core/backend representation. Generic records remain supported.
  Record fields may own managed children; copy, update, drop, and cancellation
  continue to obey the existing ARC/COW contracts.
- The semantic cut keeps `struct` and `fixed record` parsing as managed
  records, with **no promise of stack placement or no allocation**. The next
  source migration replaces `struct` with `fixed record`, after a verified
  bootstrap that accepts that spelling is available. Ordinary `record`
  remains supported. Removing the `struct` source form is a separate syntax
  cut, not a new layout contract or a prerequisite for S4 acceptance.
- A tuple remains a structural product with ordinal access. Existing
  local/match tuple scalar replacement and multi-value results must not turn
  into heap records for conceptual uniformity. Share helpers only where two
  real consumers benefit; [the tuple plan](VALUE_TUPLES_AND_STATE_HANDOFF.md)
  owns stored-tuple work.
- `union`, `enum`, `Option`, and `Result` retain their current sum
  representations for this record phase. A fieldless enum's scalar C ABI and
  `Option`/`Result` specializations are not ordinary record fields. Decide
  fixed-union syntax and enum retirement only after the record gate below.
- Ordinary-record nesting is an independent optimization. One parent
  allocation for a fresh child requires a per-*type* layout decision, an
  explicit borrow/materialization rule for extracted children, and an
  ownership proof. Do not silently inline one constructor while another
  uses a pointer field.

## Sequence

Each cut is independently reviewable. Keep old and new semantics out of the
same commit unless a vertical slice needs both to compile.

### S1. Classify remaining products and freeze the cost baseline

At the committed one-type pilot there were 151 production `struct` declarations
across `blorp/src/`, `standard_library/src/`, and `pkg/`, and no production
`fixed record` declarations (tests do contain fixed records). The two-metric
and embedded-header-count cuts brought this count to 148; eliminating the
one-field union locator brings it to 147 on this branch.
Re-run the
census on the integration base. Classify each declaration by use: internal
typed value, nested field, `Option`/union/tuple/collection, closure, generic
or erased call, foreign by-value parameter/result, native runtime mirror, or
special compiler intrinsic. Search call sites and inspect final Core/C;
declaration counts alone do not estimate dynamic cost. Record the owning
tests and the exact ABI for every exception.

```bash
rg -n '^\s*(private\s+)?(struct|fixed record)\s+[A-Za-z_][A-Za-z_0-9]*\s*\{' blorp/src standard_library/src pkg -g '*.brp'
rg -n 'ValueRecordType|ValueStruct|FixedValueRecord|blorp_box_struct' blorp/src
scripts/compiler-build-status
```

**Exit:** a retained, reviewable classification with no unknown ABI cases and
a matched same-cwd stage-2 baseline. If the ABI census is incomplete, keep
working on safe internal types; do not switch all source forms globally.

The 2026-10-03 source census is preliminary, not this exit gate: 147
declarations remain (127 under `blorp/src/`, 20 under
`standard_library/src/`, none under `pkg/`). Of the 127, 52 belong to the
new discovery tables; 42 are row shapes in
`compiler_new/stage_01_discovery/tables/rows.brp`. Most are held in inline
`List` tables; allocation budgets protect representative discovery paths
against per-row allocations
(`blorp/test/compiler_new/stage_01_discovery/tables/test_allocation_budget.brp`).
Audit each shape and sink before migration. The family needs a record-inline
optimization contract or a different table design; it is not a mechanical
rename. The old lexer token,
compact source-location rows, and reusable Perceus frames also have
deliberate inline storage.

In the standard library, `MemStats` and `SchedulerStats` mirror native C
return-by-value structs; `Range` has a dedicated Core/backend ABI path.
These three are held for S3/S4. The other 17 include hot geometry/DSP
values and JSON/parser state, so a source-only safety check is insufficient.
The [union-index cut](../benchmarks/results/record_unification_union_index_2026-10-03.md)
deleted `AcceptedUnionLocator` entirely: it only wrapped one `Int`, and
direct index storage showed 98,712 fewer typed-frontend allocations on the frozen
self-compile without changing emitted C. `GlobalHeaderCompletionMetrics`
(`stage_06_typecheck/decl.brp`) remains a bounded candidate, but its cost
is unmeasured. This census does not establish that
downstream foreign declarations cannot use other value records by value.

The S2 caller audit on `d29b264e1` found no custom by-value foreign use of
the remaining structs in production or standalone tools. Native snapshots
and first-class `Range` are the production exceptions; direct aggregate
foreign signatures also exist in fixtures. The other products use ordinary
construction, selection, update, collections, or existing erased calls.
They can converge through one coordinated semantic cut rather than 144
independent keyword migrations. This finding does not establish zero cost:
inline rows and frames will become managed records and must be measured.

### S2. Migrate internal declarations in small families

First delete a transparent wrapper when its meaning is already carried by
an existing id or index; do not allocate a record solely to preserve an
unnecessary shell. Convert remaining types only when they have no external
C layout obligation or value-only consumer. The embedded header-count cut
is complete; keep hot
per-expression/offset structs and Core work-profile types for separate cuts.
A source migration uses
ordinary `record` now; it does **not** change the language-wide meaning of
`struct`.

For every family, retain a failing-first representation test where useful,
then its count/diagnostic oracle. Inspect final Core and C from a fixture
that retains the type to confirm the expected inline-value to ARC-record
change. Check separately whether the stage-2 production compiler retains or
executes it; if not, label the self-compile result **not exercised**, never
zero-cost proof. On identical frozen input, the baseline and candidate
compilers should still emit byte-identical output C; a mismatch needs
explanation. Measure allocations, retired-instruction spread, per-phase
rows, memory, and C size with matched
stage-2 compilers. Run an exact-binary A/A control when cwd, source path, or
build metadata differ. A measured temporary cost is acceptable, but a
large or unexplained cost stops expansion until its cause is known.

**Exit per cut:** unchanged logical results and diagnostics, no ownership or
sanitizer failure, inspected representation, and a retained measurement.
Remove each converted declaration from the outstanding census. Do not mix
hot and cold families in one commit.

For the coordinated S4 cut, S2 owns caller and test readiness rather than
requiring every declaration's spelling to change first. The user has admitted
a measured temporary allocation regression in exchange for a single product
model. Keep table APIs and direct-loop optimizations; do not make a table
redesign a prerequisite. Replace inline-layout allocation expectations with
measured, narrow record-construction budgets that still catch per-use table
copies. Never drop the budgets or raise one shared ceiling until everything
passes. Old spelling counts remain a migration inventory, not a measure of
remaining semantic categories.

### S3. Isolate foreign and native by-value ABI

`MemStats` and `SchedulerStats` mirror native C structs. A heap-record pointer
is **not** ABI-equivalent to a C struct, so these two runtime boundaries need
explicit adapters before the global semantic cut. A native snapshot is copied
into an ordinary managed record; the native layout does not become a general
Blorp product category.

The production audit found no other foreign aggregate-by-value callers. One
codegen fixture passes a four-field value product to C; migrate it through a
source-level wrapper passing four scalar fields. Preserve existing managed
record-pointer foreign calls and their validation. Generalized aggregate
annotations, copy-in/copy-out metadata, and a new ABI type system are **parked**:
they are not prerequisites for changing a declaration spelling or deleting the
value-record pipeline. Synthetic Core tests of the retired layout are updated
to test the surviving managed pointer boundary, not used to justify a new
language feature.

**Exit:** native snapshot retention, field values and teardown pass runtime,
leak and sanitizer checks; the independent scalar foreign fixture and existing
record-pointer fixtures pass. Generated native signatures match their C
declarations. No remaining caller depends on the old source spelling selecting
a C aggregate ABI.

Native snapshot adapters are keyed by the existing explicit `DeclaredAbi`
identity. Their schema owns the native field order and types; typechecking
validates the corresponding language record before emission. An adapter
takes exactly one native snapshot, then constructs an ordinary managed
record. It must have owned-result and allocating effects. Neither source
spelling nor a rendered type name selects the native ABI.

Managed `get_mem_stats()` snapshots honestly allocate. Do not suppress their
allocation/release counters or subtract a hardcoded observer allowance.
Exact single-fiber interval tests use a nonallocating scalar
`read_memory_counter(MemoryCounter)` interface, leaving the measured owner's
dataflow unchanged and constructing reports only after the endpoints.
Counter-active flags remain mandatory: disabled instrumentation is not zero
activity. Separate scalar reads do not promise a coherent concurrent
snapshot; `get_mem_stats()` still does. Retire the old snapshot-based
`assert_no_heap_activity` helper and migrate its two actual callers.

Direct C aggregate support is a separate future task. Ordinary managed record
pointers and C by-value aggregates cannot be distinguished from a record
signature alone; use explicit scalar/`Ptr` wrappers at that boundary for this
migration. Do not preserve a hidden distinction based on `struct` spelling,
silently change a C signature, or infer an ABI from field shapes.

### S4. Converge semantic headers, Core, and emission

Only after S2/S3 leave no unadapted value-record caller, make parsed
`struct`/`fixed record` declarations feed the ordinary record header and
owned-field validation. Keep exact source-form information only where a
migration diagnostic needs it. Then remove `ValueStruct`/
`FixedValueRecord` header categories, value-record-only Core declaration,
type, boxing and release branches, and dead backend helpers one family at a
time. A branch is dead only after a production/test/standalone-tool census;
do not turn impossible states into silent fallbacks. This is a deletion
sequence, not an invitation to build a universal aggregate IR.

At the semantic cut, update both parsers, formatter, Guide, Grammar, Memory
Model, Ownership Model, and the language-boundary note in `AGENTS.md` in the
same change. Replace tests asserting inline `fixed record` layout with
tests asserting record behavior; keep distinct ABI tests for S3. The pinned
bootstrap must still parse any new source spelling until a separately
validated bootstrap rotation; no phase here authorizes a release or push.

**Exit:** source forms have one semantic product path; old Core/backend
variants have no producers or consumers; compiler-new parity, formatter,
runtime, leak, sanitizer, codegen audit, and stage-2/3 fixpoint pass.
Inspect generated C differences at the representation cut instead of
demanding byte identity across intentionally different layouts.

Execution is split into three isolated workstreams: S2 caller/fixture and
allocation-oracle migration; S3 native/foreign boundary adapters; S4
parser/header/lowering convergence followed by exhaustive consumer deletion.
The coordinator settles shared types and source contracts before integration,
reviews each slice, and runs compiled gates serially. Parallel source work
does not authorize overlapping benchmark or test binaries.

First-class `range.Range` is an ordinary managed nominal record in all
positions. Carry its authoritative start/end field identities through typed
range expressions and CTFE, then lower construction through the normal record
path. Preserve optimized `ForRangeExpr` loops over scalar bounds. The unrelated
bounded-integer `SemanticRangeType`/Core `RangeType` remain scalar types; they
are not the first-class range product. A local type named `Range` cannot
redirect the standard syntax provider.

Use the same frozen stage-1 generator and same-cwd stage-2 baseline when
measuring this work. The retained starting measurement is
`/tmp/blorp-record-through-s4.5K6t2p/baseline.json`, compiling frozen input
`d29b264e1a74d73a1c0c02f437437947660c3ff3` at `-O2` with five instruction
samples. Unlike source-only pilots, the global representation cut intentionally
changes that input's emitted C: compare logical behavior and diagnostics,
inspect the changed layouts, and require stage-2/3 fixpoint identity. Report
allocation and instruction regressions with their mechanism; do not claim
byte-identical C or speed from declaration counts.

### S5. Decide which layout optimizations are worth reintroducing

After simplification is stable, profile actual record constructions and
escapes. The compiler may scalar-replace a nonescaping record or fold a
fresh nested record into one parent allocation while preserving ordinary
record semantics. For parent inlining, all constructors of one type must
share one field layout, and extracting an independent child may require
materialization. Compare full-pipeline allocations, retired instructions,
retains/releases, and C size with the simpler baseline. Reopen an explicit
`fixed` promise only if it has a sound contract across typed, erased,
collection, closure, generic, and foreign positions and a substantial
measured benefit. Otherwise keep optimization implicit.

**Exit:** a separate accept/park decision per optimization. No performance
claim from static source counts, shorter C, or a microfixture alone.

## Verification and record gate

Use the smallest relevant fixture and `scripts/compiler-check --changed
--plan` for selection, then run the owning suite and
`scripts/compiler-check --changed`. Codegen/ownership cuts additionally
need generated-C inspection, codegen audit, runtime/leak and relevant
sanitizers; C-changing compiler cuts need `scripts/compiler-fixpoint`.
Run compiled gates serially on macOS. Record full logs and raw benchmark
JSON under `benchmarks/results/` or link a retained artifact from there.

### Retire `struct` after the bootstrap rotation

The next spelling cut replaces Blorp `struct` declarations with `fixed record`;
ordinary `record` remains supported. It does not introduce a layout promise or
change the managed-record semantics established by S4.

The original frozen integration branch pins `dev-0322140767b0`, which does not
parse `fixed record`: its direct empty-fixture check fails before typechecking.
Main `02c0786a6` now pins `dev-8228a8fa12e3`. A direct bootstrap check of
`fixed_record_matches_struct_layout.brp` succeeds, and its Darwin digest
matches the manifest. This establishes the syntax prerequisite, not the
candidate's managed-record semantics or S4 acceptance.

The verification checkout is based on that main revision and already migrates
317 declarations using the newer pin. Finish the broad S4 landing gates before
retiring the keyword; do not mistake declaration replacement for keyword removal.
Publishing another S4 compiler release is not required just to parse the new
spelling. Pin integration and any release remain separately authorized actions.

Replace declaration tokens and embedded Blorp-source fixtures, then remove
struct-specific lexer, parser, source-form, discovery, formatter, and JSON
branches. Update paired formatter fixtures and diagnostic-span expectations
using the formatter/parser as the oracle. Do not perform a repository-wide
word substitution: native C `struct` syntax, generated-C assertions, and scalar
Option/Result C storage remain valid. After keyword retirement, `struct` is an
ordinary identifier, not a compatibility declaration form.

Use focused parser/discovery/formatter suites first, then compiler-new parity
and the S4 integration gates. This is a syntax-and-source migration, not another
representation or performance project.

Do not start
`fixed union`, enum retirement, or shared tuple/union machinery merely
because the record path simplified. A conditional union plan needs its own
ABI and active-payload ownership gate; the old fixed-union proposal remains
in Git history until that decision is made.
