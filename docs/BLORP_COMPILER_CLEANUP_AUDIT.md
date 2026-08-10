# Blorp Compiler Cleanup Audit

Status: current inventory, reviewed 2026-08-10

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

The scanner resolves compiler imports and follows declarations from these
roots:

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
| Compiler source modules | 195 |
| Top-level declarations | 10,641 |
| Unreachable declarations | 0 |
| Estimated unreachable declaration lines | 0 |
| Entirely unreachable source modules | 0 |
| Record or struct fields with no dot read anywhere | 0 |
| Union or enum variants with no use | 0 |
| Whole unused import bindings | 0 |
| Compiler modules reachable only from tests | 3 |
| Remaining production OCaml source files | 88 |

No compiler source module is currently unreachable. The one module absent from
normal Blorp roots,
`stage_05_types/language_surface_manifest.brp`, is an intentional Dune build
input used to generate the remaining OCaml language-surface table.

## Mechanical Removal Queue

The whole-compiler scan currently reports no unreachable declarations, unread
record or struct fields, unused union or enum variants, or wholly unused import
bindings. Continue to run the audit after each cleanup because removing one
disconnected helper tree can expose another.

## Migration-Specific Removal Queue

These paths are reachable only because compatibility code explicitly keeps
them reachable. They need call-site edits or protocol changes, but no new
feature implementation.

### Document Host Toolchain Configuration

`BLORP_RAYLIB_PREFIX` is the only source-only environment control reported by
the cross-reference scan, but it is real host-toolchain configuration. Document
it or replace it with an explicit CLI/build setting; do not classify it as dead.

### Retire Superseded Maintenance Artifacts

- `scripts/audit-stage-08-dead-code` is superseded by the whole-compiler audit.
- `scripts/audit-compiler-zero-arg-pure` is an unreferenced one-time audit. It
  currently reports zero findings and is not a quality ratchet.
- `docs/BLORP_TEST_SESSION_ROADMAP.md` describes six completed slices. Move any
  remaining durable invariants into `ARCHITECTURE.md`, then delete the roadmap
  as required by `docs/README.md`.

## Large Tooling To Simplify, Not Blindly Delete

The retained test-session performance subsystem contains about 5,600 lines
across its paired benchmark driver, contract tests, policy, and fixtures. It is
live and has caught real regressions, so it is not dead code. Its migration
comparison and historical route schema remain larger than the production test
planner they measure.

Retain one paired benchmark driver and the workloads that detect compile-time
or peak-RSS regressions. Reassess migration-only route metadata independently.
Do not remove the measured compiler-suite and oversized-suite workloads until a
smaller replacement still catches the recent CI failures.

## Active Boundaries To Retain

The following similarly named code remains live:

| Boundary | Why it remains |
|---|---|
| `blorp-ocaml-host` and `BLORP_OCAML_HOST_BIN` | Production `lsp`, package commands, and private host commands still delegate |
| Parser bridge executable and prepared-bridge environment | The OCaml host and pinned bootstrap still consume it |
| `cli_artifact_json.brp` compile-plan encoding | The pinned bootstrap consumes one compile graph while building the public CLI |
| `typed_ast_json.brp`, module-surface JSON, and source indexes | Remaining OCaml tools and compatibility fixtures consume these protocols |
| Blorp package manifest/hash/inventory modules | They are tested ports awaiting production package routing |
| `language_surface_manifest.brp` | Dune generator input for the active OCaml language surface |
| `BuildCompatibility` and `CArtifact` | Active internal build/emission data despite stale migration wording |
| `is_legacy_single_letter_type_param` | Recognizes valid source generic names such as `T`; the name is stale, not the behavior |
| Perceus helpers containing `legacy` | They have active callers and require ownership-focused replacement, not deletion |
| OCaml unit and fixture gates | They cover 88 remaining production OCaml files until those consumers move |

The production OCaml inventory currently contains 47 type-system files, 33
tool files, four parser files, two final-layout files, one CTFE file, and one
bridge file. Removing setup, opam, Dune test, or host packaging globally before
those consumers move would break production LSP/package behavior and retained
compiler fixtures.

`BLORP_FRONTEND_PARSER` is a special bootstrap compatibility input. Current
compiler sessions do not read it, but `compiler_blorp_bridge.ml` still sets it
for pinned external bootstrap helper builds. Retest and remove it when the
pinned bootstrap no longer requires the selector; do not preserve it after
that point.

## Recommended Sequence

1. Retire completed audit/roadmap artifacts and correct stale migration
   comments.
2. Reassess migration-only metadata in the retained paired benchmark without
   weakening its registered regression workloads.
