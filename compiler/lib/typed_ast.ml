(** Compatibility boundary between inferred AST and later typed phases. *)

type type_origin = Ast.expr_type_origin =
  | ExplicitAnnotation of Ast.type_expr
  | Inferred
  | Synthesized of string

type type_info = {
  source_ty : Ast.type_expr option;
  semantic_ty : Ast.type_expr;
  value_ty : Ast.type_expr;
  origin : type_origin;
  widening : Type_widening_metadata.decision;
  proofs : Type_proof_metadata.expr_proofs;
}

type func_param_info = {
  param_name : string option;
  source_param_ty : Ast.type_expr;
  semantic_param_ty : Ast.type_expr;
}

type func_info = {
  source_return_ty : Ast.type_expr option;
  semantic_return_ty : Ast.type_expr;
  param_infos : func_param_info list;
}

type var_info = {
  source_binding_ty : Ast.type_expr option;
  binding_ty : Ast.type_expr;
}

type record_field_info = {
  field_name : string;
  source_field_ty : Ast.type_expr;
  semantic_field_ty : Ast.type_expr;
}

type record_info = { field_infos : record_field_info list }

type type_alias_info = {
  source_target_ty : Ast.type_expr;
  semantic_target_ty : Ast.type_expr;
}

type expr = { ast : Ast.expr; info : type_info }
type func_decl = { ast_func : Ast.func_decl; info : func_info }
type var_decl = { ast_var : Ast.var_decl; info : var_info }
type record_decl = { ast_record : Ast.record_decl; info : record_info }

type type_alias_decl = {
  ast_alias : Ast.type_alias_decl;
  info : type_alias_info;
}

type impl_decl = { ast_impl : Ast.impl_decl; typed_methods : func_decl list }

type decl_info =
  | FunctionDecl of func_decl
  | VarDecl of var_decl
  | RecordDecl of record_decl
  | TypeAliasDecl of type_alias_decl
  | ImplDecl of impl_decl
  | PrivateDecl of decl
  | NonFunctionDecl

and decl = { ast_decl : Ast.decl; decl_info : decl_info }

type program = { ast_program : Ast.program; typed_decls : decl list }

type decl_view =
  | DeclFunction of func_decl
  | DeclVar of var_decl
  | DeclRecord of record_decl
  | DeclTypeAlias of type_alias_decl
  | DeclImpl of impl_decl
  | DeclPrivate of decl
  | DeclOther

type loop_view = {
  loop_view_kind : Ast.loop_view_kind;
  loop_view_source : expr;
  loop_view_size_arg : expr option;
  loop_view_elem_type : Ast.type_expr;
}

type string_interp_part = InterpLit of string | InterpExpr of expr

type match_case = {
  case_pattern : Ast.pattern;
  case_body : expr;
  case_loc : Ast.loc;
}

type expr_desc =
  | EIdent of string
  | ELiteral of Ast.literal
  | EBinary of Ast.binop * expr * expr
  | EUnary of Ast.unop * expr
  | ELogical of Ast.logop * expr * expr
  | EAscription of expr * Ast.type_expr
  | ECall of expr * expr list
  | EIf of expr * expr * expr option
  | EMatch of expr * match_case list
  | EBlock of expr list
  | ETuple of expr list
  | EVector of expr list
  | EList of expr list
  | ERecord of (string * expr) list
  | ERecordUpdate of expr * (string * expr) list
  | EFieldAccess of expr * string
  | ELambda of func_decl
  | EVoid
  | EWhile of expr * expr
  | EFor of string * expr * expr
  | EForTuple of string list * expr * expr
  | ELoopView of loop_view
  | EAssign of string * expr
  | EVarDecl of string * Ast.type_expr option * expr * bool
  | ETupleDestruct of string list * expr
  | ERange of expr * expr
  | EBreak
  | EContinue
  | ESubscript of expr * expr
  | ESubscriptMulti of expr * expr list
  | ESubscriptAssign of expr * expr list * expr
  | EStringInterp of string_interp_part list * bool
  | EStringInterpRaw of string * bool
  | ETry of expr list
  | ETryBind of string * Ast.type_expr option * expr
  | EDebugBlock of expr list
  | EConcurrent of expr list * expr option * int option
  | EConcurrentBind of string * Ast.type_expr option * expr
  | EConcurrentFor of string * expr * expr * expr option * int option
  | EDetach of expr
  | EDict of (expr * expr) list
  | EBuiltin of string option
  | EFuncDecl of func_decl

type error =
  | MissingExprType of { loc : Ast.loc; context : string }
  | MissingExprTypeInfo of { loc : Ast.loc; context : string }
  | UnfinalizedExprType of {
      loc : Ast.loc;
      context : string;
      ty : Ast.type_expr;
    }
  | MissingRequiredType of { loc : Ast.loc; context : string }
  | UnfinalizedType of { loc : Ast.loc; context : string; ty : Ast.type_expr }
  | InvalidTypeInfo of { loc : Ast.loc; context : string; message : string }

let ast (expr : expr) = expr.ast
let func_ast (func : func_decl) = func.ast_func
let func_info (func : func_decl) = func.info
let func_param_infos (func : func_decl) = func.info.param_infos
let func_semantic_return_type (func : func_decl) = func.info.semantic_return_ty
let var_ast (var : var_decl) = var.ast_var
let var_info (var : var_decl) = var.info
let var_binding_type (var : var_decl) = var.info.binding_ty
let record_ast (record : record_decl) = record.ast_record
let record_info (record : record_decl) = record.info
let record_field_infos (record : record_decl) = record.info.field_infos
let type_alias_ast (alias : type_alias_decl) = alias.ast_alias
let type_alias_info (alias : type_alias_decl) = alias.info
let type_alias_semantic_target_type alias = alias.info.semantic_target_ty
let decl_ast decl = decl.ast_decl

let decl_view decl =
  match decl.decl_info with
  | FunctionDecl func -> DeclFunction func
  | VarDecl var -> DeclVar var
  | RecordDecl record -> DeclRecord record
  | TypeAliasDecl alias -> DeclTypeAlias alias
  | ImplDecl impl -> DeclImpl impl
  | PrivateDecl inner -> DeclPrivate inner
  | NonFunctionDecl -> DeclOther

let rec decl_func decl =
  match decl.decl_info with
  | FunctionDecl func -> Some func
  | VarDecl _ -> None
  | RecordDecl _ -> None
  | TypeAliasDecl _ -> None
  | ImplDecl _ -> None
  | PrivateDecl inner -> decl_func inner
  | NonFunctionDecl -> None

let program_ast program = program.ast_program
let program_decls program = program.typed_decls
let loc (expr : expr) = expr.ast.expr_loc
let type_info (expr : expr) = expr.info
let impl_ast (impl : impl_decl) = impl.ast_impl
let impl_methods (impl : impl_decl) = impl.typed_methods

let type_info_to_ast (info : type_info) : Ast.expr_type_info =
  {
    source_ty = info.source_ty;
    semantic_ty = info.semantic_ty;
    value_ty = info.value_ty;
    origin = info.origin;
    widening = info.widening;
    proofs = info.proofs;
  }

let type_info_of_ast (info : Ast.expr_type_info) : type_info =
  {
    source_ty = info.source_ty;
    semantic_ty = info.semantic_ty;
    value_ty = info.value_ty;
    origin = info.origin;
    widening = info.widening;
    proofs = info.proofs;
  }

let type_info_source_type (info : type_info) = info.source_ty
let type_info_semantic_type (info : type_info) = info.semantic_ty
let type_info_value_type (info : type_info) = info.value_ty
let type_info_origin (info : type_info) = info.origin
let type_info_widening (info : type_info) = info.widening
let type_info_proofs (info : type_info) = info.proofs
let semantic_type (expr : expr) = expr.info.semantic_ty
let value_type (expr : expr) = expr.info.value_ty

let rec contains_meta_type (ty : Ast.type_expr) : bool =
  match ty with
  | TyMeta _ -> true
  | TyNamed (_, args) -> List.exists contains_meta_type args
  | TyArray (elem, dims) ->
      contains_meta_type elem || List.exists contains_meta_type dims
  | TyFunc { params; return; _ } ->
      List.exists contains_meta_type params || contains_meta_type return
  | TyTuple elems -> List.exists contains_meta_type elems
  | TyRange inner -> contains_meta_type inner
  | TyDimOp (_, lhs, rhs) -> contains_meta_type lhs || contains_meta_type rhs
  | TyVar _ | TyBoundVar _ | TyConstInt _ | TySelf | TyVarDims _ -> false

let ( let* ) = Result.bind

let ensure_final_type ~loc ~context ty =
  if contains_meta_type ty then Error (UnfinalizedType { loc; context; ty })
  else Ok ()

let ensure_optional_type ~loc ~context = function
  | None -> Ok ()
  | Some ty -> ensure_final_type ~loc ~context ty

let ensure_required_type ~loc ~missing_context ~context = function
  | None -> Error (MissingRequiredType { loc; context = missing_context })
  | Some ty -> ensure_final_type ~loc ~context ty

let ensure_types_equal ~loc ~context ~message expected actual =
  if expected = actual then Ok ()
  else Error (InvalidTypeInfo { loc; context; message })

let validate_type_origin ~loc ~context = function
  | ExplicitAnnotation ty ->
      ensure_final_type ~loc ~context:(context ^ " explicit annotation") ty
  | Inferred | Synthesized _ -> Ok ()

let validate_widening_decision ~loc ~context (info : type_info) =
  match info.widening with
  | Type_widening_metadata.Keep ty ->
      let* () =
        ensure_final_type ~loc ~context:(context ^ " widening decision") ty
      in
      let* () =
        ensure_types_equal ~loc ~context
          ~message:"kept widening decision must match semantic type"
          info.semantic_ty ty
      in
      ensure_types_equal ~loc ~context
        ~message:"kept widening decision must match value type" info.value_ty ty
  | Type_widening_metadata.Widen { from_ty; to_ty; _ } ->
      let* () =
        ensure_final_type ~loc ~context:(context ^ " widening source") from_ty
      in
      let* () =
        ensure_final_type ~loc ~context:(context ^ " widening target") to_ty
      in
      let* () =
        ensure_types_equal ~loc ~context
          ~message:"widening source must match semantic type" info.semantic_ty
          from_ty
      in
      ensure_types_equal ~loc ~context
        ~message:"widening target must match value type" info.value_ty to_ty

let validate_type_info ~loc ~context (info : type_info) =
  let* () =
    ensure_optional_type ~loc ~context:(context ^ " source type") info.source_ty
  in
  let* () =
    ensure_final_type ~loc
      ~context:(context ^ " semantic type")
      info.semantic_ty
  in
  let* () =
    ensure_final_type ~loc ~context:(context ^ " value type") info.value_ty
  in
  let* () = validate_type_origin ~loc ~context info.origin in
  validate_widening_decision ~loc ~context info

let make_type_info ?source_ty ?(origin = Inferred)
    ?(proofs = Type_proof_metadata.unproven_expr) ~loc ~context ~semantic_ty
    ~value_ty ~widening () =
  let info = { source_ty; semantic_ty; value_ty; origin; widening; proofs } in
  let* () = validate_type_info ~loc ~context info in
  Ok info

let type_info_from_ast_type_info ~loc ~context (info : Ast.expr_type_info) =
  let typed_info = type_info_of_ast info in
  let* () = validate_type_info ~loc ~context typed_info in
  Ok typed_info

let of_ast_expr_shallow ?(context = "expression type") ast =
  match (ast.Ast.expr_type, ast.expr_type_info) with
  | None, _ -> Error (MissingExprType { loc = ast.expr_loc; context })
  | Some ty, _ when contains_meta_type ty ->
      Error (UnfinalizedExprType { loc = ast.expr_loc; context; ty })
  | Some ty, Some ast_info ->
      let* info =
        type_info_from_ast_type_info ~loc:ast.expr_loc ~context ast_info
      in
      let* () =
        ensure_types_equal ~loc:ast.expr_loc ~context
          ~message:"expr_type must match semantic type info" info.semantic_ty ty
      in
      Ok { ast; info }
  | Some _, None -> Error (MissingExprTypeInfo { loc = ast.expr_loc; context })

let rec validate_expr_tree expr =
  let* _ = of_ast_expr_shallow expr in
  match expr.Ast.expr_desc with
  | Ast.EVarDecl (_, ty_opt, init, _) ->
      let* () =
        ensure_optional_type ~loc:expr.expr_loc ~context:"variable annotation"
          ty_opt
      in
      validate_expr_tree init
  | Ast.ETryBind (_, ty_opt, value) ->
      let* () =
        ensure_optional_type ~loc:expr.expr_loc
          ~context:"try binding annotation" ty_opt
      in
      validate_expr_tree value
  | Ast.EConcurrentBind (_, ty_opt, value) ->
      let* () =
        ensure_optional_type ~loc:expr.expr_loc
          ~context:"concurrent binding annotation" ty_opt
      in
      validate_expr_tree value
  | Ast.ELoopView view ->
      let* () =
        ensure_final_type ~loc:expr.expr_loc ~context:"loop view element type"
          view.loop_view_elem_type
      in
      let* () = validate_expr_tree view.loop_view_source in
      Option.fold ~none:(Ok ())
        ~some:(fun size_arg -> validate_expr_tree size_arg)
        view.loop_view_size_arg
  | Ast.ELambda func | Ast.EFuncDecl func ->
      let* _ = of_ast_func_decl_with_source func in
      Ok ()
  | _ -> validate_expr_children (Ast.expr_children expr)

and validate_expr_children = function
  | [] -> Ok ()
  | expr :: rest ->
      let* () = validate_expr_tree expr in
      validate_expr_children rest

and validate_param ?(missing_context = "param") (param : Ast.param) =
  ensure_required_type ~loc:param.param_loc ~missing_context
    ~context:"function parameter type" param.param_type

and validate_func_body = function
  | Ast.FuncBodyExpr body -> validate_expr_tree body
  | Ast.FuncBuiltinBody _ | Ast.FuncForeign _ | Ast.FuncNoBody -> Ok ()

and func_body_semantic_return_type = function
  | Ast.FuncBodyExpr body ->
      let* typed_body =
        of_ast_expr_shallow ~context:"function body type" body
      in
      Ok (semantic_type typed_body)
  | Ast.FuncBuiltinBody _ | Ast.FuncForeign _ | Ast.FuncNoBody ->
      Ok (Ast.TyNamed ("Void", []))

and func_decl_semantic_return_type ast_func =
  match ast_func.Ast.func_body with
  | Ast.FuncBodyExpr _ -> func_body_semantic_return_type ast_func.func_body
  | Ast.FuncBuiltinBody _ | Ast.FuncForeign _ | Ast.FuncNoBody -> (
      match ast_func.func_return_type with
      | Some return_ty -> Ok return_ty
      | None -> func_body_semantic_return_type ast_func.func_body)

and param_semantic_type param =
  match param.Ast.param_type with
  | Some ty -> Ok ty
  | None ->
      Error
        (InvalidTypeInfo
           {
             loc = param.param_loc;
             context = "function parameter metadata";
             message = "canonical function parameter is missing a type";
           })

and make_func_param_infos ?source_func ~loc ast_func =
  let invalid_param_arity message =
    Error
      (InvalidTypeInfo { loc; context = "function source metadata"; message })
  in
  let rec without_source acc (canonical_params : Ast.param list) =
    match canonical_params with
    | [] -> Ok (List.rev acc)
    | canonical :: rest ->
        let* semantic_param_ty = param_semantic_type canonical in
        let info =
          {
            param_name = canonical.param_name;
            source_param_ty = semantic_param_ty;
            semantic_param_ty;
          }
        in
        without_source (info :: acc) rest
  in
  let rec with_source acc (source_params : Ast.param list)
      (canonical_params : Ast.param list) =
    match (source_params, canonical_params) with
    | [], [] -> Ok (List.rev acc)
    | [], _ :: _ ->
        invalid_param_arity
          "source function has fewer parameters than canonical function"
    | source :: source_rest, canonical :: canonical_rest ->
        let* semantic_param_ty = param_semantic_type canonical in
        let* () =
          ensure_optional_type ~loc:source.param_loc
            ~context:"function parameter source annotation" source.param_type
        in
        let source_param_ty =
          match source.param_type with
          | Some ty -> ty
          | None -> semantic_param_ty
        in
        let info =
          {
            param_name = canonical.param_name;
            source_param_ty;
            semantic_param_ty;
          }
        in
        with_source (info :: acc) source_rest canonical_rest
    | _ :: _, [] ->
        invalid_param_arity
          "source function has more parameters than canonical function"
  in
  match source_func with
  | None -> without_source [] ast_func.Ast.func_params
  | Some source ->
      with_source [] source.Ast.func_params ast_func.Ast.func_params

and make_func_info ?source_func ast_func =
  let* semantic_return_ty = func_decl_semantic_return_type ast_func in
  let* param_infos =
    make_func_param_infos ?source_func ~loc:(func_decl_loc ast_func) ast_func
  in
  let source_return_ty =
    match source_func with
    | Some source -> source.Ast.func_return_type
    | None -> ast_func.Ast.func_return_type
  in
  Ok { source_return_ty; semantic_return_ty; param_infos }

and of_ast_func_decl_with_source ?source_func ast_func =
  let missing_context =
    match ast_func.func_name with None -> "lambda param" | Some _ -> "param"
  in
  let* () = validate_params ~missing_context ast_func.func_params in
  let* () =
    ensure_optional_type ~loc:(func_decl_loc ast_func)
      ~context:"function return type" ast_func.func_return_type
  in
  let* () =
    match source_func with
    | Some source ->
        ensure_optional_type ~loc:(func_decl_loc ast_func)
          ~context:"function source return type" source.Ast.func_return_type
    | None -> Ok ()
  in
  let* () = validate_dim_constraints ast_func.func_dim_constraints in
  let* () = validate_func_body ast_func.func_body in
  let* info = make_func_info ?source_func ast_func in
  Ok { ast_func; info }

and of_ast_var_decl_with_source ?source_var (ast_var : Ast.var_decl) =
  let source_var = Option.value source_var ~default:ast_var in
  let* () =
    ensure_optional_type ~loc:ast_var.var_value.expr_loc
      ~context:"global variable annotation" ast_var.var_type
  in
  let* () =
    ensure_optional_type ~loc:ast_var.var_value.expr_loc
      ~context:"global variable source annotation" source_var.var_type
  in
  let* () = validate_expr_tree ast_var.var_value in
  let* typed_value =
    of_ast_expr_shallow ~context:"global variable initializer type"
      ast_var.var_value
  in
  let binding_ty =
    match ast_var.var_type with
    | Some annotation -> annotation
    | None -> value_type typed_value
  in
  Ok { ast_var; info = { source_binding_ty = source_var.var_type; binding_ty } }

and validate_params ?(missing_context = "param") = function
  | [] -> Ok ()
  | param :: rest ->
      let* () = validate_param ~missing_context param in
      validate_params ~missing_context rest

and validate_dim_constraints = function
  | [] -> Ok ()
  | (lhs, rhs) :: rest ->
      let* () =
        ensure_final_type ~loc:Ast.dummy_loc ~context:"dimension constraint" lhs
      in
      let* () =
        ensure_final_type ~loc:Ast.dummy_loc ~context:"dimension constraint" rhs
      in
      validate_dim_constraints rest

and func_decl_loc (f : Ast.func_decl) =
  match f.func_body with
  | FuncBodyExpr body -> body.expr_loc
  | FuncBuiltinBody (_, loc) -> loc
  | FuncForeign _ | FuncNoBody -> (
      match f.func_params with p :: _ -> p.param_loc | [] -> Ast.dummy_loc)

let of_ast_expr ?(context = "expression type") ast =
  let* typed = of_ast_expr_shallow ~context ast in
  let* () = validate_expr_tree ast in
  Ok typed

let typed_child ?(context = "child expression type") ast =
  of_ast_expr_shallow ~context ast

let var_value_expr (var : var_decl) =
  typed_child ~context:"global variable initializer type" var.ast_var.var_value

let typed_children ?(context = "child expression type") exprs =
  List.fold_right
    (fun expr acc ->
      let* rest = acc in
      let* typed = typed_child ~context expr in
      Ok (typed :: rest))
    exprs (Ok [])

let typed_child_opt ?(context = "child expression type") = function
  | None -> Ok None
  | Some expr ->
      let* typed = typed_child ~context expr in
      Ok (Some typed)

let typed_func_decl ?(context = "function expression")
    (ast_func : Ast.func_decl) =
  let* () = validate_params ast_func.func_params in
  let* () =
    ensure_optional_type ~loc:(func_decl_loc ast_func)
      ~context:"function return type" ast_func.func_return_type
  in
  let* () = validate_dim_constraints ast_func.func_dim_constraints in
  let* info = make_func_info ast_func in
  let* () =
    match ast_func.func_body with
    | Ast.FuncBodyExpr body ->
        let* _ = typed_child ~context body in
        Ok ()
    | Ast.FuncBuiltinBody _ | Ast.FuncForeign _ | Ast.FuncNoBody -> Ok ()
  in
  Ok { ast_func; info }

let func_body_expr func =
  match func.ast_func.func_body with
  | Ast.FuncBodyExpr body ->
      let* typed = typed_child ~context:"function body type" body in
      Ok (Some typed)
  | Ast.FuncBuiltinBody _ | Ast.FuncForeign _ | Ast.FuncNoBody -> Ok None

let expr_desc (expr : expr) =
  match expr.ast.Ast.expr_desc with
  | Ast.EIdent name -> Ok (EIdent name)
  | Ast.ELiteral lit -> Ok (ELiteral lit)
  | Ast.EBinary (op, left, right) ->
      let* left = typed_child left in
      let* right = typed_child right in
      Ok (EBinary (op, left, right))
  | Ast.EUnary (op, inner) ->
      let* inner = typed_child inner in
      Ok (EUnary (op, inner))
  | Ast.ELogical (op, left, right) ->
      let* left = typed_child left in
      let* right = typed_child right in
      Ok (ELogical (op, left, right))
  | Ast.EAscription (inner, ty) ->
      let* inner = typed_child inner in
      Ok (EAscription (inner, ty))
  | Ast.ECall (callee, args) ->
      let* callee = typed_child callee in
      let* args = typed_children args in
      Ok (ECall (callee, args))
  | Ast.EIf (cond, then_, else_) ->
      let* cond = typed_child cond in
      let* then_ = typed_child then_ in
      let* else_ = typed_child_opt else_ in
      Ok (EIf (cond, then_, else_))
  | Ast.EMatch (scrutinee, cases) ->
      let* scrutinee = typed_child scrutinee in
      let* cases =
        List.fold_right
          (fun case acc ->
            let* rest = acc in
            let* case_body = typed_child case.Ast.case_body in
            Ok
              ({
                 case_pattern = case.case_pattern;
                 case_body;
                 case_loc = case.case_loc;
               }
              :: rest))
          cases (Ok [])
      in
      Ok (EMatch (scrutinee, cases))
  | Ast.EBlock exprs ->
      let* exprs = typed_children exprs in
      Ok (EBlock exprs)
  | Ast.ETuple exprs ->
      let* exprs = typed_children exprs in
      Ok (ETuple exprs)
  | Ast.EVector exprs ->
      let* exprs = typed_children exprs in
      Ok (EVector exprs)
  | Ast.EList exprs ->
      let* exprs = typed_children exprs in
      Ok (EList exprs)
  | Ast.ERecord fields ->
      let* fields =
        List.fold_right
          (fun (name, value) acc ->
            let* rest = acc in
            let* value = typed_child value in
            Ok ((name, value) :: rest))
          fields (Ok [])
      in
      Ok (ERecord fields)
  | Ast.ERecordUpdate (base, fields) ->
      let* base = typed_child base in
      let* fields =
        List.fold_right
          (fun (name, value) acc ->
            let* rest = acc in
            let* value = typed_child value in
            Ok ((name, value) :: rest))
          fields (Ok [])
      in
      Ok (ERecordUpdate (base, fields))
  | Ast.EFieldAccess (obj, name) ->
      let* obj = typed_child obj in
      Ok (EFieldAccess (obj, name))
  | Ast.ELambda func ->
      let* func = typed_func_decl func in
      Ok (ELambda func)
  | Ast.EVoid -> Ok EVoid
  | Ast.EWhile (cond, body) ->
      let* cond = typed_child cond in
      let* body = typed_child body in
      Ok (EWhile (cond, body))
  | Ast.EFor (name, iter, body) ->
      let* iter = typed_child iter in
      let* body = typed_child body in
      Ok (EFor (name, iter, body))
  | Ast.EForTuple (names, iter, body) ->
      let* iter = typed_child iter in
      let* body = typed_child body in
      Ok (EForTuple (names, iter, body))
  | Ast.ELoopView view ->
      let* loop_view_source = typed_child view.loop_view_source in
      let* loop_view_size_arg = typed_child_opt view.loop_view_size_arg in
      Ok
        (ELoopView
           {
             loop_view_kind = view.loop_view_kind;
             loop_view_source;
             loop_view_size_arg;
             loop_view_elem_type = view.loop_view_elem_type;
           })
  | Ast.EAssign (name, rhs) ->
      let* rhs = typed_child rhs in
      Ok (EAssign (name, rhs))
  | Ast.EVarDecl (name, ty, init, is_mutable) ->
      let* init = typed_child init in
      Ok (EVarDecl (name, ty, init, is_mutable))
  | Ast.ETupleDestruct (names, init) ->
      let* init = typed_child init in
      Ok (ETupleDestruct (names, init))
  | Ast.ERange (low, high) ->
      let* low = typed_child low in
      let* high = typed_child high in
      Ok (ERange (low, high))
  | Ast.EBreak -> Ok EBreak
  | Ast.EContinue -> Ok EContinue
  | Ast.ESubscript (coll, index) ->
      let* coll = typed_child coll in
      let* index = typed_child index in
      Ok (ESubscript (coll, index))
  | Ast.ESubscriptMulti (coll, indices) ->
      let* coll = typed_child coll in
      let* indices = typed_children indices in
      Ok (ESubscriptMulti (coll, indices))
  | Ast.ESubscriptAssign (coll, indices, value) ->
      let* coll = typed_child coll in
      let* indices = typed_children indices in
      let* value = typed_child value in
      Ok (ESubscriptAssign (coll, indices, value))
  | Ast.EStringInterp (parts, is_triple) ->
      let* parts =
        List.fold_right
          (fun part acc ->
            let* rest = acc in
            match part with
            | Ast.InterpLit text -> Ok (InterpLit text :: rest)
            | Ast.InterpExpr expr ->
                let* expr = typed_child expr in
                Ok (InterpExpr expr :: rest))
          parts (Ok [])
      in
      Ok (EStringInterp (parts, is_triple))
  | Ast.EStringInterpRaw (text, is_triple) ->
      Ok (EStringInterpRaw (text, is_triple))
  | Ast.ETry exprs ->
      let* exprs = typed_children exprs in
      Ok (ETry exprs)
  | Ast.ETryBind (name, ty, value) ->
      let* value = typed_child value in
      Ok (ETryBind (name, ty, value))
  | Ast.EDebugBlock exprs ->
      let* exprs = typed_children exprs in
      Ok (EDebugBlock exprs)
  | Ast.EConcurrent (exprs, timeout, max_threads) ->
      let* exprs = typed_children exprs in
      let* timeout = typed_child_opt timeout in
      Ok (EConcurrent (exprs, timeout, max_threads))
  | Ast.EConcurrentBind (name, ty, value) ->
      let* value = typed_child value in
      Ok (EConcurrentBind (name, ty, value))
  | Ast.EConcurrentFor (name, iter, body, timeout, max_threads) ->
      let* iter = typed_child iter in
      let* body = typed_child body in
      let* timeout = typed_child_opt timeout in
      Ok (EConcurrentFor (name, iter, body, timeout, max_threads))
  | Ast.EDetach body ->
      let* body = typed_child body in
      Ok (EDetach body)
  | Ast.EDict pairs ->
      let* pairs =
        List.fold_right
          (fun (key, value) acc ->
            let* rest = acc in
            let* key = typed_child key in
            let* value = typed_child value in
            Ok ((key, value) :: rest))
          pairs (Ok [])
      in
      Ok (EDict pairs)
  | Ast.EBuiltin name -> Ok (EBuiltin name)
  | Ast.EFuncDecl func ->
      let* func = typed_func_decl func in
      Ok (EFuncDecl func)

let of_ast_expr_with_type_info ?(context = "expression type") ?source_ty ?origin
    ?proofs ~semantic_ty ~value_ty ~widening ast =
  let* info =
    make_type_info ?source_ty ?origin ?proofs ~loc:ast.Ast.expr_loc ~context
      ~semantic_ty ~value_ty ~widening ()
  in
  let ast = Ast.with_expr_type_info ast (type_info_to_ast info) in
  let* () = validate_expr_tree ast in
  Ok { ast; info }

let validate_variant (variant : Ast.variant) =
  List.fold_left
    (fun acc ty ->
      let* () = acc in
      ensure_final_type ~loc:variant.variant_loc ~context:"variant field type"
        ty)
    (Ok ()) variant.variant_fields

let validate_record_field (field : Ast.field_decl) =
  ensure_final_type ~loc:field.field_loc ~context:"record field type"
    field.field_type

let invalid_info ~loc ~context message =
  Error (InvalidTypeInfo { loc; context; message })

let make_record_info ?source_record ~loc (record_decl : Ast.record_decl) =
  let source_record = Option.value source_record ~default:record_decl in
  if source_record.record_name <> record_decl.record_name then
    invalid_info ~loc ~context:"record declaration source metadata"
      (Printf.sprintf "source record '%s' does not match canonical record '%s'"
         source_record.record_name record_decl.record_name)
  else
    let rec collect acc (source_fields : Ast.field_decl list)
        (semantic_fields : Ast.field_decl list) =
      match (source_fields, semantic_fields) with
      | [], [] -> Ok { field_infos = List.rev acc }
      | source_field :: source_rest, semantic_field :: semantic_rest
        when source_field.field_name = semantic_field.field_name ->
          let* () =
            ensure_final_type ~loc:source_field.field_loc
              ~context:"record source field type" source_field.field_type
          in
          let* () = validate_record_field semantic_field in
          collect
            ({
               field_name = semantic_field.field_name;
               source_field_ty = source_field.field_type;
               semantic_field_ty = semantic_field.field_type;
             }
            :: acc)
            source_rest semantic_rest
      | source_field :: _, semantic_field :: _ ->
          invalid_info ~loc ~context:"record declaration source metadata"
            (Printf.sprintf
               "source field '%s' does not match canonical field '%s'"
               source_field.field_name semantic_field.field_name)
      | [], _ :: _ | _ :: _, [] ->
          invalid_info ~loc ~context:"record declaration source metadata"
            "source and canonical record field counts differ"
    in
    collect [] source_record.record_fields record_decl.record_fields

let make_type_alias_info ?source_alias ~loc (alias : Ast.type_alias_decl) =
  let source_alias = Option.value source_alias ~default:alias in
  if source_alias.alias_name <> alias.alias_name then
    invalid_info ~loc ~context:"type alias source metadata"
      (Printf.sprintf "source alias '%s' does not match canonical alias '%s'"
         source_alias.alias_name alias.alias_name)
  else
    let* () =
      ensure_final_type ~loc ~context:"type alias source target"
        source_alias.alias_target
    in
    let* () =
      ensure_final_type ~loc ~context:"type alias target" alias.alias_target
    in
    Ok
      {
        source_target_ty = source_alias.alias_target;
        semantic_target_ty = alias.alias_target;
      }

let validate_trait_method (method_ : Ast.trait_method) =
  let* () = validate_params method_.method_params in
  ensure_optional_type ~loc:Ast.dummy_loc ~context:"trait method return type"
    method_.method_return_type

let source_record_decl ~loc = function
  | None -> Ok None
  | Some { Ast.decl_desc = Ast.DRecord record; _ } -> Ok (Some record)
  | Some _ ->
      invalid_info ~loc ~context:"record declaration source metadata"
        "source declaration kind does not match canonical record declaration"

let source_type_alias_decl ~loc = function
  | None -> Ok None
  | Some { Ast.decl_desc = Ast.DTypeAlias alias; _ } -> Ok (Some alias)
  | Some _ ->
      invalid_info ~loc ~context:"type alias source metadata"
        "source declaration kind does not match canonical type alias \
         declaration"

let source_func_decl ~loc = function
  | None -> Ok None
  | Some { Ast.decl_desc = Ast.DFunc func; _ } -> Ok (Some func)
  | Some _ ->
      invalid_info ~loc ~context:"function declaration source metadata"
        "source declaration kind does not match canonical function declaration"

let source_var_decl ~loc = function
  | None -> Ok None
  | Some { Ast.decl_desc = Ast.DVar var; _ } -> Ok (Some var)
  | Some _ ->
      invalid_info ~loc ~context:"variable declaration source metadata"
        "source declaration kind does not match canonical variable declaration"

let source_private_decl = function
  | Some { Ast.decl_desc = Ast.DPrivate inner; _ } -> Some inner
  | _ -> None

let rec of_ast_decl_with_source ?source_decl ast_decl =
  let* decl_info =
    match ast_decl.Ast.decl_desc with
    | Ast.DFunc func ->
        let* source_func =
          source_func_decl ~loc:ast_decl.decl_loc source_decl
        in
        let* typed_func = of_ast_func_decl_with_source ?source_func func in
        Ok (FunctionDecl typed_func)
    | Ast.DVar var ->
        let* source_var = source_var_decl ~loc:ast_decl.decl_loc source_decl in
        let* typed_var = of_ast_var_decl_with_source ?source_var var in
        Ok (VarDecl typed_var)
    | Ast.DImpl impl ->
        let* () =
          ensure_final_type ~loc:ast_decl.decl_loc ~context:"impl target type"
            impl.impl_for_type
        in
        let* typed_methods = typed_funcs impl.impl_methods in
        Ok (ImplDecl { ast_impl = impl; typed_methods })
    | Ast.DTrait trait ->
        let* () = validate_trait_methods trait.trait_methods in
        Ok NonFunctionDecl
    | Ast.DType type_decl ->
        let* () = validate_variants type_decl.type_variants in
        Ok NonFunctionDecl
    | Ast.DRecord record_decl ->
        let* source_record =
          source_record_decl ~loc:ast_decl.decl_loc source_decl
        in
        let* () = validate_record_fields record_decl.record_fields in
        let* info =
          make_record_info ?source_record ~loc:ast_decl.decl_loc record_decl
        in
        Ok (RecordDecl { ast_record = record_decl; info })
    | Ast.DTypeAlias alias ->
        let* source_alias =
          source_type_alias_decl ~loc:ast_decl.decl_loc source_decl
        in
        let* info =
          make_type_alias_info ?source_alias ~loc:ast_decl.decl_loc alias
        in
        Ok (TypeAliasDecl { ast_alias = alias; info })
    | Ast.DPrivate inner ->
        let* typed_inner =
          of_ast_decl_with_source
            ?source_decl:(source_private_decl source_decl)
            inner
        in
        Ok (PrivateDecl typed_inner)
    | Ast.DImport _ -> Ok NonFunctionDecl
  in
  Ok { ast_decl; decl_info }

and typed_funcs = function
  | [] -> Ok []
  | func :: rest ->
      let* typed_func = of_ast_func_decl_with_source func in
      let* typed_rest = typed_funcs rest in
      Ok (typed_func :: typed_rest)

and validate_trait_methods = function
  | [] -> Ok ()
  | method_ :: rest ->
      let* () = validate_trait_method method_ in
      validate_trait_methods rest

and validate_variants = function
  | [] -> Ok ()
  | variant :: rest ->
      let* () = validate_variant variant in
      validate_variants rest

and validate_record_fields = function
  | [] -> Ok ()
  | field :: rest ->
      let* () = validate_record_field field in
      validate_record_fields rest

let of_ast_var_decl ast_var = of_ast_var_decl_with_source ast_var
let of_ast_func_decl ast_func = of_ast_func_decl_with_source ast_func
let of_ast_decl ast_decl = of_ast_decl_with_source ast_decl

let of_ast_program ast_program =
  let rec validate_decls acc = function
    | [] -> Ok { ast_program; typed_decls = List.rev acc }
    | decl :: rest ->
        let* typed_decl = of_ast_decl decl in
        validate_decls (typed_decl :: acc) rest
  in
  validate_decls [] ast_program

let of_ast_program_with_sources ~source_program ast_program =
  let rec validate_decls acc source_decls canonical_decls =
    match (source_decls, canonical_decls) with
    | [], [] -> Ok { ast_program; typed_decls = List.rev acc }
    | source_decl :: source_rest, canonical_decl :: canonical_rest ->
        let* typed_decl = of_ast_decl_with_source ~source_decl canonical_decl in
        validate_decls (typed_decl :: acc) source_rest canonical_rest
    | [], canonical_decl :: _ ->
        invalid_info ~loc:canonical_decl.decl_loc
          ~context:"typed program source metadata"
          "source program has fewer declarations than canonical program"
    | source_decl :: _, [] ->
        invalid_info ~loc:source_decl.decl_loc
          ~context:"typed program source metadata"
          "source program has more declarations than canonical program"
  in
  validate_decls [] source_program ast_program
