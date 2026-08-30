# Establish the Blorp Package Root

**Status:** Complete

## Goal

Create `blorp/src/` and `blorp/test/`, make `blorp/src/main.brp` the sole
executable source root, and move the local development executable from
`./blorp` to `bin/blorp`.

## Scope

- Change the Makefile installation target and active scripts from `./blorp` to
  `bin/blorp`.
- Move the current CLI `main.brp` to `blorp/src/main.brp` without reorganizing
  command internals yet.
- Add or move root-focused tests to `blorp/test/test_main.brp`.
- Move root CLI smoke scripts to `blorp/test/cli` and build configuration,
  source-generator, embedded-manifest, release-toolchain, and test-harness tests
  to `blorp/test/build`.
- Add `blorp/source_ownership.json` with the initial owner roots, composition-root
  exception, fixture classifications, and temporary legacy paths.
- Add `scripts/check-blorp-layout` and run it from the hygiene gate. Its first
  version must reject tests below `blorp/src`, unregistered cross-owner imports,
  false consumer declarations, and improperly named executable test modules.
- Update bootstrap logical paths, source manifests, release packaging, Docker
  entry points, active README examples, and development documentation.
- Teach `clean` to remove the generated `bin/blorp` without deleting `bin/` or
  any broader directory.

Historical issue evidence may retain historical command paths when clearly
identified as such. All executable instructions in active documentation must
use `bin/blorp`.

## Non-goals

- Do not move compiler stages or individual command implementations.
- Do not change CLI parsing, dispatch semantics, diagnostics, or exit codes.
- Do not introduce a wrapper at the old `./blorp` path; that path must become a
  directory.

## TDD Contract

Before cutover, make build and CLI smoke checks assert that:

1. `make` produces an executable `bin/blorp`;
2. `blorp/src/main.brp` is the configured source root;
3. `bin/blorp --help` and each subcommand help surface remain unchanged; and
4. no active build or test script requires a root executable file named
   `./blorp`.

Capture the roadmap measurement contract in the issue evidence: baseline commit,
compiler and C toolchain versions, machine/OS identity, build mode, exact
commands and fixtures, path normalization, raw sample timings, and the output
hashes used for subsequent equivalence checks.

## Validation

Run `make`, CLI smoke, compiler-tool fixtures, and the active packaging smoke.
Compare warmed self-check latency before and after the source-root move.

## Implementation Evidence

- Baseline: `origin/main` at `d3b9f1ab4e0a84bdd47dad04e72c4a5afdca1a0c`.
- Host: Apple M-series MacBook Air, arm64, macOS 26.5.1 (Darwin 25.5.0).
- Toolchains: Blorp bootstrap `0.0.1-dev.6295ce397fdb`, commit
  `6295ce397fdb8b39b8c211d19c960d8e406e4e39`, target
  `aarch64-apple-darwin`, and Apple clang 21.0.0; both builds used the default
  local `-O0` mode.
- Clean/default bootstrap: `make` rebuilt the relocated composition root through
  `scripts/blorp-compiler-bootstrap`. `scripts/compiler-check --changed --base
  origin/main` then passed two focused suites and the CLI, compiler-tools, and
  package checks (369.59 seconds total).
- Structural validation: `scripts/check-blorp-layout`,
  `scripts/compiler-check --validate-manifest`, the layout-contract tests, and
  the dead-code-audit tests passed. The build-configuration test also verifies
  that clean CI jobs create `bin/` before installing the executable.
- Equivalence fixture:
  `blorp/test/runtime/memory/leak_check_baselines/empty_main.brp`, compiled with
  `--no-embed-runtime`. Baseline and candidate generated C were byte-identical,
  each with SHA-256
  `31d61463d4be20d026e7fa26508206c085cff548c6576fa28a86ab8fcf588281`.
- Path normalization: each compiler ran from its own repository root; the
  baseline used its root executable and old source root, while the candidate
  used `bin/blorp` and `blorp/src/main.brp`. Temporary absolute worktree and
  output paths were excluded from the compared generated C.
- Latency protocol: warm each compiler, then alternate baseline and candidate
  self-checks with `/usr/bin/time -p`, using `check --no-format` on the
  respective CLI composition root. Raw real-time samples in seconds were:

  | Pair | Baseline | Candidate |
  | ---: | ---: | ---: |
  | 1 | 57.09 | 58.55 |
  | 2 | 57.12 | 56.92 |
  | 3 | 57.68 | 58.42 |
  | 4 | 66.56 | 60.03 |
  | 5 | 58.80 | 58.00 |
  | 6 | 57.83 | 57.47 |
  | 7 | 52.96 | 52.61 |

  Baseline mean/median were 58.291/57.68 seconds; candidate mean/median were
  57.429/58.00 seconds. The candidate mean improved 1.48%; the 0.55% median
  increase is within observed run-to-run noise, so no latency degradation was
  established.
