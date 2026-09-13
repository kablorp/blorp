# Normalize Accepted Trait-Definition Visibility

**Status:** Complete

**Roadmap:** [Normalized Semantic Compilation Roadmap](NORMALIZED_SEMANTIC_COMPILATION_ROADMAP.md), Step 2e, twenty-second packet

**Depends on:** Exact accepted trait selection and method visibility (Issues 87-92)

## Outcome and Context

Issue 92 normalized bare trait-method visibility, but accepted trait-definition
visibility still held `Dict[String, Int]` beside its accepted trait table.
Selective import binding already carried a validated `TraitId`; the authority
subsequently converted it back to a source-name string key and an untyped table
index. This packet closes that representation gap:

```blorp
private union AcceptedVisibleTraitBinding:
	AcceptedVisibleTraitDefinitionBinding(SourceNameId, TraitId)
	AcceptedVisibleTraitMethodBinding(SourceNameId, TraitMethodId)

private record AcceptedVisibleTraitRow {
	source_name_id: SourceNameId,
	trait_id: TraitId
}
```

The accepted authority retains a sorted `List[AcceptedVisibleTraitRow]` and
deletes `visible_trait_indices_by_name`. The semantic-name compatibility
dictionary remains intentionally distinct: obligations and graphless Env
queries still address trait names and can see ambient qualified-only traits.
The independent `visible_trait_indices` list still represents UFCS evidence;
it is not a duplicate lookup index for bare trait names.

## Invariants and Examples

1. `SourceNameId` identifies a compilation-local spelling; `TraitId` identifies
   the accepted semantic trait. Neither is derived by guessing from text later.
2. A graph selective import emits a row only after validating its definition
   identity, exact module owner, and admitted local source-name ID.
3. Local and explicit selective trait bindings establish bare-name visibility.
   Compiler-linked prelude traits fill only absent bare names. A qualified-only
   user trait can participate in UFCS without taking over that source name.
4. Stable sorting by source-name index followed by last-row replacement retains
   the old dictionary's last-writer behavior for duplicate source names.
5. A lower-bound search finds first, middle, and last rows; misses do not fall
   through to a semantically same-named qualified-only trait.
   A low-level duplicate selective alias retains the last exact trait identity.
6. Every row lookup validates its `TraitId` against the accepted table.
   A foreign visibility/table pairing still rejects the product.
7. Diagnostics and `trait_indices_by_semantic_name` may project spellings at
   their explicit compatibility boundary. They cannot redefine source-visible
   trait identity. No parallel numeric dictionary is introduced.

For example, an import `first_traits: First as alpha` contributes
`AcceptedVisibleTraitDefinitionBinding(alpha_source_name_id, first_trait_id)`.
An owner-local `Middle` contributes its own ID pair. Even when candidate
construction appends the local `Middle` before imported `alpha` and `zeta`, the
final compact rows are ordered by source-name ID; lookup of each alias resolves
its original accepted trait and module. A qualified-only `Hidden` remains a
miss in the bare-name relation.

## Implementation Strategy

1. Add a structural test requiring exact row and binding shapes, deletion of
   `visible_trait_indices_by_name`, and preservation of the separately named
   semantic compatibility index. It failed against the Issue 92 parent.
2. At accepted visibility construction, convert each validated selective
   trait's local spelling through the shared `SourceNameTable`. Reject a
   missing source identity instead of retaining a string fallback.
3. Construct local, selective, and compiler-linked prelude candidate rows in
   the former precedence order. Stable-sort by source-name index and replace
   equal adjacent rows with the last candidate. Do not add a second map.
4. Populate the existing semantic compatibility dictionary from final rows,
   projecting text once for that consumer, then add ambient direct traits only
   where no visible row claimed the name.
5. Route `accepted_trait_find`, `contains`, compiler fallback, module path,
   method-list projection, and authority metrics through the compact relation.
   Keep the public string parameters as source/compatibility entry points.
6. Exercise multi-row alias/local/qualified-only lookup, exact selected module
   and definition, duplicate alias precedence, rejected uncataloged alias,
   inherited and method collision behavior, and foreign provenance. The
   duplicate test uses the low-level accepted visibility API because the public
   module binder rejects duplicate source aliases before authority construction.

## Fast Feedback and Acceptance

```bash
python3 blorp/test/compiler/stage_06_typecheck/support/test_declaration_boundary.py
bin/blorp check --no-format blorp/src/main.brp
make -j1
bin/blorp test blorp/test/compiler/stage_06_typecheck/test_typecheck_decl.brp
scripts/compiler-check --changed
```

The structural check takes milliseconds, the compiler self-check around ten
seconds, and the declaration suite about thirteen seconds. Run the owner gate
once when the packet stabilizes. The retained accepted-stage counter screen
uses a single parent/candidate pair with its verbose profile filtered through
`rg`; do not repeat ten wall-time pairs or claim latency from one sample.

- [x] Old `Dict[String, Int]` authority and string import-binding shape fail
  the new structural contract before implementation.
- [x] Accepted selective trait bindings and retained rows use exact IDs; the
  old string dictionary is deleted, not paralleled.
- [x] Local, selective alias, compiler-prelude, qualified-only, collision,
  accepted method, and foreign-provenance behaviors remain covered.
- [x] First/middle/last visible trait lookups find their exact owners and the
  local `Middle` definition despite candidate construction order; a
  qualified-only trait is absent.
- [x] A duplicate source alias selects the later exact `TraitId`, and a
  selectively imported trait with an uncataloged alias rejects visibility.
- [x] Structural tests pass 49/49 and declaration tests pass 149/149.
- [x] `scripts/compiler-check --changed` passes 1 source, 7 suites, and 1
  special check in 16.95 seconds after the final test addition.
- [x] Semantic checksums and work counts match the committed parent; all
  measured resource and machine-work deltas remain below 2%.
- [x] Independent code and test reviews find no unresolved issue.

## Measurements and Rollback

The accepted-stage pair has +0.20% allocations, +0.04% instructions, +0.04%
retained objects (34 objects), +128 allocated bytes, and +0.085% executable
size. Cycles, RSS, and peak footprint decreased in this pair, but no timing or
memory improvement is claimed. See the
[measurement details](../../../benchmarks/results/compiler_accepted_trait_definition_visibility_rows_step2e_2026-09-12.md)
and [raw TSV](../../../benchmarks/results/compiler_accepted_trait_definition_visibility_rows_step2e_2026-09-12.tsv).
The representation removes the accepted bare-trait string dictionary and
retains one semantic-name compatibility index for genuinely different queries.

If a trait-heavy workload later crosses the investigation threshold, retain
that workload and optimize row construction/lookup directly. Roll back this
packet as one unit rather than reintroducing the old string dictionary beside
exact rows.

## Next Packet

Audit the remaining accepted `trait_indices_by_semantic_name` and
`implementation_indices_by_trait_name` compatibility consumers. Select one
bounded query family that already receives `TraitId` and move it to exact
table/implementation relations; do not erase graphless Env behavior or create
a second retained identity dictionary without a measured, explicit need.
