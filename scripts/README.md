# Scripts

This directory contains the maintained shell entrypoints for local validation,
Docker validation, and release packaging. Prefer these scripts over calling
lower-level test runners directly.

## Test Gates

`scripts/test` is the main local test entrypoint.

```bash
scripts/test                    # all gates
scripts/test unit               # OCaml unit tests
scripts/test compiler           # compiler fixtures and codegen audit
scripts/test runtime            # runtime .brp tests
scripts/test leak               # focused leak-check baselines
scripts/test doctest            # std doctests
scripts/test cli                # public CLI, REPL, and LSP smoke tests
scripts/test unit compiler      # multiple selected gates
```

Useful options:

```bash
scripts/test --serial           # run selected gates one at a time
scripts/test --verbose          # stream child-runner output
scripts/test --log-dir logs     # keep complete gate logs
scripts/test --coverage         # OCaml unit coverage
```

`scripts/test` is quiet by default. Successful runs print a gate summary;
failures print focused excerpts and can save full logs with `--log-dir`.

Timeouts:

- `BLORP_TEST_TIMEOUT` sets the default per-test timeout.
- `BLORP_COMPILER_TEST_TIMEOUT` overrides only compiler-test invocations.

## Premerge Gate

`scripts/premerge-gate` is the broader local validation gate before merging or
cutting preview builds. It composes:

- clean build
- `make quality-full`
- `scripts/test --serial`
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

## Build Lock

`scripts/with-build-lock` serializes build/test gates per worktree. `scripts/test`
and `scripts/premerge-gate` use it automatically so concurrent local runs do not
race on Dune state, generated runtime caches, or formatter/std embedding.

Manual use:

```bash
scripts/with-build-lock make quality-full
```

## Drift Checks

`scripts/check-editor-drift` verifies that shared VSCode and IntelliJ TextMate
metadata stay byte-for-byte synchronized and parse as JSON. `make hygiene-check`
runs it automatically.

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

`scripts/package-release` packages `./blorp` into a release archive plus
`.sha256` file:

```bash
scripts/package-release dist
```

Useful environment variables:

- `BLORP_RELEASE_BINARY` selects the binary to package.
- `BLORP_RELEASE_VERSION` overrides the version in the asset name.
- `BLORP_RELEASE_TARGET` overrides the target triple in the asset name.

`scripts/install-dev` installs the latest moving `dev` release:

```bash
curl -fsSL https://raw.githubusercontent.com/kablorp/blorp/main/scripts/install-dev | bash
```

It downloads the matching `blorp-dev-<target>.tar.gz`, verifies the `.sha256`,
and installs one binary to `$HOME/.local/bin/blorp` by default.

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
