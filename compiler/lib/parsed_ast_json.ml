(** Decoder for the Blorp-owned parsed-AST JSON bridge format.

    The Blorp frontend emits a stable, tagged JSON tree. This module is the
    OCaml side of that same bridge: it converts that tree into the legacy
    [Ast.program] shape consumed by module loading, inference, and Core
    lowering while those later phases remain OCaml-owned. *)

type decode_error = {
  path : string;
  message : string;
  loc : Ast.loc option;
}

type parsed_diagnostic_severity =
  | ParsedDiagnosticError
  | ParsedDiagnosticWarning

type parsed_diagnostic = {
  parsed_diagnostic_severity : parsed_diagnostic_severity;
  parsed_diagnostic_span : Ast.loc;
  parsed_diagnostic_message : string;
  parsed_diagnostic_expected : string list;
  parsed_diagnostic_help : string option;
}

type concurrent_block_params = {
  concurrent_timeout : Ast.expr option;
  concurrent_max_threads : int option;
}

type concurrently_loop_params = {
  loop_timeout : Ast.expr option;
  loop_limit : int;
}

type decoded_for_binder =
  | DecodedForNameBinder of string
  | DecodedForTupleBinder of string list

type decoded_param_binder =
  | DecodedParamNameBinder of string
  | DecodedParamWildcardBinder
  | DecodedParamTupleBinder of string list

let decode_error_to_string err = err.path ^ ": " ^ err.message
let error path message = Error { path; message; loc = None }
let source_error path loc message = Error { path; message; loc = Some loc }
let ( let* ) = Result.bind

let field path name = function
  | Lsp_json.Object fields -> (
      match List.assoc_opt name fields with
      | Some value -> Ok value
      | None -> error path ("missing field `" ^ name ^ "`"))
  | _ -> error path "expected object"

let kind_field path value =
  let* value = field path "kind" value in
  match value with
  | Lsp_json.String kind -> Ok kind
  | _ -> error (path ^ ".kind") "expected string"

let string_value path = function
  | Lsp_json.String value -> Ok value
  | _ -> error path "expected string"

let bool_value path = function
  | Lsp_json.Bool value -> Ok value
  | _ -> error path "expected bool"

let int_value path = function
  | Lsp_json.Int value -> Ok value
  | Lsp_json.Float value ->
      if not (Float.is_finite value) then error path "expected finite integer"
      else if
        value < float_of_int min_int || value > float_of_int max_int
      then error path "integer is outside host int range"
      else
        let truncated = int_of_float value in
        if Float.equal value (float_of_int truncated) then Ok truncated
        else error path "expected exact integer"
  | _ -> error path "expected integer"

let string_field path name value =
  let* value = field path name value in
  string_value (path ^ "." ^ name) value

let bool_field path name value =
  let* value = field path name value in
  bool_value (path ^ "." ^ name) value

let optional_field name = function
  | Lsp_json.Object fields -> Ok (List.assoc_opt name fields)
  | _ -> error name "expected object"

let int_field path name value =
  let* value = field path name value in
  int_value (path ^ "." ^ name) value

let option_string_field path name value =
  let* value = field path name value in
  match value with
  | Lsp_json.Null -> Ok None
  | Lsp_json.String text -> Ok (Some text)
  | _ -> error (path ^ "." ^ name) "expected string or null"

let array_value path = function
  | Lsp_json.Array values -> Ok values
  | _ -> error path "expected array"

let array_field path name value =
  let* value = field path name value in
  array_value (path ^ "." ^ name) value

let option_string_value path = function
  | Lsp_json.Null -> Ok None
  | Lsp_json.String text -> Ok (Some text)
  | _ -> error path "expected string or null"

let decode_list path decode values =
  let rec loop index acc = function
    | [] -> Ok (List.rev acc)
    | value :: rest ->
        let* decoded = decode (Printf.sprintf "%s[%d]" path index) value in
        loop (index + 1) (decoded :: acc) rest
  in
  loop 0 [] values

let decode_identifier path value =
  let* text = string_field path "text" value in
  Ok text

let decode_string_list path value =
  let* values = array_value path value in
  decode_list path string_value values

let option_identifier_field path name value =
  let* value = field path name value in
  match value with
  | Lsp_json.Null -> Ok None
  | _ ->
      let* name = decode_identifier (path ^ "." ^ name) value in
      Ok (Some name)

let decode_span path value : (Ast.loc, decode_error) result =
  let* source_path = string_field path "path" value in
  let* line = int_field path "start_line" value in
  let* column = int_field path "start_column" value in
  let* end_line = int_field path "end_line" value in
  let* end_column = int_field path "end_column" value in
  Ok
    {
      Ast.line;
      column;
      end_line;
      end_column;
      loc_file = Some source_path;
    }

let span_field path name value =
  let* value = field path name value in
  decode_span (path ^ "." ^ name) value

let decode_parsed_diagnostic_severity path = function
  | "error" -> Ok ParsedDiagnosticError
  | "warning" -> Ok ParsedDiagnosticWarning
  | severity -> error path ("unsupported diagnostic severity `" ^ severity ^ "`")

let decode_parsed_diagnostic path value =
  let* severity_text = string_field path "severity" value in
  let* severity =
    decode_parsed_diagnostic_severity (path ^ ".severity") severity_text
  in
  let* span = span_field path "span" value in
  let* message = string_field path "message" value in
  let* expected_json = field path "expected" value in
  let* expected = decode_string_list (path ^ ".expected") expected_json in
  let* help_json = field path "help" value in
  let* help = option_string_value (path ^ ".help") help_json in
  Ok
    {
      parsed_diagnostic_severity = severity;
      parsed_diagnostic_span = span;
      parsed_diagnostic_message = message;
      parsed_diagnostic_expected = expected;
      parsed_diagnostic_help = help;
    }

let decode_dim_op path = function
  | "add" -> Ok Ast.DimAdd
  | "subtract" -> Ok Ast.DimSub
  | "multiply" -> Ok Ast.DimMul
  | "divide" -> Ok Ast.DimDiv
  | op -> error path ("unsupported dimension operator `" ^ op ^ "`")

let rec decode_type_expr path value =
  let* kind = kind_field path value in
  match kind with
  | "named" ->
      let* name_json = field path "name" value in
      let* name = decode_identifier (path ^ ".name") name_json in
      let* args_json = array_field path "args" value in
      let* args = decode_list (path ^ ".args") decode_type_expr args_json in
      if String.equal name "Self" && args = [] then Ok Ast.TySelf
      else Ok (Ast.TyNamed (name, args))
  | "qualified_named" ->
      let* module_json = field path "module" value in
      let* name_json = field path "name" value in
      let* module_name = decode_identifier (path ^ ".module") module_json in
      let* name = decode_identifier (path ^ ".name") name_json in
      let* args_json = array_field path "args" value in
      let* args = decode_list (path ^ ".args") decode_type_expr args_json in
      Ok (Ast.TyNamed (module_name ^ "." ^ name, args))
  | "bounded" ->
      let* name_json = field path "name" value in
      let* name = decode_identifier (path ^ ".name") name_json in
      let* bounds_json = array_field path "bounds" value in
      let* bounds =
        decode_list (path ^ ".bounds") decode_identifier bounds_json
      in
      Ok (Ast.TyBoundVar (Ast.make_type_param name bounds))
  | "dim_name" ->
      let* name_json = field path "name" value in
      let* name = decode_identifier (path ^ ".name") name_json in
      let* is_variadic = bool_field path "is_variadic" value in
      if is_variadic then Ok (Ast.TyVarDims name) else Ok (Ast.TyVar name)
  | "dim_literal" ->
      let* text = string_field path "value" value in
      (match int_of_string_opt text with
      | Some n -> Ok (Ast.TyConstInt n)
      | None -> error (path ^ ".value") "dimension literal must fit in Int")
  | "dim_binary" ->
      let* op_name = string_field path "op" value in
      let* op = decode_dim_op (path ^ ".op") op_name in
      let* left_json = field path "left" value in
      let* right_json = field path "right" value in
      let* left = decode_type_expr (path ^ ".left") left_json in
      let* right = decode_type_expr (path ^ ".right") right_json in
      Ok (Ast.TyDimOp (op, left, right))
  | "range" ->
      let* limit_json = field path "limit" value in
      let* limit = decode_type_expr (path ^ ".limit") limit_json in
      Ok (Ast.TyRange limit)
  | "tuple" ->
      let* items_json = array_field path "items" value in
      let* items = decode_list (path ^ ".items") decode_type_expr items_json in
      Ok (Ast.TyTuple items)
  | "function" ->
      let* is_pure = bool_field path "is_pure" value in
      let* params_json = array_field path "params" value in
      let* params = decode_list (path ^ ".params") decode_type_expr params_json in
      let* return_json = field path "return_type" value in
      let* return = decode_type_expr (path ^ ".return_type") return_json in
      Ok (Ast.TyFunc { params; return; is_pure })
  | "array" ->
      let* element_json = field path "element" value in
      let* dims_json = array_field path "dims" value in
      let* element = decode_type_expr (path ^ ".element") element_json in
      let* dims = decode_list (path ^ ".dims") decode_type_expr dims_json in
      Ok (Ast.TyArray (element, dims))
  | "missing" -> error path "missing type cannot be decoded as a concrete type"
  | kind -> error path ("unsupported parsed type kind `" ^ kind ^ "`")

let decode_optional_type_expr path value =
  match value with
  | Lsp_json.Null -> Ok None
  | _ -> (
      match kind_field path value with
      | Ok "missing" -> Ok None
      | Ok _ ->
          let* decoded = decode_type_expr path value in
          Ok (Some decoded)
      | Error err -> Error err)

let optional_type_expr_field path name value =
  let* value = field path name value in
  decode_optional_type_expr (path ^ "." ^ name) value

let decode_dim_constraint path value =
  let* left_json = field path "left" value in
  let* right_json = field path "right" value in
  let* left = decode_type_expr (path ^ ".left") left_json in
  let* right = decode_type_expr (path ^ ".right") right_json in
  Ok (left, right)

let dim_constraints_field path value =
  match value with
  | Lsp_json.Object fields -> (
      match List.assoc_opt "dim_constraints" fields with
      | None -> Ok []
      | Some json ->
          let* values = array_value (path ^ ".dim_constraints") json in
          decode_list (path ^ ".dim_constraints") decode_dim_constraint values)
  | _ -> error path "expected object"

let decode_binop path = function
  | "add" -> Ok Ast.Add
  | "subtract" -> Ok Ast.Sub
  | "multiply" -> Ok Ast.Mul
  | "divide" -> Ok Ast.Div
  | "modulo" -> Ok Ast.Mod
  | "equal" -> Ok Ast.Eq
  | "not_equal" -> Ok Ast.Ne
  | "less" -> Ok Ast.Lt
  | "less_equal" -> Ok Ast.Le
  | "greater" -> Ok Ast.Gt
  | "greater_equal" -> Ok Ast.Ge
  | op -> error path ("unsupported binary operator `" ^ op ^ "`")

let decode_logop path = function
  | "and" -> Ok Ast.And
  | "or" -> Ok Ast.Or
  | op -> error path ("unsupported logical operator `" ^ op ^ "`")

let decode_unop path = function
  | "negate" -> Ok Ast.Neg
  | "not" -> Ok Ast.Not
  | op -> error path ("unsupported unary operator `" ^ op ^ "`")

let decode_assign_op path = function
  | "add" -> Ok Ast.AssignAdd
  | "subtract" -> Ok Ast.AssignSub
  | "multiply" -> Ok Ast.AssignMul
  | "divide" -> Ok Ast.AssignDiv
  | op -> error path ("unsupported compound assignment operator `" ^ op ^ "`")

let int_literal_of_text text =
  match Int64.of_string_opt text with
  | Some value -> Ast.LitInt value
  | None -> Ast.LitInt128 text

let expr loc desc = Ast.untyped_expr ~loc desc

let decode_string_flags path value =
  let* form = optional_field "form" value in
  match form with
  | None -> Ok { Ast.sf_multiline = false; sf_raw = false }
  | Some (Lsp_json.String "plain") ->
      Ok { Ast.sf_multiline = false; sf_raw = false }
  | Some (Lsp_json.String "raw") ->
      Ok { Ast.sf_multiline = false; sf_raw = true }
  | Some (Lsp_json.String "pipe") ->
      Ok { Ast.sf_multiline = true; sf_raw = false }
  | Some (Lsp_json.String "raw_pipe") ->
      Ok { Ast.sf_multiline = true; sf_raw = true }
  | Some (Lsp_json.String other) ->
      error (path ^ ".form") ("unsupported string literal form `" ^ other ^ "`")
  | Some _ -> error (path ^ ".form") "expected string"

let decode_list_pattern_spread path value =
  let* kind = kind_field path value in
  match kind with
  | "name" ->
      let* name_json = field path "name" value in
      let* name = decode_identifier (path ^ ".name") name_json in
      Ok (Ast.PatVar name)
  | "wildcard" -> Ok Ast.PatWildcard
  | kind -> error path ("unsupported list pattern spread kind `" ^ kind ^ "`")

let option_list_pattern_spread_field path value =
  let* spread_json = field path "spread" value in
  match spread_json with
  | Lsp_json.Null -> Ok None
  | _ ->
      let* spread =
        decode_list_pattern_spread (path ^ ".spread") spread_json
      in
      Ok (Some spread)

let rec decode_pattern path value =
  let* kind = kind_field path value in
  match kind with
  | "wildcard" -> Ok Ast.PatWildcard
  | "name" ->
      let* name_json = field path "name" value in
      let* name = decode_identifier (path ^ ".name") name_json in
      Ok (Ast.PatVar name)
  | "int" ->
      let* text = string_field path "value" value in
      Ok (Ast.PatLiteral (int_literal_of_text text))
  | "float" ->
      let* text = string_field path "value" value in
      (match float_of_string_opt text with
      | Some n -> Ok (Ast.PatLiteral (Ast.LitFloat n))
      | None -> error (path ^ ".value") "float pattern is not parseable")
  | "string" ->
      let* text = string_field path "value" value in
      let* flags = decode_string_flags path value in
      Ok (Ast.PatLiteral (Ast.LitString (text, flags)))
  | "char" ->
      let* codepoint = int_field path "value" value in
      Ok (Ast.PatLiteral (Ast.LitChar codepoint))
  | "bool" ->
      let* value_bool = bool_field path "value" value in
      Ok (Ast.PatLiteral (Ast.LitBool value_bool))
  | "constructor" ->
      let* name_json = field path "name" value in
      let* args_json = array_field path "args" value in
      let* name = decode_identifier (path ^ ".name") name_json in
      let* args = decode_list (path ^ ".args") decode_pattern args_json in
      Ok (Ast.PatConstructor (name, args))
  | "qualified_constructor" ->
      let* module_json = field path "module" value in
      let* name_json = field path "name" value in
      let* args_json = array_field path "args" value in
      let* module_name = decode_identifier (path ^ ".module") module_json in
      let* name = decode_identifier (path ^ ".name") name_json in
      let* args = decode_list (path ^ ".args") decode_pattern args_json in
      Ok (Ast.PatQualified (module_name, name, args))
  | "tuple" ->
      let* items_json = array_field path "items" value in
      let* items = decode_list (path ^ ".items") decode_pattern items_json in
      let item_count = List.length items in
      if item_count < 2 || item_count > 4 then
        error path "tuple pattern must have 2-4 elements"
      else Ok (Ast.PatTuple items)
  | "list" ->
      let* items_json = array_field path "items" value in
      let* items = decode_list (path ^ ".items") decode_pattern items_json in
      let* spread = option_list_pattern_spread_field path value in
      Ok (Ast.PatList (items, spread))
  | "or" ->
      let* patterns_json = array_field path "patterns" value in
      let* patterns =
        decode_list (path ^ ".patterns") decode_pattern patterns_json
      in
      Ok (Ast.PatOr patterns)
  | "missing" -> error path "missing pattern cannot be decoded as AST"
  | kind -> error path ("unsupported parsed pattern kind `" ^ kind ^ "`")

let decode_for_binder path value =
  let* kind = kind_field path value in
  match kind with
  | "name" ->
      let* name_json = field path "name" value in
      let* name = decode_identifier (path ^ ".name") name_json in
      Ok (DecodedForNameBinder name)
  | "tuple" ->
      let* items_json = array_field path "items" value in
      let* items = decode_list (path ^ ".items") decode_identifier items_json in
      let item_count = List.length items in
      if item_count < 2 || item_count > 4 then
        error path "for tuple binder must have 2-4 elements"
      else Ok (DecodedForTupleBinder items)
  | kind -> error path ("unsupported for binder kind `" ^ kind ^ "`")

let decode_param_binder path value =
  let* kind = kind_field path value in
  match kind with
  | "name" ->
      let* name_json = field path "name" value in
      let* name = decode_identifier (path ^ ".name") name_json in
      Ok (DecodedParamNameBinder name)
  | "wildcard" -> Ok DecodedParamWildcardBinder
  | "tuple" ->
      let* items_json = array_field path "items" value in
      let* items = decode_list (path ^ ".items") decode_identifier items_json in
      let item_count = List.length items in
      if item_count < 2 || item_count > 4 then
        error path "tuple parameter binder must have 2-4 names"
      else Ok (DecodedParamTupleBinder items)
  | kind -> error path ("unsupported parameter binder kind `" ^ kind ^ "`")

let ast_param_of_decoded_binder binder ty loc =
  match binder with
  | DecodedParamNameBinder name ->
      {
        Ast.param_name = Some name;
        param_pattern = None;
        param_type = ty;
        param_loc = loc;
      }
  | DecodedParamWildcardBinder ->
      {
        Ast.param_name = None;
        param_pattern = Some Ast.PatWildcard;
        param_type = ty;
        param_loc = loc;
      }
  | DecodedParamTupleBinder names ->
      {
        Ast.param_name = None;
        param_pattern =
          Some (Ast.PatTuple (List.map (fun name -> Ast.PatVar name) names));
        param_type = ty;
        param_loc = loc;
      }

let require_block_items path expr =
  match expr.Ast.expr_desc with
  | Ast.EBlock items -> Ok items
  | _ -> error path "expected block expression"

let positive_int_literal path label expr =
  match expr.Ast.expr_desc with
  | Ast.ELiteral (Ast.LitInt value) ->
      if Int64.compare value 0L <= 0 then
        source_error path expr.expr_loc (label ^ " must be positive")
      else if Int64.compare value (Int64.of_int max_int) > 0 then
        source_error path expr.expr_loc (label ^ " is too large")
      else Ok (Int64.to_int value)
  | _ -> source_error path expr.expr_loc (label ^ " must be an integer literal")

let func_body_of_expr path body =
  let builtin_body loc = function
    | None -> Ok Ast.BuiltinIntrinsic
    | Some name -> (
        match Ast.builtin_body_of_name name with
        | Ok body -> Ok body
        | Error message -> source_error path loc message)
  in
  match body.Ast.expr_desc with
  | Ast.EBuiltin opt ->
      let loc = body.expr_loc in
      let* builtin = builtin_body loc opt in
      Ok (Ast.FuncBuiltinBody (builtin, loc))
  | Ast.EBlock [ ({ expr_desc = Ast.EBuiltin opt; _ } as builtin_expr) ] ->
      let loc = builtin_expr.expr_loc in
      let* builtin = builtin_body loc opt in
      Ok (Ast.FuncBuiltinBody (builtin, loc))
  | _ -> Ok (Ast.FuncBodyExpr body)

let decode_type_param path value =
  let* name_json = field path "name" value in
  let* name = decode_identifier (path ^ ".name") name_json in
  let* bounds_json = array_field path "bounds" value in
  let* bounds =
    decode_list (path ^ ".bounds") decode_identifier bounds_json
  in
  Ok (Ast.make_type_param name bounds)

let decode_param path value =
  let* binder_json = field path "binder" value in
  let* binder = decode_param_binder (path ^ ".binder") binder_json in
  let* ty = optional_type_expr_field path "type" value in
  let* loc = span_field path "span" value in
  Ok (ast_param_of_decoded_binder binder ty loc)

let decode_annotations path value =
  let* values = array_field path "annotations" value in
  decode_list (path ^ ".annotations") string_value values

let known_function_annotations =
  [ "tail_recursive"; "no_copy"; "debug_only"; "resource_result_ordinary" ]

let validate_function_annotations path annotations =
  let rec loop = function
    | [] -> Ok ()
    | annot :: rest ->
        if List.mem annot known_function_annotations then loop rest
        else
          error (path ^ ".annotations")
            ("unknown function annotation `" ^ annot ^ "`")
  in
  loop annotations

let rec decode_function path value =
  let* name_json = field path "name" value in
  let* name = decode_identifier (path ^ ".name") name_json in
  let* type_params_json = array_field path "type_params" value in
  let* type_params =
    decode_list (path ^ ".type_params") decode_type_param type_params_json
  in
  let* params_json = array_field path "params" value in
  let* params = decode_list (path ^ ".params") decode_param params_json in
  let* return_type = optional_type_expr_field path "return_type" value in
  let* dim_constraints = dim_constraints_field path value in
  let* body_json = field path "body" value in
  let* body =
    match body_json with
    | Lsp_json.Null -> Ok Ast.FuncNoBody
    | _ ->
        let* body_expr = decode_expr (path ^ ".body") body_json in
        func_body_of_expr (path ^ ".body") body_expr
  in
  let* is_pure = bool_field path "is_pure" value in
  let* annotations = decode_annotations path value in
  let* () = validate_function_annotations path annotations in
  Ok
    {
      Ast.func_name = Some name;
      func_type_params = type_params;
      func_params = params;
      func_return_type = return_type;
      func_body = body;
      func_is_pure = is_pure;
      func_is_tailrec = List.mem "tail_recursive" annotations;
      func_no_copy = List.mem "no_copy" annotations;
      func_debug_only = List.mem "debug_only" annotations;
      func_resource_result_ordinary =
        List.mem "resource_result_ordinary" annotations;
      func_dim_constraints = dim_constraints;
    }

and decode_expr path value =
  let* kind = kind_field path value in
  match kind with
  | "name" ->
      let* name_json = field path "name" value in
      let* name = decode_identifier (path ^ ".name") name_json in
      let* loc = span_field (path ^ ".name") "span" name_json in
      Ok (expr loc (Ast.EIdent name))
  | "int_literal" ->
      let* text = string_field path "value" value in
      let* loc = span_field path "span" value in
      Ok (expr loc (Ast.ELiteral (int_literal_of_text text)))
  | "float_literal" ->
      let* text = string_field path "value" value in
      let* loc = span_field path "span" value in
      (match float_of_string_opt text with
      | Some n -> Ok (expr loc (Ast.ELiteral (Ast.LitFloat n)))
      | None -> error (path ^ ".value") "float literal is not parseable")
  | "string_literal" ->
      let* text = string_field path "value" value in
      let* flags = decode_string_flags path value in
      let* loc = span_field path "span" value in
      Ok (expr loc (Ast.ELiteral (Ast.LitString (text, flags))))
  | "string_interp_raw" ->
      let* text = string_field path "value" value in
      let* is_multiline = bool_field path "multiline" value in
      let* loc = span_field path "span" value in
      Ok (expr loc (Ast.EStringInterpRaw (text, is_multiline)))
  | "bool_literal" ->
      let* value_bool = bool_field path "value" value in
      let* loc = span_field path "span" value in
      Ok (expr loc (Ast.ELiteral (Ast.LitBool value_bool)))
  | "char_literal" ->
      let* codepoint = int_field path "value" value in
      let* loc = span_field path "span" value in
      Ok (expr loc (Ast.ELiteral (Ast.LitChar codepoint)))
  | "unary" ->
      let* op_name = string_field path "op" value in
      let* op = decode_unop (path ^ ".op") op_name in
      let* inner_json = field path "value" value in
      let* inner = decode_expr (path ^ ".value") inner_json in
      let* loc = span_field path "span" value in
      Ok (expr loc (Ast.EUnary (op, inner)))
  | "binary" ->
      let* op_name = string_field path "op" value in
      let* op = decode_binop (path ^ ".op") op_name in
      let* left_json = field path "left" value in
      let* right_json = field path "right" value in
      let* left = decode_expr (path ^ ".left") left_json in
      let* right = decode_expr (path ^ ".right") right_json in
      let* loc = span_field path "span" value in
      Ok (expr loc (Ast.EBinary (op, left, right)))
  | "logical" ->
      let* op_name = string_field path "op" value in
      let* op = decode_logop (path ^ ".op") op_name in
      let* left_json = field path "left" value in
      let* right_json = field path "right" value in
      let* left = decode_expr (path ^ ".left") left_json in
      let* right = decode_expr (path ^ ".right") right_json in
      let* loc = span_field path "span" value in
      Ok (expr loc (Ast.ELogical (op, left, right)))
  | "ascription" ->
      let* value_json = field path "value" value in
      let* type_json = field path "type" value in
      let* inner = decode_expr (path ^ ".value") value_json in
      let* ty = decode_type_expr (path ^ ".type") type_json in
      let* loc = span_field path "span" value in
      Ok (expr loc (Ast.EAscription (inner, ty)))
  | "range" ->
      let* start_json = field path "start" value in
      let* finish_json = field path "finish" value in
      let* start_expr = decode_expr (path ^ ".start") start_json in
      let* finish = decode_expr (path ^ ".finish") finish_json in
      let* loc = span_field path "span" value in
      Ok (expr loc (Ast.ERange (start_expr, finish)))
  | "call" ->
      let* callee_json = field path "callee" value in
      let* args_json = array_field path "args" value in
      let* callee = decode_expr (path ^ ".callee") callee_json in
      let* args = decode_list (path ^ ".args") decode_expr args_json in
      let* loc = span_field path "span" value in
      Ok (expr loc (Ast.ECall (callee, args)))
  | "field_access" ->
      let* target_json = field path "target" value in
      let* field_json = field path "field" value in
      let* target = decode_expr (path ^ ".target") target_json in
      let* field = decode_identifier (path ^ ".field") field_json in
      let* loc = span_field path "span" value in
      Ok (expr loc (Ast.EFieldAccess (target, field)))
  | "subscript" ->
      let* target_json = field path "target" value in
      let* indices_json = array_field path "indices" value in
      let* target = decode_expr (path ^ ".target") target_json in
      let* indices = decode_list (path ^ ".indices") decode_expr indices_json in
      let* loc = span_field path "span" value in
      (match indices with
      | [ index ] -> Ok (expr loc (Ast.ESubscript (target, index)))
      | _ -> Ok (expr loc (Ast.ESubscriptMulti (target, indices))))
  | "list" | "tuple" | "vector" | "block" ->
      let* items_json = array_field path "items" value in
      let* items = decode_list (path ^ ".items") decode_expr items_json in
      let* loc = span_field path "span" value in
      let desc =
        match kind with
        | "list" -> Ast.EList items
        | "tuple" -> Ast.ETuple items
        | "vector" -> Ast.EVector items
        | _ -> Ast.EBlock items
      in
      Ok (expr loc desc)
  | "record" ->
      let* fields_json = array_field path "fields" value in
      let* fields =
        decode_list (path ^ ".fields") decode_record_expr_field fields_json
      in
      let* loc = span_field path "span" value in
      Ok (expr loc (Ast.ERecord fields))
  | "record_update" ->
      let* base_json = field path "base" value in
      let* fields_json = array_field path "fields" value in
      let* base = decode_expr (path ^ ".base") base_json in
      let* fields =
        decode_list (path ^ ".fields") decode_record_expr_field fields_json
      in
      let* loc = span_field path "span" value in
      Ok (expr loc (Ast.ERecordUpdate (base, fields)))
  | "dict" ->
      let* entries_json = array_field path "entries" value in
      let* entries =
        decode_list (path ^ ".entries") decode_dict_entry entries_json
      in
      let* loc = span_field path "span" value in
      Ok (expr loc (Ast.EDict entries))
  | "opaque_into" ->
      let* ty_json = field path "type" value in
      let* ty = decode_type_expr (path ^ ".type") ty_json in
      let* value_json = field path "value" value in
      let* inner = decode_expr (path ^ ".value") value_json in
      let* loc = span_field path "span" value in
      Ok (expr loc (Ast.EOpaqueInto (ty, inner)))
  | "opaque_from" ->
      let* ty_json = field path "type" value in
      let* ty = decode_type_expr (path ^ ".type") ty_json in
      let* value_json = field path "value" value in
      let* inner = decode_expr (path ^ ".value") value_json in
      let* loc = span_field path "span" value in
      Ok (expr loc (Ast.EOpaqueFrom (ty, inner)))
  | "if" ->
      let* cond_json = field path "condition" value in
      let* then_json = field path "then" value in
      let* else_json = field path "else" value in
      let* cond = decode_expr (path ^ ".condition") cond_json in
      let* then_expr = decode_expr (path ^ ".then") then_json in
      let* else_expr =
        match else_json with
        | Lsp_json.Null -> Ok None
        | _ ->
            let* decoded = decode_expr (path ^ ".else") else_json in
            Ok (Some decoded)
      in
      let* loc = span_field path "span" value in
      Ok (expr loc (Ast.EIf (cond, then_expr, else_expr)))
  | "match" ->
      let* value_json = field path "value" value in
      let* cases_json = array_field path "cases" value in
      let* scrutinee = decode_expr (path ^ ".value") value_json in
      let* cases = decode_list (path ^ ".cases") decode_match_case cases_json in
      let* loc = span_field path "span" value in
      Ok (expr loc (Ast.EMatch (scrutinee, cases)))
  | "select" ->
      let* arms_json = array_field path "arms" value in
      let* arms = decode_list (path ^ ".arms") decode_select_arm arms_json in
      let* loc = span_field path "span" value in
      Ok (expr loc (Ast.ESelect arms))
  | "with" ->
      let* binding_json = field path "binding" value in
      let* body_json = field path "body" value in
      let* binding = decode_with_binding (path ^ ".binding") binding_json in
      let* body = decode_expr (path ^ ".body") body_json in
      let* loc = span_field path "span" value in
      Ok (expr loc (Ast.EWith (binding, body)))
  | "debug_block" ->
      let* body_json = field path "body" value in
      let* body = decode_expr (path ^ ".body") body_json in
      let* body_items = require_block_items (path ^ ".body") body in
      let* loc = span_field path "span" value in
      Ok (expr loc (Ast.EDebugBlock body_items))
  | "lambda" ->
      let* is_pure = bool_field path "is_pure" value in
      let* params_json = array_field path "params" value in
      let* params = decode_list (path ^ ".params") decode_lambda_param params_json in
      let* return_type = optional_type_expr_field path "return_type" value in
      let* body_json = field path "body" value in
      let* body = decode_expr (path ^ ".body") body_json in
      let func =
        {
          Ast.func_name = None;
          func_type_params = [];
          func_params = params;
          func_return_type = return_type;
          func_body = Ast.FuncBodyExpr body;
          func_is_pure = is_pure;
          func_is_tailrec = false;
          func_no_copy = false;
          func_debug_only = false;
          func_resource_result_ordinary = false;
          func_dim_constraints = [];
        }
      in
      let* loc = span_field path "span" value in
      Ok (expr loc (Ast.ELambda func))
  | "function_decl" ->
      let* function_json = field path "function" value in
      let* func = decode_function (path ^ ".function") function_json in
      let* loc = span_field path "span" value in
      Ok (expr loc (Ast.EFuncDecl func))
  | "while" ->
      let* cond_json = field path "condition" value in
      let* body_json = field path "body" value in
      let* cond = decode_expr (path ^ ".condition") cond_json in
      let* body = decode_expr (path ^ ".body") body_json in
      let* loc = span_field path "span" value in
      Ok (expr loc (Ast.EWhile (cond, body)))
  | "for" ->
      let* binder_json = field path "binder" value in
      let* iterable_json = field path "iterable" value in
      let* body_json = field path "body" value in
      let* binder = decode_for_binder (path ^ ".binder") binder_json in
      let* iterable = decode_expr (path ^ ".iterable") iterable_json in
      let* body = decode_expr (path ^ ".body") body_json in
      let* loc = span_field path "span" value in
      let desc =
        match binder with
        | DecodedForNameBinder name -> Ast.EFor (name, iterable, body)
        | DecodedForTupleBinder names -> Ast.EForTuple (names, iterable, body)
      in
      Ok (expr loc desc)
  | "concurrent_block" ->
      let* params_json = array_field path "params" value in
      let* params =
        decode_concurrent_block_params (path ^ ".params") params_json
      in
      let* body_json = field path "body" value in
      let* body = decode_expr (path ^ ".body") body_json in
      let* body_items = require_block_items (path ^ ".body") body in
      let* loc = span_field path "span" value in
      Ok
        (expr loc
           (Ast.EConcurrent
              ( body_items,
                params.concurrent_timeout,
                params.concurrent_max_threads )))
	  | "concurrent_for" ->
	      let* name_json = field path "name" value in
	      let* iterable_json = field path "iterable" value in
	      let* params_json = array_field path "params" value in
	      let* body_json = field path "body" value in
	      let* loc = span_field path "span" value in
	      let* name = decode_identifier (path ^ ".name") name_json in
	      let* iterable = decode_expr (path ^ ".iterable") iterable_json in
	      let* params =
	        decode_concurrently_loop_params (path ^ ".params") loc params_json
	      in
	      let* body = decode_expr (path ^ ".body") body_json in
	      Ok
        (expr loc
           (Ast.EConcurrentlyLoop
              ( name,
                iterable,
                body,
                params.loop_timeout,
                Ast.ConcurrentlyLoopLimit params.loop_limit )))
  | "detach" ->
      let* body_json = field path "body" value in
      let* body = decode_expr (path ^ ".body") body_json in
      let* loc = span_field path "span" value in
      Ok (expr loc (Ast.EDetach body))
  | "builtin" ->
      let* name = option_string_field path "name" value in
      let* loc = span_field path "span" value in
      Ok (expr loc (Ast.EBuiltin name))
  | "var_decl" ->
      let* name_json = field path "name" value in
      let* name = decode_identifier (path ^ ".name") name_json in
      let* ty = optional_type_expr_field path "type" value in
      let* value_json = field path "value" value in
      let* rhs = decode_expr (path ^ ".value") value_json in
      let* is_mutable = bool_field path "is_mutable" value in
      let* loc = span_field path "span" value in
      Ok (expr loc (Ast.EVarDecl (name, ty, rhs, is_mutable)))
  | "assign" ->
      let* name_json = field path "name" value in
      let* name = decode_identifier (path ^ ".name") name_json in
      let* value_json = field path "value" value in
      let* rhs = decode_expr (path ^ ".value") value_json in
      let* loc = span_field path "span" value in
      Ok (expr loc (Ast.EAssign (name, rhs)))
  | "compound_assign" ->
      let* name_json = field path "name" value in
      let* name = decode_identifier (path ^ ".name") name_json in
      let* op_name = string_field path "op" value in
      let* op = decode_assign_op (path ^ ".op") op_name in
      let* value_json = field path "value" value in
      let* rhs = decode_expr (path ^ ".value") value_json in
      let* loc = span_field path "span" value in
      Ok (expr loc (Ast.ECompoundAssign (name, op, rhs)))
  | "subscript_assign" ->
      let* target_json = field path "target" value in
      let* target = decode_expr (path ^ ".target") target_json in
      let* indices_json = array_field path "indices" value in
      let* indices =
        decode_list (path ^ ".indices") decode_expr indices_json
      in
      let* value_json = field path "value" value in
      let* rhs = decode_expr (path ^ ".value") value_json in
      let* loc = span_field path "span" value in
      Ok (expr loc (Ast.ESubscriptAssign (target, indices, rhs)))
  | "tuple_destruct" ->
      let* names_json = array_field path "names" value in
      let* names = decode_list (path ^ ".names") decode_identifier names_json in
      let name_count = List.length names in
      if name_count < 2 || name_count > 4 then
        error path "tuple destructuring assignment must have 2-4 names"
      else
        let* value_json = field path "value" value in
        let* rhs = decode_expr (path ^ ".value") value_json in
        let* loc = span_field path "span" value in
        Ok (expr loc (Ast.ETupleDestruct (names, rhs)))
  | "question_bind" ->
      let* name_json = field path "name" value in
      let* name = decode_identifier (path ^ ".name") name_json in
      let* ty = optional_type_expr_field path "type" value in
      let* value_json = field path "value" value in
      let* rhs = decode_expr (path ^ ".value") value_json in
      let* loc = span_field path "span" value in
      Ok (expr loc (Ast.EQuestionBind (name, ty, rhs)))
  | "break" ->
      let* loc = span_field path "span" value in
      Ok (expr loc Ast.EBreak)
  | "continue" ->
      let* loc = span_field path "span" value in
      Ok (expr loc Ast.EContinue)
  | "void" ->
      let* loc = span_field path "span" value in
      Ok (expr loc Ast.EVoid)
  | "missing" -> error path "missing expression cannot be decoded as AST"
  | kind -> error path ("unsupported parsed expression kind `" ^ kind ^ "`")

and decode_record_expr_field path value =
  let* name_json = field path "name" value in
  let* value_json = field path "value" value in
  let* name = decode_identifier (path ^ ".name") name_json in
  let* field_value = decode_expr (path ^ ".value") value_json in
  Ok (name, field_value)

and decode_dict_entry path value =
  let* key_json = field path "key" value in
  let* value_json = field path "value" value in
  let* key = decode_expr (path ^ ".key") key_json in
  let* entry_value = decode_expr (path ^ ".value") value_json in
  Ok (key, entry_value)

and decode_match_case path value =
  let* pattern_json = field path "pattern" value in
  let* body_json = field path "body" value in
  let* pattern = decode_pattern (path ^ ".pattern") pattern_json in
  let* body = decode_expr (path ^ ".body") body_json in
  let* loc = span_field path "span" value in
  Ok { Ast.case_pattern = pattern; case_body = body; case_loc = loc }

and decode_lambda_param path value =
  let* name_json = field path "name" value in
  let* name = decode_identifier (path ^ ".name") name_json in
  let* ty = optional_type_expr_field path "type" value in
  let* loc = span_field path "span" value in
  Ok
    {
      Ast.param_name = Some name;
      param_pattern = None;
      param_type = ty;
      param_loc = loc;
    }

and decode_with_error_map path value =
  let* name_json = field path "name" value in
  let* value_json = field path "value" value in
  let* name = decode_identifier (path ^ ".name") name_json in
  let* map_value = decode_expr (path ^ ".value") value_json in
  Ok { Ast.with_error_name = name; with_error_value = map_value }

and option_with_error_map_field path name value =
  let* value = field path name value in
  match value with
  | Lsp_json.Null -> Ok None
  | _ ->
      let* error_map = decode_with_error_map (path ^ "." ^ name) value in
      Ok (Some error_map)

and decode_with_binding_kind path value =
  match value with
  | "plain" -> Ok Ast.WithPlain
  | "try" -> Ok Ast.WithTry
  | kind -> error path ("unsupported with binding kind `" ^ kind ^ "`")

and decode_with_binding path value =
  let* name_json = field path "name" value in
  let* name = decode_identifier (path ^ ".name") name_json in
  let* ty = optional_type_expr_field path "type" value in
  let* value_json = field path "value" value in
  let* binding_value = decode_expr (path ^ ".value") value_json in
  let* kind_name = string_field path "kind" value in
  let* kind = decode_with_binding_kind (path ^ ".kind") kind_name in
  let* error_map = option_with_error_map_field path "error_map" value in
  Ok
    {
      Ast.with_name = name;
      with_type = ty;
      with_value = binding_value;
      with_kind = kind;
      with_error_map = error_map;
    }

and decode_select_arm_kind path value =
  let* kind = kind_field path value in
  match kind with
  | "receive" ->
      let* name_json = field path "name" value in
      let* source_json = field path "source" value in
      let* name = decode_identifier (path ^ ".name") name_json in
      let* source = decode_expr (path ^ ".source") source_json in
      Ok (Ast.SelectRecv { select_bind = name; select_channel = source })
  | "sealed" ->
      let* source_json = field path "source" value in
      let* source = decode_expr (path ^ ".source") source_json in
      Ok (Ast.SelectSealed source)
  | "after" ->
      let* source_json = field path "source" value in
      let* source = decode_expr (path ^ ".source") source_json in
      Ok (Ast.SelectAfter source)
  | kind -> error path ("unsupported select arm kind `" ^ kind ^ "`")

and decode_select_arm path value =
  let* kind_json = field path "kind" value in
  let* body_json = field path "body" value in
  let* kind = decode_select_arm_kind (path ^ ".kind") kind_json in
  let* body = decode_expr (path ^ ".body") body_json in
  let* loc = span_field path "span" value in
  Ok { Ast.select_arm_kind = kind; select_arm_body = body; select_arm_loc = loc }

and decode_concurrent_param path value =
  let* name_json = field path "name" value in
  let* value_json = field path "value" value in
  let* name = decode_identifier (path ^ ".name") name_json in
  let* param_value = decode_expr (path ^ ".value") value_json in
  Ok (name, param_value)

and decode_concurrent_block_params path values =
  let rec loop index timeout max_threads = function
    | [] ->
        Ok { concurrent_timeout = timeout; concurrent_max_threads = max_threads }
    | value :: rest ->
        let item_path = Printf.sprintf "%s[%d]" path index in
        let* (name, param_value) = decode_concurrent_param item_path value in
        (match name with
        | "timeout" -> (
            match timeout with
            | Some _ ->
                source_error item_path param_value.expr_loc
                  "duplicate timeout parameter"
            | None -> loop (index + 1) (Some param_value) max_threads rest)
        | "max_threads" -> (
            match max_threads with
            | Some _ ->
                source_error item_path param_value.expr_loc
                  "duplicate max_threads parameter"
            | None ->
                let* max_threads_value =
                  positive_int_literal (item_path ^ ".value") "max_threads"
                    param_value
                in
                loop (index + 1) timeout (Some max_threads_value) rest)
        | _ ->
            source_error item_path param_value.expr_loc
              ("unknown concurrent parameter `" ^ name
             ^ "` (expected `max_threads` or `timeout`)"))
  in
  loop 0 None None values

and decode_concurrently_loop_params path loc values =
  let rec loop index timeout limit = function
    | [] -> (
        match limit with
        | Some loop_limit -> Ok { loop_timeout = timeout; loop_limit }
        | None ->
            source_error path loc
              "`for ... concurrently(...)` requires `limit: N`")
    | value :: rest ->
        let item_path = Printf.sprintf "%s[%d]" path index in
        let* (name, param_value) = decode_concurrent_param item_path value in
        (match name with
        | "timeout" -> (
            match timeout with
            | Some _ ->
                source_error item_path param_value.expr_loc
                  "duplicate timeout parameter"
            | None -> loop (index + 1) (Some param_value) limit rest)
        | "limit" -> (
            match limit with
            | Some _ ->
                source_error item_path param_value.expr_loc
                  "duplicate concurrently limit"
            | None ->
                let* limit_value =
                  positive_int_literal (item_path ^ ".value")
                    "concurrently limit" param_value
                in
                loop (index + 1) timeout (Some limit_value) rest)
        | "max_threads" ->
            source_error item_path param_value.expr_loc
              ("use `limit: N` in `concurrently(...)`; `max_threads` "
             ^ "is only valid on `concurrent(...)` blocks")
        | _ ->
            source_error item_path param_value.expr_loc
              ("unknown concurrently parameter `" ^ name
             ^ "` (expected `limit` or `timeout`)"))
  in
  loop 0 None None values

let ast_decl ?(doc = None) loc desc =
  { Ast.decl_desc = desc; decl_loc = loc; decl_doc = doc }

let decode_foreign_block_arg path value =
  let* name_json = field path "name" value in
  let* name = decode_identifier (path ^ ".name") name_json in
  let* value = string_field path "value" value in
  Ok (name, value)

let foreign_block_metadata args =
  let rec loop includes link_flags = function
    | [] -> (List.rev includes, List.rev link_flags)
    | ("include", value) :: rest -> loop (value :: includes) link_flags rest
    | ("link", value) :: rest -> loop includes ((None, value) :: link_flags) rest
    | ("link_linux", value) :: rest ->
        loop includes ((Some "linux", value) :: link_flags) rest
    | ("link_macos", value) :: rest ->
        loop includes ((Some "macos", value) :: link_flags) rest
    | _ :: rest -> loop includes link_flags rest
  in
  loop [] [] args

let decode_foreign_function_decl path value =
  let* name_json = field path "name" value in
  let* name = decode_identifier (path ^ ".name") name_json in
  let* params_json = array_field path "params" value in
  let* params = decode_list (path ^ ".params") decode_param params_json in
  let* return_type_json = field path "return_type" value in
  let* return_type = decode_type_expr (path ^ ".return_type") return_type_json in
  let* c_name = option_string_field path "c_name" value in
  let* is_pure = bool_field path "is_pure" value in
  let* is_private = bool_field path "is_private" value in
  let* annotations = decode_annotations path value in
  let* () = validate_function_annotations path annotations in
  let foreign_name = Option.value c_name ~default:name in
  let* loc = span_field path "span" value in
  let func =
    {
      Ast.func_name = Some name;
      func_type_params = [];
      func_params = params;
      func_return_type = Some return_type;
      func_body =
        Ast.FuncForeign
          {
            Ast.foreign_name = foreign_name;
            foreign_includes = [];
            foreign_link_flags = [];
          };
      func_is_pure = is_pure;
      func_is_tailrec = List.mem "tail_recursive" annotations;
      func_no_copy = List.mem "no_copy" annotations;
      func_debug_only = List.mem "debug_only" annotations;
      func_resource_result_ordinary =
        List.mem "resource_result_ordinary" annotations;
      func_dim_constraints = [];
    }
  in
  let decl = ast_decl loc (Ast.DFunc func) in
  if is_private then Ok (ast_decl loc (Ast.DPrivate decl)) else Ok decl

let apply_foreign_block_metadata ~includes ~link_flags decl =
  let apply_to_func func foreign =
    {
      func with
      Ast.func_body =
        Ast.FuncForeign
          {
            foreign with
            foreign_includes = includes @ foreign.Ast.foreign_includes;
            foreign_link_flags = link_flags @ foreign.Ast.foreign_link_flags;
          };
    }
  in
  match decl.Ast.decl_desc with
  | Ast.DFunc ({ func_body = Ast.FuncForeign foreign; _ } as func) ->
      { decl with Ast.decl_desc = Ast.DFunc (apply_to_func func foreign) }
  | Ast.DPrivate
      ( { decl_desc =
            Ast.DFunc ({ func_body = Ast.FuncForeign foreign; _ } as func);
          _ } as inner ) ->
      {
        decl with
        Ast.decl_desc =
          Ast.DPrivate
            { inner with decl_desc = Ast.DFunc (apply_to_func func foreign) };
      }
  | _ -> decl

let decode_foreign_block_decl path value =
  let* args_json = array_field path "args" value in
  let* args =
    decode_list (path ^ ".args") decode_foreign_block_arg args_json
  in
  let includes, link_flags = foreign_block_metadata args in
  let* functions_json = array_field path "functions" value in
  let* declarations =
    decode_list (path ^ ".functions") decode_foreign_function_decl functions_json
  in
  Ok (List.map (apply_foreign_block_metadata ~includes ~link_flags) declarations)

let decode_function_decl path value =
  let* function_json = field path "function" value in
  let* func = decode_function (path ^ ".function") function_json in
  let* loc = span_field (path ^ ".function") "span" function_json in
  let* doc = option_string_field (path ^ ".function") "doc" function_json in
  Ok (ast_decl ~doc loc (Ast.DFunc func))

let decode_var_decl path value =
  let* var_json = field path "var" value in
  let var_path = path ^ ".var" in
  let* name_json = field var_path "name" var_json in
  let* name = decode_identifier (var_path ^ ".name") name_json in
  let* ty = optional_type_expr_field var_path "type" var_json in
  let* value_json = field var_path "value" var_json in
  let* value = decode_expr (var_path ^ ".value") value_json in
  let* is_mutable = bool_field var_path "is_mutable" var_json in
  let* loc = span_field var_path "span" var_json in
  Ok
    (ast_decl loc
       (Ast.DVar
          {
            var_name = Some name;
            var_pattern = None;
            var_type = ty;
            var_value = value;
            var_is_mutable = is_mutable;
            var_is_const = not is_mutable;
          }))

let decode_import_symbol path value =
  let* name_json = field path "name" value in
  let* name = decode_identifier (path ^ ".name") name_json in
  let* alias = option_identifier_field path "alias" value in
  let* constructors_json = array_field path "constructors" value in
  let* constructors =
    decode_list (path ^ ".constructors") decode_identifier constructors_json
  in
  let sym_ctors =
    match constructors with [] -> Ast.CtorNone | names -> Ast.CtorSome names
  in
  Ok { Ast.sym_name = name; sym_alias = alias; sym_ctors }

let option_import_symbols_field path name value =
  let* value = field path name value in
  match value with
  | Lsp_json.Null -> Ok None
  | Lsp_json.Array values ->
      let* symbols =
        decode_list (path ^ "." ^ name) decode_import_symbol values
      in
      Ok (Some symbols)
  | _ -> error (path ^ "." ^ name) "expected array or null"

let decode_import_decl path value =
  let* module_path = string_field path "module_path" value in
  let* module_alias = option_identifier_field path "module_alias" value in
  let* symbols = option_import_symbols_field path "symbols" value in
  let* loc = span_field path "span" value in
  Ok
    (ast_decl loc
       (Ast.DImport
          {
            import_module = module_path;
            import_symbols = symbols;
            import_alias = module_alias;
          }))

let decode_import_block path value =
  let* imports_json = array_field path "imports" value in
  decode_list (path ^ ".imports") decode_import_decl imports_json

let decode_field_decl path value =
  let* name_json = field path "name" value in
  let* name = decode_identifier (path ^ ".name") name_json in
  let* type_json = field path "type" value in
  let* ty = decode_type_expr (path ^ ".type") type_json in
  let* loc = span_field path "span" value in
  Ok { Ast.field_name = name; field_type = ty; field_loc = loc }

let decode_record_decl path value =
  let* record_json = field path "record" value in
  let record_path = path ^ ".record" in
  let* name_json = field record_path "name" record_json in
  let* name = decode_identifier (record_path ^ ".name") name_json in
  let* type_params_json = array_field record_path "type_params" record_json in
  let* type_params =
    decode_list (record_path ^ ".type_params") decode_type_param type_params_json
  in
  let* fields_json = array_field record_path "fields" record_json in
  let* fields =
    decode_list (record_path ^ ".fields") decode_field_decl fields_json
  in
  let* is_struct = bool_field record_path "is_struct" record_json in
  let* doc = option_string_field record_path "doc" record_json in
  let* loc = span_field record_path "span" record_json in
  Ok
    (ast_decl ~doc loc
       (Ast.DRecord
          {
            record_name = name;
            record_type_params = type_params;
            record_fields = fields;
            record_is_value = is_struct;
            record_is_builtin = false;
          }))

let decode_variant_decl path value =
  let* name_json = field path "name" value in
  let* name = decode_identifier (path ^ ".name") name_json in
  let* fields_json = array_field path "fields" value in
  let* fields = decode_list (path ^ ".fields") decode_type_expr fields_json in
  let* loc = span_field path "span" value in
  Ok
    {
      Ast.variant_name = name;
      variant_fields = fields;
      variant_tag = 0;
      variant_loc = loc;
      variant_def_id = None;
    }

let decode_union_decl path value =
  let* union_json = field path "union" value in
  let union_path = path ^ ".union" in
  let* name_json = field union_path "name" union_json in
  let* name = decode_identifier (union_path ^ ".name") name_json in
  let* type_params_json = array_field union_path "type_params" union_json in
  let* type_params =
    decode_list (union_path ^ ".type_params") decode_type_param type_params_json
  in
  let* variants_json = array_field union_path "variants" union_json in
  let* variants =
    decode_list (union_path ^ ".variants") decode_variant_decl variants_json
  in
  let* is_enum = bool_field union_path "is_enum" union_json in
  let* doc = option_string_field union_path "doc" union_json in
  let* loc = span_field union_path "span" union_json in
  Ok
    (ast_decl ~doc loc
       (Ast.DType
          {
            type_name = name;
            type_params;
            type_variants = variants;
            type_is_enum = is_enum;
            type_is_builtin = false;
            type_is_resource = false;
            type_resource_cleanup = None;
          }))

let decode_resource_cleanup path value =
  let* kind = kind_field path value in
  match kind with
  | "builtin" ->
      let* name = string_field path "name" value in
      Ok (Ast.ResourceCleanupBuiltin name)
  | kind -> error path ("unsupported resource cleanup kind `" ^ kind ^ "`")

let option_resource_cleanup_field path name value =
  let* value = field path name value in
  match value with
  | Lsp_json.Null -> Ok None
  | _ ->
      let* cleanup = decode_resource_cleanup (path ^ "." ^ name) value in
      Ok (Some cleanup)

let decode_builtin_type_decl path value =
  let* type_json = field path "type" value in
  let type_path = path ^ ".type" in
  let* name_json = field type_path "name" type_json in
  let* name = decode_identifier (type_path ^ ".name") name_json in
  let* type_params_json = array_field type_path "type_params" type_json in
  let* type_params =
    decode_list (type_path ^ ".type_params") decode_type_param type_params_json
  in
  let* is_resource = bool_field type_path "is_resource" type_json in
  let* cleanup = option_resource_cleanup_field type_path "cleanup" type_json in
  let* doc = option_string_field type_path "doc" type_json in
  let* loc = span_field type_path "span" type_json in
  Ok
    (ast_decl ~doc loc
       (Ast.DType
          {
            type_name = name;
            type_params;
            type_variants = [];
            type_is_enum = false;
            type_is_builtin = true;
            type_is_resource = is_resource;
            type_resource_cleanup = cleanup;
          }))

let decode_type_alias_decl path value =
  let* alias_json = field path "alias" value in
  let alias_path = path ^ ".alias" in
  let* name_json = field alias_path "name" alias_json in
  let* name = decode_identifier (alias_path ^ ".name") name_json in
  let* type_params_json = array_field alias_path "type_params" alias_json in
  let* type_params =
    decode_list (alias_path ^ ".type_params") decode_type_param type_params_json
  in
  let* target_json = field alias_path "target" alias_json in
  let* target = decode_type_expr (alias_path ^ ".target") target_json in
  let* is_opaque = bool_field alias_path "is_opaque" alias_json in
  let* doc = option_string_field alias_path "doc" alias_json in
  let* loc = span_field alias_path "span" alias_json in
  Ok
    (ast_decl ~doc loc
       (Ast.DTypeAlias
          {
            alias_name = name;
            alias_type_params = type_params;
            alias_target = target;
            alias_is_opaque = is_opaque;
          }))

let decode_optional_expr path value =
  match value with
  | Lsp_json.Null -> Ok None
  | _ ->
      let* expr = decode_expr path value in
      Ok (Some expr)

let decode_trait_method_decl path value =
  let* name_json = field path "name" value in
  let* name = decode_identifier (path ^ ".name") name_json in
  let* params_json = array_field path "params" value in
  let* params = decode_list (path ^ ".params") decode_param params_json in
  let* return_type = optional_type_expr_field path "return_type" value in
  let* body_json = field path "body" value in
  let* body = decode_optional_expr (path ^ ".body") body_json in
  let* is_pure = bool_field path "is_pure" value in
  Ok
    {
      Ast.method_name = name;
      method_params = params;
      method_return_type = return_type;
      method_is_pure = is_pure;
      method_default_body = body;
    }

let decode_trait_decl path value =
  let* trait_json = field path "trait" value in
  let trait_path = path ^ ".trait" in
  let* name_json = field trait_path "name" trait_json in
  let* name = decode_identifier (trait_path ^ ".name") name_json in
  let* type_params_json = array_field trait_path "type_params" trait_json in
  let* type_params =
    decode_list (trait_path ^ ".type_params") decode_type_param type_params_json
  in
  let* supertraits_json = array_field trait_path "supertraits" trait_json in
  let* supertraits =
    decode_list (trait_path ^ ".supertraits") decode_identifier
      supertraits_json
  in
  let* methods_json = array_field trait_path "methods" trait_json in
  let* methods =
    decode_list (trait_path ^ ".methods") decode_trait_method_decl methods_json
  in
  let* doc = option_string_field trait_path "doc" trait_json in
  let* loc = span_field trait_path "span" trait_json in
  Ok
    (ast_decl ~doc loc
       (Ast.DTrait
          {
            trait_name = name;
            trait_type_params = type_params;
            trait_supertraits = supertraits;
            trait_methods = methods;
          }))

let decode_impl_decl path value =
  let* impl_json = field path "impl" value in
  let impl_path = path ^ ".impl" in
  let* trait_json = field impl_path "trait_name" impl_json in
  let* trait_name = decode_identifier (impl_path ^ ".trait_name") trait_json in
  let* for_type_json = field impl_path "for_type" impl_json in
  let* for_type = decode_type_expr (impl_path ^ ".for_type") for_type_json in
  let* methods_json = array_field impl_path "methods" impl_json in
  let* methods =
    decode_list (impl_path ^ ".methods") decode_function methods_json
  in
  let* doc = option_string_field impl_path "doc" impl_json in
  let* loc = span_field impl_path "span" impl_json in
  Ok
    (ast_decl ~doc loc
       (Ast.DImpl
          { impl_trait = trait_name; impl_for_type = for_type; impl_methods = methods }))

let expect_single_decl path decls =
  match decls with
  | [ decl ] -> Ok decl
  | [] -> error path "expected declaration, got empty declaration group"
  | _ -> error path "expected one declaration, got declaration group"

let rec decode_decl_group path value =
  let* kind = kind_field path value in
  match kind with
  | "function" ->
      let* decl = decode_function_decl path value in
      Ok [ decl ]
  | "var" ->
      let* decl = decode_var_decl path value in
      Ok [ decl ]
  | "import_block" -> decode_import_block path value
  | "foreign_block" -> decode_foreign_block_decl path value
  | "record" ->
      let* decl = decode_record_decl path value in
      Ok [ decl ]
  | "union" ->
      let* decl = decode_union_decl path value in
      Ok [ decl ]
  | "builtin_type" ->
      let* decl = decode_builtin_type_decl path value in
      Ok [ decl ]
  | "type_alias" ->
      let* decl = decode_type_alias_decl path value in
      Ok [ decl ]
  | "trait" ->
      let* decl = decode_trait_decl path value in
      Ok [ decl ]
  | "impl" ->
      let* decl = decode_impl_decl path value in
      Ok [ decl ]
  | "private" ->
      let* inner_json = field path "decl" value in
      let* inner_decls = decode_decl_group (path ^ ".decl") inner_json in
      let* inner = expect_single_decl (path ^ ".decl") inner_decls in
      let* loc = span_field path "span" value in
      Ok [ ast_decl loc (Ast.DPrivate inner) ]
  | "error" -> error path "parsed error declaration cannot be decoded as AST"
  | kind -> error path ("unsupported parsed declaration kind `" ^ kind ^ "`")

let decode_diagnostics path value =
  let* diagnostics = array_field path "diagnostics" value in
  match diagnostics with
  | [] -> Ok ()
  | _ -> error (path ^ ".diagnostics") "parsed AST diagnostics must be handled before AST decoding"

let decode_parse_diagnostics value =
  let path = "$" in
  let* diagnostics = array_field path "diagnostics" value in
  decode_list (path ^ ".diagnostics") decode_parsed_diagnostic diagnostics

let decode_program value =
  let path = "$" in
  let* kind = kind_field path value in
  if not (String.equal kind "parsed_program") then
    error path ("expected parsed_program, got `" ^ kind ^ "`")
  else
    let* () = decode_diagnostics path value in
    let* decls_json = array_field path "decls" value in
    let* decl_groups =
      decode_list (path ^ ".decls") decode_decl_group decls_json
    in
    Ok (List.concat decl_groups)

let decode_program_string source =
  match Lsp_json.parse source with
  | json -> decode_program json
  | exception Lsp_json.Parse_error message ->
      error "$" ("invalid JSON: " ^ message)
