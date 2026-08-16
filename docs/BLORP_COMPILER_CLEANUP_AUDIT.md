# Blorp Compiler Cleanup Audit

Status: current inventory, reviewed 2026-08-15

## Scope

This audit covers dead and transitional code in `compiler/blorp`, plus the
scripts, environment controls, tests, and documents that maintain those paths.
Active boundaries are not deletion candidates merely because their names
mention a bridge or compatibility contract.

Run the repeatable source inventory with:

```bash
python3 scripts/audit-compiler-blorp-dead-code
python3 scripts/audit-compiler-blorp-dead-code --json
```

The scanner resolves tracked compiler imports and follows declarations from
these roots. Ignored generated sources are excluded so the inventory is
identical in clean and built worktrees:

- the production CLI;
- every compiler-owned Blorp test;
- every compiler benchmark;
- every other tracked `.brp` source; and
- compiler modules named by build inputs.

It recognizes functions, values, records, structs, unions, enums, opaque
types, type aliases, and resource types. The result remains conservative:
comments and string contents can hide dead code by looking like references,
and field analysis is name-based across all record owners. A reported
declaration has no static caller; a declaration not reported is not
necessarily live.

## Current Snapshot

| Inventory | Count |
|---|---:|
| Compiler source modules | 274 |
| Top-level declarations | 12,770 |
| Unreachable declarations | 55 |
| Estimated unreachable declaration lines | 735 |
| Statically unreachable source modules | 0 |
| Record or struct fields with no dot read anywhere | 9 |
| Union or enum variants with no use | 52 |
| Whole unused import bindings | 1 |
| Non-benchmark foreign-language source files | 0 |

## Mechanical Removal Queue

The conservative scan currently reports 55 possibly unreachable declarations,
9 unread field names, 52 unused variants, and one unused import. These results
need declaration-level review because benchmark and test protocols deliberately
expose entry points that static source traversal cannot always prove live.
Continue to run the audit after each cleanup because removing one disconnected
helper tree can expose another.

The noncanonical generated `compiler_embedded_std.brp` copy and the dead
frontend-graph, exported-symbol, and CLI parsing helpers exposed by the
2026-08-13 scan have been removed. Build configuration now enforces
`stage_01_file_io/embedded_std.brp` as the configured generated Blorp source
and rejects additional generated embedded-std modules.

## Host Toolchain Configuration

`BLORP_RAYLIB_PREFIX` is the only source-only environment control reported by
the cross-reference scan, but it is real host-toolchain configuration. Document
it or replace it with an explicit CLI/build setting; do not classify it as dead.

## Large Tooling To Simplify, Not Blindly Delete

The retained test-session performance subsystem contains 5,444 lines across
its paired benchmark driver, contract tests, and policy, plus its source
fixtures. It is live and has caught real regressions, so it is not dead code.
Its twelve registered workloads, paired statistics, process supervision, and
reproducibility checks remain intentional.

The retired dependency-role schema, split characterization registry,
derived publication metadata, and separate characterization CLI route have
been removed. Comparison and characterization workloads now share one
explicitly tagged registry and one `--workload` selector.

## Active Boundaries To Retain

The following similarly named code remains live:

| Boundary | Why it remains |
|---|---|
| `cli_artifact_json.brp` compile-plan encoding | Explicit benchmark and diagnostic protocols still serialize selected artifacts |
| `typed_ast_json.brp`, module-surface JSON, and source indexes | Blorp-owned tooling and benchmark protocols consume these representations |
| Blorp package manifest/hash/inventory/artifact/cache modules | They implement the production package route |
| `language_surface_manifest.brp` | Type-header installation and compiler tests consume the canonical language-surface facts |
| `BuildCompatibility` and `CArtifact` | Active internal build/emission data despite stale migration wording |
| `is_legacy_single_letter_type_param` | Recognizes valid source generic names such as `T`; the name is stale, not the behavior |
| Perceus helpers containing `legacy` | They have active callers and require ownership-focused replacement, not deletion |

## Recommended Sequence

1. Package routing and lifecycle migration are complete.
2. Retired compiler-host and parser-worker infrastructure is deleted.
3. Build-source generation is consolidated into one Blorp tool.

Package vendoring intentionally preserves the historical destination
publication contract: it stages content before rename and refuses an already
present destination. Two concurrent vendor processes can still race between
that check and the rename. Closing that gap requires a portable atomic
no-replace directory rename primitive in the runtime; shell-level existence
checks are not a correctness substitute.
