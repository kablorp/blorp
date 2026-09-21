# Source Discovery Self-Compile Profile — 2026-09-20

This is the retained exploratory evidence for the six workstreams in
[`docs/SOURCE_DISCOVERY_PERFORMANCE_ROADMAP.md`](../../docs/SOURCE_DISCOVERY_PERFORMANCE_ROADMAP.md).
It ranks mechanisms within one discovery-only profile; it is not a statistical
runtime comparison or an acceptance baseline.

## Provenance

- Source and frozen input revision:
  `4054fe4d8350df1fab96b5ae8a8c2435e9b55608`
- Branch at capture: `main`, equal to `origin/main`
- Compiler: `bin/blorp`, `-O0`, build status `FRESH`, eight translation units
- Compiler SHA-256:
  `d58bee8fffd063b4dba29188180acd06888497f954323edb714913533a7a275d`
- Bootstrap: `dev-31e3206c9438 0.0.1-dev.31e3206c9438`
- Host: Apple Silicon, Darwin 25.6.0; `/usr/bin/time -l` counters
- C compiler: Apple clang 21.0.0 (`clang-2100.3.34.2`)
- Workload: frozen `blorp/src/main.brp` with its frozen
  `standard_library/src`, `compile --ast --no-format`; typechecking and C
  emission did not run
- AST output: 955 bytes, SHA-256
  `f381a6bb6c93839b054668d6aced02ee42360ff14d66f8129c2821c251c6b294`

The worktree was clean for the profile. The later AST hash confirmation had
only this docs-only roadmap change present; `bin/blorp` still matched the same
compiler inputs and SHA.

## Discovery-only command

```bash
input=$(benchmarks/self_compile_measure freeze \
  --rev 4054fe4d8350df1fab96b5ae8a8c2435e9b55608)

BLORP_COMPILER_MEMORY_PROFILE=1 /usr/bin/time -l \
  bin/blorp compile --ast --no-format \
  --std-dir "$input/standard_library/src" \
  "$input/blorp/src/main.brp" \
  >/tmp/discovery.ast 2>/tmp/discovery.stderr
```

One warmup preceded five measured runs. The table reports deltas between the
`source_discovery_start` and `source_discovery_complete` checkpoint totals,
not process-lifetime totals.

| sample | checkpoint seconds | allocations | releases | live delta | allocator-byte delta | peak RSS bytes | wall seconds | retired instructions | cycles |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 1.370890 | 11,873,195 | 9,917,329 | 1,955,866 | 145,881,168 | 196,296,704 | 1.41 | 19,512,177,609 | 5,702,573,146 |
| 2 | 1.426633 | 11,873,195 | 9,917,329 | 1,955,866 | 145,881,168 | 199,196,672 | 1.47 | 19,500,742,428 | 5,784,813,478 |
| 3 | 1.425385 | 11,873,195 | 9,917,329 | 1,955,866 | 145,881,168 | 200,228,864 | 1.46 | 19,489,177,813 | 5,783,693,611 |
| 4 | 1.371278 | 11,873,195 | 9,917,329 | 1,955,866 | 145,881,168 | 195,952,640 | 1.41 | 19,487,903,815 | 5,685,459,519 |
| 5 | 1.384839 | 11,873,195 | 9,917,329 | 1,955,866 | 145,881,168 | 197,181,440 | 1.42 | 19,491,297,701 | 5,720,780,130 |
| median | 1.384839 | 11,873,195 | 9,917,329 | 1,955,866 | 145,881,168 | 197,181,440 | 1.42 | 19,491,297,701 | 5,720,780,130 |

Retired instructions ranged from 19,487,903,815 to 19,512,177,609, a spread
of about 0.12% of the median.

The first sample's process-lifetime allocation histogram, emitted at teardown,
was:

```text
bucket_le_16=0
bucket_le_32=1385958
bucket_le_48=5051797
bucket_le_64=1313077
bucket_le_96=3837172
bucket_le_128=169742
bucket_le_192=110841
bucket_le_256=7878
bucket_le_384=4676
bucket_le_512=1080
bucket_le_1024=2617
bucket_gt_1024=9362
```

The buckets sum to 11,894,200 allocations, 21,005 more than the discovery
checkpoint delta because they include process setup and teardown. The buckets
through 96 bytes contain 11,588,004 allocations, 97.4% of that process-lifetime
total. Since discovery accounts for 99.8% of allocations in this `--ast` run,
the histogram is a close proxy for discovery's size distribution, not a
phase-exact histogram.

## Calls profile

The compiler was regenerated in calls mode for only the discovery owners:

```bash
modules=(
  blorp/src/compiler/pipeline
  blorp/src/compiler/stage_02_lex/lexer
  blorp/src/compiler/stage_03_parse/language_parser
  blorp/src/compiler/stage_03_parse/source_ast_finalize
  blorp/src/compiler/stage_04_modules/frontend_graph
  blorp/src/compiler/stage_04_modules/frontend_graph_service
  blorp/src/compiler/stage_04_modules/frontend_import_plan
  blorp/src/compiler/stage_04_modules/module_surface
  blorp/src/compiler/stage_04_modules/module_table
  blorp/src/compiler/stage_04_modules/loaded_module
  blorp/src/lib/source_graph
  blorp/src/lib/source
)

profile_args=()
for module in "${modules[@]}"; do
  profile_args+=(--profile-module "$module")
done

bin/blorp compile --profile-mode calls "${profile_args[@]}" \
  --no-embed-runtime --no-format --std-dir standard_library/src \
  -o /tmp/discovery-calls.c blorp/src/main.brp
```

The profiled C was linked with the same repository runtime recipe used by the
[sampling protocol](../README.md#sampling-a-pass): generated module code at
`-O0`, runtime at `-O2`, `-fwrapv`, and the repository's normal include set.
The profiled compiler then ran the same frozen `compile --ast` workload.

Profile diagnostics were valid:

```text
profile_mode=calls
functions_described=13246
functions_selected=628
functions_observed=407
calls_observed=88618543
invalid_start_ids=0
invalid_end_ids=0
unmatched_ends=0
out_of_order_ends=0
```

The relevant raw counts were:

| function | calls |
| --- | ---: |
| `current_tag` | 13,792,257 |
| `is_ident_start` | 8,908,399 |
| `is_ident_continue` | 7,387,640 |
| `current_payload` | 4,077,139 |
| `current_is_symbol` | 3,633,335 |
| `current_is_eof` | 3,480,074 |
| `current_symbol` | 2,983,142 |
| `source_peek` | 2,784,420 |
| `source_advance` | 2,463,669 |
| `current_is_keyword` | 2,181,277 |
| `is_space` | 1,966,416 |
| `advance_parser` | 1,947,487 |
| `source_span` | 1,918,516 |
| `source_location_from_offsets` | 1,647,830 |
| `is_digit_char` | 1,560,861 |
| `current_is_newline` | 1,529,975 |
| `tab_advance` | 1,251,015 |
| `current_location` | 926,729 |
| `cursor_advanced` | 809,326 |
| `symbol_at` | 807,334 |
| `source_span_text` | 781,271 |
| `identifier_end_cursor` | 704,979 |
| `keyword_for` | 704,979 |
| `rewrite_subscript_read_expr` | 599,259 |
| `finalize_interpolation_expr` | 591,257 |
| `materialize_location` | 156,844 |
| `parser_cursor_at_location_start` | 79,833 |
| `parser_cursor_at_location_end` | 3,772 |

The counts that distinguish normal source discovery from its special cases
were:

| mechanism | calls |
| --- | ---: |
| `parse_compiler_source_rebased` / `lex` / `initial_state` | 1,986 each |
| ordinary `parse_compiler_source` | 362 |
| `parse_interpolation_expr` | 1,624 |
| `split_interpolated_string` | 880 |
| `interpolation_hole_start_offsets` | 880 |
| discovered modules / `discover_frontend_source` | 361 |
| `frontend_import_lookup_plan` | 1,874 |
| `filesystem_import_source` | 1,874 |
| `same_source_location` for an already-discovered target | 1,516 |
| `load_source_for_location` | 358 |

Thus 81.8% of parse initializations were interpolation-hole parses, and 80.9%
of import resolutions reached identities that discovery had already loaded.
Neither percentage is a time share.

## Native sample

A plain compiler was generated with the same source/configuration as the calls
map and linked using the same `-O0` generated-code/`-O2` runtime split. Its
hashes were:

```text
plain generated C  a345c03b26ab04c9c8d8de5dd732940fdb548a812e5c77fe8f8189a24640b958
plain executable   833a8845796140df15862fcd9d9bb7fa5c59330d1f76fafe2586d47b954fa562
calls generated C  ae6b1ff70cbd5459f11308edee443aa077600fcba701225beae4e69cf725f673
calls executable   7c5278cadf4cab3c24567b19d092bc166d7223d74e5f81f66924549cbda6cd95
```

The first immediate sample mostly captured dynamic-loader startup and was
discarded. The retained capture delayed sampling by 150 ms:

```bash
/tmp/blorp-discovery-plain compile --ast --no-format \
  --std-dir "$input/standard_library/src" \
  "$input/blorp/src/main.brp" >/dev/null 2>/tmp/plain.stderr &
pid=$!
sleep 0.15
sample "$pid" 1 1 -file /tmp/native-sample-delayed.txt
wait "$pid"
```

It captured 850 main-thread samples. Attribution used the calls-mode metadata
map built from the identical source/configuration:

| subtree | inclusive samples | share of capture |
| --- | ---: | ---: |
| language parser | 736 | 86.6% |
| lexer | 274 | 32.2% |
| source-AST finalization | 82 | 9.6% |
| module surface | 2 | 0.2% |

Subtrees overlap and must not be summed. Frontend graph/service functions had
no meaningful matched sample.

The largest top-of-stack leaves after semantic symbol mapping were:

| leaf | samples | share |
| --- | ---: | ---: |
| `blorp_release` | 113 | 13.3% |
| `blorp_retain` | 82 | 9.6% |
| parser `initial_state` | 61 | 7.2% |
| parser `current_tag` | 45 | 5.3% |
| lexer `lex` | 38 | 4.5% |
| `_platform_memmove` | 24 | 2.8% |
| `blorp_alloc` | 22 | 2.6% |
| `blorp_is_unique` | 18 | 2.1% |
| lexer `is_ident_start` | 18 | 2.1% |
| token `symbol_from_ordinal` | 18 | 2.1% |
| `blorp_cooperative_checkpoint` | 15 | 1.8% |
| `blorp_string_get_opt` | 15 | 1.8% |
| `finalize_interpolation_expr` | 15 | 1.8% |
| `_tlv_get_addr` | 14 | 1.6% |
| `blorp_release_slow_finish` | 12 | 1.4% |
| `parser_cursor_at_location_start` | 12 | 1.4% |
| `open` | 11 | 1.3% |
| `keyword_for` | 11 | 1.3% |

Direct retain/release leaves account for 195 of 850 samples, 22.9%. This is a
lower bound on ownership machinery because slow release, allocation,
uniqueness checks, and cleanup frames are listed separately.

## Exact-profile limitation

Two exact-profiled compiler builds, one generated by the bootstrap and one by
the current compiler, were invalid in the same way:

```text
profile_mode=exact
functions_described=13246
functions_selected=628
functions_observed=0
unmatched_ends=88618543
calls_observed=0
calls_completed=0
```

Generated C contained both profile start and end calls, but the runtime saw
only unmatched exits. No exact-profile timing from this run was used. Calls
mode had zero invalid/unmatched/corruption counters, and the native sample was
used only for relative ranking within this capture.

## Artifact checksums

The large generated C, executables, and full 608 KiB native sample are not
checked into the repository. Their capture-time hashes are retained to make
the summarized evidence auditable:

```text
summary.json                d3a9be6f4d7758ed5dc3d414ab3ceb7fdaaef092e1048c305fa76853946f0853
calls.stderr                b4dae03f8625904a123d9d4db0b9a8d298a323e04424d585dad1f066bb45476e
native-sample-delayed.txt   7b821e7bbb7344023bb93ba7ca6cc9dc3dffb3c84b15a38be8ee17eb51f64f92
discovery-calls.c           ae6b1ff70cbd5459f11308edee443aa077600fcba701225beae4e69cf725f673
discovery-plain.c           a345c03b26ab04c9c8d8de5dd732940fdb548a812e5c77fe8f8189a24640b958
blorp-discovery-calls       7c5278cadf4cab3c24567b19d092bc166d7223d74e5f81f66924549cbda6cd95
blorp-discovery-plain       833a8845796140df15862fcd9d9bb7fa5c59330d1f76fafe2586d47b954fa562
```

Future acceptance measurements must use `benchmarks/self_compile_measure` and
retain their own raw result JSON. These exploratory numbers should not be used
as a baseline after the compiler revision, input revision, optimization level,
or host toolchain changes.
