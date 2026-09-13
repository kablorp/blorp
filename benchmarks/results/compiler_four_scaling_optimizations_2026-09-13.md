# Four compiler scaling optimizations: self-emission check

Date: 2026-09-13. Baseline compiler source: `eb6893ea`; integrated compiler:
`68a0de0f` on local `main`. The baseline compiler was rebuilt from that exact
source in a separate worktree. Both executables compiled the same integrated
`blorp/src/main.brp` source, serially in three old/new pairs. Each command
stopped after C emission; the generated C was not compiled.

```bash
<baseline-bin> compile --no-format --no-embed-runtime --time-phases \
  -o /tmp/blorp-self-baseline-eb6893ea.c blorp/src/main.brp
bin/blorp compile --no-format --no-embed-runtime --time-phases \
  -o /tmp/blorp-self-integrated-68a0de0f.c blorp/src/main.brp
```

Times are milliseconds. The phase rows are broad pipeline stages, so they
corroborate the direct per-function benchmarks without assigning every phase
change to one optimized function.

| Phase | Baseline samples | Integrated samples | Baseline median | Integrated median |
| --- | --- | --- | ---: | ---: |
| typed_frontend | 7581.016, 7582.065, 7575.361 | 7104.018, 7168.330, 7129.013 | 7581.016 | 7129.013 |
| core_lowering | 2033.067, 2037.101, 2024.816 | 1990.411, 2018.157, 2003.756 | 2033.067 | 2003.756 |
| early_core | 7783.371, 7713.794, 7669.597 | 7660.779, 7690.406, 7675.550 | 7713.794 | 7675.550 |
| runtime_projection | 1635.015, 1609.653, 1625.662 | 1046.699, 1046.806, 1044.684 | 1625.662 | 1046.699 |
| late_core | 12953.797, 12861.849, 12834.146 | 12731.703, 12791.164, 12768.580 | 12861.849 | 12768.580 |
| backend_emission | 4431.336, 4389.677, 4381.827 | 4366.589, 4380.197, 4430.289 | 4389.677 | 4380.197 |
| phase_total | 36418.593, 36195.756, 36112.262 | 34901.482, 35096.123, 35052.942 | 36195.756 | 35052.942 |
| outer_total | 36544.803, 36319.312, 36232.120 | 35021.194, 35218.990, 35177.362 | 36319.312 | 35177.362 |

Median outer latency fell by 1,142 ms (3.1%). Median runtime projection fell
by 579 ms (35.6%). No stage shows a repeatable material regression across
these three samples. This measurement excludes the time to compile generated
C, as intended.

The combined default local gate passed after integration: `scripts/test`
reported 11,032 passed, 0 failed across Compiler-Blorp, Runtime, Leak-check,
Doctests, and CLI.
