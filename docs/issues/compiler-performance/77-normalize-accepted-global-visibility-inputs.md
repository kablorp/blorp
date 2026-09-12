# Normalize Accepted Global Visibility Inputs

**Status:** Complete

**Roadmap:** [Normalized Semantic Compilation Roadmap](NORMALIZED_SEMANTIC_COMPILATION_ROADMAP.md), Step 2e, sixth packet

**Depends on:** Accepted global selective targets (Issue 76)

## Outcome

Accepted-global authority construction now receives one provenance-bound opaque
visibility aggregate whose rows are normalized values:

```blorp
private record AcceptedVisibleGlobalBindingRep {
	source_name_id: SourceNameId,
	target: GlobalId
}

opaque type AcceptedVisibleGlobalBinding = AcceptedVisibleGlobalBindingRep

private record AcceptedGlobalVisibilityRep {
	table: AcceptedGlobalTable,
	owner_module_path: String,
	owner_module_id: ModuleId,
	bindings: List[AcceptedVisibleGlobalBinding]
}

opaque type AcceptedGlobalVisibility = AcceptedGlobalVisibilityRep
```

Both local globals and imported globals cross the authority boundary as
compilation-derived values. The authority no longer accepts source-name
spellings in its visibility relation, performs a canonical-path-to-`ModuleId`
lookup, or discovers local globals by walking string names. It still retains the
owner's canonical path for semantic-type localization and the source-name table
for compatibility queries and diagnostics.

## Context

Issue 76 replaced imported `(module_path, original_name)` target reconstruction
with exact `GlobalId`, but the authority still had two source-oriented inputs:

```blorp
record AcceptedVisibleGlobalBinding {
	source_name: String,
	target: GlobalId
}
```

Local visibility was also reconstructed inside the authority by taking the
scope's canonical path, looking it up in the module table, enumerating a
`Dict[String, Int]`, and resolving every string back into `SourceNameId`.

That boundary was inverted: semantic visibility had already been decided, but
the final authority still received spellings and reconstructed identities. This
packet moves the compatibility projection to one table adapter and makes the
authority's contract reflect the normalized data it actually retains.

## Invariants

1. `AcceptedVisibleGlobalBinding` is opaque; arbitrary source-name indexes and
   global targets cannot be paired by callers. The enclosing
   `AcceptedGlobalVisibility` is also opaque and retains the exact table and
   owner context, so valid rows cannot be replayed under another compilation's
   coincident integer layout.
2. The adapter validates that the accepted-global table, prepared owner scope,
   and issuing definition table share compilation provenance.
3. The owner is `prepared_module_scope_id(owner_scope)`, never a reverse lookup
   from canonical path.
4. Every local slot must resolve to a global row owned by that exact `ModuleId`
   and a cataloged `SourceNameId`.
5. Every selective target admitted to this authority must validate as a
   `GlobalId` owned by the module recorded in its graph selective binding.
   Non-global target categories remain with their own authorities.
6. Local rows are admitted before imported rows, preserving local/import
   collision behavior.
7. The adapter requires every imported global slot to be public before erasing
   local/import origin. Private globals remain visible only through owner-local
   rows, including when a selective binding names the owner's own module.
8. Standalone syntax bindings contribute no imported semantic targets; mixed
   graph/standalone views remain invalid.
9. Qualified source lookup and diagnostic rendering remain compatibility
   projections and are not changed by this packet.

## Implementation Strategy

### 1. Change the product contract in the focused test

Require the direct authority fixture to obtain its complete local/import
visibility input from `accepted_global_visibility_bindings`. The pre-change
compiler fails because that normalized constructor does not exist. Retain the
foreign-scope, foreign-table, uncataloged alias, exact alias, completion, and
lookup assertions.

### 2. Build local rows from exact table slots

Use the prepared scope's exact `ModuleId` to select the owner's existing table
bucket. Iterate its slot indexes rather than materializing string keys. Validate
each slot against the table's global row, project the diagnostic spelling once
through the graph `SourceNameTable`, and construct an opaque row.

This packet deliberately does not add a parallel per-module index. The existing
qualified-lookup bucket remains the temporary enumeration source, but its string
keys no longer cross into authority construction.

### 3. Append exact selective-import rows

For each graph selective definition binding, resolve the admitted definition ID
as a `GlobalId`, validate its owner module, resolve the local spelling once to
`SourceNameId`, and append the same opaque row shape used for locals. Other
semantic categories remain owned by their existing authorities.

### 4. Bind rows to their compilation provenance

Return an opaque aggregate containing the accepted table, owner identity, and
normalized rows. The table owns its graph source-name domain after Issue 78.
Authority construction consumes only that aggregate, rather than accepting rows
beside a second independent table/scope triple. Cross-compilation replay is
therefore unrepresentable at the API.

Validate public visibility while imported rows still retain their origin. This
prevents a same-module selective import from acquiring the owner-local private
exception after local and imported rows are unified.

### 5. Make authority construction value-only

The authority's row loop reads only `SourceNameId` and `GlobalId`, validates the
exact slot, computes owner-local visibility from exact module IDs, and stores its
existing integer locator map. Source spelling remains available only through the
retained `SourceNameTable` for compatibility queries and diagnostics.

### 6. Preserve the source-only diagnostic

The source-only unresolved-import regression checks the exact user-facing
diagnostic, not merely an empty error list. This keeps the standalone boundary
honest while ensuring no internal accepted-global error is introduced.

## Fast Feedback Loop

Iterate with the direct product test, then run the two affected integration
suites and one production smoke:

```bash
bin/blorp test \
	blorp/test/compiler/stage_06_typecheck/test_declaration_skeleton_graph.brp
bin/blorp test \
	blorp/test/compiler/stage_06_typecheck/test_frontend_graph_typecheck.brp
bin/blorp test blorp/test/compiler/stage_06_typecheck/test_typecheck_decl.brp
bin/blorp check --no-format \
	blorp/benchmark/compiler/selective_import_graph_fixture/main.brp
```

Measure the directly affected accepted-graph stage once per variant:

```bash
env BLORP_COMPILER_BENCHMARK_SKIP_BUILD=1 /usr/bin/time -lp \
	benchmarks/compiler_typecheck_phase_profile accepted 1 32 4 16 16 memory
```

Do not add timing pairs unless a stable counter approaches a rejection boundary.
Short wall and cycle samples are retained for reproducibility, not used as
claims.

## Acceptance Criteria

- [x] Authority construction accepts no source string in its visibility rows.
- [x] Local and imported visibility share one opaque `SourceNameId + GlobalId`
  product.
- [x] Owner `ModuleId` comes directly from `PreparedModuleScope`.
- [x] The path-to-module reverse lookup is deleted from construction.
- [x] Local construction no longer enumerates or probes string keys.
- [x] Foreign provenance, invalid global targets, uncataloged names, private
  imports, and collisions fail closed; non-global categories do not enter the
  product.
- [x] A valid foreign visibility aggregate cannot be replayed with an owner
  table/scope; the consumer has no independent context arguments.
- [x] A same-module selective binding cannot import a private global under a
  cataloged alias.
- [x] Standalone source imports retain their exact user-facing diagnostic without
  an internal accepted-global error.
- [x] Direct authority, frontend graph, and declaration suites pass: 14, 11, and
  140 tests.
- [x] The production selective-import fixture typechecks.
- [x] Retained objects are neutral and allocated bytes improve slightly.
- [x] Retired instructions improve slightly; compiler executable size remains
  effectively neutral.
- [x] Allocation calls, RSS, and peak footprint remain below the roadmap's
  investigation thresholds.
- [x] Changed-owner checks pass: two production sources, nine suites, one
  declaration-boundary check, and zero failures.
- [x] Independent review reports no unresolved issue.

## Measurements

Both accepted-stage runs report semantic checksum `-6362768653699369705`,
constructor checksum `-2142865109331864226`, 1,257 primary outputs, 65 secondary
outputs, 136 accepted constructor rows, and 353 accepted field rows.

| Metric | Issue 76 baseline | Candidate | Change |
| --- | ---: | ---: | ---: |
| allocations | 278,251 | 278,317 | +0.02% |
| releases | 189,249 | 189,315 | +0.03% |
| retained objects | 89,002 | 89,002 | 0.00% |
| allocated bytes | 6,491,112 | 6,490,056 | -0.02% |
| instructions retired | 8,477,386,936 | 8,462,326,045 | -0.18% |
| cycles | 2,709,090,242 | 2,353,452,184 | -13.13% |
| maximum RSS | 40,042,496 | 40,042,496 | 0.00% |
| peak footprint | 33,522,000 | 33,538,408 | +0.05% |
| compiler executable bytes | 19,388,496 | 19,388,768 | +0.0014% |

The one-shot measured window moved from 230,169 to 170,044 microseconds. The
wall and cycle changes are recorded but not claimed. Direct counters show lower
allocated bytes and retired instructions with neutral retention; the small
allocation-call, peak-memory, and code-size movements remain comfortably within
guard thresholds. Raw evidence is in
[`compiler_accepted_global_visibility_inputs_step2e_2026-09-11.md`](../../../benchmarks/results/compiler_accepted_global_visibility_inputs_step2e_2026-09-11.md).

## Next Packet

Completed as
[`78-replace-accepted-global-string-index.md`](78-replace-accepted-global-string-index.md):
one exact per-module `SourceNameId -> slot` relation replaces the retained string
dictionaries and serves local enumeration, duplicate validation, and qualified
compatibility lookup.
