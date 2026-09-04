# Use Owner Catalogs For Lambda Regions

**Status:** Implemented

**Roadmap:** Perceus ownership optimization, Tranche 4C

**Dependencies:** Issues 48 and 49

**Parallel work:** Do not implement in parallel with Issue 51.

**Preparation:** The owner catalog now has an explicit region kind, parameter
and global catalogs share one ordered-entry constructor, empty entry lists skip
catalog construction, capture projection is explicitly named as name-mode, and
the scalar lambda baseline has dedicated counters plus a fixed 1/8/32-parameter
matrix. The preparation state was committed as `b181d6ba`; the implementation
now uses the catalog path described below.
The smoke baseline is recorded in
[`compiler_perceus_tranche4c_preparation_2026-09-04.md`](../../../benchmarks/results/compiler_perceus_tranche4c_preparation_2026-09-04.md).

## Objective

Apply the all-owner call, aggregate, and result mechanisms to each lambda
ownership region so lambda parameters, captures, and referenced globals no
longer trigger one scalar rewrite triple per borrowed value.

This issue generalizes proven machinery to a second ownership-region kind. It
does not fuse the three operation families and does not absorb match or loop
binding lifetime analysis.

## Why This Issue Exists

`normalize_lambda_body_ownership` currently builds:

```text
lambda parameters + runtime captures + referenced globals
```

and sends the complete list to `retain_borrowed_lambda_values`. For `B` borrowed
lambda values and `N` lambda-body nodes, that performs approximately
`O(3 * B * N)` reconstruction.

After Issues 48 and 49, functions and global initializers have owner-independent
boundary passes, but lambdas would remain a potentially common scalar island.
Leaving them behind would also make Issue 51's proposed region normalizer
misleading: it would be general in name but function-only in practice.

## Required Reading

Read Issues 48–49, the roadmap, and inspect:

- `normalize_lambda_expr` and `normalize_lambda_body_ownership`;
- `normalize_lambda_result_aliases` and its explicit frame stack;
- `lambda_name_mode_capture_owner` and `CoreClosure.lambda_runtime_captures`;
- the Lambda cases and boundaries in the all-owner call/aggregate traversals;
- `insert_drops_expr`, which invokes lambda normalization;
- loop and match borrowed-binding helpers that remain scalar; and
- lambda parameter/capture/global tests in the Perceus suite.

## Ownership-Region Contract

A lambda is its own ownership region. Its ordered owner sources are:

```text
managed borrowed lambda parameters
then managed runtime captures
then exact referenced managed globals
```

Preserve the existing order produced by `params.concat(captures)` and sorted
referenced globals. `CoreClosureCapture` carries only `name` and `typ`.
`lambda_name_mode_capture_owner` therefore projects it to an unresolved
`CoreVar` and the existing compatibility path matches it by spelling. Do not
manufacture definition identities in this issue. Capture discovery and
deduplication also remain name-based; distinct same-spelling captures cannot be
represented by the current closure ABI.

The outer region must treat a nested `LambdaExpr` body as opaque for borrowed
boundary normalization. `normalize_lambda_result_aliases` owns discovering and
normalizing the nested region. Runtime-capture discovery still descends through
nested lambdas to find transitive captures, and the current DCE-based global
discovery also descends through them. Do not confuse discovery membership with
rewrite traversal. If global discovery is made region-bounded here, compare its
result and output against the scalar parent explicitly.

The lambda's declared return type controls whether result normalization runs.
`transferable_result_vars` must remain empty under the existing lambda
contract unless a separate language/runtime contract explicitly proves a
transferable capture.

## Explicit Non-Goals

Do not fold these locally introduced owners into the lambda catalog:

- borrowed constructor-match bindings;
- for-loop binders;
- resource binders introduced within the body;
- mutable local slots; or
- select/concurrency result bindings.

Their lifetime rewriting is interleaved with lexical balancing and belongs to
Tranches 5–6. Existing scalar helpers for those sites remain until their
corresponding fact/planning migration.

## Required Implementation Sequence

1. Use the existing lambda-boundary fixture, scalar counters, and 1/8/32-owner
   baseline. Preserve its immediate-parent workers before cutover.
2. Use the existing explicit catalog-region kind, lambda parameter/capture
   origins, and shared ordered-entry constructor.
3. Build one parameter/capture/global catalog per lambda using the established
   runtime-capture list and exact referenced-global discovery.
4. Run the all-owner call, aggregate, and result passes for that catalog.
5. Preserve nested-lambda opacity and the existing explicit-frame traversal.
   Do not claim full stack boundedness for directly nested lambdas.
6. Cut `normalize_lambda_body_ownership` over and delete
   `retain_borrowed_lambda_values`.
7. Verify that no lambda caller invokes `retain_borrowed_scalar_value`. Delete
   the lambda loop, but do not delete lower-level scalar routines
   still used by explicit local-binding compatibility paths.
8. Measure before considering fusion.

## Benchmark Contract

The preparation tranche added `lambda_borrowed_boundary` and
`--lambda-owner-matrix` to `benchmarks/compiler_perceus_memory`.

The fixed fixture must contain:

```text
outer functions=2
lambda body_nodes=256, exact and fixed
managed lambda parameters=1,8,32
runtime captures=0
referenced globals=0
12 call, 12 aggregate, and 12 result boundary sites per lambda, fixed
nested lambda with its own distinct owner
outer worker invocation disabled
```

The primary baseline intentionally varies only lambda parameters. This keeps
the outer functions free of managed borrowed owners and isolates scalar lambda
work. A future source-kind control may compare parameters and captures only
after it can isolate capture discovery and the current capture/global name-mode
overlap. Do not claim source-kind timing equivalence from a fixture whose outer
function must itself own the captured values. Use traversable padding and
validate the exact 256-node census and 36 boundary sites before timing. The 256
serialized nodes include the fixed nested-lambda subtree;
`lambda_boundary_census` treats that subtree as opaque while counting the outer
region's boundary sites.

The baseline provides counters for normalized lambda regions, parameter /
capture / referenced-global owner slots, and scalar owner normalizations.
Because the fixture contains no function/global borrowed owners, its existing
call / aggregate / result visit counters compose exact lambda-region work.
Cutover must add catalog slots, scalar fallback requests, and rewrite actions
without reopening a second instrumentation walk. Counter validation must prove
that the nested lambda is normalized exactly once as its own region. Across
the two workers the baseline expects four normalized lambda regions and
`2 * B + 2` managed parameter slots/scalar owner normalizations at outer-owner
count `B`; capture and referenced-global slots are zero.

## TDD And Fast Feedback

Add focused tests for:

- direct lambda-parameter result;
- direct and projected capture results;
- consuming calls and aggregate storage from parameters and captures;
- a lambda parameter shadowing a capture spelling;
- name-mode capture matching and parameter-by-spelling capture exclusion;
- a referenced global distinct from a same-spelling parameter/capture;
- nested lambdas whose inner and outer owners share spelling;
- unmanaged lambda results;
- lambda-local match and loop binders remaining on their current path; and
- nested lambdas at the existing tested depth. Full stack-bounded traversal of
  directly nested lambdas is separate work unless this issue adds a lambda
  frame to the explicit driver.

Use the fast loop:

```bash
bin/blorp check --no-format blorp/src/compiler/stage_09_core/perceus.brp
bin/blorp test blorp/test/compiler/stage_09_core/test_core_perceus.brp
python3 -m unittest blorp.test.compiler.benchmark.test_perceus_memory
```

Build candidate workers only after these pass. Run seven warmed alternating
candidate/parent samples for the lambda matrix. Run a single compiler rebuild,
changed compiler gate, and generated-C comparison at the end.

## Acceptance Criteria

- `normalize_lambda_body_ownership` performs no borrowed-value loop and no
  scalar call/aggregate/result rewrite per parameter, capture, or global.
- Call, aggregate, and result node visits inside the fixed lambda body are
  independent of 1, 8, or 32 borrowed owners.
- Catalog slots equal the exact managed parameter, runtime-capture, and
  referenced-global counts. Nested lambda parameters remain local to the inner
  catalog; transitive runtime captures follow the established closure-capture
  authority.
- Scalar fallbacks are zero on the ownership-ready fixture and every retained
  compatibility fallback is counted and assigned to a named local-binding
  boundary.
- At 32 lambda owners, total borrowed-boundary reconstruction visits fall by at
  least 75% relative to the immediate parent.
- The 32-owner direct-Perceus paired median is at least 15% faster and measured
  direct-window allocations are at least 20% lower. Failure to expose a gain on
  a fixed lambda-dominant fixture is a stop/go failure, not permission to rely
  only on code aesthetics.
- The one-owner point does not regress paired direct-window time by more than
  5% and does not increase allocations or releases by more than 2%.
- Nested lambda normalization occurs exactly once per region and does not
  regress the existing tested nesting depth.
- Lambda code no longer calls `retain_borrowed_lambda_values`; delete it when
  the catalog cutover is complete.
- Match/loop/local-binding scalar paths remain semantically unchanged and are
  explicitly listed as deferred.
- Ownership events, post-Perceus Core, generated C, and runtime behavior are
  byte-identical to the immediate parent.
- Focused tests, benchmark contracts, `scripts/compiler-check --changed`, and
  `git diff --check` pass.

## Expected Result

Each lambda region pays a fixed number of borrowed-boundary traversals rather
than three traversals per borrowed parameter, capture, or global. This should
produce a visible focused gain for closure-heavy compiler code and leave Issue
51 with one consistent set of region inputs to fuse.

## Implementation Result

Lambda normalization now builds one ordered catalog from managed parameters,
name-mode runtime captures, and exact referenced managed globals. The existing
all-owner call, aggregate, and result passes consume that catalog; nested
lambdas remain opaque to those passes and are normalized by the existing
explicit lambda driver. The scalar lambda loop and its now-dead single-owner
wrapper were deleted. Match, loop, resource, mutable-slot, and concurrency
binding paths remain deferred exactly as scoped above.

The corrected 32-owner fixture reduced reconstruction visits from 36,146 to
1,072 (97.0%), improved the paired direct-Perceus median by 63.1%, reduced
allocations by 68.7%, and reduced releases by 69.7%. Candidate and immediate-parent
post-Perceus Core and generated C were byte-identical at every matrix point.
See
[`compiler_perceus_tranche4c_2026-09-04.md`](../../../benchmarks/results/compiler_perceus_tranche4c_2026-09-04.md)
for the complete measurements and verification record.
