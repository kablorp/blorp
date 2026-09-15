# Index Perceus Consumed-Parameter Membership Locally

**Status:** Proposed; independent admission experiment after a prior rejection

**Current state:** `simple_consumed_parameter_catalog` calls
`int_list_contains(consumed_params, index)` for each parameter on its >=16-item
fast path. The retained self-compile observed 12,975 calls.
**Next action:** Add threshold/invalid-index tests, then compare one local
dictionary against the current scan on sparse and dense signatures.
**Read first:** `blorp/src/compiler/stage_09_core/perceus.brp`,
`blorp/test/compiler/stage_09_core/test_core_perceus.brp`, and the
[rejected consumed-index result](../../../benchmarks/results/compiler_consumed_argument_membership_rejected_2026-09-15.md).
**Fast loop:** Use the Perceus suite and exact 15/16/32 consumed-parameter
points in `benchmarks/compiler_perceus_memory`, varying total parameters
separately.
**Decision:** Do not revive Issue 105's sorted-list representation, which
regressed dense cases. Reject immediately if dictionary construction repeats
that allocation tradeoff.

## Objective

Approach one expected-constant membership probe per parameter while preserving
the fast path's fail-closed eligibility rules.

## Proposed Shape And Invariants

Build one `Dict[Int, Bool]` from `consumed_params` before walking parameters.
Negative, out-of-range, or duplicate indexes must make this helper return
`None` and use the existing general fallback, exactly as they do today. Then
replace only `int_list_contains(consumed_params, index)`. Keep the ordered
contract list outside this private invocation.

- Preserve the `consumed_params.length() >= 16` threshold; it is a consumed
  count, not total signature width.
- Preserve `None` eligibility fallback for invalid/duplicate indexes, unmanaged
  parameters, nonzero `uniq`, present `def_id`, duplicate names, and managed
  return types; do not add a diagnostic or new rejection path.
- Preserve the resulting name-to-index catalog and general fallback behavior.
- Cover 15/16/32, sparse/dense, first/last/out-of-range/negative/duplicate, and
  valid/invalid identity combinations.
- Do not change the ownership ABI, proof traversal, or other membership sites.

## Measurement And Commands

Run alternating baseline/candidate direct-Perceus samples with total parameter
width and consumed count as independent axes. Every sparse admitted workload
must still contain at least 16 consumed parameters; use 15 and 16 consumed
entries at fixed total width for the threshold boundary. Report index
construction, membership probes, allocations/releases, instructions, elapsed
time, and post-Perceus Core hash.

```bash
bin/blorp test --timeout 180 blorp/test/compiler/stage_09_core/test_core_perceus.brp
python3 -m unittest blorp.test.compiler.benchmark.test_perceus_memory
scripts/compiler-check --changed
scripts/test compiler-core-sanitize leak
```

## Acceptance And Rejection

Accept only if invalid/canonical semantics match, sparse and dense admitted
cases with at least 16 consumed parameters each improve instructions or
allocations by at least 10%, 15/16 consumed-count threshold points plus small
signature controls remain within 3%, and no retained growth appears. Reject if
dictionary construction is repeated, dense allocations regress, or a second
contract representation escapes the invocation.
