# Blorp Compiler Cleanup Audit

Status: current inventory, reviewed 2026-08-15

## Scope

This audit covers dead and migration-specific code in `compiler/blorp`, plus
the scripts, environment controls, tests, and documents that maintain those
paths. It separates mechanically unreachable code from active OCaml migration
boundaries. Active boundaries are not deletion candidates merely because their
names mention a bridge, compatibility, or OCaml.

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
| Remaining production OCaml source files | 0 |

The production build graph contains no OCaml source. The files under
`compiler/test/` remain a frozen, non-executable historical archive.

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

## Migration-Specific Removal Queue

No compiler-host compatibility path remains. The remaining migration target is
the generator toolchain, not a second compiler implementation.

### Document Host Toolchain Configuration

`BLORP_RAYLIB_PREFIX` is the only source-only environment control reported by
the cross-reference scan, but it is real host-toolchain configuration. Document
it or replace it with an explicit CLI/build setting; do not classify it as dead.

## Large Tooling To Simplify, Not Blindly Delete

The retained test-session performance subsystem contains 5,444 lines across
its paired benchmark driver, contract tests, and policy, plus its source
fixtures. It is live and has caught real regressions, so it is not dead code.
Its twelve registered workloads, paired statistics, process supervision, and
reproducibility checks remain intentional.

The migration-only dependency-role schema, split characterization registry,
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

This audit originally counted remaining OCaml files by migration category.
Those counts are a dated planning snapshot, not a quality contract. Current
ownership must be established from the build graph and production call paths;
OCaml source text is intentionally not governed by hygiene allowlists. The 47
files under `compiler/test/` are a frozen, non-executable archive; their dated
coverage ledger is historical evidence rather than a runnable gate.

## Recommended Sequence

1. Package routing and lifecycle migration are complete.
2. The unreachable OCaml package implementation, compiler library, host, and
   parser-worker build infrastructure are deleted.
3. The three source generators were consolidated into one Blorp tool, removing
   opam and OCaml from production build, CI, release, and Docker routes.

Package vendoring intentionally preserves the historical destination
publication contract: it stages content before rename and refuses an already
present destination. Two concurrent vendor processes can still race between
that check and the rename. Closing that gap requires a portable atomic
no-replace directory rename primitive in the runtime; shell-level existence
checks are not a correctness substitute.
