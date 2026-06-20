# Blorp Compiler Port Roadmap

Status: active migration roadmap, created 2026-06-19.

This roadmap describes how to move the compiler implementation from OCaml to
Blorp while keeping the compiler usable at every merge point. The goal is not a
parallel compiler. Each migrated slice should become the production path, delete
the parallel OCaml source for that slice, and move the single JSON transfer
point earlier in the pipeline.

Use [ARCHITECTURE.md](ARCHITECTURE.md) for the live compiler pipeline and
[COMPILER_ROADMAP.md](COMPILER_ROADMAP.md) for broader semantic compiler work.
This file is specifically about the OCaml-to-Blorp port.

## Current State

The production compiler is still structurally OCaml-owned:

```text
source
  -> OCaml lexer/parser
  -> OCaml module loading
  -> OCaml inference/typecheck
  -> OCaml Typed AST
  -> OCaml Core lowering
  -> OCaml Core-to-Core pipeline
  -> OCaml C backend, with some Blorp-owned renderers
  -> generated C
```

The active handoff is centralized in `compiler/lib/compiler_blorp_bridge.ml`.
That is the correct architectural direction, but it is still transitional:

- `compiler/blorp` owns several renderer and policy modules.
- OCaml still owns Core traversal, Core stage semantics, type/layout decisions,
  source parsing, module loading, inference, typecheck, diagnostics, and the
  CLI/test/LSP orchestration.
- `blorp __compiler-bridge` accepts JSON for Blorp-owned renderer actions. Stage
  actions such as `compile_source` are reserved in the Blorp protocol but remain
  unsupported until Blorp owns those stages.
- Renderer requests use the Blorp bridge command. Checked-in TSV manifests are
  no longer the production rendering path, but they still remain as temporary
  migration debt for helper bootstrap. Renderer metadata lookups now go through
  the Blorp bridge in production. This debt lives in
  `compiler/lib/compiler_blorp_bridge.ml` and should be deleted before Merge
  Point 1 is considered closed.
- The compiled renderer bridge helper is content-addressed by production
  `compiler/blorp` source, the compiler binary, the C compiler identity, and
  the OS.
- `emit_c` exists as a bridge action, but it currently validates and echoes
  `CArtifact` JSON. It does not yet accept final Core JSON or own C emission.

Approximate current source shape, measured from this worktree on 2026-06-20:

| Area | Ownership today | Approximate size |
| --- | --- | ---: |
| Core IR, Core passes, C emission | Mostly OCaml | 61.9k OCaml lines |
| Parser, modules, inference, typecheck | OCaml | 28.4k OCaml lines |
| CLI | OCaml | 1.7k OCaml lines |
| LSP | OCaml | 6.0k OCaml lines |
| Formatter facade/projection | OCaml facade, Blorp renderer | 2.6k OCaml lines |
| Compiler Blorp production code | Blorp | 12.4k Blorp lines |
| Compiler Blorp tests | Blorp | 6.8k Blorp lines |

Current branch migration accounting against `main`, including the active
worktree, is roughly:

| Area | Added | Deleted | Net |
| --- | ---: | ---: | ---: |
| `compiler/blorp/**/*.brp` | 4.6k | 1.1k | +3.6k Blorp lines |
| `compiler/lib/**/*.ml` | 1.5k | 1.6k | -0.1k OCaml lines |

That ratio is acceptable only as temporary bridge scaffolding. The next merge
checkpoint should reduce OCaml ownership more aggressively than it expands
snippet-level Blorp renderer code.

## Non-Negotiable Invariants

### One JSON Transfer Point

There must be one interface between OCaml and Blorp compiler code:

```text
OCaml caller
  -> compiler_blorp_bridge JSON request
  -> Blorp compiler implementation
  -> compiler_blorp_bridge JSON response
  -> OCaml caller
```

Do not add side channels for compiler stages. No extra manifest-specific
interfaces, ad hoc subprocess protocols, direct generated-template access, or
parallel tools that production compilation does not use. The current
`compiler_blorp_bridge.ml` manifest fallback is an explicit temporary exception
for helper bootstrap; do not add new callers to that path.

As Blorp moves earlier in the pipeline, the transfer point moves earlier too:

```text
final Core JSON -> C
pre-final Core JSON -> C
post-lower Core JSON -> C
typed AST JSON -> C
parsed AST JSON -> C
source JSON -> C
```

### Pure Stage Logic

The vast majority of the compiler pipeline should be pure functions.

Impure code is allowed at the perimeter:

- reading source files and package files;
- writing C, binaries, logs, caches, and diagnostics;
- spawning the Blorp bridge command while OCaml still exists;
- invoking the C compiler;
- loading environment variables and platform configuration.

Stage logic should be pure over explicit inputs:

```blorp
pure func parse_source(input: ParseInput) -> Result[ParsedProgram, DiagnosticSet]
pure func typecheck_program(input: TypecheckInput) -> Result[TypedProgram, DiagnosticSet]
pure func lower_to_core(input: LowerInput) -> Result[CoreProgram, DiagnosticSet]
pure func run_core_stage(input: CoreStageInput) -> Result[CoreProgram, DiagnosticSet]
pure func emit_c(input: EmitInput) -> Result[CArtifact, DiagnosticSet]
```

The impure shell should only assemble inputs, call pure stages, and materialize
outputs:

```blorp
func compile_command(args: List[String]) -> Int
func run_command(args: List[String]) -> Int
func test_command(args: List[String]) -> Int
```

If a stage appears to need I/O, the default answer should be to move that I/O
into an explicit input snapshot. For example, module loading should eventually
consume a `SourceGraph` built by the impure perimeter, then resolve imports as a
pure function over that graph.

### Delete Parallel OCaml

Shadow implementations are temporary scaffolding. They may exist inside a merge
while parity is being established, but the merge point is not complete until the
OCaml source for the migrated slice is deleted or reduced to a narrow bridge
shim.

### Explicit Data, Not Heuristics

Compiler correctness must flow through typed data:

- source syntax in parsed AST;
- semantic facts in typed AST;
- representation and ownership facts in Core;
- backend choices in prepared Core or explicit emit metadata;
- diagnostics as structured data.

Do not recover semantics from names, suffixes, source formatting, C strings, or
"usually true" shape checks when the data model can carry the fact.

### Tests Before Migration

Every slice needs a failing test before implementation. Migration tests should
prove both behavior and deletion safety:

- JSON schema round trips;
- drift tests against current OCaml output before deletion;
- compiler behavior fixtures;
- generated C audits for backend changes;
- runtime/leak tests for ownership changes;
- benchmark baselines for compiler-shaped workloads when performance risk is
  plausible.

## Target Architecture

The end state is a Blorp compiler with a small impure perimeter and pure
compilation stages:

```text
impure CLI / tools
  -> build CompilationInput
  -> pure parse
  -> pure module graph resolution over SourceGraph
  -> pure inference/typecheck
  -> pure CTFE
  -> pure Core lowering
  -> pure Core pipeline
  -> pure C artifact emission
  -> impure artifact writing / C compiler invocation
```

The same Blorp compiler library should serve:

- `blorp check`;
- `blorp compile`;
- `blorp run`;
- `blorp test`;
- formatter projection and rendering;
- LSP queries;
- purify and future refactoring tools.

The CLI may stay impure. The compiler library should mostly be pure.

## JSON Bridge Contract

While OCaml remains, all cross-language requests should use one envelope:

```json
{
  "schema": 1,
  "domain": "compiler",
  "action": "emit_c",
  "payload": {}
}
```

Responses should be explicit:

```json
{
  "schema": 1,
  "ok": true,
  "artifact": {}
}
```

```json
{
  "schema": 1,
  "ok": false,
  "error": {
    "code": "typecheck_failed",
    "message": "...",
    "diagnostics": []
  }
}
```

Bridge actions should evolve toward phase ownership:

| Action | Input | Output | Owner after migration |
| --- | --- | --- | --- |
| `render` / `render_many` | Renderer op | Text | Temporary, deleted after full emit |
| `emit_c` | Final Core JSON | C artifact JSON | Blorp |
| `prepare_and_emit_c` | Pre-final Core JSON | C artifact JSON | Blorp |
| `run_core_pipeline` | Lowered Core JSON | Final Core or C artifact JSON | Blorp |
| `lower_and_compile` | Typed AST JSON | C artifact JSON | Blorp |
| `typecheck_and_compile` | Parsed source graph JSON | C artifact JSON | Blorp |
| `compile_source` | Source graph or single source JSON | C artifact JSON | Blorp |

The bridge should reject unknown schema versions, unknown actions, unknown
fields where strictness matters, and phase-inappropriate inputs.

## Merge Points

### Merge Point 0: Contract And Inventory Lock

Goal: make the migration boundary auditable before moving more code.

Implementation:

- Document the canonical compiler JSON envelope.
- Add bridge hygiene tests proving direct template/manifest access is limited
  to the bridge while manifests still exist.
- Add inventory tests listing OCaml files that are still expected to exist.
- Classify compiler code into migration groups: bridge, backend, final Core,
  ownership, middle Core, lowering, CTFE, type system, parser, tools.
- Add a "no new OCaml stage without roadmap update" check for compiler code.

Deletion:

- Remove stale bridge names and obsolete wrapper modules.
- Remove any unused OCaml formatting/check gates that no longer protect live
  compiler code.

Purity requirement:

- New bridge dispatch code should only parse JSON and call pure handlers, except
  for the explicit command-spawn/file-read perimeter.

Done when:

- `compiler_blorp_bridge` is the only cross-language compiler entry.
- The repo has a machine-checkable inventory of remaining OCaml slices.

Current guard:

- `compiler/blorp/ocaml_port_inventory.tsv` classifies every tracked production
  OCaml compiler source into a migration group.
- `scripts/check-compiler-port-inventory` verifies that inventory, checks the
  hidden bridge command boundary, and makes temporary direct-template access
  exceptions explicit.
- `make hygiene-check` runs the guard so premerge validation catches unplanned
  OCaml compiler additions.

### Merge Point 1: Blorp-Owned Bridge Command

Goal: stop serving Blorp compiler code through OCaml-generated manifests.

Implementation:

- Add `compiler/blorp/compiler_bridge.brp`. **Done.**
- Implement JSON request decoding and response encoding in Blorp using
  `std/json.brp`.
- Move renderer dispatch from OCaml to Blorp bridge code. **Done.**
- Keep OCaml `compiler_blorp_bridge.ml` only as subprocess client and response
  decoder.
- Replace production TSV-manifest calls with Blorp bridge actions. **Done.**
- Cache the compiled renderer bridge helper behind a content-derived key so
  compiler/test workers do not repeatedly compile the same Blorp helper.

Remaining debt before this merge point is closed:

- Delete the helper bootstrap dependency on checked-in TSV manifests. Production
  renderer metadata/arity lookup now comes from the `renderer_templates` Blorp
  bridge action.
- Reduce `compiler_blorp_bridge.ml` to bridge request/response handling plus
  helper-cache process management. Hard-coded bootstrap rows and direct
  `Core_emit_blorp_template.render_exn` fallback should disappear with the TSV
  bootstrap path.
- Keep `core_emit_blorp_template.ml` only while the helper bootstrap path needs
  it.

Deletion:

- Delete `*_templates.ml` files once the bridge no longer needs checked-in TSV
  manifests. **Partially done; renderer wrapper modules are gone.**
- Delete most of `core_emit_blorp_template.ml`.
- Delete OCaml tests that only validate TSV substitution after equivalent Blorp
  tests exist.

Purity requirement:

- Renderer dispatch in Blorp should be pure:
  `pure func handle_request_value(value: JsonValue) -> BridgeResponse`.
- The only impure piece should be command I/O around stdin/stdout.

Validation:

- Existing `compiler/blorp/tests` pass.
- OCaml bridge command tests pass.
- Drift tests prove rendered output is byte-identical before OCaml manifest
  deletion.

### Merge Point 2: Shared JSON Data Model

Goal: make real compiler stages transferable, not just string-template
operations.

Implementation:

- Add Blorp data modules for:
  - source locations;
  - diagnostics;
  - type expressions;
  - typed AST subset needed by Core lowering;
  - Core IR;
  - C artifact metadata. The Blorp `CArtifact` JSON codec exists in
    `compiler/blorp/compiler_artifact_json.brp`, and the `emit_c` bridge action
    now validates and returns that artifact shape. The next step is to feed it
    final Core JSON instead of a minimal artifact payload.
- Add JSON codecs in Blorp for these types.
- Add OCaml JSON projection only at the active transfer point.
- Add round-trip tests for representative and edge-case values.
- Add golden JSON fixtures for final Core programs used by emission tests.

Deletion:

- Delete ad hoc string-list argument encodings where structured JSON exists.
- Delete OCaml bridge helpers that parse colon/semicolon mini-formats for new
  structured payloads.

Purity requirement:

- Codecs should be pure.
- Schema validation should be pure and return typed diagnostics instead of
  raising where possible.

Validation:

- JSON round trips preserve all facts needed by the receiving stage.
- Unknown tags produce structured bridge errors.
- Fixture diffs are stable and readable.

### Merge Point 3: Complete C Emission In Blorp

Goal: make `emit_c(final_core_json)` the production backend.

Implementation:

- Port `Core_emit_context` concepts to Blorp as an immutable or locally mutable
  builder owned inside a pure emit function.
- Port C escaping, name mangling use, runtime declaration selection, static
  constants, intrinsic emission, prepared list/tensor/tuple/constructor/backend
  emission, closure emission, pattern emission, and profiling hooks.
- Replace snippet-level bridge calls with one final-Core-to-C bridge request.
- Keep C artifact output structured: C text, link flags, include dirs, runtime
  feature metadata.

Deletion:

- Delete `core_emit.ml`.
- Delete `core_emit_c.ml`.
- Delete `core_emit_intrinsic.ml`.
- Delete `core_emit_context.ml`.
- Delete `core_emit_pattern.ml` if fully absorbed.
- Delete `core_emit_blorp_backend.ml` and
  `core_emit_blorp_prepared_backend.ml` once their logic is in Blorp.

Purity requirement:

- `emit_c` should be pure from final Core plus configuration to `CArtifact`.
- Temporary name allocation should be explicit state threaded through the pure
  emitter or local mutation scoped inside the pure function.

Validation:

- Generated C is byte-identical where practical.
- Where output changes, codegen audit proves semantic equivalence and the
  generated C is inspected.
- `scripts/test compiler` and `scripts/test runtime` pass.
- `BENCH_RUNS=5 bash benchmarks/bench.sh compiler_emit` is recorded before and
  after.

### Merge Point 4: Final Core Preparation In Blorp

Goal: move the transfer point from final Core to pre-final Core.

Implementation:

- Port `core_codegen_prepare`.
- Port erased-storage, option/result, hash-container, list/tensor layout, and
  representation classification needed only for final Core.
- Move final invariant checks that protect emission into Blorp.
- Make prepared Core JSON the input to `prepare_and_emit_c`.

Deletion:

- Delete `core_codegen_prepare.ml`.
- Delete emit-only layout helpers that no longer have OCaml callers.
- Delete final-invariant OCaml checks that are now enforced in Blorp.

Purity requirement:

- Preparation should be pure:
  `pure func prepare_core(input: PrepareInput) -> Result[CoreProgram, DiagnosticSet]`.

Validation:

- Final Core dumps match before/after for targeted fixtures.
- Invariant failure messages remain structured and useful.

### Merge Point 5: Ownership Tail In Blorp

Goal: port the ownership-sensitive late pipeline.

Stages:

- `core_consume_specialize`;
- `core_perceus`;
- `core_reuse`;
- `core_closure`;
- `core_resource`;
- `core_fairness`.

Implementation:

- Port Core traversal helpers needed by these stages.
- Port Perceus last-use/drop insertion with explicit ownership facts.
- Port reuse analysis without relying on names or emitted C shape.
- Expand the existing Blorp fairness policy into full fairness traversal.
- Add stage-by-stage JSON dumps for parity.

Deletion:

- Delete the corresponding OCaml stage files after production uses the Blorp
  stage.
- Delete OCaml-only Perceus/reuse helper checks once equivalent Blorp tests
  exist.

Purity requirement:

- These stages must be pure Core-to-Core transforms.
- Fresh IDs and temporary names must come from explicit counters in stage input
  and output, not process-global mutable state.

Validation:

- Runtime and leak tests pass.
- Perceus checker coverage is preserved or ported.
- Codegen audit covers early return, branches, matches, closures, resources,
  task captures, list reuse, and static/global interactions.

### Merge Point 6: Middle Core Pipeline In Blorp

Goal: move the transfer point to lowered Core.

Stages:

- debug block erasure/retention;
- Core desugar and SSA;
- monomorphization;
- synthesized builtin bodies;
- match decision-tree compilation;
- trait method resolve;
- call resolve;
- std inline;
- tailrec lowering;
- string/list/collection/tensor/tuple fusion;
- specialization;
- DCE.

Implementation:

- Port `Core_stage` and pipeline orchestration to Blorp.
- Preserve observed stage names and dump semantics.
- Split aggregate `Fusion` internally so Blorp can report sub-stage timings
  without changing the public stage contract.
- Port stage invariants beside the stage they protect.
- Keep `--dump-core-after` and `--stop-after` behavior byte-compatible.

Deletion:

- Delete each OCaml stage file when its Blorp stage is authoritative.
- Delete OCaml stage-order duplication after Blorp owns orchestration.

Purity requirement:

- The whole Core pipeline should be pure:
  `pure func run_core_pipeline(input: CorePipelineInput) -> Result[CorePipelineOutput, DiagnosticSet]`.
- Profiling should be handled by an impure wrapper or by pure accumulation of
  timing labels supplied by the caller; stage transforms should not read clocks.

Validation:

- Golden stage dumps for lower, desugar, mono, match, resolve, specialize,
  Perceus, closure, and final.
- Compiler fixtures and codegen audit pass.
- Compiler benchmarks `compiler_ast`, `compiler_symbols`, and `compiler_emit`
  are measured for regressions.

### Merge Point 7: Core IR And Lowering In Blorp

Goal: make typed AST JSON the active transfer point.

Implementation:

- Port Core IR data definitions to Blorp.
- Port Core builders and traversal helpers.
- Port `core_lower`.
- Port module flattening and import-table assembly required after typecheck.
- Port FFI boundary annotation and initial list layout annotation.
- Define typed AST JSON as the stable input from OCaml typecheck.

Deletion:

- Delete `core.ml`.
- Delete `core_lower.ml`.
- Delete `core_flatten.ml`.
- Delete `core_ffi_boundary.ml`.
- Delete initial Core layout helpers with no remaining OCaml callers.

Purity requirement:

- Lowering must be pure from typed AST plus session counters/import metadata to
  Core plus updated counters.

Validation:

- Lowered Core dumps match existing fixtures.
- Unsupported declarations produce structured diagnostics, not dropped Core.

### Merge Point 8: CTFE In Blorp

Goal: move compile-time evaluation before Core lowering into Blorp.

Implementation:

- Port CTFE IR, values, environments, pattern handling, intrinsic dispatch,
  std evaluation, and materialization.
- Make top-level constant evaluation a pure transform over typed AST and an
  explicit constant environment.
- Keep unsupported pure operations as compile errors for constants.

Deletion:

- Delete `ctfe*.ml`.
- Delete `top_level_initializer.ml`.

Purity requirement:

- CTFE should be pure. It may evaluate pure Blorp functions using local mutation
  inside the evaluator, but it must not read files, call process APIs, or depend
  on wall-clock/runtime state.

Validation:

- CTFE tests pass.
- Static constant codegen audit cases still prove CTFE-only helpers disappear
  from generated C.
- Deterministic failure messages are checked.

### Merge Point 9: Type System Infrastructure In Blorp

Goal: prepare for Blorp-owned inference and typecheck.

Implementation:

- Port type expressions and utilities.
- Port environments, builtins, callable identity, trait obligations, overload
  tables, type metadata, proof metadata, refinements, dimension solving, type
  widening, and type normalization.
- Keep source-level facts explicit in typed metadata.
- Add JSON codecs for parsed AST and typed AST if not already complete.

Deletion:

- Delete `types.ml`.
- Delete `env.ml`, `env_types.ml`, and `env_builtins.ml`.
- Delete `dim_solver.ml`, `refinement.ml`, `type_resolution.ml`,
  `type_widening.ml`, and metadata helpers after ports are authoritative.

Purity requirement:

- Type utilities, solver operations, trait lookup, and environment updates
  should be pure values. Local mutation inside pure functions is acceptable for
  performance, but persistent input/output values must remain explicit.

Validation:

- Existing compiler-unit type/env/dim/refinement tests are ported or replaced
  with Blorp tests.
- Hidden mutable global state is eliminated from the type infrastructure.

### Merge Point 10: Inference, Typecheck, Modules, And Purity In Blorp

Goal: make parsed AST or source graph JSON the active transfer point.

Implementation:

- Port module graph representation.
- Split impure source discovery from pure module resolution:
  - impure perimeter builds `SourceGraph`;
  - pure module stage resolves imports over `SourceGraph`.
- Port inference, typecheck, trait coherence, orphan checks, purity checks,
  tailrec validation, debug-only validation, unused-import checks, and typed AST
  validation.
- Port diagnostics with structured notes/help.
- Make `check` use Blorp typecheck through the single bridge.

Deletion:

- Delete `infer.ml`.
- Delete `typecheck.ml`.
- Delete `modules.ml` after source graph loading is moved.
- Delete `typed_ast.ml` after the Blorp typed AST is authoritative.
- Delete `purity_analysis.ml` and `unused_imports.ml`.

Purity requirement:

- Typecheck must be pure from `TypecheckInput` to either `TypedProgram` or
  `DiagnosticSet`.
- Module resolution must not read files once it has a `SourceGraph`.

Validation:

- Parser, infer, typecheck, module, purity, tailrec, and import diagnostics
  fixtures pass.
- Diagnostic text is checked where user-facing behavior matters.
- Cross-module coherence tests pass.

### Merge Point 11: Parser And AST In Blorp

Goal: make source JSON the active transfer point.

Implementation:

- Port lexer, indentation handling, tokens, parser, interpolation parsing,
  subscript desugar, AST types, comment collection, and syntax diagnostics.
- Keep removed-syntax diagnostics that improve first-time user experience.
- Make formatter and LSP use the Blorp parser data model.
- Ensure `docs/GRAMMAR.md` stays synchronized.

Deletion:

- Delete `lexer.mll`.
- Delete `parser.mly`.
- Delete `ast.ml`.
- Delete `interp_parser.ml`.
- Delete `subscript_desugar.ml`.
- Delete OCaml formatter JSON projection that only existed to adapt OCaml AST
  to Blorp formatter input.

Purity requirement:

- Parsing should be pure from `String` plus filename/config to `ParsedProgram`
  or diagnostics.
- Comment collection should be returned as data, not stored globally.

Validation:

- Parser fixtures pass.
- Formatter fixtures pass.
- LSP position and symbol tests are updated to use Blorp parser data.
- Grammar docs are updated in the same merge.

### Merge Point 12: Tooling And CLI In Blorp

Goal: remove the OCaml compiler shell.

Implementation:

- Port command parsing for `check`, `compile`, `run`, `test`, `format`,
  `purify`, `repl`, and `lsp`.
- Port test runner or replace it with a Blorp runner.
- Port LSP server using the Blorp compiler library.
- Port diagnostics rendering.
- Replace Dune/opam compiler build with the Blorp compiler bootstrap path.
- Keep native runtime C build and C compiler invocation as explicit impure
  backend tooling.

Deletion:

- Delete `compiler/bin/blorp.ml`.
- Delete OCaml LSP modules.
- Delete OCaml test runner modules.
- Delete remaining OCaml formatter facade modules.
- Delete Dune/opam OCaml compiler build files once no OCaml source remains.

Purity requirement:

- CLI, LSP transport, REPL, process management, and test execution are impure
  shells.
- They should call the pure compiler library instead of embedding compiler
  semantics.

Validation:

- `scripts/test` is rewritten to no longer depend on OCaml unit tests.
- Preview smoke passes.
- Docker gates pass.
- Bootstrap process is documented and reproducible.

## Deletion Policy

For every merge point:

1. Add parity or behavior tests while OCaml still exists.
2. Port the slice to Blorp.
3. Route production calls through the Blorp slice.
4. Delete the OCaml implementation for that slice.
5. Keep only the narrow JSON bridge shim if OCaml still needs to call later
   Blorp-owned stages.
6. Update docs and architecture diagrams.
7. Record migration accounting for the slice: Blorp lines added/deleted, OCaml
   lines added/deleted, any remaining OCaml bridge exceptions, and why those
   exceptions cannot be deleted yet.

A migrated slice is incomplete if OCaml and Blorp both remain authoritative.
Large net Blorp additions with little or no OCaml deletion are only acceptable
for explicitly named bridge scaffolding, and the next adjacent slice should pay
that scaffolding down.

## Purity Design Rules

- Prefer `pure func` for every stage transform, codec, classifier, resolver,
  and renderer.
- Use local `var` mutation inside pure functions when it keeps the code simple
  or efficient.
- Pass counters, caches, and configuration explicitly.
- Return updated state explicitly when a stage mints IDs or accumulates facts.
- Keep diagnostics as values.
- Keep benchmark/profiling observation outside the transform where possible.
- Do not read environment variables, files, clocks, process state, or global
  mutable session state from stage logic.

Acceptable impure modules:

| Module kind | Why impurity is acceptable |
| --- | --- |
| CLI command runner | Reads args/env, writes files, invokes subprocesses |
| Source graph loader | Reads files before pure module resolution |
| Artifact writer | Writes C, object files, binaries, logs |
| C compiler wrapper | Invokes external compiler |
| LSP transport | Reads/writes JSON-RPC streams |
| Test runner shell | Discovers files, spawns compiles/runs, records logs |

Everything else should justify impurity explicitly.

## Validation Matrix

| Migration area | Required validation |
| --- | --- |
| Bridge/schema | JSON round trips, unknown action/schema errors, hygiene tests |
| Emission | Codegen audit, generated C inspection, runtime tests |
| Ownership | Runtime tests, leak tests, Perceus/reuse regression tests |
| Core transforms | Stage dump parity, invariant tests, compiler fixtures |
| CTFE | CTFE compiler-unit or Blorp tests, static emission audit |
| Type system | Infer/typecheck fixtures, diagnostics text checks |
| Parser | Parser pass/fail fixtures, formatter expectations, grammar docs |
| CLI/tools | CLI smoke, test runner gates, LSP smoke |
| Performance-sensitive work | `benchmarks/bench.sh` compiler rows before/after |

Recommended benchmark baseline before large Core/frontend ports:

```bash
BENCH_RUNS=5 BENCH_WARMUPS=1 bash benchmarks/bench.sh compiler_ast compiler_symbols compiler_emit
```

Recommended local gate while OCaml remains:

```bash
make
scripts/test compiler-unit compiler cli
./blorp test compiler/blorp/tests
git diff --check
```

After the OCaml unit suite is deleted, replace `compiler-unit` with the Blorp
compiler-library test suite.

## Near-Term Queue

1. Close the remaining Merge Point 1 debt by deleting the helper bootstrap TSV
   fallback.
2. Shrink the remaining TSV bootstrap path so `core_emit_blorp_template.ml`
   contains only the temporary helper-build fallback or disappears entirely.
3. Add final Core JSON fixtures and Blorp codecs for the subset needed by C
   emission.
4. Replace snippet-level renderer calls with one `emit_c` action.
5. Delete remaining manifest/template OCaml once helper bootstrap no longer
   needs TSV manifests.
6. Complete C emission in Blorp and delete the OCaml emitter.
7. Move the transfer point backward to final Core preparation, then through the
   ownership tail.
