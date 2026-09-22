# Perceus engine allocation attribution (2026-09-22)

Issue P0 of `docs/PERCEUS_CLEANUP_ISSUES.md`: allocation-free, opt-in,
C-side counters inside the Perceus drop-insertion engine, so the roughly
59-60M allocations of `pass_perceus_complete` on the self-compile are
attributed by Core node kind and by named helper instead of the 94%
"unattributed" left by `perceus_allocation_attribution_2026-09-22.md`.
Measurement only; no production code path changed (confirmed below with
`--require-identical`).

## Go / no-go for P3, P4, P5

- **P3 (resolved-value index updates above 5% of the pass?).** No.
  `add_resolved_value` and `without_bound_value` -- the only two places that
  rebuild `PerceusResolvedValueIndex`'s
  `Dict[String, Dict[Int, Dict[Int, Int]]]` -- charge **616,704** and
  **197,464** self allocations respectively, **814,168** together, **1.34%**
  of the pass's 60,823,087 allocations. `PerceusResolvedValueIndex` is
  rebuilt (not just queried) 137,953 times. This does not clear P3's
  allocation-share gate on its own; P3's other starting condition (step 1 of
  `CORE_ID_MIGRATION.md` landing, which would make `uniq` unique per binder)
  is independent of this measurement and not evaluated here.
- **P4 (frame constructions above 5%?).** No. `PerceusInsertBindingFrameStack`
  is pushed **269,077** times across the walk. Its own docstring's
  invariant -- "each frame carries the rest of the stack as its last field
  ..., so a push costs one allocation" -- makes the count a direct
  allocation count: 269,077 / 60,823,087 = **0.44%**.
- **P5 (`PerceusInsertedExpr` / `PerceusManagedLetPlan` / `direct_consume`
  wrapper above 5%?).** No, individually. `inserted_expr` (the
  `PerceusInsertedExpr` constructor) is **4.67%** (2,843,428 of 60,823,087,
  1,849,101 constructions, 1.538 allocations/call); `plan_managed_let` (the
  `PerceusManagedLetPlan` constructor) is **0.47%** (283,972 allocations,
  57,585 constructions). Combined they are 5.14%, just over the line, but
  P5 treats them as separate small-shape changes, not one combined cut, and
  neither clears 5% alone. `inserted_expr` is the closest of the three to
  the threshold and the more promising of the two if P5 is prioritized.
  `PerceusDirectConsume`'s own construction is not separately wrapped (it is
  a few-line branch inside `inserted_expr`/`inserted_non_binding_expr`), so
  its cost is a strict subset of `inserted_expr`'s 4.67% and therefore also
  under 5%.

None of P3, P4, P5 clears the 5%-of-the-pass bar on this data. The most
allocation-heavy single thing this profile found is not on that list:
`rebuild_managed_let` alone is **25.66%** of the whole pass (15,605,213
allocations, 57,472 calls, 271.5 allocations/call) -- the managed-`let`
rewrite path (balancing, protecting repeated consumes,
`retain_alias_source_in_body`, the constructor-match/if branch transforms).
That is outside P0's scope to fix, but is the number a future issue should
cite.

## Table

Frozen input: `benchmarks/self_compile_measure freeze --rev origin/main`
(current `origin/main`, commit `a49a0d2e94f3872d2caf6018ede2a142f48d3fb1`).
Program: the full self-compile (`blorp/src/main.brp`). Reference row from
the harness, same input, `BLORP_CLI_C_OPTIMIZATION=-O2`:
`pass_perceus_complete` = **60,823,087** allocations.

### Per Core node kind (`insert_drops_expr_inner_result`'s own dispatch)

Self = allocations charged directly to a call of that kind, excluding
whatever its own recursive children already charged to themselves.
Inclusive = self plus every recursive child. Only kinds with a nonzero
count are shown; the full run emitted 49 distinct `CoreExpr` kinds (see the
raw log for the complete list -- most are 2 allocations/call, the fixed
cost of one `Dup`/`Drop`-free rewrap).

| Kind | Calls | Self allocs | Self % of pass | Inclusive allocs | Self/call |
| --- | ---: | ---: | ---: | ---: | ---: |
| LetExpr | 37,517 | 5,328,013 | 8.76% | 51,138,666 | 142.02 |
| LengthMatchExpr | 2,362 | 3,004,814 | 4.94% | 10,068,390 | 1272.15 |
| ConstructorMatchExpr | 5,538 | 2,926,748 | 4.81% | 10,450,073 | 528.49 |
| VarExpr | 489,948 | 979,896 | 1.61% | 2,939,688 | 2.00 |
| SeqExpr | 4,697 | 614,331 | 1.01% | 3,543,829 | 130.79 |
| CallExpr | 86,783 | 173,566 | 0.29% | 5,933,190 | 2.00 |
| BorrowLetExpr | 16,809 | 171,828 | 0.28% | 1,227,260 | 10.22 |
| AssignExpr | 4,588 | 153,890 | 0.25% | 809,943 | 33.54 |
| FieldExpr | 29,880 | 59,760 | 0.10% | 327,004 | 2.00 |
| LiteralExpr | 30,905 | 61,810 | 0.10% | 123,620 | 2.00 |
| DupExpr | 25,698 | 51,396 | 0.08% | 397,661 | 2.00 |
| StaticStringLiteralExpr | 25,241 | 50,482 | 0.08% | 100,964 | 2.00 |
| BinaryExpr | 20,280 | 40,560 | 0.07% | 445,262 | 2.00 |
| IfExpr | 6,747 | 13,494 | 0.02% | 13,559,675 | 2.00 |
| (44 more kinds, each under 0.02% of the pass) | -- | -- | -- | -- | -- |

`IfExpr`'s huge inclusive/self gap (13,559,675 vs 13,494) is expected: an
`if` is cheap to rewrap itself, but its branches are arbitrary managed-let
chains that dominate the program.

### Per named helper

| Helper | Calls | Self allocs | Self % of pass | Inclusive allocs | Self/call |
| --- | ---: | ---: | ---: | ---: | ---: |
| `rebuild_managed_let` | 57,472 | 15,605,213 | **25.66%** | 15,605,213 | 271.53 |
| `inserted_expr` | 1,849,101 | 2,843,428 | 4.67% | 2,843,428 | 1.54 |
| `insert_drops_change_aware_call` | 159,096 | 2,092,444 | 3.44% | 14,535,779 | 13.15 |
| `add_resolved_value` | 151,446 | 616,704 | 1.01% | 616,704 | 4.07 |
| `without_bound_value` | 98,732 | 197,464 | 0.32% | 197,464 | 2.00 |
| `plan_managed_let` | 57,585 | 283,972 | 0.47% | 283,972 | 4.93 |
| `rewrite_loop_body` | 4,089 | 267,521 | 0.44% | 3,922,917 | 65.43 |
| `insert_drops_change_aware_aggregate` | 17,121 | 129,594 | 0.21% | 1,411,265 | 7.57 |
| `insert_drops_change_aware_normalized_expr` | 711,930 | 112,394 | 0.18% | 26,499,307 | 0.16 |
| `insert_drops_change_aware_fixed_ownership` | 75,737 | 46,286 | 0.08% | 873,990 | 0.61 |

`rebuild_managed_let` and `insert_drops_change_aware_call` have no self-only
allocations beyond what is already inclusive of their non-instrumented
callees (`retain_alias_source_in_body`, `balance_let_body_legacy`,
`transform_let_if_body`/`transform_let_constructor_match_body`,
`protect_repeated_consumes`, `freshen_shadowed_match_bindings`,
`call_ownership_normalization_reuses_source`, etc. are not separately
wrapped, so their cost is folded into the wrapping helper's self number,
not attributed further).

### Construction counts

| Kind | Count |
| --- | ---: |
| `PerceusInsertedExpr` | 1,849,101 |
| `PerceusManagedLetPlan` | 57,585 |
| `PerceusInsertBindingFrameStack` (frame pushes) | 269,077 |
| `PerceusResolvedValueIndex` (rebuilds) | 137,953 |

### Coverage

Sum of self allocations across every reported node kind and helper:
**35,974,032**, **59.15%** of the pass's 60,823,087 allocations -- up from
the 5.5% attributed to public helpers alone in
`perceus_allocation_attribution_2026-09-22.md`. The remaining 40.85%
(24,849,055 allocations) happens before the walk's first
`insert_drops_expr_inner_result` call, inside `insert_drops_program`'s own
setup (`CoreResolve.resolve_global_value_refs`, `build_env`,
`infer_user_call_contracts` -- the last of which the prior profile measured
directly at 5.36% of the pass on this same program) and inside
`rewrite_decl`'s own per-declaration bookkeeping, none of which this issue
instruments (out of scope: P0's target was the drop-insertion engine
itself, per the issue text).

### `perceus_work_*` fallback counters (`perceus/work_counters.brp`)

These remain `@debug_only` marker functions with no call sites recording
dynamic counts in a normal or `BLORP_PERCEUS_ENGINE_METRICS` build; getting
exact dynamic call counts needs the `--profile-mode exact` /
`FunctionProfileExact` instrumented-build path documented in
`benchmarks/README.md`'s "Sampling A Pass" section, which is a separate,
larger undertaking (a profiled self-hosted `bin/blorp` compiling the frozen
input) out of scope for this opt-in-counters issue -- the same conclusion
`perceus_allocation_attribution_2026-09-22.md` reached for these same
counters. They are enumerated here by cause instead, unchanged from that
profile's classification:

- **Missing identity** (the `has_unresolved_identity`/alias-fallback path
  the identity migration removes): `perceus_work_borrowed_call_alias_fallback_requests`,
  `perceus_work_borrowed_aggregate_alias_fallback_requests`,
  `perceus_work_borrowed_result_alias_fallback_requests`,
  `perceus_work_borrowed_global_alias_fallback_requests`,
  `perceus_work_lambda_alias_fallback_requests`.
- **Unsupported expression shape**: `perceus_work_contract_scalar_fallback_analyses`,
  `perceus_work_contract_dup_fallback_analyses`,
  `perceus_work_contract_shadow_fallback_analyses`,
  `perceus_work_legacy_count_node_visits`.
- **Missing ownership summary** (the "no contract, fall back to full
  ownership-use summary" path in `summarize_linear_call`): folded into
  `perceus_work_linear_summary_requests`/`perceus_work_linear_summary_node_visits`,
  not separately marked.
- **Structural bookkeeping, not a fallback** (visit/reconstruction/reuse
  counters for the borrowed-normalization and contract-collection walks):
  every other `perceus_work_*` name -- `perceus_work_borrowed_*_node_visits`,
  `*_owner_candidate_visits`, `*_reconstructed_nodes`, `*_rewrite_actions`,
  `*_owner_slots`, `*_regions_normalized`, the `perceus_work_contract_*`
  solver/collection counters, `perceus_work_insert_*` (already covered by
  this issue's node-kind/helper table above via the debug-only visit
  counters at each `insert_drops_change_aware_*` call site), and
  `perceus_work_declarations_rewritten`/`functions_rewritten`/`globals_rewritten`.

## On/off honesty check

Two direct compiles of the frozen self-compile input, `BLORP_CLI_C_OPTIMIZATION=-O2`,
`BLORP_COMPILER_MEMORY_PROFILE=1`, identical otherwise except for
`BLORP_PERCEUS_ENGINE_METRICS`:

| | `pass_dict_literal_ownership_complete` (cumulative) | `pass_perceus_complete` (cumulative) | Pass delta |
| --- | ---: | ---: | ---: |
| Metric unset | 148,402,668 | 209,225,755 | 60,823,087 |
| `BLORP_PERCEUS_ENGINE_METRICS=1` | 148,402,668 | 209,225,755 | 60,823,087 |

Identical to the allocation. The two runs' output C is also byte-identical
(`diff` reports no difference). The counters allocate nothing.

## No-production-change confirmation

```bash
benchmarks/self_compile_measure lock -- \
  benchmarks/self_compile_measure --program small --input-rev origin/main \
  --samples 1 --baseline <parent_small.json taken before any edit> --require-identical
```

Output C byte-identical to the parent baseline; every allocation row +0.00%
(the release path calls no new foreign function unless
`BLORP_PERCEUS_ENGINE_METRICS` is set, so this is expected by construction,
and this run confirms it).

## Gates (`benchmarks/self_compile_measure lock --`)

- `bin/blorp test --timeout 600 blorp/test/compiler/stage_09_core/test_core_perceus.brp`
  -- all 364 tests passed.
- `python3 -m unittest blorp.test.compiler.benchmark.test_perceus_memory`
  -- all 80 tests passed (it scans `results_and_loops.brp`'s source text for
  the named records; none were renamed, only wrapped with a same-named
  public entry point plus a private `_impl`, so every scanned name is still
  present verbatim).
- `make hygiene-check` -- passed; the new `realloc`/`calloc`/`malloc` call
  sites in `runtime.c` each carry a "Not an allocation the oracle observes"
  comment matching the lowering metric's pattern.
- `scripts/compiler-check --changed` -- passed (2 sources, 1 suite, 1 check,
  2,439 tests).
- `scripts/test leak` -- passed (963 tests).

## Exact commands

```bash
# Build
BLORP_CLI_C_OPTIMIZATION=-O2 make

# Freeze the input
input=$(benchmarks/self_compile_measure freeze --rev origin/main)

# Off / on honesty check (direct compiles, same input, same flags except the variable)
BLORP_COMPILER_MEMORY_PROFILE=1 bin/blorp compile --no-format --no-embed-runtime \
  --time-phases --std-dir "$input/standard_library/src" -o /tmp/off.c \
  "$input/blorp/src/main.brp" 2>/tmp/off.stderr
BLORP_PERCEUS_ENGINE_METRICS=1 BLORP_COMPILER_MEMORY_PROFILE=1 bin/blorp compile \
  --no-format --no-embed-runtime --time-phases --std-dir "$input/standard_library/src" \
  -o /tmp/on.c "$input/blorp/src/main.brp" 2>/tmp/on.stderr
diff /tmp/off.c /tmp/on.c   # -> no output (byte-identical)
grep pass_perceus_complete /tmp/off.stderr /tmp/on.stderr   # -> identical total_allocations

# Attribution table itself
grep BLORP_PERCEUS_ENGINE /tmp/on.stderr

# Harness reference row and no-production-change check
BLORP_CLI_C_OPTIMIZATION=-O2 benchmarks/self_compile_measure --input-rev origin/main --samples 1
benchmarks/self_compile_measure lock -- \
  benchmarks/self_compile_measure --program small --input-rev origin/main \
  --samples 1 --baseline /tmp/parent_small.json --require-identical

# Gates
benchmarks/self_compile_measure lock -- bin/blorp test --timeout 600 \
  blorp/test/compiler/stage_09_core/test_core_perceus.brp
benchmarks/self_compile_measure lock -- python3 -m unittest \
  blorp.test.compiler.benchmark.test_perceus_memory
benchmarks/self_compile_measure lock -- make hygiene-check
benchmarks/self_compile_measure lock -- scripts/compiler-check --changed
benchmarks/self_compile_measure lock -- scripts/test leak
```

## What this could not measure, and why

- **Exact dynamic `perceus_work_*` counts** -- needs the
  `--profile-mode exact`/`FunctionProfileExact` instrumented-build path
  (a profiled self-hosted `bin/blorp` compiling the frozen input), a
  separate and larger undertaking than opt-in counters; enumerated by cause
  instead (see above), matching the prior profile's own conclusion for the
  same counters.
- **Allocation cost of code called from inside a wrapped helper but not
  itself wrapped** (e.g. `retain_alias_source_in_body`,
  `balance_let_body_legacy`, `transform_let_if_body`/
  `transform_let_constructor_match_body`, `protect_repeated_consumes`,
  `freshen_shadowed_match_bindings` inside `rebuild_managed_let`;
  `call_ownership_normalization_reuses_source` inside
  `insert_drops_change_aware_call`) -- folded into the wrapping helper's
  self number rather than broken out further, since the issue names only
  the outer helpers to instrument. `rebuild_managed_let`'s 25.66% share is
  the clearest signal in this table that a future issue should drill into
  it the same way this one drilled into the engine as a whole.
- **The ~40.85% of the pass that happens before the first
  `insert_drops_expr_inner_result` call** (`resolve_global_value_refs`,
  `build_env`, `infer_user_call_contracts`, and `rewrite_decl`'s own
  per-declaration setup) -- out of scope for this issue, which targets the
  drop-insertion engine specifically; the prior profile already measured
  `infer_user_call_contracts` directly at 5.36% of the pass.
