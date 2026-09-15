# Step 4A: Direct Meta Scanning In Semantic Type Lists

**Status:** Implemented in this worktree; Step 4A remains open.

## Context and boundary

The Phase 9A body-validation inventory identifies repeated meta-freedom
checks on nested semantic types. A focused `bodies 1 8 32 64 4 memory`
profile attributed about 68,700 calls each to `type_contains_meta` and
generic `List.any` in the instrumented body phase. Those call totals and
self-time are directional because the profiler builds at `-O0`; they are not
whole-compiler speed claims. They do point to a small, existing traversal
boundary. `type_contains_dim_op` already scans type lists with a direct loop.

`type_contains_meta` now uses the same local pattern for named type arguments,
array dimensions, function parameters, and tuple elements:

```blorp
private pure func types_contain_meta(types: List[SemanticType]) -> Bool:
    var contains_meta: Bool = False
    for typ in types:
        if type_contains_meta(typ):
            contains_meta = True
            break
    contains_meta
```

The recursive check and short-circuit behavior are unchanged. This does not
merge validation passes, change diagnostic order, or establish session-owned
`MetaId`. It removes generic callback dispatch from one hot list traversal.

## Implementation and fast feedback

The regression test places a meta after an ordinary type in every list-bearing
variant, then checks both a meta-free tuple and an empty tuple. It passed
before and after the rewrite; it protects semantics while the body-phase
probe decides whether the representation change is worth keeping.

```bash
bin/blorp test blorp/test/compiler/stage_06_typecheck/type_system/test_type.brp
scripts/compiler-check --changed
bin/blorp test --sanitize --timeout 180 \
    blorp/test/compiler/stage_06_typecheck/type_system/test_type.brp \
    blorp/test/compiler/stage_06_typecheck/type_system/test_context.brp \
    blorp/test/compiler/stage_06_typecheck/test_typecheck_decl.brp
benchmarks/compiler_typecheck_phase_profile bodies 1 8 32 64 4 memory
benchmarks/compiler_ctfe_typecheck_profile 3 24 32 retained selected
```

The changed-owner gate passed two production sources and four focused suites;
all 225 targeted sanitizer tests passed. Independent review found no blocking
issue and requested explicit empty-list coverage, which is included.

The plain body-phase worker preserves checksum
`4664138852255368204`, 13,926 allocations, 10,098 releases, 3,828 retained
objects, and 316,160 allocated bytes. In two warm direct runs, retired
instructions were 858.6M / 837.7M before and 834.8M / 834.5M after. Peak
footprint was 18.00M / 18.06M B before and 18.01M / 18.12M B after. These
short samples support near parity with a modest instruction reduction; they
do not establish a wall-time or memory-ceiling win. Worker size shrank from
5,837,792 to 5,837,632 B. The baseline/candidate worker keys are
`b6d63f768f2d7c6e5dd842d7c263993d40b8810de7c82161f5953df08aa27e4a`
and `d7b2e53ea3bfbbd4d57febc2419021e45b8bca2325d60f8ffab5a3010b43b0dd`.

The selected CTFE guard preserves checksum 2,538, 72 dependency body checks,
three reused bodies, zero errors, 770,319 / 770,316 allocations/releases,
and 3 / 192 retained objects/bytes. In one warm direct comparison, retired
instructions were 1,590,196,162 before and 1,569,010,719 after (−1.33%);
peak footprint was 14,991,696 B before and 14,942,544 B after (−0.33%).
Worker size shrank from 6,378,992 to 6,378,832 B. The baseline/candidate
worker keys are
`c5224a179db1d44cec16902ceb3c3fa5d37dad3ef2fe9504f6d27b69aa975df6`
and `3f6b36c850401878f74d865239158991e34dbb7a8edbc30e45395d6239809ce7`.
This supports a modest instruction win with no observed resource regression,
not a robust elapsed-latency claim.

## Acceptance and remaining work

- All four list-bearing type variants detect late metas; an empty tuple remains
  meta-free.
- The focused and selected-compilation checks preserve outputs, diagnostic
  behavior, allocation/retention counts, and avoid material instruction,
  footprint, or worker-size regressions.
- This cut remains a local traversal simplification. Step 4A still needs
  nominal session-owned meta identity and a measured solver-lifetime boundary;
  a larger validation fusion should be considered only after isolating its
  traversal work and diagnostic-order constraints.
