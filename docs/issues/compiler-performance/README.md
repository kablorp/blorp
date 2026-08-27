# Compiler Self-Compilation Performance Issues

## Purpose

This directory turns the 2026-08-25 compiler self-compilation profile into
independent implementation issues. Each issue is intentionally self-contained
so it can be assigned without requiring access to the original profiling
session or prior discussion.

The issues are ordered by measured compiler-parent sample attribution, not by
implementation difficulty. The percentages overlap with inclusive call paths
elsewhere in the profile and must not be added together as projected savings.

## Profile Baseline

The profile compiled `compiler/src/stage_12_cli/main.brp` at revision
`c8d065e247899cc09a78692b5d7567e435a0c335` on an Apple M4 with 32 GiB RAM.
The target included 290 manifest-owned modules, 321,491 source lines, and
8,545,323 source bytes.

Production compiler source matched that revision. The profiling workspace also
contained an uncommitted Core-flatten benchmark harness and its focused test and
documentation updates. Those files did not change the production compiler
being measured; Issue 01 tells an implementer how to verify or recreate the
harness if it is absent from their checkout.

The production-shaped no-runtime run reported:

| Measurement | Result |
| --- | ---: |
| Frontend | 118.206 s |
| Backend | 62.340 s |
| Compiler phase total | 180.545 s |
| Wall time | 186.375 s |
| Allocations | 704,061,064 |
| Peak RSS | 2.218 GB |
| Generated C | 86.093 MB / 1,252,640 lines |

An externally sampled run collected 150,336 stack samples. Standard-library
and runtime work was attributed to the nearest compiler caller. This avoids
the built-in profiler's 16x whole-program slowdown and 1,024-entry limit.

The runtime leaves explain why these issues focus on high-level work removal:
ARC element release was 9.01% of samples, dictionary copy 7.58%, generic
release 4.87%, list access 4.04%, string equality 3.89%, and dictionary destroy
3.87%. Repeated scans and persistent collection updates create more leverage
than micro-optimizing allocation itself.

## Issue Inventory

| Order | Issue | Compiler-parent samples | Share | Approximate sampled time |
| ---: | --- | ---: | ---: | ---: |
| 1 | [Precompute callable purity-overload facts](01-precompute-callable-purity-overload-facts.md) | 14,869 | 9.891% | 18.02 s |
| 2 | [Batch scope symbol construction](02-batch-scope-symbol-construction.md) | 11,126 | 7.401% | 13.48 s |
| 3 | [Stop rebuilding UFCS names](03-cache-core-ufcs-names.md) | 10,221 | 6.799% | 12.39 s |
| 4 | [Remove projection-validation traversal churn](04-projection-validation-traversal.md) | 7,084 | 4.712% | 8.59 s |
| 5 | [Reduce callable-header registration work](05-callable-header-registration.md) | 6,132 | 4.079% exclusive | 7.43 s exclusive |
| 6 | [Batch closure function indexing](06-batch-closure-function-indexing.md) | 5,335 combined | 3.549% | 6.46 s |
| 7 | [Index managed-type membership](07-index-managed-type-membership.md) | 3,511 | 2.335% | 4.25 s |
| 8 | [Add direct scope lookup indexes](08-direct-scope-lookup-index.md) | 3,257 | 2.166% | 3.95 s |
| 9 | [Batch accepted-type registration](09-batch-accepted-type-registration.md) | 3,116 | 2.073% | 3.78 s |
| 10 | [Build call-resolution indexes once](10-build-call-resolution-indexes-once.md) | 2,976 | 1.980% | 3.61 s |
| 11 | [Add a direct definition-name index](11-direct-definition-name-index.md) | 2,734 | 1.819% | 3.31 s |
| 12 | [Avoid repeated C statement re-indentation](12-structured-c-indentation.md) | 2,056 | 1.368% | 2.49 s |

Approximate time is the sample share multiplied by the 182.203-second sampled
compiler phase total. It is an attribution ceiling, not a promised saving.

## Cross-Cutting Architecture Issues

The first twelve issues isolate individual sampled peaks. They cannot by
themselves produce a multi-fold compiler speedup because each peak is bounded
by Amdahl's law. The following issues target repeated work across complete
pipeline regions and therefore require fresh current-main measurement before
implementation:

- [Freeze frontend declarations once per typecheck graph](13-freeze-frontend-declaration-catalog.md)
  replaces repeated per-module installation of the reachable declaration
  closure with one accepted graph catalog plus module visibility projections.
- [Reduce whole-Core traversals and superlinear declaration queries](14-reduce-core-program-traversal-work.md)
  inventories complete Core pass work, removes nested linear declaration
  searches first, then addresses redundant validation, reconstruction, and
  compatible traversal fusion.

These are not additional rows in the sampled ranking. Their costs overlap many
callers and stages, so assigning one sample percentage would be misleading.

## Declaration Materialization Execution Sequence

Issue 13 is an architectural umbrella. Its implementation is decomposed into
nine ordered issues so measurement, bounded batching, representation work,
authority cutover, and deletion do not land as one unreviewable refactor.

| Order | Issue | Dependency | Scope |
| ---: | --- | --- | --- |
| 15 | [Measure scope materialization scaling](15-measure-scope-materialization-scaling.md) | None | Add exact counters, synthetic scaling fixtures, and a current production baseline. |
| 16 | [Generalize mixed-symbol batching](16-generalize-mixed-symbol-batching.md) | 15 | Replace repeated heterogeneous scope updates with one checked private batch primitive. |
| 17 | [Batch callable-header publication](17-batch-callable-header-publication.md) | 16 | Separate header preparation from deterministic publication and publish callable batches once. |
| 18 | [Batch imported-module publication](18-batch-imported-module-publication.md) | 17 | Prepare and publish one declaration plan per visible imported module. |
| 19 | [Build an accepted declaration catalog](19-build-accepted-declaration-catalog.md) | 15; informed by 16-18 | Construct and validate an opaque catalog without retaining it in production. |
| 20 | [Retain the catalog and build module views](20-retain-catalog-and-build-module-views.md) | 19 | Own one graph catalog and compact module visibility projections while legacy reads stay authoritative. |
| 21 | [Cut over types and constructors](21-cut-over-types-and-constructors-to-catalog.md) | 20 | Move one complete declaration category and delete its legacy graph storage. |
| 22 | [Cut over values, traits, and implementations](22-cut-over-values-traits-and-implementations.md) | 21 | Move the remaining graph declaration categories and leave `Env` lexical. |
| 23 | [Delete legacy materialization and reprofile](23-delete-legacy-declaration-materialization-and-reprofile.md) | 22 | Delete all migration remnants, enforce structural invariants, and measure the final compiler. |

Every row is intended to be a valid merge point. Issues 16-18 are worthwhile
only if their own measurements justify them; the catalog sequence must not use
them as an excuse to retain two publication systems. Issues 21 and 22 require
immediate category-specific deletion, and Issue 23 rejects any hidden fallback
or deferred correctness work.

## Rules For Every Issue

1. Establish a failing structural or performance assertion before changing
   production code. Functional tests alone do not prove less work is done.
2. Capture a current baseline on the same binary, host, workload, build mode,
   and iteration count used for the candidate.
3. Preserve deterministic diagnostics, identity assignment, declaration
   ordering, and ownership behavior. Faster incorrect compilation is not a
   result.
4. Prefer removing scans, copies, and intermediate collections over adding an
   unbounded cache.
5. Run the focused suite during iteration. Run the owning compiler stage and
   any named integration gates before completion.
6. Report before/after time, calls or visits, allocations when available,
   workload checksum, and functional test results. Do not claim an end-to-end
   percentage from one function's sampled ceiling.
7. Keep each issue independent. If implementation uncovers a representation
   redesign larger than the issue's proposed boundary, stop and document it
   rather than expanding scope silently.

## Whole-Compiler Verification

After a focused issue is complete, compare production-shaped compilation with:

```bash
BLORP_COMPILER_MEMORY_PROFILE=1 \
  compiler/_build/blorp-cli/blorp compile \
  --no-format --no-embed-runtime --time-phases \
  -o /tmp/blorp-self-profile.c \
  compiler/src/stage_12_cli/main.brp
```

Run this at least three times for a potentially noisy wall-clock comparison.
Delete `/tmp/blorp-self-profile.c` after measurement. A focused improvement is
acceptable even when whole-program timing noise obscures it, provided the
focused workload proves the targeted work was removed and no broader metric
regresses materially.
