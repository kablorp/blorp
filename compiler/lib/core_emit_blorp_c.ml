(** Blorp-owned C backend boundary for the supported tail-Core subset.

    This module is deliberately narrow: OCaml projects a supported
    post-closure/pre-resource Core subset to JSON, then Blorp owns the tail IR
    preparation and C artifact emission through the [prepare_and_emit_c] bridge
    action. Unsupported Core shapes are rejected before the bridge call so the
    subset boundary remains explicit. *)

type unsupported = { path : string; reason : string }

module IntSet = Set.Make (Int)
module StringSet = Set.Make (String)
module StringMap = Map.Make (String)

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
let float value = Lsp_json.Float value
let bool value = Lsp_json.Bool value
let null = Lsp_json.Null
let kind tag fields = obj (("kind", str tag) :: fields)
let option_int_json = function Some value -> int value | None -> null
let option_string_json = function Some value -> str value | None -> null
let string_list_json values = arr (List.map str values)

let supported_sized_integer_conversion_builtins =
  StringSet.of_list
    [
      "blorp_to_int8";
      "blorp_to_int16";
      "blorp_to_int32";
      "blorp_to_int128";
      "blorp_to_uint8";
      "blorp_to_uint16";
      "blorp_to_uint32";
      "blorp_to_uint64";
      "blorp_to_uint128";
    ]

let supported_primitive_runtime_builtins =
  StringSet.of_list
    [
      "blorp_black_box_float";
      "blorp_black_box_int";
	      "blorp_bool_to_string";
	      "blorp_dict_get_int";
	      "blorp_dict_new";
	      "blorp_dict_new_float";
	      "blorp_dict_new_string";
	      "blorp_dict_remove";
	      "blorp_float16_to_string";
      "blorp_float32_to_string";
      "blorp_float_to_string";
      "blorp_now_us";
      "blorp_print";
      "blorp_print_error";
      "blorp_puts";
      "blorp_set_add";
      "blorp_set_new";
      "blorp_set_new_float";
      "blorp_set_new_string";
	      "blorp_set_remove";
	      "blorp_string_concat";
	      "blorp_string_eq";
	      "blorp_time_from_parts";
      "blorp_time_now";
      "blorp_time_to_day";
      "blorp_time_to_hour";
      "blorp_time_to_minute";
      "blorp_time_to_month";
      "blorp_time_to_second";
      "blorp_time_to_weekday";
      "blorp_time_to_year";
      "blorp_to_string";
    ]

let sized_integer_conversion_builtin_supported name =
  StringSet.mem name supported_sized_integer_conversion_builtins

let primitive_runtime_builtin_supported name =
  StringSet.mem name supported_primitive_runtime_builtins

let direct_builtin_supported name =
  sized_integer_conversion_builtin_supported name
  || primitive_runtime_builtin_supported name

let release_policy_tag ~reg (ty : Ast.type_expr) =
  if
    not
      (Core_layout_type.source_value_requires_release_or_error
         ~phase:Core_error.Emit ~reg ty Ast.dummy_loc)
  then "none"
  else if Core_layout_type.is_stack_result_type ~reg ty then "stack_result"
  else
    let layout =
      Core_layout_type.source_value_layout_of_type ~phase:Core_error.Emit ~reg
        ty Ast.dummy_loc
    in
    match Core_layout_type.source_value_release_path layout with
    | Core_layout_type.SourceValueArcReleaseOnly -> "arc_only"
    | Core_layout_type.SourceValueArcReleaseWithDestructor -> "arc"
    | Core_layout_type.SourceValueNoRelease -> "none"

let release_policy_json ~reg ty = str (release_policy_tag ~reg ty)

let retain_policy_tag ~reg (ty : Ast.type_expr) =
  if
    not
      (Core_layout_type.source_value_requires_retain_or_error
         ~phase:Core_error.Emit ~reg ty Ast.dummy_loc)
  then "none"
  else if Core_layout_type.is_stack_result_type ~reg ty then "stack_result"
  else "arc"

let retain_policy_json ~reg ty = str (retain_policy_tag ~reg ty)

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

let enum_constructor_key type_name constructor_name =
  type_name ^ "\000" ^ constructor_name

let enum_constructor_c_name_for_type enum_constructors ty (variable : Core.var)
    =
  match ty with
  | Ast.TyNamed (type_name, []) ->
      StringMap.find_opt
        (enum_constructor_key type_name variable.vname)
        enum_constructors
  | _ -> None

let var_json_for_expr enum_constructors ty (variable : Core.var) =
  let name =
    match enum_constructor_c_name_for_type enum_constructors ty variable with
    | Some c_name -> c_name
    | None -> Core.Var.to_c_name variable
  in
  obj
    [
      ("name", str name);
      ("uniq", int variable.vuniq);
      ("def_id", option_int_json variable.vdef_id);
    ]

let primitive_type_names =
  StringSet.of_list
    [
      "Int";
      "Int8";
      "Int16";
      "Int32";
      "Int64";
      "Int128";
      "UInt8";
      "UInt16";
      "UInt32";
      "UInt64";
      "UInt128";
      "Float";
      "Float32";
      "Float16";
      "Bool";
      "Char";
      "String";
      "Bytes";
    ]

let primitive_type_name name = StringSet.mem name primitive_type_names

let rec type_json ~reg enum_names value_record_names heap_record_names union_names path
    (ty : Ast.type_expr) =
  let ty = Codegen_types.expand_alias ~reg ty in
  match ty with
  | Ast.TyNamed ("Void", []) -> Ok (kind "void" [])
  | Ast.TyNamed (name, args) when primitive_type_name name ->
      let* arg_values =
        result_list args (fun index arg ->
            type_json ~reg enum_names value_record_names heap_record_names union_names
              (Printf.sprintf "%s.args[%d]" path index)
              arg)
      in
      Ok (kind "named" [ ("name", str name); ("args", arg_values) ])
  | Ast.TyNamed (name, []) when StringSet.mem name enum_names ->
      Ok (kind "enum" [ ("name", str name) ])
  | Ast.TyNamed (name, _ :: _) when StringSet.mem name enum_names ->
      unsupported path ("generic enum type " ^ name)
  | Ast.TyNamed (name, []) when StringSet.mem name value_record_names ->
      Ok (kind "value_record" [ ("name", str name) ])
  | Ast.TyNamed (name, _ :: _) when StringSet.mem name value_record_names ->
      unsupported path ("generic value record type " ^ name)
  | Ast.TyNamed (name, []) when StringSet.mem name heap_record_names ->
      Ok (kind "heap_record" [ ("name", str name) ])
  | Ast.TyNamed (name, _ :: _) when StringSet.mem name heap_record_names ->
      unsupported path ("generic heap record type " ^ name)
  | Ast.TyNamed (name, []) when StringSet.mem name union_names ->
      Ok (kind "union" [ ("name", str name) ])
  | Ast.TyNamed (name, _ :: _) when StringSet.mem name union_names ->
      unsupported path ("generic union type " ^ name)
  | Ast.TyNamed (name, args) ->
      let* arg_values =
        result_list args (fun index arg ->
            type_json ~reg enum_names value_record_names heap_record_names union_names
              (Printf.sprintf "%s.args[%d]" path index)
              arg)
      in
      Ok (kind "named" [ ("name", str name); ("args", arg_values) ])
  | Ast.TyConstInt _ ->
      Ok (kind "named" [ ("name", str "Int"); ("args", arr []) ])
  | Ast.TyTuple items ->
      let* item_values =
        result_list items (fun index item ->
            type_json ~reg enum_names value_record_names heap_record_names union_names
              (Printf.sprintf "%s.items[%d]" path index)
              item)
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
  | Ast.TyRange _ -> Ok (kind "range" [])
  | Ast.TyDimOp _ -> unsupported path "dimension operation"
  | Ast.TyMeta id ->
      unsupported path ("unresolved type meta " ^ string_of_int id)

let int64_fits_json_int value =
  let as_int = Int64.to_int value in
  Int64.equal (Int64.of_int as_int) value

let int64_to_json_int path value =
  let as_int = Int64.to_int value in
  if int64_fits_json_int value then Ok as_int
  else unsupported path "integer literal out of Blorp bridge Int range"

let literal_json path (literal : Ast.literal) =
  match literal with
  | Ast.LitInt value ->
      let* n = int64_to_json_int path value in
      Ok (kind "int" [ ("value", int n) ])
  | Ast.LitFloat value -> Ok (kind "float" [ ("value", float value) ])
  | Ast.LitBool value -> Ok (kind "bool" [ ("value", bool value) ])
  | Ast.LitChar value -> Ok (kind "char" [ ("value", int value) ])
  | Ast.LitString (value, _) -> Ok (kind "string" [ ("value", str value) ])
  | Ast.LitInt128 _ -> unsupported path "Int128 literal"

let literal_match_literal_json path (literal : Ast.literal) =
  match literal with
  | Ast.LitInt _ | Ast.LitFloat _ | Ast.LitBool _ | Ast.LitChar _ ->
      literal_json path literal
  | Ast.LitString _ -> unsupported path "string literal match"
  | Ast.LitInt128 _ -> unsupported path "Int128 literal match"

let static_scalar_global_literal_json path (literal : Ast.literal) =
  match literal with
  | Ast.LitInt _ | Ast.LitFloat _ | Ast.LitBool _ | Ast.LitChar _ ->
      literal_json path literal
  | Ast.LitString _ -> unsupported path "string global initializer"
  | Ast.LitInt128 _ -> unsupported path "Int128 global initializer"

let primitive_tuple_field_type = function
  | Ast.TyNamed
      ( ( "Int" | "Int8" | "Int16" | "Int32" | "Int64" | "UInt8" | "UInt16"
        | "UInt32" | "UInt64" | "Bool" | "Char" ),
        [] ) ->
      true
  | _ -> false

let managed_pointer_tuple_field_type = function
  | Ast.TyNamed (("String" | "Bytes" | "Fixed" | "Closure"), []) -> true
  | Ast.TyFunc _ -> true
  | Ast.TyNamed ("List", [ _ ]) -> true
  | Ast.TyNamed ("Dict", [ _; _ ]) -> true
  | Ast.TyNamed ("Set", [ _ ]) -> true
  | Ast.TyTuple _ -> true
  | _ -> false

let supported_tuple_field_type ty =
  primitive_tuple_field_type ty || managed_pointer_tuple_field_type ty

let pointer_tuple_field_type heap_record_names union_names = function
  | Ast.TyNamed
      ( ("String" | "Closure" | "List" | "Dict" | "Set" | "Ptr"),
        _ ) ->
      true
  | Ast.TyNamed (name, []) ->
      StringSet.mem name heap_record_names || StringSet.mem name union_names
  | Ast.TyFunc _ | Ast.TyTuple _ -> true
  | _ -> false

let supported_tuple_field_projection_type heap_record_names union_names ty =
  supported_tuple_field_type ty
  || pointer_tuple_field_type heap_record_names union_names ty

let tuple_field_index path arity field_name =
  match int_of_string_opt field_name with
  | Some index when index >= 0 && index < arity -> Ok index
  | Some index ->
      unsupported path
        (Printf.sprintf "tuple field index %d out of bounds for arity %d" index
           arity)
  | None -> unsupported path ("non-numeric tuple field " ^ field_name)

let tuple_element_tag path = function
  | Core.BoxPrim -> Ok "prim"
  | Core.BoxPointer -> Ok "pointer"
  | Core.BoxVoid -> Ok "void"
  | Core.BoxFloat -> unsupported path "float tuple slot"
  | Core.BoxFloat32 -> unsupported path "Float32 tuple slot"
  | Core.BoxFloat16 -> unsupported path "Float16 tuple slot"
  | Core.BoxInt128 -> unsupported path "Int128 tuple slot"
  | Core.BoxUInt128 -> unsupported path "UInt128 tuple slot"
  | Core.BoxStruct _ -> unsupported path "struct tuple slot"

let literal_match_leaf_body path = function
  | Core.CTLeaf { ct_bindings = []; ct_body } -> Ok ct_body
  | Core.CTLeaf { ct_bindings = _ :: _; _ } ->
      unsupported path "literal match bindings"
  | Core.CTFail -> unsupported path "literal match fail"
  | Core.CTSwitchTag _ -> unsupported path "nested constructor match"
  | Core.CTSwitchLit _ -> unsupported path "nested literal match"
  | Core.CTSwitchLen _ -> unsupported path "nested length match"

let constructor_match_leaf_body path = function
  | Core.CTLeaf { ct_bindings; ct_body } -> Ok (ct_bindings, ct_body)
  | Core.CTFail -> unsupported path "constructor match fail case"
  | Core.CTSwitchTag _ -> unsupported path "nested constructor match"
  | Core.CTSwitchLit _ -> unsupported path "nested literal match"
  | Core.CTSwitchLen _ -> unsupported path "nested length match"

let union_constructor_tag_c_name type_name ctor =
  Printf.sprintf "TAG_%s_%s"
    (Codegen_names.sanitize_c_ident type_name)
    (Codegen_names.sanitize_c_ident ctor)

let constructor_match_test_json ~reg enum_names union_names enum_constructors path
    scrut_ty ctor =
  match scrut_ty with
  | Ast.TyNamed ("Option", [ _ ])
    when Core_layout_type.is_stack_option_type ~reg scrut_ty -> (
      match ctor with
      | "Some" -> Ok (kind "stack_option_some" [])
      | "None" -> Ok (kind "stack_option_none" [])
      | _ -> unsupported path ("unknown stack Option constructor " ^ ctor))
  | Ast.TyNamed ("Option", [ _ ])
    when Core_layout_type.is_nullable_managed_option ~reg scrut_ty -> (
      match ctor with
      | "Some" -> Ok (kind "nullable_option_some" [])
      | "None" -> Ok (kind "nullable_option_none" [])
      | _ -> unsupported path ("unknown nullable Option constructor " ^ ctor))
  | Ast.TyNamed (type_name, []) when StringSet.mem type_name enum_names -> (
      match
        StringMap.find_opt
          (enum_constructor_key type_name ctor)
          enum_constructors
      with
      | Some c_name -> Ok (kind "enum" [ ("c_name", str c_name) ])
      | None -> unsupported path ("unknown enum constructor " ^ ctor))
  | Ast.TyNamed (type_name, []) when StringSet.mem type_name union_names ->
      Ok
        (kind "union_tag"
           [ ("tag_c_name", str (union_constructor_tag_c_name type_name ctor)) ])
  | Ast.TyNamed (_type_name, _ :: _) ->
      unsupported path "constructor match on generic type"
  | _ -> unsupported path "constructor match on non-enum or non-union type"

let rec match_accessor_json ~reg scrut_ty path = function
  | Core.AccRoot -> Ok (kind "root" [])
  | Core.AccVariantField (Core.AccRoot, "Some", 0)
    when Core_layout_type.is_stack_option_type ~reg scrut_ty ->
      let* parent = match_accessor_json ~reg scrut_ty (path ^ ".parent") Core.AccRoot in
      Ok (kind "stack_option_payload" [ ("parent", parent) ])
  | Core.AccVariantField (Core.AccRoot, "Some", 0)
    when Core_layout_type.is_nullable_managed_option ~reg scrut_ty ->
      let* parent = match_accessor_json ~reg scrut_ty (path ^ ".parent") Core.AccRoot in
      Ok (kind "nullable_option_payload" [ ("parent", parent) ])
  | Core.AccVariantField (Core.AccRoot, ctor, idx) ->
      let* parent = match_accessor_json ~reg scrut_ty (path ^ ".parent") Core.AccRoot in
      Ok
        (kind "variant_field"
           [
             ("parent", parent);
             ("constructor", str ctor);
             ("field_index", int idx);
           ])
  | Core.AccVariantField _ ->
      unsupported path "nested variant match binding accessor"
  | Core.AccTupleField _ -> unsupported path "tuple match binding accessor"
  | Core.AccListElem _ -> unsupported path "list element match binding accessor"
  | Core.AccListSpread _ -> unsupported path "list spread match binding accessor"

let match_binding_mode_json path = function
  | Core.MatchBorrow -> Ok (str "borrow")
  | Core.MatchOwn -> unsupported path "owned match binding"

let match_binding_json ~reg enum_names value_record_names heap_record_names union_names
    scrut_ty var_types path (binding : Core.match_binding) =
  let binding_ty =
    Core_emit_util.find_var_type binding.mb_var.vname var_types
  in
  match binding_ty with
  | Ast.TyVar "?" -> unsupported (path ^ ".type") "match binding type unavailable"
  | _ ->
      let* typ =
        type_json ~reg enum_names value_record_names heap_record_names union_names
          (path ^ ".type") binding_ty
      in
      let* accessor =
        match_accessor_json ~reg scrut_ty (path ^ ".accessor")
          binding.mb_accessor
      in
      let* mode = match_binding_mode_json (path ^ ".mode") binding.mb_mode in
      Ok
        (obj
           [
             ("variable", var_json binding.mb_var);
             ("type", typ);
             ("accessor", accessor);
             ("mode", mode);
           ])

let match_bindings_json ~reg enum_names value_record_names heap_record_names union_names
    scrut_ty var_types path bindings =
  result_list bindings (fun index binding ->
      match_binding_json ~reg enum_names value_record_names heap_record_names
        union_names scrut_ty var_types
        (Printf.sprintf "%s[%d]" path index)
        binding)

let param_json ~reg enum_names value_record_names heap_record_names union_names path
    (param : Core.core_param) =
  let* typ =
    type_json ~reg enum_names value_record_names heap_record_names union_names (path ^ ".type")
      param.cp_ty
  in
  Ok
    (obj
       [
         ("name", var_json param.cp_name);
         ("type", typ);
         ("loc", source_loc_json param.cp_loc);
       ])

let closure_param_json ~reg enum_names value_record_names heap_record_names union_names
    path (param_var, param_ty) =
  let* typ =
    type_json ~reg enum_names value_record_names heap_record_names union_names
      (path ^ ".type") param_ty
  in
  Ok
    (obj
       [
         ("name", var_json param_var);
         ("type", typ);
         ("loc", source_loc_json Ast.dummy_loc);
       ])

let closure_params_json ~reg enum_names value_record_names heap_record_names union_names
    path params =
  result_list params (fun index param ->
      closure_param_json ~reg enum_names value_record_names heap_record_names
        union_names
        (Printf.sprintf "%s[%d]" path index)
        param)

let closure_capture_json ~reg enum_names value_record_names heap_record_names
    union_names path (name, capture_ty) =
  let* typ =
    type_json ~reg enum_names value_record_names heap_record_names union_names
      (path ^ ".type") capture_ty
  in
  Ok (obj [ ("name", str name); ("type", typ) ])

let closure_captures_json ~reg enum_names value_record_names heap_record_names
    union_names path captures =
  result_list captures (fun index capture ->
      closure_capture_json ~reg enum_names value_record_names heap_record_names
        union_names
        (Printf.sprintf "%s[%d]" path index)
        capture)

let closure_abi_json ~reg enum_names value_record_names heap_record_names union_names
    path c_name (abi : Core.closure_abi) =
  let* params =
    closure_params_json ~reg enum_names value_record_names heap_record_names
      union_names (path ^ ".params") abi.ca_params
  in
  let* captures =
    closure_captures_json ~reg enum_names value_record_names heap_record_names
      union_names (path ^ ".captures") abi.ca_captures
  in
  Ok
    (obj
       [
         ("c_name", str c_name);
         ("params", params);
         ("captures", captures);
         ("moved_captures", string_list_json abi.ca_moved_captures);
         ("task_abi", bool abi.ca_task_abi);
       ])

let scalar_closure_capture_type = function
  | Ast.TyNamed
      ( ( "Int" | "Int8" | "Int16" | "Int32" | "Int64" | "UInt8" | "UInt16"
        | "UInt32" | "UInt64" | "Bool" | "Char" ),
        [] ) ->
      true
  | _ -> false

let managed_pointer_closure_capture_type = function
  | Ast.TyNamed (("String" | "Bytes" | "Fixed"), []) -> true
  | Ast.TyFunc _ -> true
  | Ast.TyNamed ("List", [ _ ]) -> true
  | Ast.TyNamed ("Dict", [ _; _ ]) -> true
  | Ast.TyNamed ("Set", [ _ ]) -> true
  | _ -> false

let supported_closure_capture_type ty =
  scalar_closure_capture_type ty || managed_pointer_closure_capture_type ty

let rec require_supported_closure_captures path index captures =
  match captures with
  | [] -> Ok ()
  | (_, capture_ty) :: rest ->
      if supported_closure_capture_type capture_ty then
        require_supported_closure_captures path (index + 1) rest
      else
        unsupported
          (Printf.sprintf "%s[%d]" path index)
          "unsupported closure capture type"

let require_closure_body_abi path (abi : Core.closure_abi) =
  match (abi.ca_captures, abi.ca_moved_captures, abi.ca_task_abi) with
  | captures, [], false ->
      require_supported_closure_captures (path ^ ".captures") 0 captures
  | [], _ :: _, _ -> unsupported path "closure body moved captures"
  | [], [], true -> unsupported path "task closure ABI"
  | _ :: _, _ :: _, _ -> unsupported path "closure body moved captures"
  | _ :: _, [], true -> unsupported path "task closure ABI"

let loop_range_direction_json = function
  | Core.RangeMayRunBackward -> str "may_run_backward"
  | Core.RangeForwardOnly -> str "forward_only"

let loop_binder_json ~reg enum_names value_record_names heap_record_names union_names path
    (binder : Core.loop_binder) =
  let* typ =
    type_json ~reg enum_names value_record_names heap_record_names union_names (path ^ ".type")
      binder.loop_ty
  in
  Ok
    (obj
       [
         ("var", var_json binder.loop_var);
         ("type", typ);
         ( "range_direction",
           loop_range_direction_json binder.loop_range_direction );
       ])

let call_kind_json path (call_kind : Core.call_kind) =
  match call_kind with
  | Core.CKUser (name, def_id) ->
      Ok
        (kind "user" [ ("name", str name); ("def_id", option_int_json def_id) ])
  | Core.CKForeign _ -> unsupported path "foreign call"
  | Core.CKBuiltin name when direct_builtin_supported name ->
      Ok (kind "builtin" [ ("name", str name) ])
  | Core.CKBuiltin name -> unsupported path ("builtin call " ^ name)
  | Core.CKIntrinsic name -> Ok (kind "intrinsic" [ ("name", str name) ])
  | Core.CKClosure -> Ok (kind "closure" [])
  | Core.CKUnknown -> unsupported path "unresolved call kind"
  | Core.CKSelectedDirect _ -> unsupported path "selected direct call kind"

let require_closure_create path (closure : Core.closure_create) =
  require_supported_closure_captures (path ^ ".captures") 0 closure.cc_captures

let closure_create_json ~reg enum_names value_record_names heap_record_names
    union_names path (closure : Core.closure_create) =
  let* () = require_closure_create path closure in
  let c_name =
    Codegen_names.mangle_by_def_id closure.cc_def_id closure.cc_func
  in
  let* captures =
    closure_captures_json ~reg enum_names value_record_names heap_record_names
      union_names (path ^ ".captures") closure.cc_captures
  in
  Ok
    (obj
       [
         ("function_name", str closure.cc_func);
         ("def_id", int closure.cc_def_id);
         ("c_name", str c_name);
         ("static_name", str ("__sc_" ^ c_name));
         ("captures", captures);
       ])

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

let rec expr_json ~reg enum_names value_record_names heap_record_names union_names
    enum_constructors path (expr : Core.core) =
  let loc = source_loc_json expr.loc in
  let typed fields =
    let* typ =
      type_json ~reg enum_names value_record_names heap_record_names union_names (path ^ ".type")
        expr.ty
    in
    Ok (fields @ [ ("type", typ); ("loc", loc) ])
  in
  let literal_match_fallback_json path = function
    | Core.CTLeaf { ct_bindings = []; ct_body } ->
        let* body =
          expr_json ~reg enum_names value_record_names heap_record_names union_names
            enum_constructors (path ^ ".body") ct_body
        in
        Ok (kind "body" [ ("body", body) ])
    | Core.CTLeaf { ct_bindings = _ :: _; _ } ->
        unsupported path "literal match fallback bindings"
    | Core.CTFail -> Ok (kind "fail" [])
    | Core.CTSwitchTag _ -> unsupported path "nested constructor match fallback"
    | Core.CTSwitchLit _ -> unsupported path "nested literal match fallback"
    | Core.CTSwitchLen _ -> unsupported path "nested length match fallback"
  in
  match expr.desc with
  | Core.CLit literal ->
      let* literal_value = literal_json (path ^ ".literal") literal in
      let* fields = typed [ ("literal", literal_value) ] in
      Ok (kind "literal" fields)
  | Core.CVar variable ->
      let* fields =
        typed [ ("var", var_json_for_expr enum_constructors expr.ty variable) ]
      in
      Ok (kind "var" fields)
  | Core.CVoid ->
      let* fields = typed [] in
      Ok (kind "void" fields)
  | Core.CCooperativeCheckpoint ->
      let* fields = typed [] in
      Ok (kind "cooperative_checkpoint" fields)
  | Core.CCall (Core.CKIntrinsic "list_retain_for", _callee, [ lst; value ]) ->
      let layout =
        Core_layout_type.list_storage_layout_of_type ~reg lst.ty lst.loc
      in
      let* requires_retain =
        list_layout_requires_retain (path ^ ".layout") layout
      in
      if requires_retain then
        let* retain =
          list_retain_json ~reg enum_names value_record_names heap_record_names union_names
            enum_constructors (path ^ ".retain") lst value
        in
        let* fields = typed [ ("retain", retain) ] in
        Ok (kind "list_retain" fields)
      else
        let* fields = typed [] in
        Ok (kind "void" fields)
  | Core.CCall
      ( (Core.CKIntrinsic "list_set" | Core.CKIntrinsic "list_set_owned"),
        _callee,
        [ lst; index; value ] ) ->
      let layout =
        Core_layout_type.list_storage_layout_of_type ~reg lst.ty lst.loc
      in
      let* set =
        list_set_json ~reg enum_names value_record_names heap_record_names union_names
          enum_constructors (path ^ ".set") layout lst index value
      in
      let* fields = typed [ ("set", set) ] in
      Ok (kind "list_set" fields)
  | Core.CCall
      (Core.CKIntrinsic "list_handoff_set_owned", _callee, [ lst; index; value ])
    ->
      let layout =
        Core_layout_type.list_storage_layout_of_type ~reg lst.ty lst.loc
      in
      let* set =
        list_set_json ~reg enum_names value_record_names heap_record_names union_names
          enum_constructors (path ^ ".set") layout lst index value
      in
      let* fields = typed [ ("set", set) ] in
      Ok (kind "list_handoff_set_owned" fields)
  | Core.CCall
      ( Core.CKIntrinsic "list_handoff_set_source_slot",
        _callee,
        [ result; out_index; source; source_index ] ) ->
      let* slot =
        list_handoff_set_source_slot_json ~reg enum_names value_record_names
          heap_record_names union_names enum_constructors (path ^ ".slot")
          result out_index source source_index
      in
      let* fields = typed [ ("slot", slot) ] in
      Ok (kind "list_handoff_set_source_slot" fields)
  | Core.CCall
      ( (Core.CKBuiltin "blorp_list_new" | Core.CKIntrinsic "list_alloc"),
        _callee,
        [ capacity ] ) ->
      let layout =
        Core_layout_type.list_storage_layout_of_type ~reg expr.ty expr.loc
      in
      let alloc = { Core.la_layout = layout; la_capacity = capacity } in
      let* alloc_json =
        list_alloc_json ~reg enum_names value_record_names heap_record_names union_names
          enum_constructors (path ^ ".alloc") expr.loc alloc
      in
      let* fields = typed [ ("alloc", alloc_json) ] in
      Ok (kind "list_alloc" fields)
  | Core.CCall (Core.CKIntrinsic "list_get", _callee, [ lst; index ]) ->
      let get =
        {
          Core.lg_layout =
            Core_layout_type.list_storage_layout_of_type ~reg lst.ty lst.loc;
          lg_list = lst;
          lg_index = index;
          lg_bounds = Core.ListBoundsChecked;
        }
      in
      let* get_json =
        list_get_json ~reg enum_names value_record_names heap_record_names union_names
          enum_constructors (path ^ ".get") get
      in
      let* fields = typed [ ("get", get_json) ] in
      Ok (kind "list_get" fields)
  | Core.CCall (Core.CKIntrinsic "list_get_unchecked", _callee, [ lst; index ])
    ->
      let get =
        {
          Core.lg_layout =
            Core_layout_type.list_storage_layout_of_type ~reg lst.ty lst.loc;
          lg_list = lst;
          lg_index = index;
          lg_bounds = Core.ListBoundsProven;
        }
      in
      let* get_json =
        list_get_json ~reg enum_names value_record_names heap_record_names union_names
          enum_constructors (path ^ ".get") get
      in
      let* fields = typed [ ("get", get_json) ] in
      Ok (kind "list_get" fields)
  | Core.CCall (call_kind, callee, args) ->
      let* call_kind_value = call_kind_json (path ^ ".call_kind") call_kind in
      let* callee_value =
        expr_json ~reg enum_names value_record_names heap_record_names union_names
          enum_constructors (path ^ ".callee") callee
      in
      let* args_value =
        result_list args (fun index arg ->
            expr_json ~reg enum_names value_record_names heap_record_names union_names
              enum_constructors
              (Printf.sprintf "%s.args[%d]" path index)
              arg)
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
          let* left_value =
            expr_json ~reg enum_names value_record_names heap_record_names union_names
              enum_constructors (path ^ ".left") left
          in
          let* right_value =
            expr_json ~reg enum_names value_record_names heap_record_names union_names
              enum_constructors (path ^ ".right") right
          in
          let* fields =
            typed
              [
                ("op", str op_tag); ("left", left_value); ("right", right_value);
              ]
          in
          Ok (kind "binary" fields))
  | Core.CUn (op, inner) ->
      let* inner_value =
        expr_json ~reg enum_names value_record_names heap_record_names union_names
          enum_constructors (path ^ ".expr") inner
      in
      let* fields =
        typed [ ("op", str (unop_tag op)); ("expr", inner_value) ]
      in
      Ok (kind "unary" fields)
  | Core.CLog (op, left, right) ->
      let* left_value =
        expr_json ~reg enum_names value_record_names heap_record_names union_names
          enum_constructors (path ^ ".left") left
      in
      let* right_value =
        expr_json ~reg enum_names value_record_names heap_record_names union_names
          enum_constructors (path ^ ".right") right
      in
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
      let* rhs_value =
        expr_json ~reg enum_names value_record_names heap_record_names union_names
          enum_constructors (path ^ ".rhs") rhs
      in
      let* fields = typed [ ("var", var_json variable); ("rhs", rhs_value) ] in
      Ok (kind "assign" fields)
  | Core.CCast (inner, target_ty) ->
      let* inner_value =
        expr_json ~reg enum_names value_record_names heap_record_names union_names
          enum_constructors (path ^ ".expr") inner
      in
      let* typ =
        type_json ~reg enum_names value_record_names heap_record_names union_names (path ^ ".type")
          target_ty
      in
      Ok
        (kind "cast"
           [
             ("expr", inner_value);
             ("type", typ);
             ("loc", source_loc_json expr.loc);
           ])
  | Core.CField (inner, field_name) -> (
      match inner.ty with
      | Ast.TyRange _
        when String.equal field_name "start" || String.equal field_name "end" ->
          let* inner_value =
            expr_json ~reg enum_names value_record_names heap_record_names union_names
              enum_constructors (path ^ ".expr") inner
          in
          let* fields =
            typed [ ("expr", inner_value); ("field", str field_name) ]
          in
          Ok (kind "field" fields)
      | Ast.TyRange _ -> unsupported path ("unknown range field " ^ field_name)
      | Ast.TyNamed (name, []) when StringSet.mem name value_record_names ->
          let* inner_value =
            expr_json ~reg enum_names value_record_names heap_record_names union_names
              enum_constructors (path ^ ".expr") inner
          in
          let* fields =
            typed [ ("expr", inner_value); ("field", str field_name) ]
          in
          Ok (kind "field" fields)
      | Ast.TyNamed (name, []) when StringSet.mem name heap_record_names ->
          let* inner_value =
            expr_json ~reg enum_names value_record_names heap_record_names union_names
              enum_constructors (path ^ ".expr") inner
          in
          let* fields =
            typed [ ("expr", inner_value); ("field", str field_name) ]
          in
          Ok (kind "field" fields)
      | Ast.TyNamed ("Module", []) -> (
          match expr.ty with
          | Ast.TyFunc _ ->
              let* inner_value =
                expr_json ~reg enum_names value_record_names heap_record_names
                  union_names enum_constructors (path ^ ".expr") inner
              in
              let* fields =
                typed [ ("expr", inner_value); ("field", str field_name) ]
              in
              Ok (kind "field" fields)
          | _ ->
              unsupported path
                (Printf.sprintf
                   "module field value was not resolved before backend: %s.%s"
                   (Types.type_to_string inner.ty)
                   field_name))
      | Ast.TyTuple items ->
          if
            not
              (supported_tuple_field_projection_type heap_record_names
                 union_names expr.ty)
          then
            unsupported path "tuple field type outside Blorp backend subset"
          else
            let* field_index =
              tuple_field_index (path ^ ".field") (List.length items) field_name
            in
            let* inner_value =
              expr_json ~reg enum_names value_record_names heap_record_names union_names
                enum_constructors (path ^ ".expr") inner
            in
            let* fields =
              typed [ ("expr", inner_value); ("index", int field_index) ]
            in
            Ok (kind "tuple_field" fields)
      | _ ->
          unsupported path
            (Printf.sprintf
               "field access on non-record, range, or tuple: %s.%s"
               (Types.type_to_string inner.ty)
               field_name))
  | Core.CLet (binding, body) ->
      let* typ =
        type_json ~reg enum_names value_record_names heap_record_names union_names (path ^ ".type")
          binding.bind_ty
      in
      let* rhs =
        expr_json ~reg enum_names value_record_names heap_record_names union_names
          enum_constructors (path ^ ".rhs") binding.bind_rhs
      in
      let* body =
        expr_json ~reg enum_names value_record_names heap_record_names union_names
          enum_constructors (path ^ ".body") body
      in
      Ok
        (kind "let"
           [
             ("name", var_json binding.bind_var);
             ("mutable", bool binding.bind_mut);
             ("type", typ);
             ("rhs", rhs);
             ("body", body);
           ])
  | Core.CBorrowLet (binding, body) ->
      let* typ =
        type_json ~reg enum_names value_record_names heap_record_names union_names (path ^ ".type")
          binding.borrow_ty
      in
      let* rhs =
        expr_json ~reg enum_names value_record_names heap_record_names union_names
          enum_constructors (path ^ ".rhs") binding.borrow_rhs
      in
      let* body =
        expr_json ~reg enum_names value_record_names heap_record_names union_names
          enum_constructors (path ^ ".body") body
      in
      Ok
        (kind "let"
           [
             ("name", var_json binding.borrow_var);
             ("mutable", bool false);
             ("type", typ);
             ("rhs", rhs);
             ("body", body);
           ])
  | Core.CSeq (first, second) ->
      let* first_value =
        expr_json ~reg enum_names value_record_names heap_record_names union_names
          enum_constructors (path ^ ".first") first
      in
      let* second_value =
        expr_json ~reg enum_names value_record_names heap_record_names union_names
          enum_constructors (path ^ ".second") second
      in
      Ok (kind "seq" [ ("first", first_value); ("second", second_value) ])
  | Core.CIf (cond, then_expr, else_expr) ->
      let* cond_value =
        expr_json ~reg enum_names value_record_names heap_record_names union_names
          enum_constructors (path ^ ".cond") cond
      in
      let* then_value =
        expr_json ~reg enum_names value_record_names heap_record_names union_names
          enum_constructors (path ^ ".then") then_expr
      in
      let* else_value =
        expr_json ~reg enum_names value_record_names heap_record_names union_names
          enum_constructors (path ^ ".else") else_expr
      in
      let* fields =
        typed
          [ ("cond", cond_value); ("then", then_value); ("else", else_value) ]
      in
      Ok (kind "if" fields)
  | Core.CWhile (cond, body) ->
      let* cond_value =
        expr_json ~reg enum_names value_record_names heap_record_names union_names
          enum_constructors (path ^ ".cond") cond
      in
      let* body_value =
        expr_json ~reg enum_names value_record_names heap_record_names union_names
          enum_constructors (path ^ ".body") body
      in
      let* fields = typed [ ("cond", cond_value); ("body", body_value) ] in
      Ok (kind "while" fields)
  | Core.CFor (binder, { desc = Core.CRange (lo, hi); _ }, body) ->
      let* binder_value =
        loop_binder_json ~reg enum_names value_record_names heap_record_names union_names
          (path ^ ".binder") binder
      in
      let* start_value =
        expr_json ~reg enum_names value_record_names heap_record_names union_names
          enum_constructors (path ^ ".start") lo
      in
      let* end_value =
        expr_json ~reg enum_names value_record_names heap_record_names union_names
          enum_constructors (path ^ ".end") hi
      in
      let* body_value =
        expr_json ~reg enum_names value_record_names heap_record_names union_names
          enum_constructors (path ^ ".body") body
      in
      let* fields =
        typed
          [
            ("binder", binder_value);
            ("start", start_value);
            ("end", end_value);
            ("body", body_value);
          ]
      in
      Ok (kind "for_range" fields)
  | Core.CFor (binder, iter, body) -> (
      match iter.ty with
      | Ast.TyNamed ("List", _) ->
          let layout =
            Core_layout_type.list_storage_layout_of_type ~reg iter.ty iter.loc
          in
          let* for_list =
            for_list_json ~reg enum_names value_record_names heap_record_names union_names
              enum_constructors (path ^ ".for_list") binder layout iter body
          in
          let* fields = typed [ ("for_list", for_list) ] in
          Ok (kind "for_list" fields)
      | _ -> unsupported path "non-range for loop")
  | Core.CRange (lo, hi) -> (
      match expr.ty with
      | Ast.TyRange _ ->
          let* start_value =
            expr_json ~reg enum_names value_record_names heap_record_names union_names
              enum_constructors (path ^ ".start") lo
          in
          let* end_value =
            expr_json ~reg enum_names value_record_names heap_record_names union_names
              enum_constructors (path ^ ".end") hi
          in
          let* fields = typed [ ("start", start_value); ("end", end_value) ] in
          Ok (kind "range" fields)
      | Ast.TyNamed (name, []) when StringSet.mem name value_record_names ->
          let* start_value =
            expr_json ~reg enum_names value_record_names heap_record_names union_names
              enum_constructors (path ^ ".start") lo
          in
          let* end_value =
            expr_json ~reg enum_names value_record_names heap_record_names union_names
              enum_constructors (path ^ ".end") hi
          in
          let* fields = typed [ ("start", start_value); ("end", end_value) ] in
          Ok (kind "range" fields)
      | _ -> unsupported path "range expression with non-range type")
  | Core.CMatch
      ( scrutinee,
        Core.CTSwitchLit { ctl_scrut = Core.AccRoot; ctl_cases; ctl_default } )
    ->
      let* scrutinee_value =
        expr_json ~reg enum_names value_record_names heap_record_names union_names
          enum_constructors (path ^ ".scrutinee") scrutinee
      in
      let* cases_value =
        result_list ctl_cases (fun index (literal, subtree) ->
            let case_path = Printf.sprintf "%s.cases[%d]" path index in
            let* literal_value =
              literal_match_literal_json (case_path ^ ".literal") literal
            in
            let* body = literal_match_leaf_body (case_path ^ ".body") subtree in
            let* body_value =
              expr_json ~reg enum_names value_record_names heap_record_names union_names
                enum_constructors (case_path ^ ".body") body
            in
            Ok (obj [ ("literal", literal_value); ("body", body_value) ]))
      in
      let* fallback_value =
        literal_match_fallback_json (path ^ ".fallback") ctl_default
      in
      let* fields =
        typed
          [
            ("scrutinee", scrutinee_value);
            ("cases", cases_value);
            ("fallback", fallback_value);
          ]
      in
      Ok (kind "literal_match" fields)
  | Core.CMatch
      ( scrutinee,
        Core.CTSwitchTag { cts_scrut = Core.AccRoot; cts_cases; cts_default } )
    ->
      let constructor_match_fallback_json path = function
        | None -> Ok (kind "fail" [])
        | Some Core.CTFail -> Ok (kind "fail" [])
        | Some (Core.CTLeaf { ct_bindings = []; ct_body }) ->
            let* body =
              expr_json ~reg enum_names value_record_names heap_record_names union_names
                enum_constructors (path ^ ".body") ct_body
            in
            Ok (kind "body" [ ("body", body) ])
        | Some (Core.CTLeaf { ct_bindings = _ :: _; _ }) ->
            unsupported path "constructor match fallback bindings"
        | Some (Core.CTSwitchTag _) ->
            unsupported path "nested constructor match fallback"
        | Some (Core.CTSwitchLit _) ->
            unsupported path "nested literal match fallback"
        | Some (Core.CTSwitchLen _) ->
            unsupported path "nested length match fallback"
      in
      let* scrutinee_value =
        expr_json ~reg enum_names value_record_names heap_record_names union_names
          enum_constructors (path ^ ".scrutinee") scrutinee
      in
      let* cases_value =
        result_list cts_cases (fun index (ctor, subtree) ->
            let case_path = Printf.sprintf "%s.cases[%d]" path index in
            let* constructor_test =
              constructor_match_test_json ~reg enum_names union_names enum_constructors
                (case_path ^ ".test") scrutinee.ty ctor
            in
            let* bindings, body =
              constructor_match_leaf_body (case_path ^ ".body") subtree
            in
            let var_types = Core_emit_util.collect_var_types body in
            let* bindings_value =
              match_bindings_json ~reg enum_names value_record_names
                heap_record_names union_names scrutinee.ty var_types
                (case_path ^ ".bindings") bindings
            in
            let* body_value =
              expr_json ~reg enum_names value_record_names heap_record_names union_names
                enum_constructors (case_path ^ ".body") body
            in
            Ok
              (obj
                 [
                   ("constructor", str ctor);
                   ("test", constructor_test);
                   ("bindings", bindings_value);
                   ("body", body_value);
                 ]))
      in
      let* fallback_value =
        constructor_match_fallback_json (path ^ ".fallback") cts_default
      in
      let* fields =
        typed
          [
            ("scrutinee", scrutinee_value);
            ("cases", cases_value);
            ("fallback", fallback_value);
          ]
      in
      Ok (kind "constructor_match" fields)
  | Core.CBreak ->
      let* fields = typed [] in
      Ok (kind "break" fields)
  | Core.CContinue ->
      let* fields = typed [] in
      Ok (kind "continue" fields)
  | Core.CDup (variable, value_ty, body) ->
      let* value_type =
        type_json ~reg enum_names value_record_names heap_record_names union_names
          (path ^ ".value_type") value_ty
      in
      let retain_policy = retain_policy_json ~reg value_ty in
      let* body_value =
        expr_json ~reg enum_names value_record_names heap_record_names union_names
          enum_constructors (path ^ ".body") body
      in
      let* fields =
        typed
          [
            ("var", var_json variable);
            ("value_type", value_type);
            ("retain_policy", retain_policy);
            ("body", body_value);
          ]
      in
      Ok (kind "dup" fields)
  | Core.CDrop (variable, value_ty, body) ->
      let* value_type =
        type_json ~reg enum_names value_record_names heap_record_names union_names
          (path ^ ".value_type") value_ty
      in
      let release_policy = release_policy_json ~reg value_ty in
      let* body_value =
        expr_json ~reg enum_names value_record_names heap_record_names union_names
          enum_constructors (path ^ ".body") body
      in
      let* fields =
        typed
          [
            ("var", var_json variable);
            ("value_type", value_type);
            ("release_policy", release_policy);
            ("body", body_value);
          ]
      in
      Ok (kind "drop" fields)
  | Core.CTailrecLoop
      (Core.TailrecUnmanagedLoop { tul_params; tul_return_ty; tul_body }) ->
      let* params =
        result_list tul_params (fun index param ->
            param_json ~reg enum_names value_record_names heap_record_names union_names
              (Printf.sprintf "%s.params[%d]" path index)
              param)
      in
      let* return_type =
        type_json ~reg enum_names value_record_names heap_record_names union_names
          (path ^ ".return_type") tul_return_ty
      in
      let* body_value =
        expr_json ~reg enum_names value_record_names heap_record_names union_names
          enum_constructors (path ^ ".body") tul_body
      in
      Ok
        (kind "tailrec_loop"
           [
             ("params", params);
             ("return_type", return_type);
             ("body", body_value);
             ("loc", loc);
           ])
  | Core.CTailrecLoop (Core.TailrecListSpreadLoop _) ->
      unsupported path "list-spread tail-recursive loop"
  | Core.CTailrecRecur (Core.TailrecRecur { tr_args }) ->
      let* args_value =
        result_list tr_args (fun index arg ->
            expr_json ~reg enum_names value_record_names heap_record_names union_names
              enum_constructors
              (Printf.sprintf "%s.args[%d]" path index)
              arg)
      in
      let* fields = typed [ ("args", args_value) ] in
      Ok (kind "tailrec_recur" fields)
  | Core.CTailrecRecur (Core.TailrecListSpreadRecur _) ->
      unsupported path "list-spread tail-recursive recur"
  | Core.CTupleConstruct tc ->
      let* elements =
        result_list tc.tc_elems (fun index element ->
            let element_path =
              Printf.sprintf "%s.construct.elements[%d]" path index
            in
            let* element_tag =
              tuple_element_tag (element_path ^ ".kind") element.bsv_box.box_kind
            in
            let* value =
              expr_json ~reg enum_names value_record_names heap_record_names union_names
                enum_constructors (element_path ^ ".value")
                element.bsv_box.box_value
            in
            let fields =
              match element.bsv_box.box_kind with
              | Core.BoxVoid -> []
              | _ -> [ ("value", value) ]
            in
            Ok (kind element_tag fields))
      in
      let construct =
        obj
          [
            ("elements", elements);
            ("release_mask", int tc.tc_release_mask);
            ("retain_mask", int tc.tc_retain_mask);
          ]
      in
      let* fields = typed [ ("construct", construct) ] in
      Ok (kind "tuple_construct" fields)
  | Core.CTuple items -> (
      match expr.ty with
      | Ast.TyTuple item_tys
        when List.length items = List.length item_tys
             && List.for_all supported_tuple_field_type item_tys ->
          let* items_value =
            result_list items (fun index item ->
                expr_json ~reg enum_names value_record_names heap_record_names union_names
                  enum_constructors
                  (Printf.sprintf "%s.items[%d]" path index)
                  item)
          in
          let* fields = typed [ ("items", items_value) ] in
          Ok (kind "tuple" fields)
      | Ast.TyTuple _ ->
          unsupported path
            "tuple literal outside primitive Blorp backend subset"
      | _ -> unsupported path "tuple expression with non-tuple type")
  | Core.CRecord fields -> (
      match expr.ty with
      | Ast.TyNamed (type_name, [])
        when StringSet.mem type_name value_record_names
             || StringSet.mem type_name heap_record_names ->
          let* fields_value =
            result_list fields (fun index (name, value) ->
                let field_path = Printf.sprintf "%s.fields[%d]" path index in
                let* value_json =
                  expr_json ~reg enum_names value_record_names heap_record_names union_names
                    enum_constructors (field_path ^ ".value") value
                in
                Ok (obj [ ("name", str name); ("value", value_json) ]))
          in
          let* fields = typed [ ("fields", fields_value) ] in
          Ok (kind "record" fields)
      | _ -> unsupported path "record literal on non-value record")
  | Core.CRecordConstruct rc ->
      if
        (not (StringSet.mem rc.rc_type_name value_record_names))
        && not (StringSet.mem rc.rc_type_name heap_record_names)
      then unsupported path "record construction on unknown record type"
      else if Option.is_some rc.rc_erased_release_mask then
        unsupported path "record construction with erased fields"
      else
        let* fields_value =
          result_list rc.rc_fields (fun index field ->
              let field_path = Printf.sprintf "%s.fields[%d]" path index in
              match field with
              | Core.RecordRawField (name, value) ->
                  let* value_json =
                    expr_json ~reg enum_names value_record_names heap_record_names union_names
                      enum_constructors (field_path ^ ".value") value
                  in
                  Ok (obj [ ("name", str name); ("value", value_json) ])
              | Core.RecordErasedField _ ->
                  unsupported field_path "erased record field")
        in
        let* fields =
          typed [ ("type_name", str rc.rc_type_name); ("fields", fields_value) ]
        in
        Ok (kind "record_construct" fields)
  | Core.CList lit ->
      let* construct =
        list_literal_json ~reg enum_names value_record_names heap_record_names union_names
          enum_constructors (path ^ ".construct") expr.loc lit
      in
      let* fields = typed [ ("construct", construct) ] in
      Ok (kind "list_construct" fields)
  | Core.CListAlloc alloc ->
      let* alloc_json =
        list_alloc_json ~reg enum_names value_record_names heap_record_names union_names
          enum_constructors (path ^ ".alloc") expr.loc alloc
      in
      let* fields = typed [ ("alloc", alloc_json) ] in
      Ok (kind "list_alloc" fields)
  | Core.CListGet get ->
      let* get_json =
        list_get_json ~reg enum_names value_record_names heap_record_names union_names
          enum_constructors (path ^ ".get") get
      in
      let* fields = typed [ ("get", get_json) ] in
      Ok (kind "list_get" fields)
  | Core.CListHandoff handoff ->
      let* handoff_json =
        list_handoff_json ~reg enum_names value_record_names heap_record_names union_names
          enum_constructors (path ^ ".handoff") expr.loc handoff
      in
      let* fields = typed [ ("handoff", handoff_json) ] in
      Ok (kind "list_handoff" fields)
  | Core.CStringByteRead read ->
      let* read_json =
        string_byte_read_json ~reg enum_names value_record_names heap_record_names union_names
          enum_constructors (path ^ ".read") read
      in
      let* fields = typed [ ("read", read_json) ] in
      Ok (kind "string_byte_read" fields)
  | Core.CStringByteWrite write ->
      let* write_json =
        string_byte_write_json ~reg enum_names value_record_names heap_record_names union_names
          enum_constructors (path ^ ".write") write
      in
      let* fields = typed [ ("write", write_json) ] in
      Ok (kind "string_byte_write" fields)
  | Core.CStringByteCopy copy ->
      let* copy_json =
        string_byte_copy_json ~reg enum_names value_record_names heap_record_names union_names
          enum_constructors (path ^ ".copy") copy
      in
      let* fields = typed [ ("copy", copy_json) ] in
      Ok (kind "string_byte_copy" fields)
  | Core.CStringSetLen set_len ->
      let* set_len_json =
        string_set_len_json ~reg enum_names value_record_names heap_record_names union_names
          enum_constructors (path ^ ".set_len") set_len
      in
      let* fields = typed [ ("set_len", set_len_json) ] in
      Ok (kind "string_set_len" fields)
  | Core.CListConstruct lc ->
      let* construct =
        list_construct_json ~reg enum_names value_record_names heap_record_names union_names
          enum_constructors (path ^ ".construct") lc
      in
      let* fields = typed [ ("construct", construct) ] in
      Ok (kind "list_construct" fields)
  | Core.CVector _ -> unsupported path "vector literal"
  | Core.CTensorLiteral _ -> unsupported path "tensor literal"
  | Core.CDict _ -> unsupported path "dict literal"
  | Core.CDictConstruct dc ->
      let* construct =
        dict_construct_json ~reg enum_names value_record_names heap_record_names union_names
          enum_constructors (path ^ ".construct") dc
      in
      let* fields = typed [ ("construct", construct) ] in
      Ok (kind "dict_construct" fields)
  | Core.CSetAlloc alloc ->
      let* alloc_json = set_alloc_json (path ^ ".alloc") alloc in
      let* fields = typed [ ("alloc", alloc_json) ] in
      Ok (kind "set_alloc" fields)
  | Core.CRecordUpdate _ -> unsupported path "record update"
  | Core.CLambda _ -> unsupported path "lambda"
  | Core.CClosureCreate closure ->
      let* closure_json =
        closure_create_json ~reg enum_names value_record_names heap_record_names
          union_names (path ^ ".closure") closure
      in
      let* fields = typed [ ("closure", closure_json) ] in
      Ok (kind "closure_create" fields)
  | Core.CTensorRawRead read ->
      let* read_json =
        tensor_raw_read_json ~reg enum_names value_record_names heap_record_names union_names
          enum_constructors (path ^ ".read") read
      in
      let* fields = typed [ ("read", read_json) ] in
      Ok (kind "tensor_raw_read" fields)
  | Core.CTensorRawWrite write ->
      let* write_json =
        tensor_raw_write_json ~reg enum_names value_record_names heap_record_names union_names
          enum_constructors (path ^ ".write") write
      in
      let* fields = typed [ ("write", write_json) ] in
      Ok (kind "tensor_raw_write" fields)
  | Core.CTensorRawViewLet (binding, body) ->
      let* binding_json =
        tensor_raw_view_binding_json ~reg enum_names value_record_names
          heap_record_names union_names enum_constructors (path ^ ".binding")
          binding
      in
      let* body_json =
        expr_json ~reg enum_names value_record_names heap_record_names union_names
          enum_constructors (path ^ ".body") body
      in
      let* fields = typed [ ("binding", binding_json); ("body", body_json) ] in
      Ok (kind "tensor_raw_view_let" fields)
  | Core.CStringInterp _ -> unsupported path "string interpolation"
  | Core.CResourceScope scope ->
      let* scope_json =
        resource_scope_json ~reg enum_names value_record_names heap_record_names union_names
          enum_constructors (path ^ ".scope") scope
      in
      let* fields = typed [ ("scope", scope_json) ] in
      Ok (kind "resource_scope" fields)
  | Core.CResourceCleanupExit cleanup_exit ->
      let* cleanup_exit_json =
        resource_cleanup_exit_json ~reg enum_names value_record_names
          heap_record_names union_names enum_constructors (path ^ ".cleanup_exit")
          cleanup_exit
      in
      let* fields = typed [ ("cleanup_exit", cleanup_exit_json) ] in
      Ok (kind "resource_cleanup_exit" fields)
  | Core.CDebugBlock _ -> unsupported path "debug block"
  | Core.CMatchArms _ -> unsupported path "match arms"
  | Core.CMatch _ -> unsupported path "compiled match"
  | Core.CConcurrent _ -> unsupported path "concurrent block"
  | Core.CConcurrentlyLoop _ -> unsupported path "concurrently loop"
  | Core.CDetach _ -> unsupported path "detach"
  | Core.CSelect _ -> unsupported path "select"
  | Core.CBox (value, source_ty) ->
      let box = Core_codegen_prepare.make_box_op ~reg value source_ty in
      let* box_json =
        box_op_json ~reg enum_names value_record_names heap_record_names union_names
          enum_constructors (path ^ ".box") box
      in
      let* fields = typed [ ("box", box_json) ] in
      Ok (kind "box" fields)
  | Core.CUnbox (value, target_ty) ->
      let unbox =
        {
          Core.unbox_value = value;
          unbox_target_ty = target_ty;
          unbox_kind =
            Core_layout_type.unbox_kind_of_type ~phase:Core_error.Emit ~reg
              target_ty expr.loc;
        }
      in
      let* unbox_kind, expr_value =
        unbox_json ~reg enum_names value_record_names heap_record_names union_names
          enum_constructors path unbox
      in
      let* fields =
        typed [ ("unbox_kind", unbox_kind); ("expr", expr_value) ]
      in
      Ok (kind "unbox" fields)
  | Core.CUnionConstruct uc ->
      let* construct =
        union_construct_json ~reg enum_names value_record_names heap_record_names union_names
          enum_constructors (path ^ ".construct") uc
      in
      let* fields = typed [ ("construct", construct) ] in
      Ok (kind "union_construct" fields)
  | Core.CUnionReuseConstruct _ -> unsupported path "union reuse construction"
  | Core.CBoxTyped box ->
      let* box_json =
        box_op_json ~reg enum_names value_record_names heap_record_names union_names
          enum_constructors (path ^ ".box") box
      in
      let* fields = typed [ ("box", box_json) ] in
      Ok (kind "box" fields)
  | Core.CUnboxTyped unbox ->
      let* unbox_kind, expr_value =
        unbox_json ~reg enum_names value_record_names heap_record_names union_names
          enum_constructors path unbox
      in
      let* fields =
        typed [ ("unbox_kind", unbox_kind); ("expr", expr_value) ]
      in
      Ok (kind "unbox" fields)

and box_kind_json path = function
  | Core.BoxPrim -> Ok (kind "prim" [])
  | Core.BoxPointer -> Ok (kind "pointer" [])
  | Core.BoxVoid -> Ok (kind "void" [])
  | Core.BoxStruct c_type -> Ok (kind "struct" [ ("c_type", str c_type) ])
  | Core.BoxFloat -> unsupported path "float boxed storage"
  | Core.BoxFloat32 -> unsupported path "Float32 boxed storage"
  | Core.BoxFloat16 -> unsupported path "Float16 boxed storage"
  | Core.BoxInt128 -> unsupported path "Int128 boxed storage"
  | Core.BoxUInt128 -> unsupported path "UInt128 boxed storage"

and box_op_json ~reg enum_names value_record_names heap_record_names union_names enum_constructors
    path (box : Core.box_op) =
  let* () =
    match box.box_kind with
    | Core.BoxStruct _
      when Core_layout_type.is_stack_result_type ~reg box.box_source_ty ->
        unsupported path "stack Result boxed storage"
    | Core.BoxPrim | Core.BoxPointer | Core.BoxVoid | Core.BoxStruct _
    | Core.BoxFloat | Core.BoxFloat32 | Core.BoxFloat16 | Core.BoxInt128
    | Core.BoxUInt128 ->
        Ok ()
  in
  let* kind_value = box_kind_json (path ^ ".kind") box.box_kind in
  let* value =
    expr_json ~reg enum_names value_record_names heap_record_names union_names enum_constructors
      (path ^ ".value") box.box_value
  in
  let* source_type =
    type_json ~reg enum_names value_record_names heap_record_names union_names (path ^ ".source_type")
      box.box_source_ty
  in
  Ok
    (obj
       [ ("kind", kind_value); ("value", value); ("source_type", source_type) ])

and unbox_kind_json = function
  | Core.UnboxFloat -> Ok (kind "float" [])
  | Core.UnboxFloat32 -> Ok (kind "float32" [])
  | Core.UnboxFloat16 -> Ok (kind "float16" [])
  | Core.UnboxInt128 -> Ok (kind "int128" [])
  | Core.UnboxUInt128 -> Ok (kind "uint128" [])
  | Core.UnboxPointer -> Ok (kind "pointer" [])
  | Core.UnboxPrim -> Ok (kind "prim" [])
  | Core.UnboxStruct c_type -> Ok (kind "struct" [ ("c_type", str c_type) ])

and boxed_storage_value_json ~reg enum_names value_record_names heap_record_names union_names
    enum_constructors path (value : Core.boxed_storage_value) =
  let* kind_value = box_kind_json (path ^ ".kind") value.bsv_box.box_kind in
  let* value_json =
    expr_json ~reg enum_names value_record_names heap_record_names union_names enum_constructors
      (path ^ ".value") value.bsv_box.box_value
  in
  Ok
    (obj
       [
         ("kind", kind_value);
         ("value", value_json);
         ("needs_release", bool value.bsv_needs_release);
         ("transfers_ownership", bool value.bsv_transfers_ownership);
       ])

and boxed_storage_values_json ~reg enum_names value_record_names heap_record_names union_names
    enum_constructors path values =
  result_list values (fun index value ->
      boxed_storage_value_json ~reg enum_names value_record_names heap_record_names union_names
        enum_constructors
        (Printf.sprintf "%s[%d]" path index)
        value)

and dict_constructor_json path = function
  | Core.DictGeneric -> Ok (kind "generic" [])
  | Core.DictString -> Ok (kind "string" [])
  | Core.DictFloat -> Ok (kind "float" [])
  | Core.DictCustom _ -> unsupported path "custom dict constructor"

and set_constructor_json path = function
  | Core.SetGeneric -> Ok (kind "generic" [])
  | Core.SetString -> Ok (kind "string" [])
  | Core.SetFloat -> Ok (kind "float" [])
  | Core.SetCustom _ -> unsupported path "custom set constructor"

and dict_entry_json ~reg enum_names value_record_names heap_record_names union_names
    enum_constructors path
    ((key, value) : Core.boxed_storage_value * Core.boxed_storage_value) =
  let* key_json =
    boxed_storage_value_json ~reg enum_names value_record_names heap_record_names union_names
      enum_constructors (path ^ ".key") key
  in
  let* value_json =
    boxed_storage_value_json ~reg enum_names value_record_names heap_record_names union_names
      enum_constructors (path ^ ".value") value
  in
  Ok (obj [ ("key", key_json); ("value", value_json) ])

and dict_entries_json ~reg enum_names value_record_names heap_record_names union_names
    enum_constructors path entries =
  result_list entries (fun index entry ->
      dict_entry_json ~reg enum_names value_record_names heap_record_names union_names
        enum_constructors
        (Printf.sprintf "%s[%d]" path index)
        entry)

and dict_construct_json ~reg enum_names value_record_names heap_record_names union_names
    enum_constructors path (construct : Core.dict_construct) =
  let* constructor =
    dict_constructor_json (path ^ ".constructor") construct.dc_constructor
  in
  let* entries =
    dict_entries_json ~reg enum_names value_record_names heap_record_names union_names
      enum_constructors (path ^ ".entries") construct.dc_entries
  in
  Ok
    (obj
       [
         ("constructor", constructor);
         ("entries", entries);
         ("value_needs_release", bool construct.dc_value_needs_release);
       ])

and set_alloc_json path (alloc : Core.set_alloc) =
  let* constructor =
    set_constructor_json (path ^ ".constructor") alloc.sa_constructor
  in
  Ok (obj [ ("constructor", constructor) ])

and borrowed_list_iterable (expr : Core.core) =
  match expr.desc with
  | Core.CVar _ -> true
  | Core.CField (inner, _) -> borrowed_list_iterable inner
  | _ -> false

and require_borrowed_list_iterable path expr =
  if borrowed_list_iterable expr then Ok ()
  else unsupported path "list for-loop iterable must be a borrowed value"

and require_pointer_list_loop_layout path (layout : Core.list_storage_layout) =
  match layout.lsl_slots with
  | Core.ListPointerStorage -> Ok ()
  | Core.ListInlineStorage _ ->
      unsupported path "inline scalar list for-loop"
  | Core.ListInlineStructStorage _ ->
      unsupported path "inline struct list for-loop"

and for_list_json ~reg enum_names value_record_names heap_record_names union_names
    enum_constructors path binder layout iter body =
  let* () = require_borrowed_list_iterable (path ^ ".iterable") iter in
  let* () = require_pointer_list_loop_layout (path ^ ".layout") layout in
  let* binder_json =
    loop_binder_json ~reg enum_names value_record_names heap_record_names union_names
      (path ^ ".binder") binder
  in
  let* layout_json = list_storage_layout_json layout in
  let* iterable_json =
    expr_json ~reg enum_names value_record_names heap_record_names union_names enum_constructors
      (path ^ ".iterable") iter
  in
  let* body_json =
    expr_json ~reg enum_names value_record_names heap_record_names union_names enum_constructors
      (path ^ ".body") body
  in
  Ok
    (obj
       [
         ("binder", binder_json);
         ("layout", layout_json);
         ("iterable", iterable_json);
         ("body", body_json);
       ])

and list_storage_layout_json (layout : Core.list_storage_layout) =
  match layout.lsl_slots with
  | Core.ListPointerStorage -> Ok (kind "pointer" [])
  | Core.ListInlineStorage width ->
      Ok
        (kind "inline"
           [ ("width_bytes", int (Core.inline_storage_width_bytes width)) ])
  | Core.ListInlineStructStorage c_type ->
      Ok (kind "inline_struct" [ ("c_type", str c_type) ])

and list_layout_requires_retain path (layout : Core.list_storage_layout) =
  match Core.storage_policy_retain layout.lsl_policy with
  | Core.StorageNoRetain -> Ok false
  | Core.StorageArcRetain -> Ok true
  | Core.StorageUnknownRetain reason ->
      unsupported path ("unknown list retain policy: " ^ reason)

and list_construct_json ~reg enum_names value_record_names heap_record_names union_names
    enum_constructors path (lc : Core.list_construct) =
  let* layout = list_storage_layout_json lc.lc_layout in
  let* elements =
    boxed_storage_values_json ~reg enum_names value_record_names heap_record_names union_names
      enum_constructors (path ^ ".elements") lc.lc_elems
  in
  Ok
    (obj
       [
         ("layout", layout);
         ("elements", elements);
         ("elem_needs_release", bool lc.lc_elem_needs_release);
       ])

and list_literal_json ~reg enum_names value_record_names heap_record_names union_names
    enum_constructors path loc (lit : Core.list_literal) =
  let* layout = list_storage_layout_json lit.ll_layout in
  let elems =
    List.map (Core_codegen_prepare.boxed_storage_value ~reg) lit.ll_elems
  in
  let* elements =
    boxed_storage_values_json ~reg enum_names value_record_names heap_record_names union_names
      enum_constructors (path ^ ".elements") elems
  in
  Ok
    (obj
       [
         ("layout", layout);
         ("elements", elements);
         ( "elem_needs_release",
           bool
             (Core.list_storage_layout_requires_release_or_error
                ~phase:Core_error.Emit ~loc lit.ll_layout) );
       ])

and list_alloc_json ~reg enum_names value_record_names heap_record_names union_names
    enum_constructors path loc (alloc : Core.list_alloc) =
  let* layout = list_storage_layout_json alloc.la_layout in
  let* capacity =
    expr_json ~reg enum_names value_record_names heap_record_names union_names enum_constructors
      (path ^ ".capacity") alloc.la_capacity
  in
  Ok
    (obj
       [
         ("layout", layout);
         ("capacity", capacity);
         ( "elem_needs_release",
           bool
             (Core.list_storage_layout_requires_release_or_error
                ~phase:Core_error.Emit ~loc alloc.la_layout) );
       ])

and list_bounds_json = function
  | Core.ListBoundsChecked -> str "checked"
  | Core.ListBoundsProven -> str "proven"

and list_get_json ~reg enum_names value_record_names heap_record_names union_names
    enum_constructors path (get : Core.list_get) =
  let* layout = list_storage_layout_json get.lg_layout in
  let* list =
    expr_json ~reg enum_names value_record_names heap_record_names union_names enum_constructors
      (path ^ ".list") get.lg_list
  in
  let* index =
    expr_json ~reg enum_names value_record_names heap_record_names union_names enum_constructors
      (path ^ ".index") get.lg_index
  in
  Ok
    (obj
       [
         ("layout", layout);
         ("list", list);
         ("index", index);
         ("bounds", list_bounds_json get.lg_bounds);
       ])

and tensor_raw_scalar_kind_json = function
  | Core.TensorFloat64Elements -> str "float64"
  | Core.TensorFloat32Elements -> str "float32"
  | Core.TensorInt64Elements -> str "int64"

and tensor_raw_read_json ~reg enum_names value_record_names heap_record_names union_names
    enum_constructors path (read : Core.tensor_raw_read) =
  let* index =
    expr_json ~reg enum_names value_record_names heap_record_names union_names enum_constructors
      (path ^ ".index") read.trr_index
  in
  Ok
    (obj
       [
         ("view", var_json read.trr_view);
         ("raw_kind", tensor_raw_scalar_kind_json read.trr_kind);
         ("index", index);
       ])

and tensor_raw_write_json ~reg enum_names value_record_names heap_record_names union_names
    enum_constructors path (write : Core.tensor_raw_write) =
  let* index =
    expr_json ~reg enum_names value_record_names heap_record_names union_names enum_constructors
      (path ^ ".index") write.trw_index
  in
  let* value =
    expr_json ~reg enum_names value_record_names heap_record_names union_names enum_constructors
      (path ^ ".value") write.trw_value
  in
  Ok
    (obj
       [
         ("view", var_json write.trw_view);
         ("raw_kind", tensor_raw_scalar_kind_json write.trw_kind);
         ("index", index);
         ("value", value);
       ])

and tensor_raw_view_binding_json ~reg enum_names value_record_names heap_record_names union_names
    enum_constructors path (binding : Core.tensor_raw_view_binding) =
  let* source =
    expr_json ~reg enum_names value_record_names heap_record_names union_names enum_constructors
      (path ^ ".source") binding.trv_source
  in
  Ok
    (obj
       [
         ("variable", var_json binding.trv_var);
         ("raw_kind", tensor_raw_scalar_kind_json binding.trv_kind);
         ("source", source);
       ])

and list_handoff_mode_json = function
  | Core.BorrowFresh -> str "borrow_fresh"
  | Core.ConsumeReuse -> str "consume_reuse"

and list_handoff_write_order_json = function
  | Core.ForwardCompacting -> str "forward_compacting"

and list_handoff_json ~reg enum_names value_record_names heap_record_names union_names
    enum_constructors path loc (handoff : Core.list_handoff) =
  let* layout = list_storage_layout_json handoff.lh_layout in
  let* source =
    expr_json ~reg enum_names value_record_names heap_record_names union_names enum_constructors
      (path ^ ".source") handoff.lh_source
  in
  let* source_type =
    type_json ~reg enum_names value_record_names heap_record_names union_names (path ^ ".source_type")
      handoff.lh_source_ty
  in
  let* result_type =
    type_json ~reg enum_names value_record_names heap_record_names union_names (path ^ ".result_type")
      handoff.lh_result_ty
  in
  let* capacity =
    expr_json ~reg enum_names value_record_names heap_record_names union_names enum_constructors
      (path ^ ".capacity") handoff.lh_capacity
  in
  let* body =
    expr_json ~reg enum_names value_record_names heap_record_names union_names enum_constructors
      (path ^ ".body") handoff.lh_body
  in
  Ok
    (obj
       [
         ("mode", list_handoff_mode_json handoff.lh_mode);
         ("layout", layout);
         ( "elem_needs_release",
           bool
             (Core.list_storage_layout_requires_release_or_error
                ~phase:Core_error.Emit ~loc handoff.lh_layout) );
         ("source", source);
         ("source_var", var_json handoff.lh_source_var);
         ("source_type", source_type);
         ("result_type", result_type);
         ("capacity", capacity);
         ("result_var", var_json handoff.lh_result_var);
         ("len_var", var_json handoff.lh_len_var);
         ("out_var", var_json handoff.lh_out_var);
         ("body", body);
         ("write_order", list_handoff_write_order_json handoff.lh_write_order);
       ])

and list_handoff_set_source_slot_json ~reg enum_names value_record_names
    heap_record_names union_names enum_constructors path result out_index source
    source_index =
  let* result_json =
    expr_json ~reg enum_names value_record_names heap_record_names union_names enum_constructors
      (path ^ ".result") result
  in
  let* out_index_json =
    expr_json ~reg enum_names value_record_names heap_record_names union_names enum_constructors
      (path ^ ".out_index") out_index
  in
  let* source_json =
    expr_json ~reg enum_names value_record_names heap_record_names union_names enum_constructors
      (path ^ ".source") source
  in
  let* source_index_json =
    expr_json ~reg enum_names value_record_names heap_record_names union_names enum_constructors
      (path ^ ".source_index") source_index
  in
  Ok
    (obj
       [
         ("result", result_json);
         ("out_index", out_index_json);
         ("source", source_json);
         ("source_index", source_index_json);
       ])

and string_byte_read_json ~reg enum_names value_record_names heap_record_names union_names
    enum_constructors path (read : Core.string_byte_read) =
  match read.sbr_proof with
  | Core.StringReadBoundsProven ->
      let* source =
        expr_json ~reg enum_names value_record_names heap_record_names union_names
          enum_constructors (path ^ ".source") read.sbr_source
      in
      let* index =
        expr_json ~reg enum_names value_record_names heap_record_names union_names
          enum_constructors (path ^ ".index") read.sbr_index
      in
      Ok (obj [ ("source", source); ("index", index) ])

and string_byte_write_json ~reg enum_names value_record_names heap_record_names union_names
    enum_constructors path (write : Core.string_byte_write) =
  match write.sbw_proof with
  | Core.StringWriteBoundsProven ->
      let* target =
        expr_json ~reg enum_names value_record_names heap_record_names union_names
          enum_constructors (path ^ ".target") write.sbw_target
      in
      let* index =
        expr_json ~reg enum_names value_record_names heap_record_names union_names
          enum_constructors (path ^ ".index") write.sbw_index
      in
      let* byte =
        expr_json ~reg enum_names value_record_names heap_record_names union_names
          enum_constructors (path ^ ".byte") write.sbw_byte
      in
      Ok (obj [ ("target", target); ("index", index); ("byte", byte) ])

and string_byte_copy_json ~reg enum_names value_record_names heap_record_names union_names
    enum_constructors path (copy : Core.string_byte_copy) =
  match copy.sbc_proof with
  | Core.StringCopyBoundsProven ->
      let* dst =
        expr_json ~reg enum_names value_record_names heap_record_names union_names
          enum_constructors (path ^ ".dst") copy.sbc_dst
      in
      let* dst_pos =
        expr_json ~reg enum_names value_record_names heap_record_names union_names
          enum_constructors (path ^ ".dst_pos") copy.sbc_dst_pos
      in
      let* src =
        expr_json ~reg enum_names value_record_names heap_record_names union_names
          enum_constructors (path ^ ".src") copy.sbc_src
      in
      let* src_pos =
        expr_json ~reg enum_names value_record_names heap_record_names union_names
          enum_constructors (path ^ ".src_pos") copy.sbc_src_pos
      in
      let* len =
        expr_json ~reg enum_names value_record_names heap_record_names union_names
          enum_constructors (path ^ ".len") copy.sbc_len
      in
      Ok
        (obj
           [
             ("dst", dst);
             ("dst_pos", dst_pos);
             ("src", src);
             ("src_pos", src_pos);
             ("len", len);
           ])

and string_set_len_json ~reg enum_names value_record_names heap_record_names union_names
    enum_constructors path (set_len : Core.string_set_len) =
  match set_len.ssl_proof with
  | Core.StringSetLenBoundsProven ->
      let* target =
        expr_json ~reg enum_names value_record_names heap_record_names union_names
          enum_constructors (path ^ ".target") set_len.ssl_target
      in
      let* len =
        expr_json ~reg enum_names value_record_names heap_record_names union_names
          enum_constructors (path ^ ".len") set_len.ssl_len
      in
      Ok (obj [ ("target", target); ("len", len) ])

and unbox_json ~reg enum_names value_record_names heap_record_names union_names enum_constructors
    path (u : Core.unbox_op) =
  let* kind_value = unbox_kind_json u.unbox_kind in
  let* expr_value =
    expr_json ~reg enum_names value_record_names heap_record_names union_names enum_constructors
      (path ^ ".expr") u.unbox_value
  in
  Ok (kind_value, expr_value)

and list_set_json ~reg enum_names value_record_names heap_record_names union_names
    enum_constructors path (layout : Core.list_storage_layout) list index value
    =
  let boxed_value = Core_codegen_prepare.boxed_storage_value ~reg value in
  let* () = require_list_set_layout path layout boxed_value in
  let* layout_json = list_storage_layout_json layout in
  let* list_json =
    expr_json ~reg enum_names value_record_names heap_record_names union_names enum_constructors
      (path ^ ".list") list
  in
  let* index_json =
    expr_json ~reg enum_names value_record_names heap_record_names union_names enum_constructors
      (path ^ ".index") index
  in
  let* value_json =
    boxed_storage_value_json ~reg enum_names value_record_names heap_record_names union_names
      enum_constructors (path ^ ".value") boxed_value
  in
  Ok
    (obj
       [
         ("layout", layout_json);
         ("list", list_json);
         ("index", index_json);
         ("value", value_json);
         ( "value_is_stack_result",
           bool (Core_layout_type.is_stack_result_type ~reg value.ty) );
       ])

and list_retain_json ~reg enum_names value_record_names heap_record_names union_names
    enum_constructors path list value =
  let boxed_value = Core_codegen_prepare.boxed_storage_value ~reg value in
  let* list_json =
    expr_json ~reg enum_names value_record_names heap_record_names union_names enum_constructors
      (path ^ ".list") list
  in
  let* value_json =
    boxed_storage_value_json ~reg enum_names value_record_names heap_record_names union_names
      enum_constructors (path ^ ".value") boxed_value
  in
  Ok (obj [ ("list", list_json); ("value", value_json) ])

and resource_exit_json = function
  | Core.ResourceBreak -> str "break"
  | Core.ResourceContinue -> str "continue"

and resource_scope_json ~reg enum_names value_record_names heap_record_names union_names
    enum_constructors path (scope : Core.resource_scope) =
  let* typ =
    type_json ~reg enum_names value_record_names heap_record_names union_names (path ^ ".type")
      scope.rs_ty
  in
  let* acquire =
    expr_json ~reg enum_names value_record_names heap_record_names union_names enum_constructors
      (path ^ ".acquire") scope.rs_acquire
  in
  let* body =
    expr_json ~reg enum_names value_record_names heap_record_names union_names enum_constructors
      (path ^ ".body") scope.rs_body
  in
  let* cleanup =
    expr_json ~reg enum_names value_record_names heap_record_names union_names enum_constructors
      (path ^ ".cleanup") scope.rs_cleanup
  in
  Ok
    (obj
       [
         ("var", var_json scope.rs_var);
         ("type", typ);
         ("acquire", acquire);
         ("body", body);
         ("cleanup", cleanup);
       ])

and resource_cleanup_exit_json ~reg enum_names value_record_names heap_record_names union_names
    enum_constructors path (cleanup_exit : Core.resource_cleanup_exit) =
  let* cleanups =
    result_list cleanup_exit.rce_cleanups (fun index cleanup ->
        expr_json ~reg enum_names value_record_names heap_record_names union_names
          enum_constructors
          (Printf.sprintf "%s.cleanups[%d]" path index)
          cleanup)
  in
  Ok
    (obj
       [
         ("cleanups", cleanups);
         ("exit", resource_exit_json cleanup_exit.rce_exit);
       ])

and require_inline_struct_list_set_value path c_type
    (value : Core.boxed_storage_value) =
  match value.bsv_box.box_kind with
  | Core.BoxStruct value_c_type when String.equal value_c_type c_type -> Ok ()
  | Core.BoxStruct value_c_type ->
      unsupported path
        (Printf.sprintf
           "inline-struct list set value type %s does not match list storage %s"
           value_c_type c_type)
  | Core.BoxPrim | Core.BoxPointer | Core.BoxVoid | Core.BoxFloat
  | Core.BoxFloat32 | Core.BoxFloat16 | Core.BoxInt128 | Core.BoxUInt128 ->
      unsupported path "non-struct inline-struct list set value"

and require_list_set_layout path (layout : Core.list_storage_layout)
    (value : Core.boxed_storage_value) =
  match layout.lsl_slots with
  | Core.ListInlineStructStorage c_type ->
      require_inline_struct_list_set_value (path ^ ".value") c_type value
  | Core.ListPointerStorage ->
      let* _ = box_kind_json (path ^ ".value.kind") value.bsv_box.box_kind in
      Ok ()
  | Core.ListInlineStorage _ ->
      let* _ = box_kind_json (path ^ ".value.kind") value.bsv_box.box_kind in
      Ok ()

and union_representation_json path (uc : Core.union_construct) =
  match uc.uc_representation with
  | Core.OptionUnion layout -> (
      match Core_layout_type.option_constructor_abi_of_layout layout with
      | Core_layout_type.OptionConstructorStackInline abi ->
          Ok
            (kind "stack_option"
               [
                 ("option_type", str abi.soe_c_type);
                 ("tag", int uc.uc_tag);
	             ("none_value", str abi.soe_none_value);
	           ])
      | Core_layout_type.OptionConstructorNullableManaged ->
          Ok (kind "nullable_option" [])
      | Core_layout_type.OptionConstructorBoxedUnion ->
          unsupported path "boxed Option union constructor"
      | Core_layout_type.OptionConstructorUnavailable reason ->
          unsupported path ("unavailable Option constructor ABI: " ^ reason))
  | Core.GenericUnion -> unsupported path "generic union constructor"
  | Core.ResultUnion _ -> unsupported path "Result union constructor"

and union_construct_json ~reg enum_names value_record_names heap_record_names union_names
    enum_constructors path (uc : Core.union_construct) =
  let* representation =
    union_representation_json (path ^ ".representation") uc
  in
  let args =
    List.map
      (fun (arg : Core.boxed_storage_value) -> arg.bsv_box.box_value)
      uc.uc_args
  in
  let* args_json =
    result_list args (fun index arg ->
        expr_json ~reg enum_names value_record_names heap_record_names union_names
          enum_constructors
          (Printf.sprintf "%s.args[%d]" path index)
          arg)
  in
  Ok
    (obj
       [
         ("type_name", str uc.uc_type_name);
         ("constructor_name", str uc.uc_constructor_name);
         ("constructor_c_name", str uc.uc_c_name);
         ("representation", representation);
         ("args", args_json);
       ])

let function_kind_json ~reg enum_names value_record_names heap_record_names union_names
    path (func : Core.core_func) =
  match func.cf_kind with
  | Core.CFUser -> Ok (kind "user" [])
  | Core.CFBuiltin -> Ok (kind "builtin" [])
  | Core.CFForeign _ -> Ok (kind "foreign" [])
  | Core.CFClosureBody abi ->
      let* () = require_closure_body_abi path abi in
      let c_name = Codegen_names.mangle_by_def_id func.cf_def_id func.cf_name in
      let* abi_json =
        closure_abi_json ~reg enum_names value_record_names heap_record_names
          union_names (path ^ ".abi") c_name abi
      in
      Ok (kind "closure_body" [ ("abi", abi_json) ])

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

let is_string_type ty =
  match Codegen_types.normalize_type ty with
  | Ast.TyNamed (("String" | "LiteralString"), []) -> true
  | _ -> false

let string_binary_op_supported = function
  | Ast.Eq | Ast.Ne | Ast.Lt | Ast.Le | Ast.Gt | Ast.Ge -> true
  | Ast.Add | Ast.Sub | Ast.Mul | Ast.Div | Ast.Mod -> false

let require_binary_op path op (left : Core.core) (right : Core.core) =
  if (is_string_type left.ty || is_string_type right.ty)
     && not (string_binary_op_supported op)
  then unsupported path "unsupported string binary operator"
  else Ok ()

let list_layout_for_expr (expr : Core.core) =
  Core_layout_type.list_storage_layout_of_type expr.ty expr.loc

let require_emittable_list_store_layout path (layout : Core.list_storage_layout)
    ~inline_scalar_reason ~allow_inline_scalar =
  match layout.lsl_slots with
  | Core.ListPointerStorage | Core.ListInlineStructStorage _ -> Ok ()
  | Core.ListInlineStorage _ when allow_inline_scalar -> Ok ()
  | Core.ListInlineStorage _ ->
      unsupported (path ^ ".layout") inline_scalar_reason

let prepared_list_intrinsic_core_arity = function
  | "list_ensure_unique" -> Some 1
  | "list_ensure_capacity" -> Some 2
  | _ -> None

let require_core_arity path name expected args =
  let actual = List.length args in
  if actual = expected then Ok ()
  else
    unsupported path
      (Printf.sprintf "intrinsic call %s expected %d arg(s), got %d" name
         expected actual)

let require_intrinsic_renderable path name args =
  match
    Compiler_blorp_bridge.renderer_template_arity_opt_exn
      ~renderer:Compiler_blorp_bridge.intrinsic_renderer ~op:name
  with
  | Some arity -> require_core_arity path name arity args
  | None -> (
      match prepared_list_intrinsic_core_arity name with
      | Some arity -> require_core_arity path name arity args
      | None -> unsupported path ("unsupported intrinsic call " ^ name))

let require_simple_call_kind path call_kind args =
  match call_kind with
  | Core.CKUser (("Some" | "None"), _) ->
      unsupported path "unprepared Option constructor call"
  | Core.CKUser _ -> Ok ()
  | Core.CKForeign _ -> unsupported path "foreign call"
  | Core.CKBuiltin name when direct_builtin_supported name -> Ok ()
  | Core.CKBuiltin name -> unsupported path ("builtin call " ^ name)
  | Core.CKIntrinsic name -> require_intrinsic_renderable path name args
  | Core.CKClosure -> Ok ()
  | Core.CKUnknown -> unsupported path "unresolved call kind"
  | Core.CKSelectedDirect _ -> unsupported path "selected direct call kind"

let rec require_simple_expr path (expr : Core.core) =
  match expr.desc with
  | Core.CLit (Ast.LitInt _ | Ast.LitBool _ | Ast.LitString _) -> Ok ()
  | Core.CLit literal ->
      literal_json (path ^ ".literal") literal |> Result.map ignore
  | Core.CVar _ | Core.CVoid -> Ok ()
  | Core.CCall (Core.CKIntrinsic "list_retain_for", _callee, [ lst; value ]) ->
      let layout = list_layout_for_expr lst in
      let* requires_retain =
        list_layout_requires_retain (path ^ ".layout") layout
      in
      if requires_retain then
        let* () = require_simple_expr (path ^ ".list") lst in
        require_simple_expr (path ^ ".value") value
      else Ok ()
  | Core.CCall
      ( (Core.CKIntrinsic "list_set" | Core.CKIntrinsic "list_set_owned"),
        _callee,
        [ lst; index; value ] ) ->
      let layout = list_layout_for_expr lst in
      let* () =
        require_emittable_list_store_layout path layout
          ~inline_scalar_reason:"inline scalar list set" ~allow_inline_scalar:true
      in
      let* () = require_simple_expr (path ^ ".list") lst in
      let* () = require_simple_expr (path ^ ".index") index in
      require_simple_expr (path ^ ".value") value
  | Core.CCall
      (Core.CKIntrinsic "list_handoff_set_owned", _callee, [ lst; index; value ])
    ->
      let layout = list_layout_for_expr lst in
      let* () =
        require_emittable_list_store_layout path layout
          ~inline_scalar_reason:"inline scalar list handoff set"
          ~allow_inline_scalar:false
      in
      let* () = require_simple_expr (path ^ ".list") lst in
      let* () = require_simple_expr (path ^ ".index") index in
      require_simple_expr (path ^ ".value") value
  | Core.CCall
      ( Core.CKIntrinsic "list_handoff_set_source_slot",
        _callee,
        [ result; out_index; source; source_index ] ) ->
      let* () = require_simple_expr (path ^ ".result") result in
      let* () = require_simple_expr (path ^ ".out_index") out_index in
      let* () = require_simple_expr (path ^ ".source") source in
      require_simple_expr (path ^ ".source_index") source_index
  | Core.CCall
      ( (Core.CKBuiltin "blorp_list_new" | Core.CKIntrinsic "list_alloc"),
        _callee,
        [ capacity ] ) ->
      require_simple_expr (path ^ ".capacity") capacity
  | Core.CCall
      ( (Core.CKIntrinsic "list_get" | Core.CKIntrinsic "list_get_unchecked"),
        _callee,
        [ lst; index ] ) ->
      let* () = require_simple_expr (path ^ ".list") lst in
      require_simple_expr (path ^ ".index") index
  | Core.CCall (call_kind, _callee, args) ->
      let* () = require_simple_call_kind (path ^ ".call_kind") call_kind args in
      require_simple_args path args
  | Core.CBin (op, left, right) ->
      let* () = require_binary_op path op left right in
      let* () = require_simple_expr (path ^ ".left") left in
      require_simple_expr (path ^ ".right") right
  | Core.CUn (_op, inner) -> require_simple_expr (path ^ ".expr") inner
  | Core.CLog (_op, left, right) ->
      let* () = require_simple_expr (path ^ ".left") left in
      require_simple_expr (path ^ ".right") right
  | Core.CCast (inner, _target_ty) -> require_simple_expr (path ^ ".expr") inner
  | Core.CBox (inner, _source_ty) -> require_simple_expr (path ^ ".value") inner
  | Core.CBoxTyped box -> require_box_op path box
  | Core.CUnbox (inner, _target_ty) ->
      require_simple_expr (path ^ ".expr") inner
  | Core.CUnboxTyped unbox -> require_unbox_op path unbox
  | Core.CField (inner, _field_name) ->
      require_simple_expr (path ^ ".expr") inner
  | Core.CTuple items -> require_tuple_literal path expr.ty items
  | Core.CTupleConstruct tc -> require_tuple_construct path tc
  | Core.CList lit -> require_list_literal path lit
  | Core.CListAlloc alloc -> require_list_alloc path alloc
  | Core.CListGet get -> require_list_get path get
  | Core.CListHandoff handoff -> require_list_handoff path handoff
  | Core.CStringByteRead read -> require_string_byte_read path read
  | Core.CStringByteWrite write -> require_string_byte_write path write
  | Core.CStringByteCopy copy -> require_string_byte_copy path copy
  | Core.CStringSetLen set_len -> require_string_set_len path set_len
  | Core.CTensorRawRead read -> require_tensor_raw_read path read
  | Core.CTensorRawWrite write -> require_tensor_raw_write path write
  | Core.CDictConstruct construct -> require_dict_construct path construct
  | Core.CSetAlloc alloc -> require_set_alloc path alloc
  | Core.CListConstruct lc -> require_list_construct path lc
  | Core.CRecord fields -> require_record_literal path expr.ty fields
  | Core.CRecordConstruct rc -> require_record_construct path rc
  | Core.CUnionConstruct uc -> require_union_construct path uc
  | Core.CClosureCreate closure -> require_closure_create path closure
  | Core.CRange (lo, hi) ->
      let* () = require_simple_expr (path ^ ".start") lo in
      require_simple_expr (path ^ ".end") hi
  | Core.CIf (cond, then_expr, else_expr) ->
      let* () = require_simple_expr (path ^ ".cond") cond in
      let* () = require_simple_expr (path ^ ".then") then_expr in
      require_simple_expr (path ^ ".else") else_expr
  | Core.CAssign _ | Core.CLet _ | Core.CSeq _ | Core.CWhile _
  | Core.CCooperativeCheckpoint | Core.CBreak | Core.CContinue ->
      unsupported path
        (Printf.sprintf "statement-shaped expression: %s"
           (Core.pp_to_string expr))
  | _ ->
      unsupported path
        (Printf.sprintf "unsupported simple expression: %s : %s"
           (Core.pp_to_string expr)
           (Types.type_to_string expr.ty))

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

and require_tuple_element path (element : Core.boxed_storage_value) =
  let* _ = tuple_element_tag (path ^ ".kind") element.bsv_box.box_kind in
  require_simple_expr (path ^ ".value") element.bsv_box.box_value

and require_pointer_list_element path (element : Core.boxed_storage_value) =
  let* _ = box_kind_json (path ^ ".kind") element.bsv_box.box_kind in
  require_simple_expr (path ^ ".value") element.bsv_box.box_value

and require_tuple_construct path (tc : Core.tuple_construct) =
  let rec check index = function
    | [] -> Ok ()
    | element :: rest ->
        let* () =
          require_tuple_element
            (Printf.sprintf "%s.construct.elements[%d]" path index)
            element
        in
        check (index + 1) rest
  in
  check 0 tc.tc_elems

and require_tuple_literal path ty items =
  match ty with
  | Ast.TyTuple item_tys
    when List.length items = List.length item_tys
         && List.for_all supported_tuple_field_type item_tys ->
      let rec check index = function
        | [] -> Ok ()
        | item :: rest ->
            let* () =
              require_simple_expr
                (Printf.sprintf "%s.items[%d]" path index)
                item
            in
            check (index + 1) rest
      in
      check 0 items
  | Ast.TyTuple _ ->
      unsupported path "tuple literal outside primitive Blorp backend subset"
  | _ -> unsupported path "tuple expression with non-tuple type"

and require_record_literal path ty fields =
  match ty with
  | Ast.TyNamed _ ->
      let rec check index = function
        | [] -> Ok ()
        | (_name, value) :: rest ->
            let* () =
              require_simple_expr
                (Printf.sprintf "%s.fields[%d].value" path index)
                value
            in
            check (index + 1) rest
      in
      check 0 fields
  | _ -> unsupported path "record literal on non-named type"

and require_record_field_arg path = function
  | Core.RecordRawField (_name, value) ->
      require_simple_expr (path ^ ".value") value
  | Core.RecordErasedField _ -> unsupported path "erased record field"

and require_record_construct path (rc : Core.record_construct) =
  if Option.is_some rc.rc_erased_release_mask then
    unsupported path "record construction with erased fields"
  else
    let rec check index = function
      | [] -> Ok ()
      | field :: rest ->
          let* () =
            require_record_field_arg
              (Printf.sprintf "%s.fields[%d]" path index)
              field
          in
          check (index + 1) rest
    in
    check 0 rc.rc_fields

and inline_struct_list_unmanaged (layout : Core.list_storage_layout) =
  match layout.lsl_policy with
  | Core.StoragePolicyUnmanagedBits -> true
  | Core.StoragePolicyManagedPointer | Core.StoragePolicyOwnedErasedBox
  | Core.StoragePolicyUnknown _ ->
      false

and require_inline_struct_list_element path c_type ~allow_element_release_flag
    (value : Core.boxed_storage_value) =
  if value.bsv_needs_release && not allow_element_release_flag then
    unsupported path "managed inline-struct list element"
  else if value.bsv_transfers_ownership && not allow_element_release_flag then
    unsupported path "owned inline-struct list element transfer"
  else
    match value.bsv_box.box_kind with
    | Core.BoxStruct value_c_type when String.equal value_c_type c_type ->
        require_simple_expr (path ^ ".value") value.bsv_box.box_value
    | Core.BoxStruct value_c_type ->
        unsupported path
          (Printf.sprintf
             "inline-struct list element type %s does not match list storage %s"
             value_c_type c_type)
    | Core.BoxPrim | Core.BoxPointer | Core.BoxVoid | Core.BoxFloat
    | Core.BoxFloat32 | Core.BoxFloat16 | Core.BoxInt128 | Core.BoxUInt128 ->
        unsupported path "non-struct inline-struct list element"

and require_list_construct path (lc : Core.list_construct) =
  match lc.lc_layout.lsl_slots with
  | Core.ListInlineStructStorage c_type ->
      let allow_element_release_flag =
        inline_struct_list_unmanaged lc.lc_layout
      in
      if lc.lc_elem_needs_release then
        unsupported path "managed inline-struct list construction"
      else if not allow_element_release_flag then
        unsupported path
          "inline-struct list construction without unmanaged storage policy"
      else
        let rec check index = function
          | [] -> Ok ()
          | element :: rest ->
              let* () =
                require_inline_struct_list_element
                  (Printf.sprintf "%s.elements[%d]" path index)
                  c_type ~allow_element_release_flag element
              in
              check (index + 1) rest
        in
        check 0 lc.lc_elems
  | Core.ListPointerStorage | Core.ListInlineStorage _ ->
      let rec check index = function
        | [] -> Ok ()
        | element :: rest ->
            let* () =
              require_pointer_list_element
                (Printf.sprintf "%s.elements[%d]" path index)
                element
            in
            check (index + 1) rest
      in
      check 0 lc.lc_elems

and require_dict_constructor path = function
  | Core.DictGeneric | Core.DictString | Core.DictFloat -> Ok ()
  | Core.DictCustom _ -> unsupported path "custom dict constructor"

and require_set_constructor path = function
  | Core.SetGeneric | Core.SetString | Core.SetFloat -> Ok ()
  | Core.SetCustom _ -> unsupported path "custom set constructor"

and require_dict_entry path
    ((key, value) : Core.boxed_storage_value * Core.boxed_storage_value) =
  let* () = require_pointer_list_element (path ^ ".key") key in
  require_pointer_list_element (path ^ ".value") value

and require_dict_construct path (construct : Core.dict_construct) =
  let* () =
    require_dict_constructor (path ^ ".constructor") construct.dc_constructor
  in
  let rec check index = function
    | [] -> Ok ()
    | entry :: rest ->
        let* () =
          require_dict_entry (Printf.sprintf "%s.entries[%d]" path index) entry
        in
        check (index + 1) rest
  in
  check 0 construct.dc_entries

and require_set_alloc path (alloc : Core.set_alloc) =
  require_set_constructor (path ^ ".constructor") alloc.sa_constructor

and require_list_literal path (lit : Core.list_literal) =
  let* _ = list_storage_layout_json lit.ll_layout in
  let rec check index = function
    | [] -> Ok ()
    | elem :: rest ->
        let* () =
          require_simple_expr (Printf.sprintf "%s.elements[%d]" path index) elem
        in
        check (index + 1) rest
  in
  check 0 lit.ll_elems

and require_list_alloc path (alloc : Core.list_alloc) =
  let* _ = list_storage_layout_json alloc.la_layout in
  require_simple_expr (path ^ ".capacity") alloc.la_capacity

and require_list_get path (get : Core.list_get) =
  let* _ = list_storage_layout_json get.lg_layout in
  let* () = require_simple_expr (path ^ ".list") get.lg_list in
  require_simple_expr (path ^ ".index") get.lg_index

and require_list_handoff path (handoff : Core.list_handoff) =
  let* _ = list_storage_layout_json handoff.lh_layout in
  let* () = require_simple_expr (path ^ ".source") handoff.lh_source in
  let* () = require_simple_expr (path ^ ".capacity") handoff.lh_capacity in
  require_simple_expr (path ^ ".body") handoff.lh_body

and require_string_byte_read path (read : Core.string_byte_read) =
  match read.sbr_proof with
  | Core.StringReadBoundsProven ->
      let* () = require_simple_expr (path ^ ".source") read.sbr_source in
      require_simple_expr (path ^ ".index") read.sbr_index

and require_string_byte_write path (write : Core.string_byte_write) =
  match write.sbw_proof with
  | Core.StringWriteBoundsProven ->
      let* () = require_simple_expr (path ^ ".target") write.sbw_target in
      let* () = require_simple_expr (path ^ ".index") write.sbw_index in
      require_simple_expr (path ^ ".byte") write.sbw_byte

and require_string_byte_copy path (copy : Core.string_byte_copy) =
  match copy.sbc_proof with
  | Core.StringCopyBoundsProven ->
      let* () = require_simple_expr (path ^ ".dst") copy.sbc_dst in
      let* () = require_simple_expr (path ^ ".dst_pos") copy.sbc_dst_pos in
      let* () = require_simple_expr (path ^ ".src") copy.sbc_src in
      let* () = require_simple_expr (path ^ ".src_pos") copy.sbc_src_pos in
      require_simple_expr (path ^ ".len") copy.sbc_len

and require_string_set_len path (set_len : Core.string_set_len) =
  match set_len.ssl_proof with
  | Core.StringSetLenBoundsProven ->
      let* () = require_simple_expr (path ^ ".target") set_len.ssl_target in
      require_simple_expr (path ^ ".len") set_len.ssl_len

and require_tensor_raw_read path (read : Core.tensor_raw_read) =
  require_simple_expr (path ^ ".index") read.trr_index

and require_tensor_raw_write path (write : Core.tensor_raw_write) =
  let* () = require_simple_expr (path ^ ".index") write.trw_index in
  require_simple_expr (path ^ ".value") write.trw_value

and require_tensor_raw_view_binding path
    (binding : Core.tensor_raw_view_binding) =
  require_simple_expr (path ^ ".source") binding.trv_source

and require_unbox_op path (unbox : Core.unbox_op) =
  let* _ = unbox_kind_json unbox.unbox_kind in
  require_simple_expr (path ^ ".expr") unbox.unbox_value

and require_box_op path (box : Core.box_op) =
  let* _ = box_kind_json (path ^ ".kind") box.box_kind in
  match box.box_kind with
  | Core.BoxPrim | Core.BoxPointer | Core.BoxVoid | Core.BoxStruct _ ->
      require_simple_expr (path ^ ".value") box.box_value
  | Core.BoxFloat | Core.BoxFloat32 | Core.BoxFloat16 | Core.BoxInt128
  | Core.BoxUInt128 ->
      unsupported path "unsupported box kind"

and cleanup_release_call_kind_supported path = function
  | Core.CKUser _ -> Ok ()
  | Core.CKBuiltin name when direct_builtin_supported name -> Ok ()
  | Core.CKBuiltin name -> unsupported path ("builtin call " ^ name)
  | Core.CKForeign _ -> unsupported path "foreign call"
  | Core.CKIntrinsic _ -> unsupported path "intrinsic cleanup call"
  | Core.CKClosure -> unsupported path "closure cleanup call"
  | Core.CKUnknown -> unsupported path "unresolved cleanup call"
  | Core.CKSelectedDirect _ -> unsupported path "selected cleanup call"

and require_resource_cleanup_call path cleanup =
  match cleanup.Core.desc with
  | Core.CCall (call_kind, _callee, [ { desc = Core.CVar variable; _ } ]) ->
      let* () =
        cleanup_release_call_kind_supported (path ^ ".call_kind") call_kind
      in
      Ok variable
  | Core.CCall (_call_kind, _callee, _args) ->
      unsupported path
        "resource cleanup must take exactly one resource argument"
  | _ -> unsupported path "resource cleanup must be a direct finalizer call"

and require_resource_scope ~reg union_names path (scope : Core.resource_scope) =
  let* cleanup_var =
    require_resource_cleanup_call (path ^ ".cleanup") scope.rs_cleanup
  in
  if not (Core.Var.equal cleanup_var scope.rs_var) then
    unsupported (path ^ ".cleanup")
      "resource cleanup argument does not match scoped resource"
  else
    let* () = require_simple_expr (path ^ ".acquire") scope.rs_acquire in
    let* () =
      require_function_body ~reg union_names (path ^ ".body") scope.rs_body
    in
    require_function_body ~reg union_names (path ^ ".cleanup") scope.rs_cleanup

and require_resource_cleanup_exit ~reg union_names path
    (cleanup_exit : Core.resource_cleanup_exit) =
  let rec check index = function
    | [] -> Ok ()
    | cleanup :: rest ->
        let cleanup_path = Printf.sprintf "%s.cleanups[%d]" path index in
        let* _ = require_resource_cleanup_call cleanup_path cleanup in
        let* () = require_function_body ~reg union_names cleanup_path cleanup in
        check (index + 1) rest
  in
  check 0 cleanup_exit.rce_cleanups

and require_stack_option_arg path (value : Core.boxed_storage_value) =
  if value.bsv_needs_release then
    unsupported path "managed stack Option payload"
  else if value.bsv_transfers_ownership then
    unsupported path "owned stack Option payload transfer"
  else if is_void_type value.bsv_box.box_value.ty then
    unsupported path "void stack Option payload"
  else require_simple_expr (path ^ ".value") value.bsv_box.box_value

and require_union_construct path (uc : Core.union_construct) =
  match uc.uc_representation with
  | Core.OptionUnion layout -> (
      match Core_layout_type.option_constructor_abi_of_layout layout with
      | Core_layout_type.OptionConstructorStackInline _ -> (
          if uc.uc_release_mask <> 0 then
            unsupported path "managed stack Option constructor"
          else
	            match uc.uc_args with
	            | [] -> Ok ()
	            | [ arg ] -> require_stack_option_arg (path ^ ".args[0]") arg
	            | _ -> unsupported path "stack Option constructor arity above one")
      | Core_layout_type.OptionConstructorNullableManaged ->
          (match uc.uc_args with
          | [] -> Ok ()
          | [ arg ] -> require_simple_expr (path ^ ".args[0]") arg.bsv_box.box_value
          | _ -> unsupported path "nullable managed Option constructor arity above one")
      | Core_layout_type.OptionConstructorBoxedUnion ->
          unsupported path "boxed Option union constructor"
      | Core_layout_type.OptionConstructorUnavailable reason ->
          unsupported path ("unavailable Option constructor ABI: " ^ reason))
  | Core.GenericUnion -> unsupported path "generic union construction"
  | Core.ResultUnion _ -> unsupported path "Result union construction"

and require_function_body ~reg union_names path (expr : Core.core) =
  match expr.desc with
  | Core.CLet (binding, body) ->
      if is_void_type binding.bind_ty then
        let* () =
          require_function_body ~reg union_names (path ^ ".rhs")
            binding.bind_rhs
        in
        require_function_body ~reg union_names (path ^ ".body") body
      else if String.equal (Core.Var.to_c_name binding.bind_var) "_" then
        let* () =
          require_function_body ~reg union_names (path ^ ".rhs")
            binding.bind_rhs
        in
        require_function_body ~reg union_names (path ^ ".body") body
      else
        let* () =
          require_function_body ~reg union_names (path ^ ".rhs")
            binding.bind_rhs
        in
        require_function_body ~reg union_names (path ^ ".body") body
  | Core.CBorrowLet (binding, body) ->
      if is_void_type binding.borrow_ty then
        let* () =
          require_function_body ~reg union_names (path ^ ".rhs")
            binding.borrow_rhs
        in
        require_function_body ~reg union_names (path ^ ".body") body
      else if String.equal (Core.Var.to_c_name binding.borrow_var) "_" then
        let* () =
          require_function_body ~reg union_names (path ^ ".rhs")
            binding.borrow_rhs
        in
        require_function_body ~reg union_names (path ^ ".body") body
      else
        let* () =
          require_function_body ~reg union_names (path ^ ".rhs")
            binding.borrow_rhs
        in
        require_function_body ~reg union_names (path ^ ".body") body
  | Core.CAssign (_variable, rhs) ->
      require_function_body ~reg union_names (path ^ ".rhs") rhs
  | Core.CTailrecLoop
      (Core.TailrecUnmanagedLoop { tul_params = _; tul_return_ty; tul_body }) ->
      require_tailrec_tail ~reg union_names (path ^ ".body") tul_return_ty
        tul_body
  | Core.CTailrecLoop (Core.TailrecListSpreadLoop _) ->
      unsupported path "list-spread tail-recursive loop"
  | Core.CTailrecRecur _ ->
      unsupported path "tail-recursive recur outside tail-recursive loop"
  | Core.CSeq (first, second) ->
      let* () =
        require_function_body ~reg union_names (path ^ ".first") first
      in
      require_function_body ~reg union_names (path ^ ".second") second
  | Core.CIf (cond, then_expr, else_expr) -> (
      match require_simple_expr path expr with
      | Ok () -> Ok ()
      | Error _ ->
          let* () =
            require_condition_expr ~reg union_names (path ^ ".cond") cond
          in
          let* () =
            require_function_body ~reg union_names (path ^ ".then") then_expr
          in
          require_function_body ~reg union_names (path ^ ".else") else_expr)
  | Core.CWhile (cond, body) ->
      let* () =
        require_condition_expr ~reg union_names (path ^ ".cond") cond
      in
      require_function_body ~reg union_names (path ^ ".body") body
  | Core.CFor (_binder, { desc = Core.CRange (lo, hi); _ }, body) ->
      let* () = require_simple_expr (path ^ ".start") lo in
      let* () = require_simple_expr (path ^ ".end") hi in
      require_function_body ~reg union_names (path ^ ".body") body
  | Core.CFor (_binder, iter, body) -> (
      match iter.ty with
      | Ast.TyNamed ("List", _) ->
          let layout = list_layout_for_expr iter in
          let* () =
            require_borrowed_list_iterable (path ^ ".iterable") iter
          in
          let* () = require_pointer_list_loop_layout (path ^ ".layout") layout in
          let* () = require_simple_expr (path ^ ".iterable") iter in
          require_function_body ~reg union_names (path ^ ".body") body
      | _ -> unsupported path "non-range for loop")
  | Core.CMatch
      ( scrutinee,
        Core.CTSwitchLit { ctl_scrut = Core.AccRoot; ctl_cases; ctl_default } )
    ->
      require_literal_match_expr ~reg union_names path scrutinee ctl_cases
        ctl_default
  | Core.CMatch
      ( scrutinee,
        Core.CTSwitchTag { cts_scrut = Core.AccRoot; cts_cases; cts_default } )
    ->
      require_constructor_match_expr ~reg union_names path scrutinee cts_cases
        cts_default
  | Core.CMatch _ -> unsupported path "compiled match"
  | Core.CCooperativeCheckpoint -> Ok ()
  | Core.CBreak | Core.CContinue -> Ok ()
  | Core.CResourceScope scope ->
      require_resource_scope ~reg union_names path scope
  | Core.CResourceCleanupExit cleanup_exit ->
      require_resource_cleanup_exit ~reg union_names path cleanup_exit
  | Core.CTensorRawViewLet (binding, body) ->
      let* () = require_tensor_raw_view_binding (path ^ ".binding") binding in
      require_function_body ~reg union_names (path ^ ".body") body
  | Core.CDup (_variable, value_ty, body) ->
      let _retain_policy = retain_policy_tag ~reg value_ty in
      require_function_body ~reg union_names (path ^ ".body") body
  | Core.CDrop (_variable, value_ty, body) ->
      let _release_policy = release_policy_tag ~reg value_ty in
      require_function_body ~reg union_names (path ^ ".body") body
  | _ -> require_simple_expr path expr

and require_condition_expr ~reg union_names path (cond : Core.core) =
  match require_simple_expr path cond with
  | Ok () -> Ok ()
  | Error _ -> require_function_body ~reg union_names path cond

and require_tailrec_tail ~reg union_names path return_ty (expr : Core.core) =
  match expr.desc with
  | Core.CTailrecRecur (Core.TailrecRecur { tr_args }) ->
      require_simple_args path tr_args
  | Core.CTailrecRecur (Core.TailrecListSpreadRecur _) ->
      unsupported path "list-spread tail-recursive recur"
  | Core.CLet (binding, body) ->
      if is_void_type binding.bind_ty then
        let* () =
          require_function_body ~reg union_names (path ^ ".rhs")
            binding.bind_rhs
        in
        require_tailrec_tail ~reg union_names (path ^ ".body") return_ty body
      else if String.equal (Core.Var.to_c_name binding.bind_var) "_" then
        let* () =
          require_function_body ~reg union_names (path ^ ".rhs")
            binding.bind_rhs
        in
        require_tailrec_tail ~reg union_names (path ^ ".body") return_ty body
      else
        let* () =
          require_function_body ~reg union_names (path ^ ".rhs")
            binding.bind_rhs
        in
        require_tailrec_tail ~reg union_names (path ^ ".body") return_ty body
  | Core.CBorrowLet (binding, body) ->
      if is_void_type binding.borrow_ty then
        let* () =
          require_function_body ~reg union_names (path ^ ".rhs")
            binding.borrow_rhs
        in
        require_tailrec_tail ~reg union_names (path ^ ".body") return_ty body
      else if String.equal (Core.Var.to_c_name binding.borrow_var) "_" then
        let* () =
          require_function_body ~reg union_names (path ^ ".rhs")
            binding.borrow_rhs
        in
        require_tailrec_tail ~reg union_names (path ^ ".body") return_ty body
      else
        let* () =
          require_function_body ~reg union_names (path ^ ".rhs")
            binding.borrow_rhs
        in
        require_tailrec_tail ~reg union_names (path ^ ".body") return_ty body
  | Core.CSeq (first, second) ->
      let* () =
        require_function_body ~reg union_names (path ^ ".first") first
      in
      require_tailrec_tail ~reg union_names (path ^ ".second") return_ty second
  | Core.CIf (cond, then_expr, else_expr) ->
      let* () = require_simple_expr (path ^ ".cond") cond in
      let* () =
        require_tailrec_tail ~reg union_names (path ^ ".then") return_ty
          then_expr
      in
      require_tailrec_tail ~reg union_names (path ^ ".else") return_ty else_expr
  | Core.CMatch
      ( scrutinee,
        Core.CTSwitchLit { ctl_scrut = Core.AccRoot; ctl_cases; ctl_default } )
    ->
      require_literal_match_expr ~reg union_names path scrutinee ctl_cases
        ctl_default
  | Core.CMatch
      ( scrutinee,
        Core.CTSwitchTag { cts_scrut = Core.AccRoot; cts_cases; cts_default } )
    ->
      require_constructor_match_expr ~reg union_names path scrutinee cts_cases
        cts_default
  | Core.CMatch _ -> unsupported path "compiled match"
  | Core.CTailrecLoop _ -> unsupported path "nested tail-recursive loop"
  | Core.CResourceScope scope ->
      require_resource_scope ~reg union_names path scope
  | Core.CResourceCleanupExit cleanup_exit ->
      require_resource_cleanup_exit ~reg union_names path cleanup_exit
  | Core.CTensorRawViewLet (binding, body) ->
      let* () = require_tensor_raw_view_binding (path ^ ".binding") binding in
      require_tailrec_tail ~reg union_names (path ^ ".body") return_ty body
  | Core.CDup (_variable, value_ty, body) ->
      let _retain_policy = retain_policy_tag ~reg value_ty in
      require_tailrec_tail ~reg union_names (path ^ ".body") return_ty body
  | Core.CDrop (_variable, value_ty, body) ->
      let _release_policy = release_policy_tag ~reg value_ty in
      require_tailrec_tail ~reg union_names (path ^ ".body") return_ty body
  | _ ->
      if is_void_type return_ty then
        require_function_body ~reg union_names path expr
      else require_simple_expr path expr

and require_literal_match_expr ~reg union_names path scrutinee cases fallback =
  let* () = require_function_body ~reg union_names (path ^ ".scrutinee") scrutinee in
  let* () =
    require_literal_match_cases ~reg union_names (path ^ ".cases") cases
  in
  require_literal_match_fallback ~reg union_names (path ^ ".fallback") fallback

and require_literal_match_fallback ~reg union_names path = function
  | Core.CTLeaf { ct_bindings = []; ct_body } ->
      require_function_body ~reg union_names (path ^ ".body") ct_body
  | Core.CTLeaf { ct_bindings = _ :: _; _ } ->
      unsupported path "literal match fallback bindings"
  | Core.CTFail -> Ok ()
  | Core.CTSwitchTag _ -> unsupported path "nested constructor match fallback"
  | Core.CTSwitchLit _ -> unsupported path "nested literal match fallback"
  | Core.CTSwitchLen _ -> unsupported path "nested length match fallback"

and require_literal_match_cases ~reg union_names path cases =
  let rec check index = function
    | [] -> Ok ()
    | (literal, subtree) :: rest ->
        let case_path = Printf.sprintf "%s[%d]" path index in
        let* () =
          literal_match_literal_json (case_path ^ ".literal") literal
          |> Result.map ignore
        in
        let* body = literal_match_leaf_body (case_path ^ ".body") subtree in
        let* () =
          require_function_body ~reg union_names (case_path ^ ".body") body
        in
        check (index + 1) rest
  in
  check 0 cases

and require_constructor_match_expr ~reg union_names path scrutinee cases
    fallback =
  let* () = require_function_body ~reg union_names (path ^ ".scrutinee") scrutinee in
  let* () =
    require_constructor_match_cases ~reg union_names scrutinee.ty
      (path ^ ".cases") cases
  in
  require_constructor_match_fallback ~reg union_names (path ^ ".fallback")
    fallback

and require_constructor_match_fallback ~reg union_names path = function
  | None -> Ok ()
  | Some (Core.CTLeaf { ct_bindings = []; ct_body }) ->
      require_function_body ~reg union_names (path ^ ".body") ct_body
  | Some (Core.CTLeaf { ct_bindings = _ :: _; _ }) ->
      unsupported path "constructor match fallback bindings"
  | Some Core.CTFail -> Ok ()
  | Some (Core.CTSwitchTag _) ->
      unsupported path "nested constructor match fallback"
  | Some (Core.CTSwitchLit _) ->
      unsupported path "nested literal match fallback"
  | Some (Core.CTSwitchLen _) -> unsupported path "nested length match fallback"

and require_match_binding_accessor ~reg scrut_ty path = function
  | Core.AccVariantField (Core.AccRoot, "Some", 0)
    when Core_layout_type.is_stack_option_type ~reg scrut_ty ->
      Ok ()
  | Core.AccVariantField (Core.AccRoot, "Some", 0)
    when Core_layout_type.is_nullable_managed_option ~reg scrut_ty ->
      Ok ()
  | Core.AccVariantField (Core.AccRoot, _, _) -> Ok ()
  | Core.AccRoot -> unsupported path "root match binding accessor"
  | Core.AccVariantField _ ->
      unsupported path "nested variant match binding accessor"
  | Core.AccTupleField _ -> unsupported path "tuple match binding accessor"
  | Core.AccListElem _ -> unsupported path "list element match binding accessor"
  | Core.AccListSpread _ -> unsupported path "list spread match binding accessor"

and require_match_binding ~reg scrut_ty path (binding : Core.match_binding) =
  match binding.mb_mode with
  | Core.MatchBorrow ->
      require_match_binding_accessor ~reg scrut_ty (path ^ ".accessor")
        binding.mb_accessor
  | Core.MatchOwn -> unsupported path "owned match binding"

and require_match_bindings ~reg scrut_ty path bindings =
  let rec check index = function
    | [] -> Ok ()
    | binding :: rest ->
        let binding_path = Printf.sprintf "%s[%d]" path index in
        let* () = require_match_binding ~reg scrut_ty binding_path binding in
        check (index + 1) rest
  in
  check 0 bindings

and require_constructor_match_cases ~reg union_names scrut_ty path cases =
  let rec check index = function
    | [] -> Ok ()
    | (_ctor, subtree) :: rest ->
        let case_path = Printf.sprintf "%s[%d]" path index in
        let* bindings, body =
          constructor_match_leaf_body (case_path ^ ".body") subtree
        in
        let* () =
          require_match_bindings ~reg scrut_ty (case_path ^ ".bindings")
            bindings
        in
        let* () =
          require_function_body ~reg union_names (case_path ^ ".body") body
        in
        check (index + 1) rest
  in
  check 0 cases

let function_json ~reg ~enum_names ~value_record_names ~heap_record_names ~union_names
    ~enum_constructors ~global_def_ids ~global_names path loc
    (func : Core.core_func) =
  let* params =
    result_list func.cf_params (fun index param ->
        param_json ~reg enum_names value_record_names heap_record_names union_names
          (Printf.sprintf "%s.params[%d]" path index)
          param)
  in
  let* return_type =
    type_json ~reg enum_names value_record_names heap_record_names union_names (path ^ ".return_type")
      func.cf_return_ty
  in
  let* body =
    match func.cf_body with
    | Some body ->
        if expr_uses_global global_def_ids global_names body then
          unsupported (path ^ ".body") "global variable reference"
        else
          let* () =
            require_function_body ~reg union_names (path ^ ".body") body
          in
          expr_json ~reg enum_names value_record_names heap_record_names union_names
            enum_constructors (path ^ ".body") body
    | None -> Ok null
  in
  let* function_kind =
    function_kind_json ~reg enum_names value_record_names heap_record_names
      union_names (path ^ ".function_kind") func
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
         ("function_kind", function_kind);
         ("def_id", int func.cf_def_id);
         ("loc", source_loc_json loc);
       ])

let static_scalar_global_supported (global : Core.core_var) =
  (not global.cv_is_mutable) && global.cv_is_const
  &&
  match global.cv_init.desc with
  | Core.CLit (Ast.LitInt value) -> int64_fits_json_int value
  | Core.CLit (Ast.LitFloat value) -> (
      match classify_float value with
      | FP_nan | FP_infinite -> false
      | FP_normal | FP_subnormal | FP_zero -> true)
  | Core.CLit (Ast.LitBool _ | Ast.LitChar _) -> true
  | _ -> false

let project_global_decl (global : Core.core_var) =
  match global.cv_module with
  | Some _ -> static_scalar_global_supported global
  | None -> true

let global_json ~reg enum_names value_record_names heap_record_names union_names path loc
    (global : Core.core_var) =
  if not (static_scalar_global_supported global) then
    unsupported path "non-static scalar global declaration"
  else
    match global.cv_init.desc with
    | Core.CLit literal ->
        let* init_literal =
          static_scalar_global_literal_json (path ^ ".init.literal") literal
        in
        let* typ =
          type_json ~reg enum_names value_record_names heap_record_names union_names (path ^ ".type")
            global.cv_ty
        in
        let* init_typ =
          type_json ~reg enum_names value_record_names heap_record_names union_names
            (path ^ ".init.type") global.cv_init.ty
        in
        let init =
          kind "literal"
            [
              ("literal", init_literal);
              ("type", init_typ);
              ("loc", source_loc_json global.cv_init.loc);
            ]
        in
        Ok
          (kind "global"
             [
               ("name", var_json global.cv_name);
               ("type", typ);
               ("init", init);
               ("mutable", bool global.cv_is_mutable);
               ("const", bool global.cv_is_const);
               ("def_id", int global.cv_def_id);
               ("loc", source_loc_json loc);
             ])
    | _ -> unsupported path "non-literal global initializer"

let constructor_c_name name def_id =
  match def_id with
  | Some id -> Codegen_names.mangle_by_def_id id name
  | None -> Codegen_names.sanitize_c_ident name

let enum_variant_json path (variant : Ast.variant) =
  match variant.variant_fields with
  | _ :: _ -> unsupported path "enum variant payload"
  | [] ->
      Ok
        (obj
           [
             ("name", str variant.variant_name);
             ( "c_name",
               str
                 (constructor_c_name variant.variant_name variant.variant_def_id)
             );
             ("tag", int variant.variant_tag);
             ("def_id", option_int_json variant.variant_def_id);
           ])

let enum_decl_json path loc (type_decl : Ast.type_decl) =
  if type_decl.type_params <> [] then
    unsupported path "generic enum declaration"
  else
    let* variants =
      result_list type_decl.type_variants (fun index variant ->
          enum_variant_json
            (Printf.sprintf "%s.variants[%d]" path index)
            variant)
    in
    Ok
      (kind "enum"
         [
           ("name", str type_decl.type_name);
           ("variants", variants);
           ("loc", source_loc_json loc);
         ])

let supported_union_field_type = function
  | Ast.TyNamed
      ( ( "Int" | "Int8" | "Int16" | "Int32" | "Int64" | "UInt8" | "UInt16"
        | "UInt32" | "UInt64" | "Bool" | "Char" ),
        [] ) ->
      true
  | Ast.TyConstInt _ -> true
  | _ -> false

let variant_tag_c_name type_name (variant : Ast.variant) =
  Printf.sprintf "TAG_%s_%s"
    (Codegen_names.sanitize_c_ident type_name)
    (Codegen_names.sanitize_c_ident variant.variant_name)

let union_variant_json ~reg enum_names value_record_names heap_record_names
    union_names type_name path (variant : Ast.variant) =
  match variant.variant_fields with
  | [] -> unsupported path "nullary union variant"
  | fields when List.for_all supported_union_field_type fields ->
      let* field_values =
        result_list fields (fun index field_ty ->
            type_json ~reg enum_names value_record_names heap_record_names union_names
              (Printf.sprintf "%s.fields[%d]" path index)
              field_ty)
      in
      Ok
        (obj
           [
             ("name", str variant.variant_name);
             ( "c_name",
               str
                 (constructor_c_name variant.variant_name variant.variant_def_id)
             );
             ("tag_c_name", str (variant_tag_c_name type_name variant));
             ("tag", int variant.variant_tag);
             ("fields", field_values);
             ("def_id", option_int_json variant.variant_def_id);
           ])
  | _ -> unsupported path "managed union variant payload"

let union_decl_json ~reg enum_names value_record_names heap_record_names union_names path loc
    (type_decl : Ast.type_decl) =
  if type_decl.type_params <> [] then
    unsupported path "generic union declaration"
  else
    let* variants =
      result_list type_decl.type_variants (fun index variant ->
          union_variant_json ~reg enum_names value_record_names heap_record_names union_names
            type_decl.type_name
            (Printf.sprintf "%s.variants[%d]" path index)
            variant)
    in
    Ok
      (kind "union"
         [
           ("name", str type_decl.type_name);
           ("variants", variants);
           ("loc", source_loc_json loc);
         ])

let supported_union_decl (type_decl : Ast.type_decl) =
  (not type_decl.type_is_builtin)
  && (not type_decl.type_is_enum)
  && type_decl.type_params = []
  && type_decl.type_variants <> []
  && List.for_all
       (fun (variant : Ast.variant) ->
         variant.variant_fields <> []
         && List.for_all supported_union_field_type variant.variant_fields)
       type_decl.type_variants

let value_record_field_json ~reg enum_names value_record_names heap_record_names
    union_names path (field : Ast.field_decl) =
  let* typ =
    type_json ~reg enum_names value_record_names heap_record_names union_names (path ^ ".type")
      field.field_type
  in
  Ok (obj [ ("name", str field.field_name); ("type", typ) ])

let value_record_decl_json ~reg enum_names value_record_names heap_record_names union_names path loc
    (record_decl : Ast.record_decl) =
  if record_decl.record_type_params <> [] then
    unsupported path "generic value record declaration"
  else
    let* fields =
      result_list record_decl.record_fields (fun index field ->
          value_record_field_json ~reg enum_names value_record_names heap_record_names union_names
            (Printf.sprintf "%s.fields[%d]" path index)
            field)
    in
    Ok
      (kind "value_record"
         [
           ("name", str record_decl.record_name);
           ("fields", fields);
           ("loc", source_loc_json loc);
         ])

let heap_record_field_json ~reg enum_names value_record_names heap_record_names union_names path
    (field : Ast.field_decl) =
  if Core_layout_type.record_field_uses_erased_storage ~reg field.field_type then
    unsupported path "heap record field with erased storage"
  else
    let* typ =
      type_json ~reg enum_names value_record_names heap_record_names union_names
        (path ^ ".type") field.field_type
    in
    Ok
      (obj
         [
           ("name", str field.field_name);
           ("type", typ);
           ("release_policy", release_policy_json ~reg field.field_type);
         ])

let heap_record_decl_json ~reg enum_names value_record_names heap_record_names union_names path loc
    (record_decl : Ast.record_decl) =
  if record_decl.record_type_params <> [] then
    unsupported path "generic heap record declaration"
  else
    let* fields =
      result_list record_decl.record_fields (fun index field ->
          heap_record_field_json ~reg enum_names value_record_names
            heap_record_names union_names
            (Printf.sprintf "%s.fields[%d]" path index)
            field)
    in
    Ok
      (kind "heap_record"
         [
           ("name", str record_decl.record_name);
           ("fields", fields);
           ("loc", source_loc_json loc);
         ])

let impl_method_c_name (impl : Core.core_impl) (method_func : Core.core_func) =
  let type_name =
    match Codegen_types.type_key_for_impl impl.ci_for_type with
    | Some name -> name
    | None -> "Unknown"
  in
  Printf.sprintf "%s_%s_%s" impl.ci_trait method_func.cf_name type_name

let impl_method_jsons ~reg ~enum_names ~value_record_names ~heap_record_names ~union_names
    ~enum_constructors ~global_def_ids ~global_names path loc
    (impl : Core.core_impl) =
  if Codegen_types.has_type_vars impl.ci_for_type then Ok []
  else
    let rec collect acc index = function
      | [] -> Ok (List.rev acc)
      | (method_func : Core.core_func) :: rest ->
          let method_path = Printf.sprintf "%s.methods[%d]" path index in
          let method_func =
            { method_func with cf_name = impl_method_c_name impl method_func }
          in
          if method_func.cf_body = None || method_func.cf_type_params <> [] then
            collect acc (index + 1) rest
          else
            let* json =
              function_json ~reg ~enum_names ~value_record_names ~heap_record_names ~union_names
                ~enum_constructors ~global_def_ids ~global_names method_path loc
                method_func
            in
            collect (json :: acc) (index + 1) rest
    in
    collect [] 0 impl.ci_methods

let rec decl_jsons ~reg enum_names value_record_names heap_record_names union_names
    enum_constructors global_def_ids global_names index (decl : Core.core_decl)
    =
  let path = Printf.sprintf "program.decls[%d]" index in
  match decl.cd_desc with
  | Core.CDFunc func when func.cf_body = None || func.cf_type_params <> [] ->
      Ok []
  | Core.CDFunc func ->
      let* json =
        function_json ~reg ~enum_names ~value_record_names ~heap_record_names ~union_names
          ~enum_constructors ~global_def_ids ~global_names path decl.cd_loc func
      in
      Ok [ json ]
  | Core.CDType type_decl
    when type_decl.type_is_enum && not type_decl.type_is_builtin ->
      let* json = enum_decl_json path decl.cd_loc type_decl in
      Ok [ json ]
  | Core.CDType type_decl when supported_union_decl type_decl ->
      let* json =
        union_decl_json ~reg enum_names value_record_names heap_record_names union_names path
          decl.cd_loc type_decl
      in
      Ok [ json ]
  | Core.CDRecord record_decl
    when record_decl.record_is_value && not record_decl.record_is_builtin ->
      let* json =
        value_record_decl_json ~reg enum_names value_record_names heap_record_names union_names path
          decl.cd_loc record_decl
      in
      Ok [ json ]
  | Core.CDRecord record_decl
    when (not record_decl.record_is_value) && not record_decl.record_is_builtin ->
      let* json =
        heap_record_decl_json ~reg enum_names value_record_names heap_record_names
          union_names path decl.cd_loc record_decl
      in
      Ok [ json ]
  | Core.CDImport _ | Core.CDTrait _ | Core.CDType _ | Core.CDTypeAlias _
  | Core.CDRecord _ ->
      Ok []
  | Core.CDPrivate inner ->
      decl_jsons ~reg enum_names value_record_names heap_record_names union_names
        enum_constructors global_def_ids global_names index inner
  | Core.CDVar global when project_global_decl global ->
      let* json =
        global_json ~reg enum_names value_record_names heap_record_names union_names path decl.cd_loc
          global
      in
      Ok [ json ]
  | Core.CDVar _ -> Ok []
  | Core.CDImpl impl ->
      impl_method_jsons ~reg ~enum_names ~value_record_names ~heap_record_names ~union_names
        ~enum_constructors ~global_def_ids ~global_names path decl.cd_loc impl

let program_json ~reg (program : Core.core_program) =
  let rec collect_enum_names names (decl : Core.core_decl) =
    match decl.cd_desc with
    | Core.CDType type_decl
      when type_decl.type_is_enum && not type_decl.type_is_builtin ->
        StringSet.add type_decl.type_name names
    | Core.CDPrivate inner -> collect_enum_names names inner
    | _ -> names
  in
  let rec collect_value_record_names names (decl : Core.core_decl) =
    match decl.cd_desc with
    | Core.CDRecord record_decl
      when record_decl.record_is_value && not record_decl.record_is_builtin ->
        StringSet.add record_decl.record_name names
    | Core.CDPrivate inner -> collect_value_record_names names inner
    | _ -> names
  in
  let rec collect_heap_record_names names (decl : Core.core_decl) =
    match decl.cd_desc with
    | Core.CDRecord record_decl
      when (not record_decl.record_is_value) && not record_decl.record_is_builtin ->
        StringSet.add record_decl.record_name names
    | Core.CDPrivate inner -> collect_heap_record_names names inner
    | _ -> names
  in
  let rec collect_union_names names (decl : Core.core_decl) =
    match decl.cd_desc with
    | Core.CDType type_decl when supported_union_decl type_decl ->
        StringSet.add type_decl.type_name names
    | Core.CDPrivate inner -> collect_union_names names inner
    | _ -> names
  in
  let add_enum_constructor type_name constructors (variant : Ast.variant) =
    StringMap.add
      (enum_constructor_key type_name variant.variant_name)
      (constructor_c_name variant.variant_name variant.variant_def_id)
      constructors
  in
  let rec collect_enum_constructors constructors (decl : Core.core_decl) =
    match decl.cd_desc with
    | Core.CDType type_decl
      when type_decl.type_is_enum && not type_decl.type_is_builtin ->
        List.fold_left
          (add_enum_constructor type_decl.type_name)
          constructors type_decl.type_variants
    | Core.CDPrivate inner -> collect_enum_constructors constructors inner
    | _ -> constructors
  in
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
  let rec collect_projected_global_def_ids ids (decl : Core.core_decl) =
    match decl.cd_desc with
    | Core.CDVar global when project_global_decl global ->
        IntSet.add global.cv_def_id ids
    | Core.CDPrivate inner -> collect_projected_global_def_ids ids inner
    | _ -> ids
  in
  let rec collect_projected_global_names names (decl : Core.core_decl) =
    match decl.cd_desc with
    | Core.CDVar global when project_global_decl global ->
        StringSet.add (Core.Var.to_c_name global.cv_name) names
    | Core.CDPrivate inner -> collect_projected_global_names names inner
    | _ -> names
  in
  let enum_names = List.fold_left collect_enum_names StringSet.empty program in
  let value_record_names =
    List.fold_left collect_value_record_names StringSet.empty program
  in
  let heap_record_names =
    List.fold_left collect_heap_record_names StringSet.empty program
  in
  let union_names =
    List.fold_left collect_union_names StringSet.empty program
  in
  let enum_constructors =
    List.fold_left collect_enum_constructors StringMap.empty program
  in
  let all_global_def_ids =
    List.fold_left collect_global_def_ids IntSet.empty program
  in
  let all_global_names =
    List.fold_left collect_global_names StringSet.empty program
  in
  let projected_global_def_ids =
    List.fold_left collect_projected_global_def_ids IntSet.empty program
  in
  let projected_global_names =
    List.fold_left collect_projected_global_names StringSet.empty program
  in
  let unsupported_global_def_ids =
    IntSet.diff all_global_def_ids projected_global_def_ids
  in
  let unsupported_global_names =
    StringSet.diff all_global_names projected_global_names
  in
  let rec collect acc index = function
    | [] -> Ok (arr (List.rev acc))
    | decl :: rest -> (
        match
          decl_jsons ~reg enum_names value_record_names heap_record_names union_names
            enum_constructors unsupported_global_def_ids
            unsupported_global_names index decl
        with
        | Ok jsons -> collect (List.rev_append jsons acc) (index + 1) rest
        | Error _ as error -> error)
  in
  let* decls = collect [] 0 program in
  Ok (kind "program" [ ("decls", decls) ])

type config = {
  embed_runtime : bool;
  profile : bool;
  reg : Codegen_types.registry;
}

let config_with_embed ~embed_runtime ?(profile = false) ~reg () =
  { embed_runtime; profile; reg }

let with_embedded_runtime (artifact : Compiler_blorp_bridge.c_artifact) =
  {
    artifact with
    Compiler_blorp_bridge.c_code =
      Runtime.runtime_code ^ "\n" ^ artifact.Compiler_blorp_bridge.c_code;
  }

let emit_program_to_artifact (config : config) (program : Core.core_program) =
  if config.profile then unsupported "config.profile" "profile emission"
  else
    let* core_json = program_json ~reg:config.reg program in
    let artifact =
      Compiler_blorp_bridge.prepare_and_emit_c_artifact_exn core_json
    in
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
