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

val typecheck_module_only :
  filename:string ->
  source:string ->
  (Typecheck.check_state * Ast.program, Ast.compiler_error list) result
(** Parse and type-check a module, returning the final state and AST
    compatibility view. Used for analysis tools like 'purify'. Prefer
    [typecheck_module_only_typed] for new compiler callers. *)

val typecheck_module_only_typed :
  filename:string ->
  source:string ->
  (Typecheck.check_state * Typed_ast.program, Ast.compiler_error list) result
(** Parse and type-check a module, returning the final state and a validated
    typed program. *)

val compile :
  ?debug:bool ->
  ?allow_debug_only_calls:bool ->
  ?retain_debug_blocks:bool ->
  ?embed_runtime:bool ->
  ?profile:bool ->
  ?on_frontend_phase:(frontend_phase -> unit) ->
  ?on_stage:Core_pipeline.on_stage_callback ->
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

    [check_invariants] enables post-stage invariant checks defined in
    [Core_invariants]. If any check fires, compilation fails with a
    [Core_error]-tagged diagnostic. Off by default (the checks have
    non-trivial cost on large programs); enable it when debugging
    pipeline drift or before risky refactors. *)

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
