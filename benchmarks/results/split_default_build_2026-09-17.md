# Default multi-TU build, `make` from clean (2026-09-17)

Machine: Apple Silicon (arm64), macOS 26.6.2, 10 logical cores (`sysctl -n
hw.ncpu`), Apple clang 21.0.0 (clang-2100.3.34.2). One run each (single
sample; see benchmarks/results/split_generated_c_O0_O2_2026-09-17.md for the
multi-run compile-only measurement this default is based on).

Command (identical apart from `BLORP_CLI_C_SPLIT`), each preceded by
`make clean`:

```
env BLORP_CLI_C_OPTIMIZATION=-O2 BLORP_CLI_C_SPLIT=1 make   # old single-TU behavior (escape hatch)
env BLORP_CLI_C_OPTIMIZATION=-O2 make                        # new default, BLORP_CLI_C_SPLIT=8
```

Wall times (`time make ...`, real):

| BLORP_CLI_C_SPLIT | wall time |
|---|---|
| 1 (single TU) | 4m51.81s |
| 8 (new default) | 1m30.37s |

3.2x faster wall-clock for a full `make clean && make` at -O2. Both builds
produce a working `bin/blorp` (`bin/blorp --version` succeeds) and pass the
110-case CLI smoke suite (`scripts/test cli --serial --no-build`).

At the local default optimization (`BLORP_CLI_C_OPTIMIZATION` unset, i.e.
-O0), the split still parallelizes the host C compile but -O0 compiles are
already fast enough that the difference is smaller and dominated by
self-hosting (generating the C); it was not re-measured here since -O2 is
the case that matters for CI and release builds.
