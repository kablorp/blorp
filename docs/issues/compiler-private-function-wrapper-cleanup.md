# Remove Low-Value Private Compiler Wrappers

## Issue Summary

Remove a curated tranche of private compiler functions that have one direct
consumer and add indirection without enforcing a meaningful phase, ownership,
type, ABI, or diagnostic boundary.

This is a mechanical compiler simplification. It must not become a redesign of
the affected passes, a broad naming cleanup, or an automated source-rewriting
project.

## Context

The self-hosted compiler contains a large number of private helper functions.
Many are useful: recursive entry points establish initial state, opaque-type
constructors enforce representation boundaries, callbacks must exist as named
values, and policy helpers give important invariants one source of truth.

Other helpers are only one-expression wrappers around a single call site. They
increase the number of declarations, callable facts, call-graph edges, lowered
functions, and generated symbols the compiler must process while making the
source harder to follow.

A source inventory performed on 2026-08-24 found:

- 7,902 private production compiler functions;
- 1,124 non-recursive functions with one lexical consumer and at most six body
  lines; and
- 72 strict candidates with one direct call, a one-expression body, and every
  parameter used exactly once.

Lexical counts are only a triage mechanism. They are not proof that a function
is semantically unimportant. The curated candidates below were additionally
screened to exclude known phase and representation boundaries.

## Problem Statement

Low-value private wrappers create several costs:

1. Readers must jump between a call and a private declaration to understand an
   expression that could be read directly at the call site.
2. Typechecking and later compiler phases process an avoidable declaration and
   call edge.
3. Generated Core and C may retain another function or symbol when optimization
   does not eliminate the wrapper.
4. A wrapper name can give the appearance of an invariant or subsystem boundary
   even when the body merely forwards its arguments.
5. Large families of one-use `map`, `filter`, record-update, and constructor
   wrappers obscure the transformation actually being performed.

## What This Solves

- Reduces low-information declarations and call-graph edges.
- Makes local transformations visible where they are used.
- Reduces the amount of compiler source that must be inferred, lowered, and
  emitted.
- Establishes a repeatable standard for distinguishing a useful abstraction
  from a low-value wrapper.

This cleanup may modestly improve compiler time, memory, and generated-C size,
but no percentage improvement should be claimed without measurement. The main
goal is a smaller and more understandable compiler.

## Relationship To Other Work

This issue is independent of the typechecking migration and function-identity
work. It should not change identities, pipeline products, ownership behavior,
or public language semantics.

Removing declarations can make those larger projects cheaper by reducing the
number of facts and functions they process. Do not combine this issue with
changes to identity assignment, call representation, ownership lowering, or
automatic inlining.

## Scope Rules

A candidate may be removed when all of the following remain true at the time of
the edit:

- it is private;
- it has exactly one semantic consumer;
- that consumer invokes it directly rather than passing it as a function value;
- it is not recursive or mutually recursive;
- each argument is evaluated the same number of times after substitution;
- inlining does not change evaluation order, propagation, or ownership;
- it is not the constructor or accessor boundary for an opaque type;
- it does not centralize an ABI, builtin, identifier, path, or mangling policy;
- it does not establish initial state for a recursive traversal; and
- the result is easier to understand at the call site.

When the removed name carried useful intent, add one concise comment at the
call site. Do not replace one private wrapper with another.

## Tranche A: Mechanical Removals

These are the highest-confidence candidates. Replace the sole call with the
body expression, preserve argument evaluation, then delete the function.
All candidate paths below are relative to `compiler/blorp/src/`.

### Parsing And Typechecking

- `stage_03_parse/parsed_ast_traverse.brp`: `map_match_case`
- `stage_06_typecheck/decl.brp`: `main_return_type_text`
- `stage_06_typecheck/headers/type_header_install.brp`:
  `union_header_type_parameters`
- `stage_06_typecheck/headers/type_header_install.brp`:
  `alias_header_type_parameters`

### Core Preparation And Resource Management

- `stage_09_core/prepare.brp`: `prepare_tailrec_list_spread_rebinds`
- `stage_09_core/prepare.brp`: `prepare_dict_entries`
- `stage_09_core/prepare.brp`: `prepare_concurrent_bindings`
- `stage_09_core/prepare.brp`: `prepare_select_arms`
- `stage_09_core/resource_management.brp`:
  `rewrite_tailrec_list_spread_rebinds_with_cleanups`
- `stage_09_core/resource_management.brp`:
  `rewrite_dict_entries_with_cleanups`
- `stage_09_core/resource_management.brp`:
  `rewrite_concurrent_bindings_with_cleanups`
- `stage_09_core/resource_management.brp`:
  `rewrite_select_arms_with_cleanups`
- `stage_09_core/perceus.brp`: `remove_transferable_result_var`
- `stage_09_core/perceus.brp`: `empty_resolved_value_index`
- `stage_09_core/traverse.brp`: `map_context_record_field`
- `stage_09_core/traverse.brp`: `map_context_tailrec_rebind`
- `stage_09_core/runtime_projection.brp`: `canonical_value_record_field`
- `stage_09_core/record_update.brp`: `replace_record_field_var`

### Backend

- `stage_10_backend/emit.brp`: `emit_set_alloc`
- `stage_10_backend/emit.brp`: `emit_list_set_body`
- `stage_10_backend/emit.brp`: `emit_list_handoff_set_owned_body`

### CLI And LSP

- `stage_11_format/format.brp`: `read_directory_entries`
- `stage_12_cli/test_discovery.brp`: `read_directory_entries`
- `stage_12_lsp/source_loader.brp`: `read_directory_entries`
- `stage_12_cli/cli.brp`: `handled_stdout_with_status`
- `stage_12_cli/test_plan.brp`: `discovered_parse_errors`
- `stage_12_cli/lint.brp`: `constant_states_equal`
- `stage_12_lsp/analysis_planner.brp`: `planning_modules`
- `stage_12_lsp/server_actor.brp`: `clear_effects`
- `stage_12_lsp/source_loader.brp`: `source_package_layouts`
- `stage_12_lsp/workspace.brp`: `empty_analysis_cache`
- `stage_12_lsp/workspace.brp`: `selected_sources`
- `stage_12_lsp/definition.brp`: `definition_result_json`
- `stage_12_lsp/references.brp`: `references_result_json`
- `stage_12_lsp/document_highlight.brp`: `document_highlights_result_json`
- `stage_12_lsp/document_symbol.brp`: `document_symbols_result_json`

The two adapters that convert `IOError` to `String` must inline the complete
`map_err` expression. Do not drop or broaden their error conversion.

## Tranche B: Review Then Remove

These functions are still likely removable, but their names may document an
invariant or a phase-specific operation. Inspect the surrounding function and
retain the helper when inlining makes the caller materially harder to scan.

- `stage_09_core/record_update.brp`: `record_fields_assign_target`
- `stage_09_core/perceus.brp`: `normalize_owned_result_literal_case`
- `stage_09_core/perceus.brp`: `rewrite_constructor_literal_match_case`
- `stage_09_core/resolve.brp`: `resolve_global`
- `stage_09_core/match_projection.brp`: `project_global`
- `stage_09_core/runtime_projection.brp`: `canonical_union_variant`
- `stage_10_backend/emit.brp`: `call_kind_consumes_arg`
- `stage_10_backend/emit.brp`: `list_handoff_write_order_is_supported`
- `stage_12_cli/compile_effect.brp`: `append_timing_output`
- `stage_12_cli/lint.brp`: `has_window_lookup_peer`
- `stage_12_cli/lint.brp`: `has_zip_lookup_peer`
- `stage_12_lsp/compiler_service.brp`: `source_for_target`
- `stage_12_lsp/compiler_service.brp`: `module_has_different_identity`
- `stage_12_lsp/server_actor.brp`: `active_matches_completion`
- `stage_12_lsp/server_actor.brp`: `without_rejected_open_session`

For Tranche B, a short comment at the call site is preferable to retaining a
single-use function solely for its name. Keep the function if it is part of a
deliberately symmetric traversal API or if the comment would be longer and less
precise than the helper.

## Explicit Exclusions

Do not remove the following categories as part of this issue:

- opaque representation boundaries such as `bound_module_graph_from_rep`,
  `frame_limits_rep`, and `json_rpc_envelope`;
- recursive/default-state entry points such as `type_containment_summary`,
  `apply_dim_substitution`, and `resolve_callable_id_non_sequence_expr`;
- ABI, identifier, path, and mangling policies such as `normalize_host_path`,
  `mangle_nested_function_name`, and `union_tag_c_name`;
- builtin and FFI boundaries such as `restore_signal_disposition_builtin` and
  `compiler_stdin_read_raw`;
- functions passed as callbacks by name;
- ownership helpers whose name documents transfer, borrow, consume, cleanup,
  or release behavior not obvious from the expression; and
- public functions, even when they currently appear to have one repository
  consumer.

These exclusions can be reviewed in separate issues. Their current shape is
not evidence that they are unnecessary.

## Implementation Sequence

### 1. Revalidate Each Candidate

Concurrent compiler work may have changed call counts. Before editing a
function, run:

```bash
rg -n '\bFUNCTION_NAME\b' compiler/blorp/src compiler/blorp/tests
```

Expect one declaration and one direct production call. Skip and document the
candidate if the current source no longer meets that condition.

### 2. Establish A Focused Baseline

Run the affected manifest stage before editing. The exact stage names for these
batches are `parse`, `typecheck`, `core`, `backend`, `format`, `cli`, and `lsp`:

```bash
scripts/compiler-check --stage STAGE
```

For a narrower baseline, find the source entry in
`compiler/blorp/tests/compiler_test_ownership.json` and run each owned suite by
its exact path:

```bash
scripts/compiler-check compiler/blorp/tests/test_NAME.brp
```

When the working tree already contains unrelated changes, use exact stage or
suite selection instead of treating every changed module as this issue's scope.

### 3. Inline Without Changing Semantics

At the sole call site:

1. substitute each argument once;
2. preserve left-to-right evaluation and `?=`/`Result` propagation;
3. retain `map_err` conversions and constructor wrapping;
4. preserve lambda binder scope;
5. add a concise invariant comment only when useful; and
6. delete the now-unused private declaration.

Do not perform adjacent renames, traversal redesigns, collection rewrites, or
diagnostic wording changes.

### 4. Work In Stage-Sized Batches

Use separate coherent batches for:

1. parsing and typechecking;
2. Core preparation and resource management;
3. backend emission; and
4. CLI and LSP.

Each batch should compile and pass its focused suites before beginning the next
one. This makes regressions attributable and gives valid mergepoints.

### 5. Verify No Stale Symbols Remain

For every removed function, verify that its exact name has no remaining source
or test references. Also inspect generated C for a representative Core/backend
batch if a removed wrapper previously survived emission.

## Testing

After each stage-sized batch:

```bash
./blorp format --check PATHS_CHANGED_IN_BATCH
scripts/compiler-check --changed
make
```

After all batches:

```bash
scripts/test compiler-blorp
make quality
git diff --check
```

Run additional focused gates when applicable:

- formatter changes: `scripts/test compiler-tools`
- LSP changes: `scripts/test lsp`
- backend/Core changes: the manifest-owned focused Core suites and generated-C
  inspection for a representative fixture

No new behavioral test is required merely because a private wrapper was
deleted. Add a regression only if the cleanup exposes previously untested
evaluation-order, ownership, error-conversion, or emitted-C behavior.

## Acceptance Criteria

- Every removed function still met the scope rules immediately before editing.
- All accepted Tranche A functions are removed or have a documented reason for
  retention.
- Every Tranche B function is either removed or explicitly recorded as a useful
  abstraction.
- No public API, diagnostic text, ownership behavior, or generated program
  behavior changes.
- No opaque, builtin, ABI, recursive-entry, or callback boundary is removed.
- Exact searches find no stale references to removed names.
- A fresh compiler build succeeds.
- Focused compiler suites, `scripts/test compiler-blorp`, `make quality`, and
  `git diff --check` pass.

## Follow-Up Work

After this issue lands, rerun the inventory and compare:

- private function count;
- one-consumer private function count;
- generated C size for the compiler;
- frontend/typechecking function count and wall time; and
- peak memory while compiling the compiler.

Use those results to decide whether another manually curated tranche is worth
doing. Do not build an automatic source rewriter unless repeated manual
tranches demonstrate enough remaining value to justify typed source-span
correlation, hygienic substitution, fixed-point rewriting, and atomic
validation.
