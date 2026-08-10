# Scripts

This directory contains the maintained shell entrypoints for local validation,
Docker validation, and release packaging. Prefer these scripts over calling
lower-level test runners directly.

## Test Gates

`scripts/test` is the main local test entrypoint.

```bash
scripts/test                    # compiler surface/internal, runtime, leak, doctest, CLI
scripts/test compiler-unit      # compiler-internal OCaml/Alcotest unit-shaped tests
scripts/test compiler-unit-deep # compiler-internal integration-shaped Alcotest tests
scripts/test compiler           # fast compiler surface fixtures
scripts/test compiler-deep      # generated-C audit, format/purify, compiler/blorp
scripts/test compiler-blorp     # compiler-owned Blorp TestSuites
scripts/test std-check          # broad std/ typecheck sweep
scripts/test runtime            # runtime .brp tests
scripts/test leak               # ownership suites, leak baselines, and diagnostics
scripts/test doctest            # std doctests
scripts/test cli                # public CLI and LSP smoke tests
scripts/test cli-deep           # full CLI package and formatter integration tests
scripts/test lsp                # public LSP protocol fixtures
scripts/test package            # focused public package lifecycle integration
scripts/test compiler-unit compiler  # multiple selected gates
```

Useful options:

```bash
scripts/test --serial           # run selected gates one at a time
scripts/test --verbose          # stream child-runner output
scripts/test --log-dir logs     # keep complete gate logs
scripts/test --no-build         # test the existing installed toolchain
scripts/test --timings          # print compiler-unit case timings
```

`scripts/test` is quiet by default. Successful runs print a gate summary with
per-gate timing, total wall-clock time, and setup timing; failures print focused
excerpts and can save full logs with `--log-dir`.
The default gate exercises public compiler fixtures through `compiler` and the
production-owned compiler implementation through `compiler-blorp`. Retained
OCaml migration suites remain explicitly selectable with `compiler-unit` and
`compiler-unit-deep` and run in required CI.
Runtime sources owned by the leak gate are excluded from normal runtime groups.
The remaining roots run in bounded 64-root invocations whose structured results
are validated and aggregated into one runtime gate result.
`--no-build` is for controlled CI or local workflows that have already run the
required build and need to preserve that exact toolchain through validation.
Without it, `scripts/test` continues to build or install its selected compiler
before running gates.

Required CI partitions the compiler-owned source inventory across independent
`compiler-blorp` lanes by setting both `BLORP_COMPILER_TEST_SHARD_INDEX` and
`BLORP_COMPILER_TEST_SHARD_COUNT`. Shard indexes are 1-based; each shard owns a
near-equal contiguous slice of the sorted `.brp` inventory. Contiguous slices
preserve compiler graph locality and keep aggregate dependency unions bounded.
The sharded inventory is deliberately flat so explicit file selection has the
same source boundary as the normal directory route; nested sources fail the
sharded gate until their discovery semantics are handled explicitly. CI also
sets `BLORP_COMPILER_TEST_PROGRESS=1` to stream one machine-readable result per
completed artifact while preserving the compact final gate output.
Omitting both variables keeps the normal local full-corpus run, while
incomplete, out-of-range, or empty shard selections fail before invoking the
compiler.

Use `--timings` with `compiler-unit` or `compiler-unit-deep` when investigating
slow OCaml/Alcotest cases; it prints the slowest cases and leaves stable
`BLORP_COMPILER_UNIT_TIMING` records in saved logs.
With `compiler-deep` and `compiler-blorp-sanitize`, it also records generated
TestSuite frontend, typecheck, Core, host-C, and execution phases and prints
their totals.
After setup, multiple selected gates run in fixed waves by default:

```text
compiler-unit
compiler-unit-deep
compiler
compiler-deep
compiler-blorp
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
independent test jobs. Ubuntu separates compiler migration, Blorp-owned compiler,
and product/runtime coverage; platform jobs retain the smaller runtime
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
- `scripts/test --serial compiler-unit compiler-unit-deep compiler compiler-deep std-check runtime leak doctest cli-deep lsp`
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
installs only the fixed opam binary, and skips `opam install` on an exact cache
hit. It also owns and enables Dune's shared build-artifact cache, so workflows
do not repeat that setup. The opam cache key includes the concrete GitHub runner
label, architecture, `OCAML_COMPILER`, and `compiler/blorp.opam.locked`;
changing the compiler, OS image, architecture, or locked dependencies rebuilds
the switch once.

## Build Lock

`scripts/with-build-lock` serializes build/test gates per worktree. `scripts/test`
and `scripts/premerge-gate` use it automatically so concurrent local runs do not
race on Dune state, generated runtime caches, or std embedding. The wrapper also
holds the shared canonical per-user host compiler contention lease. Registered
`scripts/bench-blorp-test-session` evidence takes the exclusive side and rejects
a run while any participating build/test gate for that user is active. The
owner-only lease namespace rejects symlinks and foreign ownership before a gate
or benchmark starts.
Named baseline runs selected with `--characterization-workload` use the same
exclusive lease and validate their command, cache, sample count, timeout, and
fingerprint inputs against `benchmarks/blorp_test_session_policy.json`.

Manual use:

```bash
scripts/with-build-lock make quality
```

## Blorp Test Session Fast Loop

`scripts/test-blorp-test-session-fast` runs bounded phase-local cases under the
normal build lock and reports measured samples plus their median reference
budget. Budgets are diagnostic rather than noisy CI thresholds; behavioral
failures and supervisor timeouts fail the command.

The planning case covers compact path discovery, bounded frontend-batch
construction, and direct aggregate harness generation. The execution case quickly
typechecks the shared runtime-input boundary; the full effect TestSuite remains
a deeper behavioral check. The route case builds the stage-two compiler and
runs the production CLI path:

```bash
scripts/test-blorp-test-session-fast --case planning
scripts/test-blorp-test-session-fast --case execution --samples 1
scripts/test-blorp-test-session-fast --case route --samples 1
scripts/test-blorp-test-session-fast --list
```

The `process` and `process-session` cases remain focused checks for the native
subprocess boundary used to execute compiled tests. Median budgets are
diagnostic references, not pass/fail performance thresholds.

Each case runs with inherited `BLORP_*` mode overrides removed. Nonblocking pipe
readers retain only the final 64 KiB from each output stream and print those
tails on failure. The supervisor polls the process tree, terminates tracked
descendants across process-session boundaries, and escalates from TERM to KILL
within a fixed grace period. Tracking validates PID plus process birth time
before signaling, bounds output drained per supervisor turn, and fails the case
if process sampling remains unavailable after bounded retries. Final output
draining also has a fixed work bound. A descendant that detaches and outlives
its parent before the first process snapshot is outside this portable fast-loop
guarantee; production session work must retain the stricter process contract in
the roadmap.

## Compiler Bridge Helpers

OCaml-hosted commands send parser and CLI-planning requests to the compiled
`compiler/blorp/src/stage_12_cli/parser_bridge_cli.brp` worker.
Production typechecking and backend emission run in the public Blorp compiler.
`blorp test` is fully Blorp-owned and does not delegate to the OCaml host;
remaining host packaging is for commands such as package management and LSP.
Standalone typecheck and backend entrypoints live under
`compiler/blorp/benchmarks/` and are built only by diagnostic benchmarks.

`make install` invokes the pinned release's public `blorp compile` command to
build the current public compiler. It also installs the pinned parser worker
beside `./blorp` for commands that still delegate to the OCaml host. That worker
is not part of ordinary compilation itself.
Local compiler builds use `-O0` by default for the shortest edit/build cycle.
Set `BLORP_CLI_C_OPTIMIZATION` to select a different single C optimization
level. Main CI and tagged release builds use `-Og`, and the selected level is
part of the generated CLI cache identity.
Installation compares every helper byte-for-byte with the verified release
copy, so rerunning `make install` repairs missing or corrupted helpers without
rewriting an unchanged generation. Upgrading removes the retired
`blorp-compiler-typecheck` and `blorp-compiler-renderer` executables from the
install directory.
Compiler-owned Blorp tests still exercise current helper source. Release
qualification must separately prove that the candidate can prepare the next
helper generation before that release becomes the bootstrap.

`scripts/test` selects the installed helper binaries once at startup for gates
that need compiler bridges (`compiler-deep`, `compiler-blorp`, `std-check`,
`runtime`, `leak`, `doctest`, `cli`, `cli-deep`, `lsp`, and `package`). Pure `compiler-unit`,
`compiler-unit-deep`, and fast `compiler` runs skip this setup. The harness
exports `BLORP_COMPILER_PARSER_BRIDGE_BIN` so every selected gate executes that
worker directly. Individual tests do not compile workers on first use; the
harness also sets
`BLORP_COMPILER_REQUIRE_PREPARED_BRIDGE=1` so a lost helper path fails loudly
instead of falling back to lazy helper compilation.

Ad-hoc compiler invocations still have a fallback helper cache under
`$HOME/.cache/blorp/compiler-bridge`, or `BLORP_COMPILER_BRIDGE_CACHE_DIR` when
set. The cache key is derived from the production `compiler/blorp` source tree,
the shipped `std/` sources, formatter sources imported by compiler-owned Blorp
code, the helper entrypoint, the Blorp executable used to compile the helper,
the C compiler identity, link flags, and the OS. Cold cache construction is
protected by a per-key file lock, so parallel compiler processes do not compile
the same helper more than once.

Normal builds use `scripts/blorp-compiler-bootstrap`, which reads the immutable
release identity and per-target checksums from
`compiler/bootstrap.env`, then downloads and verifies the complete release into
`$HOME/.cache/blorp/compiler-bootstrap`, or `BLORP_COMPILER_BOOTSTRAP_CACHE_DIR`
when set. Rotate the tag, version, and all target checksums together in that
single manifest only after release CI has published the merged revision.
Every active pin uses the `toolchain` layout so the cached public command has
the private OCaml host workers beside it for delegated commands.

Fallback worker builds for an explicit custom compiler call its normal
`compile` command. Normal compiler source parsing does not read the retired
`BLORP_FRONTEND_PARSER` selector.

Tests use the complete installed compiler toolchain: the current public CLI and
the pinned prepared helper generation. Compiler-owned Blorp suites exercise
current bridge source as ordinary test code, while the release qualification
gate is responsible for proving that a candidate can produce the next helper
generation. When `BLORP_COMPILER_BRIDGE_BIN` explicitly selects a custom
compiler without prepared helper overrides, `scripts/test` can instead resolve
or build helpers through the content-addressed bridge cache. Set
`BLORP_COMPILER_BRIDGE_STARTUP_DIR` to keep the prepared helper binaries in a
specific directory for inspection; otherwise the run-local directory is removed
when the test script exits. Renderer and parser helper overrides must
always be provided together so one compiler session cannot mix generations.

Useful compiler bootstrap commands:

```bash
scripts/blorp-compiler-bootstrap --print-id
scripts/blorp-compiler-bootstrap --print-tag
scripts/blorp-compiler-bootstrap --print-path
scripts/blorp-compiler-bootstrap --print-toolchain-dir
```

`BLORP_COMPILER_BRIDGE_BIN` remains the explicit escape hatch for testing or
bisecting with another Blorp executable. Backend helper builds clear that
override for nested bridge requests so an override cannot recursively select
itself.

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
allowed in `std/`.

`scripts/check-compiler-port-inventory` verifies the OCaml-to-Blorp compiler
port inventory, the single hidden bridge command boundary, and the current
direct-template access allowlist. `make hygiene-check` runs it automatically.

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

`scripts/package-release` packages the public `./blorp` command, the private
OCaml host, and the current parser worker into a
release archive plus a `.sha256` file. The public binary is also the immutable
compiler used when that release is later pinned as the bootstrap:

```bash
scripts/package-release dist
```

When prepared bridge paths are not supplied, the helper asks `./blorp` to
prepare them before creating the archive.

Useful environment variables:

- `BLORP_RELEASE_BINARY` selects the binary to package.
- `BLORP_RELEASE_OCAML_HOST` selects the private OCaml host to package.
- `BLORP_RELEASE_PARSER_BRIDGE` selects the prepared parser bridge.
- `BLORP_RELEASE_VERSION` overrides the version in the asset name.
- `BLORP_RELEASE_TARGET` overrides the target triple in the asset name.

`scripts/install-dev` verifies the complete three-executable toolchain before
staging and installing it. Private workers are installed before the public
binary so a completed installation always exposes one release generation.

On main, CI builds the compiler once with its final dev release metadata,
prepares the next compiler bridge generation, runs the normal test gates against
that complete toolchain, smokes the archive, and uploads it as a workflow
artifact. The dev release workflow downloads and publishes those exact bytes
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
rm -f \
  "$HOME/.local/bin/blorp" \
  "$HOME/.local/bin/blorp-ocaml-host" \
  "$HOME/.local/bin/blorp-compiler-parser"
```
