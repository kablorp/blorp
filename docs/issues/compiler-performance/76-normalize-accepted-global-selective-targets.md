# Normalize Accepted Global Selective Targets

**Status:** Complete

**Roadmap:** [Normalized Semantic Compilation Roadmap](NORMALIZED_SEMANTIC_COMPILATION_ROADMAP.md), Step 2e, fifth packet

**Depends on:** Accepted global visibility names (Issue 75) and graph selective definition targets (Issue 70)

## Outcome

Accepted-global visibility construction now consumes the exact `GlobalId`
already admitted by graph selective-import resolution. It no longer rebuilds an
imported global by joining an owner module path and original source name.

```blorp
record AcceptedVisibleGlobalBinding {
	source_name: String,
	target: GlobalId
}
```

The remaining string is the local source spelling used to enter the Issue 75
`SourceNameId` visibility index. It is a boundary projection, not target
identity. The target remains a compilation-derived value from import admission
through accepted-global lookup.

## Context

Issue 70 made ordinary graph selective imports retain exact `DefinitionId`
targets, and Issue 75 made accepted-global visibility retain integer source-name
keys. The adapter between them still discarded the exact target and reconstructed
it from two strings:

```blorp
{
	source_name = imported.local_name,
	owner_module_path = imported.module_path,
	original_name = imported.original_name,
}
```

The accepted-global authority then repeated a module-table path lookup followed
by a per-module string-name lookup. Besides the redundant work, that shape made
two strings appear authoritative after import resolution had already made an
exact semantic decision.

This packet removes only that join. Callable, type, constructor, and trait-method
targets continue through their existing authorities so the change stays small
and its feedback loop remains focused.

## Invariants

1. Only a `GraphSelectiveDefinitionBinding` can contribute an imported global.
2. Each contributed definition must validate as a `GlobalId` in the issuing
   `DefinitionTable`.
3. The global's table-owned `ModuleId` must equal the module recorded by the
   selective binding.
4. The accepted-global table, owner scope, and issuing definition table must
   share compilation provenance.
5. Exact target lookup must land on the same `GlobalId`; integer coincidence
   from a foreign table is rejected.
6. Private globals, duplicate local spellings, and uncataloged local spellings
   still fail closed.
7. Non-global definition IDs are ignored because their category authorities own
   them. Graph module aliases and trait-method bindings are likewise irrelevant.
8. Source-only tooling keeps standalone bindings syntax-only and contributes no
   imported globals. A view mixing graph and standalone bindings is rejected.

## Implementation Strategy

### 1. Specify exact-target and provenance behavior first

Extend the declaration-skeleton graph test before changing production code. A
cataloged alias targeting an exact local `GlobalId` must resolve after table
completion. The same numeric definition slot issued by a foreign table must be
rejected, as must an uncataloged alias.

This test is the shortest loop because it constructs the accepted-global product
directly and avoids parsing a multi-module import graph on every edit.

### 2. Project global targets from graph import rows

Add one narrow adapter:

```blorp
pure func accepted_visible_global_bindings(
	issuing_table: DefinitionTable,
	import_bindings: List[ImportBinding],
) -> Option[List[AcceptedVisibleGlobalBinding]]
```

For every selective definition ID, use the issuing table to ask whether it is a
global. Preserve only validated global targets and their admitted local spelling.
Do not guess category from spelling, declaration shape, or module contents.

### 3. Validate the issuing capability at construction

Pass the owner's graph `DefinitionTable` into `accepted_global_authority`. Require
it to share provenance with both the accepted-global table and the owner's
prepared scope. This makes the detached `GlobalId` meaningful and prevents equal
runtime integers from crossing compilation products.

### 4. Replace the source join with exact slot lookup

Delete the imported path lookup and original-name dictionary probe. Resolve the
target through the accepted-global table's `GlobalId` index, then verify the
resulting slot has the same ID and public visibility. The local spelling is
resolved once into the existing `SourceNameId` index.

### 5. Preserve the standalone tooling boundary

`accepted_global_authority_for_module` serves both graph-bound compilation and
source-only tooling. Branch on the module-view domain before invoking the graph
adapter: a purely standalone view builds local visibility with no imported
global targets, while a mixed graph/standalone view fails closed. A frontend
regression with an unresolved selective import protects this distinction.

### 6. Keep the next identity cuts separate

Do not combine this change with callable/trait authority migration or local-global
enumeration. The local-global side still enumerates a per-module string-name
index, and the adapter still receives a local spelling. Those are visible next
boundaries, but changing either would broaden ownership and measurement scope.

## Fast Feedback Loop

Use the direct authority fixture while iterating, then two integration suites:

```bash
bin/blorp test \
	blorp/test/compiler/stage_06_typecheck/test_declaration_skeleton_graph.brp
bin/blorp test \
	blorp/test/compiler/stage_06_typecheck/test_frontend_graph_typecheck.brp
bin/blorp test blorp/test/compiler/stage_06_typecheck/test_typecheck_decl.brp
```

The production selective-import smoke is:

```bash
bin/blorp check --no-format \
	blorp/benchmark/compiler/selective_import_graph_fixture/main.brp
```

Take one allocation-aware baseline/candidate pair after building each compiler:

```bash
env BLORP_COMPILER_BENCHMARK_SKIP_BUILD=1 /usr/bin/time -lp \
	benchmarks/compiler_typecheck_phase_profile accepted 1 32 4 16 16 memory
```

Only add samples if a deterministic counter crosses an investigation threshold.
The single short wall-time sample is retained as context, not a latency claim.

## Acceptance Criteria

- [x] Imported accepted-global target identity is `GlobalId`, not module path plus
  original source name.
- [x] The old imported path/name join is deleted from authority construction.
- [x] Graph import rows are filtered by definition kind through the issuing table.
- [x] Issuing-table, owner-scope, and accepted-table provenance is validated.
- [x] Foreign-table IDs, private targets, collisions, and uncataloged aliases fail
  closed.
- [x] Source-only standalone imports remain syntax-only; mixed-domain views fail
  closed.
- [x] Callable, constructor, type, trait-method, and standalone ownership is not
  broadened by this packet.
- [x] Direct authority, graph replay, and declaration integration suites pass.
- [x] The production selective-import fixture typechecks.
- [x] Managed allocations, releases, retained objects, and allocated bytes are
  exactly neutral in the isolated accepted-graph screen.
- [x] Retired instructions remain within the 1% investigation threshold; the
  noisy one-shot cycle sample is retained without a claim.
- [x] RSS, peak footprint, and compiler size remain within the 1% investigation
  threshold.
- [x] Post-Issue-78 reconciliation passes changed-owner checks across five
  production sources, fifteen focused suites, and one declaration-boundary
  check; the complete runtime gate passes 4,469/4,469.
- [x] Independent review reports no unresolved issue.

## Measurements

Both runs report checksum `-6362768653699369705`, constructor checksum
`-2142865109331864226`, 1,257 primary outputs, 65 secondary outputs, 136 accepted
constructor rows, and 353 accepted field rows.

| Metric | Merged baseline | Candidate | Change |
| --- | ---: | ---: | ---: |
| allocations | 278,251 | 278,251 | 0.00% |
| releases | 189,249 | 189,249 | 0.00% |
| retained objects | 89,002 | 89,002 | 0.00% |
| allocated bytes | 6,491,112 | 6,491,112 | 0.00% |
| instructions retired | 8,457,676,214 | 8,464,941,684 | +0.09% |
| cycles | 2,369,252,427 | 2,708,106,964 | +14.30% |
| maximum RSS | 40,058,880 | 40,042,496 | -0.04% |
| peak footprint | 33,571,152 | 33,505,592 | -0.20% |
| compiler executable bytes | 19,388,336 | 19,388,496 | +0.0008% |

After merging current `main`, the measured window changed from 164,020 to
195,393 microseconds and cycles moved +14.30%. Those one-shot values are visibly
host-sensitive and are not used as latency evidence. The stable mechanism
counters show neutral managed-memory work, a small peak-footprint improvement,
and a +0.09% instruction guard within the 1% investigation threshold. Raw
evidence is in
[`compiler_accepted_global_exact_targets_step2e_2026-09-11.md`](../../../benchmarks/results/compiler_accepted_global_exact_targets_step2e_2026-09-11.md).

The first changed-owner attempt exposed the separately tracked runtime emission
failure that could reach an unresolved `unknown` call kind. Issues 77-78 then
completed the accepted-global visibility and per-module identity boundary. The
reconciled tree retains this exact-target design and passes both the expanded
changed-owner selection and the complete runtime gate, so no string-based
target reconstruction fallback is required.

## Next Packet

Completed as
[`77-normalize-accepted-global-visibility-inputs.md`](77-normalize-accepted-global-visibility-inputs.md):
local and imported visibility now enter the authority as opaque
`SourceNameId + GlobalId` rows, and owner identity comes directly from the
prepared module scope.
