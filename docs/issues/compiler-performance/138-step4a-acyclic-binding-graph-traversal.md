# Step 4A: Acyclic Meta Binding Graph Traversal

**Status:** Implemented in this worktree; Step 4A remains open.

## Context and invariant

The solver now has one private, opaque binding store. `fresh_meta` appends an
unbound slot; `bind_meta` is its only nonempty binding writer. Before storing
an edge, it rejects a target that is unissued, a nested unissued reference,
and any self or transitive reference back to the target. Rebinding goes
through the same check. Starting from the empty solver, every reachable
binding graph is therefore acyclic.

The earlier `meta_reference_conflicts` traversal still threaded a
`seen: List[Int]` through each recursive edge, checking membership and
appending before following a binding. That defense was needed before the
writer enforced the graph invariant; now it repeats work on the successful
`bind_meta`, occurs, and unification-issuance paths. The traversal follows
an existing binding directly:

```blorp
match lookup_meta(context, meta_id):
    Some(binding):
        meta_reference_conflicts(context, target_meta_id, binding, check)
    None:
        False
```

The three check modes still distinguish a target occurrence from an
unissued reference. This cut changes neither when an edge is accepted nor
the diagnostic boundary. A shared acyclic subgraph may still be visited
more than once from sibling branches, just as with the old path-local list;
there is no global memoization. A future writer added outside `bind_meta`
would invalidate the proof and must first restore or replace cycle safety.

## Implementation, test, and fast feedback

A new context test constructs a shared acyclic reference twice in a tuple,
checks an occurs query, rejects a back edge, and accepts an unrelated edge.
It passed before and after the change, protecting semantics. Existing tests
also cover self-cycles, transitive cycles, nested unissued metas, and
equal-type unification shortcuts.

The retained binding-chain probe issues 128 metas, builds an acyclic
1→2→...→Int chain outside its measured window, then checks the same
successful 0→1 binding 4,096 times. It measures the `bind_meta` API path,
including persistent context replacement, not an isolated validator call.

```bash
bin/blorp test blorp/test/compiler/stage_06_typecheck/type_system/test_context.brp
benchmarks/compiler_blorp_benchmark_runner \
    compiler-meta-binding-chain-profile \
    blorp/benchmark/compiler/compiler_meta_binding_chain_profile.brp \
    plain 128 4096
scripts/compiler-check --changed
bin/blorp test --sanitize --timeout 180 \
    blorp/test/compiler/stage_06_typecheck/type_system/test_context.brp
benchmarks/compiler_ctfe_typecheck_profile 3 24 32 retained selected
```

The focused context suite passes 30/30, including the new branching test.
Independent changed-owner checks pass one source and two suites in 5.56 s;
targeted ASan/UBSan passes all 30 tests. Review found no blocking issue and
confirmed the writer invariant.

The probe preserves 4,096 successful bindings and zero retained objects or
bytes. Allocation/release calls fall from 40,960/40,960 to 16,384/16,384
(−60%). In one warm direct comparison, retired instructions fall from
714,736,062 to 115,866,188 (−83.8%); sampled peak footprint is unchanged
at 1,179,936 B. Worker size falls from 684,080 to 683,584 B. The baseline
and candidate worker keys are
`98189fdd518161324ecacf1fc8e5eacb4dcb5d924e70a94034e34a2fabffa182`
and `ad67ed9fb72864e19c77511d0897f98234f6229bdadaa10ead4d401cd771b877`.
The short elapsed samples are not a reliable wall-time claim.

The selected CTFE guard preserves checksum 2,538, 72 dependency body checks,
three reused bodies, zero errors, 770,319 / 770,316 allocations/releases,
and 3 / 192 retained objects/bytes. Two short warm comparisons observed
retired instructions of 1,593.6M / 1,570.5M before and 1,571.4M / 1,569.1M
after; this is near parity, not a robust whole-compiler instruction win.
Paired sampled peak footprints were 14,991,696→15,057,208 B (+0.44%) and
14,926,136→14,975,312 B (+0.33%). Worker size fell
16 B from 6,378,832 to 6,378,816 B. The baseline/candidate worker keys are
`3f6b36c850401878f74d865239158991e34dbb7a8edbc30e45395d6239809ce7`
and `d99a9995faf7a0945c06f483c3ba72c2424bcdf654e0ab82a0ff3e51b312306c`.

## Acceptance and remaining work

- All bindings remain issued, acyclic, and accepted or rejected exactly as
  before; the shared-DAG/back-edge regression passes.
- The focused path reduces work without retained-memory growth, and the
  selected compilation guard shows no material allocation, instruction,
  peak-footprint, or worker-size regression.
- This cut does not provide nominal session provenance for `MetaId`, detach
  all solver lifetime from `Context`, or complete Step 4A body validation.
