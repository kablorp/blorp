# Scripts

This directory holds the shell entrypoints for building and proving Blorp 2:

| Script | Purpose |
| --- | --- |
| `blorp2-compiler-bootstrap` | Resolves, verifies and runs the pinned Blorp 2 seed. |
| `blorp2-fixpoint` | Proves the compiler reproduces its own C. |
| `target-triple` | Prints the native release target, such as `aarch64-apple-darwin`. |

## Validating a change

Changes under `blorp/` are validated with `make -C blorp test`, plus
`scripts/blorp2-fixpoint --prove` when the change alters emitted C and
`bash blorp/test/tooling/test_bootstrap.sh` when it touches the bootstrap
resolver or the Makefile recipes. [`blorp/AGENTS.md`](../blorp/AGENTS.md)
owns the rest of the validation rules.

The Blorp 2 workflow (`.github/workflows/blorp2.yml`) runs when `blorp/` or
its bootstrap and fixpoint scripts change. It runs Linux x64 with Clang and
GCC, Linux ARM64 with Clang, and macOS ARM64 with Clang. Each checks out
source, runs `make -C blorp test` with the pinned seed and selected C
compiler, then runs the bootstrap shell test. On a push to main that passes,
`.github/workflows/blorp2-seed.yml` builds the compiler with itself on all
three native targets, verifies that the three emit identical C, runs the
fixtures under both generations, and publishes that commit's seed as the
immutable release `blorp2-seed-<12hex>`.

The Makefile's explicit component selection (`COMPONENT_SOURCES` in
`blorp/test/e2e/self_hosted.brp`; `TARGET_COMPONENT_SOURCES=<paths>` overrides
it) runs through ordinary target TestSuite entries, one program per listed
directory (its phase), with C11 `-O0` linking and strict native memory checks.
The Blorp test driver that `make` builds runs it and the e2e selection.
The first native e2e selection runs the selected real-main cases and process-runtime
lifecycle checks through ordinary Blorp TestSuites, with exact output, strict
accounting and ASan/UBSan checks. `test-e2e` uses an already-built diagnostic B2
compiler. Unported unit/runtime/grammar/tooling and remaining native e2e cases
are DEFERRED, with their sources preserved; they receive no PASS credit, and
`test-components` prints how many each top directory holds.

## Blorp 2 seed build

`make -C blorp` (or the explicit `compiler` target) uses
`scripts/blorp2-compiler-bootstrap` to generate compiler C through a pinned
Blorp 2 seed's direct CLI, then links normal mode at `-O0` with memory
diagnostics disabled. `test-compiler` generates once and links diagnostic
mode instead. `link-test-compiler` still links an explicitly supplied C path
for fixpoint stages. Output paths, `BLORP_CC`, `TEST_COMPILER_FLAGS` and
`TEST_COMPILER_LIBRARIES` accept Make command-line overrides. Build targets
are serialized because normal and diagnostic modes share the output path.

The resolver uses the real `blorp/bootstrap.env` pin, recorded after all
three native seed assets were qualified. It validates the full source commit, matching
immutable `blorp2-seed-<12hex>` tag and all three SHA-256 values. It downloads
`blorp2-<target>` from that release and rehashes cached bytes before every use.
The separate cache defaults to `$XDG_CACHE_HOME/blorp/blorp2-bootstrap` or
`$HOME/.cache/blorp/blorp2-bootstrap`; `BLORP2_COMPILER_BOOTSTRAP_CACHE_DIR`
is its only explicit override. Relative cache paths resolve from the repository
root. Release identity cannot be overridden through environment variables.
`--print-path` verifies the seed without running it; `--print-id` validates and
prints the repository, tag and source commit without downloading it. Other
arguments are forwarded unchanged from the repository root.

The `example` target uses the newly built B2 compiler. `test` builds B2 and
runs its explicit self-hosted component and first native e2e selections; `test-components` uses an
already-built B2 compiler. Unported suites are deferred.
Run the isolated behavioral shell tests with
`bash blorp/test/tooling/test_bootstrap.sh`; they use fake transport,
seed and C compiler tools, including quoted paths and parallel target requests.
It is the one sanctioned shell test: the resolver and recipes it covers are
shell tooling. Cold/warm clean-checkout qualification uses the actual
published seed assets.

## Blorp 2 fixpoint

`scripts/blorp2-fixpoint` builds **A** from the pinned B2 seed, A builds **B**,
B builds **C**, and C compiles the source again, all linked at `-O0` through
`test-compiler`/`link-test-compiler`. `--prove` requires B/C source-C identity,
A/B exit/stdout/stderr/emitted-C parity for every fixture, and B's explicit
self-hosted components and first native e2e selection. It exits 0 for that bounded
proof, 1 at a failed stage, and 2 for setup failure. Remaining native e2e cases
and full resource qualification are DEFERRED; a successful fixpoint result
claims only the named selection.
`--frontier` reports the first failed rung of the same source/component ladder
and exits 0 except for setup failures. The old per-file parse inventory is
DEFERRED because its filesystem driver is unported; the actual seed/A loader
still parses the compiler source.
Artifacts, hashes and explicit coverage status stay under
`blorp/build/fixpoint/`. See `--help` for the current rungs.

## Rotating the seed pin

`blorp/bootstrap.env` names the seed release and its three SHA-256 values.
Rotate the tag, source commit and all three digests together, and only after
`blorp2-seed.yml` has published and qualified the release for every target.
Run `make -C blorp test`, the fixpoint and the bootstrap test against the new
pin before landing it.
