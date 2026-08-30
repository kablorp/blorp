# Delete the Legacy Layout

**Status:** In progress — legacy assets, tests, and compiler-owned CLI removed;
frontend/LSP boundary cleanup pending

## Goal

Remove obsolete paths, place every remaining build/runtime asset with an
explicit owner, and enforce the final source graph.

## Final Relocations

- `compiler/lib` native runtime inputs move to
  `blorp/src/lib/runtime/native`; compile, run, test, and package are recorded as
  consumers only where the import/build graph proves each use. A single-owner
  native input instead moves with that owner.
- `compiler/tools` moves to `blorp/tool`.
- `compiler/benchmarks` moves to `blorp/benchmark/compiler`.
- `compiler/testdata` moves to registered fixture locations under
  `blorp/test/compiler`.
- Bootstrap configuration and source-generation manifests move to
  `blorp/build`.
- `tests/test_std` moves to `std/test`; Issue 9 has already moved
  `tests/test_pkg` to `pkg/test`. All other current top-level test content must
  already have moved to a named `blorp/test` owner.

## Scope

- Delete the old top-level `compiler/` and `tests/` directories.
- Compare all former top-level test paths with the roadmap inventory and reject
  any unassigned or duplicate destination; this issue verifies ownership rather
  than choosing it for the first time.
- Reject any build or test-gate reference to `tests/test_pkg`; Issue 9 owns that
  cutover rather than this cleanup issue.
- Delete obsolete stage-owned CLI, formatter, and LSP modules.
- Remove every temporary compatibility adapter and bootstrap layout bridge.
- Finalize `blorp/source_ownership.json` and make
  `scripts/check-blorp-layout` a required hygiene gate.
- Update architecture, development, testing, packaging, and project-tree docs.

## Final Invariants

- `blorp/src/main.brp` is the only executable root.
- `blorp/src/compiler/pipeline.brp` is the only whole-compiler orchestration
  root.
- No top-level `compiler/` or `tests/` directory exists.
- No actual test code exists below `blorp/src/`.
- Every executable test module begins with `test_`; registered fixtures are
  classified separately.
- Non-library owners do not import one another.
- Every `blorp/src/lib/` module is reachable from at least two distinct named
  production owners.
- No generated C, binaries, caches, or harness sources are tracked as source.

## Validation

Run the complete preview gate, codegen audit, compiler and runtime sanitizers,
doctests, LSP, package, formatting, purify, lint, leak, and Docker premerge
checks. Apply the roadmap equivalence and latency protocol to every recorded
baseline fixture and reject any confirmed regression.
