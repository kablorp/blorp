# Build The Source-Name Catalog Without A Growing Intermediate List

**Status:** Proposed; local graph-construction refactor with an identity-order gate

**Current state:** indexed-graph construction walks every prepared module and
threads one `List[String]` through `source_name_candidates_for_decl` and
`source_name_candidates_for_import`; `source_name_table` then walks that list
again to retain first-seen unique spellings. A compiler self-compile at
`f6af78c0` observed only 1,827 import-candidate calls, yet they consumed
2,182.032 ms self time, or about 1.194 ms per call. The complete source-name
table module used 3,110.518 ms self time.
**Next action:** Add construction counters to the production indexed phase and
measure candidate appends, duplicate candidates, copied prefix elements, and
final unique names. If the intermediate list is material, build the ordered
table during declaration traversal instead.
**Read first:** `blorp/src/compiler/stage_06_typecheck/graph/source_name_table.brp`,
`blorp/src/compiler/stage_06_typecheck/graph/indexed_graph.brp`, and
`blorp/test/compiler/stage_06_typecheck/test_indexed_graph.brp`.
**Fast loop:** Exercise the `indexed` stage of
`benchmarks/compiler_typecheck_phase_profile` with module count, declarations,
imports, imported symbols, constructors, and duplicate spellings varied
independently.
**Decision:** Preserve first-seen spelling order and every issued `SourceNameId`.
Ask for guidance before changing the opaque table API or allowing a builder to
escape indexed-graph construction.

## Objective

Remove a graph-wide growing candidate list and its second pass while retaining
one exact compilation-local spelling authority.

A likely local shape is an opaque or private construction state owned beside
`SourceNameTableRep`:

```blorp
private record SourceNameTableBuilder {
	spellings: List[String],
	id_by_spelling: Dict[String, Int]
}

private pure func add_source_name(
	builder: SourceNameTableBuilder,
	spelling: String,
) -> SourceNameTableBuilder:
	if builder.id_by_spelling.contains(spelling):
		builder
	else:
		-- Append once and assign the previous length as the stable ID.
		...
```

Thread one owned builder through module, declaration, import-symbol, and
constructor traversal. Finalize it once into `SourceNameTable`. Do not retain
both the candidate list and builder in production, and do not publish a mutable
or graph-independent spelling table.

## Invariants And Tests

- Preserve prepared-module order, declaration order, import order, selected
  symbol order, and constructor order.
- The first occurrence of a spelling determines its exact integer ID.
- Duplicate local/imported spellings remain idempotent at this catalog layer;
  later visibility or binding diagnostics retain their current authority.
- Preserve qualified-import default aliases, explicit aliases, source-extension
  stripping, private declaration recursion, trait methods, and exclusions for
  implementation bodies, fields, and parameters.
- Cover empty graphs, duplicate-heavy graphs, alias collisions, selective
  imports with constructors, foreign blocks, private declarations, and two
  module orders containing the same spellings.
- Verify both spelling-to-ID and ID-to-spelling projections, not only counts.

For example, a fixture whose traversal encounters `alpha`, `beta`, `alpha`,
`gamma` must still issue IDs `alpha=0`, `beta=1`, and `gamma=2`.

## Measurement

Extend the existing indexed-phase profile rather than timing parsing or later
inference. Report total candidates, unique candidates, duplicate probes,
candidate-list appends, modeled copied elements, dictionary insertions,
builder clones, allocations, instructions, elapsed time, and an ordered
`(id, spelling)` checksum.

```bash
benchmarks/compiler_typecheck_phase_profile indexed
bin/blorp test --timeout 180 \
  blorp/test/compiler/stage_06_typecheck/test_indexed_graph.brp
scripts/compiler-check --stage typecheck
scripts/test compiler-blorp
```

Use a duplicate-light width series and a duplicate-heavy series. Keep a tiny
one-module control so dictionary/build fixed costs cannot hide a regression.
For a final comparison use matched binaries and the same prepared graph; do not
compare independently parsed inputs.

## Acceptance And Rejection

Accept when the intermediate candidate list is removed, modeled prefix/second-
pass work falls by at least 80%, a compiler-shaped wide graph improves retired
instructions or allocations by at least 10%, the small control stays within
3%, exact ID/order checksums match, and compiler-self C is byte-identical.
Reject if the builder is repeatedly copied under value semantics, table order
changes, another component keeps the old candidate list alive, or improvements
come only from duplicate-heavy synthetic input.
