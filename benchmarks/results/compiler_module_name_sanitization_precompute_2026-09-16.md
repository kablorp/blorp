# Compiler Module-Name Sanitization Precompute

Follow-up to the rejected cut E of the retired issue 149 (Core pass linear
scans). That cut measured `sanitize_core_module_name` at 505,482 calls per
self-compile, about 1.76% of retired instructions, and showed the cost is per
call, so only calling it fewer times helps.

Measured against the r2 baselines (`self_compile_baseline_O2_r2_2026-09-16.json`
and `self_compile_small_baseline_O2_r2_2026-09-16.json`), recorded from a clean
`b58c5d81` build so the deltas exclude issues 147-151. Candidate JSONs:
`self_compile_sanitize_precompute_accept_O2_2026-09-16.json` and
`self_compile_small_sanitize_precompute_accept_O2_2026-09-16.json`.

## Change

`core_module_member_name` stays the single spelling authority. It is now the
composition of `core_module_member_prefix` (the sanitized module identity plus
separator) and `core_module_member_name_from_prefix`, and callers that spell
many members of one module compute the prefix once:

- `graph_prepare` builds one `core_module_member_prefix_table` for every module
  in the graph and attaches it to each `CoreLowerContext`; type lowering
  flattens canonical `module::Type` names through it
  (`flatten_canonical_core_type_name_with_prefixes`). This path was 333,325 of
  the 497,888 member-name spellings.
- `flatten` sanitizes the module once per `prefix_module_names_with_aliases`.
- `resolve` memoizes one prefix per module path in `CoreCallResolveEnv` and
  spells call-site members through it.
- `mono_specialize` keeps a prefix table on `CoreGenericFunctionIndex`, shared
  with `core_option_fusion_target`.
- `std_inline`, `synth_name`/`parallel_tensor_pipeline` take a precomputed
  prefix per module.

`emit` (0 calls without profile selectors) and `mono_impl` (40 calls) were left
as they were.

## Call counts (calls-mode profile, self-compile)

| Function | Before | After |
| --- | ---: | ---: |
| `sanitize_core_module_name` | 505,482 | 8,457 |
| `core_module_member_name` | 497,888 | 794 |

## Self-compile, -O2, output C IDENTICAL

| Metric | Baseline r2 | Candidate | Delta |
| --- | ---: | ---: | ---: |
| allocs core_lowering | 21,960,681 | 21,259,483 | -3.19% |
| allocs early_core | 44,523,823 | 44,192,576 | -0.74% |
| allocs TOTAL | 272,498,625 | 271,462,535 | -0.38% |
| instructions retired (min) | 267,208,225,641 | 262,524,492,149 | -1.75% |

Small program, -O2, output C IDENTICAL: allocations 2,839,785 -> 2,828,124
(-0.41%), instructions 2,399,662,301 -> 2,394,226,802 (-0.23%). Wall-time rows
in the candidate JSON are not evidence: a profiling build ran concurrently.
