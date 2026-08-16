# Scripts

This directory contains the maintained shell entrypoints for local validation,
Docker validation, and release packaging. Prefer these scripts over calling
lower-level test runners directly.

## Test Gates

`scripts/test` is the main local test entrypoint.

For the shortest manifest-owned compiler feedback loop, use
`scripts/compiler-check`:

```bash
scripts/compiler-check compiler/blorp/tests/test_compiler_type_header_graph.brp
scripts/compiler-check --stage typecheck
scripts/compiler-check --changed
scripts/compiler-check --changed --base origin/main
```

An exact suite path runs only that registered suite. Stage and changed-source
selection come from
`compiler/blorp/tests/compiler_test_ownership.json`; the command does not infer
owners from names, imports, timings, or previous failures. `--changed` includes
staged, unstaged, and untracked production compiler sources, while `--base`
also includes committed changes from the merge base with the named ref.

The command prints the selected sources, suites, and special checks before it
prepares the compiler once. Suites then use `./blorp test`, and registered gate
checks use `scripts/test --no-build --log-dir`. Passing runs remove their
temporary logs. Failing runs retain complete output and an exact rerun under
the ignored `logs/compiler-check-*` tree. `scripts/compiler-check` is focused
feedback only; run the relevant broad `scripts/test` integration gates before
merging.

```bash
scripts/test                    # Blorp compiler, runtime, leak, doctest, CLI
scripts/test compiler-blorp     # Blorp TestSuites + marked production check fixtures
scripts/test compiler-tools     # formatter, purify, and lint public CLI fixtures
scripts/test std-check          # broad std/ typecheck sweep
scripts/test runtime            # runtime .brp tests
scripts/test leak               # ownership suites, leak baselines, and diagnostics
scripts/test doctest            # std doctests
scripts/test cli                # public CLI and LSP smoke tests
scripts/test cli-deep           # full CLI package and formatter integration tests
scripts/test lsp                # public LSP protocol fixtures
scripts/test package            # focused public package lifecycle integration
scripts/test compiler-blorp runtime  # multiple selected gates
```

Useful options:

```bash
scripts/test --serial           # run selected gates one at a time
scripts/test --verbose          # stream child-runner output
scripts/test --log-dir logs     # keep complete gate logs
scripts/test --no-build         # test the existing installed toolchain
scripts/test --timings          # print generated TestSuite phase timings
```

`scripts/test` is quiet by default. Successful runs print a gate summary with
per-gate timing, total wall-clock time, and setup timing; failures print focused
excerpts and can save full logs with `--log-dir`.
The default gate exercises the production-owned compiler implementation through
`compiler-blorp`. The retired OCaml test routes are no longer accepted by
`scripts/test`; their source archive is not compiled or executed.
The `compiler-blorp` gate also runs the 19 fixtures explicitly marked
`RUN-BLORP-CHECK` through a small Blorp-only runner; under CI sharding, shard 1
owns that fixture set so it executes exactly once.
Runtime sources owned by the leak gate are excluded from normal runtime groups.
The remaining roots run in bounded 64-root invocations whose structured results
are validated and aggregated into one runtime gate result.
`--no-build` is for controlled CI or local workflows that have already run the
required build and need to preserve that exact toolchain through validation.
Without it, `scripts/test` installs the current compiler before running gates.

The supported report-only typed analyzer is `blorp lint <file.brp|dir> [...]`.
Use `--format json` for the versioned machine-readable envelope and
`--fail-on-findings` when findings should fail CI. See
[`docs/LINT.md`](../docs/LINT.md) for rule IDs, confidence, and failure behavior.

Required CI partitions the compiler-owned source inventory across independent
`compiler-blorp` lanes by setting both `BLORP_COMPILER_TEST_SHARD_INDEX` and
`BLORP_COMPILER_TEST_SHARD_COUNT`. Shard indexes are 1-based; each shard owns a
contiguous slice of the sorted `.brp` inventory, balanced by root source bytes.
Contiguous slices preserve compiler graph locality. Ordinary uniquely named
sources in each shard compile into one generated program and execute serially
inside that program because this gate explicitly passes `--maximal-artifacts`.
Other `blorp test` callers retain bounded artifacts by default, and sanitizer
runs always retain the measured memory bound.
The sharded inventory is deliberately flat so explicit file selection has the
same source boundary as the normal directory route; nested sources fail the
sharded gate until their discovery semantics are handled explicitly. CI also
sets `BLORP_COMPILER_TEST_PROGRESS=1` to stream artifact start, source, result,
and elapsed-time records while preserving the compact final gate output.
Omitting both variables keeps the normal local full-corpus run, while
incomplete, out-of-range, or empty shard selections fail before invoking the
compiler.

Reproduce either required Ubuntu compiler shard against an already-built
toolchain with:

```bash
BLORP_COMPILER_TEST_SHARD_INDEX=1 \
BLORP_COMPILER_TEST_SHARD_COUNT=2 \
BLORP_COMPILER_TEST_PROGRESS=1 \
scripts/test --no-build --serial compiler-blorp
```

Use `--timings` with `compiler-blorp` or `compiler-blorp-sanitize` to record
generated TestSuite frontend, typecheck, Core, host-C, and execution phases and
print their totals.
After setup, multiple selected gates run in fixed waves by default:

```text
compiler-blorp
compiler-tools
compiler-core-sanitize
compiler-blorp-sanitize
std-check
runtime
leak + doctest + cli + lsp
package
cli-deep
```

Waves skip gates you did not select. The policy is intentionally static: the
heavy gates already do their own internal work scheduling, and a shell-level
resource scheduler would be harder to reason about than the tests it runs. Use
`--serial` when you need one gate at a time.

CI builds one compiler candidate per platform and restores those exact bytes in
independent test jobs. Ubuntu separates quality, Blorp-owned compiler, and
product/runtime coverage; platform jobs retain the smaller runtime
compatibility set. Each platform build gates only that platform's test lanes, so
a failed or slow platform does not suppress unrelated feedback. Packaging waits
for the matching platform lanes, then archives the shared candidate rather than
rebuilding it; the release workflow still publishes only from a wholly
successful CI run. The candidate carries generated CLI outputs and both embedded
standard-library sources so fresh test checkouts use the build job's exact
generated inputs.

Timeouts:

- `BLORP_TEST_TIMEOUT` sets the default per-source test budget. Compatible
  sources running in one generated artifact pool those budgets, capped at 600
  seconds per combined artifact so one batch cannot outlive its CI lane.
- `BLORP_COMPILER_TEST_TIMEOUT` overrides only compiler-test invocations. The
  grouped compiler-owned Blorp suites default to 180 seconds; individual
  compiler fixtures and codegen audits default to 30 seconds.
- Compiler-owned TestSuite artifacts contain at most eight source roots and
  512 KiB of raw root source. A source larger than that byte budget runs as a
  singleton artifact so an oversized compiler suite cannot make an otherwise
  ordinary batch exceed a CI lane's compile budget.
- `BLORP_COMPILER_SANITIZE_TEST_TIMEOUT` sets the compiler sanitizer-gate
  timeout (default 180 seconds, reflecting measured ASan overhead).
- In multi-gate wave runs, the leak-check gate scales the built-in default
  timeout by the selected gate count to avoid false timeouts under local CPU
  contention. Set `BLORP_TEST_TIMEOUT` to use an exact timeout instead.

## Premerge Gate

`scripts/premerge-gate` is the broader local validation gate before merging or
cutting preview builds. It composes:

- clean build
- `make quality`
- `scripts/test --serial compiler-blorp compiler-tools std-check runtime leak doctest cli-deep lsp`
- the direct generated-C audit in `tests/test_compiler/codegen_audit/`
- preview CLI/runtime smoke
- example checks and selected example runs
- sanitizer tests
- Docker validation when Docker is available
- lightweight secret-pattern scan
- drift and hygiene checks, including editor TextMate metadata sync

Common forms:

```bash
scripts/premerge-gate
scripts/premerge-gate --quick
scripts/premerge-gate --no-docker --no-sanitize
scripts/premerge-gate --require-docker
scripts/premerge-gate --dry-run
```

Use `--quick` for fast local confidence. Use the full default gate before
claiming a preview/release-sensitive change is ready.

The preview smoke step is guarded as non-mutating: it snapshots Git status plus
tracked and staged diffs before and after the step, and fails if validation
rewrites the working tree.

## Docker Gate

`scripts/docker-gate` runs validation inside an Ubuntu 24.04 container.

```bash
scripts/docker-gate
scripts/docker-gate --premerge-gate
scripts/docker-gate --premerge-gate --all-platforms
scripts/docker-gate --platform linux/arm64 -- tests/test_blorp/numeric/test_float16_vector.brp
scripts/docker-gate --shell
```

Modes:

- Default volume mode mounts the working tree into the container.
- `--clean` copies source into the image for a more CI-like run.
- `--premerge-gate` runs `scripts/premerge-gate --no-docker` inside Docker.

## CI OCaml Cache

GitHub workflows use `.github/actions/setup-cached-ocaml` instead of
`ocaml/setup-ocaml`. The action restores `~/.opam` before doing setup work,
installs the fixed opam binary, and creates only the OCaml switch needed by the
small source generators in `compiler/tools/`. The compiler has no Dune or opam
dependency graph. The cache key includes the concrete runner label,
architecture, and `OCAML_COMPILER`.

## Build Lock

`scripts/with-build-lock` serializes build/test gates per worktree. `scripts/test`
and `scripts/premerge-gate` use it automatically so concurrent local runs do not
race on Dune state, generated runtime caches, or std embedding. The wrapper also
holds the shared canonical per-user host compiler contention lease. Registered
`scripts/bench-blorp-test-session` evidence takes the exclusive side and rejects
a run while any participating build/test gate for that user is active. The
owner-only lease namespace rejects symlinks and foreign ownership before a gate
or benchmark starts.
Named runs selected with `--workload` use the same exclusive lease. The
registered workload kind requires a candidate for comparisons and forbids one
for characterizations; both validate their command and cache policy, while
characterizations also validate sample count, timeout, and fingerprint inputs.

Manual use:

```bash
scripts/with-build-lock make quality
```

## Blorp Test Session Feedback

Use the direct command for the boundary being changed. Planner TestSuites cover
path discovery, frontend partitions, and generated aggregate harnesses. A
typecheck covers the shared execution boundary, and the stage-two test exercises
the production CLI route:

```bash
./blorp test --timeout 30 \
  compiler/blorp/tests/test_compiler_cli_test_discovery.brp \
  compiler/blorp/tests/test_compiler_cli_test_batch.brp \
  compiler/blorp/tests/test_compiler_cli_generated_test_harness.brp \
  compiler/blorp/tests/test_compiler_cli_source_graph_context.brp \
  compiler/blorp/tests/test_compiler_cli_test_plan.brp
./blorp check --no-format \
  compiler/blorp/src/stage_12_cli/cli_test_effect.brp
tests/test_cli_stage_two.sh --timeout 90
```

Run `./blorp test --timeout 30 tests/test_blorp/sys/test_process_session.brp`
for the session API; CLI smoke separately covers inherited stdin, stdout, and
stderr for blocking commands. Use `scripts/bench-blorp-test-session` for
repeatable timing or RSS evidence; its process supervisor and registered
workloads are the single benchmark path.

## Compiler Bootstrap

`make install` invokes the pinned release's public `blorp compile` command to
build the current compiler. The compiler is a single executable; tests,
packages, the LSP, and release archives do not prepare or install private
workers.

Local compiler builds use `-O0` by default for the shortest edit/build cycle.
Set `BLORP_CLI_C_OPTIMIZATION` to select a different single C optimization
level. Main CI and tagged release builds use `-Og`, and the selected level is
part of the generated CLI cache identity.

Normal builds use `scripts/blorp-compiler-bootstrap`, which reads the immutable
release identity and per-target checksums from
`compiler/bootstrap.env`, then downloads and verifies the release into
`$HOME/.cache/blorp/compiler-bootstrap`, or `BLORP_COMPILER_BOOTSTRAP_CACHE_DIR`
when set. Rotate the tag, version, and all target checksums together in that
single manifest only after release CI has published the merged revision.
The `single` layout identity ensures caches produced by the retired
multi-executable compiler distribution cannot be reused accidentally. Only the
`blorp` executable is required or cached.

Useful compiler bootstrap commands:

```bash
scripts/blorp-compiler-bootstrap --print-id
scripts/blorp-compiler-bootstrap --print-tag
scripts/blorp-compiler-bootstrap --print-path
scripts/blorp-compiler-bootstrap --print-toolchain-dir
```

## Compiler Source Cleanup Audit

`scripts/audit-compiler-blorp-dead-code` builds a conservative whole-compiler
module and declaration reachability inventory. It also reports whole unused
import entries, globally unread field names, unused variants, and Blorp
environment controls with no tracked reference outside compiler source.

```bash
scripts/audit-compiler-blorp-dead-code
scripts/audit-compiler-blorp-dead-code --json
```

Findings require owner review before deletion; the script intentionally does
not fail the quality gate while reviewed cleanup remains queued. The current
classification and removal order live in
`docs/BLORP_COMPILER_CLEANUP_AUDIT.md`.

## Drift Checks

`scripts/check-editor-drift` verifies that shared VSCode and IntelliJ TextMate
metadata stay byte-for-byte synchronized, parse as JSON, and keep the IntelliJ
plugin's required editor integration registrations in place. `make
hygiene-check` runs it automatically.

`scripts/check-intellij-plugin` verifies the built IntelliJ plugin zip contains
the native Blorp file type, token lexer/parser, TextMate highlighter bridge, LSP
provider, goto handler, and bundled TextMate grammar. It builds the default
plugin zip before checking; pass a zip path to inspect an existing package.

`scripts/check-std-builtins` verifies that standalone `std/` function builtin
bodies use explicit identities matching their source declaration, for example
`builtin("std/list.__unsafe_list_set_index")`. Bare `builtin` function bodies are not
allowed in `std/`. It also requires every non-resource builtin type declaration
to have exactly one scalar, managed-reference, or no-value storage
classification in the compiler language-surface manifest.

## Optional Native TLS Check

`scripts/test-tls-openssl-local` is a manual integration check for the opt-in
OpenSSL TLS runtime backend. It creates a local self-signed TLS endpoint and
runs a Blorp TLS client against it with `BLORP_TLS_BACKEND=openssl`. It is not
part of the default gate because it requires host OpenSSL headers/libraries and
the `openssl` command-line tool.


## Release Helpers

`scripts/target-triple` prints the release target for the current machine:

```bash
scripts/target-triple
```

Supported targets:

- `x86_64-unknown-linux-gnu`
- `aarch64-unknown-linux-gnu`
- `aarch64-apple-darwin`
- `x86_64-apple-darwin`

`scripts/package-release` packages the public `./blorp` command into a release
archive plus a `.sha256` file. That binary is also the immutable
compiler used when that release is later pinned as the bootstrap:

```bash
scripts/package-release dist
```

Useful environment variables:

- `BLORP_RELEASE_BINARY` selects the binary to package.
- `BLORP_RELEASE_VERSION` overrides the version in the asset name.
- `BLORP_RELEASE_TARGET` overrides the target triple in the asset name.

`scripts/install-dev` verifies, stages, and atomically installs that executable.
It removes private compiler helpers left by older releases.

On main, CI builds the compiler once with its final dev release metadata,
checks the self-hosted source graph, runs the normal test gates, smokes the
single-binary archive, and uploads it as a workflow artifact. The dev release
workflow downloads and publishes those exact bytes
instead of compiling the compiler again. Explicit `v*` tags still build
independently because the tagged version embedded in the executable differs from
the dev version tested on main.

`scripts/install-dev` installs the latest moving `dev` release:

```bash
curl -fsSL https://raw.githubusercontent.com/kablorp/blorp/main/scripts/install-dev | bash
```

It downloads the matching `blorp-dev-<target>.tar.gz`, verifies the `.sha256`,
and installs the public command plus its private workers and bridges in
`$HOME/.local/bin` by default. `blorp` remains the only public command.
Incomplete archives are rejected before installation.

Useful options/environment:

```bash
scripts/install-dev --print-url
scripts/install-dev --install-dir "$HOME/bin"
BLORP_INSTALL_DIR="$HOME/bin" scripts/install-dev
```

Remove the dev binary with:

```bash
rm -f "$HOME/.local/bin/blorp"
```
