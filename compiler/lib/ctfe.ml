(** Narrow compile-time evaluator for [compile_time:] top-level blocks.

    This first slice evaluates data expressions and simple pure computation,
    then rewrites each binding to an ordinary global initializer. It is
    deliberately explicit about unsupported expression forms so CTFE grows by
    adding named cases instead of guessing from runtime lowering behavior. *)

type value_desc =
  | VInt of int64
  | VFloat of float
  | VBool of bool
  | VChar of int
  | VString of string * Ast.string_flags
  | VTuple of value list
  | VList of value list
  | VDict of (value * value) list
  | VRecord of (string * value) list
  | VRange of value * value
  | VVoid
  | VConstructor of {
      name : string;
      args : value list;
      callee : Ast.expr option;
      resolved_call : Ast.resolved_call option;
    }

and value = { ty : Ast.type_expr; desc : value_desc; loc : Ast.loc }

type binding = { mutable_binding : bool; cell : value ref }
type env = (string * binding) list
type function_table = (int * Typed_ast.func_decl) list
type constructor_table = (string * int) list

type ctx = {
  functions : function_table;
  constructor_arity : string -> int option;
  call_stack : int list;
}

let ( >>= ) = Result.bind
let ( let* ) = Result.bind

let error ?(notes = []) ?help loc message =
  {
    Ast.message;
    loc;
    phase = Ast.TypeCheck;
    kind = Ast.OtherError;
    notes;
    help;
  }

let typed_ast_error_to_error (err : Typed_ast.error) =
  let loc, message =
    match err with
    | MissingExprType { loc; context } ->
        ( loc,
          Printf.sprintf "internal CTFE error: %s missing expression type"
            context )
    | MissingExprTypeInfo { loc; context } ->
        ( loc,
          Printf.sprintf
            "internal CTFE error: %s missing structured expression type \
             metadata"
            context )
    | UnfinalizedExprType { loc; context; ty } ->
        ( loc,
          Printf.sprintf
            "internal CTFE error: %s still contains inference metavariables: %s"
            context (Types.type_to_string ty) )
    | MissingRequiredType { loc; context } ->
        (loc, Printf.sprintf "internal CTFE error: %s missing type" context)
    | UnfinalizedType { loc; context; ty } ->
        ( loc,
          Printf.sprintf
            "internal CTFE error: %s still contains inference metavariables: %s"
            context (Types.type_to_string ty) )
    | InvalidTypeInfo { loc; context; message } ->
        ( loc,
          Printf.sprintf "internal CTFE error: invalid %s: %s" context message
        )
  in
  error loc message

let unsupported loc form =
  Error
    [
      error
        ~help:
          "Use supported pure compile-time constructs here, or move this \
           computation back to runtime code."
        loc
        (Printf.sprintf "compile_time evaluator does not support %s yet" form);
    ]

let type_name ty = Types.type_to_string ty
let value_type expr = Typed_ast.value_type expr
let value_loc expr = Typed_ast.loc expr

let scalar_value expr desc =
  Ok { ty = value_type expr; desc; loc = value_loc expr }

let void_value loc = { ty = Ast.TyNamed ("Void", []); desc = VVoid; loc }

let string_flags_for_interp is_multiline =
  { Ast.sf_multiline = is_multiline; sf_raw = false }

let string_of_char_code loc code =
  match Uchar.of_int code with
  | uchar ->
      let buffer = Buffer.create 4 in
      Buffer.add_utf_8_uchar buffer uchar;
      Ok (Buffer.contents buffer)
  | exception Invalid_argument _ ->
      Error
        [
          error loc
            (Printf.sprintf "compile_time invalid Char codepoint: %d" code);
        ]

let bind_value ?(mutable_binding = false) name value env =
  if name = "_" then env
  else (name, { mutable_binding; cell = ref value }) :: env

let bind_values bindings env =
  List.fold_left
    (fun env (name, value) -> bind_value name value env)
    env bindings

let lookup_binding env loc name =
  match List.assoc_opt name env with
  | Some binding -> Ok binding
  | None ->
      Error
        [
          error
            ~help:
              "Only earlier bindings in the same compile_time block are \
               available during compile-time evaluation."
            loc
            (Printf.sprintf
               "compile_time initializer cannot reference '%s' before it is \
                evaluated"
               name);
        ]

let lookup env loc name =
  lookup_binding env loc name >>= fun binding -> Ok !(binding.cell)

let assign env loc name value =
  lookup_binding env loc name >>= fun binding ->
  if binding.mutable_binding then (
    binding.cell := value;
    Ok (void_value loc))
  else
    Error
      [
        error loc
          (Printf.sprintf "compile_time assignment target '%s' is immutable"
             name);
      ]

let constructor_arity ctx name = ctx.constructor_arity name
let constructor_is_nullary ctx name = constructor_arity ctx name = Some 0

let expect_int loc = function
  | { desc = VInt n; _ } -> Ok n
  | value ->
      Error
        [
          error loc
            (Printf.sprintf "compile_time expected Int, found %s"
               (type_name value.ty));
        ]

let expect_bool loc = function
  | { desc = VBool b; _ } -> Ok b
  | value ->
      Error
        [
          error loc
            (Printf.sprintf "compile_time expected Bool, found %s"
               (type_name value.ty));
        ]

let eval_int_binop loc op left right =
  expect_int loc left >>= fun l ->
  expect_int loc right >>= fun r ->
  let result =
    match op with
    | Ast.Add -> Int64.add l r
    | Ast.Sub -> Int64.sub l r
    | Ast.Mul -> Int64.mul l r
    | Ast.Div -> if r = 0L then 0L else Int64.div l r
    | Ast.Mod -> if r = 0L then 0L else Int64.rem l r
    | Ast.Lt | Ast.Gt | Ast.Le | Ast.Ge | Ast.Eq | Ast.Ne ->
        invalid_arg "comparison op"
  in
  Ok (VInt result)

let rec value_equal left right =
  match (left.desc, right.desc) with
  | VInt a, VInt b -> a = b
  | VFloat a, VFloat b -> a = b
  | VBool a, VBool b -> a = b
  | VChar a, VChar b -> a = b
  | VString (a, _), VString (b, _) -> a = b
  | VTuple a, VTuple b | VList a, VList b ->
      List.length a = List.length b && List.for_all2 value_equal a b
  | VRecord a, VRecord b ->
      List.length a = List.length b
      && List.for_all2
           (fun (an, av) (bn, bv) -> an = bn && value_equal av bv)
           a b
  | VDict a, VDict b ->
      List.length a = List.length b
      && List.for_all2
           (fun (ak, av) (bk, bv) -> value_equal ak bk && value_equal av bv)
           a b
  | VRange (a_start, a_end), VRange (b_start, b_end) ->
      value_equal a_start b_start && value_equal a_end b_end
  | VVoid, VVoid -> true
  | VConstructor a, VConstructor b ->
      a.name = b.name
      && List.length a.args = List.length b.args
      && List.for_all2 value_equal a.args b.args
  | _ -> false

let eval_compare_binop loc op left right =
  match op with
  | Ast.Eq -> Ok (VBool (value_equal left right))
  | Ast.Ne -> Ok (VBool (not (value_equal left right)))
  | Ast.Lt | Ast.Gt | Ast.Le | Ast.Ge ->
      expect_int loc left >>= fun l ->
      expect_int loc right >>= fun r ->
      let result =
        match op with
        | Ast.Lt -> l < r
        | Ast.Gt -> l > r
        | Ast.Le -> l <= r
        | Ast.Ge -> l >= r
        | _ -> false
      in
      Ok (VBool result)
  | Ast.Add | Ast.Sub | Ast.Mul | Ast.Div | Ast.Mod ->
      invalid_arg "arithmetic op"

let eval_string_add loc left right =
  match (left.desc, right.desc) with
  | VString (l, flags), VString (r, _) -> Ok (VString (l ^ r, flags))
  | _ -> unsupported loc "non-Int/non-String binary addition"

let eval_binary_desc loc op left right =
  match op with
  | Ast.Add -> (
      match (left.desc, right.desc) with
      | VString _, VString _ -> eval_string_add loc left right
      | _ -> eval_int_binop loc op left right)
  | Ast.Sub | Ast.Mul | Ast.Div | Ast.Mod -> eval_int_binop loc op left right
  | Ast.Lt | Ast.Gt | Ast.Le | Ast.Ge | Ast.Eq | Ast.Ne ->
      eval_compare_binop loc op left right

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
          | Error _ when constructor_is_nullary ctx name ->
              scalar_value expr
                (VConstructor
                   { name; args = []; callee = None; resolved_call = None })
          | Error _ as err -> err)
      | Typed_ast.EAscription (inner, _)
      | Typed_ast.EOpaqueInto (_, inner)
      | Typed_ast.EOpaqueFrom (_, inner) ->
          eval_expr ctx env inner
      | Typed_ast.EUnary (Ast.Neg, inner) ->
          eval_expr ctx env inner >>= fun value ->
          expect_int loc value >>= fun n ->
          scalar_value expr (VInt (Int64.neg n))
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
            | None -> unsupported loc "if without else")
      | Typed_ast.EBlock exprs -> eval_block ctx env exprs
      | Typed_ast.ETuple values ->
          eval_exprs ctx env values >>= fun values ->
          scalar_value expr (VTuple values)
      | Typed_ast.EList values ->
          eval_exprs ctx env values >>= fun values ->
          scalar_value expr (VList values)
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
          | _ -> unsupported loc "field access on non-record values")
      | Typed_ast.ERecordUpdate (base, fields) ->
          eval_record_update ctx env expr base fields
      | Typed_ast.EStringInterp (parts, is_multiline) ->
          eval_string_interp ctx env expr parts is_multiline
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
      | Typed_ast.ELambda _ -> unsupported loc "lambdas"
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

and eval_string_interp ctx env expr parts is_multiline =
  let string_of_value part_expr value =
    match value.desc with
    | VString (text, _) -> Ok text
    | VInt n -> Ok (Int64.to_string n)
    | VBool true -> Ok "True"
    | VBool false -> Ok "False"
    | VChar code -> string_of_char_code (Typed_ast.loc part_expr) code
    | _ ->
        Error
          [
            error (Typed_ast.loc part_expr)
              (Printf.sprintf
                 "compile_time string interpolation currently supports String, \
                  Int, Bool, and Char expressions, found %s"
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

and eval_block ctx env exprs =
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
        | _ -> (
            match eval_expr ctx env expr with
            | Ok _ -> loop env rest
            | Error _ as err -> err))
  in
  loop env exprs

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
        | Ast.CallableImported _ ->
            unsupported (Typed_ast.loc call_expr) "imported function calls"
        | Ast.CallableBuiltin ->
            unsupported (Typed_ast.loc call_expr) "builtin function calls"
        | Ast.CallableForeign ->
            unsupported (Typed_ast.loc call_expr) "foreign function calls"
        | Ast.CallableConstructor _ ->
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
                    };
                loc = Typed_ast.loc call_expr;
              }
        | Ast.CallableImplMethod ->
            unsupported (Typed_ast.loc call_expr) "impl method calls")
  | Some { Ast.call_target = Ast.CallTraitMethod _; _ } ->
      unsupported (Typed_ast.loc call_expr) "trait method calls"
  | Some { Ast.call_target = Ast.CallClosure _; _ } ->
      unsupported (Typed_ast.loc call_expr) "closure calls"

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
        bind_function_params ast_func.func_params arg_values
        >>= fun param_env ->
        let function_env = param_env @ caller_env in
        match Typed_ast.func_body_expr func with
        | Error err -> Error [ typed_ast_error_to_error err ]
        | Ok None ->
            unsupported (Typed_ast.loc call_expr)
              "function declarations without bodies"
        | Ok (Some body) ->
            let ctx = { ctx with call_stack = callable_id :: ctx.call_stack } in
            eval_expr ctx function_env body)

and bind_function_params params arg_values =
  let rec loop env params arg_values =
    match (params, arg_values) with
    | [], [] -> Ok env
    | param :: rest_params, value :: rest_values -> (
        match (param.Ast.param_name, param.param_pattern) with
        | Some "_", None -> loop env rest_params rest_values
        | Some name, None ->
            loop (bind_value name value env) rest_params rest_values
        | _ -> unsupported param.param_loc "pattern parameters")
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
        match bind_pattern ctx case.Typed_ast.case_pattern scrutinee_value with
        | Error _ as err -> err
        | Ok None -> loop rest
        | Ok (Some bindings) ->
            eval_expr ctx (bind_values bindings env) case.case_body)
  in
  loop cases

and bind_pattern ctx pattern value =
  match pattern with
  | Ast.PatWildcard -> Ok (Some [])
  | Ast.PatVar name when constructor_is_nullary ctx name -> (
      match value.desc with
      | VConstructor { name = value_name; args = []; _ } when name = value_name
        ->
          Ok (Some [])
      | _ -> Ok None)
  | Ast.PatVar name -> Ok (Some [ (name, value) ])
  | Ast.PatLiteral lit ->
      if pattern_literal_matches lit value then Ok (Some []) else Ok None
  | Ast.PatTuple patterns -> (
      match value.desc with
      | VTuple values -> bind_pattern_list ctx patterns values
      | _ -> Ok None)
  | Ast.PatConstructor (name, patterns) | Ast.PatQualified (_, name, patterns)
    -> (
      match value.desc with
      | VConstructor { name = value_name; args; _ }
        when name = value_name && List.length patterns = List.length args ->
          bind_pattern_list ctx patterns args
      | _ -> Ok None)
  | Ast.PatList (patterns, spread) -> (
      match value.desc with
      | VList values -> bind_list_pattern ctx patterns spread value values
      | _ -> Ok None)
  | Ast.PatOr patterns -> bind_or_pattern ctx patterns value

and bind_pattern_list ctx patterns values =
  if List.length patterns <> List.length values then Ok None
  else
    let rec loop acc patterns values =
      match (patterns, values) with
      | [], [] -> Ok (Some (List.rev acc))
      | pattern :: rest_patterns, value :: rest_values -> (
          match bind_pattern ctx pattern value with
          | Error _ as err -> err
          | Ok None -> Ok None
          | Ok (Some bindings) ->
              loop (List.rev_append bindings acc) rest_patterns rest_values)
      | _ -> Ok None
    in
    loop [] patterns values

and bind_list_pattern ctx patterns spread original values =
  let prefix_count = List.length patterns in
  if List.length values < prefix_count then Ok None
  else
    let rec take n acc rest =
      if n = 0 then (List.rev acc, rest)
      else
        match rest with
        | [] -> (List.rev acc, [])
        | value :: rest -> take (n - 1) (value :: acc) rest
    in
    let prefix_values, remaining_values = take prefix_count [] values in
    bind_pattern_list ctx patterns prefix_values >>= function
    | None -> Ok None
    | Some prefix_bindings -> (
        match spread with
        | None ->
            if remaining_values = [] then Ok (Some prefix_bindings) else Ok None
        | Some spread_pattern -> (
            let remaining =
              {
                original with
                desc = VList remaining_values;
                loc = original.loc;
              }
            in
            bind_pattern ctx spread_pattern remaining >>= function
            | None -> Ok None
            | Some spread_bindings ->
                Ok (Some (prefix_bindings @ spread_bindings))))

and bind_or_pattern ctx patterns value =
  let rec loop = function
    | [] -> Ok None
    | pattern :: rest -> (
        match bind_pattern ctx pattern value with
        | Error _ as err -> err
        | Ok None -> loop rest
        | Ok (Some _) as matched -> matched)
  in
  loop patterns

and pattern_literal_matches lit value =
  match (lit, value.desc) with
  | Ast.LitInt left, VInt right -> left = right
  | Ast.LitFloat left, VFloat right -> left = right
  | Ast.LitBool left, VBool right -> left = right
  | Ast.LitChar left, VChar right -> left = right
  | Ast.LitString (left, _), VString (right, _) -> left = right
  | Ast.LitInt128 _, _ -> false
  | _, _ -> false

let make_expr ?resolved_call loc ty desc =
  let ast = Ast.untyped_expr ~loc desc in
  match
    Typed_ast.of_ast_expr_with_type_info
      ~context:"compile_time materialized initializer" ?resolved_call
      ~semantic_ty:ty ~value_ty:ty ~widening:(Type_widening_metadata.Keep ty)
      ast
  with
  | Ok typed -> Ok (Typed_ast.ast typed)
  | Error err -> Error [ typed_ast_error_to_error err ]

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
  | VConstructor { name; args; callee; resolved_call } -> (
      value_to_exprs args >>= fun args ->
      match (callee, args) with
      | Some callee, _ ->
          make_expr ?resolved_call value.loc value.ty (Ast.ECall (callee, args))
      | None, [] -> make_expr value.loc value.ty (Ast.EIdent name)
      | None, _ ->
          Error
            [
              error value.loc
                (Printf.sprintf
                   "internal CTFE error: constructor '%s' has payload but no \
                    callee"
                   name);
            ])

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

let materialized_binding_decl binding value =
  let typed_var = Typed_ast.compile_time_binding_var binding in
  let ast_binding = Typed_ast.compile_time_binding_ast binding in
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
    {
      Ast.decl_desc = Ast.DVar ast_var;
      decl_loc = ast_binding.ctb_loc;
      decl_doc = ast_binding.ctb_doc;
    }
  in
  let inner_typed_decl = Typed_ast.make_var_decl inner_ast_decl typed_var in
  if ast_binding.ctb_private then
    let ast_decl =
      {
        Ast.decl_desc = Ast.DPrivate inner_ast_decl;
        decl_loc = ast_binding.ctb_loc;
        decl_doc = None;
      }
    in
    Ok (Typed_ast.make_private_decl ast_decl inner_typed_decl)
  else Ok inner_typed_decl

let evaluate_binding ctx env binding =
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
              materialized_binding_decl binding value >>= fun typed_decl ->
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

let rec collect_functions acc decl =
  match Typed_ast.decl_view decl with
  | Typed_ast.DeclFunction func -> (
      match Typed_ast.func_callable_id func with
      | Some callable_id -> (callable_id, func) :: acc
      | None -> acc)
  | Typed_ast.DeclPrivate inner -> collect_functions acc inner
  | _ -> acc

let collect_constructor_decls acc decl =
  let collect_type acc type_decl =
    List.fold_left
      (fun acc variant ->
        (variant.Ast.variant_name, List.length variant.variant_fields) :: acc)
      acc type_decl.Ast.type_variants
  in
  match (Typed_ast.decl_ast decl).Ast.decl_desc with
  | Ast.DType type_decl -> collect_type acc type_decl
  | Ast.DPrivate inner -> (
      match inner.Ast.decl_desc with
      | Ast.DType type_decl -> collect_type acc type_decl
      | _ -> acc)
  | _ -> acc

let evaluate_program ?(constructor_arity = fun _ -> None)
    (program : Typed_ast.program) =
  let functions =
    List.fold_left collect_functions [] (Typed_ast.program_decls program)
  in
  let constructors =
    List.fold_left collect_constructor_decls []
      (Typed_ast.program_decls program)
  in
  let constructor_arity name =
    match List.assoc_opt name constructors with
    | Some arity -> Some arity
    | None -> constructor_arity name
  in
  let ctx = { functions; constructor_arity; call_stack = [] } in
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
