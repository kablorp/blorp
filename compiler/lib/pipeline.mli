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

val compile_preloaded_graph_with_blorp_bridge :
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
  ?on_phase_timing:(phase_timing -> unit) ->
  filename:string ->
  preloaded_module_graph:Modules.preloaded_module_graph ->
  unit ->
  (compile_outcome, Ast.compiler_error list) result
(** Compatibility compilation through a Blorp frontend graph followed by
    OCaml typed-AST lowering. Only the pinned-bootstrap wrapper uses this path;
    installed CLI commands and test/REPL synthetic sources do not. *)
