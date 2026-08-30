# Extract Purify

**Status:** Planned

## Goal

Move purify production code to `blorp/src/purify/` and its tests and fixtures to
`blorp/test/purify/`.

## Scope

- Move purify arguments, rewrite planning, filesystem effects, and rendering.
- Consume parsed or typed compiler facts through the shared frontend-analysis
  boundary established by Issue 3.
- Keep rewrite-specific models and transformations purify-owned.
- Remove the legacy purify path after all callers move.

## Required Invariants

- Purify imports no non-library sibling owner, including compiler and format.
- Purify does not construct a second compiler pipeline.
- Rewrites, dry-run output, formatting handoff, and exit behavior remain
  deterministic and compatible with existing fixtures.

## Validation

Run purify fixtures, frontend-analysis boundary tests, compiler-tools, and CLI
smoke. Apply the roadmap latency protocol to representative single-file and
source-tree purify runs.

