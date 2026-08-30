# Blorp Layout Compatibility and Follow-up Ledger

This ledger records temporary compatibility code and architectural follow-ups
introduced or exposed by the CLI layout migration. An item is removed only in
the issue that removes the corresponding compatibility behavior.

## Open Compatibility Items

### Transitional two-stage bootstrap

- **Location:** `Makefile`, public CLI build recipe.
- **Why it exists:** the pinned bootstrap compiler can typecheck the canonical
  graph, but predates emission support for the compiler-private native LSP
  stdio builtins.
- **Current behavior:** a clean build first compiles a transition compiler
  through the already-supported `compiler/blorp` logical identity. The ignored
  layout maps the canonical `compiler`, `compile`, `check`, and `run` owners and
  mirrors `lib` plus `format` with only their historical compiler import paths
  rewritten. The transition compiler then
  compiles the canonical `blorp/src/main.brp` root. Incremental builds remain
  hash-cached.
- **Removal condition:** publish and pin a bootstrap compiler that emits the
  compiler-private native LSP stdio builtins, then delete the transition source,
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

### Transitional composite CLI request model

- **Location:** `blorp/src/lib/cli_args.brp` and `blorp/src/lib/cli_plan.brp`.
- **Why it exists:** the composition root parses the complete command surface,
  while extracted command owners consume the same exact request identities.
- **Current behavior:** argument and plan records are shared by multiple command
  owners and the root router; no compiler implementation module imports them for
  command dispatch.
- **Removal condition:** split command-specific parsing and planning into command
  owners, leaving in `lib` only request data with multiple independent command
  consumers.

### Formatter boundary consumed by the legacy router

- **Location:** `blorp/source_ownership.json`, `temporary_cross_owner_imports`.
- **Why it exists:** the formatter still consumes the compiler parser's recovery
  AST during the frontend-boundary migration.
- **Current behavior:** the gate permits only the recorded format-to-parser
  source edges; routing is owned by `main.brp`.
- **Removal condition:** replace the parser edges with the shared frontend source
  boundary used by the final format, purify, and LSP owners.

### Purify typed-frontend migration edge

- **Location:** `blorp/source_ownership.json`, `temporary_cross_owner_imports`
  and the exact legacy `source_graph` importer list.
- **Why it exists:** purify now owns its command and rewrite policy, but its
  typed candidate analysis still consumes raw compiler facts while the shared
  frontend gateway is being completed.
- **Current behavior:** only the recorded purify-to-frontend modules are
  reachable across the owner boundary; the bootstrap transition rewrites those
  canonical imports for the pinned compiler.
- **Removal condition:** expose the required typed candidate facts through the
  shared frontend boundary and delete these exact permissions.

### LSP frontend-analysis migration edges

- **Location:** `blorp/source_ownership.json`, `temporary_cross_owner_imports`
  entries rooted at `lsp/`.
- **Why they exist:** the LSP source and tests now have their final physical
  owner, but the pre-existing analysis and workspace models still retain raw
  parser, module-graph, and typechecker products.
- **Current behavior:** the layout gate allows only the exact compiler imports
  present before the physical extraction. No Core or backend work is added.
- **Removal condition:** introduce the compiler-neutral request/result contract
  described by Issue 10, inject its compiler implementation at `main.brp`,
  project diagnostics and semantic facts at that boundary, and delete every
  `lsp` cross-owner permission before marking Issue 10 implemented.

### Focused ownership manifest compatibility name

- **Location:** `blorp/test/compiler/compiler_test_ownership.json` and
  `scripts/compiler-check`.
- **Why it exists:** the checked-in manifest and command name predate command
  extraction, but their inventory now intentionally covers all `blorp/src`
  production modules and executable suites under `blorp/test`.
- **Removal condition:** after all mirrored command suites move, rename the
  manifest and command without changing selection semantics or CI sharding.

## Open Structural Follow-ups

- Remove legacy path-name variants from generated-symbol expectations after
  the bootstrap transition is complete.
- Re-measure clean-build latency after removing the two-stage bootstrap; that
  transition deliberately adds one compiler compilation to a cold build.
