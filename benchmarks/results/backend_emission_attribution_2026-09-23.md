# Backend emission (`emit.brp`) allocation attribution

Date: 2026-09-23

Compiler commit: `029369270435a133abaed3ba7127eba1748c5ad4` (`origin/main`,
clean). Frozen self-compile input revision: same commit. Toolchain:
`bin/blorp --version` reports `target: aarch64-apple-darwin`, `cc: Apple
clang version 21.0.0 (clang-2100.3.34.2)`, `optimization: cli=-O0
runtime=-O2`.

## Method

No per-function self-allocation counter exists for this ranking (unlike the
typecheck attribution's patched `runtime.c`); this uses call counts from the
`calls`-mode function profiler plus manual reading of each hot helper's body
to judge per-call allocation cost.

1. `benchmarks/self_compile_measure freeze --rev HEAD` to get the frozen
   input directory.
2. `bin/blorp compile --profile-mode calls --profile-module
   blorp/src/compiler/stage_10_backend/emit --std-dir standard_library/src
   --no-format -o /tmp/prof.c blorp/src/main.brp` to generate an
   instrumented `main.brp` (module path must be the full workspace-relative
   `blorp/src/...` spelling; `bin/blorp run` cannot be used directly here
   because it links a generic runtime embed that is missing CLI-only foreign
   symbols such as `blorp_compiler_require_fiber_stack_size` that the real
   build's `runtime_sources.c`/`native_runtime.c` provide).
3. Compiled `/tmp/prof.c` with `runtime_sources.c` and `native_runtime.c`
   per the roadmap's manual-link recipe, producing `/tmp/blorp-prof`.
4. Ran `/tmp/blorp-prof compile --no-format --no-embed-runtime --std-dir
   <frozen>/standard_library/src -o /tmp/x.c <frozen>/blorp/src/main.brp`,
   i.e. the profiled compiler doing a full self-compile.
   `PROFILE_DIAGNOSTICS`: `functions_described=14664 functions_selected=820
   functions_observed=559 calls_observed=14,623,137`, no loss/corruption
   counters set.
5. Denominator: `benchmarks/self_compile_measure --label em_attr --input-rev
   HEAD` on the same commit (unprofiled, plain build): total self-compile
   allocations `236,005,319`; `backend_emission_complete` phase allocations
   `20,285,078`. Emitted C for that run is `/tmp/x.c`, `1,577,399` lines.

Ratio: `20,285,078 / 1,577,399` ~= **12.86 allocations per emitted line**.

## Top 15 `emit.brp` helpers by call count

| Helper | Calls |
| --- | ---: |
| `c_var_name` | 1,050,677 |
| `emit_simple_expr_bounded` | 1,000,000 |
| `core_expr_type` | 964,441 |
| `emit_simple_expr_leaf` | 962,893 |
| `emit_simple_expr` | 930,678 |
| `emit_function_body` | 661,597 |
| `simple_call_arg_requires_ordering` | 380,121 |
| `required_body_value` | 324,655 |
| `body_value` | 277,510 |
| `nested_emission_context` | 272,787 |
| `call_args_transfer_cleanup_pop_statements` | 229,590 |
| `call_transfer_cleanup_pop_statements` | 229,590 |
| `temp_name` | 216,487 |
| `simple_call_args_require_ordering` | 201,314 |
| `selected_call_kind` | 193,547 |

No self-allocation column: without a patched profiler (as the typecheck
attribution added to `runtime.c`), calls-mode gives call frequency only, not
allocations. The ranking above is call frequency; allocation judgments below
come from reading each helper.

## Reading the ranking

- `c_var_name` -> `c_local_name` -> `c_identifier`: allocates nothing on the
  common path (returns the input `name` unchanged unless a reserved-prefix
  rewrite applies). Not a target.
- `emit_simple_expr` / `_bounded` / `_leaf` / `_chain`: already uses an
  explicit work-stack with `List.set`-in-place instead of native recursion
  or list-rebuilding. Not a target.
- `c_binary_expr` / `c_unary_expr` / `c_infix_expr`: build strings with `+`
  chains (e.g. `"(" + left_c + " " + operator + " " + right_c + ")"`), but
  these are literal-and-variable chains that the compiler's own
  `pass_fuse_string` folds into a single call before this code runs at
  self-compile time, so they are likely already close to one allocation per
  call rather than several.
- `call_args_transfer_cleanup_pop_statements` and most `*_statements`
  builders: already use `var statements: String = ""` plus `+=` (append
  in-place on a unique `var`), the shape the acceptance rules ask for.
- `append_emitted_c`: calls the `blorp_string_append` builtin directly for
  declaration-text accumulation, with a comment explicitly citing "large
  enough to require the consuming COW append primitive... avoids temporary
  concatenation trees." This is the pattern the rest of the file already
  points toward.
- `nested_emission_context` (272,787 calls): `{ emission_context | indent =
  emission_context.indent + "  " }` allocates a fresh indent string plus a
  full 5-field record update on every nested-scope entry (every loop/if/
  match body). This is the one clean match for "re-allocate indentation per
  nesting level" in the whole ranking, and it is the only concrete
  candidate this pass turned up.

## Verdict: no-go

`nested_emission_context`'s ~272,787 calls bound its cost at roughly
540,000 allocations (indent string + record copy, one of each per call) —
about 0.2% of the phase's 20,285,078 allocations and about the same share of
the compile's 236,005,319 total. The available fix is a depth-indexed cache
of precomputed indent strings, which trades a small, well-scoped allocation
removal for extra branching/lookup on a hot path; this round's own findings
(`small_list_allocation_not_the_cost_2026_09_22.md`,
`closure_callback_fold_regression_2026_09_22.md`) show that removing small
pooled allocations from hot paths has cost instructions three times running,
never won. Not worth the risk at this size. No cut is proposed; nothing was
changed in `emit.brp`.

Overall census: `backend_emission` allocation is diffuse, not concentrated.
The top 15 helpers by call count are already using the append-in-place,
work-stack, and string-fusion idioms the acceptance rules ask for; the
~12.86-allocations-per-line ratio reflects broad, thin allocation across
nearly every line-emitting call (temp names, small joins, per-arg
materialization records) rather than a few costly helpers. No cut in this
phase is recommended from this census.
