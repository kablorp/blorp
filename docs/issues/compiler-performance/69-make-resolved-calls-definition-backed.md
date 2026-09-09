# Issue 69: Make Resolved Calls Definition-Backed

**Status:** Implemented

**Roadmap:** [Normalized Compilation Database Roadmap](NORMALIZED_COMPILATION_DATABASE_ROADMAP.md)

**Dependencies:** Issue 61B publishes the canonical graph `DefinitionTable`;
Issue 68 establishes category-checked scalar constructor identity. This issue
applies the same table-backed model to callables and resolved-call consumers.

**Can proceed independently of:** Issue 70 after Issues 61B and 68, although the two
changes both touch Stage 06 typed projections and should be integrated
sequentially unless their worktree diffs are proven disjoint.

## Objective

Make resolved typed calls carry exact, definition-backed callable identity
without retaining canonical module-path strings on each imported or resolved
implementation-method call. CTFE and Core lowering must derive the callable's
owner `ModuleId` through the retained `DefinitionTable`.

The completed shape should be:

```text
Typed call
  -> CallableId or ConstructorId
  -> DefinitionId
  -> DefinitionRow.module_id
  -> ModuleTable row when a path/name must be rendered
```

not:

```text
Typed call
  -> raw definition Int + copied canonical module path
  -> path-to-ModuleId dictionary probe in CTFE
  -> another path-to-ModuleId dictionary probe in Core lowering
```

This issue must also remove the managed structural payload from hot
`CallableId` values. Adding a definition-backed ID beside the existing
`CallableId` or `CallableOrigin` path is not acceptable.

## Baseline After Issues 61B And 68

Issue 61B publishes one canonical `DefinitionTable`, and Issue 68 already
scalarizes constructor identity, but the baseline
still stores redundant structural identity in every `CallableId` and repeats a
canonical owner path in imported resolved calls and implementation-method
targets. CTFE and Core lowering consequently recover the owner `ModuleId` by
probing the module table with that retained path.

The implementation must cut over the whole call-reader chain at once. A
temporary state containing both structural identity and a scalar definition ID
would increase work and memory while leaving two authorities for ownership.

The accepted production shape is:

```blorp
opaque type CallableId = DefinitionId
opaque type ConstructorId = Int  -- Issue 68's validated scalar definition ID

enum ResolvedGraphCallableCategory:
	ResolvedSourceFunctionCall
	ResolvedForeignFunctionCall

union ResolvedCallTarget:
	ResolvedGraphCallableCall(CallableId, ResolvedGraphCallableCategory)
	ResolvedConstructorCall(ConstructorId, String)
	ResolvedUnindexedCallableCall(Int, ResolvedGraphCallableCategory)
	ResolvedUnindexedConstructorCall(Int, String)
	ResolvedCompilerBuiltinCall(Int)
	ResolvedSelectedTraitMethodCall(String, CallableId)
	ResolvedUnindexedSelectedTraitMethodCall(String, Int)
	ResolvedUnresolvedTraitMethodCall(String)
	ResolvedIntrinsicCall
	ResolvedClosureCall
```

The explicitly unindexed variants are for bootstrap/compiler declarations that
are intentionally outside the source graph. They prevent a raw runtime ID from
masquerading as a validated graph ID; they are not a fallback for a missing
graph definition row. A missing row for a graph declaration is an internal
invariant error at inference.

## Required Reading And Inventory

Read before editing:

- Issue 61B's final table density/provenance decision and Issue 68's scalar
  constructor result;
- `headers/declaration_skeleton.brp` callable and constructor identity APIs;
- `infer.brp` call resolution, equality, and typed expression construction;
- `type_system/env.brp`, especially `ImplMethodTarget` and callable symbols;
- `typed_ast_json.brp`;
- all Stage 07 call readers, especially `body_dependencies.brp`, `ir.brp`,
  `materialize.brp`, and `eval.brp`;
- Stage 08 `graph_prepare.brp`, `lower.brp`, `flatten.brp`, and `identity.brp`;
- semantic occurrence and LSP projections of resolved calls; and
- focused infer, callable, CTFE, Core lowering, JSON, replay, and generated-C
  tests.

Inventory every `CallableOrigin` and `ResolvedCallTarget` constructor and
reader. Classify each current field as:

1. exact graph identity;
2. callable semantic category;
3. local/imported location derivable from owner `ModuleId`;
4. source spelling needed in diagnostics/JSON;
5. builtin/intrinsic identity outside the graph table; or
6. generated Core/C name projection.

Do not remove source names merely because owner paths become derivable. Do not
retain local/imported as an authoritative Boolean once the current module ID
and definition owner answer that question.

## Target Identity Model

### Scalar callable and constructor IDs

Make graph callable identity a category-safe scalar over `DefinitionId`:

```blorp
opaque type CallableId = DefinitionId
opaque type ConstructorId = Int  -- Issue 68's validated scalar definition ID

pure func definition_table_callable_id(
	table: DefinitionTable,
	id: DefinitionId,
) -> Option[CallableId]
```

Only the definition table or a validating declaration-skeleton constructor may
create these values. `CallableId` must not carry a `DefinitionTable`,
`ModuleTable`, source name, span, or owner path. Generated C should represent
it as the same unboxed integer as `DefinitionId`.

If the implementation language cannot make one opaque type directly wrap
another without boxing, use equivalent private conversion functions and prove
the generated representation. Do not weaken APIs to raw `Int` everywhere.

### Separate identity from call semantics

Replace the current origin union with variants that encode only facts not
derivable from the definition row. One viable shape is:

```blorp
enum ResolvedCallableCategory:
	SourceFunctionCall
	ForeignFunctionCall
	ImplementationMethodCall

union ResolvedCallTarget:
	ResolvedCallableCall(CallableId, ResolvedCallableCategory)
	ResolvedConstructorCall(ConstructorId, TypeId)
	ResolvedCompilerBuiltinCall(BuiltinCallableId)
	ResolvedTraitMethodCall(TraitMethodId, Option[CallableId])
	ResolvedIntrinsicCall
	ResolvedClosureCall
```

This is illustrative, not a demand for these exact names. The final variants
must make illegal combinations unrepresentable:

- a constructor is not a foreign function;
- a graph callable cannot be marked imported from a path that disagrees with
  its definition row;
- an implementation target cannot pair one callable ID with another module's
  path; and
- a builtin without a graph row cannot masquerade as a graph `CallableId`.

If constructor parent identity cannot be migrated until Issue 70, retain its
current exact `TypeId` temporarily. Do not retain only the parent type's source
name if an exact ID is already available.

### Derive local versus imported

Every consumer that genuinely needs location should compare IDs:

```blorp
pure func callable_owner_kind(
	definitions: DefinitionTable,
	current_module: ModuleId,
	callable: CallableId,
) -> Option[CallableOwnerKind]:
	owner ?= definition_table_module_id(
		definitions,
		callable_id_definition_id(callable),
	)
	Some(if module_ids_equal(owner, current_module):
		LocalCallableOwner
	else:
		ImportedCallableOwner
	)
```

Prefer APIs that directly return the owner `ModuleId`; do not create and retain
this enum on every typed call unless multiple measured consumers need it.

## CTFE Cutover

`stage_07_ctfe/ir.brp` currently does this for each imported direct call:

```blorp
CallableImported(module_path):
	match module_table_find_id_by_canonical_path(context.module_table, module_path):
		Some(module_id): CtfeIrImportedCall(direct, module_id)
		None: CtfeIrUnresolvedCall
```

After the cut:

```blorp
ResolvedCallableCall(callable_id, category):
	owner ?= definition_table_callable_module_id(
		context.definition_table,
		callable_id,
	)
	if module_ids_equal(owner, context.module_id):
		CtfeIrLocalCall(direct)
	else:
		CtfeIrImportedCall(direct, owner)
```

The real code must preserve the existing pure/impure, builtin, foreign,
constructor, implementation-method, intrinsic, unresolved-trait, and eager
fallback behavior exactly. The example only demonstrates the owner lookup.

`body_dependencies.brp` should use the call variant/category, not a copied
origin path, to decide whether a callable body is a dependency. Preserve
deduplication and dependency order.

## Core-Lowering Cutover

`lower.brp` currently reduces a resolved call to `(module_path, callable_id)`,
looks the path up in `ModuleTable`, and then selects:

```text
by_module[module_id][callable_id]
```

Change the helper to return `(ModuleId, CallableId)` from the definition row:

```blorp
private pure func resolved_call_target_identity(
	definitions: DefinitionTable,
	resolved: ResolvedCallInfo,
) -> Option[(ModuleId, CallableId)]:
	callable ?= resolved_graph_callable(resolved.target)
	owner ?= definition_table_callable_module_id(definitions, callable)
	Some((owner, callable))
```

The existing callable-name registry may continue using an integer dictionary
inside a dense module-indexed outer list. This issue removes the path lookup;
it does not redesign Core naming. When diagnostics or default-name fallback
need the canonical path, materialize it once from `ModuleTable` after the owner
ID is known.

## External And Diagnostic Projection

Typed-AST JSON currently emits:

```json
{
  "kind": "direct",
  "callable_id": 42,
  "origin": {"kind": "imported", "module": "std/list"}
}
```

Keep the external schema byte-for-byte compatible unless a separate protocol
change is approved. Change the serializer boundary to receive the current
`ModuleId`, `DefinitionTable`, and `ModuleTable`, derive local/imported, and
materialize the canonical path only while rendering JSON.

If a graphless unit test serializes a standalone typed expression without an
issuing table, give the test an explicit graph fixture or a narrow graphless
projection variant. Do not put the path back into production `TypedExpr` merely
to keep a test helper convenient.

Diagnostic strings must remain exact. A missing definition row should produce
an internal invariant error at the phase-product boundary, not silently become
an unresolved user call.

## Scope

In scope:

- definition-backed, unboxed `CallableId` and `ConstructorId` where direct
  calls require them;
- a path-free resolved call representation;
- path-free `ImplMethodTarget`;
- CTFE direct-call/dependency translation by definition owner;
- Core callable-name selection by definition owner;
- table-aware typed-AST/semantic projection;
- exact invariant errors for mismatched table provenance; and
- deletion of obsolete origin equality/rendering/path adapters.

Out of scope:

- changing overload resolution or trait implementation selection;
- changing CTFE reachability, fallback, or evaluation semantics;
- replacing `TypedExpr` with an arena;
- changing Core function IDs or generated-definition allocation;
- changing UFCS/C symbol spelling;
- scalarizing all `TypeId`, `GlobalId`, `TraitId`, or `ImplId` values;
- changing the external typed-AST JSON schema; and
- adding caches or invalidation.

## Implementation Sequence

### 1. Establish the observable baseline

Use existing imported-call and implementation-method fixtures to identify the
old path probes in CTFE and Core lowering. Record the production Phase 01-06
self-check command and immediate-parent compiler before editing. Do not add
synthetic production counters or a second benchmark framework: source
inspection proves whether the obsolete probes remain, while retired
instructions and unsampled latency measure the actual effect.

### 2. Scalarize callable identity at the skeleton boundary

Construct `CallableId` only after validating the definition row category.
Convert skeleton/header/accepted callable APIs together. Delete the old
`RuntimeDeclarationIdRep` use for callables rather than retaining both.

### 3. Replace resolved call variants

Update constructors first, then equality, body dependency collection, typed
expression accessors, semantic occurrences, and JSON projection. Make the
compiler fail to typecheck until all readers handle the new exhaustive union.

### 4. Cut over CTFE

Retain `DefinitionTable` once in `CtfeContext` or its owning phase product.
Translate owner relationships by integer table lookup. Delete
`module_table_find_id_by_canonical_path` from typed-call translation.

### 5. Cut over Core lowering

Retain the same table in the Core-lowering input. Select the module-aligned
callable registry directly from the definition owner. Keep path materialization
inside error/name rendering only.

### 6. Delete compatibility code and measure

Remove `CallableImported(String)`, `ImplMethodTarget.module_path`, path-based
equality, old JSON helpers that require embedded paths, and obsolete lookup
imports. Inspect the generated representation of the scalar IDs, compare the
candidate to its immediate parent, and report production, test, and
documentation diffstats separately.

## TDD And Fast Feedback Loop

Start with tests that fail under the old representation:

1. an imported direct call contains no path in the internal typed call;
2. a resolved implementation method contains only its exact callable ID;
3. local/imported classification derives correctly for two modules with the
   same callable source name;
4. an ID from an incompatible definition table is rejected;
5. typed-AST JSON remains byte-identical;
6. CTFE dependency and fallback lists remain exact; and
7. Core lowering produces byte-identical Core JSON and definition frontier.

Iteration loop:

```bash
bin/blorp test blorp/test/compiler/stage_06_typecheck/test_infer.brp
bin/blorp test blorp/test/compiler/stage_06_typecheck/test_typed_ast_json.brp
bin/blorp test blorp/test/compiler/stage_07_ctfe/test_ctfe_ir.brp
bin/blorp test blorp/test/compiler/stage_08_core_lower/test_core_lower.brp
scripts/compiler-check --changed
```

After focused tests pass:

```bash
scripts/compiler-check --stage typecheck
scripts/test compiler-blorp
scripts/test compiler-core-sanitize
```

Inspect generated C and confirm:

- callable IDs and definition owner reads are unboxed integers;
- `ResolvedCallInfo` no longer retains a module-path string through its target;
- no definition table is retained per expression or per ID;
- CTFE/Core typed-call translation does not call the canonical-path lookup;
  and
- canonical path construction remains at JSON, diagnostics, intrinsic, or Core
  naming boundaries only.

## Performance Evaluation

The expected win scales with the number of resolved imported and
implementation-method call expressions:

- one fewer retained path per such typed call;
- integer equality instead of string equality for target identity;
- no path hash/probe when CTFE translates the call;
- no path hash/probe when Core lowering resolves the call; and
- smaller callable identity values copied through skeleton/header/accepted
  products.

Use the production Phase 01-06 self-check of `blorp/src/main.brp` as the
primary workload. Build isolated control and candidate executables, warm each
once, and run alternating uncontended measurements. Retired instructions are
the primary acceptance signal; unsampled wall time and peak RSS guard against
clear feedback-loop regressions. A 1 ms macOS sample is diagnostic evidence,
not a predicted speedup.

Source inspection must show zero canonical-path probes in CTFE/Core resolved
call translation. Focused imported-call, implementation-method, JSON, CTFE,
and Core fixtures preserve the semantic checksums and external projections.
Whole Phase 01-06 latency may be neutral, but a repeatable instruction,
latency, or peak-RSS regression is not acceptable.

## Acceptance Criteria

- Graph callable and constructor IDs used by resolved calls are category-safe,
  definition-backed, and unboxed.
- No graph resolved call stores a canonical module path.
- `ImplMethodTarget` no longer stores `module_path`.
- Local/imported ownership is derived from `DefinitionTable` and the current
  module ID.
- CTFE and Core lowering perform zero path-to-module probes for definition-
  backed resolved calls.
- Builtin, intrinsic, foreign, constructor, implementation-method, unresolved
  trait, and closure cases remain explicit and exhaustive.
- Typed-AST JSON and diagnostic text remain byte-identical for the same input.
- CTFE dependency order, worklist behavior, evaluation, fallback, and
  materialization are unchanged.
- Core JSON, callable names, UFCS names, C symbols, and definition frontier are
  unchanged.
- The old managed callable identity/origin path representation is deleted, not
  retained as compatibility state.
- `DefinitionTable` is retained once by the containing phase product, not by
  each call or ID.
- Source inspection proves that CTFE/Core graph-call translation no longer
  performs path-to-module probes, and focused fixtures preserve all semantic
  projections.
- The Phase 01-06 self-check has fewer retired instructions, or a neutral
  instruction result with clear representation/ownership value, and no
  material latency or RSS regression.
- Focused, changed, Stage 06, CTFE, Core-lowering, leak, and sanitizer tests
  pass.

## Stop Conditions

Stop and consult before:

- changing overload or trait dispatch semantics;
- changing typed-AST JSON, Core naming, C symbols, or ABI;
- adding a module ID beside every callable ID instead of looking it up;
- retaining both imported paths and definition-backed IDs on typed calls;
- adding a cache/invalidation mechanism;
- treating a missing definition row as an ordinary unresolved source call;
- flattening typed expressions; or
- broadening into nominal type normalization from Issue 70.

## Implementation Result

The completed implementation replaces the managed callable-origin payload with
an unboxed `CallableId` backed by the canonical graph `DefinitionTable` and
retains Issue 68's unboxed scalar `ConstructorId`. `ResolvedCallTarget` retains only semantic distinctions that
cannot be recovered from the definition row. Bootstrap declarations outside
the source graph use explicit unindexed variants and cannot masquerade as
validated graph identities.

An opaque CTFE imported-program set carries the canonical `DefinitionTable`
once across the phase boundary; the resulting context retains that same
authority while evaluation runs. Individual imported programs do not retain a
table. CTFE derives the owner of graph calls by direct definition-row lookup.
Core lowering does the same at its graph boundary. Neither
`stage_07_ctfe/ir.brp` nor `stage_08_core_lower/lower.brp` contains a
`module_table_find_id_by_canonical_path` probe. Typed-AST JSON derives the
legacy local/imported projection at serialization time. The complete-program
serializer receives its program and tables from one `TypecheckedGraph` phase
product and remains single-pass; the standalone resolved-call serializer
explicitly rejects identities outside its supplied graph tables.

Definition-backed owner queries exposed a pre-existing
modules-times-callables body-planning scan. `CallableHeaderGraph` now records
one contiguous `{ start, count }` range for each module alongside its canonical
flat header list, and module-local body planning traverses only that module's
range. Header projection already preserves module order, so the range builder
performs only scalar updates while visiting a module and publishes one map
entry at each module boundary. This phase-product index has no nested
copy-on-write lists, invalidation, or duplicated identity authority: every
range reads exactly its headers from the canonical list without copying the
list's remaining tail.

Generated-C inspection confirms that callable and constructor IDs are passed
as pointer-width integer immediates, are excluded from union release masks, and
do not allocate or participate in ARC. `ResolvedCallInfo` no longer retains an
owner-path string through its target, and `ImplMethodTarget` contains only its
callable ID.

Same-input checks compared the candidate and immediate-parent compilers while
both compiled immutable sources from the parent checkout. This avoids charging
the candidate for the larger source tree introduced by the issue. The required
primary workload was the Phase 01-06 self-check of the parent's
`blorp/src/main.brp`; focused `infer.brp` and `lower.brp` checks helped localize
the result. Median exact macOS counters were:

| Source | Parent instructions | Candidate instructions | Difference | Wall difference | RSS difference |
| --- | ---: | ---: | ---: | ---: | ---: |
| `blorp/src/main.brp` | 164,156,250,304 | 162,427,075,916 | -1.053% | -0.83% | -0.49% |

These are medians from five alternating runs. Candidate wall time was 9.51
seconds versus 9.59 seconds for the parent; peak RSS was 834,699,264 bytes
versus 838,844,416 bytes. Every candidate instruction sample was below every
parent sample. A separate wide-module check through 4,096 callable headers
showed essentially constant marginal allocation growth, about 183 allocations
per additional header, confirming that the range builder does not recreate the
old nested-list copy-on-write behavior. The result meets the required
fewer-instructions and no-regression gates without adding a cache or
invalidation path.
