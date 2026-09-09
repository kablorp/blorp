# Index Type-Home State

**Status:** Dispatched to
[the parallel-safe execution issue](../parallel-safe/03-index-type-home-state.md),
which is now the implementation source of truth.

**Roadmap:** [Stage 06 Latency Reduction Roadmap](STAGE06_LATENCY_REDUCTION_ROADMAP.md)

**Dependencies:** Issue 64 for serial performance attribution

**Primary owners:**

- `blorp/src/compiler/stage_06_typecheck/state.brp`
- `blorp/src/compiler/stage_06_typecheck/infer.brp`
- `blorp/src/compiler/stage_06_typecheck/headers/type_resolution.brp`
- `blorp/src/compiler/stage_06_typecheck/headers/type_header_install.brp`
- `blorp/src/compiler/stage_06_typecheck/modules/module_binding.brp`

## Objective

Replace the linear `List[TypecheckTypeHome]` representation with one private,
indexed authority shared by header resolution and body inference.

The change must preserve the existing precedence rule:

- the first imported home for a visible name is retained;
- another imported home cannot replace it; and
- a local declaration replaces an imported home with the same visible name.

## What a Type Home Represents

`TypecheckTypeHome` is transient provenance for a spelling installed into one
module's typechecking environment:

```blorp
record TypecheckTypeHome {
	type_name: String,
	module_path: String,
	imported: Bool
}
```

It does not own nominal definition identity. That remains on `TypeId` and in
the graph/header products. The type-home entry answers narrowly scoped
questions such as:

- where did this visible type spelling come from?;
- is it imported or local?; and
- should an imported alias spelling be qualified with its source module?

Because there can be only one active answer per visible name, a list is a poor
representation of the semantic model.

## Current Cost

`TypecheckState` and `InferModuleFacts` both carry:

```blorp
type_homes: List[TypecheckTypeHome]
```

Lookup scans the list:

```blorp
private pure func find_type_home_entry(
	type_homes: List[TypecheckTypeHome],
	type_name: String,
) -> Option[TypecheckTypeHome]:
	type_homes.find(func(home): home.type_name == type_name)
```

Recording first scans and then, for a local replacement, reconstructs the
whole list:

```blorp
match typecheck_state_find_type_home(state, type_name):
	Some(_):
		if imported:
			state
		else:
			{ state | type_homes = replace_type_home(...) }
	None:
		{ state | type_homes = state.type_homes.append(...) }
```

`infer.brp` contains a second linear lookup over the copied module facts. Type
resolution also nests imported-name scanning with type-home scanning.

The compiler self-check measured approximately:

- 214,899 `typecheck_state_record_type_home` calls;
- 215,108 `find_type_home_entry` calls;
- 147,640 additional `infer_facts_find_type_home_entry` calls;
- 5.02% optimized inclusive time in recording; and
- 3.83% optimized inclusive time in type-home lookup.

These percentages overlap, but the operation counts establish the repeated
linear work.

## Proposed Representation

Make the one-entry-per-visible-name invariant explicit:

```blorp
private struct TypeHomeEntry {
	module_path: String,
	imported: Bool
}

opaque type TypeHomeIndex = Dict[String, TypeHomeEntry]

private TYPE_HOME_INDEX_EMPTY: TypeHomeIndex =
	into_opaque TypeHomeIndex({})
```

Expose semantic operations rather than the dictionary representation:

```blorp
pure func type_home_index_empty() -> TypeHomeIndex

pure func type_home_index_module_path(
	index: TypeHomeIndex,
	type_name: String,
) -> Option[String]

pure func type_home_index_is_imported(
	index: TypeHomeIndex,
	type_name: String,
) -> Bool

pure func type_home_index_record(
	index: TypeHomeIndex,
	type_name: String,
	module_path: String,
	imported: Bool,
) -> TypeHomeIndex

pure func type_home_index_is_empty(index: TypeHomeIndex) -> Bool
```

Illustrative precedence logic:

```blorp
pure func type_home_index_record(
	index: TypeHomeIndex,
	type_name: String,
	module_path: String,
	imported: Bool,
) -> TypeHomeIndex:
	entries = type_home_index_rep(index)

	match entries.get(type_name):
		Some(_):
			if imported:
				index
			else:
				into_opaque TypeHomeIndex(entries.set(type_name, {
						module_path = module_path,
						imported = False
					}))
		None:
			into_opaque TypeHomeIndex(entries.set(type_name, {
					module_path = module_path,
					imported = imported
				}))
```

The visible spelling exists only as the dictionary key; the entry does not
duplicate it. This makes key/entry disagreement unrepresentable. Keep the
representation and entry type private so all updates preserve precedence.

## Do We Need Ordered Storage?

Current production searches find no semantic consumer that needs to enumerate
type homes in insertion order. The list is scanned only to find an entry by
name. Tests and benchmarks that compare the list are observing an
implementation detail.

Therefore the initial implementation should use only the dictionary. Do not
retain a parallel ordered list speculatively. If a real source-order consumer
is discovered during implementation, document it and expose a derived ordered
view with a test; do not leave two writable authorities.

## Type-Resolution Cutover

`resolve_imported_type_aliases_from_bindings` currently accepts the list and
performs a nested loop:

```blorp
for binding in imported_names:
	if binding.local_name == name:
		for home in type_homes:
			if home.type_name == name and home.imported:
				...
```

After the cutover, find the imported binding as today, then make one indexed
type-home query:

```blorp
if type_home_index_is_imported(type_homes, name):
	match type_home_index_module_path(type_homes, name):
		Some(module_path):
			Some(canonical_module_type_name(module_path, binding.original_name))
		None:
			None
else:
	None
```

This issue does not need to redesign `ImportedNameBinding`. If that list later
becomes independently measurable, it should receive its own issue.

## Incremental Implementation Plan

### 1. Pin precedence semantics with tests

Before changing the representation, add or strengthen tests for:

- empty lookup;
- first imported insertion;
- repeated identical import;
- conflicting second imported home;
- local replacement of an imported home;
- repeated local insertion;
- local entry followed by an imported insertion;
- same type name in independent states; and
- canonical alias resolution using the original imported name and home path.

Assert both the selected module path and `imported` flag.

### 2. Add focused metrics

Extend a test-owned profile observer with:

```text
type_home_record_requests
type_home_find_requests
type_home_linear_candidates_visited
type_home_replacement_list_rebuilds
type_home_index_reads
type_home_index_writes
semantic_checksum
```

Capture the immediate-parent compiler self-check baseline.

### 3. Introduce `TypeHomeIndex`

Add the opaque type, private entry without a duplicate `type_name`, and semantic
operations. Test them directly while `TypecheckState` still uses the list. This
makes precedence failures local and easy to diagnose.

### 4. Cut over `TypecheckState`

Change `type_homes` to `TypeHomeIndex`, initialize it with the empty smart
constructor, and route all state lookup/record functions through the index.
Delete `replace_type_home` and `find_type_home_entry` when unused.

### 5. Cut over immutable inference facts

Change `InferModuleFacts.type_homes` to the same `TypeHomeIndex`. Copy/share the
immutable index when creating a body session. Replace
`infer_facts_find_type_home_entry` with the common semantic lookup; do not build
a fresh index per body.

### 6. Cut over type resolution and tests

Change helper signatures in `headers/type_resolution.brp` and all benchmark
fixtures. Remove direct list construction and equality assertions. Tests
should query semantic behavior through the public index operations.

### 7. Delete legacy list machinery

Repository-wide search must find no `List[TypecheckTypeHome]`, direct `.find`
Remove `TypecheckTypeHome` entirely if it has no remaining consumer.

## Fast Feedback Loop

Run after each representation checkpoint:

```bash
bin/blorp test --timeout 180 \
  blorp/test/compiler/stage_06_typecheck/test_typecheck_state.brp

bin/blorp test --timeout 180 \
  blorp/test/compiler/stage_06_typecheck/test_immutable_sharing.brp

bin/blorp test --timeout 180 \
  blorp/test/compiler/stage_06_typecheck/test_infer.brp
```

Exercise the session-reconstruction fixture because the index must be shared,
not rebuilt per body:

```bash
bin/blorp run --release \
  blorp/benchmark/compiler/compiler_infer_session_reconstruction_profile.brp
```

Use repository search as a mechanical completion check:

```bash
rg -n "List\[TypecheckTypeHome\]|type_homes\.find|replace_type_home|find_type_home_entry" \
  blorp/src blorp/test blorp/benchmark
```

Before merge:

```bash
scripts/compiler-check --changed
scripts/compiler-check --stage typecheck
```

Then run the alternating optimized self-check protocol from the roadmap.

## Measurable Acceptance Criteria

- [ ] Precedence tests fail against an intentionally incorrect last-write-wins
      or import-over-local implementation and pass with the required rules.
- [ ] `TypecheckState` and `InferModuleFacts` carry the same immutable
      `TypeHomeIndex`; no body-local re-indexing exists.
- [ ] Production source contains no `List[TypecheckTypeHome]` and no linear
      type-home lookup or replacement helper.
- [ ] The index key is the only retained copy of the visible type spelling;
      entry values cannot disagree with it.
- [ ] `type_home_linear_candidates_visited` and
      `type_home_replacement_list_rebuilds` are zero.
- [ ] The self-check performs indexed reads/writes for the refreshed request
      counts while producing the same semantic checksum, diagnostics, and
      output hash.
- [ ] Retired instructions in the isolated type-home read/write window fall by
      at least 50%.
- [ ] Focused Stage 06 allocations do not increase by more than 0.5%.
- [ ] Stage 01-06 retired instructions improve by at least 1% relative to the
      immediate parent; otherwise reject the representation as insufficient.
- [ ] Median optimized self-check wall time does not regress by more than 2%.
- [ ] Focused state, inference, immutable-sharing, and typecheck-stage suites
      pass.

## Pitfalls and Gotchas

### Accidental last-write-wins imports

Calling `Dict.set` unconditionally would silently change ambiguous import
precedence. Preserve the current record function's branch structure.

### Duplicate authority

A dictionary plus the old list would make illegal disagreement representable
and retain both costs. Use one opaque product.

### Re-indexing per body

The index is immutable module-level data. Rebuilding it in
`infer_session_from_typecheck_state` would move rather than remove the cost.

### Treating module paths as nominal identity

The stored path is spelling provenance only. Do not expand this issue into
type-definition lookup or replace exact `TypeId` comparisons with strings.

### Persistent dictionary update cost

The dictionary still has immutable update cost. That is acceptable only if the
controlled profile shows a net improvement. Do not assume asymptotic notation
is sufficient evidence in Blorp's ARC/COW runtime.

## Non-Goals

- Do not alter `TypeId`, accepted alias authority, or module-view imports.
- Do not index unrelated `Env` or `Scope` fields.
- Do not add mutable state.
- Do not combine this change with inference solver or canonical expectation
  work.
- Do not preserve direct list APIs for compatibility.

## Expected Result

Type-home work should scale with persistent dictionary operations per semantic
read/write rather than with the number of visible types multiplied by every
header and inference lookup.
