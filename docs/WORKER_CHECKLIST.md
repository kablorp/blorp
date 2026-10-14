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
optimization level, generated-C split); check `--help` rather than assume a
fixed field set. The
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

## Hand-Back Gates

Before handing back, ask the script instead of judging which gates the change
owns: `scripts/compiler-check --changed --plan` is read-only and prints the
hand-back gates and the suites to run. Run the focused suites that own the
change. The Docker premerge gate is optional and runs on request. Details are in
[`scripts/README.md`](../scripts/README.md#test-gates).

## Measure

Full protocol: [`benchmarks/README.md`](../benchmarks/README.md#self-compile-measurement-protocol).
Allocation counts and retired instructions are evidence; wall time is not.
Compare only against a baseline built with the same toolchain (clang version,
bootstrap pin, `-O` level).

- **Stage-2 rule**: `bin/blorp` is linked by the pinned bootstrap
  (`blorp/build/bootstrap.env`), so a backend or
  `blorp/src/lib/runtime/native` change does not affect `bin/blorp`'s own
  speed until measured with a stage-2 compiler
  (`benchmarks/build_stage2_compiler`, or `self_compile_measure --stage2`).
  A compiler fix on `main` does not reach a branch's binary until the
  bootstrap pin is rotated.
- **Fixpoint**: a change to Core passes or the backend that alters emitted C
  runs `scripts/compiler-fixpoint` before review: stage 2 and stage 3 must
  emit identical C. It is not in the premerge gate because it builds two
  more compilers; the worker who changes code generation runs it once.
- `--require-identical` applies to semantics-preserving source refactors.
  Intentional codegen changes instead require generated-C review, behavioral
  and ownership gates, and the fixpoint check above.
- Run gate commands directly (`scripts/test`, `scripts/compiler-check`, etc.);
  do not spawn many compiled test binaries in parallel yourself (macOS
  `syspolicyd` stalls). Measurement noise from concurrent work is accepted;
  use the harness's min-of-runs, never wall time, as evidence.

## Land

- One task lands as one squash-merged commit on `main` with a standalone
  title: no issue numbers, no task names, no "Merge …" auto-title, no pasted
  tables (fold the measurement record into the body instead).
- Keep commit messages short: what was wrong, what changed, one or two
  headline numbers.
- Gates that must pass before landing scale with the change; see the task
  boundary table in [`AGENTS.md`](../AGENTS.md#find-the-right-boundary-first)
  and, for perf work specifically, the owning suite plus
  `scripts/compiler-check --changed --base main`.
- Do not rebase, merge, or push a shared coordinator-owned branch; the
  coordinator integrates.

## Process Rules

- Poll long builds and gates in the foreground with a BOUNDED loop
  (`for i in $(seq 1 60); do grep -q '^BLORP_GATE_RESULT' log && break; sleep 30; done`),
  never an unbounded `until ...; do sleep; done`; orphaned `until` loops from
  finished workers have been found spinning for hours. Do not end a turn
  while a build or gate runs.

- Never spawn parallel compiled binaries on macOS.
- Test codegen/RC changes in isolation before the full suite.
- Do not parallelize Perceus or other late Core passes.
- A negative performance result is still a valid, reportable result.
