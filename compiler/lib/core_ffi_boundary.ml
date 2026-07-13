(** Attach checked FFI boundary policies to Core foreign declarations.

    Lowering initially knows only whether a foreign declaration is default-copy
    mode or explicit borrow mode. Once the per-program type registry is seeded,
    this pass classifies each default-mode parameter exactly once and records the
    concrete policy in Core. Later phases, especially call resolution and C
    emission, consume that checked policy instead of re-inferring from raw
    types. *)

open Core

let phase = Core_error.Stage Core_stage.Lower

let copy_kind_to_core = function
  | Ffi_boundary.StringCopy -> ForeignStringCopy
  | Ffi_boundary.BytesCopy -> ForeignBytesCopy

let internal_borrow_policy_error param =
  Core_error.errorf phase param.cp_loc
    ~hint:"default foreign boundary classification should not produce borrow"
    "internal error: explicit FFI borrow policy reached default boundary \
     annotation"

let rejected_default_arg_error param reason =
  Core_error.errorf phase param.cp_loc
    ~hint:
      "typecheck should reject default foreign arguments that cannot be \
       defensively copied; use @no_copy only for explicit read-only borrows"
    "default foreign parameter '%s' has no safe boundary policy (%s)"
    (Var.to_string param.cp_name)
    (Ffi_boundary.rejected_default_reason_to_string reason)

let classify_default_arg ~metadata (param : core_param) =
  match
    Ffi_boundary.classify_arg ~metadata ~mode:Ffi_boundary.DefaultCopyMode
      param.cp_ty
  with
  | Ffi_boundary.ScalarByValue -> ForeignScalarByValue
  | Ffi_boundary.DefensiveCopy spec ->
      ForeignDefensiveCopy (copy_kind_to_core spec.copy_kind)
  | Ffi_boundary.ExplicitBorrow -> internal_borrow_policy_error param
  | Ffi_boundary.RejectedDefault reason ->
      rejected_default_arg_error param reason

let classify_default_args ~metadata params =
  List.map (classify_default_arg ~metadata) params

let annotate_func_kind ~metadata params = function
  | CFForeign ({ arg_passing = ForeignDefaultArgs _; _ } as foreign) ->
      let policies = classify_default_args ~metadata params in
      CFForeign { foreign with arg_passing = ForeignDefaultArgs policies }
  | CFForeign ({ arg_passing = ForeignBorrowArgs; _ } as foreign) ->
      CFForeign foreign
  | (CFUser | CFBuiltin | CFClosureBody _) as kind -> kind

let annotate_func ~metadata (f : core_func) =
  { f with cf_kind = annotate_func_kind ~metadata f.cf_params f.cf_kind }

let rec annotate_decl ~metadata (d : core_decl) =
  match d.cd_desc with
  | CDFunc f -> { d with cd_desc = CDFunc (annotate_func ~metadata f) }
  | CDPrivate inner ->
      { d with cd_desc = CDPrivate (annotate_decl ~metadata inner) }
  | _ -> d

let annotate_program ~(reg : Codegen_types.registry) (prog : core_program) :
    core_program =
  let metadata = Core_type_layout.metadata_for_registry reg in
  List.map (annotate_decl ~metadata) prog
