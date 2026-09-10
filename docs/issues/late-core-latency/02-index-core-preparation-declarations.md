# Index Core-Preparation Declarations

**Status:** Ready after the field-ordering acceptance decision is recorded

**Kind:** Pass-local late-Core latency and API-precision improvement

**Production owner:** `blorp/src/compiler/stage_09_core/prepare.brp`

**Dependency:** Decide commit `9ea9b1f3` before starting. If accepted, base this
work on that commit. If rejected, base it on the resulting `main`. The candidate
edits the same production helper and focused test suite.

## Objective

Replace repeated whole-program declaration scans in Core preparation with
narrow, immutable, pass-local indexes built once at each public preparation
entry point.

The final preparation pass must index value-record, heap-record, union, and enum
facts. The earlier dictionary-for-ownership pass needs only enum membership and
must build only that narrower product. Neither product may survive its input
Core epoch.

The change must preserve prepared Core, generated C, fallback behavior,
constructor identity, declaration order, and record field order exactly.

## Why This Work Exists

`prepare.brp` currently has four whole-declaration lookup families:

```blorp
find_value_record_decl(decls, name)
find_heap_record_decl(decls, name)
find_union_decl(decls, name)
has_enum_decl(decls, name)
```

Their recursive consumers include:

- `RecordExpr` and `RecordConstructExpr` for value and heap records;
- Option, stack-Result, boxed-Result, and generic union construction;
- nullary union-constructor recognition;
- exact union-variant resolution; and
- dictionary hash-constructor selection for a named enum key.

Every expression helper currently receives `List[CoreDecl]` even though it uses
that value as a read-only lookup database. The repeated-work shape is roughly:

```text
record requests × declarations
+ union requests × declarations
+ enum-membership requests × declarations
+ union-variant requests × variants
```

The native compiler sample attributed approximately 8.7% of late Core to final
preparation. Inclusive declaration lookup accounted for approximately 6.7% of
late Core across union, heap-record, and value-record helpers. The earlier
dictionary preparation accounted for another approximately 0.58% of late Core.
These samples overlap allocator, checkpoint, and TLS work; acceptance requires
fresh immediate-parent measurement.

## Two Distinct Core Epochs

The pipeline calls preparation code twice:

```text
projected DCE
→ consume specialization
→ static strings
→ record-update lowering
→ prepare_dict_literals_for_ownership   [epoch A]
→ Perceus
→ post-Perceus reuse
→ closure conversion
→ resource rewriting
→ fairness checkpoints
→ prepare_program                       [epoch B]
→ prepared reuse
```

The declaration lists at these boundaries must be treated as different
authorities even if many declarations happen to be unchanged. Build and
discard an index inside each public call. Do not store either index in
`CoreProgram` or `PreparedCoreProgram` and do not reuse match projection's
earlier layout.

Epoch A only asks whether a named dictionary key type is an enum. It should not
pay to index records and unions that it cannot query. Epoch B needs all four
declaration categories.

## Current Semantics To Preserve

### Declaration identity

At these Core boundaries, record, union, and enum types carry canonical Core
names rather than durable type-definition IDs. Use separate indexes keyed by
canonical name for value records, heap records, unions, and enums. Separate
maps preserve same-spelling declarations of different kinds.

The existing declaration helpers stop at the first same-kind match. Index
construction must preserve first-declaration precedence by inserting only an
absent key. Unconditional `Dict.set` would create last-write-wins behavior and
is prohibited.

### Constructor identity

`find_union_variant_by_reference` currently requires all of:

- the containing union selected by canonical type name;
- a source constructor name or that variant's `c_name`; and
- equal `Some(def_id)` values on the reference and variant.

A missing or mismatched definition ID fails closed. Do not introduce a
name-only fallback, generated-name identity, or cross-union constructor index.
Variant lookup is a separately measurable residual scan. This issue must count
and report it, but must not change it. Any exact definition-ID variant index is
a separate follow-up with its own admission and acceptance gates.

### Ordering and fallback

- `program.decls` remains the sole declaration-output order.
- Record declaration fields remain the sole canonical record-field order.
- Dictionary enumeration never determines output.
- Missing declarations retain their current `RecordExpr`,
  `RecordConstructExpr`, or unprepared fallback.
- `RecordConstructExpr.type_name` remains unchanged even if the type annotation
  names a different declaration; the index must not repair malformed Core.
- Builtin Option and Result constructor handling retains its explicit existing
  paths.

## Required Representation

Prefer stable ordinals into the one immutable declaration list:

```blorp
private record CorePreparationDeclIndex {
	decls: List[CoreDecl],
	value_records_by_name: Dict[String, Int],
	heap_records_by_name: Dict[String, Int],
	unions_by_name: Dict[String, Int],
	enum_names: Set[String]
}

private record DictOwnershipPrepareIndex {
	enum_names: Set[String]
}
```

Ordinal selectors must validate the retrieved declaration kind. That makes a
corrupt index fail closed rather than panic:

```blorp
private pure func indexed_union_decl(
	index: CorePreparationDeclIndex,
	name: String,
) -> Option[CoreUnionDecl]:
	ordinal ?= index.unions_by_name.get(name)
	decl ?= index.decls.get(ordinal)

	match decl:
		UnionDecl(union_decl):
			Some(union_decl)
		_:
			None
```

If direct-value storage measures better without increasing retained ownership,
it is acceptable. Record the comparison. Do not keep both ordinals and copied
declarations as parallel authorities.

Use a shared narrow helper to collect enum names if that removes duplication
between the two builders. Do not add a configurable universal builder with
boolean flags.

## Entry-Point Shape

Final preparation builds the full index exactly once:

```blorp
pure func prepare_program(program: CoreProgram) -> CoreProgram:
	index = build_core_preparation_decl_index(program.decls)
	{
		decls = program.decls.map(func(decl): prepare_decl(index, decl)),
		foreign_includes = program.foreign_includes
	}
```

The earlier entry builds only enum membership from its own input:

```blorp
pure func prepare_dict_literals_for_ownership(program: CoreProgram) -> CoreProgram:
	index = build_dict_ownership_prepare_index(program.decls)
	{ program |
		decls = program.decls.map(
			func(decl): prepare_dict_literals_for_ownership_decl(index, decl),
		)
	}
```

Rename recursive `decls` parameters to `index` or `context` throughout each
family. This is a cleanliness benefit: helper signatures state which facts are
available instead of accepting an arbitrary program list.

## Interaction With Field-Order Linearization

Commit `9ea9b1f3` replaces nested supplied-field search with one temporary
field dictionary per record literal. It intentionally leaves declaration
lookup unchanged.

After both changes, a record literal should perform:

```text
one program declaration lookup
+ one supplied-field indexing visit per field
+ one declaration-order field read per field
```

Resolve field ordering first. If accepted, preserve its
`index_unique_record_fields` helper and duplicate-field semantics, keep the
per-program declaration index separate from the per-literal supplied-field
index, and rerun its one- and four-field benchmarks as regression controls. If
rejected, preserve the current nested field-order behavior and use the existing
record-order semantic tests plus the declaration benchmark's one- and
four-field cases as regression controls; do not invoke branch-only artifacts.

## Test-First Plan

Extend `test_core_prepare.brp` after resolving the field-order branch:

1. each supported declaration kind at the beginning, middle, and end;
2. large unrelated declaration prefixes and suffixes do not change output;
3. identical spelling across value-record, heap-record, union, and enum kinds
   remains isolated;
4. duplicate same-kind declarations preserve first-match behavior;
5. missing declarations retain current fallback output;
6. `RecordConstructExpr` preserves a mismatched explicit `type_name`;
7. exact union definition ID succeeds;
8. wrong or absent union definition ID fails closed;
9. constructor `c_name` plus exact definition ID remains accepted;
10. same-spelling variants in unrelated unions remain isolated;
11. a named enum dictionary key selects generic hashing only when the enum is
    present;
12. custom, string, and floating dictionary hash selection remains unchanged;
13. deeply nested record/union expressions build no recursive indexes;
14. Epoch A and Epoch B each build from their own supplied program; and
15. complete prepared Core and generated C remain identical.

If field ordering was accepted, its tests for missing, extra, duplicate,
generic, nested, and release-policy-sensitive records remain mandatory. If it
was rejected, retain every record-order test present on the selected parent.

## Focused Benchmark

Add lane-owned files:

```text
blorp/benchmark/compiler/compiler_prepare_decl_index_profile.brp
blorp/benchmark/compiler/compiler_prepare_decl_index_profile_fixture.brp
benchmarks/compiler_prepare_decl_index_profile
```

Suggested interface:

```text
benchmarks/compiler_prepare_decl_index_profile \
  <plain|profile> <iterations> <unrelated_declarations> \
  <record_queries> <union_queries> <enum_queries> <variants_per_union>
```

Hold record width at one or four fields so the field-ordering algorithm does
not dominate the declaration measurement. Include distinct final-prepare and
dictionary-for-ownership modes only if both execute the production entry
points; never substitute a model of dictionary lookup for production code.

Report:

```text
full_index_builds
enum_only_index_builds
declarations_indexed
enum_declarations_indexed
value_record_lookup_requests
heap_record_lookup_requests
union_lookup_requests
enum_lookup_requests
declaration_index_reads
declaration_linear_candidates_visited
variant_lookup_requests
variant_linear_candidates_visited
prepared_record_literals
prepared_union_constructs
prepared_dict_literals
elapsed_microseconds
allocations
releases
retained_objects
semantic_checksum
```

The checksum must depend on declaration kind and order, selected declaration,
record field names and values, constructor source/C name and definition ID,
release policy, union payload shape, and dictionary hash-constructor choice.

Scale unrelated declarations through 64, 256, and 1,024 while holding query
count fixed, then scale each query family independently. Add a zero-query,
high-declaration control to expose unconditional index-construction cost.

## Incremental Implementation

1. Record the field-order acceptance decision. Rebase onto it if accepted;
   otherwise start from the resulting `main`.
2. Add work counters to the existing declaration and variant scans.
3. Record immediate-parent focused and compiler self-compilation baselines.
4. Add duplicate, fallback, exact-ID, cross-kind, and two-epoch tests.
5. Implement the enum-only Epoch A index and cut over dictionary preparation.
6. Implement the full Epoch B index with first-match semantics.
7. Cut over value-record and heap-record lookup.
8. Cut over union lookup.
9. Thread precise index types through recursive helpers.
10. Delete `find_value_record_decl`, `find_heap_record_decl`,
    `find_union_decl`, `has_enum_decl`, and raw declaration parameters used
    solely for lookup.
11. Report the retained variant-axis measurement and leave its implementation
    unchanged.
12. Verify complete Core and generated C identity. If field ordering was
    accepted, also verify its benchmark identity.
13. Collect alternating optimized measurements and run final review.

The counters in step 2 belong in the issue-owned profiler or behind
`@debug_only`. Inspect the optimized compiler artifact and confirm that normal
`prepare_program` and `prepare_dict_literals_for_ownership` execute no counter
mutation, allocation, or branch.

## Fast Feedback Loop

After every lookup-family cutover:

```bash
bin/blorp test --timeout 180 \
  blorp/test/compiler/stage_09_core/test_core_prepare.brp

benchmarks/compiler_prepare_decl_index_profile plain 1 256 128 128 128 8

scripts/compiler-check --changed
```

If field ordering was accepted, guard its performance on common widths:

```bash
benchmarks/compiler_prepare_field_order_profile plain 10 4096 1
benchmarks/compiler_prepare_field_order_profile plain 10 4096 4
```

Mechanical completion search:

```bash
rg -n "find_(value_record_decl|heap_record_decl|union_decl)|has_enum_decl" \
  blorp/src/compiler/stage_09_core/prepare.brp
```

Before review:

```bash
bin/blorp test --timeout 180 \
  blorp/test/compiler/stage_09_core/test_core_pipeline.brp
scripts/compiler-check --changed
scripts/test compiler-core-sanitize
scripts/test compiler-blorp
```

Only after the focused change is stable, build optimized parent and candidate
compilers and alternate normal compiler self-compilation with `--time-phases`.
Do not time a final-Core JSON dump.

## Expected Result

Query work changes from `O(Q * D)` to `O(D + Q)` for declaration lookup. A
separate future variant issue could change its component from `O(Qv * V)` to
`O(V + Qv)`.

The historical sample suggests a 3–7% reduction in late Core is plausible for
the full declaration change, plus a smaller improvement in Perceus input
preparation. The actual merge decision is based on immediate-parent counters
and paired timings.

## Definition Of Done

- Each preparation entry point builds exactly one product appropriate to its
  own epoch and query needs.
- Recursive helpers accept a semantic index/context rather than a raw
  declaration list used as a database.
- Every whole-declaration scan in `prepare.brp` is deleted.
- Variant traversal is retained with explicit counters and unchanged semantics.
- Record field ordering remains a distinct per-literal operation.
- Complete Core and generated C are identical. Field-order results are also
  identical to whichever accepted/rejected parent this issue uses.
- Focused and compiler-on-compiler results are recorded against the immediate
  parent.
- Correctness, performance, test-runner, and code-reviewer reviews pass.

## Acceptance Criteria

- [ ] One full index is built per `prepare_program` call.
- [ ] One enum-only index is built per
      `prepare_dict_literals_for_ownership` call.
- [ ] Each builder visits every relevant input declaration once.
- [ ] `declaration_linear_candidates_visited == 0` after construction.
- [ ] Work counters add no instructions or state to the normal optimized
      preparation entry points.
- [ ] Declaration-query work is independent of unrelated declaration count.
- [ ] Separate kind indexes preserve same-spelling cross-kind declarations.
- [ ] First-match duplicate behavior is explicit and tested.
- [ ] Exact union definition-ID and spelling validation is unchanged.
- [ ] No pass-local index crosses Perceus or another mutating pass boundary.
- [ ] The 1,024-declaration/high-query focused fixture improves median elapsed
      time by at least 30%.
- [ ] The representative mixed fixture improves by at least 15%.
- [ ] Zero-query and common small-program cases do not regress by more than 2%.
- [ ] Focused allocations and retained objects do not regress by more than 2%;
      peak RSS does not regress by more than 3%.
- [ ] Compiler self-compilation `late_core` median improves by at least 1%, or
      the issue is rejected.
- [ ] Other named phases show no repeatable regression above 1%, and whole
      compilation shows no repeatable regression above 2%.
- [ ] Prepared Core JSON, generated C bytes/SHA-256, diagnostics, and
      declaration order match the baseline. If field ordering was accepted,
      its benchmark checksum also matches.
- [ ] Core prepare, Core pipeline, Core sanitizer, changed compiler, and
      compiler-owned suites pass.

## Pitfalls

### Sharing across epochs

Epoch A and Epoch B are separated by multiple declaration-transforming passes.
Two cheap builds are correct; one retained index is not.

### Indexing facts the early pass cannot use

The dictionary-for-ownership pass needs enum membership only. Building record
and union maps there adds latency and ownership traffic without value.

### Last-write-wins drift

The old declaration helpers break on the first match. Insert only absent keys.

### Weak constructor identity

A variant definition ID does not replace containing-union identity or spelling
validation. Preserve all three checks.

### Field-index conflation

Program declarations and supplied record fields have different lifetimes and
duplicate rules. They must remain separate structures.

### Large-value copying

If dictionary values retain or copy complete declarations, use ordinals and
validate the declaration kind on retrieval.

## Non-Goals

- A universal or cross-pass Core index.
- Sharing match-projection indexes.
- Changing Core type identity.
- Changing record-field ordering.
- Changing constructor canonicalization or fallback behavior.
- Indexing union variants.
- Refactoring DCE, Perceus, reuse, closure conversion, or C emission.
- General traversal fusion or change-aware reconstruction.
