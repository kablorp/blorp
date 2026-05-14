# Compiler Pipeline Quality Audit

This audit covers the active compiler pipeline from CLI entry points through
frontend orchestration, Core passes, final Core preparation, and C backend
emission. It is a findings catalog, not a commitment to a specific sequence of
work. Small cleanup items are called out separately from larger design
opportunities.

Source of truth for the Core pass order is `compiler/lib/core_pipeline.ml`.

## Low-Risk Cleanup Status

The first cleanup pass addressed the most mechanical findings:

- Removed the single-reference production helpers listed below.
- Moved module-local type-name collection to `Ast`.
- Added `Codegen_names.source_name_for_generated_function` and migrated the
  repeated resolver/std-inline/closure/synth logic to it.
- Fixed the quadratic FFI metadata accumulator in `Core_pipeline`.
- Refreshed the stale pipeline/layout comments called out in
  `docs/ARCHITECTURE.md`, `core_pipeline.ml`, `core_trait_resolve.ml`,
  `core_perceus.ml`, `core_desugar.ml`, `core_emit_context.ml`,
  `pipeline.ml`, `pipeline.mli`, `modules.ml`, `modules.mli`,
  `typecheck.ml`, `subscript_desugar.ml`, `nested_hoist.ml`, and
  `compiler/bin/blorp.ml`.

## Scope

- CLI and orchestration: `compiler/bin/blorp.ml`, `compiler/lib/pipeline.ml`,
  `compiler/lib/pipeline.mli`.
- Frontend pipeline helpers: `modules.ml`, `parser.mly`, `lexer.mll`,
  `interp_parser.ml`, `nested_hoist.ml`, `subscript_desugar.ml`,
  `infer.ml`, `typecheck.ml`.
- Core orchestration and support: `core_pipeline.ml`, `core_stage.ml`,
  `core_profile.ml`, `core_flatten.ml`, `core_ffi_boundary.ml`,
  `core_list_layout.ml`.
- Core pass sequence: `core_lower.ml`, `core_debug.ml`, `core_desugar.ml`,
  `core_ssa.ml`, `core_mono.ml`, `core_synth.ml`, `core_match.ml`,
  `core_trait_resolve.ml`, `core_resolve.ml`, `core_std_inline.ml`,
  `core_tailrec.ml`, `core_string_pipeline.ml`,
  `core_collection_pipeline.ml`, `core_tensor_fusion.ml`,
  `core_tuple_sroa.ml`, `core_specialize.ml`, `core_perceus.ml`,
  `core_reuse.ml`, `core_closure.ml`, `core_codegen_prepare.ml`.
- Backend boundary: `backend.ml`, `core_emit_c.ml`, `core_emit_context.ml`,
  `core_emit.ml`, and the split-out emit helper modules where relevant.
- Documentation checked during this pass: `docs/ARCHITECTURE.md` and
  `docs/CODEGEN_PIPELINE_AUDIT.md`.

## Small Findings And Cleanup Status

### Removed Production Helpers

The dune warning set does not enable warning 32 for unused top-level values, so
local `let` bindings exported by a module can drift. A simple single-reference
scan across `compiler/lib`, `compiler/bin`, and `compiler/test` found these
production helpers with only their definition as a reference; the cleanup pass
removed them:

| File | Helper | Notes |
| --- | --- | --- |
| `compiler/lib/typecheck.ml` | `typecheck_with_state` | `typecheck_with_state_typed` and `typecheck_with_state_and_source` are used; this compatibility wrapper appears unused. |
| `compiler/lib/diagnostics.ml` | `format_warnings` | `format_warning` and `format_errors` are used; plural warning formatting appears unused. |
| `compiler/lib/core.ml` | `storage_policy_hash` | Storage retain/release/equality helpers are used; hash helper appears unused. |
| `compiler/lib/core.ml` | `tensor_word_storage` | Adjacent tensor storage constructors are used; this one appears unused. |
| `compiler/lib/core.ml` | `tensor_storage_unknown` | Constructor wrapper appears unused; direct variant construction may have replaced it. |
| `compiler/lib/core.ml` | `tensor_storage_validated_boundary` | Constructor wrapper appears unused. |
| `compiler/lib/core.ml` | `tensor_storage_proven_layout` | Accessor appears unused. |
| `compiler/lib/lsp/lsp_completion.ml` | `_kind_text`, `_kind_field`, `_kind_interface` | Underscore naming makes these intentionally warning-silent; delete unless kept as a visible LSP kind inventory. |

The scan intentionally did not flag helpers that are referenced by unit tests,
such as `Core_reuse.analyze_expr` and `Core_codegen_prepare.prepare_expr`.

### Stale Docs And Comments

| File | Finding |
| --- | --- |
| `docs/ARCHITECTURE.md` | Fixed: removed references to non-existent `core_erased_storage_layout.ml`; current docs point at `core_layout_type.ml` and `core_type_layout.ml`. |
| `compiler/lib/core_pipeline.ml` | Fixed: header now includes `Core_codegen_prepare` before `Core_emit_c`. |
| `compiler/lib/pipeline.mli` | Fixed: removed the dated phase label from `compile_outcome` docs. |
| `compiler/lib/pipeline.ml` | Fixed: refreshed the session-boundary comment. |
| `compiler/lib/modules.ml` | Fixed: parse-source comments now describe the current lexer reset boundary without migration-era labels. |
| `compiler/lib/subscript_desugar.ml` | Fixed: converted the "Phase 2.3" framing to current pass-contract language. |
| `compiler/lib/nested_hoist.ml` | Fixed: header now reflects recursive nested hoisting. |
| `compiler/lib/core_desugar.ml` | Fixed: removed the historical Try/TryBind removal section and refreshed the SSA split note. |
| `compiler/lib/core_trait_resolve.ml` | Fixed: removed the contradictory operator-overloading non-goal text. |
| `compiler/lib/core_perceus.ml` | Fixed: header now points reuse selection at the downstream `Core_reuse` pass. |
| `compiler/lib/core_emit_context.ml` | Fixed: removed legacy `Codegen_emit.gen_literal` duplication wording. |
| `compiler/bin/blorp.ml` | Fixed: compile-option and dump-provenance comments now use user-facing behavior instead of dated phase labels. |

### Naming Clarity

| Name | Issue |
| --- | --- |
| `Core_stage.Fusion` | The stage contains string fusion, collection fusion, tensor update fusion, and tuple SROA. The name is too narrow for dumps/profiles. |
| `Core_profile` | This profiles compiler phases, while generated programs also use `--profile` for runtime profiling. `Core_phase_profile` or `Pipeline_profile` would be clearer. |
| `Core_codegen_prepare` | The pass prepares final Core representation facts for C emission. `Core_emit_prepare` would better reflect its backend-facing role if it stays C-specific. |
| `compile_typed_with_modules` | Returns generated output plus C link/include metadata. The name hides the backend/output shape. |
| `Core_fusion` in `docs/ARCHITECTURE.md` | The actual stage variant is `Fusion`; there is no `core_fusion.ml`. The diagram label is a conceptual bucket and should say so or use `Fusion`. |

## Per-File Catalog

| File | Small cleanup candidates | Larger opportunities |
| --- | --- | --- |
| `compiler/bin/blorp.ml` | Remove dated phase labels from option comments; consider splitting `--profile` wording from `--time-phases` more consistently. | Split CLI parsing by subcommand once changes here become risky; `compile`, `run`, `test`, LSP, REPL, and purify are all in one file. |
| `compiler/lib/pipeline.mli` | Drop migration-era phase labels in docs. | Expose fewer AST compatibility paths over time; typed boundaries are the safer public shape. |
| `compiler/lib/pipeline.ml` | Module-local type-name collection now uses `Ast.module_local_type_names_from_decls`; the session-boundary comment has been refreshed. | `ensure_modules_typed` and `check_modules` share module-typechecking loops; extract one module-typing driver. Cross-module impl coherence is pairwise and could be bucketed by impl key if module counts grow. |
| `compiler/lib/modules.ml` | Refresh comments around parse postprocessing and rename hints. | Module resolution, package lookup, parse caching, export collection, config parsing, and error shaping all live here; split resolver/cache/export/config responsibilities when touching this area. |
| `compiler/lib/parser.mly` | Removed `builtin func` comments are useful for diagnostics now, but can be shorter. | Parser grammar remains large; grammar docs should continue to be generated or audited from parser changes. |
| `compiler/lib/lexer.mll` | No concrete cleanup beyond keeping removed-syntax diagnostics current. | Lexer state remains process-global with session-level guards elsewhere; if LSP concurrency increases, make lexing state explicit. |
| `compiler/lib/interp_parser.ml` | No obvious small cleanup in this scan. | Interpolation reparses expression snippets through parser machinery; keep parser error remapping tests strong if interpolation syntax expands. |
| `compiler/lib/nested_hoist.ml` | Header non-goals are stale; `rewrite_ident` comment admits it does not respect all shadowing. | Replace string substitution with a scoped AST rewrite that models binders explicitly. This removes a heuristic that conflicts with the "no flimsy heuristics" rule. |
| `compiler/lib/subscript_desugar.ml` | Convert dated phase commentary to current pass-contract docs. | Assignment subscript still stays in inference for semantic reasons; if this grows, represent read/write subscript intent explicitly in AST instead of relying on call names. |
| `compiler/lib/infer.ml` | Module-local type-name collection now uses the shared `Ast` helper; several registry comments still have old phase labels. | Split refinement/proof logic, special builtin inference, call inference, and diagnostics into focused modules. The current single file is doing too many phase-specific jobs. |
| `compiler/lib/typecheck.ml` | The unused `typecheck_with_state` wrapper was removed; module-local type-name collection now uses the shared `Ast` helper. | Split import processing, trait/impl coherence, exhaustiveness, purity, and main-signature validation into smaller modules with explicit state transitions. |
| `compiler/lib/core_pipeline.ml` | Header omits `Core_codegen_prepare`; FFI metadata fold uses `@` inside `List.fold_left`. | Make `Core_codegen_prepare` observable as a stage or document why it only appears under `Final`. Split `Fusion` timing so compiler profiles show which subpass costs time. |
| `compiler/lib/core_stage.ml` | `Fusion` name is too broad; `CodegenPrepare` has no stage despite being a real pass. | Any stage split is CLI/user-facing because `--dump-core-after` and `--stop-after` accept these names. Add aliases if renaming. |
| `compiler/lib/core_profile.ml` | Module name is ambiguous with runtime profiling. | Add substage labels for compound stages before optimizing compile time. |
| `compiler/lib/core_flatten.ml` | Dated phase comments and old dedup-history text can be reduced. | Import-table construction and module-prefix rewriting are both here; split once module identity rules change again. |
| `compiler/lib/core_ffi_boundary.ml` | No obvious small cleanup. | Good pattern for explicit boundary facts; future FFI policy additions should extend this data model rather than reclassifying in emit. |
| `compiler/lib/core_list_layout.ml` | No obvious small cleanup. | Traversal shape overlaps with other late annotation passes; if more layout annotations appear, add a small traversal helper. |
| `compiler/lib/core_lower.ml` | Dated migration comments around fresh counters, try lowering, tensor phases, and legacy naming. | File is over 2k lines; split lowering by domain: blocks/control flow, functions/closures, tensors, collections, concurrency, and declarations. |
| `compiler/lib/core_debug.ml` | No obvious small cleanup. | Narrow pass; keep as-is. |
| `compiler/lib/core_desugar.ml` | Delete or shorten the removed Try/TryBind section; remove old SSA split note. | Shared Core builder helpers would reduce repeated local `mk`/`var`/`seq` style across passes. |
| `compiler/lib/core_ssa.ml` | Dated phase comments only. | The shadow-aware substitution and ctree substitution logic overlaps with other passes; a shared scoped-rewrite utility would reduce risk. |
| `compiler/lib/core_mono.ml` | No single dead helper found; comments are mostly current. | Specialization keys, worklists, import-aware lookup, and impl specialization are coupled. A typed specialization-key module would make illegal states harder to represent. |
| `compiler/lib/core_synth.ml` | No obvious small cleanup. | If synthesis grows beyond a few cases, switch to a dispatch table keyed by intrinsic/builtin manifest entries. |
| `compiler/lib/core_match.ml` | Header still frames some content as a prior phase prerequisite. | Match compilation can improve algorithmically with column-choice heuristics; list-pattern lowering preserves source order and should stay covered by tests before changes. |
| `compiler/lib/core_trait_resolve.ml` | Contradictory operator-overload docs. | Trait method lookup, direct-function shadowing, and diagnostic suggestions overlap with `core_resolve`; consider a shared call-resolution context. |
| `compiler/lib/core_resolve.ml` | Generated function source-name normalization now goes through `Codegen_names`. | Keep call-resolution precedence and import-shadowing behavior covered by tests when changing resolver lookup. |
| `compiler/lib/core_std_inline.ml` | Generated function source-name normalization now goes through `Codegen_names`. | Rewrite target collection is allowlist-driven; keep it table/data driven if more std wrappers become compiler-owned. |
| `compiler/lib/core_tailrec.ml` | Local utilities such as `nth_opt` can use standard library equivalents where available. | ctree traversal/support checks overlap with emit, Perceus, tuple SROA, and SSA; shared ctree traversal helpers would help. |
| `compiler/lib/core_string_pipeline.ml` | Repeated fresh-name/lowering drivers across `lower_length`, materialized replace, reverse, and window. | Represent string pipeline lowering as a single driver with terminal strategies. `append_stage` uses list append; probably fine for short chains but avoid if pipelines get longer. |
| `compiler/lib/core_collection_pipeline.ml` | Repeated Core builder helpers and capture checks. | Share capture/free-var summaries with closure/Perceus only after phase-specific ownership rules are explicit in tests. |
| `compiler/lib/core_tensor_fusion.ml` | Single-constructor `fused_update` is either future-proofing or removable ceremony. | Good narrow pass. If more tensor fusion forms arrive, make the plan type explicit before adding pattern heuristics. |
| `compiler/lib/core_tuple_sroa.ml` | Local `all_some` / same-length mapping helpers duplicate common patterns. | Tuple-return summaries and ctree scalar replacement could be split into analysis and rewrite modules. |
| `compiler/lib/core_specialize.ml` | No small dead code found in this scan, but the file is very broad. | Split by domain: numeric casts, tensors, strings/debug, collection option/result layout, parallel/stream folds. Large pattern matches are the main maintainability risk. |
| `compiler/lib/core_perceus.ml` | Header says reuse is not handled yet; many "legacy" fallback comments need current framing. | Split ownership contract inference, use summarization, alias retention, branch balancing, and drop insertion. Replace legacy occurrence-count fallbacks as branch summaries become precise. |
| `compiler/lib/core_reuse.ml` | `collection_family_of_type` and `collection_family_of_type_with_env` differ only by canonicalization; name that distinction or unify. | `analyze_drop_block_with_env`, handoff analysis, and rewrite scan similar linear shapes; extract a linear-block scanner that returns facts/events. |
| `compiler/lib/core_closure.ml` | Generated function source-name normalization now goes through `Codegen_names`. | Free-variable collection and function-reference adaptation are shared concepts with Perceus and emit; make capture data explicit if more closure forms are added. |
| `compiler/lib/core_codegen_prepare.ml` | `phase = Final` hides that this pass runs before the `Final` snapshot. | Split final representation prep by concern: constructors, box/unbox, record erased fields, tensor provenance, and guard simplification. |
| `compiler/lib/backend.ml` | The "Known leak" registry section is useful but should reference current neutral layout modules. | Backend interface is intentionally thin. If a second backend appears, make registry/layout metadata target-neutral before adding backend-specific escape hatches. |
| `compiler/lib/core_emit_c.ml` | No obvious small cleanup. | Thin wrapper; keep as-is. |
| `compiler/lib/core_emit_context.ml` | Legacy migration wording around `gen_literal` is stale. | Context owns several fallback maps for unresolved legacy shapes; as earlier passes become stricter, remove fallback state one piece at a time. |
| `compiler/lib/core_emit.ml` | Large amount of dated phase commentary; one file still owns many unrelated emission concerns. Existing dirty worktree changes are present, so this audit did not edit it. | Continue splitting emission by domain. Pattern emission and intrinsic emission already moved out; tailrec list emission, tensor emission, record/union construction, and profiling wrappers are candidates. |

## Cross-Cutting Opportunities

1. Centralize module-local type-name collection.
   Done in `Ast.module_local_type_names_from_decls`.

2. Centralize generated function source-name normalization.
   Done in `Codegen_names.source_name_for_generated_function`.

3. Make compound stages more observable.
   `Fusion` currently hides four full-program traversals. Profiles should show
   string fusion, collection fusion, tensor fusion, and tuple SROA separately
   before compile-time optimization work starts.

4. Prefer explicit scoped rewrite utilities over name heuristics.
   `nested_hoist.ml` still documents a shadowing limitation in `rewrite_ident`.
   Other passes have their own scoped rewrite logic. A reusable scoped rewrite
   helper would better match the language principle of making distinctions
   explicit in data/control flow.

5. Keep layout ownership in one vocabulary.
   `docs/ARCHITECTURE.md` now points at `core_layout_type.ml` plus
   `core_type_layout.ml`; keep future docs and comments on that vocabulary.

6. Treat `Core_emit.ml` changes as high-risk even when local.
   It remains the largest pipeline file and still handles many independent C
   emission domains. Small changes here should keep generated-C audit coverage
   close to the touched path.

## Small Isolated Fixes

These were small, isolated, and low-risk:

1. Removed or justified the unused top-level helpers listed above.
2. Fixed stale docs in `docs/ARCHITECTURE.md`, `core_pipeline.ml`,
   `core_trait_resolve.ml`, `core_perceus.ml`, `core_desugar.ml`, and
   `core_emit_context.ml`.
3. Extracted the duplicated module-local type-name collector.
4. Fixed the quadratic FFI metadata accumulator in
   `Core_pipeline.compile_typed_with_modules`.
5. Added a tiny source-name normalization helper and migrated
   `core_resolve.ml`, `core_std_inline.ml`, `core_closure.ml`, and
   `core_synth.ml` to it.
