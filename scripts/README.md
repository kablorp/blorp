# Scripts

This directory contains the maintained shell entrypoints for local validation,
Docker validation, and release packaging. Prefer these scripts over calling
lower-level test runners directly.

## Repository Renames

`scripts/rename-identifiers` discovers identifiers with selected prefixes in a
source subtree, replaces complete tokens across tracked text files, and can
rename files with the same prefix. It updates comments and strings deliberately
so diagnostics, fixtures, and documentation move with internal API names.

Always inspect a dry run before applying a rename:

```bash
scripts/rename-identifiers blorp/src/lsp \
  --strip-prefix lsp_ --strip-prefix Lsp --strip-prefix LSP_ \
  --rename-file-prefix lsp_ --exclude lsp_stdio_transport --dry-run
scripts/rename-identifiers blorp/src/lsp \
  --strip-prefix lsp_ --strip-prefix Lsp --strip-prefix LSP_ \
  --rename-file-prefix lsp_ --exclude lsp_stdio_transport
python3 blorp/test/tool/test_rename_identifiers.py
```

Use `--rename OLD=NEW` to resolve a known destination collision and `--exclude`
for a staged bootstrap exception. The command rejects duplicate or ambiguous
overrides, missing source paths, and existing path targets. Identical identifiers
can be valid in separate scopes, so compilation remains the authority for
semantic collisions exposed by removing a namespace prefix.

To rename module files and their import references without changing similarly
prefixed functions or datatypes, provide only `--rename-file-prefix`:

```bash
scripts/rename-identifiers blorp/src/lsp/protocol \
  --rename-file-prefix lsp_ --dry-run
```

## Test Gates

`scripts/test` is the main local test entrypoint.

For the shortest manifest-owned compiler feedback loop, use
`scripts/compiler-check`:

```bash
scripts/compiler-check blorp/test/compiler/pipeline/test_type_header_graph.brp
scripts/compiler-check --stage typecheck
scripts/compiler-check --changed
scripts/compiler-check --changed --base origin/main
```

An exact suite path runs only that registered suite. Stage and changed-source
selection come from
`blorp/test/compiler/compiler_test_ownership.json`; the command does not infer
owners from names, imports, timings, or previous failures. `--changed` includes
staged, unstaged, and untracked production compiler sources, while `--base`
also includes committed changes from the merge base with the named ref.

The command prints the selected sources, suites, and special checks before it
prepares the compiler once. Suites then use `bin/blorp test`, and registered gate
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
`compiler-blorp`.
The `compiler-blorp` gate also runs the 54 fixtures explicitly marked
`RUN-BLORP-CHECK` through a small Blorp-only runner after the generated suite.
Runtime sources owned by the leak gate are excluded from the normal runtime corpus.
The remaining roots compile and run together in one runtime test invocation.
`--no-build` is for controlled CI or local workflows that have already run the
required build and need to preserve that exact toolchain through validation.
Without it, `scripts/test` installs the current compiler before running gates.

The supported report-only typed analyzer is `blorp lint <file.brp|dir> [...]`.
Use `--format json` for the versioned machine-readable envelope and
`--fail-on-findings` when findings should fail CI. See
[`docs/LINT.md`](../docs/LINT.md) for rule IDs, confidence, and failure behavior.

The compiler-owned suites compile and run as one generated program. CI sets
`BLORP_COMPILER_TEST_PROGRESS=1` to stream artifact start, source, result, and
elapsed-time records while preserving the compact final gate output. Reproduce
the CI compiler gate against an already-built toolchain with:

```bash
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

- `BLORP_TEST_TIMEOUT` overrides generated test artifact timeouts.
- `BLORP_RUNTIME_TEST_TIMEOUT` overrides only the single runtime corpus
  artifact, which defaults to 60 seconds. Ordinary artifacts default to 30
  seconds.
- `BLORP_LEAK_TEST_TIMEOUT` overrides only the consolidated leak-check corpus,
  which also defaults to 60 seconds.
- `BLORP_COMPILER_TEST_TIMEOUT` overrides only compiler-test invocations. The
  grouped compiler-owned Blorp suites default to 360 seconds; individual
  compiler fixtures and codegen audits default to 30 seconds.
- `BLORP_COMPILER_SANITIZE_TEST_TIMEOUT` sets the compiler sanitizer-gate
  timeout (default 180 seconds, reflecting measured ASan overhead).
## Premerge Gate

`scripts/premerge-gate` is the broader local validation gate before merging or
cutting preview builds. It composes:

- clean build
- `make quality`
- `scripts/test --serial compiler-blorp compiler-tools std-check runtime leak doctest cli-deep lsp`
- the direct generated-C audit in `blorp/test/compiler/pipeline/codegen_audit/`
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
scripts/docker-gate --platform linux/arm64 -- blorp/test/runtime/numeric/test_float16_vector.brp
scripts/docker-gate --shell
```

Modes:

- Default volume mode mounts the working tree into the container.
- `--clean` copies source into the image for a more CI-like run.
- `--premerge-gate` runs `scripts/premerge-gate --no-docker` inside Docker.

## Build Source Generation

`make compiler-build-source-generator` compiles
`blorp/tool/generate_build_sources.brp` with the pinned bootstrap compiler.
The resulting native tool generates build metadata, embedded runtime C, and the
embedded standard library. Production build and CI routes use this tool directly.

## Build Lock

`scripts/with-build-lock` serializes build/test gates per worktree. `scripts/test`
and `scripts/premerge-gate` use it automatically so concurrent local runs do not
race on generated runtime caches or std embedding. The wrapper also
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
path discovery, the shared frontend graph, and generated aggregate harnesses. A
typecheck covers the shared execution boundary, and the stage-two test exercises
the production CLI route:

```bash
bin/blorp test --timeout 30 \
  blorp/test/test/test_discovery.brp \
  blorp/test/test/test_generated_test_harness.brp \
  blorp/test/lib/test_source_graph_context.brp \
  blorp/test/test/test_plan.brp
bin/blorp check --no-format \
  blorp/src/test/effect.brp
blorp/test/cli/test_cli_stage_two.sh --timeout 90
```

Run `bin/blorp test --timeout 30 blorp/test/runtime/sys/test_process_session.brp`
for the session API; CLI smoke separately covers inherited stdin, stdout, and
stderr for blocking commands. Use `scripts/bench-blorp-test-session` for
repeatable timing or RSS evidence; its process supervisor and registered
workloads are the single benchmark path.

## Compiler Bootstrap

`make install` invokes the pinned release's public `blorp compile` command to
build the current compiler. The compiler is a single executable; tests,
packages, the LSP, and releases do not prepare or install private workers.

Local compiler builds use `-O0` by default for the shortest edit/build cycle.
Set `BLORP_CLI_C_OPTIMIZATION` to select a different single C optimization
level. Main CI and tagged release builds use `-Og`, and the selected level is
part of the generated CLI cache identity.

Normal builds use `scripts/blorp-compiler-bootstrap`, which reads the immutable
release identity and per-target checksums from
`blorp/build/bootstrap.env`, then downloads and verifies the release into
`$HOME/.cache/blorp/compiler-bootstrap`, or `BLORP_COMPILER_BOOTSTRAP_CACHE_DIR`
when set. Rotate the tag, version, and all target checksums together in that
single manifest only after release CI has published the merged revision.
The current pin uses the `single` layout for its historical archive. New direct-
binary releases use `direct`; after the first such release is pinned, the
archive compatibility path can be removed. Both layouts cache only `blorp` and
remain isolated from the retired multi-executable distribution.

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
not fail the quality gate merely because cleanup remains queued. Track accepted
cleanup work in GitHub issues rather than copying point-in-time counts into a
maintained document.

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

`scripts/package-release` copies the public `bin/blorp` command to the target-
qualified release asset `blorp-<target>`. That binary can also become the
immutable compiler when the release is later pinned as the bootstrap:

```bash
scripts/package-release dist
```

Useful environment variables:

- `BLORP_RELEASE_BINARY` selects the binary to package.
- `BLORP_RELEASE_TARGET` overrides the target triple in the asset name.

`scripts/install-dev` downloads, validates, stages, and atomically installs that
executable. It removes private compiler helpers left by older releases.

On main, CI builds the compiler once with its final dev release metadata,
checks the self-hosted source graph, runs the normal test gates, smokes the
target-qualified binary, and uploads it as a workflow artifact. The dev release
workflow downloads and publishes those exact bytes
instead of compiling the compiler again. Explicit `v*` tags still build
independently because the tagged version embedded in the executable differs from
the dev version tested on main.

`scripts/install-dev` installs the latest moving `dev` release:

```bash
curl -fsSL https://raw.githubusercontent.com/kablorp/blorp/main/scripts/install-dev | bash
```

It downloads the matching `blorp-<target>` executable and installs it as
`$HOME/.local/bin/blorp` by default. `blorp` remains the only public command.
Invalid executables are rejected before installation.
The installer temporarily accepts the previous archive format so installing
does not break while the moving `dev` release transitions to direct binaries.

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
