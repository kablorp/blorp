# Step 7A: Keyed CTFE Initializer Replacements

**Status:** Complete on `codex/step7a-keyed-ctfe`.

## Outcome

`TypecheckedModule` no longer retains a source-faithful `semantic_program` and
a second CTFE-rewritten `typed_program`. It owns one source-faithful
`typed_program` and a sparse `CtfeGlobalReplacements` table. Each row is keyed
by the graph-issued global definition ID and contains only the two payloads
that CTFE changes:

```blorp
record CtfeGlobalInitializerReplacement {
	parsed_value: ParsedExpr,
	typed_value: TypedExpr
}

private record CtfeGlobalReplacementsRep {
	definition_table: Option[DefinitionTable],
	by_definition_id: Dict[Int, CtfeGlobalInitializerReplacement]
}
```

Mutable globals have no row. A required immutable global without a definition
identity fails closed instead of falling back to its spelling or source order.
Production tables also retain their `DefinitionTable` provenance and Core
rejects a table from an equal-layout but independently issued graph.

Core preparation carries the source-faithful program and table separately.
`lower_typed_program_with_ctfe_replacements` performs one exact lookup only
when lowering a global declaration and substitutes the typed initializer in
that local lowering value. It does not build a replacement declaration list or
a second `TypedProgram`:

```blorp
match info.definition_id:
	Some(definition_id):
		match ctfe_global_replacements_find(replacements, definition_id):
			Some(replacement):
				lower_typed_global(context, { info | value = replacement.typed_value }, private)
```

Lint, LSP, and semantic-occurrence indexing read the source-faithful program.
Typed JSON and summary adapters retain their previous public output by creating
a transient complete projection only when requested. Normal Core lowering does
not call that compatibility projection.

## Implementation Strategy

1. A focused CTFE test first required an immutable and mutable global to
   produce exactly one row keyed by the immutable global's definition ID.
2. CTFE gained a replacement-producing path alongside the older complete
   rewrite helpers retained for focused evaluator tests.
3. `TypecheckCtfeArtifact` and `TypecheckedModule` cut over atomically to one
   program plus replacements; the `semantic_program` field was deleted.
4. The production pipeline and `CoreGraphUnit` carry the table to Core, where
   global lowering consumes it directly.
5. Tooling consumers moved to the one source-faithful program. Presentation
   consumers explicitly request the transient evaluated view.
6. Inventory output now reports `ctfe_replacements`, making table population
   observable without retaining another tree.

The table stores initializer payloads rather than `TypedGlobalVarInfo`; this
avoids duplicating the parsed declaration, binding type, source type, name, and
definition identity in every row.

## Fast Feedback Loop

The implementation used this progression:

```bash
bin/blorp test --timeout 180 \
  blorp/test/compiler/pipeline/test_ctfe_global_eval.brp

bin/blorp test --timeout 180 \
  blorp/test/compiler/stage_06_typecheck/test_typecheck_bridge.brp \
  blorp/test/compiler/stage_06_typecheck/test_frontend_graph_typecheck.brp \
  blorp/test/compiler/stage_08_core_lower/test_core_lower.brp

make
scripts/compiler-check --changed
benchmarks/compiler_ctfe_typecheck_profile 3 24 32 retained selected
```

The retained benchmark consumer now reads the exact replacement row rather
than materializing a complete evaluated program just to validate one answer.

## Verification And Resource Evidence

- focused CTFE globals: 33/33 passed;
- typecheck bridge: 124/124 passed;
- frontend graph typecheck: 11/11 passed;
- Core lowering: 140/140 passed, including foreign-authority rejection and a
  non-empty replacement consumed without rewriting its source program;
- CTFE retained benchmark fixture: 18/18 passed;
- `scripts/compiler-check --changed`: 8 production sources, 20 suites, and 5
  special checks passed;
- retained benchmark checksum and semantic counters were identical;
- tracked allocations were `771126` baseline versus `771138` candidate
  (`+0.0016%`), with retained objects unchanged at 3;
- compiler binary size was `19,742,512` versus `19,760,272` bytes
  (`+0.0900%`).

The baseline source revision was `c2c7d495af51d84e6822d9b1a704a5fa7b011e74`.
The candidate was the uncommitted Step 7A tree built by `make`; its `bin/blorp`
SHA-256 was
`7781daf4346efb499c947b5f246d889f88f4cfc4d78a03a243c2ead9091fee85`.

Elapsed time was noisy (`80.6–91.7 ms` warm baseline observations versus
`88.1 ms` for the final candidate) and is not used as evidence. This packet does not claim a
measured peak-RSS reduction: the retained microbenchmark has one selected
artifact and reports after-release allocator state. The direct structural win
is that a complete typed-program owner was deleted from every retained module;
Step 7B's lifetime harness must measure the resulting peak on a wide graph.

This is an enabling ownership cut, not evidence of a large physical-memory
win. Blorp values share unchanged immutable lists and expression subtrees, so
the deleted complete-program root did not imply a second physical copy of the
entire typed tree. The sparse table removes copied declaration paths and makes
later lifetime cuts possible. Step 7B must deliver the larger retained-byte
and peak-memory result by making broad frontend-only owners unreachable before
Core; a neutral allocation guard alone will not satisfy that step.

## Acceptance Criteria

- [x] CTFE replacements are keyed by exact graph-issued definition identity.
- [x] Rows retain only parsed and typed initializer payloads.
- [x] Mutable globals do not receive replacement rows.
- [x] Missing identity fails closed.
- [x] Foreign definition-table provenance fails closed at Core admission.
- [x] `TypecheckedModule` retains one complete typed program, not two.
- [x] Core consumes the sparse table without materializing a complete program.
- [x] Lint/LSP keep source-faithful semantics.
- [x] Typed JSON/summary output remains compatible.
- [x] Generated semantics, diagnostics, benchmark checksum, and gate results
  remain unchanged.
- [x] Allocation and code-size changes remain far below the material guard.

## Follow-On

Proceed to Step 7B and
[`137-codegen-input-last-use-and-release.md`](137-codegen-input-last-use-and-release.md):
inventory the remaining rich frontend fields, construct an opaque accepted
codegen-ready product, and prove the rich graph becomes unreachable before
Core preparation. Do not reintroduce a complete evaluated typed program in
that projection.
