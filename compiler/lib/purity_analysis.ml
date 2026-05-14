(** Shared purity and effect-call analysis for inferred ASTs. *)

open Ast

type call_ref = { called_name : string; call_loc : loc }

let is_impure_builtin (name : string) : bool = Builtin_metadata.is_impure name

let source_call_name (name : string) : string =
  let without_def_id =
    match String.index_opt name '#' with
    | Some idx -> String.sub name 0 idx
    | None -> name
  in
  match Codegen_names.parse_ufcs_name without_def_id with
  | Some (_module_path, source_name) -> source_name
  | None -> without_def_id

let parallel_function_name (name : string) : string option =
  let source_name = source_call_name name in
  if Builtin_metadata.is_parallel_boundary source_name then Some source_name
  else None

let rec collect_matching_calls
    ~(match_call : string -> expr -> loc -> expr list -> call_ref list)
    ~(enter_lambda : func_decl -> bool)
    ?(check_non_ident_callee : (expr -> loc -> call_ref list) option)
    (expr : expr) : call_ref list =
  let recurse =
    collect_matching_calls ~match_call ~enter_lambda ?check_non_ident_callee
  in
  match expr.expr_desc with
  | ECall (callee, args) ->
      let callee_matches =
        match callee.expr_desc with
        | EIdent name -> match_call name callee expr.expr_loc args
        | EFieldAccess (_, method_name) ->
            match_call method_name callee expr.expr_loc args
        | _ -> (
            match check_non_ident_callee with
            | Some check -> check callee expr.expr_loc
            | None -> [])
      in
      callee_matches @ List.concat_map recurse (expr_children expr)
  | ELambda func ->
      if enter_lambda func then
        match func_body_expr_opt func.func_body with
        | Some body -> recurse body
        | None -> []
      else []
  | EDetach body ->
      { called_name = "detach"; call_loc = expr.expr_loc } :: recurse body
  | EConcurrent _ ->
      { called_name = "concurrent"; call_loc = expr.expr_loc }
      :: List.concat_map recurse (expr_children expr)
  | EConcurrentFor _ ->
      { called_name = "concurrent for"; call_loc = expr.expr_loc }
      :: List.concat_map recurse (expr_children expr)
  | _ -> List.concat_map recurse (expr_children expr)

let collect_parallel_calls : expr -> call_ref list =
  collect_matching_calls
    ~match_call:(fun name _callee loc _args ->
      match parallel_function_name name with
      | Some called_name -> [ { called_name; call_loc = loc } ]
      | None -> [])
    ~enter_lambda:(fun _ -> true)

let expr_function_purity (env : Env.env) (expr : expr) : Env.purity option =
  match expr.expr_type_info with
  | Some info -> Env.function_type_purity env info.semantic_ty
  | None -> None

let func_arg_purity (env : Env.env) (arg : expr) : Env.purity option =
  match arg.expr_type_info with
  | Some info -> Env.function_type_purity env info.semantic_ty
  | None -> (
      match arg.expr_desc with
      | ELambda func ->
          Some (if func.func_is_pure then Env.Pure else Env.Impure)
      | EIdent name -> (
          match Env.lookup env name with
          | Some { kind = Env.FuncSymbol { purity; _ }; _ } -> Some purity
          | Some { kind = Env.VarSymbol { var_type; _ }; _ } ->
              Env.function_type_purity env var_type
          | _ -> None)
      | _ -> None)

let all_func_args_pure (env : Env.env) (args : expr list) : bool =
  List.for_all
    (fun arg ->
      match func_arg_purity env arg with
      | Some Env.Impure -> false
      | Some Env.Pure | None -> true)
    args

let has_func_typed_args (env : Env.env) (args : expr list) : bool =
  List.exists (fun arg -> Option.is_some (func_arg_purity env arg)) args

let impure_func_arg_refs (env : Env.env) (args : expr list) : call_ref list =
  List.filter_map
    (fun arg ->
      match func_arg_purity env arg with
      | Some Env.Impure ->
          let called_name =
            match arg.expr_desc with
            | ELambda _ -> "<impure lambda>"
            | EIdent name -> name
            | _ -> "<impure callback>"
          in
          Some { called_name; call_loc = arg.expr_loc }
      | Some Env.Pure | None -> None)
    args

let has_pure_overload (env : Env.env) (name : string) : bool =
  List.exists
    (fun (e : Env.overload_entry) -> e.ol_purity = Env.Pure)
    (Env.get_overloads env name)
  ||
  match Hashtbl.find_opt env.ufcs_methods name with
  | Some entries ->
      List.exists
        (fun (e : Env.overload_entry) -> e.ol_purity = Env.Pure)
        entries
  | None -> false

let is_pure_module_call (callee : expr)
    (module_aliases : (string * string) list) : bool =
  match callee.expr_desc with
  | EFieldAccess ({ expr_desc = EIdent mod_alias; _ }, func_name) -> (
      match List.assoc_opt mod_alias module_aliases with
      | Some mod_path -> (
          match Modules.find_cached mod_path with
          | Some m ->
              List.exists
                (fun (name, decl) ->
                  name = func_name
                  &&
                  match decl.decl_desc with
                  | DFunc f -> f.func_is_pure
                  | _ -> false)
                m.Modules.exports
          | None -> false)
      | None -> false)
  | _ -> false

let is_module_qualified_call (callee : expr)
    (module_aliases : (string * string) list) : bool =
  match callee.expr_desc with
  | EFieldAccess ({ expr_desc = EIdent mod_alias; _ }, _) ->
      List.mem_assoc mod_alias module_aliases
  | _ -> false

let callee_type_is_impure (env : Env.env) (callee : expr) : bool =
  match expr_function_purity env callee with
  | Some Env.Impure -> true
  | Some Env.Pure | None -> false

let collect_impure_calls ?(enter_lambda = fun func -> func.func_is_pure) ~strict
    (env : Env.env) (module_aliases : (string * string) list) :
    expr -> call_ref list =
  collect_matching_calls
    ~match_call:(fun name callee loc args ->
      if is_pure_module_call callee module_aliases then []
      else if is_impure_builtin name then
        match Env.lookup env name with
        | Some { kind = Env.FuncSymbol { purity = Env.Pure; _ }; _ } -> []
        | Some { kind = Env.VarSymbol { var_type; _ }; _ } -> (
            match Env.function_type_purity env var_type with
            | Some Env.Impure -> [ { called_name = name; call_loc = loc } ]
            | Some Env.Pure | None -> [])
        | _ -> [ { called_name = name; call_loc = loc } ]
      else if
        strict
        && (not (is_module_qualified_call callee module_aliases))
        && has_func_typed_args env args
        && has_pure_overload env name
      then
        if all_func_args_pure env args then []
        else impure_func_arg_refs env args
      else if callee_type_is_impure env callee then
        [ { called_name = name; call_loc = loc } ]
      else
        match Env.lookup env name with
        | Some { kind = Env.FuncSymbol { purity = Env.Impure; _ }; _ } ->
            [ { called_name = name; call_loc = loc } ]
        | Some { kind = Env.FuncSymbol { purity = Env.Pure; _ }; _ } ->
            if
              strict
              && has_func_typed_args env args
              && not (all_func_args_pure env args)
            then impure_func_arg_refs env args
            else []
        | Some { kind = Env.VarSymbol _; _ } -> []
        | Some { kind = Env.ConstructorSymbol _; _ } -> []
        | _ ->
            if strict then
              let ufcs_has_pure =
                match Hashtbl.find_opt env.ufcs_methods name with
                | Some entries ->
                    List.exists
                      (fun (e : Env.overload_entry) -> e.ol_purity = Env.Pure)
                      entries
                | None -> false
              in
              if ufcs_has_pure then []
              else
                match expr_function_purity env callee with
                | Some Env.Pure -> []
                | Some Env.Impure -> [ { called_name = name; call_loc = loc } ]
                | _ -> []
            else [])
    ?check_non_ident_callee:
      (if strict then
         Some
           (fun callee loc ->
             match expr_function_purity env callee with
             | Some Env.Pure -> []
             | _ -> [ { called_name = "<expression>"; call_loc = loc } ])
       else None)
    ~enter_lambda

let can_upgrade_lambda_body_to_pure (env : Env.env)
    (module_aliases : (string * string) list) (body : expr) : bool =
  collect_impure_calls
    ~enter_lambda:(fun _ -> false)
    ~strict:true env module_aliases body
  = []
