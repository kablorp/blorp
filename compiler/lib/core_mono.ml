(** Monomorphization pass for Core IR.

    Scans calls to generic functions, computes type substitutions,
    generates specialized copies with concrete types, and rewrites
    call sites to mangled names. Runs before C emission.

    {1 Algorithm}

    1. Collect generic function bodies from the program.
    2. Walk all expressions to find calls to generic functions.
    3. For each call: unify param types vs arg types → substitution.
    4. Mangle name, enqueue if new, drain worklist to fixpoint.
    5. Rewrite call sites to use mangled names.
    6. Append specialized functions to the program. *)

open Core

(* ============================================================================
   Type substitution
   ============================================================================ *)

let type_param_name = Env.type_param_name
let type_param_decl_names = Ast.type_param_names

type subst_value =
  | SubstType of Ast.type_expr
  | SubstDimPack of Ast.type_expr list

type mono_subst = (string * subst_value) list

let rec erase_value_refinements_for_mono (ty : Ast.type_expr) : Ast.type_expr =
  if Types.Dim.is_value_dim ty then Ast.TyNamed ("Int", [])
  else
    match ty with
    | Ast.TyArray (elem, dims) ->
        (* Array dimensions are type-level evidence and must remain concrete;
           only the value element type erases refinements for C mono. *)
        Ast.TyArray (erase_value_refinements_for_mono elem, dims)
    | Ast.TyNamed ((("Tensor" | "Vector" | "Matrix") as name), elem :: dims) ->
        Ast.TyNamed (name, erase_value_refinements_for_mono elem :: dims)
    | Ast.TyNamed (name, args) ->
        Ast.TyNamed (name, List.map erase_value_refinements_for_mono args)
    | Ast.TyTuple elems ->
        Ast.TyTuple (List.map erase_value_refinements_for_mono elems)
    | Ast.TyFunc f ->
        Ast.TyFunc
          {
            f with
            params = List.map erase_value_refinements_for_mono f.params;
            return = erase_value_refinements_for_mono f.return;
          }
    | Ast.TyRange _ -> Ast.TyNamed ("Int", [])
    | Ast.TyDimOp _ | Ast.TyConstInt _ -> Ast.TyNamed ("Int", [])
    | _ -> ty

let mono_subst_binding (name : string) (ty : Ast.type_expr) :
    string * subst_value =
  let name = type_param_name name in
  let ty =
    if Types.Dim.is_var_name name then ty
    else erase_value_refinements_for_mono ty
  in
  (name, SubstType ty)

let rec has_dim_evidence_for_mono (ty : Ast.type_expr) : bool =
  match ty with
  | Ast.TyConstInt _ | Ast.TyDimOp _ -> true
  | Ast.TyVar name | Ast.TyNamed (name, []) -> Types.Dim.is_var_name name
  | Ast.TyTuple dims -> List.for_all has_dim_evidence_for_mono dims
  | _ -> false

let mono_subst_binding_opt (name : string) (ty : Ast.type_expr) :
    (string * subst_value) option =
  let name = type_param_name name in
  let ty = Codegen_types.normalize_type ty in
  let is_identity_binding =
    match ty with
    | Ast.TyVar ty_name -> type_param_name ty_name = name
    | Ast.TySelf -> name = "Self"
    | _ -> false
  in
  if is_identity_binding then None
  else if Types.Dim.is_var_name name && not (has_dim_evidence_for_mono ty) then
    None
  else Some (mono_subst_binding name ty)

let mono_dim_pack_binding_opt (name : string) (dims : Ast.type_expr list) :
    (string * subst_value) option =
  let name = type_param_name name in
  if name = "#_" || not (Types.Dim.is_var_name name) then None
  else
    let dims = List.map Codegen_types.normalize_type dims in
    if List.for_all has_dim_evidence_for_mono dims then
      Some (name, SubstDimPack dims)
    else None

let rec collect_subst ~(reg : Codegen_types.registry)
    (type_params : Ast.type_param_decl list) (param_ty : Ast.type_expr)
    (arg_ty : Ast.type_expr) (acc : mono_subst) : mono_subst =
  let type_param_names = type_param_decl_names type_params in
  (* Expand type aliases on both sides before matching. Otherwise a param
     signature using an alias (e.g. [Decoder[T] = pure (Value) -> Result[T,_]])
     can't be unified against a concrete call-site arg whose type already
     resolves through the alias. *)
  let param_ty =
    Codegen_types.normalize_type (Codegen_types.expand_alias ~reg param_ty)
  in
  let arg_ty =
    Codegen_types.normalize_type (Codegen_types.expand_alias ~reg arg_ty)
  in
  match (param_ty, arg_ty) with
  | Ast.TyVar name, _ when List.mem (type_param_name name) type_param_names -> (
      match mono_subst_binding_opt name arg_ty with
      | Some binding -> binding :: acc
      | None -> acc)
  | Ast.TyBoundVar param, _ when List.mem param.param_name type_param_names -> (
      match mono_subst_binding_opt param.param_name arg_ty with
      | Some binding -> binding :: acc
      | None -> acc)
  | Ast.TySelf, _ when List.mem "Self" type_param_names -> (
      match mono_subst_binding_opt "Self" arg_ty with
      | Some binding -> binding :: acc
      | None -> acc)
  | Ast.TyNamed (pn, p_args), Ast.TyNamed (an, a_args)
    when pn = an ->
      (* Walk positional args, consuming the arg tail at a trailing
         [TyVarDims] to mirror [Types.go_args]. Without the [TyVarDims]
         consumption, a param like [T[#_...]] against an arg
         [Int[#2, #3]] fails length-match and leaves [T]
         unsubstituted — the call site stays generic, the prefixed
         name never gets monomorphized, and emission produces a call
         to an undeclared [std_<mod>__<name>] symbol. *)
      let rec walk_args a p_args a_args =
        match (p_args, a_args) with
        | [], _ -> a
        | [ Ast.TyVarDims name ], rest ->
            (match mono_dim_pack_binding_opt name rest with
            | Some binding -> binding :: a
            | None -> a)
        | p :: prest, ar :: arest ->
            walk_args (collect_subst ~reg type_params p ar a) prest arest
        | _ :: _, [] -> a
      in
      walk_args acc p_args a_args
  | Ast.TyArray (p_elem, p_dims), Ast.TyArray (a_elem, a_dims) ->
      let rec walk_args a p_args a_args =
        match (p_args, a_args) with
        | [], _ -> a
        | [ Ast.TyVarDims name ], rest ->
            (match mono_dim_pack_binding_opt name rest with
            | Some binding -> binding :: a
            | None -> a)
        | p :: prest, ar :: arest ->
            walk_args (collect_subst ~reg type_params p ar a) prest arest
        | _ :: _, [] -> a
      in
      walk_args acc (p_elem :: p_dims) (a_elem :: a_dims)
  | Ast.TyTuple ps, Ast.TyTuple ars -> (
      try
        List.fold_left2
          (fun a p r -> collect_subst ~reg type_params p r a)
          acc ps ars
      with Invalid_argument _ -> acc)
  | Ast.TyFunc pf, Ast.TyFunc af ->
      let acc =
        try
          List.fold_left2
            (fun a p r -> collect_subst ~reg type_params p r a)
            acc pf.params af.params
        with Invalid_argument _ -> acc
      in
      collect_subst ~reg type_params pf.return af.return acc
  | _ -> acc

(** Check if a substitution is concrete — all mapped types are fully resolved. *)
let is_concrete_subst (subst : mono_subst) : bool =
  let rec has_tyvars ty =
    match ty with
    | Ast.TyVar _ -> true
    | Ast.TyBoundVar _ -> true
    | Ast.TySelf -> true
    | Ast.TyMeta _ -> true
    | Ast.TyVarDims _ -> true
    | Ast.TyNamed (_, args) -> List.exists has_tyvars args
    | Ast.TyArray (elem, dims) -> has_tyvars elem || List.exists has_tyvars dims
    | Ast.TyTuple ts -> List.exists has_tyvars ts
    | Ast.TyFunc f -> List.exists has_tyvars f.params || has_tyvars f.return
    | Ast.TyRange t -> has_tyvars t
    | _ -> false
  in
  List.for_all
    (fun (_, value) ->
      match value with
      | SubstType ty -> not (has_tyvars ty)
      | SubstDimPack dims -> List.for_all (fun ty -> not (has_tyvars ty)) dims)
    subst

let rec has_rigid_type_vars (ty : Ast.type_expr) : bool =
  match ty with
  | Ast.TyVar _ -> true
  | Ast.TyBoundVar _ -> true
  | Ast.TySelf -> true
  | Ast.TyVarDims _ -> true
  | Ast.TyNamed (_, args) -> List.exists has_rigid_type_vars args
  | Ast.TyArray (elem, dims) ->
      has_rigid_type_vars elem || List.exists has_rigid_type_vars dims
  | Ast.TyTuple ts -> List.exists has_rigid_type_vars ts
  | Ast.TyFunc f ->
      List.exists has_rigid_type_vars f.params || has_rigid_type_vars f.return
  | Ast.TyRange t -> has_rigid_type_vars t
  | Ast.TyDimOp (_, a, b) -> has_rigid_type_vars a || has_rigid_type_vars b
  | _ -> false

let is_refinable_meta_type (ty : Ast.type_expr) : bool =
  Codegen_types.has_type_vars ty && not (has_rigid_type_vars ty)

let normalize_subst_value = function
  | SubstType ty -> SubstType (Codegen_types.normalize_type ty)
  | SubstDimPack dims ->
      SubstDimPack (List.map Codegen_types.normalize_type dims)

let subst_values_equal a b =
  match (a, b) with
  | SubstType a, SubstType b -> Types.types_equal a b
  | SubstDimPack a, SubstDimPack b ->
      List.length a = List.length b && List.for_all2 Types.types_equal a b
  | _ -> false

let dedup_subst_consistent (raw : mono_subst) : mono_subst option =
  let groups = Hashtbl.create 8 in
  let ok = ref true in
  List.iter
    (fun (name, value) ->
      let normalized =
        match value with
        | SubstType ty -> mono_subst_binding_opt name ty
        | SubstDimPack dims -> mono_dim_pack_binding_opt name dims
      in
      match normalized with
      | None -> ()
      | Some (name, value) -> (
          let value = normalize_subst_value value in
          match Hashtbl.find_opt groups name with
          | None -> Hashtbl.replace groups name value
          | Some existing -> (
              if subst_values_equal existing value then ()
              else
                match (existing, value) with
                | SubstType existing, SubstType ty -> (
                    let existing_closed =
                      not (Codegen_types.has_type_vars existing)
                    in
                    let ty_closed = not (Codegen_types.has_type_vars ty) in
                    let existing_meta = is_refinable_meta_type existing in
                    let ty_meta = is_refinable_meta_type ty in
                    (* Rigid outer type vars are not refinable here: keep the
                       substitution open so a later outer specialization can retry. *)
                    match
                      (existing_closed, ty_closed, existing_meta, ty_meta)
                    with
                    | true, true, _, _ -> ok := false
                    | _, false, _, false ->
                        Hashtbl.replace groups name (SubstType ty)
                    | false, _, false, _ -> ()
                    | false, true, true, _ ->
                        Hashtbl.replace groups name (SubstType ty)
                    | true, false, _, true -> ()
                    | false, false, true, true -> ())
                | _ -> ok := false)))
    raw;
  if not !ok then None
  else
    Some
      (Hashtbl.fold (fun k v acc -> (k, v) :: acc) groups []
      |> List.sort (fun (a, _) (b, _) -> String.compare a b))

let rec apply_subst (subst : mono_subst) (ty : Ast.type_expr) : Ast.type_expr =
  let lookup name =
    match List.assoc_opt name subst with
    | Some t -> Some t
    | None -> List.assoc_opt (type_param_name name) subst
  in
  let lookup_type name =
    match lookup name with Some (SubstType t) -> Some t | _ -> None
  in
  let apply_args args =
    List.concat_map
      (fun arg ->
        match arg with
        | Ast.TyVarDims name -> (
            match lookup name with
            | Some (SubstDimPack dims) -> List.map (apply_subst subst) dims
            | Some (SubstType ty) -> [ apply_subst subst ty ]
            | None -> [ arg ])
        | _ -> [ apply_subst subst arg ])
      args
  in
  match ty with
  | Ast.TyVar name -> ( match lookup_type name with Some t -> t | None -> ty)
  | Ast.TyBoundVar param -> (
      match lookup_type param.param_name with Some t -> t | None -> ty)
  | Ast.TySelf -> ( match lookup_type "Self" with Some t -> t | None -> ty)
  | Ast.TyNamed (name, args) -> Ast.TyNamed (name, apply_args args)
  | Ast.TyArray (elem, dims) ->
      Types.ty_array (apply_subst subst elem) (apply_args dims)
  | Ast.TyTuple ts -> Ast.TyTuple (List.map (apply_subst subst) ts)
  | Ast.TyFunc f ->
      Ast.TyFunc
        {
          f with
          params = List.map (apply_subst subst) f.params;
          return = apply_subst subst f.return;
        }
  | Ast.TyRange t -> Ast.TyRange (apply_subst subst t)
  | Ast.TyDimOp (op, a, b) ->
      Ast.TyDimOp (op, apply_subst subst a, apply_subst subst b)
  | _ -> ty

(** A specialization must close its own callable contract. Its body can still
    contain generic function-reference types; those calls are specialized when
    [rewrite_func] visits them and are not parameters of [func]. Existential
    tensor dimensions that are not declared by the function, such as [#Ds...]
    in a shape-erasing return type, remain valid runtime shape information. *)
let subst_closes_function_signature (func : core_func) (subst : mono_subst) :
    bool =
  let apply = apply_subst subst in
  let declared = type_param_decl_names func.cf_type_params in
  let is_declared name = List.mem (type_param_name name) declared in
  let rec type_is_closed = function
    | Ast.TyVar name | Ast.TyNamed (name, []) -> not (is_declared name)
    | Ast.TyBoundVar param -> not (is_declared param.param_name)
    | Ast.TyMeta _ -> false
    | Ast.TyVarDims name -> not (is_declared name)
    | Ast.TyNamed (_, args) -> List.for_all type_is_closed args
    | Ast.TyArray (elem, dims) ->
        type_is_closed elem && List.for_all type_is_closed dims
    | Ast.TyTuple elems -> List.for_all type_is_closed elems
    | Ast.TyFunc f ->
        List.for_all type_is_closed f.params && type_is_closed f.return
    | Ast.TyRange inner -> type_is_closed inner
    | Ast.TyDimOp (_, a, b) -> type_is_closed a && type_is_closed b
    | Ast.TySelf -> not (List.mem "Self" declared)
    | Ast.TyConstInt _ -> true
  in
  let substituted_type_is_closed ty = type_is_closed (apply ty) in
  List.for_all
    (fun (param : core_param) -> substituted_type_is_closed param.cp_ty)
    func.cf_params
  && substituted_type_is_closed func.cf_return_ty

(* ============================================================================
   Name mangling
   ============================================================================ *)

let rec encode_type (ty : Ast.type_expr) : string option =
  match Codegen_types.normalize_type ty with
  | Ast.TyNamed (n, []) -> Some n
  | Ast.TyNamed (n, args) ->
      let enc = List.filter_map encode_type args in
      if List.length enc = List.length args then
        Some (String.concat "_" (n :: enc))
      else None
  | Ast.TyArray (elem, dims) -> (
      let enc_dims = List.filter_map encode_type dims in
      match encode_type elem with
      | Some enc_elem when List.length enc_dims = List.length dims ->
          Some ("Array_" ^ String.concat "_" (enc_elem :: enc_dims))
      | _ -> None)
  | Ast.TyTuple ts ->
      let enc = List.filter_map encode_type ts in
      if List.length enc = List.length ts then
        Some ("Tuple_" ^ String.concat "_" enc)
      else None
  | Ast.TyFunc { params; return; is_pure } -> (
      let enc_p = List.filter_map encode_type params in
      match encode_type return with
      | Some enc_r when List.length enc_p = List.length params ->
          Some
            (Printf.sprintf "%sFn_%s_%s"
               (if is_pure then "P" else "")
               (String.concat "_" enc_p) enc_r)
      | _ -> None)
  | Ast.TyConstInt n -> Some (string_of_int n)
  | Ast.TyDimOp (op, a, b) -> (
      (* Fold [TyDimOp] with concrete integer operands into a single
         [TyConstInt] so specializations like [Float[#N * #4]]
         with a concrete outer [#N] mangle to one integer instead of
         failing encoding. [Types.Dim.reduce] is the canonical solver;
         if it returns a [TyConstInt] we emit it, otherwise fall
         through to a compound encoding so unresolved dim vars still
         produce distinct mangled names.

         A4-era lesson: before this fix, compound dim types produced
         [None] here → [try_enqueue] returned [None] → scan_and_rewrite
         left the call unrewritten → post-mono [check_unrewritten_generic_calls]
         raised on the last call found bottom-up in the body. *)
      match Types.Dim.normalize ty with
      | Ast.TyConstInt n -> Some (string_of_int n)
      | _ -> (
          match (encode_type a, encode_type b) with
          | Some ea, Some eb ->
              let op_str =
                match op with
                | Ast.DimAdd -> "Add"
                | Ast.DimSub -> "Sub"
                | Ast.DimMul -> "Mul"
                | Ast.DimDiv -> "Div"
              in
              Some (Printf.sprintf "DimOp%s_%s_%s" op_str ea eb)
          | _ -> None))
  | _ -> None

let encode_subst_value = function
  | SubstType ty -> encode_type ty
  | SubstDimPack [] -> Some "Dims0"
  | SubstDimPack dims ->
      let enc = List.filter_map encode_type dims in
      if List.length enc = List.length dims then
        Some ("Dims_" ^ String.concat "_" enc)
      else None

let mangle_name (func_name : string) (subst : mono_subst) : string option =
  let sorted = List.sort (fun (a, _) (b, _) -> String.compare a b) subst in
  let encoded =
    List.filter_map (fun (_, value) -> encode_subst_value value) sorted
  in
  if List.length encoded = List.length sorted then
    Some (func_name ^ "__mono_" ^ String.concat "_" encoded)
  else None

let generic_data_mono_separator = "__mono_"

let concrete_generic_data_name (source_name : string)
    (args : Ast.type_expr list) : string option =
  let encoded = List.filter_map encode_type args in
  if List.length encoded = List.length args then
    Some
      (Codegen_names.sanitize_c_ident
         (source_name ^ generic_data_mono_separator ^ String.concat "_" encoded))
  else None

(* ============================================================================
   Core tree type substitution
   ============================================================================ *)

let subst_core_types (subst : mono_subst) (e : core) : core =
  let st = apply_subst subst in
  transform_bottom_up
    (fun node ->
      let node = { node with ty = st node.ty } in
      match node.desc with
      | CLet (b, body) ->
          { node with desc = CLet ({ b with bind_ty = st b.bind_ty }, body) }
      | CBorrowLet (b, body) ->
          {
            node with
            desc = CBorrowLet ({ b with borrow_ty = st b.borrow_ty }, body);
          }
      | CDup (v, ty, body) -> { node with desc = CDup (v, st ty, body) }
      | CDrop (v, ty, body) -> { node with desc = CDrop (v, st ty, body) }
      | CLambda lam ->
          {
            node with
            desc =
              CLambda
                {
                  lam with
                  lam_params = List.map (fun (v, t) -> (v, st t)) lam.lam_params;
                  lam_return_ty = st lam.lam_return_ty;
                };
          }
      | CFor (binder, iter, body) ->
          {
            node with
            desc = CFor ({ binder with loop_ty = st binder.loop_ty }, iter, body);
          }
      | CUnbox (x, ty) -> { node with desc = CUnbox (x, st ty) }
      | CBox (x, ty) -> { node with desc = CBox (x, st ty) }
      | CCast (x, ty) -> { node with desc = CCast (x, st ty) }
      | _ -> node)
    e

let specialize_func (original : core_func) (mangled : string)
    (subst : mono_subst) : core_func =
  let st = apply_subst subst in
  let body =
    match original.cf_body with
    | None -> None
    | Some b ->
        let substituted = subst_core_types subst b in
        let renamed =
          transform_bottom_up
            (fun node ->
              match node.desc with
              | CVar v when v.vname = original.cf_name ->
                  (* Recursive self-reference inside a generic body: rewrite
                 to the specialized name AND clear [vdef_id]. Keeping the
                 original's [vdef_id] would mangle the recursive call site
                 to the generic's C symbol (which is never emitted). *)
                  { node with desc = CVar (Core.Var.named mangled) }
              | CCall (kind, callee, args) -> (
                  match callee.desc with
                  | CVar v when v.vname = original.cf_name ->
                      {
                        node with
                        desc =
                          CCall
                            ( (match kind with
                              | CKSelectedDirect _ -> CKUnknown
                              | _ -> kind),
                              {
                                callee with
                                desc = CVar (Core.Var.named mangled);
                              },
                              args );
                      }
                  | _ -> node)
              | _ -> node)
            substituted
        in
        Some renamed
  in
  {
    original with
    cf_name = mangled;
    cf_type_params = [];
    cf_params =
      List.map
        (fun (p : core_param) -> { p with cp_ty = st p.cp_ty })
        original.cf_params;
    cf_return_ty = st original.cf_return_ty;
    cf_body = body;
    cf_def_id = Session.mint_def_id (Session.current ());
  }

(* ============================================================================
   Main algorithm
   ============================================================================ *)

let sanitize_module_name = Codegen_names.sanitize_module_name

let concretize_node_type (expected : Ast.type_expr) (node : core) : core =
  if
    (not (Codegen_types.has_type_vars expected))
    && Codegen_types.has_type_vars node.ty
  then { node with ty = expected }
  else node

let concretize_call_args_for_specialization (gf : core_func)
    (subst : mono_subst) (args : core list) : core list =
  let st = apply_subst subst in
  try
    List.map2
      (fun (p : core_param) arg -> concretize_node_type (st p.cp_ty) arg)
      gf.cf_params args
  with Invalid_argument _ -> args

let selected_def_id_from_call_kind = function
  | CKSelectedDirect id -> Some id
  | _ -> None

let clear_selected_direct_call_kind = function
  | CKSelectedDirect _ -> CKUnknown
  | kind -> kind

let concretize_call_for_specialization (gf : core_func) (subst : mono_subst)
    (node : core) (kind : call_kind) (callee : core) (args : core list)
    (mangled : string) : core =
  let st = apply_subst subst in
  let args' = concretize_call_args_for_specialization gf subst args in
  let node' = concretize_node_type (st gf.cf_return_ty) node in
  {
    node' with
    desc =
      CCall
        ( clear_selected_direct_call_kind kind,
          { callee with desc = CVar (Core.Var.named mangled) },
          args' );
  }

let binop_method : Ast.binop -> string option = function
  | Ast.Add -> Some "add"
  | Ast.Sub -> Some "subtract"
  | Ast.Mul -> Some "multiply"
  | Ast.Div -> Some "divide"
  | Ast.Mod -> Some "remainder"
  | Ast.Eq -> Some "equals"
  | Ast.Ne -> Some "not_equals"
  | Ast.Lt -> Some "less_than"
  | Ast.Gt -> Some "greater_than"
  | Ast.Le -> Some "less_than_or_equal"
  | Ast.Ge -> Some "greater_than_or_equal"

let unop_method : Ast.unop -> string option = function
  | Ast.Neg -> Some "negate"
  | Ast.Not -> None

let impl_generation_key (trait_name : string) (for_type : Ast.type_expr) :
    string option =
  match Codegen_types.type_key_for_impl for_type with
  | Some key -> Some (trait_name ^ ":" ^ key)
  | None -> None

let specialize_impl_method (subst : mono_subst) (m : core_func) : core_func =
  let st = apply_subst subst in
  let body = Option.map (subst_core_types subst) m.cf_body in
  {
    m with
    cf_type_params = [];
    cf_params =
      List.map
        (fun (p : core_param) -> { p with cp_ty = st p.cp_ty })
        m.cf_params;
    cf_return_ty = st m.cf_return_ty;
    cf_body = body;
    cf_def_id = Session.mint_def_id (Session.current ());
  }

let specialize_impl (original : core_impl) (subst : mono_subst) : core_impl =
  {
    original with
    ci_for_type = apply_subst subst original.ci_for_type;
    ci_methods = List.map (specialize_impl_method subst) original.ci_methods;
  }

type mono_state = {
  generic_bodies : (string, core_func) Hashtbl.t;
  generic_bodies_by_id : (int, core_func) Hashtbl.t;
  ambiguous_generic_body_ids : (int, unit) Hashtbl.t;
  generic_records : (string, Ast.record_decl) Hashtbl.t;
  generic_types : (string, Ast.type_decl) Hashtbl.t;
  generic_impls_by_method : (string, core_impl list) Hashtbl.t;
  generic_impls_by_trait : (string, core_impl list) Hashtbl.t;
  generated : (string, unit) Hashtbl.t;
  generated_impls : (string, unit) Hashtbl.t;
  generated_record_names : (string, unit) Hashtbl.t;
  in_progress_record_names : (string, unit) Hashtbl.t;
  generated_type_names : (string, unit) Hashtbl.t;
  in_progress_type_names : (string, unit) Hashtbl.t;
  mutable worklist : (string * mono_subst) list;
  mutable impl_worklist : (core_impl * mono_subst) list;
  mutable specialized : core_decl list;
  mutable specialized_impls : core_decl list;
  mutable specialized_records : core_decl list;
  mutable specialized_types : core_decl list;
  import_aliases : (string, string * string) Hashtbl.t;
  module_imports : (string, (string, string * string) Hashtbl.t) Hashtbl.t;
  mutable option_fusion_counter : int;
  mutable current_module_path : string;
  reg : Codegen_types.registry;
      (** Per-compilation registry. [collect_subst] consults [reg.type_aliases]
        via [expand_alias] so alias-wrapped types unify against their
        expanded forms at call sites. *)
}

let create_state ~reg ~import_aliases ?(module_imports = Hashtbl.create 0) () =
  {
    generic_bodies = Hashtbl.create 16;
    generic_bodies_by_id = Hashtbl.create 16;
    ambiguous_generic_body_ids = Hashtbl.create 8;
    generic_records = Hashtbl.create 16;
    generic_types = Hashtbl.create 16;
    generic_impls_by_method = Hashtbl.create 16;
    generic_impls_by_trait = Hashtbl.create 16;
    generated = Hashtbl.create 64;
    generated_impls = Hashtbl.create 64;
    generated_record_names = Hashtbl.create 32;
    in_progress_record_names = Hashtbl.create 8;
    generated_type_names = Hashtbl.create 32;
    in_progress_type_names = Hashtbl.create 8;
    worklist = [];
    impl_worklist = [];
    specialized = [];
    specialized_impls = [];
    specialized_records = [];
    specialized_types = [];
    import_aliases;
    module_imports;
    option_fusion_counter = 0;
    current_module_path = "";
    reg;
  }

let register_generic_body_id (state : mono_state) (f : core_func) : unit =
  let id = f.cf_def_id in
  if Hashtbl.mem state.ambiguous_generic_body_ids id then ()
  else
    match Hashtbl.find_opt state.generic_bodies_by_id id with
    | None -> Hashtbl.replace state.generic_bodies_by_id id f
    | Some existing when existing.cf_name = f.cf_name -> ()
    | Some _ ->
        Hashtbl.remove state.generic_bodies_by_id id;
        Hashtbl.replace state.ambiguous_generic_body_ids id ()

let concrete_subst_for_call (state : mono_state) ~(func_name : string)
    (gf : core_func) (node : core) (args : core list) : mono_subst option =
  let type_params = gf.cf_type_params in
  let type_param_names = type_param_decl_names type_params in
  let rec erase_function_purity ty =
    match ty with
    | Ast.TyFunc fn ->
        Ast.TyFunc
          {
            is_pure = false;
            params = List.map erase_function_purity fn.params;
            return = erase_function_purity fn.return;
          }
    | Ast.TyNamed (name, args) ->
        Ast.TyNamed (name, List.map erase_function_purity args)
    | Ast.TyArray (elem, dims) ->
        Ast.TyArray
          (erase_function_purity elem, List.map erase_function_purity dims)
    | Ast.TyTuple elems -> Ast.TyTuple (List.map erase_function_purity elems)
    | Ast.TyRange inner -> Ast.TyRange (erase_function_purity inner)
    | Ast.TyDimOp (op, a, b) ->
        Ast.TyDimOp (op, erase_function_purity a, erase_function_purity b)
    | other -> other
  in
  let normalize_for_signature_guard ty =
    ty
    |> Codegen_types.expand_alias ~reg:state.reg
    |> Codegen_types.normalize_type |> erase_function_purity
  in
  let is_declared_param name = List.mem (type_param_name name) type_param_names in
  let rec guard_has_declared_param ty =
    match normalize_for_signature_guard ty with
    | Ast.TyVar name | Ast.TyNamed (name, []) -> is_declared_param name
    | Ast.TyBoundVar param -> is_declared_param param.param_name
    | Ast.TyVarDims name -> is_declared_param name
    | Ast.TyNamed (_, args) -> List.exists guard_has_declared_param args
    | Ast.TyArray (elem, dims) ->
        guard_has_declared_param elem || List.exists guard_has_declared_param dims
    | Ast.TyTuple elems -> List.exists guard_has_declared_param elems
    | Ast.TyFunc fn ->
        List.exists guard_has_declared_param fn.params
        || guard_has_declared_param fn.return
    | Ast.TyRange inner -> guard_has_declared_param inner
    | Ast.TyDimOp (_, a, b) ->
        guard_has_declared_param a || guard_has_declared_param b
    | _ -> false
  in
  let rec compatible_args expected actual =
    match (expected, actual) with
    | [], [] -> true
    | [ Ast.TyVarDims _ ], _ -> true
    | e :: expected, a :: actual ->
        compatible e a && compatible_args expected actual
    | _ -> false
  and compatible expected actual =
    (* This guard exists to reject stale selected IDs and unrelated same-ID
       generics before substitution. It must stay generic-aware: type params,
       bounded params, dimension params, and dim expressions containing them are
       provisional matches here. [collect_subst] below is the source of truth for
       producing concrete substitutions. Purity has already been checked by the
       frontend, and bridge-produced Core can conservatively type inline lambdas
       as impure, so purity is erased for this structural guard. *)
    let expected = normalize_for_signature_guard expected in
    let actual = normalize_for_signature_guard actual in
    match (expected, actual) with
    | Ast.TyVar name, _ when is_declared_param name -> true
    | Ast.TyBoundVar param, _ when is_declared_param param.param_name -> true
    | Ast.TyNamed (name, []), _ when is_declared_param name -> true
    | Ast.TyVarDims _, _ -> true
    | Ast.TyDimOp _, _ when guard_has_declared_param expected -> true
    | Ast.TyRange inner, _ when guard_has_declared_param inner -> true
    | Ast.TyNamed (expected_name, expected_args), Ast.TyNamed (actual_name, actual_args)
      when expected_name = actual_name && not (is_declared_param expected_name) ->
        compatible_args expected_args actual_args
    | Ast.TyArray (expected_elem, expected_dims), Ast.TyArray (actual_elem, actual_dims) ->
        compatible_args (expected_elem :: expected_dims) (actual_elem :: actual_dims)
    | Ast.TyTuple expected_elems, Ast.TyTuple actual_elems ->
        compatible_args expected_elems actual_elems
    | Ast.TyFunc expected_fn, Ast.TyFunc actual_fn ->
        compatible_args expected_fn.params actual_fn.params
        && compatible expected_fn.return actual_fn.return
    | Ast.TyRange expected_inner, Ast.TyRange actual_inner ->
        compatible expected_inner actual_inner
    | _ -> Types.types_compatible expected actual
  in
  let signature_accepts_call =
    try
      List.for_all2
        (fun (p : core_param) arg -> compatible p.cp_ty arg.ty)
        gf.cf_params args
      && compatible gf.cf_return_ty node.ty
    with Invalid_argument _ -> false
  in
  if not signature_accepts_call then None
  else
  let raw_subst =
    try
      Some
        (List.fold_left2
           (fun acc (p : core_param) arg ->
             collect_subst ~reg:state.reg type_params p.cp_ty arg.ty acc)
           [] gf.cf_params args)
    with Invalid_argument _ -> None
  in
  match raw_subst with
  | None -> None
  | Some raw_subst -> (
      let raw_subst =
        collect_subst ~reg:state.reg type_params gf.cf_return_ty node.ty
          raw_subst
      in
      match dedup_subst_consistent raw_subst with
      | None ->
          Core_error.errorf (Core_error.Stage Core_stage.Mono) node.loc
            ~hint:
              "all appearances of the same generic type parameter must resolve \
               to the same concrete type; add an overload or change the \
               function signature if mixed types are intended"
            "Conflicting type arguments for generic function '%s'" func_name
      | Some subst
        when subst <> []
             && is_concrete_subst subst
             && subst_closes_function_signature gf subst ->
          Some subst
      | Some _ -> None)

let starts_with s prefix =
  let slen = String.length s in
  let plen = String.length prefix in
  slen >= plen && String.sub s 0 plen = prefix

let ends_with s suffix =
  let slen = String.length s in
  let suffix_len = String.length suffix in
  slen >= suffix_len && String.sub s (slen - suffix_len) suffix_len = suffix

let module_qualified_name = Core_callable_identity.module_qualified_name
let post_mono_synthesis_name = Core_callable_identity.source_member_name
let generic_body_lookup_name = Core_callable_identity.declaration_name

let next_option_fusion_temp (state : mono_state) (label : string) : string =
  state.option_fusion_counter <- state.option_fusion_counter + 1;
  Printf.sprintf "__blorp_option_fusion_%s_%d" label state.option_fusion_counter

let option_payload_type (state : mono_state) (ty : Ast.type_expr) :
    Ast.type_expr option =
  match
    ty
    |> Codegen_types.expand_alias ~reg:state.reg
    |> Codegen_types.normalize_type
  with
  | Ast.TyNamed ("Option", [ payload_ty ]) -> Some payload_ty
  | _ -> None

let core_bool (loc : Ast.loc) (value : bool) : core =
  { desc = CLit (Ast.LitBool value); ty = Ast.TyNamed ("Bool", []); loc }

let core_var (loc : Ast.loc) (name : string) (ty : Ast.type_expr) : core =
  { desc = CVar (Var.named name); ty; loc }

let core_let (loc : Ast.loc) (name : string) (ty : Ast.type_expr) (rhs : core)
    (body : core) : core =
  {
    desc =
      CLet
        ( {
            bind_var = Var.named name;
            bind_mut = false;
            bind_ty = ty;
            bind_rhs = rhs;
          },
          body );
    ty = body.ty;
    loc;
  }

type option_fusion_target =
  | OptionIsSome
  | OptionIsNone
  | OptionGetOr
  | OptionGetOrElse

let option_fusion_target ~(module_path : string option) ~(source_name : string)
    : option_fusion_target option =
  match (module_path, source_name) with
  | Some "std/option", "is_some" -> Some OptionIsSome
  | Some "std/option", "is_none" -> Some OptionIsNone
  | Some "std/option", "get_or" -> Some OptionGetOr
  | Some "std/option", "get_or_else" -> Some OptionGetOrElse
  | _ -> None

let option_presence_match (node : core) (opt : core) ~(some_value : bool)
    ~(none_value : bool) : core =
  {
    node with
    desc =
      CMatchArms
        ( opt,
          [
            ( Ast.PatConstructor ("Some", [ Ast.PatWildcard ]),
              core_bool node.loc some_value );
            (Ast.PatConstructor ("None", []), core_bool node.loc none_value);
          ] );
  }

let try_fuse_option_call (state : mono_state) ~(module_path : string option)
    ~(source_name : string) (gf : core_func) (subst : mono_subst) (node : core)
    (args : core list) : core option =
  match option_fusion_target ~module_path ~source_name with
  | None -> None
  | Some target -> (
      let st = apply_subst subst in
      let args = concretize_call_args_for_specialization gf subst args in
      let node = concretize_node_type (st gf.cf_return_ty) node in
      match (target, args) with
      | OptionIsSome, [ opt ] when option_payload_type state opt.ty <> None ->
          Some
            (option_presence_match node opt ~some_value:true ~none_value:false)
      | OptionIsNone, [ opt ] when option_payload_type state opt.ty <> None ->
          Some
            (option_presence_match node opt ~some_value:false ~none_value:true)
      | OptionGetOr, [ opt; default_value ]
        when option_payload_type state opt.ty <> None ->
          let opt_name = next_option_fusion_temp state "opt" in
          let default_name = next_option_fusion_temp state "default" in
          let value_name = next_option_fusion_temp state "value" in
          let opt_var = core_var node.loc opt_name opt.ty in
          let default_var = core_var node.loc default_name node.ty in
          let match_expr =
            {
              node with
              desc =
                CMatchArms
                  ( opt_var,
                    [
                      ( Ast.PatConstructor ("Some", [ Ast.PatVar value_name ]),
                        core_var node.loc value_name node.ty );
                      (Ast.PatConstructor ("None", []), default_var);
                    ] );
            }
          in
          Some
            (core_let node.loc opt_name opt.ty opt
               (core_let node.loc default_name node.ty default_value match_expr))
      | OptionGetOrElse, [ opt; default_fn ]
        when option_payload_type state opt.ty <> None ->
          let opt_name = next_option_fusion_temp state "opt" in
          let default_fn_name = next_option_fusion_temp state "default_fn" in
          let value_name = next_option_fusion_temp state "value" in
          let opt_var = core_var node.loc opt_name opt.ty in
          let default_fn_var =
            core_var node.loc default_fn_name default_fn.ty
          in
          let default_call =
            { node with desc = CCall (CKUnknown, default_fn_var, []) }
          in
          let match_expr =
            {
              node with
              desc =
                CMatchArms
                  ( opt_var,
                    [
                      ( Ast.PatConstructor ("Some", [ Ast.PatVar value_name ]),
                        core_var node.loc value_name node.ty );
                      (Ast.PatConstructor ("None", []), default_call);
                    ] );
            }
          in
          Some
            (core_let node.loc opt_name opt.ty opt
               (core_let node.loc default_fn_name default_fn.ty default_fn
                  match_expr))
      | _ -> None)

let collect_generic_bodies (state : mono_state) (prog : core_program) : unit =
  let remember_generic_body (f : core_func) =
    register_generic_body_id state f;
    match f.cf_module with
    | None -> Hashtbl.replace state.generic_bodies f.cf_name f
    | Some module_path ->
        (* Module-owned generic functions are not visible by their bare source
           names outside that module. Indexing [std/set.add] globally as
           ["add"] makes unrelated local functions look like unresolved generic
           calls during the post-mono safety check. Store explicit module-owned
           identities only; current-module bare calls and UFCS/imported calls
           resolve through these qualified keys below. *)
        let lookup_name = generic_body_lookup_name f in
        let synthesis_name =
          module_qualified_name module_path (post_mono_synthesis_name f)
        in
        Hashtbl.replace state.generic_bodies lookup_name f;
        if synthesis_name <> lookup_name then
          Hashtbl.replace state.generic_bodies synthesis_name f
  in
  let add_generic_impl (i : core_impl) =
    let by_trait =
      match Hashtbl.find_opt state.generic_impls_by_trait i.ci_trait with
      | Some xs -> xs
      | None -> []
    in
    Hashtbl.replace state.generic_impls_by_trait i.ci_trait (i :: by_trait);
    List.iter
      (fun (m : core_func) ->
        if m.cf_body <> None then begin
          let existing =
            match Hashtbl.find_opt state.generic_impls_by_method m.cf_name with
            | Some xs -> xs
            | None -> []
          in
          Hashtbl.replace state.generic_impls_by_method m.cf_name (i :: existing)
        end)
      i.ci_methods
  in
  let remember_concrete_impl (i : core_impl) =
    match impl_generation_key i.ci_trait i.ci_for_type with
    | Some key -> Hashtbl.replace state.generated_impls key ()
    | None -> ()
  in
  let rec walk = function
    | { cd_desc = CDFunc f; _ } :: rest ->
        if
          f.cf_type_params <> []
          && (f.cf_body <> None
             || is_builtin_kind f.cf_kind
                && Core_intrinsics.has_post_mono_synthesis
                     ~module_path:f.cf_module
                     (post_mono_synthesis_name f))
        then remember_generic_body f;
        walk rest
    | { cd_desc = CDImpl i; _ } :: rest ->
        if Codegen_types.has_type_vars i.ci_for_type then add_generic_impl i
        else remember_concrete_impl i;
        walk rest
    | { cd_desc = CDRecord r; _ } :: rest ->
        if r.record_type_params <> [] && not r.record_is_builtin then
          Hashtbl.replace state.generic_records r.record_name r;
        walk rest
    | { cd_desc = CDType t; _ } :: rest ->
        if
          t.type_params <> [] && (not t.type_is_builtin) && (not t.type_is_enum)
          && not (Types.is_global_abi_type_name t.type_name)
        then Hashtbl.replace state.generic_types t.type_name t;
        walk rest
    | { cd_desc = CDPrivate inner; _ } :: rest ->
        walk [ inner ];
        walk rest
    | _ :: rest -> walk rest
    | [] -> ()
  in
  walk prog

let register_concrete_record_type (state : mono_state)
    (record_decl : Ast.record_decl) : unit =
  if record_decl.record_is_builtin then ()
  else if record_decl.record_is_value then
    Hashtbl.replace state.reg.value_records record_decl.record_name ()
  else
    Codegen_types.register_heap_record_type state.reg record_decl.record_name
      ~destructor:
        (Core_layout_type.record_destructor_policy ~reg:state.reg record_decl)

let register_concrete_union_type ?payload_storage (state : mono_state)
    (type_decl : Ast.type_decl) : unit =
  if type_decl.type_is_builtin then ()
  else if type_decl.type_is_enum then
    Codegen_types.register_enum_type state.reg type_decl.type_name
      type_decl.type_variants
  else begin
    Codegen_types.register_union_variants state.reg type_decl.type_name
      type_decl.type_variants;
    Codegen_types.register_union_type ?payload_storage state.reg
      type_decl.type_name
      ~destructor:
        (Core_layout_type.union_destructor_policy ?payload_storage
           ~reg:state.reg type_decl)
  end

let rec type_contains_parameter (parameters : string list)
    (ty : Ast.type_expr) : bool =
  let is_parameter name = List.mem (type_param_name name) parameters in
  match ty with
  | Ast.TyVar name | Ast.TyNamed (name, []) -> is_parameter name
  | Ast.TyBoundVar param -> is_parameter param.param_name
  | Ast.TyVarDims name -> is_parameter name
  | Ast.TyNamed (_, args) -> List.exists (type_contains_parameter parameters) args
  | Ast.TyArray (elem, dims) ->
      type_contains_parameter parameters elem
      || List.exists (type_contains_parameter parameters) dims
  | Ast.TyTuple elems -> List.exists (type_contains_parameter parameters) elems
  | Ast.TyFunc func ->
      List.exists (type_contains_parameter parameters) func.params
      || type_contains_parameter parameters func.return
  | Ast.TyRange inner -> type_contains_parameter parameters inner
  | Ast.TyDimOp (_, a, b) ->
      type_contains_parameter parameters a
      || type_contains_parameter parameters b
  | Ast.TySelf -> List.mem "Self" parameters
  | Ast.TyMeta _ | Ast.TyConstInt _ -> false

let concrete_type_args unresolved_parameters params args =
  List.length params = List.length args
  && args <> []
  && List.for_all
       (fun arg ->
         not
           (Codegen_types.has_type_vars arg
           || type_contains_parameter unresolved_parameters arg))
       args

let type_param_subst params args =
  List.map2
    (fun param arg -> (param, SubstType arg))
    (Ast.type_param_names params)
    args

let monomorphize_generic_data (state : mono_state) (prog : core_program) :
    core_program =
  let has_generic_data =
    Hashtbl.length state.generic_records > 0
    || Hashtbl.length state.generic_types > 0
  in
  if not has_generic_data then prog
  else
    let rec rewrite_type unresolved_parameters ty =
      match Codegen_types.normalize_type ty with
      | Ast.TyNamed (name, args) -> (
          let args = List.map (rewrite_type unresolved_parameters) args in
          match Hashtbl.find_opt state.generic_records name with
          | Some record_decl
            when concrete_type_args unresolved_parameters
                   record_decl.record_type_params args -> (
              match concrete_generic_data_name name args with
              | Some concrete_name ->
                  ensure_concrete_record record_decl concrete_name args;
                  Ast.TyNamed (concrete_name, [])
              | None -> Ast.TyNamed (name, args))
          | _ -> (
              match Hashtbl.find_opt state.generic_types name with
              | Some type_decl
                when concrete_type_args unresolved_parameters
                       type_decl.type_params args -> (
                  match concrete_generic_data_name name args with
                  | Some concrete_name ->
                      ensure_concrete_type type_decl concrete_name args;
                      Ast.TyNamed (concrete_name, [])
                  | None -> Ast.TyNamed (name, args))
              | _ -> Ast.TyNamed (name, args)))
      | Ast.TyArray (elem, dims) ->
          Ast.TyArray
            ( rewrite_type unresolved_parameters elem,
              List.map (rewrite_type unresolved_parameters) dims )
      | Ast.TyFunc f ->
          Ast.TyFunc
            {
              f with
              params = List.map (rewrite_type unresolved_parameters) f.params;
              return = rewrite_type unresolved_parameters f.return;
            }
      | Ast.TyTuple elems ->
          Ast.TyTuple (List.map (rewrite_type unresolved_parameters) elems)
      | Ast.TyRange inner ->
          Ast.TyRange (rewrite_type unresolved_parameters inner)
      | Ast.TyDimOp (op, a, b) ->
          Ast.TyDimOp
            ( op,
              rewrite_type unresolved_parameters a,
              rewrite_type unresolved_parameters b )
      | other -> other
    and ensure_concrete_record record_decl concrete_name args =
      if Hashtbl.mem state.generated_record_names concrete_name then ()
      else if Hashtbl.mem state.in_progress_record_names concrete_name then ()
      else begin
        Hashtbl.replace state.in_progress_record_names concrete_name ();
        let subst = type_param_subst record_decl.record_type_params args in
        let concrete_fields =
          List.map
            (fun (field : Ast.field_decl) ->
              {
                field with
                field_type =
                  rewrite_type []
                    (apply_subst subst field.field_type);
              })
            record_decl.record_fields
        in
        let concrete_record =
          {
            record_decl with
            record_name = concrete_name;
            record_type_params = [];
            record_fields = concrete_fields;
          }
        in
        Hashtbl.remove state.in_progress_record_names concrete_name;
        Hashtbl.replace state.generated_record_names concrete_name ();
        register_concrete_record_type state concrete_record;
        state.specialized_records <-
          {
            cd_desc = CDRecord concrete_record;
            cd_loc = Ast.dummy_loc;
            cd_doc = None;
          }
          :: state.specialized_records
      end
    and ensure_concrete_type type_decl concrete_name args =
      if Hashtbl.mem state.generated_type_names concrete_name then ()
      else if Hashtbl.mem state.in_progress_type_names concrete_name then ()
      else begin
        Hashtbl.replace state.in_progress_type_names concrete_name ();
        let subst = type_param_subst type_decl.type_params args in
        let concrete_variants =
          List.map
            (fun (variant : Ast.variant) ->
              {
                variant with
                variant_fields =
                  List.map
                    (fun field_ty ->
                      rewrite_type [] (apply_subst subst field_ty))
                    variant.variant_fields;
                variant_def_id = Some (Session.mint_def_id (Session.current ()));
              })
            type_decl.type_variants
        in
        let concrete_type =
          {
            type_decl with
            type_name = concrete_name;
            type_params = [];
            type_variants = concrete_variants;
          }
        in
        Hashtbl.remove state.in_progress_type_names concrete_name;
        Hashtbl.replace state.generated_type_names concrete_name ();
        let payload_storage =
          if Types.is_runtime_erased_payload_union_type_name type_decl.type_name
          then Codegen_types.ErasedUnionPayloadStorage
          else Codegen_types.TypedUnionPayloadStorage
        in
        register_concrete_union_type ~payload_storage state concrete_type;
        state.specialized_types <-
          {
            cd_desc = CDType concrete_type;
            cd_loc = Ast.dummy_loc;
            cd_doc = None;
          }
          :: state.specialized_types
      end
    in
    let rec rewrite_decl (decl : core_decl) =
      match decl.cd_desc with
      | CDPrivate inner ->
          { decl with cd_desc = CDPrivate (rewrite_decl inner) }
      | _ ->
          let unresolved_parameters =
            match decl.cd_desc with
            | CDFunc func -> type_param_decl_names func.cf_type_params
            | CDImpl impl ->
                (* Core receives typechecked types, so only explicit type
                   variables remain generic here. Treating every capitalized
                   concrete name as a candidate (for example [String]) keeps
                   specialized impl receivers in source form while the rest
                   of the program moves to concrete data names. *)
                Types.collect_type_vars impl.ci_for_type
                @ List.concat_map
                    (fun method_func ->
                      type_param_decl_names method_func.cf_type_params)
                    impl.ci_methods
            | CDTrait trait -> trait.ct_type_params
            | CDType type_decl -> type_param_decl_names type_decl.type_params
            | CDRecord record_decl ->
                type_param_decl_names record_decl.record_type_params
            | CDTypeAlias alias_decl ->
                type_param_decl_names alias_decl.alias_type_params
            | CDVar _ | CDImport _ | CDPrivate _ -> []
          in
          Core.map_types_in_decl
            (rewrite_type unresolved_parameters)
            decl
    in
    let rewritten = List.map rewrite_decl prog in
    rewritten
    @ List.rev state.specialized_records
    @ List.rev state.specialized_types

let try_enqueue (state : mono_state) (func_name : string) (subst : mono_subst) :
    string option =
  match mangle_name func_name subst with
  | None -> None
  | Some mangled ->
      if not (Hashtbl.mem state.generated mangled) then begin
        Hashtbl.replace state.generated mangled ();
        state.worklist <- (func_name, subst) :: state.worklist
      end;
      Some mangled

let method_with_body (method_name : string) (i : core_impl) : core_func option =
  List.find_opt
    (fun (m : core_func) -> m.cf_name = method_name && m.cf_body <> None)
    i.ci_methods

let first_body_method (i : core_impl) : core_func option =
  List.find_opt (fun (m : core_func) -> m.cf_body <> None) i.ci_methods

let rec try_enqueue_impl_for_trait (state : mono_state) (trait_name : string)
    (receiver_ty : Ast.type_expr) : bool =
  let candidates =
    match Hashtbl.find_opt state.generic_impls_by_trait trait_name with
    | Some xs -> xs
    | None -> []
  in
  List.exists (try_enqueue_impl_candidate state receiver_ty None) candidates

and try_enqueue_impl_for_method (state : mono_state) (method_name : string)
    (receiver_ty : Ast.type_expr) : bool =
  let candidates =
    match Hashtbl.find_opt state.generic_impls_by_method method_name with
    | Some xs -> xs
    | None -> []
  in
  List.exists
    (try_enqueue_impl_candidate state receiver_ty (Some method_name))
    candidates

and try_enqueue_impl_candidate (state : mono_state)
    (receiver_ty : Ast.type_expr) (method_name : string option) (i : core_impl)
    : bool =
  let method_for_params =
    match method_name with
    | Some name -> method_with_body name i
    | None -> first_body_method i
  in
  match method_for_params with
  | None -> false
  | Some method_def -> (
      let raw_subst =
        collect_subst ~reg:state.reg method_def.cf_type_params i.ci_for_type
          receiver_ty []
      in
      match dedup_subst_consistent raw_subst with
      | None -> false
      | Some subst -> (
          let concrete_for_type = apply_subst subst i.ci_for_type in
          if
            subst = []
            || (not (is_concrete_subst subst))
            || Codegen_types.has_type_vars concrete_for_type
          then false
          else
            match impl_generation_key i.ci_trait concrete_for_type with
            | None -> false
            | Some key ->
                if not (Hashtbl.mem state.generated_impls key) then begin
                  Hashtbl.replace state.generated_impls key ();
                  state.impl_worklist <- (i, subst) :: state.impl_worklist;
                  enqueue_impl_bounds state subst method_def.cf_type_params
                end;
                true))

and enqueue_impl_bounds (state : mono_state) (subst : mono_subst)
    (type_params : Ast.type_param_decl list) : unit =
  List.iter
    (fun (param : Ast.type_param_decl) ->
      match List.assoc_opt param.param_name subst with
      | None -> ()
      | Some (SubstDimPack _) -> ()
      | Some (SubstType concrete_ty) ->
          List.iter
            (fun trait_ref ->
              ignore
                (try_enqueue_impl_for_trait state
                   (Generic_params.trait_ref_name trait_ref)
                   concrete_ty))
            param.param_bounds)
    type_params

let enqueue_trait_call_dependencies (state : mono_state) (method_name : string)
    (args : core list) : unit =
  match args with
  | first :: _ -> (
      ignore (try_enqueue_impl_for_method state method_name first.ty);
      match (method_name, Codegen_types.normalize_type first.ty) with
      | "to_string", Ast.TyNamed ("List", [ elem_ty ]) ->
          ignore (try_enqueue_impl_for_trait state "Stringable" elem_ty)
      | _ -> ())
  | [] -> ()

(** Look up the module path for a qualified alias, checking both the main
    program's imports and the current module's imports. *)
let lookup_alias_module (state : mono_state) (alias_name : string) :
    string option =
  match Hashtbl.find_opt state.import_aliases alias_name with
  | Some (mp, "") -> Some mp
  | _ ->
      if state.current_module_path <> "" then
        match
          Hashtbl.find_opt state.module_imports state.current_module_path
        with
        | Some mod_aliases -> (
            match Hashtbl.find_opt mod_aliases alias_name with
            | Some (mp, _) -> Some mp
            | None -> None)
        | None -> None
      else None

type generic_hit = {
  gh_name : string;
  gh_func : core_func;
  gh_module_path : string option;
  gh_source_name : string;
}

let generic_hit_of_func (f : core_func) : generic_hit =
  {
    gh_name = generic_body_lookup_name f;
    gh_func = f;
    gh_module_path = f.cf_module;
    gh_source_name = post_mono_synthesis_name f;
  }

let lookup_generic_by_def_id (state : mono_state) (def_id : int option) :
    generic_hit option =
  match def_id with
  | None -> None
  | Some id ->
      if Hashtbl.mem state.ambiguous_generic_body_ids id then None
      else
        Option.map generic_hit_of_func
          (Hashtbl.find_opt state.generic_bodies_by_id id)

(** Callable IDs are local to a frontend typecheck artifact. Once module
    artifacts are merged, unrelated declarations may carry the same ID. The
    callee name remains authoritative: a selected generic must match either
    its source name, canonical flattened name, or explicit UFCS identity. *)
let selected_generic_hit_matches_callee (callee_name : string)
    (hit : generic_hit) : bool =
  Core_callable_identity.selected_callee_matches_function ~callee_name
    hit.gh_func

let same_generic_function_identity (left : core_func) (right : core_func) =
  left.cf_def_id = right.cf_def_id
  && String.equal left.cf_name right.cf_name
  && left.cf_module = right.cf_module

let lookup_generic_by_callee_identity (state : mono_state) callee_name =
  let found = ref None in
  let ambiguous = ref false in
  Hashtbl.iter
    (fun _ func ->
      if
        Core_callable_identity.selected_callee_matches_function ~callee_name
          func
      then
        match !found with
        | None -> found := Some (generic_hit_of_func func)
        | Some existing
          when same_generic_function_identity existing.gh_func func ->
            ()
        | Some _ -> ambiguous := true)
    state.generic_bodies;
  if !ambiguous then None else !found

let lookup_generic_module_func (state : mono_state) (mod_path : string)
    (orig_name : string) : generic_hit option =
  let prefixed = module_qualified_name mod_path orig_name in
  let try_lookup_module_owned ?(allow_unowned_prefixed = false) name =
    match Hashtbl.find_opt state.generic_bodies name with
    | Some gf
      when gf.cf_module = Some mod_path
           || (allow_unowned_prefixed && gf.cf_module = None) ->
        Some
          {
            gh_name = name;
            gh_func = gf;
            gh_module_path = Some mod_path;
            gh_source_name = orig_name;
          }
    | _ -> None
  in
  match try_lookup_module_owned ~allow_unowned_prefixed:true prefixed with
  | Some _ as found -> found
  | None -> (
      let prefixed_pure = prefixed ^ "__pure" in
      match
        try_lookup_module_owned ~allow_unowned_prefixed:true prefixed_pure
      with
      | Some _ as found -> found
      | None -> (
          match try_lookup_module_owned orig_name with
          | Some _ as found -> found
          | None -> try_lookup_module_owned (orig_name ^ "__pure")))

let source_name_for_module_call (mod_path : string) (name : string) : string =
  let prefix = sanitize_module_name mod_path ^ "__" in
  let source_name =
    if starts_with name prefix then
      String.sub name (String.length prefix) (String.length name - String.length prefix)
    else name
  in
  let pure_suffix = "__pure" in
  if ends_with source_name pure_suffix then
    String.sub source_name 0 (String.length source_name - String.length pure_suffix)
  else source_name

let qualified_call_resolves_without_mono (mod_path : string) (field : string)
    (args : core list) : bool =
  let source_name = source_name_for_module_call mod_path field in
  let names =
    if source_name = field then [ field ] else [ field; source_name ]
  in
  List.exists
    (fun name ->
      Codegen_builtins.lookup mod_path name <> None
      ||
      match args with
      | receiver :: _ ->
          Core_intrinsic_registry.lookup_ir_backed_std_function ~mod_path
            ~func_name:name ~arity:(List.length args) ~receiver_ty:receiver.ty
          <> None
      | [] -> false)
    names

module StringSet = Set.Make (String)

let scope_add_var (scope : StringSet.t) (v : var) : StringSet.t =
  StringSet.add v.vname scope

let scope_add_vars (scope : StringSet.t) (vars : var list) : StringSet.t =
  List.fold_left scope_add_var scope vars

let scope_add_pattern (scope : StringSet.t) (pat : Ast.pattern) : StringSet.t =
  List.fold_left
    (fun acc name -> StringSet.add name acc)
    scope
    (Ast.collect_pattern_vars pat)

(** Scan and rewrite: walk a Core tree, find calls to generic functions,
    enqueue monomorphization requests, and rewrite each call site inline
    to the mangled name. Returns the rewritten tree. *)
let scan_and_rewrite ?(initial_scope = StringSet.empty) (state : mono_state)
    (e : core) : core =
  let rec rewrite_ctree scope tree =
    match tree with
    | CTLeaf { ct_bindings; ct_body } ->
        let body_scope =
          List.fold_left
            (fun acc binding -> scope_add_var acc binding.mb_var)
            scope ct_bindings
        in
        CTLeaf { ct_bindings; ct_body = rewrite body_scope ct_body }
    | CTFail -> CTFail
    | CTSwitchTag sw ->
        CTSwitchTag
          {
            sw with
            cts_cases =
              List.map
                (fun (name, sub) -> (name, rewrite_ctree scope sub))
                sw.cts_cases;
            cts_default = Option.map (rewrite_ctree scope) sw.cts_default;
          }
    | CTSwitchLit sw ->
        CTSwitchLit
          {
            sw with
            ctl_cases =
              List.map
                (fun (lit, sub) -> (lit, rewrite_ctree scope sub))
                sw.ctl_cases;
            ctl_default = rewrite_ctree scope sw.ctl_default;
          }
    | CTSwitchLen sw ->
        CTSwitchLen
          {
            sw with
            ctl_len_cases =
              List.map
                (fun (n, sub) -> (n, rewrite_ctree scope sub))
                sw.ctl_len_cases;
            ctl_len_geq =
              Option.map
                (fun (n, sub) -> (n, rewrite_ctree scope sub))
                sw.ctl_len_geq;
            ctl_len_default =
              Option.map (rewrite_ctree scope) sw.ctl_len_default;
          }
  and rewrite_call scope node kind callee args =
    (match (kind, args) with
    | CKBuiltin "blorp_to_string", [ arg ] ->
        enqueue_trait_call_dependencies state "to_string" [ arg ]
    | _ -> ());
    (match callee.desc with
    | CVar v when not (StringSet.mem v.vname scope) ->
        (* Imported/target-module trait calls carry their module owner in the
           UFCS callee. Generic impls remain indexed by source method name. *)
        let method_name =
          match Codegen_names.parse_ufcs_name v.vname with
          | Some (_, source_name) -> source_name
          | None -> v.vname
        in
        enqueue_trait_call_dependencies state method_name args
    | _ -> ());
    match callee.desc with
    | CField (obj, field)
      when match obj.desc with
           | CVar v -> not (StringSet.mem v.vname scope)
           | _ -> false -> (
        (* Qualified module call: `C.cache(args)`. If the alias is a known
                module, try to specialize the resolved generic function. *)
        let alias_name = match obj.desc with CVar v -> v.vname | _ -> "" in
        match lookup_alias_module state alias_name with
        | Some mod_path -> (
            let selected_by_id =
              let selected_id =
                match selected_def_id_from_call_kind kind with
                | Some _ as id -> id
                | None -> (
                    match obj.desc with CVar v -> v.vdef_id | _ -> None)
              in
              match lookup_generic_by_def_id state selected_id with
              | Some hit when hit.gh_module_path = Some mod_path -> Some hit
              | _ -> None
            in
            let fallback_hit () =
              if qualified_call_resolves_without_mono mod_path field args then
                None
              else lookup_generic_module_func state mod_path field
            in
            match
              match selected_by_id with
              | Some _ as hit -> hit
              | None -> fallback_hit ()
            with
            | Some hit -> (
                match
                  concrete_subst_for_call state ~func_name:hit.gh_name
                    hit.gh_func node args
                with
                | Some subst -> (
                    match
                      try_fuse_option_call state ~module_path:hit.gh_module_path
                        ~source_name:hit.gh_source_name hit.gh_func subst node
                        args
                    with
                    | Some fused -> fused
                    | None -> (
                        match try_enqueue state hit.gh_name subst with
                        | Some mangled ->
                            concretize_call_for_specialization hit.gh_func subst
                              node kind callee args mangled
                        | None -> node))
                | None -> node)
            | None -> node)
        | None -> node)
    | CVar v when not (StringSet.mem v.vname scope) -> (
        let try_lookup_prefixed_for_mono mod_path orig_name =
          if qualified_call_resolves_without_mono mod_path orig_name args then
            None
          else lookup_generic_module_func state mod_path orig_name
        in
        let try_lookup_bare name =
          let visible hit_name gf =
            match (gf.cf_module, state.current_module_path) with
            | None, "" ->
                Some
                  {
                    gh_name = hit_name;
                    gh_func = gf;
                    gh_module_path = None;
                    gh_source_name = post_mono_synthesis_name gf;
                  }
            | Some owner, current when owner = current ->
                Some
                  {
                    gh_name = hit_name;
                    gh_func = gf;
                    gh_module_path = Some owner;
                    gh_source_name = post_mono_synthesis_name gf;
                  }
            | Some owner, _ when
                hit_name
                = module_qualified_name owner (post_mono_synthesis_name gf) ->
                (* Imported calls can arrive after child CVar rewriting as the
                   flattened canonical function name, e.g.
                   [std_tensor__is_empty]. That name is globally addressable
                   Core, unlike an unprefixed module-local source name. *)
                Some
                  {
                    gh_name = hit_name;
                    gh_func = gf;
                    gh_module_path = Some owner;
                    gh_source_name = post_mono_synthesis_name gf;
                  }
            | _ -> None
          in
          match Hashtbl.find_opt state.generic_bodies name with
          | Some gf -> visible name gf
          | None when state.current_module_path <> "" -> (
              let qualified =
                module_qualified_name state.current_module_path name
              in
              match Hashtbl.find_opt state.generic_bodies qualified with
              | Some gf -> visible qualified gf
              | None -> None)
          | None -> None
        in
        let try_lookup_import_alias aliases name =
          match Hashtbl.find_opt aliases name with
          | Some (mod_path, orig_name) when orig_name <> "" -> (
              match try_lookup_prefixed_for_mono mod_path orig_name with
              | Some hit -> `Generic hit
              | None -> `Concrete)
          | _ -> `Missing
        in
        let resolve_name name =
          let selected_id =
            match selected_def_id_from_call_kind kind with
            | Some _ as id -> id
            | None -> v.vdef_id
          in
          let selected_hit =
            match lookup_generic_by_def_id state selected_id with
            | Some hit when selected_generic_hit_matches_callee name hit ->
                Some hit
            | Some _ | None -> None
          in
          match selected_hit with
          | Some hit -> Some hit
          | None -> (
              (* UFCS-mangled names are already explicit method targets:
                  __ufcs_std$option__get_or -> std_option__get_or.
                  Resolve those before considering any bare same-name generic. *)
              let identity_hit =
                if Core_callable_identity.is_ufcs_name name then
                  lookup_generic_by_callee_identity state name
                else None
              in
              match identity_hit with
              | Some hit -> Some hit
              | None -> (
                  match Codegen_names.parse_ufcs_name name with
                  | Some (mod_path, orig_name) -> (
                      match try_lookup_prefixed_for_mono mod_path orig_name with
                      | Some _ as hit -> hit
                      | None -> try_lookup_bare name)
                  | None -> (
                  let import_hit =
                    (* Current module imports are authoritative inside that
                        module. Main-program imports must not leak into std
                        module bodies, because they can shadow module-local
                        calls such as dict.contains -> dict.get. *)
                    if state.current_module_path <> "" then
                      match
                        Hashtbl.find_opt state.module_imports
                          state.current_module_path
                      with
                      | Some mod_aliases ->
                          try_lookup_import_alias mod_aliases name
                      | None -> `Missing
                    else try_lookup_import_alias state.import_aliases name
                  in
                  match import_hit with
                  | `Generic hit -> Some hit
                  | `Concrete -> None
                  | `Missing -> (
                      match
                        if state.current_module_path <> "" then
                          try_lookup_prefixed_for_mono state.current_module_path
                            name
                        else None
                      with
                      | Some _ as hit -> hit
                      | None -> try_lookup_bare name))))
        in
        match resolve_name v.vname with
        | Some hit -> (
            match
              concrete_subst_for_call state ~func_name:hit.gh_name hit.gh_func
                node args
            with
            | Some subst -> (
                match
                  try_fuse_option_call state ~module_path:hit.gh_module_path
                    ~source_name:hit.gh_source_name hit.gh_func subst node args
                with
                | Some fused -> fused
                | None -> (
                    match try_enqueue state hit.gh_name subst with
                    | Some mangled ->
                        (* Use [Var.named mangled] to CLEAR [vdef_id].
                                The original [v] may carry a [vdef_id] from a
                                UFCS [#<ol_def_id>] suffix (core_lower.ml parse);
                                the specialized target is a different function
                                with its own [cf_def_id] that [Core_resolve]'s
                                [collect_env] will populate later. Keeping the
                                old id would mangle the call site to the
                                wrong C symbol. *)
                        concretize_call_for_specialization hit.gh_func subst
                          node kind callee args mangled
                    | None -> node))
            | None -> node)
        | None -> node)
    | _ -> node
  and rewrite scope e =
    let rewrite_box_op b = { b with box_value = rewrite scope b.box_value } in
    let rewrite_boxed_storage v =
      { v with bsv_box = rewrite_box_op v.bsv_box }
    in
    let rewrite_record_field = function
      | RecordRawField (name, value) ->
          RecordRawField (name, rewrite scope value)
      | RecordErasedField (name, value) ->
          RecordErasedField (name, rewrite_boxed_storage value)
    in
    let desc =
      match e.desc with
      | CLit _ | CVar _ | CVoid | CBreak | CContinue | CCooperativeCheckpoint ->
          e.desc
      | CResourceCleanupExit exit ->
          CResourceCleanupExit
            {
              exit with
              rce_cleanups = List.map (rewrite scope) exit.rce_cleanups;
            }
      | CTuple xs -> CTuple (List.map (rewrite scope) xs)
      | CList lit ->
          CList { lit with ll_elems = List.map (rewrite scope) lit.ll_elems }
      | CListAlloc alloc ->
          CListAlloc
            { alloc with la_capacity = rewrite scope alloc.la_capacity }
      | CListGet get ->
          CListGet
            {
              get with
              lg_list = rewrite scope get.lg_list;
              lg_index = rewrite scope get.lg_index;
            }
      | CStringByteRead r ->
          CStringByteRead
            {
              r with
              sbr_source = rewrite scope r.sbr_source;
              sbr_index = rewrite scope r.sbr_index;
            }
      | CStringByteWrite w ->
          CStringByteWrite
            {
              w with
              sbw_target = rewrite scope w.sbw_target;
              sbw_index = rewrite scope w.sbw_index;
              sbw_byte = rewrite scope w.sbw_byte;
            }
      | CStringByteCopy c ->
          CStringByteCopy
            {
              c with
              sbc_dst = rewrite scope c.sbc_dst;
              sbc_dst_pos = rewrite scope c.sbc_dst_pos;
              sbc_src = rewrite scope c.sbc_src;
              sbc_src_pos = rewrite scope c.sbc_src_pos;
              sbc_len = rewrite scope c.sbc_len;
            }
      | CStringSetLen s ->
          CStringSetLen
            {
              s with
              ssl_target = rewrite scope s.ssl_target;
              ssl_len = rewrite scope s.ssl_len;
            }
      | CTupleConstruct tc ->
          CTupleConstruct
            { tc with tc_elems = List.map rewrite_boxed_storage tc.tc_elems }
      | CListConstruct lc ->
          CListConstruct
            { lc with lc_elems = List.map rewrite_boxed_storage lc.lc_elems }
      | CVector xs -> CVector (List.map (rewrite scope) xs)
      | CTensorLiteral tl ->
          let payload =
            match tl.tl_payload with
            | TensorRawElements (scalar, elems) ->
                TensorRawElements (scalar, List.map (rewrite scope) elems)
            | TensorWordElements elems ->
                TensorWordElements (List.map (rewrite scope) elems)
            | TensorPackedElements (width, elems) ->
                TensorPackedElements (width, List.map (rewrite scope) elems)
            | TensorInlineStructElements (c_ty, elems) ->
                TensorInlineStructElements (c_ty, List.map (rewrite scope) elems)
            | TensorBoxedElements elems ->
                TensorBoxedElements (List.map rewrite_boxed_storage elems)
          in
          CTensorLiteral { tl with tl_payload = payload }
      | CDict kvs ->
          CDict
            (List.map (fun (k, v) -> (rewrite scope k, rewrite scope v)) kvs)
      | CDictConstruct dc ->
          CDictConstruct
            {
              dc with
              dc_entries =
                List.map
                  (fun (k, v) ->
                    (rewrite_boxed_storage k, rewrite_boxed_storage v))
                  dc.dc_entries;
            }
      | CSetAlloc _ -> e.desc
      | CRecord fs ->
          CRecord
            (List.map (fun (name, value) -> (name, rewrite scope value)) fs)
      | CRecordConstruct rc ->
          CRecordConstruct
            { rc with rc_fields = List.map rewrite_record_field rc.rc_fields }
      | CRecordUpdate (base, fs) ->
          CRecordUpdate
            ( rewrite scope base,
              List.map (fun (name, value) -> (name, rewrite scope value)) fs )
      | CRange (a, b) -> CRange (rewrite scope a, rewrite scope b)
      | CLambda lam ->
          let lam_scope =
            List.fold_left
              (fun acc (v, _) -> scope_add_var acc v)
              scope lam.lam_params
          in
          CLambda { lam with lam_body = rewrite lam_scope lam.lam_body }
      | CBin (op, lhs, rhs) -> CBin (op, rewrite scope lhs, rewrite scope rhs)
      | CUn (op, operand) -> CUn (op, rewrite scope operand)
      | CLog (op, lhs, rhs) -> CLog (op, rewrite scope lhs, rewrite scope rhs)
      | CCall (kind, callee, args) ->
          let callee' = rewrite scope callee in
          let args' = List.map (rewrite scope) args in
          CCall (kind, callee', args')
      | CTensorRawRead r ->
          CTensorRawRead { r with trr_index = rewrite scope r.trr_index }
      | CTensorRawWrite w ->
          CTensorRawWrite
            {
              w with
              trw_index = rewrite scope w.trw_index;
              trw_value = rewrite scope w.trw_value;
            }
      | CField (obj, field) -> CField (rewrite scope obj, field)
      | CStringInterp (parts, is_multiline) ->
          CStringInterp
            ( List.map
                (function
                  | IPLit _ as lit -> lit
                  | IPExpr expr -> IPExpr (rewrite scope expr))
                parts,
              is_multiline )
      | CLet (binding, body) ->
          let rhs' = rewrite scope binding.bind_rhs in
          let body' = rewrite (scope_add_var scope binding.bind_var) body in
          CLet ({ binding with bind_rhs = rhs' }, body')
      | CBorrowLet (binding, body) ->
          let rhs' = rewrite scope binding.borrow_rhs in
          let body' = rewrite (scope_add_var scope binding.borrow_var) body in
          CBorrowLet ({ binding with borrow_rhs = rhs' }, body')
      | CTensorRawViewLet (binding, body) ->
          let source' = rewrite scope binding.trv_source in
          let body' = rewrite (scope_add_var scope binding.trv_var) body in
          CTensorRawViewLet ({ binding with trv_source = source' }, body')
      | CResourceScope s ->
          let acquire' = rewrite scope s.rs_acquire in
          let scoped = scope_add_var scope s.rs_var in
          CResourceScope
            {
              s with
              rs_acquire = acquire';
              rs_body = rewrite scoped s.rs_body;
              rs_cleanup = rewrite scoped s.rs_cleanup;
            }
      | CSeq (a, b) -> CSeq (rewrite scope a, rewrite scope b)
      | CDebugBlock body -> CDebugBlock (rewrite scope body)
      | CIf (cond, then_, else_) ->
          CIf (rewrite scope cond, rewrite scope then_, rewrite scope else_)
      | CMatchArms (scrut, arms) ->
          CMatchArms
            ( rewrite scope scrut,
              List.map
                (fun (pat, body) ->
                  (pat, rewrite (scope_add_pattern scope pat) body))
                arms )
      | CMatch (scrut, tree) ->
          CMatch (rewrite scope scrut, rewrite_ctree scope tree)
      | CWhile (cond, body) -> CWhile (rewrite scope cond, rewrite scope body)
      | CFor (binder, iter, body) ->
          CFor
            ( binder,
              rewrite scope iter,
              rewrite (scope_add_var scope binder.loop_var) body )
      | CSelect select ->
          let rewrite_arm arm =
            let arm_kind, body_scope =
              match arm.select_arm_kind with
              | SelectRecv r ->
                  ( SelectRecv
                      { r with select_channel = rewrite scope r.select_channel },
                    scope_add_var scope r.select_bind )
              | SelectSealed channel ->
                  (SelectSealed (rewrite scope channel), scope)
              | SelectAfter timeout ->
                  (SelectAfter (rewrite scope timeout), scope)
            in
            {
              arm with
              select_arm_kind = arm_kind;
              select_arm_body = rewrite body_scope arm.select_arm_body;
            }
          in
          CSelect { select_arms = List.map rewrite_arm select.select_arms }
      | CAssign (v, rhs) -> CAssign (v, rewrite scope rhs)
      | CTailrecLoop loop ->
          let loop' =
            match loop with
            | TailrecUnmanagedLoop l ->
                TailrecUnmanagedLoop
                  { l with tul_body = rewrite scope l.tul_body }
            | TailrecListSpreadLoop l ->
                TailrecListSpreadLoop
                  { l with tls_body = rewrite scope l.tls_body }
          in
          CTailrecLoop loop'
      | CTailrecRecur recur ->
          let recur' =
            match recur with
            | TailrecRecur r ->
                TailrecRecur { tr_args = List.map (rewrite scope) r.tr_args }
            | TailrecListSpreadRecur r ->
                TailrecListSpreadRecur
                  {
                    r with
                    tr_rebinds =
                      List.map
                        (fun (i, arg) -> (i, rewrite scope arg))
                        r.tr_rebinds;
                  }
          in
          CTailrecRecur recur'
      | CDup (v, ty, body) -> CDup (v, ty, rewrite scope body)
      | CDrop (v, ty, body) -> CDrop (v, ty, rewrite scope body)
      | CConcurrent cb ->
          let body_scope =
            List.fold_left
              (fun acc b -> scope_add_var acc b.cb_var)
              scope cb.conc_bindings
          in
          CConcurrent
            {
              cb with
              conc_bindings =
                List.map
                  (fun b -> { b with cb_rhs = rewrite scope b.cb_rhs })
                  cb.conc_bindings;
              conc_body = rewrite body_scope cb.conc_body;
              conc_timeout = Option.map (rewrite scope) cb.conc_timeout;
            }
      | CConcurrentlyLoop cf ->
          CConcurrentlyLoop
            {
              cf with
              cf_iter = rewrite scope cf.cf_iter;
              cf_body = rewrite (scope_add_var scope cf.cf_var) cf.cf_body;
              cf_timeout = Option.map (rewrite scope) cf.cf_timeout;
            }
      | CDetach d ->
          CDetach { detach_body = rewrite scope d.detach_body }
      | CCast (expr, ty) -> CCast (rewrite scope expr, ty)
      | CUnbox (expr, ty) -> CUnbox (rewrite scope expr, ty)
      | CUnboxTyped u ->
          CUnboxTyped { u with unbox_value = rewrite scope u.unbox_value }
      | CBox (expr, ty) -> CBox (rewrite scope expr, ty)
      | CBoxTyped b -> CBoxTyped (rewrite_box_op b)
      | CUnionConstruct uc ->
          CUnionConstruct
            { uc with uc_args = List.map rewrite_boxed_storage uc.uc_args }
      | CUnionReuseConstruct urc ->
          CUnionReuseConstruct
            {
              urc with
              urc_source = rewrite scope urc.urc_source;
              urc_args = List.map rewrite_boxed_storage urc.urc_args;
            }
      | CListHandoff h ->
          let body_scope =
            scope_add_vars scope
              [ h.lh_source_var; h.lh_result_var; h.lh_len_var; h.lh_out_var ]
          in
          CListHandoff
            {
              h with
              lh_source = rewrite scope h.lh_source;
              lh_capacity = rewrite scope h.lh_capacity;
              lh_body = rewrite body_scope h.lh_body;
            }
    in
    let node = { e with desc } in
    match node.desc with
    | CCall (kind, callee, args) -> rewrite_call scope node kind callee args
    | CBin (op, lhs, _rhs) ->
        (match binop_method op with
        | Some method_name ->
            ignore (try_enqueue_impl_for_method state method_name lhs.ty)
        | None -> ());
        node
    | CUn (op, operand) ->
        (match unop_method op with
        | Some method_name ->
            ignore (try_enqueue_impl_for_method state method_name operand.ty)
        | None -> ());
        node
    | _ -> node
  in
  rewrite initial_scope e

let rewrite_func (state : mono_state) (f : core_func) : core_func =
  match f.cf_body with
  | None -> f
  | Some body ->
      let prev = state.current_module_path in
      state.current_module_path <- Option.value f.cf_module ~default:"";
      let initial_scope =
        List.map (fun (p : core_param) -> p.cp_name) f.cf_params
        |> scope_add_vars StringSet.empty
      in
      let result =
        { f with cf_body = Some (scan_and_rewrite ~initial_scope state body) }
      in
      state.current_module_path <- prev;
      result

let rewrite_var (state : mono_state) (v : core_var) : core_var =
  let prev = state.current_module_path in
  state.current_module_path <- Option.value v.cv_module ~default:"";
  let result = { v with cv_init = scan_and_rewrite state v.cv_init } in
  state.current_module_path <- prev;
  result

let rewrite_impl (state : mono_state) (i : core_impl) : core_impl =
  { i with ci_methods = List.map (rewrite_func state) i.ci_methods }

let rec rewrite_decl (state : mono_state) (d : core_decl) : core_decl =
  let desc' =
    match d.cd_desc with
    | CDFunc f -> CDFunc (rewrite_func state f)
    | CDVar v -> CDVar (rewrite_var state v)
    | CDImpl i -> CDImpl (rewrite_impl state i)
    | CDPrivate inner -> CDPrivate (rewrite_decl state inner)
    | other -> other
  in
  { d with cd_desc = desc' }

let drain_worklist (state : mono_state) (loc : Ast.loc) : unit =
  let rec loop () =
    match (state.worklist, state.impl_worklist) with
    | [], [] -> ()
    | func_batch, impl_batch ->
        state.worklist <- [];
        state.impl_worklist <- [];
        List.iter
          (fun (func_name, subst) ->
            match Hashtbl.find_opt state.generic_bodies func_name with
            | None -> ()
            | Some gf -> (
                match mangle_name func_name subst with
                | None -> ()
                | Some mangled ->
                    let specialized = specialize_func gf mangled subst in
                    let rewritten = rewrite_func state specialized in
                    state.specialized <-
                      {
                        cd_desc = CDFunc rewritten;
                        cd_loc = loc;
                        cd_doc = None;
                      }
                      :: state.specialized))
          func_batch;
        List.iter
          (fun (impl_def, subst) ->
            let specialized = specialize_impl impl_def subst in
            let rewritten = rewrite_impl state specialized in
            state.specialized_impls <-
              { cd_desc = CDImpl rewritten; cd_loc = loc; cd_doc = None }
              :: state.specialized_impls)
          impl_batch;
        loop ()
  in
  loop ()

(** Phase 2.7 Cluster 2: after mono completes, look for call sites in
    monomorphic function bodies that still reference a generic
    user-defined function body that would be dropped by emit
    ([cf_type_params <> []]). Such calls cause dangling C symbols at
    link time; we surface them here as a [Core_error] pointing at the
    call site so the user gets a blorp-level "cannot infer type
    argument" diagnostic instead of a pile of C errors.

    Scope:
    - Only flag calls in functions with [cf_type_params = []] (inside
      a generic body, non-concrete calls are expected — they'll be
      rewritten when the outer function is specialized).
    - Only flag when the callee resolves to a function with a body AND
      generic params — that's the case [emit_func] skips.
    - Skip builtins / foreign / closure-bodies — those don't need
      mono and won't dangle at emit. *)
let check_unrewritten_generic_calls (state : mono_state) (prog : core_program) :
    unit =
  let report_err name loc =
    let msg =
      Printf.sprintf
        "Cannot infer type argument for call to generic function '%s'" name
    in
    let hint =
      "add a type annotation that pins the type arguments — e.g. [x: SomeType \
       = Foo(...)] on the binding or a return-type annotation on the enclosing \
       function"
    in
    raise
      (Core_error.Core_error
         {
           phase = Core_error.Stage Core_stage.Mono;
           msg;
           loc;
           hint = Some hint;
         })
  in
  (* A qualified call [M.foo] that has a [Codegen_builtins.lookup]
     entry will be rewritten to [CKBuiltin c_name] by [Core_resolve].
     Migrated structural std APIs resolve directly to [CKIntrinsic].
     Neither path reaches emit as a call to the user-facing generic body,
     so skip them even when type arguments are unresolved. *)
  let resolves_without_mono alias_name field args =
    match lookup_alias_module state alias_name with
    | Some mod_path -> qualified_call_resolves_without_mono mod_path field args
    | None -> false
  in
  (* A bare call [foo(...)] can still have an explicit non-mono target:
     prelude builtins, selective imports whose module function has a
     runtime/IR-backed entry, or a stdlib module calling its own such
     function. Skip those so this check only reports calls that would
     genuinely dangle as unmaterialized generic user functions. *)
  let bare_resolves_without_mono ~mod_path name args =
    Codegen_builtins.lookup "" name <> None
    || mod_path <> ""
       && qualified_call_resolves_without_mono mod_path name args
    ||
    match
      if mod_path = "" then Hashtbl.find_opt state.import_aliases name
      else
        match Hashtbl.find_opt state.module_imports mod_path with
        | Some mod_aliases -> Hashtbl.find_opt mod_aliases name
        | None -> None
    with
    | Some (mp, orig_name) when orig_name <> "" ->
        qualified_call_resolves_without_mono mp orig_name args
    | _ -> false
  in
  (* Resolve a bare name the way [scan_and_rewrite] would: first try
     the enclosing module's imports, then the module's own prefixed generic,
     then the main program's imports. *)
  let resolve_bare_to_prefixed ~mod_path name =
    let from_module_imports () =
      match Hashtbl.find_opt state.module_imports mod_path with
      | Some mod_aliases -> (
          match Hashtbl.find_opt mod_aliases name with
          | Some (mp, orig_name) when orig_name <> "" ->
              Some (module_qualified_name mp orig_name)
          | _ -> None)
      | None -> None
    in
    let from_current_module () =
      if mod_path = "" then None
      else
        let prefixed = module_qualified_name mod_path name in
        if Hashtbl.mem state.generic_bodies prefixed then Some prefixed
        else None
    in
    let from_main_imports () =
      match Hashtbl.find_opt state.import_aliases name with
      | Some (mp, orig_name) when orig_name <> "" ->
          Some (module_qualified_name mp orig_name)
      | _ -> None
    in
    match from_module_imports () with
    | Some _ as hit -> hit
    | None -> (
        match from_current_module () with
        | Some _ as hit -> hit
        | None -> from_main_imports ())
  in
  let scan_body ~mod_path ~initial_scope (body : core) =
    let check_call scope node callee args =
      let target =
        match callee.desc with
        | CVar v when not (StringSet.mem v.vname scope) -> (
            if bare_resolves_without_mono ~mod_path v.vname args then None
            else
              match resolve_bare_to_prefixed ~mod_path v.vname with
              | Some prefixed -> Some prefixed
              | None when mod_path <> "" ->
                  Some (module_qualified_name mod_path v.vname)
              | None -> Some v.vname)
        | CField (obj, field) -> (
            match obj.desc with
            | CVar v
              when (not (StringSet.mem v.vname scope))
                   && not (resolves_without_mono v.vname field args) -> (
                match lookup_alias_module state v.vname with
                | Some mp -> Some (module_qualified_name mp field)
                | None -> None)
            | _ -> None)
        | _ -> None
      in
      match target with
      | Some n when Hashtbl.mem state.generic_bodies n -> report_err n node.loc
      | _ -> ()
    in
    let rec scan_ctree scope = function
      | CTLeaf { ct_bindings; ct_body } ->
          let body_scope =
            List.fold_left
              (fun acc binding -> scope_add_var acc binding.mb_var)
              scope ct_bindings
          in
          scan_expr body_scope ct_body
      | CTFail -> ()
      | CTSwitchTag sw ->
          List.iter (fun (_, sub) -> scan_ctree scope sub) sw.cts_cases;
          Option.iter (scan_ctree scope) sw.cts_default
      | CTSwitchLit sw ->
          List.iter (fun (_, sub) -> scan_ctree scope sub) sw.ctl_cases;
          scan_ctree scope sw.ctl_default
      | CTSwitchLen sw ->
          List.iter (fun (_, sub) -> scan_ctree scope sub) sw.ctl_len_cases;
          Option.iter (fun (_, sub) -> scan_ctree scope sub) sw.ctl_len_geq;
          Option.iter (scan_ctree scope) sw.ctl_len_default
    and scan_expr scope e =
      let scan_boxed_storage scope value =
        scan_expr scope value.bsv_box.box_value
      in
      match e.desc with
      | CLit _ | CVar _ | CVoid | CBreak | CContinue | CCooperativeCheckpoint ->
          ()
      | CResourceCleanupExit exit ->
          List.iter (scan_expr scope) exit.rce_cleanups
      | CTuple xs | CVector xs -> List.iter (scan_expr scope) xs
      | CTupleConstruct tc -> List.iter (scan_boxed_storage scope) tc.tc_elems
      | CList lit -> List.iter (scan_expr scope) lit.ll_elems
      | CListConstruct lc -> List.iter (scan_boxed_storage scope) lc.lc_elems
      | CListAlloc alloc -> scan_expr scope alloc.la_capacity
      | CListGet get ->
          scan_expr scope get.lg_list;
          scan_expr scope get.lg_index
      | CStringByteRead r ->
          scan_expr scope r.sbr_source;
          scan_expr scope r.sbr_index
      | CStringByteWrite w ->
          scan_expr scope w.sbw_target;
          scan_expr scope w.sbw_index;
          scan_expr scope w.sbw_byte
      | CStringByteCopy c ->
          scan_expr scope c.sbc_dst;
          scan_expr scope c.sbc_dst_pos;
          scan_expr scope c.sbc_src;
          scan_expr scope c.sbc_src_pos;
          scan_expr scope c.sbc_len
      | CStringSetLen s ->
          scan_expr scope s.ssl_target;
          scan_expr scope s.ssl_len
      | CTensorLiteral tl -> (
          match tl.tl_payload with
          | TensorRawElements (_, elems) -> List.iter (scan_expr scope) elems
          | TensorWordElements elems -> List.iter (scan_expr scope) elems
          | TensorPackedElements (_, elems) -> List.iter (scan_expr scope) elems
          | TensorInlineStructElements (_, elems) ->
              List.iter (scan_expr scope) elems
          | TensorBoxedElements elems ->
              List.iter (scan_boxed_storage scope) elems)
      | CDict kvs ->
          List.iter
            (fun (k, v) ->
              scan_expr scope k;
              scan_expr scope v)
            kvs
      | CDictConstruct dc ->
          List.iter
            (fun (k, v) ->
              scan_boxed_storage scope k;
              scan_boxed_storage scope v)
            dc.dc_entries
      | CSetAlloc _ -> ()
      | CRecord fs -> List.iter (fun (_, value) -> scan_expr scope value) fs
      | CRecordConstruct rc ->
          List.iter
            (function
              | RecordRawField (_, value) -> scan_expr scope value
              | RecordErasedField (_, value) -> scan_boxed_storage scope value)
            rc.rc_fields
      | CUnionConstruct uc -> List.iter (scan_boxed_storage scope) uc.uc_args
      | CUnionReuseConstruct urc ->
          scan_expr scope urc.urc_source;
          List.iter (scan_boxed_storage scope) urc.urc_args
      | CRecordUpdate (base, fs) ->
          scan_expr scope base;
          List.iter (fun (_, value) -> scan_expr scope value) fs
      | CRange (a, b) | CBin (_, a, b) | CLog (_, a, b) | CSeq (a, b) ->
          scan_expr scope a;
          scan_expr scope b
      | CLambda lam ->
          let lam_scope =
            List.fold_left
              (fun acc (v, _) -> scope_add_var acc v)
              scope lam.lam_params
          in
          scan_expr lam_scope lam.lam_body
      | CUn (_, operand) -> scan_expr scope operand
      | CCall (_, callee, args) ->
          scan_expr scope callee;
          List.iter (scan_expr scope) args;
          check_call scope e callee args
      | CTensorRawRead r -> scan_expr scope r.trr_index
      | CTensorRawWrite w ->
          scan_expr scope w.trw_index;
          scan_expr scope w.trw_value
      | CField (obj, _) -> scan_expr scope obj
      | CStringInterp (parts, _) ->
          List.iter
            (function IPLit _ -> () | IPExpr expr -> scan_expr scope expr)
            parts
      | CLet (binding, body) ->
          scan_expr scope binding.bind_rhs;
          scan_expr (scope_add_var scope binding.bind_var) body
      | CBorrowLet (binding, body) ->
          scan_expr scope binding.borrow_rhs;
          scan_expr (scope_add_var scope binding.borrow_var) body
      | CTensorRawViewLet (binding, body) ->
          scan_expr scope binding.trv_source;
          scan_expr (scope_add_var scope binding.trv_var) body
      | CResourceScope s ->
          scan_expr scope s.rs_acquire;
          let scoped = scope_add_var scope s.rs_var in
          scan_expr scoped s.rs_body;
          scan_expr scoped s.rs_cleanup
      | CDebugBlock body -> scan_expr scope body
      | CIf (cond, then_, else_) ->
          scan_expr scope cond;
          scan_expr scope then_;
          scan_expr scope else_
      | CMatchArms (scrut, arms) ->
          scan_expr scope scrut;
          List.iter
            (fun (pat, arm_body) ->
              scan_expr (scope_add_pattern scope pat) arm_body)
            arms
      | CMatch (scrut, tree) ->
          scan_expr scope scrut;
          scan_ctree scope tree
      | CWhile (cond, loop_body) ->
          scan_expr scope cond;
          scan_expr scope loop_body
      | CFor (binder, iter, loop_body) ->
          scan_expr scope iter;
          scan_expr (scope_add_var scope binder.loop_var) loop_body
      | CSelect select ->
          List.iter
            (fun arm ->
              let body_scope =
                match arm.select_arm_kind with
                | SelectRecv r ->
                    scan_expr scope r.select_channel;
                    scope_add_var scope r.select_bind
                | SelectSealed channel ->
                    scan_expr scope channel;
                    scope
                | SelectAfter timeout ->
                    scan_expr scope timeout;
                    scope
              in
              scan_expr body_scope arm.select_arm_body)
            select.select_arms
      | CAssign (_, rhs) -> scan_expr scope rhs
      | CTailrecLoop (TailrecUnmanagedLoop l) -> scan_expr scope l.tul_body
      | CTailrecLoop (TailrecListSpreadLoop l) -> scan_expr scope l.tls_body
      | CTailrecRecur (TailrecRecur r) -> List.iter (scan_expr scope) r.tr_args
      | CTailrecRecur (TailrecListSpreadRecur r) ->
          List.iter (fun (_, arg) -> scan_expr scope arg) r.tr_rebinds
      | CDup (_, _, body) | CDrop (_, _, body) -> scan_expr scope body
      | CConcurrent cb ->
          List.iter (fun b -> scan_expr scope b.cb_rhs) cb.conc_bindings;
          Option.iter (scan_expr scope) cb.conc_timeout;
          let body_scope =
            List.fold_left
              (fun acc b -> scope_add_var acc b.cb_var)
              scope cb.conc_bindings
          in
          scan_expr body_scope cb.conc_body
      | CConcurrentlyLoop cf ->
          scan_expr scope cf.cf_iter;
          Option.iter (scan_expr scope) cf.cf_timeout;
          scan_expr (scope_add_var scope cf.cf_var) cf.cf_body
      | CDetach d -> scan_expr scope d.detach_body
      | CCast (expr, _) | CUnbox (expr, _) | CBox (expr, _) ->
          scan_expr scope expr
      | CUnboxTyped u -> scan_expr scope u.unbox_value
      | CBoxTyped b -> scan_expr scope b.box_value
      | CListHandoff h ->
          scan_expr scope h.lh_source;
          scan_expr scope h.lh_capacity;
          let body_scope =
            scope_add_vars scope
              [ h.lh_source_var; h.lh_result_var; h.lh_len_var; h.lh_out_var ]
          in
          scan_expr body_scope h.lh_body
    in
    scan_expr initial_scope body
  in
  let rec walk_decl d =
    match d.cd_desc with
    | CDFunc f when f.cf_type_params = [] && is_builtin_kind f.cf_kind = false
      -> (
        let mod_path = Option.value f.cf_module ~default:"" in
        let initial_scope =
          List.map (fun (p : core_param) -> p.cp_name) f.cf_params
          |> scope_add_vars StringSet.empty
        in
        match f.cf_body with
        | Some b -> scan_body ~mod_path ~initial_scope b
        | None -> ())
    | CDVar v ->
        scan_body
          ~mod_path:(Option.value v.cv_module ~default:"")
          ~initial_scope:StringSet.empty v.cv_init
    | CDImpl i ->
        List.iter
          (fun (f : core_func) ->
            if f.cf_type_params = [] && is_builtin_kind f.cf_kind = false then
              let mod_path = Option.value f.cf_module ~default:"" in
              let initial_scope =
                List.map (fun (p : core_param) -> p.cp_name) f.cf_params
                |> scope_add_vars StringSet.empty
              in
              match f.cf_body with
              | Some b -> scan_body ~mod_path ~initial_scope b
              | None -> ())
          i.ci_methods
    | CDPrivate inner -> walk_decl inner
    | _ -> ()
  in
  List.iter walk_decl prog

(** Monomorphize a Core program.

    Scans all declarations, rewrites call sites inline to mangled
    names, drains the worklist to fixpoint (specialized bodies are
    also scanned and rewritten), and appends specialized functions.

    [reg] is the per-compilation registry — passed to [collect_subst] so
    type-alias-wrapped parameter signatures unify against concrete call
    sites. Defaults to an empty registry for callers that don't use aliases
    (pure unit tests). *)
let monomorphize_program ?(reg = Codegen_types.create_registry ())
    ?(import_aliases = Hashtbl.create 0) ?(module_imports = Hashtbl.create 0)
    (prog : core_program) : core_program =
  let state = create_state ~reg ~import_aliases ~module_imports () in
  let loc = Ast.dummy_loc in
  collect_generic_bodies state prog;
  let prog =
    if
      Hashtbl.length state.generic_bodies = 0
      && Hashtbl.length state.generic_impls_by_method = 0
    then prog
    else begin
      let prog = List.map (rewrite_decl state) prog in
      drain_worklist state loc;
      let final =
        prog @ List.rev state.specialized @ List.rev state.specialized_impls
      in
      check_unrewritten_generic_calls state final;
      final
    end
  in
  if
    Hashtbl.length state.generic_records = 0
    && Hashtbl.length state.generic_types = 0
  then prog
  else begin
    state.specialized_records <- [];
    state.specialized_types <- [];
    Hashtbl.clear state.generated_record_names;
    Hashtbl.clear state.in_progress_record_names;
    Hashtbl.clear state.generated_type_names;
    Hashtbl.clear state.in_progress_type_names;
    monomorphize_generic_data state prog
  end
