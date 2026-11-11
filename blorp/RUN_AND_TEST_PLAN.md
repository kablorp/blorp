# `blorp run` and `blorp test`

Status: revision 2 after review. Keith chose R0(a), the process API first,
on 2026-11-08. R2 to R6 are recommendations to confirm before the CLI
landing, the last of the five below.

## Problem

`blorp` writes C and stops. To run a program a user must find a C compiler,
know the flags, link, run and clean up:

```sh
blorp compile hello.brp -o /tmp/hello.c
clang -std=c11 -O0 -DBLORP_MEMORY_DIAGNOSTICS=0 /tmp/hello.c -o /tmp/hello -lm -lpthread
/tmp/hello
```

Test suites also need diagnostics linked in and `BLORP_LEAK_CHECK=strict` in
the environment. Keith approved (CLI plan Decision 5, 2026-11-07) `blorp run
hello.brp [ARGUMENT ...]` and `blorp test SUITE.brp ...`, each compiling,
linking with the C compiler and running.

## Background

- **Running a program from Blorp today** is `process.run_to_files(program,
  arguments, stdout_path, stderr_path, timeout_ms)`: an absolute program
  path, output written to two files, stdin from `/dev/null`, a required
  positive timeout, and no environment control (callers wrap with
  `/usr/bin/env NAME=value`, as `self_hosted_harness.brp:22` does). The child
  runs in its own process group (`src/common/codegen/runtime/process.brp:191-194`) so
  a timeout can kill everything it started.
- **The approved process API** (`PROCESS_DECISIONS.md`) replaces it with
  `Command`, `capture`, `output` and `find_program`, deletes `run_to_files` in
  its L2, and deferred a `run` that shows output live until a consumer needs
  it. Nothing is implemented.
- **New natives need a seed rotation before the compiler can use them.** An
  unknown builtin label is a parse error ("unknown builtin operation",
  `src/common/syntax/parse.brp:4323-4329`; labels in `src/common/syntax/syntax.brp:441-465`).
  The pinned seed knows `process.run_to_files`; it does not know the new
  process natives.
- **Flags in use**: the harness links with `-std=c11 -O0`, the diagnostics
  macro and `-lm -lpthread` (`self_hosted_harness.brp:410-429`); a leak under
  `BLORP_LEAK_CHECK=strict` exits 99 (`blorp/README.md`, Measuring); a test
  program exits 0 when every test passes and 1 otherwise
  (`standard_library/test.brp:43`).

## R0: which process layer `run` and `test` build on (decided: a)

- **(a) Recommended: the process API, done properly.** Land process L0 and
  L1, then a terminal-sharing `run` designed as an amendment to
  `PROCESS_DECISIONS.md` (its own decision: the child must stay in the
  parent's foreground process group, or be handed the terminal with
  `tcsetpgrp`, so Ctrl-C and terminal reads work; that gives up the
  group-kill guarantee for `run` only; and `run` takes a narrower input than
  `Command`, with no `stdin` text and no timeout, so it cannot be given a
  contradiction), then a seed rotation, then this work. Live output, real
  stdin, no timeout, `find_program`, environment control. Four landings
  before `blorp run` exists.
- **(b) `run_to_files` now, no rotation.** Works today: `--cc` must be an
  absolute path (default a named `/usr/bin/cc`), leak checking through
  `/usr/bin/env BLORP_LEAK_CHECK=strict`, output replayed after the program
  ends, stdin always empty, and every run needs a timeout (a named large
  limit). It is then rewritten when L2 deletes `run_to_files`.
- **(c) Process L0 and L1 with `capture` only, then a rotation.** Proper
  `find_program` and environment, no timeout, but output still replayed after
  the program ends and no stdin. Avoids the `run` amendment.

Decision 5 says "compiles, links and runs"; (b) and (c) meet it without live
output. Live output and stdin are what only (a) gives.

## Decisions for this plan (recommended; to confirm before the CLI landing)

**R2. Finding the C compiler.** `--cc PATH` on `run` and `test`; without it,
`find_program("cc")` (the Makefile defaults to `clang`; `cc` is the portable
name). No environment read (CLI Decision 3).

**R3. Optimization.** `-O0` by default; `--release` gives `-O2`. Both link
`-std=c11 ... -lm -lpthread`; no `-Werror` and no sanitizers, which are the
repository's checks, not a user's.

**R4. Leak checking in `blorp test`.** Always on: `test` links with
`-DBLORP_MEMORY_DIAGNOSTICS=1` and runs with `BLORP_LEAK_CHECK=strict`; `run`
links with diagnostics off.

**R5. Exit statuses**, a total mapping:

| Outcome | `blorp run` | `blorp test` |
| --- | --- | --- |
| compile or usage error | the CLI's 1 to 4 | the same |
| the C compiler cannot start | 3 | 3 |
| the emitted C fails to compile or link | 4 (a fault in Blorp) | 4 |
| `Exited(n)` | `n` | 0 → 0; 1 → 1; 99 (leak) → 1, after printing the leak line; anything else → 4 |
| `Signaled(s)` | `128 + s`, as shells report it | `128 + s` |

`blorp run` passes the program's status through, so a program that exits 1
and a compile diagnostic are both 1; stderr tells them apart, as with `cargo
run`. A link failure is 4 because standard-library programs always link;
`foreign` libraries need link flags that `run` does not take yet, and a
program using one gets a link error until a `--link` option exists (not in
scope).

**R6. Arguments.** `blorp run [OPTION ...] INPUT.brp [ARGUMENT ...]`: options
before the input; everything after it goes to the program verbatim, including
`-x` words. The alternative is a `--` separator.

## Proposed solution

```text
blorp run [--cc PATH] [--release] [--library-root DIR] INPUT.brp [ARGUMENT ...]
blorp test [--cc PATH] [--library-root DIR] SUITE.brp [SUITE.brp ...]
```

1. Parsing: `RunRequest` and `TestRequest` in `src/cli.brp`. The CLI's
   `Command` union (`src/cli.brp:34`) is renamed `CliCommand`, with
   `parse_command` and its callers, so `process.Command` keeps its name.
2. `test` compiles exactly as `compile --test-suite` does: the first suite
   owns the entry, later suites follow in order, a suite listed twice is
   Load's error. `compile --test-suite` stays, as the build-only form Make
   and the driver use; it is removed once they move onto `blorp test` (a
   later change), which completes Decision 5's "replaces".
3. Both compile to C and link inside `fs.with_temporary_directory` under a
   named parent, `/tmp` (there is no environment read for `TMPDIR`). The
   directory is removed when `blorp` returns, including when the program is
   killed by a signal; if `blorp` itself is killed, it stays, as `fs.brp:44-50`
   documents.
4. Run with the layer R0 chooses and exit per R5.

## Scope and non-goals

In scope: `run` and `test` in the CLI, help, README, AGENTS.md, and
`CLI_PLAN.md`'s wording on `--test-suite`. The process API work R0(a) needs
is planned in `PROCESS_DECISIONS.md` (its L0, L1 and a new amendment for
`run`), not here. Not in scope: build caching, parallel suites, moving the
e2e driver onto `blorp test`, watch modes, `--link`, Windows.

## Risks and unknowns

- **The seed rotation** (R0 a or c) is the long pole: plan it with the
  process landings.
- **Terminal handling** (R0 a) is new ground for the process core; its
  amendment needs its own review, with a spike on macOS and Linux.
- **`cc` on CI runners** must exist where the seed workflow runs.

## Testing

- `src/cli.brp` unit tests for both commands' parses and usage errors,
  including R6's argument handling.
- e2e cases in `self_hosted_cli.brp`, exact output and status, every row of
  R5: a program that prints and exits 3; arguments with `--flag` words; a
  program reading stdin (R0 a only); a compile error; a missing `--cc`; a
  passing suite, a failing suite, a leaking suite, and a suite killed by a
  signal; no temporary directory left under `/tmp` afterwards.
- Gates: `make -C blorp test`, then `make -C blorp test-e2e
  INSTRUCTION_CHECK=on`, `bash blorp/test/tooling/test_bootstrap.sh`,
  `scripts/blorp-fixpoint --prove`.

## Acceptance criteria

- `blorp run hello.brp` from any directory runs the program and exits with
  its status (live output under R0 a).
- From the repository root, `blorp test
  blorp/test/unit/test_format/test_layout.brp` passes with the leak check
  on (the suite reads its fixtures relative to the repository root).
- All gates pass; nothing is left under `/tmp`.

## Release strategy

Under R0(a): process L0, L1, the `run` amendment, the seed rotation, then
this change, each its own landing with its own brief and ceilings. Under
R0(b): this change alone, rewritten when process L2 lands. Back out by
reverting; `blorp compile` is unaffected.
