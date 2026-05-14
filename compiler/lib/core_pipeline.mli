(** Core IR compilation pipeline.

    This module is the boundary between typed AST and the Core/backend
    pipeline. Callers must validate through [Typed_ast] before entering this
    module. *)

exception Stopped_after of Core_stage.t
(** Raised by an [on_stage_callback] to stop compilation after a stage. *)

type on_stage_callback = Core_stage.t -> Core.core_program -> unit
(** Callback fired after each observed Core pipeline stage. *)

val observed_stage_order : Core_stage.t list
(** Stages observed by [on_stage_callback], including [Lower] and [Final]. *)

val make_stage_hook :
  check_invariants:bool -> user:on_stage_callback -> on_stage_callback
(** Compose a user callback with invariant checking. Exposed for focused tests
    of pipeline safety behavior; normal callers should pass [~on_stage] to the
    compile entrypoints. *)

val compile_typed :
  ?embed_runtime:bool ->
  ?profile:bool ->
  ?debug:bool ->
  ?on_stage:on_stage_callback ->
  ?check_invariants:bool ->
  ?backend:(module Backend.S) ->
  Typed_ast.program ->
  string
(** Compile a typed single-file program to backend output. *)

val compile_typed_with_modules :
  ?main_import_bindings:Session.import_binding list ->
  ?embed_runtime:bool ->
  ?profile:bool ->
  ?debug:bool ->
  ?on_stage:on_stage_callback ->
  ?check_invariants:bool ->
  ?backend:(module Backend.S) ->
  Typed_ast.program ->
  string * string list * string list
(** Compile a typed main program plus loaded typed modules. Returns generated
    output, link flags, and include directories. *)
