(** OCaml compatibility analysis pipeline for Blorp.

    Owns the remaining parse, module-load, and typecheck entrypoints used by
    compiler tooling. Production source compilation is Blorp-owned.

    Callers are responsible for:
    - Reading the source file
    - Calling {!Modules.init_module_paths} / {!Modules.reset} as needed
    - Formatting and reporting the returned errors *)

val typecheck_only_typed_reusing_session :
  sess:Session.t ->
  filename:string ->
  source:string ->
  ?debug:bool ->
  unit ->
  (Typed_ast.program, Ast.compiler_error list) result
(** Transitional compatibility entry point for compiler surface fixtures that
    have not yet migrated to the Blorp frontend. Reuses validated parse entries
    while resetting semantic state between independent files. *)

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
