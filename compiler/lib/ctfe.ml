(** Compile-time evaluator for top-level constants.

    Typed AST is translated to [Ctfe_ir] before expression execution. The
    evaluator consumes that smaller representation, evaluates pure computation,
    and rewrites each binding to an ordinary global initializer. Unsupported
    forms stay explicit at the IR translation/evaluation boundary so CTFE grows
    by adding named cases instead of guessing from runtime lowering behavior. *)

open Ctfe_value
open Ctfe_error
open Ctfe_env
open Ctfe_context
open Ctfe_value_ops
open Ctfe_operator

type constructor_info = Ctfe_value.constructor_info = {
  constructor_parent_type : string;
  constructor_arity : int;
  constructor_callable_id : int option;
}

let make_constructor_info ~parent_type ~arity ~callable_id =
  {
    constructor_parent_type = parent_type;
    constructor_arity = arity;
    constructor_callable_id = callable_id;
  }

module IR = Ctfe_ir

let ( >>= ) = Result.bind
let ( let* ) = Result.bind

type loop_control = LoopValue of value | LoopBreak | LoopContinue
type block_item_result = BlockItemContinue of env | BlockItemReturn of value

let translate_error = function
  | IR.TypedAstError err -> Error [ typed_ast_error_to_error err ]
  | IR.Unsupported (loc, form) -> unsupported loc form

module StringSet = Set.Make (String)

let module_alias_path import_bindings alias =
  List.find_map
    (fun (binding : Session.import_binding) ->
      match binding.original_name with
      | None when binding.local_name = alias -> Some binding.module_path
      | _ -> None)
    import_bindings

let typed_modules_for_ctfe () =
  Modules.get_all_modules ()
  |> List.filter_map (fun (m : Modules.loaded_module) ->
      match Modules.get_typed_decls m.name with
      | Some typed ->
          let import_bindings =
            match Modules.get_typed_import_bindings m.name with
            | Some bindings -> bindings
            | None -> []
          in
          Some (m.name, typed, module_alias_path import_bindings)
      | None -> None)

let rec collect_expr_references refs expr =
  let refs =
    match expr.Ast.expr_desc with
    | Ast.EIdent name | Ast.EAssign (name, _) | Ast.ECompoundAssign (name, _, _)
      ->
        StringSet.add name refs
    | _ -> refs
  in
  List.fold_left collect_expr_references refs (Ast.expr_children expr)

let collect_func_references refs func =
  match Ast.func_body_expr_opt func.Ast.func_body with
  | Some body -> collect_expr_references refs body
  | None -> refs

let collect_var_references refs var =
  collect_expr_references refs var.Ast.var_value

let rec collect_materialized_lambda_references refs expr =
  match expr.Ast.expr_desc with
  | Ast.ELambda func -> collect_func_references refs func
  | _ ->
      List.fold_left collect_materialized_lambda_references refs
        (Ast.expr_children expr)

let collect_var_materialized_lambda_references refs var =
  collect_materialized_lambda_references refs var.Ast.var_value

let var_initializer_runs_at_runtime var =
  var.Ast.var_is_mutable || not var.Ast.var_is_const

let unavailable_global_reason_for_var var =
  if var_initializer_runs_at_runtime var then RuntimeInitializedGlobal
  else LaterGlobal

let bind_unavailable_global_var env var =
  match var.Ast.var_name with
  | None -> env
  | Some name ->
      bind_unavailable_global (unavailable_global_reason_for_var var) name env

let bind_unavailable_decl_globals env decl =
  match Typed_ast.decl_view decl with
  | Typed_ast.DeclVar var ->
      bind_unavailable_global_var env (Typed_ast.var_ast var)
  | Typed_ast.DeclPrivate inner -> (
      match Typed_ast.decl_view inner with
      | Typed_ast.DeclVar var ->
          bind_unavailable_global_var env (Typed_ast.var_ast var)
      | Typed_ast.DeclFunction _ | Typed_ast.DeclRecord _
      | Typed_ast.DeclTypeAlias _ | Typed_ast.DeclImpl _
      | Typed_ast.DeclPrivate _ | Typed_ast.DeclOther ->
          env)
  | Typed_ast.DeclFunction _ | Typed_ast.DeclRecord _
  | Typed_ast.DeclTypeAlias _ | Typed_ast.DeclImpl _ | Typed_ast.DeclOther ->
      env

let bind_unavailable_program_globals env program =
  List.fold_left bind_unavailable_decl_globals env
    (Typed_ast.program_decls program)

let collect_trait_method_references refs method_ =
  match method_.Ast.method_default_body with
  | Some body -> collect_expr_references refs body
  | None -> refs

let rec collect_runtime_decl_references refs decl =
  match (Typed_ast.decl_ast decl).Ast.decl_desc with
  | Ast.DFunc func -> collect_func_references refs func
  | Ast.DVar var ->
      if var_initializer_runs_at_runtime var then
        collect_var_references refs var
      else collect_var_materialized_lambda_references refs var
  | Ast.DPrivate inner -> collect_runtime_ast_decl_references refs inner
  | Ast.DImpl impl ->
      List.fold_left collect_func_references refs impl.Ast.impl_methods
  | Ast.DTrait trait ->
      List.fold_left collect_trait_method_references refs
        trait.Ast.trait_methods
  | Ast.DType _ | Ast.DRecord _ | Ast.DImport _ | Ast.DTypeAlias _ -> refs

and collect_runtime_ast_decl_references refs decl =
  match decl.Ast.decl_desc with
  | Ast.DFunc func -> collect_func_references refs func
  | Ast.DVar var ->
      if var_initializer_runs_at_runtime var then
        collect_var_references refs var
      else collect_var_materialized_lambda_references refs var
  | Ast.DPrivate inner -> collect_runtime_ast_decl_references refs inner
  | Ast.DImpl impl ->
      List.fold_left collect_func_references refs impl.Ast.impl_methods
  | Ast.DTrait trait ->
      List.fold_left collect_trait_method_references refs
        trait.Ast.trait_methods
  | Ast.DType _ | Ast.DRecord _ | Ast.DImport _ | Ast.DTypeAlias _ -> refs

(* Private constants are emitted only when ordinary runtime declarations may
   reference them. Typed AST does not carry stable value IDs here yet, so this
   analysis is deliberately conservative: it collects source identifier names
   from runtime declarations. Shadowing can keep an otherwise erasable private
   CTFE value, but must not cause one to be erased when runtime code may need
   it. *)
let conservative_runtime_reference_names program =
  List.fold_left collect_runtime_decl_references StringSet.empty
    (Typed_ast.program_decls program)

let resolved_call_for_local_function_reference expr direct =
  match expr.IR.ty with
  | Ast.TyFunc { params; return; _ } ->
      Some
        {
          Ast.call_syntax = Ast.CallBare;
          call_target =
            Ast.CallDirect
              {
                callable_id = direct.IR.callable_id;
                source_name = direct.source_name;
                call_pure = direct.call_pure;
                origin = Ast.CallableLocal;
              };
          instantiated_params = params;
          instantiated_return = return;
        }
  | _ -> None

let rec negate_value loc result_ty value =
  let ok desc = Ok { ty = result_ty; desc; loc } in
  match value.desc with
  | VInt n -> ok (VInt (Int64.neg n))
  | VFloat n -> ok (VFloat (-.n))
  | VVector values ->
      let rec loop acc = function
        | [] -> ok (VVector (List.rev acc))
        | value :: rest -> (
            match negate_value loc value.ty value with
            | Ok value -> loop (value :: acc) rest
            | Error _ as err -> err)
      in
      loop [] values
  | _ ->
      Error
        [
          error loc
            (Printf.sprintf "compile-time constant evaluation cannot negate %s"
               (type_name value.ty));
        ]

let rec eval_ir ctx env expr =
  let loc = expr.IR.loc in
  match expr.IR.desc with
  | IR.Literal lit -> (
      match lit with
      | Ast.LitInt n -> scalar_value expr (VInt n)
      | Ast.LitFloat n -> scalar_value expr (VFloat n)
      | Ast.LitBool b -> scalar_value expr (VBool b)
      | Ast.LitChar c -> scalar_value expr (VChar c)
      | Ast.LitString (s, flags) -> scalar_value expr (VString (s, flags))
      | Ast.LitInt128 _ -> unsupported loc "Int128 literals")
  | IR.Ident ident -> (
      match lookup env loc ident.ident_name with
      | Ok value -> Ok value
      | Error _ as lookup_error -> (
          match eval_identifier_reference ctx expr ident with
          | Ok (Some value) -> Ok value
          | Ok None -> lookup_error
          | Error _ as err -> err))
  | IR.Transparent inner -> eval_ir ctx env inner
  | IR.Unary (Ast.Neg, inner) ->
      eval_ir ctx env inner >>= fun value -> negate_value loc expr.IR.ty value
  | IR.Unary (Ast.Not, inner) ->
      eval_ir ctx env inner >>= fun value ->
      expect_bool loc value >>= fun b -> scalar_value expr (VBool (not b))
  | IR.Binary (op, left, right) ->
      eval_ir ctx env left >>= fun l ->
      eval_ir ctx env right >>= fun r ->
      eval_binary_desc loc op l r >>= fun desc -> scalar_value expr desc
  | IR.Logical (Ast.And, left, right) ->
      eval_ir ctx env left >>= fun l ->
      expect_bool loc l >>= fun lb ->
      if not lb then scalar_value expr (VBool false)
      else
        eval_ir ctx env right >>= fun r ->
        expect_bool loc r >>= fun rb -> scalar_value expr (VBool rb)
  | IR.Logical (Ast.Or, left, right) ->
      eval_ir ctx env left >>= fun l ->
      expect_bool loc l >>= fun lb ->
      if lb then scalar_value expr (VBool true)
      else
        eval_ir ctx env right >>= fun r ->
        expect_bool loc r >>= fun rb -> scalar_value expr (VBool rb)
  | IR.If (cond, then_expr, else_expr) -> (
      eval_ir ctx env cond >>= fun c ->
      expect_bool loc c >>= fun cb ->
      if cb then eval_ir ctx env then_expr
      else
        match else_expr with
        | Some else_expr -> eval_ir ctx env else_expr
        | None -> scalar_value expr VVoid)
  | IR.Block block -> eval_block ctx env expr block
  | IR.Tuple values ->
      eval_exprs ctx env values >>= fun values ->
      scalar_value expr (VTuple values)
  | IR.List values ->
      eval_exprs ctx env values >>= fun values ->
      scalar_value expr (VList values)
  | IR.Vector values ->
      eval_exprs ctx env values >>= fun values ->
      scalar_value expr (VVector values)
  | IR.Record fields ->
      eval_fields ctx env fields >>= fun fields ->
      scalar_value expr (VRecord fields)
  | IR.Dict pairs ->
      eval_pairs ctx env pairs >>= fun pairs -> scalar_value expr (VDict pairs)
  | IR.ImportedGlobal { global_module_path; global_name } -> (
      match
        Ctfe_context.module_global_value ctx ~module_path:global_module_path
          ~name:global_name
      with
      | Some value -> Ok value
      | None ->
          Error
            [
              error loc
                (Printf.sprintf
                   "global constant initializer cannot reference imported \
                    value '%s.%s' because it is not a compile-time constant"
                   global_module_path global_name);
            ])
  | IR.FieldAccess access -> eval_field_access ctx env loc access
  | IR.RecordUpdate (base, fields) ->
      eval_record_update ctx env expr base fields
  | IR.StringInterp (parts, is_multiline) ->
      eval_string_interp ctx env expr parts is_multiline
  | IR.Lambda func -> eval_lambda ctx env expr func
  | IR.Call call -> eval_call ctx env expr call
  | IR.Match (scrutinee, cases) -> eval_match ctx env loc scrutinee cases
  | IR.While (cond, body) -> eval_while ctx env expr cond body
  | IR.For (name, iter, body) -> eval_for ctx env expr name iter body
  | IR.ForTuple (names, iter, body) ->
      eval_for_tuple ctx env expr names iter body
  | IR.Range (start_expr, end_expr) ->
      eval_ir ctx env start_expr >>= fun start_value ->
      eval_ir ctx env end_expr >>= fun end_value ->
      let* _ = expect_int loc start_value in
      let* _ = expect_int loc end_value in
      scalar_value expr (VRange (start_value, end_value))
  | IR.Assign (name, rhs) ->
      eval_ir ctx env rhs >>= fun value -> assign env loc name value
  | IR.CompoundAssign (name, op, rhs) ->
      lookup env loc name >>= fun current ->
      eval_ir ctx env rhs >>= fun value ->
      eval_binary_desc loc (Ast.binop_of_assign_op op) current value
      >>= fun desc ->
      let updated = { current with desc; loc } in
      assign env loc name updated
  | IR.Void -> scalar_value expr VVoid
  | IR.Break | IR.Continue -> unsupported loc "this expression form"

and eval_exprs ctx env exprs =
  let rec loop acc = function
    | [] -> Ok (List.rev acc)
    | expr :: rest -> (
        match eval_ir ctx env expr with
        | Ok value -> loop (value :: acc) rest
        | Error _ as err -> err)
  in
  loop [] exprs

and eval_fields ctx env fields =
  let rec loop acc = function
    | [] -> Ok (List.rev acc)
    | (name, expr) :: rest -> (
        match eval_ir ctx env expr with
        | Ok value -> loop ((name, value) :: acc) rest
        | Error _ as err -> err)
  in
  loop [] fields

and eval_pairs ctx env pairs =
  let rec loop acc = function
    | [] -> Ok (List.rev acc)
    | (key, value) :: rest -> (
        match (eval_ir ctx env key, eval_ir ctx env value) with
        | Ok key, Ok value -> loop ((key, value) :: acc) rest
        | Error errors, _ | _, Error errors -> Error errors)
  in
  loop [] pairs

and eval_record_update ctx env expr base updates =
  eval_ir ctx env base >>= fun base_value ->
  match base_value.desc with
  | VRecord base_fields ->
      eval_fields ctx env updates >>= fun update_values ->
      apply_record_updates expr.IR.loc base_fields update_values
      >>= fun fields -> scalar_value expr (VRecord fields)
  | _ -> unsupported base.IR.loc "record update on non-record values"

and apply_record_updates loc fields updates =
  let rec replace_field target_name target_value = function
    | [] ->
        Error
          [
            error loc
              (Printf.sprintf "compile-time record value has no field '%s'"
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

and eval_field_access ctx env loc access =
  eval_ir ctx env access.IR.field_receiver >>= fun value ->
  match (access.field_kind, value.desc) with
  | IR.RecordField field, VRecord fields -> (
      match List.assoc_opt field fields with
      | Some value -> Ok value
      | None ->
          Error
            [
              error loc
                (Printf.sprintf "compile-time record value has no field '%s'"
                   field);
            ])
  | IR.TupleField { tuple_index; tuple_field_name }, VTuple values -> (
      match List.nth_opt values tuple_index with
      | Some value -> Ok value
      | None ->
          Error
            [
              error loc
                (Printf.sprintf "compile-time tuple value has no field '%s'"
                   tuple_field_name);
            ])
  | IR.TupleInvalidField field, VTuple _ ->
      unsupported loc (Printf.sprintf "tuple field access '%s'" field)
  | IR.RangeField IR.RangeStart, VRange (start_value, _) -> Ok start_value
  | IR.RangeField IR.RangeEnd, VRange (_, end_value) -> Ok end_value
  | IR.RangeInvalidField field, VRange _ ->
      Error
        [
          error loc
            (Printf.sprintf "compile-time Range value has no field '%s'" field);
        ]
  | _, _ -> unsupported loc "field access on this value"

and eval_loop_body ctx env body =
  let loc = body.IR.loc in
  match body.IR.desc with
  | IR.Break -> Ok LoopBreak
  | IR.Continue -> Ok LoopContinue
  | IR.Block block -> eval_loop_block ctx env body block
  | IR.If (cond, then_expr, else_expr) -> (
      eval_ir ctx env cond >>= fun cond_value ->
      expect_bool loc cond_value >>= fun cond_bool ->
      if cond_bool then eval_loop_body ctx env then_expr
      else
        match else_expr with
        | Some else_expr -> eval_loop_body ctx env else_expr
        | None -> scalar_value body VVoid >>= fun value -> Ok (LoopValue value))
  | IR.Match (scrutinee, cases) -> eval_loop_match ctx env loc scrutinee cases
  | _ -> eval_ir ctx env body >>= fun value -> Ok (LoopValue value)

and eval_loop_block ctx env block_expr block =
  let rec loop env = function
    | [] -> eval_loop_body ctx env block.IR.result
    | item :: rest -> (
        match item with
        | IR.Discard expr -> (
            match eval_loop_body ctx env expr with
            | Ok (LoopValue _) -> loop env rest
            | Ok LoopBreak -> Ok LoopBreak
            | Ok LoopContinue -> Ok LoopContinue
            | Error _ as err -> err)
        | IR.BindValue _ | IR.BindTuple _ | IR.BindQuestion _ -> (
            match eval_block_binding_item ctx env block_expr item with
            | Ok (BlockItemContinue env) -> loop env rest
            | Ok (BlockItemReturn value) -> Ok (LoopValue value)
            | Error _ as err -> err))
  in
  loop env block.IR.items

and eval_lambda ctx env expr func =
  let func =
    Ctfe_context.make_function ~module_alias:ctx.module_alias
      ~constructor_info:ctx.constructor_info func
  in
  scalar_value expr
    (VClosure
       {
         closure_func = func;
         closure_env = Ctfe_env.snapshot env;
         closure_origin = ClosureLambda;
       })

and eval_identifier_reference ctx expr ident =
  let loc = expr.IR.loc in
  match ident.IR.reference_kind with
  | IR.NullaryConstructorReference constructor ->
      scalar_value expr
        (VConstructor
           {
             name = constructor.IR.constructor_name;
             args = [];
             constructor_info =
               {
                 constructor_parent_type =
                   constructor.IR.constructor_parent_type;
                 constructor_arity = 0;
                 constructor_callable_id =
                   constructor.IR.constructor_callable_id;
               };
             constructor_origin = ConstructorSynthesized;
           })
      >>= fun value -> Ok (Some value)
  | IR.LocalFunctionReference ({ callable_id; source_name; _ } as direct) -> (
      match function_by_callable_id ctx callable_id with
      | Some func ->
          let reference_call =
            resolved_call_for_local_function_reference expr direct
          in
          scalar_value expr
            (VClosure
               {
                 closure_func = func;
                 closure_env = [];
                 closure_origin =
                   ClosureLocalFunctionReference
                     { reference_name = source_name; reference_call };
               })
          >>= fun value -> Ok (Some value)
      | None ->
          Error
            [
              error loc
                (Printf.sprintf
                   "internal CTFE error: local function reference '%s' has \
                    unknown callable id %d"
                   source_name callable_id);
            ])
  | IR.ImpureFunctionReference -> unsupported loc "impure function references"
  | IR.UnsupportedFunctionReference source_name ->
      unsupported loc (Printf.sprintf "function reference '%s'" source_name)
  | IR.ValueReference -> Ok None

and eval_string_interp ctx env expr parts is_multiline =
  let string_of_value part_expr value =
    match string_text_of_value part_expr.IR.loc value with
    | Ok text -> Ok text
    | Error _ ->
        Error
          [
            error part_expr.IR.loc
              (Printf.sprintf
                 "compile-time string interpolation currently supports String, \
                  Int, Float, Bool, and Char expressions, found %s"
                 (type_name value.ty));
          ]
  in
  let rec loop acc = function
    | [] ->
        let text = String.concat "" (List.rev acc) in
        scalar_value expr (VString (text, string_flags_for_interp is_multiline))
    | IR.InterpLit text :: rest -> loop (text :: acc) rest
    | IR.InterpExpr part_expr :: rest ->
        eval_ir ctx env part_expr >>= fun value ->
        string_of_value part_expr value >>= fun text -> loop (text :: acc) rest
  in
  loop [] parts

and eval_block ctx env block_expr block =
  let rec loop env = function
    | [] -> eval_ir ctx env block.IR.result
    | item :: rest -> (
        match item with
        | IR.Discard expr -> (
            match eval_ir ctx env expr with
            | Ok _ -> loop env rest
            | Error _ as err -> err)
        | IR.BindValue _ | IR.BindTuple _ | IR.BindQuestion _ -> (
            match eval_block_binding_item ctx env block_expr item with
            | Ok (BlockItemContinue env) -> loop env rest
            | Ok (BlockItemReturn value) -> Ok value
            | Error _ as err -> err))
  in
  loop env block.IR.items

and eval_block_binding_item ctx env block_expr = function
  | IR.BindValue (name, _, init, is_mutable) -> (
      match eval_ir ctx env init with
      | Ok value ->
          Ok
            (BlockItemContinue
               (bind_value ~mutable_binding:is_mutable name value env))
      | Error _ as err -> err)
  | IR.BindTuple (names, init) -> (
      match eval_ir ctx env init with
      | Ok { desc = VTuple values; _ }
        when List.length values = List.length names ->
          Ok (BlockItemContinue (bind_values (List.combine names values) env))
      | Ok value ->
          Error
            [
              error init.IR.loc
                (Printf.sprintf
                   "compile-time tuple destructuring expected %d values, found \
                    %s"
                   (List.length names) (type_name value.ty));
            ]
      | Error _ as err -> err)
  | IR.BindQuestion (name, _, rhs) ->
      eval_question_bind ctx env block_expr name rhs
  | IR.Discard _ ->
      Error
        [
          error block_expr.IR.loc
            "internal CTFE error: discard block item reached binding evaluator";
        ]

and eval_question_bind ctx env block_expr name rhs =
  let loc = rhs.IR.loc in
  eval_ir ctx env rhs >>= fun carrier ->
  match option_state loc carrier with
  | Ok (OptionSome value) -> Ok (BlockItemContinue (bind_value name value env))
  | Ok OptionNone ->
      option_value ctx block_expr None >>= fun value ->
      Ok (BlockItemReturn value)
  | Error _ -> (
      match result_state loc carrier with
      | Ok (ResultOk value) ->
          Ok (BlockItemContinue (bind_value name value env))
      | Ok (ResultErr value) ->
          result_err_value ctx block_expr value >>= fun value ->
          Ok (BlockItemReturn value)
      | Error _ -> unsupported loc "?= on non-Option/non-Result values")

and eval_while ctx env expr cond body =
  let rec loop () =
    eval_ir ctx env cond >>= fun cond_value ->
    expect_bool cond.IR.loc cond_value >>= fun keep_going ->
    if not keep_going then scalar_value expr VVoid
    else
      eval_loop_body ctx env body >>= function
      | LoopBreak -> scalar_value expr VVoid
      | LoopContinue | LoopValue _ -> loop ()
  in
  loop ()

and eval_for ctx env expr name iter body =
  eval_ir ctx env iter >>= fun iterable ->
  match iterable.desc with
  | VRange (start_value, end_value) ->
      expect_int iter.IR.loc start_value >>= fun start_int ->
      expect_int iter.IR.loc end_value >>= fun end_int ->
      let step = if start_int <= end_int then Int64.succ else Int64.pred in
      let outside_range current =
        if start_int <= end_int then current >= end_int else current <= end_int
      in
      let rec loop current =
        if outside_range current then scalar_value expr VVoid
        else
          let item =
            { start_value with desc = VInt current; loc = iterable.loc }
          in
          eval_loop_body ctx (bind_value name item env) body >>= function
          | LoopBreak -> scalar_value expr VVoid
          | LoopContinue | LoopValue _ -> loop (step current)
      in
      loop start_int
  | VList values ->
      let rec loop = function
        | [] -> scalar_value expr VVoid
        | value :: rest -> (
            eval_loop_body ctx (bind_value name value env) body >>= function
            | LoopBreak -> scalar_value expr VVoid
            | LoopContinue | LoopValue _ -> loop rest)
      in
      loop values
  | _ -> unsupported iter.IR.loc "for loops over this iterable"

and eval_for_tuple ctx env expr names iter body =
  eval_ir ctx env iter >>= fun iterable ->
  match iterable.desc with
  | VList values ->
      let rec loop = function
        | [] -> scalar_value expr VVoid
        | value :: rest -> (
            match value.desc with
            | VTuple items when List.length items = List.length names -> (
                let loop_env =
                  List.fold_left2
                    (fun env name value -> bind_value name value env)
                    env names items
                in
                eval_loop_body ctx loop_env body >>= function
                | LoopBreak -> scalar_value expr VVoid
                | LoopContinue | LoopValue _ -> loop rest)
            | _ -> unsupported value.loc "tuple for loops over non-tuples")
      in
      loop values
  | _ -> unsupported iter.IR.loc "tuple for loops over this iterable"

and eval_call ctx env call_expr call =
  match call.IR.call_kind with
  | IR.UnresolvedCall ->
      unsupported call_expr.IR.loc "unresolved function calls"
  | IR.LocalCall { callable_id; source_name; call_pure } ->
      if not call_pure then unsupported call_expr.IR.loc "impure function calls"
      else
        eval_exprs ctx env call.args >>= fun arg_values ->
        eval_local_function_call ctx env call_expr ~callable_id ~source_name
          arg_values
  | IR.ImportedCall
      {
        imported_direct = { source_name; call_pure; _ } as imported_direct;
        module_path;
        imported_intrinsic;
      } ->
      if not call_pure then unsupported call_expr.IR.loc "impure function calls"
      else
        eval_imported_call ctx env call_expr ~module_path ~source_name
          ~imported_direct ~imported_intrinsic call.args
  | IR.BuiltinCall
      { builtin_direct = { source_name; call_pure; _ }; builtin_intrinsic } ->
      if not call_pure then unsupported call_expr.IR.loc "impure function calls"
      else
        eval_builtin_call ctx env call_expr ~source_name ~builtin_intrinsic
          call.args
  | IR.ForeignCall _ -> unsupported call_expr.IR.loc "foreign function calls"
  | IR.ConstructorCall
      {
        constructor_direct = { callable_id; source_name; call_pure };
        parent_type;
        constructor_resolved_call;
        constructor_callee_ast;
      } ->
      if not call_pure then unsupported call_expr.IR.loc "impure function calls"
      else
        eval_exprs ctx env call.args >>= fun arg_values ->
        Ok
          {
            ty = call_expr.IR.ty;
            desc =
              VConstructor
                {
                  name = source_name;
                  args = arg_values;
                  constructor_info =
                    {
                      constructor_parent_type = parent_type;
                      constructor_arity = List.length arg_values;
                      constructor_callable_id = Some callable_id;
                    };
                  constructor_origin =
                    ConstructorSourceCall
                      {
                        callee = constructor_callee_ast;
                        resolved_call = constructor_resolved_call;
                      };
                };
            loc = call_expr.IR.loc;
          }
  | IR.ImplMethodCall _ -> unsupported call_expr.IR.loc "impl method calls"
  | IR.TraitCall { trait_pure; trait_intrinsic; _ } ->
      eval_trait_call ctx env call_expr ~call_pure:trait_pure ~trait_intrinsic
        call.args
  | IR.ClosureCall { closure_pure } ->
      if closure_pure then
        eval_closure_call ctx env call_expr call.callee call.args
      else unsupported call_expr.IR.loc "impure closure calls"

and eval_imported_call ctx env call_expr ~module_path ~source_name
    ~imported_direct ~imported_intrinsic args =
  eval_exprs ctx env args >>= fun arg_values ->
  match imported_intrinsic with
  | Some _ ->
      Ctfe_std_eval.eval_imported_call
        ~eval_callback_call:(eval_callback_call env) ctx call_expr ~module_path
        ~source_name ~imported_intrinsic arg_values
  | None -> (
      match
        Ctfe_context.function_by_callable_id ctx imported_direct.callable_id
      with
      | Some func ->
          eval_imported_ctfe_function_call ctx env call_expr ~module_path
            ~source_name func arg_values
      | None -> (
          match
            Ctfe_context.imported_functions_by_source ctx ~module_path
              ~source_name
          with
          | [ func ] ->
              eval_imported_ctfe_function_call ctx env call_expr ~module_path
                ~source_name func arg_values
          | [] ->
              Ctfe_std_eval.eval_imported_call
                ~eval_callback_call:(eval_callback_call env) ctx call_expr
                ~module_path ~source_name ~imported_intrinsic arg_values
          | _ :: _ :: _ ->
              Error
                [
                  error call_expr.IR.loc
                    (Printf.sprintf
                       "compile-time imported function call '%s.%s' is \
                        ambiguous"
                       module_path source_name);
                ]))

and eval_builtin_call ctx env call_expr ~source_name ~builtin_intrinsic args =
  eval_exprs ctx env args >>= fun arg_values ->
  Ctfe_std_eval.eval_builtin_call ctx call_expr ~source_name ~builtin_intrinsic
    arg_values

and eval_trait_call ctx env call_expr ~call_pure ~trait_intrinsic args =
  let loc = call_expr.IR.loc in
  if not call_pure then unsupported loc "impure trait method calls"
  else
    eval_exprs ctx env args >>= fun arg_values ->
    Ctfe_std_eval.eval_trait_call call_expr ~trait_intrinsic arg_values

and eval_closure_call ctx env call_expr callee args =
  eval_ir ctx env callee >>= fun callee_value ->
  match callee_value.desc with
  | VClosure closure ->
      eval_exprs ctx env args >>= fun arg_values ->
      eval_closure_function_call env ctx call_expr closure arg_values
  | _ -> unsupported callee.IR.loc "closure calls on non-lambda values"

and eval_callback_call caller_env ctx call_expr callback arg_values =
  expect_closure call_expr.IR.loc callback >>= fun closure ->
  eval_closure_function_call caller_env ctx call_expr closure arg_values

and eval_closure_function_call caller_env ctx call_expr closure arg_values =
  let func = closure.closure_func in
  let ast_func = Ctfe_context.function_ast func in
  if not ast_func.func_is_pure then
    unsupported call_expr.IR.loc "impure closure calls"
  else
    bind_function_params ctx ast_func.func_params arg_values
    >>= fun param_env ->
    let function_env =
      match closure.closure_origin with
      | ClosureLocalFunctionReference _ ->
          param_env @ function_global_env ctx caller_env func
      | ClosureLambda -> param_env @ closure.closure_env
    in
    match Ctfe_context.function_body_ir func with
    | Error err -> translate_error err
    | Ok None -> unsupported call_expr.IR.loc "lambdas without bodies"
    | Ok (Some body) -> eval_ir ctx function_env body

and eval_local_function_call ctx caller_env call_expr ~callable_id ~source_name
    arg_values =
  match List.assoc_opt callable_id ctx.functions with
  | None ->
      Error
        [
          error call_expr.IR.loc
            (Printf.sprintf
               "internal compile-time constant evaluation error: cannot find \
                local function '%s'"
               source_name);
        ]
  | Some func ->
      eval_ctfe_function_call ctx caller_env call_expr func arg_values

and function_global_env ctx caller_env func =
  match func.function_module_path with
  | Some module_path -> Ctfe_context.module_global_env ctx module_path
  | None -> Ctfe_env.global_bindings caller_env

and eval_imported_ctfe_function_call ctx caller_env call_expr ~module_path
    ~source_name func arg_values =
  eval_ctfe_function_call
    ~missing_body_form:
      (Ctfe_intrinsic.imported_unsupported_form ~module_path ~source_name)
    ctx caller_env call_expr func arg_values

and eval_ctfe_function_call ?missing_body_form ctx caller_env call_expr func
    arg_values =
  let ast_func = Ctfe_context.function_ast func in
  if not ast_func.func_is_pure then
    unsupported call_expr.IR.loc "impure function calls"
  else
    bind_function_params ctx ast_func.func_params arg_values
    >>= fun param_env ->
    let function_env = param_env @ function_global_env ctx caller_env func in
    match Ctfe_context.function_body_ir func with
    | Error err -> translate_error err
    | Ok None ->
        unsupported call_expr.IR.loc
          (Option.value missing_body_form
             ~default:"function declarations without bodies")
    | Ok (Some body) -> eval_ir ctx function_env body

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
                      "compile-time function argument did not match parameter \
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
  eval_ir ctx env scrutinee >>= fun scrutinee_value ->
  let rec loop = function
    | [] -> unsupported loc "non-exhaustive match expressions"
    | case :: rest -> (
        match Ctfe_pattern.bind ctx case.IR.pattern scrutinee_value with
        | Error _ as err -> err
        | Ok None -> loop rest
        | Ok (Some bindings) -> eval_ir ctx (bind_values bindings env) case.body
        )
  in
  loop cases

and eval_loop_match ctx env loc scrutinee cases =
  eval_ir ctx env scrutinee >>= fun scrutinee_value ->
  let rec loop = function
    | [] -> unsupported loc "non-exhaustive match expressions"
    | case :: rest -> (
        match Ctfe_pattern.bind ctx case.IR.pattern scrutinee_value with
        | Error _ as err -> err
        | Ok None -> loop rest
        | Ok (Some bindings) ->
            eval_loop_body ctx (bind_values bindings env) case.body)
  in
  loop cases

let evaluate_global_var_decl ctx env ~private_ ~loc ?doc ?module_alias
    original_decl typed_var ~materialize =
  let ast_var = Typed_ast.var_ast typed_var in
  if ast_var.var_is_mutable || not ast_var.var_is_const then
    Ok (env, Some original_decl)
  else
    let materialized_result =
      match ast_var.var_name with
      | None ->
          Error
            [
              error ast_var.var_value.expr_loc
                "global constant binding must have a name";
            ]
      | Some name -> (
          match
            IR.of_typed_var_initializer
              ~nullary_constructor:
                (Ctfe_context.nullary_constructor_reference ctx)
              ?module_alias typed_var
          with
          | Error err -> translate_error err
          | Ok init -> (
              let eval_env = bind_unavailable_global CurrentGlobal name env in
              match eval_ir ctx eval_env init with
              | Error _ as err -> err
              | Ok value ->
                  if materialize then
                    Ctfe_materialize.global_var_decl ~private_ ?doc ~loc
                      typed_var value
                    >>= fun decl ->
                    Ok (bind_global_value name value env, Some decl)
                  else Ok (bind_global_value name value env, None)))
    in
    match materialized_result with Ok _ as ok -> ok | Error _ as err -> err

let evaluate_module_global_env ctx (program : Typed_ast.program) =
  let rec loop env = function
    | [] -> Ok env
    | decl :: rest -> (
        match Typed_ast.decl_view decl with
        | Typed_ast.DeclVar var ->
            let ast_decl = Typed_ast.decl_ast decl in
            evaluate_global_var_decl ctx env ~private_:false
              ~loc:ast_decl.decl_loc ?doc:ast_decl.decl_doc decl var
              ~materialize:false
            >>= fun (env, _) -> loop env rest
        | Typed_ast.DeclPrivate inner -> (
            match Typed_ast.decl_view inner with
            | Typed_ast.DeclVar var ->
                let outer_ast_decl = Typed_ast.decl_ast decl in
                let inner_ast_decl = Typed_ast.decl_ast inner in
                let doc =
                  match inner_ast_decl.decl_doc with
                  | Some _ as doc -> doc
                  | None -> outer_ast_decl.decl_doc
                in
                evaluate_global_var_decl ctx env ~private_:true
                  ~loc:outer_ast_decl.decl_loc ?doc decl var ~materialize:false
                >>= fun (env, _) -> loop env rest
            | Typed_ast.DeclFunction _ | Typed_ast.DeclRecord _
            | Typed_ast.DeclTypeAlias _ | Typed_ast.DeclImpl _
            | Typed_ast.DeclPrivate _ | Typed_ast.DeclOther ->
                loop env rest)
        | Typed_ast.DeclFunction _ | Typed_ast.DeclRecord _
        | Typed_ast.DeclTypeAlias _ | Typed_ast.DeclImpl _ | Typed_ast.DeclOther
          ->
            loop env rest)
  in
  loop
    (bind_unavailable_program_globals [] program)
    (Typed_ast.program_decls program)

let build_module_global_envs ctx imported_programs =
  let rec loop acc = function
    | [] -> Ok (List.rev acc)
    | (module_path, program, _) :: rest ->
        evaluate_module_global_env ctx program >>= fun env ->
        loop ((module_path, env) :: acc) rest
  in
  loop [] imported_programs

let bind_imported_global ctx env (binding : Session.import_binding) =
  match binding.original_name with
  | None -> env
  | Some original_name -> (
      match
        Ctfe_context.module_global_value ctx ~module_path:binding.module_path
          ~name:original_name
      with
      | Some value -> bind_global_value binding.local_name value env
      | None
        when Ctfe_context.module_has_global_binding ctx
               ~module_path:binding.module_path ~name:original_name ->
          bind_unavailable_global
            (ImportedRuntimeInitializedGlobal
               { module_path = binding.module_path; original_name })
            binding.local_name env
      | None -> env)

let imported_global_env ctx import_bindings =
  List.fold_left (bind_imported_global ctx) [] import_bindings

let evaluate_program ?(constructor_info = fun _ -> None) ?(import_bindings = [])
    (program : Typed_ast.program) =
  let imported_programs = typed_modules_for_ctfe () in
  let module_alias = module_alias_path import_bindings in
  let ctx =
    Ctfe_context.of_program ~fallback_constructor_info:constructor_info
      ~module_alias ~imported_programs program
  in
  build_module_global_envs ctx imported_programs >>= fun module_global_envs ->
  let ctx = Ctfe_context.with_module_global_envs ctx module_global_envs in
  let initial_env =
    imported_global_env ctx import_bindings |> fun env ->
    bind_unavailable_program_globals env program
  in
  let runtime_refs = conservative_runtime_reference_names program in
  let rec loop env acc = function
    | [] ->
        let typed_decls = List.rev acc in
        Ok (Typed_ast.make_program typed_decls)
    | decl :: rest -> (
        match Typed_ast.decl_view decl with
        | Typed_ast.DeclVar var -> (
            let ast_decl = Typed_ast.decl_ast decl in
            match
              evaluate_global_var_decl ctx env ~private_:false
                ~loc:ast_decl.decl_loc ?doc:ast_decl.decl_doc decl var
                ~module_alias ~materialize:true
            with
            | Ok (env, Some decl) -> loop env (decl :: acc) rest
            | Ok (env, None) -> loop env acc rest
            | Error _ as err -> err)
        | Typed_ast.DeclPrivate inner -> (
            let pass_through () = loop env (decl :: acc) rest in
            match Typed_ast.decl_view inner with
            | Typed_ast.DeclVar var -> (
                let outer_ast_decl = Typed_ast.decl_ast decl in
                let inner_ast_decl = Typed_ast.decl_ast inner in
                let doc =
                  match inner_ast_decl.decl_doc with
                  | Some _ as doc -> doc
                  | None -> outer_ast_decl.decl_doc
                in
                let loc = outer_ast_decl.decl_loc in
                let original_decl = decl in
                let materialize =
                  match (Typed_ast.var_ast var).Ast.var_name with
                  | Some name -> StringSet.mem name runtime_refs
                  | None -> true
                in
                match
                  evaluate_global_var_decl ctx env ~private_:true ~loc ?doc
                    ~module_alias original_decl var ~materialize
                with
                | Ok (env, Some decl) -> loop env (decl :: acc) rest
                | Ok (env, None) -> loop env acc rest
                | Error _ as err -> err)
            | Typed_ast.DeclFunction _ | Typed_ast.DeclRecord _
            | Typed_ast.DeclTypeAlias _ | Typed_ast.DeclImpl _
            | Typed_ast.DeclPrivate _ | Typed_ast.DeclOther ->
                pass_through ())
        | _ -> loop env (decl :: acc) rest)
  in
  loop initial_env [] (Typed_ast.program_decls program)
