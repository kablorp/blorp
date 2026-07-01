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

val frontend_phase_to_string : frontend_phase -> string
(** Stable display label for frontend timing output. *)

(** Outcome of [compile]. [Compiled] is the normal path; [Stopped_at]
    means a caller-supplied [on_stage] callback short-circuited the
    pipeline via [Core_pipeline.Stopped_after]. Previously [compile]
    re-raised the exception; Phase 0.5.2 converts it to a tagged
    variant at the library boundary so callers pattern-match the
    full outcome space instead of handling an out-of-band exception. *)
type compile_outcome = Compiled of compile_result | Stopped_at of Core_stage.t

val typecheck_only :
  filename:string ->
  source:string ->
  ?debug:bool ->
  unit ->
  (Ast.program, Ast.compiler_error list) result
(** Parse, load modules, and type-check only (no codegen). Returns the
    type-checked AST compatibility view or a list of errors. Prefer
    [typecheck_only_typed] for new compiler callers. *)

val typecheck_only_typed :
  filename:string ->
  source:string ->
  ?debug:bool ->
  unit ->
  (Typed_ast.program, Ast.compiler_error list) result
(** Parse, load modules, and type-check only (no codegen). Returns a
    validated typed program, so missing expression types and unfinalized
    inference metavariables are rejected at the typecheck boundary. *)

val typecheck_only_parsed :
  filename:string ->
  program:Ast.program ->
  ?debug:bool ->
  unit ->
  (Ast.program, Ast.compiler_error list) result
(** Load modules and type-check a program that has already passed through
    parser finalization. This is used by the Blorp-owned CLI/frontend bridge
    after OCaml restores comments, parses interpolations, and hoists nested
    declarations. Prefer [typecheck_only_typed_parsed] for new callers. *)

val typecheck_only_typed_parsed :
  filename:string ->
  program:Ast.program ->
  ?debug:bool ->
  unit ->
  (Typed_ast.program, Ast.compiler_error list) result
(** Typed-AST variant of [typecheck_only_parsed]. *)

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
    typed program. *)

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

val compile :
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
  ?program_observation:Core_pipeline.program_observation ->
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
    outward — [compile] catches it and returns [Ok (Stopped_at s)].

    [on_stage_event] fires after every Core pipeline stage with only the stage
    marker. Use it for timing or order observation that must not force Core
    program snapshots.

    [on_stage_json] fires for Blorp-owned late stages requested through
    [tail_observation_stages]. These observations are bridge JSON because OCaml
    no longer owns authoritative Core values after the post-Perceus handoff.

    [program_observation] controls how far [on_stage] receives Core program
    snapshots. The default preserves the legacy all-stage behavior. CLI paths
    that only need earlier stages can use
    [Core_pipeline.ObservePreBackendProgramStages] to avoid forcing the old
    OCaml final-tail snapshot.

    [require_main] rejects user sources that do not declare a top-level
    [main] function before Core/codegen. It is intended for runnable entry
    points such as [blorp run]; analysis-only and C-emission callers can leave
    it disabled.

    [check_invariants] enables post-stage invariant checks defined in
    [Core_invariants]. If any check fires, compilation fails with a
    [Core_error]-tagged diagnostic. Off by default (the checks have
    non-trivial cost on large programs); enable it when debugging
    pipeline drift or before risky refactors. *)

val compile_parsed :
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
  ?program_observation:Core_pipeline.program_observation ->
  ?check_invariants:bool ->
  filename:string ->
  program:Ast.program ->
  unit ->
  (compile_outcome, Ast.compiler_error list) result
(** Compile a program that has already passed through parser finalization.
    This follows the same module-load, typecheck, and Core/codegen path as
    [compile]; only the initial source read and parse are supplied by the
    caller. *)

val compile_generated_test_harness :
  ?debug:bool ->
  ?allow_debug_only_calls:bool ->
  ?retain_debug_blocks:bool ->
  ?embed_runtime:bool ->
  filename:string ->
  source:string ->
  unit ->
  (compile_outcome, Ast.compiler_error list) result
(** Compile compiler-generated test scaffolding. The harness is not a user
    source file, so its synthetic imports are not subject to unused-import
    diagnostics; any user modules loaded by the harness are still checked
    normally. *)
