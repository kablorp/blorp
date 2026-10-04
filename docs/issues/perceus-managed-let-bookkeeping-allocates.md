# Perceus managed-let and owned-value bookkeeping

Status: open. Former cleanup P5.

## Reproduction and cause

`PerceusManagedLetPlan` has ten fields, five `CoreExpr`s produced by earlier
`plan_managed_let` steps. `rebuild_managed_let` and
`managed_let_reuses_source` consume it. If the plan never travels farther,
compute fields as locals and publish once at the return. Separately,
`exact_owned_vars_add`, `exact_owned_vars_remove` and
`exact_owned_vars_contains` maintain a `CoreVar` set over a list.

## Proposed change and dependencies

Attribute each shape using `BLORP_PERCEUS_ENGINE_METRICS`,
`perceus/work_counters.brp` and `stage_09_core/work_profile.brp`; report each
item's effect separately and change only shapes the counters show matter.
The managed-let part is independent of the
[common frame stack](perceus-frame-stacks-duplicate-traversal-storage.md).
The owned-value set waits for strict value IDs in the
[Identity roadmap](../IDENTITY_ROADMAP.md), "Late-Core consumers by exact id"
(former P3). Probe a typed-ID set only after that prerequisite; neither raw
`CoreVar.id`, spelling nor an invented integer pair encoding is exact identity.

## Acceptance and owner

Owner: `blorp/src/compiler/stage_09_core/perceus/results_and_loops.brp`
and the exact-owned-variable helpers under `perceus/`.
Use [Worker Checklist](../WORKER_CHECKLIST.md) and the
[measurement protocol](../../benchmarks/README.md#self-compile-measurement-protocol).
Frozen parent/candidate self-compile and checksum-pinned small input must
produce byte-identical C. The affected engine row,
`pass_perceus_complete` and total allocations must not rise; retired
instructions must not rise beyond 0.3%. Record decreases with their mechanism;
do not promise a speed gain without measured dynamic reach.

Run `test_core_perceus.brp` (`--timeout 600`), `make hygiene-check`,
`scripts/compiler-check --changed`, serial `compiler-blorp` and
`compiler-tools` gates, `leak` and `compiler-core-sanitize`; add `runtime`
when ownership behavior could change. Do not parallelize compiled test
binaries, Perceus or late-Core passes. Gate verdict: `BLORP_GATE_RESULT`.
Retained attribution:
[pass](../../benchmarks/results/perceus_allocation_attribution_2026-09-22.md),
[engine](../../benchmarks/results/perceus_engine_attribution_2026-09-22.md).

Keep the assignment-alias environment ownership intact: moving `env` out of
its context was rejected; the invariant is documented beside
`AssignmentAliasNormalizationContext` in `perceus/mutable.brp`.
