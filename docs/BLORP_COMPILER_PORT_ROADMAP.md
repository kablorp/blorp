# Blorp Compiler Port Roadmap

Status checked against code on 2026-07-02.

This roadmap is for replacing the OCaml compiler implementation with Blorp
source. The guiding strategy is direct porting first: copy the OCaml call graph,
data flow, and tests as closely as possible, prove parity, route production
through Blorp, then delete the corresponding OCaml. Larger cleanups should wait
until after the apples-to-apples port for a slice is authoritative.

## Current Verified State

The current production compile path has two Blorp-owned islands around an
OCaml-owned middle:

```text
Blorp CLI planning / source graph discovery / source reads / parse
  -> JSON handoff carrying explicit frontend module graph data
  -> OCaml command execution / module validation / typecheck
  -> OCaml Core lowering and early Core setup
  -> OCaml Core pipeline through Perceus
  -> JSON handoff
  -> Blorp normal reuse
  -> Blorp closure conversion
  -> Blorp resource cleanup lowering
  -> Blorp fairness checkpoint insertion
  -> Blorp final Core preparation
  -> Blorp prepared union reuse
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
```

The default backend handoff is now the post-Perceus Core program.
Normal emission then calls the Blorp bridge action `emit_post_closure_c`, which
decodes Core JSON and runs the Blorp post-Perceus tail:

```text
compiler_core_reuse.rewrite_post_perceus_program
compiler_core_closure.convert_program
compiler_core_resource.rewrite_resource_program
compiler_core_fairness.insert_cooperative_checkpoints
compiler_core_prepare.prepare_program
compiler_core_reuse.rewrite_prepared_program
compiler_core_emit.try_emit_prepared_core_program_c_artifact_with_options
```

There are still important OCaml paths around that default:

- `compiler/bin/blorp.ml` remains the command execution shell. It invokes the
  Blorp CLI planner, decodes CLI artifacts, runs the OCaml typechecker and
  middle pipeline, writes C artifacts, invokes the host C compiler, and owns
  REPL/LSP/test/package command loops that have not been ported.
- `compiler/blorp/compiler_cli*.brp` owns user-argument planning for the main
  command families, source target expansion, auto-format decisions, source
  reads, source graph discovery, source-package/pkg-root context discovery, and
  frontend module graph artifact encoding for `check`, `compile`, and `run`.
- `compiler/lib/modules.ml` now consumes Blorp-parsed roots and preloaded source
  graph modules, but still owns authoritative module validation, embedded std
  policy, import origin checks, cycles, package policy, and the parse-cache
  interface used by the OCaml typechecker.
- `core_pipeline.ml` still owns the front half of the Core pipeline through
  Perceus, then hands post-Perceus Core to the Blorp backend tail.
- Timing-only stage observation uses a lightweight event callback. It does not
  materialize a duplicate OCaml final tail; the Blorp-owned backend tail is
  reported as the single `final` event unless a caller asks for tail JSON.
- Program-bearing CLI dumps and `--stop-after` requests observe `reuse`,
  `closure`, and `final` through `run_core_pipeline` Core JSON returned by the
  Blorp tail.
- OCaml invariant checking now covers the OCaml-owned pre-backend stages.
  Tail-specific invariant reporting should be added in Blorp or in the bridge
  JSON observation path as needed.
- `BLORP_COMPILER_RENDERER_HELPER=1` is now limited to static table bootstrap
  for the remaining OCaml language-surface and fairness-policy callers while
  compiling the bridge helper. It no longer routes C emission through the OCaml
  emitter or reads emission-template TSV manifests in current source. The TSV
  files remain temporarily because the pinned bootstrap compiler still needs
  them to build the bridge helper during hygiene checks.
- `compiler/lib/core_emit_blorp_c.ml` is still the OCaml Core-to-JSON projector,
  bridge client wrapper, and some validation/subset logic. It is bridge code,
  not the desired long-term compiler implementation.

The Blorp bridge protocol currently supports these actions across the backend
and parser bridge dispatchers:

| Action | Current purpose | Desired long-term status |
| --- | --- | --- |
| `emit_post_closure_c` | Current production tail handoff | Move left as more stages port |
| `prepare_and_emit_c` | Compatibility entrypoint for the pinned compiler bootstrap's older post-closure handoff | Delete after the pinned compiler advances past `dev-33e00c2b94df` |
| `run_core_pipeline` | Core JSON -> Core JSON for one tail stage | Expand into the main stage parity mechanism |
| `parse_source` | Source text or path/module metadata -> parsed AST JSON through `compiler_parser_bridge.brp` | Keep as the source parse entry until frontend module graphs feed a Blorp-owned typechecker |
| `parse_sources` | Batch source parse for CLI/source-graph discovery waves | Keep while Blorp-owned CLI graph discovery parses multiple files |
| `render_many` | Temporary non-emission table/diagnostic requests | Delete from production compile path |
| `renderer_templates` | Compatibility metadata query for the pinned compiler bootstrap's renderer arity checks | Delete after the pinned compiler advances past `dev-33e00c2b94df` |
| `lower_and_compile` | Declared, unsupported | Implement when Core lowering ports |
| `typecheck_and_compile` | Declared, unsupported | Implement when typecheck ports |
| `compile_source` | Declared, unsupported | Replace with the frontend-module/typecheck boundary or delete when no bootstrap caller needs the declared action |

Current OCaml-to-Blorp calls outside the main backend handoff are:

| OCaml site | Why it calls Blorp today | Roadmap treatment |
| --- | --- | --- |
| `compiler/bin/blorp.ml` | Hidden bridge commands, CLI artifact decoding, command execution, artifact writing, C compiler invocation, and still-OCaml command loops | Keep only as the impure shell while compiler semantics move to Blorp |
| `compiler/lib/modules.ml` | Finalizes Blorp parsed AST artifacts, preloads source graph modules, and still owns module validation/typecheck-facing cache policy | Collapse into the Blorp frontend/typechecker boundary when module loading/typecheck move |
| `compiler/lib/core_pipeline.ml` | Default C backend handoff and OCaml-owned early Core passes | Keep, but move the input boundary left over time |
| `compiler/lib/core_emit_blorp_c.ml` | Core JSON projection, bridge request, subset validation | Shrink to the single bridge shim; delete subset logic as stages move |
| `compiler/lib/language_surface.ml` | Typecheck/LSP/parser-adjacent tables live in Blorp | Remove as a runtime bridge call until typecheck is Blorp-owned |
| `compiler/lib/core_trait_resolve.ml` | Diagnostic hint rendering | Subsumed when trait resolve ports |
| `compiler/lib/core_profile.ml` | Profile text rendering and lightweight stage-event timing | Subsumed when profiling/reporting ports or made static |
| `compiler/lib/compiler_blorp_bridge.ml` | Stage/error renderers, prepared helper binaries, and bridge process management | Reduce to request/response and startup helper preparation plumbing |

The source-language surface table lookup from OCaml typecheck/LSP-adjacent code
is still a documented bridge exception. It is not a contiguous compiler-stage
handoff and should either become static generated data on the OCaml side or
disappear when typecheck moves into Blorp.

The current compile path can cross the bridge twice: once for Blorp-owned CLI
source graph/read/parse work and once for the Blorp-owned Core tail. That is
accepted migration debt while the OCaml middle remains. It must not grow into
additional side channels. The next structural goal is to make one of those
islands absorb adjacent OCaml code until the middle collapses.

## Target Architecture

The final transition target is one OCaml-to-Blorp transfer point:

```text
OCaml owns everything before the boundary
  -> one JSON request containing the boundary input
  -> Blorp owns every compiler stage after the boundary
  -> one JSON response containing diagnostics, stage observations, or artifact
```

The active ownership edges are:

| Edge input | Blorp-owned region | Status |
| --- | --- | --- |
| Source text / source graph | CLI planning, target expansion, source reads, import discovery, parse | Completed for `check`, `compile`, and `run` roots plus readable filesystem imports |
| Frontend module graph | module validation, inference, typecheck, Core lowering onward | Next frontend edge |
| Typed AST | Core lowering onward | Later frontend-to-Core checkpoint |
| Lowered Core | all Core optimization/lowering passes after lowering | Middle-Core checkpoint |
| Post-DCE / post-specialize Core | consume specialize onward | Late ownership checkpoint |
| Post-consume-specialize Core | Perceus, reuse, closure, final tail, emit | Next backend boundary after Perceus port |
| Post-Perceus Core | reuse, closure, final tail, emit | Current default backend boundary |
| Post-closure Core | resource, fairness, prepare, emit | Completed as the first Blorp tail |
| Post-reuse / pre-closure Core | closure, resource, fairness, prepare, emit | Completed for default emission |

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

The formatter and LSP should share the same Blorp source model. They should not
be separate compiler frontends or reasons to preserve an OCaml parser path.

## Non-Negotiables

- Direct port first. Preserve the OCaml module call graph, function boundaries,
  stage order, and tests until the Blorp slice is proven equivalent.
- One bridge subsystem and one protocol envelope. The final architecture should
  have one production JSON boundary; the current parser/source and Core-tail
  handoffs are temporary migration debt, not a reason to add side channels.
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

1. Pick an adjacent OCaml slice at one active ownership edge.
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
- Prepare the bridge helper binaries once at process-harness startup when a
  harness such as `scripts/test` controls many compiler invocations. Keep the
  content-keyed helper cache only as an ad-hoc fallback for standalone compiler
  invocations.
- Keep `compiler/lib/compiler_blorp_bridge.ml` focused on JSON request/response,
  subprocess/helper management, and typed response decoding.

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

Historical OCaml slice now reduced to final-stage observability in
`compiler/lib/core_pipeline.ml`.

Implementation:

- Keep `compiler_core_pipeline.run_post_closure_tail` as the single Blorp-owned
  implementation of the post-closure tail used by both bridge testing and
  production C emission.
- Keep `emit_post_closure_c` as the only production C artifact bridge action.
  The `prepare_and_emit_c` bridge action remains only as a pinned-bootstrap
  compatibility entrypoint for the older post-closure handoff. Do not
  reintroduce a prepared-Core `emit_c` bridge action; prepared emission remains
  an internal helper behind the Blorp-owned post-closure tail.
- Done: expanded `run_core_pipeline` so the Blorp tail can return `reuse`,
  `closure`, and `final` Core JSON for CLI observation, not only C artifacts.
- Done: removed the duplicate OCaml final-tail snapshot from
  `core_pipeline.ml`; program-bearing OCaml callbacks now stop at the
  post-Perceus handoff.
- Replace tail-specific invariant checks with Blorp-owned invariant reporting
  or a typed bridge JSON decoder if they are needed for release gates.
- Keep final-stage names and dump semantics stable.
- Move any remaining emit-only representation helpers out of
  `core_emit_blorp_c.ml` and into Blorp data/model code when they are part of
  final preparation rather than JSON projection.

Deletion:

- Done: deleted `core_resource.ml`, `core_fairness.ml`, and `core_reuse.ml`
  after the supported route and tail observation moved to Blorp.
- Done: folded the remaining bridge-side layout/boxing facts into
  `core_emit_layout.ml`; deleted the standalone final-preparation helper
  module now that Blorp owns final preparation.

Validation:

- Blorp tests for resource, fairness, prepare, and prepared union reuse.
- Stage parity fixtures for representative final-tail inputs.
- Runtime, leak, and codegen audit tests for resources, loops, prepared tuples,
  prepared lists, records, tensors, and managed unions.

## Checkpoint 2: Delete Snippet-Style Emission Helpers

Goal: make C emission a single Blorp artifact request, not a collection of
snippet renderers called from OCaml emission code.

Direct OCaml slice to mirror:

- remaining bootstrap-only pieces of `core_emit_blorp_template.ml`
- old OCaml emitter call sites that exist only to use these helpers

Implementation:

- Audit all production uses of prepared and intrinsic renderer wrappers.
- Move any still-needed operation into `compiler_core_emit.brp` or a Blorp
  emitter domain module with the same inputs and outputs.
- Replace runtime arity lookup calls with Blorp-side validation or a generated
  static manifest used only at the bridge edge.
- Keep bridge renderer actions only for non-emission table/diagnostic helpers
  that still have OCaml callers.
- Stop adding new OCaml emission helper code. New emission support should land
  in Blorp.

Deletion:

- Done: deleted `core_emit.ml`, `core_emit_blorp_backend.ml`,
  `core_emit_intrinsic.ml`, `core_emit_pattern.ml`, and
  `core_emit_blorp_prepared_backend.ml` after Blorp emission became
  unconditional and the remaining layout projections moved to narrow helpers.
- Done: removed the OCaml production bridge query for renderer template arity;
  intrinsic renderability is now validated by the Blorp emitter, while OCaml
  only checks arity for Core shapes it rewrites before JSON projection.
- Done: deleted the current OCaml renderer-template TSV fallback and its
  manifest parser; helper-mode render bootstrap now serves only the two static
  table families that still have OCaml callers. The TSV files themselves can be
  deleted after the pinned bootstrap advances past the old manifest reader.
- Done: removed the bridge-level intrinsic/prepared renderer commands. C
  emission now uses those Blorp renderer modules internally instead of exposing
  them as ad-hoc bridge snippet requests.

Validation:

- Source-level codegen audit proves default emission uses Blorp.
- Blorp emitter unit tests cover each deleted helper family.
- Generated C inspection for representative intrinsic, list, dict, tensor,
  tuple, constructor, channel, closure, and resource cases.

## Checkpoint 3: Move Boundary Left Through Closure

Goal: hand off post-reuse/pre-closure Core and let Blorp own closure conversion
plus the whole tail.

Status: default C emission now uses the Blorp closure conversion as part of the
post-Perceus tail. The old OCaml closure conversion wrapper has been removed;
the remaining OCaml closure code adapts function references before DCE and
provides metadata/types used by emission and invariants.

Direct OCaml slice to mirror:

- `Core_closure.adapt_function_refs_program`
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

Status: default C emission now hands off post-Perceus Core. The Blorp normal
reuse pass covers the conservative collection allocation and producer-handoff
rewrites needed by the supported route, and `core_reuse.ml` has been deleted.

Deleted OCaml slice now owned by Blorp:

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

- Done: deleted `core_reuse.ml` once both normal reuse and prepared reuse were
  Blorp-owned on the supported route.

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
- ownership-related invariant tests

Implementation:

- Done: ported consume-specialization as `compiler_core_consume_specialize.brp`
  with direct Blorp unit coverage and a `run_core_pipeline` bridge stage named
  `consume_specialize`.
- Done: started the Perceus foundation by porting ownership contract modes,
  validation, and representative intrinsic/runtime contracts to
  `compiler_core_ownership.brp`.
- Done: started the direct Perceus pass port in
  `compiler_core_perceus.brp` with managed-type environment construction,
  managed-type classification, use counting, linearity checks, and simple
  linear `let` balancing with `DupExpr`/`DropExpr`.
- Done: added the first Perceus call-contract lookup layer in Blorp:
  constructor contracts from Core union variants, result-mode classification,
  built-in/intrinsic ownership-contract lookup, and borrowed fallback contracts
  for foreign/closure calls.
- Done: applied ownership call contracts to the Blorp linear managed-let
  rewrite path, including borrowed-only post-body drops, consuming/COW-consuming
  calls, alias-returning call results, and consume-then-borrow sequencing.
- Continue porting branch/match ownership joins, loop/repeated-context consume
  protection, borrowed-result retention, final last-use/drop insertion, and
  checker support.
- Keep consume-specialization before Perceus in the same call order as
  `core_pipeline.ml` when the production boundary moves again.
- Represent ownership actions and allocation/destructor families explicitly.
- Add `run_core_pipeline` stages for `perceus` and `ownership_to_emit`.

Deletion:

- Delete consume-specialize and Perceus OCaml modules after production boundary
  moves before them.
- Done: deleted the OCaml-only Perceus checker helper and tests after Blorp
  ownership/Perceus tests covered the active checker path.

Validation:

- Done: direct consume-specialize tests cover safe self-replacement cloning,
  rejected aliasing results, and recursive constructor-field ownership.
- Done: Blorp ownership tests cover contract validation, malformed alias
  contracts, finalizer consumption, key collection intrinsics, and variadic
  string concat contracts.
- Done: Blorp Perceus tests cover managed-type classification, declaration-fed
  environment construction, `count_uses`, linearity, and simple managed-let
  Dup/Drop insertion.
- Done: Blorp Perceus tests cover constructor contract registration, def-id
  based constructor lookup, result modes, intrinsic/builtin contract lookup, and
  borrowed foreign/closure fallback contracts.
- Done: Blorp Perceus tests cover linear borrowed intrinsic drops, direct
  COW-consuming intrinsic consumption, alias-returning intrinsic results, and
  consume-then-borrow balancing.
- Port the remaining OCaml Perceus tests around branch joins, match ownership,
  loop/repeated-context consuming calls, borrowed-result retention, final drops,
  and checker diagnostics.
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

Goal: make frontend module graph JSON the boundary and let Blorp own type
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

OCaml structure read-through, checked on 2026-07-03:

- `compiler/lib/types.ml` is the semantic type utility hub over
  `Ast.type_expr`. It owns type pretty-printing, structural equality, named
  type identity normalization, type parameter syntax predicates, substitution,
  HM-style `TyMeta` creation/binding/zonking through `Session.t`, compatibility
  and bidirectional unification, array/dimension validation, primitive type
  constants, module-owned type-name qualification, and the nested `Types.Dim`
  facade.
- `compiler/lib/dim_solver.ml` is a small pure polynomial solver for dimension
  equalities. It canonicalizes `TyConstInt`, `TyVar`, `TyMeta`, and `TyDimOp`
  expressions, then reports `Solved`, `BindMeta`, `BindVar`, `Contradiction`,
  or `Stuck`.
- `compiler/lib/type_resolution.ml` is a narrow facade for source annotation
  resolution. It applies module-alias qualification, nominal dimension
  disambiguation, and alias policy through named use cases such as
  `function_parameter_annotation`, `record_field_type`, and
  `type_alias_target`.
- `compiler/lib/type_widening.ml` is a pure value-slot policy module. It
  preserves the distinction between semantic type and runtime value type for
  singleton integers, dimension operands, mutable bindings, function arguments,
  collection elements, bitwise operands, and method receivers.
- `compiler/lib/refinement.ml` plus `Type_proof_metadata` owns proof
  construction for bounded subscript/range facts. The inference code consumes
  these proofs; callers should not fabricate record-shaped proofs directly.
- `compiler/lib/env_types.ml` breaks a cycle between `Session` and `Env` by
  holding `def_id`, purity/origin enums, resource argument policy, loop-producer
  identity, bound type parameters, overload entries, and impl instances.
- `compiler/lib/env.ml` is both a lexical environment and a session-connected
  registry. Lexical scopes, `type_index`, variables, functions, constructors,
  records, aliases, type params, trait functions, and traits are value data on
  `Env.env`. Impl and UFCS method indexes alias `Session.current ()`, while
  overloads are intentionally per-env/import-scope. A Blorp port should make
  this sharing explicit in a compiler context value instead of recreating the
  ambient-session coupling.
- `compiler/lib/env_builtins.ml`, `builtin_metadata.ml`, and
  `generic_params.ml` populate the built-in type/function/trait surface. They
  are not just std docs: typecheck depends on these registrations for purity,
  special inference, resource policies, trait bounds, loop producers, and UFCS.
- `compiler/lib/language_surface.ml` is already a bridge facade over
  `compiler/blorp/language_surface_manifest.brp`. It currently serves OCaml LSP
  and prelude import helpers. It should disappear once the corresponding
  typecheck/tooling consumers read the Blorp data directly or from generated
  static data.
- `compiler/lib/typed_ast.ml` is the post-inference boundary wrapper. It
  validates that every consumed expression has finalized type info, no
  inference metas, source/semantic/value type slots, widening metadata, proofs,
  and resolved-call metadata. Core lowering and CTFE already prefer
  `Typed_ast.program` over raw `Ast.program`.
- `compiler/lib/call_resolution.ml` and `purity_analysis.ml` are smaller
  helper islands extracted from `infer.ml` / `typecheck.ml`. They are good
  early ports after `Env` exists because they mostly compute metadata from
  typed callee shapes and environment facts.
- `compiler/lib/typecheck.ml` has no `.mli`; it is currently the broad boundary
  module. Its major phases are: `check_state`; type/resource annotation
  canonicalization; import and alias registration; declaration registration for
  types, records, aliases, functions, traits, and impls; orphan/coherence and
  UFCS registration; `first_pass`; pattern exhaustiveness; function-scope setup
  and body checking; purity/tailrec/match/debug/resource/startup validation;
  global var checking; `second_pass`; prelude insertion; typed-AST conversion;
  private type leakage checks; and module-typecheck entry points.
- `compiler/lib/infer.ml` is the largest remaining frontend module. Important
  internal islands include: inference context and expected-context handling;
  type-shape memoization for resource/source/stream checks; refinement proof
  propagation; undefined identifier diagnostics; binding/free-variable helpers;
  module function/var/impl-method resolution; record field resolution; primitive
  and builtin call inference; resolved-call metadata; opaque conversions;
  subscript assignment handling; collection/tensor constructors; branch
  narrowing; block/statement inference; match/case/pattern binding; lambdas;
  and final `zonk_expr`.
- `compiler/lib/pipeline.ml` still orchestrates module loading, imported module
  typechecking, cross-module coherence, main typechecking, unused-import
  checks, and handoff to Core. Some of that remains impure or session-oriented;
  do not fold it into the first Blorp type utility slice.

Implementation sequence:

- Split impure file discovery/loading from pure module resolution.
- Port type environments as explicit values, including the current
  session-backed impl/UFCS indexes as named context fields rather than hidden
  ambient state.
- Port diagnostics with structured code, message, notes, and help.
- Eliminate the runtime `language_surface.ml` bridge call by either making the
  data internal to the Blorp typechecker or generating static OCaml data until
  this checkpoint lands.
- Keep source-language facts in typed metadata where downstream stages depend on
  them.
- Start with the pure substrate: semantic type model, type pretty-printing,
  equality, substitution, metas/zonking API shape, dimension solver,
  `Type_widening`, `Type_resolution`, and `Refinement`.
- Then port environment data: `Env_types`, lexical scopes, type index, trait
  definitions, impl instances, overload entries, UFCS method lookup, and
  built-in registrations.
- Then port declaration indexing/first pass over a `frontend_module_graph`:
  module aliases/imports, type/record/alias registration, function signatures,
  trait definitions, impl headers, module export facts, and prelude imports.
- Only after the environment and first pass exist in Blorp, port expression
  inference in small groups: literals/names, calls/overloads, records/unions,
  blocks/control flow, pattern matching, lambdas, generics/traits, resources,
  concurrency, globals/startup, and final `Typed_ast` construction.
- Keep one handoff while OCaml middle remains: Blorp emits a typed-program
  artifact that OCaml validates and lowers. Do not add parallel handoffs for
  individual inference subfeatures.

Deletion:

- Delete OCaml inference/typecheck/type utility modules after `check` and
  compile use the Blorp typed-program output.
- Delete early table/diagnostic bridge exceptions subsumed by typecheck.
- Cleanup already applied from the 2026-07-03 read-through:
  - `module_local_type_names_from_decls` was centralized as
    `Module_type_identity.local_type_names_from_decls` and removed from
    `typecheck.ml`, `infer.ml`, and `pipeline.ml`.
  - The legacy `Types.validate_tensor_dims` alias was removed; remaining
    callers use `Types.validate_array_dims` directly.
- Remaining cleanup candidates found during the 2026-07-03 read-through:
  - `Types.normalize_type_name` still maps legacy `Vector`/`Matrix` names to
    `Tensor` and is tested directly. Keep it until old nominal vector/matrix
    internal paths are either proven gone or represented explicitly in the type
    model; then delete the compatibility normalizer and its test.
  - `BLORP_FRONTEND_PARSER=ocaml` is retained only for pinned external
    bootstrap binaries that still read the retired selector. It is not a
    production source-parser selector anymore. Delete the env knob, docs, and
    bridge-env tests once the pinned bootstrap no longer needs it.
  - `language_surface.ml` is a transitional OCaml facade over Blorp-owned data.
    Delete it when typecheck/LSP/tooling no longer need an OCaml bridge call for
    source-language tables.

Validation:

- Port compiler-unit type/env/dimension/refinement tests.
- Existing infer/typecheck should-pass and should-fail fixtures pass.
- Error text tests cover user-facing diagnostics.

## Checkpoint 10: Finish Parser And Source-AST Ownership

Goal: make Blorp frontend module graph data the only parser/source-AST input to
the compiler and delete parser-adjacent OCaml that no longer owns semantics.

Detailed execution plan:
[FRONTEND_SOURCE_AST_ROADMAP.md](FRONTEND_SOURCE_AST_ROADMAP.md).

Status: the production source lex/parse path is Blorp-owned through the parser
bridge. The old parser selector/fallback model is gone. `check`, `compile`, and
`run` use Blorp CLI/source graph/read/parse artifacts packaged as a
`frontend_module_graph` before handing parsed data to the OCaml middle. Parser
artifacts now include a Blorp-owned syntactic `module_surface`; CLI source graph
import discovery and the OCaml module parse cache consume that surface instead
of rediscovering imports and syntactic exports from parsed-AST JSON. The
`frontend_module_graph` also carries the explicit std override,
source-package aliases, and local `pkg/` roots that the Blorp graph used to
resolve imports; the OCaml CLI frontier applies those facts before module
preloading rather than independently rediscovering them.

Direct OCaml slices to mirror:

- Blorp lexer/parser sources under `compiler/blorp/`
- `ast.ml`
- parser diagnostics and comment/source-span handling

Implementation:

- Keep lexing, indentation, tokens, parser grammar, comments, spans, and
  top-level source reads in Blorp.
- Keep parser-adjacent rewrites in the Blorp `typecheck_source` phase rather
  than hiding them inside OCaml typecheck.
- Keep comments and spans as explicit parse output data; do not reintroduce
  global lexer/comment stores.
- Preserve only current syntax. Removed forms should fail normally unless a
  targeted diagnostic materially improves first-time user experience.
- Update `docs/GRAMMAR.md` and parser docs in the same change when behavior
  changes.

Deletion:

- Delete OCaml parser/source-AST/desugar code after parser fixtures, formatter
  projection, and the OCaml middle consume the Blorp source model directly.
- Done: the OCaml formatter JSON projection has been deleted; formatting now
  uses Blorp-owned parse/projection/render code through the compiler bridge.

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
- Done: `compiler/blorp/compiler_cli_args.brp` owns pure CLI argument parsing as
  data for the main command families. The OCaml command shell still executes
  those parsed actions until the impure shell boundary moves.
- Done: the Blorp CLI surface is split by responsibility:
  `compiler_cli.brp` owns top-level planning/dispatch,
  `compiler_cli_args.brp` owns pure argument parsing,
  `compiler_cli_plan.brp` owns shared plan data,
  `compiler_cli_source_graph.brp` owns source reading/import graph/package
  source discovery, and `compiler_cli_artifact_json.brp` owns bridge artifact
  encoding.
- Done: `check`, `compile`, and `run` can enter the OCaml middle with
  `frontend_module_graph` artifacts instead of frontend option fallbacks for
  normal source command shapes.
- Done: `frontend_module_graph` carries graph context for std overrides,
  source-package aliases, and local `pkg/` roots, and the OCaml frontier applies
  that context before consuming preloaded parsed sources.
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

There are now two useful contiguous edges:

1. Frontend edge: finish parser/source-AST ownership by retiring remaining
   parser-adjacent OCaml, then move frontend module graph validation and type
   infrastructure into Blorp.
2. Backend edge: continue Perceus and consume-specialization until the default
   backend handoff can move before ownership insertion.

Pick slices by deletion potential and boundary clarity. A slice is preferred
when it removes OCaml code from one of those edges, avoids new bridge actions,
and leaves a smaller middle rather than another optional Blorp implementation.
