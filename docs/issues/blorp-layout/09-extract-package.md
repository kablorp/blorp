# Extract Package Management

**Status:** Implemented

## Goal

Move package lifecycle behavior to `blorp/src/package/` and its tests to
`blorp/test/package/` without turning package-specific policy into generic
library code.

## Scope

- Move package arguments, manifests, cache policy, artifact policy, native link
  planning, effects, and output.
- Move public package lifecycle fixtures to `blorp/test/package/`.
- Move current package-library tests from `tests/test_pkg` to `pkg/test`.
- Update every Makefile, test-gate, and wildcard reference to the new package
  test root in the same change; do not leave the absent old path as a fallback.
- Promote artifact, source, process, or cache code to `lib` only where another
  named production owner already consumes the same responsibility.

## Required Invariants

- Package imports no non-library sibling owner.
- Bare source imports retain the existing std/package boundary.
- Package cache identity, artifact contents, native flags, and command output
  remain equivalent.

## Validation

Run package, native package, CLI, and release-packaging gates. Apply the roadmap
latency protocol to cold and warm package operations affected by moved caches.
