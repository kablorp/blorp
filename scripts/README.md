# Scripts

This directory holds the maintained shell and Python entrypoints for local
validation, Docker validation, builds and release packaging. Prefer these
scripts over calling lower-level test runners directly.

## Validating a change

Validate with the focused suites that own the change, then land. The long
gates are optional and run on request.

1. `scripts/compiler-check --changed --plan` names the focused suites, special
   checks and hand-back gates for the change, without building or running
   anything.
2. Run those suites. `bin/blorp test path/to/test.brp` is the narrow loop once
   `scripts/compiler-build-status` reports `FRESH`; run `make` first when it
   does not.
3. Run the `scripts/test` gates the plan recommends for anything the focused
   suites do not cover.
4. `scripts/land` merges and pushes. It runs no gates.

The Docker premerge gate (`scripts/docker-gate --premerge-gate`, about 35
minutes) and `scripts/premerge-gate` are for preview and release validation
(`docs/RELEASES.md`) and for a change whose reviewer asks for them. They are
not required before landing.

Changes under `blorp_2/` are validated with `make -C blorp_2 test`;
`scripts/compiler-check` selects nothing for that tree.

CI's macOS Blorp 2 lane restores the existing compiler's build artifact and
runs unit, runtime, grammar and tooling suites, then e2e tests. The e2e suite
builds the pilot once using the restored compiler and runs every fixture.
Hosted macOS runners may omit `/usr/bin/time -l` retired-instruction counters,
so the CI step explicitly sets `BLORP_2_INSTRUCTION_CHECK=disabled`. It skips
only instruction measurement and limits; allocation caps, strict leak parsing,
native sanitizers and every fixture remain enabled. Local e2e defaults to
`required`; missing counters still fail, and empty or unknown settings reject.
E2e disables the suite timeout; the CI job retains its 45-minute limit. Failures
upload the unit and e2e logs, and packaging waits for the matching platform's
test lanes.

## Focused compiler checks

`scripts/compiler-check` selects checks from
`blorp/test/test_compiler/compiler_test_ownership.json`. It does not infer
owners from names, imports, timings or earlier failures.

```bash
scripts/compiler-check blorp/test/test_compiler/test_pipeline/test_type_header_graph.brp
scripts/compiler-check --stage typecheck
scripts/compiler-check --changed
scripts/compiler-check --changed --base origin/main
scripts/compiler-check --changed --plan
scripts/compiler-check --validate-manifest
```

- An exact suite path runs only that registered suite.
- `--changed` selects by the staged, unstaged and untracked production
  compiler sources; `--base` adds committed changes since the merge base with
  the named ref.
- `--plan` prints the selected sources, suites, special checks, exact commands
  and broad-gate recommendations without building, running tests, creating
  logs or writing files. A plan that selects nothing is a no-op explanation,
  not a passing validation; use the build, docs or release checks for those
  changes.
- Without `--plan` it prepares the compiler once, runs suites with
  `bin/blorp test` and registered gate checks with
  `scripts/test --no-build --log-dir`. Passing runs remove their temporary
  logs; failing runs keep complete output and an exact rerun under the ignored
  `logs/compiler-check-*` tree.

Sources under `blorp/src/compiler_new` and suites under
`blorp/test/test_compiler_new` are outside the manifest, so `--changed` selects
no focused check for them and prints `Hand-back gates` (`--plan --json`:
`hand_back`) instead. `tree path only` (every changed path is a `compiler_new`
module no other `blorp/src` module imports, a `compiler_new` test or data file,
the parity script and its test, or documentation) hands back
`scripts/compiler-build-status --quiet`, `bin/blorp test` on each registered
suite that imports a changed file, and
`scripts/test --no-build compiler-new compiler-new-parity`. `broad` (any other
path, including a deleted one or one the import graph cannot place) hands back
`scripts/test compiler-new compiler-new-parity compiler-blorp` plus the
manifest's recommendations. The commands are not run for you.

## Test gates

`scripts/test` is the main entrypoint. With no argument it runs the default
gates (`compiler-blorp`, `compiler-new`, `runtime`, `leak`, `doctest`, `cli`);
name gates to run only those.

```bash
scripts/test compiler-blorp     # Blorp TestSuites plus marked production check fixtures
scripts/test compiler-tools     # formatter/purify/lint fixtures plus tooling guards
scripts/test compiler-core-sanitize  # Core TestSuites under ASan (roots: compiler-core-sanitize-roots.txt)
scripts/test compiler-blorp-sanitize # compiler suites under ASan
scripts/test compiler-new       # TestSuites of the discovery stage (blorp/src/compiler_new)
scripts/test compiler-new-parity # discovery stage against the existing front end over the corpus
scripts/test std-check          # standard-library typecheck sweep
scripts/test runtime            # runtime .brp tests
scripts/test leak               # ownership suites, leak baselines and diagnostics
scripts/test doctest            # standard-library doctests
scripts/test cli                # public CLI and LSP smoke tests
scripts/test cli-deep           # full CLI package and formatter integration tests
scripts/test lsp                # public LSP protocol fixtures
scripts/test package            # public package lifecycle integration
```

Options:

```bash
scripts/test --serial            # one gate at a time
scripts/test --verbose           # stream child-runner output
scripts/test --log-dir logs      # keep complete gate logs
scripts/test --no-build          # test the existing installed toolchain
scripts/test --timings           # print generated TestSuite phase timings
scripts/test --release-compiler  # build bin/blorp at -O2 for full gate runs
scripts/test --release-artifacts # compile test artifacts at -O2 (default -O0)
```

- `scripts/test` is quiet by default: a summary with per-gate timing, then
  focused excerpts for failures. `--no-build` is only for a toolchain already
  built from the intended sources; without it the script installs the current
  compiler first. `--release-compiler` exports `BLORP_CLI_C_OPTIMIZATION=-O2`
  for that install; see "Compiler optimization level" in `docs/DEVELOPMENT.md`.
- `compiler-blorp` also runs every fixture marked `RUN-BLORP-CHECK` through
  `blorp/test/test_lib/run_blorp_check_fixtures.py`; `scripts/test` pins the
  expected fixture count (`expected_blorp_check_fixture_count`).
- `compiler-new` runs the TestSuites registered in
  `blorp/test/test_compiler_new/compiler_new_test_ownership.json` after
  checking that every `test_*.brp` there is registered and that its tools and
  support modules typecheck. It guards production code: `bin/blorp` links the
  discovery stage through `compiler/discovery_front_end.brp` and
  `compiler/discovery_adapter.brp`, so it is a default gate.
- Several selected gates run in fixed waves (compiler-blorp, compiler-tools,
  compiler-core-sanitize, compiler-blorp-sanitize, compiler-new,
  compiler-new-parity, std-check, runtime, then leak + doctest + cli + lsp,
  package, cli-deep); unselected gates are skipped. Use `--serial` for one at a
  time. On macOS, many freshly compiled binaries running at once stall in
  `syspolicyd`, so do not run compiled binaries in parallel there;
  `scripts/premerge-gate` passes `--serial` on macOS for that reason.

Timeouts (environment overrides):

- `BLORP_TEST_TIMEOUT`: generated test artifacts. `BLORP_RUNTIME_TEST_TIMEOUT`:
  the single runtime corpus (default 60 seconds; other artifacts 30).
- `BLORP_LEAK_TEST_TIMEOUT`: the leak-check corpus (default 60 seconds). A
  positive value is a floor per batch; `bin/blorp test --leak-check` grants each
  batch the larger of the floor and 5 seconds
  (`LEAK_CHECKED_SOURCE_TIMEOUT_SECONDS` in `blorp/src/test/plan.brp`) times its
  test sources. Zero disables the deadline.
- `BLORP_COMPILER_TEST_TIMEOUT`: compiler tests (grouped suites 360 seconds,
  individual fixtures and codegen audits 30).
  `BLORP_COMPILER_SANITIZE_TEST_TIMEOUT`: compiler sanitizer gates (180).
- `BLORP_COMPILER_TEST_PROGRESS=1` streams per-artifact progress, as CI does.

### Gate verdicts

Every gate entry point (`scripts/test`, `scripts/compiler-check`,
`scripts/premerge-gate`, `scripts/docker-gate`) prints exactly one verdict line
as the last line of stdout, and the exit status agrees with it:

```
BLORP_GATE_RESULT gate=<entrypoint> status=PASS|FAIL passed=N failed=N tests=N
```

Automation reads this line rather than prose. An interrupted or aborted
`scripts/test`, `scripts/premerge-gate` or `scripts/docker-gate` stops its child
processes and prints `status=FAIL`. `--help` and `premerge-gate --dry-run` print
no verdict. `blorp/test/test_build/test_gate_verdicts.sh` covers `scripts/test`.

### Discovery-stage parity

`scripts/compiler-new-parity` (the `compiler-new-parity` gate, 1-2 minutes) holds
the discovery stage to the existing front end over every tracked `.brp` file
under `blorp/src`, `standard_library/src` and `blorp/test`: every token, each
file's lexer diagnostics and accept/reject verdict, and the stage's module graph
for the self-compile root and a `blorp test` root. A mismatch prints the file and
the first differing token. Known divergences are listed in the script with a
reason (`KNOWN_DIVERGENCES`, `KNOWN_POSITION_DIVERGENCES`,
`WORDING_DIFFERENCES`); an entry that stops disagreeing fails the gate until it
is removed. A syntax change lands in both parsers and this gate keeps them in
agreement.

The tree-path modes iterate on the unlinked tree parsers. `--stop-census` ranks
why the tree scan stopped at each module's first unread declaration;
`--stop-reason LABEL`, `--files PATH...` and `--adapter-only` narrow a run (no
verdict line, dumpers built at `-O0`). `scripts/discovery-fuzz` is a
differential fuzzer for the tree path against the old parser. It needs a `FRESH`
`bin/blorp`, samples rather than gates, and each bug it finds becomes a fixed
case in
`blorp/test/test_compiler/test_stage_04_modules/test_discovery_fuzz_cases.brp`.

```bash
scripts/compiler-new-parity --stop-census
scripts/discovery-fuzz --count 20000 --minimise
scripts/discovery-fuzz --gate    # fixed seed and count; exits 1 on failure
```

## Premerge gate

`scripts/premerge-gate` is the broad local gate for preview and release
validation. It composes, in order:

- preflight and a clean `-O2` build (`--no-release-compiler` for `-O0`)
- `make quality`
- `make benchmark-tooling-check`, only when the change touches benchmark tooling
- `scripts/test --release-compiler compiler-blorp compiler-tools std-check runtime leak doctest cli-deep lsp compiler-new compiler-new-parity` (with `--serial` on macOS only)
- the generated-C audit in `blorp/test/test_compiler/test_pipeline/codegen_audit/`
  (up to 4 workers on Linux, one on macOS; `--jobs N` or
  `BLORP_CODEGEN_AUDIT_JOBS` overrides)
- preview CLI/runtime smoke, guarded to leave the working tree unchanged
- example checks and selected example runs
- sanitizer tests (`make test-asan`)
- Docker validation when Docker is available
- a lightweight secret-pattern scan
- drift and hygiene checks

```bash
scripts/premerge-gate
scripts/premerge-gate --quick
scripts/premerge-gate --no-docker --no-sanitize
scripts/premerge-gate --require-docker
scripts/premerge-gate --dry-run
```

Use `--quick` for fast local confidence; use the full default gate before
claiming a preview- or release-sensitive change is ready.

`scripts/gate-scope` classifies the change first and the gate prints
`Change scope: ...`. The changed paths are those that differ from the merge
base of `HEAD` and `origin/main` (committed, staged, unstaged and untracked
files). The scope is `docs-only` when every path is `*.md` or under `docs/`:
the gate then runs only preflight, the security scan and the static hygiene
checks. Anything else, including a path no rule recognises, is `full`; every
step runs, except benchmark tooling, which runs only when a changed path is one
of its inputs (`BENCHMARK_TOOLING_PATH_RULES` in `scripts/gate-scope`;
`benchmarks/results/` is data and does not count). `--full`, or a missing merge
base, forces every step. `blorp/test/test_build/test_gate_scope.py` covers the
rules.

Every run ends with an aligned step table (status and seconds per step), one
`BLORP_GATE_STEP name=<slug> status=PASS|FAIL|SKIP seconds=N` line per step, then
the verdict. `blorp/test/test_build/test_premerge_gate_steps.py` covers the
summary.

## Docker gate

`scripts/docker-gate` runs validation in an Ubuntu 24.04 container. Like the
premerge gate, it builds `bin/blorp` at `-O2` by default. It is optional: use it
to reproduce a Linux failure or when asked for the CI-equivalent run.

```bash
scripts/docker-gate                          # normal test gate on linux/amd64
scripts/docker-gate --premerge-gate          # scripts/premerge-gate --no-docker inside
scripts/docker-gate --premerge-gate --all-platforms
scripts/docker-gate --platform linux/arm64 -- blorp/test/test_runtime/test_numeric/test_float16_vector.brp
scripts/docker-gate --shell
```

- The default volume mode mounts the working tree; `--clean` copies the source
  into the image for a hermetic, CI-like run.
- Each gate builds the compiler inside its container, which peaks at several
  GB, so a gate holds one of `BLORP_DOCKER_GATE_MAX_CONCURRENT` (default 3)
  slots under `BLORP_DOCKER_GATE_SLOT_DIR` for its `docker run`, and later gates
  queue. `BLORP_DOCKER_GATE_BUILD_JOBS` overrides the parallel `clang` jobs per
  gate. Static-analysis stamps are cached in the `blorp-quality-cache` volume; an
  image built before the volume existed needs `--rebuild` once.

### Remote gate host

Set `BLORP_DOCKER_GATE_HOST` to an SSH host (an `~/.ssh/config` alias with key
login) to run gates on that machine's Docker. Put it in a gitignored `.env` at
the repository root, which every worktree reads, or in the environment, which
wins. `.env` holds `NAME=value` lines; only `BLORP_DOCKER_GATE_*` names are
read, and the file is parsed, not sourced.

- The working tree, including uncommitted and untracked files, is sent as a
  snapshot commit built in a private index, so the checkout is untouched. The
  gate runs in a fresh worktree of `BLORP_DOCKER_GATE_REMOTE_REPO` (default
  `blorp-gate` in the remote home), removed when the gate ends; a later run
  sweeps what a cut-off run left.
- The remote runs at most `BLORP_DOCKER_GATE_REMOTE_MAX_CONCURRENT` (default
  10) gates at once. A remote gate that itself exits 255 is reported as 254, so
  255 always means the connection failed.
- If the host is unreachable, lacks git or a running Docker, has under 20 GiB
  free, or the snapshot cannot be sent, the script prints a line starting
  `docker-gate: WARNING: not running on the gate host:` with the reason, and
  runs the gate locally. A gate that ran remotely and failed returns its status;
  it is never rerun locally. `--shell` always runs locally.
- The host needs Remote Login (SSH), git, and Docker reachable from a
  non-interactive shell. With Docker Desktop on macOS, put its CLI directory on
  `PATH` in `~/.zshenv`, remove `credsStore` from `~/.docker/config.json`, keep
  a user logged in, and disable sleep.

`blorp/test/test_build/test_docker_gate_remote.py` covers the remote path.

## Landing a branch

Validate the branch with the focused suites first (see "Validating a change").

```bash
scripts/land <branch> --title "<title>" [--body "<text>"] [--dry-run]
```

`scripts/land` merges `origin/main` into the branch (in the branch's own
worktree if it is checked out somewhere and clean, else in a temporary one; a
conflict stops it, to be resolved on the branch), squash-merges the branch onto
`origin/main` as one commit with the given title and body in a temporary
detached worktree, and pushes it to `origin main`. If `main` moved first, it
merges again and retries up to five times; any other push failure stops it. The
caller's checkout is never touched and no gate runs. Titles starting with
`Merge`, or containing an `#<digits>` issue reference, are refused. `--dry-run`
stops after the squash commit and prints its SHA; the branch still receives the
merge from `origin/main`.

## Build and bootstrap

`bin/blorp --version` is the source of truth for what a binary is: commit (plus
`-dirty`), target triple, `compiled_by` (the bootstrap tag, or `self-<commit>`
for a stage-2 binary), `optimization`, `split` (translation-unit count) and `cc`.
They are stamped in from `blorp/src/lib/runtime/native/build_stamp.c`, so a new
commit relinks rather than recompiles the compiler.

- `scripts/compiler-build-status` reads that block from the binary and prints
  `FRESH`, `STALE` or `UNKNOWN` without rebuilding. It reports `STALE` when
  `blorp/build/bootstrap.env`'s tag no longer matches a `dev-` `compiled_by`.
  Check it before a direct `bin/blorp` test and run `make` if it is not fresh.
- `make compiler-build-source-generator` compiles
  `blorp/tool/generate_build_sources.brp`, which writes the generated build
  inputs (embedded standard library, build info, embedded runtime C) that every
  build and CI run uses.
- `scripts/blorp-build-inputs sources|headers|entry` print what `bin/blorp` is
  built from: modules reached by imports from the CLI entry module, every module
  in `blorp/src/compiler/stage_01_generated_inputs/`, and the standard library. A
  module no built program imports is not an input, so editing it leaves
  `bin/blorp` FRESH. If the import graph cannot be resolved, the script lists
  every `blorp/src` module, so it can cost a rebuild but never report a stale
  binary FRESH. The reader is `scripts/blorp_import_graph.py`.
- `scripts/blorp-cli-embedded-manifest` records what an installed `bin/blorp` was
  built from; the Makefile uses it to decide whether to reinstall.
- `scripts/split-generated-c <generated.c> <out_dir> -n N` splits the compiler's
  generated C into a shared header and N translation units that the Makefile
  compiles in parallel (`BLORP_CLI_C_SPLIT`).
- `scripts/with-build-lock COMMAND...` serializes build/test gates per worktree
  (`scripts/test` and `scripts/premerge-gate` use it) so concurrent runs do not
  race on generated caches. It uses `flock`, or a POSIX file lock in
  `scripts/with-build-lock-fcntl` where `flock` is missing.
- `make install` builds with the pinned release's `blorp compile`. Local builds
  compile generated compiler C at `-O0`; `BLORP_CLI_C_OPTIMIZATION` selects the
  level (CI and releases use `-O2`) and `BLORP_CLI_RUNTIME_C_OPTIMIZATION` the
  runtime object's. `make generate-blorp-cli-c`, `prepare-blorp-cli-runtime`,
  `prepare-blorp-cli-c`, `compile-prepared-blorp-cli` and
  `install-prepared-blorp-cli` run the phases separately, as CI does.
- `scripts/blorp-compiler-bootstrap` reads the release identity and per-target
  checksums from `blorp/build/bootstrap.env`, downloads and verifies the release
  into `$HOME/.cache/blorp/compiler-bootstrap` (or
  `BLORP_COMPILER_BOOTSTRAP_CACHE_DIR`). Rotate the tag, version and all target
  checksums together, only after release CI has published the merged revision.
  `--print-id|tag|path|toolchain-dir` print the resolved values.

### Compiler fixpoint

`scripts/compiler-fixpoint` builds stage 2 from stage 1's C and stage 3 from
stage 2's C (via `benchmarks/build_stage2_compiler`) and requires stage 2 and
stage 3 to emit byte-identical C; a difference means the compiler miscompiled
itself, and the first differing line is printed. Run it for every change that
alters emitted C, before a bootstrap rotation picks it up. It needs a `FRESH`
`bin/blorp` and keeps stages under `blorp/build/_build/fixpoint/` (or
`--work-dir`). Exit status is 0 at a fixpoint, 1 when the stages differ, 2 when a
stage could not be built.

## Static and hygiene checks

`make quality` runs `hygiene-check`, `tooling-check`, `artifact-scan` and
`c-static-analysis`; the premerge gate and CI's Quality lane run it.

- `make hygiene-check` is the seconds-long static set: layout, editor drift,
  the C-symbol boundary, manifests and std builtins.
- `make tooling-check` holds the stage-2 self-compile C-symbol leak check and
  the Python and shell suites that test the scripts, build, runtime harnesses
  and parity tooling.
- `make benchmark-tooling-check` holds the suites that test the benchmark runner
  and the self-compile and memory-diagnostics scripts. Only the premerge gate
  runs it, and only when a change touches an input of those suites.
- `make artifact-scan` fails on stray generated files the suites left behind.
- `make c-static-analysis` runs `scripts/c-static-analysis`, which skips the
  clang analysis (about four minutes) when a passing run's stamp exists for the
  same sources, headers, clang version and flags. Stamps live in
  `$BLORP_QUALITY_CACHE_DIR` (default `blorp/build/_build/quality-cache`); a
  failing run writes none.

The individual checks:

- `scripts/check-blorp-layout` validates `blorp/source_ownership.json` against
  `blorp/src` and `blorp/test`: owner roots, permitted cross-owner imports, the
  isolated `compiler_new` test tree, forbidden top-level paths, and that test
  modules mirror the source layout and are named `test_*`.
- `scripts/check-editor-drift` verifies that the shared VSCode and IntelliJ
  TextMate metadata stay byte-identical, parse as JSON, and keep the plugin's
  required registrations.
- `scripts/check-c-symbol-projection-boundary` fails when a `.brp` file other
  than the backend emitter and its renderer test uses the unprojected C
  emission APIs (`*_unprojected_*_for_tests`).
- `scripts/check-c-symbol-projection-self-compile` stage-2 self-compiles
  `blorp/src/main.brp` with `bin/blorp` and fails if the emitted C still
  spells a type by its pre-projection qualified name. It needs a built
  `bin/blorp` and costs a full self-compile.
- `scripts/check-std-builtins` verifies that standalone standard-library
  builtin bodies use explicit identities matching their declaration (for
  example `builtin("list.__unsafe_list_set_index")`), and that every
  non-resource builtin type has exactly one storage classification in the
  language-surface manifest.
- `blorp lint <file.brp|dir>` is the report-only typed analyzer (see
  `docs/LINT.md`).

## Release helpers

- `scripts/target-triple` prints the release target for this machine:
  `x86_64-unknown-linux-gnu`, `aarch64-unknown-linux-gnu`, `aarch64-apple-darwin`
  or `x86_64-apple-darwin`.
- `scripts/package-release dist` copies `bin/blorp` to the target-qualified
  asset `blorp-<target>`. `BLORP_RELEASE_BINARY` selects the binary and
  `BLORP_RELEASE_TARGET` overrides the target in the asset name. That binary can
  later become the bootstrap compiler.
- `scripts/install-dev` downloads, validates and atomically installs the latest
  moving `dev` release as `$HOME/.local/bin/blorp` (the only public command),
  rejecting invalid executables before installation and removing private
  helpers left by older releases. It accepts `--print-url`,
  `--install-dir DIR` and `BLORP_INSTALL_DIR`.

  ```bash
  curl -fsSL https://raw.githubusercontent.com/kablorp/blorp/main/scripts/install-dev | bash
  ```

- `scripts/test-tls-openssl-local` is a manual check of the opt-in OpenSSL TLS
  backend (`BLORP_TLS_BACKEND=openssl`) against a local self-signed endpoint. It
  needs host OpenSSL headers and libraries plus the `openssl` command, so no
  gate runs it.

On main, CI builds the compiler once per platform with its final dev release
metadata, runs the test gates in independent jobs, and the dev release workflow
publishes those exact bytes. Explicit `v*` tags build independently, because the
tagged version embedded in the executable differs. `docs/RELEASES.md` has the
preview and release procedure.
