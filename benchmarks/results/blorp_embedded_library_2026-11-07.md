# Embedded standard library: cost, 2026-11-07

Baseline: compiler built at `4d8ca0062` (origin/main). Candidate: the embedded
library change. macOS arm64, `-O0` links, other jobs ran on the machine, so wall
times are noisy.

Self-compile: each compiler, linked with `-DBLORP_MEMORY_DIAGNOSTICS=1` from its
own generated C, compiles `blorp/src/main.brp` (candidate tree) with
`--library-root blorp/standard_library` under
`BLORP_LEAK_CHECK=strict /usr/bin/time -l`, three runs each. The two outputs
are byte-identical.

| Metric | Baseline | Candidate | Change | Ceiling |
|---|---|---|---|---|
| Allocations (first revision) | 13,542,904 | 13,542,900 | -0.00% | +1% |
| Allocations (final revision) | 13,542,904 | 13,544,638 | +0.01% | +1% |
| Retired instructions, median of 3 | 41,435,863,572 | 41,429,496,150 | -0.02% | +1% |
| Binary size, normal `-O0` link | 5,479,880 B | 5,549,112 B | +69 KB | +256 KB |
| `make -C blorp compiler`, module present | 6.64 s (about 6.2 s in the independent run) | 6.22 s | about -6% to +1% | +10% |
| `make -C blorp compiler`, `build/generated` cleaned | 6.64 s | 7.16 s (independent run, load 2.87) | +7.8% | +10% |

Lines (git diff against origin/main): production +397 -69 (generator 191, Load,
CLI, Make); tests +562 -62 (generator and Load/freshness suites, CLI and e2e
cases, `test_bootstrap.sh`).

`blorp compile src/main.brp -o a.c` and `... --library-root standard_library`
from `blorp/` write byte-identical C.

Reproduce: `make -C blorp test-compiler`, keep the baseline C from a build at
`4d8ca0062`, link both with `-DBLORP_MEMORY_DIAGNOSTICS=1`, and run the command
above. The clean-build rows are the least certain: my own runs ranged 7.0 to 9.8 s while
other jobs ran, so the table uses the independent, quieter run.
