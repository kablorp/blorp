# Index Match-Projection Declarations

**Status:** Ready

**Kind:** Independent late-Core optimization

**Roadmap relationship:** This is the execution source of truth for the
match-projection portion of Slice 1 in
[Reduce Whole-Core Traversals And Superlinear Declaration Queries](../compiler-performance/14-reduce-core-program-traversal-work.md).

**Parallel owner boundary:**

- `blorp/src/compiler/stage_09_core/match_projection.brp`
- `blorp/test/compiler/stage_09_core/test_core_match_projection.brp`
- `blorp/benchmark/compiler/compiler_match_projection_profile.brp`
- `blorp/benchmark/compiler/compiler_match_projection_profile_fixture.brp`
- `benchmarks/compiler_match_projection_profile`

Do not edit `prepare.brp`, `reuse.brp`, the general Core pipeline, Stage 06, or
the native runtime in this issue.

## Objective

Build one validated match-projection declaration layout per input Core program
and replace repeated scans of `program.decls` and union variants with exact
indexed lookup.

The result must preserve the current match projection, diagnostics, identity,
and declaration ordering byte for byte. This is a data-structure correction,
not a new resolution policy.

## Evidence

A current backend-only native sample attributed 4.40% of all self samples to
`union_variant_field_type`. That helper reaches:

```blorp
private pure func find_union_decl(
	program: CoreProgram,
	name: String,
) -> Option[CoreUnionDecl]:
	var result: Option[CoreUnionDecl] = None

	for decl in program.decls:
		match decl:
			UnionDecl(union_decl):
				if union_decl.name == name:
					result = Some(union_decl)
					break
			_:
				void

	result
```

`find_union_variant` first repeats that declaration scan and then linearly
searches the selected union's variants. The same program-level declaration
facts are requested from recursive semantic accessor projection.

This work is deterministic and tied to one immutable input program. Repeating
the scan is not part of match semantics.

## Identity Contract

Core union declarations at this phase are named by canonical Core type name.
The layout may therefore key union declarations by that canonical name only if
construction explicitly rejects duplicate names or reproduces the existing
phase invariant that makes duplicates impossible.

Union variants carry optional definition IDs. Use exact `def_id` when the
semantic accessor or match case provides it. Do not silently replace an exact
identity with constructor spelling. Where the current input genuinely contains
only a canonical constructor name, keep that behavior explicit and validate
ambiguous spellings during layout construction.

Do not use generated C names as semantic identity.

## Proposed Representation

Use a private, opaque product owned by match projection. The exact types may
follow local conventions:

```blorp
private record MatchProjectionUnionLayout {
	declaration: CoreUnionDecl,
	variants_by_name: Dict[String, CoreUnionVariant],
	variants_by_def_id: Dict[Int, CoreUnionVariant]
}

opaque type MatchProjectionLayout = Dict[String, MatchProjectionUnionLayout]
```

If storing complete declarations in dictionary values causes material copying,
store stable declaration ordinals and retain the original immutable declaration
list as the sole owner:

```blorp
private record MatchProjectionUnionRef {
	decl_index: Int,
	variants_by_name: Dict[String, Int],
	variants_by_def_id: Dict[Int, Int]
}
```

Choose between these representations with allocation and RSS measurements.
Do not keep both as writable authorities.

Define a narrow `MatchProjectionLayout` that contains the existing
`CoreSpecializeLayout` value plus the match-projection declaration index. Do
not modify `specialize_layout.brp` or add fields to `CoreSpecializeLayout`:
that product is shared by other passes and lies outside this lane's owner
boundary.

## Required Operations

Expose semantic helpers rather than the dictionary representation:

```blorp
private pure func build_match_projection_layout(
	program: CoreProgram,
) -> Result[MatchProjectionLayout, MatchProjectionLayoutError]

private pure func match_projection_union(
	layout: MatchProjectionLayout,
	type_name: String,
) -> Option[CoreUnionDecl]

private pure func match_projection_variant(
	layout: MatchProjectionLayout,
	type_name: String,
	constructor_name: String,
	constructor_def_id: Option[Int],
) -> Option[CoreUnionVariant]
```

If the current public pass cannot return layout errors, prove duplicate
rejection at an earlier invariant boundary and make construction total. Do not
convert a duplicate into first- or last-write-wins behavior merely to avoid an
error type.

Build the layout exactly once at `project_backend_matches` entry and thread it
through recursive projection. Never rebuild it per function, match, accessor,
or field.

## Test-First Plan

Before changing production lookup, add focused tests for:

1. union declaration at the beginning, middle, and end of the program;
2. multiple unrelated unions with same-spelling variant names;
3. exact variant definition ID selecting the intended constructor;
4. mismatched definition ID failing closed rather than falling back by name;
5. generic union field-type substitution;
6. nested variant-field semantic accessors;
7. erased and ordinary variant-field accessors;
8. duplicate union-name behavior at the established invariant boundary;
9. duplicate constructor-spelling behavior within a union; and
10. deep semantic match projection remaining stack bounded.

Each behavior test must compare the complete projected Core value or stable
JSON, not merely report that projection succeeded.

## Focused Benchmark

Create the lane-owned `compiler_match_projection_profile` fixture and driver
listed above. Do not add a mode to `compiler_core_pipeline_work_profile` or edit
its shared Stage 09 work-profile implementation.

Follow the benchmark wrappers' established leading instrumentation argument.
The new driver interface should be:

```text
benchmarks/compiler_match_projection_profile \
  <plain|profile> <iterations> <declarations> <matches> \
  <variants_per_union> <accessor_depth>
```

The fixture must independently scale:

- number of unrelated declarations;
- variants per selected union;
- projected semantic matches;
- accessor depth; and
- generic type arguments.

Report:

```text
declaration_index_entries
variant_name_index_entries
variant_id_index_entries
union_lookup_requests
union_linear_candidates_visited
variant_lookup_requests
variant_linear_candidates_visited
projected_match_nodes
projected_accessor_nodes
elapsed_microseconds
allocations
releases
semantic_checksum
```

Use at least declaration counts 64, 256, and 1,024 with projected match count
held constant, then match counts 64, 256, and 1,024 with declaration count held
constant. The checksum must cover projected constructor tags, field types, and
accessor shapes so dead-code elimination cannot erase the work.

## Incremental Implementation

1. Add the benchmark counters while the linear helpers remain authoritative.
2. Record immediate-parent scaling and compiler self-compilation measurements.
3. Add layout construction and duplicate-identity tests.
4. Cut over union declaration lookup.
5. Cut over variant lookup, preserving exact-ID behavior.
6. Thread the one layout through every recursive projection path.
7. Delete `find_union_decl`, `find_union_variant`, and any scan counters.
8. Confirm generated Core and C are byte-identical.
9. Run paired optimized benchmark and stage-two compiler measurements.

Do not combine this with match lowering, DCE, specialization, or representation
changes.

## Fast Feedback Loop

During implementation:

```bash
bin/blorp test --timeout 180 \
  blorp/test/compiler/stage_09_core/test_core_match_projection.brp

benchmarks/compiler_match_projection_profile plain 1 256 256 8 4
```

After cutting over each lookup family:

```bash
scripts/compiler-check --changed
scripts/test compiler-blorp
```

For production evidence, build separate optimized baseline and candidate
compiler executables. Alternate compilation of `blorp/src/main.brp` through C
emission with `--no-format --no-embed-runtime`. Use the phase-timing result when
available; otherwise retain the coarse backend and whole-wall measurements.

## Acceptance Criteria

- [ ] One match-projection layout is built per input program.
- [ ] Union and variant lookup semantics use canonical or exact identity as
      documented; generated C names are not semantic keys.
- [ ] Duplicate identities are rejected or proven impossible at one explicit
      boundary. No dictionary insertion silently changes precedence.
- [ ] Production match projection contains no scan of `program.decls` for a
      union requested during recursive expression projection.
- [ ] Production match projection contains no repeated linear variant scan for
      indexed constructor identity.
- [ ] `union_linear_candidates_visited` and
      `variant_linear_candidates_visited` are zero after index construction.
- [ ] Index construction visits each declaration and variant once.
- [ ] On the declaration-scaling fixture, lookup work is independent of the
      number of unrelated declarations after construction.
- [ ] The focused 1,024-declaration/1,024-match case improves median elapsed
      time by at least 20%.
- [ ] Focused allocations do not increase by more than 2%; if ordinal storage
      materially reduces copies, use it.
- [ ] Stage-two phase and whole-compile distributions are reported. They do not
      show a repeatable regression outside paired uncertainty; a median
      regression greater than 2% is a failure.
- [ ] A fresh native sample demonstrates that the former 4.40% lookup leaf is
      immaterial or materially reduced.
- [ ] Projected Core JSON, generated C bytes, diagnostics, and stop/observation
      output are unchanged for existing fixtures.
- [ ] Match-projection tests, changed compiler checks, and compiler-owned suites
      pass.

## Pitfalls

### Name-only constructor lookup

Different unions routinely reuse constructor spellings. The containing union
identity is always part of the key. Prefer the constructor definition ID when
the input carries it.

### Rebuilding the index recursively

Passing `CoreProgram` into a helper that lazily constructs a dictionary merely
moves the repeated work. Construction belongs at pass entry.

### Copying whole declarations into every entry

Blorp values have value semantics. Measure whether dictionary values share or
copy declaration payloads. Use stable ordinals if retaining complete variants
causes allocation or RSS growth.

### Shared cross-pass index

Do not modify `prepare.brp` or `reuse.brp` to consume this layout. Their inputs
belong to later declaration epochs and sharing would require invalidation
semantics outside this issue.

### Accidental diagnostic changes

Dictionary enumeration order must not determine output. Preserve original
program order for traversal and diagnostics; use the index only for lookup.

## Non-Goals

- Changing semantic match behavior.
- Reordering Core declarations or variants.
- Introducing global mutable caches.
- Indexing every Stage 09 declaration query.
- Sharing a universal index with another pass.
- Optimizing the C emitter.
