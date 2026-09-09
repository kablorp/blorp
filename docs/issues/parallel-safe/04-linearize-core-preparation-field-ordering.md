# Linearize Core Preparation Field Ordering

**Status:** Ready

**Kind:** Independent late-Core optimization

**Parallel owner boundary:**

- `blorp/src/compiler/stage_09_core/prepare.brp`
- `blorp/test/compiler/stage_09_core/test_core_prepare.brp`
- `blorp/benchmark/compiler/compiler_prepare_field_order_profile.brp`
- `blorp/benchmark/compiler/compiler_prepare_field_order_profile_fixture.brp`
- `benchmarks/compiler_prepare_field_order_profile`

Do not edit `match_projection.brp`, `reuse.brp`, shared Core benchmark
infrastructure, compiler orchestration, Stage 06, the C emitter, or the native
runtime in this issue.

## Objective

Replace the nested field search used to put heap- and value-record literals in
declaration order with one linear-time, pass-local ordering operation.

The prepared Core must remain byte-identical. Canonical field order, field
values, record kind, release policy, malformed-Core behavior, diagnostics, and
invariant failures do not change.

This issue intentionally does not index record or union declarations. Although
source inspection finds repeated declaration scans, the current native sample
directly admits field ordering only. Declaration lookup needs separate counters
and a later issue; bundling it here would combine two independently rejectable
optimizations in one owner.

## Evidence

Both record-ordering helpers currently search all supplied fields for every
declared field:

```blorp
for field_decl in record_decl.fields:
	match find_record_field(fields, field_decl.name):
		Some(field):
			ordered = ordered.append(field)
		None:
			found_all_fields = False
```

For `F` fields, successful ordering performs up to `F * F` spelling
comparisons. The same shape exists for value and heap records. A current
backend-only compiler sample attributed 1.74% of all self samples directly to
`order_heap_record_fields`, sufficient to admit a focused representation
change.

## Semantic Contract

The declaration's field list is the sole authority for canonical output order.
The supplied field list carries expression values and may arrive in source
order. Ordering must:

- return every supplied value exactly once in declaration order;
- fail closed when a declared field is missing;
- fail closed when an extra field is supplied;
- preserve the established malformed-Core behavior for duplicate supplied
  fields;
- keep same-spelling fields from unrelated record types independent; and
- never derive output order from dictionary enumeration.

Earlier semantic phases normally prevent malformed record literals. Focused
Core tests still construct malformed inputs, so preparation may not panic or
silently select a duplicate.

## Required Design

Build one temporary source-field index per record literal, then read it in
declaration order:

```blorp
private pure func order_record_fields(
	declared_field_names: List[String],
	fields: List[CoreRecordFieldValue],
) -> Option[List[CoreRecordFieldValue]]:
	fields_by_name ?= index_unique_record_fields(fields)

	var ordered: List[CoreRecordFieldValue] = []
	for field_name in declared_field_names:
		field ?= fields_by_name.get(field_name)
		ordered = ordered.append(field)

	if ordered.length() == fields.length():
		Some(ordered)
	else:
		None
```

The example describes responsibilities, not required syntax. Avoid allocating
`declared_field_names` if heap- and value-record declarations can pass their
field lists directly to narrow helpers.

`index_unique_record_fields` must detect a duplicate before insertion changes
authority. Unconditional `Dict.set` would introduce last-write-wins behavior
and is unacceptable.

Use one production algorithm for all record widths. Do not add a magic
small-record cutoff that selects the old nested scan. If dictionary overhead
makes ordinary four-field records slower enough to fail the acceptance gate,
reject the change and retain the current representation.

Mutable local accumulation is acceptable inside a pure function. It must rely
on normal COW uniqueness rather than a global mutable cache.

## Test-First Plan

Before changing the helpers, pin:

1. heap-record fields already in declaration order;
2. heap-record fields supplied in reverse order;
3. value-record fields in arbitrary order;
4. empty records;
5. one-field records;
6. missing supplied field fails closed;
7. extra supplied field fails closed;
8. duplicate supplied field behavior is explicit;
9. same field spelling in unrelated records remains isolated;
10. nested record literals are recursively prepared;
11. generic record field types and release policies remain unchanged; and
12. deep nested literals remain stack bounded.

Tests must compare complete prepared Core or its stable JSON. A test that only
checks `Some` versus `None` cannot detect incorrect field order or value
association.

Include an ambiguity-pressure test where two fields have the same value but
different names. This prevents a faulty implementation from appearing correct
because expressions compare equal.

## Lane-Owned Benchmark

Create the three uniquely named benchmark files in the ownership list. Do not
add a preparation mode to `compiler_core_pipeline_work_profile` or edit its
shared fixture and work-profile implementation.

Follow the established wrapper convention:

```text
benchmarks/compiler_prepare_field_order_profile \
  <plain|profile> <iterations> <record_count> <field_count>
```

The fixture independently scales record count and fields per record. Measure
field counts 1, 4, 16, 64, and 256. Include fields in reverse declaration order
to produce the stable worst-case search count, plus a representative shuffled
case.

Report:

```text
field_order_requests
declared_fields_visited
supplied_fields_indexed
field_linear_candidates_visited
field_index_reads
duplicate_fields_rejected
prepared_record_literals
elapsed_microseconds
allocations
releases
semantic_checksum
```

The checksum must depend on field names, values, final ordinals, record kind,
and release policies. It must be identical between baseline and candidate.

## Incremental Implementation

1. Add malformed, ambiguity-pressure, and canonical-order tests.
2. Add counters around the current nested search.
3. Record immediate-parent 1/4/16/64/256-field measurements.
4. Add `index_unique_record_fields` with direct unit coverage.
5. Cut over heap-record ordering.
6. Cut over value-record ordering through the same semantic operation.
7. Delete `find_record_field` if it has no remaining consumer.
8. Verify prepared Core and generated C remain byte-identical.
9. Collect paired focused measurements.
10. Rebase onto the latest main and collect stage-two late-Core and whole
    compile regression measurements.

Do not modify declaration lookup helpers during this work, even if they appear
adjacent in `prepare.brp`. Record them as follow-up evidence instead.

## Fast Feedback Loop

After every behavior change:

```bash
bin/blorp test --timeout 180 \
  blorp/test/compiler/stage_09_core/test_core_prepare.brp

benchmarks/compiler_prepare_field_order_profile plain 1 256 16
```

Use the one- and four-field cases after changes to dictionary construction:

```bash
benchmarks/compiler_prepare_field_order_profile plain 10 4096 1
benchmarks/compiler_prepare_field_order_profile plain 10 4096 4
```

Mechanical completion search:

```bash
rg -n "order_(heap|value)_record_fields|find_record_field" \
  blorp/src/compiler/stage_09_core/prepare.brp
```

Before review:

```bash
scripts/compiler-check --changed
bin/blorp test --timeout 180 \
  blorp/test/compiler/stage_09_core/test_core_pipeline.brp
scripts/test compiler-blorp
```

For production evidence, alternate optimized baseline and candidate compilers
on compilation of `blorp/src/main.brp` through C emission. Use `late_core`
timing after the phase-instrumentation lane lands. Whole-process time is a
regression guard, not the primary proof for this pass-local operation.

## Acceptance Criteria

- [ ] Heap- and value-record preparation share one semantic field-ordering
      operation or two thin adapters over one indexing primitive.
- [ ] Duplicate supplied names are rejected before dictionary insertion can
      select a winner.
- [ ] Declared field order remains the sole output-order authority.
- [ ] Field ordering performs one supplied-field indexing visit and one lookup
      per declared field.
- [ ] `field_linear_candidates_visited` is zero in candidate production work.
- [ ] Work grows linearly with supplied plus declared field count.
- [ ] Prepared Core JSON, generated C, diagnostics, and malformed-Core behavior
      remain unchanged.
- [ ] The 64- and 256-field cases improve median elapsed time by at least 30%.
- [ ] The representative mixed-width fixture improves by at least 10%.
- [ ] The common one- and four-field cases do not regress by more than 2% and
      do not materially increase allocations.
- [ ] Focused candidate allocations do not increase by more than 1% on the
      representative mixed-width fixture.
- [ ] Stage-two phase and whole-compile distributions are reported and show no
      repeatable regression outside paired uncertainty; a median regression
      greater than 2% is a failure.
- [ ] Core prepare, Core pipeline, changed compiler, and compiler-owned suites
      pass.

## Pitfalls

### Silent duplicate replacement

`Dict.set` is not validation. Check membership and preserve the current
fail-closed malformed-Core behavior before inserting a duplicate key.

### Replacing comparisons with persistent copying

Repeated immutable dictionary updates can allocate. Local unique accumulation
should permit COW mutation, but the allocation counter decides. Do not accept
an asymptotic improvement that increases representative work.

### Dictionary enumeration order

Never iterate `fields_by_name` to generate the result. Iterate the declaration
fields and query the index.

### Magic small-record paths

A field-count threshold would add two semantic implementations and a tuning
constant. Reject the index if one coherent algorithm cannot meet the common
case guard.

### Adjacent declaration scans

They are tempting, but not directly admitted by the current sample. Editing
them creates a second optimization with independent performance risk and makes
this lane conflict with a future preparation-index issue.

## Non-Goals

- Indexing union, heap-record, or value-record declarations.
- Sharing a Core-wide index across passes.
- Changing record literal syntax or semantic validation.
- Reordering declarations.
- Optimizing reuse or match projection.
- Stage 10 emitter changes.
