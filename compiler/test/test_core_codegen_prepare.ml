(** Tests for the final Core preparation pass that moves C-emitter
    type/layout decisions into explicit IR nodes. *)

open Blorp.Ast
open Blorp.Core

let loc =
  { line = 1; column = 1; end_line = 1; end_column = 1; loc_file = None }

let ty_int = TyNamed ("Int", [])
let ty_bool = TyNamed ("Bool", [])
let ty_float = TyNamed ("Float", [])
let ty_float32 = TyNamed ("Float32", [])
let ty_string = TyNamed ("String", [])
let ty_void = TyNamed ("Void", [])
let ty_test_resource = TyNamed ("TestResource", [])
let ty_list_int = TyNamed ("List", [ ty_int ])
let ty_dict_string_int = TyNamed ("Dict", [ ty_string; ty_int ])
let ty_set_string = TyNamed ("Set", [ ty_string ])
let ty_tensor_int_4 = TyNamed ("Tensor", [ ty_int; TyConstInt 4 ])
let ty_tensor_float_4 = TyNamed ("Tensor", [ ty_float; TyConstInt 4 ])
let ty_tensor_f32_2 = TyNamed ("Tensor", [ ty_float32; TyConstInt 2 ])
let ty_tensor_bool_3 = TyNamed ("Tensor", [ ty_bool; TyConstInt 3 ])
let ty_point = TyNamed ("Point", [])
let ty_tensor_point_2 = TyNamed ("Tensor", [ ty_point; TyConstInt 2 ])
let mk d t = { desc = d; ty = t; loc }
let cvoid = mk CVoid ty_void
let cint n = mk (CLit (LitInt (Int64.of_int n))) ty_int
let cfloat f = mk (CLit (LitFloat f)) ty_float
let cfloat32 f = mk (CLit (LitFloat f)) ty_float32
let cbool b = mk (CLit (LitBool b)) ty_bool
let cpoint name = mk (CVar (Var.named name)) ty_point

let core_var_equal expr var =
  match expr.desc with CVar expr_var -> Var.equal expr_var var | _ -> false

let prepare e =
  let reg = Blorp.Codegen_types.create_registry () in
  Blorp.Core_codegen_prepare.prepare_expr ~reg e

let test_empty_list_record_becomes_list_alloc () =
  match (prepare (mk (CRecord []) ty_list_int)).desc with
  | CListAlloc { la_capacity = { desc = CLit (LitInt 0L); _ }; _ } -> ()
  | _ -> Alcotest.fail "empty List literal should become explicit CListAlloc"

let test_empty_list_alias_record_becomes_list_alloc () =
  let reg = Blorp.Codegen_types.create_registry () in
  Hashtbl.replace reg.type_aliases "Ints" ([], ty_list_int);
  match
    (Blorp.Core_codegen_prepare.prepare_expr ~reg
       (mk (CRecord []) (TyNamed ("Ints", []))))
      .desc
  with
  | CListAlloc { la_capacity = { desc = CLit (LitInt 0L); _ }; _ } -> ()
  | _ ->
      Alcotest.fail "empty List alias literal should become explicit CListAlloc"

let test_empty_dict_record_becomes_dict_alloc () =
  match (prepare (mk (CRecord []) ty_dict_string_int)).desc with
  | CDictConstruct dc ->
      Alcotest.(check bool) "no entries" true (dc.dc_entries = []);
      Alcotest.(check bool)
        "string-key ctor" true
        (match dc.dc_constructor with DictString -> true | _ -> false)
  | _ ->
      Alcotest.fail "empty Dict literal should become explicit CDictConstruct"

let test_empty_dict_alias_string_key_becomes_string_alloc () =
  let reg = Blorp.Codegen_types.create_registry () in
  Hashtbl.replace reg.type_aliases "Name" ([], ty_string);
  let dict_ty = TyNamed ("Dict", [ TyNamed ("Name", []); ty_int ]) in
  match
    (Blorp.Core_codegen_prepare.prepare_expr ~reg (mk (CRecord []) dict_ty))
      .desc
  with
  | CDictConstruct { dc_constructor = DictString; _ } -> ()
  | CDictConstruct dc ->
      Alcotest.failf "expected DictString, got %s"
        (Blorp.Core.dict_constructor_str dc.dc_constructor)
  | _ ->
      Alcotest.fail
        "empty Dict alias literal should become explicit CDictConstruct"

let test_empty_dict_alias_enum_key_stays_generic_alloc () =
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
  match
    (Blorp.Core_codegen_prepare.prepare_expr ~reg (mk (CRecord []) dict_ty))
      .desc
  with
  | CDictConstruct { dc_constructor = DictGeneric; _ } -> ()
  | CDictConstruct dc ->
      Alcotest.failf "expected DictGeneric, got %s"
        (Blorp.Core.dict_constructor_str dc.dc_constructor)
  | _ ->
      Alcotest.fail
        "empty Dict alias enum literal should become explicit CDictConstruct"

let test_empty_dict_alias_record_becomes_dict_alloc () =
  let reg = Blorp.Codegen_types.create_registry () in
  Hashtbl.replace reg.type_aliases "Scores" ([], ty_dict_string_int);
  match
    (Blorp.Core_codegen_prepare.prepare_expr ~reg
       (mk (CRecord []) (TyNamed ("Scores", []))))
      .desc
  with
  | CDictConstruct { dc_constructor = DictString; dc_entries = []; _ } -> ()
  | CDictConstruct dc ->
      Alcotest.failf "expected DictString, got %s"
        (Blorp.Core.dict_constructor_str dc.dc_constructor)
  | _ ->
      Alcotest.fail
        "empty Dict alias literal should become explicit CDictConstruct"

let test_empty_set_record_becomes_set_alloc () =
  match (prepare (mk (CRecord []) ty_set_string)).desc with
  | CSetAlloc { sa_constructor = SetString } -> ()
  | _ -> Alcotest.fail "empty Set literal should become explicit CSetAlloc"

let test_empty_set_alias_string_elem_becomes_string_alloc () =
  let reg = Blorp.Codegen_types.create_registry () in
  Hashtbl.replace reg.type_aliases "Name" ([], ty_string);
  let set_ty = TyNamed ("Set", [ TyNamed ("Name", []) ]) in
  match
    (Blorp.Core_codegen_prepare.prepare_expr ~reg (mk (CRecord []) set_ty)).desc
  with
  | CSetAlloc { sa_constructor = SetString } -> ()
  | CSetAlloc { sa_constructor } ->
      Alcotest.failf "expected SetString, got %s"
        (Blorp.Core.set_constructor_str sa_constructor)
  | _ ->
      Alcotest.fail "empty Set alias literal should become explicit CSetAlloc"

let test_empty_set_alias_record_becomes_set_alloc () =
  let reg = Blorp.Codegen_types.create_registry () in
  Hashtbl.replace reg.type_aliases "Names" ([], ty_set_string);
  match
    (Blorp.Core_codegen_prepare.prepare_expr ~reg
       (mk (CRecord []) (TyNamed ("Names", []))))
      .desc
  with
  | CSetAlloc { sa_constructor = SetString } -> ()
  | CSetAlloc { sa_constructor } ->
      Alcotest.failf "expected SetString, got %s"
        (Blorp.Core.set_constructor_str sa_constructor)
  | _ ->
      Alcotest.fail "empty Set alias literal should become explicit CSetAlloc"

let test_vector_literal_becomes_tensor_literal () =
  let e = mk (CVector [ cfloat32 1.0; cfloat32 2.0 ]) ty_tensor_f32_2 in
  match (prepare e).desc with
  | CTensorLiteral tl ->
      let has_layout =
        match tl.tl_layout.tsl_slots with
        | TensorRawScalarStorage TensorFloat32Elements -> true
        | _ -> false
      in
      let is_f32_storage, raw_len =
        match tl.tl_payload with
        | TensorRawElements (TensorFloat32Elements, elems) ->
            (true, List.length elems)
        | _ -> (false, 0)
      in
      Alcotest.(check int) "raw elems" 2 raw_len;
      Alcotest.(check bool) "explicit f32 layout" true has_layout;
      Alcotest.(check bool) "f32 storage" true is_f32_storage
  | _ -> Alcotest.fail "CVector should become explicit CTensorLiteral"

let test_vector_alias_literal_uses_expanded_element_layout () =
  let reg = Blorp.Codegen_types.create_registry () in
  Hashtbl.replace reg.type_aliases "Meters" ([], ty_float);
  Hashtbl.replace reg.type_aliases "Positions"
    ([], TyNamed ("Vector", [ TyNamed ("Meters", []); TyConstInt 2 ]));
  let e = mk (CVector [ cfloat 1.0; cfloat 2.0 ]) (TyNamed ("Positions", [])) in
  match (Blorp.Core_codegen_prepare.prepare_expr ~reg e).desc with
  | CTensorLiteral tl ->
      let has_layout =
        match tl.tl_layout.tsl_slots with
        | TensorRawScalarStorage TensorFloat64Elements -> true
        | _ -> false
      in
      let is_f64_storage, raw_len =
        match tl.tl_payload with
        | TensorRawElements (TensorFloat64Elements, elems) ->
            (true, List.length elems)
        | _ -> (false, 0)
      in
      Alcotest.(check int) "raw elems" 2 raw_len;
      Alcotest.(check bool) "alias-expanded f64 layout" true has_layout;
      Alcotest.(check bool) "alias-expanded f64 storage" true is_f64_storage
  | _ -> Alcotest.fail "aliased CVector should become explicit CTensorLiteral"

let test_bool_vector_literal_becomes_packed_tensor_literal () =
  let e =
    mk (CVector [ cbool true; cbool false; cbool true ]) ty_tensor_bool_3
  in
  match (prepare e).desc with
  | CTensorLiteral tl ->
      let has_layout =
        match tl.tl_layout.tsl_slots with
        | TensorPackedStorage InlineBytes1 -> true
        | _ -> false
      in
      let is_packed, packed_len =
        match tl.tl_payload with
        | TensorPackedElements (InlineBytes1, elems) -> (true, List.length elems)
        | _ -> (false, 0)
      in
      Alcotest.(check int) "packed elems" 3 packed_len;
      Alcotest.(check bool) "explicit packed layout" true has_layout;
      Alcotest.(check bool) "bool packed storage" true is_packed
  | _ -> Alcotest.fail "Bool CVector should become packed CTensorLiteral"

let test_struct_vector_literal_becomes_inline_struct_tensor_literal () =
  let reg = Blorp.Codegen_types.create_registry () in
  Hashtbl.replace reg.value_records "Point" ();
  let e = mk (CVector [ cpoint "a"; cpoint "b" ]) ty_tensor_point_2 in
  match (Blorp.Core_codegen_prepare.prepare_expr ~reg e).desc with
  | CTensorLiteral tl ->
      let has_layout =
        match tl.tl_layout.tsl_slots with
        | TensorInlineStructStorage "Point" -> true
        | _ -> false
      in
      let is_inline_struct, elem_len =
        match tl.tl_payload with
        | TensorInlineStructElements ("Point", elems) ->
            (true, List.length elems)
        | _ -> (false, 0)
      in
      Alcotest.(check int) "inline struct elems" 2 elem_len;
      Alcotest.(check bool) "explicit inline struct layout" true has_layout;
      Alcotest.(check bool)
        "struct tensor uses inline struct storage" true is_inline_struct
  | _ ->
      Alcotest.fail "struct CVector should become inline-struct CTensorLiteral"

let test_box_unbox_become_typed_nodes () =
  let boxed = prepare (mk (CBox (cint 1, ty_int)) ty_void) in
  let unboxed = prepare (mk (CUnbox (cvoid, ty_int)) ty_int) in
  (match boxed.desc with
  | CBoxTyped { box_kind = BoxPrim; _ } -> ()
  | _ -> Alcotest.fail "CBox should become CBoxTyped with BoxPrim");
  match unboxed.desc with
  | CUnboxTyped { unbox_kind = UnboxPrim; _ } -> ()
  | _ -> Alcotest.fail "CUnbox should become CUnboxTyped with UnboxPrim"

let test_stack_option_box_unbox_become_struct_nodes () =
  let option_int = TyNamed ("Option", [ ty_int ]) in
  let value = mk (CVar (Var.named "opt")) option_int in
  let boxed = prepare (mk (CBox (value, option_int)) ty_void) in
  let unboxed = prepare (mk (CUnbox (cvoid, option_int)) option_int) in
  (match boxed.desc with
  | CBoxTyped { box_kind = BoxStruct "blorp_StackOption_Int"; _ } -> ()
  | _ ->
      Alcotest.fail
        "CBox Option[Int] should become CBoxTyped with stack-option struct \
         boxing");
  match unboxed.desc with
  | CUnboxTyped { unbox_kind = UnboxStruct "blorp_StackOption_Int"; _ } -> ()
  | _ ->
      Alcotest.fail
        "CUnbox Option[Int] should become CUnboxTyped with stack-option struct \
         unboxing"

let test_list_get_becomes_layout_node () =
  let get =
    prepare
      (mk
         (CCall
            ( CKIntrinsic "list_get",
              cvoid,
              [ mk (CVar (Var.named "xs")) ty_list_int; cint 0 ] ))
         (TyNamed ("Ptr", [])))
  in
  match get.desc with
  | CListGet
      {
        lg_layout = { lsl_slots = ListInlineStorage InlineBytes8; _ };
        lg_bounds;
        _;
      } ->
      Alcotest.(check bool)
        "keeps safe bounds by default" true
        (lg_bounds = ListBoundsChecked)
  | _ -> Alcotest.fail "list_get should become explicit CListGet"

let test_list_get_unchecked_becomes_proven_layout_node () =
  let get =
    prepare
      (mk
         (CCall
            ( CKIntrinsic "list_get_unchecked",
              cvoid,
              [ mk (CVar (Var.named "xs")) ty_list_int; cint 0 ] ))
         (TyNamed ("Ptr", [])))
  in
  match get.desc with
  | CListGet
      {
        lg_layout = { lsl_slots = ListInlineStorage InlineBytes8; _ };
        lg_bounds;
        _;
      } ->
      Alcotest.(check bool)
        "unchecked loads carry proven bounds" true
        (lg_bounds = ListBoundsProven)
  | _ -> Alcotest.fail "list_get_unchecked should become proven CListGet"

let test_string_byte_intrinsics_become_proof_nodes () =
  let s = mk (CVar (Var.named "s")) ty_string in
  let dst = mk (CVar (Var.named "dst")) ty_string in
  let read =
    prepare
      (mk (CCall (CKIntrinsic "string_get_byte", cvoid, [ s; cint 0 ])) ty_int)
  in
  let write =
    prepare
      (mk
         (CCall (CKIntrinsic "string_set_byte", cvoid, [ dst; cint 1; cint 65 ]))
         ty_void)
  in
  let copy =
    prepare
      (mk
         (CCall
            ( CKIntrinsic "string_copy_bytes",
              cvoid,
              [ dst; cint 0; s; cint 1; cint 3 ] ))
         ty_void)
  in
  let set_len =
    prepare
      (mk
         (CCall (CKIntrinsic "string_set_len", cvoid, [ dst; cint 4 ]))
         ty_void)
  in
  (match read.desc with
  | CStringByteRead { sbr_proof = StringReadBoundsProven; _ } -> ()
  | _ -> Alcotest.fail "string_get_byte should become CStringByteRead");
  (match write.desc with
  | CStringByteWrite { sbw_proof = StringWriteBoundsProven; _ } -> ()
  | _ -> Alcotest.fail "string_set_byte should become CStringByteWrite");
  (match copy.desc with
  | CStringByteCopy { sbc_proof = StringCopyBoundsProven; _ } -> ()
  | _ -> Alcotest.fail "string_copy_bytes should become CStringByteCopy");
  match set_len.desc with
  | CStringSetLen { ssl_proof = StringSetLenBoundsProven; _ } -> ()
  | _ -> Alcotest.fail "string_set_len should become CStringSetLen"

let guarded_f64_tensor_read tensor idx =
  mk
    (CIf
       ( mk
           (CCall (CKIntrinsic "tensor_is_f64_storage", cvoid, [ tensor ]))
           ty_bool,
         mk
           (CCall
              ( CKIntrinsic "tensor_get_f64_raw_unchecked",
                cvoid,
                [ tensor; idx ] ))
           ty_float,
         mk
           (CCall (CKIntrinsic "tensor_get_f64", cvoid, [ tensor; idx ]))
           ty_float ))
    ty_float

let guarded_i64_tensor_read tensor idx =
  mk
    (CIf
       ( mk
           (CCall (CKIntrinsic "tensor_is_i64_storage", cvoid, [ tensor ]))
           ty_bool,
         mk
           (CCall
              ( CKIntrinsic "tensor_get_i64_raw_unchecked",
                cvoid,
                [ tensor; idx ] ))
           ty_int,
         mk
           (CCall (CKIntrinsic "tensor_get_i64", cvoid, [ tensor; idx ]))
           ty_int ))
    ty_int

let test_proven_tensor_storage_read_drops_layout_guard () =
  let values = Var.named "values" in
  let values_ref = mk (CVar values) ty_tensor_float_4 in
  let body = guarded_f64_tensor_read values_ref (cint 0) in
  let expr =
    mk
      (CLet
         ( {
             bind_var = values;
             bind_mut = false;
             bind_ty = ty_tensor_float_4;
             bind_rhs =
               mk
                 (CVector [ cfloat 1.0; cfloat 2.0; cfloat 3.0; cfloat 4.0 ])
                 ty_tensor_float_4;
           },
           body ))
      ty_float
  in
  match (prepare expr).desc with
  | CLet
      ( _,
        {
          desc =
            CCall
              ( CKIntrinsic "tensor_get_f64_raw_unchecked",
                _,
                [ { desc = CVar read_values; _ }; _ ] );
          _;
        } )
    when Var.equal values read_values ->
      ()
  | _ ->
      Alcotest.fail
        "proven compiler-owned f64 tensor storage should drop layout guard"

let test_resource_scope_binding_clears_tensor_storage_provenance () =
  let values = Var.named "values" in
  let inner_values_ref = mk (CVar values) ty_tensor_float_4 in
  let scoped =
    mk
      (CResourceScope
         {
           rs_var = values;
           rs_ty = ty_test_resource;
           rs_acquire = mk (CVar (Var.named "open_resource")) ty_test_resource;
           rs_body = guarded_f64_tensor_read inner_values_ref (cint 0);
           rs_cleanup = cvoid;
         })
      ty_float
  in
  let expr =
    mk
      (CLet
         ( {
             bind_var = values;
             bind_mut = false;
             bind_ty = ty_tensor_float_4;
             bind_rhs =
               mk
                 (CVector [ cfloat 1.0; cfloat 2.0; cfloat 3.0; cfloat 4.0 ])
                 ty_tensor_float_4;
           },
           scoped ))
      ty_float
  in
  match (prepare expr).desc with
  | CLet
      ( _,
        {
          desc =
            CResourceScope
              {
                rs_body =
                  {
                    desc =
                      CIf
                        ( {
                            desc =
                              CCall (CKIntrinsic "tensor_is_f64_storage", _, _);
                            _;
                          },
                          {
                            desc =
                              CCall
                                ( CKIntrinsic "tensor_get_f64_raw_unchecked",
                                  _,
                                  _ );
                            _;
                          },
                          {
                            desc = CCall (CKIntrinsic "tensor_get_f64", _, _);
                            _;
                          } );
                    _;
                  };
                _;
              };
          _;
        } ) ->
      ()
  | CLet (_, { desc = CResourceScope { rs_body; _ }; _ }) ->
      Alcotest.failf
        "resource scope body incorrectly used outer storage proof: %s"
        (Blorp.Core.pp_to_string rs_body)
  | _ ->
      Alcotest.fail
        "expected prepared let containing resource scope with guarded body"

let test_unproven_tensor_storage_read_keeps_layout_guard () =
  let values = Var.named "values" in
  let values_ref = mk (CVar values) ty_tensor_float_4 in
  match (prepare (guarded_f64_tensor_read values_ref (cint 0))).desc with
  | CIf
      ( { desc = CCall (CKIntrinsic "tensor_is_f64_storage", _, _); _ },
        { desc = CCall (CKIntrinsic "tensor_get_f64_raw_unchecked", _, _); _ },
        { desc = CCall (CKIntrinsic "tensor_get_f64", _, _); _ } ) ->
      ()
  | _ ->
      Alcotest.fail
        "unproven tensor storage should keep runtime layout guard and fallback"

let test_proven_tensor_raw_view_guard_drops_fallback () =
  let values = Var.named "values" in
  let ok = Var.named "__tensor_raw_view_ok" in
  let view = Var.named "__tensor_raw_view_values" in
  let values_ref = mk (CVar values) ty_tensor_float_4 in
  let idx = cint 0 in
  let fast =
    mk
      (CTensorRawViewLet
         ( {
             trv_var = view;
             trv_kind = TensorFloat64Elements;
             trv_source = values_ref;
           },
           mk
             (CTensorRawRead
                {
                  trr_view = view;
                  trr_kind = TensorFloat64Elements;
                  trr_index = idx;
                })
             ty_float ))
      ty_float
  in
  let fallback = guarded_f64_tensor_read values_ref idx in
  let guarded =
    mk
      (CLet
         ( {
             bind_var = ok;
             bind_mut = false;
             bind_ty = ty_bool;
             bind_rhs =
               mk
                 (CCall
                    (CKIntrinsic "tensor_is_f64_storage", cvoid, [ values_ref ]))
                 ty_bool;
           },
           mk (CIf (mk (CVar ok) ty_bool, fast, fallback)) ty_float ))
      ty_float
  in
  let expr =
    mk
      (CLet
         ( {
             bind_var = values;
             bind_mut = false;
             bind_ty = ty_tensor_float_4;
             bind_rhs =
               mk
                 (CVector [ cfloat 1.0; cfloat 2.0; cfloat 3.0; cfloat 4.0 ])
                 ty_tensor_float_4;
           },
           guarded ))
      ty_float
  in
  match (prepare expr).desc with
  | CLet
      ( _,
        {
          desc =
            CTensorRawViewLet
              ( { trv_kind = TensorFloat64Elements; trv_source; _ },
                {
                  desc = CTensorRawRead { trr_kind = TensorFloat64Elements; _ };
                  _;
                } );
          _;
        } )
    when core_var_equal trv_source values ->
      ()
  | _ ->
      Alcotest.fail
        "proven raw-view storage guard should collapse to the fast path"

let test_known_tensor_producer_result_drops_layout_guard () =
  let values = Var.named "values" in
  let values_ref = mk (CVar values) ty_tensor_int_4 in
  let body = guarded_i64_tensor_read values_ref (cint 0) in
  let expr =
    mk
      (CLet
         ( {
             bind_var = values;
             bind_mut = false;
             bind_ty = ty_tensor_int_4;
             bind_rhs =
               mk
                 (CCall
                    ( CKBuiltin "blorp_vector_scalar_add_i64",
                      cvoid,
                      [ mk (CVar (Var.named "input")) ty_tensor_int_4; cint 1 ]
                    ))
                 ty_tensor_int_4;
           },
           body ))
      ty_int
  in
  match (prepare expr).desc with
  | CLet
      ( _,
        {
          desc =
            CCall
              ( CKIntrinsic "tensor_get_i64_raw_unchecked",
                _,
                [ { desc = CVar read_values; _ }; _ ] );
          _;
        } )
    when Var.equal values read_values ->
      ()
  | _ ->
      Alcotest.fail
        "producer with result-type storage should drop a matching layout guard"

let test_preserved_tensor_producer_source_drops_layout_guard () =
  let source = Var.named "source" in
  let values = Var.named "values" in
  let source_ref = mk (CVar source) ty_tensor_float_4 in
  let values_ref = mk (CVar values) ty_tensor_float_4 in
  let body = guarded_f64_tensor_read values_ref (cint 0) in
  let expr =
    mk
      (CLet
         ( {
             bind_var = source;
             bind_mut = false;
             bind_ty = ty_tensor_float_4;
             bind_rhs =
               mk
                 (CVector [ cfloat 1.0; cfloat 2.0; cfloat 3.0; cfloat 4.0 ])
                 ty_tensor_float_4;
           },
           mk
             (CLet
                ( {
                    bind_var = values;
                    bind_mut = false;
                    bind_ty = ty_tensor_float_4;
                    bind_rhs =
                      mk
                        (CCall
                           ( CKBuiltin "blorp_vector_scalar_op_rev_float",
                             cvoid,
                             [ cint 1; source_ref; cfloat 0.0 ] ))
                        ty_tensor_float_4;
                  },
                  body ))
             ty_float ))
      ty_float
  in
  match (prepare expr).desc with
  | CLet
      ( _,
        {
          desc =
            CLet
              ( _,
                {
                  desc =
                    CCall
                      ( CKIntrinsic "tensor_get_f64_raw_unchecked",
                        _,
                        [ { desc = CVar read_values; _ }; _ ] );
                  _;
                } );
          _;
        } )
    when Var.equal values read_values ->
      ()
  | _ ->
      Alcotest.fail
        "producer preserving a proven source layout should drop matching guard"

let test_unproven_preserved_tensor_producer_keeps_layout_guard () =
  let values = Var.named "values" in
  let input = mk (CVar (Var.named "input")) ty_tensor_float_4 in
  let values_ref = mk (CVar values) ty_tensor_float_4 in
  let body = guarded_f64_tensor_read values_ref (cint 0) in
  let expr =
    mk
      (CLet
         ( {
             bind_var = values;
             bind_mut = false;
             bind_ty = ty_tensor_float_4;
             bind_rhs =
               mk
                 (CCall
                    ( CKBuiltin "blorp_vector_scalar_op_rev_float",
                      cvoid,
                      [ cint 1; input; cfloat 0.0 ] ))
                 ty_tensor_float_4;
           },
           body ))
      ty_float
  in
  match (prepare expr).desc with
  | CLet
      ( _,
        {
          desc =
            CIf
              ( { desc = CCall (CKIntrinsic "tensor_is_f64_storage", _, _); _ },
                {
                  desc = CCall (CKIntrinsic "tensor_get_f64_raw_unchecked", _, _);
                  _;
                },
                { desc = CCall (CKIntrinsic "tensor_get_f64", _, _); _ } );
          _;
        } ) ->
      ()
  | _ ->
      Alcotest.fail
        "producer preserving an unproven source layout must keep runtime guard"

let suite =
  [
    ( "prepare",
      [
        Alcotest.test_case "empty_list_record" `Quick
          test_empty_list_record_becomes_list_alloc;
        Alcotest.test_case "empty_list_alias_record" `Quick
          test_empty_list_alias_record_becomes_list_alloc;
        Alcotest.test_case "empty_dict_record" `Quick
          test_empty_dict_record_becomes_dict_alloc;
        Alcotest.test_case "empty_dict_alias_string_key" `Quick
          test_empty_dict_alias_string_key_becomes_string_alloc;
        Alcotest.test_case "empty_dict_alias_enum_key" `Quick
          test_empty_dict_alias_enum_key_stays_generic_alloc;
        Alcotest.test_case "empty_dict_alias_record" `Quick
          test_empty_dict_alias_record_becomes_dict_alloc;
        Alcotest.test_case "empty_set_record" `Quick
          test_empty_set_record_becomes_set_alloc;
        Alcotest.test_case "empty_set_alias_string_elem" `Quick
          test_empty_set_alias_string_elem_becomes_string_alloc;
        Alcotest.test_case "empty_set_alias_record" `Quick
          test_empty_set_alias_record_becomes_set_alloc;
        Alcotest.test_case "vector_literal" `Quick
          test_vector_literal_becomes_tensor_literal;
        Alcotest.test_case "vector_alias_literal_layout" `Quick
          test_vector_alias_literal_uses_expanded_element_layout;
        Alcotest.test_case "bool_vector_literal_packed" `Quick
          test_bool_vector_literal_becomes_packed_tensor_literal;
        Alcotest.test_case "struct_vector_literal_inline" `Quick
          test_struct_vector_literal_becomes_inline_struct_tensor_literal;
        Alcotest.test_case "typed_box_unbox" `Quick
          test_box_unbox_become_typed_nodes;
        Alcotest.test_case "stack_option_box_unbox" `Quick
          test_stack_option_box_unbox_become_struct_nodes;
        Alcotest.test_case "list_get_layout_node" `Quick
          test_list_get_becomes_layout_node;
        Alcotest.test_case "list_get_unchecked_layout_node" `Quick
          test_list_get_unchecked_becomes_proven_layout_node;
        Alcotest.test_case "string_byte_intrinsics_proof_nodes" `Quick
          test_string_byte_intrinsics_become_proof_nodes;
        Alcotest.test_case "proven_tensor_read_drops_layout_guard" `Quick
          test_proven_tensor_storage_read_drops_layout_guard;
        Alcotest.test_case "resource_scope_clears_tensor_storage_provenance"
          `Quick test_resource_scope_binding_clears_tensor_storage_provenance;
        Alcotest.test_case "unproven_tensor_read_keeps_layout_guard" `Quick
          test_unproven_tensor_storage_read_keeps_layout_guard;
        Alcotest.test_case "proven_tensor_raw_view_guard_drops_fallback" `Quick
          test_proven_tensor_raw_view_guard_drops_fallback;
        Alcotest.test_case "known_tensor_producer_result_guard" `Quick
          test_known_tensor_producer_result_drops_layout_guard;
        Alcotest.test_case "preserved_tensor_producer_source_guard" `Quick
          test_preserved_tensor_producer_source_drops_layout_guard;
        Alcotest.test_case "unproven_preserved_tensor_producer_guard" `Quick
          test_unproven_preserved_tensor_producer_keeps_layout_guard;
      ] );
  ]
