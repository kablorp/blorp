(** Core IR compilation pipeline.

    Normal source commands enter [run_core_passes] through the strict
    prepared-Core semantic worker. Typed-program entrypoints are compatibility
    APIs for the pinned bootstrap and direct in-memory tests. *)

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

val make_stage_hook :
  check_invariants:bool -> user:on_stage_callback -> on_stage_callback
(** Compose a user callback with invariant checking. Exposed for focused tests
    of pipeline safety behavior; normal callers should pass [~on_stage] to the
    compile entrypoints. *)

type typed_module_input = {
  typed_module_name : string;
  typed_module_program : Typed_ast.program;
  typed_module_import_bindings : Session.import_binding list;
}
(** Compatibility typed-module input used outside the production source path. *)

type prepared_typed_program = {
  prepared_core : Core.core_program;
  prepared_registry : Codegen_types.registry;
  prepared_import_aliases : (string, string * string) Hashtbl.t;
  prepared_module_imports :
    (string, (string, string * string) Hashtbl.t) Hashtbl.t;
}

type backend_core_input = { blorp_tail_input : Core.core_program }
(** Core after the OCaml semantic-middle passes and before Blorp-owned DCE. *)

val prepare_typed_with_module_inputs :
  ?main_import_bindings:Session.import_binding list ->
  ?main_module_name:string ->
  modules:typed_module_input list ->
  Typed_ast.program ->
  prepared_typed_program
(** Compatibility lowering for pinned-bootstrap and in-memory OCaml callers. *)

val run_core_passes :
  ?import_aliases:(string, string * string) Hashtbl.t ->
  ?module_imports:(string, (string, string * string) Hashtbl.t) Hashtbl.t ->
  on_stage:on_stage_callback ->
  ?on_stage_event:on_stage_event ->
  reg:Codegen_types.registry ->
  ?debug:bool ->
  Core.core_program ->
  backend_core_input
(** Run the OCaml-owned semantic-middle pass sequence through specialization. *)

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
(** Compatibility typed single-file compilation; not the normal CLI route. *)

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
(** Compatibility typed graph compilation. Returns generated output, link
    flags, and include directories. *)
