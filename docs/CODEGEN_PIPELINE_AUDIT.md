# Codegen Pipeline Audit

This catalogue covers the Core-to-C codegen path after typed AST lowering. It
is intentionally about maintainability risks and optimization candidates, not a
commitment to change all items immediately.

## Live Pipeline

The current Core pipeline is:

1. `Core_lower` plus `Core_ffi_boundary` and initial list-layout annotation
2. `Core_debug`
3. `Core_desugar` plus `Core_ssa`
4. `Core_mono` plus list-layout annotation
5. `Core_synth`
6. `Core_match`
7. `Core_trait_resolve`
8. `Core_resolve`
9. `Core_std_inline`
10. `Core_tailrec`
11. `Core_string_pipeline`, `Core_collection_pipeline`,
    `Core_parallel_tensor_pipeline`, `Core_tensor_fusion`, `Core_tuple_sroa`
12. `Core_specialize` plus function-reference adaptation
13. `Core_dce`
14. `Core_consume_specialize`
15. `Core_perceus`
16. `Core_reuse`
17. `Core_closure`
18. `Core_resource`
19. `Core_fairness`
20. `Core_codegen_prepare`
21. `Core_reuse` for prepared unions
22. `Core_emit_c`

`Core_pipeline.run_core_passes` is the source of truth for pass ordering. Keep
docs, stage names, invariants, and `--dump-core-after` behavior aligned with it.

## Dead Code

Removed in this pass:

- `Core_collection_pipeline.add_vars`: unused local helper.
- `Core_list_layout.layout_of_elem`: unused wrapper around
  `Core_layout_type.list_storage_layout_of_elem`.
- Broader compiler cleanup removed additional unused Core/codegen helpers:
  storage-hash policy plumbing, dead tensor storage constructors/accessors,
  stale DCE wrappers, the retired AST-level `Core_flatten.build_import_tables`,
  unused invariant/Perceus/resolve wrappers, stack Option/Result predicates, and
  formatter/LSP/diagnostic/typecheck helper exports with no production callers.

Guardrail added:

- `test_type_boundary_hygiene.ml` now rejects those dead helper names if they
  reappear in production code.

Follow-up habit:

- Repeat the top-level single-reference scan before broad codegen refactors.
  A single reference is not always dead code, but it is a cheap way to find
  stale wrappers and test-only shims.

## Algorithmic Inefficiencies

1. `Core_pipeline.compile_typed_with_modules` accumulates FFI metadata with
   `all_flags @ flags` and `all_dirs @ dirs` inside a fold. That is quadratic
   in the number of foreign declarations. The low-risk fix is reverse
   accumulation with `List.rev_append` and one final reverse.

2. The `Fusion` stage is five full-program traversals:
   `Core_string_pipeline`, `Core_collection_pipeline`,
   `Core_parallel_tensor_pipeline`, `Core_tensor_fusion`, and
   `Core_tuple_sroa`. The ordering is meaningful, so do not merge them
   blindly. First split phase timing inside the stage or split the stage enum
   so compile-time profiles can show which traversal matters.

   The scoped vector/matrix parallel cleanup roadmap is complete enough to
   remove as a standalone roadmap. Remaining parallel-tensor follow-ups should
   stay measurement-driven:
   - rerun benchmark measurements on target release hardware before making
     performance claims;
   - consider source-storage reuse only after ownership analysis proves the
     source is uniquely owned, dead after the pipeline, and layout-compatible
     with the result;
   - consider multiple `zip_map` fusion only if measurements justify the extra
     lowering complexity.

3. Runtime-capture and free-variable checks are recomputed in several places:
   `Core_collection_pipeline.lambda_has_no_runtime_captures`,
   `Core_perceus.lambda_has_runtime_captures`, and closure/emitter free-var
   collection. This can become repeated subtree work around nested callbacks.
   A shared capture-summary abstraction is plausible, but only after the
   phase-specific rules are written as tests.

4. `compile_typed_with_modules` lowers and flattens modules, runs the full Core
   pipeline, emits output, then scans the original lowered `full` program for
   FFI link metadata. The extra traversal is likely small, but link metadata
   could be collected during lowering/flattening if compiler-time profiling
   shows it matters.

5. `Core_emit.ml` contains large mutually recursive paths for general
   expression emission, tail-recursive emission, pattern tree emission, and
   profiling. The main risk is not a known big-O issue; it is that local fixes
   can accidentally duplicate traversal logic or miss one emission variant.
   Changes here should be backed by generated-C audit tests.

## Redundant Patterns

1. Core builder helpers are repeated in multiple modules:
   `Core_string_pipeline`, `Core_collection_pipeline`, `Core_intrinsics`, and
   many tests define local `mk`, `void`, `lit_int`, `var`/`vr`, `seq`, `lett`,
   or `intr` helpers. A small `Core_builder` could reduce drift, but it should
   stay syntactic and not encode phase-specific invariants.

2. Capture/free-variable traversal is duplicated with slightly different
   semantics. `Core_closure.collect_free_vars_filtered` explicitly says it
   shares logic with `Core_emit.collect_free_vars_filtered`; Perceus and the
   collection pipeline have related local traversals. This is the strongest
   candidate for a typed, tested shared abstraction.

3. Several "annotate the whole program after enough type information exists"
   passes have similar shape: `Core_ffi_boundary.annotate_program`,
   `Core_list_layout.annotate_program`, and `Core_codegen_prepare.prepare_program`.
   The pattern is legitimate, but future boundary facts should prefer one
   explicit data model over another ad hoc late pass.

4. Late layout logic has had wrapper drift around `Core_layout_type`. Keep
   layout classification owned by `Core_layout_type`; downstream passes should
   carry explicit layout fields rather than re-sniffing element types.

## Misnamed Objects

1. `Core_stage.Fusion` is too broad. It contains string/list/scoped tensor
   pipeline fusion, tensor update fusion, and tuple scalar replacement. Either
   split it for profiling/dump granularity or rename it to a broader optimization
   stage if CLI compatibility is preserved.

2. `Core_profile` means compiler phase timing, while generated C `--profile`
   means runtime function profiling. `Core_phase_profile` or
   `Pipeline_profile` would reduce ambiguity.

3. `Core_codegen_prepare` is preparing Core for C emission after closure
   conversion. `Core_emit_prepare` would be clearer if the pass remains tied to
   the C backend's emission invariants.

4. `compile_typed_with_modules` returns generated C plus native link metadata.
   The name hides the backend and output shape. A clearer internal name would
   be `compile_typed_with_modules_to_c`; any public rename needs a compatibility
   path.

5. `Core_list_layout.annotate_program` is accurate but generic. If more layout
   annotation passes appear, prefer `annotate_list_layouts` for call-site
   readability.

## Recommended Next Steps

1. Fix the FFI metadata accumulator. It is low risk and easy to test.
2. Add per-subpass timing inside the current `Fusion` stage before attempting
   to merge or split traversals.
3. Design a shared capture/free-variable summary only after inventorying each
   phase's exact binding rules.
4. Treat stage renames as user-facing CLI changes because
   `--dump-core-after` and `--stop-after` consume stage names.
