# Reduce Callable-Header Registration Work

**Status:** Investigation first; implementation should remain bounded

## Issue Summary

Measure and remove repeated work in `register_callable_header`, especially
semantic-type conversion and one-at-a-time environment installation. This is a
high-value typechecking target, but it overlaps with scope construction and
must be decomposed before editing.

The first deliverable is a selective profiling harness with counters for each
sub-operation. The implementation should optimize the dominant proven
sub-operation, not rewrite declaration typechecking as a whole.

## Profile Evidence

The compiler self-compilation baseline took 180.545 seconds, performed 704.1
million allocations, and reached 2.218 GB peak RSS. External sampling directly
attributed 6,132 samples, 4.079% and about 7.43 seconds, to
`decl.register_callable_header` excluding compiler callees.

Its direct inclusive subtree contained 15,678 samples, 10.429% of compilation.
That inclusive value includes semantic-type conversion, validation, definition
ID work, and environment/scope insertion. It overlaps substantially with
`scope_add_symbol`; it must not be added to that issue's 7.401% attribution.

## Current Code And Responsibilities

Primary file: `compiler/src/stage_06_typecheck/decl.brp`.

For each accepted `CallableHeader`, `register_callable_header` currently:

1. obtains callable and owner identities;
2. converts every parameter header type to `SemanticType`;
3. builds parameter type and optional-name lists;
4. converts the return type;
5. converts both sides of every dimension constraint;
6. computes generic/bound type parameters;
7. validates resource result annotations and resource signature boundaries;
8. validates source/foreign-specific policies;
9. claims or verifies source definition and callable IDs;
10. constructs a semantic function type and function symbol; and
11. installs that symbol and overload metadata into `TypecheckState.env`.

The function threads errors and state deliberately. Diagnostic order and
accepted-header invariants are part of the typechecker contract.

## Problem Statement

The profile proves header registration is expensive but not which part is
unnecessary. Plausible causes include:

- the same accepted header type being converted more than once;
- repeated traversal of type parameter and dimension constraint lists;
- repeated annotation/policy scans;
- imported headers being projected or installed more than once;
- persistent list construction for parameter data; and
- repeated `Env`/`Scope` replacement for each header.

Optimizing the wrong hypothesis risks adding caches while leaving the dominant
work unchanged. Instrumentation is therefore required before production edits.

## Goals

1. Attribute registration cost to stable sub-operations.
2. Ensure each accepted callable header is converted and installed only as
   often as semantically necessary.
3. Reuse a resolved header projection when identity and owner context prove it
   is valid.
4. Batch environment insertion where it is already atomic and ordered.
5. Preserve exact diagnostics, IDs, resource policy, and generic constraints.

## Non-Goals

- Do not redesign type inference.
- Do not change callable-header acceptance or ordering.
- Do not suppress duplicate/conflict diagnostics.
- Do not introduce a cache keyed only by a string name.
- Do not merge source and foreign callable policy.
- Do not combine this work with broad `Env` representation changes.
- Do not claim the 10.429% inclusive subtree as recoverable savings.

## Required Measurement Slice

Add selective counters, enabled only by the existing compiler profiling path,
for:

- headers entered;
- source versus foreign headers;
- parameter semantic-type conversions;
- return semantic-type conversions;
- dimension-side conversions;
- type-parameter candidate traversals;
- annotation/resource validation calls;
- definition/callable ID claims;
- environment symbol insertions; and
- repeat registrations of the same nominal `CallableId` and owner.

Counters must not change normal compilation behavior or emit unbounded logs.
The workload result should include a checksum and accepted/error counts.

## Candidate Solutions

Implement only the candidate supported by the measurement.

### Candidate A: Resolved Header Projection

Create an immutable private product after a header is accepted:

```blorp
private record ResolvedCallableHeader {
	id: CallableId,
	owner: ModuleIdentity,
	param_types: List[SemanticType],
	param_names: List[Option[String]],
	return_type: SemanticType,
	dim_constraints: List[(SemanticType, SemanticType)],
	type_params: List[BoundTypeParam]
}
```

Use the repository's actual nominal identity types. This sketch is not a demand
to create aliases or duplicate existing products. Cache/project by callable ID
plus owner identity only if those values are globally unambiguous at this
phase. Resource and source-declaration validation may remain outside this
product when it depends on declaration bodies or annotations.

### Candidate B: Install Accepted Headers Once

If counters show duplicate installation, locate the repeated graph traversal
or module preparation boundary. Add a fail-closed completed/installed set keyed
by nominal callable identity. Do not silently skip a second conflicting header;
validate equality or report the existing conflict.

### Candidate C: Batch Environment Installation

If semantic conversion is not repeated but environment updates dominate,
prepare ordered `FuncSymbol`/overload products first and install them using the
batch scope API from Issue 02. Preserve source declaration order and diagnostic
order. This issue may depend on Issue 02 rather than implementing a second
batch mechanism.

## Mechanical Implementation Sequence

1. Read `register_callable_header_for_source`, all loops that call it, and the
   callable-header graph construction/acceptance code.
2. Capture focused tests before instrumentation.
3. Add the bounded counters and a benchmark fixture with modules, headers,
   parameters, generics, and dimension constraints as independent controls.
4. Record a baseline table and identify the dominant repeat ratio.
5. Write a regression that asserts the intended upper bound, such as one
   semantic conversion per header type occurrence.
6. Implement exactly one candidate solution above.
7. Re-run counters and prove the targeted repeated work disappeared.
8. Inspect errors from malformed headers and compare exact ordering/text.
9. Run focused, typecheck-stage, leak/sanitizer, and whole-compiler checks.

## Fast Feedback Loop

Use the existing typecheck benchmark infrastructure where possible:

```bash
BLORP_COMPILER_BENCHMARK_SKIP_BUILD=1 \
  benchmarks/compiler_typecheck_profile 5 1 16 256 fallback
```

If that fixture does not isolate headers, add a dedicated
`compiler_callable_header_profile` benchmark instead of overloading unrelated
inference controls. Suggested matrix:

```text
modules: 1, 8, 32
headers/module: 32, 128, 512
parameters/header: 0, 4, 16
dimension constraints/header: 0, 2, 8
```

Report valid header count, errors, conversions by category, installations,
checksum, allocations, and elapsed microseconds.

## Functional Tests

Primary suites include:

```bash
./blorp test --timeout 180 compiler/tests/test_compiler_callable_headers.brp
./blorp test --timeout 180 compiler/tests/test_compiler_implementation_headers.brp
./blorp test --timeout 180 compiler/tests/test_compiler_global_header_completion.brp
./blorp test --timeout 180 compiler/tests/test_compiler_type_header_dependencies.brp
scripts/compiler-check --stage typecheck
```

Retain or add cases for:

- zero/many parameters;
- generic bounds and inferred generic candidates;
- dimension constraints;
- source, foreign, builtin, and implementation methods;
- resource return and boundary policy;
- imported headers and diamond import graphs;
- duplicate/conflicting callable IDs;
- failed semantic-type conversion; and
- exact diagnostic order and help text.

## Acceptance Criteria

- A committed benchmark attributes the header registration sub-operations.
- The chosen optimization removes a measured repeat source; no speculative
  cache is added.
- Nominal identities, signature types, generic bounds, dimension constraints,
  and diagnostics remain unchanged.
- Focused call/conversion/allocation counts materially decrease.
- The implementation either reuses Issue 02's batch API or remains independent;
  it must not duplicate competing scope builders.
- Whole-compiler frontend time and allocation deltas are reported without
  presenting the inclusive 10.429% as guaranteed savings.

