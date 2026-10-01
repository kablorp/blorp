# Discovery Stage Switched On: Cost and Output — 2026-10-01

Criteria 2 and 5 of
[`docs/DISCOVERY_ACCEPTANCE_ROADMAP.md`](../../docs/DISCOVERY_ACCEPTANCE_ROADMAP.md)
with `BLORP_FRONT_END=stage`: the self-compile emits the same C, and the stage
with the whole adapter costs fewer instructions than the existing discovery.
Both hold.

## Provenance

- Source: branch `compiler-new/stage-switch-on`, based on `766d8c373`, measured
  at the head named in the commit that records this file
- Host: Apple Silicon, Darwin 25.6.0; `/usr/bin/time -l` counters
- C compiler: Apple clang 21.0.0 (`clang-2100.3.34.2`), `-O2 -fwrapv`
- No gate or other build ran during a measurement; the existing and stage runs
  were made back to back

## Self-compile, whole compiler

A stage-2 compiler (`BLORP_CLI_C_OPTIMIZATION=-O2 benchmarks/build_stage2_compiler
--diagnostic-output bin/blorp-stage2-diagnostic bin/blorp-stage2`) compiling
`blorp/src/main.brp` to C. The existing run leaves the variable unset, the
stage run exports `BLORP_FRONT_END=stage`; `self_compile_measure` passes the
environment to the compiler.

```bash
benchmarks/self_compile_measure --compiler bin/blorp-stage2 \
  --diagnostic-compiler bin/blorp-stage2-diagnostic --skip-build-check \
  --label front_end_existing --samples 3 \
  --output benchmarks/results/self_compile_front_end_existing_stage2_O2_2026-10-01.json
BLORP_FRONT_END=stage benchmarks/self_compile_measure --compiler bin/blorp-stage2 \
  --diagnostic-compiler bin/blorp-stage2-diagnostic --skip-build-check \
  --label front_end_stage --samples 3 --require-identical \
  --baseline benchmarks/results/self_compile_front_end_existing_stage2_O2_2026-10-01.json \
  --output benchmarks/results/self_compile_front_end_stage_stage2_O2_2026-10-01.json
```

| | Existing | Stage | Change |
| --- | ---: | ---: | ---: |
| Generated C | 76,956,462 bytes | identical | `cmp` equal |
| Allocations, source discovery | 9,340,460 | 7,831,639 | -16.15% |
| Allocations, whole compile | 211,551,296 | 210,042,475 | -0.71% |
| Retired instructions (min of 3) | 200.710 G | 199.844 G | -0.43% |
| Peak RSS | 2,134,589,440 | 2,131,591,168 | -0.14% |

Every phase after discovery has the same allocation count with either front
end, so the graph the typechecker reads is the same size and shape. The
`bin/blorp` (bootstrap-linked, `-O0` CLI) self-compile C is also byte-identical
with the stage on, checked by `scripts/front-end-stage-check` on every premerge
run.

## Discovery alone

`blorp/test/compiler/tools/discovery_adapter_cost.brp` on the self-compile
inputs (`blorp/src/main.brp`, `standard_library/src`, `pkg`, prelude and tuple;
424 modules in every mode), one binary without and one with
`-DBLORP_MEMORY_DIAGNOSTICS=1` (allocations only); the commands are those of
[`discovery_adapter_bodies_2026-10-01.md`](discovery_adapter_bodies_2026-10-01.md).
Instructions, user time and peak RSS are the median of three rounds.

| | Existing discovery | Stage, tables | Stage plus programs | Stage plus graph |
| --- | ---: | ---: | ---: | ---: |
| Allocations | 9,001,960 | 561,948 | 5,486,635 | 7,599,754 |
| Retired instructions | 10.479 G | 4.302 G | 7.724 G | 9.280 G |
| User time | 0.56 s | 0.24 s | 0.43 s | 0.54 s |
| Peak RSS | 207 MB | 196 MB | 212 MB | 389 MB |

Stage plus graph (the stage, the whole adapter and typecheck's finalization of
every module) is 11.4% under the existing
discovery in instructions and 15.6% in allocations. Against the earlier
measurement (396 modules, 8.743 G against 10.134 G) the ratio moved from
-13.7% to -11.4% because the compiler gained 28 modules since, among them the
stage and the adapter themselves; the margin remains positive. The adapter is
temporary (see the roadmap), and its peak RSS, which holds every rebuilt module
at once, is 1.9 times the existing discovery's, as before.
