# Extract Lint

**Status:** Planned

## Goal

Move lint production code to `blorp/src/lint/` and its tests and fixtures to
`blorp/test/lint/`.

## Scope

- Move lint arguments, finding models, rule execution, output formats, and exit
  policy.
- Consume compiler facts through the shared frontend-analysis boundary from
  Issue 3.
- Keep lint rules and presentation lint-owned.
- After format, purify, and lint fixtures have moved, relocate their shared
  Python/shell fixture runners and `tests/scripts` checks to `blorp/test/tool`;
  command-specific runners remain with their command tests.
- Remove the legacy lint path after all callers move.

## Required Invariants

- Lint imports no non-library sibling owner, including compiler, check, and
  purify.
- Lint does not create a partial alternative compiler pipeline.
- Finding identities, ordering, JSON output, and fail-on-findings behavior remain
  compatible.

## Validation

Run lint clean/finding fixtures, frontend-analysis tests, compiler-tools, and CLI
smoke. Apply the roadmap latency protocol to representative source trees.
