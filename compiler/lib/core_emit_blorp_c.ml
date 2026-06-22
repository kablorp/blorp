(** Blorp-owned C backend boundary for the supported final-Core subset.

    This module is deliberately narrow: OCaml projects a supported final-Core
    subset to JSON, then Blorp owns the actual C emission through the
    [emit_c] bridge action. Unsupported Core shapes are rejected before the
    bridge call so the subset boundary remains explicit. *)

type unsupported = { path : string; reason : string }

module IntSet = Set.Make (Int)
module StringSet = Set.Make (String)

let ( let* ) result f =
  match result with Ok value -> f value | Error _ as error -> error

let unsupported path reason = Error { path; reason }

let unsupported_to_string error =
  Printf.sprintf "unsupported Blorp C backend Core subset at %s: %s" error.path
    error.reason

let obj fields = Lsp_json.Object fields
let arr values = Lsp_json.Array values
let str value = Lsp_json.String value
let int value = Lsp_json.Int value
let bool value = Lsp_json.Bool value
let null = Lsp_json.Null
let kind tag fields = obj (("kind", str tag) :: fields)
let option_int_json = function Some value -> int value | None -> null
let option_string_json = function Some value -> str value | None -> null
let string_list_json values = arr (List.map str values)

let result_list values f =
  let rec collect acc index = function
    | [] -> Ok (arr (List.rev acc))
    | value :: rest -> (
        match f index value with
        | Ok json -> collect (json :: acc) (index + 1) rest
        | Error _ as error -> error)
  in
  collect [] 0 values

let source_loc_json (loc : Ast.loc) =
  match loc.loc_file with
  | Some file ->
      kind "known"
        [
          ("file", str file);
          ("line", int loc.line);
          ("column", int loc.column);
          ("end_line", int loc.end_line);
          ("end_column", int loc.end_column);
        ]
  | None -> kind "synthetic" []

let var_json (variable : Core.var) =
  obj
    [
      ("name", str (Core.Var.to_c_name variable));
      ("uniq", int variable.vuniq);
      ("def_id", option_int_json variable.vdef_id);
    ]

let rec type_json path (ty : Ast.type_expr) =
  match ty with
  | Ast.TyNamed ("Void", []) -> Ok (kind "void" [])
  | Ast.TyNamed (name, args) ->
      let* arg_values =
        result_list args (fun index arg ->
            type_json (Printf.sprintf "%s.args[%d]" path index) arg)
      in
      Ok (kind "named" [ ("name", str name); ("args", arg_values) ])
  | Ast.TyConstInt _ ->
      Ok (kind "named" [ ("name", str "Int"); ("args", arr []) ])
  | Ast.TyTuple items ->
      let* item_values =
        result_list items (fun index item ->
            type_json (Printf.sprintf "%s.items[%d]" path index) item)
      in
      Ok (kind "tuple" [ ("items", item_values) ])
  | Ast.TyArray _ -> unsupported path "array/tensor type"
  | Ast.TyFunc _ ->
      Ok (kind "named" [ ("name", str "Closure"); ("args", arr []) ])
  | Ast.TyVar name -> unsupported path ("type variable " ^ name)
  | Ast.TyBoundVar param ->
      unsupported path ("bound type variable " ^ param.param_name)
  | Ast.TySelf -> unsupported path "Self type"
  | Ast.TyVarDims name -> unsupported path ("variadic dimension " ^ name)
  | Ast.TyRange _ -> unsupported path "range type"
  | Ast.TyDimOp _ -> unsupported path "dimension operation"
  | Ast.TyMeta id ->
      unsupported path ("unresolved type meta " ^ string_of_int id)

let int64_to_json_int path value =
  let as_int = Int64.to_int value in
  if Int64.equal (Int64.of_int as_int) value then Ok as_int
  else unsupported path "integer literal out of Blorp bridge Int range"

let literal_json path (literal : Ast.literal) =
  match literal with
  | Ast.LitInt value ->
      let* n = int64_to_json_int path value in
      Ok (kind "int" [ ("value", int n) ])
  | Ast.LitBool value -> Ok (kind "bool" [ ("value", bool value) ])
  | Ast.LitString (value, _) -> Ok (kind "string" [ ("value", str value) ])
  | Ast.LitInt128 _ -> unsupported path "Int128 literal"
  | Ast.LitFloat _ -> unsupported path "Float literal"
  | Ast.LitChar _ -> unsupported path "Char literal"

let call_kind_json path (call_kind : Core.call_kind) =
  match call_kind with
  | Core.CKUser (name, def_id) ->
      Ok
        (kind "user" [ ("name", str name); ("def_id", option_int_json def_id) ])
  | Core.CKForeign _ -> unsupported path "foreign call"
  | Core.CKBuiltin name -> unsupported path ("builtin call " ^ name)
  | Core.CKIntrinsic name -> unsupported path ("intrinsic call " ^ name)
  | Core.CKClosure -> unsupported path "closure call"
  | Core.CKUnknown -> unsupported path "unresolved call kind"
  | Core.CKSelectedDirect _ -> unsupported path "selected direct call kind"

let binop_tag = function
  | Ast.Add -> Ok "add"
  | Ast.Sub -> Ok "subtract"
  | Ast.Mul -> Ok "multiply"
  | Ast.Div -> Ok "divide"
  | Ast.Eq -> Ok "equal"
  | Ast.Ne -> Ok "not_equal"
  | Ast.Lt -> Ok "less"
  | Ast.Le -> Ok "less_equal"
  | Ast.Gt -> Ok "greater"
  | Ast.Ge -> Ok "greater_equal"
  | Ast.Mod -> Ok "modulo"

let unop_tag = function Ast.Neg -> "negate" | Ast.Not -> "not"
let logop_tag = function Ast.And -> "and" | Ast.Or -> "or"

let rec expr_json path (expr : Core.core) =
  let loc = source_loc_json expr.loc in
  let typed fields =
    let* typ = type_json (path ^ ".type") expr.ty in
    Ok (fields @ [ ("type", typ); ("loc", loc) ])
  in
  match expr.desc with
  | Core.CLit literal ->
      let* literal_value = literal_json (path ^ ".literal") literal in
      let* fields = typed [ ("literal", literal_value) ] in
      Ok (kind "literal" fields)
  | Core.CVar variable ->
      let* fields = typed [ ("var", var_json variable) ] in
      Ok (kind "var" fields)
  | Core.CVoid ->
      let* fields = typed [] in
      Ok (kind "void" fields)
  | Core.CCooperativeCheckpoint ->
      let* fields = typed [] in
      Ok (kind "cooperative_checkpoint" fields)
  | Core.CCall (call_kind, callee, args) ->
      let* call_kind_value = call_kind_json (path ^ ".call_kind") call_kind in
      let* callee_value = expr_json (path ^ ".callee") callee in
      let* args_value =
        result_list args (fun index arg ->
            expr_json (Printf.sprintf "%s.args[%d]" path index) arg)
      in
      let* fields =
        typed
          [
            ("call_kind", call_kind_value);
            ("callee", callee_value);
            ("args", args_value);
          ]
      in
      Ok (kind "call" fields)
  | Core.CBin (op, left, right) -> (
      match binop_tag op with
      | Error reason -> unsupported path reason
      | Ok op_tag ->
          let* left_value = expr_json (path ^ ".left") left in
          let* right_value = expr_json (path ^ ".right") right in
          let* fields =
            typed
              [
                ("op", str op_tag); ("left", left_value); ("right", right_value);
              ]
          in
          Ok (kind "binary" fields))
  | Core.CUn (op, inner) ->
      let* inner_value = expr_json (path ^ ".expr") inner in
      let* fields =
        typed [ ("op", str (unop_tag op)); ("expr", inner_value) ]
      in
      Ok (kind "unary" fields)
  | Core.CLog (op, left, right) ->
      let* left_value = expr_json (path ^ ".left") left in
      let* right_value = expr_json (path ^ ".right") right in
      let* fields =
        typed
          [
            ("op", str (logop_tag op));
            ("left", left_value);
            ("right", right_value);
          ]
      in
      Ok (kind "logical" fields)
  | Core.CAssign (variable, rhs) ->
      let* rhs_value = expr_json (path ^ ".rhs") rhs in
      let* fields = typed [ ("var", var_json variable); ("rhs", rhs_value) ] in
      Ok (kind "assign" fields)
  | Core.CCast (inner, target_ty) ->
      let* inner_value = expr_json (path ^ ".expr") inner in
      let* target_type = type_json (path ^ ".target_type") target_ty in
      let* fields =
        typed [ ("expr", inner_value); ("target_type", target_type) ]
      in
      Ok (kind "cast" fields)
  | Core.CLet (binding, body) ->
      let* typ = type_json (path ^ ".type") binding.bind_ty in
      let* rhs = expr_json (path ^ ".rhs") binding.bind_rhs in
      let* body = expr_json (path ^ ".body") body in
      Ok
        (kind "let"
           [
             ("name", var_json binding.bind_var);
             ("mutable", bool binding.bind_mut);
             ("type", typ);
             ("rhs", rhs);
             ("body", body);
           ])
  | Core.CSeq (first, second) ->
      let* first_value = expr_json (path ^ ".first") first in
      let* second_value = expr_json (path ^ ".second") second in
      Ok (kind "seq" [ ("first", first_value); ("second", second_value) ])
  | Core.CIf (cond, then_expr, else_expr) ->
      let* cond_value = expr_json (path ^ ".cond") cond in
      let* then_value = expr_json (path ^ ".then") then_expr in
      let* else_value = expr_json (path ^ ".else") else_expr in
      let* fields =
        typed
          [ ("cond", cond_value); ("then", then_value); ("else", else_value) ]
      in
      Ok (kind "if" fields)
  | Core.CWhile (cond, body) ->
      let* cond_value = expr_json (path ^ ".cond") cond in
      let* body_value = expr_json (path ^ ".body") body in
      let* fields = typed [ ("cond", cond_value); ("body", body_value) ] in
      Ok (kind "while" fields)
  | Core.CBreak ->
      let* fields = typed [] in
      Ok (kind "break" fields)
  | Core.CContinue ->
      let* fields = typed [] in
      Ok (kind "continue" fields)
  | Core.CTuple _ -> unsupported path "tuple expression"
  | Core.CList _ -> unsupported path "list literal"
  | Core.CListAlloc _ -> unsupported path "list allocation"
  | Core.CListGet _ -> unsupported path "list get"
  | Core.CStringByteRead _ -> unsupported path "string byte read"
  | Core.CStringByteWrite _ -> unsupported path "string byte write"
  | Core.CStringByteCopy _ -> unsupported path "string byte copy"
  | Core.CStringSetLen _ -> unsupported path "string length update"
  | Core.CTupleConstruct _ -> unsupported path "tuple construction"
  | Core.CListConstruct _ -> unsupported path "list construction"
  | Core.CVector _ -> unsupported path "vector literal"
  | Core.CTensorLiteral _ -> unsupported path "tensor literal"
  | Core.CDict _ -> unsupported path "dict literal"
  | Core.CDictConstruct _ -> unsupported path "dict construction"
  | Core.CSetAlloc _ -> unsupported path "set allocation"
  | Core.CRecord _ -> unsupported path "record literal"
  | Core.CRecordConstruct _ -> unsupported path "record construction"
  | Core.CRecordUpdate _ -> unsupported path "record update"
  | Core.CRange _ -> unsupported path "range expression"
  | Core.CLambda _ -> unsupported path "lambda"
  | Core.CClosureCreate _ -> unsupported path "closure creation"
  | Core.CTensorRawRead _ -> unsupported path "tensor raw read"
  | Core.CTensorRawWrite _ -> unsupported path "tensor raw write"
  | Core.CField _ -> unsupported path "field access"
  | Core.CStringInterp _ -> unsupported path "string interpolation"
  | Core.CBorrowLet _ -> unsupported path "borrow let"
  | Core.CTensorRawViewLet _ -> unsupported path "tensor raw view"
  | Core.CResourceScope _ -> unsupported path "resource scope"
  | Core.CResourceCleanupExit _ -> unsupported path "resource cleanup exit"
  | Core.CDebugBlock _ -> unsupported path "debug block"
  | Core.CMatchArms _ -> unsupported path "match arms"
  | Core.CMatch _ -> unsupported path "compiled match"
  | Core.CFor _ -> unsupported path "for loop"
  | Core.CTailrecLoop _ -> unsupported path "tail-recursive loop"
  | Core.CTailrecRecur _ -> unsupported path "tail-recursive recur"
  | Core.CDup _ -> unsupported path "retain"
  | Core.CDrop _ -> unsupported path "release"
  | Core.CConcurrent _ -> unsupported path "concurrent block"
  | Core.CConcurrentlyLoop _ -> unsupported path "concurrently loop"
  | Core.CDetach _ -> unsupported path "detach"
  | Core.CSelect _ -> unsupported path "select"
  | Core.CBox _ -> unsupported path "box"
  | Core.CUnbox _ -> unsupported path "unbox"
  | Core.CUnionConstruct _ -> unsupported path "union construction"
  | Core.CUnionReuseConstruct _ -> unsupported path "union reuse construction"
  | Core.CListHandoff _ -> unsupported path "list handoff"
  | Core.CBoxTyped _ -> unsupported path "typed box"
  | Core.CUnboxTyped _ -> unsupported path "typed unbox"

let param_json path (param : Core.core_param) =
  let* typ = type_json (path ^ ".type") param.cp_ty in
  Ok
    (obj
       [
         ("name", var_json param.cp_name);
         ("type", typ);
         ("loc", source_loc_json param.cp_loc);
       ])

let function_kind = function
  | Core.CFUser -> "user"
  | Core.CFBuiltin -> "builtin"
  | Core.CFForeign _ -> "foreign"
  | Core.CFClosureBody _ -> "closure_body"

let var_is_global global_def_ids global_names (variable : Core.var) =
  match variable.vdef_id with
  | Some def_id when IntSet.mem def_id global_def_ids -> true
  | Some _ | None -> StringSet.mem (Core.Var.to_c_name variable) global_names

let expr_uses_global global_def_ids global_names (expr : Core.core) =
  Core.exists_tree
    (fun node ->
      match node.desc with
      | Core.CVar variable -> var_is_global global_def_ids global_names variable
      | _ -> false)
    expr

let is_void_type = function Ast.TyNamed ("Void", []) -> true | _ -> false

let require_user_call_kind path = function
  | Core.CKUser _ -> Ok ()
  | Core.CKForeign _ -> unsupported path "foreign call"
  | Core.CKBuiltin name -> unsupported path ("builtin call " ^ name)
  | Core.CKIntrinsic name -> unsupported path ("intrinsic call " ^ name)
  | Core.CKClosure -> unsupported path "closure call"
  | Core.CKUnknown -> unsupported path "unresolved call kind"
  | Core.CKSelectedDirect _ -> unsupported path "selected direct call kind"

let rec require_simple_expr path (expr : Core.core) =
  match expr.desc with
  | Core.CLit (Ast.LitInt _ | Ast.LitBool _ | Ast.LitString _) -> Ok ()
  | Core.CLit literal ->
      literal_json (path ^ ".literal") literal |> Result.map ignore
  | Core.CVar _ | Core.CVoid -> Ok ()
  | Core.CCall (call_kind, _callee, args) ->
      let* () = require_user_call_kind (path ^ ".call_kind") call_kind in
      require_simple_args path args
  | Core.CBin (_op, left, right) ->
      let* () = require_simple_expr (path ^ ".left") left in
      require_simple_expr (path ^ ".right") right
  | Core.CUn (_op, inner) -> require_simple_expr (path ^ ".expr") inner
  | Core.CLog (_op, left, right) ->
      let* () = require_simple_expr (path ^ ".left") left in
      require_simple_expr (path ^ ".right") right
  | Core.CCast (inner, _target_ty) -> require_simple_expr (path ^ ".expr") inner
  | Core.CIf (cond, then_expr, else_expr) ->
      let* () = require_simple_expr (path ^ ".cond") cond in
      let* () = require_simple_expr (path ^ ".then") then_expr in
      require_simple_expr (path ^ ".else") else_expr
  | Core.CAssign _ | Core.CLet _ | Core.CSeq _ | Core.CWhile _
  | Core.CCooperativeCheckpoint | Core.CBreak | Core.CContinue ->
      unsupported path "statement-shaped expression"
  | _ -> unsupported path "unsupported simple expression"

and require_simple_args path args =
  let rec check index = function
    | [] -> Ok ()
    | arg :: rest ->
        let* () =
          require_simple_expr (Printf.sprintf "%s.args[%d]" path index) arg
        in
        check (index + 1) rest
  in
  check 0 args

let rec require_function_body path (expr : Core.core) =
  match expr.desc with
  | Core.CLet (binding, body) ->
      if is_void_type binding.bind_ty then
        let* () = require_function_body (path ^ ".rhs") binding.bind_rhs in
        require_function_body (path ^ ".body") body
      else if String.equal (Core.Var.to_c_name binding.bind_var) "_" then
        let* () = require_function_body (path ^ ".rhs") binding.bind_rhs in
        require_function_body (path ^ ".body") body
      else
        let* () = require_simple_expr (path ^ ".rhs") binding.bind_rhs in
        require_function_body (path ^ ".body") body
  | Core.CAssign (_variable, rhs) -> require_function_body (path ^ ".rhs") rhs
  | Core.CSeq (first, second) ->
      let* () = require_function_body (path ^ ".first") first in
      require_function_body (path ^ ".second") second
  | Core.CIf (cond, then_expr, else_expr) -> (
      match require_simple_expr path expr with
      | Ok () -> Ok ()
      | Error _ ->
          let* () = require_simple_expr (path ^ ".cond") cond in
          let* () = require_function_body (path ^ ".then") then_expr in
          require_function_body (path ^ ".else") else_expr)
  | Core.CWhile (cond, body) ->
      let* () = require_simple_expr (path ^ ".cond") cond in
      require_function_body (path ^ ".body") body
  | Core.CCooperativeCheckpoint -> Ok ()
  | Core.CBreak | Core.CContinue -> Ok ()
  | _ -> require_simple_expr path expr

let function_json ~global_def_ids ~global_names path loc (func : Core.core_func)
    =
  let* params =
    result_list func.cf_params (fun index param ->
        param_json (Printf.sprintf "%s.params[%d]" path index) param)
  in
  let* return_type = type_json (path ^ ".return_type") func.cf_return_ty in
  let* body =
    match func.cf_body with
    | Some body ->
        if expr_uses_global global_def_ids global_names body then
          unsupported (path ^ ".body") "global variable reference"
        else
          let* () = require_function_body (path ^ ".body") body in
          expr_json (path ^ ".body") body
    | None -> Ok null
  in
  Ok
    (kind "function"
       [
         ("name", str func.cf_name);
         ("module", option_string_json func.cf_module);
         ( "type_params",
           string_list_json
             (List.map
                (fun (param : Ast.type_param_decl) -> param.param_name)
                func.cf_type_params) );
         ("params", params);
         ("return_type", return_type);
         ("body", body);
         ("pure", bool func.cf_is_pure);
         ("function_kind", str (function_kind func.cf_kind));
         ("def_id", int func.cf_def_id);
         ("loc", source_loc_json loc);
       ])

let rec decl_json global_def_ids global_names index (decl : Core.core_decl) =
  let path = Printf.sprintf "program.decls[%d]" index in
  match decl.cd_desc with
  | Core.CDFunc func when func.cf_body = None || func.cf_type_params <> [] ->
      Ok None
  | Core.CDFunc func ->
      let* json =
        function_json ~global_def_ids ~global_names path decl.cd_loc func
      in
      Ok (Some json)
  | Core.CDImport _ | Core.CDTrait _ | Core.CDType _ | Core.CDTypeAlias _
  | Core.CDRecord _ ->
      Ok None
  | Core.CDPrivate inner -> decl_json global_def_ids global_names index inner
  | Core.CDVar global -> (
      match global.cv_module with
      | Some _ -> Ok None
      | None -> unsupported path "global variable declaration")
  | Core.CDImpl _ -> unsupported path "impl declaration"

let program_json (program : Core.core_program) =
  let rec collect_global_def_ids ids (decl : Core.core_decl) =
    match decl.cd_desc with
    | Core.CDVar global -> IntSet.add global.cv_def_id ids
    | Core.CDPrivate inner -> collect_global_def_ids ids inner
    | _ -> ids
  in
  let rec collect_global_names names (decl : Core.core_decl) =
    match decl.cd_desc with
    | Core.CDVar global ->
        StringSet.add (Core.Var.to_c_name global.cv_name) names
    | Core.CDPrivate inner -> collect_global_names names inner
    | _ -> names
  in
  let global_def_ids =
    List.fold_left collect_global_def_ids IntSet.empty program
  in
  let global_names =
    List.fold_left collect_global_names StringSet.empty program
  in
  let rec collect acc index = function
    | [] -> Ok (arr (List.rev acc))
    | decl :: rest -> (
        match decl_json global_def_ids global_names index decl with
        | Ok (Some json) -> collect (json :: acc) (index + 1) rest
        | Ok None -> collect acc (index + 1) rest
        | Error _ as error -> error)
  in
  let* decls = collect [] 0 program in
  Ok (kind "program" [ ("decls", decls) ])

type config = { embed_runtime : bool; profile : bool }
type ctx = { output : Buffer.t; config : config }

let default_config = { embed_runtime = false; profile = false }

let config_with_embed ~embed_runtime ?(profile = false) () =
  { embed_runtime; profile }

let with_embedded_runtime (artifact : Compiler_blorp_bridge.c_artifact) =
  {
    artifact with
    Compiler_blorp_bridge.c_code =
      Runtime.runtime_code ^ "\n" ^ artifact.Compiler_blorp_bridge.c_code;
  }

let emit_program_to_artifact (config : config) (program : Core.core_program) =
  if config.profile then unsupported "config.profile" "profile emission"
  else
    let* core_json = program_json program in
    let artifact = Compiler_blorp_bridge.emit_c_artifact_exn core_json in
    Ok
      (if config.embed_runtime then with_embedded_runtime artifact else artifact)

let emit_program_string config program =
  match emit_program_to_artifact config program with
  | Ok artifact -> Ok artifact.Compiler_blorp_bridge.c_code
  | Error _ as error -> error

let try_emit_program_string config program =
  match emit_program_string config program with
  | Ok _ as ok -> ok
  | Error error -> Error (unsupported_to_string error)

module Backend : sig
  include Backend.S with type config = config

  val config_with_embed : embed_runtime:bool -> ?profile:bool -> unit -> config
end = struct
  type nonrec ctx = ctx
  type nonrec config = config

  let default_config = default_config
  let create_ctx ~reg:_ config = { output = Buffer.create 4096; config }

  let emit_program ctx program =
    match emit_program_string ctx.config program with
    | Ok c_code -> Buffer.add_string ctx.output c_code
    | Error error -> invalid_arg (unsupported_to_string error)

  let finalize ctx = Buffer.contents ctx.output
  let config_with_embed = config_with_embed
end
