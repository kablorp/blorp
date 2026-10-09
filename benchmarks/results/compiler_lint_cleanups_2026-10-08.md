# Compiler lint cleanups, 2026-10-08

## Scope and decision

Three bounded refactors, reviewed against latest main `a8413c9f38b22884c12fad3722c49be243ee0eeb`. Current-base regression gates pass. Measurements show reduced allocations and instruction cost within expected noise; no instruction speedup is claimed.

- Replace five stateless builders in `source_ast_finalize.brp` with `map`/`filter`; keep sequential name rewriting and stateful hoisting.
- Remove three always-true private parser parameters and the constant constructor-name expectation parameter. Preserve diagnostics, recovery, delimiters and spans.
- Match the accepted-global module-slot lookup once, removing the repeated lookup and eager default dictionary while preserving rejection checks and row order.

The hypothesis was reduced builder/signature boilerplate and intermediate values while preserving compiler output. Stop conditions were different emitted C, changed diagnostics/order, increased total allocations or a material instruction regression. Measurements cover the combined candidate, not per-pilot attribution.

Production physical LOC decreases by 33 (parser −5, finalizer −26, global authority −2). Characterization tests increase by 146, for a total code increase of 113. Evidence files and this report are excluded from code counts. Tests protect exact import diagnostics, empty/trailing parser inputs, finalizer order/duplicates/spans, and invalid global identities.

## Matched provenance

- Landing base and frozen self-compile input: `a8413c9f38b22884c12fad3722c49be243ee0eeb`.
- Source/test patch SHA-256: `6ca9e18f23e59edb4c7b3c451350b16fdf95d05a48d8e0ceb3533415af16bfab`; retained at `/tmp/blorp-lint-cleanups-a8413c9f3/reviewed-source.patch`.
- Same checkout: `<worktree:compiler-lint-cleanups>`. Saved baseline binaries run from its original `bin/` paths, preserving repository-root discovery.
- Baseline and candidate normal/diagnostic builds were `FRESH` at capture: bootstrap `dev-0e1598ed616e`, CLI/runtime `-O2`, split 8, Apple clang 21.0.0 (`clang-2100.3.34.2`), aarch64 macOS. Only diagnostics mode differs within each pair (0 vs 1).
- Baseline-repeat checkout metadata reports `compiler_dirty=True` because the candidate source had been reapplied. The saved baseline executable and diagnostic binary hashes are unchanged, and their embedded toolchain commit remains the clean baseline; this checkout-state flag does not describe rebuilt baseline binaries.
- Separate diagnostic allocations and normal instruction samples. All normal samples emit the same C as their diagnostic pair and baseline. Small-program input hash captured before edits and verified before candidate measurement.
- Commands run serially under an exclusive compiler-contention lease. Candidate repeat waited for unrelated gates to release that lease. Test-runner held compiled gates until measurements finished. No backend/runtime edits, so bootstrap-built measurements exercise the changed frontend implementation.
- Earlier pilot evidence used parent `87e312047`; current-base refresh supersedes that acceptance packet. The six edited source/test files and their direct contracts were unchanged upstream; the same patch reapplied cleanly. Initial-base artifacts remain in `/tmp/blorp-lint-cleanups-87e312047/`.

## Cumulative results and bounded repeat

Self allocations: 284,911,836 → 284,910,149 (−1,687). Small allocations: 1,755,846 → 1,755,810 (−36). Every allocation difference is in `typed_frontend_complete`; discovery and later phases are unchanged. Each compiler's two diagnostic runs agree on allocation checkpoints, object counts and allocator bytes; only noisy RSS differs.

The first three-sample self pair showed minimum instructions +0.1576% and median +0.0635%, prompting one bounded repeat. Repeat minima give −0.0293%. All six samples per binary are pooled, with none discarded: minimum 280,988,798,981 → 281,098,032,770 (**+0.0389%**), median **+0.0556%**. This is within the repository's documented approximately 0.1% instruction stability, supporting no material regression rather than an instruction improvement. No further repetitions were run to seek a favorable result.

Small-program minimum instructions: 1,742,107,131 → 1,741,838,662 (−0.0154%), also effectively flat. Wall time, phase time and RSS are secondary host-noise signals, not acceptance evidence.

Self C: 86,912,985 bytes, SHA-256 `c5bcc86e9777d0919a6fa36a27fd54f7fb462d4366169666f3b7fcc30d924b5d`.
Small C: 40,499 bytes, SHA-256 `2033e2664146c6d016466cdcada9d1f3e07724743d656f770b7656aeeecb3f96`.

Retained `compiler_lint_cleanups_2026-10-08_baseline_self.json` and `_candidate_self.json` contain all six pooled instruction/wall samples and maximum peak RSS. Allocation checkpoint/RSS observations and phase-time medians in those aggregate records come from the first measurement. Four `_self_first.json` / `_self_repeat.json` records preserve the complete constituent measurements. `_baseline_small.json` / `_candidate_small.json` preserve the three-sample guard. Allocation and instruction acceptance uses the values below, not unpooled phase-time medians.

### Self-compile comparison, verbatim from harness on pooled records

```text
baseline : lint-cleanups-landing-baseline-all-six @ a8413c9f38b2
candidate: lint-cleanups-landing-candidate-all-six @ a8413c9f38b2
input    : a8413c9f38b2  program=self
output C : IDENTICAL (86912985 vs 86912985 bytes)
toolchain commit differs (expected): a8413c9f38b2 -> a8413c9f38b2-dirty

metric                                               baseline        candidate     delta
----------------------------------------------------------------------------------------
allocs source_discovery_start                             660              660    +0.00%
allocs source_discovery_complete                   17,313,912       17,313,912    +0.00%
allocs typed_frontend_start                                 5                5    +0.00%
allocs typed_frontend_complete                     38,072,904       38,071,217    -0.00%
allocs core_lowering_input_ready                            8                8    +0.00%
allocs core_lowering_complete                      19,138,128       19,138,128    +0.00%
allocs pass_lower_complete                                 64               64    +0.00%
allocs pass_debug_complete                            152,221          152,221    +0.00%
allocs pass_prune_early_complete                      216,168          216,168    +0.00%
allocs pass_desugar_complete                        1,450,225        1,450,225    +0.00%
allocs pass_mono_complete                          28,063,533       28,063,533    +0.00%
allocs pass_synth_complete                            244,716          244,716    +0.00%
allocs pass_match_complete                          5,912,326        5,912,326    +0.00%
allocs pass_trait_resolve_complete                  5,204,574        5,204,574    +0.00%
allocs pass_prune_after_trait_resolve_complete        2,426,494        2,426,494    +0.00%
allocs pass_resolve_complete                        4,004,671        4,004,671    +0.00%
allocs pass_std_inline_complete                     2,038,748        2,038,748    +0.00%
allocs pass_tailrec_complete                          199,613          199,613    +0.00%
allocs pass_fuse_string_complete                    2,714,104        2,714,104    +0.00%
allocs pass_fuse_collection_complete                3,150,874        3,150,874    +0.00%
allocs pass_fuse_parallel_tensor_complete           1,365,856        1,365,856    +0.00%
allocs pass_fuse_tensor_update_complete                50,038           50,038    +0.00%
allocs early_core_complete                                  7                7    +0.00%
allocs pass_tuple_flatten_complete                  8,487,180        8,487,180    +0.00%
allocs pass_tuple_storage_complete                 15,668,220       15,668,220    +0.00%
allocs runtime_projection_complete                  1,020,590        1,020,590    +0.00%
allocs pass_adapt_function_refs_complete            2,076,584        2,076,584    +0.00%
allocs pass_tensor_specialize_specialize_fused_complete        1,857,961        1,857,961    +0.00%
allocs pass_hash_key_callbacks_complete                 6,151            6,151    +0.00%
allocs pass_resolve_backend_match_fused_complete        3,812,323        3,812,323    +0.00%
allocs pass_dce_complete                            2,666,868        2,666,868    +0.00%
allocs pass_consume_specialize_complete             1,995,228        1,995,228    +0.00%
allocs pass_static_string_literals_complete         1,649,157        1,649,157    +0.00%
allocs pass_record_update_ownership_complete        1,929,249        1,929,249    +0.00%
allocs pass_dict_literal_ownership_complete           133,516          133,516    +0.00%
allocs pass_product_evaluation_complete             3,294,385        3,294,385    +0.00%
allocs pass_ownership_perceus_fused_complete       63,813,884       63,813,884    +0.00%
allocs pass_reuse_complete                          2,639,603        2,639,603    +0.00%
allocs pass_closure_complete                        2,740,776        2,740,776    +0.00%
allocs pass_resource_management_complete              381,572          381,572    +0.00%
allocs pass_fairness_complete                         177,261          177,261    +0.00%
allocs pass_prepare_complete                          855,911          855,911    +0.00%
allocs pass_prepared_reuse_complete                   478,488          478,488    +0.00%
allocs cleanup_plan_complete                        5,405,574        5,405,574    +0.00%
allocs cancellation_plan_complete                  12,974,542       12,974,542    +0.00%
allocs late_core_complete                                   5                5    +0.00%
allocs backend_emission_complete                   19,126,883       19,126,883    +0.00%
allocs artifact_construction_complete                      76               76    +0.00%
allocs TOTAL                                      284,911,836      284,910,149    -0.00%
instructions retired (min)                    280,988,798,981  281,098,032,770    +0.04%
output bytes                                       86,912,985       86,912,985    +0.00%
peak RSS bytes                                  2,383,167,488    2,391,146,496    +0.33%
```

### Small-program comparison, verbatim

```text
baseline : lint-cleanups-landing-baseline-small @ a8413c9f38b2
candidate: lint-cleanups-landing-candidate-small @ a8413c9f38b2
input    : a8413c9f38b2  program=small
output C : IDENTICAL (40499 vs 40499 bytes)
toolchain commit differs (expected): a8413c9f38b2 -> a8413c9f38b2-dirty

metric                                               baseline        candidate     delta
----------------------------------------------------------------------------------------
allocs source_discovery_start                             660              660    +0.00%
allocs source_discovery_complete                      403,353          403,353    +0.00%
allocs typed_frontend_start                                 5                5    +0.00%
allocs typed_frontend_complete                        762,342          762,306    -0.00%
allocs core_lowering_input_ready                            8                8    +0.00%
allocs core_lowering_complete                         216,555          216,555    +0.00%
allocs pass_lower_complete                                 64               64    +0.00%
allocs pass_debug_complete                              3,614            3,614    +0.00%
allocs pass_prune_early_complete                       15,995           15,995    +0.00%
allocs pass_desugar_complete                            8,620            8,620    +0.00%
allocs pass_mono_complete                              49,817           49,817    +0.00%
allocs pass_synth_complete                              7,018            7,018    +0.00%
allocs pass_match_complete                             25,368           25,368    +0.00%
allocs pass_trait_resolve_complete                     48,740           48,740    +0.00%
allocs pass_prune_after_trait_resolve_complete           17,426           17,426    +0.00%
allocs pass_resolve_complete                           16,251           16,251    +0.00%
allocs pass_std_inline_complete                         1,885            1,885    +0.00%
allocs pass_tailrec_complete                            6,909            6,909    +0.00%
allocs pass_fuse_string_complete                       10,626           10,626    +0.00%
allocs pass_fuse_collection_complete                   10,482           10,482    +0.00%
allocs pass_fuse_parallel_tensor_complete               6,454            6,454    +0.00%
allocs pass_fuse_tensor_update_complete                 1,712            1,712    +0.00%
allocs early_core_complete                                  7                7    +0.00%
allocs pass_tuple_flatten_complete                     31,483           31,483    +0.00%
allocs pass_tuple_storage_complete                     27,995           27,995    +0.00%
allocs runtime_projection_complete                      4,147            4,147    +0.00%
allocs pass_adapt_function_refs_complete                7,055            7,055    +0.00%
allocs pass_tensor_specialize_specialize_fused_complete            5,876            5,876    +0.00%
allocs pass_hash_key_callbacks_complete                   189              189    +0.00%
allocs pass_resolve_backend_match_fused_complete           14,877           14,877    +0.00%
allocs pass_dce_complete                                3,047            3,047    +0.00%
allocs pass_consume_specialize_complete                    96               96    +0.00%
allocs pass_static_string_literals_complete             1,086            1,086    +0.00%
allocs pass_record_update_ownership_complete            1,087            1,087    +0.00%
allocs pass_dict_literal_ownership_complete               186              186    +0.00%
allocs pass_product_evaluation_complete                 1,724            1,724    +0.00%
allocs pass_ownership_perceus_fused_complete           20,425           20,425    +0.00%
allocs pass_reuse_complete                                200              200    +0.00%
allocs pass_closure_complete                            1,531            1,531    +0.00%
allocs pass_resource_management_complete                  164              164    +0.00%
allocs pass_fairness_complete                             219              219    +0.00%
allocs pass_prepare_complete                              271              271    +0.00%
allocs pass_prepared_reuse_complete                       332              332    +0.00%
allocs cleanup_plan_complete                            2,549            2,549    +0.00%
allocs cancellation_plan_complete                       6,975            6,975    +0.00%
allocs late_core_complete                                   5                5    +0.00%
allocs backend_emission_complete                       10,404           10,404    +0.00%
allocs artifact_construction_complete                      12               12    +0.00%
allocs TOTAL                                        1,755,846        1,755,810    -0.00%
instructions retired (min)                      1,742,107,131    1,741,838,662    -0.02%
output bytes                                           40,499           40,499    +0.00%
peak RSS bytes                                     41,353,216       41,009,152    -0.83%
```

## Reproduction

```bash
# In this checkout at the untouched landing base:
BLORP_CLI_C_OPTIMIZATION=-O2 make
BLORP_CLI_C_OPTIMIZATION=-O2 make build-blorp-cli-diagnostic
cp bin/blorp bin/blorp-lint-landing-baseline
cp blorp/build/_build/blorp-cli/blorp-diagnostic bin/blorp-lint-landing-baseline-diagnostic
# Measure baseline with saved compiler paths, before reapplying the candidate patch.
# Then restore patch, rebuild both modes at -O2 and verify FRESH.
scripts/with-compiler-contention-lease --mode exclusive \
  --policy benchmarks/blorp_test_session_policy.json -- \
  env BLORP_CLI_C_OPTIMIZATION=-O2 benchmarks/self_compile_measure \
  --compiler bin/blorp --diagnostic-compiler blorp/build/_build/blorp-cli/blorp-diagnostic \
  --label lint-cleanups-landing-candidate \
  --input-rev a8413c9f38b22884c12fad3722c49be243ee0eeb --samples 3 \
  --baseline /tmp/blorp-lint-cleanups-a8413c9f3/baseline-self.json \
  --output /tmp/blorp-lint-cleanups-a8413c9f3/candidate-self.json \
  --keep-output /tmp/blorp-lint-cleanups-a8413c9f3/candidate-self.c --require-identical
# Repeat once for self with distinct -repeat output/baseline paths, pooling all six runs.
# Small guard uses --program small and matching small baseline/output paths.
# Baseline omits --baseline/--require-identical and uses the two saved baseline executables.
```

Logs, generated C, build/freshness records and source patch remain in `/tmp/blorp-lint-cleanups-a8413c9f3/`. After measurements, all four compiler binaries were preserved in its `binaries/` directory with recorded hashes verified; baseline copies were removed from the checkout. Copy saved baseline binaries back to the original checkout `bin/` paths to replay matched repository-root discovery. No Docker premerge gate is run: the user's earlier request to skip that local publishing verification remains in effect; this refresh covers the separately requested performance/regression acceptance.

## Validation and review

- Initial-base characterization before production edits: 259 passed / 0 failed (209 parser, 34 finalizer, 16 declaration skeleton).
- Latest-base normal/diagnostic builds succeed; FRESH provenance, matching fingerprints and output identity confirmed.
- Initial-base focused 512/0 and broad 11,742/0 passed; source review had zero blockers, should-fix findings or nits.
- Latest-base focused suites: 512 passed / 0 failed. Serial broad gates: `compiler-new` 1,064/0, `compiler-new-parity` 3,672/0 with zero mismatched files (two known divergences and one module without complete tree reading remain reported), `compiler-blorp` 7,277/0 (6,414 component checks plus 863 production fixtures); broad total 12,013/0. Final build remains FRESH. The six-file source/test diff is unchanged after validation.
- Targeted latest-base lint confirms 38 → 27 findings: five accumulator, four constant-parameter, one repeated and one general lookup finding removed. No new findings; remaining constant-parameter message only shifts its call-site line. The same baseline source text is unchanged on latest main; initial baseline subset and fresh candidate JSON are retained under the artifact directory.
- Latest-base source and measurement/report reviews: zero blockers, should-fix findings or nits. Final precommit review approves all 15 intended files with zero issues.
- `git diff --check`: passes.
- Existing formatter import ordering/line-wrap drift was confirmed on baseline. Introduced formatting corrected; whole-file formatter conformance is not claimed.

Publication note: linked measurement JSONs are path-projected publication records. Machine-local checkout and per-user temporary paths use worktree and `$TMPDIR` placeholders. Measurement values, timestamps, samples, source/C/binary hashes and original nested provenance fields are unchanged; no measurements were rerun. The [projection receipt](compiler_report_path_projection_2026-10-08.json) records original versus publication hashes and the private original archive. Original fingerprints describe original bytes, not the projected JSON byte streams.
