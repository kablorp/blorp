(** Core IR compilation pipeline.

    This module is the boundary between typed AST and the Core/backend
    pipeline. Callers must validate through [Typed_ast] before entering this
    module. *)

exception Stopped_after of Core_stage.t
(** Raised by an [on_stage_callback] to stop compilation after a stage. *)

type on_stage_callback = Core_stage.t -> Core.core_program -> unit
(** Callback fired after each OCaml-owned program-bearing Core pipeline stage. *)

type on_stage_event = Core_stage.t -> unit
(** Lightweight callback fired after each observed Core pipeline stage without
    materializing a Core program for consumers that only need timing/order. *)

type on_stage_json_callback = Core_stage.t -> string -> unit
(** Callback fired for Blorp-owned stages whose authoritative observation is
    bridge JSON rather than an OCaml [Core.core_program]. *)

val observed_stage_order : Core_stage.t list
(** Source stage order, including Blorp-owned stages that require JSON
    observation rather than OCaml [Core.core_program] callbacks. *)

val pre_backend_program_stage_order : Core_stage.t list
(** Program-bearing stages available as OCaml [Core.core_program] callbacks. *)

val program_free_stage_event_order : Core_stage.t list
(** Stages observed by event-only callbacks. The Blorp-owned backend tail is
    reported as [Final] unless a caller explicitly requests tail JSON. *)

val stage_observed_via_blorp_tail_json : Core_stage.t -> bool
(** Whether observing this stage requires the Blorp-owned tail JSON path rather
    than an OCaml program callback. *)

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
  ?on_stage_event:on_stage_event ->
  ?on_stage_json:on_stage_json_callback ->
  ?tail_observation_stages:Core_stage.t list ->
  ?check_invariants:bool ->
  Typed_ast.program ->
  string
(** Compile a typed single-file program to backend output. *)

val compile_typed_with_modules :
  ?main_import_bindings:Session.import_binding list ->
  ?embed_runtime:bool ->
  ?profile:bool ->
  ?debug:bool ->
  ?on_stage:on_stage_callback ->
  ?on_stage_event:on_stage_event ->
  ?on_stage_json:on_stage_json_callback ->
  ?tail_observation_stages:Core_stage.t list ->
  ?check_invariants:bool ->
  Typed_ast.program ->
  string * string list * string list
(** Compile a typed main program plus loaded typed modules. Returns generated
    output, link flags, and include directories. *)
