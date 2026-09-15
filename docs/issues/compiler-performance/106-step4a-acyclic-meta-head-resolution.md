# Step 4A: Acyclic Meta Head Resolution

**Status:** Implemented in this worktree; Step 4A remains open. This follows
the binding-graph and unification cuts in [packet 104](104-step4a-meta-binding-graph-invariants.md)
and [packet 105](105-step4a-unification-shortcut-meta-validation.md).

## Context and invariant

`head_resolve` followed a meta binding chain recursively and rebuilt a
`seen: List[Int]` at each hop. That was necessary while callers could insert
cyclic bindings. Packet 104 moved cycle rejection into the sole binding
constructor, `bind_meta`, including transitive cycles through existing
bindings. The solver representation is opaque, so production callers cannot
construct its binding array directly. Retaining the visited-ID list in this
head-only query now duplicates a construction-time guarantee.

The new retained probe constructs a valid chain of issued metas outside the
measured region, then resolves varying starting IDs 4,096 times. It checks
every result against `TYPE_INT` and exits nonzero if setup or resolution
fails. A 64-hop correctness test was added to the context suite before the
refactor. The probe's baseline exposed the cost even though that correctness
test already passed: 24,832 allocations at width 64 and 28,800 at width 128.

## Implementation

`head_resolve` is now an iterative loop: while the current type is a bound
meta, replace it with its binding; otherwise return it. It does not allocate
or search a visited-ID list. An unissued or unbound meta still returns as
itself. This changes only the head query; full recursive `resolve_type_metas`
and its recovery behavior remain separate.

This relies on the invariant that every stored binding came through
`bind_meta`. If a future solver constructor or deserializer can bypass that
function, it must validate the graph before exposing the solver value.

## Fast feedback and resource evidence

```bash
bin/blorp test blorp/test/compiler/stage_06_typecheck/type_system/test_context.brp
benchmarks/compiler_meta_resolution_chain_profile 64 4096
benchmarks/compiler_meta_resolution_chain_profile 128 4096
scripts/compiler-check --changed
benchmarks/compiler_ctfe_typecheck_profile 3 24 32 retained selected
```

The retained probe uses the normal `compiler_blorp_benchmark_runner` with
Apple clang 21.0.0, `-O2 -fwrapv -pipe -w` on Darwin 25.6.0 arm64. The
baseline local worker key is
`24e6f2e3bfc098e8bf9c0abe7ff6db075469d7fe610951e6556fcb87849f7af0`;
the iterative worker key is
`0485da7811ddeb600e3f92048e5fa4bafaf60a8c0bf69836e4198d302be8f0fd`.
These keys name uncommitted local snapshots, not git revisions.

| Width × lookups | Baseline allocations / releases | Iterative allocations / releases | Retained objects / bytes |
| --- | ---: | ---: | ---: |
| 64 × 4,096 | 24,832 / 24,832 | 8,192 / 8,192 | 0 / 0 both |
| 128 × 4,096 | 28,800 / 28,800 | 8,192 / 8,192 | 0 / 0 both |

At width 128, a short B-A-A-B direct worker screen reported baseline
retired-instruction samples of 286,456,293 / 284,166,158 versus
56,503,838 / 56,307,327 after. Peak footprint ranged from 1,163,552 to
1,196,320 B across both workers. The first baseline run had 21 page faults
versus one for the other three; no wall-time claim is based on that pair.
The probe isolates head resolution, not complete compiler latency.

The selected retained CTFE workload keeps checksum 2,538, 72 dependency
body checks, three reused bodies, 769,887 allocations, 769,884 releases,
and 3 / 192 retained objects/bytes. In a B-A-A-B direct worker screen,
the warmed pre-cut worker (`8eb4c67eb4851e8a5a076a98464c90d927343bc3d4958f0160eab41f4f15985c`)
retired 1,567,354,986 instructions with 14,942,520 B peak footprint;
the iterative worker (`6eb807c093d68c5bf88cde7c7f7310e3ce9785db429e1b934a1b436de31acb5b`)
retired 1,567,251,466 / 1,567,184,838 instructions with
14,958,928 / 14,975,288 B peak footprint. The first pre-cut run had 301
page faults and is not used as a warmed comparison. Worker size moved from
6,391,968 to 6,391,872 bytes.

On the final source, independent focused context/dimension/inference tests
pass 343 / 343; the changed-owner gate passes four sources and 11 suites;
and the context ASan/UBSan test passes 27 / 27.

## Acceptance and remaining work

- Long issued chains resolve exactly; self and transitive binding cycles
  remain rejected at construction.
- The focused chain probe reduces allocations and retired instructions
  without retained-memory growth; the selected CTFE guard shows no material
  regression in allocations, instructions, peak memory, or worker size.
- Cross-session provenance is **not** established: `SemanticMetaType(Int)`
  can still alias an issued local index. Nominal session-owned IDs require an
  explicit body/module identity that travels with the type, not another
  head-resolution guard. Solver-lifetime and finalization work also remain.
