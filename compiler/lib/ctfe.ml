(** Narrow compile-time evaluator for [compile_time:] top-level blocks.

    This first slice evaluates data expressions and simple pure computation,
    then rewrites each binding to an ordinary global initializer. It is
    deliberately explicit about unsupported expression forms so CTFE grows by
    adding named cases instead of guessing from runtime lowering behavior. *)

include Ctfe_value
include Ctfe_error
include Ctfe_env
include Ctfe_context
include Ctfe_value_ops
include Ctfe_operator
module Std_call = Ctfe_intrinsic.Source
module Intrinsic = Ctfe_intrinsic

let ( >>= ) = Result.bind
let ( let* ) = Result.bind

let rec eval_expr ctx env expr =
  let loc = value_loc expr in
  match Typed_ast.expr_desc expr with
  | Error err -> Error [ typed_ast_error_to_error err ]
  | Ok desc -> (
      match desc with
      | Typed_ast.ELiteral lit -> (
          match lit with
          | Ast.LitInt n -> scalar_value expr (VInt n)
          | Ast.LitFloat n -> scalar_value expr (VFloat n)
          | Ast.LitBool b -> scalar_value expr (VBool b)
          | Ast.LitChar c -> scalar_value expr (VChar c)
          | Ast.LitString (s, flags) -> scalar_value expr (VString (s, flags))
          | Ast.LitInt128 _ -> unsupported loc "Int128 literals")
      | Typed_ast.EIdent name -> (
          match lookup env loc name with
          | Ok value -> Ok value
          | Error _ as lookup_error -> (
              match eval_function_reference ctx expr with
              | Ok (Some value) -> Ok value
              | Ok None when constructor_is_nullary ctx name ->
                  scalar_value expr
                    (VConstructor
                       {
                         name;
                         args = [];
                         callee = None;
                         resolved_call = None;
                         constructor_info = constructor_info ctx name;
                       })
              | Ok None -> lookup_error
              | Error _ as err -> err))
      | Typed_ast.EAscription (inner, _)
      | Typed_ast.EOpaqueInto (_, inner)
      | Typed_ast.EOpaqueFrom (_, inner) ->
          eval_expr ctx env inner
      | Typed_ast.EUnary (Ast.Neg, inner) -> (
          eval_expr ctx env inner >>= fun value ->
          match value.desc with
          | VInt n -> scalar_value expr (VInt (Int64.neg n))
          | VFloat n -> scalar_value expr (VFloat (-.n))
          | _ ->
              Error
                [
                  error loc
                    (Printf.sprintf "compile_time cannot negate %s"
                       (type_name value.ty));
                ])
      | Typed_ast.EUnary (Ast.Not, inner) ->
          eval_expr ctx env inner >>= fun value ->
          expect_bool loc value >>= fun b -> scalar_value expr (VBool (not b))
      | Typed_ast.EBinary (op, left, right) ->
          eval_expr ctx env left >>= fun l ->
          eval_expr ctx env right >>= fun r ->
          eval_binary_desc loc op l r >>= fun desc -> scalar_value expr desc
      | Typed_ast.ELogical (Ast.And, left, right) ->
          eval_expr ctx env left >>= fun l ->
          expect_bool loc l >>= fun lb ->
          if not lb then scalar_value expr (VBool false)
          else
            eval_expr ctx env right >>= fun r ->
            expect_bool loc r >>= fun rb -> scalar_value expr (VBool rb)
      | Typed_ast.ELogical (Ast.Or, left, right) ->
          eval_expr ctx env left >>= fun l ->
          expect_bool loc l >>= fun lb ->
          if lb then scalar_value expr (VBool true)
          else
            eval_expr ctx env right >>= fun r ->
            expect_bool loc r >>= fun rb -> scalar_value expr (VBool rb)
      | Typed_ast.EIf (cond, then_expr, else_expr) -> (
          eval_expr ctx env cond >>= fun c ->
          expect_bool loc c >>= fun cb ->
          if cb then eval_expr ctx env then_expr
          else
            match else_expr with
            | Some else_expr -> eval_expr ctx env else_expr
            | None -> scalar_value expr VVoid)
      | Typed_ast.EBlock exprs -> eval_block ctx env expr exprs
      | Typed_ast.ETuple values ->
          eval_exprs ctx env values >>= fun values ->
          scalar_value expr (VTuple values)
      | Typed_ast.EList values ->
          eval_exprs ctx env values >>= fun values ->
          scalar_value expr (VList values)
      | Typed_ast.ERecord []
        when is_named_type Std_call.dict_type (value_type expr) ->
          scalar_value expr (VDict [])
      | Typed_ast.ERecord fields ->
          eval_fields ctx env fields >>= fun fields ->
          scalar_value expr (VRecord fields)
      | Typed_ast.EDict pairs ->
          eval_pairs ctx env pairs >>= fun pairs ->
          scalar_value expr (VDict pairs)
      | Typed_ast.EFieldAccess (receiver, field) -> (
          eval_expr ctx env receiver >>= fun value ->
          match value.desc with
          | VRecord fields -> (
              match List.assoc_opt field fields with
              | Some value -> Ok value
              | None ->
                  Error
                    [
                      error loc
                        (Printf.sprintf "compile_time record has no field '%s'"
                           field);
                    ])
          | VTuple values -> (
              match int_of_string_opt field with
              | Some index when index >= 0 -> (
                  match List.nth_opt values index with
                  | Some value -> Ok value
                  | None ->
                      Error
                        [
                          error loc
                            (Printf.sprintf
                               "compile_time tuple has no field '%s'" field);
                        ])
              | _ -> unsupported loc "non-numeric tuple field access")
          | _ -> unsupported loc "field access on non-record/non-tuple values")
      | Typed_ast.ERecordUpdate (base, fields) ->
          eval_record_update ctx env expr base fields
      | Typed_ast.EStringInterp (parts, is_multiline) ->
          eval_string_interp ctx env expr parts is_multiline
      | Typed_ast.ELambda func -> eval_lambda env expr func
      | Typed_ast.ECall (callee, args) -> eval_call ctx env expr callee args
      | Typed_ast.EMatch (scrutinee, cases) ->
          eval_match ctx env loc scrutinee cases
      | Typed_ast.EWhile (cond, body) -> eval_while ctx env expr cond body
      | Typed_ast.EFor (name, iter, body) ->
          eval_for ctx env expr name iter body
      | Typed_ast.EForTuple (names, iter, body) ->
          eval_for_tuple ctx env expr names iter body
      | Typed_ast.ERange (start_expr, end_expr) ->
          eval_expr ctx env start_expr >>= fun start_value ->
          eval_expr ctx env end_expr >>= fun end_value ->
          let* _ = expect_int loc start_value in
          let* _ = expect_int loc end_value in
          scalar_value expr (VRange (start_value, end_value))
      | Typed_ast.EAssign (name, rhs) ->
          eval_expr ctx env rhs >>= fun value -> assign env loc name value
      | Typed_ast.ECompoundAssign (name, op, rhs) ->
          lookup env loc name >>= fun current ->
          eval_expr ctx env rhs >>= fun value ->
          eval_binary_desc loc (Ast.binop_of_assign_op op) current value
          >>= fun desc ->
          let updated = { current with desc; loc } in
          assign env loc name updated
      | Typed_ast.EVector _ -> unsupported loc "vector literals"
      | Typed_ast.EVarDecl _ | Typed_ast.ETupleDestruct _ | Typed_ast.EBreak
      | Typed_ast.EContinue | Typed_ast.ESubscript _
      | Typed_ast.ESubscriptMulti _ | Typed_ast.ESubscriptAssign _
      | Typed_ast.EStringInterpRaw _ | Typed_ast.EQuestionBind _
      | Typed_ast.EWith _ | Typed_ast.EDebugBlock _ | Typed_ast.ESelect _
      | Typed_ast.EConcurrent _ | Typed_ast.EConcurrentBind _
      | Typed_ast.EConcurrentlyLoop _ | Typed_ast.EDetach _
      | Typed_ast.EBuiltin _ | Typed_ast.EFuncDecl _ | Typed_ast.ELoopView _
      | Typed_ast.EVoid ->
          unsupported loc "this expression form")

and eval_exprs ctx env exprs =
  let rec loop acc = function
    | [] -> Ok (List.rev acc)
    | expr :: rest -> (
        match eval_expr ctx env expr with
        | Ok value -> loop (value :: acc) rest
        | Error _ as err -> err)
  in
  loop [] exprs

and eval_fields ctx env fields =
  let rec loop acc = function
    | [] -> Ok (List.rev acc)
    | (name, expr) :: rest -> (
        match eval_expr ctx env expr with
        | Ok value -> loop ((name, value) :: acc) rest
        | Error _ as err -> err)
  in
  loop [] fields

and eval_pairs ctx env pairs =
  let rec loop acc = function
    | [] -> Ok (List.rev acc)
    | (key, value) :: rest -> (
        match (eval_expr ctx env key, eval_expr ctx env value) with
        | Ok key, Ok value -> loop ((key, value) :: acc) rest
        | Error errors, _ | _, Error errors -> Error errors)
  in
  loop [] pairs

and eval_record_update ctx env expr base updates =
  eval_expr ctx env base >>= fun base_value ->
  match base_value.desc with
  | VRecord base_fields ->
      eval_fields ctx env updates >>= fun update_values ->
      apply_record_updates (Typed_ast.loc expr) base_fields update_values
      >>= fun fields -> scalar_value expr (VRecord fields)
  | _ -> unsupported (Typed_ast.loc base) "record update on non-record values"

and apply_record_updates loc fields updates =
  let rec replace_field target_name target_value = function
    | [] ->
        Error
          [
            error loc
              (Printf.sprintf "compile_time record has no field '%s'"
                 target_name);
          ]
    | (field_name, _) :: rest when field_name = target_name ->
        Ok ((field_name, target_value) :: rest)
    | field :: rest ->
        replace_field target_name target_value rest >>= fun rest ->
        Ok (field :: rest)
  in
  let rec loop fields = function
    | [] -> Ok fields
    | update :: rest ->
        let name, value = update in
        replace_field name value fields >>= fun fields -> loop fields rest
  in
  loop fields updates

and eval_lambda env expr func =
  let ast_func = Typed_ast.func_ast func in
  if ast_func.func_is_pure then
    scalar_value expr
      (VClosure { closure_func = func; closure_env = Ctfe_env.snapshot env })
  else unsupported (Typed_ast.loc expr) "impure lambdas"

and eval_function_reference ctx expr =
  let loc = Typed_ast.loc expr in
  match Typed_ast.expr_resolved_call expr with
  | Some
      {
        Ast.call_target =
          Ast.CallDirect
            { callable_id; source_name; call_pure; origin = Ast.CallableLocal };
        _;
      } -> (
      if not call_pure then unsupported loc "impure function references"
      else
        match function_by_callable_id ctx callable_id with
        | Some func ->
            scalar_value expr
              (VClosure { closure_func = func; closure_env = [] })
            >>= fun value -> Ok (Some value)
        | None ->
            Error
              [
                error loc
                  (Printf.sprintf
                     "internal CTFE error: local function reference '%s' has \
                      unknown callable id %d"
                     (Call_resolution.strip_callable_id_suffix source_name)
                     callable_id);
              ])
  | Some
      {
        Ast.call_target =
          Ast.CallDirect
            {
              source_name;
              call_pure = true;
              origin =
                ( Ast.CallableImported _ | Ast.CallableBuiltin
                | Ast.CallableForeign | Ast.CallableConstructor _
                | Ast.CallableImplMethod );
              _;
            };
        _;
      } ->
      unsupported loc
        (Printf.sprintf "function reference '%s'"
           (Call_resolution.strip_callable_id_suffix source_name))
  | Some { Ast.call_target = Ast.CallDirect { call_pure = false; _ }; _ } ->
      unsupported loc "impure function references"
  | Some { Ast.call_target = Ast.CallTraitMethod _ | Ast.CallClosure _; _ }
  | None ->
      Ok None

and eval_string_interp ctx env expr parts is_multiline =
  let string_of_value part_expr value =
    match string_text_of_value (Typed_ast.loc part_expr) value with
    | Ok text -> Ok text
    | Error _ ->
        Error
          [
            error (Typed_ast.loc part_expr)
              (Printf.sprintf
                 "compile_time string interpolation currently supports String, \
                  Int, Float, Bool, and Char expressions, found %s"
                 (type_name value.ty));
          ]
  in
  let rec loop acc = function
    | [] ->
        let text = String.concat "" (List.rev acc) in
        scalar_value expr (VString (text, string_flags_for_interp is_multiline))
    | Typed_ast.InterpLit text :: rest -> loop (text :: acc) rest
    | Typed_ast.InterpExpr part_expr :: rest ->
        eval_expr ctx env part_expr >>= fun value ->
        string_of_value part_expr value >>= fun text -> loop (text :: acc) rest
  in
  loop [] parts

and eval_block ctx env block_expr exprs =
  let rec loop env = function
    | [] -> unsupported Ast.dummy_loc "empty blocks"
    | [ expr ] -> eval_expr ctx env expr
    | expr :: rest -> (
        match Typed_ast.expr_desc expr with
        | Ok (Typed_ast.EVarDecl (name, _, init, is_mutable)) -> (
            match eval_expr ctx env init with
            | Ok value ->
                loop
                  (bind_value ~mutable_binding:is_mutable name value env)
                  rest
            | Error _ as err -> err)
        | Ok (Typed_ast.ETupleDestruct (names, init)) -> (
            match eval_expr ctx env init with
            | Ok { desc = VTuple values; _ }
              when List.length values = List.length names ->
                loop (bind_values (List.combine names values) env) rest
            | Ok value ->
                Error
                  [
                    error (Typed_ast.loc init)
                      (Printf.sprintf
                         "compile_time tuple destructuring expected %d values, \
                          found %s"
                         (List.length names) (type_name value.ty));
                  ]
            | Error _ as err -> err)
        | Ok (Typed_ast.EQuestionBind (name, _, rhs)) -> (
            match eval_question_bind ctx env block_expr name rhs with
            | Ok (`Continue env) -> loop env rest
            | Ok (`Return value) -> Ok value
            | Error _ as err -> err)
        | _ -> (
            match eval_expr ctx env expr with
            | Ok _ -> loop env rest
            | Error _ as err -> err))
  in
  loop env exprs

and eval_question_bind ctx env block_expr name rhs =
  let loc = Typed_ast.loc rhs in
  eval_expr ctx env rhs >>= fun carrier ->
  match option_state loc carrier with
  | Ok (OptionSome value) -> Ok (`Continue (bind_value name value env))
  | Ok OptionNone ->
      option_value ctx block_expr None >>= fun value -> Ok (`Return value)
  | Error _ -> (
      match result_state loc carrier with
      | Ok (ResultOk value) -> Ok (`Continue (bind_value name value env))
      | Ok (ResultErr value) ->
          result_err_value ctx block_expr value >>= fun value ->
          Ok (`Return value)
      | Error _ -> unsupported loc "?= on non-Option/non-Result values")

and eval_while ctx env expr cond body =
  let rec loop () =
    eval_expr ctx env cond >>= fun cond_value ->
    expect_bool (Typed_ast.loc cond) cond_value >>= fun keep_going ->
    if not keep_going then scalar_value expr VVoid
    else eval_expr ctx env body >>= fun _ -> loop ()
  in
  loop ()

and eval_for ctx env expr name iter body =
  eval_expr ctx env iter >>= fun iterable ->
  match iterable.desc with
  | VRange (start_value, end_value) ->
      expect_int (Typed_ast.loc iter) start_value >>= fun start_int ->
      expect_int (Typed_ast.loc iter) end_value >>= fun end_int ->
      let rec loop current =
        if current >= end_int then scalar_value expr VVoid
        else
          let item =
            { start_value with desc = VInt current; loc = iterable.loc }
          in
          eval_expr ctx (bind_value name item env) body >>= fun _ ->
          loop (Int64.succ current)
      in
      loop start_int
  | VList values ->
      let rec loop = function
        | [] -> scalar_value expr VVoid
        | value :: rest ->
            eval_expr ctx (bind_value name value env) body >>= fun _ ->
            loop rest
      in
      loop values
  | _ -> unsupported (Typed_ast.loc iter) "for loops over this iterable"

and eval_for_tuple ctx env expr names iter body =
  eval_expr ctx env iter >>= fun iterable ->
  match iterable.desc with
  | VList values ->
      let rec loop = function
        | [] -> scalar_value expr VVoid
        | value :: rest -> (
            match value.desc with
            | VTuple items when List.length items = List.length names ->
                let loop_env =
                  List.fold_left2
                    (fun env name value -> bind_value name value env)
                    env names items
                in
                eval_expr ctx loop_env body >>= fun _ -> loop rest
            | _ -> unsupported value.loc "tuple for loops over non-tuples")
      in
      loop values
  | _ -> unsupported (Typed_ast.loc iter) "tuple for loops over this iterable"

and eval_call ctx env call_expr callee args =
  match Typed_ast.expr_resolved_call call_expr with
  | None -> unsupported (Typed_ast.loc call_expr) "unresolved function calls"
  | Some
      {
        Ast.call_target =
          Ast.CallDirect { callable_id; source_name; call_pure; origin };
        _;
      } -> (
      if not call_pure then
        unsupported (Typed_ast.loc call_expr) "impure function calls"
      else
        match origin with
        | Ast.CallableLocal ->
            eval_exprs ctx env args >>= fun arg_values ->
            eval_local_function_call ctx env call_expr ~callable_id ~source_name
              arg_values
        | Ast.CallableImported module_path ->
            eval_imported_call ctx env call_expr ~module_path ~source_name args
        | Ast.CallableBuiltin ->
            eval_builtin_call ctx env call_expr ~source_name args
        | Ast.CallableForeign ->
            unsupported (Typed_ast.loc call_expr) "foreign function calls"
        | Ast.CallableConstructor parent_type ->
            eval_exprs ctx env args >>= fun arg_values ->
            let name = Call_resolution.strip_callable_id_suffix source_name in
            Ok
              {
                ty = value_type call_expr;
                desc =
                  VConstructor
                    {
                      name;
                      args = arg_values;
                      callee = Some (Typed_ast.ast callee);
                      resolved_call = Typed_ast.expr_resolved_call call_expr;
                      constructor_info =
                        Some
                          {
                            constructor_parent_type = parent_type;
                            constructor_arity = List.length arg_values;
                            constructor_callable_id = Some callable_id;
                          };
                    };
                loc = Typed_ast.loc call_expr;
              }
        | Ast.CallableImplMethod ->
            unsupported (Typed_ast.loc call_expr) "impl method calls")
  | Some
      {
        Ast.call_target =
          Ast.CallTraitMethod { trait_name; method_name; call_pure; _ };
        _;
      } ->
      eval_trait_call ctx env call_expr ~trait_name ~method_name ~call_pure args
  | Some { Ast.call_target = Ast.CallClosure { call_pure }; _ } ->
      if call_pure then eval_closure_call ctx env call_expr callee args
      else unsupported (Typed_ast.loc call_expr) "impure closure calls"

and eval_imported_call ctx env call_expr ~module_path ~source_name args =
  let source_name = Call_resolution.strip_callable_id_suffix source_name in
  eval_exprs ctx env args >>= fun arg_values ->
  Ctfe_std_eval.eval_imported_call ~eval_callback_call ctx call_expr
    ~module_path ~source_name arg_values

and eval_builtin_call ctx env call_expr ~source_name args =
  let loc = Typed_ast.loc call_expr in
  let source_name = Call_resolution.strip_callable_id_suffix source_name in
  eval_exprs ctx env args >>= fun arg_values ->
  match (Intrinsic.builtin_call_of_source_name source_name, arg_values) with
  | Some Intrinsic.BuiltinToString, [ receiver ] ->
      string_text_of_value loc receiver >>= string_value call_expr
  | Some Intrinsic.BuiltinLength, [ receiver ] -> (
      match receiver.desc with
      | VList values -> int_value call_expr (List.length values)
      | VDict pairs -> int_value call_expr (List.length pairs)
      | _ -> unsupported loc "length builtin on this value")
  | _ -> unsupported loc (Intrinsic.builtin_unsupported_form source_name)

and eval_trait_call ctx env call_expr ~trait_name ~method_name ~call_pure args =
  let loc = Typed_ast.loc call_expr in
  if not call_pure then unsupported loc "impure trait method calls"
  else
    eval_exprs ctx env args >>= fun arg_values ->
    match
      (Intrinsic.trait_call_of_source ~trait_name ~method_name, arg_values)
    with
    | Some Intrinsic.TraitStringableToString, [ receiver ] ->
        string_text_of_value loc receiver >>= string_value call_expr
    | Some Intrinsic.TraitHasLengthLength, [ receiver ] -> (
        match receiver.desc with
        | VList values -> int_value call_expr (List.length values)
        | VDict pairs -> int_value call_expr (List.length pairs)
        | _ -> unsupported loc "HasLength.length on this value")
    | _ -> unsupported loc "trait method calls"

and eval_closure_call ctx env call_expr callee args =
  eval_expr ctx env callee >>= fun callee_value ->
  match callee_value.desc with
  | VClosure closure ->
      eval_exprs ctx env args >>= fun arg_values ->
      eval_closure_function_call ctx call_expr closure arg_values
  | _ -> unsupported (Typed_ast.loc callee) "closure calls on non-lambda values"

and eval_callback_call ctx call_expr callback arg_values =
  expect_closure (Typed_ast.loc call_expr) callback >>= fun closure ->
  eval_closure_function_call ctx call_expr closure arg_values

and eval_closure_function_call ctx call_expr closure arg_values =
  let func = closure.closure_func in
  let ast_func = Typed_ast.func_ast func in
  if not ast_func.func_is_pure then
    unsupported (Typed_ast.loc call_expr) "impure closure calls"
  else
    bind_function_params ctx ast_func.func_params arg_values
    >>= fun param_env ->
    let function_env = param_env @ closure.closure_env in
    match Typed_ast.func_body_expr func with
    | Error err -> Error [ typed_ast_error_to_error err ]
    | Ok None -> unsupported (Typed_ast.loc call_expr) "lambdas without bodies"
    | Ok (Some body) -> eval_expr ctx function_env body

and eval_local_function_call ctx caller_env call_expr ~callable_id ~source_name
    arg_values =
  match List.assoc_opt callable_id ctx.functions with
  | None ->
      Error
        [
          error (Typed_ast.loc call_expr)
            (Printf.sprintf
               "compile_time evaluator cannot find local function '%s'"
               source_name);
        ]
  | Some func -> (
      let ast_func = Typed_ast.func_ast func in
      if not ast_func.func_is_pure then
        unsupported (Typed_ast.loc call_expr) "impure function calls"
      else
        bind_function_params ctx ast_func.func_params arg_values
        >>= fun param_env ->
        let function_env = param_env @ caller_env in
        match Typed_ast.func_body_expr func with
        | Error err -> Error [ typed_ast_error_to_error err ]
        | Ok None ->
            unsupported (Typed_ast.loc call_expr)
              "function declarations without bodies"
        | Ok (Some body) -> eval_expr ctx function_env body)

and bind_function_params ctx params arg_values =
  let rec loop env params arg_values =
    match (params, arg_values) with
    | [], [] -> Ok env
    | param :: rest_params, value :: rest_values -> (
        match (param.Ast.param_name, param.param_pattern) with
        | Some "_", None -> loop env rest_params rest_values
        | Some name, None ->
            loop (bind_value name value env) rest_params rest_values
        | None, Some pattern -> (
            Ctfe_pattern.bind ctx pattern value >>= function
            | Some bindings ->
                loop (bind_values bindings env) rest_params rest_values
            | None ->
                Error
                  [
                    error param.param_loc
                      "compile_time function argument did not match parameter \
                       pattern";
                  ])
        | Some _, Some _ ->
            Error
              [
                error param.param_loc
                  "internal CTFE error: function parameter has both a name and \
                   a pattern";
              ]
        | None, None ->
            Error
              [
                error param.param_loc
                  "internal CTFE error: function parameter has neither a name \
                   nor a pattern";
              ])
    | _ ->
        Error
          [
            error Ast.dummy_loc
              "internal CTFE error: function call argument count mismatch";
          ]
  in
  loop [] params arg_values

and eval_match ctx env loc scrutinee cases =
  eval_expr ctx env scrutinee >>= fun scrutinee_value ->
  let rec loop = function
    | [] -> unsupported loc "non-exhaustive match expressions"
    | case :: rest -> (
        match
          Ctfe_pattern.bind ctx case.Typed_ast.case_pattern scrutinee_value
        with
        | Error _ as err -> err
        | Ok None -> loop rest
        | Ok (Some bindings) ->
            eval_expr ctx (bind_values bindings env) case.case_body)
  in
  loop cases

let evaluate_binding ctx env binding =
  let Typed_ast.CompileTimeRequired =
    Typed_ast.compile_time_binding_evaluation binding
  in
  let typed_var = Typed_ast.compile_time_binding_var binding in
  let ast_var = Typed_ast.var_ast typed_var in
  match ast_var.var_name with
  | None ->
      Error
        [
          error ast_var.var_value.expr_loc
            "compile_time binding must have a name";
        ]
  | Some name -> (
      match Typed_ast.var_value_expr typed_var with
      | Error err -> Error [ typed_ast_error_to_error err ]
      | Ok init -> (
          match eval_expr ctx env init with
          | Ok value ->
              Ctfe_materialize.binding_decl binding value >>= fun typed_decl ->
              Ok (bind_value name value env, typed_decl)
          | Error _ as err -> err))

let evaluate_compile_time_block ctx env bindings =
  let rec loop env decls = function
    | [] -> Ok (env, List.rev decls)
    | binding :: rest -> (
        match evaluate_binding ctx env binding with
        | Ok (env, decl) -> loop env (decl :: decls) rest
        | Error _ as err -> err)
  in
  loop env [] bindings

let evaluate_program ?(constructor_info = fun _ -> None)
    (program : Typed_ast.program) =
  let ctx =
    Ctfe_context.of_program ~fallback_constructor_info:constructor_info program
  in
  let rec loop acc = function
    | [] ->
        let typed_decls = List.rev acc in
        Ok (Typed_ast.make_program typed_decls)
    | decl :: rest -> (
        match Typed_ast.decl_view decl with
        | Typed_ast.DeclCompileTimeBlock bindings -> (
            match evaluate_compile_time_block ctx [] bindings with
            | Ok (_, expanded) -> loop (List.rev_append expanded acc) rest
            | Error _ as err -> err)
        | _ -> loop (decl :: acc) rest)
  in
  loop [] (Typed_ast.program_decls program)
