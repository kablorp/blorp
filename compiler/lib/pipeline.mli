(** Unified compilation pipeline for blorp.

    Encapsulates the full parse → load modules → typecheck → codegen flow.

    Callers are responsible for:
    - Reading the source file
    - Calling {!Modules.init_module_paths} / {!Modules.reset} as needed
    - Formatting and reporting the returned errors *)

type compile_result = {
  program : Ast.program;
  typed_program : Typed_ast.program;
  c_code : string;
  link_flags : string list;
  include_dirs : string list;
}
(** Result of a successful compilation. [program] is the AST compatibility
    view; [typed_program] is the validated typed boundary consumed by Core. *)

(** Frontend phases that run before Core lowering. *)
type frontend_phase = Parse | ModuleLoad | ModuleTypecheck | MainTypecheck

type phase_timing_phase =
  | InMemoryFrontendGraph
  | FrontendGraphFinalize
  | GraphTypecheck
  | SemanticMiddle
  | BackendEmission
  | CorePipeline

type phase_timing = {
  timing_phase : phase_timing_phase;
  duration_seconds : float;
}
(** One observed phase from a source-to-C compilation. These phases describe
    the current architectural boundaries without introducing another compiler
    pipeline or changing ownership. *)

(** Source compilation outcome. [Compiled] is the normal path; [Stopped_at]
    means a caller-supplied [on_stage] callback short-circuited the
    pipeline via [Core_pipeline.Stopped_after]. The pipeline boundary converts
    the exception to a tagged
    variant at the library boundary so callers pattern-match the
    full outcome space instead of handling an out-of-band exception. *)
type compile_outcome = Compiled of compile_result | Stopped_at of Core_stage.t

val typecheck_only_typed_reusing_session :
  sess:Session.t ->
  filename:string ->
  source:string ->
  ?debug:bool ->
  unit ->
  (Typed_ast.program, Ast.compiler_error list) result
(** Reuses [sess]'s validated parse cache across calls while resetting all
    semantic compilation state before each run. Intended for batch test/tool
    workers that typecheck many independent files in one process. *)

val typecheck_module_only :
  filename:string ->
  source:string ->
  (Typecheck.check_state * Ast.program, Ast.compiler_error list) result
(** Parse and type-check a module, returning the final state and AST
    compatibility view. Prefer [typecheck_module_only_typed] for new
    compiler callers and source-analysis tools. *)

val typecheck_module_only_typed :
  filename:string ->
  source:string ->
  (Typecheck.check_state * Typed_ast.program, Ast.compiler_error list) result
(** Parse and type-check a module, returning the final state and a validated
    typed program.

    This is still a direct-source module analysis path for tooling/package
    checks. It should be retired or given an explicit Blorp graph handoff once
    those callers move to the contiguous Blorp frontend. *)

val typecheck_source_package_module_only_typed :
  source_package:Session.source_package ->
  filename:string ->
  source:string ->
  (Typecheck.check_state * Typed_ast.program, Ast.compiler_error list) result
(** Parse and type-check a source-package module after registering the checked
    package in the fresh pipeline session. Package ownership is then available
    to module resolution and policy checks without relying on global state. *)

val check_modules :
  ?debug:bool -> ?allow_debug_only_calls:bool -> unit -> Ast.compiler_error list
(** Type-check all currently loaded modules in the active {!Session.t}, caching
    their typed declarations and import bindings. This is the dependency
    typecheck stage used before checking a target module. *)

val compile_legacy_direct_source :
  ?debug:bool ->
  ?allow_debug_only_calls:bool ->
  ?retain_debug_blocks:bool ->
  ?embed_runtime:bool ->
  ?require_main:bool ->
  ?profile:bool ->
  ?on_frontend_phase:(frontend_phase -> unit) ->
  ?on_stage:Core_pipeline.on_stage_callback ->
  ?on_stage_event:Core_pipeline.on_stage_event ->
  ?on_stage_json:Core_pipeline.on_stage_json_callback ->
  ?tail_observation_stages:Core_stage.t list ->
  ?check_invariants:bool ->
  filename:string ->
  source:string ->
  unit ->
  (compile_outcome, Ast.compiler_error list) result
(** Compile a source file through all phases. Returns a [compile_outcome]
    on success or a list of errors. Typical callers only care about the
    [Compiled] case; the [Stopped_at] case is returned when an
    [on_stage] callback raises [Core_pipeline.Stopped_after] (triggered by
    [--stop-after=STAGE] at the CLI).

    [allow_debug_only_calls] permits direct calls to functions explicitly
    declared [@debug_only]. When omitted, it follows [debug]. Test harness
    compilation passes [true] explicitly so reflection assertions remain
    test-only without depending on source-name heuristics.

    [retain_debug_blocks] keeps [debug:] block bodies in generated code.
    When omitted, it follows [debug]. Test harness compilation passes [true]
    explicitly so diagnostic assertions can execute under [blorp test] without
    turning on verbose compiler diagnostics.

    [on_stage] fires after every Core pipeline stage with the stage marker
    and the current [core_program]. Used by [--dump-core-after] to print
    intermediate IR and by [--stop-after] to terminate early. Callbacks
    that raise [Core_pipeline.Stopped_after] do not propagate the exception
    outward — this API catches it and returns [Ok (Stopped_at s)].

    [on_stage_event] fires after every Core pipeline stage with only the stage
    marker. Use it for timing or order observation that must not force Core
    program snapshots.

    [on_stage_json] fires for Blorp-owned late stages requested through
    [tail_observation_stages]. These observations are bridge JSON because OCaml
    no longer owns authoritative Core values after the pre-DCE handoff.

    [require_main] rejects user sources that do not declare a top-level
    [main] function before Core/codegen. It is intended for runnable entry
    points such as [blorp run]; analysis-only and C-emission callers can leave
    it disabled.

    [check_invariants] enables post-stage invariant checks defined in
    [Core_invariants]. If any check fires, compilation fails with a
    [Core_error]-tagged diagnostic. Off by default (the checks have
    non-trivial cost on large programs); enable it when debugging
    pipeline drift or before risky refactors.

    This direct-source API is a legacy/tooling route. Normal Blorp CLI source
    commands prepare Core entirely in Blorp and call the semantic-middle worker
    directly. Keep new source-command work off this entrypoint. *)

val compile_in_memory_source_with_blorp_bridge :
  ?debug:bool ->
  ?allow_debug_only_calls:bool ->
  ?retain_debug_blocks:bool ->
  ?embed_runtime:bool ->
  ?on_phase_timing:(phase_timing -> unit) ->
  filename:string ->
  source:string ->
  unit ->
  (compile_outcome, Ast.compiler_error list) result
(** Compile supplied user source through the Blorp-owned source and typecheck
    frontier. [filename] provides module/import identity, but the frontend uses
    [source] even when the file does not exist or has different contents.
    This is a compatibility entrypoint for the OCaml test runner; normal source
    commands compile through the contiguous Blorp pipeline. *)

val compile_generated_test_harness :
  ?debug:bool ->
  ?allow_debug_only_calls:bool ->
  ?retain_debug_blocks:bool ->
  ?embed_runtime:bool ->
  ?on_phase_timing:(phase_timing -> unit) ->
  filename:string ->
  source:string ->
  unit ->
  (compile_outcome, Ast.compiler_error list) result
(** Compile compiler-generated test scaffolding through the Blorp-owned source
    and typecheck frontier. The harness is not a user source file, so its
    synthetic imports are not subject to unused-import diagnostics. This
    compatibility entrypoint remains until generated TestSuite harness
    compilation moves into the Blorp-owned test command. *)
