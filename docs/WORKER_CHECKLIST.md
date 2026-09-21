# Worker Checklist

The one page to read before starting a compiler or compiler-performance task.
It links to the detailed sources instead of duplicating them; when this page
and a linked doc disagree, the linked doc wins.

## Set Up

```bash
git worktree add -b <topic>/<slug> ../blorp-<slug> origin/main
cd ../blorp-<slug>
make                              # -O0 by default; fast edit-loop link step
bin/blorp --version
scripts/compiler-build-status     # FRESH / STALE / UNKNOWN, no rebuild
```

`bin/blorp --version` and `scripts/compiler-build-status` are the two ways to
confirm which binary you actually have (commit, who/what compiled it,
optimization level, generated-C split); both are being extended to print
more provenance, so check `--help` rather than assume a fixed field set. The
`cc:` line in `--version` and the harness's toolchain fingerprint both record
whatever `BLORP_CC` (default Clang) was set to when the binary was built.
Never `git stash` in a worktree — worktrees share one stash list and a pop
can destroy another agent's edits; snapshot with `git diff > file` instead.

For perf/codegen gates, run `BLORP_CLI_C_OPTIMIZATION=-O2 make` — plain
`make` defaults to `-O0` for a fast edit-loop link. Switching between `-O0`
and `-O2` in the same worktree forces a full re-link; don't interleave them.

## Fast Feedback Loop

Full recipes: [`docs/DEVELOPMENT.md`](DEVELOPMENT.md#core-pipeline-snapshots),
[`docs/DEVELOPMENT.md`](DEVELOPMENT.md#timing-compiler-phases).

```bash
bin/blorp compile --stop-after=lower --no-format program.brp       # end early
bin/blorp compile --dump-core-after=perceus --no-format program.brp # snapshot a pass
bin/blorp compile --time-phases --no-format program.brp             # per-phase timing
scripts/compiler-check --changed --plan   # read-only: what would run
scripts/compiler-check --changed          # build once, run manifest-owned checks
```

Use the smallest program and the narrowest snapshot that exercises the
behavior under investigation before reaching for a broad gate.

## Measure

Full protocol: [`benchmarks/README.md`](../benchmarks/README.md#self-compile-measurement-protocol).

```bash
benchmarks/self_compile_measure --label <task> --input-rev <rev> \
  --baseline benchmarks/results/self_compile_baseline_<toolchain>.json \
  --output /tmp/<task>.json --require-identical
```

- Compare only against a baseline built with the same toolchain (clang
  version, bootstrap pin, `-O` level); wall time is not evidence, allocation
  counts and retired instructions are.
- **Stage-2 rule**: `bin/blorp` is linked by the pinned bootstrap
  (`blorp/build/bootstrap.env`), so a backend or
  `blorp/src/lib/runtime/native` change does not affect `bin/blorp`'s own
  speed until measured with a stage-2 compiler
  (`benchmarks/build_stage2_compiler`, or `self_compile_measure --stage2`).
  A compiler fix on `main` does not reach a branch's binary until the
  bootstrap pin is rotated.
- Serialize any command that spawns many compiled binaries — `scripts/test`,
  `scripts/compiler-check` — with
  `benchmarks/self_compile_measure lock -- <cmd>`, and never run compiled
  test binaries in parallel yourself (macOS `syspolicyd` stalls).

## Land

- One task lands as one squash-merged commit on `main` with a standalone
  title: no issue numbers, no task names, no "Merge …" auto-title, no pasted
  tables (fold the measurement record into the body instead).
- Keep commit messages short: what was wrong, what changed, one or two
  headline numbers.
- Gates that must pass before landing scale with the change; see the task
  boundary table in [`AGENTS.md`](../AGENTS.md#find-the-right-boundary-first)
  and, for perf work specifically, the owning suite plus
  `self_compile_measure lock -- scripts/compiler-check --changed --base main`.
- Do not rebase, merge, or push a shared coordinator-owned branch; the
  coordinator integrates.

## Process Rules

- Never spawn parallel compiled binaries on macOS.
- Test codegen/RC changes in isolation before the full suite.
- Do not parallelize Perceus or other late Core passes.
- A negative performance result is still a valid, reportable result.
