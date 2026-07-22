(** IR intrinsic body synthesis.

    When a function is declared with [builtin], its body is not written
    in blorp source — instead, the compiler synthesizes a Core IR body from
    this registry. The synthesized body uses [CKIntrinsic] calls for the
    truly primitive operations (struct field reads, raw array access, etc.),
    while all logic (bounds checks, loops, COW decisions) is expressed as
    normal Core IR that flows through mono, perceus, and emit.

    This is what makes [builtin] implementation-agnostic: the IR bodies
    are backend-independent; only the [CKIntrinsic] leaf operations need
    backend-specific emission in [compiler_core_emit.brp]. *)

open Core
module B = Core.Build

(* ================================================================
   Helpers for constructing Core IR nodes
   ================================================================ *)

let ty_int = B.ty_int
let ty_float = Ast.TyNamed ("Float", [])
let ty_float32 = Ast.TyNamed ("Float32", [])
let ty_float16 = Ast.TyNamed ("Float16", [])
let ty_void = B.ty_void
let ty_string = B.ty_string
let ty_ptr = Ast.TyNamed ("Ptr", [])
(* void* — raw pointer for untyped element access *)

let empty_codegen_registry = Codegen_types.create_registry ()
let tensor_reg = function Some reg -> reg | None -> empty_codegen_registry

(** Create a Core node with a type and dummy loc. *)
let mk ty desc : core = B.mk ~loc:Ast.dummy_loc ~ty desc

let starts_with s prefix =
  let slen = String.length s in
  let plen = String.length prefix in
  slen >= plen && String.sub s 0 plen = prefix

let source_func_name ~(module_path : string) (func_name : string) : string =
  if module_path = "" then func_name
  else
    let prefix = Codegen_names.sanitize_module_name module_path ^ "__" in
    if starts_with func_name prefix then
      String.sub func_name (String.length prefix)
        (String.length func_name - String.length prefix)
    else func_name

(** Variable reference. *)
let vr name ty : core = B.var ~loc:Ast.dummy_loc ~ty name

(** Integer literal. *)
let lit_int n : core = B.lit_int ~loc:Ast.dummy_loc n

(** Float literal. *)
let lit_float f : core = mk ty_float (CLit (Ast.LitFloat f))

let lit_float32 f : core = mk ty_float32 (CLit (Ast.LitFloat f))
let lit_float16 f : core = mk ty_float16 (CLit (Ast.LitFloat f))

(** Void literal. *)
let void : core = B.void ~loc:Ast.dummy_loc

let loop name ty : loop_binder = loop_binder_named name ty

let forward_loop name : loop_binder =
  loop_binder_named_forward_range name ty_int

(** Intrinsic call. *)
let intr name args ty : core =
  let dummy = mk ty_void CVoid in
  mk ty (CCall (CKIntrinsic name, dummy, args))

(** First-class function call through the closure ABI. *)
let closure_call fn args ty : core = mk ty (CCall (CKClosure, fn, args))

(** Let binding: [let name = rhs in body]. *)
let lett name rhs body : core =
  mk body.ty
    (CLet
       ( {
           bind_var = Var.named name;
           bind_mut = false;
           bind_ty = rhs.ty;
           bind_rhs = rhs;
         },
         body ))

(** Borrowed alias binding: [borrow name = rhs in body]. This is for
    synthesized read-only aliases where [rhs]'s owner dominates [body]. *)
let borrow name rhs body : core =
  mk body.ty
    (CBorrowLet
       ( { borrow_var = Var.named name; borrow_ty = rhs.ty; borrow_rhs = rhs },
         body ))

(** Mutable let binding: [var name = rhs in body]. *)
let lettm name rhs body : core =
  mk body.ty
    (CLet
       ( {
           bind_var = Var.named name;
           bind_mut = true;
           bind_ty = rhs.ty;
           bind_rhs = rhs;
         },
         body ))

(** Sequence: evaluate [a] for side effect, then [b]. *)
let seq a b : core = mk b.ty (CSeq (a, b))

(** Binary op. *)
let bin op a b ty : core = mk ty (CBin (op, a, b))

(** Get param as a var reference. *)
let param (p : core_param) : core = vr p.cp_name.vname p.cp_ty

exception Malformed_intrinsic_params

type std_body_receiver =
  | NoReceiver
  | AnyReceiver
  | FirstParamNamed of string
  | FirstParamTensor

type std_body_return =
  | AnyReturn
  | ReturnNamed of string
  | ReturnOptionOfNamed of string
  | ReturnTensor

(** Parameter shapes are deliberately shallow unless the constructor says
    otherwise. [ParamNamed "List"] checks only the nominal type head, while the
    relation shapes check container element/key/value equality against the
    first parameter. *)
type std_body_param_shape =
  | AnyParam
  | ParamNamed of string
  | ParamOneOfNamed of string list
  | ParamFunc
  | ParamTensor
  | ParamSameAsFirstListElement
  | ParamListWithSameElementAsFirst
  | ParamSameAsFirstSetElement
  | ParamSetWithSameElementAsFirst
  | ParamSameAsFirstDictKey
  | ParamSameAsFirstDictValue

type std_body_synthesis =
  | BuiltinWrapper of string
  | BuiltinWrapperWithTrailingInt of { c_name : string; value : int }
  | TensorLength

type std_body_spec = {
  spec_module_path : string;
  spec_func_name : string;
  spec_arity : int;
  spec_receiver : std_body_receiver;
  spec_return : std_body_return;
  spec_param_shapes : std_body_param_shape list option;
  spec_synthesis : std_body_synthesis option;
}

type std_body_checked_params = { checked_params : core_param array }

(** During the migration, not every legacy synthesis arm has a spec entry.
    [LegacyUncheckedParams] means no table entry exists for the module/name yet,
    so old branch guards still own that signature. [SpecCheckedParams] means the
    table accepted module path, function name, arity, receiver, return, and any
    declared parameter-shape constraints before synthesis runs; it carries the
    accepting spec so entries can own synthesis directly. *)
type std_body_signature_check =
  | LegacyUncheckedParams of std_body_checked_params
  | SpecCheckedParams of std_body_spec * std_body_checked_params

let std_body_spec ?(return_shape = AnyReturn) ?param_shapes ?synthesis
    module_path func_name arity receiver =
  {
    spec_module_path = module_path;
    spec_func_name = func_name;
    spec_arity = arity;
    spec_receiver = receiver;
    spec_return = return_shape;
    spec_param_shapes = param_shapes;
    spec_synthesis = synthesis;
  }

let make_std_body_checked_params params =
  { checked_params = Array.of_list params }

let std_body_checked_param checked index =
  if index < 0 || index >= Array.length checked.checked_params then
    raise Malformed_intrinsic_params
  else checked.checked_params.(index)

let type_is_named name = function
  | Ast.TyNamed (got, _) -> got = name
  | _ -> false

let type_is_option_of_named name = function
  | Ast.TyNamed ("Option", [ inner ]) -> type_is_named name inner
  | _ -> false

let list_element_type = function
  | Ast.TyNamed ("List", [ elem_ty ]) -> Some elem_ty
  | _ -> None

let set_element_type = function
  | Ast.TyNamed ("Set", [ elem_ty ]) -> Some elem_ty
  | _ -> None

let dict_key_value_types = function
  | Ast.TyNamed ("Dict", [ key_ty; value_ty ]) -> Some (key_ty, value_ty)
  | _ -> None

let first_param_type params =
  match params with first :: _ -> Some first.cp_ty | [] -> None

let type_matches_expected expected actual = Types.types_equal expected actual

let param_same_as_first_list_element params param =
  match Option.bind (first_param_type params) list_element_type with
  | Some elem_ty -> type_matches_expected elem_ty param.cp_ty
  | None -> false

let param_list_with_same_element_as_first params param =
  match
    ( Option.bind (first_param_type params) list_element_type,
      list_element_type param.cp_ty )
  with
  | Some first_elem_ty, Some param_elem_ty ->
      type_matches_expected first_elem_ty param_elem_ty
  | _ -> false

let param_same_as_first_set_element params param =
  match Option.bind (first_param_type params) set_element_type with
  | Some elem_ty -> type_matches_expected elem_ty param.cp_ty
  | None -> false

let param_set_with_same_element_as_first params param =
  match
    ( Option.bind (first_param_type params) set_element_type,
      set_element_type param.cp_ty )
  with
  | Some first_elem_ty, Some param_elem_ty ->
      type_matches_expected first_elem_ty param_elem_ty
  | _ -> false

let param_same_as_first_dict_key params param =
  match Option.bind (first_param_type params) dict_key_value_types with
  | Some (key_ty, _) -> type_matches_expected key_ty param.cp_ty
  | None -> false

let param_same_as_first_dict_value params param =
  match Option.bind (first_param_type params) dict_key_value_types with
  | Some (_, value_ty) -> type_matches_expected value_ty param.cp_ty
  | None -> false

let std_body_spec_arity_matches spec params =
  List.length params = spec.spec_arity

let std_body_spec_receiver_matches ~is_tensor_type spec params =
  match (spec.spec_receiver, params) with
  | NoReceiver, [] -> true
  | NoReceiver, _ :: _ -> false
  | AnyReceiver, _ -> true
  | FirstParamNamed name, first :: _ -> type_is_named name first.cp_ty
  | FirstParamNamed _, [] -> false
  | FirstParamTensor, first :: _ -> is_tensor_type first.cp_ty
  | FirstParamTensor, [] -> false

let std_body_spec_return_matches ~is_tensor_type spec return_ty =
  match spec.spec_return with
  | AnyReturn -> true
  | ReturnNamed name -> type_is_named name return_ty
  | ReturnOptionOfNamed name -> type_is_option_of_named name return_ty
  | ReturnTensor -> is_tensor_type return_ty

let std_body_param_shape_matches ~is_tensor_type ~params shape param =
  match shape with
  | AnyParam -> true
  | ParamNamed name -> type_is_named name param.cp_ty
  | ParamOneOfNamed names ->
      List.exists (fun name -> type_is_named name param.cp_ty) names
  | ParamFunc -> ( match param.cp_ty with Ast.TyFunc _ -> true | _ -> false)
  | ParamTensor -> is_tensor_type param.cp_ty
  | ParamSameAsFirstListElement -> param_same_as_first_list_element params param
  | ParamListWithSameElementAsFirst ->
      param_list_with_same_element_as_first params param
  | ParamSameAsFirstSetElement -> param_same_as_first_set_element params param
  | ParamSetWithSameElementAsFirst ->
      param_set_with_same_element_as_first params param
  | ParamSameAsFirstDictKey -> param_same_as_first_dict_key params param
  | ParamSameAsFirstDictValue -> param_same_as_first_dict_value params param

let std_body_spec_params_match ~is_tensor_type spec params =
  match spec.spec_param_shapes with
  | None -> true
  | Some shapes ->
      List.length shapes = List.length params
      && List.for_all2
           (fun shape param ->
             std_body_param_shape_matches ~is_tensor_type ~params shape param)
           shapes params

let std_body_spec_matches ~is_tensor_type spec params return_ty =
  std_body_spec_arity_matches spec params
  && std_body_spec_receiver_matches ~is_tensor_type spec params
  && std_body_spec_return_matches ~is_tensor_type spec return_ty
  && std_body_spec_params_match ~is_tensor_type spec params

let std_body_specs =
  let spec = std_body_spec in
  let list_spec ?return_shape ?param_shapes func_name arity =
    spec ?return_shape ?param_shapes "std/list" func_name arity
      (FirstParamNamed "List")
  in
  let string_spec ?return_shape ?param_shapes func_name arity =
    spec ?return_shape ?param_shapes "std/string" func_name arity
      (FirstParamNamed "String")
  in
  let bytes_spec ?return_shape ?param_shapes func_name arity =
    spec ?return_shape ?param_shapes "std/bytes" func_name arity
      (FirstParamNamed "Bytes")
  in
  let set_spec ?return_shape ?param_shapes func_name arity =
    spec ?return_shape ?param_shapes "std/set" func_name arity
      (FirstParamNamed "Set")
  in
  let dict_spec ?return_shape ?param_shapes func_name arity =
    spec ?return_shape ?param_shapes "std/dict" func_name arity
      (FirstParamNamed "Dict")
  in
  let bytes_builtin_spec ?return_shape ?param_shapes ~c_name func_name arity
      receiver =
    spec ?return_shape ?param_shapes ~synthesis:(BuiltinWrapper c_name)
      "std/bytes" func_name arity receiver
  in
  let fixed_builtin_spec ?return_shape ?param_shapes ~c_name func_name arity
      receiver =
    spec ?return_shape ?param_shapes ~synthesis:(BuiltinWrapper c_name)
      "std/fixed" func_name arity receiver
  in
  let fixed_default_precision_spec ?return_shape ?param_shapes ~c_name func_name
      arity receiver =
    spec ?return_shape ?param_shapes
      ~synthesis:(BuiltinWrapperWithTrailingInt { c_name; value = 18 })
      "std/fixed" func_name arity receiver
  in
  let time_spec ?return_shape ?param_shapes ~c_name func_name arity receiver =
    spec ?return_shape ?param_shapes ~synthesis:(BuiltinWrapper c_name)
      "std/time" func_name arity receiver
  in
  let stream_spec ?return_shape ?param_shapes ~c_name func_name arity receiver =
    spec ?return_shape ?param_shapes ~synthesis:(BuiltinWrapper c_name)
      "std/stream" func_name arity receiver
  in
  let tensor_builtin_spec ?return_shape ?param_shapes ~c_name func_name arity
      receiver =
    spec ?return_shape ?param_shapes ~synthesis:(BuiltinWrapper c_name)
      "std/tensor" func_name arity receiver
  in
  let matrix_builtin_spec ?return_shape ?param_shapes ~c_name func_name arity
      receiver =
    spec ?return_shape ?param_shapes ~synthesis:(BuiltinWrapper c_name)
      "std/matrix" func_name arity receiver
  in
  let hash_spec ?return_shape ?param_shapes func_name arity receiver =
    spec ?return_shape ?param_shapes
      ~synthesis:(BuiltinWrapper ("blorp_" ^ func_name))
      "std/hash" func_name arity receiver
  in
  let math_float_type_names = [ "Float"; "Float32"; "Float16" ] in
  let repeated_param_shape shape arity = List.init arity (fun _ -> shape) in
  let math_same_float_specs func_names arity =
    List.concat_map
      (fun func_name ->
        List.map
          (fun float_name ->
            spec ~return_shape:(ReturnNamed float_name)
              ~param_shapes:(repeated_param_shape (ParamNamed float_name) arity)
              "std/math" func_name arity (FirstParamNamed float_name))
          math_float_type_names)
      func_names
  in
  let math_float_class_specs =
    List.concat_map
      (fun func_name ->
        List.map
          (fun float_name ->
            spec ~return_shape:(ReturnNamed "Bool")
              ~param_shapes:[ ParamNamed float_name ] "std/math" func_name 1
              (FirstParamNamed float_name))
          math_float_type_names)
      [ "is_nan"; "is_inf"; "is_finite" ]
  in
  let math_constant_specs =
    [
      spec ~return_shape:(ReturnNamed "Float") "std/math" "infinity" 0
        NoReceiver;
      spec ~return_shape:(ReturnNamed "Float") "std/math" "neg_infinity" 0
        NoReceiver;
      spec ~return_shape:(ReturnNamed "Float") "std/math" "nan_value" 0
        NoReceiver;
    ]
  in
  let math_unary_specs =
    math_same_float_specs
      [
        "sin";
        "cos";
        "tan";
        "asin";
        "acos";
        "atan";
        "sinh";
        "cosh";
        "tanh";
        "asinh";
        "acosh";
        "atanh";
        "exp";
        "exp2";
        "expm1";
        "log";
        "log2";
        "log10";
        "log1p";
        "sqrt";
        "cbrt";
        "floor";
        "ceil";
        "round";
        "trunc";
      ]
      1
  in
  let math_binary_specs =
    math_same_float_specs [ "pow"; "atan2"; "hypot"; "fmod"; "copysign" ] 2
  in
  let math_ternary_specs = math_same_float_specs [ "fma" ] 3 in
  let list_specs =
    [
      list_spec ~return_shape:(ReturnNamed "List")
        ~param_shapes:[ ParamNamed "List"; ParamFunc ]
        "parallel" 2;
      list_spec ~return_shape:(ReturnNamed "Int")
        ~param_shapes:[ ParamNamed "List" ] "length" 1;
      list_spec ~return_shape:(ReturnNamed "List")
        ~param_shapes:[ ParamNamed "List"; ParamSameAsFirstListElement ]
        "append" 2;
      list_spec ~return_shape:(ReturnNamed "List")
        ~param_shapes:[ ParamNamed "List"; ParamSameAsFirstListElement ]
        "__unsafe_list_append" 2;
      list_spec ~return_shape:(ReturnNamed "Option")
        ~param_shapes:[ ParamNamed "List"; ParamNamed "Int" ]
        "get" 2;
      list_spec ~return_shape:(ReturnNamed "List")
        ~param_shapes:
          [ ParamNamed "List"; ParamNamed "Int"; ParamSameAsFirstListElement ]
        "__unsafe_list_set_index" 3;
      list_spec
        ~param_shapes:
          [ ParamNamed "List"; ParamNamed "Int"; ParamSameAsFirstListElement ]
        "get_or" 3;
      list_spec ~return_shape:(ReturnNamed "List")
        ~param_shapes:
          [ ParamNamed "List"; ParamNamed "Int"; ParamSameAsFirstListElement ]
        "set" 3;
      list_spec ~return_shape:(ReturnNamed "List")
        ~param_shapes:[ ParamNamed "List"; ParamNamed "Int"; ParamNamed "Int" ]
        "__unsafe_list_swap" 3;
      list_spec ~return_shape:(ReturnNamed "List")
        ~param_shapes:[ ParamNamed "List"; ParamNamed "Int" ]
        "__unsafe_list_remove" 2;
      list_spec ~return_shape:(ReturnNamed "List")
        ~param_shapes:
          [ ParamNamed "List"; ParamNamed "Int"; ParamSameAsFirstListElement ]
        "__unsafe_list_insert" 3;
      list_spec ~return_shape:(ReturnNamed "List")
        ~param_shapes:[ ParamNamed "List" ] "__unsafe_list_tail" 1;
      list_spec ~return_shape:(ReturnNamed "List")
        ~param_shapes:[ ParamNamed "List" ] "reverse" 1;
      list_spec ~return_shape:(ReturnNamed "List")
        ~param_shapes:[ ParamNamed "List" ] "__unsafe_list_reverse" 1;
      list_spec ~return_shape:(ReturnNamed "List")
        ~param_shapes:[ ParamNamed "List"; ParamListWithSameElementAsFirst ]
        "concat" 2;
      list_spec ~return_shape:(ReturnNamed "List")
        ~param_shapes:[ ParamNamed "List"; ParamNamed "Int" ]
        "take" 2;
      list_spec ~return_shape:(ReturnNamed "List")
        ~param_shapes:[ ParamNamed "List"; ParamNamed "Int" ]
        "drop" 2;
      list_spec ~return_shape:(ReturnNamed "List")
        ~param_shapes:[ ParamNamed "List" ] "flatten" 1;
      list_spec ~return_shape:(ReturnNamed "List")
        ~param_shapes:[ ParamNamed "List"; ParamFunc ]
        "map" 2;
      list_spec ~return_shape:(ReturnNamed "List")
        ~param_shapes:[ ParamNamed "List"; ParamNamed "Int"; ParamFunc ]
        "concurrent" 3;
      list_spec ~return_shape:(ReturnNamed "List")
        ~param_shapes:
          [ ParamNamed "List"; ParamNamed "Int"; ParamNamed "Int"; ParamFunc ]
        "__concurrent_timeout_ms" 4;
      list_spec ~return_shape:(ReturnNamed "List")
        ~param_shapes:[ ParamNamed "List"; ParamFunc ]
        "map_indexed" 2;
      list_spec ~return_shape:(ReturnNamed "List")
        ~param_shapes:[ ParamNamed "List"; ParamFunc ]
        "filter" 2;
      list_spec ~return_shape:(ReturnNamed "List")
        ~param_shapes:[ ParamNamed "List"; ParamFunc ]
        "take_while" 2;
      list_spec ~return_shape:(ReturnNamed "List")
        ~param_shapes:[ ParamNamed "List"; ParamFunc ]
        "drop_while" 2;
      list_spec ~param_shapes:[ ParamNamed "List"; ParamFunc ] "partition" 2;
      list_spec ~return_shape:(ReturnNamed "List")
        ~param_shapes:[ ParamNamed "List"; ParamFunc ]
        "flat_map" 2;
      list_spec ~return_shape:(ReturnNamed "List")
        ~param_shapes:[ ParamNamed "List"; ParamFunc ]
        "filter_map" 2;
      list_spec
        ~param_shapes:[ ParamNamed "List"; AnyParam; ParamFunc ]
        "fold_left" 3;
      list_spec
        ~param_shapes:[ ParamNamed "List"; AnyParam; ParamFunc ]
        "fold_right" 3;
      list_spec ~return_shape:(ReturnNamed "Bool")
        ~param_shapes:[ ParamNamed "List"; ParamFunc ]
        "all" 2;
      list_spec ~return_shape:(ReturnNamed "Bool")
        ~param_shapes:[ ParamNamed "List"; ParamFunc ]
        "any" 2;
      list_spec ~return_shape:(ReturnNamed "Int")
        ~param_shapes:[ ParamNamed "List"; ParamFunc ]
        "count" 2;
      list_spec ~return_shape:(ReturnNamed "Void")
        ~param_shapes:[ ParamNamed "List"; ParamFunc ]
        "for_each" 2;
      list_spec ~return_shape:(ReturnNamed "Option")
        ~param_shapes:[ ParamNamed "List"; ParamFunc ]
        "find_index" 2;
      list_spec ~return_shape:(ReturnNamed "Option")
        ~param_shapes:[ ParamNamed "List"; ParamFunc ]
        "find" 2;
      list_spec ~return_shape:(ReturnNamed "Option")
        ~param_shapes:[ ParamNamed "List"; ParamSameAsFirstListElement ]
        "binary_search" 2;
      list_spec ~return_shape:(ReturnNamed "Option")
        ~param_shapes:
          [ ParamNamed "List"; ParamSameAsFirstListElement; ParamFunc ]
        "binary_search_by" 3;
      list_spec ~return_shape:(ReturnNamed "Option")
        ~param_shapes:[ ParamNamed "List"; ParamFunc ]
        "min_by" 2;
      list_spec ~return_shape:(ReturnNamed "Option")
        ~param_shapes:[ ParamNamed "List"; ParamFunc ]
        "max_by" 2;
      list_spec ~return_shape:(ReturnNamed "List")
        ~param_shapes:[ ParamNamed "List" ] "sort" 1;
      list_spec ~return_shape:(ReturnNamed "List")
        ~param_shapes:[ ParamNamed "List"; ParamFunc ]
        "sort_by" 2;
      list_spec ~return_shape:(ReturnNamed "List")
        ~param_shapes:[ ParamNamed "List"; ParamFunc ]
        "sort_desc_by" 2;
      list_spec ~return_shape:(ReturnNamed "List")
        ~param_shapes:[ ParamNamed "List"; AnyParam; ParamFunc ]
        "scan" 3;
      list_spec ~return_shape:(ReturnNamed "List")
        ~param_shapes:[ ParamNamed "List" ] "enumerate" 1;
      list_spec ~return_shape:(ReturnNamed "List")
        ~param_shapes:[ ParamNamed "List"; ParamNamed "List" ]
        "zip" 2;
      list_spec ~return_shape:(ReturnNamed "List")
        ~param_shapes:[ ParamNamed "List"; ParamNamed "List"; ParamFunc ]
        "zip_with" 3;
      list_spec ~param_shapes:[ ParamNamed "List" ] "unzip" 1;
      spec ~return_shape:(ReturnNamed "List") "std/list" "repeat" 2
        ~param_shapes:[ AnyParam; ParamNamed "Int" ]
        AnyReceiver;
      list_spec ~return_shape:(ReturnNamed "List")
        ~param_shapes:[ ParamNamed "List"; ParamSameAsFirstListElement ]
        "intersperse" 2;
      list_spec ~return_shape:(ReturnNamed "List")
        ~param_shapes:[ ParamNamed "List"; ParamNamed "Int" ]
        "windows" 2;
      list_spec ~return_shape:(ReturnNamed "List")
        ~param_shapes:[ ParamNamed "List"; ParamNamed "Int" ]
        "chunks" 2;
      spec ~return_shape:(ReturnNamed "List") "std/list" "range" 2
        ~param_shapes:[ ParamNamed "Int"; ParamNamed "Int" ]
        (FirstParamNamed "Int");
      list_spec ~return_shape:(ReturnNamed "List")
        ~param_shapes:[ ParamNamed "List" ] "unique" 1;
      spec ~return_shape:(ReturnNamed "String") "std/list" "string_append" 2
        ~param_shapes:[ ParamNamed "String"; ParamNamed "String" ]
        (FirstParamNamed "String");
    ]
  in
  let string_specs =
    [
      spec ~return_shape:(ReturnNamed "String") "std/string" "string" 1
        ~param_shapes:[ ParamNamed "Int" ] (FirstParamNamed "Int");
      spec ~return_shape:(ReturnNamed "String") "std/string"
        "string_with_capacity" 1 ~param_shapes:[ ParamNamed "Int" ]
        (FirstParamNamed "Int");
      string_spec ~return_shape:(ReturnNamed "String")
        ~param_shapes:[ ParamNamed "String"; ParamNamed "Int" ]
        "reserve" 2;
      string_spec ~return_shape:(ReturnNamed "String")
        ~param_shapes:[ ParamNamed "String"; ParamNamed "Char" ]
        "append_char" 2;
      string_spec ~return_shape:(ReturnNamed "String")
        ~param_shapes:[ ParamNamed "String"; ParamNamed "Char" ]
        "string_append_char" 2;
      string_spec ~return_shape:(ReturnNamed "Int")
        ~param_shapes:[ ParamNamed "String" ] "length" 1;
      string_spec ~return_shape:(ReturnNamed "String")
        ~param_shapes:
          [ ParamNamed "String"; ParamNamed "Int"; ParamNamed "Int" ]
        "substring" 3;
      string_spec ~return_shape:(ReturnNamed "Bool")
        ~param_shapes:[ ParamNamed "String"; ParamNamed "String" ]
        "starts_with" 2;
      string_spec ~return_shape:(ReturnNamed "Bool")
        ~param_shapes:[ ParamNamed "String"; ParamNamed "String" ]
        "ends_with" 2;
      string_spec ~return_shape:(ReturnNamed "Bool")
        ~param_shapes:[ ParamNamed "String"; ParamNamed "String" ]
        "contains" 2;
      string_spec ~return_shape:(ReturnNamed "Int")
        ~param_shapes:[ ParamNamed "String"; ParamNamed "String" ]
        "raw_index_of" 2;
      string_spec ~return_shape:(ReturnNamed "Int")
        ~param_shapes:[ ParamNamed "String"; ParamNamed "String" ]
        "count" 2;
      string_spec ~return_shape:(ReturnNamed "List")
        ~param_shapes:[ ParamNamed "String"; ParamNamed "String" ]
        "split" 2;
      string_spec ~return_shape:(ReturnNamed "String")
        ~param_shapes:[ ParamNamed "String" ] "trim" 1;
      string_spec ~return_shape:(ReturnNamed "String")
        ~param_shapes:
          [ ParamNamed "String"; ParamNamed "String"; ParamNamed "String" ]
        "replace" 3;
      string_spec ~return_shape:(ReturnNamed "String")
        ~param_shapes:[ ParamNamed "String" ] "capitalize" 1;
      string_spec ~return_shape:(ReturnNamed "String")
        ~param_shapes:[ ParamNamed "String" ] "title_case" 1;
      string_spec ~return_shape:(ReturnNamed "String")
        ~param_shapes:[ ParamNamed "String"; ParamNamed "Int" ]
        "repeat" 2;
      string_spec ~return_shape:(ReturnNamed "String")
        ~param_shapes:[ ParamNamed "String"; ParamNamed "Int" ]
        "drop_left" 2;
      string_spec ~return_shape:(ReturnNamed "String")
        ~param_shapes:[ ParamNamed "String"; ParamNamed "Int" ]
        "take_left" 2;
      string_spec ~return_shape:(ReturnNamed "String")
        ~param_shapes:[ ParamNamed "String"; ParamNamed "Int" ]
        "take_right" 2;
      string_spec ~return_shape:(ReturnNamed "String")
        ~param_shapes:[ ParamNamed "String"; ParamNamed "Int" ]
        "drop_right" 2;
      string_spec ~return_shape:(ReturnNamed "String")
        ~param_shapes:[ ParamNamed "String" ] "trim_left" 1;
      string_spec ~return_shape:(ReturnNamed "String")
        ~param_shapes:[ ParamNamed "String" ] "trim_right" 1;
      string_spec ~return_shape:(ReturnNamed "String")
        ~param_shapes:[ ParamNamed "String" ] "reverse" 1;
      string_spec ~return_shape:(ReturnNamed "String")
        ~param_shapes:
          [ ParamNamed "String"; ParamNamed "Int"; ParamNamed "Char" ]
        "pad_left" 3;
      string_spec ~return_shape:(ReturnNamed "String")
        ~param_shapes:
          [ ParamNamed "String"; ParamNamed "Int"; ParamNamed "Char" ]
        "pad_right" 3;
      string_spec ~return_shape:(ReturnNamed "String")
        ~param_shapes:
          [ ParamNamed "String"; ParamNamed "Int"; ParamNamed "Char" ]
        "center" 3;
      string_spec ~return_shape:(ReturnNamed "Int")
        ~param_shapes:[ ParamNamed "String"; ParamNamed "String" ]
        "raw_last_index_of" 2;
      string_spec ~return_shape:(ReturnNamed "String")
        ~param_shapes:[ ParamNamed "String"; ParamNamed "String" ]
        "trim_chars" 2;
      string_spec ~return_shape:(ReturnNamed "Bool")
        ~param_shapes:[ ParamNamed "String" ] "is_numeric" 1;
      string_spec ~return_shape:(ReturnNamed "Bool")
        ~param_shapes:[ ParamNamed "String" ] "is_ascii" 1;
      string_spec ~return_shape:(ReturnNamed "Bool")
        ~param_shapes:[ ParamNamed "String" ] "is_blank" 1;
      string_spec ~return_shape:(ReturnNamed "Bool")
        ~param_shapes:[ ParamNamed "String" ] "is_lower" 1;
      string_spec ~return_shape:(ReturnNamed "Bool")
        ~param_shapes:[ ParamNamed "String" ] "is_upper" 1;
      string_spec ~return_shape:(ReturnNamed "String")
        ~param_shapes:[ ParamNamed "String"; ParamNamed "String" ]
        "longest_common_prefix" 2;
      string_spec ~return_shape:(ReturnNamed "Int")
        ~param_shapes:[ ParamNamed "String"; ParamNamed "String" ]
        "hamming_distance_raw" 2;
    ]
  in
  let bytes_specs =
    [
      spec ~return_shape:(ReturnNamed "Bytes")
        ~param_shapes:[ ParamNamed "Int" ] "std/bytes" "bytes" 1
        (FirstParamNamed "Int");
      bytes_spec ~return_shape:(ReturnNamed "Int")
        ~param_shapes:[ ParamNamed "Bytes" ] "length" 1;
      bytes_spec ~return_shape:(ReturnOptionOfNamed "Int")
        ~param_shapes:[ ParamNamed "Bytes"; ParamNamed "Int" ]
        "get" 2;
      bytes_spec ~return_shape:(ReturnNamed "Bytes")
        ~param_shapes:[ ParamNamed "Bytes"; ParamNamed "Int"; ParamNamed "Int" ]
        "set_index" 3;
      bytes_spec ~return_shape:(ReturnNamed "Bytes")
        ~param_shapes:[ ParamNamed "Bytes"; ParamNamed "Int"; ParamNamed "Int" ]
        "slice" 3;
      bytes_spec ~return_shape:(ReturnNamed "Bytes")
        ~param_shapes:[ ParamNamed "Bytes"; ParamNamed "Bytes" ]
        "append" 2;
      bytes_spec ~return_shape:(ReturnNamed "Bytes")
        ~param_shapes:[ ParamNamed "Bytes"; ParamNamed "Int" ]
        "fill" 2;
      bytes_spec ~return_shape:(ReturnOptionOfNamed "Int")
        ~param_shapes:[ ParamNamed "Bytes"; ParamNamed "Int"; ParamNamed "Int" ]
        "index_of" 3;
      bytes_spec ~return_shape:(ReturnNamed "Bytes")
        ~param_shapes:
          [
            ParamNamed "Bytes";
            ParamNamed "Int";
            ParamNamed "Bytes";
            ParamNamed "Int";
            ParamNamed "Int";
          ]
        "blit" 5;
      bytes_builtin_spec ~return_shape:(ReturnNamed "String")
        ~c_name:"blorp_bytes_to_string" ~param_shapes:[ ParamNamed "Bytes" ]
        "to_string" 1 (FirstParamNamed "Bytes");
      bytes_builtin_spec ~return_shape:(ReturnOptionOfNamed "Bytes")
        ~c_name:"blorp_bytes_from_hex" ~param_shapes:[ ParamNamed "String" ]
        "from_hex" 1 (FirstParamNamed "String");
      bytes_builtin_spec ~return_shape:(ReturnNamed "Bytes")
        ~c_name:"blorp_encode_utf8" ~param_shapes:[ ParamNamed "List" ]
        "encode_utf8" 1 (FirstParamNamed "List");
      bytes_builtin_spec ~return_shape:(ReturnOptionOfNamed "List")
        ~c_name:"blorp_decode_utf8" ~param_shapes:[ ParamNamed "Bytes" ]
        "decode_utf8" 1 (FirstParamNamed "Bytes");
    ]
  in
  let set_specs =
    [
      set_spec ~return_shape:(ReturnNamed "Int")
        ~param_shapes:[ ParamNamed "Set" ] "length" 1;
      set_spec ~return_shape:(ReturnNamed "Bool")
        ~param_shapes:[ ParamNamed "Set"; ParamSameAsFirstSetElement ]
        "contains" 2;
      set_spec ~return_shape:(ReturnNamed "Set")
        ~param_shapes:[ ParamNamed "Set"; ParamSameAsFirstSetElement ]
        "add" 2;
      set_spec ~return_shape:(ReturnNamed "Bool")
        ~param_shapes:[ ParamNamed "Set"; ParamSetWithSameElementAsFirst ]
        "is_subset" 2;
      set_spec ~return_shape:(ReturnNamed "Set")
        ~param_shapes:[ ParamNamed "Set"; ParamSetWithSameElementAsFirst ]
        "difference" 2;
      set_spec ~return_shape:(ReturnNamed "Set")
        ~param_shapes:[ ParamNamed "Set"; ParamSetWithSameElementAsFirst ]
        "intersect" 2;
      set_spec ~return_shape:(ReturnNamed "Set")
        ~param_shapes:[ ParamNamed "Set"; ParamSetWithSameElementAsFirst ]
        "combine" 2;
      set_spec ~return_shape:(ReturnNamed "Set")
        ~param_shapes:[ ParamNamed "Set"; ParamFunc ]
        "map" 2;
      set_spec ~return_shape:(ReturnNamed "Set")
        ~param_shapes:[ ParamNamed "Set"; ParamFunc ]
        "filter" 2;
      set_spec ~param_shapes:[ ParamNamed "Set"; AnyParam; ParamFunc ] "fold" 3;
      set_spec ~return_shape:(ReturnNamed "List")
        ~param_shapes:[ ParamNamed "Set" ] "to_list" 1;
    ]
  in
  let dict_specs =
    [
      dict_spec ~return_shape:(ReturnNamed "Int")
        ~param_shapes:[ ParamNamed "Dict" ] "length" 1;
      dict_spec ~return_shape:(ReturnNamed "Bool")
        ~param_shapes:[ ParamNamed "Dict"; ParamSameAsFirstDictKey ]
        "contains" 2;
      dict_spec
        ~param_shapes:
          [
            ParamNamed "Dict";
            ParamSameAsFirstDictKey;
            ParamSameAsFirstDictValue;
          ]
        "get_or" 3;
      dict_spec ~return_shape:(ReturnNamed "Dict")
        ~param_shapes:
          [
            ParamNamed "Dict";
            ParamSameAsFirstDictKey;
            ParamSameAsFirstDictValue;
          ]
        "set" 3;
      dict_spec ~return_shape:(ReturnNamed "List")
        ~param_shapes:[ ParamNamed "Dict" ] "keys" 1;
      dict_spec ~return_shape:(ReturnNamed "List")
        ~param_shapes:[ ParamNamed "Dict" ] "values" 1;
      dict_spec ~return_shape:(ReturnNamed "List")
        ~param_shapes:[ ParamNamed "Dict" ] "entries" 1;
    ]
  in
  let fixed_specs =
    [
      fixed_default_precision_spec ~return_shape:(ReturnNamed "Fixed")
        ~c_name:"blorp_fixed_new"
        ~param_shapes:[ ParamNamed "Float"; ParamNamed "Int" ]
        "fixed" 2 (FirstParamNamed "Float");
      fixed_builtin_spec ~return_shape:(ReturnNamed "Fixed")
        ~c_name:"blorp_fixed_new"
        ~param_shapes:[ ParamNamed "Float"; ParamNamed "Int"; ParamNamed "Int" ]
        "with_precision" 3 (FirstParamNamed "Float");
      fixed_default_precision_spec ~return_shape:(ReturnNamed "Fixed")
        ~c_name:"blorp_fixed_from_int"
        ~param_shapes:[ ParamNamed "Int"; ParamNamed "Int" ]
        "from_int" 2 (FirstParamNamed "Int");
      spec ~return_shape:(ReturnNamed "Fixed")
        ~param_shapes:[ ParamNamed "Fixed" ] "std/fixed" "neg" 1
        (FirstParamNamed "Fixed");
      spec ~return_shape:(ReturnNamed "Int")
        ~param_shapes:[ ParamNamed "Fixed" ] "std/fixed" "get_scale" 1
        (FirstParamNamed "Fixed");
      spec ~return_shape:(ReturnNamed "Int")
        ~param_shapes:[ ParamNamed "Fixed" ] "std/fixed" "get_precision" 1
        (FirstParamNamed "Fixed");
      spec ~return_shape:(ReturnNamed "Fixed")
        ~param_shapes:[ ParamNamed "Fixed"; ParamNamed "Int" ]
        "std/fixed" "round_to" 2 (FirstParamNamed "Fixed");
      fixed_builtin_spec ~return_shape:(ReturnNamed "String")
        ~c_name:"blorp_fixed_to_string" ~param_shapes:[ ParamNamed "Fixed" ]
        "to_string" 1 (FirstParamNamed "Fixed");
      spec ~return_shape:(ReturnNamed "Int")
        ~param_shapes:[ ParamNamed "Fixed" ] "std/fixed" "to_int" 1
        (FirstParamNamed "Fixed");
      fixed_builtin_spec ~return_shape:(ReturnNamed "Float")
        ~c_name:"blorp_fixed_to_float" ~param_shapes:[ ParamNamed "Fixed" ]
        "to_float" 1 (FirstParamNamed "Fixed");
    ]
  in
  let slice_specs =
    [
      spec ~return_shape:(ReturnNamed "StringSlice")
        ~param_shapes:[ ParamNamed "String" ] "std/slice" "from_string" 1
        (FirstParamNamed "String");
      spec ~return_shape:(ReturnNamed "Int")
        ~param_shapes:[ ParamNamed "StringSlice" ]
        "std/slice" "length" 1 (FirstParamNamed "StringSlice");
      spec ~return_shape:(ReturnNamed "String")
        ~param_shapes:[ ParamNamed "StringSlice" ]
        "std/slice" "to_string" 1 (FirstParamNamed "StringSlice");
      spec ~return_shape:(ReturnNamed "StringSlice")
        ~param_shapes:
          [ ParamNamed "StringSlice"; ParamNamed "Int"; ParamNamed "Int" ]
        "std/slice" "substring" 3 (FirstParamNamed "StringSlice");
      spec ~return_shape:(ReturnNamed "Bool")
        ~param_shapes:[ ParamNamed "StringSlice"; ParamNamed "String" ]
        "std/slice" "starts_with" 2 (FirstParamNamed "StringSlice");
      spec ~return_shape:(ReturnOptionOfNamed "Char")
        ~param_shapes:[ ParamNamed "StringSlice"; ParamNamed "Int" ]
        "std/slice" "get" 2 (FirstParamNamed "StringSlice");
    ]
  in
  let time_specs =
    let int_part_specs =
      List.map
        (fun func_name ->
          time_spec ~return_shape:(ReturnNamed "Int")
            ~param_shapes:[ ParamNamed "Int" ]
            ~c_name:("blorp_time_" ^ func_name)
            func_name 1 (FirstParamNamed "Int"))
        [
          "to_year";
          "to_month";
          "to_day";
          "to_hour";
          "to_minute";
          "to_second";
          "to_weekday";
        ]
    in
    [
      time_spec ~return_shape:(ReturnNamed "Int") ~c_name:"blorp_time_now" "now"
        0 NoReceiver;
      time_spec ~return_shape:(ReturnNamed "Int")
        ~c_name:"blorp_time_from_parts" "from_parts" 6
        ~param_shapes:
          [
            ParamNamed "Int";
            ParamNamed "Int";
            ParamNamed "Int";
            ParamNamed "Int";
            ParamNamed "Int";
            ParamNamed "Int";
          ]
        (FirstParamNamed "Int");
      time_spec ~return_shape:(ReturnNamed "String") ~c_name:"blorp_time_format"
        "format_time" 2
        ~param_shapes:[ ParamNamed "Int"; ParamNamed "String" ]
        (FirstParamNamed "Int");
      time_spec ~return_shape:(ReturnOptionOfNamed "Int")
        ~c_name:"blorp_time_parse" "parse_time" 2
        ~param_shapes:[ ParamNamed "String"; ParamNamed "String" ]
        (FirstParamNamed "String");
      time_spec ~return_shape:(ReturnOptionOfNamed "Int")
        ~c_name:"blorp_time_from_iso" "from_iso" 1
        ~param_shapes:[ ParamNamed "String" ] (FirstParamNamed "String");
      time_spec ~return_shape:(ReturnOptionOfNamed "Int")
        ~c_name:"blorp_time_parse_rfc3339" "parse_rfc3339_posix" 1
        ~param_shapes:[ ParamNamed "String" ] (FirstParamNamed "String");
    ]
    @ int_part_specs
  in
  let system_specs =
    [
      spec ~return_shape:(ReturnNamed "Int")
        ~synthesis:(BuiltinWrapper "blorp_now_us") "std/system"
        "now_microseconds" 0 NoReceiver;
    ]
  in
  let stream_specs =
    let stream_builtin ?return_shape ?param_shapes func_name arity receiver =
      stream_spec ?return_shape ?param_shapes
        ~c_name:("blorp_stream_" ^ func_name)
        func_name arity receiver
    in
    [
      stream_builtin ~return_shape:(ReturnNamed "Stream") "from_list" 1
        ~param_shapes:[ ParamNamed "List" ] (FirstParamNamed "List");
      stream_builtin ~return_shape:(ReturnNamed "Stream") "from_range" 2
        ~param_shapes:[ ParamNamed "Int"; ParamNamed "Int" ]
        (FirstParamNamed "Int");
      stream_builtin ~return_shape:(ReturnNamed "Stream") "repeat" 1
        ~param_shapes:[ AnyParam ] AnyReceiver;
      stream_builtin ~return_shape:(ReturnNamed "Stream") "unfold" 2
        ~param_shapes:[ AnyParam; ParamFunc ] AnyReceiver;
      stream_builtin ~return_shape:(ReturnNamed "Stream") "empty" 0 NoReceiver;
      stream_builtin ~return_shape:(ReturnNamed "Stream") "map" 2
        ~param_shapes:[ ParamNamed "Stream"; ParamFunc ]
        (FirstParamNamed "Stream");
      stream_builtin ~return_shape:(ReturnNamed "Stream") "filter" 2
        ~param_shapes:[ ParamNamed "Stream"; ParamFunc ]
        (FirstParamNamed "Stream");
      stream_builtin ~return_shape:(ReturnNamed "Stream") "filter_map" 2
        ~param_shapes:[ ParamNamed "Stream"; ParamFunc ]
        (FirstParamNamed "Stream");
      stream_builtin ~return_shape:(ReturnNamed "Stream") "take" 2
        ~param_shapes:[ ParamNamed "Stream"; ParamNamed "Int" ]
        (FirstParamNamed "Stream");
      stream_builtin ~return_shape:(ReturnNamed "Stream") "drop" 2
        ~param_shapes:[ ParamNamed "Stream"; ParamNamed "Int" ]
        (FirstParamNamed "Stream");
      stream_builtin ~return_shape:(ReturnNamed "Stream") "take_while" 2
        ~param_shapes:[ ParamNamed "Stream"; ParamFunc ]
        (FirstParamNamed "Stream");
      stream_builtin ~return_shape:(ReturnNamed "Stream") "enumerate" 1
        ~param_shapes:[ ParamNamed "Stream" ] (FirstParamNamed "Stream");
      stream_builtin ~return_shape:(ReturnNamed "List") "collect" 1
        ~param_shapes:[ ParamNamed "Stream" ] (FirstParamNamed "Stream");
      stream_builtin
        ~param_shapes:[ ParamNamed "Stream"; AnyParam; ParamFunc ]
        "fold" 3 (FirstParamNamed "Stream");
      stream_builtin ~return_shape:(ReturnNamed "Int") "count" 1
        ~param_shapes:[ ParamNamed "Stream" ] (FirstParamNamed "Stream");
      stream_builtin ~return_shape:(ReturnNamed "Void") "for_each" 2
        ~param_shapes:[ ParamNamed "Stream"; ParamFunc ]
        (FirstParamNamed "Stream");
      stream_builtin ~return_shape:(ReturnNamed "Option") "find" 2
        ~param_shapes:[ ParamNamed "Stream"; ParamFunc ]
        (FirstParamNamed "Stream");
      stream_builtin ~return_shape:(ReturnNamed "Bool") "any" 2
        ~param_shapes:[ ParamNamed "Stream"; ParamFunc ]
        (FirstParamNamed "Stream");
      stream_builtin ~return_shape:(ReturnNamed "Bool") "all" 2
        ~param_shapes:[ ParamNamed "Stream"; ParamFunc ]
        (FirstParamNamed "Stream");
    ]
  in
  let tensor_specs =
    [
      tensor_builtin_spec ~return_shape:ReturnTensor
        ~c_name:"blorp_vector_new_fill" ~param_shapes:[ AnyParam; AnyParam ]
        "vector" 2 AnyReceiver;
      tensor_builtin_spec ~return_shape:ReturnTensor
        ~c_name:"blorp_matrix_new_fill"
        ~param_shapes:[ AnyParam; AnyParam; AnyParam ]
        "matrix" 3 AnyReceiver;
      tensor_builtin_spec ~return_shape:ReturnTensor ~c_name:"blorp_tensor3_new"
        ~param_shapes:[ AnyParam; AnyParam; AnyParam; AnyParam ]
        "tensor3" 4 AnyReceiver;
      tensor_builtin_spec ~return_shape:ReturnTensor ~c_name:"blorp_tensor4_new"
        ~param_shapes:[ AnyParam; AnyParam; AnyParam; AnyParam; AnyParam ]
        "tensor4" 5 AnyReceiver;
      tensor_builtin_spec ~return_shape:ReturnTensor ~c_name:"blorp_tensor5_new"
        ~param_shapes:
          [ AnyParam; AnyParam; AnyParam; AnyParam; AnyParam; AnyParam ]
        "tensor5" 6 AnyReceiver;
      tensor_builtin_spec ~c_name:"blorp_checked_get"
        ~param_shapes:[ ParamTensor; AnyParam ] "checked_get" 2 FirstParamTensor;
      tensor_builtin_spec ~return_shape:ReturnTensor ~c_name:"blorp_checked_set"
        "checked_set" 3
        ~param_shapes:[ ParamTensor; AnyParam; AnyParam ]
        FirstParamTensor;
      tensor_builtin_spec ~return_shape:ReturnTensor
        ~c_name:"blorp_checked_slice" "checked_slice" 3
        ~param_shapes:[ ParamTensor; AnyParam; AnyParam ]
        FirstParamTensor;
      tensor_builtin_spec ~c_name:"blorp_matrix_checked_get"
        ~param_shapes:[ ParamTensor; AnyParam; AnyParam ]
        "matrix_checked_get" 3 FirstParamTensor;
      tensor_builtin_spec ~return_shape:ReturnTensor
        ~c_name:"blorp_matrix_checked_set" "matrix_checked_set" 4
        ~param_shapes:[ ParamTensor; AnyParam; AnyParam; AnyParam ]
        FirstParamTensor;
      tensor_builtin_spec ~c_name:"blorp_tensor3_checked_get"
        ~param_shapes:[ ParamTensor; AnyParam; AnyParam; AnyParam ]
        "tensor3_checked_get" 4 FirstParamTensor;
      tensor_builtin_spec ~return_shape:ReturnTensor
        ~c_name:"blorp_tensor3_checked_set" "tensor3_checked_set" 5
        ~param_shapes:[ ParamTensor; AnyParam; AnyParam; AnyParam; AnyParam ]
        FirstParamTensor;
      tensor_builtin_spec ~c_name:"blorp_tensor4_checked_get"
        ~param_shapes:[ ParamTensor; AnyParam; AnyParam; AnyParam; AnyParam ]
        "tensor4_checked_get" 5 FirstParamTensor;
      tensor_builtin_spec ~return_shape:ReturnTensor
        ~c_name:"blorp_tensor4_checked_set" "tensor4_checked_set" 6
        ~param_shapes:
          [ ParamTensor; AnyParam; AnyParam; AnyParam; AnyParam; AnyParam ]
        FirstParamTensor;
      tensor_builtin_spec ~c_name:"blorp_tensor5_checked_get"
        ~param_shapes:
          [ ParamTensor; AnyParam; AnyParam; AnyParam; AnyParam; AnyParam ]
        "tensor5_checked_get" 6 FirstParamTensor;
      tensor_builtin_spec ~return_shape:ReturnTensor
        ~c_name:"blorp_tensor5_checked_set" "tensor5_checked_set" 7
        ~param_shapes:
          [
            ParamTensor;
            AnyParam;
            AnyParam;
            AnyParam;
            AnyParam;
            AnyParam;
            AnyParam;
          ]
        FirstParamTensor;
      tensor_builtin_spec ~c_name:"blorp_tensor_peel"
        ~param_shapes:[ ParamTensor; AnyParam ] "tensor_peel" 2 FirstParamTensor;
      spec ~return_shape:(ReturnNamed "Int") ~synthesis:TensorLength
        "std/tensor" "length" 1 ~param_shapes:[ ParamTensor ] FirstParamTensor;
    ]
  in
  let vector_specs =
    [
      spec ~return_shape:(ReturnNamed "Int") ~synthesis:TensorLength
        "std/vector" "length" 1 ~param_shapes:[ ParamTensor ] FirstParamTensor;
      spec ~param_shapes:[ ParamTensor ] "std/vector" "sum" 1 FirstParamTensor;
      spec ~param_shapes:[ ParamTensor ] "std/vector" "product" 1
        FirstParamTensor;
      spec ~param_shapes:[ ParamTensor ] "std/vector" "max" 1 FirstParamTensor;
      spec ~param_shapes:[ ParamTensor ] "std/vector" "min" 1 FirstParamTensor;
      spec ~return_shape:(ReturnNamed "Float") "std/vector" "mean" 1
        ~param_shapes:[ ParamTensor ] FirstParamTensor;
      spec ~return_shape:ReturnTensor ~param_shapes:[ ParamTensor ] "std/vector"
        "cumulative_sum" 1 FirstParamTensor;
      spec
        ~param_shapes:[ ParamTensor; ParamTensor ]
        "std/vector" "dot" 2 FirstParamTensor;
      spec ~return_shape:ReturnTensor ~param_shapes:[ ParamTensor; AnyParam ]
        "std/vector" "scale" 2 FirstParamTensor;
    ]
  in
  let matrix_specs =
    [
      matrix_builtin_spec ~return_shape:ReturnTensor
        ~c_name:"blorp_tensor_matrix_multiply"
        ~param_shapes:[ ParamTensor; ParamTensor ]
        "multiply" 2 FirstParamTensor;
      matrix_builtin_spec ~return_shape:ReturnTensor
        ~c_name:"blorp_tensor_transpose" "transpose" 1
        ~param_shapes:[ ParamTensor ] FirstParamTensor;
      matrix_builtin_spec ~return_shape:ReturnTensor
        ~c_name:"blorp_tensor_matrix_vector_multiply"
        ~param_shapes:[ ParamTensor; ParamTensor ]
        "multiply_vector" 2 FirstParamTensor;
      matrix_builtin_spec ~return_shape:ReturnTensor
        ~c_name:"blorp_tensor_transposed_matrix_vector_multiply"
        ~param_shapes:[ ParamTensor; ParamTensor ]
        "multiply_transposed_vector" 2 FirstParamTensor;
      matrix_builtin_spec ~return_shape:ReturnTensor
        ~c_name:"blorp_tensor_outer"
        ~param_shapes:[ ParamTensor; ParamTensor ]
        "outer" 2 FirstParamTensor;
    ]
  in
  let hash_specs =
    [
      hash_spec ~return_shape:(ReturnNamed "Int")
        ~param_shapes:[ ParamNamed "String" ] "hash" 1
        (FirstParamNamed "String");
      hash_spec ~return_shape:(ReturnNamed "Int")
        ~param_shapes:[ ParamNamed "Bytes" ] "hash_bytes" 1
        (FirstParamNamed "Bytes");
      hash_spec ~return_shape:(ReturnNamed "String")
        ~param_shapes:[ ParamNamed "String" ] "sha256" 1
        (FirstParamNamed "String");
      hash_spec ~return_shape:(ReturnNamed "String")
        ~param_shapes:[ ParamNamed "String" ] "md5" 1 (FirstParamNamed "String");
      hash_spec ~return_shape:(ReturnNamed "String")
        ~param_shapes:[ ParamNamed "String" ] "sha1" 1
        (FirstParamNamed "String");
      hash_spec ~return_shape:(ReturnNamed "String")
        ~param_shapes:[ ParamNamed "String" ] "sha512" 1
        (FirstParamNamed "String");
      hash_spec ~return_shape:(ReturnNamed "Int")
        ~param_shapes:[ ParamNamed "String" ] "crc32" 1
        (FirstParamNamed "String");
      hash_spec ~return_shape:(ReturnNamed "String")
        ~param_shapes:[ ParamNamed "Bytes" ] "sha256_bytes" 1
        (FirstParamNamed "Bytes");
      hash_spec ~return_shape:(ReturnNamed "String")
        ~param_shapes:[ ParamNamed "Bytes" ] "md5_bytes" 1
        (FirstParamNamed "Bytes");
      hash_spec ~return_shape:(ReturnNamed "String")
        ~param_shapes:[ ParamNamed "Bytes" ] "sha1_bytes" 1
        (FirstParamNamed "Bytes");
      hash_spec ~return_shape:(ReturnNamed "String")
        ~param_shapes:[ ParamNamed "Bytes" ] "sha512_bytes" 1
        (FirstParamNamed "Bytes");
      hash_spec ~return_shape:(ReturnNamed "Int")
        ~param_shapes:[ ParamNamed "Bytes" ] "crc32_bytes" 1
        (FirstParamNamed "Bytes");
      hash_spec ~return_shape:(ReturnNamed "String")
        ~param_shapes:[ ParamNamed "String"; ParamNamed "String" ]
        "hmac_sha256" 2 (FirstParamNamed "String");
    ]
  in
  list_specs @ string_specs @ bytes_specs @ set_specs @ dict_specs @ fixed_specs
  @ slice_specs @ time_specs @ system_specs @ stream_specs @ tensor_specs
  @ vector_specs @ matrix_specs @ hash_specs @ math_constant_specs
  @ math_unary_specs @ math_binary_specs @ math_ternary_specs
  @ math_float_class_specs

let std_body_specs_for ~module_path ~func_name =
  List.filter
    (fun spec ->
      spec.spec_module_path = module_path && spec.spec_func_name = func_name)
    std_body_specs

let std_body_signature_check ~is_tensor_type ~module_path ~func_name ~params
    ~return_ty =
  match std_body_specs_for ~module_path ~func_name with
  | [] -> Some (LegacyUncheckedParams (make_std_body_checked_params params))
  | specs ->
      specs
      |> List.find_opt (fun spec ->
          std_body_spec_matches ~is_tensor_type spec params return_ty)
      |> Option.map (fun _spec ->
          SpecCheckedParams (_spec, make_std_body_checked_params params))

(** Boolean types and literals. *)
let ty_bool = B.ty_bool

let lit_bool b : core = B.lit_bool ~loc:Ast.dummy_loc b

(** Short-circuit logical op. *)
let log op a b : core = mk ty_bool (CLog (op, a, b))

(** Null pointer (used as sentinel for linked-list traversal). *)
let null_ptr : core = mk ty_ptr (CLit (Ast.LitInt 0L))

(** If-then-else expression. *)
let if_ cond then_ else_ ty : core = mk ty (CIf (cond, then_, else_))

(** While loop. *)
let while_ cond body : core = mk ty_void (CWhile (cond, body))

(** Variable assignment (mutation). *)
let assign name rhs : core = mk ty_void (CAssign (Var.named name, rhs))

(** Binary not-equal to null (pointer comparison). *)
let not_null expr : core = bin Ast.Ne expr null_ptr ty_bool

(** Break statement. *)
let break_ : core = mk ty_void CBreak

let list_elem_ty = function Ast.TyNamed ("List", [ t ]) -> t | _ -> ty_ptr

let list_task_result_ok_ty = function
  | Ast.TyNamed
      ( "List",
        [
          Ast.TyNamed ("Result", [ ok_ty; Ast.TyNamed ("ConcurrencyError", []) ]);
        ] ) ->
      ok_ty
  | _ -> ty_ptr

let set_elem_ty ?reg ty =
  match Core_layout_type.set_type ?reg ty with
  | Some set_ty -> set_ty.set_elem_ty
  | None -> ty_ptr

let dict_key_value_tys ?reg ty =
  match Core_layout_type.dict_type ?reg ty with
  | Some dict_ty -> (dict_ty.dict_key_ty, dict_ty.dict_value_ty)
  | None -> (ty_ptr, ty_ptr)

let option_none option_ty = mk option_ty (CVar (Var.named "None"))

let option_some option_ty value =
  mk option_ty (CCall (CKUnknown, vr "Some" ty_void, [ value ]))

(* ================================================================
   Tensor reduction helpers
   ================================================================ *)

(** Functions that benefit from post-monomorphization re-synthesis.
    Only these builtins participate in monomorphization — others
    continue through the core_specialize CKUnknown dispatch. *)
let has_post_mono_synthesis (name : string) : bool =
  match name with
  | "fold" | "fold_left" | "fold_right" | "sort" | "sort_by" | "sort_desc_by" ->
      true
  | "contains" | "add" | "is_subset" | "difference" | "intersect" | "combine"
  | "map" | "filter" | "get_or" | "entries" ->
      true
  | "set" -> true
  | "sum" | "product" | "dot" | "max" | "min" | "mean" | "cumulative_sum"
  | "scale" ->
      true
  | _ -> false

let numeric_tensor_access ?reg (elem : Ast.type_expr) =
  Core_layout_type.tensor_numeric_access_of_type ~reg:(tensor_reg reg) elem

let concrete_tensor_elem ?reg (ty : Ast.type_expr) : Ast.type_expr option =
  match Core_tensor_type.of_type ~reg:(tensor_reg reg) ty with
  | Some tensor_ty when not (Codegen_types.has_type_vars tensor_ty.elem_ty) ->
      Some tensor_ty.elem_ty
  | _ -> None

let is_concrete_tensor ?reg (ty : Ast.type_expr) : bool =
  match concrete_tensor_elem ?reg ty with
  | Some elem -> Option.is_some (numeric_tensor_access ?reg elem)
  | None -> false

let unsupported_concrete_numeric_tensor ?reg (ty : Ast.type_expr) :
    Ast.type_expr option =
  match concrete_tensor_elem ?reg ty with
  | Some elem when Option.is_none (numeric_tensor_access ?reg elem) -> Some elem
  | _ -> None

let unsupported_numeric_tensor_error ?reg func_name p =
  match unsupported_concrete_numeric_tensor ?reg p.cp_ty with
  | Some elem ->
      Core_error.errorf
        ~hint:
          "Supported synthesized vector reduction element types are Int, \
           Float, Float32, and Float16."
        (Core_error.Stage Core_stage.Synth) p.cp_loc
        "%s is not implemented for tensor element type `%s`" func_name
        (Types.type_to_string elem)
  | None -> None

type tensor_elem_info = {
  elem_ty : Ast.type_expr;
  get_intr : string;
  zero_lit : core;
  one_lit : core;
  fast_access : Core_layout_type.tensor_fast_numeric_access option;
}

let tensor_numeric_zero_one_lits
    (access : Core_layout_type.tensor_numeric_access) =
  match access.tna_value_ty with
  | Ast.TyNamed ("Float", []) -> (lit_float 0.0, lit_float 1.0)
  | Ast.TyNamed ("Float32", []) -> (lit_float32 0.0, lit_float32 1.0)
  | Ast.TyNamed ("Float16", []) -> (lit_float16 0.0, lit_float16 1.0)
  | _ -> (lit_int 0, lit_int 1)

(** Get tensor element access facts for a given tensor param type.

    [get_intr] is the conservative runtime-safe read. [fast_access], when
    present, describes the typed raw storage view that is only constructed after
    checking the tensor's explicit runtime storage mode. *)
let tensor_elem_info ?reg (tensor_ty : Ast.type_expr) =
  match Core_tensor_type.of_type ~reg:(tensor_reg reg) tensor_ty with
  | Some tensor_ty -> (
      match numeric_tensor_access ?reg tensor_ty.elem_ty with
      | Some access ->
          let zero_lit, one_lit = tensor_numeric_zero_one_lits access in
          {
            elem_ty = access.tna_value_ty;
            get_intr = access.tna_get_intrinsic;
            zero_lit;
            one_lit;
            fast_access = access.tna_fast_access;
          }
      | _ ->
          {
            elem_ty = ty_int;
            get_intr = "tensor_get_i64";
            zero_lit = lit_int 0;
            one_lit = lit_int 1;
            fast_access = None;
          })
  | _ ->
      {
        elem_ty = ty_int;
        get_intr = "tensor_get_i64";
        zero_lit = lit_int 0;
        one_lit = lit_int 1;
        fast_access = None;
      }

let tensor_raw_view_let view kind source body =
  mk body.ty
    (CTensorRawViewLet
       ({ trv_var = Var.named view; trv_kind = kind; trv_source = source }, body))

let tensor_raw_read view kind index ty =
  mk ty
    (CTensorRawRead
       { trr_view = Var.named view; trr_kind = kind; trr_index = index })

(** Build an accumulator reduction loop:
    let n = tensor_len(v)
    var acc = init
    for i in 0..n:
      acc = acc OP tensor_get(v, i)
    acc *)
let tensor_reduce ?reg ?(read_to_acc = fun value -> value) ~op ~init tensor
    tensor_ty return_ty =
  let info = tensor_elem_info ?reg tensor_ty in
  let tensor_ref = vr "__tensor" tensor.ty in
  let raw_view = "__tensor_raw" in
  let build_loop read_at =
    lettm "__acc" init
      (seq
         (mk ty_void
            (CFor
               ( forward_loop "__i",
                 mk ty_int (CRange (lit_int 0, vr "__n" ty_int)),
                 mk ty_void
                   (CAssign
                      ( Var.named "__acc",
                        bin op (vr "__acc" return_ty)
                          (read_to_acc (read_at (vr "__i" ty_int)))
                          return_ty )) )))
         (vr "__acc" return_ty))
  in
  let safe_loop =
    build_loop (fun index ->
        intr info.get_intr [ tensor_ref; index ] info.elem_ty)
  in
  borrow "__tensor" tensor
    (lett "__n"
       (intr "tensor_len" [ tensor_ref ] ty_int)
       (match info.fast_access with
       | Some fast ->
           if_
             (intr fast.tfna_storage_pred_intr [ tensor_ref ] ty_bool)
             (tensor_raw_view_let raw_view fast.tfna_raw_kind tensor_ref
                (build_loop (fun index ->
                     tensor_raw_read raw_view fast.tfna_raw_kind index
                       info.elem_ty)))
             safe_loop return_ty
       | None -> safe_loop))

let tensor_dot ?reg left right tensor_ty return_ty =
  let info = tensor_elem_info ?reg tensor_ty in
  let left_ref = vr "__tensor_a" left.ty in
  let right_ref = vr "__tensor_b" right.ty in
  let left_raw_view = "__tensor_a_raw" in
  let right_raw_view = "__tensor_b_raw" in
  let build_loop read_left read_right =
    lettm "__acc" info.zero_lit
      (seq
         (mk ty_void
            (CFor
               ( forward_loop "__i",
                 mk ty_int (CRange (lit_int 0, vr "__n" ty_int)),
                 mk ty_void
                   (CAssign
                      ( Var.named "__acc",
                        bin Ast.Add (vr "__acc" return_ty)
                          (bin Ast.Mul
                             (read_left (vr "__i" ty_int))
                             (read_right (vr "__i" ty_int))
                             return_ty)
                          return_ty )) )))
         (vr "__acc" return_ty))
  in
  let safe_loop =
    build_loop
      (fun index -> intr info.get_intr [ left_ref; index ] info.elem_ty)
      (fun index -> intr info.get_intr [ right_ref; index ] info.elem_ty)
  in
  borrow "__tensor_a" left
    (borrow "__tensor_b" right
       (lett "__n"
          (intr "tensor_len" [ left_ref ] ty_int)
          (match info.fast_access with
          | Some fast ->
              if_
                (log Ast.And
                   (intr fast.tfna_storage_pred_intr [ left_ref ] ty_bool)
                   (intr fast.tfna_storage_pred_intr [ right_ref ] ty_bool))
                (tensor_raw_view_let left_raw_view fast.tfna_raw_kind left_ref
                   (tensor_raw_view_let right_raw_view fast.tfna_raw_kind
                      right_ref
                      (build_loop
                         (fun index ->
                           tensor_raw_read left_raw_view fast.tfna_raw_kind
                             index info.elem_ty)
                         (fun index ->
                           tensor_raw_read right_raw_view fast.tfna_raw_kind
                             index info.elem_ty))))
                safe_loop return_ty
          | None -> safe_loop)))

let tensor_set_intrinsic_of_get = function
  | "tensor_get_f64" -> "tensor_set_f64"
  | "tensor_get_f32" -> "tensor_set_f32"
  | "tensor_get_f16" -> "tensor_set_f16"
  | _ -> "tensor_set_i64"

(** Thin IR wrapper: forward all params to a CKBuiltin C function.
    Used for functions that are genuinely C-specific (math, OS, crypto, etc.)
    but need to be callable from IR compositions. *)
let builtin_call c_name args return_ty =
  let dummy = mk ty_void CVoid in
  mk return_ty (CCall (CKBuiltin c_name, dummy, args))

let builtin_wrapper c_name params return_ty =
  let args = List.map param params in
  Some (builtin_call c_name args return_ty)

let synthesize_std_body_from_spec spec params return_ty =
  match spec.spec_synthesis with
  | Some (BuiltinWrapper c_name) -> builtin_wrapper c_name params return_ty
  | Some (BuiltinWrapperWithTrailingInt { c_name; value }) ->
      let args = List.map param params @ [ lit_int value ] in
      Some (builtin_call c_name args return_ty)
  | Some TensorLength -> (
      match params with
      | [ p ] -> Some (intr "tensor_len" [ param p ] return_ty)
      | _ -> None)
  | None -> None

let pointer_argument_as_ptr layout value source_ty =
  match (layout : Core_layout_type.pointer_argument_layout) with
  | Core_layout_type.PointerArgumentIdentity -> value
  | Core_layout_type.PointerArgumentBox -> mk ty_ptr (CBox (value, source_ty))
  | Core_layout_type.PointerArgumentCast -> mk ty_ptr (CCast (value, ty_ptr))

let key_as_ptr ?reg ?as_ty (key : core) : core =
  let key_ty = Option.value as_ty ~default:key.ty in
  Core_layout_type.hash_key_pointer_argument ?reg key_ty |> fun layout ->
  pointer_argument_as_ptr layout key key_ty

let boxed_value_pointer_temp_requires_release ?reg value_ty loc =
  match Core_layout_type.boxed_storage_value_pointer_argument ?reg value_ty with
  | Core_layout_type.PointerArgumentBox -> (
      match
        Core_layout_type.box_kind_of_type
          ~phase:(Core_error.Other "core_intrinsics.boxed_value_pointer_temp")
          ~reg:(tensor_reg reg) value_ty loc
      with
      | Core.BoxInt128 | Core.BoxUInt128 | Core.BoxStruct _ -> true
      | Core.BoxFloat | Core.BoxFloat32 | Core.BoxFloat16 | Core.BoxVoid
      | Core.BoxPointer | Core.BoxPrim ->
          false)
  | Core_layout_type.PointerArgumentIdentity
  | Core_layout_type.PointerArgumentCast ->
      false

let boxed_value_unbox_temp_requires_release ?reg value_ty loc =
  match Core_layout_type.inline_struct_storage ?reg value_ty with
  | Core_layout_type.InlineStruct
      { inline_struct_kind = Core_layout_type.InlineStackOption; _ } ->
      false
  | Core_layout_type.InlineStruct
      { inline_struct_kind = Core_layout_type.InlineValueRecord; _ }
  | Core_layout_type.NotInlineStruct ->
      boxed_value_pointer_temp_requires_release ?reg value_ty loc

let list_collection_strategy func_name =
  match
    Core_ownership.collection_strategy ~module_path:"std/list" ~func_name
  with
  | Some strategy -> strategy
  | None -> invalid_arg ("missing std/list collection strategy for " ^ func_name)

let list_reuse_boundary func_name =
  match (list_collection_strategy func_name).result_collection with
  | Core_ownership.ReuseReceiver { cow_boundary; _ } -> cow_boundary
  | _ ->
      invalid_arg ("std/list." ^ func_name ^ " is not a receiver-reuse strategy")

let list_alloc_intrinsic func_name =
  match (list_collection_strategy func_name).result_collection with
  | Core_ownership.AllocateFresh { alloc; _ } -> alloc
  | _ ->
      invalid_arg
        ("std/list." ^ func_name ^ " is not a fresh-allocation strategy")

let list_growth_boundary func_name =
  match (list_collection_strategy func_name).result_collection with
  | Core_ownership.AllocateFresh { growth = Some name; _ } -> name
  | _ ->
      invalid_arg ("std/list." ^ func_name ^ " has no dynamic-growth boundary")

let set_collection_strategy func_name =
  match
    Core_ownership.collection_strategy ~module_path:"std/set" ~func_name
  with
  | Some strategy -> strategy
  | None -> invalid_arg ("missing std/set collection strategy for " ^ func_name)

let set_alloc_builtin func_name =
  match (set_collection_strategy func_name).result_collection with
  | Core_ownership.AllocateFresh { alloc; _ } -> alloc
  | _ ->
      invalid_arg
        ("std/set." ^ func_name ^ " is not a fresh-allocation strategy")

let set_reuse_boundary func_name =
  match (set_collection_strategy func_name).result_collection with
  | Core_ownership.ReuseReceiver { cow_boundary; _ } -> cow_boundary
  | _ ->
      invalid_arg ("std/set." ^ func_name ^ " is not a receiver-reuse strategy")

let set_reserve_for_len_boundary func_name =
  match (set_collection_strategy func_name).result_collection with
  | Core_ownership.ReuseReceiver { reserve_for_len = Some name; _ }
  | Core_ownership.AllocateFresh { reserve_for_len = Some name; _ } ->
      name
  | _ ->
      invalid_arg ("std/set." ^ func_name ^ " has no reserve-for-len boundary")

let set_list_alloc_intrinsic func_name =
  match (set_collection_strategy func_name).result_collection with
  | Core_ownership.AllocateFresh { alloc; _ } -> alloc
  | _ -> invalid_arg ("std/set." ^ func_name ^ " is not a fresh-list strategy")

let dict_collection_strategy func_name =
  match
    Core_ownership.collection_strategy ~module_path:"std/dict" ~func_name
  with
  | Some strategy -> strategy
  | None -> invalid_arg ("missing std/dict collection strategy for " ^ func_name)

let dict_list_alloc_intrinsic func_name =
  match (dict_collection_strategy func_name).result_collection with
  | Core_ownership.AllocateFresh { alloc; _ } -> alloc
  | _ -> invalid_arg ("std/dict." ^ func_name ^ " is not a fresh-list strategy")

let dict_reuse_boundary func_name =
  match (dict_collection_strategy func_name).result_collection with
  | Core_ownership.ReuseReceiver { cow_boundary; _ } -> cow_boundary
  | _ ->
      invalid_arg ("std/dict." ^ func_name ^ " is not a receiver-reuse strategy")

(* ================================================================
   List IR bodies
   ================================================================ *)

(** __unsafe_list_append(self, elem) -> List[T]

    let n = list_len(self)
    let result = list_ensure_capacity(self, n + 1)
    list_retain_for(result, elem)     -- retain new element for ARC
    list_set(result, n, elem)
    list_set_len(result, n + 1)
    result *)
let list_append self_ty self elem =
  let cow_boundary = list_reuse_boundary "append" in
  lett "__n"
    (intr "list_len" [ self ] ty_int)
    (lett "__result"
       (intr cow_boundary
          [ self; bin Ast.Add (vr "__n" ty_int) (lit_int 1) ty_int ]
          self_ty)
       (seq
          (intr "list_retain_for" [ vr "__result" self_ty; elem ] ty_void)
          (seq
             (intr "list_set"
                [ vr "__result" self_ty; vr "__n" ty_int; elem ]
                ty_void)
             (seq
                (intr "list_set_len"
                   [
                     vr "__result" self_ty;
                     bin Ast.Add (vr "__n" ty_int) (lit_int 1) ty_int;
                   ]
                   ty_void)
                (vr "__result" self_ty)))))

(** __unsafe_list_set_index(self, index, elem) -> List[T]

    let result = list_ensure_unique(self)
    list_release_elem(result, index)  -- release old element
    list_retain_for(result, elem)     -- retain new element
    list_set(result, index, elem)
    result *)
let list_set_index self_ty self index elem =
  let cow_boundary = list_reuse_boundary "__unsafe_list_set_index" in
  lett "__result"
    (intr cow_boundary [ self ] self_ty)
    (seq
       (intr "list_release_elem" [ vr "__result" self_ty; index ] ty_void)
       (seq
          (intr "list_retain_for" [ vr "__result" self_ty; elem ] ty_void)
          (seq
             (intr "list_set" [ vr "__result" self_ty; index; elem ] ty_void)
             (vr "__result" self_ty))))

(** Shared list bounds check: index >= 0 && index < list_len(self). *)
let list_in_bounds self index =
  log Ast.And
    (bin Ast.Ge index (lit_int 0) ty_bool)
    (bin Ast.Lt index (intr "list_len" [ self ] ty_int) ty_bool)

(** get_or(self, index, default) -> T

    Bounds-check directly in IR and return the default for misses. The
    in-bounds element is a borrowed alias from [self], so retain it before
    returning ownership to the caller. *)
let list_get self_ty return_ty self index =
  let elem_ty = list_elem_ty self_ty in
  let elem =
    mk elem_ty
      (CUnbox (intr "list_get_unchecked" [ self; index ] ty_ptr, elem_ty))
  in
  if_
    (list_in_bounds self index)
    (borrow "__elem" elem
       (seq
          (intr "list_retain_for" [ self; vr "__elem" elem_ty ] ty_void)
          (option_some return_ty (vr "__elem" elem_ty))))
    (option_none return_ty) return_ty

let list_get_or _self_ty return_ty self index default =
  let elem =
    mk return_ty
      (CUnbox (intr "list_get_unchecked" [ self; index ] ty_ptr, return_ty))
  in
  if_
    (list_in_bounds self index)
    (borrow "__elem" elem
       (seq
          (intr "list_retain_for" [ self; vr "__elem" return_ty ] ty_void)
          (vr "__elem" return_ty)))
    default return_ty

(** set(self, index, elem) -> List[T]

    Public infallible wrapper for indexed replacement. Out-of-bounds writes
    are no-ops; in-bounds writes use the same COW path as
    [__unsafe_list_set_index]. *)
let list_set_public self_ty self index elem =
  if_
    (list_in_bounds self index)
    (list_set_index self_ty self index elem)
    self self_ty

(** __unsafe_list_swap(self, i, j) -> List[T]

    Public std/list.swap validates both indices before calling this helper. The
    intrinsic only swaps initialized slots, so no element retain/release is
    needed; ownership of every element stays within the same list. *)
let list_swap self_ty self i j =
  let cow_boundary = list_reuse_boundary "__unsafe_list_swap" in
  lett "__result"
    (intr cow_boundary [ self ] self_ty)
    (seq
       (intr "list_swap_slots" [ vr "__result" self_ty; i; j ] ty_void)
       (vr "__result" self_ty))

(** __unsafe_list_remove(self, index) -> List[T]

    Uses COW (list_ensure_unique) to preserve elem_release metadata,
    then shifts elements left in place over the removed element.

    let n = list_len(self)
    let result = list_ensure_unique(self)
    list_release_elem(result, index)  -- release removed element
    for i in (index+1)..n:
      list_set(result, i - 1, list_get(result, i))
    list_set_len(result, n - 1)
    result *)
let list_remove self_ty self index =
  let i = vr "__i" ty_int in
  let cow_boundary = list_reuse_boundary "__unsafe_list_remove" in
  lett "__n"
    (intr "list_len" [ self ] ty_int)
    (lett "__result"
       (intr cow_boundary [ self ] self_ty)
       (seq
          (intr "list_release_elem" [ vr "__result" self_ty; index ] ty_void)
          (seq
             (mk ty_void
                (CFor
                   ( loop "__i" ty_int,
                     mk ty_int
                       (CRange
                          (bin Ast.Add index (lit_int 1) ty_int, vr "__n" ty_int)),
                     intr "list_set"
                       [
                         vr "__result" self_ty;
                         bin Ast.Sub i (lit_int 1) ty_int;
                         intr "list_get" [ vr "__result" self_ty; i ] ty_ptr;
                       ]
                       ty_void )))
             (seq
                (intr "list_set_len"
                   [
                     vr "__result" self_ty;
                     bin Ast.Sub (vr "__n" ty_int) (lit_int 1) ty_int;
                   ]
                   ty_void)
                (vr "__result" self_ty)))))

(** __unsafe_list_insert(self, index, elem) -> List[T]

    let n = list_len(self)
    let result = list_ensure_capacity(self, n + 1)
    -- shift elements right: copy from end backwards
    for i in 0..n:
      let j = n - 1 - i  (reverse iteration)
      if j >= index: list_set(result, j + 1, list_get(result, j))
    list_retain_for(result, elem)     -- retain new element
    list_set(result, index, elem)
    list_set_len(result, n + 1)
    result *)
let list_insert self_ty self index elem =
  let i = vr "__i" ty_int in
  let n = vr "__n" ty_int in
  let cow_boundary = list_reuse_boundary "__unsafe_list_insert" in
  lett "__n"
    (intr "list_len" [ self ] ty_int)
    (lett "__result"
       (intr cow_boundary [ self; bin Ast.Add n (lit_int 1) ty_int ] self_ty)
       (seq
          (* shift right: iterate i from 0..n, compute j = n-1-i *)
          (mk ty_void
             (CFor
                ( loop "__i" ty_int,
                  mk ty_int (CRange (lit_int 0, n)),
                  lett "__j"
                    (bin Ast.Sub (bin Ast.Sub n (lit_int 1) ty_int) i ty_int)
                    (mk ty_void
                       (CIf
                          ( bin Ast.Ge (vr "__j" ty_int) index ty_int,
                            intr "list_set"
                              [
                                vr "__result" self_ty;
                                bin Ast.Add (vr "__j" ty_int) (lit_int 1) ty_int;
                                intr "list_get"
                                  [ vr "__result" self_ty; vr "__j" ty_int ]
                                  ty_ptr;
                              ]
                              ty_void,
                            void ))) )))
          (seq
             (intr "list_retain_for" [ vr "__result" self_ty; elem ] ty_void)
             (seq
                (intr "list_set" [ vr "__result" self_ty; index; elem ] ty_void)
                (seq
                   (intr "list_set_len"
                      [
                        vr "__result" self_ty; bin Ast.Add n (lit_int 1) ty_int;
                      ]
                      ty_void)
                   (vr "__result" self_ty))))))

(** __unsafe_list_tail(self) -> List[T]

    Uses COW to preserve elem_release, then shifts left and releases head.

    let n = list_len(self)
    let result = list_ensure_unique(self)
    list_release_elem(result, 0)      -- release head element
    for i in 1..n:
      list_set(result, i - 1, list_get(result, i))
    list_set_len(result, n - 1)
    result *)
let list_tail self_ty self =
  let i = vr "__i" ty_int in
  let cow_boundary = list_reuse_boundary "__unsafe_list_tail" in
  lett "__n"
    (intr "list_len" [ self ] ty_int)
    (if_
       (bin Ast.Eq (vr "__n" ty_int) (lit_int 0) ty_bool)
       self (* empty list → return as-is *)
       (lett "__result"
          (intr cow_boundary [ self ] self_ty)
          (seq
             (intr "list_release_elem"
                [ vr "__result" self_ty; lit_int 0 ]
                ty_void)
             (seq
                (mk ty_void
                   (CFor
                      ( loop "__i" ty_int,
                        mk ty_int (CRange (lit_int 1, vr "__n" ty_int)),
                        intr "list_set"
                          [
                            vr "__result" self_ty;
                            bin Ast.Sub i (lit_int 1) ty_int;
                            intr "list_get" [ vr "__result" self_ty; i ] ty_ptr;
                          ]
                          ty_void )))
                (seq
                   (intr "list_set_len"
                      [
                        vr "__result" self_ty;
                        bin Ast.Sub (vr "__n" ty_int) (lit_int 1) ty_int;
                      ]
                      ty_void)
                   (vr "__result" self_ty)))))
       self_ty)

(** __unsafe_list_reverse(self) -> List[T]

    Reverse consumes one owned reference and returns an owned list. The runtime
    primitive reuses storage when the input is unique and otherwise allocates a
    reversed copy with the correct element retain policy. *)
let list_reverse self_ty self = intr "list_reverse_owned" [ self ] self_ty

let nonnegative_count n =
  if_ (bin Ast.Le n (lit_int 0) ty_bool) (lit_int 0) n ty_int

let clamp_count_to_len n len =
  if_
    (bin Ast.Le n (lit_int 0) ty_bool)
    (lit_int 0)
    (if_ (bin Ast.Lt n len ty_bool) n len ty_int)
    ty_int

let copy_borrowed_to_collection result_name result_ty elem_ty source source_i
    dest_i =
  let elem = mk elem_ty (CUnbox (vr "__copy_raw" ty_ptr, elem_ty)) in
  lett "__copy_raw"
    (intr "list_get" [ source; source_i ] ty_ptr)
    (seq
       (intr "list_retain_for" [ vr result_name result_ty; elem ] ty_void)
       (intr "list_set_owned"
          [ vr result_name result_ty; dest_i; elem ]
          ty_void))

let copy_borrowed_to_result result_ty elem_ty source source_i dest_i =
  copy_borrowed_to_collection "__result" result_ty elem_ty source source_i
    dest_i

(** concat(a, b) -> List[T]

    Allocate the exact combined length and copy borrowed elements from both
    inputs with explicit retain-before-transfer. *)
let list_concat list_ty a b =
  let alloc = list_alloc_intrinsic "concat" in
  lett "__a" a
    (lett "__b" b
       (lett "__len_a"
          (intr "list_len" [ vr "__a" list_ty ] ty_int)
          (lett "__len_b"
             (intr "list_len" [ vr "__b" list_ty ] ty_int)
             (lett "__out_n"
                (bin Ast.Add (vr "__len_a" ty_int) (vr "__len_b" ty_int) ty_int)
                (lett "__result"
                   (intr alloc [ vr "__out_n" ty_int ] list_ty)
                   (seq
                      (intr "list_copy_span_uninit"
                         [
                           vr "__result" list_ty;
                           lit_int 0;
                           vr "__a" list_ty;
                           lit_int 0;
                           vr "__len_a" ty_int;
                         ]
                         ty_void)
                      (seq
                         (intr "list_copy_span_uninit"
                            [
                              vr "__result" list_ty;
                              vr "__len_a" ty_int;
                              vr "__b" list_ty;
                              lit_int 0;
                              vr "__len_b" ty_int;
                            ]
                            ty_void)
                         (seq
                            (intr "list_set_len"
                               [ vr "__result" list_ty; vr "__out_n" ty_int ]
                               ty_void)
                            (vr "__result" list_ty)))))))))

(** take(self, n) -> List[T]

    Clamp [n] to [0, length(self)], allocate exactly that many slots, and
    copy the retained prefix. *)
let list_take self_ty self n =
  let alloc = list_alloc_intrinsic "take" in
  let elem_ty = list_elem_ty self_ty in
  let i = vr "__i" ty_int in
  let copy =
    copy_borrowed_to_result self_ty elem_ty (vr "__self" self_ty) i i
  in
  borrow "__self" self
    (lett "__len"
       (intr "list_len" [ vr "__self" self_ty ] ty_int)
       (lett "__requested" n
          (lett "__out_n"
             (clamp_count_to_len (vr "__requested" ty_int) (vr "__len" ty_int))
             (lett "__result"
                (intr alloc [ vr "__out_n" ty_int ] self_ty)
                (seq
                   (mk ty_void
                      (CFor
                         ( loop "__i" ty_int,
                           mk ty_int (CRange (lit_int 0, vr "__out_n" ty_int)),
                           copy )))
                   (seq
                      (intr "list_set_len"
                         [ vr "__result" self_ty; vr "__out_n" ty_int ]
                         ty_void)
                      (vr "__result" self_ty)))))))

(** drop(self, n) -> List[T]

    Clamp the drop count and copy the retained suffix into an exact-size
    result. *)
let list_drop self_ty self n =
  let alloc = list_alloc_intrinsic "drop" in
  let elem_ty = list_elem_ty self_ty in
  let i = vr "__i" ty_int in
  let source_i = bin Ast.Add (vr "__start" ty_int) i ty_int in
  let copy =
    copy_borrowed_to_result self_ty elem_ty (vr "__self" self_ty) source_i i
  in
  borrow "__self" self
    (lett "__len"
       (intr "list_len" [ vr "__self" self_ty ] ty_int)
       (lett "__requested" n
          (lett "__start"
             (clamp_count_to_len (vr "__requested" ty_int) (vr "__len" ty_int))
             (lett "__out_n"
                (bin Ast.Sub (vr "__len" ty_int) (vr "__start" ty_int) ty_int)
                (lett "__result"
                   (intr alloc [ vr "__out_n" ty_int ] self_ty)
                   (seq
                      (mk ty_void
                         (CFor
                            ( loop "__i" ty_int,
                              mk ty_int
                                (CRange (lit_int 0, vr "__out_n" ty_int)),
                              copy )))
                      (seq
                         (intr "list_set_len"
                            [ vr "__result" self_ty; vr "__out_n" ty_int ]
                            ty_void)
                         (vr "__result" self_ty))))))))

(** flatten(lists) -> List[T]

    Pre-scan inner list lengths, allocate once at the exact total, then copy
    borrowed inner elements with explicit retain-before-transfer. *)
let list_flatten outer_ty result_ty lists =
  let alloc = list_alloc_intrinsic "flatten" in
  let inner_ty = list_elem_ty outer_ty in
  let elem_ty = list_elem_ty result_ty in
  let outer_i = vr "__outer_i" ty_int in
  let inner_i = vr "__inner_i" ty_int in
  let out = vr "__out" ty_int in
  let current_inner =
    mk inner_ty (CUnbox (vr "__inner_raw" ty_ptr, inner_ty))
  in
  let bind_inner body =
    lett "__inner_raw"
      (intr "list_get" [ vr "__lists" outer_ty; outer_i ] ty_ptr)
      body
  in
  let prescan_body =
    bind_inner
      (assign "__total"
         (bin Ast.Add (vr "__total" ty_int)
            (intr "list_len" [ current_inner ] ty_int)
            ty_int))
  in
  let copy_inner_body =
    let elem = mk elem_ty (CUnbox (vr "__inner_elem_raw" ty_ptr, elem_ty)) in
    lett "__inner_elem_raw"
      (intr "list_get" [ current_inner; inner_i ] ty_ptr)
      (seq
         (intr "list_retain_for" [ vr "__result" result_ty; elem ] ty_void)
         (seq
            (intr "list_set_owned"
               [ vr "__result" result_ty; out; elem ]
               ty_void)
            (assign "__out" (bin Ast.Add out (lit_int 1) ty_int))))
  in
  let copy_outer_body =
    bind_inner
      (lett "__inner_n"
         (intr "list_len" [ current_inner ] ty_int)
         (mk ty_void
            (CFor
               ( loop "__inner_i" ty_int,
                 mk ty_int (CRange (lit_int 0, vr "__inner_n" ty_int)),
                 copy_inner_body ))))
  in
  lett "__lists" lists
    (lett "__outer_n"
       (intr "list_len" [ vr "__lists" outer_ty ] ty_int)
       (lettm "__total" (lit_int 0)
          (seq
             (mk ty_void
                (CFor
                   ( loop "__outer_i" ty_int,
                     mk ty_int (CRange (lit_int 0, vr "__outer_n" ty_int)),
                     prescan_body )))
             (lett "__result"
                (intr alloc [ vr "__total" ty_int ] result_ty)
                (lettm "__out" (lit_int 0)
                   (seq
                      (mk ty_void
                         (CFor
                            ( loop "__outer_i" ty_int,
                              mk ty_int
                                (CRange (lit_int 0, vr "__outer_n" ty_int)),
                              copy_outer_body )))
                      (seq
                         (intr "list_set_len"
                            [ vr "__result" result_ty; vr "__total" ty_int ]
                            ty_void)
                         (vr "__result" result_ty))))))))

(** repeat(elem, n) -> List[T]

    Clamp negative counts to zero, allocate exactly [n], and retain the input
    element once per stored slot while preserving the caller-owned argument. *)
let list_repeat result_ty elem n =
  let alloc = list_alloc_intrinsic "repeat" in
  let elem_ty = list_elem_ty result_ty in
  let i = vr "__i" ty_int in
  let loop_body =
    seq
      (intr "list_retain_for"
         [ vr "__result" result_ty; vr "__elem" elem_ty ]
         ty_void)
      (intr "list_set"
         [ vr "__result" result_ty; i; vr "__elem" elem_ty ]
         ty_void)
  in
  lett "__elem" elem
    (lett "__requested" n
       (lett "__out_n"
          (nonnegative_count (vr "__requested" ty_int))
          (lett "__result"
             (intr alloc [ vr "__out_n" ty_int ] result_ty)
             (seq
                (mk ty_void
                   (CFor
                      ( loop "__i" ty_int,
                        mk ty_int (CRange (lit_int 0, vr "__out_n" ty_int)),
                        loop_body )))
                (seq
                   (intr "list_set_len"
                      [ vr "__result" result_ty; vr "__out_n" ty_int ]
                      ty_void)
                   (vr "__result" result_ty))))))

(** intersperse(self, sep) -> List[T]

    Allocate the exact final length, retain the caller-owned separator for
    each separator slot, and retain/copy borrowed source elements into their
    output positions. *)
let list_intersperse self_ty self sep =
  let alloc = list_alloc_intrinsic "intersperse" in
  let elem_ty = list_elem_ty self_ty in
  let i = vr "__i" ty_int in
  let out = vr "__out" ty_int in
  let sep_slot = bin Ast.Sub out (lit_int 1) ty_int in
  let out_n =
    if_
      (bin Ast.Le (vr "__n" ty_int) (lit_int 1) ty_bool)
      (vr "__n" ty_int)
      (bin Ast.Sub
         (bin Ast.Mul (vr "__n" ty_int) (lit_int 2) ty_int)
         (lit_int 1) ty_int)
      ty_int
  in
  let store_sep =
    seq
      (intr "list_retain_for"
         [ vr "__result" self_ty; vr "__sep" elem_ty ]
         ty_void)
      (intr "list_set"
         [ vr "__result" self_ty; sep_slot; vr "__sep" elem_ty ]
         ty_void)
  in
  let loop_body =
    lett "__out"
      (bin Ast.Mul i (lit_int 2) ty_int)
      (seq
         (if_ (bin Ast.Gt i (lit_int 0) ty_bool) store_sep void ty_void)
         (copy_borrowed_to_result self_ty elem_ty (vr "__self" self_ty) i out))
  in
  borrow "__self" self
    (lett "__sep" sep
       (lett "__n"
          (intr "list_len" [ vr "__self" self_ty ] ty_int)
          (lett "__out_n" out_n
             (lett "__result"
                (intr alloc [ vr "__out_n" ty_int ] self_ty)
                (seq
                   (mk ty_void
                      (CFor
                         ( loop "__i" ty_int,
                           mk ty_int (CRange (lit_int 0, vr "__n" ty_int)),
                           loop_body )))
                   (seq
                      (intr "list_set_len"
                         [ vr "__result" self_ty; vr "__out_n" ty_int ]
                         ty_void)
                      (vr "__result" self_ty)))))))

(** windows(self, n) -> List[List[T]]

    Allocate the outer list exactly, then allocate each inner window exactly
    and copy borrowed source elements directly into it. This avoids the
    previous drop/take intermediate lists while making nested ownership
    explicit in Core. *)
let list_windows self_ty return_ty self n =
  let alloc = list_alloc_intrinsic "windows" in
  let inner_ty = list_elem_ty return_ty in
  let elem_ty = list_elem_ty self_ty in
  let outer_i = vr "__outer_i" ty_int in
  let inner_i = vr "__inner_i" ty_int in
  let source_i = bin Ast.Add outer_i inner_i ty_int in
  let out_n =
    if_
      (log Ast.Or
         (bin Ast.Le (vr "__requested" ty_int) (lit_int 0) ty_bool)
         (bin Ast.Gt (vr "__requested" ty_int) (vr "__len" ty_int) ty_bool))
      (lit_int 0)
      (bin Ast.Add
         (bin Ast.Sub (vr "__len" ty_int) (vr "__requested" ty_int) ty_int)
         (lit_int 1) ty_int)
      ty_int
  in
  let copy_inner =
    copy_borrowed_to_collection "__window" inner_ty elem_ty
      (vr "__self" self_ty) source_i inner_i
  in
  let build_window =
    lett "__window"
      (intr alloc [ vr "__requested" ty_int ] inner_ty)
      (seq
         (mk ty_void
            (CFor
               ( loop "__inner_i" ty_int,
                 mk ty_int (CRange (lit_int 0, vr "__requested" ty_int)),
                 copy_inner )))
         (seq
            (intr "list_set_len"
               [ vr "__window" inner_ty; vr "__requested" ty_int ]
               ty_void)
            (intr "list_set_owned"
               [ vr "__result" return_ty; outer_i; vr "__window" inner_ty ]
               ty_void)))
  in
  borrow "__self" self
    (lett "__requested" n
       (lett "__len"
          (intr "list_len" [ vr "__self" self_ty ] ty_int)
          (lett "__out_n" out_n
             (lett "__result"
                (intr alloc [ vr "__out_n" ty_int ] return_ty)
                (seq
                   (mk ty_void
                      (CFor
                         ( loop "__outer_i" ty_int,
                           mk ty_int (CRange (lit_int 0, vr "__out_n" ty_int)),
                           build_window )))
                   (seq
                      (intr "list_set_len"
                         [ vr "__result" return_ty; vr "__out_n" ty_int ]
                         ty_void)
                      (vr "__result" return_ty)))))))

(** chunks(self, n) -> List[List[T]]

    Allocate the exact number of chunks, then allocate each chunk at its exact
    size. The final chunk may be shorter than [n]. *)
let list_chunks self_ty return_ty self n =
  let alloc = list_alloc_intrinsic "chunks" in
  let inner_ty = list_elem_ty return_ty in
  let elem_ty = list_elem_ty self_ty in
  let outer_i = vr "__outer_i" ty_int in
  let inner_i = vr "__inner_i" ty_int in
  let start = vr "__start" ty_int in
  let chunk_len = vr "__chunk_len" ty_int in
  let source_i = bin Ast.Add start inner_i ty_int in
  let out_n =
    if_
      (log Ast.Or
         (bin Ast.Le (vr "__requested" ty_int) (lit_int 0) ty_bool)
         (bin Ast.Le (vr "__len" ty_int) (lit_int 0) ty_bool))
      (lit_int 0)
      (bin Ast.Div
         (bin Ast.Add
            (bin Ast.Sub (vr "__len" ty_int) (lit_int 1) ty_int)
            (vr "__requested" ty_int) ty_int)
         (vr "__requested" ty_int) ty_int)
      ty_int
  in
  let copy_inner =
    copy_borrowed_to_collection "__chunk" inner_ty elem_ty (vr "__self" self_ty)
      source_i inner_i
  in
  let build_chunk =
    lett "__start"
      (bin Ast.Mul outer_i (vr "__requested" ty_int) ty_int)
      (lett "__remaining"
         (bin Ast.Sub (vr "__len" ty_int) start ty_int)
         (lett "__chunk_len"
            (if_
               (bin Ast.Lt (vr "__remaining" ty_int) (vr "__requested" ty_int)
                  ty_bool)
               (vr "__remaining" ty_int) (vr "__requested" ty_int) ty_int)
            (lett "__chunk"
               (intr alloc [ chunk_len ] inner_ty)
               (seq
                  (mk ty_void
                     (CFor
                        ( loop "__inner_i" ty_int,
                          mk ty_int (CRange (lit_int 0, chunk_len)),
                          copy_inner )))
                  (seq
                     (intr "list_set_len"
                        [ vr "__chunk" inner_ty; chunk_len ]
                        ty_void)
                     (intr "list_set_owned"
                        [
                          vr "__result" return_ty;
                          outer_i;
                          vr "__chunk" inner_ty;
                        ]
                        ty_void))))))
  in
  borrow "__self" self
    (lett "__requested" n
       (lett "__len"
          (intr "list_len" [ vr "__self" self_ty ] ty_int)
          (lett "__out_n" out_n
             (lett "__result"
                (intr alloc [ vr "__out_n" ty_int ] return_ty)
                (seq
                   (mk ty_void
                      (CFor
                         ( loop "__outer_i" ty_int,
                           mk ty_int (CRange (lit_int 0, vr "__out_n" ty_int)),
                           build_chunk )))
                   (seq
                      (intr "list_set_len"
                         [ vr "__result" return_ty; vr "__out_n" ty_int ]
                         ty_void)
                      (vr "__result" return_ty)))))))

(** range(start, stop) -> List[Int]

    Allocate exactly max(stop - start, 0) and write primitive Int slots
    directly. *)
let list_range result_ty start stop =
  let alloc = list_alloc_intrinsic "range" in
  let i = vr "__i" ty_int in
  let value = bin Ast.Add (vr "__start" ty_int) i ty_int in
  lett "__start" start
    (lett "__stop" stop
       (lett "__out_n"
          (if_
             (bin Ast.Le (vr "__stop" ty_int) (vr "__start" ty_int) ty_bool)
             (lit_int 0)
             (bin Ast.Sub (vr "__stop" ty_int) (vr "__start" ty_int) ty_int)
             ty_int)
          (lett "__result"
             (intr alloc [ vr "__out_n" ty_int ] result_ty)
             (seq
                (mk ty_void
                   (CFor
                      ( loop "__i" ty_int,
                        mk ty_int (CRange (lit_int 0, vr "__out_n" ty_int)),
                        intr "list_set"
                          [ vr "__result" result_ty; i; value ]
                          ty_void )))
                (seq
                   (intr "list_set_len"
                      [ vr "__result" result_ty; vr "__out_n" ty_int ]
                      ty_void)
                   (vr "__result" result_ty))))))

(** unique(self) -> List[T]

    Allocate at the input length as an upper bound, keep the first occurrence
    of each value, and shrink the final length. Equality is normal Core
    [==], so post-mono trait resolution still routes user types through their
    [Equatable.equals] implementation. *)
let list_unique self_ty self =
  let alloc = list_alloc_intrinsic "unique" in
  let elem_ty = list_elem_ty self_ty in
  let i = vr "__i" ty_int in
  let scan_i = vr "__scan_i" ty_int in
  let out = vr "__out" ty_int in
  let elem = mk elem_ty (CUnbox (vr "__raw" ty_ptr, elem_ty)) in
  let prior = mk elem_ty (CUnbox (vr "__prior_raw" ty_ptr, elem_ty)) in
  let store =
    seq
      (intr "list_retain_for" [ vr "__result" self_ty; elem ] ty_void)
      (seq
         (intr "list_set_owned" [ vr "__result" self_ty; out; elem ] ty_void)
         (seq
            (assign "__out" (bin Ast.Add out (lit_int 1) ty_int))
            (intr "list_set_len"
               [ vr "__result" self_ty; vr "__out" ty_int ]
               ty_void)))
  in
  let scan_body =
    lett "__prior_raw"
      (intr "list_get" [ vr "__result" self_ty; scan_i ] ty_ptr)
      (if_
         (bin Ast.Eq prior elem ty_bool)
         (seq (assign "__seen" (lit_bool true)) break_)
         void ty_void)
  in
  let loop_body =
    lett "__raw"
      (intr "list_get" [ vr "__self" self_ty; i ] ty_ptr)
      (lettm "__seen" (lit_bool false)
         (seq
            (mk ty_void
               (CFor
                  ( loop "__scan_i" ty_int,
                    mk ty_int (CRange (lit_int 0, out)),
                    scan_body )))
            (if_
               (bin Ast.Eq (vr "__seen" ty_bool) (lit_bool false) ty_bool)
               store void ty_void)))
  in
  borrow "__self" self
    (lett "__n"
       (intr "list_len" [ vr "__self" self_ty ] ty_int)
       (lett "__result"
          (intr alloc [ vr "__n" ty_int ] self_ty)
          (lettm "__out" (lit_int 0)
             (seq
                (mk ty_void
                   (CFor
                      ( loop "__i" ty_int,
                        mk ty_int (CRange (lit_int 0, vr "__n" ty_int)),
                        loop_body )))
                (seq
                   (intr "list_set_len"
                      [ vr "__result" self_ty; vr "__out" ty_int ]
                      ty_void)
                   (vr "__result" self_ty))))))

(** map(self, f) -> List[U]

    Allocate the result once at the exact output length, then transfer each
    callback result into an uninitialized slot. This keeps allocation and
    element ownership visible to Perceus and avoids repeated append/COW work. *)
let list_map self_ty result_ty self f =
  let alloc = list_alloc_intrinsic "map" in
  let elem_ty =
    match self_ty with
    | Ast.TyNamed (("List" | "ParallelList"), [ t ]) -> t
    | _ -> ty_ptr
  in
  let result_elem_ty =
    match result_ty with
    | Ast.TyNamed (("List" | "ParallelList"), [ t ]) -> t
    | _ -> ty_ptr
  in
  let i = vr "__i" ty_int in
  let raw_elem = intr "list_get" [ vr "__self" self_ty; i ] ty_ptr in
  let elem = mk elem_ty (CUnbox (raw_elem, elem_ty)) in
  let mapped = closure_call f [ elem ] result_elem_ty in
  let loop_body =
    lett "__mapped" mapped
      (intr "list_set_owned"
         [ vr "__result" result_ty; i; vr "__mapped" result_elem_ty ]
         ty_void)
  in
  let fill_loop =
    mk ty_void
      (CFor
         ( loop "__i" ty_int,
           mk ty_int (CRange (lit_int 0, vr "__n" ty_int)),
           loop_body ))
  in
  borrow "__self" self
    (lett "__n"
       (intr "list_len" [ vr "__self" self_ty ] ty_int)
       (lett "__result"
          (intr alloc [ vr "__n" ty_int ] result_ty)
          (seq fill_loop
             (seq
                (intr "list_set_len"
                   [ vr "__result" result_ty; vr "__n" ty_int ]
                   ty_void)
                (vr "__result" result_ty)))))

(** concurrent(self, limit, f) -> List[Result[U, ConcurrencyError]]

    Build the public helper as Core for ... concurrently instead of a separate
    runtime mapping primitive. This keeps task spawning, result wrapping,
    cancellation, and timeout join behavior on the same path as source
    [for ... concurrently(limit:)]. *)
let list_concurrent_collect ?timeout self_ty result_ty self limit f =
  let elem_ty = list_elem_ty self_ty in
  let result_elem_ty = list_task_result_ok_ty result_ty in
  let item_var = Var.named "__item" in
  let item = mk elem_ty (CVar item_var) in
  let body = closure_call f [ item ] result_elem_ty in
  mk result_ty
    (CConcurrentlyLoop
       {
         cf_var = item_var;
         cf_iter = self;
         cf_body = body;
         cf_timeout = timeout;
         cf_width = ConcurrentlyLoopLimit limit;
         cf_output = ConcurrentlyLoopCollect;
         cf_item_mode = ConcurrentlyLoopCopyItem;
         cf_task_scope = synthetic_concurrent_task_scope;
       })

(** map_indexed(self, f) -> List[U]

    Same allocation policy as [map], but passes the loop index as the first
    callback argument. *)
let list_map_indexed self_ty result_ty self f =
  let alloc = list_alloc_intrinsic "map_indexed" in
  let elem_ty = list_elem_ty self_ty in
  let result_elem_ty = list_elem_ty result_ty in
  let i = vr "__i" ty_int in
  let raw_elem = intr "list_get" [ vr "__self" self_ty; i ] ty_ptr in
  let elem = mk elem_ty (CUnbox (raw_elem, elem_ty)) in
  let mapped = closure_call f [ i; elem ] result_elem_ty in
  let loop_body =
    lett "__mapped" mapped
      (intr "list_set_owned"
         [ vr "__result" result_ty; i; vr "__mapped" result_elem_ty ]
         ty_void)
  in
  let fill_loop =
    mk ty_void
      (CFor
         ( loop "__i" ty_int,
           mk ty_int (CRange (lit_int 0, vr "__n" ty_int)),
           loop_body ))
  in
  borrow "__self" self
    (lett "__n"
       (intr "list_len" [ vr "__self" self_ty ] ty_int)
       (lett "__result"
          (intr alloc [ vr "__n" ty_int ] result_ty)
          (seq fill_loop
             (seq
                (intr "list_set_len"
                   [ vr "__result" result_ty; vr "__n" ty_int ]
                   ty_void)
                (vr "__result" result_ty)))))

(** filter(self, predicate) -> List[T]

    Allocate at the input length as an upper bound, keep a separate output
    cursor, and shrink the final length after the pass. Kept elements are
    borrowed aliases from [self], so retain them before transferring the owned
    reference into the result slot. *)
let list_filter self_ty self predicate =
  let alloc = list_alloc_intrinsic "filter" in
  let elem_ty =
    match self_ty with Ast.TyNamed ("List", [ t ]) -> t | _ -> ty_ptr
  in
  let i = vr "__i" ty_int in
  let out = vr "__out" ty_int in
  let elem = mk elem_ty (CUnbox (vr "__raw" ty_ptr, elem_ty)) in
  let keep =
    seq
      (intr "list_retain_for" [ vr "__result" self_ty; elem ] ty_void)
      (seq
         (intr "list_set_owned" [ vr "__result" self_ty; out; elem ] ty_void)
         (assign "__out" (bin Ast.Add out (lit_int 1) ty_int)))
  in
  let loop_body =
    lett "__raw"
      (intr "list_get" [ vr "__self" self_ty; i ] ty_ptr)
      (if_ (closure_call predicate [ elem ] ty_bool) keep void ty_void)
  in
  borrow "__self" self
    (lett "__n"
       (intr "list_len" [ vr "__self" self_ty ] ty_int)
       (lett "__result"
          (intr alloc [ vr "__n" ty_int ] self_ty)
          (lettm "__out" (lit_int 0)
             (seq
                (mk ty_void
                   (CFor
                      ( loop "__i" ty_int,
                        mk ty_int (CRange (lit_int 0, vr "__n" ty_int)),
                        loop_body )))
                (seq
                   (intr "list_set_len"
                      [ vr "__result" self_ty; vr "__out" ty_int ]
                      ty_void)
                   (vr "__result" self_ty))))))

(** take_while(self, predicate) -> List[T]

    Allocate at the input length as an upper bound, retain/transfer matching
    borrowed elements, and stop on the first predicate miss. *)
let list_take_while self_ty self predicate =
  let alloc = list_alloc_intrinsic "take_while" in
  let elem_ty = list_elem_ty self_ty in
  let i = vr "__i" ty_int in
  let out = vr "__out" ty_int in
  let elem = mk elem_ty (CUnbox (vr "__raw" ty_ptr, elem_ty)) in
  let keep =
    seq
      (intr "list_retain_for" [ vr "__result" self_ty; elem ] ty_void)
      (seq
         (intr "list_set_owned" [ vr "__result" self_ty; out; elem ] ty_void)
         (assign "__out" (bin Ast.Add out (lit_int 1) ty_int)))
  in
  let loop_body =
    lett "__raw"
      (intr "list_get" [ vr "__self" self_ty; i ] ty_ptr)
      (if_ (closure_call predicate [ elem ] ty_bool) keep break_ ty_void)
  in
  borrow "__self" self
    (lett "__n"
       (intr "list_len" [ vr "__self" self_ty ] ty_int)
       (lett "__result"
          (intr alloc [ vr "__n" ty_int ] self_ty)
          (lettm "__out" (lit_int 0)
             (seq
                (mk ty_void
                   (CFor
                      ( loop "__i" ty_int,
                        mk ty_int (CRange (lit_int 0, vr "__n" ty_int)),
                        loop_body )))
                (seq
                   (intr "list_set_len"
                      [ vr "__result" self_ty; vr "__out" ty_int ]
                      ty_void)
                   (vr "__result" self_ty))))))

(** drop_while(self, predicate) -> List[T]

    First scan to find the retained suffix start, then allocate the exact suffix
    length and copy retained borrowed elements into the result. *)
let list_drop_while self_ty self predicate =
  let alloc = list_alloc_intrinsic "drop_while" in
  let elem_ty = list_elem_ty self_ty in
  let i = vr "__i" ty_int in
  let elem = mk elem_ty (CUnbox (vr "__raw" ty_ptr, elem_ty)) in
  let scan_body =
    lett "__raw"
      (intr "list_get" [ vr "__self" self_ty; i ] ty_ptr)
      (if_
         (closure_call predicate [ elem ] ty_bool)
         (assign "__start" (bin Ast.Add i (lit_int 1) ty_int))
         break_ ty_void)
  in
  let source_i = bin Ast.Add (vr "__start" ty_int) i ty_int in
  let copy_body =
    lett "__raw"
      (intr "list_get" [ vr "__self" self_ty; source_i ] ty_ptr)
      (seq
         (intr "list_retain_for" [ vr "__result" self_ty; elem ] ty_void)
         (intr "list_set_owned" [ vr "__result" self_ty; i; elem ] ty_void))
  in
  borrow "__self" self
    (lett "__n"
       (intr "list_len" [ vr "__self" self_ty ] ty_int)
       (lettm "__start" (lit_int 0)
          (seq
             (mk ty_void
                (CFor
                   ( loop "__i" ty_int,
                     mk ty_int (CRange (lit_int 0, vr "__n" ty_int)),
                     scan_body )))
             (lett "__out_n"
                (bin Ast.Sub (vr "__n" ty_int) (vr "__start" ty_int) ty_int)
                (lett "__result"
                   (intr alloc [ vr "__out_n" ty_int ] self_ty)
                   (seq
                      (mk ty_void
                         (CFor
                            ( loop "__i" ty_int,
                              mk ty_int
                                (CRange (lit_int 0, vr "__out_n" ty_int)),
                              copy_body )))
                      (seq
                         (intr "list_set_len"
                            [ vr "__result" self_ty; vr "__out_n" ty_int ]
                            ty_void)
                         (vr "__result" self_ty))))))))

(** partition(self, predicate) -> (List[T], List[T])

    Allocate two upper-bound output lists, copy each borrowed source element
    into the matching side with an explicit retain-before-transfer, then shrink
    both lists to their actual lengths. *)
let list_partition self_ty return_ty self predicate =
  let alloc = list_alloc_intrinsic "partition" in
  let elem_ty = list_elem_ty self_ty in
  let i = vr "__i" ty_int in
  let elem = mk elem_ty (CUnbox (vr "__raw" ty_ptr, elem_ty)) in
  let push list_name out_name out =
    seq
      (intr "list_retain_for" [ vr list_name self_ty; elem ] ty_void)
      (seq
         (intr "list_set_owned" [ vr list_name self_ty; out; elem ] ty_void)
         (assign out_name (bin Ast.Add out (lit_int 1) ty_int)))
  in
  let loop_body =
    lett "__raw"
      (intr "list_get" [ vr "__self" self_ty; i ] ty_ptr)
      (if_
         (closure_call predicate [ elem ] ty_bool)
         (push "__yes" "__yes_out" (vr "__yes_out" ty_int))
         (push "__no" "__no_out" (vr "__no_out" ty_int))
         ty_void)
  in
  borrow "__self" self
    (lett "__n"
       (intr "list_len" [ vr "__self" self_ty ] ty_int)
       (lett "__yes"
          (intr alloc [ vr "__n" ty_int ] self_ty)
          (lett "__no"
             (intr alloc [ vr "__n" ty_int ] self_ty)
             (lettm "__yes_out" (lit_int 0)
                (lettm "__no_out" (lit_int 0)
                   (seq
                      (mk ty_void
                         (CFor
                            ( loop "__i" ty_int,
                              mk ty_int (CRange (lit_int 0, vr "__n" ty_int)),
                              loop_body )))
                      (seq
                         (intr "list_set_len"
                            [ vr "__yes" self_ty; vr "__yes_out" ty_int ]
                            ty_void)
                         (seq
                            (intr "list_set_len"
                               [ vr "__no" self_ty; vr "__no_out" ty_int ]
                               ty_void)
                            (mk return_ty
                               (CTuple [ vr "__yes" self_ty; vr "__no" self_ty ]))))))))))

(** flat_map(self, f) -> List[U]

    Call [f] exactly once per source element, grow the output once per returned
    inner list, and copy borrowed inner elements into the result with explicit
    retain-before-transfer. *)
let list_flat_map self_ty result_ty self f =
  let alloc = list_alloc_intrinsic "flat_map" in
  let growth_boundary = list_growth_boundary "flat_map" in
  let elem_ty = list_elem_ty self_ty in
  let result_elem_ty = list_elem_ty result_ty in
  let outer_i = vr "__outer_i" ty_int in
  let inner_i = vr "__inner_i" ty_int in
  let out = vr "__out" ty_int in
  let inner_elem =
    mk result_elem_ty (CUnbox (vr "__inner_raw" ty_ptr, result_elem_ty))
  in
  let outer_elem = mk elem_ty (CUnbox (vr "__outer_raw" ty_ptr, elem_ty)) in
  let inner_loop_body =
    lett "__inner_raw"
      (intr "list_get" [ vr "__inner" result_ty; inner_i ] ty_ptr)
      (seq
         (intr "list_retain_for"
            [ vr "__result" result_ty; inner_elem ]
            ty_void)
         (seq
            (intr "list_set_owned"
               [ vr "__result" result_ty; out; inner_elem ]
               ty_void)
            (assign "__out" (bin Ast.Add out (lit_int 1) ty_int))))
  in
  let grow_result =
    assign "__result"
      (intr growth_boundary
         [
           vr "__result" result_ty;
           bin Ast.Add out (vr "__inner_n" ty_int) ty_int;
         ]
         result_ty)
  in
  let fill_inner_loop =
    mk ty_void
      (CFor
         ( loop "__inner_i" ty_int,
           mk ty_int (CRange (lit_int 0, vr "__inner_n" ty_int)),
           inner_loop_body ))
  in
  let sync_result_len =
    intr "list_set_len" [ vr "__result" result_ty; vr "__out" ty_int ] ty_void
  in
  let outer_loop_body =
    lett "__outer_raw"
      (intr "list_get" [ vr "__self" self_ty; outer_i ] ty_ptr)
      (lett "__inner"
         (closure_call f [ outer_elem ] result_ty)
         (lett "__inner_n"
            (intr "list_len" [ vr "__inner" result_ty ] ty_int)
            (seq grow_result (seq fill_inner_loop sync_result_len))))
  in
  borrow "__self" self
    (lett "__n"
       (intr "list_len" [ vr "__self" self_ty ] ty_int)
       (lettm "__result"
          (intr alloc [ lit_int 0 ] result_ty)
          (lettm "__out" (lit_int 0)
             (seq
                (mk ty_void
                   (CFor
                      ( loop "__outer_i" ty_int,
                        mk ty_int (CRange (lit_int 0, vr "__n" ty_int)),
                        outer_loop_body )))
                (vr "__result" result_ty)))))

(** filter_map(self, f) -> List[U]

    Allocate at the input length as an upper bound, call [f] once per element,
    transfer [Some] payloads into the result, and shrink the final length.
    The callback result is an owned [Option[U]] let binding; Perceus is the
    single owner of the wrapper's release placement. Match payload bindings are
    currently borrowed aliases, so Perceus retains managed payloads before
    [list_set_owned] consumes them. *)
let list_filter_map self_ty result_ty self f =
  let alloc = list_alloc_intrinsic "filter_map" in
  let elem_ty =
    match self_ty with
    | Ast.TyNamed (("List" | "ParallelList"), [ t ]) -> t
    | _ -> ty_ptr
  in
  let result_elem_ty =
    match result_ty with
    | Ast.TyNamed (("List" | "ParallelList"), [ t ]) -> t
    | _ -> ty_ptr
  in
  let option_ty = Ast.TyNamed ("Option", [ result_elem_ty ]) in
  let i = vr "__i" ty_int in
  let out = vr "__out" ty_int in
  let value = vr "__value" result_elem_ty in
  let keep =
    seq
      (intr "list_set_owned" [ vr "__result" result_ty; out; value ] ty_void)
      (assign "__out" (bin Ast.Add out (lit_int 1) ty_int))
  in
  let match_mapped =
    mk ty_void
      (CMatchArms
         ( vr "__mapped" option_ty,
           [
             (Ast.PatConstructor ("Some", [ Ast.PatVar "__value" ]), keep);
             (Ast.PatConstructor ("None", []), void);
           ] ))
  in
  let elem = mk elem_ty (CUnbox (vr "__raw" ty_ptr, elem_ty)) in
  let loop_body =
    lett "__raw"
      (intr "list_get" [ vr "__self" self_ty; i ] ty_ptr)
      (lett "__mapped" (closure_call f [ elem ] option_ty) match_mapped)
  in
  borrow "__self" self
    (lett "__n"
       (intr "list_len" [ vr "__self" self_ty ] ty_int)
       (lett "__result"
          (intr alloc [ vr "__n" ty_int ] result_ty)
          (lettm "__out" (lit_int 0)
             (seq
                (mk ty_void
                   (CFor
                      ( loop "__i" ty_int,
                        mk ty_int (CRange (lit_int 0, vr "__n" ty_int)),
                        loop_body )))
                (seq
                   (intr "list_set_len"
                      [ vr "__result" result_ty; vr "__out" ty_int ]
                      ty_void)
                   (vr "__result" result_ty))))))

(** fold_left/fold_right

    Thread one owned accumulator through direct list storage. The callback
    receives borrowed arguments and must return an owned accumulator. After the
    callback returns, the prior accumulator owner is dropped before the mutable
    slot is overwritten. [CDrop] is type-aware during emission, so primitive
    accumulators compile to a no-op while managed accumulators release exactly
    the old owner. *)
let list_fold_left self_ty acc_ty self init f =
  let elem_ty = list_elem_ty self_ty in
  let i = vr "__i" ty_int in
  let elem =
    mk elem_ty
      (CUnbox (intr "list_get" [ vr "__self" self_ty; i ] ty_ptr, elem_ty))
  in
  let step =
    lett "__next"
      (closure_call f [ vr "__acc" acc_ty; elem ] acc_ty)
      (assign "__acc" (vr "__next" acc_ty))
  in
  borrow "__self" self
    (lett "__n"
       (intr "list_len" [ vr "__self" self_ty ] ty_int)
       (lettm "__acc" init
          (seq
             (mk ty_void
                (CFor
                   ( loop "__i" ty_int,
                     mk ty_int (CRange (lit_int 0, vr "__n" ty_int)),
                     step )))
             (vr "__acc" acc_ty))))

let list_fold_right self_ty acc_ty self init f =
  let elem_ty = list_elem_ty self_ty in
  let offset = vr "__offset" ty_int in
  let i =
    bin Ast.Sub (bin Ast.Sub (vr "__n" ty_int) offset ty_int) (lit_int 1) ty_int
  in
  let elem =
    mk elem_ty
      (CUnbox (intr "list_get" [ vr "__self" self_ty; i ] ty_ptr, elem_ty))
  in
  let step =
    lett "__next"
      (closure_call f [ elem; vr "__acc" acc_ty ] acc_ty)
      (assign "__acc" (vr "__next" acc_ty))
  in
  borrow "__self" self
    (lett "__n"
       (intr "list_len" [ vr "__self" self_ty ] ty_int)
       (lettm "__acc" init
          (seq
             (mk ty_void
                (CFor
                   ( loop "__offset" ty_int,
                     mk ty_int (CRange (lit_int 0, vr "__n" ty_int)),
                     step )))
             (vr "__acc" acc_ty))))

(** all(self, predicate) -> Bool

    Direct non-allocating loop with short-circuit break on the first failed
    predicate. *)
let list_all self_ty self predicate =
  let elem_ty = list_elem_ty self_ty in
  let i = vr "__i" ty_int in
  let elem = mk elem_ty (CUnbox (vr "__raw" ty_ptr, elem_ty)) in
  let fail = seq (assign "__result" (lit_bool false)) break_ in
  let loop_body =
    lett "__raw"
      (intr "list_get" [ vr "__self" self_ty; i ] ty_ptr)
      (if_
         (bin Ast.Eq
            (closure_call predicate [ elem ] ty_bool)
            (lit_bool false) ty_bool)
         fail void ty_void)
  in
  borrow "__self" self
    (lett "__n"
       (intr "list_len" [ vr "__self" self_ty ] ty_int)
       (lettm "__result" (lit_bool true)
          (seq
             (mk ty_void
                (CFor
                   ( loop "__i" ty_int,
                     mk ty_int (CRange (lit_int 0, vr "__n" ty_int)),
                     loop_body )))
             (vr "__result" ty_bool))))

(** any(self, predicate) -> Bool

    Direct non-allocating loop with short-circuit break on the first matching
    predicate. *)
let list_any self_ty self predicate =
  let elem_ty = list_elem_ty self_ty in
  let i = vr "__i" ty_int in
  let elem = mk elem_ty (CUnbox (vr "__raw" ty_ptr, elem_ty)) in
  let succeed = seq (assign "__result" (lit_bool true)) break_ in
  let loop_body =
    lett "__raw"
      (intr "list_get" [ vr "__self" self_ty; i ] ty_ptr)
      (if_ (closure_call predicate [ elem ] ty_bool) succeed void ty_void)
  in
  borrow "__self" self
    (lett "__n"
       (intr "list_len" [ vr "__self" self_ty ] ty_int)
       (lettm "__result" (lit_bool false)
          (seq
             (mk ty_void
                (CFor
                   ( loop "__i" ty_int,
                     mk ty_int (CRange (lit_int 0, vr "__n" ty_int)),
                     loop_body )))
             (vr "__result" ty_bool))))

(** count(self, predicate) -> Int

    Direct non-allocating loop that increments a local counter for matching
    elements. *)
let list_count self_ty self predicate =
  let elem_ty = list_elem_ty self_ty in
  let i = vr "__i" ty_int in
  let elem = mk elem_ty (CUnbox (vr "__raw" ty_ptr, elem_ty)) in
  let count = vr "__count" ty_int in
  let increment = assign "__count" (bin Ast.Add count (lit_int 1) ty_int) in
  let loop_body =
    lett "__raw"
      (intr "list_get" [ vr "__self" self_ty; i ] ty_ptr)
      (if_ (closure_call predicate [ elem ] ty_bool) increment void ty_void)
  in
  borrow "__self" self
    (lett "__n"
       (intr "list_len" [ vr "__self" self_ty ] ty_int)
       (lettm "__count" (lit_int 0)
          (seq
             (mk ty_void
                (CFor
                   ( loop "__i" ty_int,
                     mk ty_int (CRange (lit_int 0, vr "__n" ty_int)),
                     loop_body )))
             (vr "__count" ty_int))))

(** for_each(self, f) -> Void

    Direct non-allocating loop for side-effecting callbacks. *)
let list_for_each self_ty self f =
  let elem_ty = list_elem_ty self_ty in
  let i = vr "__i" ty_int in
  let elem = mk elem_ty (CUnbox (vr "__raw" ty_ptr, elem_ty)) in
  let loop_body =
    lett "__raw"
      (intr "list_get" [ vr "__self" self_ty; i ] ty_ptr)
      (closure_call f [ elem ] ty_void)
  in
  borrow "__self" self
    (lett "__n"
       (intr "list_len" [ vr "__self" self_ty ] ty_int)
       (seq
          (mk ty_void
             (CFor
                ( loop "__i" ty_int,
                  mk ty_int (CRange (lit_int 0, vr "__n" ty_int)),
                  loop_body )))
          void))

(** find_index(self, predicate) -> Option[Int]

    Direct non-allocating loop with short-circuit break on the first matching
    element. *)
let list_find_index self_ty return_ty self predicate =
  let elem_ty = list_elem_ty self_ty in
  let i = vr "__i" ty_int in
  let elem = mk elem_ty (CUnbox (vr "__raw" ty_ptr, elem_ty)) in
  let found = seq (assign "__result" (option_some return_ty i)) break_ in
  let loop_body =
    lett "__raw"
      (intr "list_get" [ vr "__self" self_ty; i ] ty_ptr)
      (if_ (closure_call predicate [ elem ] ty_bool) found void ty_void)
  in
  borrow "__self" self
    (lett "__n"
       (intr "list_len" [ vr "__self" self_ty ] ty_int)
       (lettm "__result" (option_none return_ty)
          (seq
             (mk ty_void
                (CFor
                   ( loop "__i" ty_int,
                     mk ty_int (CRange (lit_int 0, vr "__n" ty_int)),
                     loop_body )))
             (vr "__result" return_ty))))

(** find(self, predicate) -> Option[T]

    Direct loop over list storage. The matching element is a borrowed alias
    from [self], so retain it with the source list's element metadata before
    transferring it into [Some]. *)
let list_find self_ty return_ty self predicate =
  let elem_ty = list_elem_ty self_ty in
  let i = vr "__i" ty_int in
  let elem = mk elem_ty (CUnbox (vr "__raw" ty_ptr, elem_ty)) in
  let found =
    seq
      (intr "list_retain_for" [ vr "__self" self_ty; elem ] ty_void)
      (seq (assign "__result" (option_some return_ty elem)) break_)
  in
  let loop_body =
    lett "__raw"
      (intr "list_get" [ vr "__self" self_ty; i ] ty_ptr)
      (if_ (closure_call predicate [ elem ] ty_bool) found void ty_void)
  in
  borrow "__self" self
    (lett "__n"
       (intr "list_len" [ vr "__self" self_ty ] ty_int)
       (lettm "__result" (option_none return_ty)
          (seq
             (mk ty_void
                (CFor
                   ( loop "__i" ty_int,
                     mk ty_int (CRange (lit_int 0, vr "__n" ty_int)),
                     loop_body )))
             (vr "__result" return_ty))))

(** binary_search(sorted, target) -> Option[Int]

    Binary search over a sorted [List[T:Orderable]]. The loop maintains [lo]
    and [hi], so every probe is in bounds and can use direct storage access
    instead of constructing an [Option] for [get(mid)]. *)
let list_binary_search self_ty return_ty sorted target =
  let elem_ty = list_elem_ty self_ty in
  let target_ty = target.ty in
  let lo = vr "__lo" ty_int in
  let hi = vr "__hi" ty_int in
  let mid = vr "__mid" ty_int in
  let elem = vr "__elem" elem_ty in
  let found = seq (assign "__result" (option_some return_ty mid)) break_ in
  let adjust_bounds =
    if_
      (bin Ast.Lt elem (vr "__target" target_ty) ty_bool)
      (assign "__lo" (bin Ast.Add mid (lit_int 1) ty_int))
      (assign "__hi" (bin Ast.Sub mid (lit_int 1) ty_int))
      ty_void
  in
  let loop_body =
    lett "__mid"
      (bin Ast.Add lo
         (bin Ast.Div (bin Ast.Sub hi lo ty_int) (lit_int 2) ty_int)
         ty_int)
      (lett "__elem"
         (mk elem_ty
            (CUnbox
               (intr "list_get" [ vr "__self" self_ty; mid ] ty_ptr, elem_ty)))
         (if_
            (bin Ast.Eq elem (vr "__target" target_ty) ty_bool)
            found adjust_bounds ty_void))
  in
  borrow "__self" sorted
    (lett "__target" target
       (lett "__n"
          (intr "list_len" [ vr "__self" self_ty ] ty_int)
          (lettm "__lo" (lit_int 0)
             (lettm "__hi"
                (bin Ast.Sub (vr "__n" ty_int) (lit_int 1) ty_int)
                (lettm "__result" (option_none return_ty)
                   (seq
                      (while_ (bin Ast.Le lo hi ty_bool) loop_body)
                      (vr "__result" return_ty)))))))

(** binary_search_by(sorted, target, compare) -> Option[Int]

    Generic binary search using a caller-provided comparator. Like
    [binary_search], the loop invariant proves probes in bounds, so it avoids
    per-probe [Option] construction. *)
let list_binary_search_by self_ty return_ty sorted target compare =
  let elem_ty = list_elem_ty self_ty in
  let target_ty = target.ty in
  let lo = vr "__lo" ty_int in
  let hi = vr "__hi" ty_int in
  let mid = vr "__mid" ty_int in
  let cmp = vr "__cmp" ty_int in
  let elem = mk elem_ty (CUnbox (vr "__raw" ty_ptr, elem_ty)) in
  let found = seq (assign "__result" (option_some return_ty mid)) break_ in
  let adjust_bounds =
    if_
      (bin Ast.Lt cmp (lit_int 0) ty_bool)
      (assign "__lo" (bin Ast.Add mid (lit_int 1) ty_int))
      (assign "__hi" (bin Ast.Sub mid (lit_int 1) ty_int))
      ty_void
  in
  let loop_body =
    lett "__mid"
      (bin Ast.Add lo
         (bin Ast.Div (bin Ast.Sub hi lo ty_int) (lit_int 2) ty_int)
         ty_int)
      (lett "__raw"
         (intr "list_get" [ vr "__self" self_ty; mid ] ty_ptr)
         (lett "__cmp"
            (closure_call
               (vr "__compare" compare.ty)
               [ elem; vr "__target" target_ty ]
               ty_int)
            (if_
               (bin Ast.Eq cmp (lit_int 0) ty_bool)
               found adjust_bounds ty_void)))
  in
  borrow "__self" sorted
    (lett "__target" target
       (lett "__compare" compare
          (lett "__n"
             (intr "list_len" [ vr "__self" self_ty ] ty_int)
             (lettm "__lo" (lit_int 0)
                (lettm "__hi"
                   (bin Ast.Sub (vr "__n" ty_int) (lit_int 1) ty_int)
                   (lettm "__result" (option_none return_ty)
                      (seq
                         (while_ (bin Ast.Le lo hi ty_bool) loop_body)
                         (vr "__result" return_ty))))))))

(** min_by/max_by(self, score) -> Option[T]

    Scan direct list storage while tracking the best index and best key. The
    selected element is loaded and retained once after the scan, avoiding
    repeated [Option] allocation and mutable managed element accumulators. *)
let list_min_max_by self_ty key_ty return_ty self score_fn compare_op =
  let elem_ty = list_elem_ty self_ty in
  let i = vr "__i" ty_int in
  let elem = mk elem_ty (CUnbox (vr "__raw" ty_ptr, elem_ty)) in
  let score = vr "__score" key_ty in
  let update_existing = seq (assign "__best_i" i) (assign "__best_val" score) in
  let better = bin compare_op score (vr "__best_val" key_ty) ty_bool in
  let loop_body =
    lett "__raw"
      (intr "list_get" [ vr "__self" self_ty; i ] ty_ptr)
      (lett "__score"
         (closure_call score_fn [ elem ] key_ty)
         (if_ better update_existing void ty_void))
  in
  let selected =
    lett "__best_raw"
      (intr "list_get" [ vr "__self" self_ty; vr "__best_i" ty_int ] ty_ptr)
      (let best_elem = mk elem_ty (CUnbox (vr "__best_raw" ty_ptr, elem_ty)) in
       seq
         (intr "list_retain_for" [ vr "__self" self_ty; best_elem ] ty_void)
         (option_some return_ty best_elem))
  in
  let scan_loop =
    mk ty_void
      (CFor
         ( loop "__i" ty_int,
           mk ty_int (CRange (lit_int 1, vr "__n" ty_int)),
           loop_body ))
  in
  borrow "__self" self
    (lett "__n"
       (intr "list_len" [ vr "__self" self_ty ] ty_int)
       (if_
          (bin Ast.Eq (vr "__n" ty_int) (lit_int 0) ty_bool)
          (option_none return_ty)
          (lett "__first_raw"
             (intr "list_get" [ vr "__self" self_ty; lit_int 0 ] ty_ptr)
             (let first_elem =
                mk elem_ty (CUnbox (vr "__first_raw" ty_ptr, elem_ty))
              in
              lettm "__best_i" (lit_int 0)
                (lettm "__best_val"
                   (closure_call score_fn [ first_elem ] key_ty)
                   (seq scan_loop selected))))
          return_ty))

(** sort_by/sort_desc_by(self, key_fn) -> List[T]

    Stable bottom-up merge sort over primitive index buffers:
    - compute each key exactly once into a key list,
    - merge Int indexes only, so managed values/keys are never moved through
      mutable scratch buffers,
    - materialize the output once by retaining source elements in sorted order,
    - compare keys through normal Core operators so trait resolution handles
      non-primitive [Orderable] keys and primitives keep the direct fast path.

    [compare_op] is [Le] for ascending and [Ge] for descending. Using the
    non-strict comparison keeps equal-key elements in their original order. *)
let list_sort_by self_ty key_ty self key_fn compare_op =
  let alloc = list_alloc_intrinsic "sort_by" in
  let elem_ty = list_elem_ty self_ty in
  let key_list_ty = Ast.TyNamed ("List", [ key_ty ]) in
  let index_list_ty = Ast.TyNamed ("List", [ ty_int ]) in
  let n = vr "__n" ty_int in
  let width = vr "__width" ty_int in
  let left = vr "__left" ty_int in
  let i = vr "__i" ty_int in
  let j = vr "__j" ty_int in
  let out = vr "__out" ty_int in
  let min_int a b = if_ (bin Ast.Lt a b ty_bool) a b ty_int in
  let two_width = bin Ast.Mul width (lit_int 2) ty_int in
  let move_index source_list dest_list source_i =
    lett "__move_idx_raw"
      (intr "list_get_unchecked"
         [ vr source_list index_list_ty; source_i ]
         ty_ptr)
      (lett "__move_idx"
         (mk ty_int (CUnbox (vr "__move_idx_raw" ty_ptr, ty_int)))
         (intr "list_set"
            [ vr dest_list index_list_ty; out; vr "__move_idx" ty_int ]
            ty_void))
  in
  let list_value list_expr index elem_ty =
    mk elem_ty
      (CUnbox (intr "list_get_unchecked" [ list_expr; index ] ty_ptr, elem_ty))
  in
  let preload_body =
    let elem = list_value (vr "__self" self_ty) i elem_ty in
    lett "__key"
      (closure_call key_fn [ elem ] key_ty)
      (seq
         (intr "list_set" [ vr "__idx_a" index_list_ty; i; i ] ty_void)
         (seq
            (intr "list_set_owned"
               [ vr "__keys" key_list_ty; i; vr "__key" key_ty ]
               ty_void)
            void))
  in
  let preload_loop =
    mk ty_void
      (CFor (loop "__i" ty_int, mk ty_int (CRange (lit_int 0, n)), preload_body))
  in
  let bind_index source_list source_i raw_name idx_name body =
    lett raw_name
      (intr "list_get_unchecked"
         [ vr source_list index_list_ty; source_i ]
         ty_ptr)
      (lett idx_name (mk ty_int (CUnbox (vr raw_name ty_ptr, ty_int))) body)
  in
  let key_value idx_name =
    list_value (vr "__keys" key_list_ty) (vr idx_name ty_int) key_ty
  in
  let take_left source_list =
    bind_index source_list i "__left_idx_raw" "__left_idx"
      (bind_index source_list j "__right_idx_raw" "__right_idx"
         (bin compare_op (key_value "__left_idx") (key_value "__right_idx")
            ty_bool))
  in
  let move_left source_list dest_list =
    seq
      (move_index source_list dest_list i)
      (assign "__i" (bin Ast.Add i (lit_int 1) ty_int))
  in
  let move_right source_list dest_list =
    seq
      (move_index source_list dest_list j)
      (assign "__j" (bin Ast.Add j (lit_int 1) ty_int))
  in
  let merge_step source_list dest_list =
    seq
      (if_ (take_left source_list)
         (move_left source_list dest_list)
         (move_right source_list dest_list)
         ty_void)
      (assign "__out" (bin Ast.Add out (lit_int 1) ty_int))
  in
  let merge_loop source_list dest_list =
    while_
      (log Ast.And
         (bin Ast.Lt i (vr "__mid" ty_int) ty_bool)
         (bin Ast.Lt j (vr "__right" ty_int) ty_bool))
      (merge_step source_list dest_list)
  in
  let drain_left source_list dest_list =
    while_
      (bin Ast.Lt i (vr "__mid" ty_int) ty_bool)
      (seq
         (move_index source_list dest_list i)
         (seq
            (assign "__i" (bin Ast.Add i (lit_int 1) ty_int))
            (assign "__out" (bin Ast.Add out (lit_int 1) ty_int))))
  in
  let drain_right source_list dest_list =
    while_
      (bin Ast.Lt j (vr "__right" ty_int) ty_bool)
      (seq
         (move_index source_list dest_list j)
         (seq
            (assign "__j" (bin Ast.Add j (lit_int 1) ty_int))
            (assign "__out" (bin Ast.Add out (lit_int 1) ty_int))))
  in
  let merge_run source_list dest_list =
    lett "__mid"
      (min_int (bin Ast.Add left width ty_int) n)
      (lett "__right"
         (min_int (bin Ast.Add left two_width ty_int) n)
         (lettm "__i" left
            (lettm "__j" (vr "__mid" ty_int)
               (lettm "__out" left
                  (seq
                     (merge_loop source_list dest_list)
                     (seq
                        (drain_left source_list dest_list)
                        (seq
                           (drain_right source_list dest_list)
                           (assign "__left" (bin Ast.Add left two_width ty_int)))))))))
  in
  let merge_pass source_list dest_list =
    lettm "__left" (lit_int 0)
      (seq
         (while_ (bin Ast.Lt left n ty_bool) (merge_run source_list dest_list))
         (seq
            (intr "list_set_len" [ vr dest_list index_list_ty; n ] ty_void)
            (seq
               (assign "__from_a"
                  (if_ (vr "__from_a" ty_bool) (lit_bool false) (lit_bool true)
                     ty_bool))
               (assign "__width" (bin Ast.Mul width (lit_int 2) ty_int)))))
  in
  let sort_loop =
    while_
      (bin Ast.Lt width n ty_bool)
      (if_ (vr "__from_a" ty_bool)
         (merge_pass "__idx_a" "__idx_b")
         (merge_pass "__idx_b" "__idx_a")
         ty_void)
  in
  let fill_result source_list =
    let fill_body =
      lett "__sorted_idx_raw"
        (intr "list_get_unchecked" [ vr source_list index_list_ty; i ] ty_ptr)
        (lett "__sorted_idx"
           (mk ty_int (CUnbox (vr "__sorted_idx_raw" ty_ptr, ty_int)))
           (let elem =
              list_value (vr "__self" self_ty) (vr "__sorted_idx" ty_int)
                elem_ty
            in
            seq
              (intr "list_retain_for" [ vr "__result" self_ty; elem ] ty_void)
              (intr "list_set_owned" [ vr "__result" self_ty; i; elem ] ty_void)))
    in
    let fill_loop =
      mk ty_void
        (CFor (loop "__i" ty_int, mk ty_int (CRange (lit_int 0, n)), fill_body))
    in
    fill_loop
  in
  let finish =
    lett "__result" (intr alloc [ n ] self_ty)
      (seq
         (if_ (vr "__from_a" ty_bool) (fill_result "__idx_a")
            (fill_result "__idx_b") ty_void)
         (seq
            (intr "list_set_len" [ vr "__result" self_ty; n ] ty_void)
            (vr "__result" self_ty)))
  in
  let sort_body =
    lettm "__keys"
      (intr alloc [ n ] key_list_ty)
      (lettm "__idx_a"
         (intr alloc [ n ] index_list_ty)
         (lettm "__idx_b"
            (intr alloc [ n ] index_list_ty)
            (lettm "__width" (lit_int 1)
               (lettm "__from_a" (lit_bool true)
                  (seq preload_loop
                     (seq
                        (intr "list_set_len"
                           [ vr "__keys" key_list_ty; n ]
                           ty_void)
                        (seq
                           (intr "list_set_len"
                              [ vr "__idx_a" index_list_ty; n ]
                              ty_void)
                           (seq sort_loop finish))))))))
  in
  borrow "__self" self
    (lett "__n" (intr "list_len" [ vr "__self" self_ty ] ty_int) sort_body)

(** sort(self) -> List[T]

    Stable bottom-up merge sort over primitive index buffers. Unlike the old
    std implementation, this never recursively allocates [take]/[drop] slices
    and never builds the output through repeated [append] growth. The source
    elements stay in place while Int indexes are merged, then the result is
    materialized once by retaining source elements in sorted order. *)
let list_sort self_ty self compare_op =
  let alloc = list_alloc_intrinsic "sort" in
  let elem_ty = list_elem_ty self_ty in
  let index_list_ty = Ast.TyNamed ("List", [ ty_int ]) in
  let n = vr "__n" ty_int in
  let width = vr "__width" ty_int in
  let left = vr "__left" ty_int in
  let i = vr "__i" ty_int in
  let j = vr "__j" ty_int in
  let out = vr "__out" ty_int in
  let min_int a b = if_ (bin Ast.Lt a b ty_bool) a b ty_int in
  let two_width = bin Ast.Mul width (lit_int 2) ty_int in
  let move_index source_list dest_list source_i =
    lett "__move_idx_raw"
      (intr "list_get_unchecked"
         [ vr source_list index_list_ty; source_i ]
         ty_ptr)
      (lett "__move_idx"
         (mk ty_int (CUnbox (vr "__move_idx_raw" ty_ptr, ty_int)))
         (intr "list_set"
            [ vr dest_list index_list_ty; out; vr "__move_idx" ty_int ]
            ty_void))
  in
  let preload_loop =
    mk ty_void
      (CFor
         ( loop "__i" ty_int,
           mk ty_int (CRange (lit_int 0, n)),
           intr "list_set" [ vr "__idx_a" index_list_ty; i; i ] ty_void ))
  in
  let bind_index source_list source_i raw_name idx_name body =
    lett raw_name
      (intr "list_get_unchecked"
         [ vr source_list index_list_ty; source_i ]
         ty_ptr)
      (lett idx_name (mk ty_int (CUnbox (vr raw_name ty_ptr, ty_int))) body)
  in
  let elem_from_raw raw_name =
    mk elem_ty (CUnbox (vr raw_name ty_ptr, elem_ty))
  in
  let bind_elem_raw idx_name raw_name body =
    lett raw_name
      (intr "list_get_unchecked"
         [ vr "__self" self_ty; vr idx_name ty_int ]
         ty_ptr)
      body
  in
  let take_left source_list =
    bind_index source_list i "__left_idx_raw" "__left_idx"
      (bind_index source_list j "__right_idx_raw" "__right_idx"
         (bind_elem_raw "__left_idx" "__left_elem_raw"
            (bind_elem_raw "__right_idx" "__right_elem_raw"
               (bin compare_op
                  (elem_from_raw "__left_elem_raw")
                  (elem_from_raw "__right_elem_raw")
                  ty_bool))))
  in
  let move_left source_list dest_list =
    seq
      (move_index source_list dest_list i)
      (assign "__i" (bin Ast.Add i (lit_int 1) ty_int))
  in
  let move_right source_list dest_list =
    seq
      (move_index source_list dest_list j)
      (assign "__j" (bin Ast.Add j (lit_int 1) ty_int))
  in
  let merge_step source_list dest_list =
    seq
      (if_ (take_left source_list)
         (move_left source_list dest_list)
         (move_right source_list dest_list)
         ty_void)
      (assign "__out" (bin Ast.Add out (lit_int 1) ty_int))
  in
  let merge_loop source_list dest_list =
    while_
      (log Ast.And
         (bin Ast.Lt i (vr "__mid" ty_int) ty_bool)
         (bin Ast.Lt j (vr "__right" ty_int) ty_bool))
      (merge_step source_list dest_list)
  in
  let drain_left source_list dest_list =
    while_
      (bin Ast.Lt i (vr "__mid" ty_int) ty_bool)
      (seq
         (move_index source_list dest_list i)
         (seq
            (assign "__i" (bin Ast.Add i (lit_int 1) ty_int))
            (assign "__out" (bin Ast.Add out (lit_int 1) ty_int))))
  in
  let drain_right source_list dest_list =
    while_
      (bin Ast.Lt j (vr "__right" ty_int) ty_bool)
      (seq
         (move_index source_list dest_list j)
         (seq
            (assign "__j" (bin Ast.Add j (lit_int 1) ty_int))
            (assign "__out" (bin Ast.Add out (lit_int 1) ty_int))))
  in
  let merge_run source_list dest_list =
    lett "__mid"
      (min_int (bin Ast.Add left width ty_int) n)
      (lett "__right"
         (min_int (bin Ast.Add left two_width ty_int) n)
         (lettm "__i" left
            (lettm "__j" (vr "__mid" ty_int)
               (lettm "__out" left
                  (seq
                     (merge_loop source_list dest_list)
                     (seq
                        (drain_left source_list dest_list)
                        (seq
                           (drain_right source_list dest_list)
                           (assign "__left" (bin Ast.Add left two_width ty_int)))))))))
  in
  let merge_pass source_list dest_list =
    lettm "__left" (lit_int 0)
      (seq
         (while_ (bin Ast.Lt left n ty_bool) (merge_run source_list dest_list))
         (seq
            (intr "list_set_len" [ vr dest_list index_list_ty; n ] ty_void)
            (seq
               (assign "__from_a"
                  (if_ (vr "__from_a" ty_bool) (lit_bool false) (lit_bool true)
                     ty_bool))
               (assign "__width" (bin Ast.Mul width (lit_int 2) ty_int)))))
  in
  let sort_loop =
    while_
      (bin Ast.Lt width n ty_bool)
      (if_ (vr "__from_a" ty_bool)
         (merge_pass "__idx_a" "__idx_b")
         (merge_pass "__idx_b" "__idx_a")
         ty_void)
  in
  let fill_result source_list =
    let fill_body =
      lett "__sorted_idx_raw"
        (intr "list_get_unchecked" [ vr source_list index_list_ty; i ] ty_ptr)
        (lett "__sorted_idx"
           (mk ty_int (CUnbox (vr "__sorted_idx_raw" ty_ptr, ty_int)))
           (lett "__elem_raw"
              (intr "list_get_unchecked"
                 [ vr "__self" self_ty; vr "__sorted_idx" ty_int ]
                 ty_ptr)
              (let elem =
                 mk elem_ty (CUnbox (vr "__elem_raw" ty_ptr, elem_ty))
               in
               seq
                 (intr "list_retain_for"
                    [ vr "__result" self_ty; elem ]
                    ty_void)
                 (intr "list_set_owned"
                    [ vr "__result" self_ty; i; elem ]
                    ty_void))))
    in
    mk ty_void
      (CFor (loop "__i" ty_int, mk ty_int (CRange (lit_int 0, n)), fill_body))
  in
  let finish =
    lett "__result" (intr alloc [ n ] self_ty)
      (seq
         (if_ (vr "__from_a" ty_bool) (fill_result "__idx_a")
            (fill_result "__idx_b") ty_void)
         (seq
            (intr "list_set_len" [ vr "__result" self_ty; n ] ty_void)
            (vr "__result" self_ty)))
  in
  let sort_body =
    lettm "__idx_a"
      (intr alloc [ n ] index_list_ty)
      (lettm "__idx_b"
         (intr alloc [ n ] index_list_ty)
         (lettm "__width" (lit_int 1)
            (lettm "__from_a" (lit_bool true)
               (seq preload_loop
                  (seq
                     (intr "list_set_len"
                        [ vr "__idx_a" index_list_ty; n ]
                        ty_void)
                     (seq sort_loop finish))))))
  in
  borrow "__self" self
    (lett "__n" (intr "list_len" [ vr "__self" self_ty ] ty_int) sort_body)

(** scan(self, init, f) -> List[A]

    Allocate exactly [length(self) + 1]. Slot 0 owns [init]; each later slot
    owns the callback result for the prior accumulator and current element.
    The prior accumulator is read back from the result list as a borrowed
    alias, so callbacks that return it directly rely on the closure ABI's
    owned-return rule. *)
let list_scan self_ty result_ty self init f =
  let alloc = list_alloc_intrinsic "scan" in
  let elem_ty = list_elem_ty self_ty in
  let acc_ty = list_elem_ty result_ty in
  let i = vr "__i" ty_int in
  let out_i = bin Ast.Add i (lit_int 1) ty_int in
  let result_len = bin Ast.Add (vr "__n" ty_int) (lit_int 1) ty_int in
  let prev =
    mk acc_ty
      (CUnbox (intr "list_get" [ vr "__result" result_ty; i ] ty_ptr, acc_ty))
  in
  let elem =
    mk elem_ty
      (CUnbox (intr "list_get" [ vr "__self" self_ty; i ] ty_ptr, elem_ty))
  in
  let loop_body =
    lett "__next"
      (closure_call f [ prev; elem ] acc_ty)
      (seq
         (intr "list_set_owned"
            [ vr "__result" result_ty; out_i; vr "__next" acc_ty ]
            ty_void)
         (intr "list_set_len"
            [ vr "__result" result_ty; bin Ast.Add out_i (lit_int 1) ty_int ]
            ty_void))
  in
  let scan_loop =
    mk ty_void
      (CFor
         ( loop "__i" ty_int,
           mk ty_int (CRange (lit_int 0, vr "__n" ty_int)),
           loop_body ))
  in
  borrow "__self" self
    (lett "__n"
       (intr "list_len" [ vr "__self" self_ty ] ty_int)
       (lett "__init" init
          (lett "__result"
             (intr alloc [ result_len ] result_ty)
             (seq
                (intr "list_set_owned"
                   [ vr "__result" result_ty; lit_int 0; vr "__init" acc_ty ]
                   ty_void)
                (seq
                   (intr "list_set_len"
                      [ vr "__result" result_ty; lit_int 1 ]
                      ty_void)
                   (seq scan_loop (vr "__result" result_ty)))))))

(** enumerate(self) -> List[(Int, T)]

    Allocate exactly [length(self)] and fill each slot with a freshly produced
    tuple. This keeps the output list materialization explicit in Core and
    avoids repeatedly appending through the source-level implementation. *)
let list_enumerate self_ty result_ty self =
  let alloc = list_alloc_intrinsic "enumerate" in
  let elem_ty = list_elem_ty self_ty in
  let result_elem_ty = list_elem_ty result_ty in
  let i = vr "__i" ty_int in
  let loop_body =
    lett "__raw"
      (intr "list_get" [ vr "__self" self_ty; i ] ty_ptr)
      (let elem = mk elem_ty (CUnbox (vr "__raw" ty_ptr, elem_ty)) in
       let pair = mk result_elem_ty (CTuple [ i; elem ]) in
       lett "__pair" pair
         (intr "list_set_owned"
            [ vr "__result" result_ty; i; vr "__pair" result_elem_ty ]
            ty_void))
  in
  let fill_loop =
    mk ty_void
      (CFor
         ( loop "__i" ty_int,
           mk ty_int (CRange (lit_int 0, vr "__n" ty_int)),
           loop_body ))
  in
  borrow "__self" self
    (lett "__n"
       (intr "list_len" [ vr "__self" self_ty ] ty_int)
       (lett "__result"
          (intr alloc [ vr "__n" ty_int ] result_ty)
          (seq fill_loop
             (seq
                (intr "list_set_len"
                   [ vr "__result" result_ty; vr "__n" ty_int ]
                   ty_void)
                (vr "__result" result_ty)))))

(** zip(list_a, list_b) -> List[(A, B)]

    Allocate exactly [min(length(a), length(b))] and fill each slot with a
    freshly produced tuple. Tuple field retains are handled by tuple emission
    from the direct borrowed [CUnbox] field expressions. *)
let list_zip list_a_ty list_b_ty result_ty list_a list_b =
  let alloc = list_alloc_intrinsic "zip" in
  let elem_a_ty = list_elem_ty list_a_ty in
  let elem_b_ty = list_elem_ty list_b_ty in
  let result_elem_ty = list_elem_ty result_ty in
  let i = vr "__i" ty_int in
  let loop_body =
    lett "__raw_a"
      (intr "list_get" [ vr "__list_a" list_a_ty; i ] ty_ptr)
      (lett "__raw_b"
         (intr "list_get" [ vr "__list_b" list_b_ty; i ] ty_ptr)
         (let elem_a = mk elem_a_ty (CUnbox (vr "__raw_a" ty_ptr, elem_a_ty)) in
          let elem_b = mk elem_b_ty (CUnbox (vr "__raw_b" ty_ptr, elem_b_ty)) in
          let pair = mk result_elem_ty (CTuple [ elem_a; elem_b ]) in
          lett "__pair" pair
            (intr "list_set_owned"
               [ vr "__result" result_ty; i; vr "__pair" result_elem_ty ]
               ty_void)))
  in
  let fill_loop =
    mk ty_void
      (CFor
         ( loop "__i" ty_int,
           mk ty_int (CRange (lit_int 0, vr "__n" ty_int)),
           loop_body ))
  in
  lett "__list_a" list_a
    (lett "__list_b" list_b
       (lett "__len_a"
          (intr "list_len" [ vr "__list_a" list_a_ty ] ty_int)
          (lett "__len_b"
             (intr "list_len" [ vr "__list_b" list_b_ty ] ty_int)
             (lett "__n"
                (mk ty_int
                   (CIf
                      ( bin Ast.Lt (vr "__len_b" ty_int) (vr "__len_a" ty_int)
                          ty_bool,
                        vr "__len_b" ty_int,
                        vr "__len_a" ty_int )))
                (lett "__result"
                   (intr alloc [ vr "__n" ty_int ] result_ty)
                   (seq fill_loop
                      (seq
                         (intr "list_set_len"
                            [ vr "__result" result_ty; vr "__n" ty_int ]
                            ty_void)
                         (vr "__result" result_ty))))))))

(** zip_with(list_a, list_b, f) -> List[C]

    Allocate exactly [min(length(a), length(b))], then fill by index. *)
let list_zip_with list_a_ty list_b_ty result_ty list_a list_b f =
  let alloc = list_alloc_intrinsic "zip_with" in
  let elem_a_ty = list_elem_ty list_a_ty in
  let elem_b_ty = list_elem_ty list_b_ty in
  let result_elem_ty = list_elem_ty result_ty in
  let i = vr "__i" ty_int in
  let elem_a = mk elem_a_ty (CUnbox (vr "__raw_a" ty_ptr, elem_a_ty)) in
  let elem_b = mk elem_b_ty (CUnbox (vr "__raw_b" ty_ptr, elem_b_ty)) in
  let mapped = closure_call f [ elem_a; elem_b ] result_elem_ty in
  let loop_body =
    lett "__raw_a"
      (intr "list_get" [ vr "__list_a" list_a_ty; i ] ty_ptr)
      (lett "__raw_b"
         (intr "list_get" [ vr "__list_b" list_b_ty; i ] ty_ptr)
         (lett "__mapped" mapped
            (intr "list_set_owned"
               [ vr "__result" result_ty; i; vr "__mapped" result_elem_ty ]
               ty_void)))
  in
  let fill_loop =
    mk ty_void
      (CFor
         ( loop "__i" ty_int,
           mk ty_int (CRange (lit_int 0, vr "__n" ty_int)),
           loop_body ))
  in
  lett "__list_a" list_a
    (lett "__list_b" list_b
       (lett "__len_a"
          (intr "list_len" [ vr "__list_a" list_a_ty ] ty_int)
          (lett "__len_b"
             (intr "list_len" [ vr "__list_b" list_b_ty ] ty_int)
             (lett "__n"
                (mk ty_int
                   (CIf
                      ( bin Ast.Lt (vr "__len_b" ty_int) (vr "__len_a" ty_int)
                          ty_bool,
                        vr "__len_b" ty_int,
                        vr "__len_a" ty_int )))
                (lett "__result"
                   (intr alloc [ vr "__n" ty_int ] result_ty)
                   (seq fill_loop
                      (seq
                         (intr "list_set_len"
                            [ vr "__result" result_ty; vr "__n" ty_int ]
                            ty_void)
                         (vr "__result" result_ty))))))))

(** unzip(self) -> (List[A], List[B])

    Allocate both output lists at the exact input length. Each source tuple is
    borrowed from [self], so tuple fields are retained for the destination list
    before being stored with the non-consuming slot writer. *)
let list_unzip self_ty return_ty self =
  let alloc = list_alloc_intrinsic "unzip" in
  let pair_ty = list_elem_ty self_ty in
  let elem_a_ty, elem_b_ty =
    match pair_ty with Ast.TyTuple [ a; b ] -> (a, b) | _ -> (ty_ptr, ty_ptr)
  in
  let firsts_ty, seconds_ty =
    match return_ty with
    | Ast.TyTuple [ a; b ] -> (a, b)
    | _ ->
        ( Ast.TyNamed ("List", [ elem_a_ty ]),
          Ast.TyNamed ("List", [ elem_b_ty ]) )
  in
  let i = vr "__i" ty_int in
  let pair = mk pair_ty (CUnbox (vr "__raw" ty_ptr, pair_ty)) in
  let first = mk elem_a_ty (CField (pair, "0")) in
  let second = mk elem_b_ty (CField (pair, "1")) in
  let loop_body =
    lett "__raw"
      (intr "list_get" [ vr "__self" self_ty; i ] ty_ptr)
      (seq
         (intr "list_retain_for" [ vr "__firsts" firsts_ty; first ] ty_void)
         (seq
            (intr "list_set" [ vr "__firsts" firsts_ty; i; first ] ty_void)
            (seq
               (intr "list_retain_for"
                  [ vr "__seconds" seconds_ty; second ]
                  ty_void)
               (intr "list_set"
                  [ vr "__seconds" seconds_ty; i; second ]
                  ty_void))))
  in
  let fill_loop =
    mk ty_void
      (CFor
         ( loop "__i" ty_int,
           mk ty_int (CRange (lit_int 0, vr "__n" ty_int)),
           loop_body ))
  in
  borrow "__self" self
    (lett "__n"
       (intr "list_len" [ vr "__self" self_ty ] ty_int)
       (lett "__firsts"
          (intr alloc [ vr "__n" ty_int ] firsts_ty)
          (lett "__seconds"
             (intr alloc [ vr "__n" ty_int ] seconds_ty)
             (seq fill_loop
                (seq
                   (intr "list_set_len"
                      [ vr "__firsts" firsts_ty; vr "__n" ty_int ]
                      ty_void)
                   (seq
                      (intr "list_set_len"
                         [ vr "__seconds" seconds_ty; vr "__n" ty_int ]
                         ty_void)
                      (mk return_ty
                         (CTuple
                            [
                              vr "__firsts" firsts_ty; vr "__seconds" seconds_ty;
                            ]))))))))

(* ================================================================
   String IR bodies
   ================================================================ *)

(* ty_bool defined in helpers section above *)

let string_copy_bytes dst dst_pos src src_pos len =
  intr "string_copy_bytes" [ dst; dst_pos; src; src_pos; len ] ty_void

let string_find_byte_from src byte start =
  intr "string_find_byte_from" [ src; byte; start ] ty_int

(** replace(self, old, new) -> String

    Two-pass exact-size replacement:
    - first pass counts non-overlapping matches of [old]
    - second pass writes directly into one freshly allocated output string

    Empty [old] and no-match cases return [self], matching std source
    semantics while avoiding split/join allocation. *)
let string_replace self old_ new_ =
  let slen = vr "__replace_slen" ty_int in
  let old_len = vr "__replace_old_len" ty_int in
  let new_len = vr "__replace_new_len" ty_int in
  let match_count = vr "__replace_match_count" ty_int in
  let scan_pos = vr "__replace_pos" ty_int in
  let in_pos = vr "__replace_in_pos" ty_int in
  let out_pos = vr "__replace_out_pos" ty_int in
  let out_len = vr "__replace_out_len" ty_int in
  let segment_start = vr "__replace_segment_start" ty_int in
  let segment_len = vr "__replace_segment_len" ty_int in
  let final_segment_len = vr "__replace_final_segment_len" ty_int in
  let result = vr "__replace_result" ty_string in
  let match_var = vr "__replace_match" ty_bool in
  let can_match = vr "__replace_can_match" ty_bool in
  let j = vr "__replace_j" ty_int in
  let byte_at s idx = intr "string_get_byte" [ s; idx ] ty_int in
  let compare_old_at pos =
    mk ty_void
      (CFor
         ( loop "__replace_j" ty_int,
           mk ty_int (CRange (lit_int 0, old_len)),
           mk ty_void
             (CIf
                ( bin Ast.Ne
                    (byte_at self (bin Ast.Add pos j ty_int))
                    (byte_at old_ j) ty_bool,
                  seq (assign "__replace_match" (lit_bool false)) break_,
                  void )) ))
  in
  let count_loop =
    while_
      (bin Ast.Le (bin Ast.Add scan_pos old_len ty_int) slen ty_bool)
      (lettm "__replace_match" (lit_bool true)
         (seq (compare_old_at scan_pos)
            (mk ty_void
               (CIf
                  ( match_var,
                    seq
                      (assign "__replace_match_count"
                         (bin Ast.Add match_count (lit_int 1) ty_int))
                      (assign "__replace_pos"
                         (bin Ast.Add scan_pos old_len ty_int)),
                    assign "__replace_pos"
                      (bin Ast.Add scan_pos (lit_int 1) ty_int) )))))
  in
  let copy_replacement =
    string_copy_bytes result out_pos new_ (lit_int 0) new_len
  in
  let copy_source_segment len =
    string_copy_bytes result out_pos self segment_start len
  in
  let advance_past_match =
    let next_in = bin Ast.Add in_pos old_len ty_int in
    seq
      (assign "__replace_segment_start" next_in)
      (assign "__replace_in_pos" next_in)
  in
  let copy_current_segment_and_replacement =
    lett "__replace_segment_len"
      (bin Ast.Sub in_pos segment_start ty_int)
      (seq
         (copy_source_segment segment_len)
         (seq
            (assign "__replace_out_pos"
               (bin Ast.Add out_pos segment_len ty_int))
            (seq copy_replacement
               (seq
                  (assign "__replace_out_pos"
                     (bin Ast.Add out_pos new_len ty_int))
                  advance_past_match))))
  in
  let advance_one_byte =
    assign "__replace_in_pos" (bin Ast.Add in_pos (lit_int 1) ty_int)
  in
  let fill_loop =
    while_
      (bin Ast.Lt in_pos slen ty_bool)
      (lett "__replace_can_match"
         (bin Ast.Le (bin Ast.Add in_pos old_len ty_int) slen ty_bool)
         (lettm "__replace_match" can_match
            (seq
               (mk ty_void (CIf (can_match, compare_old_at in_pos, void)))
               (mk ty_void
                  (CIf
                     ( match_var,
                       copy_current_segment_and_replacement,
                       advance_one_byte ))))))
  in
  let copy_final_segment =
    lett "__replace_final_segment_len"
      (bin Ast.Sub slen segment_start ty_int)
      (copy_source_segment final_segment_len)
  in
  let build_result =
    lett "__replace_out_len"
      (bin Ast.Add slen
         (bin Ast.Mul match_count (bin Ast.Sub new_len old_len ty_int) ty_int)
         ty_int)
      (lett "__replace_result"
         (intr "string_alloc" [ out_len ] ty_string)
         (lettm "__replace_in_pos" (lit_int 0)
            (lettm "__replace_out_pos" (lit_int 0)
               (lettm "__replace_segment_start" (lit_int 0)
                  (seq fill_loop
                     (seq copy_final_segment
                        (seq
                           (intr "string_set_len" [ result; out_len ] ty_void)
                           result)))))))
  in
  let after_count =
    if_ (bin Ast.Eq match_count (lit_int 0) ty_bool) self build_result ty_string
  in
  let replace_body =
    lett "__replace_new_len"
      (intr "string_len" [ new_ ] ty_int)
      (lettm "__replace_match_count" (lit_int 0)
         (lettm "__replace_pos" (lit_int 0) (seq count_loop after_count)))
  in
  lett "__replace_slen"
    (intr "string_len" [ self ] ty_int)
    (lett "__replace_old_len"
       (intr "string_len" [ old_ ] ty_int)
       (if_
          (bin Ast.Eq old_len (lit_int 0) ty_bool)
          self replace_body ty_string))

(** split(self, delim) -> List[String]

    Two-pass exact-size split:
    - first pass counts non-overlapping delimiter matches
    - second pass allocates one output list and copies each segment once

    Empty [delim] returns a one-element list containing [self], matching the
    std source semantics without teaching emitters about split. *)
let string_split return_ty self delim =
  let single_byte_find_min_len = 256 in
  let slen = vr "__split_slen" ty_int in
  let dlen = vr "__split_dlen" ty_int in
  let part_count = vr "__split_part_count" ty_int in
  let count_pos = vr "__split_count_pos" ty_int in
  let fill_pos = vr "__split_fill_pos" ty_int in
  let segment_start = vr "__split_segment_start" ty_int in
  let segment_len = vr "__split_segment_len" ty_int in
  let final_segment_len = vr "__split_final_segment_len" ty_int in
  let out_index = vr "__split_out_index" ty_int in
  let result = vr "__split_result" return_ty in
  let delim_byte = vr "__split_delim_byte" ty_int in
  let found_pos = vr "__split_found_pos" ty_int in
  let match_var = vr "__split_match" ty_bool in
  let j = vr "__split_j" ty_int in
  let byte_at s idx = intr "string_get_byte" [ s; idx ] ty_int in
  let compare_delim_at pos =
    mk ty_void
      (CFor
         ( loop "__split_j" ty_int,
           mk ty_int (CRange (lit_int 0, dlen)),
           mk ty_void
             (CIf
                ( bin Ast.Ne
                    (byte_at self (bin Ast.Add pos j ty_int))
                    (byte_at delim j) ty_bool,
                  seq (assign "__split_match" (lit_bool false)) break_,
                  void )) ))
  in
  let segment_copy ~name start len =
    let segment = vr name ty_string in
    lett name
      (intr "string_alloc" [ len ] ty_string)
      (seq
         (string_copy_bytes segment (lit_int 0) self start len)
         (seq (intr "string_set_len" [ segment; len ] ty_void) segment))
  in
  let delimiter_fits_at pos =
    bin Ast.Le (bin Ast.Add pos dlen ty_int) slen ty_bool
  in
  let count_loop =
    while_
      (delimiter_fits_at count_pos)
      (lettm "__split_match" (lit_bool true)
         (seq
            (compare_delim_at count_pos)
            (mk ty_void
               (CIf
                  ( match_var,
                    seq
                      (assign "__split_part_count"
                         (bin Ast.Add part_count (lit_int 1) ty_int))
                      (assign "__split_count_pos"
                         (bin Ast.Add count_pos dlen ty_int)),
                    assign "__split_count_pos"
                      (bin Ast.Add count_pos (lit_int 1) ty_int) )))))
  in
  let one_byte_count_loop =
    while_
      (bin Ast.Lt count_pos slen ty_bool)
      (lett "__split_found_pos"
         (string_find_byte_from self delim_byte count_pos)
         (mk ty_void
            (CIf
               ( bin Ast.Lt found_pos (lit_int 0) ty_bool,
                 assign "__split_count_pos" slen,
                 seq
                   (assign "__split_part_count"
                      (bin Ast.Add part_count (lit_int 1) ty_int))
                   (assign "__split_count_pos"
                      (bin Ast.Add found_pos (lit_int 1) ty_int)) ))))
  in
  let one_byte_linear_count_loop =
    let advance =
      assign "__split_count_pos" (bin Ast.Add count_pos (lit_int 1) ty_int)
    in
    while_
      (bin Ast.Lt count_pos slen ty_bool)
      (mk ty_void
         (CIf
            ( bin Ast.Eq (byte_at self count_pos) delim_byte ty_bool,
              seq
                (assign "__split_part_count"
                   (bin Ast.Add part_count (lit_int 1) ty_int))
                advance,
              advance )))
  in
  let store_segment segment index =
    intr "list_set_owned" [ result; index; segment ] ty_void
  in
  let empty_delim_result =
    lett "__split_result"
      (intr "list_alloc" [ lit_int 1 ] return_ty)
      (seq
         (intr "list_retain_for" [ result; self ] ty_void)
         (seq
            (intr "list_set" [ result; lit_int 0; self ] ty_void)
            (seq (intr "list_set_len" [ result; lit_int 1 ] ty_void) result)))
  in
  let append_current_segment =
    lett "__split_segment_len"
      (bin Ast.Sub fill_pos segment_start ty_int)
      (seq
         (store_segment
            (segment_copy ~name:"__split_segment" segment_start segment_len)
            out_index)
         (seq
            (assign "__split_out_index"
               (bin Ast.Add out_index (lit_int 1) ty_int))
            (seq
               (assign "__split_segment_start"
                  (bin Ast.Add fill_pos dlen ty_int))
               (assign "__split_fill_pos" (bin Ast.Add fill_pos dlen ty_int)))))
  in
  let fill_loop =
    while_
      (delimiter_fits_at fill_pos)
      (lettm "__split_match" (lit_bool true)
         (seq
            (compare_delim_at fill_pos)
            (mk ty_void
               (CIf
                  ( match_var,
                    append_current_segment,
                    assign "__split_fill_pos"
                      (bin Ast.Add fill_pos (lit_int 1) ty_int) )))))
  in
  let one_byte_fill_loop =
    while_
      (bin Ast.Lt fill_pos slen ty_bool)
      (lett "__split_found_pos"
         (string_find_byte_from self delim_byte fill_pos)
         (mk ty_void
            (CIf
               ( bin Ast.Lt found_pos (lit_int 0) ty_bool,
                 assign "__split_fill_pos" slen,
                 seq
                   (assign "__split_fill_pos" found_pos)
                   append_current_segment ))))
  in
  let one_byte_linear_fill_loop =
    while_
      (bin Ast.Lt fill_pos slen ty_bool)
      (mk ty_void
         (CIf
            ( bin Ast.Eq (byte_at self fill_pos) delim_byte ty_bool,
              append_current_segment,
              assign "__split_fill_pos"
                (bin Ast.Add fill_pos (lit_int 1) ty_int) )))
  in
  let append_final_segment =
    lett "__split_final_segment_len"
      (bin Ast.Sub slen segment_start ty_int)
      (store_segment
         (segment_copy ~name:"__split_final_segment" segment_start
            final_segment_len)
         out_index)
  in
  let build_split_with count_loop fill_loop =
    lettm "__split_part_count" (lit_int 1)
      (lettm "__split_count_pos" (lit_int 0)
         (seq count_loop
            (lett "__split_result"
               (intr "list_alloc" [ part_count ] return_ty)
               (lettm "__split_fill_pos" (lit_int 0)
                  (lettm "__split_segment_start" (lit_int 0)
                     (lettm "__split_out_index" (lit_int 0)
                        (seq fill_loop
                           (seq append_final_segment
                              (seq
                                 (intr "list_set_len" [ result; part_count ]
                                    ty_void)
                                 result)))))))))
  in
  let build_split = build_split_with count_loop fill_loop in
  let build_one_byte_split =
    lett "__split_delim_byte"
      (byte_at delim (lit_int 0))
      (if_
         (* Performance-only threshold: short strings are faster with inline
            byte checks; longer strings amortize the runtime helper call and
            can use libc's memchr. Both branches have identical semantics. *)
         (bin Ast.Gt slen (lit_int single_byte_find_min_len) ty_bool)
         (build_split_with one_byte_count_loop one_byte_fill_loop)
         (build_split_with one_byte_linear_count_loop one_byte_linear_fill_loop)
         return_ty)
  in
  lett "__split_slen"
    (intr "string_len" [ self ] ty_int)
    (lett "__split_dlen"
       (intr "string_len" [ delim ] ty_int)
       (if_
          (bin Ast.Eq dlen (lit_int 0) ty_bool)
          empty_delim_result
          (if_
             (bin Ast.Eq dlen (lit_int 1) ty_bool)
             build_one_byte_split build_split return_ty)
          return_ty))

(** starts_with(self, prefix) -> Bool

    if string_len(prefix) > string_len(self): return false
    for i in 0..string_len(prefix):
      if string_get_byte(self, i) != string_get_byte(prefix, i): return false
    return true

    Uses early-return via a var + break pattern since Core IR has CBreak. *)
let string_starts_with self prefix =
  let i = vr "__i" ty_int in
  let self_len = intr "string_len" [ self ] ty_int in
  let prefix_len = intr "string_len" [ prefix ] ty_int in
  (* if prefix_len > self_len: false
     else: check byte-by-byte *)
  lett "__plen" prefix_len
    (mk ty_bool
       (CIf
          ( bin Ast.Gt (vr "__plen" ty_int) self_len ty_bool,
            mk ty_bool (CLit (Ast.LitBool false)),
            (* byte-by-byte comparison *)
            lettm "__match"
              (mk ty_bool (CLit (Ast.LitBool true)))
              (seq
                 (mk ty_void
                    (CFor
                       ( loop "__i" ty_int,
                         mk ty_int (CRange (lit_int 0, vr "__plen" ty_int)),
                         mk ty_void
                           (CIf
                              ( bin Ast.Ne
                                  (intr "string_get_byte" [ self; i ] ty_int)
                                  (intr "string_get_byte" [ prefix; i ] ty_int)
                                  ty_bool,
                                seq
                                  (mk ty_void
                                     (CAssign
                                        ( Var.named "__match",
                                          mk ty_bool (CLit (Ast.LitBool false))
                                        )))
                                  (mk ty_void CBreak),
                                void )) )))
                 (vr "__match" ty_bool)) )))

(** ends_with(self, suffix) -> Bool

    if string_len(suffix) > string_len(self): return false
    let offset = string_len(self) - string_len(suffix)
    for i in 0..string_len(suffix):
      if string_get_byte(self, offset + i) != string_get_byte(suffix, i): return false
    return true *)
let string_ends_with self suffix =
  let i = vr "__i" ty_int in
  let self_len = intr "string_len" [ self ] ty_int in
  let suffix_len = intr "string_len" [ suffix ] ty_int in
  lett "__slen" suffix_len
    (mk ty_bool
       (CIf
          ( bin Ast.Gt (vr "__slen" ty_int) self_len ty_bool,
            mk ty_bool (CLit (Ast.LitBool false)),
            lett "__offset"
              (bin Ast.Sub self_len (vr "__slen" ty_int) ty_int)
              (lettm "__match"
                 (mk ty_bool (CLit (Ast.LitBool true)))
                 (seq
                    (mk ty_void
                       (CFor
                          ( loop "__i" ty_int,
                            mk ty_int (CRange (lit_int 0, vr "__slen" ty_int)),
                            mk ty_void
                              (CIf
                                 ( bin Ast.Ne
                                     (intr "string_get_byte"
                                        [
                                          self;
                                          bin Ast.Add (vr "__offset" ty_int) i
                                            ty_int;
                                        ]
                                        ty_int)
                                     (intr "string_get_byte" [ suffix; i ]
                                        ty_int)
                                     ty_bool,
                                   seq
                                     (mk ty_void
                                        (CAssign
                                           ( Var.named "__match",
                                             mk ty_bool
                                               (CLit (Ast.LitBool false)) )))
                                     (mk ty_void CBreak),
                                   void )) )))
                    (vr "__match" ty_bool))) )))

(** Helper: is a byte ASCII whitespace? (space, tab, newline, carriage return) *)
let is_ws byte =
  mk ty_bool
    (CLog
       ( Ast.Or,
         mk ty_bool
           (CLog
              ( Ast.Or,
                bin Ast.Eq byte (lit_int 32) ty_bool,
                bin Ast.Eq byte (lit_int 9) ty_bool )),
         mk ty_bool
           (CLog
              ( Ast.Or,
                bin Ast.Eq byte (lit_int 10) ty_bool,
                bin Ast.Eq byte (lit_int 13) ty_bool )) ))

(** Helper: "for all bytes, check condition" pattern.
    Returns [default_empty] for empty string, otherwise loops
    and returns false on first byte where [check_fail byte] is true.
    [check_fail] takes the byte var and returns a bool expression. *)
let string_all_bytes_check ~default_empty self check_fail =
  let i = vr "__i" ty_int in
  let n = intr "string_len" [ self ] ty_int in
  lett "__n" n
    (mk ty_bool
       (CIf
          ( bin Ast.Eq (vr "__n" ty_int) (lit_int 0) ty_bool,
            mk ty_bool (CLit (Ast.LitBool default_empty)),
            lettm "__ok"
              (mk ty_bool (CLit (Ast.LitBool true)))
              (seq
                 (mk ty_void
                    (CFor
                       ( loop "__i" ty_int,
                         mk ty_int (CRange (lit_int 0, vr "__n" ty_int)),
                         lett "__byte"
                           (intr "string_get_byte" [ self; i ] ty_int)
                           (mk ty_void
                              (CIf
                                 ( check_fail (vr "__byte" ty_int),
                                   seq
                                     (mk ty_void
                                        (CAssign
                                           ( Var.named "__ok",
                                             mk ty_bool
                                               (CLit (Ast.LitBool false)) )))
                                     (mk ty_void CBreak),
                                   void ))) )))
                 (vr "__ok" ty_bool)) )))

(** is_numeric: all bytes in '0'..'9', false for empty *)
let string_is_numeric self =
  string_all_bytes_check ~default_empty:false self (fun byte ->
      (* fail if byte < 48 or byte > 57 *)
      mk ty_bool
        (CLog
           ( Ast.Or,
             bin Ast.Lt byte (lit_int 48) ty_bool,
             (* '0' = 48 *)
             bin Ast.Gt byte (lit_int 57) ty_bool )))
(* '9' = 57 *)

(** is_ascii: all bytes <= 127, true for empty *)
let string_is_ascii self =
  string_all_bytes_check ~default_empty:true self (fun byte ->
      bin Ast.Gt byte (lit_int 127) ty_bool)

(** is_blank: all bytes are whitespace (space/tab/newline/cr), true for empty *)
let string_is_blank self =
  string_all_bytes_check ~default_empty:true self (fun byte ->
      (* fail if byte is NOT one of: 32 (space), 9 (tab), 10 (LF), 13 (CR) *)
      mk ty_bool
        (CLog
           ( Ast.And,
             mk ty_bool
               (CLog
                  ( Ast.And,
                    bin Ast.Ne byte (lit_int 32) ty_bool,
                    bin Ast.Ne byte (lit_int 9) ty_bool )),
             mk ty_bool
               (CLog
                  ( Ast.And,
                    bin Ast.Ne byte (lit_int 10) ty_bool,
                    bin Ast.Ne byte (lit_int 13) ty_bool )) )))

(** is_lower: has at least one letter, all letters are lowercase.
    Non-letter chars are ignored. *)
let string_is_lower self =
  let i = vr "__i" ty_int in
  lett "__n"
    (intr "string_len" [ self ] ty_int)
    (mk ty_bool
       (CIf
          ( bin Ast.Eq (vr "__n" ty_int) (lit_int 0) ty_bool,
            mk ty_bool (CLit (Ast.LitBool false)),
            lettm "__has_letter"
              (mk ty_bool (CLit (Ast.LitBool false)))
              (lettm "__ok"
                 (mk ty_bool (CLit (Ast.LitBool true)))
                 (seq
                    (mk ty_void
                       (CFor
                          ( loop "__i" ty_int,
                            mk ty_int (CRange (lit_int 0, vr "__n" ty_int)),
                            lett "__byte"
                              (intr "string_get_byte" [ self; i ] ty_int)
                              (mk ty_void
                                 (CIf
                                    ( mk ty_bool
                                        (CLog
                                           ( Ast.And,
                                             bin Ast.Ge (vr "__byte" ty_int)
                                               (lit_int 65) ty_bool,
                                             bin Ast.Le (vr "__byte" ty_int)
                                               (lit_int 90) ty_bool )),
                                      seq
                                        (mk ty_void
                                           (CAssign
                                              ( Var.named "__ok",
                                                mk ty_bool
                                                  (CLit (Ast.LitBool false)) )))
                                        (mk ty_void CBreak),
                                      mk ty_void
                                        (CIf
                                           ( mk ty_bool
                                               (CLog
                                                  ( Ast.And,
                                                    bin Ast.Ge
                                                      (vr "__byte" ty_int)
                                                      (lit_int 97) ty_bool,
                                                    bin Ast.Le
                                                      (vr "__byte" ty_int)
                                                      (lit_int 122) ty_bool )),
                                             mk ty_void
                                               (CAssign
                                                  ( Var.named "__has_letter",
                                                    mk ty_bool
                                                      (CLit (Ast.LitBool true))
                                                  )),
                                             void )) ))) )))
                    (mk ty_bool
                       (CLog
                          (Ast.And, vr "__ok" ty_bool, vr "__has_letter" ty_bool)))))
          )))

(** is_upper: same as is_lower but reversed *)
let string_is_upper self =
  let i = vr "__i" ty_int in
  lett "__n"
    (intr "string_len" [ self ] ty_int)
    (mk ty_bool
       (CIf
          ( bin Ast.Eq (vr "__n" ty_int) (lit_int 0) ty_bool,
            mk ty_bool (CLit (Ast.LitBool false)),
            lettm "__has_letter"
              (mk ty_bool (CLit (Ast.LitBool false)))
              (lettm "__ok"
                 (mk ty_bool (CLit (Ast.LitBool true)))
                 (seq
                    (mk ty_void
                       (CFor
                          ( loop "__i" ty_int,
                            mk ty_int (CRange (lit_int 0, vr "__n" ty_int)),
                            lett "__byte"
                              (intr "string_get_byte" [ self; i ] ty_int)
                              (mk ty_void
                                 (CIf
                                    ( mk ty_bool
                                        (CLog
                                           ( Ast.And,
                                             bin Ast.Ge (vr "__byte" ty_int)
                                               (lit_int 97) ty_bool,
                                             bin Ast.Le (vr "__byte" ty_int)
                                               (lit_int 122) ty_bool )),
                                      seq
                                        (mk ty_void
                                           (CAssign
                                              ( Var.named "__ok",
                                                mk ty_bool
                                                  (CLit (Ast.LitBool false)) )))
                                        (mk ty_void CBreak),
                                      mk ty_void
                                        (CIf
                                           ( mk ty_bool
                                               (CLog
                                                  ( Ast.And,
                                                    bin Ast.Ge
                                                      (vr "__byte" ty_int)
                                                      (lit_int 65) ty_bool,
                                                    bin Ast.Le
                                                      (vr "__byte" ty_int)
                                                      (lit_int 90) ty_bool )),
                                             mk ty_void
                                               (CAssign
                                                  ( Var.named "__has_letter",
                                                    mk ty_bool
                                                      (CLit (Ast.LitBool true))
                                                  )),
                                             void )) ))) )))
                    (mk ty_bool
                       (CLog
                          (Ast.And, vr "__ok" ty_bool, vr "__has_letter" ty_bool)))))
          )))

(* ================================================================
   Set IR bodies
   ================================================================ *)

type set_probe_strategy = SetProbeImmediate | SetProbeDispatched

let set_probe_strategy_for_elem ?reg elem_ty =
  match Core_layout_type.hash_probe_layout ?reg elem_ty with
  | Core_layout_type.HashProbeImmediate -> SetProbeImmediate
  | Core_layout_type.HashProbeDispatched -> SetProbeDispatched

let set_probe_strategy_for_set ?reg set =
  match Core_layout_type.set_type ?reg set.ty with
  | Some set_ty -> set_probe_strategy_for_elem ?reg set_ty.set_elem_ty
  | None -> SetProbeDispatched

let set_hash_probe strategy set key =
  match strategy with
  | SetProbeImmediate -> intr "set_hash_immediate" [ key ] ty_int
  | SetProbeDispatched -> intr "set_hash" [ set; key ] ty_int

let set_eq_probe strategy set lhs rhs =
  match strategy with
  | SetProbeImmediate -> intr "set_eq_immediate" [ lhs; rhs ] ty_bool
  | SetProbeDispatched -> intr "set_eq" [ set; lhs; rhs ] ty_bool

(** contains(self, elem) -> Bool
    elem_key = key_as_ptr(elem)   -- box scalars, borrow-cast pointer values
    hash = set_hash(self, elem_key)
    bucket_idx = hash & set_mask(self)
    var entry = set_bucket(self, bucket_idx)
    while entry != NULL:
        if set_eq(self, set_entry_key(entry), elem_key):
            return True
        entry = set_entry_next(entry)
    return False *)
let set_contains ?reg set_ty self elem =
  let elem_ty = set_elem_ty ?reg set_ty in
  let strategy = set_probe_strategy_for_elem ?reg elem_ty in
  let key = key_as_ptr ?reg ~as_ty:elem_ty elem in
  lett "__elem" key
    (lett "__hash"
       (set_hash_probe strategy self (vr "__elem" ty_ptr))
       (lett "__bidx"
          (intr "bit_and"
             [ vr "__hash" ty_int; intr "set_mask" [ self ] ty_int ]
             ty_int)
          (lettm "__entry"
             (intr "set_bucket" [ self; vr "__bidx" ty_int ] ty_ptr)
             (lettm "__found" (lit_bool false)
                (seq
                   (while_
                      (not_null (vr "__entry" ty_ptr))
                      (if_
                         (set_eq_probe strategy self
                            (intr "set_entry_key"
                               [ vr "__entry" ty_ptr ]
                               ty_ptr)
                            (vr "__elem" ty_ptr))
                         (seq (assign "__found" (lit_bool true)) break_)
                         (assign "__entry"
                            (intr "set_entry_next"
                               [ vr "__entry" ty_ptr ]
                               ty_ptr))
                         ty_void))
                   (vr "__found" ty_bool))))))

let set_contains_key ?reg set key =
  let strategy = set_probe_strategy_for_set ?reg set in
  lett "__hash"
    (set_hash_probe strategy set key)
    (lett "__bidx"
       (intr "bit_and"
          [ vr "__hash" ty_int; intr "set_mask" [ set ] ty_int ]
          ty_int)
       (lettm "__probe"
          (intr "set_bucket" [ set; vr "__bidx" ty_int ] ty_ptr)
          (lettm "__found" (lit_bool false)
             (seq
                (while_
                   (log Ast.And
                      (bin Ast.Eq (vr "__found" ty_bool) (lit_bool false)
                         ty_bool)
                      (not_null (vr "__probe" ty_ptr)))
                   (if_
                      (set_eq_probe strategy set
                         (intr "set_entry_key" [ vr "__probe" ty_ptr ] ty_ptr)
                         key)
                      (assign "__found" (lit_bool true))
                      (assign "__probe"
                         (intr "set_entry_next" [ vr "__probe" ty_ptr ] ty_ptr))
                      ty_void))
                (vr "__found" ty_bool)))))

let set_reserve_for_len func_name set expected_len =
  intr (set_reserve_for_len_boundary func_name) [ set; expected_len ] ty_void

(** Insert [key] into an already-owned set. This mirrors the runtime
    [blorp_set_add] insertion path, but keeps COW and entry ownership explicit
    in Core so Perceus can reason about the table mutation boundary. *)
let set_insert_retained ?reg set key =
  let strategy = set_probe_strategy_for_set ?reg set in
  let insert_key = vr "__insert_key" ty_ptr in
  let hash = vr "__insert_hash" ty_int in
  let bidx = vr "__insert_bidx" ty_int in
  let probe = vr "__insert_probe" ty_ptr in
  let found = vr "__insert_found" ty_bool in
  let new_entry = vr "__insert_new_entry" ty_ptr in
  let old_last = vr "__insert_old_last" ty_ptr in
  let new_len = vr "__insert_new_len" ty_int in
  let scan_existing =
    while_
      (log Ast.And (bin Ast.Eq found (lit_bool false) ty_bool) (not_null probe))
      (if_
         (set_eq_probe strategy set
            (intr "set_entry_key" [ probe ] ty_ptr)
            insert_key)
         (assign "__insert_found" (lit_bool true))
         (assign "__insert_probe" (intr "set_entry_next" [ probe ] ty_ptr))
         ty_void)
  in
  let link_bucket =
    seq
      (intr "set_entry_set_next"
         [ new_entry; intr "set_bucket" [ set; bidx ] ty_ptr ]
         ty_void)
      (intr "set_set_bucket" [ set; bidx; new_entry ] ty_void)
  in
  let link_order =
    seq
      (intr "set_entry_set_prev_order" [ new_entry; old_last ] ty_void)
      (seq
         (intr "set_entry_set_next_order" [ new_entry; null_ptr ] ty_void)
         (seq
            (if_ (not_null old_last)
               (intr "set_entry_set_next_order" [ old_last; new_entry ] ty_void)
               (intr "set_set_first" [ set; new_entry ] ty_void)
               ty_void)
            (intr "set_set_last" [ set; new_entry ] ty_void)))
  in
  let resize_if_needed =
    if_
      (bin Ast.Gt new_len
         (bin Ast.Div
            (bin Ast.Mul
               (intr "set_capacity" [ set ] ty_int)
               (lit_int 3) ty_int)
            (lit_int 4) ty_int)
         ty_bool)
      (intr "set_resize"
         [
           set;
           bin Ast.Mul (intr "set_capacity" [ set ] ty_int) (lit_int 2) ty_int;
         ]
         ty_void)
      void ty_void
  in
  let insert_new =
    seq
      (intr "set_retain_key_for" [ set; insert_key ] ty_void)
      (lett "__insert_new_entry"
         (intr "set_alloc_entry" [ insert_key ] ty_ptr)
         (lett "__insert_old_last"
            (intr "set_last" [ set ] ty_ptr)
            (lett "__insert_new_len"
               (bin Ast.Add (intr "set_len" [ set ] ty_int) (lit_int 1) ty_int)
               (seq link_bucket
                  (seq link_order
                     (seq
                        (intr "set_set_len" [ set; new_len ] ty_void)
                        resize_if_needed))))))
  in
  lett "__insert_key" key
    (lett "__insert_hash"
       (set_hash_probe strategy set insert_key)
       (lett "__insert_bidx"
          (intr "bit_and" [ hash; intr "set_mask" [ set ] ty_int ] ty_int)
          (lettm "__insert_probe"
             (intr "set_bucket" [ set; bidx ] ty_ptr)
             (lettm "__insert_found" (lit_bool false)
                (seq scan_existing (if_ found void insert_new ty_void))))))

(** is_subset(a, b) -> Bool
    Iterate a's insertion-order entries directly. For each borrowed key, probe
    b's hash bucket and short-circuit on the first missing element. *)
let set_is_subset ?reg a b =
  let entry = vr "__entry" ty_ptr in
  let key = vr "__key" ty_ptr in
  let scan_one =
    lett "__key"
      (intr "set_entry_key" [ entry ] ty_ptr)
      (lett "__found_in_b"
         (set_contains_key ?reg b key)
         (seq
            (if_
               (vr "__found_in_b" ty_bool)
               void
               (seq (assign "__ok" (lit_bool false)) break_)
               ty_void)
            (assign "__entry" (intr "set_entry_next_order" [ entry ] ty_ptr))))
  in
  let scan =
    lettm "__entry"
      (intr "set_first" [ a ] ty_ptr)
      (lettm "__ok" (lit_bool true)
         (seq
            (while_ (log Ast.And (vr "__ok" ty_bool) (not_null entry)) scan_one)
            (vr "__ok" ty_bool)))
  in
  lett "__a_len"
    (intr "set_len" [ a ] ty_int)
    (lett "__b_len"
       (intr "set_len" [ b ] ty_int)
       (if_
          (bin Ast.Gt (vr "__a_len" ty_int) (vr "__b_len" ty_int) ty_bool)
          (lit_bool false) scan ty_bool))

(** difference(a, b) -> Set[T]
    Build a fresh result while scanning a directly. Keys borrowed from a are
    retained for the destination set before direct entry transfer. *)
let set_difference ?reg result_ty a b =
  let alloc = set_alloc_builtin "difference" in
  let entry = vr "__entry" ty_ptr in
  let key = vr "__key" ty_ptr in
  let result = vr "__result" result_ty in
  let scan_one =
    lett "__key"
      (intr "set_entry_key" [ entry ] ty_ptr)
      (lett "__in_b"
         (set_contains_key ?reg b key)
         (seq
            (if_ (vr "__in_b" ty_bool) void
               (set_insert_retained ?reg result key)
               ty_void)
            (assign "__entry" (intr "set_entry_next_order" [ entry ] ty_ptr))))
  in
  lettm "__result"
    (builtin_call alloc [] result_ty)
    (seq
       (set_reserve_for_len "difference" result (intr "set_len" [ a ] ty_int))
       (lettm "__entry"
          (intr "set_first" [ a ] ty_ptr)
          (seq (while_ (not_null entry) scan_one) result)))

(** intersect(a, b) -> Set[T]
    Build a fresh result while scanning a directly, preserving a's insertion
    order for elements also present in b. Borrowed keys are retained for the
    destination set before direct entry transfer. *)
let set_intersect ?reg result_ty a b =
  let alloc = set_alloc_builtin "intersect" in
  let entry = vr "__entry" ty_ptr in
  let key = vr "__key" ty_ptr in
  let result = vr "__result" result_ty in
  let scan_one =
    lett "__key"
      (intr "set_entry_key" [ entry ] ty_ptr)
      (lett "__in_b"
         (set_contains_key ?reg b key)
         (seq
            (if_ (vr "__in_b" ty_bool)
               (set_insert_retained ?reg result key)
               void ty_void)
            (assign "__entry" (intr "set_entry_next_order" [ entry ] ty_ptr))))
  in
  lettm "__result"
    (builtin_call alloc [] result_ty)
    (seq
       (set_reserve_for_len "intersect" result (intr "set_len" [ a ] ty_int))
       (lettm "__entry"
          (intr "set_first" [ a ] ty_ptr)
          (seq (while_ (not_null entry) scan_one) result)))

(** combine(a, b) -> Set[T]
    COW a once, then scan b's insertion-order entries directly. Borrowed b
    keys are retained before direct entry transfer. *)
let set_combine ?reg result_ty a b =
  let entry = vr "__entry" ty_ptr in
  let key = vr "__key" ty_ptr in
  let result = vr "__result" result_ty in
  let scan_one =
    lett "__key"
      (intr "set_entry_key" [ entry ] ty_ptr)
      (seq
         (set_insert_retained ?reg result key)
         (assign "__entry" (intr "set_entry_next_order" [ entry ] ty_ptr)))
  in
  lettm "__result"
    (intr (set_reuse_boundary "combine") [ a ] result_ty)
    (seq
       (set_reserve_for_len "combine" result
          (bin Ast.Add
             (intr "set_len" [ result ] ty_int)
             (intr "set_len" [ b ] ty_int)
             ty_int))
       (lettm "__entry"
          (intr "set_first" [ b ] ty_ptr)
          (seq (while_ (not_null entry) scan_one) result)))

(** add(self, elem) -> Set[T]
    COW the receiver once, then insert the input element through the same
    direct retained-entry path used by synthesized set builders. *)
let set_add ?reg set_ty self elem =
  let elem_ty = set_elem_ty ?reg set_ty in
  let result = vr "__result" set_ty in
  lettm "__result"
    (intr (set_reuse_boundary "add") [ self ] set_ty)
    (seq
       (set_insert_retained ?reg result (key_as_ptr ?reg ~as_ty:elem_ty elem))
       result)

(** map(self, f) -> Set[U]
    Scan set entries directly and insert each callback result into a fresh set.
    Callback results are retained or boxed once, then transferred directly into
    the result table. *)
let set_map ?reg self_ty result_ty self f =
  let alloc = set_alloc_builtin "map" in
  let elem_ty = set_elem_ty ?reg self_ty in
  let result_elem_ty = set_elem_ty ?reg result_ty in
  let entry = vr "__entry" ty_ptr in
  let key = vr "__key" ty_ptr in
  let elem = mk elem_ty (CUnbox (key, elem_ty)) in
  let result = vr "__result" result_ty in
  let scan_one =
    lett "__key"
      (intr "set_entry_key" [ entry ] ty_ptr)
      (lett "__mapped"
         (closure_call f [ elem ] result_elem_ty)
         (seq
            (set_insert_retained ?reg result
               (key_as_ptr ?reg ~as_ty:result_elem_ty
                  (vr "__mapped" result_elem_ty)))
            (assign "__entry" (intr "set_entry_next_order" [ entry ] ty_ptr))))
  in
  lettm "__result"
    (builtin_call alloc [] result_ty)
    (seq
       (set_reserve_for_len "map" result (intr "set_len" [ self ] ty_int))
       (lettm "__entry"
          (intr "set_first" [ self ] ty_ptr)
          (seq (while_ (not_null entry) scan_one) result)))

(** filter(self, pred) -> Set[T]
    Scan entries directly and add borrowed keys that satisfy the predicate.
    Borrowed keys are retained before direct entry transfer. *)
let set_filter ?reg self_ty self pred =
  let alloc = set_alloc_builtin "filter" in
  let elem_ty = set_elem_ty ?reg self_ty in
  let entry = vr "__entry" ty_ptr in
  let key = vr "__key" ty_ptr in
  let elem = mk elem_ty (CUnbox (key, elem_ty)) in
  let result = vr "__result" self_ty in
  let scan_one =
    lett "__key"
      (intr "set_entry_key" [ entry ] ty_ptr)
      (seq
         (if_
            (closure_call pred [ elem ] ty_bool)
            (set_insert_retained ?reg result key)
            void ty_void)
         (assign "__entry" (intr "set_entry_next_order" [ entry ] ty_ptr)))
  in
  lettm "__result"
    (builtin_call alloc [] self_ty)
    (seq
       (set_reserve_for_len "filter" result (intr "set_len" [ self ] ty_int))
       (lettm "__entry"
          (intr "set_first" [ self ] ty_ptr)
          (seq (while_ (not_null entry) scan_one) result)))

(** fold(self, init, f) -> Acc
    Thread one owned accumulator through a direct set-entry scan. The callback
    receives the current accumulator and borrowed key value, then returns the
    next owned accumulator. *)
let set_fold ?reg self_ty acc_ty self init f =
  let elem_ty = set_elem_ty ?reg self_ty in
  let entry = vr "__entry" ty_ptr in
  let key = vr "__key" ty_ptr in
  let elem = mk elem_ty (CUnbox (key, elem_ty)) in
  let step =
    lett "__key"
      (intr "set_entry_key" [ entry ] ty_ptr)
      (lett "__next"
         (closure_call f [ vr "__acc" acc_ty; elem ] acc_ty)
         (seq
            (mk ty_void
               (CDrop
                  ( Var.named "__acc",
                    acc_ty,
                    assign "__acc" (vr "__next" acc_ty) )))
            (assign "__entry" (intr "set_entry_next_order" [ entry ] ty_ptr))))
  in
  lettm "__acc" init
    (lettm "__entry"
       (intr "set_first" [ self ] ty_ptr)
       (seq (while_ (not_null entry) step) (vr "__acc" acc_ty)))

(** to_list(self) -> List[T]
    n = set_len(self)
    result = list_alloc(n)
    var i = 0
    var entry = set_first(self)
    while entry != NULL:
        list_retain_for(result, set_entry_key(entry))
        list_set(result, i, set_entry_key(entry))
        i = i + 1
        entry = set_entry_next_order(entry)
    list_set_len(result, i)
    result *)
let set_to_list _set_ty result_ty self =
  let alloc = set_list_alloc_intrinsic "to_list" in
  lett "__n"
    (intr "set_len" [ self ] ty_int)
    (lett "__result"
       (intr alloc [ vr "__n" ty_int ] result_ty)
       (lettm "__i" (lit_int 0)
          (lettm "__entry"
             (intr "set_first" [ self ] ty_ptr)
             (seq
                (while_
                   (not_null (vr "__entry" ty_ptr))
                   (let key =
                      intr "set_entry_key" [ vr "__entry" ty_ptr ] ty_ptr
                    in
                    seq
                      (intr "list_retain_for"
                         [ vr "__result" result_ty; key ]
                         ty_void)
                      (seq
                         (intr "list_set"
                            [ vr "__result" result_ty; vr "__i" ty_int; key ]
                            ty_void)
                         (seq
                            (assign "__i"
                               (bin Ast.Add (vr "__i" ty_int) (lit_int 1) ty_int))
                            (assign "__entry"
                               (intr "set_entry_next_order"
                                  [ vr "__entry" ty_ptr ]
                                  ty_ptr))))))
                (seq
                   (intr "list_set_len"
                      [ vr "__result" result_ty; vr "__i" ty_int ]
                      ty_void)
                   (vr "__result" result_ty))))))

(* ================================================================
   Fixed IR bodies
   ================================================================ *)

let ty_fixed = Ast.TyNamed ("Fixed", [])

(** get_scale(f) -> Int = fixed_scale(f) *)
let fixed_get_scale f = intr "fixed_scale" [ f ] ty_int

(** get_precision(f) -> Int = fixed_precision(f) *)
let fixed_get_precision f = intr "fixed_precision" [ f ] ty_int

(** to_int(f) -> Int
    if scale >= 0: value / pow10(scale)
    else: value * pow10(-scale) *)
let fixed_to_int f =
  lett "__val"
    (intr "fixed_value" [ f ] ty_int)
    (lett "__scale"
       (intr "fixed_scale" [ f ] ty_int)
       (if_
          (bin Ast.Ge (vr "__scale" ty_int) (lit_int 0) ty_bool)
          (bin Ast.Div (vr "__val" ty_int)
             (intr "fixed_pow10" [ vr "__scale" ty_int ] ty_int)
             ty_int)
          (bin Ast.Mul (vr "__val" ty_int)
             (intr "fixed_pow10"
                [ bin Ast.Sub (lit_int 0) (vr "__scale" ty_int) ty_int ]
                ty_int)
             ty_int)
          ty_int))

(** to_float(f) -> Float
    Keep as CKBuiltin — needs int-to-float conversion which is
    handled by the C compiler's type coercion *)

(** neg(f) -> Fixed = fixed_alloc(-value, scale, precision) *)
let fixed_neg f =
  intr "fixed_alloc"
    [
      bin Ast.Sub (lit_int 0) (intr "fixed_value" [ f ] ty_int) ty_int;
      intr "fixed_scale" [ f ] ty_int;
      intr "fixed_precision" [ f ] ty_int;
    ]
    ty_fixed

(** round_to(f, target_scale) -> Fixed
    Rescale value to target_scale, create new Fixed *)
let fixed_round_to f target_scale =
  lett "__val"
    (intr "fixed_value" [ f ] ty_int)
    (lett "__scale"
       (intr "fixed_scale" [ f ] ty_int)
       (lett "__prec"
          (intr "fixed_precision" [ f ] ty_int)
          (lett "__diff"
             (bin Ast.Sub target_scale (vr "__scale" ty_int) ty_int)
             (lett "__new_val"
                (if_
                   (bin Ast.Gt (vr "__diff" ty_int) (lit_int 0) ty_bool)
                   (bin Ast.Mul (vr "__val" ty_int)
                      (intr "fixed_pow10" [ vr "__diff" ty_int ] ty_int)
                      ty_int)
                   (if_
                      (bin Ast.Lt (vr "__diff" ty_int) (lit_int 0) ty_bool)
                      (lett "__div"
                         (intr "fixed_pow10"
                            [
                              bin Ast.Sub (lit_int 0) (vr "__diff" ty_int)
                                ty_int;
                            ]
                            ty_int)
                         (bin Ast.Div
                            (bin Ast.Add (vr "__val" ty_int)
                               (bin Ast.Div (vr "__div" ty_int) (lit_int 2)
                                  ty_int)
                               ty_int)
                            (vr "__div" ty_int) ty_int))
                      (vr "__val" ty_int) ty_int)
                   ty_int)
                (intr "fixed_alloc"
                   [ vr "__new_val" ty_int; target_scale; vr "__prec" ty_int ]
                   ty_fixed)))))

(* ================================================================
   Slice IR bodies
   ================================================================ *)

let ty_slice = Ast.TyNamed ("StringSlice", [])

(* ty_string defined in string section above *)
let ty_char = Ast.TyNamed ("Char", [])

(** from_string(s) -> StringSlice
    slice_alloc(s, 0, string_len(s)) *)
let slice_from_string s =
  intr "slice_alloc" [ s; lit_int 0; intr "string_len" [ s ] ty_int ] ty_slice

(** length(slice) -> Int
    slice_len(slice) *)
let slice_length slice = intr "slice_len" [ slice ] ty_int

(** to_string(slice) -> String
    source = slice_source(slice)
    start = slice_start(slice)
    len = slice_len(slice)
    substring(source, start, len) — reuse string substring *)
let slice_to_string slice =
  lett "__src"
    (intr "slice_source" [ slice ] ty_string)
    (lett "__off"
       (intr "slice_start" [ slice ] ty_int)
       (lett "__slen"
          (intr "slice_len" [ slice ] ty_int)
          ( intr "string_alloc" [ vr "__slen" ty_int ] ty_string |> fun alloc ->
            lett "__r" alloc
              (seq
                 (mk ty_void
                    (CFor
                       ( loop "__i" ty_int,
                         mk ty_int (CRange (lit_int 0, vr "__slen" ty_int)),
                         intr "string_set_byte"
                           [
                             vr "__r" ty_string;
                             vr "__i" ty_int;
                             intr "string_get_byte"
                               [
                                 vr "__src" ty_string;
                                 bin Ast.Add (vr "__off" ty_int)
                                   (vr "__i" ty_int) ty_int;
                               ]
                               ty_int;
                           ]
                           ty_void )))
                 (seq
                    (intr "string_set_len"
                       [ vr "__r" ty_string; vr "__slen" ty_int ]
                       ty_void)
                    (vr "__r" ty_string))) )))

(** substring(slice, start, len) -> StringSlice
    Clamp start/len, then slice_alloc(slice.source, slice.start + clamped_start, clamped_len) *)
let slice_substring slice start len =
  lett "__src"
    (intr "slice_source" [ slice ] ty_string)
    (lett "__base"
       (intr "slice_start" [ slice ] ty_int)
       (lett "__total"
          (intr "slice_len" [ slice ] ty_int)
          (lett "__s"
             (if_
                (bin Ast.Lt start (lit_int 0) ty_bool)
                (lit_int 0)
                (if_
                   (bin Ast.Gt start (vr "__total" ty_int) ty_bool)
                   (vr "__total" ty_int) start ty_int)
                ty_int)
             (lett "__l"
                (if_
                   (bin Ast.Lt len (lit_int 0) ty_bool)
                   (lit_int 0)
                   (let max_len =
                      bin Ast.Sub (vr "__total" ty_int) (vr "__s" ty_int) ty_int
                    in
                    if_ (bin Ast.Gt len max_len ty_bool) max_len len ty_int)
                   ty_int)
                (intr "slice_alloc"
                   [
                     vr "__src" ty_string;
                     bin Ast.Add (vr "__base" ty_int) (vr "__s" ty_int) ty_int;
                     vr "__l" ty_int;
                   ]
                   ty_slice)))))

(** starts_with(slice, prefix) -> Bool
    Compare prefix bytes against slice bytes *)
let slice_starts_with slice prefix =
  lett "__plen"
    (intr "string_len" [ prefix ] ty_int)
    (lett "__slen"
       (intr "slice_len" [ slice ] ty_int)
       (if_
          (bin Ast.Gt (vr "__plen" ty_int) (vr "__slen" ty_int) ty_bool)
          (lit_bool false)
          (lett "__src"
             (intr "slice_source" [ slice ] ty_string)
             (lett "__off"
                (intr "slice_start" [ slice ] ty_int)
                (lettm "__ok" (lit_bool true)
                   (seq
                      (mk ty_void
                         (CFor
                            ( loop "__i" ty_int,
                              mk ty_int (CRange (lit_int 0, vr "__plen" ty_int)),
                              if_
                                (bin Ast.Ne
                                   (intr "string_get_byte"
                                      [
                                        vr "__src" ty_string;
                                        bin Ast.Add (vr "__off" ty_int)
                                          (vr "__i" ty_int) ty_int;
                                      ]
                                      ty_int)
                                   (intr "string_get_byte"
                                      [ prefix; vr "__i" ty_int ]
                                      ty_int)
                                   ty_bool)
                                (seq (assign "__ok" (lit_bool false)) break_)
                                void ty_void )))
                      (vr "__ok" ty_bool)))))
          ty_bool))

(** get(slice, index) -> Option[Char]
    Bounds check, then read byte from source at offset+index *)
let slice_get slice index =
  lett "__slen"
    (intr "slice_len" [ slice ] ty_int)
    (if_
       (mk ty_bool
          (CLog
             ( Ast.Or,
               bin Ast.Lt index (lit_int 0) ty_bool,
               bin Ast.Ge index (vr "__slen" ty_int) ty_bool )))
       (mk
          (Ast.TyNamed ("Option", [ ty_char ]))
          (CCall (CKBuiltin "blorp_option_none", mk ty_void CVoid, [])))
       (lett "__src"
          (intr "slice_source" [ slice ] ty_string)
          (lett "__byte"
             (intr "string_get_byte"
                [
                  vr "__src" ty_string;
                  bin Ast.Add (intr "slice_start" [ slice ] ty_int) index ty_int;
                ]
                ty_int)
             (mk
                (Ast.TyNamed ("Option", [ ty_char ]))
                (CCall
                   ( CKBuiltin "blorp_option_some",
                     mk ty_void CVoid,
                     [ mk ty_ptr (CBox (vr "__byte" ty_int, ty_int)) ] )))))
       (Ast.TyNamed ("Option", [ ty_char ])))

(* ================================================================
   Dict IR bodies
   ================================================================ *)

(** keys(self) -> List[K]
    Iterates the order array, skips holes (slot < 0), collects keys.
    Sets elem_release from dict's key_release for ARC correctness. *)
let dict_keys result_ty self =
  let alloc = dict_list_alloc_intrinsic "keys" in
  lett "__n"
    (intr "dict_len" [ self ] ty_int)
    (lett "__result"
       (intr alloc [ vr "__n" ty_int ] result_ty)
       (seq
          (intr "list_set_elem_release"
             [
               vr "__result" result_ty;
               intr "dict_key_release_fn" [ self ] ty_ptr;
             ]
             ty_void)
          (lettm "__j" (lit_int 0)
             (seq
                (mk ty_void
                   (CFor
                      ( loop "__i" ty_int,
                        mk ty_int
                          (CRange
                             (lit_int 0, intr "dict_order_len" [ self ] ty_int)),
                        lett "__slot"
                          (intr "dict_order_get"
                             [ self; vr "__i" ty_int ]
                             ty_int)
                          (if_
                             (bin Ast.Ge (vr "__slot" ty_int) (lit_int 0)
                                ty_bool)
                             (let key =
                                intr "dict_key_at"
                                  [ self; vr "__slot" ty_int ]
                                  ty_ptr
                              in
                              seq
                                (intr "list_retain_for"
                                   [ vr "__result" result_ty; key ]
                                   ty_void)
                                (seq
                                   (intr "list_set"
                                      [
                                        vr "__result" result_ty;
                                        vr "__j" ty_int;
                                        key;
                                      ]
                                      ty_void)
                                   (assign "__j"
                                      (bin Ast.Add (vr "__j" ty_int) (lit_int 1)
                                         ty_int))))
                             void ty_void) )))
                (seq
                   (intr "list_set_len"
                      [ vr "__result" result_ty; vr "__j" ty_int ]
                      ty_void)
                   (vr "__result" result_ty))))))

(** values(self) -> List[V]
    Same pattern as keys but reads values and uses value_release. *)
let dict_values result_ty self =
  let alloc = dict_list_alloc_intrinsic "values" in
  lett "__n"
    (intr "dict_len" [ self ] ty_int)
    (lett "__result"
       (intr alloc [ vr "__n" ty_int ] result_ty)
       (seq
          (intr "list_set_elem_release"
             [
               vr "__result" result_ty;
               intr "dict_value_release_fn" [ self ] ty_ptr;
             ]
             ty_void)
          (lettm "__j" (lit_int 0)
             (seq
                (mk ty_void
                   (CFor
                      ( loop "__i" ty_int,
                        mk ty_int
                          (CRange
                             (lit_int 0, intr "dict_order_len" [ self ] ty_int)),
                        lett "__slot"
                          (intr "dict_order_get"
                             [ self; vr "__i" ty_int ]
                             ty_int)
                          (if_
                             (bin Ast.Ge (vr "__slot" ty_int) (lit_int 0)
                                ty_bool)
                             (let value =
                                intr "dict_value_at"
                                  [ self; vr "__slot" ty_int ]
                                  ty_ptr
                              in
                              seq
                                (intr "list_retain_for"
                                   [ vr "__result" result_ty; value ]
                                   ty_void)
                                (seq
                                   (intr "list_set"
                                      [
                                        vr "__result" result_ty;
                                        vr "__j" ty_int;
                                        value;
                                      ]
                                      ty_void)
                                   (assign "__j"
                                      (bin Ast.Add (vr "__j" ty_int) (lit_int 1)
                                         ty_int))))
                             void ty_void) )))
                (seq
                   (intr "list_set_len"
                      [ vr "__result" result_ty; vr "__j" ty_int ]
                      ty_void)
                   (vr "__result" result_ty))))))

type dict_probe_strategy = DictProbeImmediate | DictProbeDispatched

let dict_probe_strategy_for_key ?reg key_ty =
  match Core_layout_type.hash_probe_layout ?reg key_ty with
  | Core_layout_type.HashProbeImmediate -> DictProbeImmediate
  | Core_layout_type.HashProbeDispatched -> DictProbeDispatched

let dict_probe_strategy_for_dict ?reg dict =
  match Core_layout_type.dict_type ?reg dict.ty with
  | Some dict_ty -> dict_probe_strategy_for_key ?reg dict_ty.dict_key_ty
  | None -> DictProbeDispatched

let dict_hash_probe strategy dict key =
  match strategy with
  | DictProbeImmediate -> intr "dict_hash_immediate" [ key ] ty_int
  | DictProbeDispatched -> intr "dict_hash" [ dict; key ] ty_int

let dict_eq_probe strategy dict lhs rhs =
  match strategy with
  | DictProbeImmediate -> intr "dict_eq_immediate" [ lhs; rhs ] ty_bool
  | DictProbeDispatched -> intr "dict_eq" [ dict; lhs; rhs ] ty_bool

(** Probe [dict] for [key], returning the slot index or -1.
    This mirrors the read-only half of runtime [blorp_dict_find_slot] so
    contains/get_or can avoid allocating Option values on hot lookup paths. *)
let dict_find_slot strategy dict key =
  let lookup_key = vr "__dict_lookup_key" ty_ptr in
  let hash = vr "__dict_lookup_hash" ty_int in
  let h2 = vr "__dict_lookup_h2" ty_int in
  let idx = vr "__dict_lookup_idx" ty_int in
  let found_slot = vr "__dict_lookup_found_slot" ty_int in
  let probes = vr "__dict_lookup_probes" ty_int in
  let meta = vr "__dict_lookup_meta" ty_int in
  let slot_matches =
    log Ast.And
      (bin Ast.Eq meta h2 ty_bool)
      (dict_eq_probe strategy dict
         (intr "dict_key_at" [ dict; idx ] ty_ptr)
         lookup_key)
  in
  let found_case = seq (assign "__dict_lookup_found_slot" idx) break_ in
  let empty_case = break_ in
  let advance_probe =
    seq
      (assign "__dict_lookup_idx"
         (intr "bit_and"
            [
              bin Ast.Add idx (lit_int 1) ty_int;
              intr "dict_mask" [ dict ] ty_int;
            ]
            ty_int))
      (assign "__dict_lookup_probes" (bin Ast.Add probes (lit_int 1) ty_int))
  in
  let scan_one =
    lett "__dict_lookup_meta"
      (intr "dict_meta_get" [ dict; idx ] ty_int)
      (if_ slot_matches found_case
         (if_
            (bin Ast.Eq meta (lit_int 255) ty_bool)
            empty_case advance_probe ty_void)
         ty_void)
  in
  let scan =
    while_
      (bin Ast.Le probes (intr "dict_capacity" [ dict ] ty_int) ty_bool)
      scan_one
  in
  lett "__dict_lookup_key" key
    (lett "__dict_lookup_hash"
       (dict_hash_probe strategy dict lookup_key)
       (lett "__dict_lookup_h2"
          (intr "bit_and"
             [ intr "shift_right" [ hash; lit_int 57 ] ty_int; lit_int 127 ]
             ty_int)
          (lettm "__dict_lookup_idx"
             (intr "bit_and" [ hash; intr "dict_mask" [ dict ] ty_int ] ty_int)
             (lettm "__dict_lookup_found_slot" (lit_int (-1))
                (lettm "__dict_lookup_probes" (lit_int 0) (seq scan found_slot))))))

let dict_get_or ?reg dict_ty self key default =
  let key_ty, value_ty = dict_key_value_tys ?reg dict_ty in
  let strategy = dict_probe_strategy_for_key ?reg key_ty in
  let slot = vr "__dict_get_or_slot" ty_int in
  let value = vr "__dict_get_or_value" ty_ptr in
  let unboxed_value = mk value_ty (CUnbox (value, value_ty)) in
  let found_result =
    if boxed_value_unbox_temp_requires_release ?reg value_ty default.loc then
      lett "__dict_get_or_unboxed" unboxed_value
        (seq
           (intr "dict_release_value_for" [ self; value ] ty_void)
           (vr "__dict_get_or_unboxed" value_ty))
    else unboxed_value
  in
  let found_value =
    lett "__dict_get_or_value"
      (intr "dict_value_at" [ self; slot ] ty_ptr)
      (seq (intr "dict_retain_value_for" [ self; value ] ty_void) found_result)
  in
  lett "__dict_get_or_slot"
    (dict_find_slot strategy self (key_as_ptr ?reg ~as_ty:key_ty key))
    (if_ (bin Ast.Ge slot (lit_int 0) ty_bool) found_value default value_ty)

(** entries(self) -> List[(K, V)]
    Materialize tuple entries by scanning insertion order directly. Each tuple
    is freshly produced and transferred into the result list. Tuple construction
    retains managed key/value aliases according to their concrete field types. *)
let dict_entries ?reg result_ty self =
  let pair_ty, key_ty, value_ty =
    match Core_layout_type.list_type ?reg result_ty with
    | Some list_ty -> (
        match list_ty.list_elem_ty with
        | Ast.TyTuple [ key_ty; value_ty ] as pair_ty ->
            (pair_ty, key_ty, value_ty)
        | _ ->
            let key_ty, value_ty = dict_key_value_tys ?reg self.ty in
            (Ast.TyTuple [ key_ty; value_ty ], key_ty, value_ty))
    | None -> (
        match list_elem_ty result_ty with
        | Ast.TyTuple [ key_ty; value_ty ] as pair_ty ->
            (pair_ty, key_ty, value_ty)
        | _ ->
            let key_ty, value_ty = dict_key_value_tys ?reg self.ty in
            (Ast.TyTuple [ key_ty; value_ty ], key_ty, value_ty))
  in
  let alloc = dict_list_alloc_intrinsic "entries" in
  lett "__n"
    (intr "dict_len" [ self ] ty_int)
    (lett "__result"
       (intr alloc [ vr "__n" ty_int ] result_ty)
       (seq
          (intr "list_set_elem_release"
             [ vr "__result" result_ty; intr "elem_release_fn" [] ty_ptr ]
             ty_void)
          (lettm "__j" (lit_int 0)
             (seq
                (mk ty_void
                   (CFor
                      ( loop "__i" ty_int,
                        mk ty_int
                          (CRange
                             (lit_int 0, intr "dict_order_len" [ self ] ty_int)),
                        lett "__dict_entries_slot"
                          (intr "dict_order_get"
                             [ self; vr "__i" ty_int ]
                             ty_int)
                          (if_
                             (bin Ast.Ge
                                (vr "__dict_entries_slot" ty_int)
                                (lit_int 0) ty_bool)
                             (let key_raw =
                                intr "dict_key_at"
                                  [ self; vr "__dict_entries_slot" ty_int ]
                                  ty_ptr
                              in
                              let value_raw =
                                intr "dict_value_at"
                                  [ self; vr "__dict_entries_slot" ty_int ]
                                  ty_ptr
                              in
                              let key = mk key_ty (CUnbox (key_raw, key_ty)) in
                              let value =
                                mk value_ty (CUnbox (value_raw, value_ty))
                              in
                              let pair = mk pair_ty (CTuple [ key; value ]) in
                              seq
                                (intr "list_set_owned"
                                   [
                                     vr "__result" result_ty;
                                     vr "__j" ty_int;
                                     pair;
                                   ]
                                   ty_void)
                                (assign "__j"
                                   (bin Ast.Add (vr "__j" ty_int) (lit_int 1)
                                      ty_int)))
                             void ty_void) )))
                (seq
                   (intr "list_set_len"
                      [ vr "__result" result_ty; vr "__j" ty_int ]
                      ty_void)
                   (vr "__result" result_ty))))))

(** Insert or update [key] -> [value] in an already-owned dict. This mirrors
    [blorp_dict_insert] using explicit Core slots: update releases the old
    value only when the dict owns values; insertion retains key/value before
    transferring them into the table. *)

let dict_contains ?reg dict_ty self key =
  let key_ty, _ = dict_key_value_tys ?reg dict_ty in
  let strategy = dict_probe_strategy_for_key ?reg key_ty in
  let lookup_key = vr "__dict_contains_key" ty_ptr in
  let hash = vr "__dict_contains_hash" ty_int in
  let h2 = vr "__dict_contains_h2" ty_int in
  let idx = vr "__dict_contains_idx" ty_int in
  let probes = vr "__dict_contains_probes" ty_int in
  let found = vr "__dict_contains_found" ty_bool in
  let meta = vr "__dict_contains_meta" ty_int in
  let slot_key = intr "dict_key_at" [ self; idx ] ty_ptr in
  let slot_matches =
    log Ast.And
      (bin Ast.Eq meta h2 ty_bool)
      (dict_eq_probe strategy self slot_key lookup_key)
  in
  let advance_probe =
    seq
      (assign "__dict_contains_idx"
         (intr "bit_and"
            [
              bin Ast.Add idx (lit_int 1) ty_int;
              intr "dict_mask" [ self ] ty_int;
            ]
            ty_int))
      (assign "__dict_contains_probes" (bin Ast.Add probes (lit_int 1) ty_int))
  in
  let scan_one =
    lett "__dict_contains_meta"
      (intr "dict_meta_get" [ self; idx ] ty_int)
      (if_ slot_matches
         (seq (assign "__dict_contains_found" (lit_bool true)) break_)
         (if_
            (bin Ast.Eq meta (lit_int 255) ty_bool)
            break_ advance_probe ty_void)
         ty_void)
  in
  let scan =
    while_
      (log Ast.And
         (bin Ast.Le probes (intr "dict_capacity" [ self ] ty_int) ty_bool)
         (bin Ast.Eq found (lit_bool false) ty_bool))
      scan_one
  in
  lett "__dict_contains_key"
    (key_as_ptr ?reg ~as_ty:key_ty key)
    (lett "__dict_contains_hash"
       (dict_hash_probe strategy self lookup_key)
       (lett "__dict_contains_h2"
          (intr "bit_and"
             [ intr "shift_right" [ hash; lit_int 57 ] ty_int; lit_int 127 ]
             ty_int)
          (lettm "__dict_contains_idx"
             (intr "bit_and" [ hash; intr "dict_mask" [ self ] ty_int ] ty_int)
             (lettm "__dict_contains_probes" (lit_int 0)
                (lettm "__dict_contains_found" (lit_bool false) (seq scan found))))))

let dict_insert_retained ?reg ?(release_value_temp = false) dict key value =
  let strategy = dict_probe_strategy_for_dict ?reg dict in
  let insert_key = vr "__dict_insert_key" ty_ptr in
  let insert_value = vr "__dict_insert_value" ty_ptr in
  let hash = vr "__dict_insert_hash" ty_int in
  let h2 = vr "__dict_insert_h2" ty_int in
  let idx = vr "__dict_insert_idx" ty_int in
  let first_available = vr "__dict_insert_first_available" ty_int in
  let insert_slot = vr "__dict_insert_insert_slot" ty_int in
  let found_slot = vr "__dict_insert_found_slot" ty_int in
  let probes = vr "__dict_insert_probes" ty_int in
  let meta = vr "__dict_insert_meta" ty_int in
  let slot_key = intr "dict_key_at" [ dict; idx ] ty_ptr in
  let slot_matches =
    log Ast.And
      (bin Ast.Eq meta h2 ty_bool)
      (dict_eq_probe strategy dict slot_key insert_key)
  in
  let choose_insert_slot =
    mk ty_int
      (CIf (bin Ast.Ge first_available (lit_int 0) ty_bool, first_available, idx))
  in
  let found_case = seq (assign "__dict_insert_found_slot" idx) break_ in
  let empty_case =
    seq (assign "__dict_insert_insert_slot" choose_insert_slot) break_
  in
  let remember_deleted =
    if_
      (log Ast.And
         (bin Ast.Eq meta (lit_int 128) ty_bool)
         (bin Ast.Lt first_available (lit_int 0) ty_bool))
      (assign "__dict_insert_first_available" idx)
      void ty_void
  in
  let advance_probe =
    seq remember_deleted
      (seq
         (assign "__dict_insert_idx"
            (intr "bit_and"
               [
                 bin Ast.Add idx (lit_int 1) ty_int;
                 intr "dict_mask" [ dict ] ty_int;
               ]
               ty_int))
         (assign "__dict_insert_probes" (bin Ast.Add probes (lit_int 1) ty_int)))
  in
  let scan_one =
    lett "__dict_insert_meta"
      (intr "dict_meta_get" [ dict; idx ] ty_int)
      (if_ slot_matches found_case
         (if_
            (bin Ast.Eq meta (lit_int 255) ty_bool)
            empty_case advance_probe ty_void)
         ty_void)
  in
  let scan =
    while_
      (bin Ast.Le probes (intr "dict_capacity" [ dict ] ty_int) ty_bool)
      scan_one
  in
  let finalize_insert_slot =
    if_
      (log Ast.And
         (bin Ast.Lt insert_slot (lit_int 0) ty_bool)
         (bin Ast.Ge first_available (lit_int 0) ty_bool))
      (assign "__dict_insert_insert_slot" first_available)
      void ty_void
  in
  let update_existing =
    lett "__dict_insert_old_value"
      (intr "dict_value_at" [ dict; found_slot ] ty_ptr)
      (if_
         (bin Ast.Ne (vr "__dict_insert_old_value" ty_ptr) insert_value ty_bool)
         (seq
            (intr "dict_release_value_for"
               [ dict; vr "__dict_insert_old_value" ty_ptr ]
               ty_void)
            (seq
               (intr "dict_retain_value_for" [ dict; insert_value ] ty_void)
               (intr "dict_set_value_at"
                  [ dict; found_slot; insert_value ]
                  ty_void)))
         void ty_void)
  in
  let resize_if_needed =
    if_
      (bin Ast.Ge
         (vr "__dict_insert_new_len" ty_int)
         (intr "dict_grow_at" [ dict ] ty_int)
         ty_bool)
      (intr "dict_resize"
         [
           dict;
           bin Ast.Mul (intr "dict_capacity" [ dict ] ty_int) (lit_int 2) ty_int;
         ]
         ty_void)
      void ty_void
  in
  let insert_new =
    lett "__dict_insert_order_len"
      (intr "dict_order_len" [ dict ] ty_int)
      (lett "__dict_insert_new_len"
         (bin Ast.Add (intr "dict_len" [ dict ] ty_int) (lit_int 1) ty_int)
         (lett "__dict_insert_new_order_len"
            (bin Ast.Add
               (vr "__dict_insert_order_len" ty_int)
               (lit_int 1) ty_int)
            (seq
               (intr "dict_meta_set" [ dict; insert_slot; h2 ] ty_void)
               (seq
                  (intr "dict_retain_key_for" [ dict; insert_key ] ty_void)
                  (seq
                     (intr "dict_retain_value_for" [ dict; insert_value ]
                        ty_void)
                     (seq
                        (intr "dict_set_key_at"
                           [ dict; insert_slot; insert_key ]
                           ty_void)
                        (seq
                           (intr "dict_set_value_at"
                              [ dict; insert_slot; insert_value ]
                              ty_void)
                           (seq
                              (intr "dict_order_index_set"
                                 [
                                   dict;
                                   insert_slot;
                                   vr "__dict_insert_order_len" ty_int;
                                 ]
                                 ty_void)
                              (seq
                                 (intr "dict_order_set"
                                    [
                                      dict;
                                      vr "__dict_insert_order_len" ty_int;
                                      insert_slot;
                                    ]
                                    ty_void)
                                 (seq
                                    (intr "dict_set_order_len"
                                       [
                                         dict;
                                         vr "__dict_insert_new_order_len" ty_int;
                                       ]
                                       ty_void)
                                    (seq
                                       (intr "dict_set_len"
                                          [
                                            dict;
                                            vr "__dict_insert_new_len" ty_int;
                                          ]
                                          ty_void)
                                       resize_if_needed)))))))))))
  in
  let release_insert_value_temp =
    if release_value_temp then
      intr "dict_release_value_for" [ dict; insert_value ] ty_void
    else void
  in
  lett "__dict_insert_key" key
    (lett "__dict_insert_value" value
       (lett "__dict_insert_hash"
          (dict_hash_probe strategy dict insert_key)
          (lett "__dict_insert_h2"
             (intr "bit_and"
                [ intr "shift_right" [ hash; lit_int 57 ] ty_int; lit_int 127 ]
                ty_int)
             (lettm "__dict_insert_idx"
                (intr "bit_and"
                   [ hash; intr "dict_mask" [ dict ] ty_int ]
                   ty_int)
                (lettm "__dict_insert_first_available" (lit_int (-1))
                   (lettm "__dict_insert_insert_slot" (lit_int (-1))
                      (lettm "__dict_insert_found_slot" (lit_int (-1))
                         (lettm "__dict_insert_probes" (lit_int 0)
                            (seq scan
                               (seq finalize_insert_slot
                                  (seq
                                     (if_
                                        (bin Ast.Ge found_slot (lit_int 0)
                                           ty_bool)
                                        update_existing insert_new ty_void)
                                     release_insert_value_temp)))))))))))

let dict_set ?reg dict_ty self key value =
  let key_ty, value_ty = dict_key_value_tys ?reg dict_ty in
  let value_ptr_layout =
    Core_layout_type.boxed_storage_value_pointer_argument ?reg value_ty
  in
  let release_value_temp =
    boxed_value_pointer_temp_requires_release ?reg value_ty value.loc
  in
  let result = vr "__result" dict_ty in
  lettm "__result"
    (intr (dict_reuse_boundary "set") [ self ] dict_ty)
    (seq
       (dict_insert_retained ?reg ~release_value_temp result
          (key_as_ptr ?reg ~as_ty:key_ty key)
          (pointer_argument_as_ptr value_ptr_layout value value_ty))
       result)

(* ================================================================
   Dispatch
   ================================================================ *)

let synthesize_body_impl_unsafe reg ~(func_name : string)
    ~(module_path : string) ~(params : core_param list)
    ~(checked_params : std_body_checked_params) ~(return_ty : Ast.type_expr) :
    core option =
  let func_name = source_func_name ~module_path func_name in
  let is_concrete_tensor ty = is_concrete_tensor ?reg ty in
  let unsupported_concrete_numeric_tensor ty =
    unsupported_concrete_numeric_tensor ?reg ty
  in
  let unsupported_numeric_tensor_error =
    unsupported_numeric_tensor_error ?reg
  in
  let tensor_elem_info = tensor_elem_info ?reg in
  let tensor_reduce = tensor_reduce ?reg in
  let tensor_dot = tensor_dot ?reg in
  let first_is_list () =
    match params with
    | { cp_ty = Ast.TyNamed ("List", _); _ } :: _ -> true
    | _ -> false
  in
  let first_is_parallel_list () =
    match params with
    | { cp_ty = Ast.TyNamed ("ParallelList", _); _ } :: _ -> true
    | _ -> false
  in
  let parallel_vector_view_ty ty =
    match Codegen_types.normalize_type ty with
    | Ast.TyArray (elem_ty, [ dim ]) ->
        Some (Ast.TyNamed ("ParallelVector", [ elem_ty; dim ]))
    | _ -> None
  in
  let parallel_matrix_view_ty ty =
    match Codegen_types.normalize_type ty with
    | Ast.TyArray (elem_ty, [ rows; cols ]) ->
        Some (Ast.TyNamed ("ParallelMatrix", [ elem_ty; rows; cols ]))
    | _ -> None
  in
  let first_is_vector () =
    match params with
    | { cp_ty; _ } :: _ -> Option.is_some (parallel_vector_view_ty cp_ty)
    | _ -> false
  in
  let first_is_matrix () =
    match params with
    | { cp_ty; _ } :: _ -> Option.is_some (parallel_matrix_view_ty cp_ty)
    | _ -> false
  in
  let first_is_string () =
    match params with
    | { cp_ty = Ast.TyNamed ("String", _); _ } :: _ -> true
    | _ -> false
  in
  let first_is_set () =
    match params with
    | { cp_ty = Ast.TyNamed ("Set", _); _ } :: _ -> true
    | _ -> false
  in
  let first_is_dict () =
    match params with
    | { cp_ty = Ast.TyNamed ("Dict", _); _ } :: _ -> true
    | _ -> false
  in
  let has_type_vars_param p = Codegen_types.has_type_vars p.cp_ty in
  let has_type_vars_params ps = List.exists has_type_vars_param ps in
  let first_is_slice () =
    match params with
    | { cp_ty = Ast.TyNamed ("StringSlice", _); _ } :: _ -> true
    | _ -> false
  in
  let first_is_bytes () =
    match params with
    | { cp_ty = Ast.TyNamed ("Bytes", _); _ } :: _ -> true
    | _ -> false
  in
  let return_is_list () =
    match return_ty with Ast.TyNamed ("List", _) -> true | _ -> false
  in
  let return_is_parallel_list () =
    match return_ty with Ast.TyNamed ("ParallelList", _) -> true | _ -> false
  in
  let return_is_vector () =
    match Codegen_types.normalize_type return_ty with
    | Ast.TyArray (_, [ _ ]) -> true
    | _ -> false
  in
  let return_is_matrix () =
    match Codegen_types.normalize_type return_ty with
    | Ast.TyArray (_, [ _; _ ]) -> true
    | _ -> false
  in
  let return_is_string () =
    match return_ty with Ast.TyNamed ("String", _) -> true | _ -> false
  in
  let arity n = List.length params = n in
  let with_params1 f = match params with [ p0 ] -> f p0 | _ -> None in
  let with_params2 f = match params with [ p0; p1 ] -> f p0 p1 | _ -> None in
  let with_params3 f =
    match params with [ p0; p1; p2 ] -> f p0 p1 p2 | _ -> None
  in
  let with_params5 f =
    match params with [ p0; p1; p2; p3; p4 ] -> f p0 p1 p2 p3 p4 | _ -> None
  in
  let single_int_param () =
    match params with
    | [ { cp_ty = Ast.TyNamed ("Int", _); _ } ] -> true
    | _ -> false
  in
  let with_list1 f =
    match params with
    | [ ({ cp_ty = Ast.TyNamed ("List", _); _ } as p0) ] -> Some (f p0)
    | _ -> None
  in
  let with_list2 f =
    match params with
    | ({ cp_ty = Ast.TyNamed ("List", _); _ } as p0) :: [ p1 ] -> Some (f p0 p1)
    | _ -> None
  in
  let with_vector2 f =
    match params with
    | ({ cp_ty; _ } as p0) :: [ p1 ]
      when Option.is_some (parallel_vector_view_ty cp_ty) ->
        Some (f p0 p1)
    | _ -> None
  in
  let with_matrix2 f =
    match params with
    | ({ cp_ty; _ } as p0) :: [ p1 ]
      when Option.is_some (parallel_matrix_view_ty cp_ty) ->
        Some (f p0 p1)
    | _ -> None
  in
  let with_list3 f =
    match params with
    | ({ cp_ty = Ast.TyNamed ("List", _); _ } as p0) :: [ p1; p2 ] ->
        Some (f p0 p1 p2)
    | _ -> None
  in
  let with_list4 f =
    match params with
    | ({ cp_ty = Ast.TyNamed ("List", _); _ } as p0) :: [ p1; p2; p3 ] ->
        Some (f p0 p1 p2 p3)
    | _ -> None
  in
  let with_parallel_list2 f =
    match params with
    | ({ cp_ty = Ast.TyNamed ("ParallelList", _); _ } as p0) :: [ p1 ] ->
        Some (f p0 p1)
    | _ -> None
  in
  let with_dict1 f =
    match params with
    | [ ({ cp_ty = Ast.TyNamed ("Dict", _); _ } as p0) ] -> Some (f p0)
    | _ -> None
  in
  let with_string1 f =
    match params with
    | [ ({ cp_ty = Ast.TyNamed ("String", _); _ } as p0) ] -> Some (f p0)
    | _ -> None
  in
  let param_at index = std_body_checked_param checked_params index in
  match func_name with
  | "parallel" when first_is_list () && return_is_list () ->
      with_list2 (fun self_p body_p ->
          let view_ty =
            match self_p.cp_ty with
            | Ast.TyNamed ("List", [ elem_ty ]) ->
                Ast.TyNamed ("ParallelList", [ elem_ty ])
            | _ -> self_p.cp_ty
          in
          let view = { (param self_p) with ty = view_ty } in
          closure_call (param body_p) [ view ] return_ty)
  | "parallel" when first_is_vector () && return_is_vector () ->
      with_vector2 (fun self_p body_p ->
          let view_ty =
            Option.value
              (parallel_vector_view_ty self_p.cp_ty)
              ~default:self_p.cp_ty
          in
          let view = { (param self_p) with ty = view_ty } in
          closure_call (param body_p) [ view ] return_ty)
  | "parallel" when first_is_matrix () && return_is_matrix () ->
      with_matrix2 (fun self_p body_p ->
          let view_ty =
            Option.value
              (parallel_matrix_view_ty self_p.cp_ty)
              ~default:self_p.cp_ty
          in
          let view = { (param self_p) with ty = view_ty } in
          closure_call (param body_p) [ view ] return_ty)
  | "length" when first_is_list () ->
      with_list1 (fun p -> intr "list_len" [ param p ] return_ty)
  | "length" when first_is_string () ->
      with_string1 (fun p -> intr "string_len" [ param p ] return_ty)
  | ("append" | "__unsafe_list_append") when first_is_list () ->
      with_list2 (fun self_p elem_p ->
          list_append self_p.cp_ty (param self_p) (param elem_p))
  | "get" when first_is_list () ->
      with_list2 (fun self_p idx_p ->
          list_get self_p.cp_ty return_ty (param self_p) (param idx_p))
  | "__unsafe_list_set_index" when first_is_list () ->
      with_list3 (fun self_p idx_p elem_p ->
          list_set_index self_p.cp_ty (param self_p) (param idx_p)
            (param elem_p))
  | "get_or" when first_is_list () ->
      with_list3 (fun self_p idx_p default_p ->
          list_get_or self_p.cp_ty return_ty (param self_p) (param idx_p)
            (param default_p))
  | "set" when first_is_list () ->
      with_list3 (fun self_p idx_p elem_p ->
          list_set_public self_p.cp_ty (param self_p) (param idx_p)
            (param elem_p))
  | "__unsafe_list_swap" when first_is_list () ->
      with_list3 (fun self_p i_p j_p ->
          list_swap self_p.cp_ty (param self_p) (param i_p) (param j_p))
  | "__unsafe_list_remove" when first_is_list () ->
      with_list2 (fun self_p idx_p ->
          list_remove self_p.cp_ty (param self_p) (param idx_p))
  | "__unsafe_list_insert" when first_is_list () ->
      with_list3 (fun self_p idx_p elem_p ->
          list_insert self_p.cp_ty (param self_p) (param idx_p) (param elem_p))
  | "__unsafe_list_tail" when first_is_list () ->
      with_list1 (fun self_p -> list_tail self_p.cp_ty (param self_p))
  | ("reverse" | "__unsafe_list_reverse") when first_is_list () ->
      with_list1 (fun self_p -> list_reverse self_p.cp_ty (param self_p))
  | "concat" when first_is_list () && return_is_list () ->
      with_list2 (fun a_p b_p -> list_concat a_p.cp_ty (param a_p) (param b_p))
  | "take" when first_is_list () && return_is_list () ->
      with_list2 (fun self_p n_p ->
          list_take self_p.cp_ty (param self_p) (param n_p))
  | "drop" when first_is_list () && return_is_list () ->
      with_list2 (fun self_p n_p ->
          list_drop self_p.cp_ty (param self_p) (param n_p))
  | "flatten" when first_is_list () && return_is_list () ->
      with_list1 (fun lists_p ->
          list_flatten lists_p.cp_ty return_ty (param lists_p))
  | "map" when first_is_list () ->
      with_list2 (fun self_p f_p ->
          list_map self_p.cp_ty return_ty (param self_p) (param f_p))
  | "concurrent" when first_is_list () && return_is_list () ->
      with_list3 (fun self_p limit_p f_p ->
          list_concurrent_collect self_p.cp_ty return_ty (param self_p)
            (param limit_p) (param f_p))
  | "__concurrent_timeout_ms" when first_is_list () && return_is_list () ->
      with_list4 (fun self_p limit_p timeout_p f_p ->
          list_concurrent_collect ~timeout:(param timeout_p) self_p.cp_ty
            return_ty (param self_p) (param limit_p) (param f_p))
  | "map_indexed" when first_is_list () ->
      with_list2 (fun self_p f_p ->
          list_map_indexed self_p.cp_ty return_ty (param self_p) (param f_p))
  | "filter" when first_is_list () ->
      with_list2 (fun self_p pred_p ->
          list_filter self_p.cp_ty (param self_p) (param pred_p))
  | "take_while" when first_is_list () ->
      with_list2 (fun self_p pred_p ->
          list_take_while self_p.cp_ty (param self_p) (param pred_p))
  | "drop_while" when first_is_list () ->
      with_list2 (fun self_p pred_p ->
          list_drop_while self_p.cp_ty (param self_p) (param pred_p))
  | "partition" when first_is_list () ->
      with_list2 (fun self_p pred_p ->
          list_partition self_p.cp_ty return_ty (param self_p) (param pred_p))
  | "flat_map" when first_is_list () ->
      with_list2 (fun self_p f_p ->
          list_flat_map self_p.cp_ty return_ty (param self_p) (param f_p))
  | "filter_map" when first_is_list () ->
      with_list2 (fun self_p f_p ->
          list_filter_map self_p.cp_ty return_ty (param self_p) (param f_p))
  | "filter_map" when first_is_parallel_list () && return_is_parallel_list () ->
      with_parallel_list2 (fun self_p f_p ->
          list_filter_map self_p.cp_ty return_ty (param self_p) (param f_p))
  | "fold_left"
    when first_is_list () && not (Codegen_types.has_type_vars return_ty) ->
      with_list3 (fun self_p init_p f_p ->
          list_fold_left self_p.cp_ty return_ty (param self_p) (param init_p)
            (param f_p))
  | "fold_right"
    when first_is_list () && not (Codegen_types.has_type_vars return_ty) ->
      with_list3 (fun self_p init_p f_p ->
          list_fold_right self_p.cp_ty return_ty (param self_p) (param init_p)
            (param f_p))
  | "all" when first_is_list () ->
      with_list2 (fun self_p pred_p ->
          list_all self_p.cp_ty (param self_p) (param pred_p))
  | "any" when first_is_list () ->
      with_list2 (fun self_p pred_p ->
          list_any self_p.cp_ty (param self_p) (param pred_p))
  | "count" when first_is_list () ->
      with_list2 (fun self_p pred_p ->
          list_count self_p.cp_ty (param self_p) (param pred_p))
  | "for_each" when first_is_list () ->
      with_list2 (fun self_p f_p ->
          list_for_each self_p.cp_ty (param self_p) (param f_p))
  | "find_index" when first_is_list () ->
      with_list2 (fun self_p pred_p ->
          list_find_index self_p.cp_ty return_ty (param self_p) (param pred_p))
  | "find" when first_is_list () ->
      with_list2 (fun self_p pred_p ->
          list_find self_p.cp_ty return_ty (param self_p) (param pred_p))
  | "binary_search" when first_is_list () ->
      with_list2 (fun self_p target_p ->
          list_binary_search self_p.cp_ty return_ty (param self_p)
            (param target_p))
  | "binary_search_by" when first_is_list () ->
      with_list3 (fun self_p target_p compare_p ->
          list_binary_search_by self_p.cp_ty return_ty (param self_p)
            (param target_p) (param compare_p))
  | "min_by" when first_is_list () ->
      with_list2 (fun self_p f_p ->
          let key_ty =
            match f_p.cp_ty with
            | Ast.TyFunc { return; _ } -> return
            | _ -> ty_ptr
          in
          list_min_max_by self_p.cp_ty key_ty return_ty (param self_p)
            (param f_p) Ast.Lt)
  | "max_by" when first_is_list () ->
      with_list2 (fun self_p f_p ->
          let key_ty =
            match f_p.cp_ty with
            | Ast.TyFunc { return; _ } -> return
            | _ -> ty_ptr
          in
          list_min_max_by self_p.cp_ty key_ty return_ty (param self_p)
            (param f_p) Ast.Gt)
  | "sort" when first_is_list () ->
      with_list1 (fun self_p -> list_sort self_p.cp_ty (param self_p) Ast.Le)
  | ("sort_by" | "sort_desc_by") when first_is_list () ->
      with_list2 (fun self_p key_fn_p ->
          let key_ty =
            match key_fn_p.cp_ty with
            | Ast.TyFunc { return; _ } -> return
            | _ -> ty_ptr
          in
          let compare_op =
            if func_name = "sort_desc_by" then Ast.Ge else Ast.Le
          in
          list_sort_by self_p.cp_ty key_ty (param self_p) (param key_fn_p)
            compare_op)
  | "scan" when first_is_list () ->
      with_list3 (fun self_p init_p f_p ->
          list_scan self_p.cp_ty return_ty (param self_p) (param init_p)
            (param f_p))
  | "enumerate" when first_is_list () && return_is_list () ->
      with_list1 (fun self_p ->
          list_enumerate self_p.cp_ty return_ty (param self_p))
  | "zip" when first_is_list () && return_is_list () ->
      with_list2 (fun list_a_p list_b_p ->
          list_zip list_a_p.cp_ty list_b_p.cp_ty return_ty (param list_a_p)
            (param list_b_p))
  | "zip_with" when first_is_list () ->
      with_list3 (fun list_a_p list_b_p f_p ->
          list_zip_with list_a_p.cp_ty list_b_p.cp_ty return_ty (param list_a_p)
            (param list_b_p) (param f_p))
  | "unzip" when first_is_list () ->
      with_list1 (fun self_p ->
          list_unzip self_p.cp_ty return_ty (param self_p))
  | "repeat" when return_is_list () && List.length params = 2 ->
      let elem_p = param_at 0 in
      let n_p = param_at 1 in
      Some (list_repeat return_ty (param elem_p) (param n_p))
  | "intersperse"
    when first_is_list () && return_is_list () && List.length params = 2 ->
      with_list2 (fun self_p sep_p ->
          list_intersperse self_p.cp_ty (param self_p) (param sep_p))
  | "windows"
    when first_is_list () && return_is_list () && List.length params = 2 ->
      with_list2 (fun self_p n_p ->
          list_windows self_p.cp_ty return_ty (param self_p) (param n_p))
  | "chunks"
    when first_is_list () && return_is_list () && List.length params = 2 ->
      with_list2 (fun self_p n_p ->
          list_chunks self_p.cp_ty return_ty (param self_p) (param n_p))
  | "range"
    when return_ty = Ast.TyNamed ("List", [ ty_int ]) && List.length params = 2
    ->
      let start_p = param_at 0 in
      let stop_p = param_at 1 in
      Some (list_range return_ty (param start_p) (param stop_p))
  | "unique" when first_is_list () && return_is_list () ->
      with_list1 (fun self_p -> list_unique self_p.cp_ty (param self_p))
  (* ---- String operations ---- *)
  | "substring" when first_is_string () && arity 3 ->
      (* substring(self, start, len):
         Clamp start/len to valid range, alloc new string, copy bytes.
         Matches C semantics: negative start → 0, negative len → 0,
         start+len beyond end → clamp to end. *)
      let self_p = param_at 0 in
      let start_p = param_at 1 in
      let len_p = param_at 2 in
      let s = param self_p in
      let start = param start_p in
      let req_len = param len_p in
      Some
        (lett "__slen"
           (intr "string_len" [ s ] ty_int)
           (* Clamp start: max(0, min(start, slen)) *)
           (lett "__start"
              (mk ty_int
                 (CIf
                    ( bin Ast.Lt start (lit_int 0) ty_bool,
                      lit_int 0,
                      mk ty_int
                        (CIf
                           ( bin Ast.Gt start (vr "__slen" ty_int) ty_bool,
                             vr "__slen" ty_int,
                             start )) )))
              (* Clamp len: max(0, min(req_len, slen - start)) *)
              (lett "__len"
                 (mk ty_int
                    (CIf
                       ( bin Ast.Le req_len (lit_int 0) ty_bool,
                         lit_int 0,
                         mk ty_int
                           (CIf
                              ( bin Ast.Gt
                                  (bin Ast.Add (vr "__start" ty_int) req_len
                                     ty_int)
                                  (vr "__slen" ty_int) ty_bool,
                                bin Ast.Sub (vr "__slen" ty_int)
                                  (vr "__start" ty_int) ty_int,
                                req_len )) )))
                 (lett "__result"
                    (intr "string_alloc" [ vr "__len" ty_int ] ty_string)
                    (seq
                       (mk ty_void
                          (CFor
                             ( loop "__i" ty_int,
                               mk ty_int (CRange (lit_int 0, vr "__len" ty_int)),
                               intr "string_set_byte"
                                 [
                                   vr "__result" ty_string;
                                   vr "__i" ty_int;
                                   intr "string_get_byte"
                                     [
                                       s;
                                       bin Ast.Add (vr "__start" ty_int)
                                         (vr "__i" ty_int) ty_int;
                                     ]
                                     ty_int;
                                 ]
                                 ty_void )))
                       (seq
                          (intr "string_set_len"
                             [ vr "__result" ty_string; vr "__len" ty_int ]
                             ty_void)
                          (vr "__result" ty_string)))))))
  | "contains" when first_is_string () && arity 2 ->
      (* contains(self, needle): check if needle appears anywhere in self.
         Uses starts_with-style byte comparison at each offset. *)
      let self_p = param_at 0 in
      let needle_p = param_at 1 in
      let s = param self_p in
      let needle = param needle_p in
      let i = vr "__i" ty_int in
      let j = vr "__j" ty_int in
      Some
        (lett "__slen"
           (intr "string_len" [ s ] ty_int)
           (lett "__nlen"
              (intr "string_len" [ needle ] ty_int)
              (mk ty_bool
                 (CIf
                    ( bin Ast.Eq (vr "__nlen" ty_int) (lit_int 0) ty_bool,
                      mk ty_bool (CLit (Ast.LitBool true)),
                      (* empty needle always found *)
                      mk ty_bool
                        (CIf
                           ( bin Ast.Gt (vr "__nlen" ty_int)
                               (vr "__slen" ty_int) ty_bool,
                             mk ty_bool (CLit (Ast.LitBool false)),
                             lettm "__found"
                               (mk ty_bool (CLit (Ast.LitBool false)))
                               (seq
                                  (mk ty_void
                                     (CFor
                                        ( loop "__i" ty_int,
                                          (* iterate from 0 to slen - nlen (inclusive) *)
                                          mk ty_int
                                            (CRange
                                               ( lit_int 0,
                                                 bin Ast.Add
                                                   (bin Ast.Sub
                                                      (vr "__slen" ty_int)
                                                      (vr "__nlen" ty_int)
                                                      ty_int)
                                                   (lit_int 1) ty_int )),
                                          (* check if needle matches at offset i *)
                                          lettm "__match"
                                            (mk ty_bool
                                               (CLit (Ast.LitBool true)))
                                            (seq
                                               (mk ty_void
                                                  (CFor
                                                     ( loop "__j" ty_int,
                                                       mk ty_int
                                                         (CRange
                                                            ( lit_int 0,
                                                              vr "__nlen" ty_int
                                                            )),
                                                       mk ty_void
                                                         (CIf
                                                            ( bin Ast.Ne
                                                                (intr
                                                                   "string_get_byte"
                                                                   [
                                                                     s;
                                                                     bin Ast.Add
                                                                       i j
                                                                       ty_int;
                                                                   ]
                                                                   ty_int)
                                                                (intr
                                                                   "string_get_byte"
                                                                   [ needle; j ]
                                                                   ty_int)
                                                                ty_bool,
                                                              seq
                                                                (mk ty_void
                                                                   (CAssign
                                                                      ( Var.named
                                                                          "__match",
                                                                        mk
                                                                          ty_bool
                                                                          (CLit
                                                                             (Ast
                                                                              .LitBool
                                                                                false))
                                                                      )))
                                                                (mk ty_void
                                                                   CBreak),
                                                              void )) )))
                                               (mk ty_void
                                                  (CIf
                                                     ( vr "__match" ty_bool,
                                                       seq
                                                         (mk ty_void
                                                            (CAssign
                                                               ( Var.named
                                                                   "__found",
                                                                 mk ty_bool
                                                                   (CLit
                                                                      (Ast
                                                                       .LitBool
                                                                         true))
                                                               )))
                                                         (mk ty_void CBreak),
                                                       void )))) )))
                                  (vr "__found" ty_bool)) )) )))))
  | "raw_index_of" when first_is_string () && arity 2 ->
      (* raw_index_of(self, needle) -> Int: return byte offset or -1 *)
      let self_p = param_at 0 in
      let needle_p = param_at 1 in
      let s = param self_p in
      let needle = param needle_p in
      let i = vr "__i" ty_int in
      let j = vr "__j" ty_int in
      Some
        (lett "__slen"
           (intr "string_len" [ s ] ty_int)
           (lett "__nlen"
              (intr "string_len" [ needle ] ty_int)
              (mk ty_int
                 (CIf
                    ( bin Ast.Eq (vr "__nlen" ty_int) (lit_int 0) ty_bool,
                      lit_int 0,
                      mk ty_int
                        (CIf
                           ( bin Ast.Gt (vr "__nlen" ty_int)
                               (vr "__slen" ty_int) ty_bool,
                             mk ty_int (CLit (Ast.LitInt (-1L))),
                             lettm "__pos"
                               (mk ty_int (CLit (Ast.LitInt (-1L))))
                               (seq
                                  (mk ty_void
                                     (CFor
                                        ( loop "__i" ty_int,
                                          mk ty_int
                                            (CRange
                                               ( lit_int 0,
                                                 bin Ast.Add
                                                   (bin Ast.Sub
                                                      (vr "__slen" ty_int)
                                                      (vr "__nlen" ty_int)
                                                      ty_int)
                                                   (lit_int 1) ty_int )),
                                          lettm "__match"
                                            (mk ty_bool
                                               (CLit (Ast.LitBool true)))
                                            (seq
                                               (mk ty_void
                                                  (CFor
                                                     ( loop "__j" ty_int,
                                                       mk ty_int
                                                         (CRange
                                                            ( lit_int 0,
                                                              vr "__nlen" ty_int
                                                            )),
                                                       mk ty_void
                                                         (CIf
                                                            ( bin Ast.Ne
                                                                (intr
                                                                   "string_get_byte"
                                                                   [
                                                                     s;
                                                                     bin Ast.Add
                                                                       i j
                                                                       ty_int;
                                                                   ]
                                                                   ty_int)
                                                                (intr
                                                                   "string_get_byte"
                                                                   [ needle; j ]
                                                                   ty_int)
                                                                ty_bool,
                                                              seq
                                                                (mk ty_void
                                                                   (CAssign
                                                                      ( Var.named
                                                                          "__match",
                                                                        mk
                                                                          ty_bool
                                                                          (CLit
                                                                             (Ast
                                                                              .LitBool
                                                                                false))
                                                                      )))
                                                                (mk ty_void
                                                                   CBreak),
                                                              void )) )))
                                               (mk ty_void
                                                  (CIf
                                                     ( vr "__match" ty_bool,
                                                       seq
                                                         (mk ty_void
                                                            (CAssign
                                                               ( Var.named
                                                                   "__pos",
                                                                 i )))
                                                         (mk ty_void CBreak),
                                                       void )))) )))
                                  (vr "__pos" ty_int)) )) )))))
  | "count" when first_is_string () && arity 2 ->
      (* count(self, needle) -> Int: count non-overlapping occurrences *)
      let self_p = param_at 0 in
      let needle_p = param_at 1 in
      let s = param self_p in
      let needle = param needle_p in
      Some
        (lett "__slen"
           (intr "string_len" [ s ] ty_int)
           (lett "__nlen"
              (intr "string_len" [ needle ] ty_int)
              (mk ty_int
                 (CIf
                    ( mk ty_bool
                        (CLog
                           ( Ast.Or,
                             bin Ast.Eq (vr "__nlen" ty_int) (lit_int 0) ty_bool,
                             bin Ast.Gt (vr "__nlen" ty_int)
                               (vr "__slen" ty_int) ty_bool )),
                      lit_int 0,
                      (* Use a while loop: advance by nlen on match, 1 on miss *)
                      lettm "__cnt" (lit_int 0)
                        (lettm "__pos" (lit_int 0)
                           (seq
                              (mk ty_void
                                 (CWhile
                                    ( bin Ast.Le
                                        (bin Ast.Add (vr "__pos" ty_int)
                                           (vr "__nlen" ty_int) ty_int)
                                        (vr "__slen" ty_int) ty_bool,
                                      lettm "__match"
                                        (mk ty_bool (CLit (Ast.LitBool true)))
                                        (seq
                                           (mk ty_void
                                              (CFor
                                                 ( loop "__j" ty_int,
                                                   mk ty_int
                                                     (CRange
                                                        ( lit_int 0,
                                                          vr "__nlen" ty_int )),
                                                   mk ty_void
                                                     (CIf
                                                        ( bin Ast.Ne
                                                            (intr
                                                               "string_get_byte"
                                                               [
                                                                 s;
                                                                 bin Ast.Add
                                                                   (vr "__pos"
                                                                      ty_int)
                                                                   (vr "__j"
                                                                      ty_int)
                                                                   ty_int;
                                                               ]
                                                               ty_int)
                                                            (intr
                                                               "string_get_byte"
                                                               [
                                                                 needle;
                                                                 vr "__j" ty_int;
                                                               ]
                                                               ty_int)
                                                            ty_bool,
                                                          seq
                                                            (mk ty_void
                                                               (CAssign
                                                                  ( Var.named
                                                                      "__match",
                                                                    mk ty_bool
                                                                      (CLit
                                                                         (Ast
                                                                          .LitBool
                                                                            false))
                                                                  )))
                                                            (mk ty_void CBreak),
                                                          void )) )))
                                           (mk ty_void
                                              (CIf
                                                 ( vr "__match" ty_bool,
                                                   seq
                                                     (mk ty_void
                                                        (CAssign
                                                           ( Var.named "__cnt",
                                                             bin Ast.Add
                                                               (vr "__cnt"
                                                                  ty_int)
                                                               (lit_int 1)
                                                               ty_int )))
                                                     (mk ty_void
                                                        (CAssign
                                                           ( Var.named "__pos",
                                                             bin Ast.Add
                                                               (vr "__pos"
                                                                  ty_int)
                                                               (vr "__nlen"
                                                                  ty_int) ty_int
                                                           ))),
                                                   mk ty_void
                                                     (CAssign
                                                        ( Var.named "__pos",
                                                          bin Ast.Add
                                                            (vr "__pos" ty_int)
                                                            (lit_int 1) ty_int
                                                        )) )))) )))
                              (vr "__cnt" ty_int))) )))))
  (* ---- Tier 2a: String mutation building blocks ---- *)
  (* from_char stays CKBuiltin — needs UTF-8 multi-byte encoding *)
  | "pad_left" when first_is_string () && arity 3 ->
      let s = param (param_at 0) in
      let width = param (param_at 1) in
      let fill = param (param_at 2) in
      Some
        (lett "__slen"
           (intr "string_len" [ s ] ty_int)
           (mk ty_string
              (CIf
                 ( bin Ast.Ge (vr "__slen" ty_int) width ty_bool,
                   s,
                   lett "__pad"
                     (bin Ast.Sub width (vr "__slen" ty_int) ty_int)
                     (lett "__r"
                        (intr "string_alloc" [ width ] ty_string)
                        (seq
                           (mk ty_void
                              (CFor
                                 ( loop "__i" ty_int,
                                   mk ty_int
                                     (CRange (lit_int 0, vr "__pad" ty_int)),
                                   intr "string_set_byte"
                                     [
                                       vr "__r" ty_string; vr "__i" ty_int; fill;
                                     ]
                                     ty_void )))
                           (seq
                              (mk ty_void
                                 (CFor
                                    ( loop "__i" ty_int,
                                      mk ty_int
                                        (CRange (lit_int 0, vr "__slen" ty_int)),
                                      intr "string_set_byte"
                                        [
                                          vr "__r" ty_string;
                                          bin Ast.Add (vr "__pad" ty_int)
                                            (vr "__i" ty_int) ty_int;
                                          intr "string_get_byte"
                                            [ s; vr "__i" ty_int ]
                                            ty_int;
                                        ]
                                        ty_void )))
                              (seq
                                 (intr "string_set_len"
                                    [ vr "__r" ty_string; width ]
                                    ty_void)
                                 (vr "__r" ty_string))))) ))))
  | "pad_right" when first_is_string () && arity 3 ->
      let s = param (param_at 0) in
      let width = param (param_at 1) in
      let fill = param (param_at 2) in
      Some
        (lett "__slen"
           (intr "string_len" [ s ] ty_int)
           (mk ty_string
              (CIf
                 ( bin Ast.Ge (vr "__slen" ty_int) width ty_bool,
                   s,
                   lett "__r"
                     (intr "string_alloc" [ width ] ty_string)
                     (seq
                        (mk ty_void
                           (CFor
                              ( loop "__i" ty_int,
                                mk ty_int
                                  (CRange (lit_int 0, vr "__slen" ty_int)),
                                intr "string_set_byte"
                                  [
                                    vr "__r" ty_string;
                                    vr "__i" ty_int;
                                    intr "string_get_byte"
                                      [ s; vr "__i" ty_int ]
                                      ty_int;
                                  ]
                                  ty_void )))
                        (seq
                           (mk ty_void
                              (CFor
                                 ( loop "__i" ty_int,
                                   mk ty_int
                                     (CRange (vr "__slen" ty_int, width)),
                                   intr "string_set_byte"
                                     [
                                       vr "__r" ty_string; vr "__i" ty_int; fill;
                                     ]
                                     ty_void )))
                           (seq
                              (intr "string_set_len"
                                 [ vr "__r" ty_string; width ]
                                 ty_void)
                              (vr "__r" ty_string)))) ))))
  | "center" when first_is_string () && arity 3 ->
      let s = param (param_at 0) in
      let width = param (param_at 1) in
      let fill = param (param_at 2) in
      Some
        (lett "__slen"
           (intr "string_len" [ s ] ty_int)
           (mk ty_string
              (CIf
                 ( bin Ast.Ge (vr "__slen" ty_int) width ty_bool,
                   s,
                   lett "__total_pad"
                     (bin Ast.Sub width (vr "__slen" ty_int) ty_int)
                     (lett "__left_pad"
                        (bin Ast.Div (vr "__total_pad" ty_int) (lit_int 2)
                           ty_int)
                        (lett "__r"
                           (intr "string_alloc" [ width ] ty_string)
                           (seq
                              (mk ty_void
                                 (CFor
                                    ( loop "__i" ty_int,
                                      mk ty_int
                                        (CRange
                                           (lit_int 0, vr "__left_pad" ty_int)),
                                      intr "string_set_byte"
                                        [
                                          vr "__r" ty_string;
                                          vr "__i" ty_int;
                                          fill;
                                        ]
                                        ty_void )))
                              (seq
                                 (mk ty_void
                                    (CFor
                                       ( loop "__i" ty_int,
                                         mk ty_int
                                           (CRange
                                              (lit_int 0, vr "__slen" ty_int)),
                                         intr "string_set_byte"
                                           [
                                             vr "__r" ty_string;
                                             bin Ast.Add
                                               (vr "__left_pad" ty_int)
                                               (vr "__i" ty_int) ty_int;
                                             intr "string_get_byte"
                                               [ s; vr "__i" ty_int ]
                                               ty_int;
                                           ]
                                           ty_void )))
                                 (seq
                                    (mk ty_void
                                       (CFor
                                          ( loop "__i" ty_int,
                                            mk ty_int
                                              (CRange
                                                 ( bin Ast.Add
                                                     (vr "__left_pad" ty_int)
                                                     (vr "__slen" ty_int) ty_int,
                                                   width )),
                                            intr "string_set_byte"
                                              [
                                                vr "__r" ty_string;
                                                vr "__i" ty_int;
                                                fill;
                                              ]
                                              ty_void )))
                                    (seq
                                       (intr "string_set_len"
                                          [ vr "__r" ty_string; width ]
                                          ty_void)
                                       (vr "__r" ty_string))))))) ))))
  | "raw_last_index_of" when first_is_string () && arity 2 ->
      let s = param (param_at 0) in
      let needle = param (param_at 1) in
      Some
        (lett "__slen"
           (intr "string_len" [ s ] ty_int)
           (lett "__nlen"
              (intr "string_len" [ needle ] ty_int)
              (mk ty_int
                 (CIf
                    ( bin Ast.Eq (vr "__nlen" ty_int) (lit_int 0) ty_bool,
                      vr "__slen" ty_int,
                      (* empty needle → return string length, matching C *)
                      mk ty_int
                        (CIf
                           ( bin Ast.Gt (vr "__nlen" ty_int)
                               (vr "__slen" ty_int) ty_bool,
                             mk ty_int (CLit (Ast.LitInt (-1L))),
                             lettm "__pos"
                               (mk ty_int (CLit (Ast.LitInt (-1L))))
                               (seq
                                  (mk ty_void
                                     (CFor
                                        ( loop "__i" ty_int,
                                          mk ty_int
                                            (CRange
                                               ( lit_int 0,
                                                 bin Ast.Add
                                                   (bin Ast.Sub
                                                      (vr "__slen" ty_int)
                                                      (vr "__nlen" ty_int)
                                                      ty_int)
                                                   (lit_int 1) ty_int )),
                                          lett "__off"
                                            (bin Ast.Sub
                                               (bin Ast.Sub (vr "__slen" ty_int)
                                                  (vr "__nlen" ty_int) ty_int)
                                               (vr "__i" ty_int) ty_int)
                                            (lettm "__m"
                                               (mk ty_bool
                                                  (CLit (Ast.LitBool true)))
                                               (seq
                                                  (mk ty_void
                                                     (CFor
                                                        ( loop "__j" ty_int,
                                                          mk ty_int
                                                            (CRange
                                                               ( lit_int 0,
                                                                 vr "__nlen"
                                                                   ty_int )),
                                                          mk ty_void
                                                            (CIf
                                                               ( bin Ast.Ne
                                                                   (intr
                                                                      "string_get_byte"
                                                                      [
                                                                        s;
                                                                        bin
                                                                          Ast
                                                                          .Add
                                                                          (vr
                                                                             "__off"
                                                                             ty_int)
                                                                          (vr
                                                                             "__j"
                                                                             ty_int)
                                                                          ty_int;
                                                                      ]
                                                                      ty_int)
                                                                   (intr
                                                                      "string_get_byte"
                                                                      [
                                                                        needle;
                                                                        vr "__j"
                                                                          ty_int;
                                                                      ]
                                                                      ty_int)
                                                                   ty_bool,
                                                                 seq
                                                                   (mk ty_void
                                                                      (CAssign
                                                                         ( Var
                                                                           .named
                                                                             "__m",
                                                                           mk
                                                                             ty_bool
                                                                             (CLit
                                                                                (
                                                                                Ast
                                                                                .LitBool
                                                                                false))
                                                                         )))
                                                                   (mk ty_void
                                                                      CBreak),
                                                                 void )) )))
                                                  (mk ty_void
                                                     (CIf
                                                        ( vr "__m" ty_bool,
                                                          seq
                                                            (mk ty_void
                                                               (CAssign
                                                                  ( Var.named
                                                                      "__pos",
                                                                    vr "__off"
                                                                      ty_int )))
                                                            (mk ty_void CBreak),
                                                          void ))))) )))
                                  (vr "__pos" ty_int)) )) )))))
  | "trim_chars" when first_is_string () && arity 2 ->
      let s = param (param_at 0) in
      let chars = param (param_at 1) in
      Some
        (lett "__slen"
           (intr "string_len" [ s ] ty_int)
           (lett "__clen"
              (intr "string_len" [ chars ] ty_int)
              (lettm "__start" (lit_int 0)
                 (seq
                    (mk ty_void
                       (CWhile
                          ( bin Ast.Lt (vr "__start" ty_int)
                              (vr "__slen" ty_int) ty_bool,
                            lett "__byte"
                              (intr "string_get_byte"
                                 [ s; vr "__start" ty_int ]
                                 ty_int)
                              (lettm "__found"
                                 (mk ty_bool (CLit (Ast.LitBool false)))
                                 (seq
                                    (mk ty_void
                                       (CFor
                                          ( loop "__j" ty_int,
                                            mk ty_int
                                              (CRange
                                                 (lit_int 0, vr "__clen" ty_int)),
                                            mk ty_void
                                              (CIf
                                                 ( bin Ast.Eq
                                                     (vr "__byte" ty_int)
                                                     (intr "string_get_byte"
                                                        [
                                                          chars; vr "__j" ty_int;
                                                        ]
                                                        ty_int)
                                                     ty_bool,
                                                   seq
                                                     (mk ty_void
                                                        (CAssign
                                                           ( Var.named "__found",
                                                             mk ty_bool
                                                               (CLit
                                                                  (Ast.LitBool
                                                                     true)) )))
                                                     (mk ty_void CBreak),
                                                   void )) )))
                                    (mk ty_void
                                       (CIf
                                          ( vr "__found" ty_bool,
                                            mk ty_void
                                              (CAssign
                                                 ( Var.named "__start",
                                                   bin Ast.Add
                                                     (vr "__start" ty_int)
                                                     (lit_int 1) ty_int )),
                                            mk ty_void CBreak ))))) )))
                    (lettm "__end" (vr "__slen" ty_int)
                       (seq
                          (mk ty_void
                             (CWhile
                                ( bin Ast.Gt (vr "__end" ty_int)
                                    (vr "__start" ty_int) ty_bool,
                                  lett "__byte"
                                    (intr "string_get_byte"
                                       [
                                         s;
                                         bin Ast.Sub (vr "__end" ty_int)
                                           (lit_int 1) ty_int;
                                       ]
                                       ty_int)
                                    (lettm "__found"
                                       (mk ty_bool (CLit (Ast.LitBool false)))
                                       (seq
                                          (mk ty_void
                                             (CFor
                                                ( loop "__j" ty_int,
                                                  mk ty_int
                                                    (CRange
                                                       ( lit_int 0,
                                                         vr "__clen" ty_int )),
                                                  mk ty_void
                                                    (CIf
                                                       ( bin Ast.Eq
                                                           (vr "__byte" ty_int)
                                                           (intr
                                                              "string_get_byte"
                                                              [
                                                                chars;
                                                                vr "__j" ty_int;
                                                              ]
                                                              ty_int)
                                                           ty_bool,
                                                         seq
                                                           (mk ty_void
                                                              (CAssign
                                                                 ( Var.named
                                                                     "__found",
                                                                   mk ty_bool
                                                                     (CLit
                                                                        (Ast
                                                                         .LitBool
                                                                           true))
                                                                 )))
                                                           (mk ty_void CBreak),
                                                         void )) )))
                                          (mk ty_void
                                             (CIf
                                                ( vr "__found" ty_bool,
                                                  mk ty_void
                                                    (CAssign
                                                       ( Var.named "__end",
                                                         bin Ast.Sub
                                                           (vr "__end" ty_int)
                                                           (lit_int 1) ty_int )),
                                                  mk ty_void CBreak ))))) )))
                          (lett "__len"
                             (bin Ast.Sub (vr "__end" ty_int)
                                (vr "__start" ty_int) ty_int)
                             (lett "__r"
                                (intr "string_alloc"
                                   [ vr "__len" ty_int ]
                                   ty_string)
                                (seq
                                   (mk ty_void
                                      (CFor
                                         ( loop "__i" ty_int,
                                           mk ty_int
                                             (CRange
                                                (lit_int 0, vr "__len" ty_int)),
                                           intr "string_set_byte"
                                             [
                                               vr "__r" ty_string;
                                               vr "__i" ty_int;
                                               intr "string_get_byte"
                                                 [
                                                   s;
                                                   bin Ast.Add
                                                     (vr "__start" ty_int)
                                                     (vr "__i" ty_int) ty_int;
                                                 ]
                                                 ty_int;
                                             ]
                                             ty_void )))
                                   (seq
                                      (intr "string_set_len"
                                         [
                                           vr "__r" ty_string; vr "__len" ty_int;
                                         ]
                                         ty_void)
                                      (vr "__r" ty_string)))))))))))
  | "repeat" when first_is_string () && arity 2 ->
      (* repeat(self, n): alloc n*len, copy self n times *)
      let s = param (param_at 0) in
      let n = param (param_at 1) in
      Some
        (lett "__slen"
           (intr "string_len" [ s ] ty_int)
           (mk ty_string
              (CIf
                 ( mk ty_bool
                     (CLog
                        ( Ast.Or,
                          bin Ast.Le n (lit_int 0) ty_bool,
                          bin Ast.Eq (vr "__slen" ty_int) (lit_int 0) ty_bool )),
                   intr "string_alloc" [ lit_int 0 ] ty_string,
                   lett "__total"
                     (bin Ast.Mul (vr "__slen" ty_int) n ty_int)
                     (lett "__r"
                        (intr "string_alloc" [ vr "__total" ty_int ] ty_string)
                        (seq
                           (mk ty_void
                              (CFor
                                 ( loop "__rep" ty_int,
                                   mk ty_int (CRange (lit_int 0, n)),
                                   mk ty_void
                                     (CFor
                                        ( loop "__i" ty_int,
                                          mk ty_int
                                            (CRange
                                               (lit_int 0, vr "__slen" ty_int)),
                                          intr "string_set_byte"
                                            [
                                              vr "__r" ty_string;
                                              bin Ast.Add
                                                (bin Ast.Mul (vr "__rep" ty_int)
                                                   (vr "__slen" ty_int) ty_int)
                                                (vr "__i" ty_int) ty_int;
                                              intr "string_get_byte"
                                                [ s; vr "__i" ty_int ]
                                                ty_int;
                                            ]
                                            ty_void )) )))
                           (seq
                              (intr "string_set_len"
                                 [ vr "__r" ty_string; vr "__total" ty_int ]
                                 ty_void)
                              (vr "__r" ty_string)))) ))))
  | "reverse" when first_is_string () && arity 1 ->
      (* reverse(self): alloc same-length, copy bytes in reverse *)
      let s = param (param_at 0) in
      Some
        (lett "__slen"
           (intr "string_len" [ s ] ty_int)
           (mk ty_string
              (CIf
                 ( bin Ast.Le (vr "__slen" ty_int) (lit_int 1) ty_bool,
                   s,
                   (* empty or single char: return as-is *)
                   lett "__r"
                     (intr "string_alloc" [ vr "__slen" ty_int ] ty_string)
                     (seq
                        (mk ty_void
                           (CFor
                              ( loop "__i" ty_int,
                                mk ty_int
                                  (CRange (lit_int 0, vr "__slen" ty_int)),
                                intr "string_set_byte"
                                  [
                                    vr "__r" ty_string;
                                    vr "__i" ty_int;
                                    intr "string_get_byte"
                                      [
                                        s;
                                        bin Ast.Sub
                                          (bin Ast.Sub (vr "__slen" ty_int)
                                             (lit_int 1) ty_int)
                                          (vr "__i" ty_int) ty_int;
                                      ]
                                      ty_int;
                                  ]
                                  ty_void )))
                        (seq
                           (intr "string_set_len"
                              [ vr "__r" ty_string; vr "__slen" ty_int ]
                              ty_void)
                           (vr "__r" ty_string))) ))))
  | "drop_left" when first_is_string () && arity 2 ->
      (* drop_left(self, n) = substring(self, n, len - n) *)
      let s = param (param_at 0) in
      let n = param (param_at 1) in
      Some
        (lett "__slen"
           (intr "string_len" [ s ] ty_int)
           (lett "__start"
              (mk ty_int
                 (CIf
                    ( bin Ast.Lt n (lit_int 0) ty_bool,
                      lit_int 0,
                      mk ty_int
                        (CIf
                           ( bin Ast.Gt n (vr "__slen" ty_int) ty_bool,
                             vr "__slen" ty_int,
                             n )) )))
              (lett "__len"
                 (bin Ast.Sub (vr "__slen" ty_int) (vr "__start" ty_int) ty_int)
                 (lett "__r"
                    (intr "string_alloc" [ vr "__len" ty_int ] ty_string)
                    (seq
                       (mk ty_void
                          (CFor
                             ( loop "__i" ty_int,
                               mk ty_int (CRange (lit_int 0, vr "__len" ty_int)),
                               intr "string_set_byte"
                                 [
                                   vr "__r" ty_string;
                                   vr "__i" ty_int;
                                   intr "string_get_byte"
                                     [
                                       s;
                                       bin Ast.Add (vr "__start" ty_int)
                                         (vr "__i" ty_int) ty_int;
                                     ]
                                     ty_int;
                                 ]
                                 ty_void )))
                       (seq
                          (intr "string_set_len"
                             [ vr "__r" ty_string; vr "__len" ty_int ]
                             ty_void)
                          (vr "__r" ty_string)))))))
  | "take_left" when first_is_string () && arity 2 ->
      (* take_left(self, n) = substring(self, 0, n) *)
      let s = param (param_at 0) in
      let n = param (param_at 1) in
      Some
        (lett "__slen"
           (intr "string_len" [ s ] ty_int)
           (lett "__len"
              (mk ty_int
                 (CIf
                    ( bin Ast.Le n (lit_int 0) ty_bool,
                      lit_int 0,
                      mk ty_int
                        (CIf
                           ( bin Ast.Gt n (vr "__slen" ty_int) ty_bool,
                             vr "__slen" ty_int,
                             n )) )))
              (lett "__r"
                 (intr "string_alloc" [ vr "__len" ty_int ] ty_string)
                 (seq
                    (mk ty_void
                       (CFor
                          ( loop "__i" ty_int,
                            mk ty_int (CRange (lit_int 0, vr "__len" ty_int)),
                            intr "string_set_byte"
                              [
                                vr "__r" ty_string;
                                vr "__i" ty_int;
                                intr "string_get_byte"
                                  [ s; vr "__i" ty_int ]
                                  ty_int;
                              ]
                              ty_void )))
                    (seq
                       (intr "string_set_len"
                          [ vr "__r" ty_string; vr "__len" ty_int ]
                          ty_void)
                       (vr "__r" ty_string))))))
  | "take_right" when first_is_string () && arity 2 ->
      (* take_right(self, n) = substring(self, len - n, n) *)
      let s = param (param_at 0) in
      let n = param (param_at 1) in
      Some
        (lett "__slen"
           (intr "string_len" [ s ] ty_int)
           (lett "__n"
              (mk ty_int
                 (CIf
                    ( bin Ast.Le n (lit_int 0) ty_bool,
                      lit_int 0,
                      mk ty_int
                        (CIf
                           ( bin Ast.Gt n (vr "__slen" ty_int) ty_bool,
                             vr "__slen" ty_int,
                             n )) )))
              (lett "__start"
                 (bin Ast.Sub (vr "__slen" ty_int) (vr "__n" ty_int) ty_int)
                 (lett "__r"
                    (intr "string_alloc" [ vr "__n" ty_int ] ty_string)
                    (seq
                       (mk ty_void
                          (CFor
                             ( loop "__i" ty_int,
                               mk ty_int (CRange (lit_int 0, vr "__n" ty_int)),
                               intr "string_set_byte"
                                 [
                                   vr "__r" ty_string;
                                   vr "__i" ty_int;
                                   intr "string_get_byte"
                                     [
                                       s;
                                       bin Ast.Add (vr "__start" ty_int)
                                         (vr "__i" ty_int) ty_int;
                                     ]
                                     ty_int;
                                 ]
                                 ty_void )))
                       (seq
                          (intr "string_set_len"
                             [ vr "__r" ty_string; vr "__n" ty_int ]
                             ty_void)
                          (vr "__r" ty_string)))))))
  | "drop_right" when first_is_string () && arity 2 ->
      (* drop_right(self, n) = take_left(self, len - n) *)
      let s = param (param_at 0) in
      let n = param (param_at 1) in
      Some
        (lett "__slen"
           (intr "string_len" [ s ] ty_int)
           (lett "__len"
              (mk ty_int
                 (CIf
                    ( bin Ast.Le n (lit_int 0) ty_bool,
                      vr "__slen" ty_int,
                      mk ty_int
                        (CIf
                           ( bin Ast.Ge n (vr "__slen" ty_int) ty_bool,
                             lit_int 0,
                             bin Ast.Sub (vr "__slen" ty_int) n ty_int )) )))
              (lett "__r"
                 (intr "string_alloc" [ vr "__len" ty_int ] ty_string)
                 (seq
                    (mk ty_void
                       (CFor
                          ( loop "__i" ty_int,
                            mk ty_int (CRange (lit_int 0, vr "__len" ty_int)),
                            intr "string_set_byte"
                              [
                                vr "__r" ty_string;
                                vr "__i" ty_int;
                                intr "string_get_byte"
                                  [ s; vr "__i" ty_int ]
                                  ty_int;
                              ]
                              ty_void )))
                    (seq
                       (intr "string_set_len"
                          [ vr "__r" ty_string; vr "__len" ty_int ]
                          ty_void)
                       (vr "__r" ty_string))))))
  (* ---- Tier 2b: Trimming ---- *)
  | "trim_left" when first_is_string () && arity 1 ->
      (* Find first non-whitespace byte, substring from there *)
      let s = param (param_at 0) in
      (* is_ws defined as top-level helper *)
      Some
        (lett "__slen"
           (intr "string_len" [ s ] ty_int)
           (lettm "__start" (lit_int 0)
              (seq
                 (mk ty_void
                    (CWhile
                       ( mk ty_bool
                           (CLog
                              ( Ast.And,
                                bin Ast.Lt (vr "__start" ty_int)
                                  (vr "__slen" ty_int) ty_bool,
                                is_ws
                                  (intr "string_get_byte"
                                     [ s; vr "__start" ty_int ]
                                     ty_int) )),
                         mk ty_void
                           (CAssign
                              ( Var.named "__start",
                                bin Ast.Add (vr "__start" ty_int) (lit_int 1)
                                  ty_int )) )))
                 (* result = substring from __start *)
                 (lett "__len"
                    (bin Ast.Sub (vr "__slen" ty_int) (vr "__start" ty_int)
                       ty_int)
                    (lett "__r"
                       (intr "string_alloc" [ vr "__len" ty_int ] ty_string)
                       (seq
                          (mk ty_void
                             (CFor
                                ( loop "__i" ty_int,
                                  mk ty_int
                                    (CRange (lit_int 0, vr "__len" ty_int)),
                                  intr "string_set_byte"
                                    [
                                      vr "__r" ty_string;
                                      vr "__i" ty_int;
                                      intr "string_get_byte"
                                        [
                                          s;
                                          bin Ast.Add (vr "__start" ty_int)
                                            (vr "__i" ty_int) ty_int;
                                        ]
                                        ty_int;
                                    ]
                                    ty_void )))
                          (seq
                             (intr "string_set_len"
                                [ vr "__r" ty_string; vr "__len" ty_int ]
                                ty_void)
                             (vr "__r" ty_string))))))))
  | "trim_right" when first_is_string () && arity 1 ->
      let s = param (param_at 0) in
      (* is_ws defined as top-level helper *)
      Some
        (lett "__slen"
           (intr "string_len" [ s ] ty_int)
           (lettm "__end" (vr "__slen" ty_int)
              (seq
                 (mk ty_void
                    (CWhile
                       ( mk ty_bool
                           (CLog
                              ( Ast.And,
                                bin Ast.Gt (vr "__end" ty_int) (lit_int 0)
                                  ty_bool,
                                is_ws
                                  (intr "string_get_byte"
                                     [
                                       s;
                                       bin Ast.Sub (vr "__end" ty_int)
                                         (lit_int 1) ty_int;
                                     ]
                                     ty_int) )),
                         mk ty_void
                           (CAssign
                              ( Var.named "__end",
                                bin Ast.Sub (vr "__end" ty_int) (lit_int 1)
                                  ty_int )) )))
                 (lett "__r"
                    (intr "string_alloc" [ vr "__end" ty_int ] ty_string)
                    (seq
                       (mk ty_void
                          (CFor
                             ( loop "__i" ty_int,
                               mk ty_int (CRange (lit_int 0, vr "__end" ty_int)),
                               intr "string_set_byte"
                                 [
                                   vr "__r" ty_string;
                                   vr "__i" ty_int;
                                   intr "string_get_byte"
                                     [ s; vr "__i" ty_int ]
                                     ty_int;
                                 ]
                                 ty_void )))
                       (seq
                          (intr "string_set_len"
                             [ vr "__r" ty_string; vr "__end" ty_int ]
                             ty_void)
                          (vr "__r" ty_string)))))))
  | "trim" when first_is_string () && arity 1 ->
      (* trim = trim_left + trim_right: find start and end, then substring *)
      let s = param (param_at 0) in
      (* is_ws defined as top-level helper *)
      Some
        (lett "__slen"
           (intr "string_len" [ s ] ty_int)
           (lettm "__start" (lit_int 0)
              (seq
                 (mk ty_void
                    (CWhile
                       ( mk ty_bool
                           (CLog
                              ( Ast.And,
                                bin Ast.Lt (vr "__start" ty_int)
                                  (vr "__slen" ty_int) ty_bool,
                                is_ws
                                  (intr "string_get_byte"
                                     [ s; vr "__start" ty_int ]
                                     ty_int) )),
                         mk ty_void
                           (CAssign
                              ( Var.named "__start",
                                bin Ast.Add (vr "__start" ty_int) (lit_int 1)
                                  ty_int )) )))
                 (lettm "__end" (vr "__slen" ty_int)
                    (seq
                       (mk ty_void
                          (CWhile
                             ( mk ty_bool
                                 (CLog
                                    ( Ast.And,
                                      bin Ast.Gt (vr "__end" ty_int)
                                        (vr "__start" ty_int) ty_bool,
                                      is_ws
                                        (intr "string_get_byte"
                                           [
                                             s;
                                             bin Ast.Sub (vr "__end" ty_int)
                                               (lit_int 1) ty_int;
                                           ]
                                           ty_int) )),
                               mk ty_void
                                 (CAssign
                                    ( Var.named "__end",
                                      bin Ast.Sub (vr "__end" ty_int)
                                        (lit_int 1) ty_int )) )))
                       (lett "__len"
                          (bin Ast.Sub (vr "__end" ty_int) (vr "__start" ty_int)
                             ty_int)
                          (lett "__r"
                             (intr "string_alloc"
                                [ vr "__len" ty_int ]
                                ty_string)
                             (seq
                                (mk ty_void
                                   (CFor
                                      ( loop "__i" ty_int,
                                        mk ty_int
                                          (CRange (lit_int 0, vr "__len" ty_int)),
                                        intr "string_set_byte"
                                          [
                                            vr "__r" ty_string;
                                            vr "__i" ty_int;
                                            intr "string_get_byte"
                                              [
                                                s;
                                                bin Ast.Add
                                                  (vr "__start" ty_int)
                                                  (vr "__i" ty_int) ty_int;
                                              ]
                                              ty_int;
                                          ]
                                          ty_void )))
                                (seq
                                   (intr "string_set_len"
                                      [ vr "__r" ty_string; vr "__len" ty_int ]
                                      ty_void)
                                   (vr "__r" ty_string))))))))))
  (* ---- Tier 2c: Case conversion ---- *)
  | "capitalize" when first_is_string () && arity 1 ->
      (* Uppercase first letter found (at any position), lowercase all subsequent letters *)
      let s = param (param_at 0) in
      let byte = vr "__byte" ty_int in
      let is_upper b =
        mk ty_bool
          (CLog
             ( Ast.And,
               bin Ast.Ge b (lit_int 65) ty_bool,
               bin Ast.Le b (lit_int 90) ty_bool ))
      in
      let is_lower b =
        mk ty_bool
          (CLog
             ( Ast.And,
               bin Ast.Ge b (lit_int 97) ty_bool,
               bin Ast.Le b (lit_int 122) ty_bool ))
      in
      Some
        (lett "__slen"
           (intr "string_len" [ s ] ty_int)
           (mk ty_string
              (CIf
                 ( bin Ast.Eq (vr "__slen" ty_int) (lit_int 0) ty_bool,
                   intr "string_alloc" [ lit_int 0 ] ty_string,
                   lett "__r"
                     (intr "string_alloc" [ vr "__slen" ty_int ] ty_string)
                     (seq
                        (lettm "__first_done"
                           (mk ty_bool (CLit (Ast.LitBool false)))
                           (mk ty_void
                              (CFor
                                 ( loop "__i" ty_int,
                                   mk ty_int
                                     (CRange (lit_int 0, vr "__slen" ty_int)),
                                   lett "__byte"
                                     (intr "string_get_byte"
                                        [ s; vr "__i" ty_int ]
                                        ty_int)
                                     (mk ty_void
                                        (CIf
                                           ( vr "__first_done" ty_bool,
                                             (* After first letter: lowercase any uppercase *)
                                             mk ty_void
                                               (CIf
                                                  ( is_upper byte,
                                                    intr "string_set_byte"
                                                      [
                                                        vr "__r" ty_string;
                                                        vr "__i" ty_int;
                                                        bin Ast.Add byte
                                                          (lit_int 32) ty_int;
                                                      ]
                                                      ty_void,
                                                    intr "string_set_byte"
                                                      [
                                                        vr "__r" ty_string;
                                                        vr "__i" ty_int;
                                                        byte;
                                                      ]
                                                      ty_void )),
                                             (* Before first letter found *)
                                             mk ty_void
                                               (CIf
                                                  ( is_lower byte,
                                                    (* First lowercase letter: uppercase it *)
                                                    seq
                                                      (intr "string_set_byte"
                                                         [
                                                           vr "__r" ty_string;
                                                           vr "__i" ty_int;
                                                           bin Ast.Sub byte
                                                             (lit_int 32) ty_int;
                                                         ]
                                                         ty_void)
                                                      (mk ty_void
                                                         (CAssign
                                                            ( Var.named
                                                                "__first_done",
                                                              mk ty_bool
                                                                (CLit
                                                                   (Ast.LitBool
                                                                      true)) ))),
                                                    mk ty_void
                                                      (CIf
                                                         ( is_upper byte,
                                                           (* First uppercase letter: keep it, mark done *)
                                                           seq
                                                             (intr
                                                                "string_set_byte"
                                                                [
                                                                  vr "__r"
                                                                    ty_string;
                                                                  vr "__i"
                                                                    ty_int;
                                                                  byte;
                                                                ]
                                                                ty_void)
                                                             (mk ty_void
                                                                (CAssign
                                                                   ( Var.named
                                                                       "__first_done",
                                                                     mk ty_bool
                                                                       (CLit
                                                                          (Ast
                                                                           .LitBool
                                                                             true))
                                                                   ))),
                                                           (* Non-letter: copy as-is *)
                                                           intr
                                                             "string_set_byte"
                                                             [
                                                               vr "__r"
                                                                 ty_string;
                                                               vr "__i" ty_int;
                                                               byte;
                                                             ]
                                                             ty_void )) )) )))
                                 ))))
                        (seq
                           (intr "string_set_len"
                              [ vr "__r" ty_string; vr "__slen" ty_int ]
                              ty_void)
                           (vr "__r" ty_string))) ))))
  | "title_case" when first_is_string () && arity 1 ->
      (* Uppercase first letter of each word, lowercase rest *)
      let s = param (param_at 0) in
      let byte = vr "__byte" ty_int in
      let is_upper b =
        mk ty_bool
          (CLog
             ( Ast.And,
               bin Ast.Ge b (lit_int 65) ty_bool,
               bin Ast.Le b (lit_int 90) ty_bool ))
      in
      let is_lower b =
        mk ty_bool
          (CLog
             ( Ast.And,
               bin Ast.Ge b (lit_int 97) ty_bool,
               bin Ast.Le b (lit_int 122) ty_bool ))
      in
      Some
        (lett "__slen"
           (intr "string_len" [ s ] ty_int)
           (lett "__r"
              (intr "string_alloc" [ vr "__slen" ty_int ] ty_string)
              (seq
                 (lettm "__word_start"
                    (mk ty_bool (CLit (Ast.LitBool true)))
                    (mk ty_void
                       (CFor
                          ( loop "__i" ty_int,
                            mk ty_int (CRange (lit_int 0, vr "__slen" ty_int)),
                            lett "__byte"
                              (intr "string_get_byte"
                                 [ s; vr "__i" ty_int ]
                                 ty_int)
                              (mk ty_void
                                 (CIf
                                    ( bin Ast.Eq byte (lit_int 32) ty_bool,
                                      (* Space: copy, mark word start *)
                                      seq
                                        (intr "string_set_byte"
                                           [
                                             vr "__r" ty_string;
                                             vr "__i" ty_int;
                                             byte;
                                           ]
                                           ty_void)
                                        (mk ty_void
                                           (CAssign
                                              ( Var.named "__word_start",
                                                mk ty_bool
                                                  (CLit (Ast.LitBool true)) ))),
                                      mk ty_void
                                        (CIf
                                           ( vr "__word_start" ty_bool,
                                             (* First char of word: uppercase if letter *)
                                             seq
                                               (mk ty_void
                                                  (CIf
                                                     ( is_lower byte,
                                                       intr "string_set_byte"
                                                         [
                                                           vr "__r" ty_string;
                                                           vr "__i" ty_int;
                                                           bin Ast.Sub byte
                                                             (lit_int 32) ty_int;
                                                         ]
                                                         ty_void,
                                                       intr "string_set_byte"
                                                         [
                                                           vr "__r" ty_string;
                                                           vr "__i" ty_int;
                                                           byte;
                                                         ]
                                                         ty_void )))
                                               (mk ty_void
                                                  (CAssign
                                                     ( Var.named "__word_start",
                                                       mk ty_bool
                                                         (CLit
                                                            (Ast.LitBool false))
                                                     ))),
                                             (* Middle of word: lowercase if uppercase *)
                                             seq
                                               (mk ty_void
                                                  (CIf
                                                     ( is_upper byte,
                                                       intr "string_set_byte"
                                                         [
                                                           vr "__r" ty_string;
                                                           vr "__i" ty_int;
                                                           bin Ast.Add byte
                                                             (lit_int 32) ty_int;
                                                         ]
                                                         ty_void,
                                                       intr "string_set_byte"
                                                         [
                                                           vr "__r" ty_string;
                                                           vr "__i" ty_int;
                                                           byte;
                                                         ]
                                                         ty_void )))
                                               (mk ty_void
                                                  (CAssign
                                                     ( Var.named "__word_start",
                                                       mk ty_bool
                                                         (CLit
                                                            (Ast.LitBool false))
                                                     ))) )) ))) ))))
                 (seq
                    (intr "string_set_len"
                       [ vr "__r" ty_string; vr "__slen" ty_int ]
                       ty_void)
                    (vr "__r" ty_string)))))
  | "longest_common_prefix" when first_is_string () && arity 2 ->
      let a = param (param_at 0) in
      let b = param (param_at 1) in
      Some
        (lett "__alen"
           (intr "string_len" [ a ] ty_int)
           (lett "__blen"
              (intr "string_len" [ b ] ty_int)
              (lett "__minlen"
                 (mk ty_int
                    (CIf
                       ( bin Ast.Lt (vr "__alen" ty_int) (vr "__blen" ty_int)
                           ty_bool,
                         vr "__alen" ty_int,
                         vr "__blen" ty_int )))
                 (lettm "__plen" (lit_int 0)
                    (seq
                       (mk ty_void
                          (CWhile
                             ( mk ty_bool
                                 (CLog
                                    ( Ast.And,
                                      bin Ast.Lt (vr "__plen" ty_int)
                                        (vr "__minlen" ty_int) ty_bool,
                                      bin Ast.Eq
                                        (intr "string_get_byte"
                                           [ a; vr "__plen" ty_int ]
                                           ty_int)
                                        (intr "string_get_byte"
                                           [ b; vr "__plen" ty_int ]
                                           ty_int)
                                        ty_bool )),
                               mk ty_void
                                 (CAssign
                                    ( Var.named "__plen",
                                      bin Ast.Add (vr "__plen" ty_int)
                                        (lit_int 1) ty_int )) )))
                       (* Build result: substring of a from 0..plen *)
                       (lett "__r"
                          (intr "string_alloc" [ vr "__plen" ty_int ] ty_string)
                          (seq
                             (mk ty_void
                                (CFor
                                   ( loop "__i" ty_int,
                                     mk ty_int
                                       (CRange (lit_int 0, vr "__plen" ty_int)),
                                     intr "string_set_byte"
                                       [
                                         vr "__r" ty_string;
                                         vr "__i" ty_int;
                                         intr "string_get_byte"
                                           [ a; vr "__i" ty_int ]
                                           ty_int;
                                       ]
                                       ty_void )))
                             (seq
                                (intr "string_set_len"
                                   [ vr "__r" ty_string; vr "__plen" ty_int ]
                                   ty_void)
                                (vr "__r" ty_string)))))))))
  | "hamming_distance_raw" when first_is_string () && arity 2 ->
      let a = param (param_at 0) in
      let b = param (param_at 1) in
      Some
        (lett "__len_a"
           (intr "string_len" [ a ] ty_int)
           (lett "__len_b"
              (intr "string_len" [ b ] ty_int)
              (if_
                 (bin Ast.Ne (vr "__len_a" ty_int) (vr "__len_b" ty_int) ty_bool)
                 (lit_int (-1))
                 (lettm "__diff" (lit_int 0)
                    (seq
                       (mk ty_void
                          (CFor
                             ( loop "__i" ty_int,
                               mk ty_int
                                 (CRange (lit_int 0, vr "__len_a" ty_int)),
                               mk ty_void
                                 (CIf
                                    ( bin Ast.Ne
                                        (intr "string_get_byte"
                                           [ a; vr "__i" ty_int ]
                                           ty_int)
                                        (intr "string_get_byte"
                                           [ b; vr "__i" ty_int ]
                                           ty_int)
                                        ty_bool,
                                      mk ty_void
                                        (CAssign
                                           ( Var.named "__diff",
                                             bin Ast.Add (vr "__diff" ty_int)
                                               (lit_int 1) ty_int )),
                                      void )) )))
                       (vr "__diff" ty_int)))
                 ty_int)))
  | "is_numeric" when first_is_string () && arity 1 ->
      Some (string_is_numeric (param (param_at 0)))
  | "is_ascii" when first_is_string () && arity 1 ->
      Some (string_is_ascii (param (param_at 0)))
  | "is_blank" when first_is_string () && arity 1 ->
      Some (string_is_blank (param (param_at 0)))
  | "is_lower" when first_is_string () && arity 1 ->
      Some (string_is_lower (param (param_at 0)))
  | "is_upper" when first_is_string () && arity 1 ->
      Some (string_is_upper (param (param_at 0)))
  | "starts_with" when first_is_string () && arity 2 ->
      let self_p = param_at 0 in
      let prefix_p = param_at 1 in
      Some (string_starts_with (param self_p) (param prefix_p))
  | "ends_with" when first_is_string () && arity 2 ->
      let self_p = param_at 0 in
      let suffix_p = param_at 1 in
      Some (string_ends_with (param self_p) (param suffix_p))
  | "replace" when first_is_string () && arity 3 ->
      let self_p = param_at 0 in
      let old_p = param_at 1 in
      let new_p = param_at 2 in
      Some (string_replace (param self_p) (param old_p) (param new_p))
  | "split" when first_is_string () && arity 2 ->
      let self_p = param_at 0 in
      let delim_p = param_at 1 in
      Some (string_split return_ty (param self_p) (param delim_p))
  (* ---- Builder operations ---- *)
  | "string" when return_is_string () && single_int_param () ->
      let cap = param (param_at 0) in
      Some (intr "string_alloc" [ cap ] ty_string)
  | "string_with_capacity" when arity 1 ->
      let cap = param (param_at 0) in
      Some (intr "string_alloc" [ cap ] ty_string)
  | "reserve" when first_is_string () && arity 2 ->
      let s = param (param_at 0) in
      let cap = param (param_at 1) in
      Some (intr "string_ensure_capacity" [ s; cap ] ty_string)
  | ("append_char" | "string_append_char") when first_is_string () && arity 2 ->
      (* UTF-8 encode the codepoint in IR, then use the COW/capacity primitive
         for owned string mutation. *)
      let s = param (param_at 0) in
      let c = param (param_at 1) in
      let set_byte offset byte =
        intr "string_set_byte"
          [
            vr "__r" ty_string;
            bin Ast.Add (vr "__slen" ty_int) (lit_int offset) ty_int;
            byte;
          ]
          ty_void
      in
      let shr value bits = intr "shift_right" [ value; lit_int bits ] ty_int in
      let band value mask = intr "bit_and" [ value; lit_int mask ] ty_int in
      let bor prefix value = intr "bit_or" [ lit_int prefix; value ] ty_int in
      let cont_byte value = bor 0x80 (band value 0x3F) in
      let replacement =
        seq
          (set_byte 0 (lit_int 0xEF))
          (seq (set_byte 1 (lit_int 0xBF)) (set_byte 2 (lit_int 0xBD)))
      in
      let write_one = set_byte 0 c in
      let write_two =
        seq (set_byte 0 (bor 0xC0 (shr c 6))) (set_byte 1 (cont_byte c))
      in
      let write_three =
        seq
          (set_byte 0 (bor 0xE0 (shr c 12)))
          (seq (set_byte 1 (cont_byte (shr c 6))) (set_byte 2 (cont_byte c)))
      in
      let write_four =
        seq
          (set_byte 0 (bor 0xF0 (shr c 18)))
          (seq
             (set_byte 1 (cont_byte (shr c 12)))
             (seq (set_byte 2 (cont_byte (shr c 6))) (set_byte 3 (cont_byte c))))
      in
      let char_len =
        if_
          (bin Ast.Lt c (lit_int 0) ty_bool)
          (lit_int 3)
          (if_
             (bin Ast.Le c (lit_int 0x7F) ty_bool)
             (lit_int 1)
             (if_
                (bin Ast.Le c (lit_int 0x7FF) ty_bool)
                (lit_int 2)
                (if_
                   (bin Ast.Le c (lit_int 0xFFFF) ty_bool)
                   (lit_int 3)
                   (if_
                      (bin Ast.Le c (lit_int 0x10FFFF) ty_bool)
                      (lit_int 4) (lit_int 3) ty_int)
                   ty_int)
                ty_int)
             ty_int)
          ty_int
      in
      let write_utf8 =
        if_
          (bin Ast.Lt c (lit_int 0) ty_bool)
          replacement
          (if_
             (bin Ast.Le c (lit_int 0x7F) ty_bool)
             write_one
             (if_
                (bin Ast.Le c (lit_int 0x7FF) ty_bool)
                write_two
                (if_
                   (bin Ast.Le c (lit_int 0xFFFF) ty_bool)
                   write_three
                   (if_
                      (bin Ast.Le c (lit_int 0x10FFFF) ty_bool)
                      write_four replacement ty_void)
                   ty_void)
                ty_void)
             ty_void)
          ty_void
      in
      Some
        (lett "__slen"
           (intr "string_len" [ s ] ty_int)
           (lett "__clen" char_len
              (lett "__newlen"
                 (bin Ast.Add (vr "__slen" ty_int) (vr "__clen" ty_int) ty_int)
                 (lett "__r"
                    (intr "string_ensure_capacity"
                       [ s; vr "__newlen" ty_int ]
                       ty_string)
                    (seq write_utf8
                       (seq
                          (intr "string_set_len"
                             [ vr "__r" ty_string; vr "__newlen" ty_int ]
                             ty_void)
                          (vr "__r" ty_string)))))))
  | "string_append" when first_is_string () && arity 2 ->
      (* ensure_capacity(s, s.len + other.len) + copy other bytes + set_len *)
      let s = param (param_at 0) in
      let other = param (param_at 1) in
      Some
        (lett "__slen"
           (intr "string_len" [ s ] ty_int)
           (lett "__olen"
              (intr "string_len" [ other ] ty_int)
              (mk ty_string
                 (CIf
                    ( bin Ast.Eq (vr "__olen" ty_int) (lit_int 0) ty_bool,
                      s,
                      lett "__newlen"
                        (bin Ast.Add (vr "__slen" ty_int) (vr "__olen" ty_int)
                           ty_int)
                        (lett "__r"
                           (intr "string_ensure_capacity"
                              [ s; vr "__newlen" ty_int ]
                              ty_string)
                           (seq
                              (mk ty_void
                                 (CFor
                                    ( loop "__i" ty_int,
                                      mk ty_int
                                        (CRange (lit_int 0, vr "__olen" ty_int)),
                                      intr "string_set_byte"
                                        [
                                          vr "__r" ty_string;
                                          bin Ast.Add (vr "__slen" ty_int)
                                            (vr "__i" ty_int) ty_int;
                                          intr "string_get_byte"
                                            [ other; vr "__i" ty_int ]
                                            ty_int;
                                        ]
                                        ty_void )))
                              (seq
                                 (intr "string_set_len"
                                    [ vr "__r" ty_string; vr "__newlen" ty_int ]
                                    ty_void)
                                 (vr "__r" ty_string)))) )))))
  (* ---- Bytes operations ---- *)
  | "bytes"
    when match return_ty with Ast.TyNamed ("Bytes", _) -> true | _ -> false ->
      with_params1 (fun size_p ->
          (* bytes(size): alloc + zero-fill + set_len *)
          let size = param size_p in
          let ty_bytes = Ast.TyNamed ("Bytes", []) in
          Some
            (lett "__size"
               (mk ty_int
                  (CIf (bin Ast.Lt size (lit_int 0) ty_bool, lit_int 0, size)))
               (lett "__r"
                  (intr "bytes_alloc" [ vr "__size" ty_int ] ty_bytes)
                  (seq
                     (mk ty_void
                        (CFor
                           ( loop "__i" ty_int,
                             mk ty_int (CRange (lit_int 0, vr "__size" ty_int)),
                             intr "bytes_set"
                               [ vr "__r" ty_bytes; vr "__i" ty_int; lit_int 0 ]
                               ty_void )))
                     (seq
                        (intr "bytes_set_len"
                           [ vr "__r" ty_bytes; vr "__size" ty_int ]
                           ty_void)
                        (vr "__r" ty_bytes))))))
  | "length" when first_is_bytes () ->
      with_params1 (fun b_p ->
          let b = param b_p in
          Some (intr "bytes_len" [ b ] return_ty))
  | "get" when first_is_bytes () ->
      with_params2 (fun b_p idx_p ->
          (* bounds check + bytes_get wrapped in Option *)
          let b = param b_p in
          let idx = param idx_p in
          let ty_bytes = Ast.TyNamed ("Bytes", []) in
          ignore ty_bytes;
          Some
            (mk return_ty
               (CIf
                  ( mk ty_bool
                      (CLog
                         ( Ast.Or,
                           bin Ast.Lt idx (lit_int 0) ty_bool,
                           bin Ast.Ge idx
                             (intr "bytes_len" [ b ] ty_int)
                             ty_bool )),
                    (* OOB → None. Use CKBuiltin to construct None *)
                    mk return_ty
                      (CCall (CKBuiltin "blorp_option_none", void, [])),
                    (* In bounds → Some(bytes_get(b, idx)) *)
                    mk return_ty
                      (CCall
                         ( CKBuiltin "blorp_option_some",
                           void,
                           [
                             mk ty_ptr
                               (CBox (intr "bytes_get" [ b; idx ] ty_int, ty_int));
                           ] )) ))))
  | "set_index" when first_is_bytes () ->
      with_params3 (fun b_p idx_p val_p ->
          (* COW + bounds check + clamp value to 0..255 + bytes_set *)
          let b = param b_p in
          let idx = param idx_p in
          let val_ = param val_p in
          let ty_bytes = Ast.TyNamed ("Bytes", []) in
          Some
            (mk ty_bytes
               (CIf
                  ( mk ty_bool
                      (CLog
                         ( Ast.Or,
                           bin Ast.Lt idx (lit_int 0) ty_bool,
                           bin Ast.Ge idx
                             (intr "bytes_len" [ b ] ty_int)
                             ty_bool )),
                    b,
                    (* OOB → return unchanged *)
                    lett "__cval"
                      (mk ty_int
                         (CIf
                            ( bin Ast.Lt val_ (lit_int 0) ty_bool,
                              lit_int 0,
                              mk ty_int
                                (CIf
                                   ( bin Ast.Gt val_ (lit_int 255) ty_bool,
                                     lit_int 255,
                                     val_ )) )))
                      (lett "__r"
                         (intr "bytes_cow" [ b ] ty_bytes)
                         (seq
                            (intr "bytes_set"
                               [ vr "__r" ty_bytes; idx; vr "__cval" ty_int ]
                               ty_void)
                            (vr "__r" ty_bytes))) ))))
  | "slice" when first_is_bytes () ->
      with_params3 (fun b_p start_p req_len_p ->
          let b = param b_p in
          let start = param start_p in
          let req_len = param req_len_p in
          let ty_bytes = Ast.TyNamed ("Bytes", []) in
          Some
            (lett "__blen"
               (intr "bytes_len" [ b ] ty_int)
               (lett "__start"
                  (mk ty_int
                     (CIf
                        ( bin Ast.Lt start (lit_int 0) ty_bool,
                          lit_int 0,
                          mk ty_int
                            (CIf
                               ( bin Ast.Gt start (vr "__blen" ty_int) ty_bool,
                                 vr "__blen" ty_int,
                                 start )) )))
                  (lett "__len"
                     (mk ty_int
                        (CIf
                           ( bin Ast.Le req_len (lit_int 0) ty_bool,
                             lit_int 0,
                             mk ty_int
                               (CIf
                                  ( bin Ast.Gt
                                      (bin Ast.Add (vr "__start" ty_int) req_len
                                         ty_int)
                                      (vr "__blen" ty_int) ty_bool,
                                    bin Ast.Sub (vr "__blen" ty_int)
                                      (vr "__start" ty_int) ty_int,
                                    req_len )) )))
                     (lett "__r"
                        (intr "bytes_alloc" [ vr "__len" ty_int ] ty_bytes)
                        (seq
                           (mk ty_void
                              (CFor
                                 ( loop "__i" ty_int,
                                   mk ty_int
                                     (CRange (lit_int 0, vr "__len" ty_int)),
                                   intr "bytes_set"
                                     [
                                       vr "__r" ty_bytes;
                                       vr "__i" ty_int;
                                       intr "bytes_get"
                                         [
                                           b;
                                           bin Ast.Add (vr "__start" ty_int)
                                             (vr "__i" ty_int) ty_int;
                                         ]
                                         ty_int;
                                     ]
                                     ty_void )))
                           (seq
                              (intr "bytes_set_len"
                                 [ vr "__r" ty_bytes; vr "__len" ty_int ]
                                 ty_void)
                              (vr "__r" ty_bytes))))))))
  | "append" when first_is_bytes () ->
      with_params2 (fun a_p b_p ->
          let a = param a_p in
          let b = param b_p in
          let ty_bytes = Ast.TyNamed ("Bytes", []) in
          Some
            (lett "__alen"
               (intr "bytes_len" [ a ] ty_int)
               (lett "__blen"
                  (intr "bytes_len" [ b ] ty_int)
                  (lett "__total"
                     (bin Ast.Add (vr "__alen" ty_int) (vr "__blen" ty_int)
                        ty_int)
                     (lett "__r"
                        (intr "bytes_alloc" [ vr "__total" ty_int ] ty_bytes)
                        (seq
                           (mk ty_void
                              (CFor
                                 ( loop "__i" ty_int,
                                   mk ty_int
                                     (CRange (lit_int 0, vr "__alen" ty_int)),
                                   intr "bytes_set"
                                     [
                                       vr "__r" ty_bytes;
                                       vr "__i" ty_int;
                                       intr "bytes_get"
                                         [ a; vr "__i" ty_int ]
                                         ty_int;
                                     ]
                                     ty_void )))
                           (seq
                              (mk ty_void
                                 (CFor
                                    ( loop "__i" ty_int,
                                      mk ty_int
                                        (CRange (lit_int 0, vr "__blen" ty_int)),
                                      intr "bytes_set"
                                        [
                                          vr "__r" ty_bytes;
                                          bin Ast.Add (vr "__alen" ty_int)
                                            (vr "__i" ty_int) ty_int;
                                          intr "bytes_get"
                                            [ b; vr "__i" ty_int ]
                                            ty_int;
                                        ]
                                        ty_void )))
                              (seq
                                 (intr "bytes_set_len"
                                    [ vr "__r" ty_bytes; vr "__total" ty_int ]
                                    ty_void)
                                 (vr "__r" ty_bytes)))))))))
  | "fill" when first_is_bytes () ->
      with_params2 (fun b_p val_p ->
          let b = param b_p in
          let val_ = param val_p in
          let ty_bytes = Ast.TyNamed ("Bytes", []) in
          Some
            (lett "__r"
               (intr "bytes_cow" [ b ] ty_bytes)
               (lett "__len"
                  (intr "bytes_len" [ vr "__r" ty_bytes ] ty_int)
                  (seq
                     (mk ty_void
                        (CFor
                           ( loop "__i" ty_int,
                             mk ty_int (CRange (lit_int 0, vr "__len" ty_int)),
                             intr "bytes_set"
                               [ vr "__r" ty_bytes; vr "__i" ty_int; val_ ]
                               ty_void )))
                     (vr "__r" ty_bytes)))))
  | "index_of" when first_is_bytes () ->
      with_params3 (fun b_p val_p start_p ->
          let b = param b_p in
          let val_ = param val_p in
          let start = param start_p in
          Some
            (lett "__blen"
               (intr "bytes_len" [ b ] ty_int)
               (lett "__start"
                  (mk ty_int
                     (CIf
                        ( bin Ast.Lt start (lit_int 0) ty_bool,
                          lit_int 0,
                          mk ty_int
                            (CIf
                               ( bin Ast.Gt start (vr "__blen" ty_int) ty_bool,
                                 vr "__blen" ty_int,
                                 start )) )))
                  (lettm "__pos"
                     (mk ty_int (CLit (Ast.LitInt (-1L))))
                     (seq
                        (mk ty_void
                           (CFor
                              ( forward_loop "__i",
                                mk ty_int
                                  (CRange
                                     (vr "__start" ty_int, vr "__blen" ty_int)),
                                mk ty_void
                                  (CIf
                                     ( bin Ast.Eq
                                         (intr "bytes_get"
                                            [ b; vr "__i" ty_int ]
                                            ty_int)
                                         val_ ty_bool,
                                       seq
                                         (mk ty_void
                                            (CAssign
                                               ( Var.named "__pos",
                                                 vr "__i" ty_int )))
                                         (mk ty_void CBreak),
                                       void )) )))
                        (* Wrap in Option *)
                        (mk return_ty
                           (CIf
                              ( bin Ast.Ge (vr "__pos" ty_int) (lit_int 0)
                                  ty_bool,
                                mk return_ty
                                  (CCall
                                     ( CKBuiltin "blorp_option_some",
                                       void,
                                       [
                                         mk ty_ptr
                                           (CBox (vr "__pos" ty_int, ty_int));
                                       ] )),
                                mk return_ty
                                  (CCall
                                     (CKBuiltin "blorp_option_none", void, []))
                              ))))))))
  | "blit" when first_is_bytes () ->
      with_params5 (fun dst_p dst_off_p src_p src_off_p len_p ->
          (* COW + bounds-clamped copy from src to dst *)
          let dst = param dst_p in
          let dst_off = param dst_off_p in
          let src = param src_p in
          let src_off = param src_off_p in
          let len = param len_p in
          let ty_bytes = Ast.TyNamed ("Bytes", []) in
          (* Clamp offsets into their buffers so availabilities are never negative.
         Internal copy loops must not inherit source-level backward range
         semantics when the requested copy length clamps to zero. *)
          let clamp_to_len value len =
            mk ty_int
              (CIf
                 ( bin Ast.Lt value (lit_int 0) ty_bool,
                   lit_int 0,
                   mk ty_int (CIf (bin Ast.Gt value len ty_bool, len, value)) ))
          in
          let min_int a b = mk ty_int (CIf (bin Ast.Lt a b ty_bool, a, b)) in
          let requested =
            mk ty_int (CIf (bin Ast.Le len (lit_int 0) ty_bool, lit_int 0, len))
          in
          let copy_loop =
            mk ty_void
              (CFor
                 ( forward_loop "__i",
                   mk ty_int (CRange (lit_int 0, vr "__clen" ty_int)),
                   intr "bytes_set"
                     [
                       vr "__r" ty_bytes;
                       bin Ast.Add (vr "__do" ty_int) (vr "__i" ty_int) ty_int;
                       intr "bytes_get"
                         [
                           src;
                           bin Ast.Add (vr "__so" ty_int) (vr "__i" ty_int)
                             ty_int;
                         ]
                         ty_int;
                     ]
                     ty_void ))
          in
          let body =
            lett "__src_len"
              (intr "bytes_len" [ src ] ty_int)
              (lett "__dst_len"
                 (intr "bytes_len" [ vr "__r" ty_bytes ] ty_int)
                 (lett "__do"
                    (clamp_to_len dst_off (vr "__dst_len" ty_int))
                    (lett "__so"
                       (clamp_to_len src_off (vr "__src_len" ty_int))
                       (lett "__src_avail"
                          (bin Ast.Sub (vr "__src_len" ty_int)
                             (vr "__so" ty_int) ty_int)
                          (lett "__dst_avail"
                             (bin Ast.Sub (vr "__dst_len" ty_int)
                                (vr "__do" ty_int) ty_int)
                             (lett "__requested" requested
                                (lett "__clen"
                                   (min_int (vr "__requested" ty_int)
                                      (min_int (vr "__src_avail" ty_int)
                                         (vr "__dst_avail" ty_int)))
                                   (seq copy_loop (vr "__r" ty_bytes)))))))))
          in
          Some (lett "__r" (intr "bytes_cow" [ dst ] ty_bytes) body))
  (* ---- Set operations ---- *)
  | "length" when first_is_set () ->
      with_params1 (fun p -> Some (intr "set_len" [ param p ] return_ty))
  | "contains" when first_is_set () ->
      with_params2 (fun self_p elem_p ->
          if
            Codegen_types.has_type_vars self_p.cp_ty
            || Codegen_types.has_type_vars elem_p.cp_ty
          then None
          else
            Some (set_contains ?reg self_p.cp_ty (param self_p) (param elem_p)))
  | "add" when first_is_set () ->
      with_params2 (fun self_p elem_p ->
          if
            Codegen_types.has_type_vars self_p.cp_ty
            || Codegen_types.has_type_vars elem_p.cp_ty
          then None
          else Some (set_add ?reg self_p.cp_ty (param self_p) (param elem_p)))
  | "is_subset" when first_is_set () ->
      with_params2 (fun a_p b_p ->
          if has_type_vars_params [ a_p; b_p ] then None
          else Some (set_is_subset ?reg (param a_p) (param b_p)))
  | "difference" when first_is_set () ->
      with_params2 (fun a_p b_p ->
          if
            has_type_vars_params [ a_p; b_p ]
            || Codegen_types.has_type_vars return_ty
          then None
          else Some (set_difference ?reg return_ty (param a_p) (param b_p)))
  | "intersect" when first_is_set () ->
      with_params2 (fun a_p b_p ->
          if
            has_type_vars_params [ a_p; b_p ]
            || Codegen_types.has_type_vars return_ty
          then None
          else Some (set_intersect ?reg return_ty (param a_p) (param b_p)))
  | "combine" when first_is_set () ->
      with_params2 (fun a_p b_p ->
          if
            has_type_vars_params [ a_p; b_p ]
            || Codegen_types.has_type_vars return_ty
          then None
          else Some (set_combine ?reg return_ty (param a_p) (param b_p)))
  | "map" when first_is_set () ->
      with_params2 (fun self_p f_p ->
          if
            has_type_vars_params [ self_p; f_p ]
            || Codegen_types.has_type_vars return_ty
          then None
          else
            Some
              (set_map ?reg self_p.cp_ty return_ty (param self_p) (param f_p)))
  | "filter" when first_is_set () ->
      with_params2 (fun self_p pred_p ->
          if
            has_type_vars_params [ self_p; pred_p ]
            || Codegen_types.has_type_vars return_ty
          then None
          else Some (set_filter ?reg self_p.cp_ty (param self_p) (param pred_p)))
  | "fold" when first_is_set () ->
      with_params3 (fun self_p init_p f_p ->
          Some
            (set_fold ?reg self_p.cp_ty return_ty (param self_p) (param init_p)
               (param f_p)))
  | "to_list" when first_is_set () ->
      with_params1 (fun self_p ->
          Some (set_to_list self_p.cp_ty return_ty (param self_p)))
  | "length" when first_is_dict () ->
      with_dict1 (fun p -> intr "dict_len" [ param p ] return_ty)
  | "contains" when first_is_dict () ->
      with_params2 (fun self_p key_p ->
          if
            Codegen_types.has_type_vars self_p.cp_ty
            || Codegen_types.has_type_vars key_p.cp_ty
          then None
          else
            Some (dict_contains ?reg self_p.cp_ty (param self_p) (param key_p)))
  | "get_or" when first_is_dict () ->
      with_params3 (fun self_p key_p default_p ->
          if
            Codegen_types.has_type_vars self_p.cp_ty
            || Codegen_types.has_type_vars key_p.cp_ty
            || Codegen_types.has_type_vars default_p.cp_ty
          then None
          else
            Some
              (dict_get_or ?reg self_p.cp_ty (param self_p) (param key_p)
                 (param default_p)))
  | "set" when first_is_dict () ->
      with_params3 (fun self_p key_p value_p ->
          if
            Codegen_types.has_type_vars self_p.cp_ty
            || Codegen_types.has_type_vars key_p.cp_ty
            || Codegen_types.has_type_vars value_p.cp_ty
          then None
          else
            Some
              (dict_set ?reg self_p.cp_ty (param self_p) (param key_p)
                 (param value_p)))
  (* ---- Fixed operations ---- *)
  | "get_scale"
    when match params with
         | [ { cp_ty = Ast.TyNamed ("Fixed", _); _ } ] -> true
         | _ -> false ->
      with_params1 (fun p -> Some (fixed_get_scale (param p)))
  | "get_precision"
    when match params with
         | [ { cp_ty = Ast.TyNamed ("Fixed", _); _ } ] -> true
         | _ -> false ->
      with_params1 (fun p -> Some (fixed_get_precision (param p)))
  | "to_int"
    when match params with
         | [ { cp_ty = Ast.TyNamed ("Fixed", _); _ } ] -> true
         | _ -> false ->
      with_params1 (fun p -> Some (fixed_to_int (param p)))
  | "neg"
    when match params with
         | [ { cp_ty = Ast.TyNamed ("Fixed", _); _ } ] -> true
         | _ -> false ->
      with_params1 (fun p -> Some (fixed_neg (param p)))
  | "round_to"
    when match params with
         | { cp_ty = Ast.TyNamed ("Fixed", _); _ } :: [ _ ] -> true
         | _ -> false ->
      with_params2 (fun f_p s_p ->
          Some (fixed_round_to (param f_p) (param s_p)))
  (* ---- Slice operations ---- *)
  | "from_string"
    when (match params with
           | [ { cp_ty = Ast.TyNamed ("String", _); _ } ] -> true
           | _ -> false)
         && return_ty = Ast.TyNamed ("StringSlice", []) ->
      with_params1 (fun p -> Some (slice_from_string (param p)))
  | "length" when first_is_slice () ->
      with_params1 (fun p -> Some (slice_length (param p)))
  | "to_string" when first_is_slice () ->
      with_params1 (fun p -> Some (slice_to_string (param p)))
  | "substring" when first_is_slice () ->
      with_params3 (fun slice_p start_p len_p ->
          Some (slice_substring (param slice_p) (param start_p) (param len_p)))
  | "starts_with" when first_is_slice () ->
      with_params2 (fun slice_p prefix_p ->
          Some (slice_starts_with (param slice_p) (param prefix_p)))
  | "get" when first_is_slice () ->
      with_params2 (fun slice_p idx_p ->
          Some (slice_get (param slice_p) (param idx_p)))
  | "keys" when first_is_dict () ->
      with_dict1 (fun self_p -> dict_keys return_ty (param self_p))
  | "values" when first_is_dict () ->
      with_dict1 (fun self_p -> dict_values return_ty (param self_p))
  | "entries" when first_is_dict () ->
      with_dict1 (fun self_p -> dict_entries ?reg return_ty (param self_p))
  (* ==== Math intrinsics ====
     IEEE 754 math operations emit as CKIntrinsic (not CKBuiltin) because
     backends produce structurally different code:
       C backend:    sin(x)          — bare libm function call
       WASM backend: f64.sin         — native WASM instruction
       LLVM backend: @llvm.sin.f64   — LLVM intrinsic

     abs/min/max are excluded — they're polymorphic (Int + Float) and stay
     CKBuiltin with type dispatch in core_specialize. Float round is included
     here as math_round; integer rounding does not use this intrinsic.

     When called with a tensor arg, core_specialize rewrites
     CKIntrinsic "math_sqrt" → CKBuiltin "blorp_vector_sqrt" (tensor lift). *)
  (* Unary math: Float -> Float (also handles Float32/Float16 via cast) *)
  | "sin" | "cos" | "tan" | "asin" | "acos" | "atan" | "sinh" | "cosh" | "tanh"
  | "asinh" | "acosh" | "atanh" | "exp" | "exp2" | "expm1" | "log" | "log2"
  | "log10" | "log1p" | "sqrt" | "cbrt" | "floor" | "ceil" | "round"
  | "trunc"
    when match params with
         | [ { cp_ty = Ast.TyNamed (("Float" | "Float32" | "Float16"), _); _ } ]
           ->
             true
         | _ -> false ->
      let p = param_at 0 in
      let ty_float = Ast.TyNamed ("Float", []) in
      let is_f64 =
        match p.cp_ty with Ast.TyNamed ("Float", _) -> true | _ -> false
      in
      if is_f64 then Some (intr ("math_" ^ func_name) [ param p ] return_ty)
      else
        (* Float32/Float16: cast to Float64, apply, cast back *)
        let widened = mk ty_float (CCast (param p, ty_float)) in
        let result = intr ("math_" ^ func_name) [ widened ] ty_float in
        Some (mk return_ty (CCast (result, return_ty)))
  (* Binary math: Float * Float -> Float (also handles Float32/Float16) *)
  | ("pow" | "atan2" | "hypot" | "fmod" | "copysign")
    when List.length params = 2
         &&
         match (param_at 0).cp_ty with
         | Ast.TyNamed (("Float" | "Float32" | "Float16"), _) -> true
         | _ -> false ->
      let p0 = param_at 0 in
      let p1 = param_at 1 in
      let ty_float = Ast.TyNamed ("Float", []) in
      let is_f64 =
        match p0.cp_ty with Ast.TyNamed ("Float", _) -> true | _ -> false
      in
      if is_f64 then
        Some (intr ("math_" ^ func_name) [ param p0; param p1 ] return_ty)
      else
        let a = mk ty_float (CCast (param p0, ty_float)) in
        let b = mk ty_float (CCast (param p1, ty_float)) in
        let result = intr ("math_" ^ func_name) [ a; b ] ty_float in
        Some (mk return_ty (CCast (result, return_ty)))
  (* Ternary math: fma *)
  | "fma" when List.length params = 3 ->
      let a = param (param_at 0) in
      let b = param (param_at 1) in
      let c = param (param_at 2) in
      Some (intr "math_fma" [ a; b; c ] return_ty)
  (* Float constants *)
  | "infinity" when params = [] && return_ty = Ast.TyNamed ("Float", []) ->
      Some (intr "math_infinity" [] return_ty)
  | "neg_infinity" when params = [] && return_ty = Ast.TyNamed ("Float", []) ->
      Some (intr "math_neg_infinity" [] return_ty)
  | "nan_value" when params = [] && return_ty = Ast.TyNamed ("Float", []) ->
      Some (intr "math_nan" [] return_ty)
  (* Float classification — works for all float widths *)
  | "is_nan"
    when match params with
         | [ { cp_ty = Ast.TyNamed (("Float" | "Float32" | "Float16"), _); _ } ]
           ->
             true
         | _ -> false ->
      Some (intr "math_is_nan" [ param (param_at 0) ] return_ty)
  | "is_inf"
    when match params with
         | [ { cp_ty = Ast.TyNamed (("Float" | "Float32" | "Float16"), _); _ } ]
           ->
             true
         | _ -> false ->
      Some (intr "math_is_inf" [ param (param_at 0) ] return_ty)
  | "is_finite"
    when match params with
         | [ { cp_ty = Ast.TyNamed (("Float" | "Float32" | "Float16"), _); _ } ]
           ->
             true
         | _ -> false ->
      Some (intr "math_is_finite" [ param (param_at 0) ] return_ty)
  (* ==== CKBuiltin wrappers ====
     These functions are genuinely C-specific (OS calls, math, crypto, etc.)
     but wrapped as IR bodies so they can be called from IR compositions.
     The wrapper is a single CKBuiltin call that forwards all params. *)
  (* ---- IO arm removed 2026-04-24: std/io.brp bodies migrated to
         [builtin("blorp_*")] which synthesize the call directly in
         [Core_lower.lower_func]. No more bare [builtin] bodies for
         print/print_error/read_line/input. *)

  (* Debug / Memory / Random / Crypto-random / Process / Signal arms
     removed 2026-04-24. std/{debug,memory,random,crypto_random,process}.brp
     declare these with [builtin("blorp_*")] bodies. *)

  (* Regex arm removed 2026-04-24: std/regex.brp declares test_regex, find,
     replace_all, find_all with [builtin("blorp_regex_*")] bodies. *)

  (* String arms removed 2026-04-24: std/string.brp declares from_char, chars,
     from_chars, to_bytes, parse_int, parse_float, get, url_encode, url_decode,
     html_escape, base64_encode, base64_decode, codepoint_length, codepoints,
     codepoint_reverse, levenshtein, longest_common_substring with
     [builtin("blorp_*")] bodies. *)

  (* Legacy builder C wrappers removed. string_append_char is synthesized above
     so UTF-8 encoding and COW flow through Core IR. *)
  (* ---- Tensor/Vector operations ---- *)
  (* ---- Tensor reductions (require concrete element type) ---- *)
  (* These return None when the element type is generic (pre-mono).
     After monomorphization, core_synth re-attempts synthesis with
     concrete types, and is_concrete_tensor returns true. *)
  | "sum" when List.length params = 1 && is_concrete_tensor (param_at 0).cp_ty
    ->
      let p = param_at 0 in
      let info = tensor_elem_info p.cp_ty in
      Some
        (tensor_reduce ~op:Ast.Add ~init:info.zero_lit (param p) p.cp_ty
           return_ty)
  | "product"
    when List.length params = 1 && is_concrete_tensor (param_at 0).cp_ty ->
      let p = param_at 0 in
      let info = tensor_elem_info p.cp_ty in
      Some
        (tensor_reduce ~op:Ast.Mul ~init:info.one_lit (param p) p.cp_ty
           return_ty)
  | "dot" when List.length params = 2 && is_concrete_tensor (param_at 0).cp_ty
    ->
      let pa = param_at 0 in
      let pb = param_at 1 in
      Some (tensor_dot (param pa) (param pb) pa.cp_ty return_ty)
  | "max" when List.length params = 1 && is_concrete_tensor (param_at 0).cp_ty
    ->
      let p = param_at 0 in
      let info = tensor_elem_info p.cp_ty in
      (* max: init = data[0] (or 0 if empty), loop from 1..n with conditional *)
      Some
        (lett "__n"
           (intr "tensor_len" [ param p ] ty_int)
           (if_
              (bin Ast.Eq (vr "__n" ty_int) (lit_int 0) ty_bool)
              info.zero_lit
              (lettm "__acc"
                 (intr info.get_intr [ param p; lit_int 0 ] return_ty)
                 (seq
                    (mk ty_void
                       (CFor
                          ( loop "__i" ty_int,
                            mk ty_int (CRange (lit_int 1, vr "__n" ty_int)),
                            lett "__val"
                              (intr info.get_intr
                                 [ param p; vr "__i" ty_int ]
                                 return_ty)
                              (if_
                                 (bin Ast.Gt (vr "__val" return_ty)
                                    (vr "__acc" return_ty) ty_bool)
                                 (mk ty_void
                                    (CAssign
                                       (Var.named "__acc", vr "__val" return_ty)))
                                 void ty_void) )))
                    (vr "__acc" return_ty)))
              return_ty))
  | "min" when List.length params = 1 && is_concrete_tensor (param_at 0).cp_ty
    ->
      let p = param_at 0 in
      let info = tensor_elem_info p.cp_ty in
      Some
        (lett "__n"
           (intr "tensor_len" [ param p ] ty_int)
           (if_
              (bin Ast.Eq (vr "__n" ty_int) (lit_int 0) ty_bool)
              info.zero_lit
              (lettm "__acc"
                 (intr info.get_intr [ param p; lit_int 0 ] return_ty)
                 (seq
                    (mk ty_void
                       (CFor
                          ( loop "__i" ty_int,
                            mk ty_int (CRange (lit_int 1, vr "__n" ty_int)),
                            lett "__val"
                              (intr info.get_intr
                                 [ param p; vr "__i" ty_int ]
                                 return_ty)
                              (if_
                                 (bin Ast.Lt (vr "__val" return_ty)
                                    (vr "__acc" return_ty) ty_bool)
                                 (mk ty_void
                                    (CAssign
                                       (Var.named "__acc", vr "__val" return_ty)))
                                 void ty_void) )))
                    (vr "__acc" return_ty)))
              return_ty))
  | "mean" when List.length params = 1 && is_concrete_tensor (param_at 0).cp_ty
    ->
      let p = param_at 0 in
      (* mean = sum / length, always returns Float *)
      let read_to_float value =
        if
          Types.types_equal
            (Codegen_types.normalize_type value.ty)
            (Codegen_types.normalize_type return_ty)
        then value
        else mk return_ty (CCast (value, return_ty))
      in
      let sum_body =
        tensor_reduce ~op:Ast.Add ~init:(lit_float 0.0)
          ~read_to_acc:read_to_float (param p) p.cp_ty return_ty
      in
      Some
        (lett "__n"
           (intr "tensor_len" [ param p ] ty_int)
           (if_
              (bin Ast.Eq (vr "__n" ty_int) (lit_int 0) ty_bool)
              (lit_float 0.0)
              (lett "__sum" sum_body
                 (bin Ast.Div (vr "__sum" return_ty)
                    (mk return_ty (CCast (vr "__n" ty_int, return_ty)))
                    return_ty))
              return_ty))
  | "cumulative_sum"
    when List.length params = 1 && is_concrete_tensor (param_at 0).cp_ty ->
      let p = param_at 0 in
      let info = tensor_elem_info p.cp_ty in
      let set_intr = tensor_set_intrinsic_of_get info.get_intr in
      let elem_ty = info.elem_ty in
      Some
        (lett "__n"
           (intr "tensor_len" [ param p ] ty_int)
           (lett "__result"
              (intr "tensor_alloc" [ vr "__n" ty_int ] return_ty)
              (lettm "__running" info.zero_lit
                 (seq
                    (mk ty_void
                       (CFor
                          ( loop "__i" ty_int,
                            mk ty_int (CRange (lit_int 0, vr "__n" ty_int)),
                            seq
                              (mk ty_void
                                 (CAssign
                                    ( Var.named "__running",
                                      bin Ast.Add (vr "__running" elem_ty)
                                        (intr info.get_intr
                                           [ param p; vr "__i" ty_int ]
                                           elem_ty)
                                        elem_ty )))
                              (intr set_intr
                                 [
                                   vr "__result" return_ty;
                                   vr "__i" ty_int;
                                   vr "__running" elem_ty;
                                 ]
                                 ty_void) )))
                    (vr "__result" return_ty)))))
  | "scale" when List.length params = 2 && is_concrete_tensor (param_at 0).cp_ty
    ->
      let pv = param_at 0 in
      let ps = param_at 1 in
      let info = tensor_elem_info pv.cp_ty in
      let set_intr = tensor_set_intrinsic_of_get info.get_intr in
      let elem_ty = info.elem_ty in
      Some
        (lett "__n"
           (intr "tensor_len" [ param pv ] ty_int)
           (lett "__result"
              (intr "tensor_alloc" [ vr "__n" ty_int ] return_ty)
              (seq
                 (mk ty_void
                    (CFor
                       ( loop "__i" ty_int,
                         mk ty_int (CRange (lit_int 0, vr "__n" ty_int)),
                         intr set_intr
                           [
                             vr "__result" return_ty;
                             vr "__i" ty_int;
                             bin Ast.Mul
                               (intr info.get_intr
                                  [ param pv; vr "__i" ty_int ]
                                  elem_ty)
                               (param ps) elem_ty;
                           ]
                           ty_void )))
                 (vr "__result" return_ty))))
  | "sum" | "product" | "dot" | "max" | "min" | "mean" | "cumulative_sum"
  | "scale"
    when match params with
         | p :: _ ->
             Option.is_some (unsupported_concrete_numeric_tensor p.cp_ty)
         | [] -> false ->
      unsupported_numeric_tensor_error func_name (param_at 0)
  (* Other vector operations still use core_specialize dispatch. *)
  | _ -> None

let synthesize_body_impl reg ~func_name ~module_path ~params ~return_ty =
  let source_name = source_func_name ~module_path func_name in
  let is_tensor_type ty = Core_tensor_type.is_type ~reg:(tensor_reg reg) ty in
  match
    std_body_signature_check ~is_tensor_type ~module_path ~func_name:source_name
      ~params ~return_ty
  with
  | None -> None
  | Some (SpecCheckedParams (spec, checked_params)) -> (
      match synthesize_std_body_from_spec spec params return_ty with
      | Some body -> Some body
      | None -> (
          try
            synthesize_body_impl_unsafe reg ~func_name ~module_path ~params
              ~checked_params ~return_ty
          with Malformed_intrinsic_params -> None))
  | Some (LegacyUncheckedParams checked_params) -> (
      try
        synthesize_body_impl_unsafe reg ~func_name ~module_path ~params
          ~checked_params ~return_ty
      with Malformed_intrinsic_params -> None)

let synthesize_body = synthesize_body_impl None

let synthesize_body_with_reg ~(reg : Codegen_types.registry) =
  synthesize_body_impl (Some reg)

type std_body_resolution = StdBuiltinNoBody | StdBuiltinBody of core

let synthesize_std_body_impl reg ~module_path ~func_name ~params ~return_ty =
  match synthesize_body_impl reg ~func_name ~module_path ~params ~return_ty with
  | Some body -> StdBuiltinBody body
  | None -> StdBuiltinNoBody

let synthesize_std_body = synthesize_std_body_impl None
