(** Remaining OCaml Core semantic-middle pipeline. *)

type on_stage_callback = Core_stage.t -> Core.core_program -> unit
(** Callback fired after each OCaml-owned program-bearing Core stage. *)

type on_stage_event = Core_stage.t -> unit
(** Lightweight callback fired without materializing another Core program. *)

val make_stage_hook :
  check_invariants:bool -> user:on_stage_callback -> on_stage_callback
(** Compose a stage observer with invariant checking. *)

type backend_core_input = { blorp_tail_input : Core.core_program }
(** Core after the OCaml semantic middle and before Blorp-owned DCE. *)

val run_core_passes_from_post_match :
  ?import_aliases:(string, string * string) Hashtbl.t ->
  ?module_imports:(string, (string, string * string) Hashtbl.t) Hashtbl.t ->
  on_stage:on_stage_callback ->
  ?on_stage_event:on_stage_event ->
  reg:Codegen_types.registry ->
  Core.core_program ->
  backend_core_input
(** Run production post-match Core through specialization. *)
