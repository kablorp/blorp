# Use Exact Constructor-Skeleton Lookup

**Status:** Implemented and accepted

**Roadmap:** [Stage 06 Latency Reduction Roadmap](STAGE06_LATENCY_REDUCTION_ROADMAP.md)

**Dependencies:** None

**Primary owners:**

- `blorp/src/compiler/stage_06_typecheck/headers/declaration_skeleton.brp`
- `blorp/src/compiler/stage_06_typecheck/headers/type_header_graph.brp`

## Objective

Resolve a parsed union variant to its existing `ConstructorId` without
projecting and scanning every constructor declaration in the graph.

This is a lookup change only. It must not change constructor identity,
duplicate detection, visibility, ordering, or type-header construction.

## Why This Is First

The compiler self-check contains approximately 19,666 declaration skeletons
and 3,429 union variants. The current type-header path calls
`declaration_skeleton_graph_constructor_skeletons` once per variant.

That helper:

1. scans every skeleton;
2. constructs a fresh list containing only constructor skeletons; and
3. returns the list to `constructor_for_variant`, which scans it again for one
   exact constructor.

The measured result was:

- 3,429 graph-wide constructor projections;
- approximately 67.4 million skeleton visits before the second scan;
- 5.34% direct self-time in the unoptimized production profile; and
- a 10-14% inclusive constructor/type-header construction envelope.

This work is redundant because `DeclarationSkeletonGraphRep` already maintains
the following name-chain index during validation:

```blorp
private record DeclarationSkeletonGraphRep {
	bound_graph: BoundModuleGraph,
	skeletons: List[DeclarationSkeleton],
	module_ids_by_skeleton: List[ModuleId],
	previous_same_name_index_by_skeleton: List[Int],
	latest_skeleton_index_by_name: Dict[String, Int]
}
```

The same index already backs exact type and trait lookup.

## Current Code Shape

The broad projection is:

```blorp
pure func declaration_skeleton_graph_constructor_skeletons(
	graph: DeclarationSkeletonGraph,
) -> List[ConstructorDeclarationSkeletonInfo]:
	var constructor_skeletons: List[ConstructorDeclarationSkeletonInfo] = []

	for skeleton in declaration_skeleton_graph_rep(graph).skeletons:
		match skeleton:
			ConstructorDeclarationSkeleton(id, visibility, parent_type_id, source):
				constructor_skeletons = constructor_skeletons.append({
					id = id,
					visibility = visibility,
					parent_type_id = parent_type_id,
					source = source,
				})
			_:
				void

	constructor_skeletons
```

The hot caller asks for only one result:

```blorp
private pure func constructor_for_variant(
	declaration_graph: DeclarationSkeletonGraph,
	parent_type_id: TypeId,
	variant: ParsedVariantDecl,
) -> Option[ConstructorId]:
	var result: Option[ConstructorId] = None

	for constructor in declaration_skeleton_graph_constructor_skeletons(declaration_graph):
		if (
			type_ids_equal(constructor.parent_type_id, parent_type_id)
			and constructor.source.name.text == variant.name.text
			and source_spans_equal(constructor.source.span, variant.span)
		):
			result = Some(constructor.id)
			break

	result
```

## Proposed API

Add one exact query beside the existing indexed type and trait queries:

```blorp
pure func declaration_skeleton_graph_find_constructor(
	graph: DeclarationSkeletonGraph,
	parent_type_id: TypeId,
	name: String,
	span: SourceSpan,
) -> Option[ConstructorDeclarationSkeletonInfo]
```

Its implementation should:

1. start at `latest_skeleton_index_by_name.get_or(name, -1)`;
2. walk only `previous_same_name_index_by_skeleton`;
3. accept only `ConstructorDeclarationSkeleton`;
4. compare the exact `parent_type_id` and source span;
5. return the existing ID, visibility, parent, and source payload; and
6. return `None` on any inconsistent index entry rather than inventing an ID.

Illustrative implementation shape:

```blorp
pure func declaration_skeleton_graph_find_constructor(
	graph: DeclarationSkeletonGraph,
	parent_type_id: TypeId,
	name: String,
	span: SourceSpan,
) -> Option[ConstructorDeclarationSkeletonInfo]:
	representation = declaration_skeleton_graph_rep(graph)
	var index = representation.latest_skeleton_index_by_name.get_or(name, -1)
	var result: Option[ConstructorDeclarationSkeletonInfo] = None

	while index >= 0 and result.is_none():
		match representation.skeletons.get(index):
			Some(ConstructorDeclarationSkeleton(id, visibility, parent, source)):
				if type_ids_equal(parent, parent_type_id) and source_spans_equal(source.span, span):
					result = Some({
						id = id,
						visibility = visibility,
						parent_type_id = parent,
						source = source,
					})
			_:
				void

		index = representation.previous_same_name_index_by_skeleton.get_or(index, -1)

	result
```

The final implementation should use local naming and helpers consistent with
the existing `declaration_skeleton_graph_find_module_name_kind` query. Do not
copy more lookup machinery than necessary.

`constructor_for_variant` then becomes a narrow projection:

```blorp
declaration_skeleton_graph_find_constructor(
	declaration_graph,
	parent_type_id,
	variant.name.text,
	variant.span,
).map(func(constructor): constructor.id)
```

## Identity and Correctness Requirements

The key is not merely the constructor name. Constructors with the same name may
exist:

- in different modules;
- under different union parents;
- in recovered or independently built source snapshots; and
- at different source locations.

The lookup must therefore use the exact existing `TypeId` owner and source
span. Do not infer the owner module from a canonical path or split a type name.
Do not key by `variant.name.text` alone. Do not manufacture a new
`ConstructorId` from the parsed variant.

The construction-time namespace check remains authoritative for duplicate
constructors. This issue only changes retrieval after a valid graph exists.

## Incremental Implementation Plan

### 1. Add exact query tests before the production change

Extend the declaration-skeleton tests with a graph containing:

- two modules defining the same constructor name;
- two union types in one graph using distinct constructor names;
- private and public unions;
- constructors at different spans; and
- a missing name, wrong parent, and wrong span.

Assert the exact returned `ConstructorId`, parent, visibility, and source span.
The wrong-parent and wrong-span cases must return `None`.

### 2. Add lookup-work observation

Extend the focused profile fixture or a test-only observer to report:

```text
constructor_lookup_requests
constructor_name_chain_candidates_visited
constructor_graph_wide_projections
constructor_projection_skeletons_visited
checksum
```

The observer must exercise the real query implementation. Do not retain a
production global counter.

### 3. Implement the indexed query

Reuse the existing name chain. Keep the old projection temporarily only while
the new query's tests are being written.

### 4. Cut over `constructor_for_variant`

Replace the broad list projection with the new exact query. Compare type-header
checksums and errors before deleting anything.

### 5. Delete the broad projection if unused

Repository-wide search currently finds no other production consumer of
`declaration_skeleton_graph_constructor_skeletons`. Delete it once the final
consumer is gone. Do not keep it as a fallback or debug path.

## Fast Feedback Loop

During implementation:

```bash
rg -n "declaration_skeleton_graph_constructor_skeletons|constructor_for_variant" \
  blorp/src blorp/test blorp/benchmark

bin/blorp test --timeout 180 \
  blorp/test/compiler/stage_06_typecheck/test_declaration_skeleton_graph.brp

bin/blorp test --timeout 180 \
  blorp/test/compiler/stage_06_typecheck/test_typecheck_phase_profile.brp

bin/blorp run --release \
  blorp/benchmark/compiler/compiler_typecheck_phase_profile.brp -- \
  headers 20 8 32 64 4 memory
```

Before merge:

```bash
scripts/compiler-check --changed
scripts/compiler-check --stage typecheck
```

Then run the alternating optimized compiler self-check described in the
roadmap.

## Measurable Acceptance Criteria

- [x] Exact lookup tests cover same-name/different-module, wrong-parent,
      wrong-span, visibility, and missing cases.
- [x] Successful type-header construction returns the same constructor IDs and
      semantic checksum as the baseline.
- [x] Compiler self-check diagnostics and output hash are identical.
- [x] `constructor_graph_wide_projections` falls from 3,429 to zero on the
      baseline self-check workload.
- [x] `constructor_projection_skeletons_visited` falls from about 67.4 million
      to zero.
- [x] Name-chain candidates visited are at least 90% below the former skeleton
      visits on the same workload.
- [x] No production call to
      `declaration_skeleton_graph_constructor_skeletons` remains; delete the
      function if it has no enumeration consumer.
- [x] Stage 01-06 retired instructions improve by at least 2% relative to the
      immediate parent, or the issue is rejected as too small for its added
      surface.
- [x] Median optimized self-check wall time does not regress by more than 2%.
- [x] Focused Stage 06 tests and compiler checks pass.

## Implementation Result

Implemented on 2026-09-08 against parent `3cb15e55c3d741a64ae1f362cb7d5928a170b375`.

`declaration_skeleton_graph_find_constructor` now starts from the existing
latest-by-name entry and walks only the same-name predecessor chain. It verifies
the indexed name, exact parent `TypeId`, and exact source span. An out-of-range
or otherwise incomplete index chain fails closed with `None`.

`constructor_for_variant` uses this exact query, and the graph-wide constructor
projection was deleted. Focused tests cover exact ID, parent, visibility, and
source preservation; same-named constructors in separate modules; and missing,
wrong-parent, and wrong-span queries.

The maintained mixed-header fixture reports:

| Metric | Result |
| --- | ---: |
| declaration skeletons | 1,153 |
| constructor lookup requests | 33 |
| same-name candidates visited | 33 |
| graph-wide projections | 0 |
| projected skeleton visits | 0 |

The former implementation would have visited `33 * 1,153 = 38,049` skeletons
just to construct the temporary projection lists. The exact query visits 33
candidates on the same fixture, a 99.913% reduction. Repeated observations
produce the same constructor checksum, `8938789772392276139`.

Five alternating optimized compiler self-check pairs used
`check --no-format blorp/src/main.brp`. Every run exited successfully and
produced byte-identical output with SHA-256
`c1758b804e292be62860bce968c8cee14b4b6a8fec681ff19c5318e5195c0963`.

| Metric | Baseline samples | Candidate samples | Median change |
| --- | --- | --- | ---: |
| wall seconds | 11.32, 11.75, 13.59, 12.46, 12.38 | 9.94, 10.43, 11.54, 11.49, 10.73 | -13.328% |
| retired instructions | 198,755,833,762; 198,731,511,510; 198,821,618,040; 198,773,608,483; 198,745,492,218 | 175,490,684,776; 175,528,335,295; 175,578,040,194; 175,622,756,584; 175,558,604,431 | -11.671% |
| elapsed cycles | 43,683,673,932; 43,413,570,051; 45,368,324,613; 43,800,483,514; 43,595,279,742 | 39,146,036,781; 39,561,123,001; 39,517,565,569; 39,566,430,836; 39,331,021,545 | -9.537% |
| peak RSS bytes | 835,764,224; 834,879,488; 837,058,560; 835,092,480; 835,534,848 | 834,355,200; 833,339,392; 833,830,912; 834,928,640; 834,338,816 | -0.143% |

Validation completed with 13/13 declaration-skeleton tests and 8/8 isolated
typecheck-profile tests. `scripts/compiler-check --changed` passed 2 sources,
6 suites, and 1 check; `scripts/compiler-check --stage typecheck` passed 44
sources, 34 suites, and 2 checks. All changed Blorp sources pass formatter
validation and `git diff --check`.

## Non-Goals

- Do not change declaration-skeleton construction or duplicate validation.
- Do not introduce a second constructor table unless the existing name chain
  fails the acceptance gate and a measured comparison justifies it.
- Do not change `ConstructorId`, `TypeId`, `DefinitionIndex`, module identity,
  visibility, or diagnostic wording.
- Do not retain the broad projection for compatibility.
- Do not combine this issue with accepted-graph caching or CTFE work.

## Expected Result

Type-header construction should become proportional to the small same-name
candidate chain for each variant, not the product of all variants and all graph
declarations. This is the highest-confidence mechanical improvement in the
profile.
