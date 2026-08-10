# Blorp Compiler Cleanup Audit

Status: current inventory, reviewed 2026-08-10

## Scope

This audit covers dead and migration-specific code in `compiler/blorp`, plus
the scripts, environment controls, tests, and documents that maintain those
paths. It separates mechanically unreachable code from active OCaml migration
boundaries. Active boundaries are not deletion candidates merely because their
names mention a bridge, compatibility, or OCaml.

Run the repeatable source inventory with:

```bash
python3 scripts/audit-compiler-blorp-dead-code
python3 scripts/audit-compiler-blorp-dead-code --json
```

The scanner resolves compiler imports and follows declarations from these
roots:

- the production CLI;
- the parser worker;
- every compiler-owned Blorp test;
- every compiler benchmark;
- every other tracked `.brp` source; and
- compiler modules named by build inputs.

It recognizes functions, values, records, structs, unions, enums, opaque
types, type aliases, and resource types. The result remains conservative:
comments and string contents can hide dead code by looking like references,
and field analysis is name-based across all record owners. A reported
declaration has no static caller; a declaration not reported is not
necessarily live.

## Current Snapshot

| Inventory | Count |
|---|---:|
| Compiler source modules | 195 |
| Top-level declarations | 10,679 |
| Unreachable declarations | 39 |
| Estimated unreachable declaration lines | 486 |
| Entirely unreachable source modules | 0 |
| Record or struct fields with no dot read anywhere | 4 |
| Union or enum variants with no use | 1 |
| Whole unused import bindings | 2 |
| Compiler modules reachable only from tests | 3 |
| Remaining production OCaml source files | 88 |

No compiler source module is currently unreachable. The one module absent from
normal Blorp roots,
`stage_05_types/language_surface_manifest.brp`, is an intentional Dune build
input used to generate the remaining OCaml language-surface table.

## Mechanical Removal Queue

The 39 unreachable declarations divide into two reviewable changes. Blorp
has no ordinary function reflection, and none of these declarations is a
`builtin` or `foreign` entry point. They are absent from production, test,
benchmark, and build roots.

### Types And Typecheck: 24 Declarations

```text
stage_05_types/env.brp
  symbol_kind_label
  env_has_trait_bound
  env_find_trait_method_for_param
  env_resolve_trait_method_sig
  env_find_ufcs_method_by_def_id
  find_overload_loop_producer_by_def_id
  env_find_callable_loop_producer_by_def_id
  env_find_similar
stage_05_types/refinement.brp
  subscript_proof_collection
  UNPROVEN_EXPR
  expr_proofs_of_binding
  binding_refinement_of_expr_proofs
  binding_proves_dim_at_most
stage_05_types/type_resolution.brp
  annotation
  local_binding_annotation
  variant_field_type
  type_alias_target
stage_05_types/type_widening.brp
  widening_decision_value_type
  widening_decision_reason
  bitwise_operand_slot
stage_06_typecheck/infer.brp
  bind_type_list_subst
  bind_type_subst
stage_06_typecheck/modules/module_binding.brp
  compiler_register_import_decl
stage_06_typecheck/typecheck_decl.brp
  typecheck_prescan_decl
```

Several are mutually recursive or call one another, but the group has no
incoming edge. The similarly named OCaml `Env.symbol_kind_label` is active in
the OCaml typechecker; that does not make the independent Blorp function live.

### Core: 15 Declarations

```text
stage_09_core/core_early_invariants.brp
  core_early_invariant_stage
  core_early_invariant_loc
stage_09_core/core_specialize_layout.brp
  stream_element_layout
  nullable_managed_option_payload
stage_09_core/core_traverse.brp
  map_literal_match_case
  map_literal_match_cases
  map_literal_match_fallback
  map_constructor_literal_match
  map_constructor_match_body
  map_constructor_length_branch
  map_constructor_length_cases
  map_constructor_length_match
  map_constructor_match_case
  map_core_constructor_match_cases
  map_core_constructor_match_fallback
```

The constructor-match traversal helpers form one disconnected helper tree.
Remove that tree together so the file retains one coherent traversal surface.

### Fields, Variants, And Imports

| Candidate | Evidence |
|---|---|
| `Context.search_paths` | Initialized to `[]`; never read or updated |
| `Env.current_function` | Initialized to `None`; never read or updated |
| `Env.current_function_pure` | Initialized to `False`; never read or updated |
| `RankedTensorCheckedGet.tensor_expr` | Stored after dimensions are derived; later code reads only `tensor`, `indices`, and `dims` |
| `VarOrigin.OtherBinding` | Declared but never constructed or matched |
| `typecheck_decl` import of `compiler_local_type_names_from_decls` | Whole import entry is unused |
| `core_runtime_projection` import of `CoreLayoutTypeIndex` | Whole import entry is unused |

These are compactness wins as well as source cleanup. Removing the three
context/environment fields also shrinks values copied through typechecking.

## Migration-Specific Removal Queue

These paths are reachable only because compatibility code explicitly keeps
them reachable. They need call-site edits or protocol changes, but no new
feature implementation.

### Remove No-Op Test Options

`CliTestArgs.jobs`, `CliTestArgs.cache`, and the test-specific
`CliTestArgs.no_format` value are parsed and tested but never affect test
planning or execution. The production route is serial, has no per-test result
cache, and is always read-only.

Remove test support for `-j`, `--no-cache`, and `--no-format`, then remove those
arguments from `Makefile`, `scripts/test`, CI/release smoke commands, CLI
tests, benchmark policies, and documentation. Keeping accepted no-op options is
actively misleading, especially `--no-cache`, because runtime preparation can
still use its normal cache.

### Shrink The Test-Session Counter Protocol

Four `CompilerTestSessionCounters` fields are always zero in production:

```text
path_policy_process_isolated_files
path_policy_filesystem_isolated_files
planned_combined_selector_harnesses
ocaml_host_invocations
```

They describe rejected or retired migration designs, not current behavior.
Remove them and bump the internal counter schema. Rename
`planned_combined_run_all_harnesses` to a direct aggregate-suite term at the
same boundary. Update the benchmark parser and its contract tests in the same
change.

### Remove The Parser-Retention Diagnostic Route

`BLORP_COMPILER_PARSER_RETENTION` is read only by `parser_bridge_cli.brp`. No
tracked script, benchmark, test, workflow, or document sets or describes it.
It keeps a second parser response shape and retention-only allocation reporting
path alive in `parser_bridge.brp`. Remove the environment branch,
`handle_retention_request_value`, and its private retention artifact helpers.

`BLORP_RAYLIB_PREFIX` is also source-only according to the cross-reference
scan, but it is real host-toolchain configuration. Document it or replace it
with an explicit CLI/build setting; do not classify it as dead.

### Retire Superseded Maintenance Artifacts

- `scripts/audit-stage-08-dead-code` is superseded by the whole-compiler audit.
- `scripts/audit-compiler-zero-arg-pure` is an unreferenced one-time audit. It
  currently reports zero findings and is not a quality ratchet.
- `docs/BLORP_TEST_SESSION_ROADMAP.md` describes six completed slices. Move any
  remaining durable invariants into `ARCHITECTURE.md`, then delete the roadmap
  as required by `docs/README.md`.

## Large Tooling To Simplify, Not Blindly Delete

The test-session performance subsystem contains about 8,010 lines across its
two Python/shell drivers, contract tests, policy, and fixtures. It is live and
has caught real regressions, so it is not dead code. Its migration comparison,
historical route schema, duplicate process supervision, and fast-loop wrapper
are now larger than the production test planner they measure.

Retain one paired benchmark driver and the workloads that detect compile-time
or peak-RSS regressions. Reassess the separate fast-loop supervisor and the
retired-runner schema after the counter cleanup. Do not remove the measured
compiler-suite and oversized-suite workloads until a smaller replacement
still catches the recent CI failures.

## Active Boundaries To Retain

The following similarly named code remains live:

| Boundary | Why it remains |
|---|---|
| `blorp-ocaml-host` and `BLORP_OCAML_HOST_BIN` | Production `lsp`, package commands, and private host commands still delegate |
| Parser bridge executable and prepared-bridge environment | The OCaml host and pinned bootstrap still consume it |
| `cli_artifact_json.brp` compile-plan encoding | The pinned bootstrap consumes one compile graph while building the public CLI |
| `typed_ast_json.brp`, module-surface JSON, and source indexes | Remaining OCaml tools and compatibility fixtures consume these protocols |
| Blorp package manifest/hash/inventory modules | They are tested ports awaiting production package routing |
| `language_surface_manifest.brp` | Dune generator input for the active OCaml language surface |
| `BuildCompatibility` and `CArtifact` | Active internal build/emission data despite stale migration wording |
| `is_legacy_single_letter_type_param` | Recognizes valid source generic names such as `T`; the name is stale, not the behavior |
| Perceus helpers containing `legacy` | They have active callers and require ownership-focused replacement, not deletion |
| OCaml unit and fixture gates | They cover 88 remaining production OCaml files until those consumers move |

The production OCaml inventory currently contains 47 type-system files, 33
tool files, four parser files, two final-layout files, one CTFE file, and one
bridge file. Removing setup, opam, Dune test, or host packaging globally before
those consumers move would break production LSP/package behavior and retained
compiler fixtures.

`BLORP_FRONTEND_PARSER` is a special bootstrap compatibility input. Current
compiler sessions do not read it, but `compiler_blorp_bridge.ml` still sets it
for pinned external bootstrap helper builds. Retest and remove it when the
pinned bootstrap no longer requires the selector; do not preserve it after
that point.

## Recommended Sequence

1. Remove the dead type/typecheck declarations, fields, variant, and import.
2. Remove the disconnected Core helpers, field, and import.
3. Remove parser-retention diagnostics and their environment switch.
4. Remove no-op test options and stale test-session counters.
5. Consolidate the test-session benchmark tooling without losing the two CI
   regression workloads.
6. Retire completed audit/roadmap artifacts and correct stale migration
   comments.

Each of the first two changes should regenerate the audit, check the
production CLI root, and run the owning compiler TestSuites. The test-option
and counter changes also require CLI stage-two, shell harness, benchmark
contract, and exact `compiler-blorp` shard verification.
