# Split test artifacts: 1 vs 8 translation units (2026-09-17)

`blorp test` now compiles each generated artifact as 8 C translation units
(`--c-translation-units=N`, `1` restores the single-TU behaviour) and compiles
the bodies concurrently before linking them with the cached runtime object.

## How this was measured

Host: Darwin 25.6.0, shared with other agents. Everything below ran under
`nice -n 19`, serially, **one run per configuration** — treat single-digit
percentage differences as noise. Load average is recorded per run.

Both configurations used the same compiler binary; the unit count was passed
explicitly, so nothing but the artifact shape differs:

```
BLORP_TEST_TIMINGS=1 nice -n 19 bin/blorp test --suite --timeout 300 \
    [--release] --c-translation-units=<N> <roots>
```

Corpora:

- `runtime`: every directory under `blorp/test/runtime` except `memory`
  (the leak gate owns that one) — 398 generated suites.
- `compiler`: every suite path in
  `blorp/test/compiler/compiler_test_ownership.json` — 245 generated suites.

Phase numbers are the `BLORP_TEST_TIMING` totals the harness prints:
`pipeline` is the Blorp compiler (emission included), `host_c` is the host C
compile plus link, `execution` is running the artifacts.

## -O0 (the gating default)

runtime corpus, load average ~2.5-3.1:

- N=1: wall 46s, pipeline 6303ms, host_c 11446ms, execution 28068ms
- N=8: wall 45s, pipeline 6509ms, host_c 9358ms, execution 28191ms

compiler corpus, load average ~2.9-4.3:

- N=1: wall 124s, pipeline 50517ms, host_c 36577ms, execution 34187ms
- N=8: wall 124s, pipeline 56697ms, host_c 23041ms, execution 40295ms

At -O0 the split is a wash on wall time. It takes 37% off `host_c` on the
compiler corpus (36.6s -> 23.0s), and gives most of it back in `pipeline`
(+12%), because split emission re-derives per-declaration material the
single-file renderer never needs. Execution is unchanged work; its +18% on the
compiler corpus is not explained by this change and is within what a shared
machine produces between two single runs.

## -O2 (`blorp test --release`, `scripts/test --release-artifacts`)

compiler corpus, load average ~3.4-3.9:

- N=1: wall 476s, pipeline 51486ms, host_c 388966ms, execution 31630ms
- N=8: wall 280s, pipeline 60758ms, host_c 184046ms, execution 31818ms

This is where the split pays: `host_c` drops 53% (389s -> 184s) and total wall
time drops 41% (476s -> 280s). At -O2 the host C compiler dominates, the extra
emission cost is a rounding error, and 8 independent units keep the machine
busy where one unit cannot.

## Gate wall times at the new default

`scripts/test <gate> --serial --no-build`, one run each, load average 4-9:
compiler-blorp 2m37s, runtime 51s, leak 1m03s, cli 59s, lsp 4m13s. The same
gates at N=1 (a build with the default flipped to 1) put runtime at 54-61s,
which is the same wash the corpus numbers show.

## Reading this

The default of 8 is not chosen for -O0 gate time — it does not help there. It
is chosen because it is free at -O0 and worth ~40% at -O2, so
`--release-artifacts` runs and any future -O2 gating get the parallelism
without a second decision. If -O0 gate time is what matters most, the honest
statement is that this change does not move it.
