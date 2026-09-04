# Use Owner Catalogs For Lambda Regions

**Status:** Proposed

**Roadmap:** Perceus ownership optimization, Tranche 4C

**Dependencies:** Issues 48 and 49

**Parallel work:** Do not implement in parallel with Issue 51.

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

and sends the complete list to `retain_borrowed_values`. For `B` borrowed
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
- `lambda_capture_param` and `CoreClosure.lambda_runtime_captures`;
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
referenced globals. Captures currently use their established projected
`CoreVar` identity; do not manufacture definition identities or infer captures
from spelling in this issue.

The outer region must treat a nested `LambdaExpr` body as opaque for borrowed
boundary normalization. `normalize_lambda_result_aliases` owns discovering and
normalizing the nested region. Entering it from both the outer traversal and
the lambda-region traversal would duplicate ownership events.

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

1. Add a lambda-boundary fixture and failing 1/8/32-owner scaling assertion.
2. Introduce explicit owner kinds for lambda parameters and captures if Issue
   49 has not already generalized the catalog representation.
3. Build one parameter/capture/global catalog per lambda using the established
   runtime-capture list and exact referenced-global discovery.
4. Run the all-owner call, aggregate, and result passes for that catalog.
5. Preserve nested-lambda opacity and the existing stack-bounded lambda walker.
6. Cut `normalize_lambda_body_ownership` over and delete its
   `retain_borrowed_values` loop.
7. Verify that remaining scalar `retain_borrowed_values` callers are zero. If
   the helper is dead, delete it. Do not delete lower-level scalar routines
   still used by explicit local-binding compatibility paths.
8. Measure before considering fusion.

## Benchmark Contract

Add `lambda_borrowed_boundary` and `--lambda-owner-matrix` to
`benchmarks/compiler_perceus_memory`.

The fixed fixture must contain:

```text
outer functions=2
lambda body_nodes=256, exact and fixed
lambda borrowed owners=1,8,32
fixed split between parameters and captures at each point
fixed referenced-global count
12 call, 12 aggregate, and 12 result boundary sites per lambda, fixed
nested lambda with its own distinct owner
outer worker invocation disabled
```

Because one owner cannot have the same parameter/capture split as 8 or 32,
make the primary matrix vary total borrowed sources while a second fixed
32-owner control compares all-parameter, all-capture, and mixed catalogs. The
primary scaling assertion concerns node visits; the control proves owner kind
does not alter traversal count or accidentally change capture projection. Use
traversable padding and validate the exact 256-node census and 36 boundary
sites before timing.

Add counters for lambda regions built, catalog slots by owner kind, call /
aggregate / result visits within lambda regions, scalar fallback requests, and
rewrite actions. Counter validation must prove that the nested lambda is
normalized exactly once as its own region.

## TDD And Fast Feedback

Add focused tests for:

- direct lambda-parameter result;
- direct and projected capture results;
- consuming calls and aggregate storage from parameters and captures;
- a lambda parameter shadowing a capture spelling;
- same-spelling distinct captures where the current capture representation
  permits them;
- a referenced global distinct from a same-spelling parameter/capture;
- nested lambdas whose inner and outer owners share spelling;
- unmanaged lambda results;
- lambda-local match and loop binders remaining on their current path; and
- deep nested lambdas remaining stack bounded.

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
  referenced-global counts; nested-lambda owners never enter the outer catalog.
- Scalar fallbacks are zero on the ownership-ready fixture and every retained
  compatibility fallback is counted and assigned to a named local-binding
  boundary.
- At 32 lambda owners, total borrowed-boundary reconstruction visits fall by at
  least 75% relative to the immediate parent.
- The 32-owner direct-Perceus paired median is at least 15% faster and measured
  direct-window allocations are at least 20% lower. Failure to expose a gain on
  a fixed lambda-dominant fixture is a stop/go failure, not permission to rely
  only on code aesthetics.
- The one-owner point does not regress time beyond paired noise and does not
  increase allocations or releases by more than 2%.
- Nested lambda normalization occurs exactly once per region and remains stack
  bounded.
- Function, global-initializer, and lambda code no longer call
  `retain_borrowed_values`; delete it when no caller remains.
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
