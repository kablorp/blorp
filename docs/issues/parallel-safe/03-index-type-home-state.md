# Index Type-Home State

**Status:** Ready

**Kind:** Independent Stage 06 optimization

**Detailed predecessor:**
[Index Type-Home State](../compiler-performance/65-index-type-home-state.md).
This file is the execution source of truth for the parallel lane.

**Parallel owner boundary:**

- `blorp/src/compiler/stage_06_typecheck/state.brp`
- `blorp/src/compiler/stage_06_typecheck/decl.brp`
- `blorp/src/compiler/stage_06_typecheck/infer.brp`
- `blorp/src/compiler/stage_06_typecheck/headers/type_resolution.brp`
- `blorp/src/compiler/stage_06_typecheck/headers/type_header_install.brp`
- `blorp/src/compiler/stage_06_typecheck/modules/module_binding.brp`
- matching Stage 06 tests and type-home benchmark fixtures

Do not edit Stage 09, compiler phase orchestration, the native runtime, or the C
emitter in this issue.

## Objective

Replace `List[TypecheckTypeHome]` with one opaque, immutable `TypeHomeIndex`
shared by header resolution and body inference. Delete all linear type-home
lookup and replacement paths.

The index must encode the existing precedence rule:

- the first imported home for a visible spelling is retained;
- later imported homes cannot replace it;
- every local recording replaces the existing home, imported or local; and
- a later import cannot replace a local home.

This is not a nominal-identity redesign. A type home records visible-spelling
provenance; `TypeId` remains the authority for nominal type identity.

## Evidence

The most recent focused Stage 06 profile recorded approximately:

- 214,899 type-home recording requests;
- 215,108 state lookup requests;
- 147,640 inference-fact lookup requests;
- 5.02% optimized inclusive time in recording; and
- 3.83% optimized inclusive time in lookup.

Those percentages overlap, but the request counts prove that the compiler
repeatedly scans and reconstructs a collection whose semantic model permits
only one active entry per visible name.

## Required Representation

Use one private key/value authority:

```blorp
private struct TypeHomeEntry {
	module_path: String,
	imported: Bool
}

opaque type TypeHomeIndex = Dict[String, TypeHomeEntry]
```

The visible type spelling exists only as the dictionary key. Do not duplicate
`type_name` inside `TypeHomeEntry`, because key/value disagreement would then be
representable.

Expose semantic operations rather than the dictionary:

```blorp
pure func type_home_index_empty() -> TypeHomeIndex

private pure func type_home_index_entry(
	index: TypeHomeIndex,
	type_name: String,
) -> Option[TypeHomeEntry]

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
```

Keep `TypeHomeEntry` and `type_home_index_entry` private. Production callers
use the narrow module-path and imported accessors, so no public signature
exposes a private representation type.

The recording operation must encode precedence explicitly. It must not call
`Dict.set` unconditionally:

```blorp
match type_home_index_entry(index, type_name):
	Some(_):
		if imported:
			index
		else:
			type_home_index_replace_with_local(index, type_name, module_path)
	None:
		type_home_index_insert(index, type_name, module_path, imported)
```

The example states the invariant; follow local naming and API conventions in
production code.

## Sharing Contract

`TypecheckState` and `InferModuleFacts` must carry the same immutable index.
Body-session creation shares that value. It must not enumerate and rebuild the
index for every function body.

There is no demonstrated consumer of type-home insertion order. Do not retain
an ordered list beside the dictionary. If implementation discovers a genuine
ordered consumer, stop and document it before extending the data model.

## Test-First Plan

Before changing storage, pin these behaviors:

1. empty lookup;
2. first imported insertion;
3. repeated identical import;
4. conflicting second imported home retains the first;
5. local declaration replaces an imported home;
6. repeated local insertion replaces the earlier local path, matching current
   recording behavior;
7. import after local declaration does not replace it;
8. same spelling in independent module states remains independent;
9. imported alias resolution uses the original imported name and selected
   module path; and
10. body inference observes the same home selected during header resolution.

At least one negative control must intentionally implement unconditional
last-write-wins behavior and demonstrate that the precedence test fails.

## Focused Metrics

Retain or add the following counters in the test-owned profiler:

```text
type_home_record_requests
type_home_find_requests
type_home_linear_candidates_visited
type_home_replacement_list_rebuilds
type_home_index_reads
type_home_index_writes
body_session_index_rebuilds
semantic_checksum
```

The fixture must scale visible type names and body count independently. Use at
least 64, 256, and 1,024 visible names and enough bodies to expose accidental
per-body reconstruction.

## Incremental Implementation

1. Add precedence and sharing tests against list-backed behavior.
2. Record immediate-parent work counters and paired optimized self-checks.
3. Add the opaque index and test its semantic operations directly.
4. Cut over `TypecheckState` and delete its list replacement helper.
5. Cut over `InferModuleFacts` and prove body sessions share the index.
6. Cut over header/type-resolution consumers.
7. Remove `TypecheckTypeHome` if no semantic consumer remains.
8. Remove direct list construction and implementation-detail equality from
   fixtures.
9. Verify there is one writable authority and zero legacy scans.
10. Collect paired focused and stage-two measurements.

Do not mix this with accepted-type canonicalization, solver changes, imported
name indexing, or general environment refactoring.

## Fast Feedback Loop

After each representation checkpoint:

```bash
bin/blorp test --timeout 180 \
  blorp/test/compiler/stage_06_typecheck/test_typecheck_state.brp

bin/blorp test --timeout 180 \
  blorp/test/compiler/stage_06_typecheck/test_immutable_sharing.brp

bin/blorp test --timeout 180 \
  blorp/test/compiler/stage_06_typecheck/test_infer.brp
```

Exercise body-session construction:

```bash
bin/blorp run --release \
  blorp/benchmark/compiler/compiler_infer_session_reconstruction_profile.brp
```

Mechanical completion search:

```bash
rg -n "List\[TypecheckTypeHome\]|type_homes\.find|replace_type_home|find_type_home_entry" \
  blorp/src blorp/test blorp/benchmark
```

Before review:

```bash
scripts/compiler-check --changed
scripts/compiler-check --stage typecheck
```

Use alternating optimized baseline/candidate executables to run
`check --no-format blorp/src/main.brp`. Also run compile-through-C after the
phase-timing lane lands, but use Stage 06 check time as the primary latency
metric.

## Acceptance Criteria

- [ ] The precedence tests distinguish first-import-wins, every-local-write
      replacement, and import-after-local behavior.
- [ ] `TypecheckState` and `InferModuleFacts` carry the same immutable
      `TypeHomeIndex` representation.
- [ ] Body-session construction performs zero index rebuilds.
- [ ] No `List[TypecheckTypeHome]`, linear type-home find, or list replacement
      helper remains in production.
- [ ] The visible spelling is stored only as the dictionary key.
- [ ] The dictionary is the only writable authority; no parallel ordered list
      or cache remains.
- [ ] Linear candidate visits and replacement-list rebuilds are zero.
- [ ] Indexed lookup work is independent of the number of unrelated visible
      type names after construction.
- [ ] Retired instructions in the isolated type-home window fall by at least
      50%.
- [ ] Optimized compiler self-check median improves by at least 1% across the
      required paired runs. If it does not, reject the representation rather
      than keeping it for theoretical complexity.
- [ ] Focused Stage 06 allocations do not increase by more than 0.5%.
- [ ] Diagnostics, semantic checksum, and generated C remain unchanged.
- [ ] Focused state, inference, sharing, and complete typecheck-stage checks
      pass.

## Pitfalls

### Accidental last-write-wins behavior

Persistent dictionaries make unconditional replacement easy. That would
change import precedence. Keep the policy in one tested smart operation.

### Re-indexing immutable facts per body

This moves rather than removes work. `InferModuleFacts` must share the module
index produced during header processing.

### Treating provenance as nominal identity

The stored module path answers where a visible spelling came from. It must not
replace `TypeId` comparisons or become a new global identity scheme.

### Assuming dictionary updates are free

Blorp dictionaries have persistent COW behavior. The focused allocation and
wall-time gates are mandatory; asymptotic improvement alone is insufficient.

### Preserving compatibility machinery

Blorp is pre-0.1 and this is a private compiler representation. Delete the list
form completely rather than maintaining adapters.

## Non-Goals

- Indexing `ImportedNameBinding`.
- Changing `TypeId` or accepted semantic types.
- General environment or scope redesign.
- Mutable global caching.
- Stage 09 or backend changes.
