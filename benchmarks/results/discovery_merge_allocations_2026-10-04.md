# Discovery merge allocation measurements

Measured on 2026-10-04 after reconciling discovery-tree work with main `3e5cf1ff32fb95f1b7d797a501e733341992fb15`. These are allocation contracts for the merged source, not a performance comparison.

The retained executable `parser_probe.brp` now generates `fixed union E` rather
than `enum E`. It no longer reproduces the historical source hash in the frozen
manifest; measurements, logs and hash manifests below remain historical.

## Provenance

```text
blorp 0.0.1
commit: a5ae15eab7e8-dirty
target: aarch64-apple-darwin
channel: local
dirty: true
compiled_by: dev-d44472d3a5d0
optimization: cli=-O0 runtime=-O2
split: 8
cc: Apple clang version 21.0.0 (clang-2100.3.34.2)
memory_diagnostics: 0
```

The CLI is from the fresh root build of `a5ae15eab7e8-dirty`; bootstrap `dev-d44472d3a5d0`, CLI `-O0`, runtime `-O2`, Apple clang 21.0.0. Test artifacts are built by this CLI with `--leak-check`. `MemoryStatsActive` and `OracleStatsActive` must equal 1 before and after every measured call; unavailable counters fail closed.

Compiler SHA-256: `8f0ec3a540939a6a999b2528c0e7e373c7ca37c2c4cc5d63e26c61f950cc014b`.

## Commands and boundaries

```bash
bin/blorp test --leak-check --repeat 2 --timeout 180 \
  blorp/test/compiler_new/stage_01_discovery/lex/test_lexer_allocations.brp \
  blorp/test/compiler_new/stage_01_discovery/tables/test_allocation_budget.brp \
  blorp/test/compiler_new/stage_01_discovery/tables/test_load_allocation_budget.brp
scripts/check-blorp-layout
```

- Lexer: reset counters, call `lex_module`, then read managed allocations. Text construction is excluded.
- Bridge: lexer/source admission finish first; reset counters, then `bridge_lexed_module`.
- Parser: lexer, admission, module opening and bridge finish first; reset counters, parse declarations and close module.
- Full load: reset counters before `load_module(empty_discovery_builder(), request, RootModule, text)`.
- The small-count probes use matching TestSuite compilation and repeat counts 0, 1, 2, 10, 2,000 and 4,000. Empty function-body prefixes are intentionally invalid at zero repeats; that result remains visible rather than contributing a vacuous count.

## Interpretation

Both `record` and `fixed record` are managed. `Span` in discovery remains the packed scalar opaque type; there is no per-span record allocation at this boundary. Managed `Token`, `SymbolMatch`, `NumberScan`, line-plan and opening/snapshot records account for costs that old inline-struct expectations omitted. The numerical changes also reflect measuring parser-only versus full load; these scopes must not be compared as equivalent workloads.

Repeated name bridging rewrites five tokens per item; repeated literal bridging rewrites six. Rejected-number bridging allocates four managed products per item: the name token, rejected-token kind update, literal-payload update and diagnostic row. Interpolation bridging allocates ten per item: eight piece/list/interpolation products and two rewritten tokens. Existing interned spellings/literals are reused. At 2,000 versus 4,000 items these slopes remain fixed, with only 1–2 extra growth allocations. The setup allowance remains 100; it was not increased.

Lexer pins are exact. Symbols have 14 allocations/item (7 token records, 6 SymbolMatch records, 1 line plan); repeated names have 8/item (4 token records, 3 spelling-result tuples, 1 line plan); keyword-only input has 5/item (4 tokens, 1 line plan). Number-family deltas include managed NumberScan products in addition to tokens and checked values. Per-family counts, rather than a claimed complete attribution of all remaining products, are retained below.

Parser and full-load pins retain the existing tolerance of 100 around the measured 2,000-item count. An extra allocation per item would add 2,000, so those contracts continue to detect builder/table copies. Row append remained exactly 6,020 and both existing row-append tests passed.

### Compilation mode matters

The standalone `bin/blorp run --leak-check` probe produced different parser/load counts from TestSuite compilation: expression parsing was 28,085 standalone versus 34,086 in TestSuite, and full load was 68,214 versus 74,215. Recompiling the probe as a TestSuite matched the owning tests exactly. The smaller standalone numbers were excluded from pins. This is a compilation-context caveat; no compiler optimization claim is made from these samples.

## Results

65 tests passed twice (130 checks) with zero reported leaks. Lexer: 12; parser/bridge: 29; full load: 24. Both small-count TestSuite probes also passed with zero reported leaks. Layout and scoped `git diff --check` passed.

## Raw artifacts

Original artifact directory: `/tmp/blorp-9a08-allocation-merge/`. Keep the copied raw logs and probe sources alongside this ledger for durable evidence. `baseline.log` records stale-pin failures; `final.log` records the twice-passing suites; `parser_probe_test.log` and `lexer_bridge_probe_test.log` contain the admitted sample counts. `probe.log` and `parser_probe.log` are standalone experiments, excluded from pins. Scratch source was removed from the checkout after capture.

## Exact samples

### Lexer and bridge

| Family | Boundary | 0 | 1 | 2 | 10 | 2000 | 4000 | Large slope | Setup at 2000 | Growth remainder |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| symbols | lexer | 15 | 30 | 45 | 162 | 28036 | 56038 | 14 | 36 | 2 |
| symbols | bridge | 3 | 4 | 5 | 8 | 15 | 16 | 0 | 15 | 1 |
| names | lexer | 15 | 35 | 44 | 113 | 16047 | 32049 | 8 | 47 | 2 |
| names | bridge | 3 | 8 | 12 | 39 | 6016 | 12017 | 3 | 16 | 1 |
| keywords | lexer | 15 | 20 | 26 | 71 | 10035 | 20037 | 5 | 35 | 2 |
| keywords | bridge | 3 | 3 | 4 | 7 | 14 | 15 | 0 | 14 | 1 |
| layout | lexer | 15 | 38 | 52 | 153 | 24047 | 48049 | 12 | 47 | 2 |
| layout | bridge | 3 | 7 | 10 | 29 | 4016 | 8017 | 2 | 16 | 1 |
| comments | lexer | 15 | 25 | 32 | 85 | 12040 | 24042 | 6 | 40 | 2 |
| comments | bridge | 3 | 6 | 7 | 18 | 2015 | 4016 | 1 | 15 | 1 |
| dimensions | lexer | 15 | 29 | 36 | 88 | 12043 | 24045 | 6 | 43 | 2 |
| dimensions | bridge | 3 | 12 | 15 | 33 | 4021 | 8022 | 2 | 21 | 1 |
| integers | lexer | 15 | 36 | 58 | 225 | 40047 | 80050 | 20 | 47 | 3 |
| integers | bridge | 3 | 10 | 14 | 41 | 6018 | 12019 | 3 | 18 | 1 |
| floats | lexer | 15 | 28 | 41 | 144 | 24046 | 48049 | 12 | 46 | 3 |
| floats | bridge | 3 | 8 | 11 | 29 | 4017 | 8018 | 2 | 17 | 1 |
| strings | lexer | 15 | 24 | 33 | 104 | 16046 | 32049 | 8 | 46 | 3 |
| strings | bridge | 3 | 6 | 9 | 27 | 4015 | 8016 | 2 | 15 | 1 |
| rawstrings | lexer | 15 | 28 | 41 | 144 | 24046 | 48049 | 12 | 46 | 3 |
| rawstrings | bridge | 3 | 6 | 9 | 27 | 4015 | 8016 | 2 | 15 | 1 |
| characters | lexer | 15 | 23 | 32 | 100 | 16035 | 32037 | 8 | 35 | 2 |
| characters | bridge | 3 | 3 | 4 | 6 | 14 | 15 | 0 | 14 | 1 |
| interpolations | lexer | 15 | 51 | 86 | 373 | 70044 | 140047 | 35 | 44 | 3 |
| interpolations | bridge | 3 | 13 | 21 | 90 | 16024 | 32026 | 8 | 24 | 2 |
| bridge_names | lexer | 15 | 40 | 53 | 153 | 24048 | 48050 | 12 | 48 | 2 |
| bridge_names | bridge | 3 | 14 | 20 | 62 | 10020 | 20021 | 5 | 20 | 1 |
| bridge_literals | lexer | 15 | 60 | 99 | 401 | 74054 | 148057 | 37 | 54 | 3 |
| bridge_literals | bridge | 3 | 16 | 23 | 73 | 12021 | 24022 | 6 | 21 | 1 |
| bridge_rejected_int | lexer | 15 | 32 | 45 | 148 | 24049 | 48052 | 12 | 49 | 3 |
| bridge_rejected_int | bridge | 3 | 12 | 17 | 54 | 8028 | 16030 | 4 | 28 | 2 |
| bridge_rejected_float | lexer | 15 | 32 | 45 | 148 | 24049 | 48052 | 12 | 49 | 3 |
| bridge_rejected_float | bridge | 3 | 12 | 17 | 54 | 8028 | 16030 | 4 | 28 | 2 |
| bridge_interpolation | lexer | 15 | 68 | 117 | 508 | 96049 | 192052 | 48 | 49 | 3 |
| bridge_interpolation | bridge | 3 | 17 | 28 | 113 | 20027 | 40029 | 10 | 27 | 2 |
| newspellings | lexer | 15 | 23 | 31 | 100 | 16034 | 32036 | 8 | 34 | 2 |

Setup at 2000 is `count2000 - slope * 2000`: a named observed setup/list-growth remainder at that size, not a constant intercept across every list capacity. Large slope is the integer quotient of `(count4000 - count2000) / 2000`; growth remainder is the remaining allocation count. It distinguishes fixed per-item work from small list-growth costs, not an asymptotic proof.

### Parser and full load

| Family | Boundary | 0 | 1 | 2 | 10 | 2000 | 4000 | Large slope | Setup at 2000 | Growth remainder |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| expression_statements_copies_no_table | parser | invalid | 63 | 82 | 226 | 34086 | 68090 | 17 | 86 | 4 |
| expression_statements_copies_no_table | load | invalid | 176 | 215 | 527 | 74215 | 148223 | 37 | 215 | 8 |
| blocks_and_calls_copies_no_table | parser | invalid | 87 | 127 | 440 | 76088 | 152092 | 38 | 88 | 4 |
| blocks_and_calls_copies_no_table | load | invalid | 236 | 329 | 1058 | 178226 | 356234 | 89 | 226 | 8 |
| matches_and_patterns_copies_no_table | parser | invalid | 118 | 188 | 732 | 134092 | 268096 | 67 | 92 | 4 |
| matches_and_patterns_copies_no_table | load | invalid | 339 | 508 | 1822 | 324271 | 648280 | 162 | 271 | 9 |
| selects_copies_no_table | parser | invalid | 93 | 141 | 510 | 90088 | 180092 | 45 | 88 | 4 |
| selects_copies_no_table | load | invalid | 257 | 364 | 1201 | 204244 | 408253 | 102 | 244 | 9 |
| concurrent_blocks_copies_no_table | parser | invalid | 126 | 203 | 803 | 148094 | 296098 | 74 | 94 | 4 |
| concurrent_blocks_copies_no_table | load | invalid | 366 | 560 | 2066 | 372277 | 744286 | 186 | 277 | 9 |
| lambdas_copies_no_table | parser | invalid | 103 | 159 | 593 | 106091 | 212095 | 53 | 91 | 4 |
| lambdas_copies_no_table | load | invalid | 300 | 434 | 1468 | 254256 | 508264 | 127 | 256 | 8 |
| interpolations_copies_no_table | parser | invalid | 107 | 168 | 639 | 116090 | 232094 | 58 | 90 | 4 |
| interpolations_copies_no_table | load | invalid | 265 | 384 | 1329 | 232242 | 464252 | 116 | 242 | 10 |
| record_literals_and_updates_copies_no_table | parser | invalid | 91 | 137 | 483 | 84092 | 168096 | 42 | 92 | 4 |
| record_literals_and_updates_copies_no_table | load | invalid | 266 | 379 | 1237 | 210244 | 420252 | 105 | 244 | 8 |
| loops_copies_no_table | parser | invalid | 116 | 184 | 718 | 132082 | 264085 | 66 | 82 | 3 |
| loops_copies_no_table | load | invalid | 305 | 453 | 1605 | 284248 | 568256 | 142 | 248 | 8 |
| question_binds_copies_no_table | parser | invalid | 73 | 103 | 320 | 52090 | 104094 | 26 | 90 | 4 |
| question_binds_copies_no_table | load | invalid | 221 | 295 | 858 | 136245 | 272254 | 68 | 245 | 9 |
| function_declarations_copies_no_table | parser | 8 | 82 | 140 | 622 | 112168 | 224183 | 56 | 168 | 15 |
| function_declarations_copies_no_table | load | 39 | 257 | 410 | 1633 | 294306 | 588326 | 147 | 306 | 20 |
| type_declarations_copies_no_table | parser | 8 | 98 | 184 | 851 | 164069 | 328074 | 82 | 69 | 5 |
| type_declarations_copies_no_table | load | 39 | 288 | 474 | 1917 | 356207 | 712216 | 178 | 207 | 9 |
| trait_and_impl_declarations_copies_no_table | parser | 8 | 85 | 152 | 693 | 128131 | 256142 | 64 | 131 | 11 |
| trait_and_impl_declarations_copies_no_table | load | 39 | 245 | 401 | 1632 | 298259 | 596275 | 149 | 259 | 16 |
| imports_copies_no_table | parser | invalid | 39 | 60 | 233 | 40069 | 80074 | 20 | 69 | 5 |
| imports_copies_no_table | load | invalid | 160 | 226 | 735 | 122191 | 244200 | 61 | 191 | 9 |
| collection_literals_copies_no_table | parser | invalid | 126 | 204 | 804 | 148096 | 296100 | 74 | 96 | 4 |
| collection_literals_copies_no_table | load | invalid | 386 | 601 | 2268 | 412279 | 824288 | 206 | 279 | 9 |
| tuple_list_and_qualified_patterns_copies_no_table | parser | invalid | 177 | 302 | 1286 | 244095 | 488099 | 122 | 95 | 4 |
| tuple_list_and_qualified_patterns_copies_no_table | load | invalid | 492 | 794 | 3173 | 590291 | 1180300 | 295 | 291 | 9 |
| with_scopes_copies_no_table | parser | invalid | 99 | 153 | 562 | 100091 | 200095 | 50 | 91 | 4 |
| with_scopes_copies_no_table | load | invalid | 270 | 389 | 1294 | 222241 | 444249 | 111 | 241 | 8 |
| conversions_and_builtins_copies_no_table | parser | invalid | 86 | 128 | 442 | 76092 | 152096 | 38 | 92 | 4 |
| conversions_and_builtins_copies_no_table | load | invalid | 266 | 372 | 1176 | 196261 | 392270 | 98 | 261 | 9 |
| bindings_and_local_functions_copies_no_table | parser | invalid | 106 | 164 | 622 | 110135 | 220144 | 55 | 135 | 9 |
| bindings_and_local_functions_copies_no_table | load | invalid | 300 | 434 | 1476 | 254299 | 508312 | 127 | 299 | 13 |
| postfix_chains_and_unary_operators_copies_no_table | parser | invalid | 125 | 202 | 795 | 146096 | 292100 | 73 | 96 | 4 |
| postfix_chains_and_unary_operators_copies_no_table | load | invalid | 339 | 516 | 1903 | 342254 | 684262 | 171 | 254 | 8 |
| written_types_copies_no_table | parser | 8 | 150 | 277 | 1275 | 242150 | 484162 | 121 | 150 | 12 |
| written_types_copies_no_table | load | 39 | 464 | 774 | 3212 | 600327 | 1200343 | 300 | 327 | 16 |
| foreign_blocks_copies_no_table | parser | 8 | 66 | 114 | 521 | 94128 | 188139 | 47 | 128 | 11 |
| foreign_blocks_copies_no_table | load | 39 | 236 | 374 | 1471 | 264268 | 528284 | 132 | 268 | 16 |
| supertraits_copies_no_table | parser | 8 | 101 | 188 | 843 | 158137 | 316148 | 79 | 137 | 11 |
| supertraits_copies_no_table | load | 39 | 285 | 481 | 1986 | 368269 | 736285 | 184 | 269 | 16 |

Setup at 2000 is `count2000 - slope * 2000`: a named observed setup/list-growth remainder at that size, not a constant intercept across every list capacity. Large slope is the integer quotient of `(count4000 - count2000) / 2000`; growth remainder is the remaining allocation count. It distinguishes fixed per-item work from small list-growth costs, not an asymptotic proof.
