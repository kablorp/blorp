# Typecheck body-checking per-helper allocation ranking

Date: 2026-09-22 (Issue T-F, `docs/TYPECHECK_OPTIMIZATION_ISSUES.md`)

Compiler commit: `71fa20899730e50f7d7562cb5192e8f9bf9a4ac1` (dirty worktree
`typecheck-tf-td`, cut 1's runtime.c self-allocations counter applied).
Frozen self-compile input revision: `c67257f4663a5225463868fe4a2dbb1b3dd8047f`
(`origin/main` at freeze time). Toolchain: `bin/blorp --version` reports
`target: aarch64-apple-darwin`, `cc: Apple clang version 21.0.0
(clang-2100.3.34.2)`, `optimization: cli=-O0 runtime=-O2` for the plain build
used for the metrics denominator; the profiled binary used for the ranking
below links its own `runtime.c` object at `-O2` with
`-DBLORP_PROFILE_EXACT_TIMING=1` and its `blorp_cli_main.c` at `-O2`, per the
two-step exact-profile recipe (bootstrap `compile --no-embed-runtime
--profile --profile-mode exact`, then `cc -DBLORP_PROFILE_EXACT_TIMING=1` for
the runtime object).

## Method

1. Cut 1 (`blorp/src/lib/runtime/native/runtime.c`): added
   `self_allocations` to `blorp_ProfileEntry`/`blorp_ProfileFrame`/
   `blorp_ProfileSnapshot`, attributed the same way `self_ns` is (allocation
   counter delta at frame enter/exit minus the callees' committed share).
   Printed as two more columns (`Self allocs`, `Avg allocs`) at the end of
   the existing "Function Profile" table; all prior columns unchanged.
   `BLORP_PROFILE_MODE_EXACT` only. Verified against the synthetic probe: the
   plumbing correctly attributes non-zero self-allocation counts to real
   helpers (`json__escape` etc. show `0` because they are pure string/format
   helpers with a pooled reuse; typecheck helpers below show real nonzero
   counts).
2. Cut 2 (retained probe/gate): `benchmarks/blorp/profiles/typecheck_body_helper_allocations.brp`
   drives `typecheck_graph` in-process over a deterministic synthetic module
   set (12 modules x 96 probe bodies, 40-deep nominal chains) built from the
   same fixture `benchmarks/compiler_typecheck_profile` already drives
   (`blorp/benchmark/compiler/compiler_typecheck_profile_fixture.brp`).
   `benchmarks/compiler_typecheck_body_helper_allocations` wraps it exactly
   like the DCE wrapper: checks `error_count == 0`, `typed_declaration_count`
   identity, and caps `allocations` (measured `498,606`; wrapper default cap
   is that value, `BLORP_TYPECHECK_HELPERS_MEASURE_ONLY=1` lifts it). Wired
   into `make hygiene-check` (see "Doc corrections" below: the retired DCE
   wrapper this issue modeled itself on was never wired into a gate at
   landing time, so this issue's wrapper is instead wired the way the
   `compiler_record_update_*` wrappers already are).
3. Cut 3 (this ranking): built a profiled compiler whose own generated C was
   produced by `bin/blorp compile --no-embed-runtime --profile --profile-mode
   exact` (all 14,671 described functions selected — restricting
   `--profile-module` to individual `stage_06_typecheck/type_system/*` files
   failed for files whose functions are fully inlined/eliminated before
   emission, e.g. `type_json.brp`; described-function selection already
   only includes functions surviving to Core, so the doc's "restrict to
   `--profile-module`" step does not apply cleanly file-by-file — see "Doc
   corrections"), then linked with a `runtime.c` object built with
   `-DBLORP_PROFILE_EXACT_TIMING=1 -DMINICORO_IMPL -DBLORP_COMPILER_RUNTIME_SOURCES=1`.
   Ran that profiled compiler with `BLORP_COMPILER_MEMORY_PROFILE=1`
   (allocation counters are gated behind this env var or `BLORP_TRACK_STATS`;
   without it every `Self allocs` column reads zero — see "Doc corrections")
   and `--stop-after=lower` on the frozen self-compile input, then filtered
   the printed "Function Profile" table to rows whose C symbol prefix is
   `blorp_src_compiler_stage_06_typecheck_infer__` or
   `blorp_src_compiler_stage_06_typecheck_type_system_*__` (1,161 of 4,416
   observed functions). `PROFILE_DIAGNOSTICS` showed `calls_completed=808885089`,
   confirming the run was recorded, not abandoned.
4. Denominator: `module_bodies` allocations on the same frozen input,
   measured separately with the plain (unprofiled) build and
   `BLORP_TYPECHECK_BODY_METRICS=1` (metrics inflate totals, used for
   attribution only, never for acceptance): **27,882,470** allocations.

Raw profile rows for every typecheck-matching function (1,161 rows, tab
column layout matching the printed table) are in
`typecheck_body_helper_allocations_O2_2026-09-22.tsv`.

## Top 40 by self allocations

The top twenty rows account for 13,897,328 of 27,882,470 `module_bodies`
allocations, **49.84%** — just under the 50% bar in the issue's acceptance
criterion, so this widens to the top forty as the issue directs. The top
forty account for 18,411,727 allocations, **66.03%** of `module_bodies`.

| Helper | File | Calls | Self allocations | Allocs/call |
| --- | --- | ---: | ---: | ---: |
| `localize_module_types` | `type_system/semantic_type.brp` | 828,488 | 2,100,020 | 2.535 |
| `resolve_alias_seen` | `type_system/accepted_alias_authority.brp` | 1,533,284 | 1,509,685 | 0.985 |
| `split_canonical_module_type_name` | `type_system/semantic_type.brp` | 679,274 | 1,166,517 | 1.717 |
| `array_types_equal` | `type_system/semantic_type.brp` | 912,185 | 912,185 | 1.000 |
| `infer_result` | `infer.brp` | 712,587 | 712,587 | 1.000 |
| `infer_call_with_callee_result` | `infer.brp` | 74,948 | 670,608 | 8.948 |
| `accepted_trait_implementation_authority` | `type_system/accepted_trait_implementation_authority.brp` | 756 | 638,564 | 844.661 |
| `scope_add_symbol` | `type_system/env.brp` | 207,921 | 623,763 | 3.000 |
| `typed_expr_info_from_slot` | `infer.brp` | 580,335 | 580,335 | 1.000 |
| `infer_context_with_state` | `infer.brp` | 562,489 | 562,489 | 1.000 |
| `infer_without_expected` | `infer.brp` | 545,228 | 545,228 | 1.000 |
| `infer_with_canonical_expected_value_slot` | `infer.brp` | 262,054 | 524,108 | 2.000 |
| `env_push_scope` | `type_system/env.brp` | 126,240 | 504,960 | 4.000 |
| `bind_type_subst_result` | `infer.brp` | 481,363 | 481,363 | 1.000 |
| `infer_name_expr` | `infer.brp` | 279,813 | 441,110 | 1.576 |
| `lookup_bare_value` | `infer.brp` | 425,737 | 425,512 | 0.999 |
| `call_signature` | `infer.brp` | 91,657 | 402,879 | 4.396 |
| `resolve_var_dims_type` | `infer.brp` | 364,346 | 376,843 | 1.034 |
| `constructor_symbol_from_locator` | `type_system/accepted_union_authority.brp` | 125,390 | 376,170 | 3.000 |
| `infer_call_args_with_subst` | `infer.brp` | 91,657 | 342,402 | 3.736 |
| `resolve_alias_list` | `type_system/accepted_alias_authority.brp` | 1,509,634 | 342,130 | 0.227 |
| `bind_var_dims_subst_result` | `infer.brp` | 318,195 | 318,195 | 1.000 |
| `env_add_var_with_module_details` | `type_system/env.brp` | 99,684 | 299,052 | 3.000 |
| `owner_entry` | `type_system/accepted_callable_authority.brp` | 138,093 | 276,186 | 2.000 |
| `env_mint_def_id` | `type_system/env.brp` | 137,342 | 274,684 | 2.000 |
| `argument_target_slot` | `type_system/type_widening.brp` | 274,165 | 268,946 | 0.981 |
| `type_contains_resource_seen` | `infer.brp` | 244,998 | 259,275 | 1.058 |
| `infer_expected_slot` | `infer.brp` | 525,366 | 246,593 | 0.469 |
| `infer_block_expr` | `infer.brp` | 69,874 | 209,622 | 3.000 |
| `add_core_builtin_functions` | `type_system/builtins.brp` | 1,135 | 202,030 | 178.000 |
| `env_add_symbol` | `type_system/env.brp` | 199,587 | 199,587 | 1.000 |
| `qualify_module_local_types` | `type_system/semantic_type.brp` | 76,275 | 194,556 | 2.551 |
| `infer_ufcs_call_with_resolved_call` | `infer.brp` | 16,833 | 194,494 | 11.554 |
| `env_add_trait_function` | `type_system/env.brp` | 62,991 | 188,061 | 2.986 |
| `type_lists_equal` | `type_system/semantic_type.brp` | 648,116 | 184,066 | 0.284 |
| `implementation_owner_module_path` | `type_system/accepted_trait_implementation_authority.brp` | 181,463 | 181,463 | 1.000 |
| `bind_call_var_dims` | `infer.brp` | 91,657 | 178,035 | 1.942 |
| `binding_from_slot` | `type_system/accepted_callable_authority.brp` | 173,903 | 173,903 | 1.000 |
| `symbol_is_type_binding` | `type_system/env.brp` | 348,072 | 166,661 | 0.479 |
| `typed_expr_with_info` | `infer.brp` | 156,860 | 156,860 | 1.000 |

All file paths are relative to `blorp/src/compiler/stage_06_typecheck/`.
Full mangled C symbols (e.g.
`blorp_src_compiler_stage_06_typecheck_type_system_semantic_type__localize_module_types`)
are in the `.tsv`.

## Top 20 by allocations per call, calls > 1,000

The expensive-but-rare helpers the first table hides. `add_core_builtin_functions`
et al. only run once per compile (constant per module count) but each call
allocates hundreds of times; they are not levers for the self-compile's
allocation total (1,135 calls total) but would matter for a workload that
rebuilds builtin tables per session.

| Helper | File | Calls | Allocs/call | Self allocations |
| --- | --- | ---: | ---: | ---: |
| `add_core_builtin_functions` | `type_system/builtins.brp` | 1,135 | 178.000 | 202,030 |
| `add_core_builtin_traits` | `type_system/builtins.brp` | 1,135 | 69.000 | 78,315 |
| `builtin_union_types` | `type_system/builtins.brp` | 1,136 | 23.000 | 26,128 |
| `infer_match_cases` | `infer.brp` | 10,270 | 12.979 | 133,296 |
| `infer_ufcs_call_with_resolved_call` | `infer.brp` | 16,833 | 11.554 | 194,494 |
| `constructor_symbols_with_ids` | `type_system/env.brp` | 3,408 | 11.333 | 38,624 |
| `infer_call_with_callee_result` | `infer.brp` | 74,948 | 8.948 | 670,608 |
| `record_field_types` | `infer.brp` | 8,050 | 8.294 | 66,766 |
| `add_core_builtin_types` | `type_system/builtins.brp` | 1,136 | 8.000 | 9,088 |
| `append_constructor_locators` | `type_system/accepted_union_authority.brp` | 3,703 | 7.020 | 25,996 |
| `add_checked_write_builtin::consume_arg0` (closure) | `type_system/builtins.brp` | 5,675 | 6.600 | 37,455 |
| `add_tensor_constructor_builtin::consume_arg0` (closure) | `type_system/builtins.brp` | 5,675 | 6.000 | 34,050 |
| `prepend_constructor_locators` | `type_system/accepted_union_authority.brp` | 1,293 | 5.851 | 7,565 |
| `infer_var_decl_expr` | `infer.brp` | 13,528 | 5.578 | 75,461 |
| `add_checked_read_builtin::consume_arg0` (closure) | `type_system/builtins.brp` | 4,540 | 5.500 | 24,970 |
| `infer_record_fields` | `infer.brp` | 5,025 | 5.411 | 27,191 |
| `accepted_fields_for_inference` | `infer.brp` | 6,940 | 5.146 | 35,716 |
| `call_signature` | `infer.brp` | 91,657 | 4.396 | 402,879 |
| `scope_add_type_symbols` | `type_system/env.brp` | 3,408 | 4.333 | 14,768 |
| `table_trait_methods_seen` | `type_system/accepted_trait_implementation_authority.brp` | 3,156 | 4.295 | 13,554 |

## Reading the ranking

- `infer.brp` and `type_system/env.brp`/`semantic_type.brp`/
  `accepted_alias_authority.brp` dominate, consistent with the doc's own note
  ("body checking is 72%... the next typecheck lever is `Scope.symbols_by_name`
  and the `env_add_*` tail-call chain" from `FRONTEND_FACTS_ROADMAP.md`).
  `scope_add_symbol`, `env_push_scope`, `env_add_var_with_module_details`,
  `env_mint_def_id`, `env_add_symbol`, `env_add_trait_function` together are
  1,887,107 self allocations (6.8% of `module_bodies` alone) — the T-B
  "scope lookup keyed by name id" issue was retired on an unproven allocation
  claim; this ranking gives it real numbers if revisited.
- `resolve_alias_seen`/`resolve_alias_list` (1,851,815 combined) reopen the
  retired T-B/alias-resolution line with real evidence: `resolve_alias_seen`
  is called 1.5M times for 1.0 allocation/call (a `List.contains`-style seen
  set, one alloc per probe) — a likely candidate for a Dict/Set rewrite, but
  per the traps in the shared context, probe cost is not always allocation
  cost, so this still needs its own attribution before a cut is written.
- `localize_module_types`, `split_canonical_module_type_name`,
  `array_types_equal`, `type_lists_equal`, `qualify_module_local_types` (all
  in `semantic_type.brp`) sum to 4,557,344 self allocations (16.3% of
  `module_bodies`) — the single largest file-level concentration outside
  `infer.brp`'s own helpers, and worth its own issue.
- `accepted_trait_implementation_authority` at 756 calls / 844.7 allocs per
  call is the extreme outlier in the "rare but expensive" table's absence
  (its calls=756 falls under the >1,000 threshold) but is worth flagging
  directly: at 638,564 total self allocations from three-quarters of a
  thousand calls, it rebuilds something large per call; this is exactly the
  T-D cut 2 target function's neighbor (`prepare_accepted_trait_header` is
  called from the same loop in `decl.brp`) and should be cross-checked
  against T-D cut 2's per-loop attribution once that lands.

## Doc corrections (not applied to the doc; listed for the coordinator)

- "the wrapper joins the compiler-tools gate the way the DCE wrapper did"
  (Issue T-F, cut 4): the DCE wrapper (`compiler_dce_facts_builder_allocations`,
  commit `94d34bdc`) was never wired into any gate at landing time — it is
  README-documented but not called from `Makefile` or `scripts/test`. This
  issue's wrapper is instead wired into `make hygiene-check`, next to the
  `compiler_record_update_*` wrappers, which *are* real precedent for "a
  benchmark wrapper joins a gate."
- "restrict to `--profile-module` covering `stage_06_typecheck/infer` and
  `stage_06_typecheck/type_system/*`" (Issue T-F, cut 3): `--profile-module`
  takes one exact, already-described module path per flag, not a glob, and
  fails hard (`internal C emission failure: unknown profile module`) for any
  named file whose functions were fully inlined/eliminated before Core
  emission (e.g. `type_system/type_json.brp` has none surviving). Selecting
  all functions (empty selector list, which the emitter treats as "select
  everything" per `select_profile_functions`) and post-filtering the printed
  table by C-symbol prefix, as this ranking does, is more robust and avoids
  hand-maintaining a working module subset.
- The fast-loop recipe's `--stop-after=lower` dumps the current program as
  one huge single-line JSON blob to stderr in addition to (or possibly
  instead of, depending on ordering) the `BLORP_TYPECHECK_PHASE`/profile
  rows; this is pre-existing behavior (reproduced with the unmodified `main`
  build too), not caused by this issue's changes, but it means any command
  capturing `--stop-after=lower`'s stderr without piping through `grep`
  produces a many-tens-of-megabytes file. Worth a note in the doc's fast-loop
  section so the next worker isn't surprised.
- Allocation counting (`get_mem_stats`/the profiler's new `Self allocs`
  column) is zero unless `BLORP_COMPILER_MEMORY_PROFILE=1` (or
  `BLORP_TRACK_STATS=1`, which also turns on `bytes_allocated` tracking) is
  set; `blorp_init_object_header` only increments
  `global_mem_stats.total_allocations` when `__blorp_stats_enabled ||
  __blorp_lightweight_stats_enabled`. The doc's cut-3 recipe should say this
  explicitly next to "the profiled compiler ... --profile-mode exact", since
  a profiled run without the env var silently prints an all-zero `Self
  allocs` column with no error.

## Cross-check against retired issues

- T-B (scope lookup) and the alias-resolution line in T-D's shared context
  are directly supported by this ranking (see "Reading the ranking" above):
  `env_add_*`/`scope_add_symbol`/`env_push_scope` and
  `resolve_alias_seen`/`resolve_alias_list` are both in the top twenty by
  self allocations.
- T-C (per-node `TypedExprInfo`/`ValueSlot`, rejected at 2.889% ceiling) is
  visible here as `typed_expr_info_from_slot` (580,335) and
  `typed_expr_with_info` (156,860): 737,195 combined, 2.6% of
  `module_bodies` — consistent with T-C's own measured ceiling, confirming
  neither this ranking nor T-C's own numbers contradict each other.
