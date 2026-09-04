# Normalize Borrowed Results For All Owners

**Status:** Implemented

**Roadmap:** Perceus ownership optimization, Tranche 4A

**Dependencies:** Tranches 2 and 3 of
`PERCEUS_OWNERSHIP_OPTIMIZATION_ROADMAP.md`

**Parallel work:** Do not implement in parallel with Issues 49–51. They modify
the same owner catalog and borrowed-boundary traversal. Benchmark-fixture work
may be prepared separately only if it does not change production Perceus code.

## Objective

Replace the function-parameter result rewrite that walks result paths once for
every borrowed managed parameter with one result-position traversal over the
ordered borrowed-owner catalog.

This issue changes compiler work only. It must preserve the exact post-Perceus
Core tree, ownership-event order, generated C, and runtime behavior.

## Why This Issue Exists

`retain_borrowed_param_results` currently performs:

```blorp
for param in func_info.params:
	if is_managed_type(env, param.typ) and not consumed_params.contains(index):
		result = retain_borrowed_param_result(env, param, result)
```

For `B` borrowed managed parameters and `R` result-path nodes, this reconstructs
approximately `O(B * R)` Core. Tranches 2 and 3 have already made call and
aggregate normalization owner-independent, so result handling is now the
remaining parameter-multiplied borrowed-boundary pass in `rewrite_function`.

Result ownership is narrower than ordinary traversal: only expressions that
can provide the function result propagate result position. It is nevertheless
semantically delicate because existing `DupExpr` nodes, exact lexical
shadowing, compiled-match bindings, and evaluate-once aliases can disable one
owner without disabling the others.

## Required Reading

Read the roadmap and inspect:

- `retain_borrowed_param_result` and all
  `retain_borrowed_param_result_in_*` helpers;
- `retain_borrowed_param_results`;
- `retain_borrowed_owned_uses`;
- `BorrowedOwnerCatalog`, `BorrowedOwnerRewriteContext`, and
  `first_borrowed_owner_aliasing_expr`;
- `protect_borrowed_param_calls_for_function`;
- `retain_borrowed_param_aggregates`;
- the result, match, resource, and multi-owner cases in
  `blorp/test/compiler/stage_09_core/test_core_perceus.brp`; and
- `benchmarks/compiler_perceus_memory` and its Tranche 2/3 matrices.

Before changing code, inventory the exact variants handled by
`retain_borrowed_param_result`. That implementation is the compatibility
authority. Do not infer additional result paths from general Core child shape.

## Semantic Contract

### Result carriers

Preserve the current closed result-position rules:

```text
VarExpr                  terminal alias candidate
FieldExpr                terminal computed alias candidate
TupleFieldExpr           terminal computed alias candidate
CallExpr                 terminal computed alias candidate
CastExpr                 terminal computed alias candidate
UnboxExpr                terminal computed alias candidate
LetExpr                  body only
BorrowLetExpr            body only
SeqExpr                  second expression only
IfExpr                   then and else arms
LiteralMatchExpr         every case/fallback result
AccessorLiteralMatchExpr every case/fallback result
LengthMatchExpr          every branch result
ConstructorMatchExpr     every case/fallback result
DupExpr                  body for owners not satisfied by this Dup
DropExpr                 body
ResourceScopeExpr        body only, subject to binder shadowing
AssignExpr               no result propagation
all other variants       unchanged by result normalization
```

Conditions, scrutinees, initializers, assignment right-hand sides, resource
acquisition/cleanup, and loop/task children are not function-result positions.
Do not broaden this whitelist in an output-preserving optimization.

### Branch-local ownership

Result ownership remains branch-local. Given:

```text
if condition: owner_a else: owner_b
```

normalize each arm independently. Do not replace the complete conditional with
one synthetic temporary. Call-argument ownership deliberately uses an
evaluate-once wrapper around a complete computed argument; function-result
ownership does not have that shape today.

### Owner state

The traversal needs result-specific owner state in addition to lexical
shadowing. A `DupExpr` for one owner satisfies that owner's result obligation
below the node but must not hide other owners.

Use an explicit representation, for example:

```blorp
record BorrowedResultRewriteContext {
	base: BorrowedOwnerRewriteContext,
	result_satisfied_owner_ids: Dict[Int, Bool]
}
```

The exact representation may differ, but do not use one boolean or one shared
active-owner set for both lexical visibility and result satisfaction.

### Terminal aliases

For a direct `VarExpr`, emit the same `DupExpr` as the earliest matching legacy
owner pass. For managed `FieldExpr`, `TupleFieldExpr`, `CallExpr`, `CastExpr`,
or `UnboxExpr`, use the same evaluate-once temporary and synthetic name that
the scalar implementation would have emitted for that earliest owner.

Direct/projection queries should use the existing candidate index. Complex
aliases may use the exact scalar predicate only at an explicit compatibility
boundary. Add `BorrowedResultOwnerQuery` or an equivalent distinction so
result candidate visits and scalar fallbacks are not attributed to call or
aggregate counters.

## Required Implementation Sequence

1. Add the result-focused fixture and failing matrix assertions.
2. Add result candidate, fallback, and rewrite counters.
3. Implement a private all-owner result traversal alongside the scalar path.
4. Cover exact binders, `DupExpr` satisfaction, every compiled-match form, and
   resource-scope shadowing.
5. Cut `rewrite_function` over for function parameters only.
6. Compare exact post-Perceus artifacts with an immediate-parent worker.
7. Delete `retain_borrowed_param_results` and parameter-only result helpers
   that have no remaining caller. Keep scalar primitives still used by match,
   loop, lambda, or global compatibility paths for later issues.
8. Reprofile the focused matrix before broad testing.

Do not add referenced globals, lambda captures, fusion, or all-value lifetime
facts in this issue.

## Benchmark Contract

Add `borrowed_return` to `benchmarks/compiler_perceus_memory` and a
`--result-matrix` mode.

The fixture must use:

```text
functions=2
body_nodes=256, exact and fixed across points
borrowed managed owners=1,8,32
managed return type
balanced result branches with 32 terminal aliases per function, fixed
all benchmark aliases select owner zero; additional owners are unused
worker invocation disabled in the direct fixture
```

Use structurally traversable padding outside result position to reach exactly
256 nodes; do not use an opaque `CastExpr` around the body. Validate the
fixture's complete node census and exactly 64 expected result retains across
the two functions before accepting timing data.

Add deterministic counters for:

```text
borrowed_result_node_visits
borrowed_result_owner_candidate_visits
borrowed_result_alias_fallback_requests
borrowed_result_rewrite_actions
borrowed_origin_member_visits
borrowed_origin_storage_slots
```

The matrix must reuse one timing worker and one counter worker, use explicit
immediate-parent timing/counter workers, warm both, run at least seven paired
samples in alternating order, and reject unequal artifacts.

## TDD And Fast Feedback

Before implementation, add focused Perceus tests that fail under a deliberately
single-owner implementation:

- two borrowed parameters returned from different `if` arms;
- two owners returned from different literal, accessor-literal, length, and
  constructor-match branches;
- a direct variable result and each computed terminal alias form;
- an existing `DupExpr` satisfying one owner while another branch still needs
  a retain;
- exact and same-spelling/different-identity binder shadowing;
- a resource binder shadowing only one owner;
- an unmanaged return-type near miss;
- a consumed managed parameter near miss; and
- incoming ownership nodes at the explicit compatibility boundary.

During iteration, use only:

```bash
bin/blorp check --no-format blorp/src/compiler/stage_09_core/perceus.brp
bin/blorp test blorp/test/compiler/stage_09_core/test_core_perceus.brp
python3 -m unittest blorp.test.compiler.benchmark.test_perceus_memory
```

Do not rebuild for each source edit. Once typechecking and focused tests pass,
build one candidate timing worker and one debug/profile counter worker, then run
the result matrix. Run `make` and `scripts/compiler-check --changed` only after
the focused artifact and performance gates pass.

## Acceptance Criteria

- `retain_borrowed_param_results` no longer performs one result traversal per
  function parameter and is deleted.
- Candidate `borrowed_result_node_visits` is identical at 1, 8, and 32 owners
  for the fixed fixture.
- Candidate result-query and rewrite counters scale with actual fixed terminal
  aliases, not owner count times result-path size.
- Scalar result fallbacks are zero on the ownership-ready fixture and are
  reported separately wherever compatibility requires them.
- The 32-owner candidate performs at least 75% fewer result-path node visits
  than the immediate parent.
- The 32-owner direct-Perceus paired median is at least 15% faster than the
  immediate parent. If that is not achieved after making result density
  representative and dominant without changing matrix axes, stop and reassess
  before merging.
- The 32-owner measured direct-window allocation count is at least 20% lower;
  one-owner allocations and releases do not regress by more than 2%.
- Every listed result-carrier form, exact shadowing, and per-owner `DupExpr`
  satisfaction has a focused semantic regression.
- Ownership-event order, post-Perceus Core, and generated C are byte-identical
  to the immediate parent for every matrix point.
- The compiler self-compilation comparison is recorded, but whole-compiler
  time is not a landing gate.
- Focused tests, benchmark contracts, `scripts/compiler-check --changed`, and
  `git diff --check` pass.

## Expected Result

The result pass changes from `O(B * R)` reconstruction to one `O(R)` traversal
plus indexed terminal queries and actual retain actions. The focused fixture
should show a clear direct-Perceus and allocation improvement at 8 and 32
owners, while ordinary one-owner programs remain effectively neutral.

## Implementation Result

The function-parameter result rewrite now uses one branch-local traversal over
the ordered borrowed-owner catalog. Lexical shadowing and result satisfaction
are represented separately, and the scalar result primitives remain only for
the later global, lambda, match-binding, and local-owner migrations.

On 2026-09-04, seven paired alternating samples against the captured Tranche 3
parent produced the following direct-Perceus results for the fixed 32-owner
fixture:

- result-path visits: 6,144 to 130 (97.9% fewer);
- median paired direct-window ratio: 0.726 (27.4% faster);
- direct-window allocations: 25,662 to 19,596 (23.6% fewer);
- direct-window releases: 25,072 to 19,006 (24.2% fewer); and
- post-Perceus Core: byte-identical.

At one owner, allocations and releases both improved by roughly 0.3%, staying
inside the 2% non-regression bound. Candidate result work was exactly 130 node
visits, 64 indexed candidate visits, zero scalar fallbacks, and 64 rewrites at
every owner-count point.
