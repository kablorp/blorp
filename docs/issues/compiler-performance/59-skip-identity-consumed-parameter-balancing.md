# Skip Proven-Identity Consumed-Parameter Balancing

**Status:** Implemented

## Objective

Avoid the parameter-by-parameter ownership summaries and reconstructions used
by `balance_consumed_param_bodies` when one stack-bounded scan proves that every
consumed managed parameter is transferred exactly once by a direct call and no
parameter ownership action can be required.

This is the first measured post-Tranche-4 checkpoint. It is deliberately a
narrow extension of the existing broad-signature identity proof, not the
all-value ownership-fact architecture proposed by Tranches 5 and 6.

## Why this checkpoint exists

The required post-Tranche-4 self profile found that borrowed-boundary fusion is
no longer the dominant repeated work. In a 46,417-sample native profile of
compiler self-compilation through Perceus:

- `insert_drops_expr` accounted for 4,646 inclusive samples;
- consumed-parameter balancing accounted for 1,114 inclusive samples; and
- `summarize_linear_ownership_uses` itself was much smaller at 155 inclusive
  samples, although its allocation and reconstruction work is charged to its
  callers.

The fixed 644-node nested-call fixture made the multiplicative behavior exact:

| Consumed owners | Direct Perceus | Linear-summary requests | Summary visits |
| ---: | ---: | ---: | ---: |
| 1 | 46.830 ms | 697 | 112,363 |
| 8 | 1,826.011 ms | 37,201 | 5,692,209 |
| 32 | 6,777.236 ms | 162,625 | 21,103,425 |
| 128 | 20,718.717 ms | 871,681 | 60,347,649 |

`insert_node_visits` remained fixed at 5,159 for every owner count. Inspection
of the resulting 32-owner artifact found zero parameter `DupExpr` or
`DropExpr` nodes in all eight workers: the expensive balancing result was the
input tree.

## Implementation

The existing `SimpleConsumedParameterCatalog` already establishes the narrow
entry conditions:

- at least 16 consumed parameters;
- unmanaged function result;
- unique parameter spellings;
- managed consumed parameters only; and
- unresolved, unhygienic parameter identities only.

`prove_simple_consumed_parameter_balance` now also receives the current
`PerceusEnv` and accepts direct calls only when `contract_for_call` supplies an
exact ownership contract. Each candidate parameter must occur as a direct
argument in a caller-consuming slot exactly once.

The scan rejects:

- borrowed or retained candidate arguments;
- repeated or missing candidate consumption;
- parameter references in callees or unsupported argument expressions;
- branches, matches, loops, aliases, shadowing, and parameter ownership nodes;
- resolved or hygienic parameter identities; and
- managed casts.

Unmanaged casts may transparently wrap a supported linear region. Literals and
static string literals may occupy unrelated call slots. These rules recognize
generated forwarding and builtin-consuming call sequences without attempting
to solve general ownership planning.

When the proof succeeds, `balance_consumed_param_bodies` returns the already
rewritten body. When it fails, the established parameter-by-parameter authority
runs unchanged.

## Benchmark integrity repair

Static string pooling made the old per-worker `BENCH_MANAGED_LOCAL_*` literals
immortal, so the benchmark's generic "Perceus ran" validator no longer had a
mortal ownership event to inspect. Making every worker literal dynamic would
have changed the fixed node and function-scaling axes.

The benchmark now places one constant-cost mortal String sentinel in `main`,
outside all worker bodies. The worker geometry is unchanged, while every
Perceus action must emit the sentinel's ARC drop. The input-expression formula
accounts for the five additional sentinel nodes.

## Acceptance criteria

- [x] The new direct-consuming-call case fails the existing identity proof
  before implementation and passes afterward.
- [x] A borrowed call argument is an explicit rejection case.
- [x] An unmanaged cast wrapper is accepted and a managed cast is rejected.
- [x] Missing, repeated, shadowed, resolved, branch, loop, and other existing
  rejection cases remain covered.
- [x] The proof uses call contracts rather than call names or syntax guesses.
- [x] The 32-owner focused artifact is byte-identical to the direct parent.
- [x] The focused direct-Perceus window and deterministic allocation counts
  improve materially.
- [x] The complete focused Perceus suite and benchmark contract suite pass.
- [x] Compiler self-compilation is measured and reported without claiming a
  gain that the workload does not show.

## Result

On seven paired, alternating samples of the eight-function, 32-owner,
644-node nested-call fixture:

| Metric | Direct parent | Candidate | Change |
| --- | ---: | ---: | ---: |
| Direct Perceus median | 6,760.080 ms | 13.410 ms | -99.80% |
| Window allocations | 94,920,801 | 125,079 | -99.87% |
| Window releases | 94,915,263 | 119,541 | -99.87% |
| Linear-summary requests | 162,625 | 1 | -99.999% |
| Linear-summary visits | 21,103,425 | 1 | -99.999% |

The 532,843-byte post-Perceus artifact is byte-identical, with SHA-256
`26ac392372fda49d3f6f28ec1101f5fb96bdf47895827e5e8205466ca39db8a9`.

Same-source compiler self-compilation was neutral rather than faster. One
candidate run reported 33.703 seconds through the Core/Perceus backend versus
33.059 seconds for the direct parent; retired instructions changed from
1,062,747,081,145 to 1,065,196,542,876 (+0.23%). The 313,653,142-byte snapshots
were byte-identical. This checkpoint therefore prevents severe scaling on
broad generated signatures; it does not materially accelerate the current
compiler source.

Detailed measurements are recorded in
[`compiler_perceus_direct_consuming_call_identity_2026-09-07.md`](../../../benchmarks/results/compiler_perceus_direct_consuming_call_identity_2026-09-07.md).

## Fast feedback loop

During implementation:

```bash
bin/blorp check --no-format blorp/src/compiler/stage_09_core/perceus.brp
bin/blorp test blorp/test/compiler/stage_09_core/test_core_perceus.brp
python3 -m unittest blorp.test.compiler.benchmark.test_perceus_memory
```

The paired benchmark reuses explicit timing workers so compilation is outside
the measured window. Full compiler/runtime gates are deferred until the next
complete merge boundary.

## Follow-up boundary

Do not keep adding expression shapes to this proof. Branches, matches,
repetition, aliases, borrowed-before-consume ordering, and local binders require
the all-value occurrence and region facts in Tranche 5. This shortcut should be
removed once the general Tranche 6 planner meets or beats it.
