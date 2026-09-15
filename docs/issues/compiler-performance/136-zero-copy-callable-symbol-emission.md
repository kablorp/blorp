# Emit Compact Callable Symbols Without Rebuilding Core

**Status:** Complete (2026-09-15).

**Current state:** Final C-symbol preparation validates the original prepared
`CoreProgram` and publishes an immutable `CEmissionSymbolPlan`. C emission
traverses that original Core and selects compact spellings only at callable use
sites. The projected-program copy, recursive rewriter, and reverse display-name
dictionary have been deleted.

**Result:** The baseline profile counted 37,632 rebuilt Core expressions. The
candidate makes that reconstruction structurally impossible: its opaque result
contains only symbol-plan metadata and canonical-list rows, so its
schema-compatible rebuild fields are zero by representation rather than by a
runtime traversal counter. Managed allocations fell by 74.4% and retained
objects by 98.3% while preserving the exact symbol checksum. Deterministic
backend response, generated C, native objects, and runtime output are
byte-identical. See the
[retained result](../../../benchmarks/results/compiler_c_symbol_zero_copy_2026-09-15.md)
and [raw paired production data](../../../benchmarks/results/compiler_c_symbol_zero_copy_2026-09-15.json).

**Read first:**
`blorp/src/compiler/stage_10_backend/c_symbol_projection.brp`,
`blorp/src/compiler/stage_10_backend/emit.brp`,
`blorp/src/compiler/pipeline.brp`,
`blorp/test/compiler/stage_10_backend/test_c_symbol_projection.brp`, and the
[retained callable-projection result](../../../benchmarks/results/compiler_c_symbol_projection_2026-08-23.md).

**Fast loop:** Run
`benchmarks/compiler_c_symbol_projection_profile calls 3 256 96 16` for direct
allocation/work evidence and the focused symbol-projection suite after each
edit. Replay the deterministic request through `compiler_backend_memory` for
direct RSS only after its generator exists. Inspect generated C before broader
gates.

**Decision:** Accept only if projected Core node reconstruction reaches zero,
the deterministic backend response and paired production-route output are
unchanged, and backend allocations, retired instructions, peak memory, and
latency have no material regression.
The intended success signal is a lower backend peak/retained-memory measure.
Reject a second shadow AST, emitter-side name guessing, or a fallback that
emits an unprojected internal callable.

## Objective

Preserve the validated compact callable-symbol policy while emitting directly
from the original prepared Core, eliminating the full projected-Core copy and
its reverse display-name dictionary.

## Problem

`project_core_program_callables` currently does two conceptually different
jobs:

1. validate that final Core has complete, collision-free callable identities;
2. rewrite the whole tree so the ordinary emitter sees projected strings.

The first job is required. The second is not. In production it executes after
all expensive Core passes, at exactly the point where the prepared Core is
largest. Recursive `project_expr`, `project_function`, and `project_decl`
construct a second graph whose semantic content is identical except for a few
C spellings. C emission then grows a complete artifact string while that graph
is live.

This is a poor lifetime boundary even when copy-on-write shares some leaves:
all child-bearing expression spines are rebuilt, allocation and traversal work
is proportional to final Core size, and peak memory can overlap prepared Core,
projected Core, and generated C.

## Scope And Invariants

This issue changes representation only. Preserve all existing behavior:

- callable selection remains keyed by artifact-local definition identity;
- `main`, foreign, builtin, and runtime symbols remain preserved;
- collision detection includes generated helpers and canonical empty lists;
- unknown/deferred/unresolved calls still fail before partial C is returned;
- profile labels, inventory comments, Core dumps, and error text remain
  readable;
- generated C is byte-for-byte identical for the deterministic backend request
  and paired production-route fixture.

String-only list/dictionary callback cleanup remains owned by
[the C-symbol follow-up](c-symbol-projection-followups.md). It may continue to
use the plan's exact validated original-spelling index during this
representation change.

## Target Design

The final boundary should publish a small immutable plan, not another program:

```blorp
record CEmissionSymbolPlan {
	callables_by_definition_id: Dict[Int, CCallableSymbol],
	callbacks_by_original_spelling: Dict[String, CCallableSymbol],
	canonical_empty_lists: List[CanonicalEmptyList]
}

pure func prepare_c_emission_symbols(
	program: CoreProgram,
) -> Result[CEmissionSymbolPlan, CSymbolProjectionError]
```

The exact shape may differ, but it contains only symbol metadata and validation
results, never `CoreProgram`, `CoreDecl`, or `CoreExpr`.

The emitter receives prepared Core plus the plan and projects only at a C-name
use site:

```blorp
name ?= emitted_callable_name(
	plan,
	function_info.name,
	function_info.def_id,
)
```

Calls, declarations, closure records, task closures, static closure helpers,
and callback adapters must all use one projection API. Helper spellings such
as the static-closure name derive from the selected projected base name rather
than being stored back into Core.

Readable output should receive the logical name already present on the
original Core node. The no-copy design therefore should delete
`original_name_by_projected_name`; it must not replace it with another reverse
dictionary. If a particular emission path has only a projected name, fix that
API to carry the original node/identity rather than reconstructing display
state.

## Implementation Strategy

### 1. Establish A Direct Work Signal

Add benchmark-only or profile metrics for:

- final Core expressions visited by validation;
- Core expressions rebuilt by symbol projection;
- projected declarations rebuilt;
- plan entries and preserved symbols; and
- emitted C bytes.

The baseline must demonstrate nonzero rebuild work on the focused scaling
fixtures. The candidate must report schema-compatible zeros and document that
they follow from the compiler-checked plan-only result type, not from an
observed traversal counter. Keep validation visits separate: correctness
validation is not the work being removed.

### 2. Separate Plan Construction From Rewriting

Rename the boundary around what it owns. Retain inventory, identity validation,
collision handling, and canonical-empty-list discovery. Return only the plan
and canonical-empty-list table. Delete the projected-program opaque wrapper
once its final consumer is migrated.

Do not combine this with a speculative validation fusion; a later profile can
justify that independently.

### 3. Make Emitter Lookups Explicit

Thread the immutable plan through the existing emission context. Centralize
lookups so every callable use either returns its selected C spelling or the
same structured failure produced today. Avoid sprinkling raw dictionary
lookups through the 24k-line emitter.

Convert in small vertical slices:

1. callable declarations and forward declarations;
2. direct calls and callable values;
3. closure creation/static closure helpers;
4. concurrent/detached task helpers; and
5. list/dictionary/set callback names.

After each slice, the focused test must show identical C. Temporary mixed mode
is allowed only within the uncommitted implementation: there must be one
emission authority at review.

### 4. Delete The Rewriter And Reverse Display Map

Remove `project_expr`, `project_function`, `project_decl`,
`projected_core_program_value`, and the reverse display-name map. Confirm that
the backend result no longer owns any second Core root.

## Test-First Cases

Before changing the implementation, extend the focused suite so the emission
path—not merely plan construction—covers:

- user and closure-body declarations;
- direct calls, recursion, and callable values;
- closure creation and its static object;
- detached, concurrent, and concurrently-loop task helpers;
- list-to-string and custom hash/equality callbacks;
- missing, stale, negative, duplicate, and unresolved definition identities;
- canonical empty-list symbols.

For each accepted case compare the complete generated C with the current
baseline fixture. For each rejected case compare the structured error text and
prove no partial artifact is returned.

## Measurement Plan

The environment-based production capture recipe still printed in
`benchmarks/README.md` is not implemented by the current compiler and is not an
executable loop for this issue. Do not rely on it. First add a deterministic
request generator beside
`blorp/benchmark/compiler/compiler_core_source_loc_request.brp`. It should
reuse the projection profile's calls/deep fixture shapes and print one schema-1
`emit_core_c` envelope. Name it
`compiler_c_symbol_projection_request.brp`, cover it with the backend-memory
benchmark contract test, and document its exact invocation in
`benchmarks/README.md`.

The narrow instrumented loop already exists and reports managed allocations,
releases, live objects, allocated bytes, validation work, checksums, and window
time:

```bash
benchmarks/compiler_c_symbol_projection_profile calls 3 256 96 16
benchmarks/compiler_c_symbol_projection_profile deep 3 256 96 1
```

On macOS, wrap the plain cached binary invocation with `/usr/bin/time -lp` for
retired instructions; on Linux use the repository's normal `perf stat`
workflow from the profiling guide. Alternate baseline and candidate invocations
and retain the raw rows rather than averaging unrelated builds.

Once the deterministic backend request exists, build timing and counter
backend workers for the pinned baseline and candidate, then alternate these
commands three times per worker:

```bash
benchmarks/compiler_backend_memory "$request" --bridge "$baseline_bridge" --timeout 60 --json
benchmarks/compiler_backend_memory "$request" --bridge "$candidate_bridge" --timeout 60 --json
```

Reverse the order on every other pair. `compiler_backend_memory` is a
single-worker runner, so the saved result must record execution order and
compare request/response SHA explicitly. Add `--vmmap` in a separate macOS
run; do not mix sampled and unsampled RSS rows.

Use the existing paired end-to-end guard for generated C, native objects, and
runtime output:

```bash
benchmarks/compiler_c_symbol_projection \
  --baseline-compiler "$baseline_compiler" \
  --baseline-compiler-root "$baseline_root" \
  --compiler "$candidate_compiler" \
  --compiler-root "$candidate_root" \
  --samples 3 --skip-build --json
```

Run three alternating pairs first; expand to five only if a primary metric is
noisy enough to change the decision. Do not default to ten pairs.

Classify metrics before running:

| Metric | Role | Expected result |
| --- | --- | --- |
| Rebuilt Core nodes | Primary mechanism | Drops to zero |
| Backend peak/retained memory | Primary outcome | Meaningfully lower |
| Allocation calls/bytes | Primary outcome | Lower |
| Retired instructions | Primary outcome | Lower or neutral |
| Backend wall time | Guard/outcome | Lower or within noise |
| Generated C bytes/SHA | Correctness | Exactly identical |
| Final executable output | Correctness | Exactly identical in paired end-to-end gate |
| Native object size | Guard | Exactly identical for identical C/toolchain |

Preserve raw paired JSON under `benchmarks/results/` with revisions, hashes,
host, and commands. If RSS is too
coarse, add a boundary-retained-byte or allocation counter; do not make a
wall-time-only claim.

## Acceptance Criteria

- The emitter traverses the original prepared `CoreProgram` with an immutable
  `CEmissionSymbolPlan`.
- The plan contains no Core AST/program owner.
- The baseline projection rebuild counters are nonzero; the candidate reports
  schema-compatible zeros justified by its compiler-checked plan-only payload.
- `CProjectedProgram` and its recursive rewrite helpers are deleted.
- The reverse projected-to-display-name dictionary is deleted.
- The deterministic backend response is byte-identical by SHA; paired
  production-route generated C, native objects, and runtime behavior are
  unchanged.
- Existing failure cases remain fail-closed with the same useful diagnostics.
- Three alternating pairs show lower allocations and a lower direct
  peak/retained-memory signal; retired instructions and latency do not cross
  the roadmap regression thresholds.
- Focused backend tests, codegen audit, compiler checks, sanitizer/leak gates,
  and `git diff --check` pass.

If output identity holds and reconstruction reaches zero but host RSS cannot
resolve the difference, retain the deterministic allocation/retained-byte
evidence and explicitly label RSS inconclusive. A measured regression beyond
the roadmap thresholds rejects the change or requires a separately justified
tradeoff.

## Non-Goals And Stop Conditions

- No compact projection of types, globals, fields, locals, or ABI-visible
  symbols.
- Stop and ask for design review if an emitter path cannot select a callable
  from exact identity or the validated callback index without reading a
  mutated Core name.
