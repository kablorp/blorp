# Extract the Compilation Command Family

**Status:** Planned

## Goal

Move compile, check, and run into independent command owners while preserving
all compiler orchestration in `blorp/src/compiler/pipeline.brp`.

## Target Ownership

```text
blorp/src/compile/
blorp/src/check/
blorp/src/run/
blorp/test/compile/
blorp/test/check/
blorp/test/run/
```

## Scope

- Move each command's argument parsing, command model, effects, and output to its
  owner directory.
- Route compile and run through the whole-compilation boundary established by
  Issue 3. Route check through its frontend-validation operation; do not model
  check as whole compilation with a hidden stop flag.
- Keep compile artifact policy, check reporting, and run process lifetime local
  unless another independent production owner consumes the exact behavior.
- Move and rename focused tests in the same commits.
- Remove the legacy compile/check/run paths after their callers move.

Compile, check, and run are separate commits within this dependency-ordered
issue. Every commit passes its focused command gate and leaves no duplicate
production authority.

## Required Invariants

- The three command owners do not import one another or `compiler/`.
- No command can alter or restate compiler phase order.
- Check does not perform backend work that it previously skipped.
- Generated C, diagnostics, output selection, and run exit propagation remain
  equivalent.

## Validation

Run focused command suites, compiler pipeline suites, CLI smoke, and codegen
audit. Apply the roadmap latency protocol independently to compile, check, and
run.
