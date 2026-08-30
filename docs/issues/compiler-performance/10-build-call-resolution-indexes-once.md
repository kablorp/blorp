# Build Core Call-Resolution Indexes Once

**Status:** Implemented; focused timing complete, broad validation pending

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

Primary file: `blorp/src/compiler/stage_09_core/resolve.brp`.

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

## Consumer and Ordering Inventory

The implementation must preserve these `CoreCallResolveEnv` contracts:

| Field | Consumers and ordering contract |
| --- | --- |
| `user_functions` | Bare and prefixed user-call lookup uses dictionary overwrite behavior; later declarations with the same emitted name remain the visible name-based target. |
| `user_functions_by_id` | Selected-call lookup by `def_id` keeps the first target inserted for an ID. Later duplicate IDs must not replace it. |
| `colliding_user_function_ids` | Selected-call lookup rejects any colliding ID. Set iteration order is not observable. |
| `module_functions` | Module-qualified call lookup uses `module_path + "\n" + source_name` as the exact key. Later declarations with the same key keep current overwrite behavior. |
| `global_types` | Imported/qualified global-value recognition uses dictionary lookup by lowered global name. Later same-name globals keep current overwrite behavior. |
| `foreign_functions` | Bare, imported, and qualified foreign calls retain exact C symbol and argument-passing metadata. |
| `builtin_functions` | Bare and module-qualified builtin resolution retains the runtime name selected during environment construction. Builtin lookup still precedes user/module fallback where it did before. |
| `constructors` | Constructor resolution scans the candidate list for a name. Candidate list order remains declaration order so ambiguity behavior is unchanged. |
| `import_bindings` | Target-module imports use an indexed local-name lookup. Duplicate local imports retain existing last-binding-wins behavior from `import_index`. |
| `module_imports` | Per-module imports use the same local-name index as target imports. Duplicate module entries retain existing module-name overwrite behavior. |
| `module_paths` | Explicit UFCS lookup iterates module paths. The ordered projection must remain first-seen order across module imports, target imports, and source-module declarations. |

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
./blorp test --timeout 180 blorp/test/compiler/stage_09_core/test_core_resolve.brp
./blorp test --timeout 180 blorp/test/compiler/pipeline/test_core_function_refs.brp
./blorp test --timeout 180 blorp/test/compiler/stage_09_core/test_core_backend_projection.brp
./blorp test --timeout 180 blorp/test/compiler/pipeline/test_core_closure_identity.brp
scripts/compiler-check --stage core
scripts/test compiler-core-sanitize
blorp/test/compiler/pipeline/codegen_audit/run_codegen_audit.sh ./blorp
```

Cover source functions, module functions, aliases, builtin forwarding, foreign
metadata, globals, enum/union constructors, implementation methods, unresolved
generic impls, duplicate names, duplicate IDs, ambiguous calls, and imports.

## Implementation Results

Implementation date: 2026-08-26.

The final candidate keeps `CoreCallResolveEnv` private, replaces construction
through whole-record helper returns with local component accumulators, and uses
a `Set[String]` for module-path membership while retaining the ordered
first-seen `module_paths` list for consumers. Production resolution still calls
the private `collect_call_resolve_env` builder directly.

A diagnostic-only `observe_core_call_resolve_env` hook was added for benchmark
and invariant tests. The hook calls the same private builder used by production
and returns only primitive index counts plus a compact ordered module-path
checksum; it does not expose `CoreCallResolveEnv` or its component collections.
Semantic equivalence for call targets, ambiguity, foreign metadata, and type
behavior stays covered by focused resolver behavior tests instead of recursive
diagnostic serialization in `resolve.brp`.

Focused fixture guard after diagnostic-surface reduction:

```text
declarations=22 user_functions=11 user_functions_by_id=11 colliding_user_function_ids=1
module_functions=8 globals=2 foreign_functions=2 builtin_functions=5
constructor_names=3 constructor_targets=6 import_bindings=4 module_imports=2
module_import_bindings=4 module_paths=8 module_path_membership_checks=16
module_path_order_checksum=6701649995124992104 workload_valid=True
```

Allocation guard fixture cap:

```text
declarations=556 module_paths=162 module_path_membership_checks=674
total_allocations <= 13600 workload_valid=True
```

Clean timing window, same harness, five alternating legacy/candidate pairs:

```text
./blorp run --no-format compiler/benchmarks/compiler_core_call_resolve_profile.brp -- 20 2048 16 4 64 4
```

Timing caveat: these samples were recorded before reducing the diagnostic
snapshot from full recursive metadata checksums to count-only observation. The
private `collect_call_resolve_env` construction path measured in legacy and
candidate states was unchanged; the final committed diagnostic hook does less
post-construction observation work and no longer emits `index_checksum`,
`module_path_checksum`, or `constructor_checksum`.

| State | elapsed microseconds | Median | Allocations |
| --- | --- | ---: | ---: |
| Legacy whole-record builder | 2129393, 2215531, 2103324, 2112085, 2170259 | 2129393 | 1237561 |
| Local accumulator builder | 269024, 262525, 268364, 271339, 269681 | 269024 | 1031761 |

Every timing sample reported:

```text
declarations=2076 user_functions=2051 user_functions_by_id=2021
colliding_user_function_ids=31 module_functions=2048 globals=16
foreign_functions=2 builtin_functions=5 constructor_names=4
constructor_targets=8 import_bindings=64 module_imports=16
module_import_bindings=64 module_paths=82
module_path_membership_checks=2130 workload_valid=True
checksum=8546454913731665232
index_checksum=-6029037680111759804
module_path_checksum=-5159956429227091153
constructor_checksum=-7023100518823174182
```

Median construction-window result: 7.9x faster, 87.4% lower elapsed time, and
205800 fewer total allocations per 20 constructions, or 10290 fewer
allocations per construction.

Focused validation passed:

```text
./blorp test --timeout 180 blorp/test/compiler/stage_09_core/test_core_call_resolve_profile_benchmark.brp
./blorp format blorp/src/compiler/stage_09_core/resolve.brp compiler/benchmarks/compiler_core_call_resolve_profile_fixture.brp compiler/benchmarks/compiler_core_call_resolve_profile.brp blorp/test/compiler/stage_09_core/test_core_call_resolve_profile_benchmark.brp
git diff --check
```

The focused benchmark suite passed 2/2 after diagnostic-surface reduction and
formatting. `git diff --check` passed. The ownership manifest JSON parses and
the new Issue 10 suite mapping is internally consistent.

`make` passed before the diagnostic-surface reduction; it was not rerun after
the final reduction because coordination requested no broad gates or extra
timing.

Manifest validation caveat:

```text
scripts/compiler-check --validate-manifest
error: unowned production compiler module: blorp/src/compiler/stage_12_cli/typecheck_capture.brp
```

That tracked stage 12 ownership gap is outside this issue's diff.

Broader Core resolve, sanitizer, codegen audit, and full
`scripts/compiler-check --stage core` gates remain intentionally pending per
coordination instructions.

## Acceptance Criteria

- `collect_call_resolve_env` constructs the aggregate environment once.
- Module-path membership no longer uses repeated `List.contains` scans.
- Every logical index and resolution result matches the baseline fixtures.
- Focused construction allocations and elapsed time improve materially at
  2,048+ declarations.
- Collision and ambiguity behavior remains fail closed and deterministic.
- No cross-pass cache or name-prefix heuristic is introduced.
- Core resolve, sanitizer, and codegen audit gates pass.
