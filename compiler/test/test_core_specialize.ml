(** Tests for Core_specialize: post-resolve builtin rewriting. *)

open Blorp.Ast
open Blorp.Core

let loc =
  { line = 1; column = 1; end_line = 1; end_column = 1; loc_file = None }

let ty_int = TyNamed ("Int", [])
let ty_float = TyNamed ("Float", [])
let ty_float32 = TyNamed ("Float32", [])
let ty_float16 = TyNamed ("Float16", [])
let ty_bool = TyNamed ("Bool", [])
let ty_string = TyNamed ("String", [])
let ty_bytes = TyNamed ("Bytes", [])
let ty_ptr = TyNamed ("Ptr", [])
let ty_var_t = TyVar "T"
let ty_named_t = TyNamed ("T", [])
let ty_void = TyNamed ("Void", [])
let tparams names = List.map (fun name -> make_type_param name []) names
let ty_list_int = TyNamed ("List", [ ty_int ])
let ty_list_char = TyNamed ("List", [ TyNamed ("Char", []) ])
let ty_stream_string = TyNamed ("Stream", [ ty_string ])
let mk d t = { desc = d; ty = t; loc }
let cvar n t = mk (CVar (Var.named n)) t
let cvoid = mk CVoid ty_void

let resource_scope name ty acquire body cleanup =
  mk
    (CResourceScope
       {
         rs_var = Var.named name;
         rs_ty = ty;
         rs_acquire = acquire;
         rs_body = body;
         rs_cleanup = cleanup;
       })
    body.ty

let enum_variant name tag =
  {
    variant_name = name;
    variant_fields = [];
    variant_tag = tag;
    variant_loc = loc;
    variant_def_id = None;
  }

let tensor elem dims =
  TyNamed ("Tensor", elem :: List.map (fun n -> TyConstInt n) dims)

let call_builtin name args ret_ty =
  mk (CCall (CKBuiltin name, mk CVoid ty_void, args)) ret_ty

let call_unknown name args ret_ty =
  mk (CCall (CKUnknown, cvar name ty_void, args)) ret_ty

let call_intrinsic name args ret_ty =
  mk (CCall (CKIntrinsic name, mk CVoid ty_void, args)) ret_ty

let specialize e =
  let reg = Blorp.Codegen_types.create_registry () in
  Blorp.Core_specialize.specialize_expr ~reg e

let specialize_with_reg reg e = Blorp.Core_specialize.specialize_expr ~reg e

let int_lit = function
  | { desc = CLit (LitInt n); _ } -> Int64.to_int n
  | _ -> Alcotest.fail "expected integer literal argument"

let rec drop n xs =
  if n <= 0 then xs
  else match xs with [] -> [] | _ :: rest -> drop (n - 1) rest

let expect_builtin_with_dims label expected_name expected_dims e =
  match (specialize e).desc with
  | CCall (CKBuiltin got_name, _, args) ->
      Alcotest.(check string) (label ^ " name") expected_name got_name;
      let got_dims =
        List.map int_lit
          (drop (List.length args - List.length expected_dims) args)
      in
      Alcotest.(check (list int)) (label ^ " dims") expected_dims got_dims
  | CCall (CKUnknown, _, _) -> Alcotest.failf "%s stayed CKUnknown" label
  | CCall (kind, _, _) ->
      let got =
        match kind with
        | CKUser (n, _) -> "CKUser " ^ n
        | CKForeign { fc_c_name; _ } -> "CKForeign " ^ fc_c_name
        | CKIntrinsic n -> "CKIntrinsic " ^ n
        | CKBuiltin n -> "CKBuiltin " ^ n
        | CKClosure -> "CKClosure"
        | CKUnknown -> "CKUnknown"
        | CKSelectedDirect id -> Printf.sprintf "CKSelectedDirect %d" id
      in
      Alcotest.failf "%s resolved as %s" label got
  | _ -> Alcotest.failf "%s did not specialize to a call" label

let expect_builtin_with_dims_with_reg label reg expected_name expected_dims e =
  match (specialize_with_reg reg e).desc with
  | CCall (CKBuiltin got_name, _, args) ->
      Alcotest.(check string) (label ^ " name") expected_name got_name;
      let got_dims =
        List.map int_lit
          (drop (List.length args - List.length expected_dims) args)
      in
      Alcotest.(check (list int)) (label ^ " dims") expected_dims got_dims
  | CCall (CKUnknown, _, _) -> Alcotest.failf "%s stayed CKUnknown" label
  | CCall (kind, _, _) ->
      let got =
        match kind with
        | CKUser (n, _) -> "CKUser " ^ n
        | CKForeign { fc_c_name; _ } -> "CKForeign " ^ fc_c_name
        | CKIntrinsic n -> "CKIntrinsic " ^ n
        | CKBuiltin n -> "CKBuiltin " ^ n
        | CKClosure -> "CKClosure"
        | CKUnknown -> "CKUnknown"
        | CKSelectedDirect id -> Printf.sprintf "CKSelectedDirect %d" id
      in
      Alcotest.failf "%s resolved as %s" label got
  | _ -> Alcotest.failf "%s did not specialize to a call" label

let expect_builtin label expected_name e =
  match (specialize e).desc with
  | CCall (CKBuiltin got_name, _, _) ->
      Alcotest.(check string) (label ^ " name") expected_name got_name
  | _ -> Alcotest.failf "%s did not specialize to expected builtin" label

let expect_builtin_last_int_with_reg label reg expected_name expected_last e =
  match (specialize_with_reg reg e).desc with
  | CCall (CKBuiltin got_name, _, args) ->
      Alcotest.(check string) (label ^ " name") expected_name got_name;
      Alcotest.(check int)
        (label ^ " last int") expected_last
        (int_lit (List.hd (List.rev args)))
  | _ -> Alcotest.failf "%s did not specialize to expected builtin" label

let expect_builtin_last_int label expected_name expected_last e =
  expect_builtin_last_int_with_reg label
    (Blorp.Codegen_types.create_registry ())
    expected_name expected_last e

let expect_cbox_arg_source label expected_source index args =
  match List.nth_opt args index with
  | Some { desc = CBox (_, source_ty); ty = TyNamed ("Void", []); _ } ->
      Alcotest.(check string)
        (label ^ " source type") expected_source
        (Blorp.Types.type_to_string source_ty)
  | Some arg ->
      Alcotest.failf "%s arg %d was not CBox: %s" label index
        (Blorp.Core.pp_to_string arg)
  | None -> Alcotest.failf "%s missing arg %d" label index

let expect_cbox_arg label index args =
  expect_cbox_arg_source label "Int" index args

let expect_builtin_with_reg label reg expected_name e =
  match (specialize_with_reg reg e).desc with
  | CCall (CKBuiltin got_name, _, _) ->
      Alcotest.(check string) (label ^ " name") expected_name got_name
  | _ -> Alcotest.failf "%s did not specialize to expected builtin" label

let expect_intrinsic label expected_name e =
  match (specialize e).desc with
  | CCall (CKIntrinsic got_name, _, _) ->
      Alcotest.(check string) (label ^ " name") expected_name got_name
  | _ -> Alcotest.failf "%s did not specialize to expected intrinsic" label

let expect_intrinsic_with_reg label reg expected_name e =
  match (specialize_with_reg reg e).desc with
  | CCall (CKIntrinsic got_name, _, _) ->
      Alcotest.(check string) (label ^ " name") expected_name got_name
  | _ -> Alcotest.failf "%s did not specialize to expected intrinsic" label

let test_vector_minmax_uses_tensor_element_abi () =
  let cases =
    [
      ("Float max", "blorp_max", ty_float, "blorp_vector_max_float");
      ("Float min", "blorp_min", ty_float, "blorp_vector_min_float");
      ("Float32 max", "blorp_max", ty_float32, "blorp_vector_max_float32");
      ("Float32 min", "blorp_min", ty_float32, "blorp_vector_min_float32");
      ("Float16 max", "blorp_max", ty_float16, "blorp_vector_max_float16");
      ("Float16 min", "blorp_min", ty_float16, "blorp_vector_min_float16");
      ("Int max", "blorp_max", ty_int, "blorp_vector_max_int");
      ("Int min", "blorp_min", ty_int, "blorp_vector_min_int");
    ]
  in
  List.iter
    (fun (label, sentinel, elem_ty, expected) ->
      let vector = cvar "values" (tensor elem_ty [ 3 ]) in
      expect_builtin label expected (call_builtin sentinel [ vector ] elem_ty))
    cases

let expect_ranked_checked_get_shape_dims label expected_dims args =
  let got_dims = List.map int_lit (List.filteri (fun i _ -> i >= 1 && i <= 3) args) in
  Alcotest.(check (list int)) (label ^ " dims") expected_dims got_dims

let count_intrinsic name body =
  fold_tree
    (fun acc node ->
      match node.desc with
      | CCall (CKIntrinsic got, _, _) when got = name -> acc + 1
      | _ -> acc)
    0 body

let count_tensor_raw_view_let kind body =
  fold_tree
    (fun acc node ->
      match node.desc with
      | CTensorRawViewLet ({ trv_kind; _ }, _) when trv_kind = kind -> acc + 1
      | _ -> acc)
    0 body

let count_tensor_raw_read kind body =
  fold_tree
    (fun acc node ->
      match node.desc with
      | CTensorRawRead { trr_kind; _ } when trr_kind = kind -> acc + 1
      | _ -> acc)
    0 body

let expect_list_alloc_width label expected_width e =
  match (specialize e).desc with
  | CListAlloc alloc ->
      let got_width =
        match alloc.la_layout.lsl_slots with
        | ListInlineStorage width -> inline_storage_width_bytes width
        | ListInlineStructStorage _ -> 0
        | ListPointerStorage -> 0
      in
      Alcotest.(check int) (label ^ " width") expected_width got_width
  | _ -> Alcotest.failf "%s did not specialize to CListAlloc" label

let expect_list_alloc_width_with_reg label reg expected_width e =
  match (specialize_with_reg reg e).desc with
  | CListAlloc alloc ->
      let got_width =
        match alloc.la_layout.lsl_slots with
        | ListInlineStorage width -> inline_storage_width_bytes width
        | ListInlineStructStorage _ -> 0
        | ListPointerStorage -> 0
      in
      Alcotest.(check int) (label ^ " width") expected_width got_width
  | _ -> Alcotest.failf "%s did not specialize to CListAlloc" label

let expect_string_literal label expected e =
  match (specialize e).desc with
  | CLit (LitString (got, _)) ->
      Alcotest.(check string) (label ^ " literal") expected got
  | _ -> Alcotest.failf "%s did not specialize to a string literal" label

let expect_bool_literal label expected e =
  match (specialize e).desc with
  | CLit (LitBool got) ->
      Alcotest.(check bool) (label ^ " literal") expected got
  | _ -> Alcotest.failf "%s did not specialize to a bool literal" label

let test_debug_type_name_intrinsic_folds () =
  let arg = mk (CLit (LitInt 42L)) (TyConstInt 42) in
  expect_string_literal "type_name" "#42"
    (call_intrinsic "type_name" [ arg ] ty_string)

let test_debug_is_heap_intrinsic_folds () =
  expect_bool_literal "is_heap Int" false
    (call_intrinsic "is_heap" [ mk (CLit (LitInt 1L)) ty_int ] ty_bool);
  expect_bool_literal "is_heap List" true
    (call_intrinsic "is_heap" [ cvar "xs" ty_list_int ] ty_bool)

let test_debug_reflection_requires_intrinsic_call_kind () =
  let arg = mk (CLit (LitInt 42L)) (TyConstInt 42) in
  match (specialize (call_unknown "type_name" [ arg ] ty_string)).desc with
  | CCall (CKUnknown, _, _) -> ()
  | CLit (LitString _) ->
      Alcotest.fail "unresolved type_name call folded by callee name"
  | _ -> Alcotest.fail "expected unresolved type_name to remain a call"

let test_list_alloc_intrinsic_specializes_to_layout_node () =
  let cap = mk (CLit (LitInt 4L)) ty_int in
  let e =
    mk (CCall (CKIntrinsic "list_alloc", mk CVoid ty_void, [ cap ])) ty_list_int
  in
  expect_list_alloc_width "List[Int] alloc" 8 e

let test_builtin_list_new_specializes_to_layout_node () =
  let cap = mk (CLit (LitInt 4L)) ty_int in
  let e = call_builtin "blorp_list_new" [ cap ] ty_list_int in
  expect_list_alloc_width "blorp_list_new List[Int]" 8 e

let test_list_alloc_enum_uses_registry_layout () =
  let reg = Blorp.Codegen_types.create_registry () in
  let color_ty = TyNamed ("Color", []) in
  Blorp.Codegen_types.register_enum_type reg "Color"
    [
      {
        variant_name = "Red";
        variant_fields = [];
        variant_tag = 0;
        variant_loc = loc;
        variant_def_id = None;
      };
      {
        variant_name = "Blue";
        variant_fields = [];
        variant_tag = 1;
        variant_loc = loc;
        variant_def_id = None;
      };
    ];
  let cap = mk (CLit (LitInt 2L)) ty_int in
  let e =
    mk
      (CCall (CKIntrinsic "list_alloc", mk CVoid ty_void, [ cap ]))
      (TyNamed ("List", [ color_ty ]))
  in
  expect_list_alloc_width_with_reg "List[Color] alloc" reg 1 e

let test_generic_function_list_alloc_gets_layout_without_other_rewrites () =
  let reg = Blorp.Codegen_types.create_registry () in
  let cap = mk (CLit (LitInt 4L)) ty_int in
  let list_t = TyNamed ("List", [ ty_var_t ]) in
  let type_dispatch_call =
    call_builtin "blorp_to_int" [ cvar "x" ty_var_t ] ty_int
  in
  let alloc =
    mk (CCall (CKIntrinsic "list_alloc", mk CVoid ty_void, [ cap ])) list_t
  in
  let body = mk (CSeq (type_dispatch_call, alloc)) list_t in
  let fn =
    {
      cf_name = "make_list";
      cf_module = None;
      cf_type_params = tparams [ "T" ];
      cf_params = [];
      cf_return_ty = list_t;
      cf_body = Some body;
      cf_is_pure = false;
      cf_kind = CFUser;
      cf_def_id = 1;
    }
  in
  let decl = { cd_desc = CDFunc fn; cd_loc = loc; cd_doc = None } in
  match Blorp.Core_specialize.specialize_program ~reg [ decl ] with
  | [
   {
     cd_desc = CDFunc { cf_body = Some { desc = CSeq (left, right); _ }; _ };
     _;
   };
  ] -> (
      match (left.desc, right.desc) with
      | ( CCall (CKBuiltin "blorp_to_int", _, _),
          CListAlloc { la_layout = { lsl_slots = ListPointerStorage; _ }; _ } )
        ->
          ()
      | _ ->
          Alcotest.fail
            "generic specialization should only rewrite list allocation layout")
  | _ -> Alcotest.fail "expected one specialized function"

let test_matrix_vector_multiply_float_specializes_with_dims () =
  let w = cvar "w" (tensor ty_float [ 2; 3 ]) in
  let x = cvar "x" (tensor ty_float [ 3 ]) in
  let e =
    call_builtin "blorp_tensor_matrix_vector_multiply" [ w; x ]
      (tensor ty_float [ 2 ])
  in
  expect_builtin_with_dims "multiply_vector float"
    "blorp_tensor_matrix_vector_multiply_float" [ 2; 3 ] e

let test_matrix_vector_multiply_float32_specializes_with_dims () =
  let w = cvar "w" (tensor ty_float32 [ 2; 3 ]) in
  let x = cvar "x" (tensor ty_float32 [ 3 ]) in
  let e =
    call_builtin "blorp_tensor_matrix_vector_multiply" [ w; x ]
      (tensor ty_float32 [ 2 ])
  in
  expect_builtin_with_dims "multiply_vector float32"
    "blorp_tensor_matrix_vector_multiply_float32" [ 2; 3 ] e

let test_matrix_vector_multiply_float16_specializes_with_dims () =
  let w = cvar "w" (tensor ty_float16 [ 2; 3 ]) in
  let x = cvar "x" (tensor ty_float16 [ 3 ]) in
  let e =
    call_builtin "blorp_tensor_matrix_vector_multiply" [ w; x ]
      (tensor ty_float16 [ 2 ])
  in
  expect_builtin_with_dims "multiply_vector float16"
    "blorp_tensor_matrix_vector_multiply_float16" [ 2; 3 ] e

let test_transposed_matrix_vector_multiply_float_specializes_with_dims () =
  let w = cvar "w" (tensor ty_float [ 2; 3 ]) in
  let x = cvar "x" (tensor ty_float [ 2 ]) in
  let e =
    call_builtin "blorp_tensor_transposed_matrix_vector_multiply" [ w; x ]
      (tensor ty_float [ 3 ])
  in
  expect_builtin_with_dims "multiply_transposed_vector float"
    "blorp_tensor_transposed_matrix_vector_multiply_float" [ 2; 3 ] e

let test_transposed_matrix_vector_multiply_float16_specializes_with_dims () =
  let w = cvar "w" (tensor ty_float16 [ 2; 3 ]) in
  let x = cvar "x" (tensor ty_float16 [ 2 ]) in
  let e =
    call_builtin "blorp_tensor_transposed_matrix_vector_multiply" [ w; x ]
      (tensor ty_float16 [ 3 ])
  in
  expect_builtin_with_dims "multiply_transposed_vector float16"
    "blorp_tensor_transposed_matrix_vector_multiply_float16" [ 2; 3 ] e

let test_outer_multiply_int_specializes_with_dims () =
  let a = cvar "a" (tensor ty_int [ 2 ]) in
  let b = cvar "b" (tensor ty_int [ 3 ]) in
  let e = call_builtin "blorp_tensor_outer" [ a; b ] (tensor ty_int [ 2; 3 ]) in
  expect_builtin_with_dims "outer int" "blorp_tensor_outer_int" [ 2; 3 ] e

let test_outer_multiply_float_specializes_with_dims () =
  let a = cvar "a" (tensor ty_float [ 2 ]) in
  let b = cvar "b" (tensor ty_float [ 3 ]) in
  let e =
    call_builtin "blorp_tensor_outer" [ a; b ] (tensor ty_float [ 2; 3 ])
  in
  expect_builtin_with_dims "outer float" "blorp_tensor_outer_float" [ 2; 3 ] e

let test_outer_multiply_float16_specializes_with_dims () =
  let a = cvar "a" (tensor ty_float16 [ 2 ]) in
  let b = cvar "b" (tensor ty_float16 [ 3 ]) in
  let e =
    call_builtin "blorp_tensor_outer" [ a; b ] (tensor ty_float16 [ 2; 3 ])
  in
  expect_builtin_with_dims "outer float16" "blorp_tensor_outer_float16" [ 2; 3 ]
    e

let test_matrix_multiply_float16_specializes_with_dims () =
  let a = cvar "a" (tensor ty_float16 [ 2; 3 ]) in
  let b = cvar "b" (tensor ty_float16 [ 3; 4 ]) in
  let e =
    call_builtin "blorp_tensor_matrix_multiply" [ a; b ]
      (tensor ty_float16 [ 2; 4 ])
  in
  expect_builtin_with_dims "multiply float16"
    "blorp_tensor_matrix_multiply_float16" [ 2; 3; 4 ] e

let test_unknown_matrix_vector_multiply_requires_resolved_builtin () =
  let w = cvar "w" (tensor ty_int [ 2; 2 ]) in
  let x = cvar "x" (tensor ty_int [ 2 ]) in
  let e = call_unknown "multiply_vector" [ w; x ] (tensor ty_int [ 2 ]) in
  match (specialize e).desc with
  | CCall (CKUnknown, _, _) -> ()
  | CCall (CKBuiltin name, _, _) ->
      Alcotest.failf "unresolved multiply_vector specialized to %s by name" name
  | _ -> Alcotest.fail "expected unresolved multiply_vector to remain a call"

let test_float32_vector_fill_uses_packed_runtime () =
  let value = mk (CLit (LitFloat 0.0)) ty_float32 in
  let size = mk (CLit (LitInt 4L)) ty_int in
  let e =
    call_builtin "blorp_vector_new_fill" [ value; size ]
      (tensor ty_float32 [ 4 ])
  in
  expect_builtin "float32 vector fill" "blorp_vector_new_fill_f32" e

let test_float64_vector_fill_uses_unboxed_runtime () =
  let value = mk (CLit (LitFloat 0.0)) ty_float in
  let size = mk (CLit (LitInt 4L)) ty_int in
  let e =
    call_builtin "blorp_vector_new_fill" [ value; size ] (tensor ty_float [ 4 ])
  in
  expect_builtin "float64 vector fill" "blorp_vector_new_fill_f64" e

let test_alias_matrix_vector_multiply_static_dims_specializes () =
  let reg = Blorp.Codegen_types.create_registry () in
  Hashtbl.replace reg.type_aliases "Meters" ([], ty_float);
  Hashtbl.replace reg.type_aliases "Weights"
    ( [],
      TyNamed ("Matrix", [ TyNamed ("Meters", []); TyConstInt 2; TyConstInt 3 ])
    );
  Hashtbl.replace reg.type_aliases "Inputs"
    ([], TyNamed ("Vector", [ TyNamed ("Meters", []); TyConstInt 3 ]));
  Hashtbl.replace reg.type_aliases "Outputs"
    ([], TyNamed ("Vector", [ TyNamed ("Meters", []); TyConstInt 2 ]));
  let w = cvar "w" (TyNamed ("Weights", [])) in
  let x = cvar "x" (TyNamed ("Inputs", [])) in
  let e =
    call_builtin "blorp_tensor_matrix_vector_multiply" [ w; x ]
      (TyNamed ("Outputs", []))
  in
  expect_builtin_with_dims_with_reg "alias multiply_vector" reg
    "blorp_tensor_matrix_vector_multiply_float" [ 2; 3 ] e

let test_alias_matrix_multiply_static_dims_specializes () =
  let reg = Blorp.Codegen_types.create_registry () in
  Hashtbl.replace reg.type_aliases "Meters" ([], ty_float);
  Hashtbl.replace reg.type_aliases "Left"
    ( [],
      TyNamed ("Matrix", [ TyNamed ("Meters", []); TyConstInt 2; TyConstInt 3 ])
    );
  Hashtbl.replace reg.type_aliases "Right"
    ( [],
      TyNamed ("Matrix", [ TyNamed ("Meters", []); TyConstInt 3; TyConstInt 4 ])
    );
  Hashtbl.replace reg.type_aliases "Product"
    ( [],
      TyNamed ("Matrix", [ TyNamed ("Meters", []); TyConstInt 2; TyConstInt 4 ])
    );
  let a = cvar "a" (TyNamed ("Left", [])) in
  let b = cvar "b" (TyNamed ("Right", [])) in
  let e =
    call_builtin "blorp_tensor_matrix_multiply" [ a; b ]
      (TyNamed ("Product", []))
  in
  expect_builtin_with_dims_with_reg "alias multiply" reg
    "blorp_tensor_matrix_multiply_float" [ 2; 3; 4 ] e

let test_float64_matrix_fill_uses_unboxed_runtime () =
  let value = mk (CLit (LitFloat 0.0)) ty_float in
  let rows = mk (CLit (LitInt 2L)) ty_int in
  let cols = mk (CLit (LitInt 3L)) ty_int in
  let e =
    call_builtin "blorp_matrix_new_fill" [ value; rows; cols ]
      (tensor ty_float [ 2; 3 ])
  in
  expect_builtin "float64 matrix fill" "blorp_matrix_new_fill_f64" e

let test_bool_vector_fill_uses_packed_runtime () =
  let value = mk (CLit (LitBool true)) ty_bool in
  let size = mk (CLit (LitInt 4L)) ty_int in
  let e =
    call_builtin "blorp_vector_new_fill" [ value; size ] (tensor ty_bool [ 4 ])
  in
  expect_builtin_last_int "bool vector fill" "blorp_vector_new_fill_packed" 1 e

let test_enum_vector_fill_uses_packed_runtime () =
  let reg = Blorp.Codegen_types.create_registry () in
  let color_ty = TyNamed ("Color", []) in
  Blorp.Codegen_types.register_enum_type reg "Color"
    [
      {
        variant_name = "Red";
        variant_fields = [];
        variant_tag = 0;
        variant_loc = loc;
        variant_def_id = None;
      };
      {
        variant_name = "Blue";
        variant_fields = [];
        variant_tag = 1;
        variant_loc = loc;
        variant_def_id = None;
      };
    ];
  let value = mk (CVar (Var.named "Red")) color_ty in
  let size = mk (CLit (LitInt 4L)) ty_int in
  let e =
    call_builtin "blorp_vector_new_fill" [ value; size ] (tensor color_ty [ 4 ])
  in
  expect_builtin_last_int_with_reg "enum vector fill" reg
    "blorp_vector_new_fill_packed" 1 e

let test_float32_checked_get_uses_packed_runtime () =
  let v = cvar "v" (tensor ty_float32 [ 4 ]) in
  let idx = mk (CLit (LitInt 2L)) ty_int in
  let e = call_builtin "blorp_checked_get" [ v; idx ] ty_float32 in
  expect_intrinsic "float32 checked_get" "tensor_get_f32" e

let test_float64_checked_get_uses_unboxed_intrinsic () =
  let v = cvar "v" (tensor ty_float [ 4 ]) in
  let idx = mk (CLit (LitInt 2L)) ty_int in
  let e = call_builtin "blorp_checked_get" [ v; idx ] ty_float in
  expect_intrinsic "float64 checked_get" "tensor_get_f64" e

let test_alias_int_checked_get_uses_raw_scalar_intrinsic () =
  let reg = Blorp.Codegen_types.create_registry () in
  Hashtbl.replace reg.type_aliases "Count" ([], ty_int);
  Hashtbl.replace reg.type_aliases "Counts"
    ([], TyNamed ("Vector", [ TyNamed ("Count", []); TyConstInt 4 ]));
  let v = cvar "v" (TyNamed ("Counts", [])) in
  let idx = mk (CLit (LitInt 2L)) ty_int in
  let e = call_builtin "blorp_checked_get" [ v; idx ] (TyNamed ("Count", [])) in
  expect_intrinsic_with_reg "alias int checked_get" reg "tensor_get_i64" e

let test_alias_enum_checked_get_uses_layout_intrinsic () =
  let reg = Blorp.Codegen_types.create_registry () in
  Blorp.Codegen_types.register_enum_type reg "Color"
    [ enum_variant "Red" 0; enum_variant "Blue" 1 ];
  Hashtbl.replace reg.type_aliases "Paint" ([], TyNamed ("Color", []));
  Hashtbl.replace reg.type_aliases "Paints"
    ([], TyNamed ("Vector", [ TyNamed ("Paint", []); TyConstInt 4 ]));
  let v = cvar "v" (TyNamed ("Paints", [])) in
  let idx = mk (CLit (LitInt 2L)) ty_int in
  let e = call_builtin "blorp_checked_get" [ v; idx ] (TyNamed ("Paint", [])) in
  expect_intrinsic_with_reg "alias enum checked_get" reg "tensor_get_i64" e

let test_float64_matrix_checked_get_uses_unboxed_runtime () =
  let m = cvar "m" (tensor ty_float [ 2; 3 ]) in
  let row = mk (CLit (LitInt 1L)) ty_int in
  let col = mk (CLit (LitInt 2L)) ty_int in
  let e = call_builtin "blorp_matrix_checked_get" [ m; row; col ] ty_float in
  expect_builtin "float64 matrix checked_get" "blorp_matrix_checked_get_f64" e

let test_rank3_int_checked_get_injects_shape_and_unboxes () =
  let t = cvar "t" (tensor ty_int [ 2; 3; 4 ]) in
  let i = mk (CLit (LitInt 1L)) ty_int in
  let j = mk (CLit (LitInt 2L)) ty_int in
  let k = mk (CLit (LitInt 3L)) ty_int in
  let e = call_builtin "blorp_tensor3_checked_get" [ t; i; j; k ] ty_int in
  match (specialize e).desc with
  | CUnbox
      ( { desc = CCall (CKBuiltin got_name, _, args); ty = TyNamed ("Ptr", []); _ },
        TyNamed ("Int", []) ) ->
      Alcotest.(check string)
        "rank3 int checked_get builtin" "blorp_tensor3_checked_get_shape"
        got_name;
      Alcotest.(check int) "rank3 int checked_get arg count" 7
        (List.length args);
      expect_ranked_checked_get_shape_dims "rank3 int checked_get" [ 2; 3; 4 ]
        args
  | _ -> Alcotest.fail "rank3 Int checked_get should specialize through CUnbox"

let test_rank3_float_checked_get_uses_shape_f64_runtime () =
  let t = cvar "t" (tensor ty_float [ 2; 3; 4 ]) in
  let i = mk (CLit (LitInt 1L)) ty_int in
  let j = mk (CLit (LitInt 2L)) ty_int in
  let k = mk (CLit (LitInt 3L)) ty_int in
  let e = call_builtin "blorp_tensor3_checked_get" [ t; i; j; k ] ty_float in
  match (specialize e).desc with
  | CCall (CKBuiltin got_name, _, args) ->
      Alcotest.(check string)
        "rank3 float checked_get builtin" "blorp_tensor3_checked_get_shape_f64"
        got_name;
      Alcotest.(check int) "rank3 float checked_get arg count" 7
        (List.length args);
      expect_ranked_checked_get_shape_dims "rank3 float checked_get" [ 2; 3; 4 ]
        args
  | _ -> Alcotest.fail "rank3 Float checked_get should specialize to shape f64"

let test_bounds_proven_tensor_read_uses_typed_raw_view () =
  let values = cvar "values" (tensor ty_float [ 4 ]) in
  let idx = cvar "i" ty_int in
  let checked_get = call_builtin "blorp_checked_get" [ values; idx ] ty_float in
  let bound : Blorp.Core_specialize.loop_index_bound =
    {
      lib_var = Var.named "i";
      lib_lower_nonnegative = true;
      lib_upper_exclusive = Some 4;
    }
  in
  let env : Blorp.Core_specialize.specialize_env =
    { loop_index_bounds = [ bound ] }
  in
  match
    Blorp.Core_specialize.bounds_proven_tensor_read env checked_get values idx
  with
  | None -> Alcotest.fail "bounds-proven Float tensor read should specialize"
  | Some body ->
      Alcotest.(check int)
        "does not emit raw unchecked get intrinsic" 0
        (count_intrinsic "tensor_get_f64_raw_unchecked" body);
      Alcotest.(check int)
        "binds one typed raw tensor view" 1
        (count_tensor_raw_view_let TensorFloat64Elements body);
      Alcotest.(check int)
        "reads through typed raw tensor view" 1
        (count_tensor_raw_read TensorFloat64Elements body)

let test_bounds_proven_tensor_read_rejects_temporary_source () =
  let parent = cvar "parent" (tensor ty_float [ 2; 4 ]) in
  let row = mk (CLit (LitInt 0L)) ty_int in
  let values =
    call_builtin "blorp_tensor_slice_row" [ parent; row ]
      (tensor ty_float [ 4 ])
  in
  let idx = cvar "i" ty_int in
  let checked_get = call_builtin "blorp_checked_get" [ values; idx ] ty_float in
  let bound : Blorp.Core_specialize.loop_index_bound =
    {
      lib_var = Var.named "i";
      lib_lower_nonnegative = true;
      lib_upper_exclusive = Some 4;
    }
  in
  let env : Blorp.Core_specialize.specialize_env =
    { loop_index_bounds = [ bound ] }
  in
  Alcotest.(check bool)
    "temporary tensor source is not borrowed by a raw view" true
    (Option.is_none
       (Blorp.Core_specialize.bounds_proven_tensor_read env checked_get values
          idx))

let guarded_float64_raw_read source idx =
  let cond = call_intrinsic "tensor_is_f64_storage" [ source ] ty_bool in
  let fast =
    call_intrinsic "tensor_get_f64_raw_unchecked" [ source; idx ] ty_float
  in
  let safe = call_builtin "blorp_checked_get" [ source; idx ] ty_float in
  mk (CIf (cond, fast, safe)) ty_float

let test_raw_tensor_view_collection_respects_resource_scope_binding () =
  let values_ty = tensor ty_float [ 4 ] in
  let values = cvar "values" values_ty in
  let idx = cvar "i" ty_int in
  let scoped =
    resource_scope "values" values_ty
      (cvar "open_values" values_ty)
      (guarded_float64_raw_read values idx)
      cvoid
  in
  match
    Blorp.Core_specialize.collect_raw_tensor_views
      Blorp.Core_specialize.empty_specialize_env [] [] scoped
  with
  | Some [] -> ()
  | Some views ->
      Alcotest.failf "expected no views, collected %d" (List.length views)
  | None -> Alcotest.fail "resource scope should not make collection fail"

let test_raw_tensor_view_rewrite_does_not_enter_resource_scope () =
  let values_ty = tensor ty_float [ 4 ] in
  let values = cvar "values" values_ty in
  let idx = cvar "i" ty_int in
  let scoped =
    resource_scope "values" values_ty
      (cvar "open_values" values_ty)
      (guarded_float64_raw_read values idx)
      cvoid
  in
  let view : Blorp.Core_specialize.raw_tensor_view =
    {
      rtv_tensor = Var.named "values";
      rtv_tensor_ty = values_ty;
      rtv_ptr = Var.named "__values_raw";
      rtv_kind = TensorFloat64Elements;
      rtv_needs_unique = false;
    }
  in
  let rewritten =
    Blorp.Core_specialize.rewrite_raw_tensor_view_body
      Blorp.Core_specialize.empty_specialize_env [] [ view ] scoped
  in
  Alcotest.(check int)
    "resource body is not rewritten to raw view" 0
    (count_tensor_raw_read TensorFloat64Elements rewritten)

let test_float64_checked_set_uses_unboxed_runtime () =
  let v = cvar "v" (tensor ty_float [ 4 ]) in
  let idx = mk (CLit (LitInt 2L)) ty_int in
  let value = mk (CLit (LitFloat 1.5)) ty_float in
  let e =
    call_builtin "blorp_checked_set" [ v; idx; value ] (tensor ty_float [ 4 ])
  in
  expect_builtin "float64 checked_set" "blorp_vector_set_inplace_f64" e

let test_float64_matrix_checked_set_uses_unboxed_runtime () =
  let m = cvar "m" (tensor ty_float [ 2; 3 ]) in
  let row = mk (CLit (LitInt 1L)) ty_int in
  let col = mk (CLit (LitInt 2L)) ty_int in
  let value = mk (CLit (LitFloat 1.5)) ty_float in
  let e =
    call_builtin "blorp_matrix_checked_set" [ m; row; col; value ]
      (tensor ty_float [ 2; 3 ])
  in
  expect_builtin "float64 matrix checked_set" "blorp_matrix_checked_set_f64" e

let test_float32_vector_get_option_uses_packed_runtime () =
  let v = cvar "v" (tensor ty_float32 [ 4 ]) in
  let idx = mk (CLit (LitInt 2L)) ty_int in
  let e =
    call_builtin "blorp_vector_get_opt" [ v; idx ]
      (TyNamed ("Option", [ ty_float32 ]))
  in
  expect_builtin "float32 option get" "blorp_vector_get_opt_f32" e

let test_dict_get_managed_option_uses_nullable_runtime () =
  let dict = cvar "d" (TyNamed ("Dict", [ ty_int; ty_string ])) in
  let key = cvar "k" ty_int in
  let e =
    call_builtin "blorp_dict_get" [ dict; key ]
      (TyNamed ("Option", [ ty_string ]))
  in
  match (specialize e).desc with
  | CCall (CKBuiltin "blorp_dict_get_nullable", _, args) ->
      expect_cbox_arg "key" 1 args
  | CCall (CKBuiltin got_name, _, _) ->
      Alcotest.failf "dict get Option[String] used %s" got_name
  | _ -> Alcotest.fail "dict get Option[String] did not specialize to builtin"

let test_dict_capacity_alias_string_key_uses_string_constructor () =
  let reg = Blorp.Codegen_types.create_registry () in
  Hashtbl.replace reg.type_aliases "Name" ([], ty_string);
  let dict_ty = TyNamed ("Dict", [ TyNamed ("Name", []); ty_int ]) in
  let cap = mk (CLit (LitInt 8L)) ty_int in
  let e = call_builtin "blorp_dict_with_capacity" [ cap ] dict_ty in
  expect_builtin_with_reg "alias string dict capacity" reg
    "blorp_dict_with_capacity_string" e

let test_immediate_dict_alias_enum_key_stays_generic_constructor () =
  let reg = Blorp.Codegen_types.create_registry () in
  Blorp.Codegen_types.register_enum_type reg "Color"
    [
      {
        variant_name = "Red";
        variant_fields = [];
        variant_tag = 0;
        variant_loc = loc;
        variant_def_id = None;
      };
      {
        variant_name = "Blue";
        variant_fields = [];
        variant_tag = 1;
        variant_loc = loc;
        variant_def_id = None;
      };
    ];
  Hashtbl.replace reg.type_aliases "Shade" ([], TyNamed ("Color", []));
  let dict_ty = TyNamed ("Dict", [ TyNamed ("Shade", []); ty_int ]) in
  let dict_new = call_builtin "blorp_dict_new" [] dict_ty in
  let key = cvar "key" (TyNamed ("Shade", [])) in
  let value = mk (CLit (LitInt 1L)) ty_int in
  let e = call_builtin "blorp_dict_insert" [ dict_new; key; value ] dict_ty in
  match (specialize_with_reg reg e).desc with
  | CCall
      ( CKBuiltin "blorp_dict_insert",
        _,
        { desc = CCall (CKBuiltin "blorp_dict_new", _, []); _ } :: _ ) ->
      ()
  | other ->
      Alcotest.failf
        "alias-to-enum dict constructor should stay generic, got: %s"
        (Blorp.Core.pp_to_string { e with desc = other })

let test_vector_get_managed_option_uses_nullable_runtime () =
  let v = cvar "v" (tensor ty_string [ 4 ]) in
  let idx = mk (CLit (LitInt 2L)) ty_int in
  let e =
    call_builtin "blorp_vector_get_opt" [ v; idx ]
      (TyNamed ("Option", [ ty_string ]))
  in
  expect_builtin "vector get Option[String]" "blorp_vector_get_nullable" e

let test_matrix_get_managed_option_uses_nullable_runtime () =
  let m = cvar "m" (tensor ty_string [ 2; 3 ]) in
  let row = mk (CLit (LitInt 1L)) ty_int in
  let col = mk (CLit (LitInt 2L)) ty_int in
  let e =
    call_builtin "blorp_matrix_get_opt" [ m; row; col ]
      (TyNamed ("Option", [ ty_string ]))
  in
  expect_builtin "matrix get Option[String]" "blorp_matrix_get_nullable" e

let test_vector_set_managed_option_uses_nullable_runtime () =
  let v = cvar "v" (tensor ty_float [ 4 ]) in
  let idx = mk (CLit (LitInt 2L)) ty_int in
  let value = mk (CLit (LitFloat 1.5)) ty_float in
  let e =
    call_builtin "blorp_vector_set_cow" [ v; idx; value ]
      (TyNamed ("Option", [ tensor ty_float [ 4 ] ]))
  in
  match (specialize e).desc with
  | CCall (CKBuiltin "blorp_vector_set_cow_nullable", _, args) ->
      expect_cbox_arg_source "vector set value" "Float" 2 args
  | CCall (CKBuiltin got_name, _, _) ->
      Alcotest.failf "vector set Option[Tensor] used %s" got_name
  | _ -> Alcotest.fail "vector set Option[Tensor] did not specialize"

let test_float32_vector_set_managed_option_uses_nullable_runtime () =
  let v = cvar "v" (tensor ty_float32 [ 4 ]) in
  let idx = mk (CLit (LitInt 2L)) ty_int in
  let value = mk (CLit (LitFloat 1.5)) ty_float32 in
  let e =
    call_builtin "blorp_vector_set_cow" [ v; idx; value ]
      (TyNamed ("Option", [ tensor ty_float32 [ 4 ] ]))
  in
  expect_builtin "float32 vector set Option[Tensor]"
    "blorp_vector_set_cow_nullable_f32" e

let test_stream_filter_map_managed_option_uses_nullable_runtime () =
  let stream = cvar "s" ty_stream_string in
  let func =
    cvar "f"
      (TyFunc
         {
           params = [ ty_string ];
           return = TyNamed ("Option", [ ty_string ]);
           is_pure = true;
         })
  in
  let e =
    call_builtin "blorp_stream_filter_map" [ stream; func ] ty_stream_string
  in
  expect_builtin "stream filter_map Option[String]"
    "blorp_stream_filter_map_nullable" e

let test_stream_map_managed_result_sets_owned_arc_layout () =
  let stream = cvar "s" (TyNamed ("Stream", [ ty_int ])) in
  let func =
    cvar "f"
      (TyFunc { params = [ ty_int ]; return = ty_string; is_pure = true })
  in
  let e = call_builtin "blorp_stream_map" [ stream; func ] ty_stream_string in
  expect_builtin_last_int "stream map String result" "blorp_stream_map" 2 e

let test_stream_map_scalar_result_sets_immediate_layout () =
  let stream = cvar "s" ty_stream_string in
  let func =
    cvar "f"
      (TyFunc { params = [ ty_string ]; return = ty_int; is_pure = true })
  in
  let e =
    call_builtin "blorp_stream_map" [ stream; func ]
      (TyNamed ("Stream", [ ty_int ]))
  in
  expect_builtin_last_int "stream map Int result" "blorp_stream_map" 0 e

let test_stream_repeat_managed_value_sets_borrowed_arc_layout () =
  let value = cvar "s" ty_string in
  let e = call_builtin "blorp_stream_repeat" [ value ] ty_stream_string in
  expect_builtin_last_int "stream repeat String value" "blorp_stream_repeat" 1 e

let test_stream_repeat_scalar_value_sets_immediate_layout () =
  let value = mk (CLit (LitInt 7L)) ty_int in
  let e =
    call_builtin "blorp_stream_repeat" [ value ]
      (TyNamed ("Stream", [ ty_int ]))
  in
  expect_builtin_last_int "stream repeat Int value" "blorp_stream_repeat" 0 e

let expect_stream_unfold_layouts label expected_elem expected_state e =
  match (specialize e).desc with
  | CCall (CKBuiltin got_name, _, args) ->
      Alcotest.(check string) (label ^ " name") "blorp_stream_unfold" got_name;
      let args = List.rev args in
      Alcotest.(check int)
        (label ^ " state layout") expected_state
        (int_lit (List.hd args));
      Alcotest.(check int)
        (label ^ " elem layout") expected_elem
        (int_lit (List.hd (List.tl args)))
  | _ -> Alcotest.failf "%s did not specialize to expected builtin" label

let test_stream_unfold_managed_result_scalar_state_layouts () =
  let seed = mk (CLit (LitInt 0L)) ty_int in
  let func =
    cvar "f"
      (TyFunc
         {
           params = [ ty_int ];
           return = TyNamed ("Option", [ TyTuple [ ty_string; ty_int ] ]);
           is_pure = true;
         })
  in
  let e = call_builtin "blorp_stream_unfold" [ seed; func ] ty_stream_string in
  expect_stream_unfold_layouts "stream unfold String/Int" 2 0 e

let test_stream_unfold_managed_state_layout () =
  let seed = cvar "s" ty_string in
  let func =
    cvar "f"
      (TyFunc
         {
           params = [ ty_string ];
           return = TyNamed ("Option", [ TyTuple [ ty_string; ty_string ] ]);
           is_pure = true;
         })
  in
  let e = call_builtin "blorp_stream_unfold" [ seed; func ] ty_stream_string in
  expect_stream_unfold_layouts "stream unfold String/String" 2 2 e

let test_stream_fold_raw_result_keeps_pointer_type () =
  let stream = cvar "s" (TyNamed ("Stream", [ ty_int ])) in
  let init = mk (CLit (LitInt 0L)) ty_int in
  let func =
    cvar "f"
      (TyFunc { params = [ ty_int; ty_int ]; return = ty_int; is_pure = true })
  in
  let e = call_builtin "blorp_stream_fold" [ stream; init; func ] ty_int in
  match (specialize e).desc with
  | CUnbox
      ( {
          desc =
            CCall
              ( CKBuiltin "blorp_stream_fold",
                _,
                [ _stream; _init; _func; { desc = CLit (LitInt 0L); _ } ] );
          ty = TyNamed ("Ptr", []);
          _;
        },
        TyNamed ("Int", []) ) ->
      ()
  | CUnbox ({ ty = got_ty; _ }, _) ->
      Alcotest.failf "stream fold raw result used %s, expected Ptr"
        (Blorp.Types.type_to_string got_ty)
  | _ -> Alcotest.fail "stream fold should unbox a raw pointer result"

let test_runtime_managed_option_builtins_use_nullable_runtime () =
  let name = cvar "name" ty_string in
  let bytes = cvar "bytes" ty_bytes in
  expect_builtin "getenv Option[String]" "blorp_getenv_nullable"
    (call_builtin "blorp_getenv" [ name ] (TyNamed ("Option", [ ty_string ])));
  expect_builtin "base64_decode Option[String]" "blorp_base64_decode_nullable"
    (call_builtin "blorp_base64_decode" [ name ]
       (TyNamed ("Option", [ ty_string ])));
  expect_builtin "bytes_from_hex Option[Bytes]" "blorp_bytes_from_hex_nullable"
    (call_builtin "blorp_bytes_from_hex" [ name ]
       (TyNamed ("Option", [ ty_bytes ])));
  expect_builtin "decode_utf8 Option[List[Char]]" "blorp_decode_utf8_nullable"
    (call_builtin "blorp_decode_utf8" [ bytes ]
       (TyNamed ("Option", [ ty_list_char ])))

let test_assert_shape_managed_option_uses_nullable_runtime () =
  let v = cvar "v" (tensor ty_float [ 4 ]) in
  let size = mk (CLit (LitInt 4L)) ty_int in
  let e =
    call_builtin "blorp_assert_shape" [ v; size ]
      (TyNamed ("Option", [ tensor ty_float [ 4 ] ]))
  in
  expect_builtin "assert_shape Option[Tensor]" "blorp_assert_shape_nullable" e

let test_float32_vector_exp_builtin_specializes () =
  let v = cvar "v" (tensor ty_float32 [ 4 ]) in
  let e = call_builtin "blorp_vector_exp" [ v ] (tensor ty_float32 [ 4 ]) in
  expect_builtin "float32 exp" "blorp_vector_exp_float32" e

let test_float32_unary_neg_uses_float32_scalar_runtime () =
  let v = cvar "v" (tensor ty_float32 [ 4 ]) in
  let e = mk (CUn (Neg, v)) (tensor ty_float32 [ 4 ]) in
  expect_builtin "float32 unary neg" "blorp_vector_scalar_op_rev_float32" e

let test_float16_unary_neg_uses_float16_scalar_runtime () =
  let v = cvar "v" (tensor ty_float16 [ 4 ]) in
  let e = mk (CUn (Neg, v)) (tensor ty_float16 [ 4 ]) in
  expect_builtin "float16 unary neg" "blorp_vector_scalar_op_rev_float16" e

let test_custom_tensor_arithmetic_raises_core_error () =
  let custom_ty = TyNamed ("CustomNumber", []) in
  let tensor_ty = tensor custom_ty [ 4 ] in
  let left = cvar "left" tensor_ty in
  let right = cvar "right" tensor_ty in
  let e = mk (CBin (Add, left, right)) tensor_ty in
  Test_helpers.check_core_error_raises
    ~phase:(Blorp.Core_error.Stage Blorp.Core_stage.Specialize)
    ~msg_contains:"tensor arithmetic requires a concrete numeric element type"
    (fun () -> ignore (specialize e))

let test_bool_tensor_to_string_uses_bool_runtime () =
  let v = cvar "v" (tensor (TyNamed ("Bool", [])) [ 3 ]) in
  let e = call_builtin "blorp_to_string" [ v ] (TyNamed ("String", [])) in
  expect_builtin "bool tensor to_string" "blorp_vector_to_string_bool" e

let test_enum_tensor_to_string_uses_enum_runtime () =
  let reg = Blorp.Codegen_types.create_registry () in
  Blorp.Codegen_types.register_enum_type reg "Base" [];
  let v = cvar "v" (tensor (TyNamed ("Base", [])) [ 3 ]) in
  let e = call_builtin "blorp_to_string" [ v ] (TyNamed ("String", [])) in
  expect_builtin_with_reg "enum tensor to_string" reg "blorp_vector_to_string_Base"
    e

let test_sequential_list_folds_are_not_void_boxed_runtime_builtins () =
  let forbidden = [ "blorp_list_fold_left"; "blorp_list_fold_right" ] in
  List.iter
    (fun name ->
      Alcotest.(check bool)
        name false
        (List.mem_assoc name Blorp.Core_specialize.void_boxed_arg_positions))
    forbidden

let test_set_contains_is_not_void_boxed_runtime_builtin () =
  Alcotest.(check bool)
    "blorp_set_contains" false
    (List.mem_assoc "blorp_set_contains"
       Blorp.Core_specialize.void_boxed_arg_positions)

let test_dict_insert_refinement_preserves_void_arg_boxing () =
  let dict_ty = TyNamed ("Dict", [ ty_int; ty_int ]) in
  let dict = cvar "d" dict_ty in
  let key = mk (CLit (LitInt 1L)) ty_int in
  let value = mk (CLit (LitInt 2L)) ty_int in
  let e = call_builtin "blorp_dict_insert" [ dict; key; value ] dict_ty in
  match (specialize e).desc with
  | CCall (CKBuiltin "blorp_dict_insert", _, args) ->
      expect_cbox_arg "key" 1 args;
      expect_cbox_arg "value" 2 args
  | _ -> Alcotest.fail "dict_insert did not remain a builtin call"

let test_set_add_refinement_preserves_void_arg_boxing () =
  let set_ty = TyNamed ("Set", [ ty_int ]) in
  let set = cvar "s" set_ty in
  let elem = mk (CLit (LitInt 1L)) ty_int in
  let e = call_builtin "blorp_set_add" [ set; elem ] set_ty in
  match (specialize e).desc with
  | CCall (CKBuiltin "blorp_set_add", _, args) -> expect_cbox_arg "elem" 1 args
  | _ -> Alcotest.fail "set_add did not remain a builtin call"

let test_fold_parallel_with_preserves_void_arg_boxing () =
  let numbers = cvar "numbers" ty_list_int in
  let init = mk (CLit (LitInt 0L)) ty_int in
  let func =
    cvar "f"
      (TyFunc { params = [ ty_int; ty_int ]; return = ty_int; is_pure = true })
  in
  let threads = mk (CLit (LitInt 1L)) ty_int in
  let e =
    call_builtin "blorp_fold_parallel_with"
      [ numbers; init; func; threads ]
      ty_int
  in
  match (specialize e).desc with
  | CUnbox
      ( { desc = CCall (CKBuiltin "blorp_fold_parallel_with", _, args); _ },
        TyNamed ("Int", []) ) ->
      expect_cbox_arg "init" 1 args
  | other ->
      Alcotest.failf "fold_parallel_with did not keep expected shape: %s"
        (Blorp.Core.pp_to_string { e with desc = other })

let test_pointer_cbox_rewrites_to_borrow_cast () =
  let s = cvar "s" ty_string in
  let boxed = mk (CBox (s, ty_string)) ty_ptr in
  match (specialize boxed).desc with
  | CCast ({ desc = CVar v; _ }, TyNamed ("Ptr", [])) when v.vname = "s" -> ()
  | _ -> Alcotest.fail "pointer CBox should specialize to non-owning Ptr cast"

let test_stale_generic_cbox_uses_inner_type () =
  let f = cvar "f" ty_float in
  let boxed = mk (CBox (f, ty_var_t)) ty_ptr in
  match (specialize boxed).desc with
  | CBox ({ desc = CVar v; _ }, TyVar "T") when v.vname = "f" -> ()
  | _ ->
      Alcotest.fail
        "stale generic CBox metadata should not make Float a borrowed cast"

let test_stale_generic_cbox_rewrites_pointer_inner () =
  let s = cvar "s" ty_string in
  let boxed = mk (CBox (s, ty_var_t)) ty_ptr in
  match (specialize boxed).desc with
  | CCast ({ desc = CVar v; _ }, TyNamed ("Ptr", [])) when v.vname = "s" -> ()
  | _ ->
      Alcotest.fail "stale generic CBox metadata should use pointer inner type"

let test_named_generic_cbox_waits_for_concrete_inner () =
  let t = cvar "t" ty_named_t in
  let boxed = mk (CBox (t, ty_named_t)) ty_ptr in
  match (specialize boxed).desc with
  | CBox ({ desc = CVar v; _ }, TyNamed ("T", [])) when v.vname = "t" -> ()
  | _ ->
      Alcotest.fail
        "unresolved named generic CBox should not become a borrowed cast"

let test_named_generic_cbox_rewrites_pointer_inner () =
  let s = cvar "s" ty_string in
  let boxed = mk (CBox (s, ty_named_t)) ty_ptr in
  match (specialize boxed).desc with
  | CCast ({ desc = CVar v; _ }, TyNamed ("Ptr", [])) when v.vname = "s" -> ()
  | _ ->
      Alcotest.fail
        "named generic CBox metadata should use concrete pointer inner type"

let test_tensor_peel_nonconstant_dims_raise_core_error () =
  let coll =
    cvar "m" (TyNamed ("Tensor", [ ty_int; TyConstInt 2; TyVar "#N" ]))
  in
  let idx = mk (CLit (LitInt 0L)) ty_int in
  let e =
    call_builtin "blorp_tensor_peel" [ coll; idx ] (tensor ty_int [ 3 ])
  in
  Test_helpers.check_core_error_raises
    ~phase:(Blorp.Core_error.Stage Blorp.Core_stage.Specialize)
    ~msg_contains:"tensor_peel" (fun () -> ignore (specialize e))

let test_tensor_peel_raw_call_keeps_pointer_type () =
  let coll = cvar "m" (tensor ty_int [ 2; 3 ]) in
  let idx = mk (CLit (LitInt 0L)) ty_int in
  let result_ty = tensor ty_int [ 3 ] in
  let e = call_builtin "blorp_tensor_peel" [ coll; idx ] result_ty in
  match (specialize e).desc with
  | CCast
      ( { desc = CCall (CKBuiltin "blorp_tensor_slice_row", _, _); ty; _ },
        cast_ty ) ->
      Alcotest.(check string)
        "raw tensor peel call type" "Ptr" (Blorp.Types.type_to_string ty);
      Alcotest.(check string)
        "tensor peel result type" "Tensor[Int, #3]"
        (Blorp.Types.type_to_string cast_ty)
  | _ -> Alcotest.fail "tensor_peel should cast a pointer-returning runtime call"

let test_vector_norm_non_tensor_raises_core_error () =
  let x = cvar "x" ty_int in
  let e = call_builtin "blorp_vector_norm" [ x ] ty_float in
  Test_helpers.check_core_error_raises
    ~phase:(Blorp.Core_error.Stage Blorp.Core_stage.Specialize)
    ~msg_contains:"vector_norm requires a tensor argument" (fun () ->
      ignore (specialize e))

let test_matrix_multiply_non_tensor_operand_raises_core_error () =
  let a = cvar "a" ty_int in
  let b = cvar "b" (tensor ty_float [ 3; 4 ]) in
  let e =
    call_builtin "blorp_tensor_matrix_multiply" [ a; b ]
      (tensor ty_float [ 2; 4 ])
  in
  Test_helpers.check_core_error_raises
    ~phase:(Blorp.Core_error.Stage Blorp.Core_stage.Specialize)
    ~msg_contains:"multiply requires tensor operands" (fun () ->
      ignore (specialize e))

let test_matrix_multiply_non_tensor_right_operand_raises_core_error () =
  let a = cvar "a" (tensor ty_float [ 2; 3 ]) in
  let b = cvar "b" ty_int in
  let e =
    call_builtin "blorp_tensor_matrix_multiply" [ a; b ]
      (tensor ty_float [ 2; 4 ])
  in
  Test_helpers.check_core_error_raises
    ~phase:(Blorp.Core_error.Stage Blorp.Core_stage.Specialize)
    ~msg_contains:"multiply requires tensor operands" (fun () ->
      ignore (specialize e))

let test_vector_map_non_tensor_result_raises_core_error () =
  let v = cvar "v" (tensor ty_int [ 3 ]) in
  let f =
    cvar "f" (TyFunc { params = [ ty_int ]; return = ty_int; is_pure = true })
  in
  let e = call_builtin "blorp_vector_map" [ v; f ] ty_list_int in
  Test_helpers.check_core_error_raises
    ~phase:(Blorp.Core_error.Stage Blorp.Core_stage.Specialize)
    ~msg_contains:"tensor map result must be a tensor" (fun () ->
      ignore (specialize e))

let test_vector_map_value_record_result_sets_release_flag () =
  let reg = Blorp.Codegen_types.create_registry () in
  Hashtbl.replace reg.value_records "ProbeAccel" ();
  let accel = TyNamed ("ProbeAccel", []) in
  let v = cvar "v" (tensor ty_float [ 4 ]) in
  let f =
    cvar "f" (TyFunc { params = [ ty_float ]; return = accel; is_pure = true })
  in
  let e = call_builtin "blorp_vector_map" [ v; f ] (tensor accel [ 4 ]) in
  expect_builtin_last_int_with_reg "value record vector map" reg
    "blorp_vector_map" 1 e

let test_matrix_map_value_record_result_sets_release_flag () =
  let reg = Blorp.Codegen_types.create_registry () in
  Hashtbl.replace reg.value_records "ProbeAccel" ();
  let accel = TyNamed ("ProbeAccel", []) in
  let m = cvar "m" (tensor ty_float [ 2; 3 ]) in
  let f =
    cvar "f" (TyFunc { params = [ ty_float ]; return = accel; is_pure = true })
  in
  let e = call_builtin "blorp_matrix_map" [ m; f ] (tensor accel [ 2; 3 ]) in
  expect_builtin_last_int_with_reg "value record matrix map" reg
    "blorp_matrix_map" 1 e

let test_matrix_zip_map_scalar_result_clears_release_flag () =
  let reg = Blorp.Codegen_types.create_registry () in
  let a = cvar "a" (tensor ty_float [ 2; 3 ]) in
  let b = cvar "b" (tensor ty_float [ 2; 3 ]) in
  let f =
    cvar "f"
      (TyFunc
         { params = [ ty_float; ty_float ]; return = ty_float; is_pure = true })
  in
  let e =
    call_builtin "blorp_matrix_zip_map" [ a; b; f ] (tensor ty_float [ 2; 3 ])
  in
  expect_builtin_last_int_with_reg "scalar matrix zip_map" reg
    "blorp_matrix_zip_map" 0 e

let test_list_parallel_value_record_result_sets_release_flag () =
  let reg = Blorp.Codegen_types.create_registry () in
  Hashtbl.replace reg.value_records "ProbeAccel" ();
  let accel = TyNamed ("ProbeAccel", []) in
  let list_ty = TyNamed ("List", [ ty_float ]) in
  let result_ty = TyNamed ("List", [ accel ]) in
  let v = cvar "v" list_ty in
  let f =
    cvar "f" (TyFunc { params = [ ty_float ]; return = accel; is_pure = true })
  in
  let e = call_builtin "blorp_map_parallel" [ v; f ] result_ty in
  expect_builtin_last_int_with_reg "value record list parallel map" reg
    "blorp_map_parallel" 1 e

let test_vector_map_scalar_result_clears_release_flag () =
  let reg = Blorp.Codegen_types.create_registry () in
  let v = cvar "v" (tensor ty_float [ 4 ]) in
  let f =
    cvar "f"
      (TyFunc { params = [ ty_float ]; return = ty_float; is_pure = true })
  in
  let e = call_builtin "blorp_vector_map" [ v; f ] (tensor ty_float [ 4 ]) in
  expect_builtin_last_int_with_reg "scalar vector map" reg "blorp_vector_map" 0
    e

let test_fold_value_record_acc_sets_release_flag () =
  let reg = Blorp.Codegen_types.create_registry () in
  Hashtbl.replace reg.value_records "ProbeAccel" ();
  let accel = TyNamed ("ProbeAccel", []) in
  let values = cvar "values" (TyNamed ("List", [ ty_float ])) in
  let init = cvar "init" accel in
  let f =
    cvar "f"
      (TyFunc { params = [ accel; ty_float ]; return = accel; is_pure = true })
  in
  let e = call_builtin "blorp_fold_parallel" [ values; init; f ] accel in
  match (specialize_with_reg reg e).desc with
  | CUnbox ({ desc = CCall (CKBuiltin "blorp_fold_parallel", _, args); _ }, _)
    ->
      Alcotest.(check int)
        "value record fold acc release flag" 1
        (int_lit (List.hd (List.rev args)))
  | other ->
      Alcotest.failf "fold_parallel did not keep expected shape: %s"
        (Blorp.Core.pp_to_string { e with desc = other })

let suite =
  [
    ( "debug_reflection_specialization",
      [
        Alcotest.test_case "type_name_intrinsic_folds" `Quick
          test_debug_type_name_intrinsic_folds;
        Alcotest.test_case "is_heap_intrinsic_folds" `Quick
          test_debug_is_heap_intrinsic_folds;
        Alcotest.test_case "requires_intrinsic_call_kind" `Quick
          test_debug_reflection_requires_intrinsic_call_kind;
      ] );
    ( "list_layout_specialization",
      [
        Alcotest.test_case "list_alloc_intrinsic_to_layout_node" `Quick
          test_list_alloc_intrinsic_specializes_to_layout_node;
        Alcotest.test_case "builtin_list_new_to_layout_node" `Quick
          test_builtin_list_new_specializes_to_layout_node;
        Alcotest.test_case "enum_alloc_uses_registry_layout" `Quick
          test_list_alloc_enum_uses_registry_layout;
        Alcotest.test_case
          "generic_func_list_alloc_gets_layout_without_other_rewrites" `Quick
          test_generic_function_list_alloc_gets_layout_without_other_rewrites;
      ] );
    ( "matrix_builtins",
      [
        Alcotest.test_case "matrix_vector_multiply_float" `Quick
          test_matrix_vector_multiply_float_specializes_with_dims;
        Alcotest.test_case "matrix_vector_multiply_float32" `Quick
          test_matrix_vector_multiply_float32_specializes_with_dims;
        Alcotest.test_case "matrix_vector_multiply_float16" `Quick
          test_matrix_vector_multiply_float16_specializes_with_dims;
        Alcotest.test_case "transposed_matrix_vector_multiply_float" `Quick
          test_transposed_matrix_vector_multiply_float_specializes_with_dims;
        Alcotest.test_case "transposed_matrix_vector_multiply_float16" `Quick
          test_transposed_matrix_vector_multiply_float16_specializes_with_dims;
        Alcotest.test_case "outer_multiply_int" `Quick
          test_outer_multiply_int_specializes_with_dims;
        Alcotest.test_case "outer_multiply_float" `Quick
          test_outer_multiply_float_specializes_with_dims;
        Alcotest.test_case "outer_multiply_float16" `Quick
          test_outer_multiply_float16_specializes_with_dims;
        Alcotest.test_case "matrix_multiply_float16" `Quick
          test_matrix_multiply_float16_specializes_with_dims;
        Alcotest.test_case
          "unknown_matrix_vector_multiply_requires_resolved_builtin" `Quick
          test_unknown_matrix_vector_multiply_requires_resolved_builtin;
      ] );
    ( "float32_tensor_specialization",
      [
        Alcotest.test_case "vector_fill_packed" `Quick
          test_float32_vector_fill_uses_packed_runtime;
        Alcotest.test_case "float64_vector_fill_unboxed" `Quick
          test_float64_vector_fill_uses_unboxed_runtime;
        Alcotest.test_case "vector_minmax_uses_tensor_element_abi" `Quick
          test_vector_minmax_uses_tensor_element_abi;
        Alcotest.test_case
          "alias_matrix_vector_multiply_static_dims_specializes" `Quick
          test_alias_matrix_vector_multiply_static_dims_specializes;
        Alcotest.test_case "alias_matrix_multiply_static_dims_specializes"
          `Quick test_alias_matrix_multiply_static_dims_specializes;
        Alcotest.test_case "float64_matrix_fill_unboxed" `Quick
          test_float64_matrix_fill_uses_unboxed_runtime;
        Alcotest.test_case "bool_vector_fill_packed" `Quick
          test_bool_vector_fill_uses_packed_runtime;
        Alcotest.test_case "enum_vector_fill_packed" `Quick
          test_enum_vector_fill_uses_packed_runtime;
        Alcotest.test_case "checked_get_packed" `Quick
          test_float32_checked_get_uses_packed_runtime;
        Alcotest.test_case "float64_checked_get_unboxed" `Quick
          test_float64_checked_get_uses_unboxed_intrinsic;
        Alcotest.test_case "alias_int_checked_get_raw_scalar" `Quick
          test_alias_int_checked_get_uses_raw_scalar_intrinsic;
        Alcotest.test_case "alias_enum_checked_get_layout_intrinsic" `Quick
          test_alias_enum_checked_get_uses_layout_intrinsic;
        Alcotest.test_case "float64_matrix_checked_get_unboxed" `Quick
          test_float64_matrix_checked_get_uses_unboxed_runtime;
        Alcotest.test_case "rank3_int_checked_get_shape_unbox" `Quick
          test_rank3_int_checked_get_injects_shape_and_unboxes;
        Alcotest.test_case "rank3_float_checked_get_shape_f64" `Quick
          test_rank3_float_checked_get_uses_shape_f64_runtime;
        Alcotest.test_case "bounds_proven_tensor_read_typed_raw_view" `Quick
          test_bounds_proven_tensor_read_uses_typed_raw_view;
        Alcotest.test_case "bounds_proven_tensor_read_rejects_temporary_source"
          `Quick test_bounds_proven_tensor_read_rejects_temporary_source;
        Alcotest.test_case "raw_tensor_view_resource_scope_collection" `Quick
          test_raw_tensor_view_collection_respects_resource_scope_binding;
        Alcotest.test_case "raw_tensor_view_resource_scope_rewrite" `Quick
          test_raw_tensor_view_rewrite_does_not_enter_resource_scope;
        Alcotest.test_case "float64_checked_set_unboxed" `Quick
          test_float64_checked_set_uses_unboxed_runtime;
        Alcotest.test_case "float64_matrix_checked_set_unboxed" `Quick
          test_float64_matrix_checked_set_uses_unboxed_runtime;
        Alcotest.test_case "option_get_packed" `Quick
          test_float32_vector_get_option_uses_packed_runtime;
        Alcotest.test_case "dict_get_nullable_managed" `Quick
          test_dict_get_managed_option_uses_nullable_runtime;
        Alcotest.test_case "dict_capacity_alias_string_key" `Quick
          test_dict_capacity_alias_string_key_uses_string_constructor;
        Alcotest.test_case "immediate_dict_alias_enum_key" `Quick
          test_immediate_dict_alias_enum_key_stays_generic_constructor;
        Alcotest.test_case "vector_get_nullable_managed" `Quick
          test_vector_get_managed_option_uses_nullable_runtime;
        Alcotest.test_case "matrix_get_nullable_managed" `Quick
          test_matrix_get_managed_option_uses_nullable_runtime;
        Alcotest.test_case "vector_set_nullable_managed" `Quick
          test_vector_set_managed_option_uses_nullable_runtime;
        Alcotest.test_case "vector_set_nullable_f32" `Quick
          test_float32_vector_set_managed_option_uses_nullable_runtime;
        Alcotest.test_case "stream_filter_map_nullable_managed" `Quick
          test_stream_filter_map_managed_option_uses_nullable_runtime;
        Alcotest.test_case "stream_map_managed_result_sets_owned_arc_layout"
          `Quick test_stream_map_managed_result_sets_owned_arc_layout;
        Alcotest.test_case "stream_map_scalar_result_sets_immediate_layout"
          `Quick test_stream_map_scalar_result_sets_immediate_layout;
        Alcotest.test_case
          "stream_repeat_managed_value_sets_borrowed_arc_layout" `Quick
          test_stream_repeat_managed_value_sets_borrowed_arc_layout;
        Alcotest.test_case "stream_repeat_scalar_value_sets_immediate_layout"
          `Quick test_stream_repeat_scalar_value_sets_immediate_layout;
        Alcotest.test_case "stream_unfold_managed_result_scalar_state_layouts"
          `Quick test_stream_unfold_managed_result_scalar_state_layouts;
        Alcotest.test_case "stream_unfold_managed_state_layout" `Quick
          test_stream_unfold_managed_state_layout;
        Alcotest.test_case "stream_fold_raw_result_keeps_pointer_type" `Quick
          test_stream_fold_raw_result_keeps_pointer_type;
        Alcotest.test_case "runtime_nullable_managed_builtins" `Quick
          test_runtime_managed_option_builtins_use_nullable_runtime;
        Alcotest.test_case "assert_shape_nullable_managed" `Quick
          test_assert_shape_managed_option_uses_nullable_runtime;
        Alcotest.test_case "vector_exp_packed" `Quick
          test_float32_vector_exp_builtin_specializes;
        Alcotest.test_case "unary_neg_packed" `Quick
          test_float32_unary_neg_uses_float32_scalar_runtime;
        Alcotest.test_case "unary_neg_float16" `Quick
          test_float16_unary_neg_uses_float16_scalar_runtime;
        Alcotest.test_case "custom_tensor_arithmetic_rejected" `Quick
          test_custom_tensor_arithmetic_raises_core_error;
        Alcotest.test_case "bool_to_string" `Quick
          test_bool_tensor_to_string_uses_bool_runtime;
        Alcotest.test_case "enum_to_string" `Quick
          test_enum_tensor_to_string_uses_enum_runtime;
      ] );
    ( "list_hof_specialization",
      [
        Alcotest.test_case
          "sequential_list_folds_are_not_void_boxed_runtime_builtins" `Quick
          test_sequential_list_folds_are_not_void_boxed_runtime_builtins;
        Alcotest.test_case "set_contains_is_not_void_boxed_runtime_builtin"
          `Quick test_set_contains_is_not_void_boxed_runtime_builtin;
        Alcotest.test_case "dict_insert_refinement_preserves_void_arg_boxing"
          `Quick test_dict_insert_refinement_preserves_void_arg_boxing;
        Alcotest.test_case "set_add_refinement_preserves_void_arg_boxing" `Quick
          test_set_add_refinement_preserves_void_arg_boxing;
        Alcotest.test_case "fold_parallel_with_preserves_void_arg_boxing" `Quick
          test_fold_parallel_with_preserves_void_arg_boxing;
        Alcotest.test_case "pointer_cbox_rewrites_to_borrow_cast" `Quick
          test_pointer_cbox_rewrites_to_borrow_cast;
        Alcotest.test_case "stale_generic_cbox_uses_inner_type" `Quick
          test_stale_generic_cbox_uses_inner_type;
        Alcotest.test_case "stale_generic_cbox_rewrites_pointer_inner" `Quick
          test_stale_generic_cbox_rewrites_pointer_inner;
        Alcotest.test_case "named_generic_cbox_waits_for_concrete_inner" `Quick
          test_named_generic_cbox_waits_for_concrete_inner;
        Alcotest.test_case "named_generic_cbox_rewrites_pointer_inner" `Quick
          test_named_generic_cbox_rewrites_pointer_inner;
        Alcotest.test_case "tensor_peel_nonconstant_dims_raise_core_error"
          `Quick test_tensor_peel_nonconstant_dims_raise_core_error;
        Alcotest.test_case "tensor_peel_raw_call_keeps_pointer_type" `Quick
          test_tensor_peel_raw_call_keeps_pointer_type;
        Alcotest.test_case "vector_norm_non_tensor_raises_core_error" `Quick
          test_vector_norm_non_tensor_raises_core_error;
        Alcotest.test_case
          "matrix_multiply_non_tensor_operand_raises_core_error" `Quick
          test_matrix_multiply_non_tensor_operand_raises_core_error;
        Alcotest.test_case
          "matrix_multiply_non_tensor_right_operand_raises_core_error" `Quick
          test_matrix_multiply_non_tensor_right_operand_raises_core_error;
        Alcotest.test_case "vector_map_non_tensor_result_raises_core_error"
          `Quick test_vector_map_non_tensor_result_raises_core_error;
        Alcotest.test_case "vector_map_value_record_result_sets_release_flag"
          `Quick test_vector_map_value_record_result_sets_release_flag;
        Alcotest.test_case "matrix_map_value_record_result_sets_release_flag"
          `Quick test_matrix_map_value_record_result_sets_release_flag;
        Alcotest.test_case "matrix_zip_map_scalar_result_clears_release_flag"
          `Quick test_matrix_zip_map_scalar_result_clears_release_flag;
        Alcotest.test_case "list_parallel_value_record_result_sets_release_flag"
          `Quick test_list_parallel_value_record_result_sets_release_flag;
        Alcotest.test_case "vector_map_scalar_result_clears_release_flag" `Quick
          test_vector_map_scalar_result_clears_release_flag;
        Alcotest.test_case "fold_value_record_acc_sets_release_flag" `Quick
          test_fold_value_record_acc_sets_release_flag;
      ] );
  ]
