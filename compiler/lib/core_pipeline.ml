(** Remaining OCaml Core semantic-middle pipeline.

    Normal source compilation arrives as post-match Core produced by the
    Blorp frontend. This module owns the contiguous OCaml middle from trait
    resolution through specialization; Blorp takes ownership again at the
    pre-DCE boundary.

    The remaining pass chain is:
    1. [Core_trait_resolve] — rewrite trait methods/operators to impl calls
    2. [Core_resolve] — classify calls by callee kind
    3. [Core_std_inline] — expand compiler-owned std wrappers
    4. [Core_tailrec] — make tail-recursive self-loops explicit
    5. collection, string, tensor, and tuple pipeline rewrites
    6. [Core_specialize] — resolve type-dispatched builtins
    7. pre-DCE Core handoff to the Blorp backend

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

(** Monomorphization retains generic templates as worklist inputs. The
    semantic middle needs only the concrete runtime program. [Option] and
    [Result] remain because their erased payload layouts are runtime ABI. *)
let project_semantic_middle_program (program : Core.core_program) :
    Core.core_program =
  let is_runtime_abi_union (type_decl : Ast.type_decl) =
    type_decl.type_params <> []
    && (String.equal type_decl.type_name "Option"
       || String.equal type_decl.type_name "Result")
  in
  let impl_is_generic (impl : Core.core_impl) =
    Codegen_types.has_type_vars impl.ci_for_type
    || List.exists
         (fun (method_func : Core.core_func) ->
           method_func.cf_type_params <> [])
         impl.ci_methods
  in
  let rec project_decl (decl : Core.core_decl) =
    match decl.cd_desc with
    | Core.CDFunc func when func.cf_type_params <> [] -> None
    | Core.CDType type_decl
      when type_decl.type_params <> [] && not (is_runtime_abi_union type_decl) ->
        None
    | Core.CDRecord record_decl when record_decl.record_type_params <> [] -> None
    | Core.CDImpl impl when impl_is_generic impl -> None
    | Core.CDPrivate inner ->
        Option.map
          (fun projected -> { decl with cd_desc = Core.CDPrivate projected })
          (project_decl inner)
    | _ -> Some decl
  in
  List.filter_map project_decl program

(** Run the production OCaml middle from Blorp-owned post-match Core to
    the pre-DCE backend handoff. *)
let run_core_passes_from_post_match ?(import_aliases = Hashtbl.create 0)
    ?(module_imports = Hashtbl.create 0) ~(on_stage : on_stage_callback)
    ?(on_stage_event = no_op_on_stage_event) ~(reg : Codegen_types.registry)
    (prog : Core.core_program) : backend_core_input =
  let prog = project_semantic_middle_program prog in
  let observe stage prog =
    on_stage_event stage;
    on_stage stage prog;
    prog
  in
  let run_stage stage pass prog = pass prog |> observe stage in
  let pre_dce =
    prog |> run_stage Core_stage.TraitResolve
         (Core_trait_resolve.resolve_program ~import_aliases ~module_imports)
    |> run_stage Core_stage.Resolve
         (Core_resolve.resolve_program ~import_aliases ~module_imports)
    |> run_stage Core_stage.StdInline Core_std_inline.rewrite_program
    |> run_stage Core_stage.Tailrec (Core_tailrec.lower_program ~reg)
    |> run_stage Core_stage.Fusion (fun p ->
        p
        |> Core_string_pipeline.fuse_program ~reg
        |> Core_collection_pipeline.fuse_program ~reg
        |> Core_parallel_tensor_pipeline.fuse_program
        |> Core_tensor_fusion.fuse_program ~reg
        |> Core_tuple_sroa.rewrite_program ~reg)
    |> run_stage Core_stage.Specialize (Core_specialize.specialize_program ~reg)
  in
  { blorp_tail_input = pre_dce }
