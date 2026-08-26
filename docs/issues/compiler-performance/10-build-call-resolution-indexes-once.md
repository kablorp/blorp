# Build Core Call-Resolution Indexes Once

**Status:** Ready for measurement and bounded refactor

## Issue Summary

Construct `CoreCallResolveEnv` from local index components and a true module-path
membership set, then produce the immutable environment once. Avoid repeatedly
replacing an eleven-field record while walking every Core declaration.

This issue does not change call resolution rules. It changes the construction
cost of the indexes those rules already require.

## Profile Evidence

The compiler self-compilation baseline took 180.545 seconds, performed 704.1
million allocations, and reached 2.218 GB peak RSS. External sampling attributed
2,976 samples, 1.980% and about 3.61 seconds, to
`resolve.collect_call_resolve_env` and direct library/runtime work.

Stage 09 Core accounted for 34.983% of all attributed samples. This constructor
is a bounded opportunity inside that larger stage: it walks every declaration,
updates several dictionaries and sets, and repeatedly checks module-path
membership in a list.

## Current Representation

Primary file: `compiler/src/stage_09_core/resolve.brp`.

`CoreCallResolveEnv` stores eleven fields:

- user functions by name and by ID;
- colliding user function IDs;
- module functions;
- globals;
- foreign and builtin functions;
- constructors;
- import bindings and module imports; and
- module paths as `List[String]`.

`collect_call_resolve_env` begins with an empty record, walks declarations, and
calls helpers such as `remember_function`, `remember_user_function`,
`remember_module_function`, `remember_constructor`, and
`remember_module_path`. Those helpers return updated copies of the aggregate
record. Module-path insertion repeatedly uses `List.contains`.

## Problem Statement

All call-resolution facts are collected in one setup pass, but the API models
collection as persistent replacement of the complete environment. This creates
avoidable record, dictionary, list, equality, and ARC work. Module path
deduplication is also linear in the number of paths.

## Goals

1. Build each index component with a local accumulator and construct the final
   environment once.
2. Use indexed membership for module-path deduplication while preserving any
   required deterministic ordered projection.
3. Preserve every collision, ambiguity, import, constructor, builtin, foreign,
   and implementation-method rule.
4. Demonstrate lower construction allocations and near-linear scaling.

## Non-Goals

- Do not change `CoreCallKind` or callable identity representation.
- Do not alter call resolution precedence.
- Do not discard collision tracking.
- Do not infer categories from name prefixes.
- Do not merge call resolution with DCE, closure, or backend projection.
- Do not add a process-global resolution cache.

## Proposed Design

Introduce a private builder representation only if it makes ownership and field
updates clearer. It can be a record of component collections, but avoid
returning it after every declaration. The simplest implementation keeps local
variables in `collect_call_resolve_env` and uses narrow helpers that update or
return only the affected component.

For module paths, maintain:

```blorp
var module_path_set: Set[String] = ...
var module_paths: List[String] = ...
```

Add to the ordered list only when insertion into the set is new. If no consumer
requires order, remove the list only after proving that with `rg` and tests.

Where a helper currently needs the whole environment but changes only two
fields, refactor it to return a small explicit result or inline it at the sole
construction call site. Do not hide whole-record copying behind a renamed
helper.

## Mechanical Implementation Sequence

1. Inventory every `CoreCallResolveEnv` field consumer and document whether
   iteration order matters.
2. Add a synthetic-program benchmark with configurable functions, modules,
   constructors, implementation methods, duplicate IDs, and imports.
3. Add fixture assertions/checksums for all eleven logical indexes.
4. Replace module-path list membership with a set plus ordered list if needed.
5. Refactor one helper family at a time to update component accumulators.
6. Construct `CoreCallResolveEnv` once after declaration traversal.
7. Remove helpers that only wrapped whole-record updates and now have no useful
   policy role.
8. Compare exact resolution results and ambiguity behavior.
9. Run Core resolve, call-target, sanitizer, codegen, and whole-compiler checks.

## Required Invariants

- The first non-colliding function remains available by ID.
- A repeated function ID is recorded as colliding and never silently resolved.
- Name-based user functions retain current overwrite/precedence behavior.
- Module function keys include the same module/source information as before.
- Builtin runtime names and foreign argument-passing metadata remain exact.
- Constructor candidate lists retain deterministic declaration order.
- Generic implementation methods with unresolved parameters remain excluded.
- Import binding precedence and module imports remain unchanged.
- Ordered module paths, if observable, remain first-seen order.
- Dictionary/set iteration order must not affect diagnostics or output.

## Fast Feedback Loop

Add a benchmark matrix such as:

```text
declarations: 128, 512, 2,048, 8,192
modules: 1, 16, 128
constructors/type: 0, 4, 32
duplicate-ID interval: never, 64, 8
imports/module: 0, 4, 32
```

Report counts/checksums for every index, module-path membership operations,
collisions, elapsed microseconds, and allocations. Separate fixture creation
from measured index construction.

## Functional Tests

Run:

```bash
./blorp test --timeout 180 compiler/tests/test_compiler_core_resolve.brp
./blorp test --timeout 180 compiler/tests/test_compiler_core_function_refs.brp
./blorp test --timeout 180 compiler/tests/test_compiler_core_backend_projection.brp
./blorp test --timeout 180 compiler/tests/test_compiler_core_closure_identity.brp
scripts/compiler-check --stage core
scripts/test compiler-core-sanitize
tests/test_compiler/codegen_audit/run_codegen_audit.sh ./blorp
```

Cover source functions, module functions, aliases, builtin forwarding, foreign
metadata, globals, enum/union constructors, implementation methods, unresolved
generic impls, duplicate names, duplicate IDs, ambiguous calls, and imports.

## Acceptance Criteria

- `collect_call_resolve_env` constructs the aggregate environment once.
- Module-path membership no longer uses repeated `List.contains` scans.
- Every logical index and resolution result matches the baseline fixtures.
- Focused construction allocations and elapsed time improve materially at
  2,048+ declarations.
- Collision and ambiguity behavior remains fail closed and deterministic.
- No cross-pass cache or name-prefix heuristic is introduced.
- Core resolve, sanitizer, and codegen audit gates pass.
