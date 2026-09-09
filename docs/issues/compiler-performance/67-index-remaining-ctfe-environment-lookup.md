# Index Remaining CTFE Environment Lookup

**Status:** Recount and admit after Issue 64

**Roadmap:** [Stage 06 Latency Reduction Roadmap](STAGE06_LATENCY_REDUCTION_ROADMAP.md)

**Dependencies:** Issue 64. Follow the roadmap's serial measurement order and
recount after the Issue 66 decision.

**Primary owners:**

- `blorp/src/compiler/stage_07_ctfe/value.brp`
- `blorp/src/compiler/stage_07_ctfe/env.brp`
- Stage 07 CTFE environment, evaluator, and leak tests

## Objective

After graph-owned dependency-global evaluation removes repeated requests,
replace residual linear `CtfeEnv` name lookup with a coherent nearest-binding
index while preserving ordered lexical history.

The representation must preserve:

- nearest-binding shadowing;
- mutable-local assignment;
- scope projection;
- environment concatenation precedence;
- global filtering;
- unavailable-binding diagnostics; and
- closure capture by value.

## Why This Is Last and Measurement-Gated

Before Issue 64, one compiler self-check recorded:

- 149,668 `ctfe_env_has_binding` calls;
- 164,505 `ctfe_lookup_binding` calls;
- 5.23% unoptimized direct time in `ctfe_env_has_binding`;
- 3.34% unoptimized direct time in `ctfe_lookup_binding`; and
- approximately 5.4% optimized attribution to the combined binding-scan
  family.

These functions are also heavily exercised while reevaluating the same
dependency globals for multiple artifacts. Issue 64 should eliminate many
requests entirely. Optimizing the old request count would risk paying index
storage and update costs for work that no longer exists.

Refresh the function counts and whole-check share after Issue 64 and the later
roadmap checkpoints. Admit implementation only if residual binding scans still
account for at least 1% of whole-check retired instructions or allocations.

## Current Semantics

`CtfeEnv` is a nearest-binding-first list:

```blorp
opaque type CtfeEnv = List[(String, CtfeBinding)]
```

Every binding is prepended:

```blorp
[(name, binding)].concat(ctfe_env_unsafe_representation(env))
```

Lookup returns the first match:

```blorp
pure func ctfe_lookup_binding(
	env: CtfeEnv,
	name: String,
) -> Result[CtfeBinding, CtfeEnvError]:
	var result: Option[CtfeBinding] = None

	for (candidate_name, binding) in ctfe_env_unsafe_representation(env):
		if result.is_none() and candidate_name == name:
			result = Some(binding)

	-- preserve unavailable versus missing errors
```

The ordered list carries more information than a visible-name dictionary:

- a local binding shadows a global or farther lexical binding;
- an inner local shadows an outer local;
- assignment updates the nearest binding, even when it is immutable;
- `ctfe_env_concat(nearer, farther)` gives the complete nearer environment
  precedence;
- `ctfe_project_existing_bindings(scoped_env, base_env)` removes bindings
  introduced by an inner scope and reveals shadowed entries again; and
- `ctfe_global_bindings` filters history by binding scope.

A plain `Dict[String, CtfeBinding]` cannot express projection or restoration of
shadowed bindings.

## Proposed Representation

Retain ordered scope history, but store it oldest-first so an index can point to
the nearest binding without retaining a second copy of every managed binding:

```blorp
private record CtfeEnvRep {
	bindings_oldest_first: List[(String, CtfeBinding)],
	nearest_index_by_name: Dict[String, Int],
	local_binding_count: Int
}

opaque type CtfeEnv = CtfeEnvRep
```

The invariant is:

```text
nearest_index_by_name[name] == the greatest valid list position whose name matches
local_binding_count == number of entries with CtfeLocalBinding scope
```

Keeping the index value as an `Int` avoids retaining each `CtfeBinding` and its
possibly recursive `CtfeValue` twice.

All representation construction must pass through private smart functions.
The public API remains semantic environment operations.

## Core Operations

### Binding

Append new entries and point the index to the new final position:

```blorp
private pure func ctfe_env_cons_binding(
	env: CtfeEnv,
	name: String,
	binding: CtfeBinding,
) -> CtfeEnv:
	if name == "_":
		env
	else:
		representation = ctfe_env_rep(env)
		binding_index = representation.bindings_oldest_first.length()
		local_delta = if binding.scope == CtfeLocalBinding:
			1
		else:
			0

		ctfe_env_from_rep({
			bindings_oldest_first = representation.bindings_oldest_first.append(
				(name, binding),
			),
			nearest_index_by_name = representation.nearest_index_by_name.set(
				name,
				binding_index,
			),
			local_binding_count = representation.local_binding_count + local_delta
		})
```

### Lookup and existence

`ctfe_env_has_binding` reads only `nearest_index_by_name`. Lookup reads the
indexed position and then preserves the current distinction:

```text
available binding   -> Ok(binding)
unavailable global  -> CtfeUnavailableBinding with the exact reason
missing name        -> CtfeUnknownBinding
```

An invalid index position is an internal invariant failure, not a missing
binding. Prefer a private validated accessor so corruption cannot silently
change a diagnostic.

### Assignment

Use the nearest indexed position. If that binding is immutable, return
`CtfeImmutableAssignment` without searching for a hidden mutable outer binding.
If mutable, replace exactly that list entry. The index position does not change.

### Concatenation

For oldest-first storage:

```text
combined history = farther history ++ nearer history
```

Rebuild the index by scanning oldest-first and setting every encountered name;
the final position is the nearer binding. Preserve `_` filtering at insertion,
not during arbitrary reconstruction.

### Scope projection

Bindings introduced after `base_env` occupy a suffix. Projection retains the
prefix of length `ctfe_env_length(base_env)`, then rebuilds the index and local
count from that prefix.

Do not return `base_env` solely because lengths match unless the existing
function's contract proves it is the same base lineage. Preserve the current
value result for unusual direct API inputs.

### Global filtering

Filter the oldest-first history for `CtfeGlobalBinding`, then rebuild one
coherent environment. The resulting local count is zero and shadow precedence
among globals is unchanged.

## Recursive Type and Module Boundary

`CtfeValue` contains lambdas, lambdas capture `CtfeEnv`, and `CtfeEnv` contains
bindings whose values are `CtfeValue`. This recursive relationship currently
forces the opaque type to live in `value.brp`, while operations live in
`env.brp`.

The public `ctfe_env_unsafe_from_representation` and
`ctfe_env_unsafe_representation` functions are a documented module-private
collaboration workaround. Update that bridge to carry one coherent
`CtfeEnvRep`, or replace it with narrower construction/access functions. Do not
expose history and index as independently writable values: that would make
corrupt environments representable.

## Incremental Implementation Plan

### 1. Recount and apply the admission gate

Add a focused observation returning:

```text
binding_lookup_requests
binding_lookup_candidates_visited
binding_has_requests
binding_has_candidates_visited
binding_insertions
assignment_requests
assignment_replacement_candidates_visited
concat_rebuild_entries
projection_rebuild_entries
global_filter_rebuild_entries
semantic_checksum
```

Capture the immediate-parent optimized compiler self-check. Stop here if the
residual scan family is below 1%.

### 2. Pin adversarial semantics before representation changes

Add or strengthen exact tests for:

- local over global shadowing;
- inner local over outer local;
- same name bound three times;
- mutable assignment to the nearest binding;
- immutable inner binding hiding a mutable outer binding;
- unavailable self, later, runtime, and imported-runtime globals;
- `nearer` over `farther` concatenation;
- projection revealing a shadowed outer binding;
- projection with no additional bindings;
- global filtering after local shadowing;
- `_` adding no entry; and
- lambda closure capture before and after outer environment extension.

Assert returned values and exact errors, not representation order.

### 3. Introduce the coherent representation and builder

Add `CtfeEnvRep`, an empty constructor, and one private builder from an
oldest-first history. Initially route existing public operations through the
builder without changing lookup. This checkpoint proves ordering conversion
and ownership independently.

### 4. Cut over binding and indexed reads

Change binding to append, maintain the index, and switch `has`/`lookup` to it.
Run the environment and evaluator suites immediately.

### 5. Cut over assignment

Replace the nearest indexed entry. Add an invariant test that verifies index
positions after replacement and after a shadowing insertion.

### 6. Cut over concat, projection, and filtering

Use the common builder for each structural operation. Test them separately so
an ordering regression is localized.

### 7. Close the recursive collaboration boundary

Make it impossible for `env.brp` to update history without rebuilding the
index. Remove obsolete nearest-first list helpers and direct representation
construction.

### 8. Remove temporary comparison machinery and reprofile

Keep only deterministic benchmark observations that protect the indexed-read
and semantic checksum invariants. Remove strategy switches and production
profiling state.

## Fast Feedback Loop

Run after every operation checkpoint:

```bash
bin/blorp test --timeout 180 \
  blorp/test/compiler/stage_07_ctfe/test_ctfe_env.brp

bin/blorp test --timeout 180 \
  blorp/test/compiler/stage_07_ctfe/test_ctfe_eval.brp

bin/blorp test --timeout 180 \
  blorp/test/compiler/stage_07_ctfe/test_ctfe_value.brp
```

Then cover global evaluation and graph integration:

```bash
bin/blorp test --timeout 180 \
  blorp/test/compiler/stage_07_ctfe/test_ctfe_globals.brp

bin/blorp test --timeout 180 \
  blorp/test/compiler/pipeline/test_ctfe_global_eval.brp

bin/blorp run --release \
  blorp/benchmark/compiler/compiler_ctfe_typecheck_profile.brp -- \
  5 24 32 retained
```

If Issue 64 leaves too little lookup work in the existing benchmark, add a
focused environment benchmark parameterized by bindings, shadow depth,
lookups, assignments, concats, and projections. Indexed and baseline semantic
checksums must match.

Before merge:

```bash
scripts/compiler-check --changed
scripts/compiler-check --stage typecheck
scripts/test leak
```

Finally run five alternating optimized compiler self-check pairs using the
roadmap protocol.

## Measurable Acceptance Criteria

The issue has two valid outcomes.

### Accepted implementation

- [ ] The refreshed scan family meets the 1% whole-check admission threshold.
- [ ] Shadowing, concat, projection, assignment, unavailable-binding, global
      filtering, and closure-capture tests match the baseline exactly.
- [ ] `ctfe_env_has_binding` and `ctfe_lookup_binding` visit zero ordered-history
      candidates.
- [ ] Total binding lookup candidates fall by at least 90% on the refreshed
      compiler self-check.
- [ ] Retired instructions in the isolated binding read/write window fall by at
      least 50%.
- [ ] Issue 64's dependency evaluation and target rewrite counts remain
      unchanged.
- [ ] Complete self-check peak RSS does not increase by more than 1%, and total
      allocations do not increase by more than 0.5%.
- [ ] Whole-check retired instructions improve by at least 1%.
- [ ] Median optimized self-check wall time does not regress by more than 2%.
- [ ] Compiler output, diagnostics, CTFE values, and benchmark checksums are
      identical.
- [ ] Focused Stage 07, compiler-stage, and leak suites pass.
- [ ] No nearest-first compatibility representation, dual writable authority,
      or production profiling switch remains.

### Rejected implementation

- [ ] The issue records the refreshed request/candidate counts and production
      share that failed admission, or the representation prototype's measured
      loss.
- [ ] All candidate representation changes and switches are removed.
- [ ] Useful adversarial tests and honest profiler improvements may remain.

## Pitfalls and Gotchas

### Reversing shadow precedence

The physical storage order changes. Oldest-first reconstruction must use
last-write-wins index updates; concatenation must put farther history before
nearer history.

### Treating unavailable as absent

The index includes `CtfeUnavailableGlobal` bindings. `has_binding` is true for
them, while value lookup returns the detailed existing error.

### Updating a hidden outer mutable binding

Assignment targets the nearest binding first. An immutable nearer binding must
reject assignment even if a mutable same-named binding exists farther out.

### Breaking projection lineage

Projection is based on the relationship between the scoped and base histories,
not simply dictionary key subtraction. Shadowed names must reappear correctly.

### Duplicating recursive values in the index

Index list positions rather than `CtfeBinding` values to avoid an extra
retained recursive value graph per visible name.

### Optimizing eliminated work

Pre-Issue-64 counts are context only, not an admission measurement.

## Non-Goals

- Do not change CTFE evaluation order or dependency-global caching.
- Do not move mutable state outside immutable `CtfeEnv` values.
- Do not alter constructor, function, or module-alias lookup.
- Do not add a process-global cache.
- Do not preserve direct list representation APIs for compatibility.

## Expected Result

Residual CTFE binding reads should require one name-index lookup and one exact
history-position read, while the ordered history continues to express lexical
scope and immutable assignment semantics. The representation should be kept
only if it wins after Issue 64 removes the larger source of duplicate requests.

