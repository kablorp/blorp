(** Rewrites evaluated CTFE values back into ordinary typed declarations. *)

open Ctfe_value

let ( >>= ) = Result.bind
let ( let* ) = Result.bind

let make_expr ?resolved_call loc ty desc =
  let ast = Ast.untyped_expr ~loc desc in
  match
    Typed_ast.of_ast_expr_with_type_info
      ~context:"compile-time materialized initializer" ?resolved_call
      ~semantic_ty:ty ~value_ty:ty ~widening:(Type_widening_metadata.Keep ty)
      ast
  with
  | Ok typed -> Ok (Typed_ast.ast typed)
  | Error err -> Error [ Ctfe_error.typed_ast_error_to_error err ]

let constructor_resolved_call name info params return =
  Option.map
    (fun callable_id ->
      {
        Ast.call_syntax = Ast.CallBare;
        call_target =
          Ast.CallDirect
            {
              callable_id;
              source_name = name;
              call_pure = true;
              origin = Ast.CallableConstructor info.constructor_parent_type;
            };
        instantiated_params = params;
        instantiated_return = return;
      })
    info.constructor_callable_id

let synthetic_constructor_call value name arg_values arg_exprs info =
  let params = List.map (fun arg -> arg.ty) arg_values in
  let callee_ty = Ast.TyFunc { params; return = value.ty; is_pure = true } in
  let resolved_call = constructor_resolved_call name info params value.ty in
  make_expr value.loc callee_ty (Ast.EIdent name) >>= fun callee ->
  make_expr ?resolved_call value.loc value.ty (Ast.ECall (callee, arg_exprs))

let rec value_to_expr value =
  match value.desc with
  | VInt n -> make_expr value.loc value.ty (Ast.ELiteral (Ast.LitInt n))
  | VFloat n -> make_expr value.loc value.ty (Ast.ELiteral (Ast.LitFloat n))
  | VBool b -> make_expr value.loc value.ty (Ast.ELiteral (Ast.LitBool b))
  | VChar c -> make_expr value.loc value.ty (Ast.ELiteral (Ast.LitChar c))
  | VString (s, flags) ->
      make_expr value.loc value.ty (Ast.ELiteral (Ast.LitString (s, flags)))
  | VTuple values ->
      value_to_exprs values >>= fun values ->
      make_expr value.loc value.ty (Ast.ETuple values)
  | VList values ->
      value_to_exprs values >>= fun values ->
      make_expr value.loc value.ty (Ast.EList values)
  | VVector values ->
      value_to_exprs values >>= fun values ->
      make_expr value.loc value.ty (Ast.EVector values)
  | VDict pairs ->
      value_pairs_to_exprs pairs >>= fun pairs ->
      make_expr value.loc value.ty (Ast.EDict pairs)
  | VRecord fields ->
      value_fields_to_exprs fields >>= fun fields ->
      make_expr value.loc value.ty (Ast.ERecord fields)
  | VRange (start_value, end_value) ->
      value_to_expr start_value >>= fun start_expr ->
      value_to_expr end_value >>= fun end_expr ->
      make_expr value.loc value.ty (Ast.ERange (start_expr, end_expr))
  | VVoid -> make_expr value.loc value.ty Ast.EVoid
  | VClosure
      {
        closure_env = [];
        closure_origin =
          ClosureLocalFunctionReference { reference_name; reference_call };
        _;
      } ->
      make_expr ?resolved_call:reference_call value.loc value.ty
        (Ast.EIdent reference_name)
  | VClosure { closure_func; closure_env; closure_origin = ClosureLambda } ->
      if Ctfe_env.has_local_bindings closure_env then
        Error
          [
            Ctfe_error.error value.loc
              "compile-time function values that capture local bindings cannot \
               be materialized as global data";
          ]
      else make_expr value.loc value.ty (Ast.ELambda closure_func.function_ast)
  | VClosure _ ->
      Error
        [
          Ctfe_error.error value.loc
            "compile-time constant evaluation cannot materialize function \
             values as global data";
        ]
  | VConstructor { name; args; constructor_info; constructor_origin } -> (
      value_to_exprs args >>= fun arg_exprs ->
      match (constructor_origin, arg_exprs) with
      | ConstructorSourceCall { callee; resolved_call }, _ ->
          make_expr ?resolved_call value.loc value.ty
            (Ast.ECall (callee, arg_exprs))
      | ConstructorSynthesized, [] ->
          make_expr value.loc value.ty (Ast.EIdent name)
      | ConstructorSynthesized, _ ->
          synthetic_constructor_call value name args arg_exprs constructor_info)

and value_to_exprs values =
  let rec loop acc = function
    | [] -> Ok (List.rev acc)
    | value :: rest -> (
        match value_to_expr value with
        | Ok expr -> loop (expr :: acc) rest
        | Error _ as err -> err)
  in
  loop [] values

and value_fields_to_exprs fields =
  let rec loop acc = function
    | [] -> Ok (List.rev acc)
    | (name, value) :: rest -> (
        match value_to_expr value with
        | Ok expr -> loop ((name, expr) :: acc) rest
        | Error _ as err -> err)
  in
  loop [] fields

and value_pairs_to_exprs pairs =
  let rec loop acc = function
    | [] -> Ok (List.rev acc)
    | (key, value) :: rest -> (
        match (value_to_expr key, value_to_expr value) with
        | Ok key, Ok value -> loop ((key, value) :: acc) rest
        | Error errors, _ | _, Error errors -> Error errors)
  in
  loop [] pairs

let global_var_decl ?(private_ = false) ?doc ~loc typed_var value =
  let* value_expr = value_to_expr value in
  let ast_var =
    {
      (Typed_ast.var_ast typed_var) with
      Ast.var_value = value_expr;
      var_is_mutable = false;
      var_is_const = true;
    }
  in
  let typed_var = Typed_ast.with_var_ast typed_var ast_var in
  let inner_ast_decl =
    { Ast.decl_desc = Ast.DVar ast_var; decl_loc = loc; decl_doc = doc }
  in
  let inner_typed_decl = Typed_ast.make_var_decl inner_ast_decl typed_var in
  if private_ then
    let ast_decl =
      {
        Ast.decl_desc = Ast.DPrivate inner_ast_decl;
        decl_loc = loc;
        decl_doc = None;
      }
    in
    Ok (Typed_ast.make_private_decl ast_decl inner_typed_decl)
  else Ok inner_typed_decl
