# Batch Callable-Header Publication

**Status:** Rejected after focused measurement

## Context And Dependencies

This issue evaluated the measured environment-publication candidate from
[`05-callable-header-registration.md`](05-callable-header-registration.md).
Issue 15 proved callable installation remains material on current main.
Issue 16 provided the tested mixed-symbol batch primitive.

Historical evidence showed 623,368 `register_callable_header` calls and 589,023
`register_callable_header_for_source` calls while compiling the compiler.
The inclusive registration path was 17.28% of samples, but much of that cost
belongs to descendants such as `scope_add_symbol`. Treat the inclusive value as
context, not recoverable time.

## Problem Statement

`typecheck_register_imported_signature_decls` and local signature registration
thread a complete `TypecheckState` through one declaration at a time. Callable
header conversion, identity validation, diagnostics, overload metadata, and
scope publication are interleaved.

Only publication should be batched. Semantic conversion and diagnostics must
retain source order and fail-closed behavior. A batch that prepares all symbols
without respecting dependencies on previously registered headers would be
incorrect.

## Goal Evaluated

Separate callable-header preparation from environment publication, then publish
one ordered callable group at a proven atomic declaration-list boundary.

The issue had to reduce `Scope`/`Env` publications without skipping semantic
conversion, caching by string name, or deferring errors. The candidate did
reduce physical publications, but it failed the focused allocation gate, so no
production code change was retained.

## Experimental Dependency Audit

The discarded candidate included a behavior-neutral extraction that separated
`prepare_callable_header` from immediate `register_callable_header`
publication. That experimental preparation path was audited before changing
publication behavior.

| Code path | Reads | Dependency class | Can observe header N's newly published callable while preparing header N+1? |
| --- | --- | --- | --- |
| `register_local_callable_headers` | `callable_header_graph_callables`, each header's callable module identity | accepted graph fact | No. The loop selects graph-owned headers and passes the threaded state onward, but the selection itself does not inspect `Env` callable symbols. |
| `register_callable_header_for_source` | `typecheck_state_find_func_callable_id`, `callable_header_graph_find_definition_id` | identity reservation/claim, accepted graph fact | No. Lookup is through the module-scope definition index and accepted callable graph, not the published `Env` function scope. |
| `callable_header_semantic_type` | `local_semantic_type_from_resolved_shape` or `imported_semantic_type_from_resolved_shape` over `TypeHeaderGraph`, owner identity, and owner/module path | module/type header fact | No. Resolved callable parameter, return, and dimension-constraint types come from type-header graph facts, not `Env` function lookup. |
| `validate_resource_result_annotation` | `state.errors`, annotations/body metadata, `resource_type_scan_context(state.env, state.known_type_index)` | diagnostic/error state, existing environment declaration | No callable-symbol dependency found. The resource scan resolves aliases and resource type facts (`env_resolve_alias_head`, `env_type_is_resource`) and does not call function lookup, callable-ID lookup, overload lookup, UFCS lookup, or `env_symbols_named`. |
| `validate_resource_signature_boundary` | current diagnostic state, parsed params, semantic types, `resource_type_scan_context(next.env, next.known_type_index)` | diagnostic/error state, existing environment declaration | No callable-symbol dependency found. It appends diagnostics in order and uses Env only for type alias/resource classification. |
| `function_resource_arg_policy` | annotations/body metadata, `resource_type_scan_context(state.env, state.known_type_index)` | existing environment declaration | No callable-symbol dependency found. It computes only resource argument policy from already converted semantic types. |
| `callable_key_from_span` | current module identity, name, span | identity reservation/claim | No. It forms the key used for definition-index operations. |
| `typecheck_state_claim_func_callable_id` | module identity, module-scope definition index, and in extensible scopes `env.next_def_id` through `env_mint_def_id` | identity reservation/claim | No function-symbol lookup. The identity frontier is stateful, so preparation must remain sequential and in existing source/graph order. |
| Successful publication leaf | `env_add_func_with_info` | publication-only environment update | Yes, this is the only callable symbol publication. It currently happens once per successfully prepared header and is the only boundary proposed for batching. |

Audit conclusion: preparation of header N+1 does not read the callable symbol
published for header N. The only `Env` reads in preparation are type/resource
classification reads, and function-symbol publication happens at the terminal
success leaf. Therefore a declaration-list boundary may prepare headers
sequentially in the current order, preserve all diagnostics and identity
frontier updates, and defer only the successful callable-symbol publications
until the end of that same list.

## Evaluated Representation And Env Boundary

The measured candidate used a narrow private phase product storing the exact
item consumed by the Env publication API:

```blorp
private record CallableHeaderPreparation {
	state: TypecheckState,
	registration: Option[(String, FuncSymbol)]
}
```

It carries no source-order field because source order is represented by the
prepared list order. It carries no parsed declaration copy, overload fact, trait
fact, or generic transaction state because `register_callable_header` currently
publishes only a function symbol. This remained a record because Blorp structs
cannot store `TypecheckState`, `Option`, or tuple fields; the benchmark must
measure that one transient result allocation per prepared header against the
Scope/Env publications removed by batching. That overhead was part of the
accepted measurement risk and contributed to the poor allocation result.

The evaluated Env-level publication boundary was:

```blorp
pure func env_publish_callable_header_symbols(
	env: Env,
	registrations: List[(String, FuncSymbol)],
) -> Env
```

If Blorp module visibility requires this to be exported from `env.brp`, keep the
type this narrow and document it as the callable-header publication boundary.
The implementation should build the ordered `Symbol` list internally and
delegate to Issue 16's private `scope_add_symbols`; it must not expose `Scope`
or make `scope_add_symbols` public.

Ordering and duplicate semantics:

- `registrations` are consumed in source/graph order for one declaration list.
- Same-name lookup remains newest-first, matching repeated
  `env_add_func_with_info` calls.
- Duplicate callable IDs remain last-wins in the callable-ID index, matching
  `scope_add_symbol`/`scope_add_symbols`.
- Empty input returns the original `Env`; singleton input is behavior-equivalent
  to `env_add_func_with_info`.
- Function-symbol publication does not invalidate type containment because the
  current per-header function insertion path does not install type bindings.

Counter semantics:

- `CALLABLE_HEADER_PROFILE_ENVIRONMENT_INSERTIONS` remains a per-header logical
  successful-registration counter. It is emitted once for each successful
  prepared callable, even when publication is batched.
- `CALLABLE_HEADER_PROFILE_ENVIRONMENT_PUBLICATION_GROUPS` is the physical
  publication counter. It is emitted once per non-empty
  `env_publish_callable_header_symbols` group, including the immediate
  singleton adapter used by paths not yet batched.

Preparation must continue to return errors explicitly and thread any identity
frontier in the same order as today. Publication must accept only successfully
prepared items from the same declaration-list boundary.

## Mechanical Sequence Evaluated

1. Add a focused observation asserting current conversions, claims, symbols,
   overload facts, scope publications, and env publications per declaration
   list.
2. Extract a private `prepare_callable_header` from
   `register_callable_header`; initially publish its result immediately so the
   refactor is behavior-neutral.
3. Add exact equivalence tests for prepared products and diagnostics.
4. Add a private `publish_callable_header_registrations` that consumes an
   ordered list and Issue 16's mixed-symbol batch.
5. Preserve sequential construction of overload, trait, and ID facts through
   local accumulators. Publish each associated `Env` field once where its
   semantics allow.
6. Migrate local callable declaration lists first.
7. Measure and verify.

The implementation stopped at local callable declaration-list measurement. The
candidate failed the allocation gate, so imported publication was not cut over,
production replay was not run, and temporary production, runtime, benchmark,
README, and test changes were removed before committing this documentation-only
result.

## TDD Coverage

Primary suites:

- `compiler/tests/test_compiler_callable_headers.brp`
- `compiler/tests/test_compiler_implementation_headers.brp`
- `compiler/tests/test_compiler_global_header_completion.brp`
- `compiler/tests/test_compiler_typecheck_decl.brp`
- `compiler/tests/test_compiler_env.brp`

Required cases:

1. Empty and one-header groups.
2. Source, foreign, builtin, and implementation method headers.
3. Generic bounds and dimension constraints.
4. Resource arguments/results and rejection diagnostics.
5. Pure/impure overload pairs.
6. Same-name overload order.
7. Duplicate/conflicting callable identities.
8. A malformed middle header followed by a valid header; diagnostics and
   identity assignment must match the baseline exactly.
9. Trait methods and owner identity.
10. Imported and local declarations with the same spelling.
11. Debug-only and foreign policy metadata.

Compare exact errors, help text, source spans, IDs, symbol lookup order,
overload order, and typed result checksum.

## Focused Measurement Result

Controlled local workload measurement used two temporary source trees created
from the same candidate tree. The baseline tree differed only by restoring
immediate publication inside `register_local_callable_headers`; the candidate
kept local batch publication. Both trees had identical runtime counter schema,
fixture, runner, tests, and docs.

```text
base commit: f7537a9ebb53c4a164e90b294fa45dca584b0f5c
log path: logs/issue17-local-batch-20260827-011402-a
bootstrap compiler sha256: 45af71efeb59724fa445f3f958ba05b2166a2c99a4dc16eef621d9eb6c0741c1
candidate patch sha256: 67e9d5ffb2a95653402ad571ffb7e0d713de19555c90f352a1284e403eab3f5f
candidate patch bytes: 52021
baseline-vs-candidate patch sha256: 86dc0af39801ee643334254bd903e8ddf0ee74fad2f65aeceeb5620ce05dcbfa
baseline-vs-candidate patch bytes: 1312
baseline worker sha256: ea53614c88ed621885002982f63aadb4320a9aaaf0ed019d1bebb8917d35ad72
candidate worker sha256: 647699ff0cc618886a354bbcb004e959d21ba88735ca107770186323bd6c447d
```

Command shape:

```text
benchmarks/compiler_callable_header_profile 5 0 0 4 2 fallback H
```

Rows alternated baseline then candidate for each pair and for target headers
`1, 16, 64, 256, 1024`. Each worker received one warmup before measurement.
All measured rows had identical artifact/header/declaration/error/checksum
fields and identical logical counters except the physical publication-group
counter. `errors=0` and `workload_valid=True` for all rows.

The local target list is currently registered twice per benchmark iteration.
With five benchmark iterations, `environment_insertions=10 * H`, candidate
physical publication groups are `10`, and baseline physical publication groups
are `10 * H`. This repeated target registration factor is real evidence for
Issues 19-23 and was not normalized away.

| Target headers | Worker | Elapsed microseconds samples | Elapsed median | Allocations samples | Allocations median | Environment insertions | Publication groups | Group/insertion ratio | Repeat registrations |
| ---: | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | baseline | 37067,37584,38000 | 37584 | 95625,95625,95625 | 95625 | 10,10,10 | 10,10,10 | 1,1,1 | 9,9,9 |
| 1 | candidate | 36526,36441,37906 | 36526 | 95625,95625,95625 | 95625 | 10,10,10 | 10,10,10 | 1,1,1 | 9,9,9 |
| 16 | baseline | 164823,165351,168979 | 165351 | 330760,330760,330760 | 330760 | 160,160,160 | 160,160,160 | 1,1,1 | 144,144,144 |
| 16 | candidate | 163793,163369,164348 | 163793 | 329470,329470,329470 | 329470 | 160,160,160 | 10,10,10 | 0.0625,0.0625,0.0625 | 144,144,144 |
| 64 | baseline | 573551,577763,579395 | 577763 | 1083040,1083040,1083040 | 1083040 | 640,640,640 | 640,640,640 | 1,1,1 | 576,576,576 |
| 64 | candidate | 573091,570774,571336 | 571336 | 1077470,1077470,1077470 | 1077470 | 640,640,640 | 10,10,10 | 0.015625,0.015625,0.015625 | 576,576,576 |
| 256 | baseline | 2290535,2287355,2273135 | 2287355 | 4093360,4093360,4093360 | 4093360 | 2560,2560,2560 | 2560,2560,2560 | 1,1,1 | 2304,2304,2304 |
| 256 | candidate | 2283969,2311799,2258755 | 2283969 | 4070550,4070550,4070550 | 4070550 | 2560,2560,2560 | 10,10,10 | 0.00390625,0.00390625,0.00390625 | 2304,2304,2304 |
| 1024 | baseline | 10481178,10572958,10422123 | 10481178 | 16135960,16135960,16135960 | 16135960 | 10240,10240,10240 | 10240,10240,10240 | 1,1,1 | 9216,9216,9216 |
| 1024 | candidate | 10176141,10221609,10447087 | 10221609 | 16044070,16044070,16044070 | 16044070 | 10240,10240,10240 | 10,10,10 | 0.000976562,0.000976562,0.000976562 | 9216,9216,9216 |

| Target headers | Allocation delta | Allocation reduction | Elapsed delta | Elapsed reduction |
| ---: | ---: | ---: | ---: | ---: |
| 1 | 0 | 0.00% | -1058 us | 2.82% |
| 16 | -1290 | 0.39% | -1558 us | 0.94% |
| 64 | -5570 | 0.51% | -6427 us | 1.11% |
| 256 | -22810 | 0.56% | -3386 us | 0.15% |
| 1024 | -91890 | 0.57% | -259569 us | 2.48% |

The benchmark summary emitted total allocation count and `bytes_allocated`.
`bytes_allocated` was `0` in every stdout summary. Release/current-object/
current-byte counters were not available in this wrapper output.

Conclusion: physical publication groups collapsed, from `10 * H` to `10` in
this workload, but total allocation work barely moved. The best measured
allocation reduction was 0.57%, and the required gate was at least 25% at 256
headers. The local batching candidate is rejected. No production replay was run
because the focused allocation gate failed.

## Pitfalls

- Do not batch across a diagnostic-order boundary.
- Do not publish symbols from rejected headers.
- Do not claim IDs in a different order.
- Do not merge local and imported visibility semantics.
- Do not retain both prepared products and copied parsed declarations beyond
  publication.
- Do not create a generic transaction framework; keep the product specific to
  accepted callable headers.

## Acceptance Outcome

- Preparation and publication were proven separable for local callable headers.
- Existing semantic fields and logical counters matched in the focused matrix.
- Scope/env publication groups materially decreased.
- Focused allocations did not improve materially: 0.56% at 256 headers versus
  the required 25%.
- Imported publication was not cut over.
- Production replay was not run.

## Merge Point

Only this documentation result is independently mergeable. No production,
runtime, benchmark, README, or test changes are retained from the rejected
candidate.
