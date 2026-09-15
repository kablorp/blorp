# Step 4A: Solver State And Indexed Bindings

**Status:** Implemented in this worktree; Step 4A remains open. This follows
the validated-body product in
[packet 102](102-step4a-validated-body-product-first-cut.md).

## Context and implementation

`Context` previously exposed three independently editable meta fields:
`meta_origins`, `meta_bindings`, and `fresh_meta_counter`. Binding lookup
scanned a sparse list and replacement rebuilt it. More importantly,
unification accepted `SemanticMetaType(0)` when the session had issued no
meta 0. The new regression test failed on that behavior before this cut.

The solver now has one opaque value with parallel issued-meta arrays:

```blorp
private record MetaSolverStateRep {
    origins: List[String],
    bindings: List[Option[SemanticType]]
}
opaque type MetaSolverState = MetaSolverStateRep

record Context {
    -- Non-solver fields omitted.
    solver: MetaSolverState
}
```

The frontier is `origins.length()`, not a separately editable counter.
Issuing a meta appends one origin and one `None` binding. `lookup_meta`
reads its indexed slot. `bind_meta` returns `Option[Context]` and rejects
negative or unissued indices; unification propagates that rejection. The
dimension solver reads the same indexed array, without a per-call conversion
to a pair list. The accepted/rejected body-product boundary from packet 102
is unchanged.

Tests that fabricated bindings for unissued IDs now issue metas first. The
infer-session reconstruction benchmark creates a stale seed by issuing a
meta, rather than manufacturing inconsistent origin and frontier counts.
Count/equality observations preserve its reset check without exposing the
solver representation.

## Fast feedback and representation decision

```bash
bin/blorp test blorp/test/compiler/stage_06_typecheck/type_system/test_context.brp \
  blorp/test/compiler/stage_06_typecheck/type_system/test_dim_solver.brp
bin/blorp test blorp/test/compiler/stage_06_typecheck/test_infer.brp
bin/blorp test blorp/test/compiler/pipeline/test_infer_session_reconstruction_profile_benchmark.brp
scripts/compiler-check --changed
benchmarks/compiler_meta_binding_width_profile 128 16
benchmarks/compiler_ctfe_typecheck_profile 3 24 32 retained selected
```

The retained width probe issues, binds, and looks up each ID, checks its
exact mapped value, and fails on any missing/mismatched binding. It also
contains a synthetic linear-list reference. That reference omits the real
`Context` and is **not** a production before/after baseline. The useful
screen compares the solver path across separately compiled candidate stores.

Exploratory candidate snapshots were built by
`benchmarks/compiler_blorp_benchmark_runner` with Apple clang 21.0.0,
`-O2 -fwrapv -pipe -w`, on Darwin 25.6.0 arm64. The runner cache keys below
hash all compiler and benchmark `.brp` sources, the compiler executable,
runner, C compiler, and platform. They identify the local uncommitted
snapshots; they are not reproducible git commits:

| Store | Cached worker key | 128 × 16 solver allocations | Retired instructions, B-A-A-B sample | Peak footprint, B-A-A-B sample |
| --- | --- | ---: | --- | --- |
| Grouped sparse list | `5d9629a187ef47d0b786a8df7a63ec7ec0997b59bfa711bd76b8bf98da8d09e1` | 30,688 | 131,369,058; 131,056,574 | 1,245,472; 1,245,472 B |
| Indexed `List[Option[SemanticType]]` | `020962eae4607b548cec76d9059723ff1a137d87e6c7c6444bd951962e5cf8af` | 20,480 | 102,006,046; 101,711,406 | 1,245,472; 1,245,472 B |

The direct command for each snapshot was `/usr/bin/time -l WORKER ARGS`:
sparse used `128 16`; the older indexed snapshot used `16` because its
prototype argument parser fixed width at 128 and read iterations from the
first user argument. Both reported width 128, 16 iterations, checksum
132,096, and zero retained objects/bytes. The two short measurements were
alternated sparse-indexed-indexed-sparse; elapsed microseconds are too noisy
to claim a wall-time win. The current retained probe has corrected argument
parsing and per-ID validation; on the final indexed store at width 128 × 16
it reports `linear_valid=True`, `solver_valid=True`, equal checksum 132,096,
20,480 solver allocations/releases, and zero retention.

An integer-dictionary candidate reduced width-probe allocations further
(18,432 at width 128 × 16) but raised its measured peak footprint to
1,442,080–1,507,616 B in a paired run, versus the sparse-list baseline's
1,229,088 B. It was removed. At widths 16, 32, 64, 128, and 512, the
indexed candidate was also checked with the corrected probe; it preserved
exact IDs and zero retention. The width screen is a mechanism test, not an
end-to-end compiler latency claim or proof that all body widths benefit.

The selected retained CTFE guard preserves checksum 2,538, 72 body checks,
three reused bodies, 769,887 allocations, 769,884 releases, and 3 / 192
retained objects/bytes relative to packet 102. Its pre-cut worker key is
`65f071e78ad843a41c81e9859618b57da26c89feaa3962a61534396da0685754`;
the final indexed worker key is
`cffdab21558c98b913089b69779a762e3e00bea45fe2ba900b35f023d1ed4e1e`.
In a B-A-A-B direct run, the warmed baseline had 1,568,794,129 retired
instructions and 14,958,928 B peak footprint; the two indexed runs had
1,568,868,141 / 1,566,944,727 instructions and 14,942,520 / 14,909,752 B
peak footprint. The first baseline run had 297 page faults, so no wall-time
win is claimed. The profiled worker grew from 6,358,544 to 6,391,776 bytes
(+0.52%), below the roadmap's 1% investigation threshold.

Focused context (18), dimension (7), and inference (309) tests pass. The
changed-owner compiler check passed four sources and 11 suites. On the final
indexed candidate, the independent broad compiler gate passed 4,559 / 4,559
and targeted context/dimension/inference ASan/UBSan passed 334 / 334.

## Acceptance and remaining work

This cut is acceptable when issued-meta binding and reset invariants hold,
dimension decisions and diagnostics remain unchanged, and both the focused
width probe and compilation guard show no material regression. It is not
Step 4A completion:

- `SemanticMetaType(Int)` remains freely constructible. Same-index metas from
  separate sessions are still indistinguishable. Nominal, session-owned
  `MetaId` needs a construction/provenance design.
- `Context` contains the solver value, so solver lifetime is not detached
  from broader typecheck state.
- Inferred expressions still use `finalize_infer_result`; final
  complete-program validation and raw Core materialization remain.
- The validation-rule inventory and compatible final-walk fusion remain.

Step 4B type interning is optional and was not attempted.
