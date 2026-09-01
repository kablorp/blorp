# Blorp Layout Compatibility and Follow-up Ledger

This ledger records temporary compatibility code and architectural follow-ups
introduced or exposed by the CLI layout migration. An item is removed only in
the issue that removes the corresponding compatibility behavior.

## Open Compatibility Items

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
  reachable across the owner boundary. The pinned compiler now consumes those
  canonical imports directly.
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

## Resolved Compatibility Items

### Transitional bootstrap bridges

- **Resolved by:** pinning `dev-12f30feecf23`, the first fully green release
  built from the canonical package layout, and later
  `dev-75e0a6caa4cb`, which accepts bare standard-library builtin identities.
- **Result:** the public build compiles `blorp/src/main.brp` directly with the
  pinned compiler. The ignored old-layout tree, rewritten source copies,
  builtin-identity rewrite, transition C, transition executable, and extra
  native link are deleted.
- **Local evidence:** the first changed-source `make install` after cutover took
  66.89 seconds on the roadmap host; an immediate no-change build took 0.57
  seconds. After the bare-identity cutover, the pinned compiler directly emitted
  both the build-source generator and current compiler C. The build contract
  rejects any return of transition-layout fragments or more than one canonical
  compiler compilation.

### Historical LSP stdio type identities

- **Resolved by:** retiring support for Core artifacts produced from the former
  `compiler/src`, `compiler/blorp`, and compiler-owned stage-12 LSP paths after
  pinning the canonical bootstrap.
- **Result:** operation metadata accepts only the prefix-free type identity,
  the canonical `blorp/src/lsp` module identity, and its canonical generated C
  spelling. Focused projection tests reject representative historical names.
