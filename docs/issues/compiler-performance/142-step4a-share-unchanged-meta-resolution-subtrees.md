# Step 4A: Share Unchanged Meta-Resolution Subtrees

**Status:** Focused implementation, resource screen, and compiler gate complete.
This is an independent finalization cut, not session-owned
`MetaId` or Step 4A completion.

## Context and boundary

`resolve_type_metas` rebuilt every recursive `SemanticType` node and list even
when the input contained no meta, or contained only unbound metas that must
remain unchanged. It is called during inference for binding and variable
types. `zonk_type` already avoided the fully meta-free case with a separate
`type_contains_meta` scan, but then rebuilt unchanged siblings when any meta
was present. Packet 141's session issuer remains the next coordinated
identity migration; changing `SemanticMetaType(Int)` without a valid issuer at
every fresh-context boundary would recreate the cross-session alias.

The first test asserts that resolving a nested meta-free function/array type
performs no tracked allocations. It failed before the change (1 of 31 context
tests failed) and passed after it. A second test requires the same behavior
for a nested *unbound* issued meta. Existing bound-chain, zonk, unissued-meta,
and unification tests guard the changed path's semantics.

## Implementation

`resolve_type_metas_if_changed` returns `None` when a subtree is unchanged
and `Some(resolved)` only when a binding or finalization actually changes it.
`None` never means a failed resolution. Lists retain their existing storage
until the first changed child, when `List.set` performs one COW clone;
subsequent replacements mutate that unique clone. Bound meta chains still
resolve recursively; issued unbound metas still become their origin variable
only for zonking, and unissued metas remain visible to the solved-body guard.

```blorp
match resolve_type_metas_if_changed(context, typ, finalize_unbound):
    Some(resolved): resolved
    None: typ  -- preserve the original immutable subtree
```

This is one traversal for both meta-free and meta-bearing inputs. It follows
the existing change-sensitive tree-rewrite precedent in `semantic_type.brp`.
It does not add an interning table, source strings, a second solver authority,
or a meta-ID compatibility path.

## Fast feedback and resource screen

The retained `compiler_meta_free_resolution_profile.brp` constructs nested
types and bindings outside the measured loop. Run its two modes with the
existing cached compiler to reproduce the narrow work:

```bash
env BLORP_COMPILER_BENCHMARK_SKIP_BUILD=1 \
    benchmarks/compiler_blorp_benchmark_runner \
    compiler-meta-free-resolution-profile \
    blorp/benchmark/compiler/compiler_meta_free_resolution_profile.brp \
    plain 16 4096 meta-free

# Replace meta-free with bound to screen a type containing a bound meta.
bin/blorp test blorp/test/compiler/stage_06_typecheck/type_system/test_context.brp
scripts/compiler-check --changed
benchmarks/compiler_ctfe_typecheck_profile 3 24 32 retained selected
```

One warm direct worker sample at width 16 / 4,096 iterations, comparing the
old recursive rebuild with the single-pass candidate, gave:

| Mode | Allocations/releases, old → new | Retired instructions, old → new | Peak footprint, old → new |
| --- | ---: | ---: | ---: |
| `meta-free` | 270,336 → 135,168 | 375,163,511 → 224,600,153 | 1,098,016 → 1,081,632 B |
| `bound` | 270,336 → 266,240 | 375,463,926 → 376,337,565 | 1,114,400 → 1,098,016 B |

Both modes resolved all iterations, balanced allocations/releases, and had
zero retention. The meta-free case halves allocation calls and cuts focused
instructions about 40%; the bound case is near instruction parity (about
+0.23%) with fewer allocations. The small peak differences are one-sample
screens, not a memory-ceiling claim. The final benchmark derives the bound meta ID from the issued
type and gates balanced allocation/release counts and zero retention; that
setup/exit change is outside the measured loop. The final worker grew 944 B
(about 0.13%) relative to the baseline worker. The before/after workers are
local source snapshots, not Git
revisions; their cache keys are
`5648205fe802b9dcf781b4981279c8ecd6d771ea3e12aa1d6c320d3668d7c0e5`
and `57000b45f4b6c34c5498cee3e4d602f4176adef7cfcf4b49f4118c0aa46afacd`.

The focused context suite passed 32/32, changed-owner compiler checks passed
for the modified source, and `scripts/test compiler-blorp` passed 4,585/4,585.

The selected CTFE guard kept checksum 2,538, 72 dependency body checks,
three reuses, zero errors, and three objects/192 B retained. Allocation calls
fell 770,319 → 770,145. One warm direct pair had 1,570,290,274 →
1,569,218,936 retired instructions and 14,942,520 → 14,876,984 B sampled
peak footprint. Both are near parity at whole-worker scale; the short elapsed
times are not a latency claim. Worker size rose 1,312 B (about 0.02%). This
pair uses the prior packet-140 worker and the current candidate worker, with
local cache keys
`58f0879968eb6687b0bb82dd1fc9b6aa84b70b14b202a75569e0efd0349d30c0`
and `d14644e433d752932981c316068a8613285f806ce6574344f19d64eee6a84c4c`.

## Acceptance and next slice

- The focused context test fails before the change and passes after it;
  meta-free and unbound recursive types allocate nothing when resolved.
- Existing bound, unbound, finalization, and diagnostic-order behavior stays
  unchanged in the relevant compiler gates.
- Both focused benchmark modes remain correct, balanced, and free of retained
  objects; no material regression appears in allocations, instructions, peak
  footprint, or worker size on the selected compiler guard.
- This cut does not satisfy the Step 4A session-provenance contract. Packet 141
  remains the starting point for the explicit issuer and nominal `MetaId`
  migration; it must be implemented across the fresh-solver boundaries rather
  than by adding a packed integer or string-keyed adapter.
