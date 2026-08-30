# Extract Formatting

**Status:** Planned

## Goal

Move formatting production code to `blorp/src/format/` and its executable tests
and fixtures to `blorp/test/format/`.

## Scope

- Move formatter arguments, filesystem effects, diff output, exit policy,
  document construction, and rendering under the format owner.
- Consume syntax only through the Issue 3 shared boundary when another named
  production owner needs that boundary. Otherwise keep the required parser
  projection format-owned.
- Move public formatter fixtures and normalize executable test names.
- Remove the legacy formatter command path after all production callers move.

The formatter engine remains format-owned in this issue. If LSP becomes its
second consumer, Issue 10 promotes only the shared engine and records format and
LSP as its consumers; CLI effects remain under format.

## Required Invariants

- Format imports no non-library sibling owner.
- Formatting output and `--check`/`--diff` exit behavior remain byte-for-byte
  compatible.
- The move introduces no second parser or guessed source representation.

## Validation

Run formatter unit tests, public fixtures, CLI smoke, and formatting checks over
representative compiler, standard-library, and test sources.

