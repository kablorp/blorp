# CLI-Inward Compiler Port Roadmap

Status: historical roadmap. It records the CLI-inward slices that led to the
current frontend graph boundary; use `BLORP_COMPILER_PORT_ROADMAP.md` as the
current production-boundary source of truth.

Last checked against code on 2026-07-01.

This roadmap covers expanding Blorp ownership from the command-line entry point
inward. The goal is not to port every command at once. The goal is to make the
compiler-facing CLI path contiguous: Blorp should own argument parsing, target
expansion, source reads, formatting decisions, root parsing, and eventually
source graph construction before handing off to the still-OCaml typechecker.

## Target Direction

Near-term target:

```text
Blorp CLI args
  -> Blorp check target expansion
  -> Blorp auto-format decisions
  -> Blorp file reads
  -> Blorp batched parse
  -> OCaml typecheck over parsed roots
```

Longer-term target:

```text
Blorp CLI args
  -> Blorp root target expansion
  -> Blorp source graph discovery
  -> Blorp source graph reads
  -> Blorp batched parse
  -> OCaml typecheck over parsed source graph
```

This is the frontend counterpart to the backend-tail migration in
`BLORP_COMPILER_PORT_ROADMAP.md`. The same rule applies: move the boundary
inward in small, authoritative slices, then delete the replaced OCaml code.

## Current State

- `compiler/blorp/src/stage_12_cli/compiler_cli_args.brp` owns pure CLI argument parsing.
- `compiler/blorp/src/stage_12_cli/compiler_cli.brp` owns top-level CLI planning, help/version
  output, formatter dispatch, single-file source reads, auto-format decisions,
  and parser-bridge parsing for simple `check`, `compile`, and `run` shapes.
- `compiler/blorp/src/stage_12_cli/compiler_cli.brp` now models CLI source work with
  `CliSourceTarget`, `CliSourceFile`, `CliParsedSourceFile`, and
  `CliCheckSourceBatch`; single parsed-source artifacts are encoded from the
  typed parsed-source record.
- `compiler/blorp/src/stage_12_cli/compiler_cli.brp` expands explicit `check` targets in Blorp.
  It validates missing paths, preserves explicit file targets, walks directory
  targets recursively, filters directory contents to `.brp` files, and sorts
  the discovered source paths deterministically.
- `compiler/blorp/src/stage_12_cli/compiler_cli.brp` now formats eligible expanded `check` root
  sources, respects `--no-format` and `BLORP_NO_FORMAT=1`, skips files under
  the repository `std/` directory, and reads those sources through typed file
  APIs before handing execution back to OCaml.
- `compiler/blorp/src/stage_12_cli/compiler_cli.brp` now parses non-empty multi-root and
  directory `check` roots with the existing `parse_sources` bridge action and
  returns a `parsed_source_batch` CLI artifact. OCaml decodes and finalizes that
  batch, then typechecks those explicit roots without rediscovering or reparsing
  them.
- `compiler/bin/blorp_ocaml_host.ml` still owns command execution, artifact
  writing, C compiler invocation, REPL/LSP runtime loops, test execution,
  package command execution, and the final execution of multi-path/directory
  checks.
- Single-root `check`, `compile`, and `run` can cross the bridge with a parsed
  source artifact. Multi-root and directory `check` now validate, expand,
  auto-format, read, and parse root sources in Blorp, then typecheck the decoded
  root ASTs through the existing OCaml typecheck path. Imported modules still
  load through OCaml-owned module discovery and parsing.
- `compile` and `run` now use the same action-aware `CliSourceFile` read and
  parse helpers as `check` for their single root. Their command-specific options
  still cross the bridge unchanged with the parsed-source artifact.
- `check`, `compile`, and `run` now discover readable local filesystem imports
  from Blorp-parsed root ASTs, read those imported sources in Blorp, batch-parse
  each discovery wave, and hand roots plus dependency modules to OCaml as an
  explicit `parsed_source_graph` artifact when imports are found.
- Source graph preloads seed the OCaml module loader's parse cache as trusted
  same-invocation source. OCaml still applies the existing import resolution,
  origin, cycle, and typecheck rules, but matching graph entries do not reread
  or reparse source text.
- `compiler/bin/blorp_ocaml_host.ml` no longer expands, reads, or parses
  explicit `check` root targets. Check execution consumes parsed root
  artifacts; an empty parsed root list is treated as an error instead of
  falling back to OCaml discovery.
- The bridge protocol already contains `parse_sources`; use that for batched
  root parsing instead of adding a parallel batch parser path.

## Non-Goals For This Roadmap

- Do not port typecheck as part of CLI work. The handoff target for this roadmap
  is parsed root/source graph data.
- Do not move `test`, `package`, REPL, or LSP execution first. They expand
  surface area but do not push the compiler frontend boundary inward as cleanly
  as `check`.
- Do not introduce a second production parser channel. Reuse the existing bridge
  envelope and parser bridge actions.
- Do not preserve stale compatibility forms. Blorp is pre-0.1; prefer the
  current coherent CLI and language behavior.

## Checkpoint 1: Model Check Source Inputs In Blorp

Goal: represent the check command's source work as typed Blorp data before
serializing any response to OCaml.

Status: implemented.

Add or refine internal records/unions in `compiler_cli.brp`:

- `CliSourceTarget`: validated root target kind, such as file or directory.
- `CliSourceFile`: path, module name, and source text.
- `CliParsedSourceFile`: path, module name, and parser artifact.
- `CliCheckSourceBatch`: original args, check options, and parsed files.

Keep JSON at the bridge boundary. The planning code should work with Blorp data
first, then encode once.

Validation:

- Blorp CLI tests cover the new data constructors and JSON encoding.
- Existing `run_cli` tests still pass.

## Checkpoint 2: Move Check Target Expansion Into Blorp

Goal: `blorp check` root files and directories are discovered in Blorp.

Status: implemented.

Implementation:

- For every `CliCheckArgs.paths` item:
  - report missing paths with the current user-facing diagnostic shape;
  - preserve explicit file targets as given, matching existing parser-diagnostic
    behavior for non-`.brp` files;
  - recursively walk directory targets;
  - collect only `.brp` files from directories;
  - sort deterministically;
  - preserve the current behavior for empty inputs and empty directories.
- Do not expand imports yet. This checkpoint handles explicit root targets only.
- Keep path handling explicit and testable. Avoid inferring behavior from string
  prefixes except for file extension checks and absolute/relative path handling.

Tests:

- single file target;
- directory target;
- nested directory target with stable ordering;
- mixed file and directory targets;
- missing target;
- empty directory;
- non-`.brp` files in a directory.

Validation:

- `./blorp test compiler/blorp/tests/test_compiler_cli.brp`
- `scripts/test cli`

## Checkpoint 3: Move Check File Reads And Auto-Format Into Blorp

Goal: every explicit `check` root source file is formatted when appropriate and
read by Blorp before OCaml sees the command.

Status: implemented.

Implementation:

- Use typed std file APIs for reads.
- Apply existing auto-format behavior before reading.
- Respect `--no-format` and `BLORP_NO_FORMAT`.
- Preserve std-directory skip behavior.
- Return structured read/format errors through the CLI artifact.

Tests:

- `check` on user files auto-formats when enabled;
- `check --no-format` does not modify files;
- `BLORP_NO_FORMAT=1` does not modify files;
- std files are not auto-formatted;
- read failure is reported as a clean CLI error.

Validation:

- `scripts/test cli`
- targeted temp-directory check smoke.

## Checkpoint 4: Add Parsed Source Batch Artifacts For Check

Goal: `check` can return multiple parsed roots from Blorp to OCaml.

Status: implemented.

Implementation:

- Add a CLI run plan variant for parsed check batches, for example
  `CliRunParsedSourceBatch`.
- Encode a bridge artifact like:

```json
{
  "kind": "parsed_source_batch",
  "command": "check",
  "args": ["check", "src"],
  "options": {},
  "sources": [
    {
      "path": "src/main.brp",
      "module": "main",
      "parsed_source": {}
    }
  ]
}
```

- Use existing `parse_sources` protocol support for multiple files.
- Preserve source order from target expansion.
- Report per-file parse diagnostics without dropping path/module identity.

OCaml bridge changes:

- Decode `parsed_source_batch`.
- Validate that the artifact command is `check`.
- Validate raw args/options enough to reject malformed bridge responses.
- Finalize every parsed source artifact through the same AST finalization path
  used by the current single parsed-source route.

Tests:

- response decoding accepts well-formed batches;
- response decoding rejects wrong command/kind;
- parser diagnostics identify the failing source;
- ordering is stable.

Validation:

- `scripts/test compiler-unit`
- `scripts/test cli`

## Checkpoint 5: Route Check Execution Through Parsed Root Batches

Goal: OCaml typechecks Blorp-parsed root files without rediscovering or
reparsing those root files.

Status: implemented.

Implementation:

- Extend the current check frontier shape so it can carry multiple
  parsed roots.
- Typecheck each parsed root using the existing OCaml typecheck/module-loading
  machinery.
- Keep OCaml-owned import loading for now.
- Ensure root files from a check batch are not reparsed in OCaml.
- Preserve output order and exit-code behavior.

Important boundary:

- It is acceptable for imported modules to still parse through OCaml-owned module
  loading temporarily.
- It is not acceptable for explicit check root files to be reparsed after this
  checkpoint.

Tests:

- `blorp check file.brp`;
- `blorp check dir/`;
- `blorp check file1.brp file2.brp`;
- directory with one invalid source;
- directory with imports;
- `--dump-ast` and `--dump-typed-ast` behavior for explicit roots.

Validation:

- `scripts/test cli`
- `scripts/test compiler`
- `git diff --check`

## Checkpoint 6: Delete Replaced OCaml Check Root Plumbing

Goal: remove the OCaml code paths that only exist to expand, read, or parse
explicit `check` root targets.

Status: implemented.

Implementation:

- Empty-directory check targets are now reported by the Blorp check planner as
  `Error: no .brp files found`.
- OCaml check execution no longer expands check paths or reparses roots. It only
  typechecks the parsed root list supplied by the Blorp frontier.
- The generic `.brp` directory collector remains in OCaml for purify until that
  command moves inward.

Deleted/reviewed targets:

- empty-root fallback branches in the Blorp CLI planner that sent `check` back
  as frontend options;
- OCaml root-target parse helpers that were only used for check roots;
- OCaml tests were reviewed; no test-only check root parser path remained after
  the frontier changed.

Keep:

- OCaml module-loading parse paths until source graph loading moves to Blorp.
- OCaml typecheck and diagnostics paths until the typechecker ports.
- OCaml command execution and artifact writing until later CLI-shell work.

Validation:

- `rg` confirms no deleted path is referenced.
- `scripts/test compiler-unit compiler cli`
- `git diff --check`

## Checkpoint 7: Reuse The Same Source Input Model For Compile And Run

Goal: make `compile` and `run` use the same Blorp source read/parse model as
`check`, while preserving their single-root nature.

Status: implemented.

Implementation:

- Keep `compile` and `run` as single-root commands.
- Use the same `CliSourceFile` and parsed-source helpers as `check`.
- Preserve command-specific options:
  - `--ast`;
  - `--dump-ast`;
  - `--dump-typed-ast`;
  - `--dump-core-after`;
  - `--dump-core-file`;
  - `--stop-after`;
  - runtime args for `run`;
  - sanitizer, leak-check, timeout, thread, profile, debug, and release flags.
- Avoid creating compile/run-specific file readers unless behavior truly differs.
- The bridge rejects legacy `frontend_options` artifacts; normal `check`,
  `compile`, and `run` command shapes must use `frontend_module_graph`.

Tests:

- compile single file uses parsed source artifact;
- run single file uses parsed source artifact;
- invalid compile/run source reports parse diagnostics from Blorp;
- source is not reparsed as an explicit root in OCaml.

Validation:

- `scripts/test cli`
- representative `./blorp compile --no-format ...`
- representative `./blorp run --no-format ...`

## Checkpoint 8: Move Source Graph Loading Into Blorp

Goal: make Blorp own explicit roots plus imported source discovery and reads.

Status: implemented for readable filesystem imports: local project modules,
explicit filesystem std overrides, source-package aliases from `blorp.toml`,
source-package internal imports, and local `pkg/...` package roots.

Implemented:

- Blorp extracts import module paths from parsed AST JSON instead of rescanning
  source text.
- Blorp resolves readable `./...`, `../...`, and bare local imports relative to
  the importing source file.
- Blorp resolves filesystem std imports only when `--std-dir` or `BLORP_STD`
  supplies an explicit std source directory. Embedded std remains compiler-owned
  OCaml data, not a filesystem source graph.
- Blorp reads root `blorp.toml` package entries, resolves local path aliases and
  already-fetched hash-cache aliases, reads package manifests, and discovers
  exported source-package modules without fetching from the network.
- Blorp keeps package-internal source discovery inside the current package
  source directory and resolves root-project package aliases only from
  non-package source files. The OCaml module loader still performs the
  authoritative package validation, origin checks, hash verification, and
  diagnostics before typechecking.
- Blorp resolves local `pkg/...` imports from discovered package roots for
  root-project code, while leaving the existing std/source-package restrictions
  enforced by OCaml.
- Blorp batches parsing by source-graph discovery wave using the existing
  `parse_sources` bridge action.
- The CLI bridge emits `parsed_source_graph` artifacts with explicit `roots` and
  `modules`.
- OCaml decodes source graphs, finalizes every parsed source through the normal
  parser-finalization path, and preloads dependency ASTs into the session parse
  cache.
- Trusted graph preloads still pass through OCaml import resolution before
  reuse, preserving origin checks and avoiding a second independent module
  policy.

Target handoff:

```text
Blorp source graph with parsed modules
  -> OCaml typecheck
```

Validation:

- `make`
- `./blorp format --check compiler/blorp/src/stage_12_cli/compiler_cli.brp compiler/blorp/tests/test_compiler_cli.brp`
- `./blorp test --no-format compiler/blorp/tests/test_compiler_cli.brp`
- `dune exec -- ./test/run_tests.exe test CompilerBlorpBridge`
- `dune exec -- ./test/run_tests.exe test Session.modules_isolation`
- temp-directory `blorp check --no-format` and `blorp compile --no-format`
  smoke with a root importing a sibling module.

## Testing Strategy

Each checkpoint should include at least one direct Blorp unit test and one CLI
or bridge-level integration test. Prefer small tests that prove the boundary
moved, not only end-to-end success.

Useful commands:

```bash
make
./blorp test compiler/blorp/tests/test_compiler_cli.brp
scripts/test cli
scripts/test compiler
scripts/test compiler-unit
git diff --check
```

Before deleting OCaml code:

```bash
rg "name_of_deleted_helper|deleted_path" compiler tests docs
scripts/test compiler-unit compiler cli
```

## Merge Standard

For every slice:

1. Add tests first, or identify the existing tests that fail without the change.
2. Route only one command shape at a time.
3. Keep data typed inside Blorp and JSON only at the bridge boundary.
4. Validate bridge responses defensively on the OCaml side.
5. Delete replaced OCaml code in the same branch once the Blorp path is
   authoritative.
6. Update this roadmap if the actual boundary differs from the plan.
