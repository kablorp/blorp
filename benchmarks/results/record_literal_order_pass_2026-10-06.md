# Cost of the record_literal_order pass (2026-10-06)

`record_literal_order` binds the field values of every record literal that is
not written in declaration order to variables, in written order, before
Perceus (`docs/OWNERSHIP_MODEL.md`, "Record Literal Field Order"). It walks
every function body with `map_core_expr_children_with_state`, because the
binders it mints are counter ids from `CorePassState.next_binder_id`.
Lowering cannot do the binding: `TypedRecordExpr` carries no declared field
list (only `TypedRecordUpdateExpr` does), so lowering would need a typed-AST
change or a second source of declaration order. The construction form in
[`PRODUCT_UNIFICATION.md`](../../docs/PRODUCT_UNIFICATION.md#2-operations)
carries evaluation order and storage position separately and replaces the
pass.

## Provenance and command

- Baseline: stage-2 compiler at `620475e4d` (origin/main). Candidate: stage-2
  compiler at the change that adds the pass, rebased on `620475e4d`.
- Both built with `BLORP_CLI_C_OPTIMIZATION=-O2 make`, Apple clang 21.0.0,
  arm64; build status `FRESH` before each measurement.
- Input frozen at `620475e4d` for both; two samples each.

```bash
benchmarks/self_compile_measure --stage2 --label baseline \
  --input-rev 620475e4d --output baseline.json
benchmarks/self_compile_measure --stage2 --label candidate \
  --input-rev 620475e4d --baseline baseline.json --output candidate.json
```

Raw results: [`record_literal_order_pass_2026-10-06/`](record_literal_order_pass_2026-10-06/).

## Result

| Metric | Baseline | Candidate | Delta |
| --- | ---: | ---: | ---: |
| `pass_record_literal_order_complete` allocations | | 1,447,706 | new |
| Allocations in all other passes | | | +7,625 in total, at most +0.02% per pass |
| Total allocations | 244,620,519 | 246,075,850 | +0.59% |
| Instructions retired (min) | 226,300,447,913 | 226,802,505,365 | +0.22% |
| Output C bytes | 82,783,886 | 82,784,474 | +588 |
| Peak RSS | 2,182,053,888 | 2,179,399,680 | -0.12% |

Generated C differs only for the compiler's own out-of-order literals, which
bind 32 field values. Wall time is not evidence here: phase totals moved by
more than the pass costs, in both directions, on a loaded host.

Nearly all of the pass's allocations are the `CoreMapState` record the
stateful child map returns per visited node; the rewrite itself fires on a
handful of literals. A read-only prefilter per function, or folding the walk
into an existing pre-Perceus walk once that walk can mint binder ids, would
remove most of it if the cost matters before the construction form lands.
