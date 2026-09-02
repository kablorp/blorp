# Support Narrow Managed Option Captures In Generic Closures

**Status:** Ready for minimization and diagnosis

## Problem

Narrowing a private typechecking helper from an `OverloadEntry` parameter to
its `Option[String]` module path remains source-type-correct, but capturing that
option in the existing `List.filter` closure fails during C emission. Capturing
the original record succeeds. Replacing the closure with a mutable append loop
also compiles, but is unrelated workaround code and must not become the fix.

## First Step

Add the smallest compiler regression that captures an `Option[String]` in a
generic list predicate and reaches generated C. Confirm whether the failure is
specific to `Option[String]`, generic callbacks, managed union captures, or the
typechecking call site before changing production code.

## Acceptance

- The minimized source fails before the fix and compiles after it.
- Generated C gives the closure environment and captured option correct owners.
- The original helper can accept the narrow option without workaround loops.
- Focused closure, typechecking, ownership, leak, and sanitizer tests pass.
