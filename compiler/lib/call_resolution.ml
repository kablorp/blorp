(** Shared call-resolution metadata helpers. *)

type callee_resolution = {
  callee_ty : Ast.type_expr;
  callee_expr : Ast.expr;
  source_callee : Ast.expr;
  args : Ast.expr list;
  resolved_trait : (string * string * bool * int option) option;
  resolved_target : Ast.resolved_call_target option;
  syntax_hint : Ast.call_syntax option;
}

let strip_callable_id_suffix name =
  match String.index_opt name '#' with
  | Some idx -> String.sub name 0 idx
  | None -> name

let parse_callable_id_suffix name =
  match String.index_opt name '#' with
  | Some idx when idx + 1 < String.length name ->
      String.sub name (idx + 1) (String.length name - idx - 1)
      |> int_of_string_opt
  | _ -> None

let is_ufcs_mangled_name name =
  let clean = strip_callable_id_suffix name in
  String.length clean >= 7 && String.sub clean 0 7 = "__ufcs_"

let parse_ufcs_name name =
  let prefix = "__ufcs_" in
  if not (String.starts_with ~prefix name) then None
  else
    let rest =
      String.sub name (String.length prefix)
        (String.length name - String.length prefix)
    in
    let rec find_separator index =
      if index < 1 then None
      else if rest.[index - 1] = '_' && rest.[index] = '_' then Some (index - 1)
      else find_separator (index - 1)
    in
    match find_separator (String.length rest - 1) with
    | None -> None
    | Some separator ->
        let module_part = String.sub rest 0 separator in
        let source_name =
          String.sub rest (separator + 2)
            (String.length rest - separator - 2)
        in
        let module_path =
          String.map (fun ch -> if ch = '$' then '/' else ch) module_part
        in
        Some (module_path, source_name)

let call_purity_bool = function Env.Pure -> true | Env.Impure -> false

let callable_origin_of_env ~(module_path : string option)
    (origin : Env.func_origin) : Ast.callable_origin =
  match origin with
  | Env.Builtin -> Ast.CallableBuiltin
  | Env.Foreign -> Ast.CallableForeign
  | Env.UserDefined -> (
      match module_path with
      | Some path -> Ast.CallableImported path
      | None -> Ast.CallableLocal)

let get_callee_name (callee : Ast.expr) : string option =
  match callee.expr_desc with
  | Ast.EIdent name -> Some name
  | Ast.EFieldAccess (_, name) -> Some name
  | _ -> None

let has_flexible_lambda args =
  List.exists
    (fun (arg : Ast.expr) ->
      match arg.expr_desc with
      | Ast.ELambda f when not f.func_is_pure -> true
      | _ -> false)
    args

let overload_pure_callback_count (entry : Env.overload_entry) =
  match entry.ol_func_type with
  | Ast.TyFunc { params; _ } ->
      List.fold_left
        (fun acc param_ty ->
          match param_ty with
          | Ast.TyFunc { is_pure = true; _ } -> acc + 1
          | _ -> acc)
        0 params
  | _ -> 0

let select_by_typed_args entries arg_tys =
  Env.select_overload_for_args entries arg_tys

let select_by_first_arg env name first_arg_ty =
  Option.bind first_arg_ty (Env.resolve_overload env name)

let nominal_head_name = function
  | Ast.TyNamed (name, _) -> Some name
  | _ -> None

let filter_by_first_arg entries first_arg_ty =
  match first_arg_ty with
  | None -> entries
  | Some first_arg_ty ->
      let first_arg_head = nominal_head_name first_arg_ty in
      List.filter
        (fun (entry : Env.overload_entry) ->
          match entry.ol_func_type with
          | Ast.TyFunc { params = first_param :: _; _ } -> (
              match (nominal_head_name first_param, first_arg_head) with
              | Some pn, Some an -> pn = an
              | None, _ ->
                  Types.types_compatible
                    ~type_params:(Env.overload_type_param_names entry)
                    first_param first_arg_ty
              | _ -> false)
          | _ -> false)
        entries

let same_receiver_pair (a : Env.overload_entry) (b : Env.overload_entry) =
  match (a.ol_func_type, b.ol_func_type) with
  | Ast.TyFunc { params = ap :: _; _ }, Ast.TyFunc { params = bp :: _; _ } -> (
      match (nominal_head_name ap, nominal_head_name bp) with
      | Some an, Some bn -> an = bn
      | None, None -> true
      | _ -> false)
  | _ -> false

let select_by_context_purity ~current_function_pure ~overloads ~first_arg_ty =
  match filter_by_first_arg overloads first_arg_ty with
  | [ a; b ] when a.Env.ol_purity <> b.Env.ol_purity ->
      if not (same_receiver_pair a b) then None
      else
        let preferred_purity =
          if current_function_pure then Env.Pure else Env.Impure
        in
        List.find_opt
          (fun entry -> entry.Env.ol_purity = preferred_purity)
          [ a; b ]
  | _ -> None

let call_syntax_of_source_callee ~module_aliases ~(source_callee : Ast.expr)
    target =
  match target with
  | Ast.CallClosure _ -> Ast.CallClosureSyntax
  | Ast.CallDirect { source_name; _ } when is_ufcs_mangled_name source_name ->
      Ast.CallMethodOnlyUfcs
  | _ -> (
      match source_callee.expr_desc with
      | Ast.EFieldAccess ({ expr_desc = Ast.EIdent alias; _ }, _) -> (
          match Checker_query.module_alias_path module_aliases alias with
          | Some module_path -> Ast.CallQualified module_path
          | None -> Ast.CallMethod)
      | Ast.EFieldAccess _ -> Ast.CallMethod
      | Ast.EIdent _ -> (
          match target with
          | Ast.CallTraitMethod _ -> Ast.CallTraitDispatch
          | _ -> Ast.CallBare)
      | _ -> Ast.CallClosureSyntax)

let resolved_target_from_overload name (entry : Env.overload_entry) =
  let source_name = strip_callable_id_suffix name in
  Ast.CallDirect
    {
      callable_id = entry.ol_def_id;
      source_name;
      call_pure = call_purity_bool entry.ol_purity;
      origin =
        callable_origin_of_env ~module_path:entry.ol_module_path entry.ol_origin;
    }

let resolved_target_from_callee ~env ~callee_name ~callee_ty =
  match callee_name with
  | Some name -> (
      match Env.lookup env name with
      | Some
          {
            kind =
              Env.FuncSymbol { callable_id; purity; origin; module_path; _ };
            _;
          } ->
          Some
            (Ast.CallDirect
               {
                 callable_id;
                 source_name = strip_callable_id_suffix name;
                 call_pure = call_purity_bool purity;
                 origin = callable_origin_of_env ~module_path origin;
               })
      | Some
          { kind = Env.ConstructorSymbol { parent_type; constructor_id; _ }; _ }
        ->
          Some
            (Ast.CallDirect
               {
                 callable_id = constructor_id;
                 source_name = strip_callable_id_suffix name;
                 call_pure = true;
                 origin = Ast.CallableConstructor parent_type;
               })
      | Some { kind = Env.VarSymbol { var_type; _ }; _ } -> (
          match Env.function_type_purity env var_type with
          | Some purity ->
              Some (Ast.CallClosure { call_pure = call_purity_bool purity })
          | None -> None)
      | _ -> (
          match parse_callable_id_suffix name with
          | Some callable_id ->
              let call_pure =
                match callee_ty with
                | Ast.TyFunc { is_pure; _ } -> is_pure
                | _ -> false
              in
              Some
                (Ast.CallDirect
                   {
                     callable_id;
                     source_name = strip_callable_id_suffix name;
                     call_pure;
                     origin = Ast.CallableImported "";
                   })
          | None -> (
              match callee_ty with
              | Ast.TyFunc { is_pure; _ } ->
                  Some (Ast.CallClosure { call_pure = is_pure })
              | _ -> None)))
  | None -> (
      match callee_ty with
      | Ast.TyFunc { is_pure; _ } ->
          Some (Ast.CallClosure { call_pure = is_pure })
      | _ -> None)

let resolved_call_metadata ?call_syntax_hint ~module_aliases
    ~resolved_target_from_qualified ~source_callee ~resolved_callee
    ~resolved_overload ~resolved_trait ~resolved_target_hint ~callee_ty
    ~instantiated_params ~instantiated_return env =
  let callee_name = get_callee_name resolved_callee in
  let target =
    match
      (resolved_target_hint, resolved_trait, callee_name, resolved_overload)
    with
    | Some target, _, _, _ -> Some target
    | None, Some (trait_name, method_name, call_pure, callable_id), _, _ ->
        Some
          (Ast.CallTraitMethod
             { trait_name; method_name; call_pure; callable_id })
    | None, None, Some name, Some entry ->
        Some (resolved_target_from_overload name entry)
    | None, None, _, None -> (
        match resolved_target_from_qualified resolved_callee with
        | Some target -> Some target
        | None -> resolved_target_from_callee ~env ~callee_name ~callee_ty)
    | None, None, None, Some _ -> None
  in
  Option.map
    (fun call_target ->
      {
        Ast.call_syntax =
          Option.value call_syntax_hint
            ~default:
              (call_syntax_of_source_callee ~module_aliases ~source_callee
                 call_target);
        call_target;
        instantiated_params;
        instantiated_return;
      })
    target
