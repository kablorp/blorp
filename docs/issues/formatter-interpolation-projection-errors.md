# Define Formatter Behavior For Invalid Interpolations

**Status:** Requires an explicit behavior decision

## Problem

Formatter projection parses interpolation expressions but can replace a failed
projection with literal text, suppressing the malformed-interpolation error.
Source-AST finalization now preserves exact source-path provenance and exposes
the diagnostic, but the formatter's public behavior remains unclear.

## Decision

Specify whether formatting invalid source must surface interpolation parse
errors or deliberately preserve the original text as a recoverable formatting
operation. Do not silently infer the policy from the current fallback.

## Acceptance

- Tests cover malformed interpolation through both parsing and `blorp format`.
- The chosen behavior preserves exact source paths and deterministic diagnostics.
- Formatter recovery does not discard or invent source text.
- The user-facing formatter contract documents the decision if behavior changes.
