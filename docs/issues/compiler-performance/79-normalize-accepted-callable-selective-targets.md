# Normalize Accepted-Callable Selective Targets

**Status:** Complete

**Roadmap:** [Normalized Semantic Compilation Roadmap](NORMALIZED_SEMANTIC_COMPILATION_ROADMAP.md), Step 2e, eighth packet

**Depends on:** Accepted-global exact visibility and per-module membership (Issues 76-78)

## Outcome

Graph selective callable imports now cross the accepted-callable authority
boundary as exact ordered `CallableId` targets:

```blorp
private record AcceptedVisibleCallableBindingRep {
	source_name: String,
	targets: List[CallableId]
}

private record AcceptedCallableVisibilityRep {
	table: AcceptedCallableTable,
	bindings: List[AcceptedVisibleCallableBinding]
}

opaque type AcceptedCallableVisibility = AcceptedCallableVisibilityRep
```

The old binding reconstructed imported overloads from an owner module path and
original source name. Those descriptive join fields are deleted. The retained
local spelling remains a compatibility key because the current callable
authority and inference APIs still query unqualified values and UFCS candidates
by source spelling.

## Context

Before this packet, module binding had already resolved a selective import to
one or more exact graph definition IDs:

```blorp
GraphSelectiveDefinitionBinding(local_name, module_id, definition_ids)
```

The declaration adapter discarded that identity and rebuilt a descriptive row:

```blorp
{
	source_name = imported.local_name,
	owner_module_path = imported.module_path,
	original_name = imported.original_name
}
```

The accepted authority then joined `(owner_module_path, original_name)` against
its string index. That repeated resolution after binding, allowed an exact
overload set to widen accidentally to every same-named callable owned by the
module, and retained source strings where typed identity already existed.

The graph binding's definition list is important: a selective source name may
refer to an ordered overload set. A scalar target would discard valid
overloads, while a name lookup could include an overload that was not admitted
by the import surface. Exact ordered IDs preserve the binding decision.

## Invariants

1. Only graph-issued `DefinitionId` values can become imported `CallableId`
   targets.
2. The issuing definition table and accepted callable table must share one
   provenance domain.
3. Every callable target must be owned by the `ModuleId` recorded on its graph
   import binding.
4. Target order is the graph binding's order; accepted overload precedence is
   preserved by the authority's existing public-index projection.
5. Definition IDs for types, globals, constructors, and other non-callable
   categories are ignored rather than reinterpreted as callables.
6. Missing or rejected accepted-callable slots remain absent, matching the old
   name-index behavior; private targets remain filtered by visibility.
7. Standalone source tooling remains environment-backed because its import
   bindings intentionally have no graph-issued definition IDs.
8. Graph and standalone bindings may never coexist in one module view.
9. The visibility aggregate is opaque and retains its accepted table, so
   coincident runtime integers from another compilation cannot be replayed.
10. No parallel path/name target index is added by this packet.

## Before and After

Before, the adapter reduced exact graph bindings to descriptive strings:

```blorp
for imported in module_view_imported_names(view):
	bindings = bindings.append({
			source_name = imported.local_name,
			owner_module_path = imported.module_path,
			original_name = imported.original_name
		})
```

After, the visibility constructor consumes the authoritative import rows:

```blorp
visibility ?= accepted_visible_callable_bindings(
	table,
	definition_table,
	module_view_import_bindings(view),
).to_result("accepted callable module view rejected invalid exact import bindings")
```

Each graph selective row category-checks and validates its IDs before
publication:

```blorp
match callable_id_from_definition_table(
	issuing_table,
	definition_id_runtime_value(definition_id),
):
	Some(callable_id):
		match callable_id_module_id(issuing_table, callable_id):
			Some(target_module_id):
				if module_ids_equal(target_module_id, module_id):
					targets = targets.append(callable_id)
```

Authority construction now probes accepted slots by exact callable ID:

```blorp
indices = public_indices(
	representation,
	table_indices_for_ids(representation, binding_representation.targets),
)
```

## Implementation Strategy

### 1. Lock the boundary with a failing shape test

Require a private binding representation with `targets: List[CallableId]`,
reject `owner_module_path` and `original_name`, and require the declaration
adapter to consume `module_view_import_bindings`. This test failed against the
old descriptive binding before implementation.

### 2. Project graph definition IDs exactly once

Add an accepted-callable visibility constructor beside the table authority. It
checks shared definition-table provenance, category-checks each ID, validates
module ownership, preserves order, and publishes an opaque aggregate only when
all identity-bearing rows are valid.

### 3. Bind targets to the consuming table

Store the table in the opaque visibility product. This makes the construction
boundary carry both the imported IDs and the authority that can interpret them,
rather than exposing a replayable list of scalar values.

### 4. Keep standalone imports explicit

The source-level bridge uses `StandaloneSelectiveDefinitionBinding`, which has
spelling but no `DefinitionId`. When a view is wholly standalone, construct an
empty graph visibility and leave imported callable lookup in the existing
environment. Reject mixed graph/standalone views. A focused bridge test caught
this boundary during implementation.

### 5. Preserve overload and visibility behavior

Map each exact target through the accepted table's existing definition-ID
index, then reuse `public_indices`. Do not scan the callable table, widen by
name, or expose private/rejected rows.

### 6. Reject a premature integer-key migration

A prototype that also converted callable visibility dictionaries from strings
to generic integer keys added about 2.4% allocations/releases. Removing the
source-name lookup allocation did not affect that result, demonstrating that
the generic integer dictionary representation—not string projection—was the
cost. Revert the prototype and retain the local spelling until a compact map or
dense relation can replace the old table without a material regression.

## Fast Feedback Loop

The boundary test runs in milliseconds:

```bash
python3 -m unittest \
  blorp.test.compiler.stage_06_typecheck.support.test_declaration_boundary.\
DeclarationBoundaryTests.test_callable_selective_visibility_uses_exact_targets
```

Then exercise the authority, source adapter, and inference consumers once:

```bash
bin/blorp test blorp/test/compiler/stage_06_typecheck/test_accepted_semantic_catalog.brp
bin/blorp test blorp/test/compiler/stage_06_typecheck/test_typecheck_decl.brp
bin/blorp test blorp/test/compiler/stage_06_typecheck/test_typecheck_bridge.brp
bin/blorp test blorp/test/compiler/stage_06_typecheck/test_infer.brp
```

Once stable, run the owner-selected gate once:

```bash
scripts/compiler-check --changed
```

Take one accepted-stage guard sample, reusing the retained Issue 78 parent
sample instead of collecting many noisy wall-time pairs:

```bash
env BLORP_COMPILER_BENCHMARK_SKIP_BUILD=1 /usr/bin/time -lp \
	benchmarks/compiler_typecheck_phase_profile accepted 1 32 4 16 16 memory
```

## Acceptance Criteria

- [x] A boundary test fails on the old descriptive target representation.
- [x] Accepted callable selective bindings retain ordered exact `CallableId`
  targets and no target module path/original-name pair.
- [x] The visibility constructor validates definition-table provenance,
  callable category, and module ownership before publication.
- [x] The opaque visibility product binds exact IDs to their accepted table.
- [x] The declaration adapter consumes graph import bindings directly.
- [x] A focused behavioral test proves first-only and second-only exact
  selection, ordered and reversed overload precedence, and rejection of a
  wrong module, foreign definition table, and standalone binding.
- [x] Standalone imports remain environment-backed and mixed binding domains
  fail closed.
- [x] Imported overload, UFCS, private visibility, and generic-constructor
  source behavior remain covered by passing declaration/bridge/inference tests.
- [x] The changed-owner gate passes: six production sources, 18 focused suites,
  one declaration-boundary check, and zero failures.
- [x] Retained objects and allocated bytes are neutral; allocation, release,
  instruction, RSS, footprint, and executable-size guards remain below 0.35%.
- [x] A broader integer-key dictionary prototype with a 2.4%
  allocation/release regression is rejected rather than merged.
- [x] Independent review reports no unresolved issue.

## Measurements

Both accepted-stage samples produced identical semantic checksums, output
counts, and accepted catalog counts.

| Metric | Issue 78 baseline | Candidate | Change |
| --- | ---: | ---: | ---: |
| Allocations | 278,349 | 278,382 | +0.0119% |
| Releases | 189,347 | 189,380 | +0.0174% |
| Retained objects | 89,002 | 89,002 | 0.0000% |
| Allocated bytes | 6,490,056 | 6,490,056 | 0.0000% |
| Retired instructions | 8,458,546,611 | 8,460,316,056 | +0.0209% |
| Cycles | 2,325,715,780 | 2,322,167,528 | -0.1526% |
| Maximum RSS | 40,091,648 | 40,206,336 | +0.2861% |
| Peak footprint | 33,505,592 | 33,620,280 | +0.3423% |
| Compiler bytes | 19,405,296 | 19,406,144 | +0.0044% |

The detailed evidence is retained in
[`compiler_accepted_callable_exact_targets_step2e_2026-09-11.md`](../../../benchmarks/results/compiler_accepted_callable_exact_targets_step2e_2026-09-11.md)
and its TSV companion. One-shot setup, window, and cycle measurements are
recorded but not treated as latency claims.

## Next Packet

Normalize accepted-callable visibility names without repeating the rejected
generic `Dict[Int, List[Int]]` design. The bounded follow-up is
[`80-normalize-accepted-callable-visibility-names.md`](80-normalize-accepted-callable-visibility-names.md):
retain `SourceNameId` in exact visibility rows, keep spelling projection at the
remaining compatibility consumer, and use measured list prototypes to define
the producer-side compact relation that follows.
