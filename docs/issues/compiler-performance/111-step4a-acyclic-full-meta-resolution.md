# Step 4A: Acyclic Full Meta Resolution

**Status:** Implemented in this worktree; Step 4A remains open. This follows
the construction-time binding-graph invariant in
[packet 104](104-step4a-meta-binding-graph-invariants.md) and the head-only
resolution cut in [packet 106](106-step4a-acyclic-meta-head-resolution.md).

## Context and invariant

`resolve_type_metas` and `zonk_type` still threaded a `seen: List[Int]` through
their recursive semantic-type walk. Following a bound meta scanned this list
and appended the next ID. This was a defensive cycle fallback before
`bind_meta` rejected self and transitive cycles, including nested references.
The solver representation is now private and opaque, with `bind_meta` as its
only binding writer. Full resolution can rely on that construction-time
invariant, just as `head_resolve` already does.

```blorp
private pure func resolve_type_metas_recursive(
    context: Context,
    typ: SemanticType,
    finalize_unbound: Bool,
) -> SemanticType:
    match typ:
        SemanticMetaType(meta_id):
            match lookup_meta(context, meta_id):
                Some(binding):
                    resolve_type_metas_recursive(context, binding, finalize_unbound)
                None:
                    unbound_meta_type(context, meta_id, finalize_unbound)
        -- Other variants recursively map their contained types.
```

This removes only per-hop visited-list work. The recursive reconstruction of
named, array, function, tuple, range, and dimension-expression types is
unchanged. An issued but unbound meta still projects to its origin type
variable during `zonk_type`; an unissued index remains unresolved after the
subsequent [fail-closed zonk cut](112-step4a-unissued-meta-finalization-boundary.md).
`resolve_type_metas` leaves either kind unbound as `SemanticMetaType`. There
is no valid source-language or diagnostic change.
Existing recursion depth is unchanged: the old implementation was recursive
as well. If a future loader or constructor can create a solver without
`bind_meta`, it must validate acyclicity before exposing that value.

## Focused feedback

A new context test builds a 64-meta chain, resolves it twice inside a nested
type, and checks both finalization and unresolved-meta recovery. It passed
before and after the refactor; the measurable failing target was the retained
full-resolution probe's allocation cost. The existing self/transitive-cycle
tests protect the constructor invariant. The probe now accepts explicit
`head` or `full` mode (default `head`); an unknown mode exits nonzero, so a
misspelling cannot be mistaken for a full-resolution measurement. Setup and
binding occur outside the measured region.

```bash
bin/blorp test blorp/test/compiler/stage_06_typecheck/type_system/test_context.brp
benchmarks/compiler_meta_resolution_chain_profile 128 4096 full
benchmarks/compiler_meta_resolution_chain_profile 128 4096 head
scripts/compiler-check --changed
benchmarks/compiler_ctfe_typecheck_profile 3 24 32 retained selected
```

The 128-meta × 4,096-lookup baseline, after adding `full` mode but before
changing `context.brp`, resolved every lookup and reported 32,896
allocations/releases with zero retained objects/bytes. Its local worker key
is `99088ef0906db60cbb14511882cae4982652a60799e178d58e8deaabeae8fe81`.
The post-review worker key is
`d8d966d1eff030721a04505b341b2f02e187029c7ffbb5bf979f6e5cc0742556`.
It reports 12,288 allocations/releases and zero retention, a reduction of
20,608 calls (62.6%). An unknown benchmark mode exits 1; the unchanged
head mode still reports 8,192 allocations/releases at this width. These
cache keys identify local source snapshots, not Git revisions.

| Full-resolution signal, 128 × 4,096 | Pre-cut | Candidate | Reading |
| --- | ---: | ---: | --- |
| Allocations / releases | 32,896 / 32,896 | 12,288 / 12,288 | −62.6% |
| Retired instructions | 281,103,973 / 280,739,583 | 69,245,611 / 68,907,765 | About −75% in two paired short samples |
| Peak footprint | 1,196,320 / 1,147,168 B | 1,179,936 / 1,163,552 B | Same range |
| Worker size | 702,536 B | 702,696 B | +160 B (+0.023%) |

Each direct worker run had one page fault. The small program and short elapsed
times do not support a whole-compiler latency claim; retired instructions and
allocation calls are the useful mechanism signals here.

The selected retained CTFE compilation guard preserves checksum 2,538, 72
dependency body checks, three reused bodies, zero errors, and 3 / 192
retained objects/bytes. Allocations/releases are unchanged at
770,319 / 770,316. The pre-cut worker key is
`683a60a35f852f500005bafa69242de7de5c439c52e2531d65102cacd9e3398a`;
the candidate key is
`dec99636777e0dbcc001364e2efa6c03c7bab32155cc2e666b462174c27c0b66`.
Two short paired direct samples had 1,569,299,568 / 1,569,092,564 retired
instructions before versus 1,568,978,856 / 1,569,698,520 after: near
parity at this resolution. Peak footprint was 14,893,368 / 14,942,520 B
before versus 14,991,672 / 15,024,440 B after, a small increase under 1%
in these samples. Worker size fell 192 B, from 6,379,168 to 6,378,976 B.
All four runs had ten page faults; short elapsed times are too noisy to claim
a whole-compiler latency change.

The focused context suite passes 28/28; an independent changed-owner gate
passes one production source and two focused suites, and targeted ASan/UBSan
passes the same 28 context tests. `format --check` and `git diff --check`
pass for this cut. Review found no resolver correctness or diagnostic issue;
the benchmark's invalid-mode behavior was tightened before final measurement.

## Acceptance and remaining work

- Full resolution, final zonking, and unbound-meta recovery preserve exact
  values; binding cycles continue to fail at construction.
- The focused full-resolution probe reduces allocation calls and retired
  instructions without retained-memory growth. Head-only behavior is
  unchanged.
- Selected compiler compilation preserves checksum, body-check/reuse counts,
  and retained bytes. Allocation calls and instructions are near parity, the
  sampled peak-footprint increase stays below 1%, and worker size falls
  slightly. No whole-compiler latency win is claimed.

This removes a redundant guard, not the complete finalization walk. Nominal
session-owned `MetaId`, solver-lifetime separation from broad `Context`, and
further measured traversal fusion remain Step 4A work.
