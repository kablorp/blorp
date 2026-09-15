# Cancellation Propagation Worklist

Issue 131 replaced fixed-point queue expansion through `List.concat` with
ownership-local appends. The measured source was based on `bdce2c5a`; only the
queue expansion differs between the baseline and candidate production sources.

## Decision

Accept. On the 512-function seeded ring, median production-analysis latency
fell 55.72% and externally measured retired instructions fell 43.45%. The
512-function fan-in improved 54.15%. A no-edge control moved +0.15%, well
inside the 3% guardrail. Ordered function summaries, global summaries,
generated plans, and compiler-self generated C were identical.

The ring models 392,960 prefix elements copied by the baseline per analysis.
The append loop performs no per-transition prefix copy. Generated C shows that
the first append may detach the 512-entry list because `pending` initially
aliases `facts`; even charging that one detachment reduces modeled copied
entries by 99.87%.

## Paired production-path results

`compiler_pass_compare` alternated seven baseline/candidate pairs. Ring and
fan-in used 20 analysis iterations and 512 functions. The no-edge control used
1,000 iterations and 64 functions. All samples reported `workload_valid=True`.

| Workload | Baseline median | Candidate median | Change | Allocations | Retained objects |
| --- | ---: | ---: | ---: | ---: | ---: |
| Seeded ring | 39,756 us | 17,605 us | -55.72% | 277,240 to 267,020 (-3.69%) | 2,566 to 2,566 |
| Fan-in | 55,192 us | 25,307 us | -54.15% | 276,760 to 266,560 (-3.69%) | 2,566 to 2,566 |
| No edge | 50,761 us | 50,835 us | +0.15% | 730,000 to 730,000 | 198 to 198 |

The complete paired samples are retained in
`compiler_cancellation_propagation_worklist_2026-09-15.tsv`.

Five alternating `/usr/bin/time -lp` ring samples used 100 iterations and 512
functions. Median retired instructions fell from 3,419,877,606 to
1,934,085,889 (-43.45%); median cycles fell from 789,552,223 to 350,978,900
(-55.55%). Median real time was 0.19 s versus 0.08 s.
The raw native samples are retained in
`compiler_cancellation_propagation_worklist_native_2026-09-15.tsv`.

Narrow exact profiling over five 256-function ring analyses reported 3.253 ms
baseline and 1.834 ms candidate self time (-43.62%) in
`analyze_function_cancellation`. Both profiles completed all five calls with
zero invalid, unmatched, abandoned, or recovered frames. Collection-copy
counters rose by one list copy per analysis in the candidate, as expected for
the initial `facts` alias detachment; those counters do not include concat's
explicit span copies. The exact-profile rows are retained in
`compiler_cancellation_propagation_worklist_exact_2026-09-15.tsv`.

## Semantic and generated-code checks

- The cancellation-plan suite passed 37/37, including no-edge, chain, wide
  fan-in, diamond, self-cycle, mutual-cycle, and disconnected graphs.
- Every paired sample had identical ordered function-summary, global-summary,
  and generated-plan checksums.
- The baseline and candidate compilers emitted byte-identical C for the current
  compiler source, SHA-256
  `d0fb88ca6ce243f39723562cd03515ecb0776a1f15800e49325d499071ef450f`.
- Candidate generated C uses `blorp_list_ensure_capacity` in the append loop
  and does not retain `pending` before each append.

## Provenance and reproduction

The baseline and candidate benchmark executable SHA-256 values were
`1d3363db7968af5086781b356198a022998877d14a4c5750dafa29a709067daa`
and `6dda5fb78f07dca28ccedee4774e53df50f5899b9e352bd6ffa9e393fe725bca`.
The shared benchmark source hash was
`081f1530de6c8f0b407cfc65bc3acc8a4ce2d39c7ad49111a9072f875c7d2dd1`.
The production source hashes were
`81a5ab7dde63a374f8882fa1473de3f9b9508c5cecb74e77f2fd8eb74e84034d`
(baseline) and
`093e011d7fafd7b5dca50002b976b77bb750caec52ca95cc069015c252853283`
(candidate). The paired comparison did not receive source-root arguments, so
these explicit hashes provide the source provenance.

Build the same benchmark source against the two production variants, then run:

```bash
benchmarks/compiler_pass_compare \
  --label issue131-ring \
  --baseline-bin "$baseline_bin" \
  --candidate-bin "$candidate_bin" \
  --prefix CANCELLATION_PROPAGATION_PROFILE \
  --time-field elapsed_microseconds \
  --checksum-field function_summary_checksum \
  --checksum-field global_summary_checksum \
  --checksum-field generated_plan_checksum \
  --stable-field shape \
  --stable-field functions \
  --stable-field call_edges \
  --stable-field caller_bucket_entries \
  --stable-field summary_transitions \
  --stable-field enqueues \
  --stable-field dequeues \
  --stable-field workload_valid \
  --metric-field total_allocations \
  --metric-field total_releases \
  --metric-field current_objects \
  --metric-field bytes_allocated \
  --pairs 7 --warmup-pairs 1 \
  -- propagation ring 20 512
```

For exact attribution, use the workspace-relative logical module path:

```bash
bin/blorp run --release --no-format \
  --profile-mode exact \
  --profile-function blorp/src/compiler/stage_10_backend/cancellation_plan::analyze_function_cancellation \
  blorp/benchmark/compiler/compiler_cancellation_plan_profile.brp \
  -- propagation ring 5 256
```
