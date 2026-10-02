# Discovery stage as the default front end, 2026-10-01

The default front end is the discovery stage; `BLORP_FRONT_END=existing` runs
the old path. A stage-2 `-O2` compiler (commit ebf16fd6f, built with
`BLORP_CLI_C_OPTIMIZATION=-O2 benchmarks/build_stage2_compiler`) compiling
`blorp/src/main.brp` to C, the same binary with the variable unset (default)
and set to `existing`, run back to back:

```bash
BLORP_FRONT_END=existing benchmarks/self_compile_measure --stage2 --skip-build-check \
  --label front_end_existing --samples 3 --output <existing>.json
env -u BLORP_FRONT_END benchmarks/self_compile_measure --stage2 --skip-build-check \
  --label front_end_default --samples 3 --require-identical --baseline <existing>.json \
  --output <default>.json
```

Raw samples: `self_compile_front_end_existing_stage2_O2_2026-10-01_flip.json` and
`self_compile_front_end_default_stage2_O2_2026-10-01_flip.json`. A second pair in
the opposite order is summarized in the last column.

| | Existing | Default (stage) | Change | Second pair, change |
| --- | ---: | ---: | ---: | ---: |
| Generated C | 79,625,425 bytes | identical | `cmp` equal | identical |
| Allocations, source discovery | 9,466,700 | 7,939,636 | -16.13% | -16.13% |
| Allocations, whole compile | 212,893,344 | 211,366,280 | -0.72% | -0.72% |
| Retired instructions (min of 3) | 400.639 G | 405.269 G | +1.16% | +1.16% (405.901 G vs 401.195 G) |
| Peak RSS | 2,155,266,048 | 2,151,415,808 | -0.18% | -0.11% |

Allocations are deterministic and unchanged after discovery. The default costs
1.16% more retired instructions than the existing front end, in both orders,
where the first switch-on measurement
(`discovery_stage_switched_on_2026-10-01.md`) found 0.43% fewer. The stage has
grown since (the rewritten parsers, the rendered diagnostics); the cost is for
the next stage cleanup to look at, not a reason to keep the old default.

The `bin/blorp` (bootstrap-linked, `-O0`) self-compile C is byte-identical with
either front end (79,372,544 bytes).
