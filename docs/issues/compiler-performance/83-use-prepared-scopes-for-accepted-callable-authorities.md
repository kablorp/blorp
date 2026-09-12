# Use Prepared Scopes for Accepted-Callable Authorities

**Status:** Complete

**Roadmap:** [Normalized Semantic Compilation Roadmap](NORMALIZED_SEMANTIC_COMPILATION_ROADMAP.md), Step 2e, twelfth packet

**Depends on:** Exact accepted-callable visibility inputs (Issue 82)

## Outcome

Accepted-callable authority construction no longer accepts module-path strings:

```blorp
owner_module_path: Option[String]
direct_module_paths: List[String]
```

It accepts graph-bound prepared scopes instead:

```blorp
pure func accepted_callable_authority(
	visibility: AcceptedCallableVisibility,
	owner_scope: Option[PreparedModuleScope],
	direct_module_scopes: List[PreparedModuleScope],
) -> Option[AcceptedCallableAuthority]
```

The constructor validates each scope against the accepted table's module-table
domain and retains only its `ModuleId`. The production caller already owns the
exact scopes, so no path is projected and no reverse module-table lookup occurs.

## Context

Issue 82 changed the retained authority to exact owner, selective-binding, and
direct-module identities, but its compatibility API still accepted strings and
resolved them immediately. That left an avoidable string round trip:

```text
PreparedModuleScope
  -> canonical path String
  -> module table lookup
  -> ModuleId
```

The prepared module boundary already carries the graph capability that gives a
`ModuleId` meaning. Carrying that capability into construction is both cheaper
and safer than projecting a path and looking it up again.

A bare `ModuleId` parameter would be smaller but insufficiently constrained:
`ModuleId` is an opaque compact table index, not a globally unique value. An ID
issued by another compilation could have the same runtime integer. Accepting a
`PreparedModuleScope` permits the constructor to validate module-table
compatibility before extracting the ID.

## Invariants

1. Authority construction accepts no owner or direct-module path strings.
2. Every owner and direct scope must use a module table compatible with the
   accepted callable table.
3. A supplied incompatible scope rejects the authority; it is not silently
   treated as a missing module.
4. The retained authority still stores only `ModuleId`, not a prepared scope.
5. Owner and direct-module order is unchanged.
6. Standalone authorities may omit an owner and direct scopes.
7. Exact owner lookup remains available after unqualified name access is hidden.
8. Public inference and qualified query APIs remain string-taking where source
   text is still their natural input.
9. No compatibility shim reconstructs a path from a scope.

## Implementation Strategy

### 1. Lock the construction boundary with a failing test

Extend the declaration boundary test to require:

```text
owner_scope: Option[PreparedModuleScope]
direct_module_scopes: List[PreparedModuleScope]
```

The same test rejects `owner_module_path` and `direct_module_paths`. It fails
against Issue 82 before production changes.

### 2. Validate scope provenance centrally

Use one narrow helper for both owner and direct scopes:

```blorp
private pure func accepted_callable_authority_module_id(
	table: AcceptedCallableTableRep,
	scope: PreparedModuleScope,
) -> Option[ModuleId]:
	if module_tables_are_compatible(
		table.module_table,
		prepared_module_scope_module_table(scope),
	):
		Some(prepared_module_scope_id(scope))
	else:
		None
```

This keeps provenance validation at the construction boundary. Later authority
queries can rely on the retained IDs without repeating compatibility checks.

### 3. Fail closed for incompatible scopes

An owner scope is optional, but a supplied owner must validate. Every supplied
direct scope must also validate. The constructor returns `None` for any
incompatible scope rather than dropping it or accepting its raw integer index.

A behavior test builds a scope from a separate compilation graph and verifies
that construction rejects it.

### 4. Carry scopes directly from `BoundModule`

The production adapter already owns the exact scope values:

```blorp
owner_scope = bound_module_scope(bound_module)
direct_module_scopes = bound_module_direct_import_modules(bound_module)
	.map(importable_module_prepared_scope)
```

Both standalone and graph-backed branches pass `Some(owner_scope)` and the same
ordered direct-scope list. The former path projection and table lookup are
deleted rather than retained as fallback behavior.

### 5. Keep source-query conversion at natural boundaries

This packet does not add ID-taking versions of `accepted_callable_find` or the
qualified lookup APIs. Their current callers hold parsed source names, so moving
the same `SourceNameTable` lookup one stack frame earlier would add API surface
without eliminating work or retained data.

## Fast Feedback Loop

Start with the millisecond-scale structural check:

```bash
python3 -m unittest \
  blorp.test.compiler.stage_06_typecheck.support.test_declaration_boundary.\
DeclarationBoundaryTests.test_callable_authority_retains_exact_visibility_inputs
```

Then run the declaration behavior suite:

```bash
bin/blorp test \
  blorp/test/compiler/stage_06_typecheck/test_typecheck_decl.brp
```

The focused behavior test covers compatible dependency scope construction,
incompatible cross-graph scope rejection, hidden unqualified lookup, and exact
owner localization.

Once stable, run the changed-owner gate once:

```bash
scripts/compiler-check --changed
```

Finally retain one accepted-stage guard sample:

```bash
env BLORP_COMPILER_BENCHMARK_SKIP_BUILD=1 /usr/bin/time -lp \
	benchmarks/compiler_typecheck_phase_profile accepted 1 32 4 16 16 memory
```

Allocation and memory counters are the primary guard for this boundary-only
change. One-shot wall time and cycles are retained but not used as latency
claims.

## Acceptance Criteria

- [x] The structural test fails against the Issue 82 string-taking constructor.
- [x] Production construction passes prepared scopes directly.
- [x] Owner and direct module paths are absent from the constructor API.
- [x] Scope compatibility is validated before extracting `ModuleId`.
- [x] An incompatible cross-graph scope rejects construction.
- [x] The authority retains only IDs after construction.
- [x] Local, selective, qualified, and UFCS behavior remains unchanged.
- [x] All 142 declaration tests pass.
- [x] The changed-owner gate passes: two production sources, nine focused
  suites, one declaration-boundary check, and zero failures.
- [x] Allocation, release, retained-object, and allocated-byte counters are
  exactly neutral.
- [x] Instructions, RSS, and peak footprint improve; compiler size is
  effectively neutral.
- [x] Independent review reports no unresolved issue.

## Measurements

Both accepted-stage samples produced identical semantic checksums, output
counts, accepted catalog counts, and deterministic memory counters.

| Metric | Issue 82 baseline | Candidate | Change |
| --- | ---: | ---: | ---: |
| Allocations | 265,849 | 265,849 | 0.0000% |
| Releases | 183,921 | 183,921 | 0.0000% |
| Retained objects | 81,928 | 81,928 | 0.0000% |
| Allocated bytes | 6,015,952 | 6,015,952 | 0.0000% |
| Retired instructions | 8,271,714,950 | 8,265,037,225 | -0.0807% |
| Cycles | 2,322,681,745 | 2,293,604,863 | -1.2519% |
| Maximum RSS | 37,666,816 | 37,617,664 | -0.1305% |
| Peak footprint | 31,097,168 | 31,031,632 | -0.2107% |
| Compiler bytes | 19,423,872 | 19,423,920 | +0.0002% |

Detailed evidence is retained in
[`compiler_accepted_callable_prepared_scopes_step2e_2026-09-11.md`](../../../benchmarks/results/compiler_accepted_callable_prepared_scopes_step2e_2026-09-11.md)
and its TSV companion.

## Next Packet

Audit the remaining `OverloadEntry` source context retained beyond typecheck,
especially `module_path: Option[String]`. Separate diagnostic/debug projection
needs from semantic ownership, and move accepted downstream consumers toward
`CallableId`/`ModuleId` before changing this widely shared compatibility type.
