# Preserve Exact Direct Accepted-Callable Resolution

**Status:** Complete

**Roadmap:** [Normalized Semantic Compilation Roadmap](NORMALIZED_SEMANTIC_COMPILATION_ROADMAP.md), Step 2e, thirteenth packet

**Depends on:** Prepared-scope accepted-callable authorities (Issue 83)

## Outcome

Direct accepted-callable lookup now returns the semantic identity that selected
the callable instead of discarding it and returning only a compatibility
`OverloadEntry`:

```blorp
record AcceptedCallableBinding {
	id: CallableId,
	source_name: String,
	entry: OverloadEntry
}
```

Bare and qualified accepted calls consume `binding.id` directly when building
`ResolvedGraphCallableCall`. The source spelling comes from the canonical
definition row. Inference no longer compares `OverloadEntry.module_path` with
an imported-name path to rediscover the original function name, and it no
longer reconstructs a graph `CallableId` from `entry.def_id`.

This is intentionally not a wholesale `OverloadEntry` rewrite. Environment,
standalone, compiler-builtin, and UFCS candidates still share that compatibility
type. The packet first establishes an exact accepted-only downstream carrier so
those paths can be separated without adding an invalid optional ID or a magic
sentinel to every overload entry.

## Context

Issue 83 made accepted authority construction exact, but ordinary queries lost
that precision at the return boundary:

```blorp
pure func accepted_callable_find(...) -> Option[OverloadEntry]
```

The accepted table had already validated and retained a `CallableId`. Returning
only `OverloadEntry` forced inference to reconstruct semantic identity from the
legacy raw `def_id`:

```blorp
callable_id_from_reserved_graph_definition(entry.def_id)
```

Selective aliases had a second reverse join. To obtain the declaration's source
name, inference looked up the local alias in `ModuleView`, compared the binding's
module-path string with `entry.module_path`, and then selected either the
original name or local spelling. That work was unnecessary: the callable's
canonical definition row already owns both its exact ID and source spelling.

The distinction matters beyond this small amount of lookup work. A later phase
must not infer that a raw integer or a module path identifies a callable. Once a
call is accepted, semantic identity should flow forward as `CallableId`; source
strings should survive only as explicit presentation/debug payload until the
typed call representation can replace them with a cold-table handle.

## Invariants

1. A direct accepted lookup returns the exact `CallableId` stored in its table
   slot.
2. The returned source spelling comes from the callable's canonical definition
   row, not from import-path comparison.
3. Bare and qualified accepted calls construct `ResolvedGraphCallableCall`
   directly from that ID.
4. Accepted graph-call construction never derives an ID from
   `OverloadEntry.def_id`.
5. Bare accepted-call inference never reads `OverloadEntry.module_path`.
6. Selective aliases preserve their local callee spelling and their canonical
   source spelling as distinct values.
7. Existing newest-first overload selection and visibility order are unchanged.
8. Owner-local entries remain localized exactly as before.
9. Exact, owner-definition, Env, standalone, builtin, and UFCS APIs remain
   unchanged unless they consume the new direct binding.
10. No parallel lookup index, generic integer dictionary, sentinel ID, or
    compatibility fallback is introduced.

## Implementation Strategy

### 1. Lock the downstream contract first

The declaration boundary test requires an `AcceptedCallableBinding` with an
exact ID, canonical source spelling, and semantic payload. It also requires the
two direct query APIs to return that carrier and rejects graph-call construction
that inspects `entry.module_path` or calls the raw-ID conversion helper.

This millisecond test failed before production edits because no binding existed.

### 2. Project one binding from an already selected slot

After an accepted query has selected its canonical slot, it combines three
facts already owned by the accepted product:

```blorp
row ?= definition_table_callable_row(
	table.definition_table,
	callable_id_definition_id(slot.id),
)

Some({
	id = slot.id,
	source_name = row.name,
	entry = entry
})
```

The row lookup is checked by callable kind. The accepted table constructor has
already validated that the slot ID, source-name ID, module owner, and entry
agree, so this is projection rather than another semantic join.

### 3. Preserve owner localization

Unqualified lookup continues through `entry_at`, which localizes module-owned
signature types and clears their compatibility module path for the owner.
Qualified lookup continues to expose the canonical imported entry. The binding
wraps those pre-existing payload choices; it does not change type spellings or
visibility semantics.

### 4. Consume exact identity in inference

The accepted branch of `BareValueLookup` now carries the phase-specific binding.
Its resolved call is constructed as:

```blorp
resolved_call_from_graph_overload_entry(
	name.text,
	binding.source_name,
	binding.id,
	binding.entry,
)
```

Qualified function values and qualified callees use the same path. The graph
resolver accepts `CallableId` explicitly and cannot accidentally substitute a
raw definition integer.

### 5. Keep remaining compatibility work bounded

`OverloadEntry.module_path` is still used to mix graph, Env, standalone, and
builtin UFCS candidates and to recover source names for non-accepted Env
symbols. Removing it globally now would require a legitimate identity domain
for every one of those categories. That is the next boundary audit, not hidden
scope in this packet.

## Fast Feedback Loop

Start with the structural boundary test:

```bash
python3 -m unittest \
  blorp.test.compiler.stage_06_typecheck.support.test_declaration_boundary.\
DeclarationBoundaryTests.test_direct_accepted_callable_resolution_preserves_exact_identity
```

Then exercise accepted-table construction, alias selection, owner localization,
and normal body inference:

```bash
bin/blorp test \
  blorp/test/compiler/stage_06_typecheck/test_typecheck_decl.brp
```

The behavior fixture verifies that the local alias `selected` returns the exact
chosen overload ID while preserving canonical source name `choose`.

Once stable, run the changed-owner gate once:

```bash
scripts/compiler-check --changed
```

Finally retain one checked-bodies baseline/candidate pair. Unlike the accepted
stage, this stage executes direct callable lookup and body inference:

```bash
env BLORP_COMPILER_BENCHMARK_SKIP_BUILD=1 /usr/bin/time -lp \
	benchmarks/compiler_typecheck_phase_profile bodies 1 32 4 16 16 memory
```

Allocation, retained-object, allocated-byte, retired-instruction, and compiler
size signals are the primary guards. One-shot wall time and cycles are recorded
but are not used as latency claims.

## Acceptance Criteria

- [x] The structural test fails before the binding exists.
- [x] Direct accepted lookup returns `AcceptedCallableBinding`.
- [x] The binding preserves exact `CallableId` and canonical source spelling.
- [x] Bare and qualified accepted calls use the exact ID directly.
- [x] Accepted graph resolution does not reconstruct an ID from `def_id`.
- [x] Bare accepted resolution does not inspect a module-path string.
- [x] Selective overload aliases preserve exact target and source name.
- [x] All 142 declaration tests pass.
- [x] The changed-owner gate passes: two production sources, six focused
  suites, one declaration-boundary check, and zero failures.
- [x] Allocations, releases, retained objects, and allocated bytes are exactly
  neutral.
- [x] Retired instructions, RSS, peak footprint, and compiler size remain below
  the 1% guard in a workload that executes the changed path.
- [x] No wall-time claim is made from the single noisy sample.
- [x] Independent review reports no unresolved correctness issue and identifies
  the accepted-stage evidence gap corrected by the final bodies-stage pair.

## Measurements

Both checked-bodies samples produced semantic checksum `2057305071532051463`,
constructor checksum `-2142865109331864226`, 34 primary outputs, and zero
secondary outputs.

| Metric | Issue 83 baseline | Candidate | Change |
| --- | ---: | ---: | ---: |
| Allocations | 17,232 | 17,232 | 0.0000% |
| Releases | 12,924 | 12,924 | 0.0000% |
| Retained objects | 4,308 | 4,308 | 0.0000% |
| Allocated bytes | 350,408 | 350,408 | 0.0000% |
| Retired instructions | 6,265,136,939 | 6,274,672,205 | +0.1522% |
| Cycles | 1,766,913,472 | 1,785,861,678 | +1.0724% |
| Maximum RSS | 24,887,296 | 24,821,760 | -0.2633% |
| Peak footprint | 17,563,984 | 17,596,728 | +0.1864% |
| Compiler bytes | 19,423,920 | 19,424,368 | +0.0023% |

One-shot setup time moved from `424480` to `431841` microseconds and the measured
body-check window from `16431` to `18384` microseconds. Those signals are
retained as noisy observations, not performance claims. The relevant sample
shows exact allocation neutrality, retired instructions and memory within the
1% guard, and one-shot cycles within 1.08%. No repeated latency sampling was
performed.

Detailed evidence is retained in
[`compiler_direct_accepted_callable_identity_step2e_2026-09-11.md`](../../../benchmarks/results/compiler_direct_accepted_callable_identity_step2e_2026-09-11.md)
and its TSV companion.

## Next Packet

Separate accepted UFCS candidates from Env and standalone candidates so graph
UFCS selection can retain `CallableId` and `ModuleId` without using
`OverloadEntry.module_path` for origin grouping. Do not change the shared
compatibility type until each non-graph origin has an explicit representation.
