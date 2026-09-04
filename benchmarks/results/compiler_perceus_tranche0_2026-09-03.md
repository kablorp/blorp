# Perceus Tranche 0 Baseline — 2026-09-03

This is the first counter-aware baseline for the ownership optimization
roadmap. It records two distinct inner windows over the same fixture and the
same post-Perceus artifact. The source tree was the Tranche 0 candidate based
on revision `8b507154a891172981c62a9096e8a7095c38a408`; the benchmark correctly
reported `working_tree_dirty=true` because this result was captured before the
change was committed.

## Fixture

```text
fixture_version=5
body_shape=nested_user_call
globals=1
functions=4
body_leaves=64
global_reads_per_function=0
params_per_function=4
parameter_type=String
user_call_edges=1
samples=7
warmup=true
build_mode=benchmark-worker-O0
```

Command, with `--measurement-window perceus-direct --no-work-counters` added
for the second row:

```bash
benchmarks/compiler_perceus_memory \
  --globals 1 --functions 4 --body-leaves 64 \
  --global-reads-per-function 0 --params-per-function 4 \
  --body-shape nested_user_call --user-call-edges 1 \
  --samples 7 --timeout 120 --json
```

## Results

| Inner window | Median inner time | Median inner allocations | Median inner releases | Process median |
| --- | ---: | ---: | ---: | ---: |
| ownership-preparation plus Perceus | 9,033 us | 67,003 | 66,379 | 0.112092 s |
| direct Perceus | 9,498 us | 65,122 | 64,795 | 0.110088 s |
| backend emission | 1,667 us | 8,856 | 8,847 | 0.112323 s |

The composite and direct timing samples were captured in separate runs and the
direct run happened to be slower, so their time difference is not presented as
a preparation estimate. Their median window counters show 1,881 additional
allocations and 1,584 additional releases in the composite window.
Process medians are intentionally not used to infer the slice because worker
startup and JSON dominate them.

Both Core windows produced 32,908-byte Core with SHA-256
`771e7e70e4a3747ea434f42395ca8491832f322b32197e7e46cda3e152d6bb5d`.
The post-Perceus census was four ARC `DropExpr` nodes, zero `DupExpr` nodes,
and 290 expression nodes.

The untimed stage inspection recorded:

| Stage | Expression nodes | ARC dup | ARC drop | SHA-256 |
| --- | ---: | ---: | ---: | --- |
| ownership-ready | 286 | 0 | 0 | `43f5901bd3c4022da73c386920b7a66cdf39ff19edb31d12714dc11693a73f13` |
| post-Perceus | 290 | 0 | 4 | `771e7e70e4a3747ea434f42395ca8491832f322b32197e7e46cda3e152d6bb5d` |
| post-reuse | 290 | 0 | 4 | `771e7e70e4a3747ea434f42395ca8491832f322b32197e7e46cda3e152d6bb5d` |
| prepared | 290 | 0 | 4 | `771e7e70e4a3747ea434f42395ca8491832f322b32197e7e46cda3e152d6bb5d` |

The backend-emission run produced 10,679 bytes of generated program C with
SHA-256 `503e41b0bf033188b90be7c2825c4dd92435ab80eb38f8211702bcff95431d9f`.
It contained zero retain calls, four release calls, one ARC-only release, four
cleanup pushes, 24 cleanup pops, zero cleanup-duplicate updates, and zero
stack-result retains/releases. The census strips C string/character literals
and comments before matching. The bridge artifact does not embed the runtime
definitions, so these are generated-program counts.

## Direct Perceus work counters

The separate debug/profile worker ran twice; its counter maps and output hashes
were identical. Registration calls have already been subtracted.

| Counter | Count |
| --- | ---: |
| contract function analyses | 8 |
| contract managed-parameter summaries | 28 |
| contract wave iterations | 3 |
| contract wave function reanalyses | 3 |
| linear summary requests | 1,809 |
| linear summary node visits | 13,273 |
| legacy count node visits | 0 |
| borrowed-call node visits | 0 |
| borrowed-aggregate node visits | 0 |
| borrowed-result node visits | 0 |
| resolved-value queries | 0 |
| insertion node visits | 286 |
| insertion rebuild actions | 286 |
| declarations rewritten | 6 |
| functions rewritten | 5 |
| globals rewritten | 1 |

The counter worker SHA-256 was
`b6bbf73891b77643645001e1c6908a42e09a1b310a5c73540c04cf7deb176905`
for the composite-window run. The direct run independently produced the same
counter map and artifact with worker SHA-256
`5a47d3d8d1c2904557d7fb66584fafb826aada64c7ab03649c0743630c036a08`.
The timing worker SHA-256 was
`b04c53e51b3dbf40f1168fa60581aee6ff4c0cab37184f150b0a29039d86cc91`
for the composite window and
`609331c6ffad68e07423647b272d978b2e135bcdc6c845f9c40b88a2e733a035`
for the direct window. The backend-emission timing worker SHA-256 was
`b9cf2aa59e5d388367727ad5328cc6e5288b2ae1270f523e27d924990f96cf08`.
All three runs used final harness SHA-256
`cc33b114e79107213028f39a76b007c09aa498c9b1859d82299b80d612b8a103`.

## Raw samples

```text
ownership-preparation-plus-perceus inner_us:
9417 9033 8930 8716 9427 9304 9008

ownership-preparation-plus-perceus process_s:
0.10707224998623133 0.11245645798044279 0.11208241700660437
0.10867512499680743 0.11220741699798964 0.1123747090168763
0.11209174999385141

direct-perceus inner_us:
9179 9747 9801 9280 9830 9498 9343

direct-perceus process_s:
0.10348012499161996 0.10476874999585561 0.10467487497953698
0.11008766602026299 0.11264495801879093 0.11230579199036583
0.11239954200573266

backend-emission inner_us:
1676 1649 1679 1856 1658 1667 1653

backend-emission process_s:
0.10340995900332928 0.11230304100899957 0.11245587500161491
0.11246362500241958 0.11232329098857008 0.11235091599519365
0.1113833749841433
```

## Interpretation

This baseline replaces the first roadmap hypothesis with a measured direction:
contract work is multiplicative through repeated scalar summaries, with 1,809
summary requests and 13,273 visited nodes for only 28 managed-parameter equations.
Tranche 1 should primarily reduce those two summary counters and the three
body-level reanalyses. Generated Core must remain byte-identical.

No runtime ARC-operation conclusion is drawn here. This harness transforms
Core but does not execute emitted programs; runtime operation counters belong
immediately before the runtime-changing tranches.

## Production instrumentation erasure

A normal, counter-disabled backend worker was generated directly from the
candidate sources. Its 41,847,940-byte C artifact contained zero
`perceus_work_` symbols. The logical counters therefore add no calls or marker
definitions to the production/timing build; only the separately configured
`--debug --profile` worker contains them.

## Production-shaped self-compilation smoke

One counter-disabled compiler self-compilation stopped at Perceus completed
successfully. This is a smoke measurement, not a seven-sample timing claim:

```text
command=bin/blorp compile --no-format --stop-after=perceus --dump-core-file=<temp>/perceus.json blorp/src/main.brp
real_seconds=135.41
user_seconds=131.73
system_seconds=2.34
maximum_resident_set_size_bytes=5762203648
instructions_retired=1390788719586
cycles_elapsed=334318424083
perceus_core_json_bytes=313654095
status=success
```

The 313 MB serialized artifact and process envelope explain why synthetic
worker timings are retained for the fast feedback loop. Later optimization
tranches should compare this production shape from isolated control/candidate
worktrees rather than treating this single dirty-tree sample as a baseline
ratio.

A second counter-disabled smoke continued through production C emission:

```text
command=bin/blorp compile --no-format -o <temp>/compiler.c blorp/src/main.brp
real_seconds=123.45
user_seconds=121.27
system_seconds=1.10
maximum_resident_set_size_bytes=2132918272
instructions_retired=1272516164348
cycles_elapsed=313517471764
compiler_c_bytes=99823644
status=success
```

These two production-shaped runs used the installed compiler while the
instrumented source tree was dirty. They prove the corpus and output sizes are
practical, but they are not the clean, alternating parent/candidate comparison
required for a performance claim. Tranche 0 changes no production ownership
algorithm; that comparison belongs at the first optimizing tranche.
