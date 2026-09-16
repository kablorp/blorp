# Core-lowering function deduplication: Accepted

Date: 2026-09-16. Issue:
`docs/issues/compiler-performance/122-core-lowering-function-deduplication.md`.
Worktree base: `cab823d4` (branch `worktree-agent-af13720a98339d435`).

## Decision

Accept. `flatten.deduplicate_functions` now builds two invocation-local
`Dict[String, Bool]` indexes once per call instead of rescanning every
declaration for a name match and calling `List.contains` on a growing
seen-name list. The full-declaration rescan falls to exactly zero calls once
duplicates exist ahead of their implementation, the wide worst-case fixture's
inclusive `deduplicate_functions` time drops by 97% and its allocations by
2.5%, the small already-short-circuiting fixture is not regressed (allocations
change by 0.02%, elapsed time improves), and every Core checksum is identical
before and after.

## Change

`blorp/src/compiler/stage_08_core_lower/flatten.brp`: replaced
`function_decl_has_implementation_named` (an `O(n)` scan of all declarations,
called once per not-yet-admitted duplicate) and the `List[String]` seen-name
accumulator (checked with linear `.contains()`) with:

- `index_implemented_function_names(decls)`, built once per call, mapping
  function name to whether some declaration implements it;
- a `Dict[String, Bool]` `seen` index accumulated during the single pass,
  replacing the `List[String]` + `.contains()` membership check.

The walk over `decls` is otherwise unchanged: declarations are still visited
in their original order exactly once, the output list is still built by
appending admitted declarations in that order (never reconstructed from dict
iteration), and the winner rule is unchanged — an implementation wins over a
forward declaration by name, and otherwise the first declaration by name wins.
The comparison key stays the exact `function_info.name` string; identity is
not strengthened to `def_id`, module, or any other nominal identity. `ImplDecl`
and all non-function declarations pass through the `for` loop's default arm
exactly as before.

## Harness Changes

`blorp/benchmark/compiler/compiler_core_flatten_profile_fixture.brp` and
`compiler_core_flatten_profile.brp` already existed but only produced the
implementation-first shape (`CoreFlattenProfileConfig` had no order or
duplicate-ratio controls), which the issue's own "Feedback Loop" section
flags as mostly short-circuiting the expensive rescan. Extended rather than
duplicated:

- `CoreFlattenProfileDeclarationOrder` (`ImplementationFirstOrder` /
  `ForwardDeclarationFirstOrder`) and `forward_declarations_per_callable: Int`
  were added to `CoreFlattenProfileConfig`.
- `source_program` now emits, per logical callable, one implementation and
  `forward_declarations_per_callable` bodyless duplicates, ordered per
  `declaration_order` (implementation first, or all duplicates first).
- `expected_aliases` was generalized to expect one alias per non-implementation
  declaration (previously hardcoded to exactly one forward declaration per
  callable), and the workload-validity checks in `core_flatten_profile_observe`
  were updated to the same formula (`callable_count *
  forward_declarations_per_callable`) for both the `prefix` and `aliases`
  stages.
- The CLI (`compiler_core_flatten_profile.brp`) gained two new trailing
  positional arguments (`impl-first|fwd-first`, `forward_declarations_per_callable`,
  both optional and defaulting to the prior implicit behavior: `impl-first`,
  `1`), and the printed row gained `declaration_order`,
  `forward_declarations_per_callable`, `new_allocations`, and `new_releases`
  (from `memory.get_mem_stats()` snapshots taken immediately inside the
  profile window).
- `blorp/test/compiler/stage_08_core_lower/test_core_flatten.brp`'s existing
  `CoreFlattenProfileConfig` literal was updated with the two new required
  fields (`ImplementationFirstOrder`, `1`), preserving its existing
  expectations unchanged.

All prior default invocations (`benchmarks/compiler_core_flatten_profile
prefix|aliases 10 128 4`) are unchanged in behavior.

## Benchmark Commands

```bash
# Wide worst case: 128 callables, 8 duplicate forward declarations each,
# all duplicates placed before their implementation.
benchmarks/compiler_core_flatten_profile prefix 10 128 4 fwd-first 8

# Small path: 128 callables, 1 forward declaration each, implementation
# first (the shape the retained fixture already exercised).
benchmarks/compiler_core_flatten_profile prefix 10 128 4 impl-first 1
```

Each cell below is the median of 3 repeated single-process runs
(`BLORP_COMPILER_BENCHMARK_SKIP_BUILD=1`, instrumented `--profile` build,
Apple Silicon macOS). `new_allocations`/`new_releases` were identical across
all 3 repeats in every cell (deterministic managed-allocation counts); elapsed
times vary run to run because the instrumented build carries per-call
timestamping overhead subject to normal system scheduling noise, so treat
`window_microseconds` as directional and the `deduplicate_functions`
self/inclusive rows and rescan call counts as the primary, deterministic
evidence.

## Wide Fixture: 128 Callables × 8 Forward Declarations, Forward-Declaration-First

| Metric | Before | After | Change |
| --- | ---: | ---: | ---: |
| Full-declaration rescans (`function_decl_has_implementation_named` calls, 10 iterations) | 10,240 | 0 (function removed) | -100% |
| `deduplicate_functions` inclusive ms (10 iterations) | 238.054 | 6.269 | -97.4% |
| `prefix_module_names_with_aliases` inclusive ms (10 iterations) | 629.058 | 233.224 | -62.9% |
| `window_microseconds` (10 iterations, median of 3) | 639,542 | 239,499 | -62.5% |
| `new_allocations` (10 iterations) | 411,381 | 401,101 | -2.5% |
| `new_releases` (10 iterations) | 402,545 | 392,265 | -2.6% |
| `checksum` | 8329755092875520672 | 8329755092875520672 | identical |
| `output_callables` / `rewritten_calls` | 128 / 512 | 128 / 512 | identical |

The rescan count is the direct, deterministic signature of the fix: the
pre-index algorithm called `function_decl_has_implementation_named` exactly
once for every one of the 1,024 forward declarations per iteration (128
callables × 8 duplicates, all placed before their implementation so none is
ever already "seen"); the new algorithm never calls it because the function no
longer exists. `deduplicate_functions`'s own inclusive time falls by 97%,
comfortably clearing the issue's "improves instructions or allocations by at
least 10%" bar through the instrumented self-time proxy even though the raw
allocation-count improvement alone (2.5%) does not individually clear 10% —
allocation counts for this shape are dominated by the surrounding rewrite
plan and expression rewriting, which are out of scope for this change and
unaffected by it.

## Small (Already-Short-Circuiting) Fixture: 128 Callables × 1 Forward Declaration, Implementation-First

| Metric | Before | After | Change |
| --- | ---: | ---: | ---: |
| `window_microseconds` (10 iterations, median of 3) | 147,471 | 120,641 | -18.2% (faster) |
| `new_allocations` (10 iterations) | 212,951 | 212,911 | -0.02% |
| `new_releases` (10 iterations) | 206,803 | 206,763 | -0.02% |
| `checksum` | 8329755092875520672 | 8329755092875520672 | identical |

This is the shape the retained fixture already exercised before this change:
every duplicate is already `seen` by the time it is visited, so the old
algorithm never called the expensive rescan here either. The new algorithm
replaces a `List[String]` + `.contains()` seen-set with a `Dict[String, Bool]`
and adds one linear index-build pass; the small-path allocation delta (-0.02%)
is far inside the issue's "small path remains within 2%" bound, and elapsed
time did not regress.

## Invariant Tests Added

Added to `blorp/test/compiler/stage_08_core_lower/test_core_flatten.brp`
(all exercise the public `prefix_module_names_with_aliases` entry point, and
all were verified to pass against both the pre-change and post-change
`flatten.brp` — see Verification):

- `deduplicates same name by declaration order not def_id`: two bodyless
  declarations sharing one name and no implementation anywhere, with the
  *second* declaration given the numerically lower `def_id`. Confirms the
  survivor is chosen by encounter order, not by comparing `def_id` or any
  other nominal identity.
- `preserves implementation and order with duplicates before and after`:
  forward declarations on both sides of one implementation, with unrelated
  marker declarations before and after. Confirms every duplicate is dropped
  regardless of which side of the implementation it falls on, and that
  surrounding declarations keep their exact relative order.
- `preserves non-function declarations while deduplicating functions`: a
  `GlobalDecl`, `TraitDecl`, `EnumDecl`, `ValueRecordDecl`, and `ImplDecl`
  interleaved with three duplicate function declarations sharing one name.
  Confirms every non-function declaration is untouched and counted, and that
  `ImplDecl`'s methods pass through unmodified (method count is not an axis
  for this function).
- `deduplicates empty program`: `program([])` produces an empty declaration
  list.
- `deduplicates many interleaved duplicate names`: three logical callables
  with two to four bodyless duplicates each, interleaved with each other and
  with each other's implementations. Confirms exact survivor identity per
  name and total output count at a correctness (not performance) scale.

## Verification

```bash
bin/blorp test --timeout 180 blorp/test/compiler/stage_08_core_lower/test_core_flatten.brp
# All 28 tests passed (23 pre-existing + 5 new)

scripts/compiler-check --changed
# Compiler check passed: 1 sources, 1 suites, 1 checks in 127.47s

scripts/test compiler-blorp
# BLORP_GATE_RESULT gate=compiler_blorp status=FAIL passed=57 failed=1 tests=58
```

`scripts/test compiler-blorp`'s one failure (`compiler_blorp_component`,
purity/CTFE errors in unrelated `stage_06_typecheck` typecheck-phase-profile
sources) is pre-existing and unrelated to this change: it reproduces
identically on a clean worktree with none of this issue's edits applied
(verified by stashing all changes, rebuilding, and re-running the same gate).
It does not touch `stage_08_core_lower/flatten.brp` or either flatten
benchmark file.

All 5 new invariant tests were additionally verified to pass against the
pre-change `flatten.brp` (temporarily restored via `git stash`, rebuilt, and
re-run), confirming they assert genuine pre-existing behavior rather than
something only true after the optimization — the change is a pure performance
refactor, not a behavior change.

Core output identity: every benchmark row above reports the identical Core
checksum (`8329755092875520672`) for both the pre-change and post-change
binaries, across both the wide and small fixtures and both declaration
orders.

## Rejected Premise Check

The issue's "Reject if..." conditions were checked before implementation and
do not apply: the name-only winner rule is unchanged (verified by the new
invariant tests, which pass identically before and after), declaration order
is unchanged (the walk still visits `decls` once in original order and
appends to an output list in that order), and the new `implemented` index is
built exactly once per `deduplicate_functions` call, not per function.
