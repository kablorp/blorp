# Index Resolved Import Adjacency By Module Ordinal

**Status:** Implemented and measured

**Dependencies:** Issues 46-49 must be complete or explicitly rejected. Start
from the immediate accepted baseline and reprofile module visibility before
editing.

**Blocks:** None. This is an independent resolved-graph product and must not be
used to justify Issue 51.

**Parallel work:** None in Stage 06 module binding, visibility, import closure,
or importable-module indexes.

## Objective

After source import paths have been resolved and validated, store import
dependency adjacency as module-local integer ordinals rather than repeatedly
looking up canonical path strings during closure traversal.

Keep path dictionaries for source-level import resolution, ambiguity,
diagnostics, and external queries. Only the already-resolved adjacency and its
internal traversal become ordinal-addressed.

## Required Reading

Read `AGENTS.md`, Issues 24, 45-49, and:

- `stage_04_modules` import resolution and loaded-module identity code;
- `stage_06_typecheck/modules/module_binding.brp`;
- `stage_06_typecheck/modules/module_visibility.brp`;
- `stage_06_typecheck/graph/indexed_graph.brp`;
- the frontend graph, module binding/visibility, import precedence, and LSP
  imported-definition/reference tests; and
- the compiler import-graph/profile fixtures.

## Current Behavior And Ceiling

`ImportableModuleIndexRep` already retains:

```blorp
modules: List[ImportableModule]
modules_by_path: Dict[String, ImportableModule]
module_ordinals_by_path: Dict[String, Int]
candidate_paths_by_request: Dict[String, List[String]]
dependency_paths_by_path: Dict[String, List[String]]
```

Construction resolves every parsed import into canonical paths, then stores a
path-keyed path list. `importable_module_dependency_closure` later maintains a
string queue/set and performs `dependency_paths_by_path` lookups for each
visited module before mapping paths back through `module_ordinals_by_path`.

The historical broad profile observed about 34,000 dependency-path reads and
roughly 53 ms of instrumented dependency-closure function time. This is a
smaller ceiling than Issues 48 and 49. Reprofile first; do not implement if the
current compiler no longer has a measurable module-visibility share.

Each `ImportableModuleIndex` owns its own ordinal universe. The dependency-only
index and all-modules index must never exchange bare ordinals.

## Proposed Representation

Conceptually:

```blorp
private record ImportableModuleIndexRep {
	modules: List[ImportableModule],
	modules_by_path: Dict[String, ImportableModule],
	module_ordinals_by_path: Dict[String, Int],
	candidate_paths_by_request: Dict[String, List[String]],
	dependency_ordinals_by_module: List[List[Int]],
	prelude_path: Option[String]
}
```

The final name may differ, but the ownership must remain inside the opaque
index. Build exactly one adjacency slot for every module, including an empty
list for modules without imports. Resolve source paths once during
construction, preserve first-seen source order, and deduplicate exactly as the
current implementation does.

Adjacency preserves each module's accepted-import order. Closure discovery
remains breadth-first, but the public result is currently normalized by
`ImportableModuleIndex.modules` ordinal in
`importable_module_index_modules_for_paths`. The candidate must preserve both
invariants separately: edge order is accepted-import order, while returned
module order is index order.

## Implementation Plan

### 1. Pin path-resolution and closure behavior

Write failing structural/behavior tests before changing storage. Cover exact
path wins, request aliases, ambiguity sorting, duplicate imports, private
import blocks, self-import exclusion, prelude/ambient module injection, missing
imports, origin conflicts, accepted-import edge order, and module-index-ordered
closure output.

### 2. Build adjacency after path resolution

Keep `modules_by_path`, `module_ordinals_by_path`, and
`candidate_paths_by_request` unchanged while parsing/resolving imports. Convert
each accepted canonical dependency path to an ordinal in the same index. A
missing ordinal is an internal construction failure, not an empty edge.

Build adjacency by append in module order or one final map. Do not repeatedly
grow an arbitrary persistent outer list if generated C shows full-list copies.

### 3. Traverse only local ordinals

Change dependency closure to hold ordinals internally. Keep the current output
type and order. The current-module exclusion must compare the resolved local
ordinal when available while preserving the exact external/path behavior for
requests that are not members of the index.

### 4. Delete the old adjacency

Remove `dependency_paths_by_path` and its lookup helper after all internal
readers migrate. Do not retain path and ordinal mirrors. Temporary counters may
observe both matched strategies but must be removed from production.

## Non-Goals

- Do not change Stage 4 resolution, canonical paths, origins, request aliases,
  import syntax, ambiguity, precedence, or diagnostics.
- Do not remove `modules_by_path`, `module_ordinals_by_path`, or
  `candidate_paths_by_request`; they serve real path-resolution boundaries.
- Do not expose module ordinals or combine dependency/all-index universes.
- Do not alter `ModuleView`, `Env`, declaration authorities, nominal IDs, or
  LSP semantic identity.
- Do not retain mutable adjacency or add caching.

## TDD Plan

Required fixtures:

1. no imports and one explicit empty adjacency slot;
2. singleton edge;
3. chain closure order;
4. star/fan-out accepted-import edge order and module-index result order;
5. layered/diamond deduplication;
6. dense graph exact edge and closure counts;
7. duplicate import declarations remain one dependency;
8. private and public import blocks behave identically for dependency reach;
9. exact path versus alias selection and deterministic ambiguity diagnostics;
10. self-import/current-module exclusion;
11. prelude and ambient tuple implementation behavior;
12. user/stdlib/source-package/native origins remain distinct; and
13. a parsed-error/recovery module owns an explicit empty adjacency slot and no
    outgoing closure edges, including when source text contained an import
    before the parse error; and
14. LSP imported definition/reference behavior is unchanged.

Derive expected adjacency and closure from fixture edges, not from the
production traversal under test.

## Measurement Plan

Measure matched path and ordinal strategies through the actual production
index and closure functions. Keep semantic, modeled, exact-function, and cost
evidence separate.

Matrix:

```text
modules:       1, 8, 32, 128, 256
topology:      empty, chain, star, layered/diamond, dense
imports/node:  0, 1, 4, 16, all
root count:    1, 4, 16
origin mix:    user-only, mixed supported origins
```

Generate only valid combinations: `root_count <= modules`, and cap concrete
imports per node at `modules - 1`; `all` means every other eligible module.
Record requested and effective values separately rather than silently
normalizing them.

Record resolved edge count, deduped edge count, queue visits, set probes,
path-dictionary reads, ordinal-list reads, module projections, checksum,
diagnostics, elapsed, allocations, releases, retained objects/bytes, retired
instructions, cycles, and RSS.

Pair/alternate strategies per configuration. Warm both workers and run at
least three measured pairs for each 128-module sentinel. Require exact semantic
equality. Run production replay only if the largest representative closure
meets the focused acceptance threshold and the current production profile
confirms the path is exercised.

## Fast Feedback

1. Run module binding/visibility tests after every representation change.
2. Run untimed 8-module chain, diamond, and dense rows.
3. Confirm adjacency/closure checksums before collecting timing.
4. Inspect generated C for one outer adjacency allocation, integer set keys,
   direct list reads, and no path-key construction in closure.
5. Run a 128-module dense sentinel and compare allocations/instructions.
6. Stop before broad gates if the sentinel improves neither metric by 10%.
7. If green, run changed checks, LSP imported-navigation tests, then request a
   clean timing slot for the matrix and production replay.
8. Obtain code-reviewer, test-runner, and code-optimizer approval.

## Implemented Boundary

`ImportableModuleIndexRep` now retains one private
`List[List[Int]]` adjacency in module-index order. Construction still uses the
existing canonical-path and request-alias dictionaries to resolve source
imports. Each accepted canonical dependency is converted to an ordinal in the
same index, deduplicated in first-seen order, and appended to that module's
slot. A missing ordinal makes the private adjacency invalid and closure fails
closed; it is never represented as a sentinel ordinal or silently omitted.

`importable_module_index_dependency_closure` is the narrow semantic boundary
between module binding and visibility. Its arguments and result remain opaque
`ImportableModule` values. It resolves root paths and the optional current
module path once, then queues, deduplicates, and traverses only local `Int`
ordinals. Result projection performs checked reads and preserves the existing
module-index ordering. No ordinal crosses an index or enters a public compiler
identity.

The old `dependency_paths_by_path` field and dependency-path lookup helper are
removed. Path dictionaries used by source import resolution, aliases,
ambiguity handling, and external queries remain unchanged.

## Measurement Results

The baseline was commit `40d8dfb8`. Baseline and initially measured candidate
optimized compiler SHA-256 values were respectively
`13eda31652b9df5191555b1ae260b2659a71ce6633fce1ac28010a18d491c639`
and
`23da6a7434a1089a923caaf2af597a50f2e286ebe5a15372b7a0633f468f5763`.
The final candidate used by the refreshed matrix had SHA-256
`f40d0b63fa1657edf0fe5a9b7f84b20d80ee691185959305c3cc4932373a1c35`.
The shared fixture and runner source hashes were
`379cf25b4d1d58cce56c606e97f530d184492b55c4dec6e037378370e111fcc6`
and
`4b59b33a7c6f47e937557937fdde8311c4f85268d509cb930673b4eeadfbdf38`.

### Focused scaling

The full matrix contained 600 alternating baseline/candidate pairs and all
1,200 rows had `errors=0` and `workload_valid=True`. Every pair had identical
modules, requested/effective imports, roots, fixture-modeled resolved edges,
modeled queue and adjacency reads, visible modules, and checksum. The edge
count is derived from the independent topology generator, not exposed private
index contents; exact production evidence comes from function instrumentation.
Raw rows and the deterministic summary are under
`logs/issue50/matrix-v3-final/full-20260904/`.

| Dimension | Pairs | Allocation delta | Elapsed delta |
| --- | ---: | ---: | ---: |
| all rows | 600 | -95.09% | -59.08% |
| empty | 120 | -75.60% | -56.66% |
| chain | 120 | -96.11% | -70.56% |
| star | 120 | -91.44% | -67.91% |
| layered | 120 | -96.11% | -59.80% |
| dense | 120 | -96.11% | -53.71% |
| 1 module | 50 | -46.08% | -38.24% |
| 8 modules | 100 | -75.00% | -58.44% |
| 32 modules | 150 | -88.21% | -61.97% |
| 128 modules | 150 | -95.36% | -61.11% |
| 256 modules | 150 | -97.26% | -58.24% |

The required 128-module sentinels used 1,000 closure iterations and three
alternating pairs. Allocations were deterministic at 531,129 baseline and
18,129 candidate in both workloads (`-96.59%`). Chain median elapsed fell from
38,323 to 11,522 microseconds (`-69.94%`); dense median elapsed fell from
210,865 to 119,955 microseconds (`-43.11%`). Checksums were identical in every
pair. The chain and dense raw logs are under
`logs/issue50/focused-sentinel/`.

### Exact production function evidence

A fresh baseline and candidate function profile compiled and checked
`blorp/src/main.brp`. Compiler output SHA-256 was identical at
`c1758b804e292be62860bce968c8cee14b4b6a8fec681ff19c5318e5195c0963`.
The closure remained represented by 607 production invocations.

| Function boundary | Baseline | Candidate |
| --- | ---: | ---: |
| visibility closure | 607 calls / 73.273 ms | 607 calls / 32.689 ms |
| dependency-path lookup | 34,894 calls / 13.204 ms | not emitted |
| path-to-module projection | 1,214 calls / 34.914 ms | 607 calls / 9.344 ms |
| ordinal closure implementation | not present | 607 calls / 29.985 ms |

Instrumented wrapper time fell 55.39%. Function-profile time is inclusive and
perturbative; call retirement, not its absolute elapsed value, is the exact
production fact. Raw profiles are under
`logs/issue50/{preaudit-production,function-profile/}`.

### Production replay

The replay reused the 11,401,074-byte compiler-main capture with SHA-256
`7e97872920905caa554e408a558c4cbb6f188f06a95493658fd6c0314ce97ab2`.
Baseline and candidate worker hashes were
`68becbc4c23d5804a355b00e3a66cf6993762b550ef7adb54dee75b11952807a`
and
`7dbdce8ea6bf7a23758f09c5693fa9fed2a862aeb76e6165e89e40f6797ed295`.
After one warmup per worker, all three alternating pairs were verified, had
allocator statistics, did not time out, and produced exactly 807,215,979
response bytes with SHA-256
`0ce3eacc184042580b6999a39dc7b7d58f6d67a74680657c498aacfcaa9f9f79`.

The graph-preparation interval, which contains the changed visibility work,
fell from 107,991,709 to 107,851,566 allocations (`-0.130%`) and from
97,746,563 to 97,606,420 releases (`-0.143%`) in every pair. The later body
typecheck interval was unchanged at 93,922 allocations and 83,400 releases.
Final replay allocations fell 140,143 (`-0.030%`), retained objects were
identical, and median peak RSS fell from 908,115,968 to 907,591,680 bytes
(`-0.058%`). Elapsed samples were noisy: baseline ranged 63.537-84.907 seconds
with median 79.066; candidate ranged 68.481-94.695 seconds with median 70.273.
The deterministic allocation delta, rather than elapsed time, clears the
production checkpoint gate. Raw JSON is under
`logs/issue50/replay/runs-20260904/`.

### Whole compiler and generated C

Three optimized alternating `blorp check --no-format blorp/src/main.brp`
pairs produced byte-identical output. Median retired instructions fell from
316,307,374,774 to 316,264,136,153 (`-0.0137%`). Median elapsed moved from
17.98 to 18.03 seconds (`+0.28%`), and median RSS moved from 880,312,320 to
880,246,784 bytes (`-0.007%`). These pass the predeclared whole-compiler
regression limits but are too small for a compiler-wide speedup claim.

Final generated C SHA-256
`14d8d9213e28123ffb7b2a75e23781a4c038cd43e7c0ec5948abf954f6802055`
contains one ordinal adjacency field, integer queue/set operations, checked
integer adjacency reads, and the final checked module projection. The only
canonical path reads in closure are root/current-module path-to-ordinal
resolution before traversal; the traversal loop contains no dependency-path
dictionary or path-key construction. It also contains no capturing closure in
this function; a final review replaced the candidate's `Option.and_then` with
a direct match. Extracts are retained under
`logs/issue50/generated-c-final/`.

The production replay, function profile, whole-compiler pairs, and three-pair
sentinels preceded that final allocation cleanup and were not rerun. They
therefore include one extra candidate allocation per dependency-closure call
and are conservative for cost. The final 600-pair matrix, generated C, focused
120/120 declaration suite, and 3/3 benchmark suite were refreshed after the
cleanup. The cleanup changes no branch result or identity semantics; its
unrefreshed production artifact hashes remain explicitly identified above.

## Limitations And Recommendation

This is a low-level visibility win, not a compiler-wide acceleration. Canonical
strings remain the correct representation at source resolution, diagnostic,
alias, and external identity boundaries. Closure still sorts reached ordinals
to preserve existing module-index result order. The focused benchmark measures
closure after graph setup; production replay includes setup and all compiler
work and therefore shows the much smaller realized share.

Keep the ordinal adjacency candidate. It removes exact repeated production
work, clears the focused and graph-preparation allocation gates, preserves all
semantic and whole-compiler limits, and does not expand public identity or
cache state. It provides no evidence for Issue 51, which remains independently
scoped.

## Acceptance Criteria

- Every semantic edge, closure order, diagnostic, and checksum is identical.
- Closure performs zero `dependency_paths_by_path` reads and zero canonical
  path-key constructions after root resolution.
- Adjacency has exactly one local slot per module and never crosses index
  provenance.
- The 128-module representative chain and dense sentinels reduce focused
  retired instructions or allocations by at least 20%. No topology group may
  regress both median allocations and retired instructions by more than 5%.
- The production module-visibility checkpoint reduces allocations/releases by
  at least 0.10% or median retired instructions by at least 0.05%.
- Whole-compiler retired instructions do not regress by more than 0.05%, median
  elapsed does not regress by more than 1.0%, and median peak RSS does not
  regress by more than 0.5%.
- Production responses and LSP imported-navigation results are byte-identical.
- Generated C contains integer adjacency reads and no duplicate path adjacency.
- The old representation, strategy switches, and diagnostic APIs are removed.
- All required reviews approve.

If the production share or ratchet is too small, reject the candidate. The
existing path representation is coherent and should not be replaced for
aesthetic reasons.
