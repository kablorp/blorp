(** Decoder for the Blorp-owned typed-AST JSON bridge format.

    This module owns the OCaml side of the temporary typed-program handoff.
    Keep it structural and loss-aware: decode metadata that maps cleanly to
    existing OCaml compiler types, and represent transitional bridge-only facts
    explicitly instead of squeezing them into legacy AST fields. *)

type decode_error = {
  path : string;
  message : string;
  loc : Ast.loc option;
}

type decoded_value_slot = {
  value_slot_semantic_ty : Ast.type_expr;
  value_slot_decision : Ast.type_widening_decision;
}

type decoded_trait_method_target = {
  callable_id : int;
  module_path : string;
}

type decoded_resolved_call_target =
  | DecodedDirectCall of {
      callable_id : int;
      origin : Ast.callable_origin;
    }
  | DecodedTraitMethodCall of {
      trait_name : string;
      impl_target : decoded_trait_method_target option;
    }
  | DecodedIntrinsicCall
  | DecodedClosureCall

type decoded_resolved_call_info = {
  callee_name : string;
  source_name : string;
  purity : Env_types.purity;
  target : decoded_resolved_call_target;
  instantiated_params : Ast.type_expr list;
  instantiated_return : Ast.type_expr;
  resource_args : Env_types.resource_arg_policy;
  dim_constraints : (Ast.type_expr * Ast.type_expr) list;
}

type decoded_typed_expr_info = {
  source_ty : Ast.type_expr option;
  semantic_ty : Ast.type_expr;
  value_ty : Ast.type_expr;
  origin : Ast.expr_type_origin;
  value_slot : decoded_value_slot;
  proofs : Type_proof_metadata.expr_proofs;
  resolved_call : decoded_resolved_call_info option;
  resource_dependencies : string list;
}

type decoded_for_binder =
  | DecodedForNameBinder of string
  | DecodedForTupleBinder of string list

type decoded_concurrently_loop_params = {
  loop_timeout : Typed_ast.expr option;
  loop_limit : int;
}

type decoded_concurrent_block_params = {
  block_timeout : Typed_ast.expr option;
  block_max_threads : int option;
}

let decode_error_to_string err = err.path ^ ": " ^ err.message
let error path message = Error { path; message; loc = None }
let ( let* ) = Result.bind

let field path name = function
  | Lsp_json.Object fields -> (
      match List.assoc_opt name fields with
      | Some value -> Ok value
      | None -> error path ("missing field `" ^ name ^ "`"))
  | _ -> error path "expected object"

let optional_field path name = function
  | Lsp_json.Object fields -> Ok (List.assoc_opt name fields)
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

let int_field path name value =
  let* value = field path name value in
  int_value (path ^ "." ^ name) value

let const_int_field path name value =
  let* value = field path name value in
  let value_path = path ^ "." ^ name in
  match value with
  | Lsp_json.String text -> (
      match int_of_string_opt text with
      | Some value -> Ok (Some value)
      | None -> (
          match Int64.of_string_opt text with
          | Some _ -> Ok None
          | None -> error value_path "expected integer text"))
  | Lsp_json.Int value -> Ok (Some value)
  | Lsp_json.Float value ->
      if not (Float.is_finite value) then error value_path "expected finite integer"
      else if value < float_of_int min_int || value > float_of_int max_int then
        Ok None
      else
        let truncated = int_of_float value in
        if Float.equal value (float_of_int truncated) then Ok (Some truncated)
        else error value_path "expected exact integer"
  | _ -> error value_path "expected integer"

let option_string_value path = function
  | Lsp_json.Null -> Ok None
  | Lsp_json.String value -> Ok (Some value)
  | _ -> error path "expected string or null"

let option_string_field path name value =
  let* value = field path name value in
  option_string_value (path ^ "." ^ name) value

let option_int_value path = function
  | Lsp_json.Null -> Ok None
  | value ->
      let* decoded = int_value path value in
      Ok (Some decoded)

let array_value path = function
  | Lsp_json.Array values -> Ok values
  | _ -> error path "expected array"

let array_field path name value =
  let* value = field path name value in
  array_value (path ^ "." ^ name) value

let decode_list path decode values =
  let rec loop index acc = function
    | [] -> Ok (List.rev acc)
    | value :: rest ->
        let* decoded = decode (Printf.sprintf "%s[%d]" path index) value in
        loop (index + 1) (decoded :: acc) rest
  in
  loop 0 [] values

let decode_string_list path value =
  let* values = array_value path value in
  decode_list path string_value values

let decode_identifier path value =
  let* text = string_field path "text" value in
  Ok text

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
  let* span_json = field path name value in
  decode_span (path ^ "." ^ name) span_json

let decode_identifier_with_span path value =
  let* text = string_field path "text" value in
  let* loc = span_field path "span" value in
  Ok (text, loc)

let parsed_decode_result = function
  | Ok value -> Ok value
  | Error err ->
      Error
        {
          path = err.Parsed_ast_json.path;
          message = err.Parsed_ast_json.message;
          loc = err.Parsed_ast_json.loc;
        }

let decode_parsed_function path value =
  parsed_decode_result (Parsed_ast_json.decode_function path value)

let decode_parsed_record_decl path value =
  let wrapped = Lsp_json.Object [ ("record", value) ] in
  match parsed_decode_result (Parsed_ast_json.decode_record_decl path wrapped) with
  | Ok ({ Ast.decl_desc = Ast.DRecord _; _ } as decl) -> Ok decl
  | Ok _ -> error path "decoded parsed declaration was not a record"
  | Error err -> Error err

let decode_parsed_type_alias_decl path value =
  let wrapped = Lsp_json.Object [ ("alias", value) ] in
  match parsed_decode_result (Parsed_ast_json.decode_type_alias_decl path wrapped) with
  | Ok ({ Ast.decl_desc = Ast.DTypeAlias _; _ } as decl) -> Ok decl
  | Ok _ -> error path "decoded parsed declaration was not a type alias"
  | Error err -> Error err

let decode_parsed_union_decl path value =
  let wrapped = Lsp_json.Object [ ("union", value) ] in
  match parsed_decode_result (Parsed_ast_json.decode_union_decl path wrapped) with
  | Ok ({ Ast.decl_desc = Ast.DType _; _ } as decl) -> Ok decl
  | Ok _ -> error path "decoded parsed declaration was not a union"
  | Error err -> Error err

let decode_parsed_impl_decl path value =
  let wrapped = Lsp_json.Object [ ("impl", value) ] in
  match parsed_decode_result (Parsed_ast_json.decode_impl_decl path wrapped) with
  | Ok ({ Ast.decl_desc = Ast.DImpl _; _ } as decl) -> Ok decl
  | Ok _ -> error path "decoded parsed declaration was not an impl"
  | Error err -> Error err

let decode_parsed_var_decl path value =
  let wrapped =
    Lsp_json.Object [ ("kind", Lsp_json.String "var"); ("var", value) ]
  in
  match parsed_decode_result (Parsed_ast_json.decode_decl_group path wrapped) with
  | Ok [ ({ Ast.decl_desc = Ast.DVar _; _ } as decl) ] -> Ok decl
  | Ok [ _ ] -> error path "decoded parsed declaration was not a global variable"
  | Ok _ -> error path "decoded global variable produced unexpected declaration count"
  | Error err -> Error err

let typed_decl_of_ast_decl path ast_decl =
  match Typed_ast.of_ast_decl ast_decl with
  | Ok decl -> Ok decl
  | Error _ -> error path "decoded parsed declaration failed typed-AST validation"

let rec decorate_typed_passthrough_decl (decl : Ast.decl) : Ast.decl =
  let desc =
    match decl.decl_desc with
    | Ast.DType type_decl ->
        let variants =
          List.mapi
            (fun tag (variant : Ast.variant) ->
              {
                variant with
                variant_tag = tag;
                variant_def_id =
                  Some (Session.mint_def_id (Session.current ()));
              })
            type_decl.type_variants
        in
        Ast.DType { type_decl with type_variants = variants }
    | Ast.DPrivate inner ->
        Ast.DPrivate (decorate_typed_passthrough_decl inner)
    | other -> other
  in
  { decl with decl_desc = desc }

let decode_parsed_typed_decl_group path value =
  let* ast_decls =
    parsed_decode_result (Parsed_ast_json.decode_decl_group path value)
  in
  let rec loop acc index decls =
    match decls with
    | [] -> Ok (List.rev acc)
    | ast_decl :: rest ->
        let item_path = Printf.sprintf "%s[%d]" path index in
        let ast_decl = decorate_typed_passthrough_decl ast_decl in
        let* typed_decl = typed_decl_of_ast_decl item_path ast_decl in
        loop (typed_decl :: acc) (index + 1) rest
  in
  loop [] 0 ast_decls

let expect_single_typed_decl path decls =
  match decls with
  | [ decl ] -> Ok decl
  | [] -> error path "typed declaration decoded to no declarations"
  | _ -> error path "typed declaration decoded to a declaration group"

let int_literal_of_text text =
  match Int64.of_string_opt text with
  | Some value -> Ast.LitInt value
  | None -> Ast.LitInt128 text

let decode_dim_op path = function
  | "add" -> Ok Ast.DimAdd
  | "subtract" -> Ok Ast.DimSub
  | "multiply" -> Ok Ast.DimMul
  | "divide" -> Ok Ast.DimDiv
  | op -> error path ("unsupported dimension operator `" ^ op ^ "`")

let rec decode_type path value =
  let* kind = kind_field path value in
  match kind with
  | "named" ->
      let* name = string_field path "name" value in
      let* args_json = array_field path "args" value in
      let* args = decode_list (path ^ ".args") decode_type args_json in
      Ok (Ast.TyNamed (name, args))
  | "array" ->
      let* element_json = field path "element" value in
      let* element = decode_type (path ^ ".element") element_json in
      let* dims_json = array_field path "dims" value in
      let* dims = decode_list (path ^ ".dims") decode_type dims_json in
      Ok (Ast.TyArray (element, dims))
  | "function" ->
      let* is_pure = bool_field path "pure" value in
      let* params_json = array_field path "params" value in
      let* params = decode_list (path ^ ".params") decode_type params_json in
      let* return_json = field path "return_type" value in
      let* return = decode_type (path ^ ".return_type") return_json in
      Ok (Ast.TyFunc { params; return; is_pure })
  | "type_var" ->
      let* name = string_field path "name" value in
      Ok (Ast.TyVar name)
  | "const_int" ->
      let* value = const_int_field path "value" value in
      Ok
        (match value with
        | Some value -> Ast.TyConstInt value
        | None -> Ast.TyNamed ("Int", []))
  | "tuple" ->
      let* items_json = array_field path "items" value in
      let* items = decode_list (path ^ ".items") decode_type items_json in
      Ok (Ast.TyTuple items)
  | "self" -> Ok Ast.TySelf
  | "var_dims" ->
      let* name = string_field path "name" value in
      Ok (Ast.TyVarDims name)
  | "range" ->
      let* inner_json = field path "inner" value in
      let* inner = decode_type (path ^ ".inner") inner_json in
      Ok (Ast.TyRange inner)
  | "dim_op" ->
      let* op_text = string_field path "op" value in
      let* op = decode_dim_op (path ^ ".op") op_text in
      let* left_json = field path "left" value in
      let* left = decode_type (path ^ ".left") left_json in
      let* right_json = field path "right" value in
      let* right = decode_type (path ^ ".right") right_json in
      Ok (Ast.TyDimOp (op, left, right))
  | "meta" ->
      let* id = int_field path "id" value in
      Ok (Ast.TyMeta id)
  | _ -> error (path ^ ".kind") ("unsupported type kind `" ^ kind ^ "`")

let decode_optional_type path = function
  | Lsp_json.Null -> Ok None
  | value ->
      let* ty = decode_type path value in
      Ok (Some ty)

let decode_collection_kind path = function
  | "list" -> Ok Ast.ListLiteral
  | "vector" -> Ok Ast.VectorLiteral
  | "dict" -> Ok Ast.DictLiteral
  | "set" -> Ok Ast.SetLiteral
  | kind -> error path ("unsupported collection kind `" ^ kind ^ "`")

let decode_binary_op path = function
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

let decode_unary_op path = function
  | "negate" -> Ok Ast.Neg
  | "not" -> Ok Ast.Not
  | op -> error path ("unsupported unary operator `" ^ op ^ "`")

let decode_logical_op path = function
  | "and" -> Ok Ast.And
  | "or" -> Ok Ast.Or
  | op -> error path ("unsupported logical operator `" ^ op ^ "`")

let decode_widening_reason path value =
  let* kind = kind_field path value in
  match kind with
  | "mutable_binding" -> Ok Ast.MutableBinding
  | "argument_slot" -> Ok Ast.ArgumentSlot
  | "collection_element" ->
      let* collection = string_field path "collection" value in
      let* kind = decode_collection_kind (path ^ ".collection") collection in
      Ok (Ast.CollectionElement kind)
  | "bitwise_operator" -> Ok Ast.BitwiseOperator
  | "method_receiver" -> Ok Ast.MethodReceiver
  | "range_proof_erasure" -> Ok Ast.RangeProofErasure
  | "tuple_literal" -> Ok Ast.TupleLiteral
  | "numeric_operator" ->
      let* op = string_field path "op" value in
      let* op = decode_binary_op (path ^ ".op") op in
      Ok (Ast.NumericOperator op)
  | _ ->
      error (path ^ ".kind") ("unsupported widening reason kind `" ^ kind ^ "`")

let decode_widening_decision path value =
  let* kind = kind_field path value in
  match kind with
  | "keep" ->
      let* ty_json = field path "type" value in
      let* ty = decode_type (path ^ ".type") ty_json in
      Ok (Ast.Keep ty)
  | "widen" ->
      let* from_json = field path "from_type" value in
      let* from_ty = decode_type (path ^ ".from_type") from_json in
      let* to_json = field path "to_type" value in
      let* to_ty = decode_type (path ^ ".to_type") to_json in
      let* reason_json = field path "reason" value in
      let* reason = decode_widening_reason (path ^ ".reason") reason_json in
      Ok (Ast.Widen { from_ty; to_ty; reason })
  | _ ->
      error
        (path ^ ".kind")
        ("unsupported widening decision kind `" ^ kind ^ "`")

let decode_expr_type_origin path value =
  let* kind = kind_field path value in
  match kind with
  | "inferred" -> Ok Ast.Inferred
  | "explicit_annotation" ->
      let* ty_json = field path "type" value in
      let* ty = decode_type (path ^ ".type") ty_json in
      Ok (Ast.ExplicitAnnotation ty)
  | "synthesized" ->
      let* label = string_field path "label" value in
      Ok (Ast.Synthesized label)
  | _ -> error (path ^ ".kind") ("unsupported type origin kind `" ^ kind ^ "`")

let decode_list_pattern_spread path value =
  let* kind = kind_field path value in
  match kind with
  | "name" ->
      let* name_json = field path "name" value in
      let* name = decode_identifier (path ^ ".name") name_json in
      Ok (Ast.PatVar name)
  | "wildcard" -> Ok Ast.PatWildcard
  | _ ->
      error
        (path ^ ".kind")
        ("unsupported list pattern spread kind `" ^ kind ^ "`")

let decode_optional_list_pattern_spread path = function
  | Lsp_json.Null -> Ok None
  | value ->
      let* spread = decode_list_pattern_spread path value in
      Ok (Some spread)

let rec decode_pattern path value =
  let* kind = kind_field path value in
  match kind with
  | "wildcard" -> Ok Ast.PatWildcard
  | "name" ->
      let* name_json = field path "name" value in
      let* name = decode_identifier (path ^ ".name") name_json in
      let* type_json = field path "type" value in
      let* _ = decode_type (path ^ ".type") type_json in
      Ok (Ast.PatVar name)
  | "bool" ->
      let* value_bool = bool_field path "value" value in
      Ok (Ast.PatLiteral (Ast.LitBool value_bool))
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
      Ok
        (Ast.PatLiteral
           (Ast.LitString
              (text, { Ast.sf_multiline = false; sf_raw = false })))
  | "char" ->
      let* codepoint = int_field path "value" value in
      Ok (Ast.PatLiteral (Ast.LitChar codepoint))
  | "constructor" ->
      let* name_json = field path "name" value in
      let* name = decode_identifier (path ^ ".name") name_json in
      let* args_json = array_field path "args" value in
      let* args = decode_list (path ^ ".args") decode_pattern args_json in
      Ok (Ast.PatConstructor (name, args))
  | "qualified_constructor" ->
      let* module_json = field path "module" value in
      let* module_name = decode_identifier (path ^ ".module") module_json in
      let* name_json = field path "name" value in
      let* name = decode_identifier (path ^ ".name") name_json in
      let* args_json = array_field path "args" value in
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
      let* spread_json = field path "spread" value in
      let* spread =
        decode_optional_list_pattern_spread (path ^ ".spread") spread_json
      in
      Ok (Ast.PatList (items, spread))
  | "or" ->
      let* items_json = array_field path "items" value in
      let* items = decode_list (path ^ ".items") decode_pattern items_json in
      Ok (Ast.PatOr items)
  | "unsupported" ->
      let* label = string_field path "label" value in
      error path ("unsupported typed pattern `" ^ label ^ "`")
  | _ ->
      error
        (path ^ ".kind")
        ("unsupported typed pattern kind `" ^ kind ^ "`")

let decode_value_slot path value =
  let* semantic_json = field path "semantic_type" value in
  let* value_slot_semantic_ty =
    decode_type (path ^ ".semantic_type") semantic_json
  in
  let* decision_json = field path "decision" value in
  let* value_slot_decision =
    decode_widening_decision (path ^ ".decision") decision_json
  in
  Ok { value_slot_semantic_ty; value_slot_decision }

let decode_collection_identity path value =
  let* name = string_field path "name" value in
  match Type_proof_metadata.collection_identity name with
  | Some identity -> Ok identity
  | None -> error (path ^ ".name") "invalid collection identity"

let decode_dimension_identity path value =
  let* name = string_field path "name" value in
  match Type_proof_metadata.dimension_identity name with
  | Some identity -> Ok identity
  | None -> error (path ^ ".name") "invalid dimension identity"

let decode_proof_source path = function
  | "unknown" -> Ok Type_proof_metadata.ProofSourceUnknown
  | "loop_range" -> Ok Type_proof_metadata.ProofSourceLoopRange
  | "loop_indices" -> Ok Type_proof_metadata.ProofSourceLoopIndices
  | "loop_enumerate" -> Ok Type_proof_metadata.ProofSourceLoopEnumerate
  | "condition" -> Ok Type_proof_metadata.ProofSourceCondition
  | "range_type_fallback" ->
      Ok Type_proof_metadata.ProofSourceRangeTypeFallback
  | source -> error path ("unsupported proof source `" ^ source ^ "`")

let rec decode_proven_collection path value =
  let* kind = kind_field path value in
  match kind with
  | "var" ->
      let* identity_json = field path "identity" value in
      let* identity =
        decode_collection_identity (path ^ ".identity") identity_json
      in
      Ok (Type_proof_metadata.collection_var identity)
  | "subscript" ->
      let* parent_json = field path "parent" value in
      let* parent = decode_proven_collection (path ^ ".parent") parent_json in
      let* identity_json = field path "identity" value in
      let* index =
        decode_collection_identity (path ^ ".identity") identity_json
      in
      Ok (Type_proof_metadata.collection_subscript parent ~index)
  | "dim" ->
      let* dim = int_field path "value" value in
      (match Type_proof_metadata.collection_dim dim with
      | Some collection -> Ok collection
      | None -> error (path ^ ".value") "dimension collection must be >= 0")
  | _ ->
      error
        (path ^ ".kind")
        ("unsupported proven collection kind `" ^ kind ^ "`")

let decode_range_upper path value =
  let* kind = kind_field path value in
  match kind with
  | "literal" ->
      let* upper = int_field path "value" value in
      (match Type_proof_metadata.range_upper_lit upper with
      | Some range_upper -> Ok range_upper
      | None -> error (path ^ ".value") "range upper literal must be >= 0")
  | "dimension" ->
      let* identity_json = field path "identity" value in
      let* identity =
        decode_dimension_identity (path ^ ".identity") identity_json
      in
      Ok (Type_proof_metadata.range_upper_dimension identity)
  | "length_minus" ->
      let* identity_json = field path "identity" value in
      let* coll = decode_collection_identity (path ^ ".identity") identity_json in
      let* end_offset = int_field path "offset" value in
      (match Type_proof_metadata.range_upper_length_minus ~coll ~end_offset with
      | Some range_upper -> Ok range_upper
      | None -> error (path ^ ".offset") "length-minus offset must be >= 0")
  | "at_most_length" ->
      let* identity_json = field path "identity" value in
      let* coll = decode_collection_identity (path ^ ".identity") identity_json in
      Ok (Type_proof_metadata.range_upper_at_most_length ~coll)
  | _ ->
      error (path ^ ".kind") ("unsupported range upper kind `" ^ kind ^ "`")

let decode_range_proof path value =
  let* range_start = int_field path "start" value in
  let* upper_json = field path "upper" value in
  let* range_upper = decode_range_upper (path ^ ".upper") upper_json in
  let* source_text = string_field path "source" value in
  let* source = decode_proof_source (path ^ ".source") source_text in
  match
    Type_proof_metadata.make_range_proof_with_source ~source ~range_start
      ~range_upper
  with
  | Some proof -> Ok proof
  | None -> error path "invalid range proof bounds"

let decode_optional_range_proof path = function
  | Lsp_json.Null -> Ok None
  | value ->
      let* proof = decode_range_proof path value in
      Ok (Some proof)

let decode_subscript_proof path value =
  let* collection_json = field path "collection" value in
  let* collection =
    decode_proven_collection (path ^ ".collection") collection_json
  in
  let* source_text = string_field path "source" value in
  let* source = decode_proof_source (path ^ ".source") source_text in
  Ok (Type_proof_metadata.make_subscript_proof ~source ~collection)

let decode_optional_subscript_proof path = function
  | Lsp_json.Null -> Ok None
  | value ->
      let* proof = decode_subscript_proof path value in
      Ok (Some proof)

let decode_value_proofs path value =
  let* range_json = field path "range" value in
  let* range = decode_optional_range_proof (path ^ ".range") range_json in
  let* subscript_json = field path "subscript" value in
  let* subscript =
    decode_optional_subscript_proof (path ^ ".subscript") subscript_json
  in
  let proofs =
    match range with
    | Some proof -> Type_proof_metadata.range_binding proof
    | None -> Type_proof_metadata.unproven_expr
  in
  let proofs =
    match subscript with
    | Some proof ->
        Type_proof_metadata.binding_add_subscript_proof
          ~source:(Type_proof_metadata.subscript_proof_source proof)
          proofs
          ~collection:(Type_proof_metadata.subscript_proof_collection proof)
    | None -> proofs
  in
  Ok proofs

let decode_purity path = function
  | "pure" -> Ok Env_types.Pure
  | "impure" -> Ok Env_types.Impure
  | purity -> error path ("unsupported purity `" ^ purity ^ "`")

let decode_resource_result_policy path = function
  | "dependent" -> Ok Env_types.ResourceResultDependent
  | "independent" -> Ok Env_types.ResourceResultIndependent
  | "ordinary" -> Ok Env_types.ResourceResultOrdinary
  | policy -> error path ("unsupported resource result policy `" ^ policy ^ "`")

let decode_resource_arg_policy path value =
  let* kind = kind_field path value in
  match kind with
  | "reject" -> Ok Env_types.RejectResourceArgs
  | "allow" ->
      let* result_text = string_field path "result_policy" value in
      let* result_policy =
        decode_resource_result_policy (path ^ ".result_policy") result_text
      in
      Ok (Env_types.AllowResourceArgs result_policy)
  | _ ->
      error
        (path ^ ".kind")
        ("unsupported resource argument policy kind `" ^ kind ^ "`")

let decode_callable_origin path value =
  let* kind = kind_field path value in
  match kind with
  | "local" -> Ok Ast.CallableLocal
  | "imported" ->
      let* module_path = string_field path "module" value in
      Ok (Ast.CallableImported module_path)
  | "builtin" -> Ok Ast.CallableBuiltin
  | "foreign" -> Ok Ast.CallableForeign
  | "constructor" ->
      let* parent_type = string_field path "parent_type" value in
      Ok (Ast.CallableConstructor parent_type)
  | "impl_method" -> Ok Ast.CallableImplMethod
  | _ ->
      error
        (path ^ ".kind")
        ("unsupported callable origin kind `" ^ kind ^ "`")

let decode_dim_constraint path value =
  let* left_json = field path "left" value in
  let* left = decode_type (path ^ ".left") left_json in
  let* right_json = field path "right" value in
  let* right = decode_type (path ^ ".right") right_json in
  Ok (left, right)

let decode_trait_method_target path value =
  let* callable_id = int_field path "callable_id" value in
  let* module_path = string_field path "module_path" value in
  Ok { callable_id; module_path }

let decode_optional_trait_method_target path = function
  | Lsp_json.Null -> Ok None
  | value ->
      let* target = decode_trait_method_target path value in
      Ok (Some target)

let decode_resolved_call_target path value =
  let* kind = kind_field path value in
  match kind with
  | "direct" ->
      let* callable_id = int_field path "callable_id" value in
      let* origin_json = field path "origin" value in
      let* origin = decode_callable_origin (path ^ ".origin") origin_json in
      Ok (DecodedDirectCall { callable_id; origin })
  | "trait_method" ->
      let* trait_name = string_field path "trait_name" value in
      let* impl_target_json = field path "impl_target" value in
      let* impl_target =
        decode_optional_trait_method_target
          (path ^ ".impl_target") impl_target_json
      in
      Ok (DecodedTraitMethodCall { trait_name; impl_target })
  | "intrinsic" -> Ok DecodedIntrinsicCall
  | "closure" -> Ok DecodedClosureCall
  | _ ->
      error (path ^ ".kind")
        ("unsupported resolved call target kind `" ^ kind ^ "`")

let decode_resolved_call_info path value =
  let* callee_name = string_field path "callee_name" value in
  let* source_name_opt = option_string_field path "source_name" value in
  let source_name = Option.value ~default:callee_name source_name_opt in
  let* purity_text = string_field path "purity" value in
  let* purity = decode_purity (path ^ ".purity") purity_text in
  let* target_json = field path "target" value in
  let* target = decode_resolved_call_target (path ^ ".target") target_json in
  let* instantiated_params_json = array_field path "instantiated_params" value in
  let* instantiated_params =
    decode_list (path ^ ".instantiated_params") decode_type
      instantiated_params_json
  in
  let* instantiated_return_json = field path "instantiated_return" value in
  let* instantiated_return =
    decode_type (path ^ ".instantiated_return") instantiated_return_json
  in
  let* resource_args_json = field path "resource_args" value in
  let* resource_args =
    decode_resource_arg_policy (path ^ ".resource_args") resource_args_json
  in
  let* constraints_json = array_field path "dim_constraints" value in
  let* dim_constraints =
    decode_list (path ^ ".dim_constraints") decode_dim_constraint
      constraints_json
  in
  Ok
    {
      callee_name;
      source_name;
      purity;
      target;
      instantiated_params;
      instantiated_return;
      resource_args;
      dim_constraints;
    }

let decode_optional_resolved_call_info path = function
  | Lsp_json.Null -> Ok None
  | value ->
      let* info = decode_resolved_call_info path value in
      Ok (Some info)

let validate_origin_coherence path source_ty origin =
  match origin with
  | Ast.ExplicitAnnotation ty -> (
      match source_ty with
      | Some source_ty when Types.types_equal source_ty ty -> Ok ()
      | Some _ -> error path "explicit origin type must match source type"
      | None -> error path "explicit origin requires source type")
  | Ast.Inferred | Ast.Synthesized _ -> Ok ()

let validate_widening_coherence path semantic_ty value_ty value_slot =
  if
    not
      (Types.types_equal semantic_ty value_slot.value_slot_semantic_ty)
  then
    error
      (path ^ ".value_slot.semantic_type")
      "semantic type must match value slot semantic type"
  else
    match value_slot.value_slot_decision with
    | Ast.Keep ty ->
        if not (Types.types_equal semantic_ty ty) then
          error
            (path ^ ".value_slot.decision.type")
            "kept widening decision must match semantic type"
        else if not (Types.types_equal value_ty ty) then
          error
            (path ^ ".value_slot.decision.type")
            "kept widening decision must match value type"
        else Ok ()
    | Ast.Widen { from_ty; to_ty; _ } ->
        if not (Types.types_equal semantic_ty from_ty) then
          error
            (path ^ ".value_slot.decision.from_type")
            "widening source must match semantic type"
        else if not (Types.types_equal value_ty to_ty) then
          error
            (path ^ ".value_slot.decision.to_type")
            "widening target must match value type"
        else Ok ()

let types_equal_list left right =
  let rec loop left right =
    match (left, right) with
    | [], [] -> true
    | left :: left_rest, right :: right_rest ->
        Types.types_equal left right && loop left_rest right_rest
    | _ -> false
  in
  loop left right

let optional_types_equal left right =
  match (left, right) with
  | None, None -> true
  | Some left, Some right -> Types.types_equal left right
  | _ -> false

let decode_typed_expr_info path value =
  let* source_json = field path "source_type" value in
  let* source_ty = decode_optional_type (path ^ ".source_type") source_json in
  let* semantic_json = field path "semantic_type" value in
  let* semantic_ty = decode_type (path ^ ".semantic_type") semantic_json in
  let* value_json = field path "value_type" value in
  let* value_ty = decode_type (path ^ ".value_type") value_json in
  let* origin_json = field path "origin" value in
  let* origin = decode_expr_type_origin (path ^ ".origin") origin_json in
  let* value_slot_json = field path "value_slot" value in
  let* value_slot = decode_value_slot (path ^ ".value_slot") value_slot_json in
  let* proofs_json = field path "proofs" value in
  let* proofs = decode_value_proofs (path ^ ".proofs") proofs_json in
  let* resolved_call_json = field path "resolved_call" value in
  let* resolved_call =
    decode_optional_resolved_call_info (path ^ ".resolved_call")
      resolved_call_json
  in
  let* resource_deps_json = field path "resource_dependencies" value in
  let* resource_dependencies =
    decode_string_list (path ^ ".resource_dependencies") resource_deps_json
  in
  let* () = validate_origin_coherence (path ^ ".origin") source_ty origin in
  let* () =
    validate_widening_coherence path semantic_ty value_ty value_slot
  in
  Ok
    {
      source_ty;
      semantic_ty;
      value_ty;
      origin;
      value_slot;
      proofs;
      resolved_call;
      resource_dependencies;
    }

let call_pure_of_purity = function
  | Env_types.Pure -> true
  | Env_types.Impure -> false

let normalize_imported_function_ref_desc
    (info : decoded_typed_expr_info) (desc : Ast.expr_desc) : Ast.expr_desc =
  match (desc, info.resolved_call) with
  | ( Ast.EIdent _,
      Some
        {
          target =
            DecodedDirectCall
              { origin = Ast.CallableImported module_path; _ };
          source_name;
          _;
        } ) ->
      Ast.EIdent
        (Codegen_names.sanitize_module_name module_path ^ "__" ^ source_name)
  | _ -> desc

let normalize_trait_method_function_ref_desc
    (info : decoded_typed_expr_info) (desc : Ast.expr_desc) : Ast.expr_desc =
  match (desc, info.resolved_call) with
  | ( Ast.EIdent _,
      Some
        {
          target =
            DecodedTraitMethodCall
              { impl_target = Some { module_path; _ }; _ };
          source_name;
          _;
        } ) ->
      Ast.EIdent (Codegen_names.make_ufcs_name module_path source_name)
  | _ -> desc

let normalize_imported_bare_call_desc
    (info : decoded_typed_expr_info) (desc : Ast.expr_desc) : Ast.expr_desc =
  match (desc, info.resolved_call) with
  | ( Ast.ECall (({ Ast.expr_desc = Ast.EIdent _; _ } as callee), args),
      Some
        {
          target =
            DecodedDirectCall
              { origin = Ast.CallableImported module_path; _ };
          source_name;
          _;
        } ) ->
      Ast.ECall
        ( { callee with
            expr_desc =
              Ast.EIdent
                (Codegen_names.make_ufcs_name module_path source_name);
          },
          args )
  | _ -> desc

let call_syntax_of_direct_desc origin desc =
  match desc with
  | Ast.ECall
      ( { Ast.expr_desc = Ast.EFieldAccess ({ expr_desc = Ast.EIdent _; _ }, _);
          _;
        },
        _ )
  | Ast.EFieldAccess ({ expr_desc = Ast.EIdent _; _ }, _) -> (
      match origin with
      | Ast.CallableImported module_path -> Ast.CallQualified module_path
      | _ -> Ast.CallMethod)
  | Ast.ECall ({ Ast.expr_desc = Ast.EFieldAccess _; _ }, _)
  | Ast.EFieldAccess _ ->
      Ast.CallMethod
  | _ -> Ast.CallBare

let call_syntax_of_decoded_target target desc =
  match target with
  | DecodedIntrinsicCall -> Ast.CallBare
  | DecodedClosureCall -> Ast.CallClosureSyntax
  | DecodedTraitMethodCall _ ->
      call_syntax_of_direct_desc Ast.CallableImplMethod desc
  | DecodedDirectCall { origin; _ } -> call_syntax_of_direct_desc origin desc

let materialize_resolved_call _path desc
    (info_opt : decoded_resolved_call_info option) =
  match info_opt with
  | None -> Ok None
  | Some info -> (
      match info.target with
      | DecodedIntrinsicCall -> Ok None
      | DecodedClosureCall ->
          Ok
            (Some
               {
                 Ast.call_syntax = Ast.CallClosureSyntax;
                 call_target =
                   Ast.CallClosure { call_pure = call_pure_of_purity info.purity };
                 instantiated_params = info.instantiated_params;
                 instantiated_return = info.instantiated_return;
               })
      | DecodedTraitMethodCall { trait_name; impl_target } ->
          Ok
            (Some
               {
                 Ast.call_syntax = call_syntax_of_decoded_target info.target desc;
                 call_target =
                   Ast.CallTraitMethod
                     {
                       trait_name;
                       method_name = info.source_name;
                       call_pure = call_pure_of_purity info.purity;
                       callable_id = Option.map (fun target -> target.callable_id) impl_target;
                     };
                 instantiated_params = info.instantiated_params;
                 instantiated_return = info.instantiated_return;
               })
      | DecodedDirectCall { callable_id; origin } ->
          Ok
            (Some
               {
                 Ast.call_syntax = call_syntax_of_decoded_target info.target desc;
                 call_target =
                   Ast.CallDirect
                     {
                       callable_id;
                       source_name = info.source_name;
                       call_pure = call_pure_of_purity info.purity;
                       origin;
                     };
                 instantiated_params = info.instantiated_params;
                 instantiated_return = info.instantiated_return;
               }))

let make_typed_expr path loc info desc =
  let desc = normalize_imported_function_ref_desc info desc in
  let desc = normalize_trait_method_function_ref_desc info desc in
  let desc = normalize_imported_bare_call_desc info desc in
  let* resolved_call =
    materialize_resolved_call (path ^ ".info.resolved_call") desc
      info.resolved_call
  in
  let ast = Ast.untyped_expr ~loc desc in
  match
    Typed_ast.of_ast_expr_with_type_info
      ?source_ty:info.source_ty ~origin:info.origin ?resolved_call
      ~proofs:info.proofs ~semantic_ty:info.semantic_ty ~value_ty:info.value_ty
      ~widening:info.value_slot.value_slot_decision ast
  with
  | Ok typed -> Ok typed
  | Error _ -> error path "decoded expression failed typed-AST validation"

let decode_info_field path value =
  let* info_json = field path "info" value in
  decode_typed_expr_info (path ^ ".info") info_json

let rec decode_expr_items path value =
  let* items_json = array_field path "items" value in
  decode_list (path ^ ".items") decode_typed_expr items_json

and decode_identifier_list path value =
  match value with
  | Lsp_json.Array items -> decode_list path decode_identifier items
  | _ -> error path "expected array"

and decode_typed_dict_entry path value =
  let* key_json = field path "key" value in
  let* key = decode_typed_expr (path ^ ".key") key_json in
  let* value_json = field path "value" value in
  let* value_expr = decode_typed_expr (path ^ ".value") value_json in
  Ok (Typed_ast.ast key, Typed_ast.ast value_expr)

and decode_typed_record_field path value =
  let* name_json = field path "name" value in
  let* name = decode_identifier (path ^ ".name") name_json in
  let* value_json = field path "value" value in
  let* value_expr = decode_typed_expr (path ^ ".value") value_json in
  Ok (name, Typed_ast.ast value_expr)

and decode_typed_match_case path value =
  let* pattern_json = field path "pattern" value in
  let* pattern = decode_pattern (path ^ ".pattern") pattern_json in
  let* body_json = field path "body" value in
  let* body = decode_typed_expr (path ^ ".body") body_json in
  let* loc = span_field path "span" value in
  Ok
    {
      Ast.case_pattern = pattern;
      case_body = Typed_ast.ast body;
      case_loc = loc;
    }

and decode_typed_string_interpolation_part path value =
  let* kind = kind_field path value in
  match kind with
  | "literal" ->
      let* text = string_field path "text" value in
      Ok (Ast.InterpLit text)
  | "expr" ->
      let* expr_json = field path "expr" value in
      let* expr = decode_typed_expr (path ^ ".expr") expr_json in
      Ok (Ast.InterpExpr (Typed_ast.ast expr))
  | _ ->
      error
        (path ^ ".kind")
        ("unsupported typed string interpolation part kind `" ^ kind ^ "`")

and decode_loop_view path loc = function
  | Lsp_json.Null -> Ok None
  | value ->
      let* kind = kind_field path value in
      let* source_json = field path "source" value in
      let* source = decode_typed_expr (path ^ ".source") source_json in
      let* element_type_json = field path "element_type" value in
      let* element_type =
        decode_type (path ^ ".element_type") element_type_json
      in
      let* loop_view_kind, size_arg =
        match kind with
        | "indices" -> Ok (Ast.LoopIndices, None)
        | "enumerate" -> Ok (Ast.LoopEnumerate, None)
        | "enumerate2" -> Ok (Ast.LoopEnumerate2, None)
        | "windows" ->
            let* size = int_field path "size" value in
            if size <= 0 then error (path ^ ".size") "expected positive window size"
            else
              let* size_arg_json = field path "size_arg" value in
              let* size_arg =
                decode_typed_expr (path ^ ".size_arg") size_arg_json
              in
              Ok (Ast.LoopWindows size, Some (Typed_ast.ast size_arg))
        | _ -> error (path ^ ".kind") ("unsupported loop view `" ^ kind ^ "`")
      in
      let loop_type = Ast.TyNamed ("Loop", [ element_type ]) in
      let ast =
        Ast.untyped_expr ~loc
          (Ast.ELoopView
             {
               loop_view_kind;
               loop_view_source = Typed_ast.ast source;
               loop_view_size_arg = size_arg;
               loop_view_elem_type = element_type;
             })
      in
      (match
         Typed_ast.of_ast_expr_with_type_info
           ~context:"decoded loop view" ~origin:(Ast.Synthesized "loop view")
           ~semantic_ty:loop_type ~value_ty:loop_type
           ~widening:(Type_widening_metadata.Keep loop_type) ast
       with
      | Ok typed -> Ok (Some typed)
      | Error _ -> error path "decoded loop view failed typed-AST validation")

and decode_typed_lambda_param path value =
  let* name_json = field path "name" value in
  let* name = decode_identifier (path ^ ".name") name_json in
  let* loc = span_field (path ^ ".name") "span" name_json in
  let* _source_type_json = field path "source_type" value in
  let* param_type_json = field path "param_type" value in
  let* param_type = decode_type (path ^ ".param_type") param_type_json in
  Ok
    {
      Ast.param_name = Some name;
      param_pattern = None;
      param_type = Some param_type;
      param_loc = loc;
    }

and decode_for_binder path value =
  let* kind = kind_field path value in
  match kind with
  | "name" ->
      let* name_json = field path "name" value in
      let* name = decode_identifier (path ^ ".name") name_json in
      Ok (DecodedForNameBinder name)
  | "tuple" ->
      let* names_json = field path "names" value in
      let* names = decode_identifier_list (path ^ ".names") names_json in
      let count = List.length names in
      if count < 2 || count > 4 then
        error path "for tuple binder must have 2-4 names"
      else Ok (DecodedForTupleBinder names)
  | _ -> error path ("unsupported for binder kind `" ^ kind ^ "`")

and channel_elem_type path channel =
  match Typed_ast.semantic_type channel with
  | Ast.TyNamed ("Channel", [ elem_ty ])
  | Ast.TyNamed ("std/channel::Channel", [ elem_ty ])
  | Ast.TyNamed ("std_channel__Channel", [ elem_ty ]) ->
      Ok elem_ty
  | _ -> error path "select receive arm expected Channel[T]"

and decode_typed_select_arm_kind path value =
  let* kind = kind_field path value in
  match kind with
  | "receive" ->
      let* name_json = field path "name" value in
      let* name = decode_identifier (path ^ ".name") name_json in
      let* elem_type_json = field path "elem_type" value in
      let* expected_elem_type =
        decode_type (path ^ ".elem_type") elem_type_json
      in
      let* channel_json = field path "channel" value in
      let* channel = decode_typed_expr (path ^ ".channel") channel_json in
      let* actual_elem_type = channel_elem_type (path ^ ".channel") channel in
      if not (Types.types_equal expected_elem_type actual_elem_type) then
        error (path ^ ".elem_type")
          "select receive element type does not match channel type"
      else
        Ok
          (Ast.SelectRecv
             { select_bind = name; select_channel = Typed_ast.ast channel })
  | "sealed" ->
      let* elem_type_json = field path "elem_type" value in
      let* expected_elem_type =
        decode_type (path ^ ".elem_type") elem_type_json
      in
      let* channel_json = field path "channel" value in
      let* channel = decode_typed_expr (path ^ ".channel") channel_json in
      let* actual_elem_type = channel_elem_type (path ^ ".channel") channel in
      if not (Types.types_equal expected_elem_type actual_elem_type) then
        error (path ^ ".elem_type")
          "select sealed element type does not match channel type"
      else Ok (Ast.SelectSealed (Typed_ast.ast channel))
  | "after" ->
      let* timeout_json = field path "timeout" value in
      let* timeout = decode_typed_expr (path ^ ".timeout") timeout_json in
      Ok (Ast.SelectAfter (Typed_ast.ast timeout))
  | _ -> error path ("unsupported select arm kind `" ^ kind ^ "`")

and decode_typed_select_arm path value =
  let* kind_json = field path "kind" value in
  let* kind = decode_typed_select_arm_kind (path ^ ".kind") kind_json in
  let* body_json = field path "body" value in
  let* body = decode_typed_expr (path ^ ".body") body_json in
  let* loc = span_field path "span" value in
  Ok
    {
      Ast.select_arm_kind = kind;
      select_arm_body = Typed_ast.ast body;
      select_arm_loc = loc;
    }

and decode_typed_with_error_map path value =
  let* name_json = field path "name" value in
  let* name = decode_identifier (path ^ ".name") name_json in
  let* value_json = field path "value" value in
  let* mapped = decode_typed_expr (path ^ ".value") value_json in
  Ok
    {
      Ast.with_error_name = name;
      with_error_value = Typed_ast.ast mapped;
    }

and decode_optional_typed_with_error_map path = function
  | Lsp_json.Null -> Ok None
  | value ->
      let* decoded = decode_typed_with_error_map path value in
      Ok (Some decoded)

and decode_typed_with_binding path value =
  let* name_json = field path "name" value in
  let* name = decode_identifier (path ^ ".name") name_json in
  let* annotation_json = field path "annotation" value in
  let* annotation = decode_optional_type (path ^ ".annotation") annotation_json in
  let* value_json = field path "value" value in
  let* binding_value = decode_typed_expr (path ^ ".value") value_json in
  let* kind_name = string_field path "kind" value in
  let* kind =
    match kind_name with
    | "plain" -> Ok Ast.WithPlain
    | "try" -> Ok Ast.WithTry
    | _ ->
        error (path ^ ".kind")
          ("unsupported with binding kind `" ^ kind_name ^ "`")
  in
  let* error_map_json = field path "error_map" value in
  let* error_map =
    decode_optional_typed_with_error_map (path ^ ".error_map") error_map_json
  in
  Ok
    {
      Ast.with_name = name;
      with_type = annotation;
      with_value = Typed_ast.ast binding_value;
      with_kind = kind;
      with_error_map = error_map;
    }

and decode_typed_concurrent_param path value =
  let* name_json = field path "name" value in
  let* name = decode_identifier (path ^ ".name") name_json in
  let* param_value_json = field path "value" value in
  let* param_value = decode_typed_expr (path ^ ".value") param_value_json in
  Ok (name, param_value)

and positive_int_literal_from_typed_expr path label expr =
  match (Typed_ast.ast expr).Ast.expr_desc with
  | Ast.ELiteral (Ast.LitInt value) ->
      if Int64.compare value 0L <= 0 then
        error path (label ^ " must be positive")
      else if Int64.compare value (Int64.of_int max_int) > 0 then
        error path (label ^ " is too large")
      else Ok (Int64.to_int value)
  | _ -> error path (label ^ " must be an integer literal")

and decode_concurrently_loop_params path values =
  let rec loop index timeout limit = function
    | [] -> (
        match limit with
        | Some loop_limit -> Ok { loop_timeout = timeout; loop_limit }
        | None -> error path "`for ... concurrently(...)` requires `limit: N`")
    | value :: rest ->
        let item_path = Printf.sprintf "%s[%d]" path index in
        let* name, param_value = decode_typed_concurrent_param item_path value in
        (match name with
        | "timeout" -> (
            match timeout with
            | Some _ -> error item_path "duplicate timeout parameter"
            | None -> loop (index + 1) (Some param_value) limit rest)
        | "limit" -> (
            match limit with
            | Some _ -> error item_path "duplicate concurrently limit"
            | None ->
                let* limit_value =
                  positive_int_literal_from_typed_expr (item_path ^ ".value")
                    "concurrently limit" param_value
                in
                loop (index + 1) timeout (Some limit_value) rest)
        | "max_threads" ->
            error item_path
              "use `limit: N` in `concurrently(...)`; `max_threads` is only \
               valid on `concurrent(...)` blocks"
        | _ ->
            error item_path
              ("unknown concurrently parameter `" ^ name
             ^ "` (expected `limit` or `timeout`)"))
  in
  loop 0 None None values

and decode_concurrent_block_params path values =
  let rec loop index timeout max_threads = function
    | [] -> Ok { block_timeout = timeout; block_max_threads = max_threads }
    | value :: rest ->
        let item_path = Printf.sprintf "%s[%d]" path index in
        let* name, param_value = decode_typed_concurrent_param item_path value in
        (match name with
        | "timeout" -> (
            match timeout with
            | Some _ -> error item_path "duplicate timeout parameter"
            | None -> loop (index + 1) (Some param_value) max_threads rest)
        | "max_threads" -> (
            match max_threads with
            | Some _ -> error item_path "duplicate max_threads parameter"
            | None ->
                let* max_threads_value =
                  positive_int_literal_from_typed_expr (item_path ^ ".value")
                    "max_threads" param_value
                in
                loop (index + 1) timeout (Some max_threads_value) rest)
        | "limit" ->
            error item_path
              "use `max_threads: N` on `concurrent(...)` blocks; `limit` is \
               only valid on `for ... concurrently(...)`"
        | _ ->
            error item_path
              ("unknown concurrent parameter `" ^ name
             ^ "` (expected `max_threads` or `timeout`)"))
  in
  loop 0 None None values

and decode_concurrent_binding path value =
  let* binding = decode_typed_expr path value in
  match (Typed_ast.ast binding).Ast.expr_desc with
  | Ast.EConcurrentBind _ -> Ok (Typed_ast.ast binding)
  | _ -> error path "concurrent block binding must be a concurrent_bind node"

and subscript_desc path receiver indices =
  match indices with
  | [ index ] -> Ok (Ast.ESubscript (Typed_ast.ast receiver, Typed_ast.ast index))
  | _ :: _ ->
      Ok
        (Ast.ESubscriptMulti
           (Typed_ast.ast receiver, List.map Typed_ast.ast indices))
  | [] -> error (path ^ ".indices") "subscript requires at least one index"

and decode_optional_typed_expr path = function
  | Lsp_json.Null -> Ok None
  | value ->
      let* expr = decode_typed_expr path value in
      Ok (Some expr)

and decode_typed_expr path value =
  let* kind = kind_field path value in
  let decode_common desc =
    let* loc = span_field path "span" value in
    let* info = decode_info_field path value in
    make_typed_expr path loc info desc
  in
  match kind with
  | "name" ->
      let* name_json = field path "name" value in
      let* name, loc =
        decode_identifier_with_span (path ^ ".name") name_json
      in
      let* info = decode_info_field path value in
      make_typed_expr path loc info (Ast.EIdent name)
  | "int_literal" ->
      let* text = string_field path "value" value in
      decode_common (Ast.ELiteral (int_literal_of_text text))
  | "float_literal" ->
      let* text = string_field path "value" value in
      (match float_of_string_opt text with
      | Some number -> decode_common (Ast.ELiteral (Ast.LitFloat number))
      | None -> error (path ^ ".value") "float literal is not parseable")
  | "string_literal" ->
      let* text = string_field path "value" value in
      decode_common
        (Ast.ELiteral
           (Ast.LitString
              (text, { Ast.sf_multiline = false; sf_raw = false })))
  | "string_interpolation_raw" ->
      let* text = string_field path "value" value in
      let* is_multiline = bool_field path "raw" value in
      decode_common (Ast.EStringInterpRaw (text, is_multiline))
  | "string_interpolation" ->
      let* parts_json = array_field path "parts" value in
      let* parts =
        decode_list (path ^ ".parts") decode_typed_string_interpolation_part
          parts_json
      in
      let* is_multiline = bool_field path "multiline" value in
      decode_common (Ast.EStringInterp (parts, is_multiline))
  | "bool_literal" ->
      let* value_bool = bool_field path "value" value in
      decode_common (Ast.ELiteral (Ast.LitBool value_bool))
  | "char_literal" ->
      let* codepoint = int_field path "value" value in
      decode_common (Ast.ELiteral (Ast.LitChar codepoint))
  | "unary" ->
      let* op_text = string_field path "op" value in
      let* op = decode_unary_op (path ^ ".op") op_text in
      let* inner_json = field path "inner" value in
      let* inner = decode_typed_expr (path ^ ".inner") inner_json in
      decode_common (Ast.EUnary (op, Typed_ast.ast inner))
  | "binary" ->
      let* op_text = string_field path "op" value in
      let* op = decode_binary_op (path ^ ".op") op_text in
      let* left_json = field path "left" value in
      let* left = decode_typed_expr (path ^ ".left") left_json in
      let* right_json = field path "right" value in
      let* right = decode_typed_expr (path ^ ".right") right_json in
      decode_common
        (Ast.EBinary (op, Typed_ast.ast left, Typed_ast.ast right))
  | "logical" ->
      let* op_text = string_field path "op" value in
      let* op = decode_logical_op (path ^ ".op") op_text in
      let* left_json = field path "left" value in
      let* left = decode_typed_expr (path ^ ".left") left_json in
      let* right_json = field path "right" value in
      let* right = decode_typed_expr (path ^ ".right") right_json in
      decode_common
        (Ast.ELogical (op, Typed_ast.ast left, Typed_ast.ast right))
  | "call" ->
      let* callee_json = field path "callee" value in
      let* callee = decode_typed_expr (path ^ ".callee") callee_json in
      let* args_json = array_field path "args" value in
      let* args = decode_list (path ^ ".args") decode_typed_expr args_json in
      decode_common
        (Ast.ECall (Typed_ast.ast callee, List.map Typed_ast.ast args))
  | "tuple" ->
      let* items = decode_expr_items path value in
      decode_common (Ast.ETuple (List.map Typed_ast.ast items))
  | "tuple_destruct" ->
      let* names_json = field path "names" value in
      let* names = decode_identifier_list (path ^ ".names") names_json in
      let* value_json = field path "value" value in
      let* source = decode_typed_expr (path ^ ".value") value_json in
      decode_common (Ast.ETupleDestruct (names, Typed_ast.ast source))
  | "assign" ->
      let* name_json = field path "name" value in
      let* name = decode_identifier (path ^ ".name") name_json in
      let* scope = string_field path "scope" value in
      let* () =
        match scope with
        | "local" | "module" -> Ok ()
        | _ -> error (path ^ ".scope") "unsupported assignment scope"
      in
      let* value_json = field path "value" value in
      let* assigned = decode_typed_expr (path ^ ".value") value_json in
      decode_common (Ast.EAssign (name, Typed_ast.ast assigned))
  | "subscript" ->
      let* receiver_json = field path "receiver" value in
      let* receiver = decode_typed_expr (path ^ ".receiver") receiver_json in
      let* indices_json = array_field path "indices" value in
      let* indices =
        decode_list (path ^ ".indices") decode_typed_expr indices_json
      in
      let* desc = subscript_desc path receiver indices in
      decode_common desc
  | "subscript_assign" ->
      let* _ = field path "target" value in
      let* receiver_json = field path "receiver" value in
      let* receiver = decode_typed_expr (path ^ ".receiver") receiver_json in
      let* indices_json = array_field path "indices" value in
      let* indices =
        decode_list (path ^ ".indices") decode_typed_expr indices_json
      in
      let* value_json = field path "value" value in
      let* assigned = decode_typed_expr (path ^ ".value") value_json in
      decode_common
        (Ast.ESubscriptAssign
           (Typed_ast.ast receiver, List.map Typed_ast.ast indices, Typed_ast.ast assigned))
  | "list" ->
      let* items = decode_expr_items path value in
      decode_common (Ast.EList (List.map Typed_ast.ast items))
  | "vector" ->
      let* items = decode_expr_items path value in
      decode_common (Ast.EVector (List.map Typed_ast.ast items))
  | "dict" ->
      let* entries_json = array_field path "entries" value in
      let* entries =
        decode_list (path ^ ".entries") decode_typed_dict_entry entries_json
      in
      decode_common (Ast.EDict entries)
  | "opaque_into" ->
      let* target_json = field path "target_type" value in
      let* target_type = decode_type (path ^ ".target_type") target_json in
      let* inner_json = field path "inner" value in
      let* inner = decode_typed_expr (path ^ ".inner") inner_json in
      decode_common (Ast.EOpaqueInto (target_type, Typed_ast.ast inner))
  | "opaque_from" ->
      let* source_json = field path "source_type" value in
      let* source_type = decode_type (path ^ ".source_type") source_json in
      let* inner_json = field path "inner" value in
      let* inner = decode_typed_expr (path ^ ".inner") inner_json in
      decode_common (Ast.EOpaqueFrom (source_type, Typed_ast.ast inner))
  | "record" ->
      let* fields_json = array_field path "fields" value in
      let* fields =
        decode_list (path ^ ".fields") decode_typed_record_field fields_json
      in
      decode_common (Ast.ERecord fields)
  | "record_update" ->
      let* receiver_json = field path "receiver" value in
      let* receiver = decode_typed_expr (path ^ ".receiver") receiver_json in
      let* fields_json = array_field path "fields" value in
      let* fields =
        decode_list (path ^ ".fields") decode_typed_record_field fields_json
      in
      decode_common (Ast.ERecordUpdate (Typed_ast.ast receiver, fields))
  | "lambda" ->
      let* is_pure = bool_field path "is_pure" value in
      let* params_json = array_field path "params" value in
      let* params =
        decode_list (path ^ ".params") decode_typed_lambda_param params_json
      in
      let* return_json = field path "return_annotation" value in
      let* return_annotation =
        decode_optional_type (path ^ ".return_annotation") return_json
      in
      let* body_json = field path "body" value in
      let* body = decode_typed_expr (path ^ ".body") body_json in
      let func =
        {
          Ast.func_name = None;
          func_type_params = [];
          func_params = params;
          func_return_type = return_annotation;
          func_body = Ast.FuncBodyExpr (Typed_ast.ast body);
          func_is_pure = is_pure;
          func_is_tailrec = false;
          func_no_copy = false;
          func_debug_only = false;
          func_resource_result_ordinary = false;
          func_dim_constraints = [];
        }
      in
      decode_common (Ast.ELambda func)
  | "block" ->
      let* items = decode_expr_items path value in
      decode_common (Ast.EBlock (List.map Typed_ast.ast items))
  | "if" ->
      let* condition_json = field path "condition" value in
      let* condition =
        decode_typed_expr (path ^ ".condition") condition_json
      in
      let* then_json = field path "then" value in
      let* then_branch = decode_typed_expr (path ^ ".then") then_json in
      let* else_json = field path "else" value in
      let* else_branch =
        decode_optional_typed_expr (path ^ ".else") else_json
      in
      decode_common
        (Ast.EIf
           ( Typed_ast.ast condition,
             Typed_ast.ast then_branch,
             Option.map Typed_ast.ast else_branch ))
  | "match" ->
      let* scrutinee_json = field path "scrutinee" value in
      let* scrutinee = decode_typed_expr (path ^ ".scrutinee") scrutinee_json in
      let* cases_json = array_field path "cases" value in
      let* cases =
        decode_list (path ^ ".cases") decode_typed_match_case cases_json
      in
      decode_common (Ast.EMatch (Typed_ast.ast scrutinee, cases))
  | "select" ->
      let* arms_json = array_field path "arms" value in
      let* arms =
        decode_list (path ^ ".arms") decode_typed_select_arm arms_json
      in
      decode_common (Ast.ESelect arms)
  | "while" ->
      let* condition_json = field path "condition" value in
      let* condition =
        decode_typed_expr (path ^ ".condition") condition_json
      in
      let* body_json = field path "body" value in
      let* body = decode_typed_expr (path ^ ".body") body_json in
      decode_common (Ast.EWhile (Typed_ast.ast condition, Typed_ast.ast body))
  | "for" ->
      let* binder_json = field path "binder" value in
      let* binder = decode_for_binder (path ^ ".binder") binder_json in
      let* iterable_json = field path "iterable" value in
      let* iterable = decode_typed_expr (path ^ ".iterable") iterable_json in
      let* loop_view_json = optional_field path "loop_view" value in
      let* loop_view =
        match loop_view_json with
        | Some loop_view_json ->
            decode_loop_view (path ^ ".loop_view") (Typed_ast.loc iterable)
              loop_view_json
        | None -> Ok None
      in
      let* body_json = field path "body" value in
      let* body = decode_typed_expr (path ^ ".body") body_json in
      let iterable = Option.value ~default:iterable loop_view in
      let desc =
        match binder with
        | DecodedForNameBinder name ->
            Ast.EFor (name, Typed_ast.ast iterable, Typed_ast.ast body)
        | DecodedForTupleBinder names ->
            Ast.EForTuple (names, Typed_ast.ast iterable, Typed_ast.ast body)
      in
      decode_common desc
  | "concurrent_for" ->
      let* name_json = field path "name" value in
      let* name = decode_identifier (path ^ ".name") name_json in
      let* iterable_json = field path "iterable" value in
      let* iterable = decode_typed_expr (path ^ ".iterable") iterable_json in
      let* params_json = array_field path "params" value in
      let* params =
        decode_concurrently_loop_params (path ^ ".params") params_json
      in
      let* body_json = field path "body" value in
      let* body = decode_typed_expr (path ^ ".body") body_json in
      decode_common
        (Ast.EConcurrentlyLoop
           ( name,
             Typed_ast.ast iterable,
             Typed_ast.ast body,
             Option.map Typed_ast.ast params.loop_timeout,
             Ast.ConcurrentlyLoopLimit params.loop_limit ))
  | "concurrent_bind" ->
      let* name_json = field path "name" value in
      let* name = decode_identifier (path ^ ".name") name_json in
      let* annotation_json = field path "annotation" value in
      let* annotation = decode_optional_type (path ^ ".annotation") annotation_json in
      let* value_json = field path "value" value in
      let* binding_value = decode_typed_expr (path ^ ".value") value_json in
      decode_common
        (Ast.EConcurrentBind (name, annotation, Typed_ast.ast binding_value))
  | "concurrent_block" ->
      let* params_json = array_field path "params" value in
      let* params = decode_concurrent_block_params (path ^ ".params") params_json in
      let* bindings_json = array_field path "bindings" value in
      let* bindings =
        decode_list (path ^ ".bindings") decode_concurrent_binding bindings_json
      in
      decode_common
        (Ast.EConcurrent
           ( bindings,
             Option.map Typed_ast.ast params.block_timeout,
             params.block_max_threads ))
  | "detach" ->
      let* body_json = field path "body" value in
      let* body = decode_typed_expr (path ^ ".body") body_json in
      decode_common (Ast.EDetach (Typed_ast.ast body))
  | "range" ->
      let* start_json = field path "start" value in
      let* start_expr = decode_typed_expr (path ^ ".start") start_json in
      let* end_json = field path "end" value in
      let* end_expr = decode_typed_expr (path ^ ".end") end_json in
      decode_common (Ast.ERange (Typed_ast.ast start_expr, Typed_ast.ast end_expr))
  | "field_access" ->
      let* receiver_json = field path "receiver" value in
      let* receiver = decode_typed_expr (path ^ ".receiver") receiver_json in
      let* field_json = field path "field" value in
      let* field_name = decode_identifier (path ^ ".field") field_json in
      decode_common (Ast.EFieldAccess (Typed_ast.ast receiver, field_name))
  | "ascription" ->
      let* inner_json = field path "inner" value in
      let* inner = decode_typed_expr (path ^ ".inner") inner_json in
      let* target_json = field path "target_type" value in
      let* target_type = decode_type (path ^ ".target_type") target_json in
      decode_common (Ast.EAscription (Typed_ast.ast inner, target_type))
  | "with" ->
      let* binding_json = field path "binding" value in
      let* binding = decode_typed_with_binding (path ^ ".binding") binding_json in
      let* body_json = field path "body" value in
      let* body = decode_typed_expr (path ^ ".body") body_json in
      decode_common (Ast.EWith (binding, Typed_ast.ast body))
  | "debug_block" ->
      let* body_json = field path "body" value in
      let* body = decode_typed_expr (path ^ ".body") body_json in
      decode_common (Ast.EDebugBlock [ Typed_ast.ast body ])
  | "var_decl" ->
      let* payload_json = field path "payload" value in
      let* name_json = field (path ^ ".payload") "name" payload_json in
      let* name = decode_identifier (path ^ ".payload.name") name_json in
      let* annotation_json = field (path ^ ".payload") "annotation" payload_json in
      let* annotation =
        decode_optional_type (path ^ ".payload.annotation") annotation_json
      in
      let* initializer_json = field (path ^ ".payload") "initializer" payload_json in
      let* init_expr =
        decode_typed_expr (path ^ ".payload.initializer") initializer_json
      in
      let* is_mutable = bool_field (path ^ ".payload") "is_mutable" payload_json in
      decode_common
        (Ast.EVarDecl (name, annotation, Typed_ast.ast init_expr, is_mutable))
  | "question_bind" ->
      let* name_json = field path "name" value in
      let* name = decode_identifier (path ^ ".name") name_json in
      let* annotation_json = field path "annotation" value in
      let* annotation = decode_optional_type (path ^ ".annotation") annotation_json in
      let* value_json = field path "value" value in
      let* value_expr = decode_typed_expr (path ^ ".value") value_json in
      decode_common (Ast.EQuestionBind (name, annotation, Typed_ast.ast value_expr))
  | "void" -> decode_common Ast.EVoid
  | "break" -> decode_common Ast.EBreak
  | "continue" -> decode_common Ast.EContinue
  | "builtin" ->
      let* name_json = field path "name" value in
      let* name =
        match name_json with
        | Lsp_json.Null -> Ok None
        | Lsp_json.String text -> Ok (Some text)
        | _ -> error (path ^ ".name") "expected string or null"
      in
      decode_common (Ast.EBuiltin name)
  | "unsupported" ->
      let* label = string_field path "label" value in
      error path ("unsupported typed expression `" ^ label ^ "`")
  | _ ->
      error
        (path ^ ".kind")
        ("typed expression kind `" ^ kind ^ "` is not decoded yet")

let params_with_semantic_types path params param_types =
  let rec loop acc params param_types =
    match (params, param_types) with
    | [], [] -> Ok (List.rev acc)
    | param :: rest, typ :: type_rest ->
        loop ({ param with Ast.param_type = Some typ } :: acc) rest type_rest
    | [], _ :: _ | _ :: _, [] ->
        error path "function parameter metadata count must match source params"
  in
  loop [] params param_types

let function_body_from_typed_body source_func = function
  | Some body -> Ast.FuncBodyExpr (Typed_ast.ast body)
  | None -> source_func.Ast.func_body

let canonical_function_from_typed_info path source_func effective_type_params
    param_types semantic_return_type typed_body =
  let* params =
    params_with_semantic_types (path ^ ".param_types")
      source_func.Ast.func_params param_types
  in
  Ok
    {
      source_func with
      Ast.func_type_params = effective_type_params;
      Ast.func_params = params;
      func_return_type = Some semantic_return_type;
      func_body = function_body_from_typed_body source_func typed_body;
    }

let validate_function_bridge_metadata path source_return_type
    semantic_return_type param_types callable_id typed_func =
  let info = Typed_ast.func_info typed_func in
  if not (optional_types_equal info.source_return_ty source_return_type) then
    error (path ^ ".source_return_type")
      "function source return type metadata is incoherent"
  else if
    not (Types.types_equal (Typed_ast.func_semantic_return_type typed_func)
           semantic_return_type)
  then
    error (path ^ ".semantic_return_type")
      "function semantic return type metadata is incoherent"
  else if not (Typed_ast.func_callable_id typed_func = callable_id) then
    error (path ^ ".callable_id") "function callable id was not preserved"
  else
    let semantic_params =
      List.map
        (fun (param : Typed_ast.func_param_info) -> param.semantic_param_ty)
        (Typed_ast.func_param_infos typed_func)
    in
    if types_equal_list semantic_params param_types then Ok ()
    else error (path ^ ".param_types") "function parameter metadata is incoherent"

let decode_typed_function_info path value =
  let* decl_json = field path "decl" value in
  let* source_func = decode_parsed_function (path ^ ".decl") decl_json in
  let* loc = span_field (path ^ ".decl") "span" decl_json in
  let* doc = option_string_field (path ^ ".decl") "doc" decl_json in
  let* callable_id_json = field path "callable_id" value in
  let* callable_id = option_int_value (path ^ ".callable_id") callable_id_json in
  let decode_effective_type_param param_path param_json =
    let* name = string_field param_path "name" param_json in
    let* bounds_json = array_field param_path "bounds" param_json in
    let* bounds =
      decode_list (param_path ^ ".bounds") string_value bounds_json
    in
    Ok (Ast.make_type_param name bounds)
  in
  let* effective_type_params_json =
    array_field path "effective_type_params" value
  in
  let* effective_type_params =
    decode_list (path ^ ".effective_type_params") decode_effective_type_param
      effective_type_params_json
  in
  let* param_types_json = array_field path "param_types" value in
  let* param_types =
    decode_list (path ^ ".param_types") decode_type param_types_json
  in
  let* source_return_json = field path "source_return_type" value in
  let* source_return_type =
    decode_optional_type (path ^ ".source_return_type") source_return_json
  in
  let* semantic_return_json = field path "semantic_return_type" value in
  let* semantic_return_type =
    decode_type (path ^ ".semantic_return_type") semantic_return_json
  in
  let* body_json = field path "body" value in
  let* typed_body = decode_optional_typed_expr (path ^ ".body") body_json in
  let* canonical_func =
    canonical_function_from_typed_info path source_func effective_type_params
      param_types semantic_return_type typed_body
  in
  let source_decl =
    { Ast.decl_desc = Ast.DFunc source_func; decl_loc = loc; decl_doc = doc }
  in
  let typed_decl =
    { Ast.decl_desc = Ast.DFunc canonical_func; decl_loc = loc; decl_doc = doc }
  in
  let callable_id_of_func ~name ~loc:_ =
    match source_func.Ast.func_name with
    | Some source_name when String.equal source_name name -> callable_id
    | _ -> None
  in
  match
    Typed_ast.of_ast_program_with_sources ~callable_id_of_func
      ~source_program:[ source_decl ] [ typed_decl ]
  with
  | Ok program -> (
      match Typed_ast.program_decls program with
      | [ decl ] -> (
          match Typed_ast.decl_view decl with
          | Typed_ast.DeclFunction typed_func ->
              let* () =
                validate_function_bridge_metadata path source_return_type
                  semantic_return_type param_types callable_id typed_func
              in
              Ok decl
          | _ -> error path "decoded declaration was not a function")
      | _ -> error path "decoded function produced unexpected declaration count")
  | Error _ -> error path "decoded function failed typed-AST validation"

let decode_typed_function_decl path value =
  let* decl = decode_typed_function_info path value in
  match Typed_ast.decl_view decl with
  | Typed_ast.DeclFunction func -> Ok func
  | _ -> error path "decoded typed function info did not produce a function"

let func_param_infos_equal left right =
  let rec loop left right =
    match (left, right) with
    | [], [] -> true
    | (left : Typed_ast.func_param_info) :: left_rest,
      (right : Typed_ast.func_param_info) :: right_rest ->
        left.param_name = right.param_name
        && Types.types_equal left.source_param_ty right.source_param_ty
        && Types.types_equal left.semantic_param_ty right.semantic_param_ty
        && loop left_rest right_rest
    | _ -> false
  in
  loop left right

let validate_typed_function_decl_metadata path expected actual =
  let expected_info = Typed_ast.func_info expected in
  let actual_info = Typed_ast.func_info actual in
  if
    not
      (optional_types_equal expected_info.source_return_ty
         actual_info.source_return_ty)
  then
    error (path ^ ".source_return_type")
      "function source return type was not preserved"
  else if
    not
      (Types.types_equal expected_info.semantic_return_ty
         actual_info.semantic_return_ty)
  then
    error (path ^ ".semantic_return_type")
      "function semantic return type was not preserved"
  else if not (expected_info.callable_id = actual_info.callable_id) then
    error (path ^ ".callable_id") "function callable id was not preserved"
  else if
    not
      (func_param_infos_equal expected_info.param_infos actual_info.param_infos)
  then error (path ^ ".param_types") "function parameter metadata was not preserved"
  else Ok ()

type decoded_record_field_info = {
  field_name : string;
  source_field_ty : Ast.type_expr;
  semantic_field_ty : Ast.type_expr;
}

let decode_record_field_info path value =
  let* field_name = string_field path "name" value in
  let* source_json = field path "source_type" value in
  let* source_field_ty = decode_type (path ^ ".source_type") source_json in
  let* semantic_json = field path "semantic_type" value in
  let* semantic_field_ty = decode_type (path ^ ".semantic_type") semantic_json in
  Ok { field_name; source_field_ty; semantic_field_ty }

let record_fields_with_semantic_types path source_fields field_infos =
  let rec loop acc source_fields field_infos =
    match (source_fields, field_infos) with
    | [], [] -> Ok (List.rev acc)
    | source :: source_rest, info :: info_rest ->
        if not (String.equal source.Ast.field_name info.field_name) then
          error path "record field metadata order must match source fields"
        else if not (Types.types_equal source.field_type info.source_field_ty) then
          error (path ^ ".source_type")
            "record source field type metadata is incoherent"
        else
          loop
            ({ source with Ast.field_type = info.semantic_field_ty } :: acc)
            source_rest info_rest
    | [], _ :: _ | _ :: _, [] ->
        error path "record field metadata count must match source fields"
  in
  loop [] source_fields field_infos

let validate_record_bridge_metadata path field_infos typed_record =
  let actual = Typed_ast.record_field_infos typed_record in
  let expected_len = List.length field_infos in
  let actual_len = List.length actual in
  if expected_len <> actual_len then
    error path "record field metadata count was not preserved"
  else
    let rec loop index
        (expected_fields : decoded_record_field_info list)
        (actual_fields : Typed_ast.record_field_info list) =
      match (expected_fields, actual_fields) with
      | [], [] -> Ok ()
      | expected :: expected_rest, actual :: actual_rest ->
          let item_path = Printf.sprintf "%s.fields[%d]" path index in
          if not (String.equal expected.field_name actual.field_name) then
            error (item_path ^ ".name") "record field name was not preserved"
          else if
            not
              (Types.types_equal expected.source_field_ty actual.source_field_ty)
          then
            error (item_path ^ ".source_type")
              "record source type was not preserved"
          else if
            not
              (Types.types_equal expected.semantic_field_ty
                 actual.semantic_field_ty)
          then
            error (item_path ^ ".semantic_type")
              "record semantic type was not preserved"
          else loop (index + 1) expected_rest actual_rest
      | _ -> error path "record field metadata count was not preserved"
    in
    loop 0 field_infos actual

let decode_typed_record_info path value =
  let* decl_json = field path "decl" value in
  let* source_decl = decode_parsed_record_decl (path ^ ".decl") decl_json in
  let* fields_json = array_field path "fields" value in
  let* field_infos =
    decode_list (path ^ ".fields") decode_record_field_info fields_json
  in
  match source_decl.Ast.decl_desc with
  | Ast.DRecord source_record -> (
      let* fields =
        record_fields_with_semantic_types (path ^ ".fields")
          source_record.record_fields field_infos
      in
      let typed_record = { source_record with Ast.record_fields = fields } in
      let typed_decl =
        { source_decl with Ast.decl_desc = Ast.DRecord typed_record }
      in
      match
        Typed_ast.of_ast_program_with_sources ~source_program:[ source_decl ]
          [ typed_decl ]
      with
      | Ok program -> (
          match Typed_ast.program_decls program with
          | [ decl ] -> (
              match Typed_ast.decl_view decl with
              | Typed_ast.DeclRecord record ->
                  let* () =
                    validate_record_bridge_metadata path field_infos record
                  in
                  Ok decl
              | _ -> error path "decoded declaration was not a record")
          | _ -> error path "decoded record produced unexpected declaration count")
      | Error _ -> error path "decoded record failed typed-AST validation")
  | _ -> error path "decoded parsed declaration was not a record"

let validate_type_alias_bridge_metadata path source_target_type
    semantic_target_type typed_alias =
  let info = Typed_ast.type_alias_info typed_alias in
  if not (Types.types_equal info.source_target_ty source_target_type) then
    error (path ^ ".source_target_type")
      "type alias source target metadata is incoherent"
  else if
    not
      (Types.types_equal (Typed_ast.type_alias_semantic_target_type typed_alias)
         semantic_target_type)
  then
    error (path ^ ".semantic_target_type")
      "type alias semantic target metadata is incoherent"
  else Ok ()

let decode_typed_type_alias_info path value =
  let* decl_json = field path "decl" value in
  let* source_decl = decode_parsed_type_alias_decl (path ^ ".decl") decl_json in
  let* source_target_json = field path "source_target_type" value in
  let* source_target_type =
    decode_type (path ^ ".source_target_type") source_target_json
  in
  let* semantic_target_json = field path "semantic_target_type" value in
  let* semantic_target_type =
    decode_type (path ^ ".semantic_target_type") semantic_target_json
  in
  match source_decl.Ast.decl_desc with
  | Ast.DTypeAlias source_alias ->
      if not (Types.types_equal source_alias.alias_target source_target_type) then
        error (path ^ ".source_target_type")
          "type alias source target metadata must match source declaration"
      else
        let typed_alias =
          { source_alias with Ast.alias_target = semantic_target_type }
        in
        let typed_decl =
          { source_decl with Ast.decl_desc = Ast.DTypeAlias typed_alias }
        in
        (match
           Typed_ast.of_ast_program_with_sources ~source_program:[ source_decl ]
             [ typed_decl ]
         with
        | Ok program -> (
            match Typed_ast.program_decls program with
            | [ decl ] -> (
                match Typed_ast.decl_view decl with
                | Typed_ast.DeclTypeAlias alias ->
                    let* () =
                      validate_type_alias_bridge_metadata path source_target_type
                        semantic_target_type alias
                    in
                    Ok decl
                | _ -> error path "decoded declaration was not a type alias")
            | _ ->
                error path
                  "decoded type alias produced unexpected declaration count")
        | Error _ -> error path "decoded type alias failed typed-AST validation")
  | _ -> error path "decoded parsed declaration was not a type alias"

type decoded_union_variant_info = {
  union_variant_name : string;
  union_variant_fields : Ast.type_expr list;
  union_variant_tag : int;
  union_variant_def_id : int option;
}

let decode_union_variant_info path value =
  let* name = string_field path "name" value in
  let* fields_json = array_field path "fields" value in
  let* fields = decode_list (path ^ ".fields") decode_type fields_json in
  let* tag = int_field path "tag" value in
  let* def_id_json = field path "def_id" value in
  let* def_id = option_int_value (path ^ ".def_id") def_id_json in
  Ok
    {
      union_variant_name = name;
      union_variant_fields = fields;
      union_variant_tag = tag;
      union_variant_def_id = def_id;
    }

let union_variants_with_metadata path source_variants variant_infos =
  let rec loop acc index source_variants variant_infos =
    match (source_variants, variant_infos) with
    | [], [] -> Ok (List.rev acc)
    | source :: source_rest, info :: info_rest ->
        let item_path = Printf.sprintf "%s[%d]" path index in
        if not (String.equal source.Ast.variant_name info.union_variant_name)
        then
          error (item_path ^ ".name")
            "union variant metadata order must match source variants"
        else if
          List.length source.variant_fields
          <> List.length info.union_variant_fields
        then
          error (item_path ^ ".fields")
            "union variant metadata field count must match source variant"
        else if info.union_variant_tag <> index then
          error (item_path ^ ".tag")
            "union variant tag must match declaration order"
        else
          let typed_variant =
            {
              source with
              Ast.variant_fields = info.union_variant_fields;
              variant_tag = info.union_variant_tag;
              variant_def_id = info.union_variant_def_id;
            }
          in
          loop (typed_variant :: acc) (index + 1) source_rest info_rest
    | [], _ :: _ | _ :: _, [] ->
        error path "union variant metadata count must match source variants"
  in
  loop [] 0 source_variants variant_infos

let validate_union_bridge_metadata path variant_infos typed_type_decl =
  let actual = typed_type_decl.Ast.type_variants in
  let rec loop index expected actual =
    match (expected, actual) with
    | [], [] -> Ok ()
    | expected :: expected_rest, actual :: actual_rest ->
        let item_path = Printf.sprintf "%s.variants[%d]" path index in
        if not (String.equal expected.union_variant_name actual.Ast.variant_name)
        then
          error (item_path ^ ".name") "union variant name was not preserved"
        else if
          not
            (types_equal_list expected.union_variant_fields
               actual.variant_fields)
        then
          error (item_path ^ ".fields")
            "union variant fields were not preserved"
        else if expected.union_variant_tag <> actual.variant_tag then
          error (item_path ^ ".tag") "union variant tag was not preserved"
        else if expected.union_variant_def_id <> actual.variant_def_id then
          error (item_path ^ ".def_id") "union variant def id was not preserved"
        else loop (index + 1) expected_rest actual_rest
    | _ -> error path "union variant metadata count was not preserved"
  in
  loop 0 variant_infos actual

let decode_typed_union_info path value =
  let* decl_json = field path "decl" value in
  let* source_decl = decode_parsed_union_decl (path ^ ".decl") decl_json in
  let* variants_json = array_field path "variants" value in
  let* variant_infos =
    decode_list (path ^ ".variants") decode_union_variant_info variants_json
  in
  match source_decl.Ast.decl_desc with
  | Ast.DType source_type_decl -> (
      let* variants =
        union_variants_with_metadata (path ^ ".variants")
          source_type_decl.type_variants variant_infos
      in
      let typed_type_decl =
        { source_type_decl with Ast.type_variants = variants }
      in
      let typed_decl =
        { source_decl with Ast.decl_desc = Ast.DType typed_type_decl }
      in
      match
        Typed_ast.of_ast_program_with_sources ~source_program:[ source_decl ]
          [ typed_decl ]
      with
      | Ok program -> (
          match Typed_ast.program_decls program with
          | [ decl ] -> (
              match (Typed_ast.decl_ast decl).Ast.decl_desc with
              | Ast.DType decoded_type_decl ->
                  let* () =
                    validate_union_bridge_metadata path variant_infos
                      decoded_type_decl
                  in
                  Ok decl
              | _ -> error path "decoded declaration was not a union")
          | _ -> error path "decoded union produced unexpected declaration count")
      | Error _ -> error path "decoded union failed typed-AST validation")
  | _ -> error path "decoded parsed declaration was not a union"

let function_name_matches name func =
  match (Typed_ast.func_ast func).Ast.func_name with
  | Some func_name -> String.equal func_name name
  | None -> false

let callable_id_from_typed_methods methods name =
  match List.find_opt (function_name_matches name) methods with
  | Some func -> Typed_ast.func_callable_id func
  | None -> None

let validate_impl_bridge_metadata path for_type expected_methods typed_impl =
  let actual_impl = Typed_ast.impl_ast typed_impl in
  if not (Types.types_equal actual_impl.impl_for_type for_type) then
    error (path ^ ".for_type") "impl target type was not preserved"
  else
    let rec loop index expected actual =
      match (expected, actual) with
      | [], [] -> Ok ()
      | expected_func :: expected_rest, actual_func :: actual_rest ->
          let item_path = Printf.sprintf "%s.methods[%d]" path index in
          let expected_name = (Typed_ast.func_ast expected_func).Ast.func_name in
          let actual_name = (Typed_ast.func_ast actual_func).Ast.func_name in
          if expected_name <> actual_name then
            error (item_path ^ ".decl.name") "impl method name was not preserved"
          else
            let* () =
              validate_typed_function_decl_metadata item_path expected_func
                actual_func
            in
            loop (index + 1) expected_rest actual_rest
      | _ -> error (path ^ ".methods") "impl method count was not preserved"
    in
    loop 0 expected_methods (Typed_ast.impl_methods typed_impl)

let decode_typed_impl_info path value =
  let* decl_json = field path "decl" value in
  let* source_decl = decode_parsed_impl_decl (path ^ ".decl") decl_json in
  let* for_type_json = field path "for_type" value in
  let* for_type = decode_type (path ^ ".for_type") for_type_json in
  let* methods_json = array_field path "methods" value in
  let* typed_methods =
    decode_list (path ^ ".methods") decode_typed_function_decl methods_json
  in
  match source_decl.Ast.decl_desc with
  | Ast.DImpl source_impl -> (
      let canonical_impl =
        {
          source_impl with
          Ast.impl_for_type = for_type;
          impl_methods = List.map Typed_ast.func_ast typed_methods;
        }
      in
      let typed_decl =
        { source_decl with Ast.decl_desc = Ast.DImpl canonical_impl }
      in
      let callable_id_of_func ~name ~loc:_ =
        callable_id_from_typed_methods typed_methods name
      in
      match
        Typed_ast.of_ast_program_with_sources ~callable_id_of_func
          ~source_program:[ source_decl ] [ typed_decl ]
      with
      | Ok program -> (
          match Typed_ast.program_decls program with
          | [ decl ] -> (
              match Typed_ast.decl_view decl with
              | Typed_ast.DeclImpl impl ->
                  let* () =
                    validate_impl_bridge_metadata path for_type typed_methods
                      impl
                  in
                  Ok decl
              | _ -> error path "decoded declaration was not an impl")
          | _ -> error path "decoded impl produced unexpected declaration count")
      | Error _ -> error path "decoded impl failed typed-AST validation")
  | _ -> error path "decoded parsed declaration was not an impl"

let decode_typed_global_var_info path value =
  let* decl_json = field path "decl" value in
  let decl_path = path ^ ".decl" in
  let* source_decl = decode_parsed_var_decl decl_path decl_json in
  let* source_var =
    match source_decl.Ast.decl_desc with
    | Ast.DVar var -> Ok var
    | _ -> error decl_path "decoded parsed declaration was not a global variable"
  in
  let source_type = source_var.Ast.var_type in
  let* binding_type_json = field path "binding_type" value in
  let* binding_type = decode_type (path ^ ".binding_type") binding_type_json in
  let* source_type_json = field path "source_type" value in
  let* typed_source_type =
    decode_optional_type (path ^ ".source_type") source_type_json
  in
  let* value_json = field path "value" value in
  let* typed_value = decode_typed_expr (path ^ ".value") value_json in
  let source_types_match =
    match (source_type, typed_source_type) with
    | None, None -> true
    | Some left, Some right -> Types.types_equal left right
    | _ -> false
  in
  if not source_types_match then
    error path "global variable source type metadata must match source decl"
  else
    let ast_var =
      {
        source_var with
        var_type = Some binding_type;
        var_value = Typed_ast.ast typed_value;
      }
    in
    let ast_decl =
      {
        Ast.decl_desc = Ast.DVar ast_var;
        decl_loc = source_decl.decl_loc;
        decl_doc = source_decl.decl_doc;
      }
    in
    match Typed_ast.of_ast_var_decl_with_source ~source_var ast_var with
    | Ok typed_var ->
        if Types.types_equal (Typed_ast.var_binding_type typed_var) binding_type
        then Ok (Typed_ast.make_var_decl ast_decl typed_var)
        else error path "global variable binding type metadata is incoherent"
    | Error _ -> error path "decoded global variable failed typed-AST validation"

let rec decode_typed_decl_group path value =
  let* kind = kind_field path value in
  match kind with
  | "function" ->
      let* info_json = field path "info" value in
      let* decl = decode_typed_function_info (path ^ ".info") info_json in
      Ok [ decl ]
  | "global_var" ->
      let* info_json = field path "info" value in
      let* decl = decode_typed_global_var_info (path ^ ".info") info_json in
      Ok [ decl ]
  | "record" ->
      let* info_json = field path "info" value in
      let* decl = decode_typed_record_info (path ^ ".info") info_json in
      Ok [ decl ]
  | "type_alias" ->
      let* info_json = field path "info" value in
      let* decl = decode_typed_type_alias_info (path ^ ".info") info_json in
      Ok [ decl ]
  | "union" ->
      let* info_json = field path "info" value in
      let* decl = decode_typed_union_info (path ^ ".info") info_json in
      Ok [ decl ]
  | "impl" ->
      let* info_json = field path "info" value in
      let* decl = decode_typed_impl_info (path ^ ".info") info_json in
      Ok [ decl ]
  | "parsed" ->
      let* decl_json = field path "decl" value in
      decode_parsed_typed_decl_group (path ^ ".decl") decl_json
  | "private" ->
      let* inner_json = field path "inner" value in
      let* inner_group = decode_typed_decl_group (path ^ ".inner") inner_json in
      let* inner = expect_single_typed_decl (path ^ ".inner") inner_group in
      let ast_decl =
        {
          Ast.decl_desc = Ast.DPrivate (Typed_ast.decl_ast inner);
          decl_loc = (Typed_ast.decl_ast inner).Ast.decl_loc;
          decl_doc = None;
        }
      in
      Ok [ Typed_ast.make_private_decl ast_decl inner ]
  | _ ->
      error
        (path ^ ".kind")
        ("typed declaration kind `" ^ kind ^ "` is not decoded yet")

let decode_typed_program value =
  let path = "$" in
  let* kind = kind_field path value in
  if not (String.equal kind "typed_program") then
    error path ("expected typed_program, got `" ^ kind ^ "`")
  else
    let* _ = field path "source" value in
    let* diagnostics = array_field path "diagnostics" value in
    match diagnostics with
    | _ :: _ ->
        error (path ^ ".diagnostics")
          "typed program diagnostics must be handled before decoding"
    | [] ->
        let* decls_json = array_field path "decls" value in
        let* decl_groups =
          decode_list (path ^ ".decls") decode_typed_decl_group decls_json
        in
        Ok (Typed_ast.make_program (List.concat decl_groups))
