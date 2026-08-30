# Remove Single-Use Multiline Straight-Line Functions

## Status

Ready for implementation.

## Issue Summary

Delete the private compiler functions listed below by copying each existing
body expression into its sole direct call site and then deleting the function.

This issue is intentionally mechanical. Do not redesign the surrounding pass,
rename symbols, change collection operations, alter diagnostics, or add an
automatic source rewriter.

## Context

[Remove Low-Value Private Compiler Wrappers](compiler-private-function-wrapper-cleanup.md)
targets one-line forwarding functions. This issue is the next bounded tranche:
functions whose bodies occupy several formatted source lines but still perform
one straight-line transformation.

The candidates were scanned on 2026-08-24. Every listed function then had:

- private visibility;
- exactly one lexical consumer outside its declaration;
- a direct call at that consumer;
- no recursion;
- no `match`, `if`, `for`, `while`, `?=`, or mutable local in its body;
- no use as a callback or first-class function value; and
- exactly one use of every formal parameter in the body.

The last condition matters: substituting the call arguments cannot duplicate
their evaluation.

## Problem Statement

Formatter line wrapping makes some simple expressions look substantial enough
to justify a helper. The result is a private declaration and call-graph edge
for a constructor, record literal, `map`, `all`, `any`, or method chain that is
used only once.

These functions make readers navigate away from the only caller without adding
an invariant or reusable abstraction. They also add declarations and callable
facts that the self-hosted compiler must process.

## Goal

Remove every still-valid candidate in the inventory below without changing:

- evaluation order;
- argument evaluation count;
- source diagnostics;
- type or ownership behavior;
- Core or generated-C semantics; or
- public compiler and language behavior.

## Non-Goals

Do not:

- convert loops into `map`, `filter`, or `fold`;
- simplify or restructure the copied expression;
- merge related functions or records;
- rename functions, fields, variables, or variants;
- remove opaque constructors or accessors;
- inline callbacks or recursive entry points;
- change an error or diagnostic message;
- modify ownership, cleanup, ABI, path, identifier, or mangling policy; or
- add new abstractions to replace the deleted functions.

## Mandatory Per-Function Procedure

Perform these steps for each row, in order.

### 1. Confirm The Inventory Has Not Drifted

```bash
rg -n '\bFUNCTION_NAME\b' blorp/src/compiler blorp/test/compiler
```

There must be exactly one declaration and one direct call. The call must be in
the file and approximate line listed below. If there is another consumer, a
callback reference, recursion, or a materially changed body, mark the row
`SKIPPED: inventory drift` and make no edit for that function.

### 2. Copy, Do Not Reimplement

Copy the existing body expression verbatim into the direct call site. Replace
each formal parameter with the corresponding actual argument.

- Keep nested lambdas unchanged.
- Keep constructor variants unchanged.
- Keep method-chain order unchanged.
- Keep literals and default values unchanged.
- Do not distribute, simplify, or combine boolean expressions.
- Do not introduce a temporary unless the formatter or parser requires one.
- Do not add a comment. If the result cannot be understood without the removed
  function name, mark the row `SKIPPED: useful abstraction` instead.

### 3. Delete The Declaration

Delete the complete private function declaration and any documentation that
describes only that function. Do not delete adjacent comments or declarations.

### 4. Format And Check The File Immediately

```bash
./blorp format PATH
./blorp format --check PATH
./blorp check --no-format PATH
```

Do not continue to another file while one of these commands is red.

### 5. Confirm The Symbol Is Gone

```bash
rg -n '\bFUNCTION_NAME\b' blorp/src/compiler blorp/test/compiler
```

For a removed function, this command must produce no output.

## Candidate Inventory

Paths are relative to `blorp/src/compiler/`. Line numbers are navigation hints
from the 2026-08-24 scan; the function name and current source are authoritative.

| File | Function | Definition | Sole call |
|---|---|---:|---:|
| `stage_03_parse/language_parser.brp` | `make_block_expr` | 3011 | 3088 |
| `stage_04_modules/module_surface.brp` | `function_surface_symbol` | 157 | 378 |
| `stage_04_modules/module_surface.brp` | `trait_method_surface_symbol` | 169 | 290 |
| `stage_04_modules/module_surface.brp` | `impl_method_surface_symbol` | 182 | 317 |
| `stage_05_types/env.brp` | `field_names_match` | 1854 | 1871 |
| `stage_06_typecheck/bridge.brp` | `type_header_graph_diagnostics` | 391 | 455 |
| `stage_06_typecheck/bridge.brp` | `trait_topology_graph_diagnostics` | 405 | 469 |
| `stage_06_typecheck/bridge.brp` | `callable_header_graph_diagnostics` | 416 | 483 |
| `stage_06_typecheck/bridge.brp` | `implementation_header_graph_diagnostics` | 427 | 497 |
| `stage_06_typecheck/decl.brp` | `implementation_header_bound_type_params` | 3199 | 3480 |
| `stage_06_typecheck/decl.brp` | `implementation_method_bound_type_params` | 3210 | 3344 |
| `stage_06_typecheck/headers/type_header_graph.brp` | `bool_at` | 2436 | 2791 |
| `stage_06_typecheck/headers/type_header_install.brp` | `builtin_header_type_parameters` | 543 | 579 |
| `stage_06_typecheck/infer.brp` | `tuple_value_type_from_items` | 12335 | 12400 |
| `stage_08_core_lower/flatten.brp` | `bound_with_pattern` | 808 | 823 |
| `stage_08_core_lower/lower.brp` | `lower_runtime_helper_body` | 1052 | 4418 |
| `stage_09_core/consume_specialize.brp` | `rewrite_owned_recursive_call_args` | 1095 | 1024 |
| `stage_09_core/fairness.brp` | `insert_constructor_length_match_cases` | 915 | 954 |
| `stage_09_core/mono_impl.brp` | `impl_has_selected_method` | 84 | 205 |
| `stage_09_core/perceus.brp` | `constructor_match_cases_can_balance` | 7045 | 7691 |
| `stage_09_core/perceus.brp` | `install_mutable_assignment_in_constructor_cases` | 8240 | 8325 |
| `stage_09_core/perceus.brp` | `global_is_unshadowed` | 18810 | 18868 |
| `stage_09_core/prepare.brp` | `prepare_constructor_length_match_cases` | 3733 | 3776 |
| `stage_09_core/resource_management.brp` | `rewrite_dict_literal_entries_with_cleanups` | 274 | 1446 |
| `stage_09_core/synth_list.brp` | `unknown_call` | 138 | 248 |
| `stage_09_core/synth_list.brp` | `all_types_concrete` | 337 | 4876 |
| `stage_12_cli/doctest.brp` | `public_exports` | 544 | 740 |
| `stage_12_cli/lint.brp` | `module_private_callables` | 354 | 786 |
| `stage_12_cli/lint.brp` | `module_call_observations` | 601 | 791 |
| `stage_12_cli/lint.brp` | `function_loop_findings` | 1500 | 1704 |
| `stage_12_lsp/analysis_model.brp` | `semantic_index_capability_list_contains` | 396 | 916 |
| `stage_12_lsp/analysis_planner.brp` | `module_is_forced` | 351 | 377 |
| `stage_12_lsp/diagnostic.brp` | `diagnostic_phases_in_publication_order` | 42 | 80 |
| `stage_12_lsp/workspace.brp` | `targets_contain_index` | 1143 | 1222 |
| `stage_12_lsp/workspace.brp` | `targets_contain_missing_module` | 1175 | 1225 |

## File-Ordered Execution Batches

Use these exact batches. Finish all checks for one batch before starting the
next.

### Batch 1: Parse And Modules

1. `stage_03_parse/language_parser.brp`
2. `stage_04_modules/module_surface.brp`

Then run:

```bash
scripts/compiler-check --stage parse
scripts/compiler-check --stage modules
```

### Batch 2: Types And Typechecking

1. `stage_05_types/env.brp`
2. `stage_06_typecheck/bridge.brp`
3. `stage_06_typecheck/decl.brp`
4. `stage_06_typecheck/headers/type_header_graph.brp`
5. `stage_06_typecheck/headers/type_header_install.brp`
6. `stage_06_typecheck/infer.brp`

Then run:

```bash
scripts/compiler-check --stage types
scripts/compiler-check --stage typecheck
```

### Batch 3: Core Lowering And Core

1. `stage_08_core_lower/flatten.brp`
2. `stage_08_core_lower/lower.brp`
3. `stage_09_core/consume_specialize.brp`
4. `stage_09_core/fairness.brp`
5. `stage_09_core/mono_impl.brp`
6. `stage_09_core/perceus.brp`
7. `stage_09_core/prepare.brp`
8. `stage_09_core/resource_management.brp`
9. `stage_09_core/synth_list.brp`

Then run:

```bash
scripts/compiler-check --stage core-lower
scripts/compiler-check --stage core
```

### Batch 4: CLI And LSP

1. `stage_12_cli/doctest.brp`
2. `stage_12_cli/lint.brp`
3. `stage_12_lsp/analysis_model.brp`
4. `stage_12_lsp/analysis_planner.brp`
5. `stage_12_lsp/diagnostic.brp`
6. `stage_12_lsp/workspace.brp`

Then run:

```bash
scripts/compiler-check --stage cli
scripts/compiler-check --stage lsp
scripts/test lsp
```

## Explicit Exclusions From This Issue

The scan also found short, single-consumer functions that must not be folded
into this mechanical tranche. In particular, do not edit:

- `finalize_lexer` or `bind_standalone_typecheck_graph`: phase boundaries;
- `recovery_module_surface`: recovery-state construction;
- `known_type_index_add_resource`: opaque representation update;
- `lambda_has_no_runtime_captures`, `collection_stage_types_match_source`,
  `allowed_owned_call_use`, and `can_own_binding`: optimization invariants;
- `result_var_for_param` and `drop_temp_var`: generated-name policy;
- `function_consumed_param_indices` and `let_tracks_cleanup`: ownership policy;
- `positive_float64_bits`: numeric representation policy;
- `render_dict_value_release_init`: runtime ABI emission;
- `test_session_counters_requested`: environment-variable policy;
- `package_module_name`, `should_auto_format_cli_source`,
  `implicit_compiler_sources`, and `default_package_cache_root`: path, source,
  or configuration policy;
- `document_highlights_for_symbol` and `reference_locations_in_modules`: named
  LSP query boundaries; or
- the `lower_materialized_*` string-pipeline helpers: strategy callbacks.

Do not add excluded functions to the candidate inventory while implementing
this issue.

## Final Verification

After all four batches:

```bash
scripts/compiler-check --changed
make
scripts/test compiler-blorp
make quality
git diff --check
```

Inspect the final diff and verify that it contains only:

- deletion of listed private declarations;
- direct substitution of their existing bodies at the listed call sites; and
- formatter changes required by those substitutions.

Any other semantic or structural edit is out of scope.

## Acceptance Criteria

- Every listed function is either removed or recorded as skipped for one of the
  two permitted reasons: `inventory drift` or `useful abstraction`.
- Every removed function had one direct consumer immediately before removal.
- Every removed body was copied rather than reimplemented.
- No argument is duplicated, omitted, or reordered.
- Exact searches return no references to removed names.
- The diff contains no unrelated cleanup or redesign.
- All four stage-batch checks pass.
- `scripts/compiler-check --changed`, `make`, `scripts/test compiler-blorp`,
  `make quality`, and `git diff --check` pass.

## Expected Impact

The direct result is 35 fewer private declarations and call-graph edges when
all candidates remain valid. This should reduce compiler source complexity and
slightly reduce frontend and generated-function work. Measure generated-C size,
compiler wall time, and peak memory after the issue only if making a performance
claim; this issue is justified by simplification alone.
