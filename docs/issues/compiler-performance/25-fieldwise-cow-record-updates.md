# Replace Only Changed Fields During COW Record Reuse

**Status:** Implemented 2026-09-01; full-frontend allocation checkpoints remain a profiling rough edge

## Objective

Make a consumed heap-record update preserve unchanged fields in place when the
record is uniquely owned. The generated fast path must release and replace only
the fields named by the update. It must not retain every inherited managed
field, invoke the complete record destructor, and assign those inherited fields
back to the same allocation.

The shared-owner path must continue to implement ordinary value semantics by
constructing one independent record. Source evaluation order, ownership,
diagnostics, and observable results must remain unchanged.

This is primarily an ARC-traffic and compiler-time optimization. It is **not**
expected to materially reduce allocation counts beyond the record allocations
already removed by the existing consumed-record reuse work.

## Outcome In One Example

Given a heap record such as the lexer state:

```blorp
private record LexerState {
	source: SourceFile,
	cursor: Cursor,
	diagnostics: List[ParseDiagnostic],
	pending_trivia: List[Trivia],
	indent_stack: List[Int],
	lambda_body_levels: List[LambdaBodyLevel],
	group_depth: Int,
	pending_newline: Bool,
	at_line_start: Bool,
	line_has_token: Bool,
	last_token_kind: Option[TokenKind]
}

private pure func advance(state: LexerState) -> LexerState:
	{ state | cursor = source_advance(state.source, state.cursor) }
```

the unique-owner path should be equivalent to:

```c
LexerState* result = state;
result->cursor = next_cursor;
```

It must not be equivalent to:

```c
blorp_retain(state->source);
blorp_retain(state->diagnostics);
blorp_retain(state->pending_trivia);
blorp_retain(state->indent_stack);
blorp_retain(state->lambda_body_levels);
blorp_retain(state->last_token_kind);
LexerState_destroy(state);
state->source = source;
state->cursor = next_cursor;
state->diagnostics = diagnostics;
state->pending_trivia = pending_trivia;
state->indent_stack = indent_stack;
state->lambda_body_levels = lambda_body_levels;
state->last_token_kind = last_token_kind;
```

The precise generated C will include normal temporary and cancellation-cleanup
handling. The important structural property is that unchanged fields are not
retained, released, or assigned on the unique path.

## Why This Issue Exists

The current ownership pipeline already recognizes consumed heap-record updates.
The relevant sequence in `stage_09_core/pipeline.brp` is:

```text
consume specialization
  -> record-update normalization
  -> Perceus ownership insertion
  -> post-Perceus reuse
  -> backend preparation and C emission
```

`record_update.brp` turns qualifying consumed updates into
`RecordReuseExpr`. The node preserves the required ordering: all new field
values are evaluated before the source owner is consumed. The backend emits a
per-record helper with this shape:

```c
static inline Record* __blorp_reuse_record_Record(
    Record* old,
    /* every field value */
) {
    if (old && blorp_is_unique(old)) {
        Record_destroy(old);
        /* assign every field */
        return old;
    }
    Record* fresh = Record_make(/* every field value */);
    if (old) blorp_release(old);
    return fresh;
}
```

This correctly avoids a replacement record allocation when `old` is unique.
It remains wasteful for sparse updates because `RecordReuseExpr` has only
whole-record replacement semantics:

1. ownership insertion retains inherited managed fields so they can be passed
   as owned constructor arguments;
2. the unique branch invokes the complete destructor, releasing those fields;
3. the helper assigns all fields back, including unchanged fields; and
4. a one-field `LexerState` update therefore performs ownership work for all of
   its managed fields.

For the current `LexerState`, a cursor-only update crosses six managed fields:
`source`, `diagnostics`, `pending_trivia`, `indent_stack`,
`lambda_body_levels`, and `last_token_kind`. The existing unique path can
therefore perform roughly six retains and six matching releases for an update
that changes only an unmanaged `Cursor`.

Character advancement executes this pattern millions of times while compiling
the compiler. Atomic ARC operations are a plausible remaining lexer cost even
though the record allocation itself has already been removed.

## Existing Evidence And Expected Effect

Historical Stage 01-04 measurements for compiler self-parsing used:

```bash
BLORP_COMPILER_MEMORY_PROFILE=1 \
  <compiler> compile --ast --no-format blorp/src/main.brp
```

`--ast` constructs and validates the Stage 04 frontend graph, then exits before
typechecking. The recent consumed-record reuse correction changed this workload
approximately as follows:

| Metric | Before consumed-record reuse | After consumed-record reuse | Change |
| --- | ---: | ---: | ---: |
| Stage 01-04 elapsed | 16.03 s | 14.96 s | -6.7% |
| Allocations | 45,734,164 | 38,617,174 | -7,116,990 / -15.6% |

Those values are historical evidence, not the baseline for this issue. Refresh
them on the starting revision, using controlled workers and the same workload.

Fieldwise updates should leave the approximately 38.6 million allocation count
nearly unchanged. The unique path already reuses the record allocation, and
retains, releases, destructor calls, and field assignments do not themselves
allocate. The expected improvement is fewer ARC operations and less elapsed
time:

- focused wide-state loop: a clear reduction in generated ownership operations
  and a measurable timing improvement;
- lexing: an exploratory expectation of 10-25%, not an acceptance promise;
- Stage 01-04 combined: an exploratory expectation of 5-15%; and
- Stage 01-04 allocations: neutral, apart from incidental compiler-source or
  instrumentation differences.

Do not claim an allocation improvement unless new measurements actually show
one and identify its cause.

## Semantic Requirements

### Value Semantics

Blorp record updates retain value semantics:

```blorp
original: State = make_state()
alias: State = original
updated: State = { original | cursor = next_cursor }
```

After the update, `alias` must still observe the old cursor. The compiler may
modify the original allocation only when the runtime reference count proves it
is unique. Otherwise it must create one fresh record.

### Evaluation Order

All replacement expressions must be evaluated exactly once and in existing
Core field order before the source record is consumed or mutated. This is
required for:

- impure replacement expressions;
- replacements that read the source record;
- swaps and cross-field aliases;
- nested record-update chains;
- branch-local updates; and
- managed replacement values that require an owning temporary.

No generated field write may occur while a later replacement expression can
still read the pre-update source.

### Ownership Transfer

The update operation consumes one owner of the source and one owner of every
replacement value.

On the unique path:

1. keep the source allocation;
2. release each overwritten field using its declared release policy;
3. move the corresponding replacement value into that field; and
4. leave every inherited field untouched.

On the shared path:

1. retain only the inherited values required by the new record;
2. move replacement values into the new record;
3. construct exactly one fresh record;
4. release the consumed source owner; and
5. leave all other owners of the source unchanged.

The implementation must handle `NoReleasePolicy`, `ArcReleasePolicy`,
`ArcReleaseOnlyPolicy`, and `StackResultReleasePolicy` correctly. Do not assume
that every managed field uses ordinary `blorp_release`.

### Complete And Sparse Shapes

`RecordUpdateExpr` currently contains every declared field exactly once in
declaration order. Inherited fields are represented by a projection of the same
field from the update base. Preserve that invariant for the pre-ownership node.

The fieldwise ownership node must explicitly distinguish inherited fields from
replacement fields. Do not recover this distinction in the backend from names,
temporary spelling, or C text.

An update with no effective replacements should become the consumed source. An
update replacing every field should continue to use whole-record
`RecordReuseExpr`, whose shared path is already optimal. The new fieldwise form
is for updates with at least one inherited field and at least one replacement.

## Required IR Design

Introduce a distinct phase-specific Core operation. The preferred name is
`RecordCowUpdateExpr`; choose a comparably explicit name only if repository
naming constraints require it.

Do not silently change `RecordReuseExpr` to mean both whole-record reuse and
sparse record update. `RecordReuseExpr` is also produced by the post-Perceus
reuse pass when a dead heap-record allocation is repurposed for an unrelated
complete `RecordExpr`. Combining those semantics would make ownership and
backend validation ambiguous.

A suitable representation is:

```blorp
record CoreRecordCowField {
	field: CoreHeapRecordField,
	replacement: Option[CoreExpr]
}

union CoreExpr:
	-- existing variants...
	RecordCowUpdateExpr(
		CoreExpr,
		List[CoreRecordCowField],
		CoreType,
		CoreSourceLoc,
	)
```

Here:

- `replacement = None` means the field is inherited from the source allocation;
- `replacement = Some(value)` means `value` is evaluated, owned, and moved into
  the field;
- `CoreHeapRecordField` carries the declared name, type, and release policy;
- the list is complete and in heap-record declaration order; and
- the node is legal only for a matching `HeapRecordType` source and result.

This shape makes illegal backend states difficult to construct. It also lets
Perceus traverse replacement expressions without manufacturing expressions for
inherited fields, and gives C emission the exact release policy and complete
fallback layout without a name-based guess.

If embedding `CoreHeapRecordField` creates a demonstrated problem, an equivalent
dedicated descriptor may be used. It must still carry explicit field identity,
type, release policy, and inherited-versus-replaced state. A list of replacement
names without schema is insufficient.

### JSON And Validation

Give the new node its own Core JSON tag, for example `record_cow_update`. Its
decoder and whole-program shape validation must reject:

- a non-variable source;
- a source or result that is not a heap record;
- differing source and result record names;
- a missing heap-record declaration;
- missing, duplicate, unknown, or out-of-order fields;
- a field type or release policy that differs from its declaration;
- a replacement expression with the wrong type;
- zero replacement fields; and
- a complete replacement set that should be `RecordReuseExpr`.

Diagnostics should identify the exact JSON path and violated invariant. Update
round-trip tests and malformed-shape tests in `test_core_json.brp`.

This node is internal ownership IR, but JSON dumps and replay decoding must
remain total and deterministic.

## Record-Update Normalization

Change `record_update.brp` to retain complete heap-record declarations, not
only a list of declared record names. Build one invocation-local index by record
name in `lower_record_updates_for_ownership`; do not add a declarations-times-
updates linear search.

For a single consumed update:

1. find the exact `CoreHeapRecordDecl`;
2. validate the complete input field shape against it;
3. classify each field with `inherited_record_field`;
4. recursively prepare every replacement expression;
5. preserve the existing fields-before-source evaluation contract;
6. emit `RecordCowUpdateExpr` for a genuinely sparse update;
7. emit whole-record `RecordReuseExpr` when every field is replaced; and
8. retain the existing fresh `RecordExpr` fallback when ownership transfer is
   not proven.

For nested update chains, replace the current value-only staged-field state
with explicit provenance. A staged field must retain:

```text
declared field schema
current staged value, when replaced
whether the final value is inherited from the original source
```

Every explicit replacement expression in every layer must still be evaluated,
including a value overwritten by a later layer. Only the last replacement for
each field is moved into the final record. Perceus must release unused staged
managed values at the same point it does today.

An inherited field in a later layer preserves the earlier field's provenance.
A replacement in a later layer changes that field to replaced. This allows a
multi-layer chain to collapse to one COW update without losing evaluation or
ownership behavior.

Continue to reject reuse when the existing safety checks reject it, including
assignment to the consumed variable, unsafe source touches, incompatible
record types, missing declarations, and resource-scope hazards. This issue does
not broaden record-reuse eligibility.

## Perceus And Traversal Semantics

Every exhaustive `CoreExpr` consumer must learn the new node. Start from:

```bash
rg -l 'RecordReuseExpr' blorp/src/compiler blorp/test/compiler
```

At the time this issue was written, the production set included:

```text
stage_08_core_lower/flatten.brp
stage_09_core/closure.brp
stage_09_core/consume_specialize.brp
stage_09_core/dce.brp
stage_09_core/fairness.brp
stage_09_core/ir.brp
stage_09_core/perceus.brp
stage_09_core/prepare.brp
stage_09_core/record_update.brp
stage_09_core/resource_management.brp
stage_09_core/reuse.brp
stage_09_core/ssa.brp
stage_09_core/std_inline.brp
stage_09_core/traverse.brp
stage_09_core/tuple_sroa.brp
stage_10_backend/emit.brp
```

Refresh that inventory after adding the variant; do not treat the list as
exhaustive if the tree has changed.

The ownership meaning must remain:

```text
replacement fields, in declaration order
then source consumption
```

Only `Some(replacement)` children participate in expression traversal, use
counting, mutable-assignment rewriting, capture analysis, alias retention, and
drop insertion. `None` fields are schema, not synthetic reads of the source.

The result is an owned temporary. Passes that clone or rebuild the node must
preserve field descriptors and map only replacement expressions. No pass may
materialize inherited projections merely to reuse existing record-field
helpers.

`RecordCowUpdateExpr` may survive Perceus and backend preparation. The late
invariant that rejects surviving `RecordUpdateExpr` must continue to reject the
source-level update node, while accepting the explicit ownership form.

Keep the ownership-node inventory synchronized if any production file newly
contains `DupExpr` or `DropExpr` construction.

## Backend Contract

Emit one optimal conditional operation for a sparse update. Pseudocode for a
record with fields `a`, `b`, and `c`, replacing only `b`, is:

```c
Value next_b = /* evaluate and own replacement before touching source */;
Record* old = source;
Record* result;

if (blorp_is_unique(old)) {
    release_with_declared_policy(old->b);
    old->b = next_b;
    result = old;
} else {
    retain_with_declared_policy(old->a);
    retain_with_declared_policy(old->c);
    result = Record_make(old->a, next_b, old->c);
    blorp_release(old);
}
```

Requirements:

- evaluate and materialize replacements before the uniqueness check;
- preserve declaration order for replacement evaluation and constructor args;
- leave inherited fields completely untouched on the unique path;
- retain inherited managed fields only inside the shared branch;
- release overwritten fields only inside the unique branch;
- move replacement owners into either result path exactly once;
- pop any temporary cancellation-cleanup slots when ownership transfers;
- allocate exactly zero records on the unique path and exactly one on the
  shared path;
- work for unmanaged, ARC, ARC-release-only, and stack-result fields; and
- preserve packed boolean field emission and existing record layouts.

Do not implement this by first cloning the entire shared record and then
patching it. That design adds a retain/release pair for every replaced managed
field on the shared path. The backend has the complete explicit field plan and
can construct the final shared-path record directly.

Do not emit one helper for every possible field subset. That creates exponential
code-shape growth. Prefer site-local structured C or a bounded helper strategy
whose generated-C size is measured. Existing whole-record
`__blorp_reuse_record_<Type>` behavior must remain available and unchanged for
`RecordReuseExpr`.

## Fast Feedback Loop

Full compiler rebuilding and end-to-end compilation are intentionally last.
Most development should use one small probe plus focused source tests.

### 1. Create The Scratch Probe First

Create ignored `scratch/fieldwise_record_update_probe.brp` with:

- a wide heap record containing at least five managed fields;
- at least two unmanaged fields;
- a consuming `advance` helper that replaces exactly one unmanaged field;
- a loop with a configurable iteration count;
- a deterministic checksum printed after the loop;
- `reset_mem_stats` immediately before the measured loop;
- `get_mem_stats` immediately after it; and
- a second correctness path that keeps an alias alive and proves the old value
  is unchanged after a COW update.

A suitable core is:

```blorp
import:
	memory: get_mem_stats, reset_mem_stats

record ProbeState {
	source: String,
	diagnostics: List[String],
	pending: List[String],
	indent_stack: List[Int],
	levels: List[Int],
	offset: Int,
	line: Int
}

pure func advance(state: ProbeState) -> ProbeState:
	{ state | offset = state.offset + 1 }

func run(iterations: Int) -> (Int, Int):
	var state: ProbeState = {
		source = "probe",
		diagnostics = [],
		pending = [],
		indent_stack = [0],
		levels = [],
		offset = 0,
		line = 1
	}
	reset_mem_stats()
	var i: Int = 0
	while i < iterations:
		state = advance(state)
		i += 1
	stats = get_mem_stats()
	(state.offset + state.line, stats.total_allocations)
```

Adapt only the command-line plumbing needed to make the probe compile. Keep the
measured loop free of printing, file I/O, fixture construction, and stats reads.
Do not commit the scratch file or generated C.

### 2. Capture The Probe Baseline Once

Before changing production code, compile the probe to a temporary path and
inspect `advance` and its consuming specialization:

```bash
probe_c=$(mktemp "${TMPDIR:-/tmp}/blorp-fieldwise-record.XXXXXX.c")
bin/blorp compile --no-format --no-embed-runtime \
  -o "$probe_c" scratch/fieldwise_record_update_probe.brp
rg -n 'advance|reuse_record_ProbeState|ProbeState_destroy|blorp_retain|blorp_release' \
  "$probe_c"
rm -f "$probe_c"
```

The baseline should show inherited-field retains and a complete record
destructor on the unique path. Save only the focused function excerpt and its
hash in the work log; do not retain generated C in the repository.

During implementation, `bin/blorp` still contains the old emitter until the
integrated rebuild. Use the small Core artifact constructed inside
`test_core_emit.brp` to inspect candidate C after every backend slice. Do not
rebuild the complete compiler simply to refresh the scratch artifact. Compile
the scratch probe again only after the integrated `make`; the completed
candidate must then show only the `offset` write on the unique path.

Use `rg` against focused generated C; do not read a multi-megabyte compiler
artifact for each edit.

### 3. Typecheck Continuously

After each coherent edit, typecheck only the changed production module and its
focused test owner with the existing compiler. Do not run `make` merely to find
syntax or type errors. Typical iteration targets are:

```bash
bin/blorp check --no-format blorp/src/compiler/stage_09_core/ir.brp
bin/blorp check --no-format blorp/src/compiler/stage_09_core/record_update.brp
bin/blorp check --no-format blorp/src/compiler/stage_09_core/perceus.brp
bin/blorp check --no-format blorp/src/compiler/stage_10_backend/emit.brp
```

When an IR variant makes a temporarily incomplete exhaustive match prevent a
module from typechecking, finish the mechanical match updates as one slice and
return immediately to narrow checks.

### 4. Run Only Focused Suites During Development

Once the source typechecks, use:

```bash
bin/blorp test blorp/test/compiler/stage_09_core/test_core_json.brp
bin/blorp test blorp/test/compiler/stage_09_core/test_core_pipeline.brp
bin/blorp test blorp/test/compiler/stage_09_core/test_core_perceus.brp
bin/blorp test blorp/test/compiler/stage_10_backend/test_core_emit.brp
```

Inspect the small Core emitter artifact after backend emission changes. The
scratch probe continues to provide the fixed source shape and baseline during
this phase, but is regenerated with the candidate only after the integrated
build. Do not run the complete compiler, runtime, leak, CLI, or premerge gates
while basic IR and C-shape tests are still changing.

### 5. Rebuild Only At The Integrated Checkpoint

Run `make` after the focused Core, ownership, backend, and scratch checks agree.
The rebuilt compiler must then compile the probe and the compiler a second time
before performance conclusions are drawn.

## Test-First Plan

### Core Shape Tests

Add failing tests before production changes for:

1. a consumed one-field sparse update becomes `RecordCowUpdateExpr`;
2. its inherited fields have `replacement = None`;
3. its changed field has exactly one prepared replacement;
4. a complete replacement remains `RecordReuseExpr`;
5. a no-op update becomes the consumed source without a COW node;
6. an unconsumed or aliased source remains a fresh `RecordExpr` path;
7. a missing record declaration retains the total materialization fallback;
8. nested chains preserve every replacement evaluation but carry only the last
   value for each final replaced field;
9. a later inherited field preserves earlier replacement provenance;
10. branch-local qualifying updates use the same explicit node independently;
11. assignments or unsafe touches of the consumed variable still reject reuse;
12. replacements that read another source field are staged before consumption;
13. managed replacements receive correct ownership balancing; and
14. long sequence spines remain iterative and stack safe.

Prefer structural pattern matching over broad JSON substring assertions when a
test needs to prove exact field provenance.

### Core JSON Tests

Cover:

- round-trip of a valid sparse node;
- exact field order;
- non-variable and mismatched source;
- value-record rejection;
- unknown, missing, duplicate, and reordered fields;
- mismatched field schema or release policy;
- wrong replacement type;
- zero replacements; and
- all fields replaced.

Assert diagnostic content, not only failure status.

### Perceus And Traversal Tests

Prove that:

- replacement children are traversed once;
- inherited descriptors are not converted to source-field reads;
- use counting observes replacement values and the source exactly as specified;
- replacement values are owned before source consumption;
- direct aliases of managed source fields remain alive;
- unused overwritten staged values are released;
- mutable assignment rewriting preserves the node;
- closure, DCE, SSA, tuple SROA, preparation, resource, fairness, and reuse
  traversals preserve or map it without changing its semantics; and
- the ordinary `RecordUpdateExpr` late invariant remains intact.

### Backend C-Shape Tests

Extend `test_core_emit.brp` with exact structural assertions for:

- unique sparse update: no record constructor, no complete destructor, no
  inherited retain/release, and only named field assignments;
- shared sparse update: one constructor, inherited managed fields retained,
  replacement values moved, and the source owner released;
- replacement expression emitted before the uniqueness test;
- two replaced fields emitted once and in order;
- unmanaged field replacement;
- ordinary ARC field replacement;
- `ArcReleaseOnlyPolicy` field replacement;
- `StackResultReleasePolicy` field replacement;
- packed boolean replacement;
- unchanged whole-record `RecordReuseExpr` emission; and
- bounded generated C for multiple update sites and shapes.

Do not assert temporary numbers that can change harmlessly. Assert semantic C
fragments and their relative order.

### Runtime And Ownership Regressions

Add or extend runtime memory tests for:

- repeated unique sparse updates remain allocation bounded;
- a live alias forces COW and observes the old fields;
- unchanged managed fields survive both unique and shared paths;
- overwritten managed fields are released;
- a replacement aliasing an unchanged field remains owned;
- swapping two managed fields is safe;
- nested updates preserve values and evaluation count;
- branch updates preserve values; and
- no leak or double release occurs under sanitizer/leak execution.

Use exact results plus bounded memory assertions. A `should_fail`-style test
without checking its diagnostic is not sufficient.

## Measurement Protocol

### Focused Probe

Build baseline and candidate probe executables with:

- the same probe source hash;
- the same compiler generation;
- the same C compiler and optimization flags;
- the same runtime source/object;
- the same iteration count; and
- alternating run order.

Run one warmup and at least five alternating measured pairs. Report:

- median measured-loop time;
- all raw sample times;
- checksum;
- allocations and releases inside the loop;
- current objects and allocator bytes after the loop;
- generated-C bytes; and
- static counts of inherited retains/releases in the generated update path.

The checksum and allocation behavior must match. The candidate must remove all
inherited ownership operations from the unique path. Timing supports that
structural proof; it does not replace it.

### Stage 01-04 Compiler Workload

Use `compile --ast` so the measured command stops after the validated frontend
graph and before Stage 05:

```bash
BLORP_COMPILER_MEMORY_PROFILE=1 \
  <worker> compile --ast --no-format blorp/src/main.brp
```

This optimization changes the generated implementation of the compiler's own
lexer and parser. A compiler built once by the old pinned bootstrap does not
contain the new ownership optimization in its own generated lexer. Therefore
performance validation requires controlled second-generation workers:

```text
same pinned seed compiler
  -> build baseline generation 1 from baseline sources
  -> baseline generation 1 builds baseline generation 2

same pinned seed compiler
  -> build candidate generation 1 from candidate sources
  -> candidate generation 1 builds candidate generation 2
```

Only generation-2 workers are compared. Record source hashes, seed compiler
hash, generated C hashes, worker hashes, C compiler version, flags, and runtime
hash. Build workers serially to avoid resource interference.

Both workers must process the exact same Stage 01-04 source corpus. Prefer the
candidate source tree as the shared workload after confirming that the baseline
worker can parse it; `--ast` does not execute candidate typechecking or backend
logic. If that is not possible, create one immutable copied corpus and document
why.

Run one warmup and at least five alternating measured pairs. Capture:

- Stage 01-04 wall time;
- total allocations and releases at exit;
- current objects and allocator bytes;
- process peak RSS;
- module/file/token counts when available;
- output summary checksum; and
- worker and input hashes.

Allocation counts should remain neutral. Use a 0.5% investigation threshold:
any larger movement must be explained rather than attributed to fieldwise
updates. Timing is noisy; report every sample and the median without presenting
the exploratory 5-15% expectation as a guaranteed result.

If leaf profiling is repeated, keep it restricted to Stages 01-04. Compare
`lex`, `scan_one`, identifier scanning, cursor advancement, parser entrypoints,
and aggregate parse time. Do not use total compiler time to judge this issue.

## Acceptance Criteria

The issue is complete only when all of the following are true:

1. sparse consumed heap-record updates have an explicit phase-specific IR form;
2. inherited and replaced fields are represented explicitly, not inferred in C
   emission;
3. the unique path performs no allocation and no ownership operation or
   assignment for inherited fields;
4. the shared path allocates one final record and preserves value semantics;
5. replacement expressions are evaluated once, in order, before source
   consumption or mutation;
6. all four release-policy classes are handled correctly;
7. complete updates retain the existing whole-record reuse path;
8. unsafe or unproven cases retain the existing fresh-construction fallback;
9. nested and branch update behavior is unchanged;
10. Core JSON decoding rejects malformed fieldwise nodes with actionable paths;
11. every Core traversal handles the new node intentionally;
12. focused generated-C tests prove removal of inherited ARC traffic;
13. runtime, leak, and sanitizer tests show no leaks, double releases, or stale
    aliases;
14. the scratch wide-state probe produces the same checksum and allocation
    count with a measurable timing improvement;
15. second-generation Stage 01-04 allocation counts remain neutral within the
    documented threshold when the selected command crosses the checkpointed
    execution boundary; otherwise the report documents that profiling gap and
    supplies focused allocation counts plus process-level peak RSS;
16. second-generation Stage 01-04 timings and lexer leaves are reported without
    relying on total compiler time;
17. generated-C growth is measured and no per-field-subset helper explosion is
    introduced;
18. `make`, affected compiler checks, runtime ownership checks, sanitizer/leak
    checks, formatting, and `git diff --check` pass; and
19. one complete relevant test pass is run only after the focused implementation
    loop is stable.

If the focused probe does not improve despite proving fewer ownership
operations, stop and profile the probe before expanding the implementation. If
the design requires heuristic field classification, changes public record
semantics, or creates unbounded generated-code specialization, stop and revise
the design rather than landing a partial workaround.

## Final Validation Sequence

After focused development is complete:

1. run formatting checks for changed Blorp files;
2. run `scripts/compiler-check --changed`;
3. run the owning Stage 09 Core and Stage 10 backend suites;
4. run the affected runtime memory suite;
5. run compiler Core sanitizer and ownership/leak gates;
6. run `make` and prove two-generation self-hosting;
7. inspect generated C for the scratch probe and real `LexerState.advance`;
8. run the focused alternating benchmark;
9. run the second-generation Stage 01-04 alternating benchmark;
10. run one complete relevant test pass;
11. run `git diff --check`; and
12. delete every generated `.c`, worker, copied corpus, and temporary log that
    is not an intentionally retained ignored benchmark artifact.

Use the repository's code-reviewer, test-runner, and code-optimizer review flow
before commit. Address blocking findings and include their final verdicts in the
implementation report.

## Out Of Scope

Do not combine this issue with:

- lexer emission-list refactoring;
- removal or inlining of `token_with_trivia`;
- consuming specialization through tuple-returning helpers;
- canonical empty collection literals;
- tuple/result SROA;
- stack conversion of `SourceSpan`, `SourceFile`, or lexer/parser state;
- broader record-reuse eligibility;
- public syntax or record-semantics changes;
- runtime identity observability; or
- general ARC instrumentation.

Those may be measured separately after this optimization. Cosmetic reshaping of
`emit_token` has already been shown not to change its material allocation shape
and is not a substitute for the ownership fix described here.

## Implementation Report Requirements

The completed issue report must include:

- final IR representation and its invariants;
- why source evaluation order is preserved;
- unique- and shared-path ownership accounting;
- representative before/after generated C;
- focused probe source hash and all benchmark samples;
- Stage 01-04 worker generations, hashes, samples, and memory counters, or an
  explicit checkpoint-boundary limitation with the available RSS evidence;
- allocation-neutrality result for the narrow operation and, when the
  checkpoint boundary supports it, the complete early frontend;
- generated-C size result;
- focused and final test commands with pass/fail totals;
- sanitizer and leak results;
- reviewer findings and resolution; and
- any rough edge discovered in consuming specialization, Perceus, cancellation
  cleanup, or backend record layout.

## Implementation Report

### Final Design

The implementation adds the phase-specific node:

```blorp
RecordCowUpdateExpr(
	source: CoreExpr,
	fields: List[CoreRecordCowField],
	typ: CoreType,
	loc: CoreSourceLoc,
)

record CoreRecordCowField {
	field: CoreHeapRecordField,
	replacement: Option[CoreExpr]
}
```

The field list is the complete heap-record declaration schema in declaration
order. `Some(expr)` identifies a replaced field and `None` identifies an
inherited field. Validation requires a declared heap-record type, an exact
name/type/release-policy match for every field, a variable source of the same
heap-record type, and a replacement count strictly between zero and the full
field count. Zero replacements reduce to the source; complete replacements
continue to use `RecordReuseExpr`.

Normalization also validates the original and prepared field expression types.
An apparent inherited projection must have the exact source variable, source
type, field name, and declared result type. Malformed or unproven Core is
materialized as an ordinary fresh `RecordExpr`; it is never promoted into the
trusted COW form.

Nested update chains classify each field as inherited, newly replaced, or a
replacement carried from an earlier layer. Every explicit replacement is
staged in its original order, including a replacement overwritten by a later
layer. The final sparse/full update is emitted only after those lets, so all
replacement expressions run once before uniqueness is tested or the source is
mutated.

### Ownership Accounting And Emission

The node's traversal order is replacement expressions in declaration order,
followed by the source. An inherited field has no child expression. Perceus,
closure conversion, DCE, SSA, reuse, preparation, and every other exhaustive
Core consumer handle that representation explicitly.

The backend emits the operation at its use site; there is no helper specialized
by changed-field subset. Replacement values are first moved into temporaries
and their cancellation-cleanup slots are popped. The two runtime paths are:

```c
/* unique */
if (blorp_is_unique(source)) {
    release_changed_field(source->changed);
    source->changed = replacement;
    result = source;
} else {
    /* shared */
    retain_inherited_field(source->inherited);
    result = Record_make(replacement, source->inherited);
    blorp_release(source);
}
```

The unique path performs no ownership operation, assignment, destructor call,
or allocation for inherited fields. The shared path retains inherited managed
fields exactly once, constructs one final record, and releases the consumed
source owner. Emission has explicit cases for `NoReleasePolicy`,
`ArcReleasePolicy`, `ArcReleaseOnlyPolicy`, and
`StackResultReleasePolicy`. Adjacent packed Boolean fields retain their normal
record layout.

### Focused Probe

The ignored scratch probe is
`scratch/fieldwise_record_update_probe.brp`, SHA-256
`742f08b4912ebb0b3367e7dbe7492d145001873c0b9608f94c61ce571adb4744`.
It performs one million sparse updates to a seven-field state with five
managed inherited fields and checks an aliased value.

The baseline generated C hash was
`ab06491d5947fbdbc0c060be4be81155ce05483a3d97721c90e27918a4db4058`;
the candidate hash was
`97c830e881fbcc5266288e77133cb157c034af2fe0e83796a18aeb37962d68a9`.
The candidate C was 26,292 bytes versus 26,833 bytes for the baseline, a
541-byte (2.0%) reduction. Both runs reported:

```text
checksum=1000001 allocations=0
```

After warmup, seven alternating elapsed-time samples in milliseconds were:

| Worker | Samples | Median |
| --- | --- | ---: |
| Baseline | 16.100, 16.862, 15.808, 15.896, 15.875, 15.474, 15.553 | 15.875 |
| Candidate | 6.516, 6.217, 6.427, 6.023, 5.907, 6.046, 5.884 | 6.046 |

The focused loop improved by 61.9%. Generated-C inspection confirmed that the
candidate unique path performs only the offset assignment; the five inherited
managed fields have no retain, release, destructor, or assignment on that
path.

### Compiler Self-Host And Frontend Measurement

The strict baseline worktree was revision
`c4f407dc99a40b62ccfca340ef5eba64348307a3`. Its generation-two worker hashes
were:

```text
C:      a02d366b445db8220ffa73f29479650628673228300e1edd2e51275b1ed3707d
worker: 9380c667c14f40fad3c370fdc1f491d80302b354c4e4eb2ee6e9fe701877b5c7
```

Both workers were built from bootstrap compiler SHA-256
`95e13612f1aff6f25b201919562be8230263af5d2d439e33cdf49839b75a2c94`
with Apple clang 21.0.0 and the repository's `-O0 -fwrapv -pipe -w`
compiler-worker flags. The candidate runtime object hash was
`0cd2f5c0daff5b4d53421df426838184a660852e54b1288567f4e6a80947d288`.

The final candidate generation-two hashes were:

```text
C:      dc7856b37b5c564484a6bdd3800c9219dd1a3b433eb0c8e59be32a4c3b454c00
worker: 17850bed236451544d6bbffed819474e1b7eca000859d55ee425bffb6c7064ec
```

The candidate worker regenerated byte-identical generation-three C with hash
`dc7856b37b5c564484a6bdd3800c9219dd1a3b433eb0c8e59be32a4c3b454c00`.
The measured input manifest over all `.brp` files under `blorp/src` and
`standard_library/src` was
`90ac8742bb7a0c0926d339ed94255b7d31665707e01fdcda61879865fa4a084f`.

Both generation-two workers ran the same candidate source tree with:

```bash
<worker> compile --ast --no-format \
  --std-dir standard_library/src blorp/src/main.brp
```

CLI planning discovers and validates the complete reachable Stage 04 graph
before the AST-only command renders the root summary. The summary output hash
was identical at
`c4bce017fb6e9b2e7dff1d0a9538567fc7933ea0615bf14b0da8211d64225c39`,
but that root-only output is not used as proof of corpus identity; the input
manifest supplies that evidence.

After one warmup per worker, six balanced pairs measured by macOS
`/usr/bin/time -l` alternated AB/BA worker order:

| Worker | Elapsed samples (s) | Median elapsed | Median peak RSS |
| --- | --- | ---: | ---: |
| Baseline | 3.98, 3.97, 3.99, 3.99, 4.02, 4.05 | 3.99 s | 281,354,240 B |
| Candidate | 3.64, 3.65, 3.68, 3.67, 3.94, 3.77 | 3.675 s | 281,296,896 B |

The complete early frontend improved by 7.9%. Median peak RSS changed by
-57,344 bytes (-0.02%), which is effectively neutral.

`BLORP_COMPILER_MEMORY_PROFILE=1` did not emit allocation checkpoints for this
command. Graph discovery happens while building the CLI plan, while the first
checkpoint is in `execute_compile_plan_timed`; the AST-only branch returns
before that function. Consequently this report does not claim a full-frontend
allocation-count change. The focused update loop proves allocation neutrality
for the optimized operation, and peak RSS is neutral, but exact graph-wide
allocation/release counts require moving profiling checkpoints to the plan
construction boundary or adding a dedicated benchmark worker. That
instrumentation change is intentionally not folded into this ownership patch.

### Code Size And Profile Shape

The final baseline generation-two C was 96,814,317 bytes and the candidate was
97,281,830 bytes: +467,513 bytes (+0.48%). The corresponding `-O0` workers were
20,607,040 and 20,677,136 bytes: +70,096 bytes (+0.34%). The compiler contains
94 site-local fieldwise COW updates. No per-field-subset helpers are emitted,
so growth is linear in qualifying sites rather than combinatorial in record
shape.

A macOS sampling profile also showed the intended leaf-level shift. In one
equal-duration sample, top-of-stack counts for `blorp_release`, `blorp_retain`,
and task-cleanup duplication moved from 196/146/76 to 177/121/41. The old
whole-record `LexerState` reuse helper appeared 34 times in the baseline sample
and was absent from the candidate's sampled hot leaves. These sample counts are
supporting evidence only; the alternating wall-time benchmark is the primary
timing result.

### Validation And Review

Focused tests cover JSON round trips and exact first-error paths, malformed
normalization fallback, nested overwritten replacement staging, explicit
traversal behavior, all release policies, unique-branch negative assertions,
shared-branch ownership counts, bounded multi-site emission, aliases, managed
field swaps, allocation bounds, and loops.

The final validation includes:

- `make`;
- byte-identical generation-two/generation-three self-hosting;
- 113/113 Core JSON tests;
- 43/43 contiguous Core pipeline tests;
- 300/300 Perceus tests;
- 301/301 backend emitter tests;
- 7/7 Core traversal tests;
- 13/13 Record COW runtime tests in normal, ASan/UBSan, and leak-check modes;
- the changed-file compiler gate covering 16 production sources, 18 owning
  suites, Core sanitizer, generated-C audit, and the leak gate; and
- formatter checks plus `git diff --check`.

Initial code review reported three medium findings: trusted normalization did
not validate every annotation, JSON validation could overwrite the first error
and used an imprecise schema path, and structural/evaluation-order evidence was
too broad. The implementation now uses structural Core type equality at the IR
boundary, falls back on malformed annotations, stops at the first exact JSON
error, and includes the focused tests listed above. No backend ownership or
cancellation-cleanup defect was found.

The only retained rough edge is the profiling-checkpoint boundary described
above. It affects graph-wide allocation measurement, not generated program
correctness or the fieldwise update fast path.
