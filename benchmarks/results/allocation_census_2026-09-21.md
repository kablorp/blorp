# Allocation-analysis precision: cleanup, loop, and checkpoint classification (2026-09-21)

Motivating gap: `pure func total(xs: List[Int]) -> Int` with a plain `for`
loop reported "unknown: runtime_callback_boundary" before this change. Cause:
`cleanup_facts` in `allocation_analysis.brp` treated every `NamedType`
release under `ArcReleasePolicy` as an unknown runtime callback, including
`List`/`Dict`/`Set`, instead of only the container kinds that can actually
call back into user code (`Closure`, `Channel`, `Stream`/`FallibleStream`,
resource sources, network session types). The fairness pass's cooperative
checkpoint at every loop back-edge was also cataloged as an unknown runtime
callback, so *no* loop could be proven allocation-free regardless of its
body.

## Changes

- `blorp/src/compiler/stage_09_core/allocation_analysis.brp`: `cleanup_facts`
  now decomposes `List[T]`/`Set[T]`/`Dict[K, V]` into their element types'
  own (already-computed) cleanup facts instead of treating them as an opaque
  unknown boundary. Every other `NamedType` under `ArcReleasePolicy`
  (`Closure`, `Channel`, `Stream`/`FallibleStream`, resource sources, network
  session types, and anything else not recognized) is still unknown.
- `blorp/src/compiler/stage_09_core/allocation_contracts.brp`:
  - `CooperativeCheckpointExpr` is now `free_allocation_contract` (was
    `unknown: runtime_callback_boundary`). `blorp_cooperative_checkpoint`'s
    fast path only decrements a thread-local budget
    (`runtime.c:26007-26013`); its slow path resets the budget, polls
    cancellation (a `longjmp` into already-registered cleanup frames — those
    frames' own values are accounted at the types actually being cleaned up,
    not at the checkpoint), and calls `blorp_yield_now`
    (`runtime.c:25947-25971`), which records a pending wake and calls
    `mco_yield` — a coroutine stack switch, not a heap allocation. Neither
    path allocates.
  - The `CustomHashContainerConstructor` arm of `dict_construct_allocation_contract`
    now reports `unknown_call_target` / `UnknownCallAllocationDependency`
    (the user's hash/equals callback is a named, unresolved call target)
    instead of the generic `runtime_callback_boundary`.
  - Added `core_call_kind_operation_name` and `core_expr_operation_detail`:
    display-only helpers that name, for a `call` site, the matched Core call
    kind or runtime/foreign symbol, and for a `cleanup`/`control_flow` site,
    the type being released or iterated. These never feed back into
    classification.
- `blorp/src/compiler/stage_09_core/allocation_analysis.brp`: `AllocationSite`
  gained a `detail: String` field (empty when not applicable), populated
  once per site from `core_expr_operation_detail`.
- `blorp/src/compiler/stage_09_core/allocation_report.brp`: JSON and human
  reports render `detail`.
- `ALLOCATION_CONTRACT_CATALOG_REVISION` bumped 2 -> 3.

`union_cleanup_kind`/`union_cleanup_plan` (the recursive-union
`cleanup_scratch` rule) and `emit_iterative_union_destructor`/
`emit_union_destructor` (which already dispatch on that same
`union_cleanup_kind`) were already correct and consistent with each other
before this change; no runtime or emitter code was touched.

### Iterative-destructor policy, as found in the emitter

`emit_union_destructor` (`stage_10_backend/emit.brp`) picks between
`emit_simple_union_destructor` and `emit_iterative_union_destructor` by
calling `union_cleanup_kind` from `allocation_contracts.brp` — the same
function the allocation analysis calls. A union gets the iterative
destructor (`IterativeUnionCleanup`) exactly when at least one variant field
is typed as the union itself (`UnionType(union_decl.name)`) with
`ArcReleasePolicy` — i.e. a self-recursive field. `emit_iterative_union_destructor`
emits a `**stack`/`count`/`capacity` work list grown with `realloc` (doubling
from 64) so a long recursive chain (e.g. a linked list encoded as a union)
is released without host-stack recursion. That is the one real allocating
trap in an otherwise ordinary release, and it was already classified as
`may_allocate: cleanup_scratch` by `union_cleanup_plan` before this task.

### Cooperative-checkpoint policy, as found in the runtime

- Fast path, `runtime.c:26007-26013` (`blorp_cooperative_checkpoint`):
  decrements a `_Thread_local long` budget and returns if it is still
  positive. No allocation.
- Slow path, `runtime.c:25988-26001` (`blorp_cooperative_checkpoint_slow`):
  resets the budget, calls `__blorp_cancel_current_task_if_requested`
  (checks a cancellation flag; if set, drains already-registered cleanup
  frames and `longjmp`s out — the drained values' own release facts are
  accounted where those values are actually dropped, not here), then calls
  `blorp_yield_now` if a fiber is current.
- `blorp_yield_now`, `runtime.c:25947-25971`: records a pending wake
  (`blorp_fiber_record_pending_wake_locked`, no allocation) and calls
  `mco_yield` (minicoro coroutine stack switch — no heap allocation).

## Census command

```
input=$(benchmarks/self_compile_measure freeze --rev origin/main)
BLORP_CLI_C_OPTIMIZATION=-O2 make
bin/blorp compile --explain-allocations=json --no-format \
  --std-dir "$input/standard_library/src" "$input/blorp/src/main.brp" > /tmp/census.json
```

Both runs below used the **same frozen input** (`origin/main` at
`cf0138851282`) so the tables are a direct before/after diff attributable
only to this change, not to unrelated commits landing on `main` between the
original task write-up (input `10acd6104`, compiler `349fb4f7`) and this
run. `blorp/src/lib/runtime/native` and `standard_library/src/memory.brp`
were not touched.

## Owner status

| owner status | before | after | delta |
|---|---:|---:|---:|
| `core_no_known_allocation` | 2,484 | 2,626 | +142 |
| `may_allocate` only | 1,063 | 1,170 | +107 |
| `unknown` only | 3,136 | 2,641 | -495 |
| `may_allocate_and_unknown` | 9,328 | 9,574 | +246 |
| total owners | 16,011 | 16,011 | 0 |

142 owners moved to fully proven allocation-free; 495 owners lost every
unknown witness (most of them landed in `may_allocate_and_unknown` rather
than `core_no_known_allocation`, because their bodies also touch a real
`may_allocate` operation elsewhere, e.g. a `List` literal or a heap record).

## Unknown-reason sites, by category

| site category / unknown reason | before | after | delta |
|---|---:|---:|---:|
| `cleanup` / `runtime_callback_boundary` | 47,603 | 32,465 | -15,138 (-31.8%) |
| `call` / `runtime_operation` | 23,292 | 23,292 | 0 |
| `control_flow` / `runtime_callback_boundary` | 9,063 | 3,473 | -5,590 (-61.7%) |
| `call` / `unknown_call_target` | 1,388 | 1,388 | 0 |
| `record` / `runtime_callback_boundary` | 851 | 651 | -200 |
| `call` / `missing_function_body` | 151 | 151 | 0 |
| `call` / `foreign_call_boundary` | 27 | 27 | 0 |
| `tuple` / `runtime_callback_boundary` | 2 | 1 | -1 |
| total sites | 170,669 | 166,114 | -4,555 |

`control_flow`/`runtime_callback_boundary` did **not** reach zero. The 3,473
remaining sites are, with `detail` now naming the type, loops over
`List`/`Dict`/`Set` of genuinely opaque element types — mostly compiler-internal
unions like `CoreExpr`, `SemanticType`, and `ParsedExpr` that transitively
contain `FunctionType`/`Closure`-typed fields (lambda bodies, converted
closures) somewhere in their variants, plus a residue of `Option[List[T]]`
and other `Option`-wrapped containers, which this task did not attempt to
resolve (`Option`'s payload release policy is computed separately in
`nullable_managed_option_payload_release_policy` and was out of scope). These
are correct conservative answers, not remaining bugs: forcing them to zero
would require either resolving closure call targets (a much larger,
unrelated project) or unsoundly special-casing types by name, which the
roadmap's "Conservative answers and diagnostics" section rules out. No
`call` category counts moved, because the codebase under test has zero
`CustomHashContainerConstructor` dict literals with non-empty entries; the
fix is covered by unit tests instead.

## `may_allocate` reasons (unchanged except the one this task targets)

| may reason | before | after |
|---|---:|---:|
| `cleanup_scratch` | 15,253 | 23,813 |
| `managed_object` | 20,521 | 20,521 |
| `raw_buffer` | 6,328 | 6,328 |
| `cow_fallback` | 861 | 861 |
| `closure_environment` | 1,025 | 1,025 |
| `tuple_storage` | 2,437 | 2,437 |
| `capacity_growth` | 238 | 238 |
| `heap_box` | 210 | 210 |
| `task` | 4 | 4 |

Every `may_allocate` reason except `cleanup_scratch` is byte-for-byte
unchanged before/after, which is the expected signature of a precision fix
that only removes false unknowns and never relaxes a real risk.
`cleanup_scratch` rose by 8,560: `List`/`Dict`/`Set` containers of a
recursive union (e.g. a `List[CoreExpr]`-shaped structure, or any container
of a self-recursive union type) previously hit the blanket
`NamedType -> unknown` arm before ever reaching `union_cleanup_plan`; now
that the container decomposes into its element type first, those sites
correctly resolve to `may_allocate: cleanup_scratch` — the same fact
`union_cleanup_plan` already computed for a bare recursive-union drop,
matching the emitter's iterative-destructor policy.

## Probe

```
pure func total(xs: List[Int]) -> Int:
	var sum: Int = 0
	for x in xs:
		sum += x
	sum
```

Before: `unknown: runtime_callback_boundary`. After:
`total#121: no known allocation in analyzed Core; executable coverage incomplete`.

## Gates

```
benchmarks/self_compile_measure lock -- bin/blorp test --timeout 180 \
  blorp/test/compiler/stage_09_core/test_core_allocation_contracts.brp \
  blorp/test/compiler/stage_09_core/test_core_allocation_analysis.brp \
  blorp/test/compiler/stage_09_core/test_core_allocation_report.brp
BLORP_GATE_RESULT gate=bin/blorp-test-allocation-suites status=PASS tests=53

benchmarks/self_compile_measure lock -- scripts/compiler-check --changed --base origin/main
BLORP_GATE_RESULT gate=compiler-check status=PASS passed=2445 failed=0 tests=2445

# baseline measured first, from a separate origin/main worktree/build:
benchmarks/self_compile_measure --program small --label precision-baseline \
  --input-rev origin/main --samples 1 --output /tmp/precision_baseline.json
benchmarks/self_compile_measure --program small --label precision \
  --input-rev origin/main --samples 1 --baseline /tmp/precision_baseline.json --require-identical
# output C : IDENTICAL (45827 vs 45827 bytes)
BLORP_GATE_RESULT gate=self_compile_measure_require_identical status=PASS output_c=identical bytes=45827
```

The identical-C run's instruction-retired delta (+78%) and peak-RSS delta
(+9%) are toolchain noise, not a regression: `self_compile_measure`'s own
`make` step defaults to `-O0` for the candidate build, while the baseline
measurement had been built at `-O2` in its own worktree; the tool's own
"toolchain mismatch: optimization differs" line flags this. The metric that
matters for a report-only change — generated C byte-for-byte identity — is
exact.
