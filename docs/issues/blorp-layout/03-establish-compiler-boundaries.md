# Establish Shared Compiler Service Boundaries

**Status:** Planned

## Goal

Create explicit multi-consumer application boundaries for whole compilation,
frontend analysis, and compiler inspection before moving command owners. No
command may import `blorp/src/compiler/` directly.

## Boundaries

- A compilation service owns application requests and results for compile, run,
  and later test execution. It invokes the authoritative whole pipeline without
  restating phase order.
- A frontend-analysis service owns accepted frontend validation for check and
  immutable inspection results needed by purify, lint, and LSP. It stops at the
  compiler-owned frontend boundary and never performs Core or backend work.
- A syntax/format projection is introduced only if at least two production
  owners need the same parsed representation. Otherwise it remains format-owned.

These boundaries live under `blorp/src/lib/` only after the issue proves their
named production consumers in `blorp/source_ownership.json`. They must own real
request/result adaptation, lifetime, or immutable projection responsibilities;
do not add passthrough wrappers around compiler functions.

## Scope

- Move CLI-owned compiler request/result types to the compiler or shared
  application boundary according to semantic ownership.
- Remove compiler imports of CLI plans, arguments, renderers, and effects.
- Route existing legacy command callers through the new boundaries before
  relocating those callers.
- Add focused tests under `blorp/test/lib/` and compiler boundary tests under
  `blorp/test/compiler/`.
- Register and verify at least two production consumers for every new `lib`
  module.

## Required Invariants

- Whole compilation has one pipeline authority.
- Frontend consumers do not pay for Core or backend work.
- Compiler-owned typed or parsed graphs do not leak mutable compiler state.
- No generic `execute`, `context`, `service`, or `utils` module hides unrelated
  responsibilities.

## Validation

Run compiler pipeline, frontend graph, inspection, CLI boundary, and LSP
analysis suites. Compare exact results and latency for whole-pipeline and
frontend-only requests separately.
