# Measure Scope Materialization Scaling

**Status:** Evidence captured

## Context

This is the measurement prerequisite for Issues 16-23 and the executable
decomposition of Slice 0 from
[`13-freeze-frontend-declaration-catalog.md`](13-freeze-frontend-declaration-catalog.md).
It must merge before representation work begins.

The revision-matched compiler profile at `aa269938` measured:

| Function | Exact calls | Attributed samples | Share |
| --- | ---: | ---: | ---: |
| `scope_add_symbol` | 1,531,964 | 13,458 | 12.46% |
| `register_callable_header` | 623,368 | 7,293 | 6.75% |
| `env_add_accepted_type_with_containment` | 95,012 | 3,807 | 3.52% |

Within `scope_add_symbol`, 71.1% of samples were under the name-index
`Dict.set`, 20.7% were under symbol-list growth, and 5.5% were under the
callable-ID index. Runtime leaves were dominated by `blorp_dict_copy` (58.9%),
`blorp_list_copy_with_capacity` (19.3%), `memmove` (10.7%), and memory zeroing
(4.3%).

Those numbers predate several batching changes. This issue must establish a
fresh current-main baseline and determine what remains before another
production optimization is accepted.

## Problem Statement

The current architecture can repeat work at two levels:

1. Installing `K` symbols into a persistent scope one at a time can approach
   `O(KD + K^2)` when the existing scope has `D` symbols and collection COW
   copies grow with the scope.
2. Preparing every module can reinstall declarations from visible or direct
   dependencies. Across a dense module graph, total installation work can
   approach `O(M^2 * D)` for `M` modules with `D` declarations each.

These are hypotheses until current counters establish the multiplicity and
growth exponent. Do not infer current cost from the historical flamegraph.

## Goal

Produce deterministic counters and scaling fixtures that answer:

- how many unique declarations exist;
- how many times each declaration category is prepared and published;
- how many `Scope` and `Env` values are published;
- how many symbols use single-item versus batch insertion;
- how work changes with module count, import fan-out, declarations per module,
  and duplicate-name pressure; and
- whether current-main self-compilation still exhibits superlinear growth.

This issue makes no production representation change.

## Production Boundaries To Instrument

Primary files:

- `blorp/src/compiler/stage_05_types/env.brp`
- `blorp/src/compiler/stage_06_typecheck/decl.brp`
- `blorp/src/compiler/stage_06_typecheck/headers/type_header_install.brp`
- `blorp/src/compiler/stage_06_typecheck/modules/bound_module_graph.brp`
- `blorp/src/compiler/stage_06_typecheck/modules/module_binding.brp`

Instrument the exact paths used by:

- `scope_add_symbol`;
- `scope_add_type_declaration_symbols`;
- `env_add_symbol`;
- `env_add_type_declaration_symbols`;
- `register_callable_header`;
- `typecheck_register_imported_signature_decls`;
- `typecheck_register_import_module_types`;
- `typecheck_register_direct_import_module_decls`; and
- `prepare_accepted_body_module`.

Do not duplicate those algorithms in the benchmark.

## Required Observation

Use the existing `compiler_frontend_declaration_catalog_profile` harness as the
Issue 15 surface. Do not add observation fields to `TypecheckState`, `Env`,
`Scope`, accepted graph records, or process globals. Keep four evidence classes
separate: semantic inventory, modeled direct-API representation work with
`expected_*` workload facts, exact production function counts from existing
instrumentation, and replay cost from `benchmarks/compiler_typecheck_replay`.

The semantic observation product remains bounded and primitive, and unique
denominators are computed once from canonical graph declarations by category:

```text
modules_prepared
unique_modules
unique_type_declarations
unique_constructors
unique_callables
unique_globals
unique_traits
unique_implementations
visible_module_edges
direct_module_edges
imported_type_installations
imported_callable_installations
imported_global_installations
imported_trait_installations
imported_implementation_installations
local_declaration_installations
```

Rows must distinguish canonical graph preparation, initializer preparation, and
CTFE artifact preparation. The CTFE artifact row exercises
`graph_facts_ctfe_artifact_typecheck_module` separately and must not be silently
mixed with the canonical graph row. Initializer rows execute
`initializer_module_base_state` and the completed-global initializer path as
semantic-path checks; exact completed-global installation counts come only from
an emitted function-profiler boundary when available.

Also report:

```text
declaration_installation_factor = total installations / unique declarations
scope_publications_per_symbol
env_publications_per_symbol
installations_per_visible_edge
installations_per_direct_edge
```

The observation must be disabled by default, deterministic, and returned to a
benchmark-facing caller. Do not use process-global mutable counters or print
from production helpers.

## TDD Sequence

1. Add a fixture with two modules and one direct import.
2. Assert exact unique declaration and installation counts.
3. Add a diamond import graph and assert that unique declaration counts do not
   change when the same dependency is visible through two paths.
4. Add a dense graph and assert the currently observed installation
   multiplicity. This assertion should initially document the old work, not the
   desired future count.
5. Add mixed type, constructor, callable, global, trait, and implementation
   declarations so every category counter is exercised.
6. Add a checksum over accepted results and diagnostics so a lower counter
   cannot pass by skipping work.

## Scaling Fixture

Extend the existing frontend declaration-catalog benchmark surface instead of
creating a parallel scope-materialization framework:

- `compiler/benchmarks/compiler_frontend_declaration_catalog_profile_fixture.brp`
- `compiler/benchmarks/compiler_frontend_declaration_catalog_profile.brp`
- `blorp/test/compiler/stage_06_typecheck/test_frontend_declaration_catalog_profile_benchmark.brp`
- `benchmarks/compiler_frontend_declaration_catalog_profile`
- the existing production ownership mapping for `decl.brp`

Independent controls:

```text
module_count: 8, 16, 32, 64
declarations_per_module: 4, 16, 64
direct_import_fanout: 1, 4, 16
graph_shape: chain, star, layered, dense
body_count_per_module: 0, 1
```

Fixture construction must be outside the measured window. Every row must
report all structural counters, elapsed microseconds, allocations, releases,
retained objects, allocator bytes, errors, and a deterministic result checksum.

For each doubling series report:

```text
doubling_ratio = work(2N) / work(N)
growth_exponent = log2(doubling_ratio)
```

Flag two consecutive deterministic-counter ratios above `2.20`, or measured
allocation/time exponents above `1.20` after setup is excluded.

## Production Baseline

Capture one compiler request and preserve its hash:

```bash
capture=$(mktemp "${TMPDIR:-/tmp}/blorp-scope-materialization.XXXXXX.json")
./blorp check --no-format --capture-typecheck-request "$capture" \
  blorp/src/compiler/stage_12_cli/main.brp

benchmarks/compiler_typecheck_replay "$capture" \
  --target-only --timeout 180 --memory-limit 4G \
  --allocator-stats --no-inventory --json
```

Record one warmup and three measured runs. Preserve worker and response hashes,
response bytes, frontend checkpoints, elapsed time, peak RSS, allocations,
releases, current objects, and allocator bytes.

Also regenerate the exact-call-count profile described in:

`logs/compiler-self-profile-2026-08-26-aa269938/exact-counts/REPORT.md`

against current main. Report current counts for `scope_add_symbol`,
`register_callable_header`, and every new counter boundary.

## Issue 15 Evidence

Raw logs are intentionally ignored under
`logs/issue15-20260826-231106-final/` for the final synthetic matrix and
exact-function rerun, and under `logs/issue15-20260826-223804/production-replay/`
for production replay. The evidence is split into four classes: semantic
inventory, modeled direct-API representation facts, exact existing
function-profiler counts, and production replay cost. Modeled `expected_*`
values are closed-form fixture facts, not production publication counts. Missing
function-profiler rows are not replaced with modeled counts. The initializer
row executes the completed-global initializer path as a semantic-path check, but
does not expose an exact completed-global installation counter.

### Synthetic Scaling

`logs/issue15-20260826-231106-final/summary.tsv` contains 60 rows across 15
configurations after the CTFE denominator correction and target-owned category
expansion. Every semantic and direct row reported `workload_valid=True`;
semantic rows reported `error_count=0`. Repeated `chain/8/8/1/0`
configurations produced one stable checksum.

| Series | Step | Unique declarations | Installations | Ratio | Exponent | Elapsed us |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| modules | 4 | 75 | 209 |  |  | 119743 |
| modules | 8 | 143 | 591 | 2.828 | 1.500 | 306288 |
| modules | 16 | 279 | 1883 | 3.186 | 1.672 | 920122 |
| modules | 32 | 551 | 6579 | 3.494 | 1.805 | 3028699 |
| declarations/module | 4 | 127 | 503 |  |  | 250712 |
| declarations/module | 8 | 143 | 591 | 1.175 | 0.233 | 306660 |
| declarations/module | 16 | 175 | 767 | 1.298 | 0.376 | 449794 |
| declarations/module | 32 | 239 | 1119 | 1.459 | 0.545 | 858423 |
| bodies/module | 0 | 143 | 591 |  |  | 309598 |
| bodies/module | 1 | 151 | 614 | 1.039 | 0.055 | 354700 |
| bodies/module | 4 | 175 | 683 | 1.112 | 0.154 | 444093 |

| Shape | Visible edges | Direct edges | Unique declarations | Installations | Factor millis | Elapsed us |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| chain | 36 | 15 | 143 | 591 | 4132 | 306385 |
| dense | 36 | 36 | 143 | 675 | 4720 | 362758 |
| layered | 36 | 21 | 143 | 615 | 4300 | 319347 |
| star | 8 | 8 | 136 | 248 | 1823 | 149882 |

The module-count series exceeds the deterministic-counter threshold for three
consecutive doublings. Declaration count and body count remain sublinear in
installation work for this fixture. This supports proceeding with Issue 16 only
as a representation experiment with production replay as the acceptance gate.

### Exact Function Counts

Captured from the final-source rerun in
`logs/issue15-20260826-231106-final/function-instrumentation/chain_8x8.function-profile.log`.

| Boundary | Exact calls | Status |
| --- | ---: | --- |
| `scope_add_symbol` | 5972 | captured |
| `scope_add_type_declaration_symbols` | 335 | captured |
| `env_add_symbol` | 4929 | captured |
| `env_add_type` | 1081 | captured |
| `env_add_type_with_constructor_ids` | 1297 | captured |
| `env_add_trait` |  | unavailable: exact boundary name not emitted; only generated consume helper appeared |
| `env_add_trait_function` | 3058 | captured |
| `env_add_impl` | 2680 | captured |
| `env_add_overload` |  | unavailable: absent from this workload's emitted profile rows |
| `env_add_ufcs_method` |  | unavailable: absent from this workload's emitted profile rows |
| `register_callable_header` |  | unavailable: source boundary exists but exact function name is not emitted in this profile |
| `register_trait_header` | 87 | captured |
| `register_implementation_header` |  | unavailable: source boundary exists but exact function name is not emitted in this profile |
| `typecheck_register_imported_signature_decls` | 52 | captured |
| `typecheck_register_import_module_types` | 136 | captured |
| `typecheck_register_direct_import_module_decls` | 52 | captured |
| `typecheck_register_import_modules_from` | 35 | captured |
| `initializer_module_base_state` | 18 | captured |
| `install_completed_globals_for_initializer` |  | unavailable: initializer path is executed as a semantic-path check, but this exact installation boundary is not counted or emitted |
| `graph_facts_ctfe_artifact_typecheck_module` |  | unavailable: CTFE row is semantically represented, but this exact name is not emitted |
| `typecheck_bind_program_module_view` | 17 | captured |
| `typecheck_state_record_type_home` | 878 | captured |

### Production Replay Baseline

Capture and worker identities:

| Item | Value |
| --- | --- |
| Source commit | `22d0e3d4b295eea43bf3cf70254effedd019f0a0` |
| Capture path | `logs/issue15-20260826-223804/production-replay/compiler-main.typecheck-request.json` |
| Capture bytes | 10977279 |
| Capture SHA-256 | `97f6e1ff71f4d74b437e763a89e6efa230c425e609ba93f688dd9093be2ec658` |
| Replay request SHA-256 | `cd19c742d03ebf1bd010d97ed943268f716bf5c9fc18ea256d82a97805856e17` |
| Target source SHA-256 | `d732a4bfed4c5037afd10c22cf0a42a8505f326110fad07673e590f2800c79e3` |
| Replay script SHA-256 | `527bbac12065bf646ffbf780998fbc73e6b7c7e81ac0b664f95de0bc3e11ae09` |
| Worker source SHA-256 | `70b366f777f0e6e9d9d450a287c31a3c589889213e198d62f4e3ea9569d74ee7` |
| Prepared worker SHA-256 | `21445d45cc13d028a3b67caf738c118dab4bb1c139cb3cd7579e1e21a0e43a9f` |
| Response SHA-256 | `ebc79e9379c873c5f26029cbe184691cc0c98b4dc4aa8e04fb467f8424689839` |
| Response bytes | 2030349 |

One warmup and three measured serial replays used `--target-only --timeout 180
--memory-limit 4G --allocator-stats --no-inventory --json`. All measured runs
were verified, had allocator stats available, did not time out, did not hit the
memory limit, and produced byte-identical responses.

| Metric | Median | Min | Max |
| --- | ---: | ---: | ---: |
| elapsed seconds | 48.663655 | 48.584324 | 48.761557 |
| peak RSS bytes | 1044447232 | 1044381696 | 1044561920 |
| total allocations | 280380907 | 280380907 | 280380907 |
| total releases | 271426638 | 271426638 | 271426638 |
| current objects | 8954269 | 8954269 | 8954269 |
| allocator bytes | 694529168 | 694529168 | 694529168 |

| Checkpoint | Median us | Min us | Max us |
| --- | ---: | ---: | ---: |
| graph parse complete | 4677657 | 4673180 | 4743260 |
| graph declaration skeleton complete | 3143282 | 3122430 | 3208348 |
| graph CTFE plan complete | 16445 | 16217 | 44826 |
| CTFE dependency typecheck complete | 25318360 | 25206856 | 25413450 |
| typecheck complete | 625133 | 617283 | 659137 |
| projection complete | 95643 | 94836 | 98758 |
| typed artifact scope complete | 1175 | 1169 | 1216 |

### Recommendation

Proceed with Issue 16 only under its measurement gates. Issue 15 shows
superlinear module-scaling installation work in the deterministic fixture and a
large production replay baseline, but it also shows that existing function
instrumentation cannot expose every requested low-level boundary by exact name.
Issue 16 must therefore keep semantic inventory, direct modeled facts, exact
available function counts, and replay cost separate, and must not claim exact
production counts for boundaries the current profiler does not emit.

## Acceptance Criteria

- The observation follows the production registration path.
- All counters have focused exact-value tests.
- Chain, star, layered, and dense graphs produce valid checksums.
- Current scaling ratios and production replay data are recorded in this issue.
- Normal compilation behavior and output are unchanged.
- Observation overhead is measured and stays below 3% when enabled; disabled
  overhead is zero or below measurement resolution.
- The issue concludes with an explicit proceed/reject recommendation for Issues
  16-23 based on current evidence.

## Merge Point

This is a valid merge point because it adds opt-in measurement and tests without
changing production representation or lookup behavior.
