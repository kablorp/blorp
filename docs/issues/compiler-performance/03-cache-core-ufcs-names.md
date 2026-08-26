# Stop Rebuilding Core UFCS Names

**Status:** Ready for implementation

## Issue Summary

Avoid repeatedly replacing module path separators and concatenating the same
UFCS prefix during typed-AST to Core lowering. Compute the module-specific
prefix once per lowering context or cache each canonical callable name at its
existing identity boundary.

This is deliberately narrower than the compiler-wide integer-identity roadmap.
Do not turn it into a cross-pipeline identifier migration.

## Profile Evidence

The compiler self-compilation baseline took 180.545 seconds, made 704.1 million
allocations, and reached 2.218 GB peak RSS. External sampling attributed 10,221
samples, 6.799% and about 12.39 seconds, to
`identity.core_ufcs_function_name` and its string/library/runtime descendants.

The helper is tiny, but each call performs `module_name.replace("/", "$" )`
and multiple string concatenations. The sample includes string equality,
allocation, release, and copying caused by those operations. Its high share is
evidence of invocation frequency and repeated construction, not a claim that
the helper's control flow itself is complex.

## Current Code

Primary file: `compiler/src/stage_08_core_lower/identity.brp`.

```blorp
pure func core_ufcs_function_name(module_name: String, source_name: String) -> String:
	"__ufcs_" + module_name.replace("/", "$") + "__" + source_name
```

The same helper is also used to compute the decoding prefix in
`core_ufcs_source_name_for_module`. Callers across Core lowering reconstruct
names for declarations, references, overloads, and aliases.

## Problem Statement

Module identity is stable during lowering, but its escaped UFCS prefix is
recomputed for every source name and often for repeated references to the same
callable. Large projects therefore allocate and release many equivalent
strings before later identity work can discard or replace them.

## Goals

1. Compute module path escaping no more than once per module lowering context.
2. Avoid rebuilding the full same callable name when an existing per-callable
   identity or declaration product can retain it safely.
3. Preserve exact Core name bytes and decoding behavior.
4. Prove fewer string replacements, allocations, and calls on a focused
   workload.

## Non-Goals

- Do not change the Core naming format.
- Do not shorten C identifiers.
- Do not replace strings with global integer IDs across the pipeline.
- Do not add a process-global string intern table.
- Do not merge `core_module_member_name`, pure-overload naming, or unrelated
  sanitization policy unless required for the same prefix object.
- Do not infer module ownership from a formatted string.

## Proposed Design

The lowest-risk design is a module-specific prefix:

```blorp
pure func core_ufcs_module_prefix(module_name: String) -> String:
	CORE_UFCS_PREFIX + module_name.replace("/", CORE_UFCS_MODULE_SEPARATOR) + "__"

pure func core_ufcs_name_from_prefix(prefix: String, source_name: String) -> String:
	prefix + source_name
```

Add the prefix to the existing typed-to-Core module/lowering context, or compute
it once at the entry to a module traversal and pass it to declaration and
expression lowerers. Do not add it to every AST node.

If the current branch already carries a nominal callable identity product with
one canonical Core name, prefer constructing the full name once when that
product is built. The implementation must remain a local change: use existing
identity carriers; do not design new cross-stage identity infrastructure.

## Mechanical Implementation Sequence

1. Inventory all production `core_ufcs_function_name` calls and classify them
   as module setup, declaration construction, reference construction, or
   decoding.
2. Add focused tests for exact naming before changing callers.
3. Add a benchmark that constructs many names in a small number of modules and
   reports a checksum of all resulting bytes.
4. Introduce `core_ufcs_module_prefix` and a private name-from-prefix helper.
5. Thread the prefix through one module-lowering path and replace repeated
   calls there.
6. Preserve the public two-string helper for callers that do not have a module
   context, but implement it through the new primitives.
7. Migrate the remaining hot lowering callers mechanically.
8. Leave decoding explicit: `core_ufcs_source_name_for_module` may build one
   prefix per invocation unless its caller already has the prefix. Do not cache
   incorrectly across modules.
9. Inspect generated Core and generated C for representative programs.

## Invariants And Pitfalls

- Output must remain exactly `__ufcs_<module-with-/-as-$>__<source>`.
- Module segments and source names may contain `__`; decoding is only valid
  relative to a known module and must remain so.
- Preserve behavior for empty source names because decoding uses that to make a
  prefix.
- Do not use dictionary iteration order to assign or emit names.
- Do not retain a lowering context beyond its module and accidentally apply a
  prefix to another module.
- A full callable-name cache must be keyed by nominal callable identity or an
  unambiguous module/source pair, not source spelling alone.
- Measure retained memory as well as allocation count. A cache that retains all
  temporary strings can reduce calls while increasing peak RSS.

## Fast Feedback Loop

Add a focused benchmark under `compiler/benchmarks/` that accepts module count,
names per module, and iterations. Use repeated references to expose caching and
many distinct names to expose prefix reuse. Report:

- full-name construction count;
- module-prefix construction count;
- output checksum and total bytes;
- elapsed microseconds; and
- allocation counts when available.

Suggested workload matrix:

```text
modules=1, names=4096
modules=16, names=4096
modules=256, names=4096
```

The optimized one-module case should perform one module-path replacement, not
4,096 replacements.

## Functional Tests

Use:

```bash
./blorp test --timeout 180 compiler/tests/test_compiler_core_lower.brp
./blorp test --timeout 180 compiler/tests/test_compiler_core_flatten.brp
scripts/compiler-check --stage core-lower
```

Cover:

- simple and nested module paths;
- module names containing `.` and `/` where each relevant naming helper has a
  distinct policy;
- empty source name prefix generation;
- pure and impure overload names;
- two modules with the same source function name;
- UFCS decode round trips relative to a known module; and
- byte-identical generated Core names before and after.

## Acceptance Criteria

- Module path replacement occurs once per module context on the hot lowering
  path.
- Focused output names and checksum are unchanged.
- Focused calls/allocations and elapsed time materially decrease.
- Peak retained memory does not materially increase.
- Existing Core lowering and flattening suites pass.
- Representative generated Core and C retain byte-identical callable names.
- The change uses existing identity/context products and does not expand into a
  compiler-wide naming refactor.

