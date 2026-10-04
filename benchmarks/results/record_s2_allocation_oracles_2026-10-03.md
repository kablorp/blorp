# Managed-product allocation oracle checkpoint

Worktree: `r2-ownership-questions/blorp`, base `d29b264e1a74` plus integrated
S2/S3/S4 semantic changes. Compiler build status was FRESH, CLI/runtime `-O2`,
compiled by `dev-0322140767b0`. Binary SHA-256:
`36b5baf3787e35b0b91fb0673fe133bb2d1f29c318837b7230eb991dc72e4ee0`.
All compiled runs were serial under the coordinator's sole-slot grant.
The default run/test child uses BuildFast (`-O0` generated C), independently
of the compiler executable's `-O2` build. Neither release nor sanitizer was enabled.

## Discovery

Retained probe: `benchmarks/blorp/compiler_discovery_record_allocations.brp`.
Inputs are built before reset; the owning parser helper checks diagnostic-free
discovery, retained token population, and both diagnostic gates. Scalar reads
precede reporting. Both complete no-debug runs succeeded with identical SHA-256
`f59c1c1817465a7fe49ea5c3712d72ae2900540765ae68a8567a795933c47ffb`.
Both matched debug runs also succeeded with identical SHA-256
`fb7a81039cc270d1606edba1fe278a54b815b5ad86cb8dcb47a0ea18c013914a`.
Every debug count exactly matches the owning-suite diagnostic measurement.

```sh
bin/blorp run --no-format --memory-stats --timeout 180 benchmarks/blorp/compiler_discovery_record_allocations.brp
bin/blorp run --no-format --debug --memory-stats --timeout 180 benchmarks/blorp/compiler_discovery_record_allocations.brp
```

Each family uses 2,000 repeats:

| Family | No-debug allocations | Debug allocations (test pin) |
| --- | ---: | ---: |
| expression_statements | 52151 | 58152 |
| blocks_and_calls | 138158 | 150159 |
| matches_and_patterns | 240171 | 262172 |
| selects | 156162 | 170163 |
| concurrent_blocks | 266173 | 290174 |
| lambdas | 186167 | 206168 |
| interpolations | 154191 | 164192 |
| record_literals_and_updates | 150164 | 166165 |
| loops | 218159 | 238160 |
| question_binds | 94162 | 102163 |
| function_declarations | 230226 | 232226 |
| type_declarations | 300126 | 300126 |
| trait_and_impl_declarations | 246186 | 248186 |
| imports | 90126 | 90126 |
| collection_literals | 292178 | 316179 |
| tuple_list_and_qualified_patterns | 434179 | 474180 |
| with_scopes | 164164 | 182165 |
| conversions_and_builtins | 146167 | 158168 |
| bindings_and_local_functions | 196210 | 206211 |
| postfix_chains_and_unary_operators | 252171 | 282172 |
| written_types | 486217 | 488217 |
| foreign_blocks | 206184 | 206184 |
| supertraits | 308193 | 310193 |

The direct 2,000-step append workload measured 6,020 allocations: three managed
products per step (DefinitionRow, NodeRow, its child-span record), plus 20 list
growth allocations. Definition and node populations are explicitly checked.
The old shared 500 ceiling is retired. Every family and direct-row case uses
its measured debug pin with the existing fixed strict +/-100 tolerance, not a
percentage allowance. One extra copy per repeat adds at least 2,000 objects
and still fails, even at the largest 488,217 pin. Lower counts also fail until
an intentional allocation removal is independently measured and re-pinned.

## Runtime and owned workloads

Flat/nested record workloads measured allocations/releases/live residual
`2/2/0` and `3/3/0`, respectively, identically for struct/fixed spellings.
Vector literal/fill, matrix literal/fill, and ten index updates measured
`10/3/5/2/22` allocations. These are exact named pins; fill additionally checks
shared record identity, updates check written and untouched values. Observers
are scalar counters, with no report-record subtraction or hidden traffic.

The Blorp allocation-oracle shell gate initially passed 10/11 cases. Its
nested-field family has newly managed Row values: six shapes measured
`1018/10026`, chain/conditional `1027/10039`, and the double-parent method
chain `2020/20028` for 1,000/10,000 steps. Exact pins now cover those values,
with logical completeness, active gates, and residual capacity-growth checks.
The two intern shapes retain their existing growth-only guard; no unmeasured
count was assigned. Other consuming update/builder/threading and tuple shapes,
scalar/loop/map counter intervals, and diagnostic flag checks passed unchanged.

Raw logs under `/tmp/blorp-record-through-s4.5K6t2p/`:

- `s2-discovery-probe-first.log`, `s2-discovery-probe-repeat.log`
- `s2-discovery-debug-probe-first.log`, `s2-discovery-debug-probe-repeat.log`
- `s2-discovery-debug-pinned-tests.log` (24/24 pass)
- `s2-budget-first-tests.log` (discovery 24/24 fail; fixed 2/2 fail; vector 2/5 fail)
- `s2-budget-measured-tests.log`, `s2-runtime-measure-repeat.log`
- `s2-scalar-oracle-first.log` (10 pass, 1 explained managed-row failure)
- `s2-budget-pinned-first.log` (post-pin source grouping errors, not acceptance)

Post-pin acceptance: fixed-record 2/2, vector/matrix 5/5, String 21/21,
erased channel 4/4 pass (`s2-budget-postpin.log`). The complete scalar oracle
gate passes 11/11 (`s2-scalar-oracle-postpin.log`), including the exact nested
managed-row pins and unchanged growth controls.

Discovery acceptance is now 24/24. The initial post-pin 4/24 result is retained
in `s2-budget-postpin.log`: it used no-debug pins for a debug-enabled harness.
`blorp/src/test/plan.brp:test_run_options` forces `debug=True`.
`tables/node_builder.brp:append_parent_node_from_stack_with_payload` invokes
`kind.node_schema().arity.arity_admits(count)` inside a debug block. The
`NodeSchema` product returned by `row_kinds.brp:shape` is now managed: one
allocation per parent-node check. Expression statements have three parent
nodes per repeat plus the enclosing body, explaining exactly +6,001;
blocks add +12,001, matches +22,001, several declarations +2,000. This is
debug invariant cost, not evidence of a table-copy ownership regression.
The diagnostic counts are retained in `s2-discovery-postpin-actual.log`.

Matched probe compilation retains debug blocks, enables diagnostic runtime,
disables formatting, and uses default single-TU BuildFast with no sanitizer,
leak-check or function profiling. Unlike the test harness, `--memory-stats`
enables startup stats reporting. `parse_allocations` calls `reset_mem_stats`
before the workload: runtime epoch counters are zeroed and counters/metadata
enabled identically, followed by both fail-closed active gates. Startup/report
traffic therefore does not enter the measured managed interval.
Only exact confirmed debug pins changed; strict +/-100 was not loosened.
The compile slot was released after the successful owning suite rerun.

No production spellings, bootstrap pins, or releases changed. Outstanding
heap-row optimization remains separate S5 work.

## Outstanding oracle audit — NOT run / NOT accepted

Read-only source audit found four definite stale runtime expectations:

- `blorp/test/runtime/memory/test_memstats_observability.brp:25`: snapshot
  `refcount == 0`; replace with measured managed identity/retention coverage.
- `blorp/test/runtime/concurrency/test_scheduler_stats.brp:537`: same stale
  snapshot expectation; retain exact scheduler field/reset semantics.
- `blorp/test/runtime/types/test_type_name_generic.brp:66–71`: generic
  struct-alias `is_heap == False`; ordinary managed product should be True,
  retaining the alias's type-name identity and scalar Option's False case.
- `blorp/test/runtime/types/test_stack_option.brp:558–593`: managed Point
  construction mixed into a `<10` scalar Option oracle. Split genuine scalar
  no-traffic coverage from separately measured managed construction.

`blorp/test/runtime/types/test_struct_vector.brp:370–404` has an obsolete inline
layout explanation and `<50` live-object cap. Its vector has no use after the
loop, so its lifetime at the snapshot is **unproven**. Inspect generated C and
measure a deliberately retained owner at scalar endpoints; do not guess 101.

Nine definite stale codegen fixtures under
`blorp/test/compiler/pipeline/codegen_audit/should_pass/`:

- `fixed_record_matches_struct_layout.brp:1–12`
- `blorp_backend_value_record_construct.brp:5–12`
- `blorp_backend_cross_module_struct_field.brp:1–7`
- `blorp_backend_value_record_range.brp:2–5`
- `vector_parallel_map_inline_result_layout.brp:1–5`
- `vector_struct_get_or_inline_storage.brp:1–5`
- `union_struct_enum_payload_typed.brp:1–10`
- `erased_union_boxed_payload_ownership.brp:1–10`
- `canonical_empty_list_literals.brp:6,9`

Keep their source/output logical coverage. Replace only observed obsolete C
layout assertions with actual managed header/pointer/ownership expectations;
do not guess generated identifiers or remove gates. Two mixed fixtures need
observed C: `parallel_filter_map_stack_fallback.brp` uses managed Point where
its comment claims generated-stack fallback; `option_generated_stack.brp`
mixes Point with genuine Int128/UInt128/bounded-Range/enum stack coverage.
Keep the supported scalar paths independently protected.

True snapshot before/after reporting intervals now include observer traffic:
`blorp/benchmark/compiler/compiler_core_flatten_profile.brp:117–123`,
`blorp/test/compiler/tools/discovery_adapter_cost.brp:239–243`, and
`blorp/test/compiler_new/tools/{builder_append_probe,builder_rule_probe,
discovery_dump,parse_dump}.brp`. General `mem_delta` stays honest; isolated
workload measurements require scalar endpoints, not subtract-one constants.
Reset-separated benchmark segments and graph release comparisons remain
native-first reports: saved earlier snapshots belong to the previous epoch.
Native C snapshot tests remain nonallocating and need no observer allowance.

Next feedback, only after the coordinator grants a serial compile slot:
`bin/blorp test --timeout 180` with the five runtime paths above, plus actual
generated-C inspection and the codegen-audit gate for the listed fixtures.
The coordinator owns checkpoint/bootstrap reconciliation and routes any
implementation; this audit authorizes no production changes. None of these
outstanding cases was edited or run during this audit.
