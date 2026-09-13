# Nested Declaration Hoist Issue 92

Baseline: root checkout `bin/blorp` at `eb6893ea5e7d4e1e28fd2d81da468fb69a20d877`.

Candidate: `codex/issue-92-hoist-nested-decls` after replacing
`hoist_nested_decls` top-level concat with local append loops.

Fixtures were generated once outside the measured process:

```bash
fixture_dir=$(mktemp -d "${TMPDIR:-/tmp}/issue92-nested-hoist-fixtures.XXXXXX")
benchmarks/compiler_nested_hoist_fixtures.py "$fixture_dir"
```

Each compiler/fixture pair used one unrecorded warmup followed by five measured
samples:

```bash
<compiler> compile --ast --no-format "$fixture" >/dev/null
```

Retired-instruction counters were not available in the local toolchain used for
this run.

## Median Wall Time

| Variant | Functions | Baseline median (s) | Candidate median (s) | Speedup |
| --- | ---: | ---: | ---: | ---: |
| independent | 4,096 | 0.290097 | 0.184373 | 1.57x |
| independent | 8,192 | 0.751278 | 0.325347 | 2.31x |
| independent | 16,384 | 2.336710 | 0.615228 | 3.80x |
| mixed | 4,096 | 0.636489 | 0.413176 | 1.54x |
| mixed | 8,192 | 1.663647 | 0.780963 | 2.13x |
| mixed | 16,384 | 5.085865 | 1.532404 | 3.32x |

## Samples

| Variant | Functions | Compiler | Samples (s) |
| --- | ---: | --- | --- |
| independent | 4,096 | baseline | 0.286948, 0.290482, 0.290212, 0.290097, 0.289905 |
| independent | 4,096 | candidate | 0.184646, 0.184373, 0.185320, 0.181548, 0.183981 |
| independent | 8,192 | baseline | 0.751075, 0.789375, 0.751278, 0.752116, 0.751183 |
| independent | 8,192 | candidate | 0.330136, 0.324598, 0.325347, 0.324028, 0.329777 |
| independent | 16,384 | baseline | 2.426966, 2.339867, 2.296060, 2.329416, 2.336710 |
| independent | 16,384 | candidate | 0.629003, 0.612847, 0.612038, 0.615441, 0.615228 |
| mixed | 4,096 | baseline | 0.635941, 0.633965, 0.636489, 0.636701, 0.644640 |
| mixed | 4,096 | candidate | 0.411360, 0.415241, 0.415939, 0.412759, 0.413176 |
| mixed | 8,192 | baseline | 1.663273, 1.665822, 1.675939, 1.662330, 1.663647 |
| mixed | 8,192 | candidate | 0.788936, 0.780951, 0.780963, 0.778350, 0.796192 |
| mixed | 16,384 | baseline | 5.085865, 5.096731, 5.142372, 5.019642, 5.083160 |
| mixed | 16,384 | candidate | 1.527932, 1.532404, 1.534903, 1.547248, 1.530674 |

## Mechanism Check

Generated C for the branch compiler shows the top-level hoisted-declaration loop
appending directly to the local `values` accumulator through
`blorp_list_ensure_capacity`. The previous helper-boundary accumulator retain
and the old source-level concat path are not present in this hoist loop.
