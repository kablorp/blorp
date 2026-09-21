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

## Cut 2 (2026-09-21): closures, functions, Channel, and Option decompose too

Follow-up to cut 1. Cut 1 left `List`/`Dict`/`Set` of closures, closure-holding
records, `Channel`, and `Option`-wrapped containers unknown, and treated
custom-hash containers as a release-time risk. This cut checked each of
those assumptions against the runtime and corrected the ones that did not
hold.

### What the runtime actually does on release

- **Closures are safe to decompose.** `blorp_closure_destroy` (`runtime.c`)
  only calls `blorp_release` on each retained capture slot named by
  `env_release_mask`; it never runs arbitrary user code. Capture retention
  at creation is symmetric: `emit.brp`'s `closure_capture_box_expr` calls
  `blorp_retain((blorp_Object*)...)` for managed-pointer captures. So
  releasing a closure is exactly as risky as releasing its captures — no
  more, no less. `FunctionType` values are ARC-managed the same way
  (`cleanup_release_policy_for_type` gives both `NamedType("Closure", [])`
  and `FunctionType` `ArcReleasePolicy`) and decompose identically.
  The catch: a bare `Closure`/`FunctionType` `CoreType` cannot say which
  concrete closure literal occupies a given slot (the same "which instance
  is this really" problem as an erased union payload), so there is no
  single field type to recurse into the way a record field works. The fix
  is a whole-program bound: scan every `ClosureCreateExpr` anywhere in the
  program (not just top-level — nested closures too) via
  `program_closure_capture_types`, merge all their captures' cleanup facts
  once via `closure_capture_cleanup_facts`, and cache the result on
  `AllocationTypeIndex.closure_capture_facts`. Every `Closure`/`FunctionType`
  release in the program then decomposes to that one merged fact set. A
  capture that is itself `Closure`/`FunctionType`-typed contributes nothing
  extra at this step (computed against an index with an still-empty
  `closure_capture_facts`) because whichever literal produced that captured
  closure is itself found independently by the same whole-program scan — a
  one-pass flattening, not an approximation.
- **`Channel` is not a special "resource" case.** `blorp_channel_destructor`
  only calls the generic `elem_release` on buffered values — the same
  mechanism `blorp_dict_destroy`/`blorp_list_destroy` use for element
  release. `Channel[T]` now decomposes into `T`'s own cleanup facts exactly
  like `List`/`Set`.
- **`Option` decomposes into its payload.** The nullable/managed
  representation means "release the payload if present"; `cleanup_facts`
  now appends `{typ = payload, policy = cleanup_release_policy_for_type(payload)}`
  instead of treating any `ArcReleasePolicy` `Option` as unknown. `Result`
  was already fully decomposed via `StackResultType`/`BoxedResultType` in
  cut 1 (a separate representation, not a `NamedType`); no change needed
  there.
- **Custom-hash containers are not a release-time risk — the original cut-2
  hypothesis for this one did not hold.** `blorp_dict_destroy` and
  `blorp_set_destroy` (`runtime.c`) never call `dict->hash_fn`/`dict->eq_fn`
  (or the `Set` equivalents) during teardown; those fields are read only by
  the insert/lookup/rehash paths. Release only calls the generic
  `key_release`/`value_release`, identical to an ordinary `Dict`/`Set`. The
  `hash_fn`/`eq_fn` fields are plain C function pointers (not
  `blorp_Closure*`), so there is not even a captured closure to release
  alongside the container. The genuine custom-hash risk stays exactly where
  cut 1 already put it: `unknown_call_target` on the *construction* site
  (`dict_construct_allocation_contract`'s `CustomHashContainerConstructor`
  arm), not cleanup. No cleanup-side change was made for this case, and the
  requested "custom-hash-holding record" negative test is not constructible
  because there is no such cleanup-time distinction to observe — instead,
  `test_record_holding_dict_field_cleanup_is_free_regardless_of_hash_kind`
  demonstrates the actual (free) behavior directly.
- **Resources with a real finalizer stay unknown, confirmed.**
  `blorp_tls_session_destroy` and `blorp_websocket_session_destroy` call
  `backend->close(session)` — a real backend callback, not just element
  release. `blorp_stream_destroy`/`blorp_fallible_stream_destroy` call
  `s->state_cleanup(s)`, a function pointer chosen per-instance by which
  stream combinator (`map`/`filter`/`take_while`/...) built that particular
  stream — a second "which instance is this" type-erasure problem, but
  without an equivalent of `CoreClosureCapture` to bound it program-wide, so
  it stays unknown. `Stream`/`FallibleStream`, resource sources, and network
  session types are the remaining `NamedType` fallback case in
  `cleanup_facts`.

### Changes

- `blorp/src/compiler/stage_09_core/allocation_analysis.brp`:
  - `AllocationTypeIndex` gained `closure_capture_facts: CoreLocalAllocationFacts`.
  - Added `scan_closure_capture_types`, `program_closure_capture_types`, and
    `closure_capture_cleanup_facts` to compute it once per analysis.
  - `cleanup_facts`'s `NamedType` arm now also decomposes `("Channel", [element])`
    like `List`/`Set`, `("Option", [payload])` into the payload, and
    `("Closure", [])` into `index.closure_capture_facts`. The `FunctionType`
    arm (previously grouped with `TypeParameterType`/`SelfType` as unknown)
    is now its own arm using `index.closure_capture_facts`;
    `TypeParameterType`/`SelfType` remain unknown (unresolved generics,
    unrelated to this task).
- No changes to `allocation_contracts.brp`, `allocation_report.brp`, or the
  emitter/runtime — cut 1 already made the emission-time and construction-time
  fixes this cut needed to build on.

### Before/after census (identical frozen input, `origin/main` cut-1 commit `3984badfa`)

Both runs used the same frozen snapshot of that exact commit, so this table
isolates cut 2's effect from cut 1's (already-landed) effect and from
unrelated commits landed on `main` afterward (a runtime-oracle allocation
counter and a build fix, neither touching the allocation-analysis files).

| owner status | before (cut 1 only) | after (cut 1 + cut 2) | delta |
|---|---:|---:|---:|
| `core_no_known_allocation` | 2,869 | 2,927 | +58 |
| `may_allocate` only | 1,209 | 1,733 | +524 |
| `unknown` only | 2,804 | 2,496 | -308 |
| `may_allocate_and_unknown` | 10,006 | 9,732 | -274 |
| total owners | 16,888 | 16,888 | 0 |

| site category / unknown reason | before | after | delta |
|---|---:|---:|---:|
| `cleanup` / `runtime_callback_boundary` | 36,725 | 12,478 | -24,247 (-66.0%) |
| `call` / `runtime_operation` | 24,852 | 24,852 | 0 |
| `control_flow` / `runtime_callback_boundary` | 3,720 | **0** | -3,720 (-100%) |
| `call` / `unknown_call_target` | 1,446 | 1,446 | 0 |
| `call` / `foreign_call_boundary` | 1,091 | 1,091 | 0 |
| `record` / `runtime_callback_boundary` | 630 | **0** | -630 (-100%) |
| `call` / `missing_function_body` | 192 | 192 | 0 |
| `tuple` / `runtime_callback_boundary` | 1 | **0** | -1 (-100%) |
| total sites | 176,760 | 176,760 | 0 |

`control_flow`, `record`, and `tuple` category unknowns from
`runtime_callback_boundary` are now fully eliminated — every remaining
`runtime_callback_boundary` unknown is in the `cleanup` and (transitively,
via loop iterable cleanup) `call` categories, and each now names the actual
resource/stream/network type via `detail` (cut 1's site-naming field).

| may reason | before | after |
|---|---:|---:|
| `cleanup_scratch` | 26,189 | 32,966 |
| `managed_object` | 20,654 | 20,654 |
| `raw_buffer` | 6,537 | 6,537 |
| `cow_fallback` | 849 | 849 |
| `closure_environment` | 1,120 | 1,120 |
| `tuple_storage` | 2,521 | 2,521 |
| `capacity_growth` | 193 | 193 |
| `heap_box` | 281 | 281 |
| `task` | 5 | 5 |

Every `may_allocate` reason except `cleanup_scratch` is unchanged, the same
signature as cut 1: only false unknowns are removed, no real risk is
relaxed. `cleanup_scratch` rose by 6,777 for the same reason as cut 1 — more
paths (now through `Channel`/`Option`/`Closure` as well as `List`/`Dict`/`Set`)
reach a recursive union's `union_cleanup_plan` instead of stopping at a
blanket unknown first.

### Gates

Allocation test suites (`bin/blorp test`, using its own `BLORP_GATE_RESULT`
env-driven summary line, not composed here):

```
benchmarks/self_compile_measure lock -- env BLORP_GATE_RESULT=alloc-precision-cut2-tests \
  bin/blorp test --timeout 180 \
  blorp/test/compiler/stage_09_core/test_core_allocation_contracts.brp \
  blorp/test/compiler/stage_09_core/test_core_allocation_analysis.brp \
  blorp/test/compiler/stage_09_core/test_core_allocation_report.brp
BLORP_GATE_RESULT gate=alloc-precision-cut2-tests status=PASS passed=59 failed=0 tests=59
```

`scripts/compiler-check`'s own line:

```
benchmarks/self_compile_measure lock -- scripts/compiler-check --changed --base origin/main
BLORP_GATE_RESULT gate=compiler-check status=PASS passed=2074 failed=0 tests=2074
```

`self_compile_measure --require-identical` (this tool does not print a
`BLORP_GATE_RESULT` line; reporting its actual output verbatim). Baseline
measured first from a separate worktree pinned at cut 1's landed commit
(`3984badfa`), candidate measured from this branch against the same input
revision:

```
benchmarks/self_compile_measure --program small --label cut2-parent --input-rev 3984badf \
  --samples 1 --output /tmp/cut2_parent_measure.json          # baseline, parent worktree
benchmarks/self_compile_measure --program small --label cut2 --input-rev 3984badf \
  --samples 1 --baseline /tmp/cut2_parent_measure.json --require-identical --allow-toolchain-mismatch
output C : IDENTICAL (45827 vs 45827 bytes)
```
Exit code 0. `--allow-toolchain-mismatch` was required because the tool's own
`make` step rebuilds the candidate at `-O0` while the baseline was built at
`-O2` in its own worktree — the same toolchain-level (not content-level)
mismatch cut 1 hit; the tool distinguishes this from an actual C difference
via a separate exit code (3 for a real diff, 4 for a toolchain mismatch), and
only the identical-bytes result is the acceptance evidence for a report-only
change. Without `--allow-toolchain-mismatch` the run exits 4 on the
toolchain guard alone, even though the C is identical — worth flagging for
whoever reviews future report-only gates against this tool: check
`output bytes` and `output C : IDENTICAL` in the printed comparison, not
just the process exit code, since 4 does not mean the content differs.

### Probe

`Option[List[Int]]` and closures capturing only scalars, which both showed
up as `unknown: runtime_callback_boundary` in the cut-1 census (821 and part
of the "List of complex union types" residue respectively), now report no
known allocation, matching the `total(xs)` probe from cut 1.
