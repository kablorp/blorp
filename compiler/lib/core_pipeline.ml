(** Remaining OCaml Core semantic-middle pipeline.

    Normal source compilation arrives after Blorp-owned string fusion. This
    module owns the remaining OCaml fusion subpasses and specialization; Blorp
    takes ownership again at the pre-DCE boundary.

    The remaining pass chain is:
    1. collection, scoped-tensor, tensor-update, and tuple pipeline rewrites
    2. [Core_specialize] — resolve type-dispatched builtins
    3. pre-DCE Core handoff to the Blorp backend

    There is deliberately no typed-AST or prepared-Core compatibility
    entrypoint here. Early Core stages are production Blorp code and are tested
    through that implementation. *)

type on_stage_callback = Core_stage.t -> Core.core_program -> unit
(** Callback fired after each OCaml-owned program-bearing Core stage. *)

type on_stage_event = Core_stage.t -> unit
(** Lightweight stage callback for timing/order consumers. *)

let no_op_on_stage_event : on_stage_event = fun _ -> ()

(** Critical safety checks that should never reach emission, even when broad
    development invariant checking is disabled. *)
let critical_invariant_violations stage prog =
  match stage with
  | Core_stage.Final -> Core_invariants.run_for_stage stage prog
  | _ -> []

let invariant_violations ~check_invariants stage prog =
  if check_invariants then Core_invariants.run_for_stage stage prog
  else critical_invariant_violations stage prog

let fire_stage ~(check_invariants : bool) ~(user : on_stage_callback)
    (stage : Core_stage.t) (prog : Core.core_program) : unit =
  match invariant_violations ~check_invariants stage prog with
  | [] -> user stage prog
  | violation :: _ -> raise (Core_error.Core_error violation)

(** Compose a stage observer with invariant checking. Checks run before the
    observer so stop-after behavior cannot mask a stage violation. *)
let make_stage_hook ~(check_invariants : bool) ~(user : on_stage_callback) :
    on_stage_callback =
 fun stage prog -> fire_stage ~check_invariants ~user stage prog

type backend_core_input = {
  blorp_tail_input : Core.core_program;
      (** Pre-DCE Core handed to the Blorp-owned backend tail. *)
}

(** Run the production OCaml middle from Blorp-owned post-string-fusion Core to
    the pre-DCE backend handoff. *)
let run_core_passes_from_post_string_fusion ~(on_stage : on_stage_callback)
    ?(on_stage_event = no_op_on_stage_event) ~(reg : Codegen_types.registry)
    (prog : Core.core_program) : backend_core_input =
  let observe stage prog =
    on_stage_event stage;
    on_stage stage prog;
    prog
  in
  let run_stage stage pass prog = pass prog |> observe stage in
  let pre_dce =
    prog |> run_stage Core_stage.Fusion (fun p ->
        p
        |> Core_collection_pipeline.fuse_program ~reg
        |> Core_parallel_tensor_pipeline.fuse_program
        |> Core_tensor_fusion.fuse_program ~reg
        |> Core_tuple_sroa.rewrite_program ~reg)
    |> run_stage Core_stage.Specialize (Core_specialize.specialize_program ~reg)
  in
  { blorp_tail_input = pre_dce }
