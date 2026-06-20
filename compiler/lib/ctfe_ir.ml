(** Normalized expression representation for compile-time evaluation.

    This IR is intentionally smaller than [Typed_ast.expr]. It keeps the facts
    CTFE needs from typechecking, such as resolved call metadata and source
    types, while making unsupported expression forms explicit at the translation
    boundary. *)

module Intrinsic = Ctfe_intrinsic

type expr = { loc : Ast.loc; ty : Ast.type_expr; desc : expr_desc }

and expr_desc =
  | Literal of Ast.literal
  | Ident of identifier
  | Transparent of expr
  | Unary of Ast.unop * expr
  | Binary of Ast.binop * expr * expr
  | Logical of Ast.logop * expr * expr
  | If of expr * expr * expr option
  | Block of block
  | Tuple of expr list
  | List of expr list
  | Vector of expr list
  | Record of (string * expr) list
  | Dict of (expr * expr) list
  | ImportedGlobal of imported_global
  | FieldAccess of field_access
  | RecordUpdate of expr * (string * expr) list
  | StringInterp of interp_part list * bool
  | Lambda of Typed_ast.func_decl
  | Call of call
  | Match of expr * match_case list
  | While of expr * expr
  | For of string * expr * expr
  | ForTuple of string list * expr * expr
  | Range of expr * expr
  | Assign of string * expr
  | CompoundAssign of string * Ast.assign_op * expr
  | Void
  | Break
  | Continue

and identifier = { ident_name : string; reference_kind : reference_kind }

and reference_kind =
  | ValueReference
  | LocalFunctionReference of direct_call
  | NullaryConstructorReference of nullary_constructor
  | UnsupportedFunctionReference of string
  | ImpureFunctionReference

and call = { call_kind : call_kind; callee : expr; args : expr list }

and call_kind =
  | UnresolvedCall
  | LocalCall of direct_call
  | ImportedCall of imported_call
  | BuiltinCall of builtin_call
  | ForeignCall of direct_call
  | ConstructorCall of constructor_call
  | ImplMethodCall of direct_call
  | TraitCall of trait_call
  | ClosureCall of closure_call

and direct_call = { callable_id : int; source_name : string; call_pure : bool }

and nullary_constructor = {
  constructor_name : string;
  constructor_parent_type : string;
  constructor_callable_id : int option;
}

and imported_call = {
  imported_direct : direct_call;
  module_path : string;
  imported_intrinsic : Intrinsic.imported_call option;
}

and imported_global = { global_module_path : string; global_name : string }

and builtin_call = {
  builtin_direct : direct_call;
  builtin_intrinsic : Intrinsic.builtin_call option;
}

and constructor_call = {
  constructor_direct : direct_call;
  parent_type : string;
  constructor_resolved_call : Ast.resolved_call option;
  constructor_callee_ast : Ast.expr;
}

and trait_call = {
  trait_name : string;
  method_name : string;
  trait_pure : bool;
  trait_intrinsic : Intrinsic.trait_call option;
}

and closure_call = { closure_pure : bool }
and field_access = { field_receiver : expr; field_kind : field_access_kind }

and field_access_kind =
  | RecordField of string
  | TupleField of { tuple_index : int; tuple_field_name : string }
  | TupleInvalidField of string
  | RangeField of range_field
  | RangeInvalidField of string

and range_field = RangeStart | RangeEnd
and block = { items : block_item list; result : expr }

and block_item =
  | Discard of expr
  | BindValue of string * Ast.type_expr option * expr * bool
  | BindTuple of string list * expr
  | BindQuestion of string * Ast.type_expr option * expr

and interp_part = InterpLit of string | InterpExpr of expr
and match_case = { pattern : Ast.pattern; body : expr }

type translate_error =
  | TypedAstError of Typed_ast.error
  | Unsupported of Ast.loc * string

type translate_context = {
  nullary_constructor : string -> nullary_constructor option;
  module_alias : string -> string option;
  module_has_global : module_path:string -> name:string -> bool;
}

let ( let* ) = Result.bind
let unsupported loc form = Error (Unsupported (loc, form))

let make source desc =
  { loc = Typed_ast.loc source; ty = Typed_ast.value_type source; desc }

let is_named_type name ty =
  match Types.head_resolve ty with
  | Ast.TyNamed (actual, _) -> actual = name
  | _ -> false

let clean_source_name = Call_resolution.strip_callable_id_suffix

let direct_call callable_id source_name call_pure =
  { callable_id; source_name = clean_source_name source_name; call_pure }

let field_access_kind receiver_ty field =
  match Types.head_resolve receiver_ty with
  | Ast.TyTuple elems | Ast.TyNamed ("Tuple", elems) -> (
      match int_of_string_opt field with
      | Some index when index >= 0 && index < List.length elems ->
          TupleField { tuple_index = index; tuple_field_name = field }
      | Some _ | None -> TupleInvalidField field)
  | Ast.TyNamed (name, _) when name = Intrinsic.Source.range_type ->
      if field = Intrinsic.Source.range_start_field then RangeField RangeStart
      else if field = Intrinsic.Source.range_end_field then RangeField RangeEnd
      else RangeInvalidField field
  | _ -> RecordField field

let call_kind_of_resolved_call ~callee_ast = function
  | None -> UnresolvedCall
  | Some ({ Ast.call_target = Ast.CallDirect raw_direct; _ } as resolved_call)
    -> (
      let direct =
        direct_call raw_direct.callable_id raw_direct.source_name
          raw_direct.call_pure
      in
      match raw_direct.origin with
      | Ast.CallableLocal -> LocalCall direct
      | Ast.CallableImported module_path ->
          ImportedCall
            {
              imported_direct = direct;
              module_path;
              imported_intrinsic =
                Intrinsic.imported_call_of_source ~module_path
                  ~source_name:direct.source_name;
            }
      | Ast.CallableBuiltin ->
          BuiltinCall
            {
              builtin_direct = direct;
              builtin_intrinsic =
                Intrinsic.builtin_call_of_source_name direct.source_name;
            }
      | Ast.CallableForeign -> ForeignCall direct
      | Ast.CallableConstructor parent_type ->
          ConstructorCall
            {
              constructor_direct = direct;
              parent_type;
              constructor_resolved_call = Some resolved_call;
              constructor_callee_ast = callee_ast;
            }
      | Ast.CallableImplMethod -> ImplMethodCall direct)
  | Some
      {
        Ast.call_target =
          Ast.CallTraitMethod
            { trait_name; method_name; call_pure; callable_id = _ };
        _;
      } ->
      TraitCall
        {
          trait_name;
          method_name;
          trait_pure = call_pure;
          trait_intrinsic =
            Intrinsic.trait_call_of_source ~trait_name ~method_name;
        }
  | Some { Ast.call_target = Ast.CallClosure { call_pure }; _ } ->
      ClosureCall { closure_pure = call_pure }

let reference_kind_of_resolved_call ctx ident_name = function
  | Some
      {
        Ast.call_target =
          Ast.CallDirect
            { callable_id; source_name; call_pure; origin = Ast.CallableLocal };
        _;
      } ->
      LocalFunctionReference (direct_call callable_id source_name call_pure)
  | Some { Ast.call_target = Ast.CallDirect { call_pure = false; _ }; _ } ->
      ImpureFunctionReference
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
      UnsupportedFunctionReference (clean_source_name source_name)
  | Some { Ast.call_target = Ast.CallTraitMethod _ | Ast.CallClosure _; _ }
  | None -> (
      match ctx.nullary_constructor ident_name with
      | Some constructor -> NullaryConstructorReference constructor
      | None -> ValueReference)

let option_map f = function
  | None -> Ok None
  | Some value ->
      let* value = f value in
      Ok (Some value)

let list_map f values =
  let rec loop acc = function
    | [] -> Ok (List.rev acc)
    | value :: rest ->
        let* value = f value in
        loop (value :: acc) rest
  in
  loop [] values

let named_list_map f values =
  let rec loop acc = function
    | [] -> Ok (List.rev acc)
    | (name, value) :: rest ->
        let* value = f value in
        loop ((name, value) :: acc) rest
  in
  loop [] values

let pair_list_map f values =
  let rec loop acc = function
    | [] -> Ok (List.rev acc)
    | (left, right) :: rest ->
        let* left = f left in
        let* right = f right in
        loop ((left, right) :: acc) rest
  in
  loop [] values

let default_nullary_constructor _ = None
let default_module_alias _ = None
let default_module_has_global ~module_path:_ ~name:_ = false

let translate_context ?(module_alias = default_module_alias)
    ?(module_has_global = default_module_has_global) nullary_constructor =
  { nullary_constructor; module_alias; module_has_global }

let rec of_typed_expr_with ctx expr =
  match Typed_ast.expr_desc expr with
  | Error err -> Error (TypedAstError err)
  | Ok desc -> of_desc ctx expr desc

and of_desc ctx expr = function
  | Typed_ast.ELiteral lit -> Ok (make expr (Literal lit))
  | Typed_ast.EIdent name ->
      Ok
        (make expr
           (Ident
              {
                ident_name = name;
                reference_kind =
                  reference_kind_of_resolved_call ctx name
                    (Typed_ast.expr_resolved_call expr);
              }))
  | Typed_ast.EAscription (inner, _)
  | Typed_ast.EOpaqueInto (_, inner)
  | Typed_ast.EOpaqueFrom (_, inner) ->
      let* inner = of_typed_expr_with ctx inner in
      Ok (make expr (Transparent inner))
  | Typed_ast.EUnary (op, inner) ->
      let* inner = of_typed_expr_with ctx inner in
      Ok (make expr (Unary (op, inner)))
  | Typed_ast.EBinary (op, left, right) ->
      let* left = of_typed_expr_with ctx left in
      let* right = of_typed_expr_with ctx right in
      Ok (make expr (Binary (op, left, right)))
  | Typed_ast.ELogical (op, left, right) ->
      let* left = of_typed_expr_with ctx left in
      let* right = of_typed_expr_with ctx right in
      Ok (make expr (Logical (op, left, right)))
  | Typed_ast.EIf (cond, then_expr, else_expr) ->
      let* cond = of_typed_expr_with ctx cond in
      let* then_expr = of_typed_expr_with ctx then_expr in
      let* else_expr = option_map (of_typed_expr_with ctx) else_expr in
      Ok (make expr (If (cond, then_expr, else_expr)))
  | Typed_ast.EBlock exprs ->
      let* block = of_block_exprs ctx exprs in
      Ok (make expr (Block block))
  | Typed_ast.ETuple values ->
      let* values = list_map (of_typed_expr_with ctx) values in
      Ok (make expr (Tuple values))
  | Typed_ast.EList values ->
      let* values = list_map (of_typed_expr_with ctx) values in
      Ok (make expr (List values))
  | Typed_ast.EVector values ->
      let* values = list_map (of_typed_expr_with ctx) values in
      Ok (make expr (Vector values))
  | Typed_ast.ERecord []
    when is_named_type Intrinsic.Source.dict_type (Typed_ast.value_type expr) ->
      Ok (make expr (Dict []))
  | Typed_ast.ERecord fields ->
      let* fields = named_list_map (of_typed_expr_with ctx) fields in
      Ok (make expr (Record fields))
  | Typed_ast.EDict pairs ->
      let* pairs = pair_list_map (of_typed_expr_with ctx) pairs in
      Ok (make expr (Dict pairs))
  | Typed_ast.EFieldAccess (receiver, field) ->
      let qualified_module =
        match (Typed_ast.ast receiver).Ast.expr_desc with
        | Ast.EIdent alias -> ctx.module_alias alias
        | _ -> None
      in
      begin match qualified_module with
      | Some module_path when ctx.module_has_global ~module_path ~name:field ->
          Ok
            (make expr
               (ImportedGlobal
                  { global_module_path = module_path; global_name = field }))
      | Some module_path -> (
          match ctx.nullary_constructor field with
          | Some constructor ->
              Ok
                (make expr
                   (Ident
                      {
                        ident_name = field;
                        reference_kind = NullaryConstructorReference constructor;
                      }))
          | None ->
              Ok
                (make expr
                   (ImportedGlobal
                      { global_module_path = module_path; global_name = field }))
          )
      | None ->
          let* receiver = of_typed_expr_with ctx receiver in
          let field_kind = field_access_kind receiver.ty field in
          Ok (make expr (FieldAccess { field_receiver = receiver; field_kind }))
      end
  | Typed_ast.ERecordUpdate (base, fields) ->
      let* base = of_typed_expr_with ctx base in
      let* fields = named_list_map (of_typed_expr_with ctx) fields in
      Ok (make expr (RecordUpdate (base, fields)))
  | Typed_ast.EStringInterp (parts, is_multiline) ->
      let* parts = list_map (interp_part ctx) parts in
      Ok (make expr (StringInterp (parts, is_multiline)))
  | Typed_ast.ELambda func -> Ok (make expr (Lambda func))
  | Typed_ast.ECall (callee, args) ->
      let callee_ast = Typed_ast.ast callee in
      let* callee = of_typed_expr_with ctx callee in
      let* args = list_map (of_typed_expr_with ctx) args in
      let call_kind =
        call_kind_of_resolved_call ~callee_ast
          (Typed_ast.expr_resolved_call expr)
      in
      Ok (make expr (Call { call_kind; callee; args }))
  | Typed_ast.EMatch (scrutinee, cases) ->
      let* scrutinee = of_typed_expr_with ctx scrutinee in
      let* cases = list_map (match_case ctx) cases in
      Ok (make expr (Match (scrutinee, cases)))
  | Typed_ast.EWhile (cond, body) ->
      let* cond = of_typed_expr_with ctx cond in
      let* body = of_typed_expr_with ctx body in
      Ok (make expr (While (cond, body)))
  | Typed_ast.EFor (name, iter, body) ->
      let* iter = of_typed_expr_with ctx iter in
      let* body = of_typed_expr_with ctx body in
      Ok (make expr (For (name, iter, body)))
  | Typed_ast.EForTuple (names, iter, body) ->
      let* iter = of_typed_expr_with ctx iter in
      let* body = of_typed_expr_with ctx body in
      Ok (make expr (ForTuple (names, iter, body)))
  | Typed_ast.ERange (start_expr, end_expr) ->
      let* start_expr = of_typed_expr_with ctx start_expr in
      let* end_expr = of_typed_expr_with ctx end_expr in
      Ok (make expr (Range (start_expr, end_expr)))
  | Typed_ast.EAssign (name, rhs) ->
      let* rhs = of_typed_expr_with ctx rhs in
      Ok (make expr (Assign (name, rhs)))
  | Typed_ast.ECompoundAssign (name, op, rhs) ->
      let* rhs = of_typed_expr_with ctx rhs in
      Ok (make expr (CompoundAssign (name, op, rhs)))
  | Typed_ast.EBreak -> Ok (make expr Break)
  | Typed_ast.EContinue -> Ok (make expr Continue)
  | Typed_ast.EVarDecl _ | Typed_ast.ETupleDestruct _
  | Typed_ast.EQuestionBind _ ->
      unsupported (Typed_ast.loc expr) "block binding as a value"
  | Typed_ast.ESubscript _ | Typed_ast.ESubscriptMulti _ ->
      unsupported (Typed_ast.loc expr) "subscript expressions"
  | Typed_ast.ESubscriptAssign _ ->
      unsupported (Typed_ast.loc expr) "subscript assignments"
  | Typed_ast.EStringInterpRaw _ ->
      unsupported (Typed_ast.loc expr) "raw string interpolation"
  | Typed_ast.EWith _ ->
      unsupported (Typed_ast.loc expr) "resource with expressions"
  | Typed_ast.EDebugBlock _ -> unsupported (Typed_ast.loc expr) "debug blocks"
  | Typed_ast.ESelect _ -> unsupported (Typed_ast.loc expr) "select expressions"
  | Typed_ast.EConcurrent _ ->
      unsupported (Typed_ast.loc expr) "concurrent blocks"
  | Typed_ast.EConcurrentBind _ ->
      unsupported (Typed_ast.loc expr) "concurrent bindings"
  | Typed_ast.EConcurrentlyLoop _ ->
      unsupported (Typed_ast.loc expr) "concurrently loops"
  | Typed_ast.EDetach _ -> unsupported (Typed_ast.loc expr) "detach expressions"
  | Typed_ast.EBuiltin _ ->
      unsupported (Typed_ast.loc expr) "builtin expressions"
  | Typed_ast.EFuncDecl _ ->
      unsupported (Typed_ast.loc expr) "nested function declarations"
  | Typed_ast.ELoopView _ -> unsupported (Typed_ast.loc expr) "loop views"
  | Typed_ast.EVoid -> Ok (make expr Void)

and interp_part ctx = function
  | Typed_ast.InterpLit text -> Ok (InterpLit text)
  | Typed_ast.InterpExpr expr ->
      let* expr = of_typed_expr_with ctx expr in
      Ok (InterpExpr expr)

and of_block_exprs ctx exprs =
  match List.rev exprs with
  | [] -> unsupported Ast.dummy_loc "empty blocks"
  | result :: item_exprs_rev ->
      let* items =
        list_map (of_block_item_expr ctx) (List.rev item_exprs_rev)
      in
      let* result = of_typed_expr_with ctx result in
      Ok { items; result }

and of_block_item_expr ctx expr =
  match Typed_ast.expr_desc expr with
  | Error err -> Error (TypedAstError err)
  | Ok (Typed_ast.EVarDecl (name, ty, init, is_mutable)) ->
      let* init = of_typed_expr_with ctx init in
      Ok (BindValue (name, ty, init, is_mutable))
  | Ok (Typed_ast.ETupleDestruct (names, init)) ->
      let* init = of_typed_expr_with ctx init in
      Ok (BindTuple (names, init))
  | Ok (Typed_ast.EQuestionBind (name, ty, rhs)) ->
      let* rhs = of_typed_expr_with ctx rhs in
      Ok (BindQuestion (name, ty, rhs))
  | Ok desc ->
      let* expr = of_desc ctx expr desc in
      Ok (Discard expr)

and match_case ctx case =
  let* body = of_typed_expr_with ctx case.Typed_ast.case_body in
  Ok { pattern = case.case_pattern; body }

let of_typed_expr ?(nullary_constructor = default_nullary_constructor)
    ?(module_alias = default_module_alias)
    ?(module_has_global = default_module_has_global) expr =
  of_typed_expr_with
    (translate_context ~module_alias ~module_has_global nullary_constructor)
    expr

let of_function_body ?(nullary_constructor = default_nullary_constructor)
    ?(module_alias = default_module_alias)
    ?(module_has_global = default_module_has_global) func =
  let ctx =
    translate_context ~module_alias ~module_has_global nullary_constructor
  in
  match Typed_ast.func_body_expr func with
  | Error err -> Error (TypedAstError err)
  | Ok None -> Ok None
  | Ok (Some body) ->
      let* body = of_typed_expr_with ctx body in
      Ok (Some body)

let of_typed_var_initializer
    ?(nullary_constructor = default_nullary_constructor)
    ?(module_alias = default_module_alias)
    ?(module_has_global = default_module_has_global) typed_var =
  let ctx =
    translate_context ~module_alias ~module_has_global nullary_constructor
  in
  match Typed_ast.var_value_expr typed_var with
  | Error err -> Error (TypedAstError err)
  | Ok init -> of_typed_expr_with ctx init
