# Blorp Compiler Port Roadmap

Status checked against code on 2026-06-26.

This roadmap is for replacing the OCaml compiler implementation with Blorp
source. The guiding strategy is direct porting first: copy the OCaml call graph,
data flow, and tests as closely as possible, prove parity, route production
through Blorp, then delete the corresponding OCaml. Larger cleanups should wait
until after the apples-to-apples port for a slice is authoritative.

## Current Verified State

The current production compile path is mixed:

```text
OCaml CLI / module loading / typecheck
  -> OCaml Core lowering and early Core setup
  -> OCaml Core pipeline through closure conversion
  -> JSON handoff
  -> Blorp resource cleanup lowering
  -> Blorp fairness checkpoint insertion
  -> Blorp final Core preparation
  -> Blorp C artifact emission
  -> OCaml artifact writing / C compiler invocation
```

`compiler/lib/core_pipeline.ml` is the source of truth for the current stage
order. After lowering and initial setup it runs:

```text
Lower
Debug
Desugar + SSA
Mono + list layout
Synth
Match
TraitResolve
Resolve
StdInline
Tailrec
Fusion
Specialize + function-ref adaptation
Dce
ConsumeSpecialize
Perceus
Reuse
Closure
```

The default backend handoff is the post-closure, pre-resource Core program.
Normal emission then calls the Blorp bridge action `emit_post_closure_c`, which
decodes Core JSON and runs the Blorp post-closure tail:

```text
compiler_core_resource.rewrite_resource_program
compiler_core_fairness.insert_cooperative_checkpoints
compiler_core_prepare.prepare_program
compiler_core_reuse.rewrite_prepared_program
compiler_core_emit.try_emit_prepared_core_program_c_artifact_with_options
```

There are still important OCaml paths around that default:

- `core_pipeline.ml` still materializes a lazy OCaml final Core program for
  final-stage dumps, invariant checks, profiling-related observability, and the
  renderer-helper bootstrap path.
- That lazy OCaml final path runs `Core_resource`, `Core_fairness`,
  `Core_codegen_prepare`, and then `Core_reuse.rewrite_prepared_program`.
  The Blorp production tail now mirrors that final-tail pass sequence.
- `BLORP_COMPILER_RENDERER_HELPER=1` still routes through the OCaml C emitter so
  the bridge helper can bootstrap.
- `compiler/lib/core_emit_blorp_c.ml` is still the OCaml Core-to-JSON projector,
  bridge client wrapper, and some validation/subset logic. It is bridge code,
  not the desired long-term compiler implementation.

The Blorp bridge currently supports these actions in
`compiler/blorp/compiler_bridge.brp`:

| Action | Current purpose | Desired long-term status |
| --- | --- | --- |
| `emit_c` | Emit already-prepared Core JSON | Keep only while callers need prepared Core |
| `emit_post_closure_c` | Current production tail handoff | Move left as more stages port |
| `run_core_pipeline` | Core JSON -> Core JSON for one tail stage | Expand into the main stage parity mechanism |
| `render` / `render_many` / `renderer_templates` | Temporary snippet/table requests | Delete from production compile path |
| `lower_and_compile` | Declared, unsupported | Implement when Core lowering ports |
| `typecheck_and_compile` | Declared, unsupported | Implement when typecheck ports |
| `compile_source` | Declared, unsupported | Implement when parser/source loading ports |

Current OCaml-to-Blorp calls outside the main backend handoff are:

| OCaml site | Why it calls Blorp today | Roadmap treatment |
| --- | --- | --- |
| `compiler/bin/blorp.ml` | Hidden `__compiler-bridge` command | Keep as the command perimeter while OCaml is the outer shell |
| `compiler/lib/core_pipeline.ml` | Default C backend handoff | Keep, but move the input boundary left over time |
| `compiler/lib/core_emit_blorp_c.ml` | Core JSON projection, bridge request, intrinsic arity checks | Shrink to the single bridge shim; delete subset logic as stages move |
| `compiler/lib/core_emit_blorp_backend.ml` | Old OCaml emitter helper using Blorp intrinsic snippets | Delete with OCaml emitter/bootstrap cleanup |
| `compiler/lib/core_emit_blorp_prepared_backend.ml` | Old OCaml emitter helper using Blorp prepared snippets | Delete with OCaml emitter/bootstrap cleanup |
| `compiler/lib/core_fairness.ml` | OCaml final-tail observability path reads Blorp policy rows | Delete when final tail is fully Blorp-observed |
| `compiler/lib/language_surface.ml` | Typecheck/LSP/parser-adjacent tables live in Blorp | Remove as a runtime bridge call until typecheck is Blorp-owned |
| `compiler/lib/core_trait_resolve.ml` | Diagnostic hint rendering | Subsumed when trait resolve ports |
| `compiler/lib/core_profile.ml` | Profile text rendering | Subsumed when profiling/reporting ports or made static |
| `compiler/lib/compiler_blorp_bridge.ml` | Stage/error renderers and bridge process management | Reduce to request/response and helper-cache plumbing |

The earliest current Blorp call is the source-language surface table lookup from
OCaml typecheck/LSP-adjacent code. That call is not part of a contiguous
compiler tail. It should not drive the next big porting slice. Near-term, it
should either become compile-time/generated static data on the OCaml side or be
allowed only behind a documented bridge exception until typecheck moves into
Blorp.

## Target Architecture

During the transition, each production compile should have one OCaml-to-Blorp
transfer point:

```text
OCaml owns everything before the boundary
  -> one JSON request containing the boundary input
  -> Blorp owns every compiler stage after the boundary
  -> one JSON response containing diagnostics, stage observations, or artifact
```

The boundary should move left in this order:

| Boundary | Blorp owns after handoff | Status |
| --- | --- | --- |
| Post-closure Core | resource, fairness, prepare, emit | Current default |
| Post-reuse / pre-closure Core | closure, resource, fairness, prepare, emit | Next major boundary target |
| Post-Perceus Core | reuse, closure, final tail, emit | After closure ports |
| Post-consume-specialize Core | Perceus, reuse, closure, final tail, emit | After ownership tests are mirrored |
| Post-DCE / post-specialize Core | consume specialize onward | Late ownership checkpoint |
| Lowered Core | all Core optimization/lowering passes after lowering | Middle-Core checkpoint |
| Typed AST | Core lowering onward | Lowering checkpoint |
| Parsed source graph | typecheck onward | Frontend checkpoint |
| Source graph or source text | parse onward | Full compiler ownership |

The final compiler should look like this:

```text
impure CLI / tool shell
  -> build source input
  -> pure parse
  -> pure module graph resolution over explicit source data
  -> pure inference/typecheck
  -> pure compile-time evaluation
  -> pure Core lowering
  -> pure Core pipeline
  -> pure C artifact emission
  -> impure artifact writing / C compiler invocation
```

The formatter and LSP should eventually share the same Blorp compiler library,
but they are not the lowest-friction route to reducing OCaml in the compile
pipeline. Treat them as later consolidation unless they block the compiler
boundary.

## Non-Negotiables

- Direct port first. Preserve the OCaml module call graph, function boundaries,
  stage order, and tests until the Blorp slice is proven equivalent.
- One production JSON boundary. Temporary renderer/snippet calls are migration
  debt, not the architecture.
- Delete OCaml with each authoritative Blorp slice. A port is incomplete if both
  languages still implement the same production stage.
- Prefer strict data over strings. Use enums/unions/records/structs so illegal
  states are unrepresentable at the data model boundary.
- Preserve phase boundaries. Do not put typechecking in emission, parsing
  constraints in Core passes, or codegen guesses in earlier stages.
- Keep stage transforms pure. Local mutation inside `pure func` is fine when it
  keeps a direct port simple and efficient.
- Keep bridge errors structured. Unsupported cases should identify the missing
  Core shape or stage feature, not fall through to partial generated C.
- Tests come before deletion. If the OCaml slice had unit tests, mirror them in
  `compiler/blorp/tests` or create equivalent stage/golden tests before removing
  the OCaml tests.

## Direct Port Method

Use this procedure for every slice:

1. Pick an adjacent OCaml slice immediately to the left of the current boundary.
2. List the OCaml entry points, private helper graph, important local types, and
   current tests. Avoid redesigning the slice at this step.
3. Add or port failing Blorp tests that describe the OCaml behavior. Keep test
   names close to the OCaml names where practical so review can compare them.
4. Add the Blorp data types needed for that exact slice. Match the OCaml facts
   first; tighten names and variants only when it clearly makes an illegal state
   unrepresentable without changing behavior.
5. Port functions mechanically. Preserve helper decomposition unless the OCaml
   helper exists only to work around OCaml limitations.
6. Add a parity path while both implementations exist. For Core passes, prefer:
   `Core JSON input -> OCaml stage output` compared with
   `Core JSON input -> Blorp stage output`.
7. Route production through the Blorp slice using the existing bridge envelope.
8. Delete the replaced OCaml implementation and OCaml-only tests. Leave only the
   narrowest bridge shim if OCaml still owns earlier stages.
9. Do a small cleanup pass after deletion: names, purity annotations,
   duplicated helpers, string interpolation, multi-line strings, and replacing
   string tags with enums/unions.

Do not combine a direct port with a broad architecture rewrite. If the direct
port exposes a design problem, record it and make the minimal representation
change needed to keep the port correct.

## Checkpoint 0: Boundary Inventory And Guardrails

Goal: make every remaining OCaml-to-Blorp call intentional while the boundary is
being moved left.

Implementation:

- Keep an allowlist of OCaml files that may call `Compiler_blorp_bridge`.
- Mark each allowlist entry as one of: production boundary, command perimeter,
  bootstrap exception, observability exception, or table/diagnostic exception.
- Add or maintain a hygiene check that rejects new bridge call sites unless this
  roadmap is updated.
- Ensure bridge cache keys are content-derived from the relevant Blorp compiler
  source and do not include tests unless the helper actually needs tests.
- Keep `compiler/lib/compiler_blorp_bridge.ml` focused on JSON request/response,
  subprocess/cache management, and typed response decoding.

Deletion:

- Delete stale bridge wrappers and renderer names as soon as no allowlisted call
  uses them.
- Delete any OCaml tests that only verify removed bridge snippets after the
  equivalent Blorp tests exist.

Validation:

- `rg "Compiler_blorp_bridge\\." compiler/lib compiler/bin -g '*.ml'` matches
  the allowlist.
- `scripts/check-compiler-port-inventory` passes if present.
- `git diff --check` passes.

## Checkpoint 1: Close The Current Tail

Goal: make the current post-closure handoff a truly contiguous Blorp tail, with
no duplicate OCaml final-tail implementation needed for production observation.

Direct OCaml slice to mirror:

- `compiler/lib/core_resource.ml`
- `compiler/lib/core_fairness.ml`
- `compiler/lib/core_codegen_prepare.ml`
- the `Core_reuse.rewrite_prepared_program` subgraph in
  `compiler/lib/core_reuse.ml`
- final-stage observability in `compiler/lib/core_pipeline.ml`

Implementation:

- Keep `compiler_core_pipeline.run_post_closure_tail` as the single Blorp-owned
  implementation of the post-closure tail used by both bridge testing and
  production C emission.
- Expand `run_core_pipeline` so the Blorp tail can return final Core JSON for
  observation, not only C artifacts.
- Replace `needs_ocaml_final` in `core_pipeline.ml` with Blorp-backed final
  observation or Blorp-owned invariant reporting.
- Keep final-stage names and dump semantics stable.
- Move any remaining emit-only representation helpers out of
  `core_emit_blorp_c.ml` and into Blorp data/model code when they are part of
  final preparation rather than JSON projection.

Deletion:

- Delete or reduce `core_resource.ml` and `core_fairness.ml` once final dumps and
  invariants no longer require their OCaml versions.
- Delete the prepared-reuse OCaml subgraph if Blorp owns it or tests prove it is
  unreachable/obsolete.
- Shrink `core_codegen_prepare.ml` to only earlier-stage facts that still have
  OCaml callers; delete final-preparation functions as Blorp owns them.

Validation:

- Blorp tests for resource, fairness, prepare, and prepared union reuse.
- Stage parity fixtures for representative final-tail inputs.
- Runtime, leak, and codegen audit tests for resources, loops, prepared tuples,
  prepared lists, records, tensors, and managed unions.

## Checkpoint 2: Delete Snippet-Style Emission Helpers

Goal: make C emission a single Blorp artifact request, not a collection of
snippet renderers called from OCaml emission code.

Direct OCaml slice to mirror:

- `compiler/lib/core_emit_blorp_backend.ml`
- `compiler/lib/core_emit_blorp_prepared_backend.ml`
- `compiler/lib/core_emit_intrinsic.ml`
- remaining bootstrap-only pieces of `core_emit_blorp_template.ml`
- old OCaml emitter call sites that exist only to use these helpers

Implementation:

- Audit all production uses of prepared and intrinsic renderer wrappers.
- Move any still-needed operation into `compiler_core_emit.brp` or a Blorp
  emitter domain module with the same inputs and outputs.
- Replace runtime arity lookup calls with Blorp-side validation or a generated
  static manifest used only at the bridge edge.
- Keep renderer actions only for bridge-helper bootstrap and tests until the
  helper can compile without them.
- Stop adding new OCaml emission helper code. New emission support should land
  in Blorp.

Deletion:

- Delete `core_emit_blorp_backend.ml` when no OCaml production emitter calls it.
- Delete `core_emit_blorp_prepared_backend.ml` when prepared operations are
  emitted in Blorp.
- Delete `core_emit_intrinsic.ml` when the old OCaml emitter no longer needs it.
- Delete renderer-template fallback code after the bridge helper bootstrap no
  longer depends on it.

Validation:

- Source-level codegen audit proves default emission uses Blorp.
- Blorp emitter unit tests cover each deleted helper family.
- Generated C inspection for representative intrinsic, list, dict, tensor,
  tuple, constructor, channel, closure, and resource cases.

## Checkpoint 3: Move Boundary Left Through Closure

Goal: hand off post-reuse/pre-closure Core and let Blorp own closure conversion
plus the whole tail.

Direct OCaml slice to mirror:

- `Core_closure.adapt_function_refs_program`
- `Core_closure.convert_program`
- closure/task metadata helpers used by emission and invariants
- closure-specific tests and invariant checks

Implementation:

- Port the OCaml closure local types and helper graph directly.
- Add Blorp Core JSON support for every closure/task metadata shape the OCaml
  stage produces or consumes.
- Add `run_core_pipeline` stage support for `closure` and for
  `closure_to_emit` as a combined convenience action.
- Route `core_pipeline.ml` to hand off before closure when no final OCaml
  observation is needed.
- Make final observation use Blorp closure output when dumps/invariants request
  stages after closure.

Deletion:

- Delete the old closure conversion path once production and observations are
  Blorp-backed.
- Remove closure-specific OCaml invariant code only after equivalent Blorp
  invariants or parity tests exist.

Validation:

- Port closure compiler-unit tests into `compiler/blorp/tests`.
- Add stage parity fixtures for captured closures, direct function refs,
  concurrent task closures, detach, resource captures, and closure params.
- Run runtime concurrency and memory/leak tests that exercise closures.

## Checkpoint 4: Move Boundary Left Through Reuse

Goal: hand off post-Perceus Core and let Blorp own reuse, closure, final tail,
and emission.

Direct OCaml slice to mirror:

- `Core_reuse.rewrite_program`
- collection reuse analysis
- managed-union reuse analysis
- prepared-union reuse if not completed in Checkpoint 1

Implementation:

- Port reuse facts as explicit Blorp variants. Avoid stringly typed family tags
  where an enum or union can represent the allocation family.
- Preserve fail-closed behavior for interference, owner reads, incompatible
  allocations, and non-linear control flow.
- Keep reuse decisions independent from generated C text.
- Add `run_core_pipeline` stages for `reuse` and `reuse_to_emit`.

Deletion:

- Delete `core_reuse.ml` once both normal reuse and prepared reuse are Blorp-owned
  and all earlier OCaml stages call the Blorp boundary before reuse.

Validation:

- Port reuse unit tests.
- Add JSON stage parity for list/dict/set/string/bytes/managed union candidates.
- Run leak tests and generated-C audits for reuse boundaries.

## Checkpoint 5: Move Boundary Left Through Perceus And Consume Specialize

Goal: hand off post-DCE Core and let Blorp own ownership insertion,
consume-specialization, reuse, closure, final tail, and emission.

Direct OCaml slice to mirror:

- `compiler/lib/core_consume_specialize.ml`
- `compiler/lib/core_perceus.ml`
- `compiler/lib/core_perceus_check.ml`
- ownership-related invariant tests

Implementation:

- Port Perceus environment construction, call contracts, last-use/drop
  insertion, and balancing helpers.
- Port consume-specialization before Perceus in the same call order as
  `core_pipeline.ml`.
- Represent ownership actions and allocation/destructor families explicitly.
- Add `run_core_pipeline` stages for `consume_specialize`, `perceus`, and
  `ownership_to_emit`.

Deletion:

- Delete consume-specialize and Perceus OCaml modules after production boundary
  moves before them.
- Delete OCaml Perceus checker tests after Blorp tests cover the same checks.

Validation:

- Port Perceus and consume-specialize tests.
- Run the full leak gate and targeted concurrency cancellation/leak tests.
- Compare Core dumps after Perceus and reuse for representative fixtures.

## Checkpoint 6: Move Boundary Left Through Late Middle-Core Passes

Goal: hand off after specialization inputs or earlier and let Blorp own the late
optimization/lowering cluster.

Direct OCaml slices to mirror, in boundary-adjacent order:

- `Core_dce.prune_unreachable_declarations`
- `Core_specialize.specialize_program`
- `Core_tailrec.lower_program`
- `Core_std_inline.rewrite_program`
- `Core_resolve.resolve_program`
- `Core_trait_resolve.resolve_program`

Implementation:

- Port one pass or tightly coupled pair at a time.
- Preserve public stage names even if Blorp internally splits work more finely.
- Move diagnostics with the pass that emits them. For example,
  trait-resolution hint rendering should disappear as a bridge call when
  trait resolve itself ports.
- Add `run_core_pipeline` combined stages only after individual stages have
  parity tests.

Deletion:

- Delete each OCaml pass when the boundary moves before it and stage observation
  can read the Blorp result.
- Delete diagnostic renderer bridge exceptions that become internal to Blorp.

Validation:

- Stage dump parity after each pass.
- Existing compiler fixtures for trait errors, call resolution, tailrec, DCE,
  specialization, and std inline.

## Checkpoint 7: Move Boundary Left Through Fusion, Match, Synth, Mono, Desugar

Goal: make lowered Core enter a Blorp-owned Core pipeline.

Direct OCaml slices to mirror:

- `Core_string_pipeline`
- `Core_collection_pipeline`
- `Core_parallel_tensor_pipeline`
- `Core_tensor_fusion`
- `Core_tuple_sroa`
- `Core_match`
- `Core_synth`
- `Core_mono`
- `Core_list_layout`
- `Core_desugar`
- `Core_ssa`
- `Core_debug`

Implementation:

- Port the fusion cluster with parity tests per family before combining it.
- Port match decision-tree construction directly, preserving exhaustiveness and
  fallback behavior.
- Port monomorphization with explicit import/module alias inputs.
- Keep all counters and generated names explicit in stage input/output.
- Add a single Blorp `run_core_pipeline` action that accepts lowered Core and
  returns either requested stage snapshots or a C artifact.

Deletion:

- Delete each OCaml Core pass after the lowered-Core boundary is authoritative.
- Delete duplicate OCaml stage-order orchestration.

Validation:

- Golden Core dumps for lower, desugar, mono, match, resolve, specialize,
  Perceus, closure, and final.
- Runtime and compiler fixtures for generics, traits, pattern matching, tensors,
  collection pipelines, strings, and debug blocks.

## Checkpoint 8: Move Boundary Left Through Core Lowering

Goal: make typed AST JSON the active boundary and let Blorp own Core creation
and every downstream stage.

Direct OCaml slices to mirror:

- `Core_lower`
- `Core_flatten`
- `Core_ffi_boundary`
- initial `Core_list_layout`
- Core builder/traversal helpers still required by lowering

Implementation:

- Define typed AST JSON as the stable transfer input.
- Port lowering in the same declaration and expression order as OCaml.
- Preserve source locations, type metadata, function identities, import aliases,
  module imports, registry facts, and generated IDs.
- Keep FFI/list layout annotation as explicit post-lowering passes unless the
  OCaml call graph proves they are inseparable.

Deletion:

- Delete OCaml lowering and flattening modules after the typed-AST boundary is
  authoritative.
- Delete OCaml Core data helpers only when no earlier OCaml code still needs the
  OCaml Core representation.

Validation:

- Lowered Core parity fixtures.
- Compiler fixtures for modules, imports, FFI boundaries, lists, records,
  unions, closures, tensors, and resources.

## Checkpoint 9: Move Boundary Left Through Type Infrastructure And Typecheck

Goal: make parsed source graph JSON the boundary and let Blorp own type
inference, checking, trait resolution inputs, and typed AST output.

Direct OCaml slices to mirror:

- `types.ml` and type utilities
- `env*.ml`
- `dim_solver.ml`
- `refinement.ml`
- `type_resolution.ml`
- `type_widening.ml`
- `infer.ml`
- `typecheck.ml`
- purity, tailrec, unused-import, and typed-AST validation helpers
- module graph resolution that is pure over already-loaded source data

Implementation:

- Split impure file discovery/loading from pure module resolution.
- Port type environments as explicit values.
- Port diagnostics with structured code, message, notes, and help.
- Eliminate the runtime `language_surface.ml` bridge call by either making the
  data internal to the Blorp typechecker or generating static OCaml data until
  this checkpoint lands.
- Keep source-language facts in typed metadata where downstream stages depend on
  them.

Deletion:

- Delete OCaml inference/typecheck/type utility modules after `check` and
  compile use the Blorp typed-program output.
- Delete early table/diagnostic bridge exceptions subsumed by typecheck.

Validation:

- Port compiler-unit type/env/dimension/refinement tests.
- Existing infer/typecheck should-pass and should-fail fixtures pass.
- Error text tests cover user-facing diagnostics.

## Checkpoint 10: Move Boundary Left Through Parser And Source AST

Goal: make source text or source graph the only input to the Blorp compiler.

Direct OCaml slices to mirror:

- `lexer.mll`
- `parser.mly`
- `ast.ml`
- `interp_parser.ml`
- `subscript_desugar.ml`
- parser diagnostics and comment/source-span handling

Implementation:

- Port lexing, indentation, tokens, parser grammar, interpolation parsing, and
  desugaring directly before changing grammar behavior.
- Keep removed-syntax diagnostics that improve first-time user experience.
- Return comments and spans as explicit parse output data.
- Update `docs/GRAMMAR.md` and parser docs in the same change if behavior
  changes.

Deletion:

- Delete OCaml lexer/parser/AST/desugar code after parser fixtures and formatter
  projection use Blorp source data.
- Delete OCaml formatter JSON projection that only adapts OCaml AST to Blorp.

Validation:

- Parser should-pass and should-fail fixtures.
- Formatter fixtures where parse trees affect formatting.
- LSP position/symbol tests after they switch to Blorp parse data.

## Checkpoint 11: Tooling, Formatter, LSP, And OCaml Shell Removal

Goal: remove the remaining OCaml compiler shell after the compiler library is
Blorp-owned.

Direct OCaml slices to mirror:

- CLI command parsing and compile/run/check/test wiring
- test runner
- formatter facade and formatter process management
- LSP server transport and request handlers
- diagnostics rendering shell
- Dune/opam build wrapper, when no compiler OCaml remains

Implementation:

- Keep impure shell responsibilities explicit: args/env, file IO, subprocesses,
  editor protocol streams, artifact writing, and C compiler invocation.
- Make each shell call the pure Blorp compiler library rather than embedding
  compiler semantics.
- Treat formatter/LSP as consumers of the same compiler data model, not separate
  compiler frontends.

Deletion:

- Delete `compiler/bin/blorp.ml` only after an equivalent Blorp CLI exists.
- Delete OCaml LSP, formatter, and test runner modules as they port.
- Delete Dune/opam compiler build files when no OCaml source remains.

Validation:

- Full `scripts/test`.
- Preview smoke commands from `AGENTS.md`.
- Docker premerge gates.
- Reproducible bootstrap documentation.

## Testing Strategy

Every porting slice needs at least one of these parity mechanisms before OCaml
deletion:

| Slice type | Required parity evidence |
| --- | --- |
| Core-to-Core pass | Same Core JSON input, compare OCaml stage output to Blorp stage output |
| Emission helper | Same Core input, compare generated C where stable; otherwise compare behavior and audited C fragments |
| Diagnostics | Same input, compare code/message/notes/help expected by fixtures |
| Typecheck/infer | Same source fixture result and expected diagnostic text |
| Parser | Same parser fixture behavior and formatter/LSP impacts |
| CLI/tooling | Same exit codes, stdout/stderr contract, and artifact behavior |

Keep end-to-end tests throughout the migration. They prove the whole compiler
still works, but they do not replace stage parity tests for deleting OCaml.

Recommended local validation while OCaml remains:

```bash
make
scripts/test compiler-unit compiler cli
./blorp test compiler/blorp/tests
git diff --check
```

Before checkpoint merges that touch ownership or emission:

```bash
scripts/test runtime leak
scripts/test compiler
```

Before large Core/frontend boundary moves:

```bash
BENCH_RUNS=5 BENCH_WARMUPS=1 bash benchmarks/bench.sh compiler_ast compiler_symbols compiler_emit
```

## Deletion Policy

For each checkpoint:

1. Port or add tests while OCaml still exists.
2. Port the OCaml call graph directly into Blorp.
3. Route production through the Blorp implementation.
4. Delete the replaced OCaml implementation and OCaml-only tests.
5. Leave only a narrow bridge shim if OCaml still owns earlier stages.
6. Update this roadmap if the boundary or call inventory changes.
7. Record migration accounting in the change summary: OCaml deleted, Blorp added,
   remaining bridge exceptions, and why each exception remains.

Large net additions of Blorp without proportional OCaml deletion are acceptable
only for short-lived bridge scaffolding. The next adjacent checkpoint should pay
that scaffolding down.

## Near-Term Execution Order

1. Close the current-tail parity gap, especially prepared union reuse and final
   observability. This is the most direct route to deleting late OCaml tail code.
2. Delete snippet-style emission helpers and bootstrap-only renderer fallbacks so
   production emission is one Blorp artifact request.
3. Port closure conversion directly and move the main boundary to
   post-reuse/pre-closure Core.
4. Port reuse, then Perceus and consume-specialize, with leak tests and stage
   parity after each move.
5. Continue left through the middle-Core passes in the exact order used by
   `core_pipeline.ml`, deleting each OCaml module as soon as Blorp is
   authoritative.

The next implementation slice should therefore start with Checkpoint 1, not with
parser/typechecker work and not with formatter cleanup. It is adjacent to the
current boundary, has clear OCaml modules to copy, and can produce immediate
OCaml deletion.
