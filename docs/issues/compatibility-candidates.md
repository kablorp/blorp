# Compatibility And Migration Candidates

These are **current internal bridges**, not source-language compatibility
promises. Select one candidate and write its failing/characterization test
before removing it; do not sweep them together. The paths were checked on
current `main` during the documentation cleanup. Git history preserves the
older audit and resolved migrations.

## Compiler Bridges

| Candidate | Current owner and reason | Removal proof |
| --- | --- | --- |
| Resource rewrite sequencing | `stage_09_core/resource_management.brp` binds rewritten fields and match operands before record/union construction for older emitters. | Test each shape independently; inspect C evaluation and ownership; focused leak/sanitizer plus pinned and newly built two-generation self-host. |
| Pre-contract call ownership guess | `stage_09_core/match_projection.brp` guesses an owned result for a call missing a complete ownership contract. | Require a contract at projection ingress or return a typed error; update malformed fixtures, then delete the guess. |
| Duplicate CTFE imported-module merge | `stage_07_ctfe/context.brp` merges manually repeated module inputs; production preparation already deduplicates by canonical `ModuleId`. | Admit a deduplicated input type or validate uniqueness at construction; no silent duplicate groups. |
| CTFE function-reference type fallback | `stage_07_ctfe/materialize.brp` substitutes `[] -> Void` when a function-reference value carries a non-function type. | Make its payload or constructor guarantee `SemanticFunctionType`; reject malformed values before materialization. |
| Single-letter semantic type-variable guess | `stage_06_typecheck/type_system/semantic_type.brp` and `infer.brp` treat some bare `SemanticNamedType("T", [])` shapes as type variables. | Inventory dynamic producers and tests, use `SemanticTypeVar` everywhere internally, then reject new named-type encodings. Source parameter name `T` remains valid. |
| Duplicate Core identity precedence | `stage_09_core/perceus.brp` and `dce.brp` tolerate conflicting global/constructor identities with deterministic first/last precedence. | Validate exact uniqueness at Core ingress, then simplify both indexes. |
| Foreign linker argument groups | `stage_10_backend/build_artifact_builder.brp` splits an upstream string into argv items. | Keep until typecheck/Core/C-artifact producers carry typed `BuildLinkArgument` items; removing the splitter first breaks valid flags such as `-framework Cocoa`. |
| Expanded match source bridge | `stage_09_core/match_projection.brp` uses separate nested matches because an older bootstrap miscompiled compact overlapping patterns. | Prove the compact form with generated C, match ownership, sanitizer/leak, and two-generation self-hosting. |
| Global-resolution owning shell | `stage_09_core/resolve.brp` carries managed resolution/scope fields through an owning context to protect older bootstrap borrow behavior. | Remove the shell alone, inspect C ownership, run resolve/leak tests and two-generation self-hosting; retain the separate frame-depth-safe dispatcher. |
| Type-containment side tables | `stage_06_typecheck/type_system/env.brp` holds containment facts beside symbols because an older bootstrap corrupted embedded recursive projections. | Prototype embedding against current accepted-authority/session design, compare build and recursive containment behavior, and prove two-generation self-hosting. |

The bootstrap pin's age is not proof that a bridge is safe to remove. For
bootstrap-shaped candidates, a focused current-compiler test alone is
insufficient; retain each bridge until its own generated-C and two-generation
check passes.

## Command-Layout Boundaries

| Candidate | Current owner | Removal proof |
| --- | --- | --- |
| Composite CLI request and plan | `blorp/src/lib/cli_args.brp`, `cli_plan.brp`, and `main.brp` still share cross-command records. | Split command-specific parsing/planning while keeping truly shared request data in `lib`. |
| Formatter parser edge | Exact formatter-to-parser permissions in `blorp/source_ownership.json`. | Supply the shared frontend source boundary, migrate format projection, delete only the corresponding permissions. |
| Purify typed frontend edge | `purify/command.brp`, `source_graph.brp`, and exact ownership permissions consume raw compiler facts. | Expose typed candidate facts through the frontend boundary and remove the recorded cross-owner imports. |
| LSP frontend-analysis edges | LSP analysis still consumes parser/module/typecheck products under exact `source_ownership.json` permissions. | Introduce a compiler-neutral request/result boundary at `main.brp`; project diagnostics and semantics there before deleting permissions. |
| Focused manifest compatibility name | `blorp/test/compiler/compiler_test_ownership.json` and `scripts/compiler-check` retain a compiler-era name despite mirrored command suites. | Treat as a rename-only proposal: preserve selector/CI semantics and update all scripts/docs together. Do not claim suites still need physical migration without new evidence. |

Before assigning any row, recheck its production path and nearest test. If a
row is no longer present, remove it from this list after locating the change
that resolved it. A completed removal leaves its current invariant in
[Architecture](../ARCHITECTURE.md) or the relevant owner reference, not a
historical checklist here.
