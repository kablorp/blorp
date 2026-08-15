# Blorp Compiler Cleanup Audit

Status: current inventory, reviewed 2026-08-13

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
- the parser worker;
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
| Compiler source modules | 242 |
| Top-level declarations | 11,427 |
| Unreachable declarations | 36 |
| Estimated unreachable declaration lines | 449 |
| Statically unreachable source modules | 1 |
| Record or struct fields with no dot read anywhere | 11 |
| Union or enum variants with no use | 53 |
| Whole unused import bindings | 1 |
| Compiler modules reachable only from tests | 44 |
| Remaining production OCaml source files | 87 |

The one module absent from normal Blorp roots,
`stage_05_types/language_surface_manifest.brp`, is an intentional Dune build
input used to generate the remaining OCaml language-surface table.

## Mechanical Removal Queue

The whole-compiler scan currently reports no unreachable declarations, unread
record or struct fields, unused union or enum variants, or wholly unused import
bindings outside the active Blorp LSP foundation. Its 36 unreachable
declarations, 11 unread fields, 53 unused variants, and one unused import are
test-only architecture under active development, not retained production
compatibility. Continue to run the audit after each cleanup because removing
one disconnected helper tree can expose another.

The noncanonical generated `compiler_embedded_std.brp` copy and the dead
frontend-graph, exported-symbol, and CLI parsing helpers exposed by the
2026-08-13 scan have been removed. Build configuration now enforces
`stage_01_file_io/embedded_std.brp` as the configured generated Blorp source
and rejects additional generated embedded-std modules.

## Migration-Specific Removal Queue

These paths are reachable only because compatibility code explicitly keeps
them reachable. They need call-site edits or protocol changes, but no new
feature implementation.

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
| `blorp-ocaml-host` and `BLORP_OCAML_HOST_BIN` | Package commands and compiler-bridge preparation still cross an explicit host boundary; production LSP does not |
| Parser bridge executable and prepared-bridge environment | The OCaml host and pinned bootstrap still consume it |
| `cli_artifact_json.brp` compile-plan encoding | The bridge envelope serializes compile plans for internal callers |
| `typed_ast_json.brp`, module-surface JSON, and source indexes | Parser/typecheck bridge workers and the remaining OCaml package host consume these protocols |
| Blorp package manifest/hash/inventory modules | They are tested ports awaiting production package routing |
| `language_surface_manifest.brp` | Dune generator input for the active OCaml language surface |
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

1. Route package `check` and `hash` through the existing Blorp-owned manifest,
   inventory, and hashing modules.
2. Port the remaining package commands and delete the package host boundary
   once their public integration coverage is maintained.
3. Remove bridge-only OCaml subsystems as their remaining package and bootstrap
   consumers move to Blorp.
