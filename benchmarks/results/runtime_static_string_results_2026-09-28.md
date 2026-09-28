# Static runtime string results

Date: 2026-09-28

Base revision and frozen input: `584e87ac86bdd6b42694b07450a73ee7e85b87c3`.
The candidate is that revision plus the runtime change (static `""`,
`"True"`/`"False"`, a 128-entry ASCII single-character table, and returning
the non-empty operand of a join with an empty one). Toolchain: Apple clang 21,
`BLORP_CLI_C_OPTIMIZATION=-O2`. The machine was shared with other agents, so
instruction counts carry some noise; allocation counts are deterministic.

## Microbenchmark

`benchmarks/blorp/string_static_results.brp`: 2M Bool/Char conversions (every
64th character non-ASCII) plus 2M joins with an empty operand. Generated C was
emitted by each compiler (the runtime is embedded) and built with
`clang -fwrapv -O2 -pthread -I blorp/src/lib/runtime/native`; allocation counts
come from `-DBLORP_MEMORY_DIAGNOSTICS=1` builds run with `BLORP_TRACK_STATS=1`,
instructions from `/usr/bin/time -l` on `-DBLORP_MEMORY_DIAGNOSTICS=0` builds.

| metric | base | candidate | delta |
| --- | ---: | ---: | ---: |
| managed allocations | 12,000,003 | 31,253 | -99.7% |
| instructions retired (min of 3) | 7,125,445,531 | 602,122,637 | -91.5% |
| max RSS | 1.72 MB | 1.69 MB | ~0 |

Checksum output identical (`71364581`). The remaining 31,250 allocations are
the deliberately non-ASCII characters.

## Stage-2 self-compile

```bash
BLORP_CLI_C_OPTIMIZATION=-O2 benchmarks/build_stage2_compiler \
  --diagnostic-output /tmp/rss-static-strings/<base|cand>-diag /tmp/rss-static-strings/<base|cand>
benchmarks/self_compile_measure freeze --rev 584e87ac86bdd6b42694b07450a73ee7e85b87c3
benchmarks/self_compile_measure measure --compiler <bin> --diagnostic-compiler <diag> \
  --skip-build-check --input-rev 584e87ac86bdd6b42694b07450a73ee7e85b87c3 --samples 3 \
  [--baseline base.json --require-identical]
```

Base binary sha256 `beb111cd6fc1...`, candidate `acdab94d3d21...`.

| metric | base | candidate | delta |
| --- | ---: | ---: | ---: |
| allocations total | 187,942,262 | 185,817,132 | -1.13% |
| instructions retired (min) | 186,583,274,766 | 185,725,808,605 | -0.46% |
| instructions retired (median) | 186,640,020,678 | 185,888,918,096 | -0.40% |
| peak RSS bytes | 1,827,454,976 | 1,817,165,824 | -0.56% |
| generated C bytes | 78,810,045 | 78,810,045 | identical |

Generated C sha256 (both): `3d9d59065336edcfec83e06f59d9e362b78d6eafe7b8a9d634adae62a0fa0c8c`.
