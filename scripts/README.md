# Scripts

This directory holds the shell entrypoints for building and proving Blorp:

| Script | Purpose |
| --- | --- |
| `blorp-compiler-bootstrap` | Resolves, verifies and runs the pinned Blorp seed. |
| `blorp-fixpoint` | Proves the compiler reproduces its own C. |
| `target-triple` | Prints the native release target, such as `aarch64-apple-darwin`. |

## Validating a change

Changes under `blorp/` are validated with `make -C blorp test`, plus
`scripts/blorp-fixpoint --prove` when the change alters emitted C and
`bash blorp/test/tooling/test_bootstrap.sh` when it touches the bootstrap
resolver or the Makefile recipes. [`blorp/AGENTS.md`](../blorp/AGENTS.md)
owns the rest of the validation rules.

The Blorp workflow (`.github/workflows/blorp.yml`) runs when `blorp/` or
its bootstrap and fixpoint scripts change. It runs Linux x64 with Clang and
GCC, Linux ARM64 with Clang, and macOS ARM64 with Clang. Each checks out
source, runs `make -C blorp test` with the pinned seed and selected C
compiler, then runs the bootstrap shell test. On a push to main that passes,
`.github/workflows/blorp-seed.yml` builds the compiler with itself on all
three native targets, verifies that the three emit identical C, runs the
fixtures under both generations, and publishes that commit's seed as the
immutable release `blorp-seed-<12hex>`, whose assets are `blorp-<target>`.

The Makefile's explicit component selection (`COMPONENT_SOURCES` in
`blorp/test/e2e/self_hosted.brp`; `TARGET_COMPONENT_SOURCES=<paths>` overrides
it) runs through ordinary target TestSuite entries, one program per listed
directory (its phase), with C11 `-O0` linking and strict native memory checks.
The Blorp test driver that `make` builds runs it and the e2e selection.
The native e2e selection runs the real-main cases and process-runtime
lifecycle checks through ordinary Blorp TestSuites, with exact output, strict
accounting and ASan/UBSan checks. The test targets use the already-built test
compiler, `blorp/build/blorp-test`. Every `test_*.brp` file is selected and run; the
full component run fails on one that `COMPONENT_SOURCES` does not list.

## Blorp seed build

`make -C blorp` (or the explicit `compiler` target) uses
`scripts/blorp-compiler-bootstrap` to generate compiler C through a pinned
Blorp seed's direct CLI, then links it twice at `-O0`: the `blorp` command,
`blorp/build/blorp` (`BLORP_COMPILER`), with memory diagnostics disabled, and
the test compiler, `blorp/build/blorp-test` (`BLORP_TEST_COMPILER`), with them
enabled. `test-compiler` generates once and links only the test compiler.
`link-test-compiler` still links an explicitly supplied C path for fixpoint
stages. The test targets run only `BLORP_TEST_COMPILER`: e2e checks the strict
allocation report on every compile, which only a diagnostic link prints, and
the two builds never share a path. Output paths, `BLORP_CC`,
`TEST_COMPILER_FLAGS` and `TEST_COMPILER_LIBRARIES` accept Make command-line
overrides. Recipes run one at a time, because `compiler` and `test-compiler`
both link the test compiler and the test targets run compiled programs.

The resolver uses the real `blorp/bootstrap.env` pin, recorded after all
three native seed assets were qualified. It validates the full source commit, matching
immutable `<family>-seed-<12hex>` tag and all three SHA-256 values. It downloads
`<family>-<target>` from that release and rehashes cached bytes before every use.
The release family is one named value in the resolver, `seed_release_family`. It
is `blorp`, the family the seed workflow publishes.
The separate cache defaults to `$XDG_CACHE_HOME/blorp/seed` or
`$HOME/.cache/blorp/seed`; `BLORP_COMPILER_BOOTSTRAP_CACHE_DIR`
is its only explicit override. Relative cache paths resolve from the repository
root. Release identity cannot be overridden through environment variables.
Before running the seed the resolver prints one line to stderr, such as
`Blorp bootstrap: seed blorp-seed-4acd2377961d (cached)` (or `downloaded`), so a
build log shows which seed built the compiler.
`--print-path` verifies the seed without running it; `--print-id` validates and
prints the repository, tag and source commit without downloading it. Other
arguments are forwarded unchanged from the repository root.
The cache was `$XDG_CACHE_HOME/blorp/blorp2-bootstrap` before the rename to Blorp; that
directory is no longer read and can be deleted.

The `example` target uses the newly built `blorp` command. `test` builds the test
compiler and runs its explicit self-hosted component and native e2e selections;
`test-target-components` uses an already-built test compiler.
Run the isolated behavioral shell tests with
`bash blorp/test/tooling/test_bootstrap.sh`; they use fake transport,
seed and C compiler tools, including quoted paths and parallel target requests.
It is the one sanctioned shell test: the resolver and recipes it covers are
shell tooling. Cold/warm clean-checkout qualification uses the actual
published seed assets.

## Blorp fixpoint

`scripts/blorp-fixpoint` builds **A** from the pinned seed, A builds **B**,
B builds **C**, and C compiles the source again, all linked at `-O0` through
`test-compiler`/`link-test-compiler`. `--prove` requires B/C source-C identity,
A/B exit/stdout/stderr/emitted-C parity for every fixture, and B's explicit
self-hosted components and native e2e selection. It exits 0 for that bounded
proof, 1 at a failed stage, and 2 for setup failure. Full resource
qualification is DEFERRED; a successful fixpoint result
claims only the named selection.
`--frontier` reports the first failed rung of the same source/component ladder
and exits 0 except for setup failures. The old per-file parse inventory is
DEFERRED because its filesystem driver is unported; the actual seed/A loader
still parses the compiler source.
Artifacts, hashes and explicit coverage status stay under
`blorp/build/fixpoint/`. See `--help` for the current rungs.

## Rotating the seed pin

Before the compiler C, the same seed builds `blorp/scripts/embed_library.brp`,
whose output `blorp/build/generated/embedded_library.brp` holds the standard
library the compiler embeds. Both are Make file targets, so they are rebuilt only
when the library or the generator changes; `blorp-seed.yml` runs the target
before reference A.
`blorp/bootstrap.env` names the seed release and its three SHA-256 values.
Rotate the tag, source commit and all three digests together, and only after
`blorp-seed.yml` has published and qualified the release for every target.

The seed is driven as `compile INPUT --library-root DIR -o OUTPUT` by
`generate-compiler` and the generator target in `blorp/Makefile`, the seed step of
`blorp-seed.yml`, and the fake seed in `blorp/test/tooling/test_bootstrap.sh` (its
two seed argument lists). A change to the seed's command line moves those with the pin.

The seed workflow's fixture parity step deliberately accepts only exit 0 and 1
for a fixture: an exit 4 (a fault in blorp) or 2 or 3 fails the step.
Run `make -C blorp test`, the fixpoint and the bootstrap test against the new
pin before landing it.
