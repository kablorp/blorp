# Scripts

This directory contains the maintained shell entrypoints for local validation,
Docker validation, and release packaging. Prefer these scripts over calling
lower-level test runners directly.

## Test Gates

`scripts/test` is the main local test entrypoint.

```bash
scripts/test                    # default local gates
scripts/test compiler-unit      # compiler-internal OCaml/Alcotest unit-shaped tests
scripts/test compiler-unit-deep # compiler-internal integration-shaped Alcotest tests
scripts/test compiler           # fast compiler surface fixtures
scripts/test compiler-deep      # generated-C audit, format/purify, compiler/blorp
scripts/test std-check          # broad std/ typecheck sweep
scripts/test runtime            # runtime .brp tests
scripts/test leak               # focused leak-check baselines and leak diagnostics
scripts/test doctest            # std doctests
scripts/test cli                # public CLI, REPL, and LSP smoke tests
scripts/test cli-deep           # full CLI package and formatter integration tests
scripts/test compiler-unit compiler  # multiple selected gates
```

Useful options:

```bash
scripts/test --serial           # run selected gates one at a time
scripts/test --verbose          # stream child-runner output
scripts/test --log-dir logs     # keep complete gate logs
scripts/test --coverage         # compiler-unit coverage
scripts/test --timings          # print unit cases and generated-suite phases
```

`scripts/test` is quiet by default. Successful runs print a gate summary with
per-gate timing, total wall-clock time, and setup timing; failures print focused
excerpts and can save full logs with `--log-dir`.
Use `--timings` with `compiler-unit` or `compiler-unit-deep` when investigating
slow OCaml/Alcotest coverage; it prints the slowest cases and leaves stable
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
std-check
runtime
leak + doctest + cli
cli-deep
```

Waves skip gates you did not select. The policy is intentionally static: the
heavy gates already do their own internal work scheduling, and a shell-level
resource scheduler would be harder to reason about than the tests it runs. Use
`--serial` when you need one gate at a time.

Timeouts:

- `BLORP_TEST_TIMEOUT` sets the default per-test timeout.
- `BLORP_COMPILER_TEST_TIMEOUT` overrides only compiler-test invocations. The
  grouped compiler-owned Blorp suites default to 180 seconds; individual
  compiler fixtures and codegen audits default to 30 seconds.
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
- `scripts/test --serial compiler-unit compiler-unit-deep compiler compiler-deep std-check runtime leak doctest cli-deep`
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
hit. It also enables Dune's shared cache. The cache key includes the concrete
GitHub runner label, architecture, `OCAML_COMPILER`, and
`compiler/blorp.opam.locked`; changing the compiler, OS image, architecture, or
locked dependencies rebuilds the switch once.

## Build Lock

`scripts/with-build-lock` serializes build/test gates per worktree. `scripts/test`
and `scripts/premerge-gate` use it automatically so concurrent local runs do not
race on Dune state, generated runtime caches, or std embedding.

Manual use:

```bash
scripts/with-build-lock make quality
```

## Compiler Bridge Helpers

Backend renderer/Core requests use a compiled
`compiler/blorp/src/stage_12_cli/compiler_bridge_cli.brp` helper. Parser requests use
`compiler/blorp/src/stage_12_cli/compiler_parser_bridge_cli.brp`, and typed-frontend requests
use `compiler/blorp/src/stage_12_cli/compiler_typecheck_bridge_cli.brp`. Parser and typecheck
imports stay separate so the backend helper stays bootstrap-small.

`make install` uses the pinned complete toolchain to build the current public
compiler and installs the pinned renderer, parser, and typecheck helpers beside
`./blorp`. This is a one-generation bootstrap boundary: an ordinary build does
not require the newly built compiler to compile its own backend immediately.
Installation compares every helper byte-for-byte with the verified release
copy, so rerunning `make install` repairs missing or corrupted helpers without
rewriting an unchanged generation.
Compiler-owned Blorp tests still exercise current helper source. Release
qualification must separately prove that the candidate can prepare the next
helper generation before that release becomes the bootstrap.

`scripts/test` selects the installed helper binaries once at startup for gates
that need compiler bridges (`compiler-deep`, `std-check`, `runtime`, `leak`,
`doctest`, `cli`, and `cli-deep`). Pure `compiler-unit`,
`compiler-unit-deep`, and fast `compiler` runs skip this setup. The harness
exports
`BLORP_COMPILER_RENDERER_BRIDGE_BIN`,
`BLORP_COMPILER_PARSER_BRIDGE_BIN`, and
`BLORP_COMPILER_TYPECHECK_BRIDGE_BIN` so every selected gate executes those
helpers directly. Individual tests do not compile helpers on first use; the
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
`BLORP_BOOTSTRAP_LAYOUT=single` remains supported only for historical
manifests; every active pin must use `toolchain` so the cached public command
has all private workers and prepared bridges beside it.

Fallback helper builds for an explicit custom compiler call the normal
`compile` command with
`BLORP_COMPILER_RENDERER_HELPER=1`. Normal compiler source parsing does not read
the old `BLORP_FRONTEND_PARSER` selector. The bootstrap wrapper sets that
retired knob only for pinned external bootstrap binaries that still read it, so
those binaries stay on their built-in parser while compiling bridge helpers.

Tests use the complete installed compiler toolchain: the current public CLI and
the pinned prepared helper generation. Compiler-owned Blorp suites exercise
current bridge source as ordinary test code, while the release qualification
gate is responsible for proving that a candidate can produce the next helper
generation. When `BLORP_COMPILER_BRIDGE_BIN` explicitly selects a custom
compiler without prepared helper overrides, `scripts/test` can instead resolve
or build helpers through the content-addressed bridge cache. Set
`BLORP_COMPILER_BRIDGE_STARTUP_DIR` to keep the prepared helper binaries in a
specific directory for inspection; otherwise the run-local directory is removed
when the test script exits. Renderer, parser, and typecheck helper overrides must
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

`scripts/package-release` packages the public `./blorp` command and its private
OCaml workers and prepared compiler bridges into a release archive plus a
`.sha256` file:

```bash
scripts/package-release dist
```

When prepared bridge paths are not supplied, the helper asks `./blorp` to
prepare them before creating the archive.

Useful environment variables:

- `BLORP_RELEASE_BINARY` selects the binary to package.
- `BLORP_RELEASE_OCAML_HOST` selects the private OCaml host to package.
- `BLORP_RELEASE_OCAML_MIDDLE` selects the private semantic worker to package.
- `BLORP_RELEASE_RENDERER_BRIDGE` selects the prepared renderer bridge.
- `BLORP_RELEASE_PARSER_BRIDGE` selects the prepared parser bridge.
- `BLORP_RELEASE_TYPECHECK_BRIDGE` selects the prepared typecheck bridge.
- `BLORP_RELEASE_VERSION` overrides the version in the asset name.
- `BLORP_RELEASE_TARGET` overrides the target triple in the asset name.

The three prepared bridge overrides must be supplied together so one archive
cannot mix helpers from different compiler generations.

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
  "$HOME/.local/bin/blorp-ocaml-middle" \
  "$HOME/.local/bin/blorp-compiler-renderer" \
  "$HOME/.local/bin/blorp-compiler-parser" \
  "$HOME/.local/bin/blorp-compiler-typecheck"
```
