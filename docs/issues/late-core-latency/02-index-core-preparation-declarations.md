# Reassess Core-Preparation Declaration Indexing

**Status:** The unconditional-index prototype was rejected. It removed modeled
scans but changed the 1,024-declaration direct-pass paired median from 36,918
to 37,239 µs (+0.87%) without a useful allocation win. The raw decision is in
[`compiler_optimization_round2_2026-09-13.md`](../../../benchmarks/results/compiler_optimization_round2_2026-09-13.md).

**Current state:** `stage_09_core/prepare.brp` still uses first-match whole-
declaration lookups for value records, heap records, unions, and enums.
Dictionary-for-ownership preparation is an earlier Core epoch and needs only
enum membership; final preparation occurs after Perceus and needs broader
facts. Neither can reuse an index across the intervening mutations.

**Next action:** Measure actual query density and index-build cost on small
programs and compiler self-emission. Test a query-gated or lazy pass-local
index in a direct production-pass benchmark. Do not revive the rejected full
unconditional index merely because its synthetic candidate-visit count is
better.

**Read first:** `blorp/src/compiler/stage_09_core/prepare.brp`, its focused
`test_core_prepare.brp`, [Core pipeline](../../ARCHITECTURE.md#core-pipeline),
and the retained benchmark result. If the old direct-pass runner is absent on
current `main`, first establish a small fixture that executes the actual
preparation entry point; do not benchmark a copied lookup model.

## Objective

Determine whether a query-gated or lazy pass-local declaration index can beat
the current first-match lookup behavior on representative preparation
workloads without regressing small or zero-query cases.

## Correctness Boundary

- Canonical Core type names are the current lookup keys. Value-record,
  heap-record, union, and enum namespaces remain distinct even for identical
  spelling. Same-kind duplicates retain **first-declaration wins**, not a
  dictionary's last-write result.
- Union-variant selection requires the containing union, source or C
  constructor spelling, and equal present definition IDs. Missing/mismatched
  IDs fail closed; do not introduce a name-only fallback.
- `program.decls` and record field lists determine output order. A lookup
  table may not reorder declarations or fields, repair malformed Core, or
  change builtin Option/Result fallbacks.
- Index lifetime is one public preparation call in one Core epoch. An early
  enum-only query must not pay for final-pass record/union indexes.

## Fast Loop And Decision

Scale unrelated declarations at fixed record/union/enum query counts, then
scale each query family independently. Include a high-declaration zero-query
control and a representative mixed workload. Record query counts, candidate
visits, index builds/entries, allocation/retained bytes, instructions, direct
pass latency, and an exact prepared-Core checksum. Build both variants from
matched source/host-C inputs, warm and alternate samples, and keep raw data
under `benchmarks/results/`.

Admit a production cut only if the representative direct pass improves beyond
noise, the zero-query/small cases do not regress materially, and allocation
or memory does not merely move into index construction. Require identical
prepared Core, generated C, diagnostics, declaration/field order, and focused
Core/ownership tests. Otherwise record the negative result and close the
indexing idea until the workload changes.
