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
  `CORE_ID_MIGRATION.md` landing, which would make `id` unique per binder)
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

## Follow-up: drilling into `rebuild_managed_let` (2026-09-22, second pass)

`rebuild_managed_let` alone was 25.66% of the pass above. This section
drills one level into it (and `plan_managed_let`), attributing self
allocations to each step it performs, using the same
`BLORP_PERCEUS_ENGINE_METRICS` mechanism: `perceus_engine_node_enter`/
`perceus_engine_node_exit` wraps around `summarize_linear_ownership_uses`
(`perceus/uses.brp`), `balance_let_body_legacy` / `transform_let_if_body` /
`transform_let_constructor_match_body` (`perceus/balance.brp`),
`protect_repeated_consumes` (`perceus/protect.brp`), the four helpers
`plan_managed_let` calls to compute `PerceusManagedLetPlan`'s fields
(`binding_alias_rhs_is_owned_temporary`,
`normalize_binding_alias_rhs_reuses_source`,
`normalize_binding_alias_rhs_with_owned_status`,
`retain_mutable_match_branch_results`, all in `results_and_loops.brp`), and
`balanced_path_has_divergent_constructor_match` (`perceus/balance.brp`).
Two additions: `BLORP_PERCEUS_ENGINE_LET_BINDINGS schema=1 total=... managed=...`
counts how many `let` bindings the engine visits and how many are managed,
and the final `LetExpr`/`BorrowLetExpr` reconstruction is bracketed under
the label `let-reconstruct`.

**Off-limits files.** Another worker is editing `perceus/borrowed.brp` and
`perceus/mutable.brp` concurrently. `rewrite_mutable_let_body`
(`perceus/mutable.brp`) is therefore not wrapped at its own definition;
instead the *call site* inside `rebuild_managed_let_impl`
(`results_and_loops.brp`) is bracketed with `perceus_engine_node_enter`/
`perceus_engine_node_exit("helper:rewrite_mutable_let_body")`, which
attributes the same allocations to this step without touching that file.
`mutable.brp` was not edited. If a future cut needs to change
`rewrite_mutable_let_body` itself, what it would need is exactly what this
bracket already shows: an inclusive cost of 3,616,045 allocations across
4,055 calls (only for mutable managed lets) -- the same shape as this
issue's other findings, so the same kind of drill (an enter/exit bracket
around its own internal steps) would apply there too, once that file is
free to edit.

**A second multi-caller correction.** `protect_repeated_consumes` also has
several other callers (`borrowed.brp`, `mutable.brp` x3, `short_circuit.brp`),
so wrapping its own definition (as done for the other helpers) aggregates
across the whole compile, not just this call site -- the same caveat this
report already noted for `summarize_linear_ownership_uses`. A second,
call-site-only bracket, labeled `let-protect-repeated-consumes-site`, was
added around the one call inside `rebuild_managed_let_impl` to isolate the
managed-let-scoped share from the global aggregate.

### Let bindings on the self-compile

`BLORP_PERCEUS_ENGINE_LET_BINDINGS schema=1 total=73890 managed=57601` --
73,890 `LetExpr` bindings visited by the frame-stack loop in
`insert_drops_expr_inner_result_impl`, of which 57,601 (77.9%) are managed
(bind a type `is_managed_type` reports true for) and go through
`plan_managed_let`/the managed-let frame pair; the remaining 16,289 are
unmanaged and rebuilt directly. Of the 57,601 managed lets, only 57,488
(99.8%) actually reach `rebuild_managed_let` -- the other 113 are resolved
by the cheaper `proven_unused`/`reuses_source`/`direct_consume` checks in
`insert_drops_expr_inner_result_impl` before `rebuild_managed_let` is ever
called, so there is very little "early-out before planning" headroom left
in the current structure (see the go/no-go below).

### `rebuild_managed_let`'s budget, broken down

Frozen input: `origin/main` at `a109eca0cb29c816625185ccf3a2d7428f910028`.
Reference row, same input: `pass_perceus_complete` = **60,868,648**
allocations (delta of `pass_dict_literal_ownership_complete`'s
148,498,896 and `pass_perceus_complete`'s 209,367,544 cumulative totals).
`rebuild_managed_let`'s own row: calls=57,488, self=2,951,246,
**inclusive=15,607,175 (25.64% of the pass)** -- consistent with the first
pass's 25.66% (the 0.02-point difference is input drift between the two
measurement runs, not the instrumentation).

| Step | Scope | Calls | Self allocs | Self % of pass | % of rebuild's budget |
| --- | --- | ---: | ---: | ---: | ---: |
| `balance_let_body_legacy` | Aggregate (see caveat) | 46,731 | 182,618 (self); **4,968,657 (inclusive)** | **8.16%** (inclusive) | **31.84%** |
| `rebuild_managed_let` self (remaining glue: match dispatch, `is_immortal_value_expr`, `freshen_shadowed_match_bindings`, the immutable branch's `retain_alias_source_in_body`, `body_starts_with_dup`) | Exact | 57,488 | 2,951,246 | 4.85% | 18.91% |
| `rewrite_mutable_let_body` (call-site bracket) | Exact (mutable lets only) | 4,055 | 1,310,133 (self); 3,616,045 (inclusive) | 5.94% (inclusive) | 23.17% |
| `let-protect-repeated-consumes-site` (call-site bracket) | Exact | 53,342 | ~0 (self); 1,144,531 (inclusive) | 1.88% (inclusive) | 7.33% |
| `transform_let_constructor_match_body` | Exact | 2,737 | 230,085 (self); 522,413 (inclusive) | 0.86% (inclusive) | 3.35% |
| `transform_let_if_body` | Exact | 3,878 | 18,406 (self); 293,716 (inclusive) | 0.48% (inclusive) | 1.88% |
| `plan_managed_let` self (remaining) | Exact | 57,601 | 61,656 | 0.10% | -- (separate budget) |
| `binding_alias_rhs_is_owned_temporary` | Exact | 58,769 | 75,779 | 0.12% | -- (separate budget) |
| `normalize_binding_alias_rhs_with_owned_status` | Exact | 14,010 | 58,119 | 0.10% | -- (separate budget) |
| `retain_mutable_match_branch_results` | Exact | 19,630 | 54,429 | 0.09% | -- (separate budget) |
| `normalize_binding_alias_rhs_reuses_source` | Exact | 57,601 | 20,223 | 0.03% | -- (separate budget) |
| `let-reconstruct` (final `LetExpr` node) | Exact | 57,488 | 57,488 | 0.09% | 0.37% |
| `balanced_path_has_divergent_constructor_match` | Exact, but recursive (see note) | 714,561 | 1,294 (self) | 0.002% | 0.01% |
| `protect_repeated_consumes` (own definition, global) | **Aggregate, not scoped** | 3,226,532 | 2,086,226 (self); 29,235,161 (inclusive) | 3.43% (self, global) | n/a (see caveat) |
| `summarize_linear_ownership_uses` (own definition, global) | **Aggregate, not scoped** | 4,799,071 | 17,381,954 (self); 53,411,618 (inclusive) | **28.56%** (self, global) | n/a (see caveat) |

Notes:
- **Scope column.** "Exact" means the row's number is scoped to calls
  reachable only from `rebuild_managed_let`/`plan_managed_let` (either the
  function has no other caller, or the wrap is a call-site bracket rather
  than a definition wrap). "Aggregate" means the wrapped function has other
  callers elsewhere in Perceus, so the self/inclusive numbers sum across the
  whole compile, not just this call path; `balance_let_body_legacy`'s other
  caller (`balance_concurrent_binding_body`) was checked and found
  negligible on this program (`PreClosureConcurrentlyLoopExpr` appears once
  in the whole self-compile), so its row is treated as ~100%
  managed-let-scoped despite being an aggregate wrap.
- **`balanced_path_has_divergent_constructor_match`'s inclusive number is
  not reported** because it is self-recursive with a single external entry
  point (only called from `rebuild_managed_let_impl`); the aggregate table
  sums `inclusive_allocations` once per *call*, including every recursive
  re-entry, so the reported total for a deeply recursive predicate
  over-counts the same allocations many times over (the same effect this
  report's first section already documented for `IfExpr`'s node-kind row).
  Its `self` (1,294 across 714,561 calls) is the trustworthy number, and it
  is negligible: the predicate does not allocate `CoreExpr` nodes, just
  booleans and (rarely) small `Option`s.
- **Budget arithmetic does not sum to exactly 15,607,175** (the rows above
  add to roughly 13.5M): the remainder is the uninstrumented calls inside
  `rebuild_managed_let_impl`'s own glue (`is_immortal_value_expr`,
  `freshen_shadowed_match_bindings`, `releasing_match_consumes_owner`, the
  immutable branch's `retain_alias_source_in_body` call before balancing,
  `body_starts_with_dup`), which are folded into the "remaining glue" self
  row above rather than drilled further, since none of them were named in
  the issue's step list.

### Go/no-go: does any step exceed 25% of `rebuild_managed_let`'s budget (~6.41% of the pass)?

**Yes: `balance_let_body_legacy`, at 31.84% of the budget (8.16% of the
pass).** This is the only step whose scoped-or-near-scoped share clears the
line; `rewrite_mutable_let_body` (23.17% of budget, 5.94% of the pass) is
close but under.

### What was investigated for the cut, and why it lands where it does

The hypothesized shapes were checked directly against `balance_let_body_legacy`
and its callers, not assumed:

- **"A summary computed more than once for the same body."** Traced every
  path into `balance_let_body_legacy`: the `ConstructorMatchExpr` arm in
  `rebuild_managed_let_impl` tries `releasing_match_consumes_owner` (cheap,
  no summary) then `transform_let_constructor_match_body` before falling
  back; but `transform_let_constructor_match_body`'s own `None` returns
  either happen before any `summarize_linear_ownership_uses` call (the
  shadow/shape check) or, when they do happen, are on `scrutinee`, a
  different and much smaller expression than the `body` the fallback then
  summarizes. The dominant caller by volume, the wildcard (`_`) arm for
  "boring" bodies (46,731 of the 46,731 total `balance_let_body_legacy`
  calls come through both the wildcard and the two `ConstructorMatchExpr`
  fallback points combined; the wildcard arm alone accounts for the large
  majority since `transform_let_if_body` and `transform_let_constructor_match_body`
  together only see 6,615 calls), calls `balance_let_body_legacy` directly
  with no prior summary of the same body at all. No duplicate call on the
  same `(env, name, body)` triple was found.
- **"A body rebuilt through two transformations when one would do."** Found
  a real instance, but in `transform_let_constructor_match_body`, not
  `balance_let_body_legacy`: `match_node` (a `ConstructorMatchExpr` wrapping
  the freshened cases/fallback) was built unconditionally at the top of the
  function, but is read on only one of its four return paths there and one
  more further down; every other path (three of five) returned `None` or
  built a *different* `ConstructorMatchExpr` from
  `balance_constructor_match_cases`/`balance_constructor_match_fallback`,
  discarding the eagerly-built node. This is the cut implemented below.
- **"A plan record built for bindings that need no rebuild."** Checked:
  `plan_managed_let` cannot know in advance whether a binding will be
  `proven_unused` or `direct_consume`, because those checks depend on
  `resolved_values`, an index populated by walking *forward* through the
  binding's body in source order -- information that does not exist yet
  when the `Let` is first visited pre-order. Confirmed by the let-binding
  counts above: only 113 of 57,601 managed lets (0.2%) skip
  `rebuild_managed_let` via these checks, so there is negligible early-out
  headroom left to add without restructuring the two-pass architecture,
  which is out of scope here.
- **"The legacy balance path taken for a common shape the newer paths could
  handle."** Would require broadening `transform_let_if_body`/
  `transform_let_constructor_match_body` (or adding a new specialized path)
  to cover more body shapes. This changes *which* balancing strategy a
  program takes, which would change the emitted C for programs that shift
  onto the new path -- incompatible with this issue's byte-identical-C
  acceptance bar. Not attempted.
- **`balance_let_body_legacy`'s own dominant cost** (self 182,618 vs.
  inclusive 4,968,657 -- 96% of its budget) is the one
  `summarize_linear_ownership_uses(env, variable.name, body)` call at its
  top, over whatever `body` remains after `protect_repeated_consumes`. No
  confirmed duplicate or avoidable-without-behavior-change instance of this
  call was found for the dominant (wildcard-arm) case; a further cut here
  would mean changing `summarize_linear_ownership_uses` itself (called
  4,799,071 times project-wide, 28.56% of the pass on its own), which is a
  shared-traversal change well beyond this issue's scope and risk budget.

**Cut implemented:** the `transform_let_constructor_match_body` `match_node`
deferral above. It does not target the 8.16%-of-pass mechanism directly
(that mechanism's dominant cost was not found to be an avoidable
duplicate), but it is a real, verified, safe reduction found while drilling
the same call tree, and it changes nothing else in `rebuild_managed_let`'s
own code.

### On/off honesty check (drill-down instrumentation only, before the cut)

Two direct compiles of the pinned self-compile input
(`a109eca0cb29c816625185ccf3a2d7428f910028`), `BLORP_CLI_C_OPTIMIZATION=-O2`,
`BLORP_COMPILER_MEMORY_PROFILE=1`, identical otherwise except
`BLORP_PERCEUS_ENGINE_METRICS`:

| | `pass_dict_literal_ownership_complete` (cumulative) | `pass_perceus_complete` (cumulative) | Pass delta |
| --- | ---: | ---: | ---: |
| Metric unset | 148,498,896 | 209,367,544 | 60,868,648 |
| `BLORP_PERCEUS_ENGINE_METRICS=1` | 148,498,896 | 209,367,544 | 60,868,648 |

Identical. Output C also byte-identical between the two runs.

## The cut: deferring `match_node` in `transform_let_constructor_match_body`

Landed on top of the drill-down instrumentation above, as its own commit.
`transform_let_constructor_match_body_impl` (`perceus/balance.brp`) built
`match_node: CoreExpr = ConstructorMatchExpr(scrutinee, release_policy,
freshened_cases, freshened_fallback, typ, loc)` unconditionally at the top
of the function, once per call. It is read on exactly two of the function's
five return paths (the `scrutinee_aliases_owner`/`NoReleasePolicy`
preserve-owner success, and the `total_needed == 0` success further down);
every other path -- the two `None`s and the `dups_count > 0` success, which
builds a *different* `ConstructorMatchExpr` via
`balance_constructor_match_cases`/`balance_constructor_match_fallback` --
discarded it unread. The fix moves the construction into the two arms that
actually use it (each builds its own copy, since the two arms are mutually
exclusive) instead of building it once, eagerly, for every call.

### Before / after (pinned self-compile input `a109eca0cb29c816625185ccf3a2d7428f910028`)

| | `helper:transform_let_constructor_match_body` self allocs | `pass_dict_literal_ownership_complete` (cumulative) | `pass_perceus_complete` (cumulative) | Pass delta |
| --- | ---: | ---: | ---: | ---: |
| Before | 230,085 | 148,498,896 | 209,367,544 | 60,868,648 |
| After | 229,794 | 148,498,896 | 209,367,253 | **60,868,357** |
| Δ | -291 | +0.00% | -291 | **-291 (-0.0005%)** |

Output C is byte-identical to the pre-cut build on the same input (`diff`
reports no difference). The reduction is small and real: `match_node` is
read on 2,737 - (a small fraction) calls out of 2,737 total, so most calls
to this function were paying for one wasted `ConstructorMatchExpr`
allocation (plus the `List` references it holds) that this cut now skips.

This does not target `balance_let_body_legacy`'s 8.16%-of-pass share
directly -- see "What was investigated for the cut" above for why that
mechanism's dominant cost (a necessary `summarize_linear_ownership_uses`
call, not a confirmed duplicate) was not cut. It is a real, small,
independently-verified reduction found in the same call tree while
drilling `rebuild_managed_let`.

### Small-program identity and instructions

`benchmarks/self_compile_measure --program small --input-rev origin/main
--samples 3 --baseline <parent at commit dae765e5d77d> --require-identical`:
output C byte-identical (45,827 bytes both), every allocation row +0.00%,
instructions retired **+0.02%** (well under the 0.3% floor). An earlier
single-sample run under heavy concurrent load from other workers'
gates briefly read instructions retired at +77%; re-measured in isolation
(and again at 3 samples) it reads +0.02%-+0.04% consistently, confirming
the first reading was scheduling noise from concurrent CPU contention, not
a real regression -- `/usr/bin/time -l`'s instruction counter on this
platform is not immune to that under enough concurrent load, so a surprising
instructions delta should be re-checked in isolation before trusting it.

### Gates (`benchmarks/self_compile_measure lock --`, foreground)

All run against the final state (drill-down instrumentation + the cut):

- `bin/blorp test --timeout 600 blorp/test/compiler/stage_09_core/test_core_perceus.brp` -- 364 passed.
- `python3 -m unittest blorp.test.compiler.benchmark.test_perceus_memory` -- 80 passed.
- `make hygiene-check` -- passed.
- `scripts/compiler-check --changed` -- passed (1 source changed for this commit, 2,439 tests).
- `scripts/test --serial compiler-blorp compiler-tools` -- 5,143 passed.
- `scripts/test leak` -- 963 passed.
- `compiler-core-sanitize` -- included in and passed as part of `scripts/compiler-check --changed`'s special checks.

## Commits

Two commits, per the coordinator's instruction to keep the measurement and
the cut separate:

1. `89a94912` "Drill Perceus's managed-let rebuild into per-step allocation
   counters" -- instrumentation only (this file's "Follow-up" section
   above), no cut, `pass_perceus_complete` unchanged.
2. The `transform_let_constructor_match_body` `match_node` deferral above,
   its own commit on top -- the only behavior-affecting (allocation-count)
   change in this follow-up.

## P8 follow-up: does `summarize_linear_ownership_uses` re-summarize the same
## `(name, expr)` within one `rebuild_managed_let`? (2026-09-22, third pass)

Issue P8 of `docs/PERCEUS_CLEANUP_ISSUES.md`'s worker brief: the prior
section found `summarize_linear_ownership_uses` at 28.56% of the pass
(self, aggregated across the whole compile) and stopped short of drilling
into it because that was out of scope for the `rebuild_managed_let` drill.
P8's hypothesis is narrower and checkable: within a *single*
`rebuild_managed_let` invocation, do several of its helpers (the legacy
balance, the divergent-constructor-match predicate, the `transform_let_if_body`/
`transform_let_constructor_match_body` paths, the preserves-owner checks)
call `summarize_linear_ownership_uses` more than once on the identical
`(name, expr)` pair -- the same name and the same `CoreExpr` node by
pointer identity, not merely an equal-shaped one?

### Instrumentation

Extended the `BLORP_PERCEUS_ENGINE_METRICS` mechanism (still allocation-free,
still opt-in, still never rendering or hashing a value -- see the design
note at the top of this file) with:

- **Depth-scoped external/internal split.** `summarize_linear_ownership_uses`'s
  existing metrics wrapper (`perceus/uses.brp`) now also calls a dedicated
  enter/exit pair (`perceus_engine_summary_enter`/`perceus_engine_summary_exit`,
  `runtime.c`) around the same `_impl` call. These keep their own small
  stack (separate from the generic node-kind stack) whose depth at entry
  says whether this is an "external" call (depth was 0 -- reached from
  outside `uses.brp`'s own recursion) or an "internal" one (reached through
  `summarize_linear_call`'s callee/argument recursion or
  `summarize_linear_borrow`'s catch-all fallback, both of which call back
  into the same wrapped entry point).
- **Per-invocation identity table.** Every external call records the raw
  pointer identity of its `name: String` and `expr: CoreExpr` arguments
  (the same primitive `blorp_same_object`/`same_core_expr` already use
  elsewhere in this pass family -- never a rendered or hashed key) into a
  small array, linear-scanned to check whether that exact pair was already
  seen. The array resets whenever a new `rebuild_managed_let` invocation
  begins (`perceus_engine_summary_invocation_begin`, called once at the top
  of `rebuild_managed_let_impl` in `results_and_loops.brp`), so a match only
  counts as a duplicate within the same managed-let rebuild, never across
  two different bindings.
- **A real node-visit counter under the metric.** `perceus_work_linear_summary_node_visits`
  is `@debug_only` and erased in a normal or `BLORP_PERCEUS_ENGINE_METRICS`
  build (it only counts under the separate, much larger `--profile-mode exact`
  instrumented-build path). Added a second call
  (`perceus_engine_summary_node_visit`) at the same site in the frame-stack
  loop, gated on `perceus_engine_metrics_enabled()` like every other hook
  here, so `node_visits` is a real dynamic count under this metric without
  needing the exact-profile build.

Files touched: `blorp/src/compiler/stage_09_core/perceus/uses.brp` (the
metrics wrapper and the frame-loop hook, plus this module's own local
rebinding of the new foreign hooks -- there is no re-export in Blorp),
`blorp/src/compiler/stage_09_core/perceus/results_and_loops.brp` (the
`perceus_engine_summary_invocation_begin` foreign declaration and its one
call site at the top of `rebuild_managed_let_impl`), and
`blorp/src/lib/runtime/native/runtime.c`/`runtime_decl.c` (the new counters
and hooks, same file section as the rest of `BLORP_PERCEUS_ENGINE_METRICS`).
`perceus/contracts.brp` and `perceus/borrowed.brp`/`perceus/mutable.brp`
were not touched (owned by other concurrent workers).

### On/off honesty check

Frozen input: `benchmarks/self_compile_measure freeze --rev origin/main`,
commit `14f4a469374dd9a91163632e55771733cf1cbafc` (`origin/main` after
merging in the P7 drill-down/cut commits and an unrelated `contracts.brp`
change from a concurrent worker). Two direct compiles of the same input,
`BLORP_CLI_C_OPTIMIZATION=-O2`, `BLORP_COMPILER_MEMORY_PROFILE=1`, identical
otherwise except `BLORP_PERCEUS_ENGINE_METRICS`:

| | `pass_dict_literal_ownership_complete` (cumulative) | `pass_perceus_complete` (cumulative) | Pass delta |
| --- | ---: | ---: | ---: |
| Metric unset | 148,800,274 | 209,179,634 | 60,379,360 |
| `BLORP_PERCEUS_ENGINE_METRICS=1` | 148,800,274 | 209,179,634 | 60,379,360 |

Identical. The generated C is also byte-identical between the two runs
(`diff` reports no difference) -- confirmed both on this frozen self-compile
input and on a small hand-written program used to smoke-test the
instrumentation first.

### The census

Same frozen input, `BLORP_PERCEUS_ENGINE_METRICS=1` run:

```
BLORP_PERCEUS_ENGINE_LET_BINDINGS schema=1 total=73908 managed=57604
BLORP_PERCEUS_ENGINE_SUMMARY schema=1 node_visits=9254443 external_calls=1137607 external_repeated_calls=160240 repeated_inclusive_allocations=1388534
BLORP_PERCEUS_ENGINE_NODE kind=helper:summarize_linear_ownership_uses calls=4801330 self_allocations=17388595 inclusive_allocations=53424140 self_per_call=3.622
```

| Quantity | Value |
| --- | ---: |
| Total calls to `summarize_linear_ownership_uses` (external + internal recursion) | 4,801,330 |
| **External calls** (reached from outside `uses.brp`'s own recursion) | **1,137,607** |
| Internal (recursive) calls, by subtraction | 3,663,723 |
| External calls that repeat a `(name, expr)` pair already summarized in the same `rebuild_managed_let` invocation | **160,240** (14.09% of external calls) |
| Inclusive allocations of those repeated external calls | **1,388,534** |
| `summarize_linear_ownership_uses`'s own inclusive allocations (global, matches the prior section's 53,411,618 within input drift) | 53,424,140 |
| Repeated calls' share of the summary walk's allocations | 1,388,534 / 53,424,140 = **2.60%** |
| Repeated calls' share of the whole pass | 1,388,534 / 60,379,360 = **2.30%** |
| Node visits (frame-stack loop iterations, now counted for real under this metric) | 9,254,443 |
| Allocations per node visited (53,424,140 / 9,254,443) | **5.77** |

### Go/no-go: are repeated calls at least 20% of the summary walk's allocations?

**No.** 2.60% of `summarize_linear_ownership_uses`'s own inclusive
allocations (2.30% of the whole pass) come from calls that repeat a
`(name, expr)` pair already summarized within the same `rebuild_managed_let`
invocation -- an order of magnitude under the 20% bar this issue set for
attempting the per-binding memoization in deliverable 2. The 14.09% of
external calls that are repeats charge disproportionately *less* than their
share of calls (2.60% of allocations), which is consistent with duplicate
calls tending to land on smaller subtrees (a branch or scrutinee, not a
whole managed-let body) rather than on the large bodies that dominate the
walk's cost.

This matches, rather than contradicts, the prior section's own finding for
`balance_let_body_legacy`: drilling every path into it found "no confirmed
duplicate call on the same `(env, name, body)` triple" for the dominant
wildcard-arm case. This census confirms that at the identity level and
across every caller of `summarize_linear_ownership_uses`, not just
`balance_let_body_legacy`'s callers: the walk is overwhelmingly summarizing
distinct `(name, expr)` pairs, not re-walking the same one.

**Deliverable executed: 3 (report and stop; no memoization).** The
per-node cost of the walk itself dominates -- 5.77 allocations per frame-loop
node visit, from the boxed `OwnershipUseSummary` combinators
(`seq_ownership_uses`, `aggregate_ownership_uses`, the frame-stack pushes)
and the `PerceusOwnershipSummaryFrameStack` frame allocations, not from
redundant work on shared subtrees. `OwnershipUseSummary`'s own docstring
already records that flattening it from a boxed `record` to unboxed scalars
was measured and made things 2% worse; re-testing that tradeoff is
explicitly out of scope for this issue (a separate decision, per the issue
brief). No changes were made to `balance.brp` or the memoization call sites
named in deliverable 2's brief -- there is no confirmed duplicate-work
mechanism there to cut without changing behavior.

### Gates (`benchmarks/self_compile_measure lock --`, foreground)

- `bin/blorp test --timeout 600 blorp/test/compiler/stage_09_core/test_core_perceus.brp` -- 364 passed.
- `python3 -m unittest blorp.test.compiler.benchmark.test_perceus_memory` -- 80 passed.
- `make hygiene-check` -- passed.
- `scripts/compiler-check --changed` -- passed (2 sources changed, 2,439 tests).
- `scripts/test --serial compiler-blorp compiler-tools` -- 5,144 passed.
- `scripts/test leak` -- 963 passed.
- `scripts/test compiler-core-sanitize` -- 2,075 passed.

`pass_perceus_complete` is unchanged by this commit (instrumentation only,
confirmed above); there is no cut to measure identity or instructions for,
per the go/no-go result.

### Commit

One commit, instrumentation and this results section together (deliverable
1 only -- deliverable 2's 20% gate was not met, so there is no second,
behavior-changing commit for this issue).

## P8 follow-up: what the walk's 5.77 allocations per node visit are made of
## (2026-09-22, fourth pass)

The prior section found 5.77 allocations per frame-stack node visit inside
`summarize_linear_ownership_uses`, and ruled out re-summarizing the same
`(name, expr)` pair as the cause (only 2.6% of the walk's allocations).
This pass attributes those 5.77 allocations/visit to a source category,
using the same allocation-free `BLORP_PERCEUS_ENGINE_METRICS` mechanism,
to find out whether the walk's own per-node shape (not duplicate work) is
concentrated in one avoidable place.

### Instrumentation

Two new plain occurrence counters (`perceus_engine_summary_record_construct`/
`_frame_push`, `runtime.c`), each a single global increment gated on
`perceus_engine_metrics_enabled()`, called once per `OwnershipUseSummary`
record literal and once per `PerceusOwnershipSummaryFrameStack` frame
construction in `perceus/uses.brp` (`ownership_uses_from_legacy_count`,
`seq_ownership_uses`, `ownership_uses_with_returns_alias`,
`sum_ownership_uses`, `branch_ownership_uses_pair`, `branch_ownership_uses`,
and the frame-unwind `PerceusOwnershipSummaryDupBodyFrame` arm for (a); all
nine push sites in the frame-stack loop for (b)). Both shapes are
documented ("a push costs one allocation") to cost exactly one allocation
per construction -- the same assumption `PerceusInsertBindingFrameStack`'s
push count already relied on in the first section of this file -- so the
counts double as the categories' allocation counts directly, with no
per-construction bracket needed.

For the call/match/repeated-body/borrow dispatch (categories c, e, f), six
functions were split into a public wrapper plus a private `_impl` and
bracketed with the existing `perceus_engine_node_enter`/`_node_exit`
mechanism, the same pattern `rebuild_managed_let`'s own drill-down used:
`summarize_linear_call` (`"summary:call"`), `summarize_call_args`
(`"summary:call-args-list"`, nested inside the call bracket),
`summarize_match_ownership_uses` (`"summary:match-combine"`),
`summarize_constructor_literal_match_uses`/`summarize_constructor_length_match_uses`/
`summarize_constructor_match_branch_uses` (all three share the label
`"summary:match-branch-list"`, since they are the three list-building
callers that assemble `branch_uses` before `summarize_match_ownership_uses`
combines it with the scrutinee), `summarize_repeated_body_uses`
(`"summary:repeated-body"`), and `summarize_linear_borrow`
(`"summary:borrow"`). Two more call sites -- the `count_uses` legacy
fallback in the `WhileExpr` arm and in the dispatch's final `_:` arm -- were
bracketed individually (both labeled `"summary:legacy-count-fallback-site"`)
since the fallback itself is a two-line expression, not a named helper.

**Scope caveats**, matching the pattern the prior drill-down already
established:

- `summarize_match_ownership_uses` is also called from `contracts.brp`
  (4 call sites, a file owned by another concurrent worker and not
  touched here), so its row aggregates across the whole compile, not just
  the summary walk.
- `summarize_linear_borrow` is also called from `balance.brp` (3 sites) and
  `contracts.brp` (4 sites), and is self-recursive (`FieldExpr`/
  `TupleFieldExpr`/`CastExpr`/`BoxExpr`/`UnboxExpr` all recurse into it),
  so both its aggregation and its self-recursion caveats from the prior
  section's methodology apply; its **self** number is what is trustworthy.
- `summarize_linear_call` has one external caller (`protect.brp`); not
  separately checked for magnitude here, but it is a single call site
  against `summarize_linear_call`'s 1.86M calls in this run, so its
  contribution is expected to be negligible by the same reasoning the
  prior section applied to `balance_let_body_legacy`'s one external caller.
- **Dead-code note, found while locating the match-arm sites**:
  `summarize_linear_ownership_uses_non_binding` has its own `LetExpr`/
  `BorrowLetExpr`/`SeqExpr`/`AssignExpr`/`DupExpr`/`DropExpr`/
  `DebugBlockExpr` arms (including a second `OwnershipUseSummary`
  construction site for `DupExpr`, not instrumented here), but its single
  caller is the frame-stack loop's own catch-all `_:` arm, which is only
  reached for a `current_expr` that already failed to match exactly those
  same seven kinds one level up. These arms therefore appear unreachable.
  Flagged separately rather than fixed here (out of scope for an
  attribution-only pass); see the spawned follow-up.

### On/off honesty check

Frozen input: `benchmarks/self_compile_measure freeze --rev origin/main`,
commit `424d61c8946b43b5eae788a2185fd6e436d191ce` (`origin/main` after the
prior census commit landed). Two direct compiles, `BLORP_CLI_C_OPTIMIZATION=-O2`,
`BLORP_COMPILER_MEMORY_PROFILE=1`, identical otherwise except
`BLORP_PERCEUS_ENGINE_METRICS`:

| | `pass_dict_literal_ownership_complete` (cumulative) | `pass_perceus_complete` (cumulative) | Pass delta |
| --- | ---: | ---: | ---: |
| Metric unset | 148,803,855 | 211,530,490 | 62,726,635 |
| `BLORP_PERCEUS_ENGINE_METRICS=1` | 148,803,855 | 211,530,490 | 62,726,635 |

Identical; generated C is also byte-identical between the two runs and
against the small smoke-test program used to check the instrumentation
first.

### The table

Same frozen input, `BLORP_PERCEUS_ENGINE_METRICS=1` run. The pass delta
above (62,726,635) is higher than the second section's 60,379,360 and the
first section's 60,868,648 -- input drift between measurement runs on
different commits of a self-compiling compiler (this frozen input now
embeds every `uses.brp`/`results_and_loops.brp` line this issue has added
so far), the same effect the prior two sections already documented and not
a regression (confirmed by the on/off match immediately above, on this
same commit).

```
BLORP_PERCEUS_ENGINE_LET_BINDINGS schema=1 total=73908 managed=57604
BLORP_PERCEUS_ENGINE_SUMMARY schema=1 node_visits=9254533 external_calls=1137629 external_repeated_calls=160240 repeated_inclusive_allocations=1560675
BLORP_PERCEUS_ENGINE_SUMMARY_SHAPES schema=1 record_constructions=11083210 frame_pushes=4339854
BLORP_PERCEUS_ENGINE_NODE kind=helper:summarize_linear_ownership_uses calls=4801402 self_allocations=8189104 inclusive_allocations=59702445 self_per_call=1.706
BLORP_PERCEUS_ENGINE_NODE kind=summary:call calls=1859998 self_allocations=9643638 inclusive_allocations=21856008 self_per_call=5.185
BLORP_PERCEUS_ENGINE_NODE kind=summary:call-args-list calls=1859998 self_allocations=1907495 inclusive_allocations=12211390 self_per_call=1.026
BLORP_PERCEUS_ENGINE_NODE kind=summary:match-branch-list calls=100169 self_allocations=220897 inclusive_allocations=11308029 self_per_call=2.205
BLORP_PERCEUS_ENGINE_NODE kind=summary:match-combine calls=99802 self_allocations=113672 inclusive_allocations=113672 self_per_call=1.139
BLORP_PERCEUS_ENGINE_NODE kind=summary:repeated-body calls=17381 self_allocations=34752 inclusive_allocations=1376111 self_per_call=1.999
BLORP_PERCEUS_ENGINE_NODE kind=summary:legacy-count-fallback-site calls=23 self_allocations=23 inclusive_allocations=23 self_per_call=1.000
BLORP_PERCEUS_ENGINE_NODE kind=summary:borrow calls=4312382 self_allocations=0 inclusive_allocations=3993817 self_per_call=0.000
```

`summarize_linear_ownership_uses`'s own inclusive allocations, 59,702,445,
is used below as "the walk" -- 95.2% of this run's 62,726,635-allocation
pass delta.

| Category | Source | Count | Allocations | % of walk | % of pass |
| --- | --- | ---: | ---: | ---: | ---: |
| (a) `OwnershipUseSummary` record returned per node | `record_constructions` | 11,083,210 | 11,083,210 | **18.56%** | 17.67% |
| (b) `PerceusOwnershipSummaryFrameStack` pushes | `frame_pushes` | 4,339,854 | 4,339,854 | 7.27% | 6.92% |
| (c) List construction in aggregate/branch arms | `summary:call-args-list` self (1,907,495) + `summary:match-branch-list` self (220,897) | -- | 2,128,392 | 3.57% | 3.39% |
| (d) `Option`/`Result`/tuple wrappers on return paths | none found on the walk's hot paths | -- | ~0 | ~0% | ~0% |
| (e) `count_uses` fallbacks | `summary:repeated-body` self (34,752) + `summary:legacy-count-fallback-site` self (23) | -- | 34,775 | 0.06% | 0.06% |
| (f) `summarize_linear_borrow` re-walks | `summary:borrow` self | -- | 0 | 0% | 0% |
| (g) everything else (call/match dispatch glue, the frame loop's own unbracketed record/frame work) | `summary:call` self (9,643,638) + `summary:match-combine` self (113,672) + `helper:summarize_linear_ownership_uses` self (8,189,104) | -- | 17,946,414 | 30.06% | 28.61% |

Rows do not sum to the walk's 59,702,445: (a) and (b) are cross-cutting
shape counts (every construction anywhere in the walk, regardless of which
named bracket, if any, is active when it happens), while (c)/(e)/(f)/(g)
attribute cost by call path, and a construction inside e.g.
`summary:call`'s own glue is counted once in (a)'s global tally and again
inside (g)'s `summary:call` self number. This is the same overlapping-row
shape the prior `rebuild_managed_let` drill-down already reported ("budget
arithmetic does not sum exactly... the remainder is uninstrumented glue")
and is disclosed rather than forced to add up.

### (d): no wrapper found

Unlike the lowering metric's Result-of-tuple box, no `Option`/`Result`/
tuple construction was found on `summarize_linear_ownership_uses`'s
dominant paths. `contract_for_call` returns `Option[OwnershipCallContract]`
and is matched immediately in `summarize_linear_call_impl` without being
stored or threaded further; `summarize_call_args` returns a plain `List`;
`call_result_aliases_target` returns a `Bool`. Category (d) is negligible
here because there is nothing to attribute.

### (f): a pure delegator

`summarize_linear_borrow`'s self allocations are exactly 0 across
4,312,382 calls: its `VarExpr` arm returns one of the two pre-built shared
constants (`BORROW_OWNERSHIP_USE`/`NO_OWNERSHIP_USES`, module-level values
built once, not per call), and every other arm either recurses into itself
or falls through to `summarize_linear_ownership_uses` -- both charged to
the child, never to this function's own self. It is a router, not an
allocation site; its cost surfaces entirely in category (a) (via whichever
`seq_ownership_uses`/etc. its callees construct) or in the recursive
`helper:summarize_linear_ownership_uses` bracket.

### Go/no-go: does any category exceed 25% of the walk's allocations?

**No single actionable category does.** (g), the residual "everything
else" bucket, is the only row above 25% (30.06%), but it is not one
mechanism -- it is `summary:call`'s own dispatch glue (contract lookup,
`aggregate_ownership_uses_from`'s per-item combine, alias checks),
`summary:match-combine`'s scrutinee/branch combine, and the frame loop's
own record/frame construction that happens directly at the top level
rather than inside a named bracket, three different things lumped together
because none of them cleared 5% individually against the pass in the
`rebuild_managed_let` drill-down's own methodology (a further split was
not instrumented, since doing so risked re-litigating that prior issue's
scope). It does not have "the exact shape" of a single cut.

Of the concrete, single-mechanism categories, **(a) `OwnershipUseSummary`
record construction is the largest at 18.56% of the walk** (17.67% of the
pass) -- under the 25% bar. Per the brief, a category that clears 25% and
requires changing `OwnershipUseSummary`'s own representation is not to be
implemented in this pass regardless (the record's docstring already
records a measured, rejected flattening); (a) does not clear the bar
either way, so this is moot here. (b) frame pushes (7.27%), (c) list
construction (3.57%), (e) legacy-count fallback (0.06%), and (f) borrow
delegation (0%) are all well under 25% and are not list-construction- or
wrapper-shaped cuts a loop could trivially avoid -- (c) is the one category
matching that description in the brief, and at 3.57% of the walk it is an
order of magnitude under the bar.

**No cut is proposed or implemented.** This is a negative result:
allocations per node visited are inherent to how many `OwnershipUseSummary`
records and `PerceusOwnershipSummaryFrameStack` frames a walk of this shape
builds, spread across the dispatch, not concentrated in one avoidable
per-call wrapper or list. `pass_perceus_complete` is unchanged by this
commit (instrumentation only, confirmed by the on/off check above).

### Gates (`benchmarks/self_compile_measure lock --`, foreground)

- `bin/blorp test --timeout 600 blorp/test/compiler/stage_09_core/test_core_perceus.brp` -- 364 passed.
- `python3 -m unittest blorp.test.compiler.benchmark.test_perceus_memory` -- 80 passed.
- `make hygiene-check` -- passed.
- `scripts/compiler-check --changed` -- passed (1 source changed, 2,439 tests).
- `scripts/test --serial compiler-blorp compiler-tools` -- 5,144 passed.
- `scripts/test leak` -- 963 passed.
- `scripts/test compiler-core-sanitize` -- 2,075 passed.

### Commit

One commit: the attribution instrumentation and this results section
together. No behavior-changing cut follows, per the go/no-go result above.

## Errata (2026-09-22, fifth pass): the (a)/(b) hooks were not free, removed

The "On/off honesty check" above compared the metric's *reported totals*
between `BLORP_PERCEUS_ENGINE_METRICS` on and off and found them identical.
That check was insufficient: a bisect across this issue's commits (base
`424d61c8`, this commit `7d269320`) found `pass_perceus_complete` up
1,738,825 allocations (+3.7% of the pass) from this commit alone **with
the metric off**, i.e. `BLORP_PERCEUS_ENGINE_METRICS` unset entirely. The
on/off check only proves the two *runs* agree with each other; it cannot
show that either run agrees with the pre-instrumentation baseline, which
is the number that actually matters for a "free when unset" claim.

The cause was not the hook calls themselves -- `blorp_perceus_engine_summary_record_construct_c`/
`_frame_push_c` return immediately when the metric is unset, so calling
them is not what allocated. The cause was *inserting the calls at all* in
source: at every one of the (a)/(b) sites, the call sat immediately before
a tail-position `OwnershipUseSummary` record literal or
`PerceusOwnershipSummaryFrameStack` union construction that reuses an
existing, uniquely-owned local's storage in place (`first`/`second` in
`seq_ownership_uses` and friends, `frames` in the frame-stack push sites).
That reuse decision is made statically, while compiling `uses.brp` itself,
by shape -- it does not know or care what a runtime flag will evaluate to
later. Inserting any statement, including a metric-gated `if
env.engine_metrics_enabled: perceus_engine_summary_record_construct()`, in
front of the construction broke the shape the reuse optimizer matches on,
so the construction fell back to a fresh allocation on **every** call,
metric on or off. Confirmed by direct measurement on the same frozen
input (`0c2e104331a2`, `-O2`): pristine `pass_perceus_complete` (before
this commit's (a)/(b) hooks existed) 48,962,950; with the hooks present
but metric-gated at each call site, still 48,962,950 (no improvement);
with the (a)/(b) hooks removed entirely and the bare constructions
restored verbatim, 47,245,327 -- matching the pre-instrumentation figure
within drift from unrelated commits since. The (c)/(e)/(f)/(g) categories'
`summary:*`/`helper:*` wrapper functions do not have this problem: they
wrap whole function *calls* (enter/call/exit around a call in the `else`
branch, a plain tail call to `_impl` in the `if` branch), never insert a
statement in front of an existing reused construction, and this file's
own "On/off honesty check" plus a direct pristine-vs-instrumented
allocation comparison confirm they cost nothing on the release path.

**Fix**: removed the (a)/(b) hooks (`perceus_engine_summary_record_construct`/
`_frame_push`, their foreign declarations, and their call sites in
`ownership_uses_from_legacy_count`, `seq_ownership_uses`,
`ownership_uses_with_returns_alias`, `sum_ownership_uses`,
`branch_ownership_uses_pair`, `branch_ownership_uses`, the
`PerceusOwnershipSummaryDupBodyFrame` unwind arm, and all nine frame-stack
push sites) along with the matching C-side counters and the
`BLORP_PERCEUS_ENGINE_SUMMARY_SHAPES` report line in `runtime.c`/
`runtime_decl.c`. The (a)/(b) attribution numbers in the table above stand
as a one-time historical measurement; the mechanism used to take them is
gone. The (c)/(e)/(f)/(g) wrapper-call instrumentation is unaffected and
remains free on the release path.
