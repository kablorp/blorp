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
      "blorp_float16_to_string";
      "blorp_float32_to_string";
      "blorp_float_to_string";
      "blorp_now_us";
      "blorp_print";
      "blorp_print_error";
      "blorp_puts";
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

let rec type_json enum_names value_record_names union_names path
    (ty : Ast.type_expr) =
  match ty with
  | Ast.TyNamed ("Void", []) -> Ok (kind "void" [])
  | Ast.TyNamed (name, []) when StringSet.mem name enum_names ->
      Ok (kind "enum" [ ("name", str name) ])
  | Ast.TyNamed (name, _ :: _) when StringSet.mem name enum_names ->
      unsupported path ("generic enum type " ^ name)
  | Ast.TyNamed (name, []) when StringSet.mem name value_record_names ->
      Ok (kind "value_record" [ ("name", str name) ])
  | Ast.TyNamed (name, _ :: _) when StringSet.mem name value_record_names ->
      unsupported path ("generic value record type " ^ name)
  | Ast.TyNamed (name, []) when StringSet.mem name union_names ->
      Ok (kind "union" [ ("name", str name) ])
  | Ast.TyNamed (name, _ :: _) when StringSet.mem name union_names ->
      unsupported path ("generic union type " ^ name)
  | Ast.TyNamed (name, args) ->
      let* arg_values =
        result_list args (fun index arg ->
            type_json enum_names value_record_names union_names
              (Printf.sprintf "%s.args[%d]" path index)
              arg)
      in
      Ok (kind "named" [ ("name", str name); ("args", arg_values) ])
  | Ast.TyConstInt _ ->
      Ok (kind "named" [ ("name", str "Int"); ("args", arr []) ])
  | Ast.TyTuple items ->
      let* item_values =
        result_list items (fun index item ->
            type_json enum_names value_record_names union_names
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

let supported_tuple_field_type = function
  | Ast.TyNamed
      ( ( "Int" | "Int8" | "Int16" | "Int32" | "Int64" | "UInt8" | "UInt16"
        | "UInt32" | "UInt64" | "Bool" | "Char" ),
        [] ) ->
      true
  | _ -> false

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
  | Core.CTLeaf { ct_bindings = []; ct_body } -> Ok ct_body
  | Core.CTLeaf { ct_bindings = _ :: _; _ } ->
      unsupported path "constructor match bindings"
  | Core.CTFail -> unsupported path "constructor match fail case"
  | Core.CTSwitchTag _ -> unsupported path "nested constructor match"
  | Core.CTSwitchLit _ -> unsupported path "nested literal match"
  | Core.CTSwitchLen _ -> unsupported path "nested length match"

let enum_constructor_c_name_for_match enum_constructors path scrut_ty ctor =
  match scrut_ty with
  | Ast.TyNamed (type_name, []) -> (
      match
        StringMap.find_opt
          (enum_constructor_key type_name ctor)
          enum_constructors
      with
      | Some c_name -> Ok c_name
      | None -> unsupported path ("unknown enum constructor " ^ ctor))
  | _ -> unsupported path "constructor match on non-enum type"

let param_json enum_names value_record_names union_names path
    (param : Core.core_param) =
  let* typ =
    type_json enum_names value_record_names union_names (path ^ ".type")
      param.cp_ty
  in
  Ok
    (obj
       [
         ("name", var_json param.cp_name);
         ("type", typ);
         ("loc", source_loc_json param.cp_loc);
       ])

let loop_range_direction_json = function
  | Core.RangeMayRunBackward -> str "may_run_backward"
  | Core.RangeForwardOnly -> str "forward_only"

let loop_binder_json enum_names value_record_names union_names path
    (binder : Core.loop_binder) =
  let* typ =
    type_json enum_names value_record_names union_names (path ^ ".type")
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

let rec expr_json ~reg enum_names value_record_names union_names enum_constructors
    path (expr : Core.core) =
  let loc = source_loc_json expr.loc in
  let typed fields =
    let* typ =
      type_json enum_names value_record_names union_names (path ^ ".type")
        expr.ty
    in
    Ok (fields @ [ ("type", typ); ("loc", loc) ])
  in
  let literal_match_fallback_json path = function
    | Core.CTLeaf { ct_bindings = []; ct_body } ->
        let* body =
          expr_json ~reg enum_names value_record_names union_names enum_constructors
            (path ^ ".body") ct_body
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
  | Core.CCall (call_kind, callee, args) ->
      let* call_kind_value = call_kind_json (path ^ ".call_kind") call_kind in
      let* callee_value =
        expr_json ~reg enum_names value_record_names union_names enum_constructors
          (path ^ ".callee") callee
      in
      let* args_value =
        result_list args (fun index arg ->
            expr_json ~reg enum_names value_record_names union_names
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
            expr_json ~reg enum_names value_record_names union_names
              enum_constructors (path ^ ".left") left
          in
          let* right_value =
            expr_json ~reg enum_names value_record_names union_names
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
        expr_json ~reg enum_names value_record_names union_names enum_constructors
          (path ^ ".expr") inner
      in
      let* fields =
        typed [ ("op", str (unop_tag op)); ("expr", inner_value) ]
      in
      Ok (kind "unary" fields)
  | Core.CLog (op, left, right) ->
      let* left_value =
        expr_json ~reg enum_names value_record_names union_names enum_constructors
          (path ^ ".left") left
      in
      let* right_value =
        expr_json ~reg enum_names value_record_names union_names enum_constructors
          (path ^ ".right") right
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
        expr_json ~reg enum_names value_record_names union_names enum_constructors
          (path ^ ".rhs") rhs
      in
      let* fields = typed [ ("var", var_json variable); ("rhs", rhs_value) ] in
      Ok (kind "assign" fields)
  | Core.CCast (inner, target_ty) ->
      let* inner_value =
        expr_json ~reg enum_names value_record_names union_names enum_constructors
          (path ^ ".expr") inner
      in
      let* typ =
        type_json enum_names value_record_names union_names (path ^ ".type")
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
            expr_json ~reg enum_names value_record_names union_names
              enum_constructors (path ^ ".expr") inner
          in
          let* fields =
            typed [ ("expr", inner_value); ("field", str field_name) ]
          in
          Ok (kind "field" fields)
      | Ast.TyRange _ -> unsupported path ("unknown range field " ^ field_name)
      | Ast.TyNamed (name, []) when StringSet.mem name value_record_names ->
          let* inner_value =
            expr_json ~reg enum_names value_record_names union_names
              enum_constructors (path ^ ".expr") inner
          in
          let* fields =
            typed [ ("expr", inner_value); ("field", str field_name) ]
          in
          Ok (kind "field" fields)
      | Ast.TyTuple items ->
          if not (supported_tuple_field_type expr.ty) then
            unsupported path "tuple field type outside Blorp backend subset"
          else
            let* field_index =
              tuple_field_index (path ^ ".field") (List.length items) field_name
            in
            let* inner_value =
              expr_json ~reg enum_names value_record_names union_names
                enum_constructors (path ^ ".expr") inner
            in
            let* fields =
              typed [ ("expr", inner_value); ("index", int field_index) ]
            in
            Ok (kind "tuple_field" fields)
      | _ ->
          unsupported path "field access on non-value record, range, or tuple")
  | Core.CLet (binding, body) ->
      let* typ =
        type_json enum_names value_record_names union_names (path ^ ".type")
          binding.bind_ty
      in
      let* rhs =
        expr_json ~reg enum_names value_record_names union_names enum_constructors
          (path ^ ".rhs") binding.bind_rhs
      in
      let* body =
        expr_json ~reg enum_names value_record_names union_names enum_constructors
          (path ^ ".body") body
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
  | Core.CSeq (first, second) ->
      let* first_value =
        expr_json ~reg enum_names value_record_names union_names enum_constructors
          (path ^ ".first") first
      in
      let* second_value =
        expr_json ~reg enum_names value_record_names union_names enum_constructors
          (path ^ ".second") second
      in
      Ok (kind "seq" [ ("first", first_value); ("second", second_value) ])
  | Core.CIf (cond, then_expr, else_expr) ->
      let* cond_value =
        expr_json ~reg enum_names value_record_names union_names enum_constructors
          (path ^ ".cond") cond
      in
      let* then_value =
        expr_json ~reg enum_names value_record_names union_names enum_constructors
          (path ^ ".then") then_expr
      in
      let* else_value =
        expr_json ~reg enum_names value_record_names union_names enum_constructors
          (path ^ ".else") else_expr
      in
      let* fields =
        typed
          [ ("cond", cond_value); ("then", then_value); ("else", else_value) ]
      in
      Ok (kind "if" fields)
  | Core.CWhile (cond, body) ->
      let* cond_value =
        expr_json ~reg enum_names value_record_names union_names enum_constructors
          (path ^ ".cond") cond
      in
      let* body_value =
        expr_json ~reg enum_names value_record_names union_names enum_constructors
          (path ^ ".body") body
      in
      let* fields = typed [ ("cond", cond_value); ("body", body_value) ] in
      Ok (kind "while" fields)
  | Core.CFor (binder, { desc = Core.CRange (lo, hi); _ }, body) ->
      let* binder_value =
        loop_binder_json enum_names value_record_names union_names
          (path ^ ".binder") binder
      in
      let* start_value =
        expr_json ~reg enum_names value_record_names union_names enum_constructors
          (path ^ ".start") lo
      in
      let* end_value =
        expr_json ~reg enum_names value_record_names union_names enum_constructors
          (path ^ ".end") hi
      in
      let* body_value =
        expr_json ~reg enum_names value_record_names union_names enum_constructors
          (path ^ ".body") body
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
  | Core.CFor _ -> unsupported path "non-range for loop"
  | Core.CRange (lo, hi) -> (
      match expr.ty with
      | Ast.TyRange _ ->
          let* start_value =
            expr_json ~reg enum_names value_record_names union_names
              enum_constructors (path ^ ".start") lo
          in
          let* end_value =
            expr_json ~reg enum_names value_record_names union_names
              enum_constructors (path ^ ".end") hi
          in
          let* fields = typed [ ("start", start_value); ("end", end_value) ] in
          Ok (kind "range" fields)
      | Ast.TyNamed (name, []) when StringSet.mem name value_record_names ->
          let* start_value =
            expr_json ~reg enum_names value_record_names union_names
              enum_constructors (path ^ ".start") lo
          in
          let* end_value =
            expr_json ~reg enum_names value_record_names union_names
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
        expr_json ~reg enum_names value_record_names union_names enum_constructors
          (path ^ ".scrutinee") scrutinee
      in
      let* cases_value =
        result_list ctl_cases (fun index (literal, subtree) ->
            let case_path = Printf.sprintf "%s.cases[%d]" path index in
            let* literal_value =
              literal_match_literal_json (case_path ^ ".literal") literal
            in
            let* body = literal_match_leaf_body (case_path ^ ".body") subtree in
            let* body_value =
              expr_json ~reg enum_names value_record_names union_names
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
              expr_json ~reg enum_names value_record_names union_names
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
        expr_json ~reg enum_names value_record_names union_names enum_constructors
          (path ^ ".scrutinee") scrutinee
      in
      let* cases_value =
        result_list cts_cases (fun index (ctor, subtree) ->
            let case_path = Printf.sprintf "%s.cases[%d]" path index in
            let* constructor_c_name =
              enum_constructor_c_name_for_match enum_constructors
                (case_path ^ ".constructor")
                scrutinee.ty ctor
            in
            let* body =
              constructor_match_leaf_body (case_path ^ ".body") subtree
            in
            let* body_value =
              expr_json ~reg enum_names value_record_names union_names
                enum_constructors (case_path ^ ".body") body
            in
            Ok
              (obj
                 [
                   ("constructor", str ctor);
                   ("constructor_c_name", str constructor_c_name);
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
        type_json enum_names value_record_names union_names
          (path ^ ".value_type") value_ty
      in
      let retain_policy = retain_policy_json ~reg value_ty in
      let* body_value =
        expr_json ~reg enum_names value_record_names union_names enum_constructors
          (path ^ ".body") body
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
        type_json enum_names value_record_names union_names
          (path ^ ".value_type") value_ty
      in
      let release_policy = release_policy_json ~reg value_ty in
      let* body_value =
        expr_json ~reg enum_names value_record_names union_names enum_constructors
          (path ^ ".body") body
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
            param_json enum_names value_record_names union_names
              (Printf.sprintf "%s.params[%d]" path index)
              param)
      in
      let* return_type =
        type_json enum_names value_record_names union_names
          (path ^ ".return_type") tul_return_ty
      in
      let* body_value =
        expr_json ~reg enum_names value_record_names union_names enum_constructors
          (path ^ ".body") tul_body
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
            expr_json ~reg enum_names value_record_names union_names
              enum_constructors
              (Printf.sprintf "%s.args[%d]" path index)
              arg)
      in
      let* fields = typed [ ("args", args_value) ] in
      Ok (kind "tailrec_recur" fields)
  | Core.CTailrecRecur (Core.TailrecListSpreadRecur _) ->
      unsupported path "list-spread tail-recursive recur"
  | Core.CTupleConstruct tc ->
      if tc.tc_release_mask <> 0 then
        unsupported path "managed tuple construction"
      else if tc.tc_retain_mask <> 0 then
        unsupported path "tuple construction requiring retain"
      else
        let* elements =
          result_list tc.tc_elems (fun index element ->
              let element_path = Printf.sprintf "%s.elements[%d]" path index in
              if element.bsv_needs_release then
                unsupported element_path "managed tuple element"
              else if element.bsv_transfers_ownership then
                unsupported element_path "owned tuple element transfer"
              else
                let* element_tag =
                  tuple_element_tag (element_path ^ ".kind")
                    element.bsv_box.box_kind
                in
                let* value =
                  expr_json ~reg enum_names value_record_names union_names
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
        let* fields = typed [ ("elements", elements) ] in
        Ok (kind "tuple_construct" fields)
  | Core.CTuple items -> (
      match expr.ty with
      | Ast.TyTuple item_tys
        when List.length items = List.length item_tys
             && List.for_all supported_tuple_field_type item_tys ->
          let* items_value =
            result_list items (fun index item ->
                expr_json ~reg enum_names value_record_names union_names
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
        when StringSet.mem type_name value_record_names ->
          let* fields_value =
            result_list fields (fun index (name, value) ->
                let field_path = Printf.sprintf "%s.fields[%d]" path index in
                let* value_json =
                  expr_json ~reg enum_names value_record_names union_names
                    enum_constructors (field_path ^ ".value") value
                in
                Ok (obj [ ("name", str name); ("value", value_json) ]))
          in
          let* fields = typed [ ("fields", fields_value) ] in
          Ok (kind "record" fields)
      | _ -> unsupported path "record literal on non-value record")
  | Core.CRecordConstruct rc ->
      if not (StringSet.mem rc.rc_type_name value_record_names) then
        unsupported path "record construction on non-value record"
      else if Option.is_some rc.rc_erased_release_mask then
        unsupported path "record construction with erased fields"
      else
        let* fields_value =
          result_list rc.rc_fields (fun index field ->
              let field_path = Printf.sprintf "%s.fields[%d]" path index in
              match field with
              | Core.RecordRawField (name, value) ->
                  let* value_json =
                    expr_json ~reg enum_names value_record_names union_names
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
  | Core.CList _ -> unsupported path "list literal"
  | Core.CListAlloc _ -> unsupported path "list allocation"
  | Core.CListGet _ -> unsupported path "list get"
  | Core.CStringByteRead _ -> unsupported path "string byte read"
  | Core.CStringByteWrite _ -> unsupported path "string byte write"
  | Core.CStringByteCopy _ -> unsupported path "string byte copy"
  | Core.CStringSetLen _ -> unsupported path "string length update"
  | Core.CListConstruct lc ->
      let* construct =
        list_construct_json ~reg enum_names value_record_names union_names
          enum_constructors (path ^ ".construct") lc
      in
      let* fields = typed [ ("construct", construct) ] in
      Ok (kind "list_construct" fields)
  | Core.CVector _ -> unsupported path "vector literal"
  | Core.CTensorLiteral _ -> unsupported path "tensor literal"
  | Core.CDict _ -> unsupported path "dict literal"
  | Core.CDictConstruct _ -> unsupported path "dict construction"
  | Core.CSetAlloc _ -> unsupported path "set allocation"
  | Core.CRecordUpdate _ -> unsupported path "record update"
  | Core.CLambda _ -> unsupported path "lambda"
  | Core.CClosureCreate _ -> unsupported path "closure creation"
  | Core.CTensorRawRead _ -> unsupported path "tensor raw read"
  | Core.CTensorRawWrite _ -> unsupported path "tensor raw write"
  | Core.CStringInterp _ -> unsupported path "string interpolation"
  | Core.CBorrowLet _ -> unsupported path "borrow let"
  | Core.CTensorRawViewLet _ -> unsupported path "tensor raw view"
  | Core.CResourceScope _ -> unsupported path "resource scope"
  | Core.CResourceCleanupExit _ -> unsupported path "resource cleanup exit"
  | Core.CDebugBlock _ -> unsupported path "debug block"
  | Core.CMatchArms _ -> unsupported path "match arms"
  | Core.CMatch _ -> unsupported path "compiled match"
  | Core.CConcurrent _ -> unsupported path "concurrent block"
  | Core.CConcurrentlyLoop _ -> unsupported path "concurrently loop"
  | Core.CDetach _ -> unsupported path "detach"
  | Core.CSelect _ -> unsupported path "select"
  | Core.CBox _ -> unsupported path "box"
  | Core.CUnbox _ -> unsupported path "unbox"
  | Core.CUnionConstruct uc ->
      let* construct =
        union_construct_json ~reg enum_names value_record_names union_names
          enum_constructors (path ^ ".construct") uc
      in
      let* fields = typed [ ("construct", construct) ] in
      Ok (kind "union_construct" fields)
  | Core.CUnionReuseConstruct _ -> unsupported path "union reuse construction"
  | Core.CListHandoff _ -> unsupported path "list handoff"
  | Core.CBoxTyped _ -> unsupported path "typed box"
  | Core.CUnboxTyped _ -> unsupported path "typed unbox"

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

and boxed_storage_value_json ~reg enum_names value_record_names union_names
    enum_constructors path (value : Core.boxed_storage_value) =
  let* kind_value = box_kind_json (path ^ ".kind") value.bsv_box.box_kind in
  let* value_json =
    expr_json ~reg enum_names value_record_names union_names enum_constructors
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

and boxed_storage_values_json ~reg enum_names value_record_names union_names
    enum_constructors path values =
  result_list values (fun index value ->
      boxed_storage_value_json ~reg enum_names value_record_names union_names
        enum_constructors
        (Printf.sprintf "%s[%d]" path index)
        value)

and list_storage_layout_json (layout : Core.list_storage_layout) =
  match layout.lsl_slots with
  | Core.ListPointerStorage -> Ok (kind "pointer" [])
  | Core.ListInlineStorage width ->
      Ok
        (kind "inline"
           [ ("width_bytes", int (Core.inline_storage_width_bytes width)) ])
  | Core.ListInlineStructStorage c_type ->
      Ok (kind "inline_struct" [ ("c_type", str c_type) ])

and list_construct_json ~reg enum_names value_record_names union_names
    enum_constructors path (lc : Core.list_construct) =
  let* layout = list_storage_layout_json lc.lc_layout in
  let* elements =
    boxed_storage_values_json ~reg enum_names value_record_names union_names
      enum_constructors (path ^ ".elements") lc.lc_elems
  in
  Ok
    (obj
       [
         ("layout", layout);
         ("elements", elements);
         ("elem_needs_release", bool lc.lc_elem_needs_release);
       ])

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
          unsupported path "nullable managed Option constructor"
      | Core_layout_type.OptionConstructorBoxedUnion ->
          unsupported path "boxed Option union constructor"
      | Core_layout_type.OptionConstructorUnavailable reason ->
          unsupported path ("unavailable Option constructor ABI: " ^ reason))
  | Core.GenericUnion -> unsupported path "generic union constructor"
  | Core.ResultUnion _ -> unsupported path "Result union constructor"

and union_construct_json ~reg enum_names value_record_names union_names
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
        expr_json ~reg enum_names value_record_names union_names
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

let require_intrinsic_renderable path name args =
  match
    Compiler_blorp_bridge.renderer_template_arity_opt_exn
      ~renderer:Compiler_blorp_bridge.intrinsic_renderer ~op:name
  with
  | Some arity when List.length args = arity -> Ok ()
  | Some arity ->
      unsupported path
        (Printf.sprintf "intrinsic call %s expected %d arg(s), got %d" name
           arity (List.length args))
  | None -> unsupported path ("unsupported intrinsic call " ^ name)

let require_simple_call_kind path call_kind args =
  match call_kind with
  | Core.CKUser _ -> Ok ()
  | Core.CKForeign _ -> unsupported path "foreign call"
  | Core.CKBuiltin name when direct_builtin_supported name -> Ok ()
  | Core.CKBuiltin name -> unsupported path ("builtin call " ^ name)
  | Core.CKIntrinsic name -> require_intrinsic_renderable path name args
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
      let* () = require_simple_call_kind (path ^ ".call_kind") call_kind args in
      require_simple_args path args
  | Core.CBin (_op, left, right) ->
      let* () = require_simple_expr (path ^ ".left") left in
      require_simple_expr (path ^ ".right") right
  | Core.CUn (_op, inner) -> require_simple_expr (path ^ ".expr") inner
  | Core.CLog (_op, left, right) ->
      let* () = require_simple_expr (path ^ ".left") left in
      require_simple_expr (path ^ ".right") right
  | Core.CCast (inner, _target_ty) -> require_simple_expr (path ^ ".expr") inner
  | Core.CField (inner, _field_name) ->
      require_simple_expr (path ^ ".expr") inner
  | Core.CTuple items -> require_tuple_literal path expr.ty items
  | Core.CTupleConstruct tc -> require_tuple_construct path tc
  | Core.CListConstruct lc -> require_list_construct path lc
  | Core.CRecord fields -> require_record_literal path expr.ty fields
  | Core.CRecordConstruct rc -> require_record_construct path rc
  | Core.CUnionConstruct uc -> require_union_construct path uc
  | Core.CRange (lo, hi) ->
      let* () = require_simple_expr (path ^ ".start") lo in
      require_simple_expr (path ^ ".end") hi
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

and require_tuple_element path (element : Core.boxed_storage_value) =
  if element.bsv_needs_release then unsupported path "managed tuple element"
  else if element.bsv_transfers_ownership then
    unsupported path "owned tuple element transfer"
  else
    let* _ = tuple_element_tag (path ^ ".kind") element.bsv_box.box_kind in
    require_simple_expr (path ^ ".value") element.bsv_box.box_value

and require_tuple_construct path (tc : Core.tuple_construct) =
  if tc.tc_release_mask <> 0 then unsupported path "managed tuple construction"
  else if tc.tc_retain_mask <> 0 then
    unsupported path "tuple construction requiring retain"
  else
    let rec check index = function
      | [] -> Ok ()
      | element :: rest ->
          let* () =
            require_tuple_element
              (Printf.sprintf "%s.elements[%d]" path index)
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
      let allow_element_release_flag = inline_struct_list_unmanaged lc.lc_layout in
      if lc.lc_elem_needs_release then
        unsupported path "managed inline-struct list construction"
      else if not allow_element_release_flag then
        unsupported path "inline-struct list construction without unmanaged storage policy"
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
  | Core.ListPointerStorage -> unsupported path "pointer list construction"
  | Core.ListInlineStorage _ -> unsupported path "inline scalar list construction"

and require_stack_option_arg path (value : Core.boxed_storage_value) =
  if value.bsv_needs_release then unsupported path "managed stack Option payload"
  else if value.bsv_transfers_ownership then
    unsupported path "owned stack Option payload transfer"
  else if is_void_type value.bsv_box.box_value.ty then
    unsupported path "void stack Option payload"
  else require_simple_expr (path ^ ".value") value.bsv_box.box_value

and require_union_construct path (uc : Core.union_construct) =
  match uc.uc_representation with
  | Core.OptionUnion layout -> (
      match Core_layout_type.option_constructor_abi_of_layout layout with
      | Core_layout_type.OptionConstructorStackInline _ ->
          if uc.uc_release_mask <> 0 then
            unsupported path "managed stack Option constructor"
          else
            (
            match uc.uc_args with
            | [] -> Ok ()
            | [ arg ] -> require_stack_option_arg (path ^ ".args[0]") arg
            | _ -> unsupported path "stack Option constructor arity above one")
      | Core_layout_type.OptionConstructorNullableManaged ->
          unsupported path "nullable managed Option constructor"
      | Core_layout_type.OptionConstructorBoxedUnion ->
          unsupported path "boxed Option union constructor"
      | Core_layout_type.OptionConstructorUnavailable reason ->
          unsupported path ("unavailable Option constructor ABI: " ^ reason))
  | Core.GenericUnion -> unsupported path "generic union construction"
  | Core.ResultUnion _ -> unsupported path "Result union construction"

let rec require_function_body ~reg union_names path (expr : Core.core) =
  match expr.desc with
  | Core.CLet (binding, body) ->
      if is_void_type binding.bind_ty then
        let* () =
          require_function_body ~reg union_names (path ^ ".rhs") binding.bind_rhs
        in
        require_function_body ~reg union_names (path ^ ".body") body
      else if String.equal (Core.Var.to_c_name binding.bind_var) "_" then
        let* () =
          require_function_body ~reg union_names (path ^ ".rhs") binding.bind_rhs
        in
        require_function_body ~reg union_names (path ^ ".body") body
      else
        let* () = require_simple_expr (path ^ ".rhs") binding.bind_rhs in
        require_function_body ~reg union_names (path ^ ".body") body
  | Core.CAssign (_variable, rhs) ->
      require_function_body ~reg union_names (path ^ ".rhs") rhs
  | Core.CTailrecLoop
      (Core.TailrecUnmanagedLoop { tul_params = _; tul_return_ty; tul_body }) ->
      require_tailrec_tail ~reg union_names (path ^ ".body") tul_return_ty tul_body
  | Core.CTailrecLoop (Core.TailrecListSpreadLoop _) ->
      unsupported path "list-spread tail-recursive loop"
  | Core.CTailrecRecur _ ->
      unsupported path "tail-recursive recur outside tail-recursive loop"
  | Core.CSeq (first, second) ->
      let* () = require_function_body ~reg union_names (path ^ ".first") first in
      require_function_body ~reg union_names (path ^ ".second") second
  | Core.CIf (cond, then_expr, else_expr) -> (
      match require_simple_expr path expr with
      | Ok () -> Ok ()
      | Error _ ->
          let* () = require_simple_expr (path ^ ".cond") cond in
          let* () =
            require_function_body ~reg union_names (path ^ ".then") then_expr
          in
          require_function_body ~reg union_names (path ^ ".else") else_expr)
  | Core.CWhile (cond, body) ->
      let* () = require_simple_expr (path ^ ".cond") cond in
      require_function_body ~reg union_names (path ^ ".body") body
  | Core.CFor (_binder, { desc = Core.CRange (lo, hi); _ }, body) ->
      let* () = require_simple_expr (path ^ ".start") lo in
      let* () = require_simple_expr (path ^ ".end") hi in
      require_function_body ~reg union_names (path ^ ".body") body
  | Core.CFor _ -> unsupported path "non-range for loop"
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
  | Core.CDup (_variable, value_ty, body) ->
      let _retain_policy = retain_policy_tag ~reg value_ty in
      require_function_body ~reg union_names (path ^ ".body") body
  | Core.CDrop (_variable, value_ty, body) ->
      let _release_policy = release_policy_tag ~reg value_ty in
      require_function_body ~reg union_names (path ^ ".body") body
  | _ -> require_simple_expr path expr

and require_tailrec_tail ~reg union_names path return_ty (expr : Core.core) =
  match expr.desc with
  | Core.CTailrecRecur (Core.TailrecRecur { tr_args }) ->
      require_simple_args path tr_args
  | Core.CTailrecRecur (Core.TailrecListSpreadRecur _) ->
      unsupported path "list-spread tail-recursive recur"
  | Core.CLet (binding, body) ->
      if is_void_type binding.bind_ty then
        let* () =
          require_function_body ~reg union_names (path ^ ".rhs") binding.bind_rhs
        in
        require_tailrec_tail ~reg union_names (path ^ ".body") return_ty body
      else if String.equal (Core.Var.to_c_name binding.bind_var) "_" then
        let* () =
          require_function_body ~reg union_names (path ^ ".rhs") binding.bind_rhs
        in
        require_tailrec_tail ~reg union_names (path ^ ".body") return_ty body
      else
        let* () = require_simple_expr (path ^ ".rhs") binding.bind_rhs in
        require_tailrec_tail ~reg union_names (path ^ ".body") return_ty body
  | Core.CSeq (first, second) ->
      let* () = require_function_body ~reg union_names (path ^ ".first") first in
      require_tailrec_tail ~reg union_names (path ^ ".second") return_ty second
  | Core.CIf (cond, then_expr, else_expr) ->
      let* () = require_simple_expr (path ^ ".cond") cond in
      let* () =
        require_tailrec_tail ~reg union_names (path ^ ".then") return_ty then_expr
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
  | Core.CDup (_variable, value_ty, body) ->
      let _retain_policy = retain_policy_tag ~reg value_ty in
      require_tailrec_tail ~reg union_names (path ^ ".body") return_ty body
  | Core.CDrop (_variable, value_ty, body) ->
      let _release_policy = release_policy_tag ~reg value_ty in
      require_tailrec_tail ~reg union_names (path ^ ".body") return_ty body
  | _ ->
      if is_void_type return_ty then require_function_body ~reg union_names path expr
      else require_simple_expr path expr

and require_literal_match_expr ~reg union_names path scrutinee cases fallback =
  let* () = require_simple_expr (path ^ ".scrutinee") scrutinee in
  let* () = require_literal_match_cases ~reg union_names (path ^ ".cases") cases in
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

and require_constructor_match_expr ~reg union_names path scrutinee cases fallback =
  let* () = require_simple_expr (path ^ ".scrutinee") scrutinee in
  let* () =
    require_constructor_match_cases ~reg union_names (path ^ ".cases") cases
  in
  require_constructor_match_fallback ~reg union_names (path ^ ".fallback") fallback

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

and require_constructor_match_cases ~reg union_names path cases =
  let rec check index = function
    | [] -> Ok ()
    | (_ctor, subtree) :: rest ->
        let case_path = Printf.sprintf "%s[%d]" path index in
        let* body = constructor_match_leaf_body (case_path ^ ".body") subtree in
        let* () =
          require_function_body ~reg union_names (case_path ^ ".body") body
        in
        check (index + 1) rest
  in
  check 0 cases

let function_json ~reg ~enum_names ~value_record_names ~union_names
    ~enum_constructors ~global_def_ids ~global_names path loc
    (func : Core.core_func) =
  let* params =
    result_list func.cf_params (fun index param ->
        param_json enum_names value_record_names union_names
          (Printf.sprintf "%s.params[%d]" path index)
          param)
  in
  let* return_type =
    type_json enum_names value_record_names union_names (path ^ ".return_type")
      func.cf_return_ty
  in
  let* body =
    match func.cf_body with
    | Some body ->
        if expr_uses_global global_def_ids global_names body then
          unsupported (path ^ ".body") "global variable reference"
        else
          let* () = require_function_body ~reg union_names (path ^ ".body") body in
          expr_json ~reg enum_names value_record_names union_names enum_constructors
            (path ^ ".body") body
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

let global_json enum_names value_record_names union_names path loc
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
          type_json enum_names value_record_names union_names (path ^ ".type")
            global.cv_ty
        in
        let* init_typ =
          type_json enum_names value_record_names union_names
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

let union_variant_json enum_names value_record_names union_names type_name path
    (variant : Ast.variant) =
  match variant.variant_fields with
  | [] -> unsupported path "nullary union variant"
  | fields when List.for_all supported_union_field_type fields ->
      let* field_values =
        result_list fields (fun index field_ty ->
            type_json enum_names value_record_names union_names
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

let union_decl_json enum_names value_record_names union_names path loc
    (type_decl : Ast.type_decl) =
  if type_decl.type_params <> [] then
    unsupported path "generic union declaration"
  else
    let* variants =
      result_list type_decl.type_variants (fun index variant ->
          union_variant_json enum_names value_record_names union_names
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

let value_record_field_json enum_names value_record_names union_names path
    (field : Ast.field_decl) =
  let* typ =
    type_json enum_names value_record_names union_names (path ^ ".type")
      field.field_type
  in
  Ok (obj [ ("name", str field.field_name); ("type", typ) ])

let value_record_decl_json enum_names value_record_names union_names path loc
    (record_decl : Ast.record_decl) =
  if record_decl.record_type_params <> [] then
    unsupported path "generic value record declaration"
  else
    let* fields =
      result_list record_decl.record_fields (fun index field ->
          value_record_field_json enum_names value_record_names union_names
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

let impl_method_c_name (impl : Core.core_impl) (method_func : Core.core_func) =
  let type_name =
    match Codegen_types.type_key_for_impl impl.ci_for_type with
    | Some name -> name
    | None -> "Unknown"
  in
  Printf.sprintf "%s_%s_%s" impl.ci_trait method_func.cf_name type_name

let impl_method_jsons ~reg ~enum_names ~value_record_names ~union_names
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
              function_json ~reg ~enum_names ~value_record_names ~union_names
                ~enum_constructors ~global_def_ids ~global_names method_path loc
                method_func
            in
            collect (json :: acc) (index + 1) rest
    in
    collect [] 0 impl.ci_methods

let rec decl_jsons ~reg enum_names value_record_names union_names enum_constructors
    global_def_ids global_names index (decl : Core.core_decl) =
  let path = Printf.sprintf "program.decls[%d]" index in
  match decl.cd_desc with
  | Core.CDFunc func when func.cf_body = None || func.cf_type_params <> [] ->
      Ok []
  | Core.CDFunc func ->
      let* json =
        function_json ~reg ~enum_names ~value_record_names ~union_names
          ~enum_constructors ~global_def_ids ~global_names path decl.cd_loc func
      in
      Ok [ json ]
  | Core.CDType type_decl
    when type_decl.type_is_enum && not type_decl.type_is_builtin ->
      let* json = enum_decl_json path decl.cd_loc type_decl in
      Ok [ json ]
  | Core.CDType type_decl when supported_union_decl type_decl ->
      let* json =
        union_decl_json enum_names value_record_names union_names path
          decl.cd_loc type_decl
      in
      Ok [ json ]
  | Core.CDRecord record_decl
    when record_decl.record_is_value && not record_decl.record_is_builtin ->
      let* json =
        value_record_decl_json enum_names value_record_names union_names path
          decl.cd_loc record_decl
      in
      Ok [ json ]
  | Core.CDImport _ | Core.CDTrait _ | Core.CDType _ | Core.CDTypeAlias _
  | Core.CDRecord _ ->
      Ok []
  | Core.CDPrivate inner ->
      decl_jsons ~reg enum_names value_record_names union_names enum_constructors
        global_def_ids global_names index inner
  | Core.CDVar global when project_global_decl global ->
      let* json =
        global_json enum_names value_record_names union_names path decl.cd_loc
          global
      in
      Ok [ json ]
  | Core.CDVar _ -> Ok []
  | Core.CDImpl impl ->
      impl_method_jsons ~reg ~enum_names ~value_record_names ~union_names
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
          decl_jsons ~reg enum_names value_record_names union_names
            enum_constructors unsupported_global_def_ids unsupported_global_names
            index decl
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
