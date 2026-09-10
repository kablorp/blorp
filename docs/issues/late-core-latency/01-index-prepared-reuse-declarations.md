# Index Prepared-Reuse Declarations

**Status:** Ready

**Kind:** Pass-local late-Core latency and cleanup improvement

**Production owner:** `blorp/src/compiler/stage_09_core/reuse.brp`

## Objective

Build one private declaration layout at `rewrite_prepared_program` entry and
replace every recursive union-declaration scan in prepared reuse with exact
indexed lookup. Measure the remaining per-union variant scan independently and
leave any variant index to a separately admitted follow-up.

The pass must preserve declaration order, complete Core output, diagnostics,
and generated C byte for byte. This issue changes how immutable facts are
found; it does not change reuse decisions or ownership semantics.

## Why This Work Exists

Prepared reuse is the final pass in `run_post_closure_tail`:

```blorp
resource_program = rewrite_resource_program(program)
checked_program = insert_cooperative_checkpoints(resource_program)
prepared_program = CorePrepare.prepare_program(checked_program)
CoreReuse.rewrite_prepared_program(prepared_program)
```

At this point the declaration list is immutable for the duration of the pass.
Nevertheless, `reuse.brp` repeatedly scans it:

```blorp
pure func find_union_decl(
	decls: List[CoreDecl],
	name: String,
) -> Option[CoreUnionDecl]:
	var result: Option[CoreUnionDecl] = None

	for decl in decls:
		match decl:
			UnionDecl(union_decl):
				if union_decl.name == name:
					result = Some(union_decl)
			_:
				void

	result
```

`prepared_union_type_name` invokes that scan merely to answer whether a type is
a known union. `leaf_owns_managed_variant_fields` scans the declarations and
then scans the chosen union's variants. Both queries are reached recursively
while prepared expressions and match branches are rewritten.

The current native sample attributed approximately 5.4% of late Core to
prepared reuse. Inclusive stacks rooted in union lookup represented about
4.95% of late Core and approximately 91% of the prepared-reuse sample. These
figures overlap checkpoint and allocator leaves, so they are an upper bound,
not a promised speedup. They are strong evidence that the repeated scan is the
correct first target in this pass.

## Current Semantic Behavior To Preserve

Before editing production code, tests must pin these details:

- `UnionType(name)` is recognized only when a union with that canonical Core
  name exists.
- zero-argument `NamedType(name, [])` follows the same recognition path;
  parameterized `NamedType` does not.
- a constructor match is eligible only when the requested variant exists in
  the selected union;
- fields with a release-requiring policy must have the corresponding direct
  owned binding before the leaf owns every managed field;
- variants with the same spelling in different unions remain independent;
- declaration traversal and clone/reuse insertion order remain source ordered;
  and
- generated C names are not semantic type identity.

The current helpers walk the complete list and retain the last same-named
declaration or variant. Valid prepared Core is expected to have unique
canonical union names and unique variant names within a union, but an index may
not silently turn that implementation accident into an undocumented rule.

There is currently no late-Core invariant that rejects duplicate union names.
The index must therefore preserve last-match behavior explicitly. Name the
construction operation so replacement is deliberate, cover it with a duplicate
test, and do not keep a fallback scan.

## Required Representation

Use a private product owned only by prepared reuse:

```blorp
private record PreparedReuseLayout {
	variants_by_union_name: Dict[String, List[CoreUnionVariant]]
}
```

Construction traverses declarations in source order and explicitly replaces a
previous entry when it sees a later union with the same name:

```blorp
private pure func record_last_prepared_reuse_union(
	by_name: Dict[String, List[CoreUnionVariant]],
	union_decl: CoreUnionDecl,
) -> Dict[String, List[CoreUnionVariant]]:
	-- Deliberately preserve the previous full scan's last-match behavior.
	by_name.set(union_decl.name, union_decl.variants)
```

The named helper and duplicate test prevent `Dict.set` replacement from being
an accidental policy. The value stores only the variant list consumed by this
pass rather than a complete union declaration. Do not expose the representation
outside `reuse.brp`.

The layout deliberately does not contain `SourceAlias`. Alias state is built
and updated while recursively analyzing reuse; it has a different lifetime and
identity contract. Conflating it with immutable declarations would turn this
bounded change into a broader reuse redesign.

## Required Operations

Expose narrow semantic operations rather than direct dictionary access:

```blorp
private pure func build_prepared_reuse_layout(
	program: CoreProgram,
) -> PreparedReuseLayout

private pure func prepared_reuse_union(
	layout: PreparedReuseLayout,
	type_name: String,
) -> Option[List[CoreUnionVariant]]

private pure func prepared_reuse_union_type_name(
	layout: PreparedReuseLayout,
	typ: CoreType,
) -> Option[String]
```

The code is illustrative. Follow local visibility and naming conventions.

Build the layout exactly once:

```blorp
pure func rewrite_prepared_program(program: CoreProgram) -> CoreProgram:
	layout: PreparedReuseLayout = build_prepared_reuse_layout(program)
	var rewritten: List[CoreDecl] = []

	for decl in program.decls:
		rewritten = rewritten.append(rewrite_prepared_decl(layout, decl))

	{ program | decls = rewritten }
```

Every recursive helper that currently accepts `decls` solely for lookup should
accept `PreparedReuseLayout`. Passing the layout makes the dependency precise
and prevents a future helper from reintroducing an arbitrary declaration scan.

## Identity And Epoch Contract

This index belongs to the output of `CorePrepare.prepare_program`. It must not
be built before preparation and retained across preparation, because
preparation reconstructs expressions and canonicalizes constructor forms. It
must not be shared with match projection: DCE, consume specialization,
Perceus, post-Perceus reuse, closure conversion, resource management,
fairness, and Core preparation all intervene.

At the prepared-reuse boundary, union type references carry canonical type
names and match branches carry canonical constructor names. Keying those two
specific facts by name is permitted only after the invariant is pinned. If a
future Core representation carries definition IDs here, migrate the lookup to
those IDs rather than inventing a name heuristic.

## Test-First Plan

Add or strengthen focused tests before changing lookup:

1. union declaration at the beginning, middle, and end of `program.decls`;
2. many unrelated declarations surrounding one requested union;
3. `UnionType` recognition;
4. zero-argument `NamedType` recognition;
5. parameterized `NamedType` rejection;
6. missing union fails closed;
7. missing variant fails closed;
8. same-spelling variants in two unions do not cross-resolve;
9. managed and unmanaged variant fields preserve release decisions;
10. direct owned, borrowed, nested, and wrong-index bindings preserve the
    existing decision;
11. duplicate union and duplicate variant names preserve explicit last-match
    behavior;
12. declaration and inserted-reuse ordering remains identical; and
13. a deeply nested prepared match remains stack bounded.

Tests should compare the complete rewritten Core value or stable JSON. Boolean
helper tests alone cannot detect reordered declarations, changed release
policies, or an incorrect constructor selection.

## Focused Benchmark

Add lane-owned files rather than extending a shared benchmark:

```text
blorp/benchmark/compiler/compiler_prepared_reuse_decl_profile.brp
blorp/benchmark/compiler/compiler_prepared_reuse_decl_profile_fixture.brp
benchmarks/compiler_prepared_reuse_decl_profile
```

Suggested interface:

```text
benchmarks/compiler_prepared_reuse_decl_profile \
  <plain|profile> <iterations> <declarations> <union_count> \
  <variants_per_union> <prepared_match_count>
```

Scale unrelated declaration count independently from lookup count. Include a
representative mixed fixture and a worst-case fixture where the requested union
and variant are last in source order. The timed window must invoke production
`rewrite_prepared_program` on the original prepared input for every iteration;
do not time a modeled lookup or feed one iteration's rewritten output into the
next.

Report at least:

```text
layout_builds
declarations_indexed
union_entries_written
union_lookup_requests
union_linear_candidates_visited
variant_lookup_requests
variant_linear_candidates_visited
prepared_nodes_visited
rewritten_reuse_sites
elapsed_microseconds
allocations
releases
semantic_checksum
```

The checksum must depend on declaration order, selected union and variant
identities, release policies, field indexes, and rewritten expression shape.

Use declaration counts 64, 256, and 1,024 with lookup count held constant, then
lookup counts 64, 256, and 1,024 with declaration count held constant. The
candidate's post-construction lookup work must not grow with unrelated
declarations.

## Incremental Implementation

1. Add lookup counters around the current helpers and record the immediate-
   parent scaling curve.
2. Add the semantic and malformed-input tests above.
3. Implement layout construction and direct layout-operation tests.
4. Cut over union-presence and union-variant-list queries.
5. Measure and report the residual variant scan without changing it.
6. Thread `PreparedReuseLayout` through recursive helpers.
7. Delete `find_union_decl` and parameters carrying raw declarations solely
   for that helper.
8. Remove the unused declaration/context parameter from
   `rewrite_prepared_union_result` and its internal recursive calls.
9. Inspect generated Core and generated C for exact identity.
10. Collect alternating focused benchmark pairs.
11. Build the candidate compiler once and collect alternating compiler-on-
    compiler `late_core` measurements.
12. Run the integrated gates and obtain performance and correctness review.

Each cutover should typecheck and pass the focused benchmark before proceeding.
Do not combine this issue with alias indexing or change-aware reconstruction.

## Fast Feedback Loop

During the representation change:

```bash
bin/blorp test --timeout 180 \
  blorp/test/compiler/stage_09_core/test_core_reuse.brp

benchmarks/compiler_prepared_reuse_decl_profile plain 1 256 64 8 256

scripts/compiler-check --changed
```

If the focused reuse suite has a more specific prepared-reuse owner, use that
suite and record its exact path in the implementation report. Use `rg` after
each cutover:

```bash
rg -n "find_union_decl|find_union_variant|List\[CoreDecl\]" \
  blorp/src/compiler/stage_09_core/reuse.brp
```

Remaining `List[CoreDecl]` parameters are acceptable only when they enumerate
declarations or belong to the earlier post-Perceus rewrite. Explain every
remaining match in the implementation report.

Once local work is stable, build optimized baseline and candidate compilers and
alternate:

```bash
<compiler> compile --no-format --no-embed-runtime --time-phases \
  -o <temporary-output.c> blorp/src/main.brp
```

Do not use `--stop-after=final` for timing: serializing the very large final
Core JSON contaminates the late-Core window.

## Expected Result

The mandatory lookup component changes from approximately `O(Q * D)` to
`O(D + Q)`, where `D` is declaration count and `Q` is union lookup requests.
A separately admitted future variant index could change its component from
`O(Qv * V)` to `O(V + Qv)`; that change is not part of this issue.

The historical profile suggests a 2–5% late-Core reduction is plausible. That
is a directional forecast, not an acceptance substitute. Allocation may rise
slightly during one-time index construction but should fall overall by avoiding
repeated list traversal and temporary ownership traffic.

## Definition Of Done

- Prepared reuse builds one private declaration layout per invocation.
- All recursive union-declaration lookup uses that layout.
- Raw declaration lists remain only where source-order enumeration is needed.
- The prepared-union-result recursion no longer carries a context it does not
  read.
- The superseded production scan helper is deleted; issue-owned benchmark
  counters remain available without adding work to the normal compiler path.
- Duplicate identity behavior is explicit and tested.
- Complete prepared Core and generated C are unchanged.
- Focused and compiler-on-compiler measurements are recorded against the
  immediate parent.
- The issue passes correctness, performance, test-runner, and code-reviewer
  review.

## Acceptance Criteria

- [ ] `layout_builds == 1` for one `rewrite_prepared_program` invocation.
- [ ] Index construction visits every declaration once.
- [ ] Source audit finds no query-time loop over program declarations; the
      focused benchmark reports `union_linear_candidates_visited == 0`.
- [ ] Union lookup work is independent of unrelated declaration count.
- [ ] Variant candidate visits are measured independently and reported without
      changing the variant algorithm.
- [ ] Canonical union/variant identity and explicit last-match duplicate
      behavior are tested.
- [ ] No fallback declaration scan remains in prepared reuse.
- [ ] The 1,024-declaration/1,024-request focused case improves median elapsed
      time by at least 20%.
- [ ] The representative production-shaped direct-pass fixture improves
      median elapsed time by at least 5%.
- [ ] Focused allocations do not increase by more than 2%; retained objects,
      allocator bytes, and peak RSS do not regress by more than 3%.
- [ ] Compiler self-compilation `late_core` shows no repeatable regression
      above 2%; report the point estimate even when it is below the noise
      floor.
- [ ] No other named compiler phase shows a repeatable regression above 1%,
      and whole compilation shows no repeatable regression above 2%.
- [ ] Rewritten Core JSON, generated C bytes, generated C SHA-256, diagnostics,
      and declaration order match the baseline.
- [ ] Focused reuse tests, `scripts/compiler-check --changed`, and
      `scripts/test compiler-blorp` pass.

## Pitfalls

### Accidental duplicate policy

The old scans retain the last match. Preserve that policy in a named
source-ordered insertion helper and a focused duplicate test.

### Indexing the wrong epoch

An index from match projection or preparation input is stale here. Build from
the exact `CoreProgram` supplied to `rewrite_prepared_program`.

### Copying large declarations

Blorp has value semantics. If storing `CoreUnionDecl` in multiple dictionary
values creates measurable ownership traffic, use stable ordinals into one
immutable source list.

### Reordering output

Never enumerate the dictionary to rebuild program declarations or variants.
The source list remains the ordering authority.

### Expanding into alias state

`SourceAlias` is flow-sensitive state. It is not part of this immutable layout
and remains out of scope.

## Non-Goals

- Sharing an index with match projection or Core preparation.
- Changing reuse eligibility or ownership policy.
- Indexing `SourceAlias`.
- Indexing union variants; the retained variant-axis measurement may admit a
  separate follow-up.
- General change-aware Core reconstruction.
- Modifying DCE, Perceus, closure conversion, fairness, or C emission.
- Introducing a universal Core declaration catalog.
