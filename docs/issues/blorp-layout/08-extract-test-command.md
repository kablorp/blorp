# Extract the Test Command

**Status:** Implemented

## Goal

Move production implementation of `blorp test` to `blorp/src/test/` and tests of
that implementation to `blorp/test/test/`.

## Scope

- Move test arguments, discovery, planning, generated harnesses, doctest
  extraction, execution, and result reporting.
- Route compilation and process behavior through already proven
  multi-consumer `lib` boundaries; do not import compile or run owners.
- Keep generated source, C, and executables ephemeral.
- Move runtime and language-behavior fixtures from `tests/test_blorp` to
  `blorp/test/runtime`; these are not tests of the command implementation.
- Move shared leak fixtures, leak-report checks, and runtime allocator checks to
  `blorp/test/runtime`, and test-session benchmark checks to
  `blorp/test/test`.
- Classify executable test modules separately from registered fixture inputs.

## Required Invariants

- Test imports no non-library sibling owner, including compiler, compile, and
  run.
- Batching, timeouts, sanitizers, leak checking, profiling, and doctests remain
  unchanged.
- Generated harness source is deterministic.

## Validation

Run focused test-command suites, compiler Blorp tests, runtime, leak, sanitizer,
doctest, and CLI gates. Compare generated harnesses and warmed suite latency.
