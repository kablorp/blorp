(** Strict structural decoder for the Blorp-owned post-tuple-SROA Core handoff.

    This is deliberately separate from the late backend projection in
    [Core_emit_blorp_c]. The semantic-middle worker performs the post-debug,
    post-desugar, post-mono, post-match, post-trait-resolution, and
    post-resolution, post-std-inline, post-tailrec, and post-tuple-SROA
    semantic invariant checks immediately after this structural decode. The
    accepted expression set includes semantic decision trees created by match
    compilation and the non-owning constructor test synthesized before that
    stage. It rejects raw matches and ownership-bearing backend forms so a pass
    cannot accidentally run twice or lose a release policy during projection. *)

type decode_error = { path : string; message : string }

type decoded_program = {
  core : Core.core_program;
  foreign_includes : string list;
  union_payload_storage : (string * Codegen_types.union_payload_storage) list;
}

let ( let* ) = Result.bind

let error path message = Error { path; message }
let path_field path name = path ^ "." ^ name
let path_index path index = Printf.sprintf "%s[%d]" path index

let field path name = function
  | Lsp_json.Object fields -> (
      match List.assoc_opt name fields with
      | Some value -> Ok value
      | None -> error (path_field path name) "missing required field")
  | _ -> error path "expected object"

let string path = function
  | Lsp_json.String value -> Ok value
  | _ -> error path "expected string"

let int path = function
  | Lsp_json.Int value -> Ok value
  | _ -> error path "expected integer"

let exact_int64 path = function
  | Lsp_json.Int value -> Ok (Int64.of_int value)
  | Lsp_json.String value -> (
      match Int64.of_string_opt value with
      | Some value -> Ok value
      | None -> error path "expected signed 64-bit integer text")
  | _ -> error path "expected integer or signed 64-bit integer text"

let bool path = function
  | Lsp_json.Bool value -> Ok value
  | _ -> error path "expected boolean"

let array path = function
  | Lsp_json.Array values -> Ok values
  | _ -> error path "expected array"

let string_field path name value =
  let* value = field path name value in
  string (path_field path name) value

let int_field path name value =
  let* value = field path name value in
  int (path_field path name) value

let bool_field path name value =
  let* value = field path name value in
  bool (path_field path name) value

let array_field path name value =
  let* value = field path name value in
  array (path_field path name) value

let kind path value = string_field path "kind" value

let optional decode path = function
  | Lsp_json.Null -> Ok None
  | value ->
      let* value = decode path value in
      Ok (Some value)

let rec decode_list decode path index = function
  | [] -> Ok []
  | item :: rest ->
      let* item = decode (path_index path index) item in
      let* rest = decode_list decode path (index + 1) rest in
      Ok (item :: rest)

let list_field decode path name value =
  let* values = array_field path name value in
  decode_list decode (path_field path name) 0 values

let string_list_field path name value = list_field string path name value

let optional_int_field path name value =
  let* value = field path name value in
  optional int (path_field path name) value

let optional_string_field path name value =
  let* value = field path name value in
  optional string (path_field path name) value

let decode_loc path value =
  let* tag = kind path value in
  match tag with
  | "synthetic" -> Ok Ast.dummy_loc
  | "known" ->
      let* file = string_field path "file" value in
      let* line = int_field path "line" value in
      let* column = int_field path "column" value in
      let* end_line = int_field path "end_line" value in
      let* end_column = int_field path "end_column" value in
      Ok { Ast.line; column; end_line; end_column; loc_file = Some file }
  | _ -> error (path_field path "kind") ("unsupported location kind `" ^ tag ^ "`")

let decode_loc_field path name value =
  let* value = field path name value in
  decode_loc (path_field path name) value

let decode_var path value =
  let* vname = string_field path "name" value in
  let* vuniq = int_field path "uniq" value in
  let* vdef_id = optional_int_field path "def_id" value in
  Ok { Core.vname; vuniq; vdef_id }

let decode_var_field path name value =
  let* value = field path name value in
  decode_var (path_field path name) value

let type_param name = Ast.make_type_param name []

let decode_type_param path value =
  let* name = string_field path "name" value in
  let* bounds = string_list_field path "bounds" value in
  Ok (Ast.make_type_param name bounds)

let rec decode_type path value =
  let* tag = kind path value in
  match tag with
  | "void" -> Ok (Ast.TyNamed ("Void", []))
  | "named" ->
      let* name = string_field path "name" value in
      let* args = list_field decode_type path "args" value in
      Ok (Ast.TyNamed (name, args))
  | "type_parameter" ->
      let* name = string_field path "name" value in
      Ok (Ast.TyVar name)
  | "self" -> Ok Ast.TySelf
  | "function" ->
      let* is_pure = bool_field path "pure" value in
      let* params = list_field decode_type path "params" value in
      let* return = decode_type_field path "return_type" value in
      Ok (Ast.TyFunc { params; return; is_pure })
  | "stack_result" | "boxed_result" ->
      let* ok_ty = decode_type_field path "ok_type" value in
      let* err_ty = decode_type_field path "err_type" value in
      Ok (Ast.TyNamed ("Result", [ ok_ty; err_ty ]))
  | "enum" | "value_record" | "heap_record" | "union" ->
      let* name = string_field path "name" value in
      Ok (Ast.TyNamed (name, []))
  | "range" ->
      (* The shared backend model intentionally erases the range bound while
         retaining the fact that indexing was proven.  Middle passes only
         inspect the range constructor; the wildcard dimension is never used
         to derive a bound. *)
      Ok (Ast.TyRange (Ast.TyVar "#_"))
  | "tuple" ->
      let* items = list_field decode_type path "items" value in
      Ok (Ast.TyTuple items)
  | "tensor" ->
      let* info = field path "info" value in
      let info_path = path_field path "info" in
      let* element = decode_type_field info_path "element_type" info in
      let* dims = list_field decode_tensor_dim info_path "dims" info in
      Ok (Ast.TyArray (element, dims))
  | _ -> error (path_field path "kind") ("unsupported Core type `" ^ tag ^ "`")

and decode_type_field path name value =
  let* value = field path name value in
  decode_type (path_field path name) value

and decode_tensor_dim path value =
  let* tag = kind path value in
  match tag with
  | "static" ->
      let* value = int_field path "value" value in
      Ok (Ast.TyConstInt value)
  | "runtime" ->
      let* name = string_field path "name" value in
      Ok (Ast.TyVar name)
  | "variadic" ->
      let* name = string_field path "name" value in
      Ok (Ast.TyVarDims name)
  | "operation" ->
      let* op_name = string_field path "op" value in
      let* op =
        match op_name with
        | "add" -> Ok Ast.DimAdd
        | "subtract" -> Ok Ast.DimSub
        | "multiply" -> Ok Ast.DimMul
        | "divide" -> Ok Ast.DimDiv
        | _ -> error (path_field path "op")
            ("unsupported dimension operator `" ^ op_name ^ "`")
      in
      let* left_json = field path "left" value in
      let* left = decode_tensor_dim (path_field path "left") left_json in
      let* right_json = field path "right" value in
      let* right = decode_tensor_dim (path_field path "right") right_json in
      Ok (Ast.TyDimOp (op, left, right))
  | _ -> error (path_field path "kind") ("unsupported tensor dimension `" ^ tag ^ "`")

let decode_literal path value =
  let* tag = kind path value in
  match tag with
  | "int" ->
      let* value_json = field path "value" value in
      let* value = exact_int64 (path_field path "value") value_json in
      Ok (Ast.LitInt value)
  | "wide_int" ->
      let* value = string_field path "value" value in
      Ok (Ast.LitInt128 value)
  | "float" -> (
      let* raw = field path "value" value in
      match raw with
      | Lsp_json.Int n -> Ok (Ast.LitFloat (float_of_int n))
      | Lsp_json.Float n -> Ok (Ast.LitFloat n)
      | _ -> error (path_field path "value") "expected number")
  | "float_text" ->
      let* text = string_field path "value" value in
      (try Ok (Ast.LitFloat (float_of_string text))
       with Failure _ -> error (path_field path "value") "invalid float literal")
  | "float_infinity" -> Ok (Ast.LitFloat infinity)
  | "float_neg_infinity" -> Ok (Ast.LitFloat neg_infinity)
  | "float_nan" -> Ok (Ast.LitFloat nan)
  | "bool" ->
      let* value = bool_field path "value" value in
      Ok (Ast.LitBool value)
  | "char" ->
      let* value = int_field path "value" value in
      Ok (Ast.LitChar value)
  | "string" ->
      let* value = string_field path "value" value in
      Ok (Ast.LitString (value, { sf_multiline = false; sf_raw = false }))
  | _ -> error (path_field path "kind") ("unsupported literal `" ^ tag ^ "`")

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
  | tag -> error path ("unsupported binary operator `" ^ tag ^ "`")

let decode_unary_op path = function
  | "negate" -> Ok Ast.Neg
  | "not" -> Ok Ast.Not
  | tag -> error path ("unsupported unary operator `" ^ tag ^ "`")

let decode_logical_op path = function
  | "and" -> Ok Ast.And
  | "or" -> Ok Ast.Or
  | tag -> error path ("unsupported logical operator `" ^ tag ^ "`")

let decode_foreign_copy_kind path value =
  let* tag = string path value in
  match tag with
  | "string" -> Ok Core.ForeignStringCopy
  | "bytes" -> Ok Core.ForeignBytesCopy
  | _ -> error path ("unsupported FFI copy kind `" ^ tag ^ "`")

let decode_foreign_default_policy path value =
  let* tag = kind path value in
  match tag with
  | "scalar_by_value" -> Ok Core.ForeignScalarByValue
  | "defensive_copy" ->
      let* copy = field path "copy_kind" value in
      let* copy = decode_foreign_copy_kind (path_field path "copy_kind") copy in
      Ok (Core.ForeignDefensiveCopy copy)
  | _ -> error (path_field path "kind") ("unsupported FFI policy `" ^ tag ^ "`")

let decode_foreign_arg_passing path value =
  let* tag = kind path value in
  match tag with
  | "borrow" -> Ok Core.ForeignBorrowArgs
  | "default" ->
      let* policies = list_field decode_foreign_default_policy path "policies" value in
      Ok (Core.ForeignDefaultArgs policies)
  | _ -> error (path_field path "kind") ("unsupported FFI argument mode `" ^ tag ^ "`")

let decode_call_kind path value =
  let* tag = kind path value in
  match tag with
  | "unknown" -> Ok Core.CKUnknown
  | "selected_direct" ->
      error (path_field path "kind")
        "unresolved selected direct call reached the post-tuple-SROA boundary"
  | "deferred_trait" ->
      error (path_field path "kind")
        "unresolved deferred trait call reached the post-tuple-SROA boundary"
  | "selected_trait" ->
      error (path_field path "kind")
        "unresolved selected trait call reached the post-tuple-SROA boundary"
  | "user" ->
      let* name = string_field path "name" value in
      let* id = optional_int_field path "def_id" value in
      Ok (Core.CKUser (name, id))
  | "foreign" ->
      let* name = string_field path "name" value in
      let* passing_json = field path "arg_passing" value in
      let* fc_arg_passing =
        decode_foreign_arg_passing (path_field path "arg_passing") passing_json
      in
      Ok (Core.CKForeign { fc_c_name = name; fc_arg_passing })
  | "builtin" ->
      let* name = string_field path "name" value in
      Ok (Core.CKBuiltin name)
  | "intrinsic" ->
      let* name = string_field path "name" value in
      Ok (Core.CKIntrinsic name)
  | "closure" -> Ok Core.CKClosure
  | _ ->
      error (path_field path "kind")
        ("call kind `" ^ tag
       ^ "` is not valid at the post-tuple-SROA boundary")

let decode_inline_width path = function
  | 1 -> Ok Core.InlineBytes1
  | 2 -> Ok Core.InlineBytes2
  | 4 -> Ok Core.InlineBytes4
  | 8 -> Ok Core.InlineBytes8
  | width -> error path (Printf.sprintf "unsupported inline list width %d" width)

let decode_list_slots path value =
  let* tag = kind path value in
  match tag with
  | "pointer" -> Ok Core.ListPointerStorage
  | "inline" ->
      let* width = int_field path "width_bytes" value in
      let* width = decode_inline_width (path_field path "width_bytes") width in
      Ok (Core.ListInlineStorage width)
  | "inline_struct" ->
      let* c_type = string_field path "c_type" value in
      Ok (Core.ListInlineStructStorage c_type)
  | _ -> error (path_field path "kind") ("unsupported list layout `" ^ tag ^ "`")

let list_element_type = function
  | Ast.TyNamed (("List" | "ParallelList"), [ elem ]) -> Some elem
  | _ -> None

let list_storage_layout ty slots elem_needs_release =
  let value_layout, policy =
    match slots with
    | Core.ListInlineStorage width ->
        (Core.ListElementInlineBits width, Core.StoragePolicyUnmanagedBits)
    | Core.ListInlineStructStorage c_type ->
        (Core.ListElementStackStruct c_type, Core.StoragePolicyUnmanagedBits)
    | Core.ListPointerStorage when elem_needs_release ->
        (Core.ListElementPointer, Core.StoragePolicyManagedPointer)
    | Core.ListPointerStorage ->
        (Core.ListElementBoxedValue, Core.StoragePolicyUnmanagedBits)
  in
  Core.list_storage_layout ?elem_ty:(list_element_type ty) ~value_layout
    ~policy slots

let decode_box_kind path value =
  let* tag = kind path value in
  match tag with
  | "prim" -> Ok Core.BoxPrim
  | "pointer" -> Ok Core.BoxPointer
  | "void" -> Ok Core.BoxVoid
  | "float" -> Ok Core.BoxFloat
  | "float32" -> Ok Core.BoxFloat32
  | "float16" -> Ok Core.BoxFloat16
  | "int128" -> Ok Core.BoxInt128
  | "uint128" -> Ok Core.BoxUInt128
  | "struct" ->
      let* c_type = string_field path "c_type" value in
      Ok (Core.BoxStruct c_type)
  | _ -> error (path_field path "kind") ("unsupported box kind `" ^ tag ^ "`")

let decode_unbox_kind path value =
  let* tag = kind path value in
  match tag with
  | "float" -> Ok Core.UnboxFloat
  | "float32" -> Ok Core.UnboxFloat32
  | "float16" -> Ok Core.UnboxFloat16
  | "int128" -> Ok Core.UnboxInt128
  | "uint128" -> Ok Core.UnboxUInt128
  | "pointer" -> Ok Core.UnboxPointer
  | "prim" -> Ok Core.UnboxPrim
  | "struct" ->
      let* c_type = string_field path "c_type" value in
      Ok (Core.UnboxStruct c_type)
  | _ -> error (path_field path "kind") ("unsupported unbox kind `" ^ tag ^ "`")

let decode_tensor_raw_scalar path = function
  | Lsp_json.String "float64" -> Ok Core.TensorFloat64Elements
  | Lsp_json.String "float32" -> Ok Core.TensorFloat32Elements
  | Lsp_json.String "int64" -> Ok Core.TensorInt64Elements
  | Lsp_json.String tag ->
      error path ("unsupported tensor raw scalar kind `" ^ tag ^ "`")
  | _ -> error path "expected tensor raw scalar kind string"

let decode_release_policy path = function
  | Lsp_json.String ("none" | "arc" | "arc_only" | "stack_result") -> Ok ()
  | Lsp_json.String tag -> error path ("unsupported release policy `" ^ tag ^ "`")
  | _ -> error path "expected release policy string"

let rec decode_expr path value =
  let* tag = kind path value in
  match tag with
  | "literal" ->
      let* literal_json = field path "literal" value in
      let* literal = decode_literal (path_field path "literal") literal_json in
      decode_typed_expr path value (Core.CLit literal)
  | "var" ->
      let* variable = decode_var_field path "var" value in
      decode_typed_expr path value (Core.CVar variable)
  | "void" -> decode_typed_expr path value Core.CVoid
  | "debug_block" ->
      let* body = decode_expr_field path "body" value in
      decode_typed_expr path value (Core.CDebugBlock body)
  | "call" ->
      let* kind_json = field path "call_kind" value in
      let* call_kind = decode_call_kind (path_field path "call_kind") kind_json in
      let* callee = decode_expr_field path "callee" value in
      let* args = list_field decode_expr path "args" value in
      decode_typed_expr path value (Core.CCall (call_kind, callee, args))
  | "binary" ->
      let* tag = string_field path "op" value in
      let* op = decode_binary_op (path_field path "op") tag in
      let* left = decode_expr_field path "left" value in
      let* right = decode_expr_field path "right" value in
      decode_typed_expr path value (Core.CBin (op, left, right))
  | "unary" ->
      let* tag = string_field path "op" value in
      let* op = decode_unary_op (path_field path "op") tag in
      let* inner = decode_expr_field path "expr" value in
      decode_typed_expr path value (Core.CUn (op, inner))
  | "logical" ->
      let* tag = string_field path "op" value in
      let* op = decode_logical_op (path_field path "op") tag in
      let* left = decode_expr_field path "left" value in
      let* right = decode_expr_field path "right" value in
      decode_typed_expr path value (Core.CLog (op, left, right))
  | "assign" ->
      let* variable = decode_var_field path "var" value in
      let* rhs = decode_expr_field path "rhs" value in
      decode_typed_expr path value (Core.CAssign (variable, rhs))
  | "cast" ->
      let* inner = decode_expr_field path "expr" value in
      let* target_ty = decode_type_field path "type" value in
      let* loc = decode_loc_field path "loc" value in
      Ok (Core.mk ~loc ~ty:target_ty (Core.CCast (inner, target_ty)))
  | "box" -> decode_box_expr path value
  | "unbox" -> decode_unbox_expr path value
  | "field" ->
      let* inner = decode_expr_field path "expr" value in
      let* name = string_field path "field" value in
      decode_typed_expr path value (Core.CField (inner, name))
  | "tuple_field" ->
      let* inner = decode_expr_field path "expr" value in
      let* index = int_field path "index" value in
      decode_typed_expr path value (Core.CField (inner, string_of_int index))
  | "tuple" ->
      let* items = list_field decode_expr path "items" value in
      decode_typed_expr path value (Core.CTuple items)
  | "vector" ->
      let* items = list_field decode_expr path "items" value in
      decode_typed_expr path value (Core.CVector items)
  | "lambda" ->
      let* params = list_field decode_param path "params" value in
      let* return_ty = decode_type_field path "return_type" value in
      let* body = decode_expr_field path "body" value in
      let* is_pure = bool_field path "pure" value in
      let lam_params = List.map (fun p -> (p.Core.cp_name, p.cp_ty)) params in
      decode_typed_expr path value
        (Core.CLambda { lam_params; lam_body = body; lam_return_ty = return_ty; lam_is_pure = is_pure })
  | "list_construct" -> decode_list_construct_expr path value
  | "list_handoff" -> decode_list_handoff_expr path value
  | "dict" ->
      let decode_entry entry_path entry =
        let* key = decode_expr_field entry_path "key" entry in
        let* item = decode_expr_field entry_path "value" entry in
        Ok (key, item)
      in
      let* entries = list_field decode_entry path "entries" value in
      decode_typed_expr path value (Core.CDict entries)
  | "record" ->
      let decode_record_field field_path field =
        let* name = string_field field_path "name" field in
        let* item = decode_expr_field field_path "value" field in
        Ok (name, item)
      in
      let* fields = list_field decode_record_field path "fields" value in
      decode_typed_expr path value (Core.CRecord fields)
  | "record_update" ->
      let decode_record_field field_path field =
        let* name = string_field field_path "name" field in
        let* item = decode_expr_field field_path "value" field in
        Ok (name, item)
      in
      let* base = decode_expr_field path "base" value in
      let* fields = list_field decode_record_field path "fields" value in
      (match base.Core.desc with
      | Core.CVar _ ->
          decode_typed_expr path value (Core.CRecordUpdate (base, fields))
      | _ ->
          error (path_field path "base")
            "record update base must be a variable expression")
  | "let" -> decode_let_expr path value
  | "borrow_let" -> decode_borrow_let_expr path value
  | "seq" ->
      let* first = decode_expr_field path "first" value in
      let* second = decode_expr_field path "second" value in
      Ok (Core.mk ~loc:second.loc ~ty:second.ty (Core.CSeq (first, second)))
  | "if" ->
      let* cond = decode_expr_field path "cond" value in
      let* then_ = decode_expr_field path "then" value in
      let* else_ = decode_expr_field path "else" value in
      decode_typed_expr path value (Core.CIf (cond, then_, else_))
  | "while" ->
      let* cond = decode_expr_field path "cond" value in
      let* body = decode_expr_field path "body" value in
      decode_typed_expr path value (Core.CWhile (cond, body))
  | "break" -> decode_typed_expr path value Core.CBreak
  | "continue" -> decode_typed_expr path value Core.CContinue
  | "range" ->
      let* start = decode_expr_field path "start" value in
      let* finish = decode_expr_field path "end" value in
      decode_typed_expr path value (Core.CRange (start, finish))
  | "for_range" -> decode_for_range_expr path value
  | "for_channel" | "for_list" | "for_string" | "for_dict" | "for_set"
  | "for_stream" | "for_resource_source" | "for_tensor" ->
      decode_for_container_expr tag path value
  | "resource_scope" -> decode_resource_scope_expr path value
  | "pre_closure_detach" ->
      let* detached = field path "pre_closure_detach" value in
      let* body = decode_expr_field (path_field path "pre_closure_detach") "body" detached in
      decode_typed_expr path value (Core.CDetach { detach_body = body })
  | "pre_closure_concurrent" -> decode_concurrent_expr path value
  | "pre_closure_concurrently_loop" -> decode_concurrently_loop_expr path value
  | "tensor_raw_read" -> decode_tensor_raw_read_expr path value
  | "tensor_raw_view_let" -> decode_tensor_raw_view_let_expr path value
  | "drop" -> decode_drop_expr path value
  | "select" -> decode_select_expr path value
  | "semantic_match" -> decode_semantic_match_expr path value
  | "constructor_match" -> decode_precompiled_constructor_match_expr path value
  | "tailrec_loop" -> decode_tailrec_loop_expr path value
  | "tailrec_recur" -> decode_tailrec_recur_expr path value
  | "tailrec_list_spread_loop" ->
      decode_tailrec_list_spread_loop_expr path value
  | "tailrec_list_spread_recur" ->
      decode_tailrec_list_spread_recur_expr path value
  | _ ->
      error (path_field path "kind")
        ("Core expression `" ^ tag
       ^ "` is not valid at the post-tuple-SROA boundary")

and decode_typed_expr path value desc =
  let* ty = decode_type_field path "type" value in
  let* loc = decode_loc_field path "loc" value in
  Ok (Core.mk ~loc ~ty desc)

and decode_expr_field path name value =
  let* value = field path name value in
  decode_expr (path_field path name) value

and decode_tailrec_loop_expr path value =
  let* tul_params = list_field decode_param path "params" value in
  let* tul_return_ty = decode_type_field path "return_type" value in
  let* tul_body = decode_expr_field path "body" value in
  let* loc = decode_loc_field path "loc" value in
  Ok
    (Core.mk ~loc ~ty:tul_return_ty
       (Core.CTailrecLoop
          (Core.TailrecUnmanagedLoop
             { tul_params; tul_return_ty; tul_body })))

and decode_tailrec_recur_expr path value =
  let* tr_args = list_field decode_expr path "args" value in
  decode_typed_expr path value
    (Core.CTailrecRecur (Core.TailrecRecur { tr_args }))

and decode_tailrec_list_spread_loop_expr path value =
  let* loop = field path "loop" value in
  let loop_path = path_field path "loop" in
  let* tls_params = list_field decode_param loop_path "params" loop in
  let* tls_return_ty = decode_type_field loop_path "return_type" loop in
  let* tls_list_index = int_field loop_path "list_index" loop in
  let* tls_list_param_json = field loop_path "list_param" loop in
  let* tls_list_param =
    decode_param (path_field loop_path "list_param") tls_list_param_json
  in
  let* tls_cursor_var = decode_var_field loop_path "cursor" loop in
  let* layout_json = field loop_path "layout" loop in
  let* _layout = decode_list_slots (path_field loop_path "layout") layout_json in
  let* tls_body = decode_expr_field loop_path "body" loop in
  let* loc = decode_loc_field path "loc" value in
  if tls_list_index < 0 || tls_list_index >= List.length tls_params then
    error (path_field loop_path "list_index")
      "tailrec list parameter index is outside the parameter list"
  else
    let indexed_param = List.nth tls_params tls_list_index in
    if
      (not (Core.Var.equal indexed_param.cp_name tls_list_param.cp_name))
      || not (Types.types_equal indexed_param.cp_ty tls_list_param.cp_ty)
    then
      error (path_field loop_path "list_param")
        "tailrec list parameter does not match the indexed parameter"
    else
      Ok
        (Core.mk ~loc ~ty:tls_return_ty
           (Core.CTailrecLoop
              (Core.TailrecListSpreadLoop
                 {
                   tls_params;
                   tls_return_ty;
                   tls_list_index;
                   tls_list_param;
                   tls_cursor_var;
                   tls_body;
                 })))

and decode_tailrec_list_spread_recur_expr path value =
  let decode_rebind rebind_path rebind =
    let* param_index = int_field rebind_path "param_index" rebind in
    let* rebind_value = decode_expr_field rebind_path "value" rebind in
    if param_index < 0 then
      error (path_field rebind_path "param_index")
        "tailrec parameter index must be non-negative"
    else Ok (param_index, rebind_value)
  in
  let* tr_rebinds = list_field decode_rebind path "rebinds" value in
  let* tr_cursor_advance = int_field path "cursor_advance" value in
  if tr_cursor_advance < 0 then
    error (path_field path "cursor_advance")
      "tailrec list cursor advance must be non-negative"
  else
    decode_typed_expr path value
      (Core.CTailrecRecur
         (Core.TailrecListSpreadRecur
            { tr_rebinds; tr_cursor_advance }))

and decode_param path value =
  let* cp_name = decode_var_field path "name" value in
  let* cp_ty = decode_type_field path "type" value in
  let* cp_loc = decode_loc_field path "loc" value in
  Ok { Core.cp_name; cp_ty; cp_loc }

and decode_box_expr path value =
  let* box_json = field path "box" value in
  let box_path = path_field path "box" in
  let* kind_json = field box_path "kind" box_json in
  let* box_kind = decode_box_kind (path_field box_path "kind") kind_json in
  let* box_value = decode_expr_field box_path "value" box_json in
  let* box_source_ty = decode_type_field box_path "source_type" box_json in
  decode_typed_expr path value
    (Core.CBoxTyped { box_value; box_source_ty; box_kind })

and decode_unbox_expr path value =
  let* kind_json = field path "unbox_kind" value in
  let* unbox_kind =
    decode_unbox_kind (path_field path "unbox_kind") kind_json
  in
  let* unbox_value = decode_expr_field path "expr" value in
  let* unbox_target_ty = decode_type_field path "type" value in
  let* loc = decode_loc_field path "loc" value in
  Ok
    (Core.mk ~loc ~ty:unbox_target_ty
       (Core.CUnboxTyped { unbox_value; unbox_target_ty; unbox_kind }))

and decode_boxed_value path value =
  let* kind_json = field path "kind" value in
  let* box_kind = decode_box_kind (path_field path "kind") kind_json in
  let* box_value = decode_expr_field path "value" value in
  let* bsv_needs_release = bool_field path "needs_release" value in
  let* bsv_transfers_ownership = bool_field path "transfers_ownership" value in
  Ok
    {
      Core.bsv_box = { box_value; box_source_ty = box_value.ty; box_kind };
      bsv_needs_release;
      bsv_transfers_ownership;
    }

and decode_list_construct_expr path value =
  let* ty = decode_type_field path "type" value in
  let* loc = decode_loc_field path "loc" value in
  let* construct = field path "construct" value in
  let construct_path = path_field path "construct" in
  let* layout_json = field construct_path "layout" construct in
  let* slots = decode_list_slots (path_field construct_path "layout") layout_json in
  let* lc_elems = list_field decode_boxed_value construct_path "elements" construct in
  let* lc_elem_needs_release = bool_field construct_path "elem_needs_release" construct in
  let lc_layout = list_storage_layout ty slots lc_elem_needs_release in
  Ok
    (Core.mk ~loc ~ty
       (Core.CListConstruct { lc_layout; lc_elems; lc_elem_needs_release }))

and decode_list_handoff_expr path value =
  let* ty = decode_type_field path "type" value in
  let* loc = decode_loc_field path "loc" value in
  let* handoff = field path "handoff" value in
  let handoff_path = path_field path "handoff" in
  let* mode = string_field handoff_path "mode" handoff in
  let* () =
    if mode = "borrow_fresh" then Ok ()
    else
      error (path_field handoff_path "mode")
        "post-tuple-SROA list handoff must use borrow_fresh mode"
  in
  let* layout_json = field handoff_path "layout" handoff in
  let* slots =
    decode_list_slots (path_field handoff_path "layout") layout_json
  in
  let* elem_needs_release =
    bool_field handoff_path "elem_needs_release" handoff
  in
  let* lh_source = decode_expr_field handoff_path "source" handoff in
  let* lh_source_var = decode_var_field handoff_path "source_var" handoff in
  let* lh_source_ty = decode_type_field handoff_path "source_type" handoff in
  let* lh_result_ty = decode_type_field handoff_path "result_type" handoff in
  let* lh_capacity = decode_expr_field handoff_path "capacity" handoff in
  let* lh_result_var = decode_var_field handoff_path "result_var" handoff in
  let* lh_len_var = decode_var_field handoff_path "len_var" handoff in
  let* lh_out_var = decode_var_field handoff_path "out_var" handoff in
  let* lh_body = decode_expr_field handoff_path "body" handoff in
  let* write_order = string_field handoff_path "write_order" handoff in
  let* () =
    if write_order = "forward_compacting" then Ok ()
    else
      error (path_field handoff_path "write_order")
        "unsupported collection list handoff write order"
  in
  let* () =
    if Types.types_equal ty lh_result_ty then Ok ()
    else
      error (path_field handoff_path "result_type")
        "list handoff result type does not match expression type"
  in
  let* () =
    if Types.types_equal lh_source.ty lh_source_ty then Ok ()
    else
      error (path_field handoff_path "source_type")
        "list handoff source type does not match source expression"
  in
  let lh_layout = list_storage_layout lh_result_ty slots elem_needs_release in
  Ok
    (Core.mk ~loc ~ty
       (Core.CListHandoff
          {
            lh_mode = Core.BorrowFresh;
            lh_layout;
            lh_source;
            lh_source_var;
            lh_source_ty;
            lh_result_ty;
            lh_capacity;
            lh_result_var;
            lh_len_var;
            lh_out_var;
            lh_body;
            lh_write_order = Core.ForwardCompacting;
          }))

and decode_let_expr path value =
  let* bind_var = decode_var_field path "name" value in
  let* bind_mut = bool_field path "mutable" value in
  let* bind_ty = decode_type_field path "type" value in
  let* bind_rhs = decode_expr_field path "rhs" value in
  let* body = decode_expr_field path "body" value in
  Ok
    (Core.mk ~loc:body.loc ~ty:body.ty
       (Core.CLet ({ bind_var; bind_mut; bind_ty; bind_rhs }, body)))

and decode_borrow_let_expr path value =
  let* borrow_var = decode_var_field path "name" value in
  let* borrow_ty = decode_type_field path "type" value in
  let* borrow_rhs = decode_expr_field path "rhs" value in
  let* body = decode_expr_field path "body" value in
  Ok
    (Core.mk ~loc:body.loc ~ty:body.ty
       (Core.CBorrowLet ({ borrow_var; borrow_ty; borrow_rhs }, body)))

and decode_tensor_raw_read_expr path value =
  let* read = field path "read" value in
  let read_path = path_field path "read" in
  let* trr_view = decode_var_field read_path "view" read in
  let* kind_json = field read_path "raw_kind" read in
  let* trr_kind =
    decode_tensor_raw_scalar (path_field read_path "raw_kind") kind_json
  in
  let* trr_index = decode_expr_field read_path "index" read in
  decode_typed_expr path value
    (Core.CTensorRawRead { trr_view; trr_kind; trr_index })

and decode_tensor_raw_view_let_expr path value =
  let* binding = field path "binding" value in
  let binding_path = path_field path "binding" in
  let* trv_var = decode_var_field binding_path "variable" binding in
  let* kind_json = field binding_path "raw_kind" binding in
  let* trv_kind =
    decode_tensor_raw_scalar (path_field binding_path "raw_kind") kind_json
  in
  let* trv_source = decode_expr_field binding_path "source" binding in
  let* body = decode_expr_field path "body" value in
  decode_typed_expr path value
    (Core.CTensorRawViewLet ({ trv_var; trv_kind; trv_source }, body))

and decode_drop_expr path value =
  let* variable = decode_var_field path "var" value in
  let* value_ty = decode_type_field path "value_type" value in
  let* release_policy = field path "release_policy" value in
  let* () =
    decode_release_policy (path_field path "release_policy") release_policy
  in
  let* body = decode_expr_field path "body" value in
  decode_typed_expr path value (Core.CDrop (variable, value_ty, body))

and decode_loop_binder path value =
  let* loop_var = decode_var_field path "var" value in
  let* loop_ty = decode_type_field path "type" value in
  let* direction = string_field path "range_direction" value in
  let* loop_range_direction =
    match direction with
    | "forward_only" -> Ok Core.RangeForwardOnly
    | "may_run_backward" -> Ok Core.RangeMayRunBackward
    | _ -> error (path_field path "range_direction")
        ("unsupported loop direction `" ^ direction ^ "`")
  in
  Ok
    {
      Core.loop_var;
      loop_ty;
      loop_range_direction;
      loop_source_storage = Core.default_loop_source_storage;
    }

and decode_for_range_expr path value =
  let* binder_json = field path "binder" value in
  let* binder = decode_loop_binder (path_field path "binder") binder_json in
  let* start = decode_expr_field path "start" value in
  let* finish = decode_expr_field path "end" value in
  let* body = decode_expr_field path "body" value in
  let range = Core.mk ~loc:start.loc ~ty:(Ast.TyNamed ("Range", [ binder.loop_ty ]))
      (Core.CRange (start, finish)) in
  decode_typed_expr path value (Core.CFor (binder, range, body))

and decode_for_container_expr tag path value =
  let field_name = tag in
  let* loop = field path field_name value in
  let loop_path = path_field path field_name in
  let* binder_json = field loop_path "binder" loop in
  let* binder = decode_loop_binder (path_field loop_path "binder") binder_json in
  let* iterable = decode_expr_field loop_path "iterable" loop in
  let* body = decode_expr_field loop_path "body" loop in
  decode_typed_expr path value (Core.CFor (binder, iterable, body))

and decode_resource_scope_expr path value =
  let* scope = field path "scope" value in
  let scope_path = path_field path "scope" in
  let* rs_var = decode_var_field scope_path "var" scope in
  let* rs_ty = decode_type_field scope_path "type" scope in
  let* rs_acquire = decode_expr_field scope_path "acquire" scope in
  let* rs_body = decode_expr_field scope_path "body" scope in
  let* rs_cleanup = decode_expr_field scope_path "cleanup" scope in
  decode_typed_expr path value
    (Core.CResourceScope { rs_var; rs_ty; rs_acquire; rs_body; rs_cleanup })

and decode_concurrent_expr path value =
  let* block = field path "pre_closure_concurrent" value in
  let block_path = path_field path "pre_closure_concurrent" in
  let decode_binding binding_path binding =
    let* cb_var = decode_var_field binding_path "var" binding in
    let* cb_ty = decode_type_field binding_path "type" binding in
    let* cb_rhs = decode_expr_field binding_path "rhs" binding in
    Ok { Core.cb_var; cb_ty; cb_rhs; cb_task_scope = Core.synthetic_concurrent_task_scope }
  in
  let* conc_bindings = list_field decode_binding block_path "bindings" block in
  let* conc_body = decode_expr_field block_path "body" block in
  let* timeout_json = field block_path "timeout" block in
  let* conc_timeout = optional decode_expr (path_field block_path "timeout") timeout_json in
  let* max_threads_json = field block_path "max_threads" block in
  let* conc_max_threads = optional int (path_field block_path "max_threads") max_threads_json in
  decode_typed_expr path value
    (Core.CConcurrent { conc_bindings; conc_body; conc_timeout; conc_max_threads })

and decode_concurrently_loop_expr path value =
  let* loop = field path "pre_closure_concurrently_loop" value in
  let loop_path = path_field path "pre_closure_concurrently_loop" in
  let* cf_var = decode_var_field loop_path "var" loop in
  let* cf_iter = decode_expr_field loop_path "iterable" loop in
  let* cf_body = decode_expr_field loop_path "body" loop in
  let* timeout_json = field loop_path "timeout" loop in
  let* cf_timeout = optional decode_expr (path_field loop_path "timeout") timeout_json in
  let* limit = decode_expr_field loop_path "limit" loop in
  let* output = string_field loop_path "output" loop in
  let* cf_output =
    match output with
    | "collect" -> Ok Core.ConcurrentlyLoopCollect
    | "discard" -> Ok Core.ConcurrentlyLoopDiscard
    | _ -> error (path_field loop_path "output")
        ("unsupported concurrent-loop output `" ^ output ^ "`")
  in
  let* mode_json = field loop_path "item_mode" loop in
  let mode_path = path_field loop_path "item_mode" in
  let* mode_tag = kind mode_path mode_json in
  let* cf_item_mode =
    match mode_tag with
    | "copy" -> Ok Core.ConcurrentlyLoopCopyItem
    | "move_resource_item" ->
        let* clmi_resource_ty = decode_type_field mode_path "resource_type" mode_json in
        let* clmi_error_ty = decode_type_field mode_path "error_type" mode_json in
        Ok
          (Core.ConcurrentlyLoopMoveResourceItem
             { clmi_resource_ty; clmi_error_ty })
    | _ -> error (path_field mode_path "kind")
        ("unsupported concurrent-loop item mode `" ^ mode_tag ^ "`")
  in
  decode_typed_expr path value
    (Core.CConcurrentlyLoop
       {
         cf_var;
         cf_iter;
         cf_body;
         cf_timeout;
         cf_width = Core.ConcurrentlyLoopLimit limit;
         cf_output;
         cf_item_mode;
         cf_task_scope = Core.synthetic_concurrent_task_scope;
       })

and decode_select_expr path value =
  let* select = field path "select" value in
  let select_path = path_field path "select" in
  let decode_arm arm_path arm =
    let* kind_json = field arm_path "kind" arm in
    let kind_path = path_field arm_path "kind" in
    let* tag = kind kind_path kind_json in
    let* select_arm_kind =
      match tag with
      | "recv" ->
          let* recv = field kind_path "recv" kind_json in
          let recv_path = path_field kind_path "recv" in
          let* select_bind = decode_var_field recv_path "binder" recv in
          let* select_elem_ty = decode_type_field recv_path "elem_type" recv in
          let* select_channel = decode_expr_field recv_path "channel" recv in
          Ok (Core.SelectRecv { select_bind; select_elem_ty; select_channel })
      | "sealed" ->
          let* channel = decode_expr_field kind_path "channel" kind_json in
          Ok (Core.SelectSealed channel)
      | "after" ->
          let* timeout = decode_expr_field kind_path "timeout" kind_json in
          Ok (Core.SelectAfter timeout)
      | _ -> error (path_field kind_path "kind") ("unsupported select arm `" ^ tag ^ "`")
    in
    let* select_arm_body = decode_expr_field arm_path "body" arm in
    let* select_arm_loc = decode_loc_field arm_path "loc" arm in
    Ok { Core.select_arm_kind; select_arm_body; select_arm_loc }
  in
  let* select_arms = list_field decode_arm select_path "arms" select in
  decode_typed_expr path value (Core.CSelect { select_arms })

and decode_match_binding path value =
  let* mb_var = decode_var_field path "variable" value in
  let* accessor_json = field path "accessor" value in
  let* mb_accessor = decode_accessor (path_field path "accessor") accessor_json in
  let* mode = string_field path "mode" value in
  let* mb_mode =
    match mode with
    | "own" -> Ok Core.MatchOwn
    | "borrow" -> Ok Core.MatchBorrow
    | _ -> error (path_field path "mode")
        ("unsupported match binding mode `" ^ mode ^ "`")
  in
  Ok { Core.mb_var; mb_accessor; mb_mode }

and decode_accessor path value =
  let* tag = kind path value in
  let parent () =
    let* value = field path "parent" value in
    decode_accessor (path_field path "parent") value
  in
  match tag with
  | "root" -> Ok Core.AccRoot
  | "variant_field" | "erased_variant_field" ->
      let* parent = parent () in
      let* constructor = string_field path "constructor" value in
      let* index = int_field path "field_index" value in
      Ok (Core.AccVariantField (parent, constructor, index))
  | "nullable_option_payload" | "stack_option_payload" ->
      let* parent = parent () in
      Ok (Core.AccVariantField (parent, "Some", 0))
  | "stack_result_ok_payload" | "boxed_stack_result_ok_payload"
  | "boxed_result_ok_payload" ->
      let* parent = parent () in
      Ok (Core.AccVariantField (parent, "Ok", 0))
  | "stack_result_err_payload" | "boxed_stack_result_err_payload"
  | "boxed_result_err_payload" ->
      let* parent = parent () in
      Ok (Core.AccVariantField (parent, "Err", 0))
  | "tuple_field" ->
      let* parent = parent () in
      let* index = int_field path "index" value in
      Ok (Core.AccTupleField (parent, index))
  | "list_element" ->
      let* parent = parent () in
      let* index = int_field path "index" value in
      Ok (Core.AccListElem (parent, index))
  | "list_spread" ->
      let* parent = parent () in
      let* offset = int_field path "offset" value in
      Ok (Core.AccListSpread (parent, offset))
  | _ -> error (path_field path "kind") ("unsupported match accessor `" ^ tag ^ "`")

and decode_semantic_match_expr path value =
  let* scrutinee = decode_expr_field path "scrutinee" value in
  let* tree_json = field path "tree" value in
  let* tree = decode_semantic_match_tree (path_field path "tree") tree_json in
  decode_typed_expr path value (Core.CMatch (scrutinee, tree))

and decode_semantic_match_tree path value =
  let* tag = kind path value in
  match tag with
  | "leaf" ->
      let* bindings = list_field decode_match_binding path "bindings" value in
      let* body = decode_expr_field path "body" value in
      Ok (Core.CTLeaf { ct_bindings = bindings; ct_body = body })
  | "fail" -> Ok Core.CTFail
  | "constructor" ->
      let* accessor_json = field path "accessor" value in
      let* cts_scrut = decode_accessor (path_field path "accessor") accessor_json in
      let decode_case case_path case =
        let* constructor = string_field case_path "constructor" case in
        let* body_json = field case_path "body" case in
        let* body =
          decode_semantic_match_tree (path_field case_path "body") body_json
        in
        Ok (constructor, body)
      in
      let* cts_cases = list_field decode_case path "cases" value in
      let* fallback_json = field path "fallback" value in
      let* cts_default =
        optional decode_semantic_match_tree (path_field path "fallback")
          fallback_json
      in
      Ok (Core.CTSwitchTag { cts_scrut; cts_cases; cts_default })
  | "literal" ->
      let* accessor_json = field path "accessor" value in
      let* ctl_scrut = decode_accessor (path_field path "accessor") accessor_json in
      let decode_case case_path case =
        let* literal_json = field case_path "literal" case in
        let* literal =
          decode_literal (path_field case_path "literal") literal_json
        in
        let* body_json = field case_path "body" case in
        let* body =
          decode_semantic_match_tree (path_field case_path "body") body_json
        in
        Ok (literal, body)
      in
      let* ctl_cases = list_field decode_case path "cases" value in
      let* fallback_json = field path "fallback" value in
      let* ctl_default =
        decode_semantic_match_tree (path_field path "fallback") fallback_json
      in
      Ok (Core.CTSwitchLit { ctl_scrut; ctl_cases; ctl_default })
  | "length" ->
      let* accessor_json = field path "accessor" value in
      let* ctl_len_scrut =
        decode_accessor (path_field path "accessor") accessor_json
      in
      let decode_case case_path case =
        let* length = int_field case_path "length" case in
        let* body_json = field case_path "body" case in
        let* body =
          decode_semantic_match_tree (path_field case_path "body") body_json
        in
        Ok (length, body)
      in
      let decode_geq geq_path geq =
        let* minimum_length = int_field geq_path "minimum_length" geq in
        let* body_json = field geq_path "body" geq in
        let* body =
          decode_semantic_match_tree (path_field geq_path "body") body_json
        in
        Ok (minimum_length, body)
      in
      let* ctl_len_cases = list_field decode_case path "cases" value in
      let* geq_json = field path "geq" value in
      let* ctl_len_geq =
        optional decode_geq (path_field path "geq") geq_json
      in
      let* fallback_json = field path "fallback" value in
      let* ctl_len_default =
        optional decode_semantic_match_tree (path_field path "fallback")
          fallback_json
      in
      Ok
        (Core.CTSwitchLen
           { ctl_len_scrut; ctl_len_cases; ctl_len_geq; ctl_len_default })
  | _ ->
      error (path_field path "kind")
        ("unsupported semantic match tree `" ^ tag ^ "`")

and decode_precompiled_constructor_match_expr path value =
  let* release_policy =
    string_field path "scrutinee_release_policy" value
  in
  let* () =
    if release_policy = "none" then Ok ()
    else
      error (path_field path "scrutinee_release_policy")
        "precompiled constructor match must not own its scrutinee"
  in
  let* scrutinee = decode_expr_field path "scrutinee" value in
  let decode_case case_path case =
    let* constructor = string_field case_path "constructor" case in
    let* bindings = list_field decode_match_binding case_path "bindings" case in
    let* body_json = field case_path "body" case in
    let* body =
      decode_precompiled_constructor_match_body
        (path_field case_path "body") body_json
    in
    Ok (constructor, prepend_match_bindings bindings body)
  in
  let* cases = list_field decode_case path "cases" value in
  let* fallback_json = field path "fallback" value in
  let* fallback =
    decode_precompiled_match_fallback (path_field path "fallback")
      fallback_json
  in
  let default = match fallback with Core.CTFail -> None | tree -> Some tree in
  decode_typed_expr path value
    (Core.CMatch
       ( scrutinee,
         Core.CTSwitchTag
           {
             cts_scrut = Core.AccRoot;
             cts_cases = cases;
             cts_default = default;
           } ))

and decode_precompiled_constructor_match_body path value =
  let* tag = kind path value in
  match tag with
  | "expr" ->
      let* body = decode_expr_field path "expr" value in
      Ok (Core.CTLeaf { ct_bindings = []; ct_body = body })
  | _ ->
      error (path_field path "kind")
        ("precompiled constructor match body `" ^ tag
       ^ "` is not valid at the post-tuple-SROA boundary")

and decode_precompiled_match_fallback path value =
  let* tag = kind path value in
  match tag with
  | "body" ->
      let* body = decode_expr_field path "body" value in
      Ok (Core.CTLeaf { ct_bindings = []; ct_body = body })
  | "bindings" ->
      let* bindings = list_field decode_match_binding path "bindings" value in
      let* body = decode_expr_field path "body" value in
      Ok (Core.CTLeaf { ct_bindings = bindings; ct_body = body })
  | "fail" -> Ok Core.CTFail
  | _ ->
      error (path_field path "kind")
        ("precompiled constructor match fallback `" ^ tag
       ^ "` is not valid at the post-tuple-SROA boundary")

and prepend_match_bindings bindings tree =
  match tree with
  | Core.CTLeaf leaf ->
      Core.CTLeaf
        { leaf with ct_bindings = bindings @ leaf.ct_bindings }
  | Core.CTFail -> Core.CTFail
  | Core.CTSwitchTag switch ->
      Core.CTSwitchTag
        {
          switch with
          cts_cases =
            List.map
              (fun (tag, branch) ->
                (tag, prepend_match_bindings bindings branch))
              switch.cts_cases;
          cts_default =
            Option.map (prepend_match_bindings bindings)
              switch.cts_default;
        }
  | Core.CTSwitchLit switch ->
      Core.CTSwitchLit
        {
          switch with
          ctl_cases =
            List.map
              (fun (literal, branch) ->
                (literal, prepend_match_bindings bindings branch))
              switch.ctl_cases;
          ctl_default =
            prepend_match_bindings bindings switch.ctl_default;
        }
  | Core.CTSwitchLen switch ->
      Core.CTSwitchLen
        {
          switch with
          ctl_len_cases =
            List.map
              (fun (length, branch) ->
                (length, prepend_match_bindings bindings branch))
              switch.ctl_len_cases;
          ctl_len_geq =
            Option.map
              (fun (length, branch) ->
                (length, prepend_match_bindings bindings branch))
              switch.ctl_len_geq;
          ctl_len_default =
            Option.map (prepend_match_bindings bindings)
              switch.ctl_len_default;
        }

let decode_function_kind path value =
  let* tag = kind path value in
  match tag with
  | "user" -> Ok Core.CFUser
  | "unresolved_builtin" -> Ok Core.CFUnresolvedBuiltin
  | "builtin" -> Ok Core.CFBuiltin
  | "foreign" ->
      let* c_name = string_field path "c_name" value in
      let* includes = string_list_field path "includes" value in
      let decode_link link_path link =
        let* platform = optional_string_field link_path "platform" link in
        let* flag = string_field link_path "flag" link in
        Ok (platform, flag)
      in
      let* link_flags = list_field decode_link path "link_flags" value in
      let* passing_json = field path "arg_passing" value in
      let* arg_passing = decode_foreign_arg_passing (path_field path "arg_passing") passing_json in
      Ok (Core.CFForeign { c_name; includes; link_flags; arg_passing })
  | _ ->
      error (path_field path "kind")
        ("function kind `" ^ tag ^ "` is not valid post-tuple-SROA")

let decode_function path value =
  let* name = string_field path "name" value in
  let* cf_module = optional_string_field path "module" value in
  let* type_params = string_list_field path "type_params" value in
  let cf_type_params = List.map type_param type_params in
  let* cf_params = list_field decode_param path "params" value in
  let* cf_return_ty = decode_type_field path "return_type" value in
  let* body_json = field path "body" value in
  let* cf_body = optional decode_expr (path_field path "body") body_json in
  let* cf_is_pure = bool_field path "pure" value in
  let* kind_json = field path "function_kind" value in
  let* cf_kind = decode_function_kind (path_field path "function_kind") kind_json in
  let* cf_def_id = int_field path "def_id" value in
  Ok
    {
      Core.cf_name = name;
      cf_module;
      cf_type_params;
      cf_params;
      cf_return_ty;
      cf_body;
      cf_is_pure;
      cf_kind;
      cf_def_id;
    }

let rec decode_decl path value =
  let* tag = kind path value in
  let* loc = decode_loc_field path "loc" value in
  let wrap desc = Ok { Core.cd_desc = desc; cd_loc = loc; cd_doc = None } in
  match tag with
  | "function" ->
      let* fn = decode_function path value in
      wrap (Core.CDFunc fn)
  | "global" ->
      let* cv_name = decode_var_field path "name" value in
      let* cv_module = optional_string_field path "source_module" value in
      let* cv_ty = decode_type_field path "type" value in
      let* cv_init = decode_expr_field path "init" value in
      let* cv_is_mutable = bool_field path "mutable" value in
      let* cv_is_const = bool_field path "const" value in
      let* is_private = bool_field path "private" value in
      let* cv_def_id = int_field path "def_id" value in
      let global =
        Core.CDVar
          { cv_name; cv_module; cv_ty; cv_init; cv_is_mutable; cv_is_const; cv_def_id }
      in
      if is_private then wrap (Core.CDPrivate { cd_desc = global; cd_loc = loc; cd_doc = None })
      else wrap global
  | "enum" | "union" -> decode_type_decl tag path value loc
  | "value_record" | "heap_record" -> decode_record_decl tag path value loc
  | "type_alias" ->
      let* alias_name = string_field path "name" value in
      let* params = string_list_field path "type_params" value in
      let* alias_target = decode_type_field path "target" value in
      let* alias_is_opaque = bool_field path "opaque" value in
      wrap
        (Core.CDTypeAlias
           { alias_name; alias_type_params = List.map type_param params; alias_target; alias_is_opaque })
  | "trait" -> decode_trait_decl path value loc
  | "impl" -> decode_impl_decl path value loc
  | _ -> error (path_field path "kind") ("unsupported Core declaration `" ^ tag ^ "`")

and decode_type_decl tag path value loc =
  let* type_name = string_field path "name" value in
  let* params = string_list_field path "type_params" value in
  let decode_variant variant_path variant =
    let* variant_name = string_field variant_path "name" variant in
    let* variant_tag = int_field variant_path "tag" variant in
    let* variant_def_id = optional_int_field variant_path "def_id" variant in
    let* variant_fields =
      if tag = "enum" then Ok []
      else
        list_field
          (fun field_path field -> decode_type_field field_path "type" field)
          variant_path "fields" variant
    in
    Ok { Ast.variant_name; variant_fields; variant_tag; variant_loc = loc; variant_def_id }
  in
  let* type_variants = list_field decode_variant path "variants" value in
  Ok
    {
      Core.cd_desc =
        Core.CDType
          {
            type_name;
            type_params = List.map type_param params;
            type_variants;
            type_is_enum = tag = "enum";
            type_is_builtin = false;
            type_is_resource = false;
            type_resource_cleanup = None;
          };
      cd_loc = loc;
      cd_doc = None;
    }

and decode_record_decl tag path value loc =
  let* record_name = string_field path "name" value in
  let* params = string_list_field path "type_params" value in
  let decode_field field_path field =
    let* field_name = string_field field_path "name" field in
    let* field_type = decode_type_field field_path "type" field in
    Ok { Ast.field_name; field_type; field_loc = loc }
  in
  let* record_fields = list_field decode_field path "fields" value in
  Ok
    {
      Core.cd_desc =
        Core.CDRecord
          {
            record_name;
            record_type_params = List.map type_param params;
            record_fields;
            record_is_value = tag = "value_record";
            record_is_builtin = false;
          };
      cd_loc = loc;
      cd_doc = None;
    }

and decode_trait_decl path value loc =
  let* ct_name = string_field path "name" value in
  let* ct_type_params = string_list_field path "type_params" value in
  let* ct_supertraits = string_list_field path "supertraits" value in
  let decode_method method_path method_ =
    let* ctm_name = string_field method_path "name" method_ in
    let* ctm_params = list_field decode_param method_path "params" method_ in
    let* return_ty = decode_type_field method_path "return_type" method_ in
    let* ctm_is_pure = bool_field method_path "pure" method_ in
    Ok { Core.ctm_name; ctm_params; ctm_return_ty = Some return_ty; ctm_is_pure }
  in
  let* ct_methods = list_field decode_method path "methods" value in
  Ok
    {
      Core.cd_desc = Core.CDTrait { ct_name; ct_type_params; ct_supertraits; ct_methods };
      cd_loc = loc;
      cd_doc = None;
    }

and decode_impl_decl path value loc =
  let* ci_trait = string_field path "trait_name" value in
  let* ci_for_type = decode_type_field path "for_type" value in
  let* impl_type_params = list_field decode_type_param path "type_params" value in
  let* () =
    match impl_type_params with
    | [] -> Ok ()
    | _ ->
        error (path_field path "type_params")
          "generic impl template is not valid post-tuple-SROA"
  in
  let* ci_methods = list_field decode_function path "methods" value in
  Ok { Core.cd_desc = Core.CDImpl { ci_trait; ci_for_type; ci_methods }; cd_loc = loc; cd_doc = None }

let rec decode_union_payload_storage path index = function
  | [] -> Ok []
  | value :: rest ->
      let decl_path = path_index path index in
      let* tag = kind decl_path value in
      let* current =
        if tag = "union" then
          let* name = string_field decl_path "name" value in
          let* storage = string_field decl_path "payload_storage" value in
          match storage with
          | "typed" -> Ok [ (name, Codegen_types.TypedUnionPayloadStorage) ]
          | "erased" ->
              Ok [ (name, Codegen_types.ErasedUnionPayloadStorage) ]
          | _ ->
              error (path_field decl_path "payload_storage")
                ("unsupported union payload storage `" ^ storage ^ "`")
        else Ok []
      in
      let* remaining =
        decode_union_payload_storage path (index + 1) rest
      in
      Ok (current @ remaining)

type record_storage =
  | ValueRecordStorage
  | HeapRecordStorage

let same_record_storage left right =
  match (left, right) with
  | ValueRecordStorage, ValueRecordStorage
  | HeapRecordStorage, HeapRecordStorage ->
      true
  | _ -> false

let decode_record_type_shape shapes path value =
  let* tag = kind path value in
  let* name = string_field path "name" value in
  match tag with
  | "value_record" -> Ok (name, ValueRecordStorage)
  | "heap_record" -> Ok (name, HeapRecordStorage)
  | "named" -> (
      match Hashtbl.find_opt shapes name with
      | Some storage -> Ok (name, storage)
      | None ->
          error path
            (Printf.sprintf
               "record update type `%s` has no matching record declaration"
               name))
  | _ ->
      error path
        "record update type must identify a declared value or heap record"

let validate_record_update_storage_shapes
    (program : decoded_program) value =
  let shapes = Hashtbl.create 16 in
  let rec collect_decl (decl : Core.core_decl) =
    match decl.cd_desc with
    | Core.CDRecord record ->
        Hashtbl.replace shapes record.record_name
          (if record.record_is_value then ValueRecordStorage
           else HeapRecordStorage)
    | Core.CDPrivate inner -> collect_decl inner
    | _ -> ()
  in
  List.iter collect_decl program.core;
  let validate_update path update =
    let* result_type = field path "type" update in
    let result_type_path = path_field path "type" in
    let* result_name, result_storage =
      decode_record_type_shape shapes result_type_path result_type
    in
    let* base = field path "base" update in
    let base_path = path_field path "base" in
    let* base_type = field base_path "type" base in
    let base_type_path = path_field base_path "type" in
    let* base_name, base_storage =
      decode_record_type_shape shapes base_type_path base_type
    in
    if
      not
        (String.equal base_name result_name
        && same_record_storage base_storage result_storage)
    then
      error base_type_path
        "record update base and result must have the same record type and storage"
    else
      match Hashtbl.find_opt shapes result_name with
      | Some declared_storage
        when same_record_storage declared_storage result_storage ->
          Ok ()
      | Some _ ->
          let storage_name =
            match result_storage with
            | ValueRecordStorage -> "value-record"
            | HeapRecordStorage -> "heap-record"
          in
          error result_type_path
            (Printf.sprintf
               "record update type `%s` has no matching %s declaration"
               result_name storage_name)
      | None ->
          error result_type_path
            (Printf.sprintf
               "record update type `%s` has no matching record declaration"
               result_name)
  in
  let rec validate_tree path = function
    | Lsp_json.Object fields as object_value ->
        let* () =
          match List.assoc_opt "kind" fields with
          | Some (Lsp_json.String "record_update") ->
              validate_update path object_value
          | _ -> Ok ()
        in
        let rec validate_fields = function
          | [] -> Ok ()
          | (name, child) :: rest ->
              let* () = validate_tree (path_field path name) child in
              validate_fields rest
        in
        validate_fields fields
    | Lsp_json.Array items ->
        let rec validate_items index = function
          | [] -> Ok ()
          | child :: rest ->
              let* () = validate_tree (path_index path index) child in
              validate_items (index + 1) rest
        in
        validate_items 0 items
    | _ -> Ok ()
  in
  validate_tree "program" value

let validate_record_update_shapes (program : decoded_program) =
  let shapes = Hashtbl.create 16 in
  let rec collect_decl (decl : Core.core_decl) =
    match decl.cd_desc with
    | Core.CDRecord record ->
        Hashtbl.replace shapes record.record_name
          (List.map (fun field -> field.Ast.field_name) record.record_fields)
    | Core.CDPrivate inner -> collect_decl inner
    | _ -> ()
  in
  List.iter collect_decl program.core;
  let validate_expr path expr =
    let violation =
      Core.fold_tree
        (fun existing node ->
          match existing with
          | Some _ -> existing
          | None -> (
              match node.Core.desc with
              | Core.CRecordUpdate (_, fields) -> (
                  match node.ty with
                  | Ast.TyNamed (record_name, _) -> (
                      let actual = List.map fst fields in
                      match Hashtbl.find_opt shapes record_name with
                      | Some expected when actual = expected -> None
                      | Some _ ->
                          Some
                            (Printf.sprintf
                               "record update for `%s` must contain every \
                                declared field exactly once in declaration \
                                order"
                               record_name)
                      | None ->
                          Some
                            (Printf.sprintf
                               "record update type `%s` has no matching record \
                                declaration"
                               record_name))
                  | _ ->
                      Some
                        "record update type must be a value or heap record")
              | _ -> None))
        None expr
    in
    match violation with
    | Some message -> error path message
    | None -> Ok ()
  in
  let rec validate_decl index (decl : Core.core_decl) =
    let path = Printf.sprintf "program.decls[%d]" index in
    match decl.cd_desc with
    | Core.CDFunc { cf_body = Some body; _ } ->
        validate_expr (path ^ ".body") body
    | Core.CDVar global -> validate_expr (path ^ ".init") global.cv_init
    | Core.CDImpl impl ->
        let rec validate_methods method_index = function
          | [] -> Ok ()
          | method_ :: rest ->
              let* () =
                match method_.Core.cf_body with
                | Some body ->
                    validate_expr
                      (Printf.sprintf "%s.methods[%d].body" path method_index)
                      body
                | None -> Ok ()
              in
              validate_methods (method_index + 1) rest
        in
        validate_methods 0 impl.ci_methods
    | Core.CDPrivate inner -> validate_decl index inner
    | _ -> Ok ()
  in
  let rec validate_decls index = function
    | [] -> Ok ()
    | decl :: rest ->
        let* () = validate_decl index decl in
        validate_decls (index + 1) rest
  in
  validate_decls 0 program.core

let decode_program value =
  let path = "program" in
  let* tag = kind path value in
  if tag <> "program" then error (path_field path "kind") "expected Core program"
  else
    let* decls = array_field path "decls" value in
    let* core = decode_list decode_decl (path_field path "decls") 0 decls in
    let* union_payload_storage =
      decode_union_payload_storage (path_field path "decls") 0 decls
    in
    let* foreign_includes = string_list_field path "foreign_includes" value in
    let program = { core; foreign_includes; union_payload_storage } in
    let* () = validate_record_update_storage_shapes program value in
    let* () = validate_record_update_shapes program in
    Ok program

let decode_error_to_string error = error.path ^ ": " ^ error.message
