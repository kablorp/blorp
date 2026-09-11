# Normalize Local Source-Name Identities

**Status:** Complete

**Roadmap:** [Normalized Semantic Compilation Roadmap](NORMALIZED_SEMANTIC_COMPILATION_ROADMAP.md), Step 2e, second packet

**Depends on:** Qualified-alias source-name identities (`a0ef13d4`)

## Outcome

Graph-backed module-local declaration lookup no longer retains a
`Dict[String, TopLevelNameKind]`. The indexed graph catalogs every spelling
that can enter that relation, and each graph `ModuleView` stores the accepted
rows as `Dict[Int, TopLevelNameKind]` keyed by the compilation's
`SourceNameId`. Standalone parser/typechecker helpers keep an explicitly
separate string-keyed relation.

This is a deliberately small Step 2e packet. It normalizes one complete query
family, preserves its collision semantics, and deletes the replaced graph
string map. It does not claim that source strings have left typechecking:
declaration prescan still receives parsed spellings, diagnostic results still
need text, and imported-name relations have not migrated yet.

## Context

Before this packet, Step 2e had one compilation-local spelling table, but it
cataloged only qualified aliases. Local declarations were registered and
queried through a second semantic index:

```blorp
private record ModuleViewRep {
	local_names: Dict[String, TopLevelNameKind]
}
```

That representation made a source string serve two jobs:

1. retained text for diagnostics and debugging; and
2. the key used by later semantic lookup and conflict detection.

The distinction matters. The compiler must retain a spelling projection while
diagnostics can refer to a declaration, but the accepted relation itself only
needs a stable compilation-local value. Repeated string keys enlarge each
per-module view, keep text-oriented equality and hashing in semantic paths,
and make it easier for tooling to reconstruct a subtly different namespace.

## Scope

The migrated rows are exactly the names registered by declaration prescan:

- records and unions;
- union variant constructors;
- builtin types and type aliases;
- functions and foreign functions;
- globals;
- traits; and
- declarations wrapped in `private`.

Record fields, function parameters, trait methods, implementation methods,
selective import aliases, and parser-error placeholders are intentionally not
local declaration rows. Qualified import aliases remain cataloged by the first
Step 2e packet.

## Target Representation

Graph and standalone storage are separate fields, with construction selecting
the valid domain:

```blorp
private record ModuleViewRep {
	source_name_table: Option[SourceNameTable]
	graph_local_names_by_source_name_id: Dict[Int, TopLevelNameKind]
	standalone_local_names_by_local_name: Dict[String, TopLevelNameKind]
}

private union LocalNameStorage:
	GraphLocalNameStorage(Int)
	StandaloneLocalNameStorage
```

`SourceNameId` remains opaque outside its owner. `ModuleView` uses the table
index only as the key type supported by `Dict`; callers cannot manufacture an
accepted graph spelling without first resolving it through the graph-owned
table.

Lookup retains a source-oriented compatibility boundary for current callers:

```blorp
pure func module_view_find_local_name(
	view: ModuleView,
	local_name: String,
) -> Option[TopLevelNameKind]
```

For a graph view, the function projects `String -> SourceNameId -> Int` and
queries the normalized relation. For a standalone view, it queries the
standalone string map. There is no cross-domain fallback.

## Invariants

1. The indexed graph owns the only source-name table used by its module views.
2. Every spelling admitted to the graph local-name relation was cataloged from
   the same parsed declaration inventory before registration starts.
3. Graph local-name storage is keyed only by that table's IDs.
4. Standalone local-name storage remains string-keyed and cannot be written
   through a graph-branded view.
5. An uncataloged graph declaration fails closed with
   `LocalNameInvalidSourceName`; it never enters a fallback string map.
6. Local-name, qualified-alias, and selective-import conflict precedence is
   unchanged.
7. Removing unqualified names clears both storage domains.
8. A graph view containing local-name rows cannot silently discard its source
   table and become a standalone view.

## Implementation Strategy

### 1. Make catalog admission authoritative

Move declaration spelling admission beside `SourceNameTable`, where qualified
alias admission already lives. `source_name_candidates_for_decl` exhaustively
matches parsed declaration variants and recursively unwraps private
declarations. `IndexedGraph` delegates to this function instead of maintaining
an alias-only classifier.

The test inventory exercises every admitted top-level kind and asserts that a
record field and trait method are absent. This guards the important negative
boundary as well as the accepted rows.

### 2. Split graph and standalone storage

Replace the single local-name map with graph-ID and standalone-string maps.
Represent the write choice with `LocalNameStorage` rather than a Boolean. This
makes it impossible for the shared registration helper to update an ambiguous
container.

### 3. Fail at the registration boundary

Add `module_view_register_local_name_for_graph`. It resolves the parsed
spelling through the active source-name table before performing any collision
checks. Missing catalog membership returns an explicit registration variant,
which the typecheck state converts to an internal diagnostic.

This is preferable to accepting the spelling and hoping a later lookup can
recover it: construction establishes the invariant once, and all later graph
queries can assume their keys came from the compilation domain.

### 4. Preserve standalone behavior explicitly

Keep `module_view_register_local_name` for standalone source-oriented callers,
but reject it when the view has graph source-name capability. The adapter that
converts an unused graph view to standalone mode must also reject a view that
already contains graph-local rows.

### 5. Select the domain from the view capability

Typecheck states used by standalone helpers may still own a `ModuleTable`, so
the presence of a module table does not identify a graph compilation. The
registration call therefore checks `module_view_has_graph_source_names` and
uses the graph path only when the view actually carries the graph spelling
capability.

This distinction was found by the narrow declaration suite: selecting from
`ModuleTable` presence broke 53 standalone tests. The corrected boundary keeps
module identity and graph spelling identity independent.

### 6. Migrate every query and collision consumer

Route direct local-name lookup and the local-name checks inside qualified and
selective import registration through one representation-aware helper. During
graph local-name registration, resolve the spelling once and reuse its integer
key for both the existing-local and module-alias collision probes. Delete the
old `local_names` field only after all reads and writes use the new relations.

## Fast Feedback Loop

The iteration order is intentionally short:

```bash
bin/blorp test blorp/test/compiler/stage_06_typecheck/test_indexed_graph.brp
bin/blorp test blorp/test/compiler/stage_06_typecheck/test_module_view.brp
bin/blorp test blorp/test/compiler/stage_06_typecheck/test_typecheck_decl.brp
bin/blorp test blorp/test/compiler/stage_06_typecheck/test_typecheck_state.brp
```

The first test proves catalog coverage and exclusions. The second proves
storage-domain and collision behavior. The third exercises production
declaration prescan, including the uncataloged-name failure. The fourth guards
state-level lookup behavior.

Once those are green, use one production smoke fixture and the manifest-owned
changed-owner gate:

```bash
bin/blorp check --no-format \
	blorp/test/compiler/stage_06_typecheck/infer_fixtures/infer/should_pass/qualified_alias_sort.brp

scripts/compiler-check --changed
```

Performance feedback uses one retained baseline/candidate pair, not repeated
wall-time sampling:

```bash
/usr/bin/time -lp benchmarks/compiler_typecheck_profile 1 8 32 64 mixed 4

/usr/bin/time -lp benchmarks/compiler_typecheck_phase_profile \
	bound 1 32 4 16 16 memory

/usr/bin/time -lp bin/blorp check --no-format \
	blorp/test/compiler/stage_06_typecheck/infer_fixtures/infer/should_pass/qualified_alias_sort.brp
```

The phase benchmark adds managed allocations, releases, retained objects, and
allocated bytes to the native instruction, cycle, RSS, and peak-footprint
screen. One-shot elapsed time is recorded for reproducibility but is not an
acceptance claim.

## Acceptance Criteria

- [x] The source-name catalog includes every spelling that can enter the local
  declaration relation and excludes non-local names.
- [x] Graph local-name storage is `Dict[Int, TopLevelNameKind]` keyed by the
  active `SourceNameTable` domain.
- [x] The replaced graph `Dict[String, TopLevelNameKind]` is deleted rather
  than retained as a parallel index.
- [x] Standalone local-name storage is separately named and string-backed.
- [x] Graph registration rejects uncataloged spellings and standalone writes.
- [x] Direct lookup and all import/local collision checks use the normalized
  graph relation.
- [x] Existing collision precedence and name-kind results are unchanged.
- [x] Focused graph, module-view, state, and declaration tests pass.
- [x] The production qualified-alias fixture still typechecks.
- [x] Mixed, isolated-phase, and production native/resource guards remain
  within the 1% investigation threshold.
- [x] The allocation-aware screen is understood: graph registration adds one
  transient allocation/release pair for its source-string-to-ID projection,
  while retained objects are unchanged and allocated bytes grow only 0.28%.
- [x] Changed-owner checks and independent review report no unresolved issue.

## Measurements

The immutable baseline is `a0ef13d4`, the first Step 2e packet. Checksums and
semantic work counts are identical. Mixed instructions increase 0.79%, while
its cycles, RSS, and peak footprint stay within 0.49%. The isolated phase stays
within 0.74%, production within 0.42%, and compiler size is effectively flat.
Mixed measured-window time happened to improve 0.36%, but a
single short elapsed sample is not used as evidence of speedup.

The allocation-aware bound-phase screen adds 1,158 allocations and releases,
exactly one for each graph-local registration in that workload. Catalog
construction happens before the memory counters reset. The measured cost is
the required `String -> SourceNameId` projection at registration; the resolved
index is reused for the subsequent local and alias probes. Retained objects
remain 1,148, and allocated bytes increase 264 bytes (0.28%). Eliminating that
last projection allocation requires the caller to carry `SourceNameId` from
admission into prescan; it is not evidence that the deleted per-module string
relation remains useful.

Raw commands, hashes, and counters are retained in
[`compiler_local_source_names_step2e_2026-09-11.md`](../../../benchmarks/results/compiler_local_source_names_step2e_2026-09-11.md).

## Next Packet

Continue Step 2e with one remaining visibility family whose consumers can move
together. Selective imported local names are the likely boundary, but the
packet should first prove that registration and resolution can carry a
`SourceNameId` without adding a second lookup or parallel index. Prefer passing
the ID from admission into registration so the pipeline progressively stops
re-projecting source strings. If that cannot be done within a small packet,
normalize the narrower caller boundary first rather than bulk-cataloging names
that still have string-only consumers.
