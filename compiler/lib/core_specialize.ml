(** Post-resolve specialization of type-dispatched builtins.

    Runs after [Core_resolve] (calls are tagged) and after [Core_mono]
    (types are concrete).  Rewrites generic builtins like [blorp_to_int]
    into [CCast] nodes or concrete builtin names based on the argument
    type.

    This keeps [Core_emit] free of type dispatch — it just emits
    [CCast] as a C cast and [CKBuiltin] calls by their resolved name. *)

open Core

let normalize_type = Codegen_types.normalize_type
let empty_codegen_registry = Codegen_types.create_registry ()
let effective_reg = function Some reg -> reg | None -> empty_codegen_registry

let unqualified_type_name name =
  let rec last_colon i =
    if i < 0 then None else if name.[i] = ':' then Some i else last_colon (i - 1)
  in
  match last_colon (String.length name - 1) with
  | Some i when i + 1 < String.length name ->
      String.sub name (i + 1) (String.length name - i - 1)
  | _ -> name

let type_name_is expected name =
  name = expected || unqualified_type_name name = expected

let option_equality_builtin_for_type ~reg ~loc option_ty =
  match Core_layout_type.option_equality_abi ~reg option_ty with
  | Core_layout_type.OptionEqualityStackInline _
  | Core_layout_type.OptionEqualityNullableString ->
      "__blorp_option_eq_layout"
  | Core_layout_type.OptionEqualityBoxedUnionRuntime fn -> fn
  | Core_layout_type.OptionEqualityUnavailable reason ->
      Core_error.errorf (Core_error.Stage Core_stage.Specialize) loc
        ~hint:
          "Option equality must be lowered with a representation-specific ABI; \
           add a layout-owned equality strategy for this payload type."
        "cannot lower Option equality safely: %s" reason

(* Runtime void* ABI slots live on Core_ownership builtin contract entries so
   ownership and argument boxing cannot drift independently. Core_specialize
   consumes the derived map to insert explicit CBox nodes before final Core. *)
let void_boxed_arg_positions = Core_ownership.builtin_void_boxed_arg_positions
let is_pointer_type ~reg ty = Core_layout_type.is_pointer_type ~reg ty
let tensor_type ?reg ty = Core_tensor_type.of_type ~reg:(effective_reg reg) ty

let tensor_parts ?reg ty =
  Option.map (fun (tensor_ty : Core_tensor_type.t) ->
      (tensor_ty.elem_ty, tensor_ty.dims))
  @@ tensor_type ?reg ty

let is_tensor_type ?reg ty = Option.is_some (tensor_type ?reg ty)

type loop_index_bound = {
  lib_var : var;
  lib_lower_nonnegative : bool;
  lib_upper_exclusive : int option;
}

type specialize_env = { loop_index_bounds : loop_index_bound list }

let empty_specialize_env = { loop_index_bounds = [] }

type raw_tensor_view = {
  rtv_tensor : var;
  rtv_tensor_ty : Ast.type_expr;
  rtv_ptr : var;
  rtv_kind : tensor_unboxed_scalar;
  rtv_needs_unique : bool;
}

let raw_view_counter = ref 0

let fresh_raw_view_name prefix =
  let id = !raw_view_counter in
  incr raw_view_counter;
  Printf.sprintf "__tensor_raw_view_%s_%d" prefix id

type tensor_arithmetic_op =
  | TensorAdd
  | TensorSub
  | TensorMul
  | TensorDiv
  | TensorMod

let tensor_arithmetic_op_of_ast = function
  | Ast.Add -> Some TensorAdd
  | Ast.Sub -> Some TensorSub
  | Ast.Mul -> Some TensorMul
  | Ast.Div -> Some TensorDiv
  | Ast.Mod -> Some TensorMod
  | _ -> None

let tensor_arithmetic_op_code = function
  | TensorAdd -> 0
  | TensorSub -> 1
  | TensorMul -> 2
  | TensorDiv -> 3
  | TensorMod -> 4

type tensor_arithmetic_elem =
  | TensorArithmeticInt
  | TensorArithmeticFloat
  | TensorArithmeticFloat32
  | TensorArithmeticFloat16
  | TensorArithmeticGenericIntLike

let tensor_arithmetic_elem_of_type ty =
  match normalize_type ty with
  | Ast.TyNamed ("Int", []) -> TensorArithmeticInt
  | Ast.TyNamed ("Float", _) -> TensorArithmeticFloat
  | Ast.TyNamed ("Float32", _) -> TensorArithmeticFloat32
  | Ast.TyNamed ("Float16", _) -> TensorArithmeticFloat16
  | _ -> TensorArithmeticGenericIntLike

let tensor_arithmetic_elem_code = function
  | TensorArithmeticFloat -> 1
  | TensorArithmeticFloat32 -> 2
  | TensorArithmeticFloat16 -> 3
  | TensorArithmeticInt | TensorArithmeticGenericIntLike -> 0

let direct_vector_binary_builtin elem op =
  match (elem, op) with
  | TensorArithmeticInt, TensorAdd -> Some "blorp_vector_add_i64"
  | TensorArithmeticInt, TensorSub -> Some "blorp_vector_sub_i64"
  | TensorArithmeticInt, TensorMul -> Some "blorp_vector_mul_i64"
  | TensorArithmeticInt, TensorDiv -> Some "blorp_vector_div_i64"
  | TensorArithmeticInt, TensorMod -> Some "blorp_vector_mod_i64"
  | TensorArithmeticFloat, TensorAdd -> Some "blorp_simd_vector_add_f64"
  | TensorArithmeticFloat, TensorSub -> Some "blorp_simd_vector_sub_f64"
  | TensorArithmeticFloat, TensorMul -> Some "blorp_simd_vector_mul_f64"
  | TensorArithmeticFloat, TensorDiv -> Some "blorp_simd_vector_div_f64"
  | TensorArithmeticFloat32, TensorAdd -> Some "blorp_simd_vector_add_f32"
  | TensorArithmeticFloat32, TensorSub -> Some "blorp_simd_vector_sub_f32"
  | TensorArithmeticFloat32, TensorMul -> Some "blorp_simd_vector_mul_f32"
  | TensorArithmeticFloat32, TensorDiv -> Some "blorp_simd_vector_div_f32"
  | _ -> None

let direct_vector_scalar_builtin ~reversed elem op =
  match (elem, reversed, op) with
  | TensorArithmeticInt, false, TensorAdd -> Some "blorp_vector_scalar_add_i64"
  | TensorArithmeticInt, false, TensorSub -> Some "blorp_vector_scalar_sub_i64"
  | TensorArithmeticInt, false, TensorMul -> Some "blorp_vector_scalar_mul_i64"
  | TensorArithmeticInt, false, TensorDiv -> Some "blorp_vector_scalar_div_i64"
  | TensorArithmeticInt, false, TensorMod -> Some "blorp_vector_scalar_mod_i64"
  | TensorArithmeticInt, true, TensorAdd -> Some "blorp_vector_scalar_add_i64"
  | TensorArithmeticInt, true, TensorSub ->
      Some "blorp_vector_scalar_rev_sub_i64"
  | TensorArithmeticInt, true, TensorMul -> Some "blorp_vector_scalar_mul_i64"
  | TensorArithmeticInt, true, TensorDiv ->
      Some "blorp_vector_scalar_rev_div_i64"
  | TensorArithmeticInt, true, TensorMod ->
      Some "blorp_vector_scalar_rev_mod_i64"
  | TensorArithmeticFloat, false, TensorAdd ->
      Some "blorp_vector_scalar_add_f64"
  | TensorArithmeticFloat, false, TensorSub ->
      Some "blorp_vector_scalar_sub_f64"
  | TensorArithmeticFloat, false, TensorMul ->
      Some "blorp_vector_scalar_mul_f64"
  | TensorArithmeticFloat, false, TensorDiv ->
      Some "blorp_vector_scalar_div_f64"
  | TensorArithmeticFloat, true, TensorAdd -> Some "blorp_vector_scalar_add_f64"
  | TensorArithmeticFloat, true, TensorSub ->
      Some "blorp_vector_scalar_rev_sub_f64"
  | TensorArithmeticFloat, true, TensorMul -> Some "blorp_vector_scalar_mul_f64"
  | TensorArithmeticFloat, true, TensorDiv ->
      Some "blorp_vector_scalar_rev_div_f64"
  | TensorArithmeticFloat32, false, TensorAdd ->
      Some "blorp_vector_scalar_add_f32"
  | TensorArithmeticFloat32, false, TensorSub ->
      Some "blorp_vector_scalar_sub_f32"
  | TensorArithmeticFloat32, false, TensorMul ->
      Some "blorp_vector_scalar_mul_f32"
  | TensorArithmeticFloat32, false, TensorDiv ->
      Some "blorp_vector_scalar_div_f32"
  | TensorArithmeticFloat32, true, TensorAdd ->
      Some "blorp_vector_scalar_add_f32"
  | TensorArithmeticFloat32, true, TensorSub ->
      Some "blorp_vector_scalar_rev_sub_f32"
  | TensorArithmeticFloat32, true, TensorMul ->
      Some "blorp_vector_scalar_mul_f32"
  | TensorArithmeticFloat32, true, TensorDiv ->
      Some "blorp_vector_scalar_rev_div_f32"
  | _ -> None

let scalar_dispatch_builtin ~reversed elem =
  match (elem, reversed) with
  | TensorArithmeticFloat, false -> "blorp_vector_scalar_op_float"
  | TensorArithmeticFloat, true -> "blorp_vector_scalar_op_rev_float"
  | TensorArithmeticFloat32, false -> "blorp_vector_scalar_op_float32"
  | TensorArithmeticFloat32, true -> "blorp_vector_scalar_op_rev_float32"
  | TensorArithmeticFloat16, false -> "blorp_vector_scalar_op_float16"
  | TensorArithmeticFloat16, true -> "blorp_vector_scalar_op_rev_float16"
  | TensorArithmeticInt, false | TensorArithmeticGenericIntLike, false ->
      "blorp_vector_scalar_op_int"
  | TensorArithmeticInt, true | TensorArithmeticGenericIntLike, true ->
      "blorp_vector_scalar_op_rev_int"

let simd_dispatch_elem_code elem =
  match elem with
  | TensorArithmeticFloat32 -> Some 0
  | TensorArithmeticFloat -> Some 1
  | _ -> None

let require_tensor_parts ?reg ~loc ~context ty =
  match tensor_parts ?reg ty with
  | Some parts -> parts
  | None ->
      Core_error.errorf (Core_error.Stage Core_stage.Specialize) loc
        ~hint:
          "This specialization path is tensor-specific. If source typechecking \
           allowed this call, fix the earlier dispatch instead of choosing a \
           default element type here."
        "%s, got %s" context (Types.type_to_string ty)

let tensor_elem_type ?reg ~loc ~context ty =
  let elem, _ = require_tensor_parts ?reg ~loc ~context ty in
  normalize_type elem

let cast e arg target_ty = { e with desc = CCast (arg, target_ty) }

let specialize_list_alloc ~reg e cap =
  {
    e with
    desc =
      CListAlloc
        {
          la_layout =
            Core_layout_type.list_storage_layout_of_type ~reg e.ty e.loc;
          la_capacity = cap;
        };
  }

let rec specialize_layout_allocs_expr ~reg (e : core) : core =
  let e = map_children (specialize_layout_allocs_expr ~reg) e in
  match e.desc with
  | CCall (CKIntrinsic "list_alloc", _, [ cap ])
  | CCall (CKBuiltin "blorp_list_new", _, [ cap ]) ->
      specialize_list_alloc ~reg e cap
  | _ -> e

(** Specialize [to_int(arg)] by argument type.
    Float/Bool/Char/sized-int/range -> CCast to Int.
    Int -> identity (elide call).
    String -> blorp_to_int (parse). *)
let specialize_to_int (e : core) arg : core =
  match normalize_type arg.ty with
  | Ast.TyNamed ("Int", _) -> arg
  | Ast.TyNamed ("Float", _)
  | Ast.TyNamed ("Float32", _)
  | Ast.TyNamed ("Float16", _)
  | Ast.TyNamed ("Bool", _)
  | Ast.TyNamed ("Char", _) ->
      cast e arg (Ast.TyNamed ("Int", []))
  (* Range-refined integers erase to [long] at runtime — cast is a no-op
     at the C level but needed so the Core IR carries the right type. *)
  | Ast.TyRange _ -> cast e arg (Ast.TyNamed ("Int", []))
  | ty when Types.is_any_integer_type ty -> cast e arg (Ast.TyNamed ("Int", []))
  | _ -> e

(** Specialize [to_float(arg)] by argument type.
    Int/sized-int/range -> CCast to Float.
    Float -> identity.
    Bool -> CCast to Int then CCast to Float.
    String -> blorp_to_float (parse). *)
let specialize_to_float (e : core) arg : core =
  match normalize_type arg.ty with
  | Ast.TyNamed ("Float", _) -> arg
  | Ast.TyNamed ("Int", _)
  | Ast.TyNamed ("Float32", _)
  | Ast.TyNamed ("Float16", _) ->
      cast e arg (Ast.TyNamed ("Float", []))
  | Ast.TyNamed ("Bool", _) ->
      let to_long =
        cast
          { arg with ty = Ast.TyNamed ("Int", []) }
          arg
          (Ast.TyNamed ("Int", []))
      in
      cast e to_long (Ast.TyNamed ("Float", []))
  | Ast.TyRange _ -> cast e arg (Ast.TyNamed ("Float", []))
  | ty when Types.is_any_integer_type ty ->
      cast e arg (Ast.TyNamed ("Float", []))
  | _ -> e

let specialize_to_float32 (e : core) arg : core =
  match normalize_type arg.ty with
  | Ast.TyNamed ("Float32", _) -> arg
  | Ast.TyRange _ -> cast e arg (Ast.TyNamed ("Float32", []))
  | _ -> cast e arg (Ast.TyNamed ("Float32", []))

let specialize_to_float16 (e : core) arg : core =
  match normalize_type arg.ty with
  | Ast.TyNamed ("Float16", _) -> arg
  | Ast.TyRange _ -> cast e arg (Ast.TyNamed ("Float16", []))
  | _ -> cast e arg (Ast.TyNamed ("Float16", []))

(** Specialize [to_string(arg)] by argument type.
    Dispatches to the correct C to_string function. *)
let enum_vector_to_string_name name =
  "blorp_vector_to_string_" ^ Codegen_names.sanitize_c_ident name

let tensor_to_string_builtin = function
  | Core_layout_type.TensorToStringFloat32 -> "blorp_vector_to_string_float32"
  | Core_layout_type.TensorToStringFloat16 -> "blorp_vector_to_string_float16"
  | Core_layout_type.TensorToStringFloat -> "blorp_vector_to_string_float"
  | Core_layout_type.TensorToStringBool -> "blorp_vector_to_string_bool"
  | Core_layout_type.TensorToStringEnum name -> enum_vector_to_string_name name
  | Core_layout_type.TensorToStringInt -> "blorp_vector_to_string_int"

let specialize_to_string ~reg (e : core) callee arg : core =
  let builtin c = { e with desc = CCall (CKBuiltin c, callee, [ arg ]) } in
  let is_tensor_type ty = is_tensor_type ~reg ty in
  let tensor_elem_type ~loc ~context ty =
    tensor_elem_type ~reg ~loc ~context ty
  in
  match normalize_type arg.ty with
  | Ast.TyNamed ("String", _) -> arg
  | ty when Types.Dim.is_value_dim ty -> builtin "blorp_to_string"
  | Ast.TyRange _ ->
      (* Refinement types [..#N] erase to [long] at runtime; dispatch
         through Int's runtime. trait_resolve does not reach [..#N] via
         [Stringable for Int] because the refinement type is distinct. *)
      builtin "blorp_to_string"
  | Ast.TyNamed ("Int128", _) -> builtin "blorp_int128_to_string"
  | Ast.TyNamed ("UInt128", _) -> builtin "blorp_uint128_to_string"
  | ty when Types.is_any_integer_type ty ->
      (* Fallback for integer types that may not have made it through
         trait_resolve (e.g. post-mono concrete calls that weren't
         rewritten because the impl registry entry wasn't in scope at
         the right phase). All sized-integer stdlib impls call
         [blorp_to_string] anyway. *)
      builtin "blorp_to_string"
  | Ast.TyNamed ("Float", _) -> builtin "blorp_float_to_string"
  | Ast.TyNamed ("Float32", _) -> builtin "blorp_float32_to_string"
  | Ast.TyNamed ("Float16", _) -> builtin "blorp_float16_to_string"
  | Ast.TyNamed ("Bool", _) -> builtin "blorp_bool_to_string"
  | Ast.TyNamed ("Char", _) -> builtin "blorp_from_char"
  | Ast.TyNamed ("Bytes", _) -> builtin "blorp_bytes_to_string"
  | Ast.TyNamed ("List", [ et ]) ->
      let elem_ty = normalize_type et in
      let ts_fn =
        match elem_ty with
        | ty when Types.is_any_integer_type ty -> "blorp_list_to_string_int"
        | Ast.TyNamed ("Float", _) -> "blorp_list_to_string_float"
        | Ast.TyNamed ("Float32", _) -> "blorp_list_to_string_float32"
        | Ast.TyNamed ("Float16", _) -> "blorp_list_to_string_float16"
        | Ast.TyNamed ("String", _) -> "blorp_list_to_string_string"
        | Ast.TyNamed ("Bool", _) -> "blorp_list_to_string_bool"
        | _ -> "blorp_list_to_string_cb"
      in
      builtin ts_fn
  | ty when is_tensor_type ty ->
      let elem =
        tensor_elem_type ~loc:e.loc
          ~context:"to_string tensor dispatch requires a tensor argument" ty
      in
      let ts_fn =
        Core_layout_type.tensor_to_string_runtime_of_elem_type ~reg elem
        |> tensor_to_string_builtin
      in
      builtin ts_fn
  | Ast.TyNamed ("StringSlice", _) -> builtin "Stringable_to_string_StringSlice"
  | Ast.TyNamed ("Url", _) -> builtin "Stringable_to_string_Url"
  | Ast.TyNamed ("Fixed", _) -> builtin "blorp_fixed_to_string"
  | _ ->
      (* No Stringable impl for this type.  The [to_string] sentinel was
         registered in [env_builtins] with a [T: Stringable] bound; if we
         reach here, typecheck admitted the call but neither
         [Core_trait_resolve] (which would have rewritten the callee to a
         mangled impl name) nor the type-dispatch table above had a
         rewrite.  That used to silently emit [blorp_to_string(arg)] — the
         runtime function for [Int] — causing an incoherent C warning and
         garbage output.  Fire a structured error instead so the gap is
         visible at the correct call site. *)
      let type_name = Types.type_to_string (normalize_type arg.ty) in
      Core_error.errorf (Core_error.Stage Core_stage.Specialize) arg.loc
        ~hint:
          (Printf.sprintf
             "no Stringable impl is in scope for '%s'. Options: (1) call \
              [debug_string(x)] for a compiler-synthesized debug \
              representation that works on any type, or (2) add [implements \
              Stringable for %s: func to_string(...) -> String: ...]"
             type_name type_name)
        "to_string has no Stringable impl for type '%s'" type_name

(** Specialize [debug_string(arg)] by argument type.

    Universal debug representation — works on any type by design,
    unlike [to_string] which requires a Stringable impl. Routes to
    existing runtime [to_string] variants for primitives and
    collections, emits a placeholder literal for opaque types (fn,
    Channel, Ptr), and — for now — falls through for composite user
    types (tuples / records / unions / enums). Composite support is
    a follow-up; callers hitting the fallthrough will see the same
    "no debug_string for this type" codegen failure that [to_string]
    produces for non-Stringable types today.

    The representation is debug-oriented: structural where possible,
    placeholders where not. It is non-overrideable — this pass runs
    before any user-defined [func debug_string(x: MyType)] lookup, so
    the compiler's synthesized form is canonical. *)
let specialize_debug_string ~reg (e : core) callee arg : core =
  let builtin c = { e with desc = CCall (CKBuiltin c, callee, [ arg ]) } in
  let is_tensor_type ty = is_tensor_type ~reg ty in
  let tensor_elem_type ~loc ~context ty =
    tensor_elem_type ~reg ~loc ~context ty
  in
  let lit_string s =
    let flags = { Ast.sf_triple = false; sf_raw = false } in
    {
      e with
      desc = CLit (Ast.LitString (s, flags));
      ty = Ast.TyNamed ("String", []);
    }
  in
  match normalize_type arg.ty with
  (* Primitives — route through the same runtime functions [to_string] uses.
     The representation is identical for now; a follow-up can differentiate
     (e.g., quote/escape strings for debug output).
     debug_string is a universal compiler-synthesized function (no trait,
     no user impls). All primitive arms are reached directly by
     [specialize_debug_string] — unlike [specialize_to_string] where
     trait_resolve already rewrites to the stdlib impl. *)
  | Ast.TyNamed ("String", _) -> arg
  | Ast.TyNamed ("Int", _) -> builtin "blorp_to_string"
  | ty when Types.Dim.is_value_dim ty -> builtin "blorp_to_string"
  | Ast.TyRange _ -> builtin "blorp_to_string"
  | Ast.TyNamed ("Float", _) -> builtin "blorp_float_to_string"
  | Ast.TyNamed ("Float32", _) -> builtin "blorp_float32_to_string"
  | Ast.TyNamed ("Float16", _) -> builtin "blorp_float16_to_string"
  | Ast.TyNamed ("Bool", _) -> builtin "blorp_bool_to_string"
  | Ast.TyNamed ("Char", _) -> builtin "blorp_from_char"
  | Ast.TyNamed ("Int128", _) -> builtin "blorp_int128_to_string"
  | Ast.TyNamed ("UInt128", _) -> builtin "blorp_uint128_to_string"
  | Ast.TyNamed ("Bytes", _) -> builtin "blorp_bytes_to_string"
  | ty when Types.is_any_integer_type ty -> builtin "blorp_to_string"
  (* Collections — reuse existing per-element-type variants. *)
  | Ast.TyNamed ("List", [ et ]) ->
      let elem_ty = normalize_type et in
      let fn =
        match elem_ty with
        | Ast.TyNamed ("Float", _) -> "blorp_list_to_string_float"
        | Ast.TyNamed ("Float32", _) -> "blorp_list_to_string_float32"
        | Ast.TyNamed ("Float16", _) -> "blorp_list_to_string_float16"
        | Ast.TyNamed ("String", _) -> "blorp_list_to_string_string"
        | Ast.TyNamed ("Bool", _) -> "blorp_list_to_string_bool"
        | _ -> "blorp_list_to_string_int"
      in
      builtin fn
  | ty when is_tensor_type ty ->
      let elem =
        tensor_elem_type ~loc:e.loc
          ~context:"debug_string tensor dispatch requires a tensor argument" ty
      in
      let fn =
        match normalize_type elem with
        | Ast.TyNamed ("Float32", _) -> "blorp_vector_to_string_float32"
        | Ast.TyNamed ("Float16", _) -> "blorp_vector_to_string_float16"
        | Ast.TyNamed ("Float", _) -> "blorp_vector_to_string_float"
        | _ -> "blorp_vector_to_string_int"
      in
      builtin fn
  | Ast.TyNamed ("StringSlice", _) -> builtin "Stringable_to_string_StringSlice"
  | Ast.TyNamed ("Url", _) -> builtin "Stringable_to_string_Url"
  | Ast.TyNamed ("Fixed", _) -> builtin "blorp_fixed_to_string"
  (* Opaque types — no meaningful structural view; emit a placeholder.
     Note: this skips evaluating [arg], which is OK for pure refs
     (the callee was already looked up as a value). If [arg] is a
     side-effectful expression (rare; debug_string of a function
     application result), the side effect is preserved by [arg]'s
     placement in the containing expression. *)
  | Ast.TyNamed ("Void", _) -> lit_string "()"
  | Ast.TyFunc _ -> lit_string "<fn>"
  | Ast.TyNamed ("Channel", _) -> lit_string "<channel>"
  | Ast.TyNamed ("Ptr", _) -> lit_string "<ptr>"
  (* Composite types (tuples, records, unions, enums) — deferred.
     The call passes through unchanged; code will fail at C compile
     with an undeclared-identifier error for [blorp_debug_string].
     Caller gets the same shape of diagnostic they'd get for
     [to_string] on a non-Stringable type today. *)
  | _ -> e

(** Specialize [hash(arg)] by argument type.

    Primitive types route to the runtime's HashDoS-resistant seeded
    hash functions ([blorp_dict_hash_int], [blorp_dict_hash_string]
    etc. — already used internally by Dict/Set key dispatch). For
    floats, the runtime doesn't have a dedicated hasher; we bit-cast
    to an integer of matching width and route through
    [blorp_dict_hash_int]. For booleans, bit-value works directly.
    For Char, the codepoint Int is the right hash. Unknown types
    pass through — core_trait_resolve handles user-defined Hashable
    impls via the normal method-dispatch path. *)
let specialize_hash (e : core) callee arg : core =
  let builtin c = { e with desc = CCall (CKBuiltin c, callee, [ arg ]) } in
  match normalize_type arg.ty with
  | Ast.TyNamed ("String", _) -> builtin "blorp_hash_string"
  | ty when Types.Dim.is_value_dim ty -> builtin "blorp_hash_int"
  | Ast.TyNamed ("Int", _) | Ast.TyNamed ("Bool", _) | Ast.TyNamed ("Char", _)
    ->
      builtin "blorp_hash_int"
  | ty when Types.is_any_integer_type ty -> builtin "blorp_hash_int"
  | Ast.TyNamed ("Float", _)
  | Ast.TyNamed ("Float32", _)
  | Ast.TyNamed ("Float16", _) ->
      builtin "blorp_hash_float"
  | _ -> e

let int_ty = Ast.TyNamed ("Int", [])
let void_ty = Ast.TyNamed ("Void", [])

let void_slot_arg_already_explicit arg =
  match arg.desc with CBox _ | CBoxTyped _ -> true | _ -> false

let box_void_slot_arg_if_needed ~reg arg =
  if void_slot_arg_already_explicit arg || is_pointer_type ~reg arg.ty then
    (arg, false)
  else ({ arg with desc = CBox (arg, arg.ty); ty = void_ty }, true)

let box_void_args_for_builtin ~reg name args =
  match List.assoc_opt name void_boxed_arg_positions with
  | None -> (args, false)
  | Some positions ->
      let changed = ref false in
      let args =
        List.mapi
          (fun i arg ->
            if List.mem i positions then (
              let arg, arg_changed = box_void_slot_arg_if_needed ~reg arg in
              if arg_changed then changed := true;
              arg)
            else arg)
          args
      in
      (args, !changed)

let int_lit loc n =
  { desc = CLit (Ast.LitInt (Int64.of_int n)); ty = int_ty; loc }

let void_dummy loc = { desc = CVoid; ty = void_ty; loc }

let boxed_storage_needs_release ~reg ~loc ty =
  Core_layout_type.boxed_storage_requires_release_or_error
    ~phase:(Core_error.Stage Core_stage.Specialize) ~reg ty loc

let tensor_result_elem_needs_release ~reg ~loc ~context ty =
  boxed_storage_needs_release ~reg ~loc (tensor_elem_type ~reg ~loc ~context ty)

let returns_nullable_managed_option ~reg ty =
  Core_layout_type.is_nullable_managed_option ~reg ty

let list_elem_type ~loc ~context ty =
  match normalize_type ty with
  | Ast.TyNamed (name, elem :: _)
    when type_name_is "List" name || type_name_is "ParallelList" name ->
      normalize_type elem
  | _ ->
      Core_error.errorf (Core_error.Stage Core_stage.Specialize) loc
        ~hint:
          "This specialization path is list-specific. If source typechecking \
           allowed this call, fix the earlier dispatch instead of choosing a \
           default element type here."
        "%s must be List, got %s" context (Types.type_to_string ty)

let list_result_elem_needs_release ~reg ~loc ~context ty =
  boxed_storage_needs_release ~reg ~loc (list_elem_type ~loc ~context ty)

let stream_elem_type ~loc ~context ty =
  match normalize_type ty with
  | Ast.TyNamed (name, [ elem ]) when type_name_is "Stream" name ->
      normalize_type elem
  | _ ->
      Core_error.errorf (Core_error.Stage Core_stage.Specialize) loc
        ~hint:
          "This specialization path is stream-specific. If source typechecking \
           allowed this call, fix the earlier dispatch instead of choosing a \
           default element type here."
        "%s must be Stream, got %s" context (Types.type_to_string ty)

let stream_result_elem_needs_release ~reg ~loc ~context ty =
  boxed_storage_needs_release ~reg ~loc (stream_elem_type ~loc ~context ty)

type stream_element_layout =
  | StreamImmediate
  | StreamBorrowedArc
  | StreamOwnedArc

let stream_element_layout_code = function
  | StreamImmediate -> 0
  | StreamBorrowedArc -> 1
  | StreamOwnedArc -> 2

let stream_result_owned_layout ~reg ~loc ~context ty =
  if stream_result_elem_needs_release ~reg ~loc ~context ty then StreamOwnedArc
  else StreamImmediate

let stream_result_borrowed_layout ~reg ~loc ~context ty =
  if stream_result_elem_needs_release ~reg ~loc ~context ty then
    StreamBorrowedArc
  else StreamImmediate

let stream_state_layout ~reg ~loc ty =
  if
    Core_layout_type.source_value_requires_retain_or_error
      ~phase:(Core_error.Stage Core_stage.Specialize) ~reg ty loc
  then StreamOwnedArc
  else StreamImmediate

let stream_layout_needs_pointer_arg = function
  | StreamImmediate -> false
  | StreamBorrowedArc | StreamOwnedArc -> true

let stream_runtime_value_arg ~reg ~layout arg =
  if stream_layout_needs_pointer_arg layout || is_pointer_type ~reg arg.ty then
    arg
  else
    let ptr_ty = Ast.TyNamed ("Ptr", []) in
    { arg with desc = CCast (arg, ptr_ty); ty = ptr_ty }

let tensor_has_elem ?reg name ty =
  match tensor_parts ?reg ty with
  | None -> false
  | Some (elem, _) -> (
      match normalize_type elem with
      | Ast.TyNamed (got, _) -> got = name
      | _ -> false)

let int_literal_value e =
  match e.desc with CLit (Ast.LitInt n) -> Some (Int64.to_int n) | _ -> None

let find_loop_index_bound env v =
  List.find_opt (fun bound -> Var.equal bound.lib_var v) env.loop_index_bounds

let rec expr_is_nonnegative env e =
  match int_literal_value e with
  | Some n -> n >= 0
  | None -> (
      match e.desc with
      | CVar v -> (
          match find_loop_index_bound env v with
          | Some bound -> bound.lib_lower_nonnegative
          | None -> false)
      | CBin (Ast.Add, l, r) ->
          expr_is_nonnegative env l && expr_is_nonnegative env r
      | _ -> false)

let loop_index_bound_for_range env binder iter =
  match iter.desc with
  | CRange (start, stop) ->
      Some
        {
          lib_var = binder.loop_var;
          lib_lower_nonnegative = expr_is_nonnegative env start;
          lib_upper_exclusive = int_literal_value stop;
        }
  | _ -> None

let tensor_first_dim ?reg ty =
  match tensor_parts ?reg ty with
  | Some (_, Ast.TyConstInt n :: _) -> Some n
  | _ -> None

let loop_proves_tensor_index_in_bounds ?reg env tensor idx =
  match idx.desc with
  | CVar v -> (
      match (find_loop_index_bound env v, tensor_first_dim ?reg tensor.ty) with
      | ( Some
            { lib_lower_nonnegative = true; lib_upper_exclusive = Some stop; _ },
          Some dim ) ->
          stop <= dim
      | _ -> false)
  | _ -> false

let tensor_fast_read_intrinsics_of_kind = function
  | TensorFloat64Elements ->
      ("tensor_is_f64_storage", TensorFloat64Elements, "tensor_get_f64")
  | TensorFloat32Elements ->
      ("tensor_is_f32_storage", TensorFloat32Elements, "tensor_get_f32")
  | TensorInt64Elements ->
      ("tensor_is_i64_storage", TensorInt64Elements, "tensor_get_i64")

let tensor_fast_read_intrinsics ?reg ty =
  let reg = effective_reg reg in
  match Core_layout_type.tensor_raw_scalar_kind_of_type ~reg ty with
  | Some kind -> Some (tensor_fast_read_intrinsics_of_kind kind)
  | None -> None

let raw_tensor_kind_of_storage_pred = function
  | "tensor_is_f64_storage" -> Some TensorFloat64Elements
  | "tensor_is_f32_storage" -> Some TensorFloat32Elements
  | "tensor_is_i64_storage" -> Some TensorInt64Elements
  | _ -> None

let raw_tensor_kind_of_raw_get = function
  | "tensor_get_f64_raw_unchecked" -> Some TensorFloat64Elements
  | "tensor_get_f32_raw_unchecked" -> Some TensorFloat32Elements
  | "tensor_get_i64_raw_unchecked" -> Some TensorInt64Elements
  | _ -> None

let raw_tensor_kind_of_vector_set_builtin = function
  | "blorp_vector_set_inplace_f64" -> Some TensorFloat64Elements
  | "blorp_vector_set_inplace_f32" -> Some TensorFloat32Elements
  | "blorp_vector_set_inplace_i64" -> Some TensorInt64Elements
  | _ -> None

let raw_tensor_storage_pred_intrinsic kind =
  let pred, _, _ = tensor_fast_read_intrinsics_of_kind kind in
  pred

let bounds_proven_tensor_read ?reg env e tensor idx =
  if not (loop_proves_tensor_index_in_bounds ?reg env tensor idx) then None
  else
    match tensor_fast_read_intrinsics ?reg e.ty with
    | None -> None
    | Some (storage_pred_intr, raw_kind, safe_get_intr) ->
        let void_ty = Ast.TyNamed ("Void", []) in
        let dummy = { e with desc = CVoid; ty = void_ty } in
        let storage_ok =
          {
            e with
            desc = CCall (CKIntrinsic storage_pred_intr, dummy, [ tensor ]);
            ty = Ast.TyNamed ("Bool", []);
          }
        in
        let raw_view =
          let prefix =
            match tensor.desc with CVar v -> Var.to_c_name v | _ -> "expr"
          in
          Var.named (fresh_raw_view_name prefix)
        in
        let raw_read =
          {
            e with
            desc =
              CTensorRawRead
                { trr_view = raw_view; trr_kind = raw_kind; trr_index = idx };
          }
        in
        let fast_read =
          {
            e with
            desc =
              CTensorRawViewLet
                ( {
                    trv_var = raw_view;
                    trv_kind = raw_kind;
                    trv_source = tensor;
                  },
                  raw_read );
          }
        in
        let safe_read =
          {
            e with
            desc = CCall (CKIntrinsic safe_get_intr, dummy, [ tensor; idx ]);
          }
        in
        Some { e with desc = CIf (storage_ok, fast_read, safe_read) }

let ty_bool = Ast.TyNamed ("Bool", [])
let ty_void = Ast.TyNamed ("Void", [])
let mk_core ~loc ~ty desc = { desc; ty; loc }
let mk_void ~loc desc = mk_core ~loc ~ty:ty_void desc
let dummy_callee loc = mk_void ~loc CVoid
let cvar ~loc v ty = mk_core ~loc ~ty (CVar v)

let string_starts_with s prefix =
  let slen = String.length s in
  let plen = String.length prefix in
  slen >= plen && String.sub s 0 plen = prefix

let is_vector_get_opt_builtin_name = function
  | "blorp_vector_get_opt" -> true
  | name -> string_starts_with name "blorp_vector_get_opt_"

let is_stable_get_or_input e =
  match e.desc with CVar _ | CLit _ -> true | _ -> false

let tensor_get_or_match_default tree =
  let leaf_returns_some_payload = function
    | CTLeaf
        {
          ct_bindings = [ (some_v, AccVariantField (AccRoot, "Some", 0)) ];
          ct_body = { desc = CVar body_v; _ };
        }
      when Var.equal some_v body_v ->
        true
    | _ -> false
  in
  let leaf_body_without_bindings = function
    | CTLeaf { ct_bindings = []; ct_body } -> Some ct_body
    | _ -> None
  in
  match tree with
  | CTSwitchTag { cts_scrut = AccRoot; cts_cases; cts_default = None } -> (
      match
        (List.assoc_opt "Some" cts_cases, List.assoc_opt "None" cts_cases)
      with
      | Some some_tree, Some none_tree when leaf_returns_some_payload some_tree
        ->
          leaf_body_without_bindings none_tree
      | _ -> None)
  | _ -> None

let direct_tensor_get_or_read ~reg ~loc ~return_ty arr idx =
  let dummy = dummy_callee loc in
  match Core_layout_type.tensor_checked_get_access_of_type ~reg return_ty with
  | Some access ->
      Some
        (mk_core ~loc ~ty:return_ty
           (CCall
              ( CKIntrinsic access.Core_layout_type.tcga_get_intrinsic,
                dummy,
                [ arr; idx ] )))
  | None -> (
      match Core_layout_type.tensor_element_storage ~reg return_ty with
      | Core_layout_type.TensorElementInlineStruct _ ->
          Some
            (mk_core ~loc ~ty:return_ty
               (CCall (CKIntrinsic "tensor_get_unchecked", dummy, [ arr; idx ])))
      | Core_layout_type.TensorElementRawScalar _
      | Core_layout_type.TensorElementPackedBits _
      | Core_layout_type.TensorElementBoxed ->
          None)

let rewrite_tensor_get_or_match ~reg e scrut tree =
  match scrut.desc with
  | CCall (CKBuiltin get_name, _, [ arr; idx ])
    when is_vector_get_opt_builtin_name get_name
         && is_stable_get_or_input arr && is_stable_get_or_input idx -> (
      match
        ( tensor_get_or_match_default tree,
          direct_tensor_get_or_read ~reg ~loc:e.loc ~return_ty:e.ty arr idx )
      with
      | Some default, Some read ->
          let zero = int_lit e.loc 0 in
          let len =
            mk_core ~loc:e.loc ~ty:int_ty
              (CCall (CKIntrinsic "tensor_len", dummy_callee e.loc, [ arr ]))
          in
          let lower_ok =
            mk_core ~loc:e.loc ~ty:ty_bool (CBin (Ast.Ge, idx, zero))
          in
          let upper_ok =
            mk_core ~loc:e.loc ~ty:ty_bool (CBin (Ast.Lt, idx, len))
          in
          let in_bounds =
            mk_core ~loc:e.loc ~ty:ty_bool (CLog (Ast.And, lower_ok, upper_ok))
          in
          Some { e with desc = CIf (in_bounds, read, default) }
      | _ -> None)
  | _ -> None

let is_raw_view_ok_var v =
  String.length v.vname >= String.length "__tensor_raw_view_ok_"
  && String.sub v.vname 0 (String.length "__tensor_raw_view_ok_")
     = "__tensor_raw_view_ok_"

let var_is_blocked blocked v = List.exists (fun b -> Var.equal b v) blocked

let raw_tensor_kind_of_guarded_read e =
  let guarded_source = function
    | {
        desc =
          CCall
            (CKIntrinsic storage_pred, _, [ ({ desc = CVar pred_v; _ } as t) ]);
        _;
      } -> (
        match raw_tensor_kind_of_storage_pred storage_pred with
        | Some pred_kind -> Some (t, pred_v, pred_kind)
        | None -> None)
    | _ -> None
  in
  match e.desc with
  | CIf (cond, fast_read, _safe) -> (
      match guarded_source cond with
      | None -> None
      | Some (t, pred_v, pred_kind) -> (
          match fast_read.desc with
          | CCall (CKIntrinsic raw_get, _, [ { desc = CVar raw_v; _ }; idx ])
            -> (
              match raw_tensor_kind_of_raw_get raw_get with
              | Some raw_kind
                when Var.equal pred_v raw_v && pred_kind = raw_kind ->
                  Some (t, idx, raw_kind)
              | _ -> None)
          | CTensorRawViewLet
              ( { trv_var; trv_kind; trv_source = { desc = CVar source_v; _ } },
                {
                  desc =
                    CTensorRawRead { trr_view; trr_kind; trr_index = idx; _ };
                  _;
                } )
            when Var.equal pred_v source_v && Var.equal trv_var trr_view
                 && pred_kind = trv_kind && trv_kind = trr_kind ->
              Some (t, idx, trr_kind)
          | _ -> None))
  | _ -> None

let add_raw_tensor_view blocked views tensor kind needs_unique =
  match tensor.desc with
  | CVar v when not (var_is_blocked blocked v) ->
      let rec add acc = function
        | [] ->
            Some
              (List.rev
                 ({
                    rtv_tensor = v;
                    rtv_tensor_ty = tensor.ty;
                    rtv_ptr = Var.named (fresh_raw_view_name (Var.to_c_name v));
                    rtv_kind = kind;
                    rtv_needs_unique = needs_unique;
                  }
                 :: acc))
        | existing :: rest when Var.equal existing.rtv_tensor v ->
            if existing.rtv_kind <> kind then None
            else
              let merged =
                {
                  existing with
                  rtv_needs_unique = existing.rtv_needs_unique || needs_unique;
                }
              in
              Some (List.rev_append acc (merged :: rest))
        | existing :: rest -> add (existing :: acc) rest
      in
      add [] views
  | _ -> Some views

let body_env_for_loop env binder iter =
  match loop_index_bound_for_range env binder iter with
  | Some bound -> { loop_index_bounds = bound :: env.loop_index_bounds }
  | None -> env

let rec collect_raw_tensor_views ?reg env blocked views e =
  let collect_child acc child =
    collect_raw_tensor_views ?reg env blocked acc child
  in
  let collect_child_opt acc child =
    match acc with None -> None | Some views -> collect_child views child
  in
  let collect_children views e =
    Core.fold_immediate_children collect_child_opt (Some views) e
  in
  match e.desc with
  | CLet (b, _body) when is_raw_view_ok_var b.bind_var -> Some views
  | CBorrowLet (b, _body) when is_raw_view_ok_var b.borrow_var ->
      (* A nested raw-view loop already owns this subtree's fast/fallback
         split. Do not hoist its fallback patterns again into an outer loop. *)
      Some views
  | CLet (b, body) ->
      Option.bind (collect_raw_tensor_views ?reg env blocked views b.bind_rhs)
        (fun views ->
          collect_raw_tensor_views ?reg env (b.bind_var :: blocked) views body)
  | CBorrowLet (b, body) ->
      Option.bind (collect_raw_tensor_views ?reg env blocked views b.borrow_rhs)
        (fun views ->
          collect_raw_tensor_views ?reg env (b.borrow_var :: blocked) views body)
  | CResourceScope _ ->
      (* Resource scopes are semantic cleanup boundaries. Do not hoist raw
         tensor views from acquisition/body/cleanup into an enclosing loop. *)
      Some views
  | CFor (binder, iter, body) ->
      Option.bind (collect_raw_tensor_views ?reg env blocked views iter)
        (fun views ->
          let body_env = body_env_for_loop env binder iter in
          collect_raw_tensor_views ?reg body_env
            (binder.loop_var :: blocked)
            views body)
  | CAssign
      ( assign_v,
        ({
           desc =
             CCall
               ( CKBuiltin set_name,
                 _,
                 [ ({ desc = CVar arr_v; _ } as arr); idx; value ] );
           _;
         } as rhs) ) -> (
      let base =
        Option.bind (collect_raw_tensor_views ?reg env blocked views value)
          (fun views -> collect_raw_tensor_views ?reg env blocked views idx)
      in
      match (base, raw_tensor_kind_of_vector_set_builtin set_name) with
      | Some views, Some kind
        when Var.equal assign_v arr_v
             && loop_proves_tensor_index_in_bounds ?reg env arr idx ->
          add_raw_tensor_view blocked views arr kind true
      | Some views, _ -> collect_children views rhs
      | None, _ -> None)
  | _ -> (
      match raw_tensor_kind_of_guarded_read e with
      | Some (tensor, idx, kind) ->
          Option.bind (collect_raw_tensor_views ?reg env blocked views idx)
            (fun views -> add_raw_tensor_view blocked views tensor kind false)
      | None -> collect_children views e)

let find_raw_tensor_view blocked views tensor kind =
  match tensor.desc with
  | CVar v when not (var_is_blocked blocked v) ->
      List.find_opt
        (fun view -> Var.equal view.rtv_tensor v && view.rtv_kind = kind)
        views
  | _ -> None

let raw_tensor_ptr_read loc view idx result_ty =
  mk_core ~loc ~ty:result_ty
    (CTensorRawRead
       { trr_view = view.rtv_ptr; trr_kind = view.rtv_kind; trr_index = idx })

let raw_tensor_ptr_write loc view idx value =
  mk_void ~loc
    (CTensorRawWrite
       {
         trw_view = view.rtv_ptr;
         trw_kind = view.rtv_kind;
         trw_index = idx;
         trw_value = value;
       })

let rec rewrite_raw_tensor_view_body ?reg env blocked views e =
  let rewrite = rewrite_raw_tensor_view_body ?reg env blocked views in
  match raw_tensor_kind_of_guarded_read e with
  | Some (tensor, idx, kind) -> (
      match find_raw_tensor_view blocked views tensor kind with
      | Some view -> raw_tensor_ptr_read e.loc view (rewrite idx) e.ty
      | None -> map_children rewrite e)
  | None -> (
      match e.desc with
      | CLet (b, body) ->
          let rhs' = rewrite b.bind_rhs in
          let body' =
            rewrite_raw_tensor_view_body ?reg env (b.bind_var :: blocked) views
              body
          in
          { e with desc = CLet ({ b with bind_rhs = rhs' }, body') }
      | CBorrowLet (b, body) ->
          let rhs' = rewrite b.borrow_rhs in
          let body' =
            rewrite_raw_tensor_view_body ?reg env (b.borrow_var :: blocked)
              views body
          in
          { e with desc = CBorrowLet ({ b with borrow_rhs = rhs' }, body') }
      | CResourceScope _ ->
          (* Do not rewrite reads inside cleanup scopes to use a raw view that
             was proven and bound outside the resource lifetime boundary. *)
          e
      | CFor (binder, iter, body) ->
          let iter' = rewrite iter in
          let body_env = body_env_for_loop env binder iter' in
          let body' =
            rewrite_raw_tensor_view_body ?reg body_env
              (binder.loop_var :: blocked)
              views body
          in
          { e with desc = CFor (binder, iter', body') }
      | CAssign
          ( assign_v,
            {
              desc =
                CCall
                  ( CKBuiltin set_name,
                    _,
                    [ ({ desc = CVar arr_v; _ } as arr); idx; value ] );
              _;
            } ) -> (
          match raw_tensor_kind_of_vector_set_builtin set_name with
          | Some kind
            when Var.equal assign_v arr_v
                 && loop_proves_tensor_index_in_bounds ?reg env arr idx -> (
              match find_raw_tensor_view blocked views arr kind with
              | Some view ->
                  let idx' = rewrite idx in
                  let value' = rewrite value in
                  let store = raw_tensor_ptr_write e.loc view idx' value' in
                  { e with desc = CSeq (store, mk_void ~loc:e.loc CVoid) }
              | None -> map_children rewrite e)
          | _ -> map_children rewrite e)
      | _ -> map_children rewrite e)

let raw_tensor_view_condition loc view =
  let tensor = cvar ~loc view.rtv_tensor view.rtv_tensor_ty in
  let storage_ok =
    mk_core ~loc ~ty:ty_bool
      (CCall
         ( CKIntrinsic (raw_tensor_storage_pred_intrinsic view.rtv_kind),
           dummy_callee loc,
           [ tensor ] ))
  in
  if not view.rtv_needs_unique then storage_ok
  else
    let unique_ok =
      mk_core ~loc ~ty:ty_bool
        (CCall (CKIntrinsic "tensor_is_unique", dummy_callee loc, [ tensor ]))
    in
    mk_core ~loc ~ty:ty_bool (CLog (Ast.And, storage_ok, unique_ok))

let combine_raw_tensor_view_conditions loc views =
  match views with
  | [] -> None
  | first :: rest ->
      let first_cond = raw_tensor_view_condition loc first in
      Some
        (List.fold_left
           (fun acc view ->
             mk_core ~loc ~ty:ty_bool
               (CLog (Ast.And, acc, raw_tensor_view_condition loc view)))
           first_cond rest)

let bind_raw_tensor_views loc views body =
  List.fold_right
    (fun view body ->
      let tensor = cvar ~loc view.rtv_tensor view.rtv_tensor_ty in
      {
        body with
        desc =
          CTensorRawViewLet
            ( {
                trv_var = view.rtv_ptr;
                trv_kind = view.rtv_kind;
                trv_source = tensor;
              },
              body );
      })
    views body

let maybe_add_raw_tensor_view_loop ?reg env loop =
  match loop.desc with
  | CFor _ -> (
      match collect_raw_tensor_views ?reg env [] [] loop with
      | None | Some [] -> loop
      | Some views -> (
          match combine_raw_tensor_view_conditions loop.loc views with
          | None -> loop
          | Some condition ->
              let ok_var = Var.named (fresh_raw_view_name "ok") in
              let ok_expr = cvar ~loc:loop.loc ok_var ty_bool in
              let fast_loop =
                rewrite_raw_tensor_view_body ?reg env [] views loop
                |> bind_raw_tensor_views loop.loc views
              in
              let guarded =
                mk_void ~loc:loop.loc (CIf (ok_expr, fast_loop, loop))
              in
              {
                loop with
                desc =
                  CLet
                    ( {
                        bind_var = ok_var;
                        bind_mut = false;
                        bind_ty = ty_bool;
                        bind_rhs = condition;
                      },
                      guarded );
              }))
  | _ -> loop

let packed_tensor_elem_width_bytes ~reg ty =
  match tensor_parts ~reg ty with
  | Some (elem, _) -> (
      match Core_layout_type.tensor_element_storage ~reg elem with
      | Core_layout_type.TensorElementPackedBits width ->
          Some (inline_storage_width_bytes width)
      | _ -> None)
  | None -> None

let option_runtime_builtin ?boxed abi ~primitive ~nullable =
  match abi with
  | Core_layout_type.OptionPayloadPrimitiveStack suffix ->
      Some (primitive suffix)
  | Core_layout_type.OptionPayloadNullableManaged -> Some nullable
  | Core_layout_type.OptionPayloadBoxedUnion -> boxed
  | Core_layout_type.OptionPayloadNoSpecialization -> None

let option_type_runtime_builtin ?boxed ~reg ty ~primitive ~nullable =
  match Core_layout_type.option_type_runtime_abi ~reg ty with
  | Some abi -> option_runtime_builtin ?boxed abi ~primitive ~nullable
  | None -> None

let option_payload_runtime_builtin ?boxed ~reg payload_ty ~primitive ~nullable =
  Core_layout_type.option_payload_runtime_abi ~reg payload_ty
  |> option_runtime_builtin ?boxed ~primitive ~nullable

let tensor_get_builtin_for_option_layout ~reg ~kind ~collection_ty ~return_ty =
  ignore collection_ty;
  option_type_runtime_builtin ~reg return_ty
    ~primitive:(Printf.sprintf "blorp_%s_get_opt_%s" kind)
    ~nullable:(Printf.sprintf "blorp_%s_get_nullable" kind)

let vector_set_cow_builtin_for_option_layout ~reg ~collection_ty ~return_ty =
  let nullable_return =
    match Core_layout_type.option_type_runtime_abi ~reg return_ty with
    | Some Core_layout_type.OptionPayloadNullableManaged -> true
    | Some
        ( Core_layout_type.OptionPayloadPrimitiveStack _
        | Core_layout_type.OptionPayloadBoxedUnion
        | Core_layout_type.OptionPayloadNoSpecialization )
    | None ->
        false
  in
  if nullable_return then
    if tensor_has_elem ~reg "Int" collection_ty then
      Some "blorp_vector_set_cow_nullable_i64"
    else if tensor_has_elem ~reg "Float32" collection_ty then
      Some "blorp_vector_set_cow_nullable_f32"
    else Some "blorp_vector_set_cow_nullable"
  else if tensor_has_elem ~reg "Int" collection_ty then
    Some "blorp_vector_set_cow_i64"
  else if tensor_has_elem ~reg "Float32" collection_ty then
    Some "blorp_vector_set_cow_f32"
  else None

let dict_get_builtin_for_option_layout ~reg ty =
  option_type_runtime_builtin ~reg ty
    ~primitive:(Printf.sprintf "blorp_dict_get_%s")
    ~nullable:"blorp_dict_get_nullable"

let channel_recv_builtin_for_option_layout ~reg base ty =
  option_type_runtime_builtin ~reg ty
    ~primitive:(Printf.sprintf "%s_%s" base)
    ~nullable:(base ^ "_nullable")

let stream_filter_map_builtin_for_option_layout ~reg base ty =
  match Core_layout_type.canonical_type ~reg ty with
  | Ast.TyNamed ("Stream", [ elem ]) ->
      option_payload_runtime_builtin ~reg elem
        ~primitive:(Printf.sprintf "%s_%s" base)
        ~nullable:(base ^ "_nullable")
  | _ -> None

let fallible_stream_find_builtin_for_result_option_layout ~reg ~loc base ty =
  match Core_layout_type.canonical_type ~reg ty with
  | Ast.TyNamed ("Result", [ Ast.TyNamed ("Option", [ elem ]); _ ]) -> (
      match Core_layout_type.option_payload_runtime_abi ~reg elem with
      | Core_layout_type.OptionPayloadPrimitiveStack suffix ->
          base ^ "_" ^ suffix
      | Core_layout_type.OptionPayloadNullableManaged -> base ^ "_nullable"
      | Core_layout_type.OptionPayloadBoxedUnion ->
          Core_error.errorf (Core_error.Stage Core_stage.Specialize) loc
            ~hint:
              "Use a concrete nullable-managed or primitive-stack Option \
               payload for fallible stream find_result, or add a boxed Option \
               ABI before enabling this payload."
            "fallible stream find_result cannot return boxed-union Option \
             payloads yet"
      | Core_layout_type.OptionPayloadNoSpecialization ->
          Core_error.errorf (Core_error.Stage Core_stage.Specialize) loc
            ~hint:
              "Add a runtime specialization for this Option payload layout \
               before using it as find_result's result payload."
            "fallible stream find_result has no Option payload ABI for %s"
            (Types.type_to_string elem))
  | _ ->
      Core_error.errorf (Core_error.Stage Core_stage.Specialize) loc
        ~hint:
          "find_result must return Result[Option[T], E] after type inference \
           and monomorphization"
        "fallible stream find_result has unexpected return type %s"
        (Types.type_to_string ty)

let list_filter_map_parallel_builtin_for_option_layout ~reg base ty =
  match Core_layout_type.canonical_type ~reg ty with
  | Ast.TyNamed (name, [ elem ])
    when type_name_is "List" name || type_name_is "ParallelList" name ->
      option_payload_runtime_builtin ~reg elem
        ~primitive:(Printf.sprintf "%s_%s" base)
        ~nullable:(base ^ "_nullable") ~boxed:base
  | _ -> None

let list_filter_map_parallel_builtins =
  [
    "blorp_filter_map_parallel";
    "blorp_filter_map_parallel_int";
    "blorp_filter_map_parallel_int8";
    "blorp_filter_map_parallel_int16";
    "blorp_filter_map_parallel_int32";
    "blorp_filter_map_parallel_int64";
    "blorp_filter_map_parallel_uint8";
    "blorp_filter_map_parallel_uint16";
    "blorp_filter_map_parallel_uint32";
    "blorp_filter_map_parallel_uint64";
    "blorp_filter_map_parallel_float";
    "blorp_filter_map_parallel_bool";
    "blorp_filter_map_parallel_char";
    "blorp_filter_map_parallel_f32";
    "blorp_filter_map_parallel_f16";
    "blorp_filter_map_parallel_nullable";
  ]

let is_list_filter_map_parallel_builtin c =
  List.mem c list_filter_map_parallel_builtins

let matrix_static_dims ~reg ty =
  match tensor_parts ~reg ty with
  | Some (_, Ast.TyConstInt rows :: Ast.TyConstInt cols :: _) ->
      Some (rows, cols)
  | _ -> None

let vector_static_dim ~reg ty =
  match tensor_parts ~reg ty with
  | Some (_, Ast.TyConstInt n :: _) -> Some n
  | _ -> None

let tensor_elementwise_builtin_name func_name elem_ty =
  match func_name with
  | "norm" | "blorp_vector_norm" ->
      Some
        (match normalize_type elem_ty with
        | Ast.TyNamed ("Float32", _) -> "blorp_vector_norm_float32"
        | Ast.TyNamed ("Float16", _) -> "blorp_vector_norm_float16"
        | _ -> "blorp_vector_norm")
  | "sqrt" | "blorp_vector_sqrt" ->
      Some
        (match normalize_type elem_ty with
        | Ast.TyNamed ("Float32", _) -> "blorp_vector_sqrt_float32"
        | Ast.TyNamed ("Float16", _) -> "blorp_vector_sqrt_float16"
        | _ -> "blorp_vector_sqrt")
  | "exp" | "blorp_vector_exp" ->
      Some
        (match normalize_type elem_ty with
        | Ast.TyNamed ("Float32", _) -> "blorp_vector_exp_float32"
        | Ast.TyNamed ("Float16", _) -> "blorp_vector_exp_float16"
        | _ -> "blorp_vector_exp")
  | "log" | "blorp_vector_log" ->
      Some
        (match normalize_type elem_ty with
        | Ast.TyNamed ("Float32", _) -> "blorp_vector_log_float32"
        | Ast.TyNamed ("Float16", _) -> "blorp_vector_log_float16"
        | _ -> "blorp_vector_log")
  | "abs" | "blorp_vector_abs" -> Some "blorp_vector_abs"
  | _ -> None

let matrix_vector_multiply_runtime_name elem_ty =
  match normalize_type elem_ty with
  | Ast.TyNamed ("Float", _) -> Some "blorp_tensor_matrix_vector_multiply_float"
  | Ast.TyNamed ("Float32", _) ->
      Some "blorp_tensor_matrix_vector_multiply_float32"
  | Ast.TyNamed ("Float16", _) ->
      Some "blorp_tensor_matrix_vector_multiply_float16"
  | Ast.TyNamed ("Int", _) -> Some "blorp_tensor_matrix_vector_multiply_int"
  | _ -> None

let transposed_matrix_vector_multiply_runtime_name elem_ty =
  match normalize_type elem_ty with
  | Ast.TyNamed ("Float", _) ->
      Some "blorp_tensor_transposed_matrix_vector_multiply_float"
  | Ast.TyNamed ("Float32", _) ->
      Some "blorp_tensor_transposed_matrix_vector_multiply_float32"
  | Ast.TyNamed ("Float16", _) ->
      Some "blorp_tensor_transposed_matrix_vector_multiply_float16"
  | Ast.TyNamed ("Int", _) ->
      Some "blorp_tensor_transposed_matrix_vector_multiply_int"
  | _ -> None

let outer_multiply_runtime_name elem_ty =
  match normalize_type elem_ty with
  | Ast.TyNamed ("Float", _) -> Some "blorp_tensor_outer_float"
  | Ast.TyNamed ("Float32", _) -> Some "blorp_tensor_outer_float32"
  | Ast.TyNamed ("Float16", _) -> Some "blorp_tensor_outer_float16"
  | Ast.TyNamed ("Int", _) -> Some "blorp_tensor_outer_int"
  | _ -> None

type matrix_multiply_tensor_operands = {
  mt_elem_ty : Ast.type_expr;
  mt_static_dims : (int * int * int) option;
}

let matrix_multiply_tensor_operands ~reg ~loc left right =
  match (tensor_type ~reg left.ty, tensor_type ~reg right.ty) with
  | Some left_ty, Some right_ty ->
      let static_dims =
        match (left_ty.dims, right_ty.dims) with
        | Ast.TyConstInt m :: Ast.TyConstInt k :: _, _ :: Ast.TyConstInt n :: _
          ->
            Some (m, k, n)
        | _ -> None
      in
      {
        mt_elem_ty = normalize_type left_ty.elem_ty;
        mt_static_dims = static_dims;
      }
  | _ ->
      Core_error.errorf (Core_error.Stage Core_stage.Specialize) loc
        ~hint:
          "multiply specialization requires both operands to carry tensor \
           shape metadata. If typechecking accepted this, fix dispatch before \
           specialization."
        "multiply requires tensor operands, got %s and %s"
        (Types.type_to_string left.ty)
        (Types.type_to_string right.ty)

let runtime_matrix_dims loc matrix =
  let dummy = void_dummy loc in
  let rows =
    {
      matrix with
      desc = CCall (CKIntrinsic "tensor_len", dummy, [ matrix ]);
      ty = int_ty;
    }
  in
  let capacity =
    {
      matrix with
      desc = CCall (CKIntrinsic "tensor_capacity", dummy, [ matrix ]);
      ty = int_ty;
    }
  in
  let cols =
    { matrix with desc = CBin (Ast.Div, capacity, rows); ty = int_ty }
  in
  (rows, cols)

let specialize_matrix_vector_call e c_name matrix vector rows cols =
  let dummy = void_dummy e.loc in
  {
    e with
    desc = CCall (CKBuiltin c_name, dummy, [ matrix; vector; rows; cols ]);
  }

let specialize_matrix_vector_multiply ~reg e matrix vector =
  let elem_ty =
    tensor_elem_type ~reg ~loc:e.loc
      ~context:"multiply_vector requires a tensor matrix argument" matrix.ty
  in
  match matrix_vector_multiply_runtime_name elem_ty with
  | Some c_name -> (
      match matrix_static_dims ~reg matrix.ty with
      | Some (rows, cols) ->
          specialize_matrix_vector_call e c_name matrix vector
            (int_lit e.loc rows) (int_lit e.loc cols)
      | None ->
          let rows, cols = runtime_matrix_dims e.loc matrix in
          specialize_matrix_vector_call e c_name matrix vector rows cols)
  | None ->
      Core_error.errorf
        ~hint:
          "Supported multiply_vector element types are Int, Float, Float32, \
           and Float16."
        (Core_error.Stage Core_stage.Specialize) e.loc
        "multiply_vector is not implemented for element type `%s`"
        (Types.type_to_string elem_ty)

let specialize_transposed_matrix_vector_multiply ~reg e matrix vector =
  let elem_ty =
    tensor_elem_type ~reg ~loc:e.loc
      ~context:"multiply_transposed_vector requires a tensor matrix argument"
      matrix.ty
  in
  match transposed_matrix_vector_multiply_runtime_name elem_ty with
  | Some c_name -> (
      match matrix_static_dims ~reg matrix.ty with
      | Some (rows, cols) ->
          specialize_matrix_vector_call e c_name matrix vector
            (int_lit e.loc rows) (int_lit e.loc cols)
      | None ->
          let rows, cols = runtime_matrix_dims e.loc matrix in
          specialize_matrix_vector_call e c_name matrix vector rows cols)
  | None ->
      Core_error.errorf
        ~hint:
          "Supported multiply_transposed_vector element types are Int, Float, \
           Float32, and Float16."
        (Core_error.Stage Core_stage.Specialize) e.loc
        "multiply_transposed_vector is not implemented for element type `%s`"
        (Types.type_to_string elem_ty)

let specialize_outer_multiply ~reg e a b =
  let elem_ty =
    tensor_elem_type ~reg ~loc:e.loc
      ~context:"outer requires a tensor left operand" a.ty
  in
  match outer_multiply_runtime_name elem_ty with
  | Some c_name ->
      let m =
        match vector_static_dim ~reg a.ty with
        | Some n -> int_lit e.loc n
        | None ->
            {
              a with
              desc = CCall (CKIntrinsic "tensor_len", void_dummy e.loc, [ a ]);
              ty = int_ty;
            }
      in
      let n =
        match vector_static_dim ~reg b.ty with
        | Some n -> int_lit e.loc n
        | None ->
            {
              b with
              desc = CCall (CKIntrinsic "tensor_len", void_dummy e.loc, [ b ]);
              ty = int_ty;
            }
      in
      let dummy = void_dummy e.loc in
      { e with desc = CCall (CKBuiltin c_name, dummy, [ a; b; m; n ]) }
  | None ->
      Core_error.errorf
        ~hint:
          "Supported outer element types are Int, Float, Float32, and Float16."
        (Core_error.Stage Core_stage.Specialize) e.loc
        "outer is not implemented for element type `%s`"
        (Types.type_to_string elem_ty)

(** Walk a single expression and specialize type-dispatched builtins. *)
let cbox_effective_source_ty inner source_ty =
  if Codegen_types.has_type_vars source_ty then inner.ty else source_ty

let should_rewrite_cbox_to_borrow_cast ~reg inner source_ty =
  let source_ty = cbox_effective_source_ty inner source_ty in
  (not (Codegen_types.has_type_vars source_ty))
  && is_pointer_type ~reg source_ty

let set_constructor_name_for_elem ~reg elem =
  Core_hash_container_layout.set_constructor_builtin_name ~reg elem

let dict_constructor_name_for_key ~reg key =
  Core_hash_container_layout.dict_constructor_builtin_name ~reg key

let dict_capacity_constructor_name_for_key ~reg key =
  Core_hash_container_layout.dict_capacity_constructor_builtin_name ~reg key

let refine_immediate_set_constructor ~reg elem set_expr =
  match set_expr.desc with
  | CCall
      ( CKBuiltin
          ( "blorp_set_new" | "blorp_set_new_string" | "blorp_set_new_float"
          | "blorp_set_new_custom" ),
        callee,
        [] ) ->
      {
        set_expr with
        ty = Ast.TyNamed ("Set", [ elem.ty ]);
        desc =
          CCall
            (CKBuiltin (set_constructor_name_for_elem ~reg elem.ty), callee, []);
      }
  | _ -> set_expr

let refine_immediate_dict_constructor ~reg key value dict_expr =
  match dict_expr.desc with
  | CCall
      ( CKBuiltin
          ( "blorp_dict_new" | "blorp_dict_new_string" | "blorp_dict_new_float"
          | "blorp_dict_new_custom" ),
        callee,
        [] ) ->
      {
        dict_expr with
        ty = Ast.TyNamed ("Dict", [ key.ty; value.ty ]);
        desc =
          CCall
            (CKBuiltin (dict_constructor_name_for_key ~reg key.ty), callee, []);
      }
  | CCall
      ( CKBuiltin
          ( "blorp_dict_with_capacity" | "blorp_dict_with_capacity_string"
          | "blorp_dict_with_capacity_float" | "blorp_dict_with_capacity_custom"
            ),
        callee,
        [ cap ] ) ->
      {
        dict_expr with
        ty = Ast.TyNamed ("Dict", [ key.ty; value.ty ]);
        desc =
          CCall
            ( CKBuiltin (dict_capacity_constructor_name_for_key ~reg key.ty),
              callee,
              [ cap ] );
      }
  | _ -> dict_expr

let rec specialize_expr ?(env = empty_specialize_env) ~reg (e : core) : core =
  let is_tensor_type ty = is_tensor_type ~reg ty in
  let tensor_parts ty = tensor_parts ~reg ty in
  let tensor_elem_type ~loc ~context ty =
    tensor_elem_type ~reg ~loc ~context ty
  in
  let tensor_has_elem name ty = tensor_has_elem ~reg name ty in
  let bounds_proven_tensor_read env e tensor idx =
    bounds_proven_tensor_read ~reg env e tensor idx
  in
  let e =
    match e.desc with
    | CFor (binder, iter, body) ->
        let iter' = specialize_expr ~env ~reg iter in
        let body_env = body_env_for_loop env binder iter' in
        let body' = specialize_expr ~env:body_env ~reg body in
        maybe_add_raw_tensor_view_loop ~reg body_env
          { e with desc = CFor (binder, iter', body') }
    | _ -> map_children (specialize_expr ~env ~reg) e
  in
  match e.desc with
  | CBox (inner, source_ty)
    when should_rewrite_cbox_to_borrow_cast ~reg inner source_ty ->
      (* Generic IR sometimes has to box an unknown [T] for a raw void*
         operation. After monomorphization, pointer-backed instantiations
         should be a non-owning view, not an owning retain. *)
      {
        e with
        desc = CCast (inner, Ast.TyNamed ("Ptr", []));
        ty = Ast.TyNamed ("Ptr", []);
      }
  | CMatch (scrut, tree) -> (
      match rewrite_tensor_get_or_match ~reg e scrut tree with
      | Some rewritten -> rewritten
      | None -> e)
  | CCall (CKIntrinsic "list_alloc", _, [ cap ])
  | CCall (CKBuiltin "blorp_list_new", _, [ cap ]) ->
      specialize_list_alloc ~reg e cap
  | CCall (CKBuiltin "blorp_dict_with_capacity", callee, [ cap ]) ->
      let dict_fn =
        match normalize_type e.ty with
        | Ast.TyNamed ("Dict", key :: _) ->
            dict_capacity_constructor_name_for_key ~reg key
        | _ -> "blorp_dict_with_capacity"
      in
      { e with desc = CCall (CKBuiltin dict_fn, callee, [ cap ]) }
  | CCall
      ( CKBuiltin (("blorp_channel_recv" | "blorp_channel_try_recv") as base),
        callee,
        args ) -> (
      match channel_recv_builtin_for_option_layout ~reg base e.ty with
      | Some builtin_name ->
          { e with desc = CCall (CKBuiltin builtin_name, callee, args) }
      | None -> e)
  | CCall (CKBuiltin c, callee, [ arg ]) -> (
      match c with
      | "blorp_getenv" | "blorp_decode_utf8" | "blorp_base64_decode"
      | "blorp_bytes_from_hex"
        when returns_nullable_managed_option ~reg e.ty ->
          { e with desc = CCall (CKBuiltin (c ^ "_nullable"), callee, [ arg ]) }
      | "sqrt" | "exp" | "log" | "abs" | "blorp_vector_norm"
      | "blorp_vector_exp" | "blorp_vector_log" | "blorp_vector_sqrt"
      | "blorp_vector_abs"
        when is_tensor_type arg.ty -> (
          let elem_ty =
            tensor_elem_type ~loc:e.loc
              ~context:
                "vector elementwise specialization requires a tensor argument"
              arg.ty
          in
          match tensor_elementwise_builtin_name c elem_ty with
          | Some builtin_name ->
              { e with desc = CCall (CKBuiltin builtin_name, callee, [ arg ]) }
          | None -> e)
      | "blorp_vector_norm" ->
          let elem_ty =
            tensor_elem_type ~loc:e.loc
              ~context:"vector_norm requires a tensor argument" arg.ty
          in
          let norm_name =
            match elem_ty with
            | Ast.TyNamed ("Float32", _) -> "blorp_vector_norm_float32"
            | Ast.TyNamed ("Float16", _) -> "blorp_vector_norm_float16"
            | _ -> c
          in
          { e with desc = CCall (CKBuiltin norm_name, callee, [ arg ]) }
      | "blorp_to_int" -> specialize_to_int e arg
      | "blorp_to_float" -> specialize_to_float e arg
      | "blorp_to_float32" -> specialize_to_float32 e arg
      | "blorp_to_float16" -> specialize_to_float16 e arg
      | "blorp_to_string" -> specialize_to_string ~reg e callee arg
      | "blorp_debug_string" -> specialize_debug_string ~reg e callee arg
      | "blorp_hash" -> specialize_hash e callee arg
      | "blorp_stream_repeat" ->
          let elem_layout =
            stream_result_borrowed_layout ~reg ~loc:e.loc
              ~context:"stream repeat result" e.ty
          in
          let elem_layout_code = stream_element_layout_code elem_layout in
          let arg = stream_runtime_value_arg ~reg ~layout:elem_layout arg in
          {
            e with
            desc =
              CCall
                ( CKBuiltin "blorp_stream_repeat",
                  callee,
                  [ arg; int_lit e.loc elem_layout_code ] );
          }
      | "blorp_length" -> (
          let dummy =
            { arg with desc = CVoid; ty = Ast.TyNamed ("Void", []) }
          in
          let intrinsic_name =
            match normalize_type arg.ty with
            | Ast.TyNamed ("List", _) -> Some "list_len"
            | Ast.TyNamed ("String", _) -> Some "string_len"
            | Ast.TyNamed ("Dict", _) -> Some "dict_len"
            | Ast.TyNamed ("Set", _) -> Some "set_len"
            | Ast.TyNamed ("Bytes", _) -> Some "bytes_len"
            | Ast.TyNamed ("StringSlice", _) -> Some "slice_len"
            | ty when is_tensor_type ty -> Some "tensor_len"
            | _ -> None
          in
          (* Check for compile-time known dim → constant fold *)
          let const_len =
            match tensor_parts arg.ty with
            | Some (_, Ast.TyConstInt n :: _) -> Some n
            | _ -> None
          in
          match const_len with
          | Some n ->
              (* Constant-fold: length(v) → n when dim is compile-time known *)
              { e with desc = CLit (Ast.LitInt (Int64.of_int n)) }
          | None -> (
              match intrinsic_name with
              | Some name ->
                  { e with desc = CCall (CKIntrinsic name, dummy, [ arg ]) }
              | None -> e))
      | "blorp_vector_len" ->
          let dummy =
            { arg with desc = CVoid; ty = Ast.TyNamed ("Void", []) }
          in
          { e with desc = CCall (CKIntrinsic "tensor_len", dummy, [ arg ]) }
      | "blorp_to_bool" -> (
          match normalize_type arg.ty with
          | Ast.TyNamed ("Bool", _) -> arg
          | Ast.TyNamed ("Int", _) ->
              let zero =
                {
                  arg with
                  desc = CLit (Ast.LitInt 0L);
                  ty = Ast.TyNamed ("Int", []);
                }
              in
              { e with desc = CBin (Ast.Ne, arg, zero) }
          | Ast.TyNamed ("Option", _) ->
              (* to_bool(option) → option->tag == TAG_Some *)
              let tag =
                {
                  arg with
                  desc = CField (arg, "tag");
                  ty = Ast.TyNamed ("Int", []);
                }
              in
              let some_tag =
                {
                  arg with
                  desc = CVar (Var.named "TAG_Some");
                  ty = Ast.TyNamed ("Int", []);
                }
              in
              {
                e with
                desc = CBin (Ast.Eq, tag, some_tag);
                ty = Ast.TyNamed ("Bool", []);
              }
          | Ast.TyNamed ("Result", _) ->
              (* to_bool(result) → result->tag == TAG_Ok *)
              let tag =
                {
                  arg with
                  desc = CField (arg, "tag");
                  ty = Ast.TyNamed ("Int", []);
                }
              in
              let ok_tag =
                {
                  arg with
                  desc = CVar (Var.named "TAG_Ok");
                  ty = Ast.TyNamed ("Int", []);
                }
              in
              {
                e with
                desc = CBin (Ast.Eq, tag, ok_tag);
                ty = Ast.TyNamed ("Bool", []);
              }
          | _ -> cast e arg (Ast.TyNamed ("Bool", [])))
      | "blorp_to_char" -> (
          match normalize_type arg.ty with
          | Ast.TyNamed ("Char", _) -> arg
          | _ -> cast e arg (Ast.TyNamed ("Char", [])))
      | "blorp_tensor_transpose" ->
          (* transpose(m) where m: T[#M, #N] — inject dim args.
              blorp_tensor_transpose(mat, rows, cols) at runtime. *)
          let mk_int n =
            {
              desc = CLit (Ast.LitInt (Int64.of_int n));
              ty = Ast.TyNamed ("Int", []);
              loc = e.loc;
            }
          in
          let dummy =
            { arg with desc = CVoid; ty = Ast.TyNamed ("Void", []) }
          in
          let rows, cols =
            match normalize_type arg.ty with
            | ty -> (
                match tensor_parts ty with
                | Some (_, Ast.TyConstInt r :: Ast.TyConstInt c :: _) -> (r, c)
                | _ -> (0, 0))
          in
          if rows > 0 && cols > 0 then
            {
              e with
              desc =
                CCall
                  ( CKBuiltin "blorp_tensor_transpose",
                    dummy,
                    [ arg; mk_int rows; mk_int cols ] );
            }
          else
            (* Runtime fallback: rows = .len, cols = .capacity / .len *)
            let rows_e =
              {
                arg with
                desc = CCall (CKIntrinsic "tensor_len", dummy, [ arg ]);
                ty = Ast.TyNamed ("Int", []);
              }
            in
            let cap_e =
              {
                arg with
                desc = CCall (CKIntrinsic "tensor_capacity", dummy, [ arg ]);
                ty = Ast.TyNamed ("Int", []);
              }
            in
            let cols_e =
              {
                arg with
                desc = CBin (Ast.Div, cap_e, rows_e);
                ty = Ast.TyNamed ("Int", []);
              }
            in
            {
              e with
              desc =
                CCall
                  ( CKBuiltin "blorp_tensor_transpose",
                    dummy,
                    [ arg; rows_e; cols_e ] );
            }
      | "blorp_max" | "blorp_min" ->
          (* Tensor reduction: max(tensor) / min(tensor) → vector_max/min *)
          let is_tensor_arg = is_tensor_type arg.ty in
          if is_tensor_arg then
            let elem_ty =
              tensor_elem_type ~loc:e.loc
                ~context:"max/min tensor reduction requires a tensor argument"
                arg.ty
            in
            let suffix =
              match elem_ty with
              | Ast.TyNamed ("Float", _) -> "_float"
              | Ast.TyNamed ("Float32", _) -> "_float32"
              | Ast.TyNamed ("Float16", _) -> "_float16"
              | _ -> "_int"
            in
            let bare = String.sub c 6 (String.length c - 6) in
            let dummy =
              { desc = CVoid; ty = Ast.TyNamed ("Void", []); loc = e.loc }
            in
            {
              e with
              desc =
                CCall
                  (CKBuiltin ("blorp_vector_" ^ bare ^ suffix), dummy, [ arg ]);
            }
          else e
      | _ -> e)
  | CCall ((CKUser _ | CKForeign _), callee, [ arg ]) when is_tensor_type arg.ty
    -> (
      let func_name =
        match callee.desc with CVar v -> Some v.vname | _ -> None
      in
      match func_name with
      | Some name -> (
          let elem_ty =
            tensor_elem_type ~loc:e.loc
              ~context:"tensor UFCS specialization requires a tensor receiver"
              arg.ty
          in
          match tensor_elementwise_builtin_name name elem_ty with
          | Some builtin_name ->
              { e with desc = CCall (CKBuiltin builtin_name, callee, [ arg ]) }
          | None -> e)
      | None -> e)
  | CCall (CKBuiltin "blorp_set_add", callee, [ set_expr; elem ]) ->
      let set_expr = refine_immediate_set_constructor ~reg elem set_expr in
      let args, _ =
        box_void_args_for_builtin ~reg "blorp_set_add" [ set_expr; elem ]
      in
      { e with desc = CCall (CKBuiltin "blorp_set_add", callee, args) }
  | CCall (CKBuiltin "blorp_dict_insert", callee, [ dict_expr; key; value ]) ->
      let dict_expr =
        refine_immediate_dict_constructor ~reg key value dict_expr
      in
      let args, _ =
        box_void_args_for_builtin ~reg "blorp_dict_insert"
          [ dict_expr; key; value ]
      in
      { e with desc = CCall (CKBuiltin "blorp_dict_insert", callee, args) }
  | CCall (CKBuiltin "blorp_dict_get", callee, args) -> (
      match dict_get_builtin_for_option_layout ~reg e.ty with
      | Some builtin_name ->
          let args, _ = box_void_args_for_builtin ~reg builtin_name args in
          { e with desc = CCall (CKBuiltin builtin_name, callee, args) }
      | None -> e)
  | CCall (CKBuiltin ("blorp_channel_recv_timeout" as base), callee, args) -> (
      match channel_recv_builtin_for_option_layout ~reg base e.ty with
      | Some builtin_name ->
          { e with desc = CCall (CKBuiltin builtin_name, callee, args) }
      | None -> e)
  | CCall (CKBuiltin ("blorp_stream_find" as base), callee, args) -> (
      match channel_recv_builtin_for_option_layout ~reg base e.ty with
      | Some builtin_name ->
          { e with desc = CCall (CKBuiltin builtin_name, callee, args) }
      | None -> e)
  | CCall (CKBuiltin "blorp_stream_unfold", callee, [ seed; func ]) ->
      let elem_layout =
        stream_result_owned_layout ~reg ~loc:e.loc
          ~context:"stream unfold result" e.ty
      in
      let state_layout = stream_state_layout ~reg ~loc:e.loc seed.ty in
      let seed = stream_runtime_value_arg ~reg ~layout:state_layout seed in
      {
        e with
        desc =
          CCall
            ( CKBuiltin "blorp_stream_unfold",
              callee,
              [
                seed;
                func;
                int_lit e.loc (stream_element_layout_code elem_layout);
                int_lit e.loc (stream_element_layout_code state_layout);
              ] );
      }
  | CCall (CKBuiltin "blorp_stream_map", callee, args) when List.length args = 2
    ->
      let elem_layout =
        stream_result_owned_layout ~reg ~loc:e.loc ~context:"stream map result"
          e.ty
      in
      let elem_layout_code = stream_element_layout_code elem_layout in
      {
        e with
        desc =
          CCall
            ( CKBuiltin "blorp_stream_map",
              callee,
              args @ [ int_lit e.loc elem_layout_code ] );
      }
  | CCall (CKBuiltin ("blorp_stream_filter_map" as base), callee, args) -> (
      match stream_filter_map_builtin_for_option_layout ~reg base e.ty with
      | Some builtin_name ->
          { e with desc = CCall (CKBuiltin builtin_name, callee, args) }
      | None -> e)
  (* Set[T] constructor: dispatch to type-specific new based on element type.
     blorp_set_new() defaults to int hash/eq; String and Float need their
     own hash/eq functions for value-based comparison. User types with
     source-level Hashable + Equatable impls route to _custom, which
     core_emit resolves to [Hashable_hash_<T>] / [Equatable_equals_<T>]
     function pointers. *)
  | CCall (CKBuiltin "blorp_set_new", callee, []) ->
      let set_fn =
        match normalize_type e.ty with
        | Ast.TyNamed ("Set", [ elem ]) ->
            set_constructor_name_for_elem ~reg elem
        | _ -> "blorp_set_new"
      in
      { e with desc = CCall (CKBuiltin set_fn, callee, []) }
  (* Dict[K, V] constructor: dispatch to type-specific new based on key type.
     blorp_dict_new() defaults to int hash/eq; String and Float keys need
     their own hash/eq functions for value-based comparison. User types
     with source-level Hashable + Equatable impls route to _custom. *)
  | CCall (CKBuiltin "blorp_dict_new", callee, []) ->
      let dict_fn =
        match normalize_type e.ty with
        | Ast.TyNamed ("Dict", key :: _) ->
            dict_constructor_name_for_key ~reg key
        | _ -> "blorp_dict_new"
      in
      { e with desc = CCall (CKBuiltin dict_fn, callee, []) }
  (* [equals(a, b)] — trait-method sentinel dispatched by arg type. The
     sentinel [blorp_eq_dispatch] is registered in [Codegen_builtins]
     purely so [Core_resolve] tags these calls as [CKBuiltin] instead of
     [CKClosure]; the real dispatch happens here. *)
  | CCall (CKBuiltin "blorp_eq_dispatch", _, [ l; r ]) -> (
      let dummy =
        { desc = CVoid; ty = Ast.TyNamed ("Void", []); loc = e.loc }
      in
      let is_string_ty ty =
        match normalize_type ty with
        | Ast.TyNamed ("String", _) | Ast.TyNamed ("LiteralString", _) -> true
        | _ -> false
      in
      let list_elem ty =
        match normalize_type ty with
        | Ast.TyNamed ("List", [ elem ]) -> Some (normalize_type elem)
        | _ -> None
      in
      if is_string_ty l.ty || is_string_ty r.ty then
        {
          e with
          desc = CCall (CKBuiltin "blorp_string_eq", dummy, [ l; r ]);
          ty = Ast.TyNamed ("Bool", []);
        }
      else
        match (list_elem l.ty, list_elem r.ty) with
        | Some elem, _ | _, Some elem ->
            let fn =
              match elem with
              | Ast.TyNamed ("String", _) -> "blorp_list_eq_string"
              | Ast.TyNamed ("Float", _) -> "blorp_list_eq_float"
              | _ -> "blorp_list_eq"
            in
            {
              e with
              desc = CCall (CKBuiltin fn, dummy, [ l; r ]);
              ty = Ast.TyNamed ("Bool", []);
            }
        | None, None -> (
            (* Option equality *)
            let option_elem ty =
              match normalize_type ty with
              | Ast.TyNamed ("Option", [ elem ]) -> Some (normalize_type elem)
              | _ -> None
            in
            match (option_elem l.ty, option_elem r.ty) with
            | Some elem, _ | _, Some elem ->
                let option_ty = Ast.TyNamed ("Option", [ elem ]) in
                let fn =
                  option_equality_builtin_for_type ~reg ~loc:e.loc option_ty
                in
                {
                  e with
                  desc = CCall (CKBuiltin fn, dummy, [ l; r ]);
                  ty = Ast.TyNamed ("Bool", []);
                }
            | None, None ->
                {
                  e with
                  desc = CBin (Ast.Eq, l, r);
                  ty = Ast.TyNamed ("Bool", []);
                }))
  (* Option == / != via plain CBin (not through eq_dispatch) *)
  | CBin (op, l, r)
    when (op = Ast.Eq || op = Ast.Ne)
         &&
         match normalize_type l.ty with
         | Ast.TyNamed ("Option", _) -> true
         | _ -> false ->
      let dummy =
        { desc = CVoid; ty = Ast.TyNamed ("Void", []); loc = e.loc }
      in
      let elem =
        match normalize_type l.ty with
        | Ast.TyNamed ("Option", [ el ]) -> normalize_type el
        | _ -> Ast.TyNamed ("Int", [])
      in
      let option_ty = Ast.TyNamed ("Option", [ elem ]) in
      let fn = option_equality_builtin_for_type ~reg ~loc:e.loc option_ty in
      let eq_call =
        {
          e with
          desc = CCall (CKBuiltin fn, dummy, [ l; r ]);
          ty = Ast.TyNamed ("Bool", []);
        }
      in
      if op = Ast.Ne then
        { e with desc = CUn (Ast.Not, eq_call); ty = Ast.TyNamed ("Bool", []) }
      else eq_call
  (* Unary negation on a tensor: -v → scalar_op_rev(Sub, v, 0), giving 0 - v
     element-wise. Uses the reverse variant so we don't allocate a temporary
     scalar-filled vector. *)
  | CUn (Ast.Neg, v) when is_tensor_type v.ty ->
      let dummy =
        { desc = CVoid; ty = Ast.TyNamed ("Void", []); loc = e.loc }
      in
      let elem_ty =
        tensor_elem_type ~loc:e.loc
          ~context:"tensor negation requires a tensor operand" v.ty
      in
      let sub_op =
        {
          desc = CLit (Ast.LitInt 1L);
          ty = Ast.TyNamed ("Int", []);
          loc = e.loc;
        }
      in
      let c_name, zero =
        match elem_ty with
        | Ast.TyNamed ("Float", _) ->
            ( "blorp_vector_scalar_op_rev_float",
              {
                desc = CLit (Ast.LitFloat 0.0);
                ty = Ast.TyNamed ("Float", []);
                loc = e.loc;
              } )
        | Ast.TyNamed ("Float32", _) ->
            ( "blorp_vector_scalar_op_rev_float32",
              {
                desc = CLit (Ast.LitFloat 0.0);
                ty = Ast.TyNamed ("Float32", []);
                loc = e.loc;
              } )
        | Ast.TyNamed ("Float16", _) ->
            ( "blorp_vector_scalar_op_rev_float16",
              {
                desc = CLit (Ast.LitFloat 0.0);
                ty = Ast.TyNamed ("Float16", []);
                loc = e.loc;
              } )
        | _ ->
            ( "blorp_vector_scalar_op_rev_int",
              {
                desc = CLit (Ast.LitInt 0L);
                ty = Ast.TyNamed ("Int", []);
                loc = e.loc;
              } )
      in
      { e with desc = CCall (CKBuiltin c_name, dummy, [ sub_op; v; zero ]) }
  | CBin (op, l, r) when is_tensor_type l.ty && (op = Ast.Eq || op = Ast.Ne) ->
      let dummy =
        { desc = CVoid; ty = Ast.TyNamed ("Void", []); loc = e.loc }
      in
      let elem_ty =
        tensor_elem_type ~loc:e.loc
          ~context:"tensor equality requires a tensor left operand" l.ty
      in
      let mk_int n =
        {
          desc = CLit (Ast.LitInt (Int64.of_int n));
          ty = Ast.TyNamed ("Int", []);
          loc = e.loc;
        }
      in
      let elem_code =
        match elem_ty with
        | Ast.TyNamed ("Float", _) -> 1
        | Ast.TyNamed ("Float32", _) -> 2
        | Ast.TyNamed ("Float16", _) -> 3
        | _ -> 0
      in
      let eq_call =
        {
          e with
          desc =
            CCall
              (CKBuiltin "blorp_vector_eq", dummy, [ mk_int elem_code; l; r ]);
          ty = Ast.TyNamed ("Bool", []);
        }
      in
      if op = Ast.Ne then
        { e with desc = CUn (Ast.Not, eq_call); ty = Ast.TyNamed ("Bool", []) }
      else eq_call
  | CBin (op, l, r)
    when let l_is_t = is_tensor_type l.ty in
         let r_is_t = is_tensor_type r.ty in
         l_is_t || r_is_t -> (
      match tensor_arithmetic_op_of_ast op with
      | None -> e
      | Some arith_op -> (
          let dummy =
            { desc = CVoid; ty = Ast.TyNamed ("Void", []); loc = e.loc }
          in
          let op_code = tensor_arithmetic_op_code arith_op in
          let l_is_t = is_tensor_type l.ty in
          let r_is_t = is_tensor_type r.ty in
          (* Tensor-element type comes from whichever operand is a tensor. *)
          let elem_ty =
            let pick t =
              match tensor_parts t.ty with
              | Some (elem, _) -> Some elem
              | _ -> None
            in
            match (pick l, pick r) with
            | Some t, _ | _, Some t -> t
            | None, None -> Ast.TyNamed ("Float", [])
          in
          let mk_int n =
            {
              desc = CLit (Ast.LitInt (Int64.of_int n));
              ty = Ast.TyNamed ("Int", []);
              loc = e.loc;
            }
          in
          let elem = tensor_arithmetic_elem_of_type elem_ty in
          let elem_code = tensor_arithmetic_elem_code elem in
          match (l_is_t, r_is_t) with
          | true, true ->
              (* tensor OP tensor: use the SIMD dispatcher for packed floating
             elements, otherwise fall back to the generic scalar helper. *)
              let fn, args =
                match direct_vector_binary_builtin elem arith_op with
                | Some fn -> (fn, [ l; r ])
                | None -> (
                    match simd_dispatch_elem_code elem with
                    | Some code ->
                        ( "blorp_simd_vector_op",
                          [ mk_int op_code; mk_int code; l; r ] )
                    | None ->
                        ( "blorp_vector_op",
                          [ mk_int op_code; mk_int elem_code; l; r ] ))
              in
              { e with desc = CCall (CKBuiltin fn, dummy, args) }
          | true, false ->
              (* tensor OP scalar — scalar on the right is the natural
              SIMD shape. Args are (op_code, vector, scalar). *)
              let fn, args =
                match
                  direct_vector_scalar_builtin ~reversed:false elem arith_op
                with
                | Some fn -> (fn, [ l; r ])
                | None ->
                    ( scalar_dispatch_builtin ~reversed:false elem,
                      [ mk_int op_code; l; r ] )
              in
              { e with desc = CCall (CKBuiltin fn, dummy, args) }
          | false, true ->
              (* scalar OP tensor — flip the operands. Commutative ops
              (Add, Mul) reuse the scalar-on-right path; non-commutative
              ops (Sub, Div, Mod) dispatch to [_rev] which computes
              [scalar OP v[i]] preserving operand order. All four
              element types (Int, Float, Float32, Float16) have rev
              runtime helpers. *)
              let fn, args =
                match
                  direct_vector_scalar_builtin ~reversed:true elem arith_op
                with
                | Some fn -> (fn, [ r; l ])
                | None ->
                    ( scalar_dispatch_builtin ~reversed:true elem,
                      [ mk_int op_code; r; l ] )
              in
              { e with desc = CCall (CKBuiltin fn, dummy, args) }
          | false, false ->
              (* The outer [when] guard requires at least one operand to
              be a tensor; this branch is unreachable. *)
              e))
  | CCall (CKBuiltin c, callee, args)
    when c = "blorp_checked_get"
         || c = "blorp_matrix_checked_get"
         || c = "blorp_tensor3_checked_get"
         || c = "blorp_tensor4_checked_get"
         || c = "blorp_tensor5_checked_get" -> (
      let result_ty = e.ty in
      let is_pointer = is_pointer_type ~reg result_ty in
      let void_ty = Ast.TyNamed ("Void", []) in
      let typed_unchecked_intrinsic =
        Core_layout_type.tensor_checked_get_access_of_type ~reg result_ty
        |> Option.map (fun access -> access.Core_layout_type.tcga_get_intrinsic)
      in
      (* Try to eliminate bounds checks for 1D primitive checked_get calls.
         Managed element reads keep the runtime path because checked_get returns
         an alias borrowed from the vector; Perceus must make any needed
         ownership copy explicit. *)
      let try_unchecked () =
        if c <> "blorp_checked_get" || is_pointer then None
        else
          match args with
          | [ arr; idx ] -> (
              let dim =
                match tensor_parts arr.ty with
                | Some (_, Ast.TyConstInt n :: _) -> Some n
                | _ -> None
              in
              let idx_val =
                match idx.desc with
                | CLit (Ast.LitInt n) -> Some (Int64.to_int n)
                | _ -> None
              in
              match (dim, idx_val) with
              | Some n, Some i when i >= 0 && i < n -> (
                  let dummy = { arr with desc = CVoid; ty = void_ty } in
                  match typed_unchecked_intrinsic with
                  | Some intr_name ->
                      Some
                        {
                          e with
                          desc =
                            CCall (CKIntrinsic intr_name, dummy, [ arr; idx ]);
                        }
                  | None ->
                      let raw =
                        {
                          e with
                          desc =
                            CCall
                              ( CKIntrinsic "tensor_get_unchecked",
                                dummy,
                                [ arr; idx ] );
                          ty = void_ty;
                        }
                      in
                      if is_pointer then
                        Some { e with desc = CCast (raw, result_ty) }
                      else Some { e with desc = CUnbox (raw, result_ty) })
              | _ -> None)
          | _ -> None
      in
      let try_bounds_proven_loop_read () =
        if c <> "blorp_checked_get" || is_pointer then None
        else
          match args with
          | [ arr; idx ] -> bounds_proven_tensor_read env e arr idx
          | _ -> None
      in
      match try_unchecked () with
      | Some optimized -> optimized
      | None -> (
          match try_bounds_proven_loop_read () with
          | Some optimized -> optimized
          | None -> (
              match (normalize_type result_ty, c) with
              | Ast.TyNamed ("Float", _), "blorp_checked_get" ->
                  {
                    e with
                    desc =
                      CCall (CKBuiltin "blorp_checked_get_f64", callee, args);
                  }
              | Ast.TyNamed ("Float", _), "blorp_matrix_checked_get" ->
                  {
                    e with
                    desc =
                      CCall
                        (CKBuiltin "blorp_matrix_checked_get_f64", callee, args);
                  }
              | Ast.TyNamed ("Float32", _), "blorp_checked_get" ->
                  {
                    e with
                    desc =
                      CCall (CKBuiltin "blorp_checked_get_f32", callee, args);
                  }
              | Ast.TyNamed ("Float32", _), "blorp_matrix_checked_get" ->
                  {
                    e with
                    desc =
                      CCall
                        (CKBuiltin "blorp_matrix_checked_get_f32", callee, args);
                  }
              | _ ->
                  let raw_call =
                    {
                      e with
                      desc = CCall (CKBuiltin c, callee, args);
                      ty = void_ty;
                    }
                  in
                  if is_pointer then
                    { e with desc = CCast (raw_call, result_ty) }
                  else { e with desc = CUnbox (raw_call, result_ty) })))
  (* multiply: type-dispatch + inject dimension args from types.
     blorp call: multiply(a, b) where a: T[#M,#K], b: T[#K,#N]
     C call: blorp_tensor_matrix_multiply_float(a, b, m, k, n) *)
  | CCall (CKBuiltin "blorp_tensor_matrix_multiply", _callee, [ a; b ]) -> (
      let operands = matrix_multiply_tensor_operands ~reg ~loc:e.loc a b in
      let elem_ty = operands.mt_elem_ty in
      let c_name =
        match elem_ty with
        | Ast.TyNamed ("Float", _) -> "blorp_tensor_matrix_multiply_float"
        | Ast.TyNamed ("Float32", _) -> "blorp_tensor_matrix_multiply_float32"
        | Ast.TyNamed ("Float16", _) -> "blorp_tensor_matrix_multiply_float16"
        | Ast.TyNamed ("Int", _) -> "blorp_tensor_matrix_multiply_int"
        | _ ->
            Core_error.errorf
              ~hint:
                "Supported multiply element types are Int, Float, Float32, and \
                 Float16."
              (Core_error.Stage Core_stage.Specialize) e.loc
              "multiply is not implemented for element type `%s`"
              (Types.type_to_string elem_ty)
      in
      match operands.mt_static_dims with
      | Some (m, k, n) ->
          let dummy = { a with desc = CVoid; ty = Ast.TyNamed ("Void", []) } in
          {
            e with
            desc =
              CCall
                ( CKBuiltin c_name,
                  dummy,
                  [ a; b; int_lit e.loc m; int_lit e.loc k; int_lit e.loc n ] );
          }
      | None ->
          (* Dims not statically known — try reading from runtime .len/.capacity.
           a: T[m, k] -> a.len = m, a.capacity = m*k -> k = capacity/len
           b: T[k, n] -> b.capacity = k*n -> n = capacity/len *)
          let dummy = { a with desc = CVoid; ty = Ast.TyNamed ("Void", []) } in
          let m_expr =
            {
              a with
              desc = CCall (CKIntrinsic "tensor_len", dummy, [ a ]);
              ty = Ast.TyNamed ("Int", []);
            }
          in
          let k_expr =
            {
              a with
              desc =
                CBin
                  ( Ast.Div,
                    {
                      a with
                      desc = CCall (CKIntrinsic "tensor_capacity", dummy, [ a ]);
                      ty = Ast.TyNamed ("Int", []);
                    },
                    m_expr );
              ty = Ast.TyNamed ("Int", []);
            }
          in
          let n_expr =
            {
              a with
              desc =
                CBin
                  ( Ast.Div,
                    {
                      a with
                      desc = CCall (CKIntrinsic "tensor_capacity", dummy, [ b ]);
                      ty = Ast.TyNamed ("Int", []);
                    },
                    k_expr );
              ty = Ast.TyNamed ("Int", []);
            }
          in
          {
            e with
            desc =
              CCall (CKBuiltin c_name, dummy, [ a; b; m_expr; k_expr; n_expr ]);
          })
  | CCall
      ( CKBuiltin "blorp_tensor_matrix_vector_multiply",
        _callee,
        [ matrix; vector ] ) ->
      specialize_matrix_vector_multiply ~reg e matrix vector
  | CCall
      ( CKBuiltin "blorp_tensor_transposed_matrix_vector_multiply",
        _callee,
        [ matrix; vector ] ) ->
      specialize_transposed_matrix_vector_multiply ~reg e matrix vector
  | CCall (CKBuiltin "blorp_tensor_outer", _callee, [ a; b ]) ->
      specialize_outer_multiply ~reg e a b
  | CCall (CKBuiltin ("blorp_filter_map_parallel" as base), callee, [ self; f ])
    -> (
      match
        list_filter_map_parallel_builtin_for_option_layout ~reg base e.ty
      with
      | Some builtin_name ->
          let elem_needs_release =
            if
              list_result_elem_needs_release ~reg ~loc:e.loc
                ~context:"list parallel filter_map result" e.ty
            then 1
            else 0
          in
          {
            e with
            desc =
              CCall
                ( CKBuiltin builtin_name,
                  callee,
                  [ self; f; int_lit e.loc elem_needs_release ] );
          }
      | None ->
          let fallback = Core_intrinsics.list_filter_map self.ty e.ty self f in
          let ctors = Core_match.collect_constructor_names [] in
          Core_match.compile_expr ~ctors fallback)
  (* List parallel maps/zips return a fresh list. Append a runtime flag that
     says whether the erased result slots own ARC-managed storage. This is
     deliberately not pointer classification: value records are unmanaged by
     source-value semantics, but their erased container slots are heap boxes. *)
  | CCall (CKBuiltin c, callee, args)
    when (c = "blorp_map_parallel" && List.length args = 2)
         || (c = "blorp_zip_parallel" && List.length args = 3)
         || (is_list_filter_map_parallel_builtin c && List.length args = 2) ->
      let elem_needs_release =
        if
          list_result_elem_needs_release ~reg ~loc:e.loc
            ~context:"list parallel map/filter_map/zip result" e.ty
        then 1
        else 0
      in
      {
        e with
        desc =
          CCall
            (CKBuiltin c, callee, args @ [ int_lit e.loc elem_needs_release ]);
      }
  | CCall (CKBuiltin c, callee, args)
    when (c = "blorp_map_parallel_with" && List.length args = 3)
         || (c = "blorp_zip_parallel_with" && List.length args = 4) ->
      let elem_needs_release =
        if
          list_result_elem_needs_release ~reg ~loc:e.loc
            ~context:"list parallel map/zip result" e.ty
        then 1
        else 0
      in
      {
        e with
        desc =
          CCall
            (CKBuiltin c, callee, args @ [ int_lit e.loc elem_needs_release ]);
      }
  (* Vector/matrix maps/zips return a fresh tensor. Specialization appends the
     erased-slot ownership flag; emission appends runtime layout metadata for
     the matrix and parallel variants once the concrete result type is known. *)
  | CCall (CKBuiltin c, callee, args)
    when (c = "blorp_vector_map" || c = "blorp_matrix_map"
         || c = "blorp_matrix_map_indexed")
         && List.length args = 2 ->
      let mk_int n =
        {
          desc = CLit (Ast.LitInt (Int64.of_int n));
          ty = Ast.TyNamed ("Int", []);
          loc = e.loc;
        }
      in
      let elem_needs_release =
        if
          tensor_result_elem_needs_release ~reg ~loc:e.loc
            ~context:"tensor map result must be a tensor" e.ty
        then 1
        else 0
      in
      {
        e with
        desc = CCall (CKBuiltin c, callee, args @ [ mk_int elem_needs_release ]);
      }
  | CCall (CKBuiltin c, callee, args)
    when (c = "blorp_vmap_parallel"
         || c = "blorp_vmap_indexed_parallel"
         || c = "blorp_mmap_parallel"
         || c = "blorp_mmap_indexed_parallel"
         || c = "blorp_mmap_flat_indexed_parallel")
         && List.length args = 2 ->
      let mk_int n =
        {
          desc = CLit (Ast.LitInt (Int64.of_int n));
          ty = Ast.TyNamed ("Int", []);
          loc = e.loc;
        }
      in
      let elem_needs_release =
        if
          tensor_result_elem_needs_release ~reg ~loc:e.loc
            ~context:"parallel map result must be a tensor" e.ty
        then 1
        else 0
      in
      {
        e with
        desc = CCall (CKBuiltin c, callee, args @ [ mk_int elem_needs_release ]);
      }
  | CCall (CKBuiltin c, callee, args)
    when (c = "blorp_matrix_zip_map" || c = "blorp_vzip_parallel"
        || c = "blorp_mzip_parallel"
         || c = "blorp_mzip_indexed_parallel")
         && List.length args = 3 ->
      let mk_int n =
        {
          desc = CLit (Ast.LitInt (Int64.of_int n));
          ty = Ast.TyNamed ("Int", []);
          loc = e.loc;
        }
      in
      let elem_needs_release =
        if
          tensor_result_elem_needs_release ~reg ~loc:e.loc
            ~context:"parallel zip result must be a tensor" e.ty
        then 1
        else 0
      in
      {
        e with
        desc = CCall (CKBuiltin c, callee, args @ [ mk_int elem_needs_release ]);
      }
  (* Parallel/stream folds carry the accumulator through erased [void*]
     storage, so the release flag is also erased-storage ownership, not
     source pointer-ness. *)
  | CCall (CKBuiltin c, callee, args)
    when c = "blorp_fold_parallel"
         || c = "blorp_fold_parallel_ordered"
         || c = "blorp_fold_parallel_with"
         || c = "blorp_fold_parallel_ordered_with"
         || c = "blorp_stream_fold" ->
      let mk_int n =
        {
          desc = CLit (Ast.LitInt (Int64.of_int n));
          ty = Ast.TyNamed ("Int", []);
          loc = e.loc;
        }
      in
      let acc_needs_release =
        match args with
        | _ :: init :: _ ->
            if boxed_storage_needs_release ~reg ~loc:e.loc init.ty then 1 else 0
        | _ -> 0
      in
      let args, _ = box_void_args_for_builtin ~reg c args in
      let raw_result_ty = Ast.TyNamed ("Ptr", []) in
      let raw =
        {
          e with
          desc = CCall (CKBuiltin c, callee, args @ [ mk_int acc_needs_release ]);
          ty = raw_result_ty;
        }
      in
      if is_pointer_type ~reg e.ty then { e with desc = CCast (raw, e.ty) }
      else { e with desc = CUnbox (raw, e.ty) }
  | CCall (CKBuiltin ("blorp_fallible_stream_fold_file_raw" as c), callee, args)
    ->
      let mk_int n =
        {
          desc = CLit (Ast.LitInt (Int64.of_int n));
          ty = Ast.TyNamed ("Int", []);
          loc = e.loc;
        }
      in
      let acc_needs_release =
        match args with
        | _ :: init :: _ ->
            if boxed_storage_needs_release ~reg ~loc:e.loc init.ty then 1 else 0
        | _ -> 0
      in
      let args, _ = box_void_args_for_builtin ~reg c args in
      {
        e with
        desc = CCall (CKBuiltin c, callee, args @ [ mk_int acc_needs_release ]);
      }
  | CCall (CKBuiltin ("blorp_fallible_stream_find_file_raw" as c), callee, args)
    ->
      let c =
        fallible_stream_find_builtin_for_result_option_layout ~reg ~loc:e.loc c
          e.ty
      in
      { e with desc = CCall (CKBuiltin c, callee, args) }
  (* tensor_peel: emitted by infer for multi-dim [checked_get] where the
     result is a sub-tensor. Rewrite to blorp_tensor_slice_row with
     row_size / result_first_dim extracted from the collection's
     post-mono concrete type. *)
  | CCall (CKBuiltin "blorp_tensor_peel", callee, [ coll; idx ]) ->
      let open Ast in
      let tensor_peel_error message =
        Core_error.errorf (Core_error.Stage Core_stage.Specialize) e.loc
          ~hint:
            "tensor_peel must run after monomorphization, with a T[#D0, #D1, \
             ...] whose remaining dimensions are compile-time constants."
          "%s" message
      in
      let dim_int = function TyConstInt n -> Some n | _ -> None in
      (* Coll type is T[d0, d1, ...]. Peeling drops d0 — the
         remaining dims determine row_size (product) and result's first
         dim (first of remaining, or row_size when only one remains). *)
      let remaining_dims =
        match tensor_parts coll.ty with
        | Some (_, _d0 :: rest) -> rest
        | _ -> []
      in
      let product_opt dims =
        List.fold_left
          (fun acc d ->
            match (acc, dim_int d) with
            | Some n, Some k -> Some (n * k)
            | _ -> None)
          (Some 1) dims
      in
      let row_size =
        match product_opt remaining_dims with
        | Some n -> n
        | None ->
            tensor_peel_error
              "tensor_peel on tensor with non-constant remaining dims"
      in
      let result_first_dim =
        match remaining_dims with
        | [ _ ] -> row_size
        | d :: _ -> ( match dim_int d with Some n -> n | None -> row_size)
        | [] ->
            tensor_peel_error
              "tensor_peel emitted for 1D tensor; infer should have used \
               checked_get instead"
      in
      let mk_int n =
        {
          desc = CLit (LitInt (Int64.of_int n));
          ty = TyNamed ("Int", []);
          loc = e.loc;
        }
      in
      let new_args = [ coll; idx; mk_int row_size; mk_int result_first_dim ] in
      let void_ty = TyNamed ("Void", []) in
      let raw_call =
        {
          e with
          desc = CCall (CKBuiltin "blorp_tensor_slice_row", callee, new_args);
          ty = void_ty;
        }
      in
      { e with desc = CCast (raw_call, e.ty) }
  | CCall (CKBuiltin "blorp_vector_new_fill", callee, [ value; size ])
    when tensor_has_elem "Int" e.ty ->
      {
        e with
        desc =
          CCall (CKBuiltin "blorp_vector_new_fill_i64", callee, [ value; size ]);
      }
  | CCall (CKBuiltin "blorp_vector_new_fill", callee, [ value; size ])
    when tensor_has_elem "Float" e.ty ->
      {
        e with
        desc =
          CCall (CKBuiltin "blorp_vector_new_fill_f64", callee, [ value; size ]);
      }
  | CCall (CKBuiltin "blorp_vector_new_fill", callee, [ value; size ])
    when tensor_has_elem "Float32" e.ty ->
      {
        e with
        desc =
          CCall (CKBuiltin "blorp_vector_new_fill_f32", callee, [ value; size ]);
      }
  | CCall (CKBuiltin "blorp_vector_new_fill", callee, [ value; size ])
    when Option.is_some (packed_tensor_elem_width_bytes ~reg e.ty) ->
      let width =
        match packed_tensor_elem_width_bytes ~reg e.ty with
        | Some width -> width
        | None -> assert false
      in
      {
        e with
        desc =
          CCall
            ( CKBuiltin "blorp_vector_new_fill_packed",
              callee,
              [ value; size; int_lit e.loc width ] );
      }
  | CCall (CKBuiltin "blorp_matrix_new_fill", callee, [ value; rows; cols ])
    when tensor_has_elem "Int" e.ty ->
      {
        e with
        desc =
          CCall
            ( CKBuiltin "blorp_matrix_new_fill_i64",
              callee,
              [ value; rows; cols ] );
      }
  | CCall (CKBuiltin "blorp_matrix_new_fill", callee, [ value; rows; cols ])
    when tensor_has_elem "Float" e.ty ->
      {
        e with
        desc =
          CCall
            ( CKBuiltin "blorp_matrix_new_fill_f64",
              callee,
              [ value; rows; cols ] );
      }
  | CCall (CKBuiltin "blorp_matrix_new_fill", callee, [ value; rows; cols ])
    when tensor_has_elem "Float32" e.ty ->
      {
        e with
        desc =
          CCall
            ( CKBuiltin "blorp_matrix_new_fill_f32",
              callee,
              [ value; rows; cols ] );
      }
  | CCall (CKBuiltin "blorp_matrix_new_fill", callee, [ value; rows; cols ])
    when Option.is_some (packed_tensor_elem_width_bytes ~reg e.ty) ->
      let width =
        match packed_tensor_elem_width_bytes ~reg e.ty with
        | Some width -> width
        | None -> assert false
      in
      {
        e with
        desc =
          CCall
            ( CKBuiltin "blorp_matrix_new_fill_packed",
              callee,
              [ value; rows; cols; int_lit e.loc width ] );
      }
  | CCall
      ( CKBuiltin
          (( "blorp_getenv" | "blorp_decode_utf8" | "blorp_base64_decode"
           | "blorp_bytes_from_hex" ) as name),
        callee,
        args )
    when returns_nullable_managed_option ~reg e.ty ->
      { e with desc = CCall (CKBuiltin (name ^ "_nullable"), callee, args) }
  | CCall (CKBuiltin "blorp_vector_get_opt", callee, [ arr; idx ]) -> (
      match
        tensor_get_builtin_for_option_layout ~reg ~kind:"vector"
          ~collection_ty:arr.ty ~return_ty:e.ty
      with
      | Some builtin_name ->
          { e with desc = CCall (CKBuiltin builtin_name, callee, [ arr; idx ]) }
      | None -> e)
  | CCall (CKBuiltin "blorp_matrix_get_opt", callee, [ arr; row; col ]) -> (
      match
        tensor_get_builtin_for_option_layout ~reg ~kind:"matrix"
          ~collection_ty:arr.ty ~return_ty:e.ty
      with
      | Some builtin_name ->
          {
            e with
            desc = CCall (CKBuiltin builtin_name, callee, [ arr; row; col ]);
          }
      | None -> e)
  | CCall (CKBuiltin "blorp_assert_shape", callee, args)
    when returns_nullable_managed_option ~reg e.ty ->
      {
        e with
        desc = CCall (CKBuiltin "blorp_assert_shape_nullable", callee, args);
      }
  | CCall (CKBuiltin "blorp_vector_set_cow", callee, [ arr; idx; value ]) -> (
      match
        vector_set_cow_builtin_for_option_layout ~reg ~collection_ty:arr.ty
          ~return_ty:e.ty
      with
      | Some builtin_name ->
          let args, _ =
            box_void_args_for_builtin ~reg builtin_name [ arr; idx; value ]
          in
          { e with desc = CCall (CKBuiltin builtin_name, callee, args) }
      | None -> e)
  | CCall (CKBuiltin "blorp_matrix_set_opt", callee, args)
    when (match args with
           | arr :: _ -> tensor_has_elem "Int" arr.ty
           | _ -> false)
         && returns_nullable_managed_option ~reg e.ty ->
      {
        e with
        desc =
          CCall (CKBuiltin "blorp_matrix_set_opt_nullable_i64", callee, args);
      }
  | CCall (CKBuiltin "blorp_matrix_set_opt", callee, args)
    when match args with arr :: _ -> tensor_has_elem "Int" arr.ty | _ -> false
    ->
      {
        e with
        desc = CCall (CKBuiltin "blorp_matrix_set_opt_i64", callee, args);
      }
  | CCall (CKBuiltin "blorp_matrix_set_opt", callee, args)
    when returns_nullable_managed_option ~reg e.ty ->
      let args, _ =
        box_void_args_for_builtin ~reg "blorp_matrix_set_opt_nullable" args
      in
      {
        e with
        desc = CCall (CKBuiltin "blorp_matrix_set_opt_nullable", callee, args);
      }
  | CCall (CKBuiltin "blorp_checked_set", callee, [ arr; idx; value ])
    when tensor_has_elem "Int" arr.ty ->
      {
        e with
        desc =
          CCall
            ( CKBuiltin "blorp_vector_set_inplace_i64",
              callee,
              [ arr; idx; value ] );
      }
  | CCall (CKBuiltin "blorp_checked_set", callee, [ arr; idx; value ])
    when tensor_has_elem "Float" arr.ty ->
      {
        e with
        desc =
          CCall
            ( CKBuiltin "blorp_vector_set_inplace_f64",
              callee,
              [ arr; idx; value ] );
      }
  | CCall (CKBuiltin "blorp_checked_set", callee, [ arr; idx; value ])
    when tensor_has_elem "Float32" arr.ty ->
      {
        e with
        desc =
          CCall
            ( CKBuiltin "blorp_vector_set_inplace_f32",
              callee,
              [ arr; idx; value ] );
      }
  | CCall
      (CKBuiltin "blorp_matrix_checked_set", callee, [ arr; row; col; value ])
    when tensor_has_elem "Int" arr.ty ->
      {
        e with
        desc =
          CCall
            ( CKBuiltin "blorp_matrix_checked_set_i64",
              callee,
              [ arr; row; col; value ] );
      }
  | CCall
      (CKBuiltin "blorp_matrix_checked_set", callee, [ arr; row; col; value ])
    when tensor_has_elem "Float" arr.ty ->
      {
        e with
        desc =
          CCall
            ( CKBuiltin "blorp_matrix_checked_set_f64",
              callee,
              [ arr; row; col; value ] );
      }
  | CCall
      (CKBuiltin "blorp_matrix_checked_set", callee, [ arr; row; col; value ])
    when tensor_has_elem "Float32" arr.ty ->
      {
        e with
        desc =
          CCall
            ( CKBuiltin "blorp_matrix_checked_set_f32",
              callee,
              [ arr; row; col; value ] );
      }
  | CCall (CKBuiltin c, callee, args)
    when c = "blorp_checked_set"
         || c = "blorp_matrix_checked_set"
         || c = "blorp_tensor3_checked_set"
         || c = "blorp_tensor4_checked_set"
         || c = "blorp_tensor5_checked_set" ->
      let boxed_args =
        List.mapi
          (fun i arg ->
            let is_last = i = List.length args - 1 in
            if is_last && not (is_pointer_type ~reg arg.ty) then
              (* The outer [arg with ty = Void] captures "this expression now
             produces void*" — the new shape after boxing. The [CBox] payload
             references the pre-shadow [arg] (still carrying the concrete
             source type), and [arg.ty] there is the un-shadowed original. *)
              {
                arg with
                desc = CBox (arg, arg.ty);
                ty = Ast.TyNamed ("Void", []);
              }
            else arg)
          args
      in
      { e with desc = CCall (CKBuiltin c, callee, boxed_args) }
  | CCall (CKBuiltin c, callee, args)
    when c = "blorp_vector_new_fill" || c = "blorp_matrix_new_fill" ->
      let boxed_args =
        List.mapi
          (fun i arg ->
            if i = 0 && not (is_pointer_type ~reg arg.ty) then
              {
                arg with
                desc = CBox (arg, arg.ty);
                ty = Ast.TyNamed ("Void", []);
              }
            else arg)
          args
      in
      { e with desc = CCall (CKBuiltin c, callee, boxed_args) }
  | CCall (CKBuiltin c, callee, args)
    when List.mem_assoc c void_boxed_arg_positions ->
      let boxed_args, changed = box_void_args_for_builtin ~reg c args in
      if changed then { e with desc = CCall (CKBuiltin c, callee, boxed_args) }
      else e
  (* [type_name] / [is_heap] from [std/debug]: constant-fold per mono copy.
     Infer defers the fold when the arg type still has type vars (pure func
     identify[T](x: T): type_name(x)). Core_resolve tags those deferred calls
     as explicit debug-reflection intrinsics, and post-mono [arg.ty] is
     concrete for each specialized copy. *)
  | CCall (CKIntrinsic "type_name", _, [ arg ]) ->
      let s = Types.type_to_string arg.ty in
      {
        e with
        desc = CLit (Ast.LitString (s, { sf_triple = false; sf_raw = false }));
      }
  | CCall (CKIntrinsic "is_heap", _, [ arg ]) ->
      let desc =
        match
          Core_type_layout.classify_debug_heap_value
            (Core_type_layout.metadata_for_registry reg)
            arg.ty
        with
        | Core_type_layout.DebugHeapValue -> CLit (Ast.LitBool true)
        | Core_type_layout.DebugStackValue -> CLit (Ast.LitBool false)
        | Core_type_layout.DebugHeapUnknownNamed name ->
            Core_error.errorf (Core_error.Stage Core_stage.Specialize) arg.loc
              ~hint:
                "ensure the type is registered before debug reflection is \
                 specialized"
              "debug heap classifier has no layout for type %s" name
        | Core_type_layout.DebugHeapInvalidValueType msg ->
            Core_error.errorf (Core_error.Stage Core_stage.Specialize) arg.loc
              ~hint:"only runtime value types may be reflected with is_heap"
              "%s" msg
      in
      { e with desc }
  | CCall (CKUnknown, callee, args) ->
      let func_name =
        match callee.desc with CVar v -> Some v.vname | _ -> None
      in
      let first_is_tensor =
        match args with first :: _ -> is_tensor_type first.ty | [] -> false
      in
      if first_is_tensor then
        let elem_ty =
          match args with
          | first :: _ ->
              tensor_elem_type ~loc:e.loc
                ~context:
                  "unknown tensor call specialization requires a tensor \
                   receiver"
                first.ty
          | [] -> Ast.TyNamed ("Int", [])
        in
        let dummy =
          { desc = CVoid; ty = Ast.TyNamed ("Void", []); loc = e.loc }
        in
        match (func_name, args) with
        (* sum, product, dot, max, min, mean, argmax, argmin, cumulative_sum — post-mono synthesis *)
        | Some name, _
          when Option.is_some (tensor_elementwise_builtin_name name elem_ty) ->
            let builtin_name =
              Option.get (tensor_elementwise_builtin_name name elem_ty)
            in
            { e with desc = CCall (CKBuiltin builtin_name, dummy, args) }
        | Some "scale", _ ->
            let scale_name =
              match elem_ty with
              | Ast.TyNamed ("Float", _) -> "blorp_vector_scale_float"
              | _ -> "blorp_vector_scale_int"
            in
            { e with desc = CCall (CKBuiltin scale_name, dummy, args) }
        | _ -> e
      else e
  | _ -> e

(** Specialize a function body. Generic bodies (those with remaining type
    parameters after mono) only get phase-invariant layout rewrites. [Core_emit]
    skips them (only monomorphized copies are emitted), and several specialize
    rewrites (notably [tensor_peel] → [blorp_tensor_slice_row]) require
    concrete dim values that a generic body doesn't have. Layout-bearing list
    allocation is still safe: unresolved element types use pointer storage, and
    concrete monomorphized copies get their precise layout through the normal
    full specialization path. *)
let specialize_func ~reg (f : core_func) : core_func =
  match f.cf_body with
  | None -> f
  | Some body when f.cf_type_params <> [] ->
      { f with cf_body = Some (specialize_layout_allocs_expr ~reg body) }
  | Some body -> { f with cf_body = Some (specialize_expr ~reg body) }

let rec specialize_decl ~reg (d : core_decl) : core_decl =
  let desc' =
    match d.cd_desc with
    | CDFunc f -> CDFunc (specialize_func ~reg f)
    | CDVar v -> CDVar { v with cv_init = specialize_expr ~reg v.cv_init }
    | CDImpl i ->
        CDImpl
          { i with ci_methods = List.map (specialize_func ~reg) i.ci_methods }
    | CDTrait _ as other -> other (* no expressions; defaults live on AST *)
    | CDPrivate inner -> CDPrivate (specialize_decl ~reg inner)
    | (CDType _ | CDRecord _ | CDImport _ | CDTypeAlias _) as other -> other
  in
  { d with cd_desc = desc' }

(** Entry point — takes the shared registry so enum-type names are
    recognized by [is_pointer_type] when deciding whether to box. *)
let specialize_program ~reg (prog : core_program) : core_program =
  List.map (specialize_decl ~reg) prog
