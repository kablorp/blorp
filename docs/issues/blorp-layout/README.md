# Blorp Source Layout Roadmap

**Status:** Planned

This roadmap moves every production component of the `blorp` executable under
one package root without changing language behavior, compiler phase order, CLI
output, or generated C.

## Final Layout

```text
blorp/
  src/
    main.brp
    compiler/
      pipeline.brp
    compile/
    check/
    run/
    format/
    purify/
    test/
    lint/
    package/
    lsp/
    lib/
  test/
    test_main.brp
    cli/
    build/
    tool/
    compiler/
    compile/
    check/
    run/
    format/
    purify/
    test/
    lint/
    package/
    lsp/
    lib/
    runtime/
  benchmark/
    compiler/
  tool/
  build/
```

`blorp/src/test/` is production code implementing the `blorp test` command.
Tests of that production code live only in `blorp/test/test/`. No test,
fixture, or test-support module may live below `blorp/src/`.

The existing root `./blorp` executable must move before the `blorp/` directory
can exist. Local builds will install the executable as `bin/blorp`; release
packaging may continue to publish an executable named `blorp`.

The language libraries remain separately owned repository packages:

```text
std/                    # Portable shipped standard-library source
  test/                 # Former tests/test_std
pkg/                    # Optional packages and native bindings
  test/                 # Former tests/test_pkg
examples/               # User-facing examples and preview smoke inputs
```

They are build inputs and distribution content, but they are not implementation
directories for the `blorp` executable. The current `blorp/test/runtime` runtime
and language-behavior fixtures move to `blorp/test/runtime`. Public parser,
inference, typecheck, codegen, and CLI-tool fixtures currently under
`tests/test_compiler` move to their owning `blorp/test/compiler` or command
directories. The final layout has no ambiguous top-level `tests/` tree.

The complete current top-level test inventory is assigned before migration:

| Current path or group | Final owner | Issue |
| --- | --- | --- |
| `blorp/test/compiler`, parser/infer/typecheck/codegen fixtures, root `test_compiler_*`, compiler audit and ownership-ledger tests | `blorp/test/compiler` | 2 |
| `tests/test_cli*.sh` and root executable smoke | `blorp/test/cli` | 1 |
| Build configuration, source-generator, embedded-manifest, release-toolchain, and test-harness tests | `blorp/test/build` | 1 |
| `tests/scripts` and shared compiler-tool fixture runners | `blorp/test/tool` | 7 |
| `blorp/test/runtime` plus leak fixtures, leak-report tests, and runtime allocator tests | `blorp/test/runtime` | 8 |
| Test-session benchmark checks | `blorp/test/test` | 8 |
| `tests/lsp` | `blorp/test/lsp` | 10 |
| `tests/test_std` | `std/test` | 11 |
| `tests/test_pkg` | `pkg/test` | 9 |
| `tests/README.md` | Split into owning active documentation, then removed | 11 |
| `__pycache__` and other generated caches | Removed, never migrated | Owning issue |

Before Issue 2 moves anything, its path inventory expands these groups to exact
files and rejects unassigned or duplicate destinations. Issue 11 compares the
live old tree against that inventory and fails if an unassigned path remains.

## Dependency Contract

- `blorp/src/main.brp` is the sole composition root. It may import each command's
  public entry point.
- A non-library owner is one of `compiler`, `compile`, `check`, `run`, `format`,
  `purify`, `test`, `lint`, `package`, or `lsp` immediately below
  `blorp/src/`.
- Non-library owners do not import one another.
- Command owners therefore do not import `compiler/` directly. Shared compiler
  execution and inspection gateways belong in `lib/`; those gateways alone may
  import the compiler implementation.
- Code may enter `blorp/src/lib/` only when at least two distinct non-library
  production owners reach it through production imports. `main`, tests, build
  tools, benchmarks, and generated modules do not count as consumers.
- Single-consumer code remains with its owning implementation, even when it
  looks generally useful.
- The same second-consumer rule applies to `blorp/test/lib/`, counting distinct
  test owner directories.
- Compiler phase order is owned only by
  `blorp/src/compiler/pipeline.brp`.
- Compiler modules do not import command models, CLI argument types, renderers,
  or host-effect implementations.
- Tests mirror production ownership. Executable test modules use `test_`
  filename prefixes. Inputs beneath explicitly registered `fixture/`,
  `should_pass/`, `should_fail/`, and golden-data directories are fixtures and
  need not use the prefix.

The intended production dependency flow is:

```text
main -> command owner -> multi-consumer lib gateway -> compiler pipeline
```

A gateway is not a passthrough alias. It owns a shared application request and
result boundary used by its named consumers. Compiler phase order and
compiler-internal representations remain on the compiler side of that boundary.

## Mechanical Enforcement

Issue 1 introduces `blorp/source_ownership.json` and
`scripts/check-blorp-layout`. The manifest records:

- every non-library owner root;
- the `main` composition-root exception;
- allowed owner-to-`lib` edges;
- the narrow `lib`-to-`compiler` gateway edges;
- fixture-directory classifications; and
- for each `lib` module, at least two named production owner consumers.

The gate constructs the production import graph, verifies that each named
consumer can reach the shared module, rejects unlisted cross-owner imports, and
rejects `lib` modules with fewer than two distinct reachable production owners.
It separately scans executable test modules for the `test_` convention and
rejects test code below `blorp/src/`. Manifest entries cannot substitute for an
actual import-graph path.

## Migration and Equivalence Rules

Each issue is independently mergeable. A source move carries its focused tests,
ownership manifests, build inputs, and active documentation in the same change.
Compatibility adapters may exist only when the next issue names their consumer
and removal point. Structural moves must not be combined with semantic rewrites.

Issue 1 records the clean baseline revision, toolchain identity, fixtures, and
timings used throughout the roadmap. Each issue uses the same machine and build
mode, one discarded warm-up, and at least seven alternating baseline/candidate
runs. A candidate outside the baseline run-to-run range is rerun with at least
fifteen alternating samples and profiled. Any repeatable slowdown attributable
to the change is a rejection, even when small; thresholds are triage triggers,
not permission to consume a latency budget.

User-program generated C and public CLI output are compared byte-for-byte.
Self-host compilation comparisons normalize only the recorded old/new physical
source-root prefixes. Any other intentional path-bearing delta must be listed
and reviewed; semantic Core, diagnostics, symbols, and emitted operations may
not be normalized away.

For every issue:

1. Add or relocate the focused test before cutting over production imports.
2. Preserve public help, diagnostics, exit status, generated C, and relevant
   compiler snapshots.
3. Run the focused suites plus the manifest-owned changed checks.
4. Apply the recorded equivalence and latency protocol.
5. Obtain review before commit.

## Sequence

1. [Establish the package root and measurement contract](01-establish-package-root.md).
2. [Relocate the compiler and its focused tests](02-relocate-compiler.md).
3. [Establish shared compiler service boundaries](03-establish-compiler-boundaries.md).
4. [Extract the compilation command family](04-extract-compilation-commands.md).
5. [Extract formatting](05-extract-formatting.md).
6. [Extract purify](06-extract-purify.md).
7. [Extract lint](07-extract-lint.md).
8. [Extract the test command](08-extract-test-command.md).
9. [Extract package management](09-extract-package.md).
10. [Extract LSP](10-extract-lsp.md).
11. [Delete the legacy layout and enforce the final architecture](11-delete-legacy-layout.md).

Issues 1 through 4 are dependency ordered. Issues 5 and 6 may proceed after
Issue 3 when they do not touch the same legacy files. Issue 7 follows Issues 5
and 6 because it owns the final shared compiler-tool runner relocation. Issues
8 through 10 follow Issue 4 because they reuse compiler services without
importing compilation command owners. Issue 11 runs last.
