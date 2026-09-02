# Delete Legacy Declaration Materialization And Reprofile

**Status:** Superseded by Issue 43 of `ENVIRONMENT_REUSE_ROADMAP.md`

## Context And Dependencies

This document is retained only as prior planning context. The executable final
cleanup is now `43-delete-legacy-environment-materialization-and-reprofile.md`,
after the roadmap has established a retained production catalog, explicit
canonical and CTFE module views, and migrated every graph-owned declaration
family out of `Env`.

This issue is the mandatory cleanup and proof step. It deletes the old
materialization architecture, makes regressions structurally detectable, and
measures whether the complete sequence improves compiler self-compilation.

Do not treat this issue as optional polish. Leaving dead builders, dual reads,
or duplicate graph state would preserve complexity and make future regressions
likely.

## Problem Statement

After a staged migration, a codebase commonly retains:

- unused registration helpers;
- graph declaration fields in `Env`;
- compatibility adapters between catalog IDs and old symbols;
- counters that observe paths no longer allowed;
- tests that construct invalid legacy states;
- comments describing obsolete authority boundaries; and
- fallback reads that hide incomplete migration.

Those remnants consume maintenance effort even if they no longer dominate
runtime. More importantly, they make it possible to accidentally restore
per-module declaration publication later. The final architecture needs explicit
negative assertions and whole-compiler evidence.

## Goal

1. Delete every obsolete graph-declaration materialization path.
2. Reduce `Env` and related records to their documented lexical responsibilities.
3. Remove compatibility adapters and duplicate identity/name storage that have
   no remaining production consumer.
4. Add permanent structural assertions against repeated graph publication and
   graph-wide exact-query scans.
5. Reprofile typechecking and whole compiler self-compilation on current main.
6. Update architecture and performance documentation with measured results and
   remaining bottlenecks.

## Non-Goals

- Do not add unrelated optimizations to improve the final numbers.
- Do not retain dead APIs for backwards compatibility; the compiler is pre-0.1.
- Do not weaken tests merely because they construct legacy internals.
- Do not claim a multi-fold speedup unless production measurements show it.
- Do not delete lexical scope machinery.

## Phase 1: Prove The New Authority Is Complete

Before deleting anything, produce an inventory of every accepted declaration
category:

| Category | Catalog storage | Module-view visibility | Production readers | Legacy readers | Legacy writers |
| --- | --- | --- | --- | --- | --- |

The required categories are types, constructors, aliases, functions, globals,
traits, trait methods, implementations, implementation methods, overloads,
UFCS candidates, type homes, resource facts, foreign facts, builtin facts, and
debug-only facts.

Every row must have production readers through the catalog/view and zero
required legacy readers before deletion begins.

## Phase 2: Delete In Dependency Order

Delete in this order so compiler errors expose missed consumers clearly:

1. legacy imported-module declaration publication loops;
2. legacy accepted local header publication loops;
3. category-specific `Env` graph insertion helpers;
4. generic mixed-symbol batching helpers that no longer have lexical callers;
5. graph-only fields and indexes from `Scope`, `Env`, `TypecheckState`, and body
   seed records;
6. adapters converting catalog entries back into legacy `Symbol`/
   `OverloadEntry`/trait/impl records;
7. dual-read validation bridges and fallback branches;
8. migration-only counters that merely compare old and new answers;
9. tests and fixtures whose only purpose was constructing legacy graph state;
10. stale imports, wrappers, comments, and docs.

Use `rg` after each deletion family. Do not leave deprecated aliases or private
wrappers around deleted APIs.

## Phase 3: Audit Every Remaining Broad Record

For each field in `Scope`, `Env`, `TypecheckState`, `InferModuleFacts`, accepted
body seeds, and graph facts, document one of:

- lexical/body-local state;
- graph catalog ownership;
- module visibility projection;
- diagnostic/recovery state;
- inference cache with an explicit lifetime; or
- deletion.

Remove fields that are always empty, always derivable from the catalog, or only
written/read by tests. If removing a field requires a new semantic design,
record a follow-up instead of silently broadening this issue.

## Permanent Structural Assertions

Keep a small production-shaped observation surface or focused test hook that
asserts:

```text
accepted_declaration_catalog_builds == 1
module_declaration_views_built == accepted_module_count
legacy_graph_symbol_installs == 0
legacy_imported_declaration_publications == 0
legacy_local_declaration_publications == 0
exact_catalog_query_graph_scans == 0
```

Also retain the existing scope-materialization scaling assertions:

- catalog construction is linear in accepted declaration count;
- adding unrelated modules does not increase exact-query candidate visits;
- module-view construction scales with actual visible edges/declarations, not
  the complete declaration closure for every module; and
- lexical scope insertion remains proportional to body-local declarations.

Prefer deterministic logical counters over elapsed-time-only tests.

## Correctness Verification

Run the complete focused ownership manifest and all public compiler fixtures:

```bash
make
scripts/compiler-check --validate-manifest
scripts/compiler-check --stage typecheck
scripts/test compiler-blorp
scripts/test compiler-tools
scripts/test std-check
scripts/test runtime
scripts/test leak
scripts/test cli
scripts/test lsp
scripts/test compiler-blorp-sanitize
scripts/test compiler-core-sanitize
make quality
```

Run the codegen audit if any identity or lowering adapter was deleted. Confirm
that no generated `.c` artifacts remain in the repository.

Add explicit stale-symbol checks for deleted registration API names to the
focused migration test or hygiene script when practical.

## Final Scaling Measurement

Rerun the existing scope-materialization matrix with exactly the same workload definitions and report
baseline, post-batching, and final-catalog states. Include:

- modules 1, 4, 16, 64, 256;
- declarations per module 1, 8, 32, 128;
- import chain, fan-out, and diamond graphs;
- type/constructor-heavy workloads;
- callable/overload/UFCS-heavy workloads; and
- mixed compiler-shaped workloads.

For each row report setup, publication, catalog/view construction, body query,
and total windows; allocations/releases; retained objects/bytes; and all
logical work counters. Calculate empirical exponents for module and declaration
growth. Flag any exponent materially above 1.2 for work that should be linear.

## Production Typecheck Replay

Capture one current compiler CLI typecheck request. Build baseline and candidate
workers from controlled source states with the same bootstrap compiler. Run at
least five alternating pairs after one warmup per worker.

Require:

- byte-identical responses;
- identical diagnostics and ordering;
- recorded worker and request hashes;
- named typecheck checkpoint time;
- end-to-end replay elapsed time;
- allocation/release/current-object/allocator-byte counters; and
- peak sampled RSS.

Report every pair and medians. Do not hide noisy or unfavorable rows.

## Whole-Compiler Profile

Run at least three unsampled production-shaped self-compilations and one sampled
profile. Compare against the current baseline using the same command and build
mode. Report:

- frontend, backend, and total phase time;
- wall time;
- allocations and peak RSS;
- generated C size;
- top cumulative compiler functions;
- top invocation counts; and
- the former peaks around `scope_add_symbol`, callable-header registration,
  imported-module registration, and scope lookup.

Also collect exact LLVM instrumentation counters for the affected call sites if
that mechanism remains available. The expected result is not merely shorter
individual flames: the total frontend sample mass and allocation count should
fall.

## Acceptance Criteria

Accept only if:

1. no legacy graph declaration materialization remains in production;
2. all declaration categories have one catalog authority;
3. `Env` has a documented lexical-only responsibility;
4. permanent counters prove zero graph publication and zero graph scans for
   exact queries;
5. catalog and module-view construction are linear on synthetic scaling tests;
6. production responses and diagnostics are unchanged;
7. production replay allocations materially decrease;
8. peak RSS does not materially regress;
9. production frontend time improves beyond noise, or the issue explicitly
   records why the architectural simplification is retained despite neutral
   timing; and
10. all focused, broad, sanitizer, leak, hygiene, and quality gates pass.

If catalog/view construction simply replaces the old cost or production timing
regresses, reject or revise the architecture. Do not defer the evidence to a
future optimization.

## Documentation Updates

Update `docs/ARCHITECTURE.md` with catalog ownership and lexical `Env`
boundaries, `docs/COMPILER_PRIORITIES.md` with measured results and next
bottlenecks, and the compatibility ledger when its accepted-declaration entry
is resolved.

## Valid Merge Point

This is the final merge point for the declaration-materialization sequence. It
must leave no migration-only fallback and no required follow-up for correctness.
Further optimizations may build on the catalog, but the compiler must be
coherent, measurable, and fully tested at this point.
