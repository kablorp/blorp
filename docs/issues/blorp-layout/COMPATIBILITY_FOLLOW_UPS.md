# Blorp Layout Compatibility and Follow-up Ledger

This ledger records temporary compatibility code and architectural follow-ups
introduced or exposed by the CLI layout migration. An item is removed only in
the issue that removes the corresponding compatibility behavior.

## Open Compatibility Items

### Transitional two-stage bootstrap

- **Location:** `Makefile`, public CLI build recipe.
- **Why it exists:** the pinned bootstrap compiler recognizes the historical
  LSP stdio result types under `compiler_src_...` and
  `compiler_blorp_src_...`, but not their canonical relocated
  `blorp_src_compiler_...` identity.
- **Current behavior:** a clean build first compiles a transition compiler
  through the already-supported `compiler/blorp/src` logical identity. That
  transition compiler then compiles the canonical `blorp/src/main.brp` root.
  Incremental builds remain hash-cached.
- **Removal condition:** publish and pin a bootstrap compiler whose operation
  metadata accepts `blorp_src_compiler_...`, then delete the transition source,
  transition executable, logical-layout rewrite, and first compilation/link.

### Historical LSP stdio type identities

- **Location:**
  `blorp/src/compiler/stage_09_core/operation_metadata.brp`.
- **Why it exists:** bootstrap and development compilers may encounter stdio
  result/error types produced under the old source roots during the migration.
- **Current behavior:** accepted type-name lists include historical
  `compiler_src_...`, transition `compiler_blorp_src_...`, and canonical
  `blorp_src_compiler_...` spellings.
- **Removal condition:** after the new bootstrap is pinned and old generated
  artifacts are no longer supported, remove the historical and transition
  spellings, leaving canonical and intentionally prefix-free identities.

### Legacy command owners inside the compiler tree

- **Location:** `blorp/source_ownership.json`, `legacy_owner_paths` and
  `legacy_owner_importers`.
- **Why it exists:** formatter, CLI, and LSP modules moved with the compiler so
  the bootstrap transition remained coherent.
- **Current behavior:** an exact allowlist preserves only the pre-existing
  imports into each legacy subtree. The layout gate rejects new inbound
  dependencies even though the temporary paths remain physically nested under
  the compiler owner.
- **Removal condition:** Issues 4-10 extract these owners. Issue 11 must reject
  any remaining `stage_11_format`, `stage_12_cli`, or `stage_12_lsp` module
  beneath `blorp/src/compiler/`.

### Formatter implementation imported from `tools/formatter`

- **Location:** `blorp/source_ownership.json`, `legacy_source_roots`.
- **Why it exists:** the temporarily compiler-hosted formatter still imports
  the existing formatter document model and renderer.
- **Removal condition:** the format extraction issue establishes one owned
  format implementation path and removes this escape from the compiler owner.

## Open Structural Follow-ups

- Move or classify the remaining top-level `compiler/lib`, `compiler/tools`,
  `compiler/benchmarks`, and `compiler/testdata` assets before deleting the
  top-level `compiler/` directory.
- Remove legacy path-name variants from generated-symbol expectations after
  the bootstrap transition is complete.
- Re-measure clean-build latency after removing the two-stage bootstrap; that
  transition deliberately adds one compiler compilation to a cold build.
