(** Unit tests for typed AST compatibility helpers. *)

open Blorp.Ast
open Blorp.Types

let check_true msg b = Alcotest.(check bool) msg true b

let with_type expr ty =
  Blorp.Ast.with_expr_type_info expr (Blorp.Ast.expr_type_info_from_type ty)

let expr_with_type ty =
  with_type
    {
      expr_desc = EIdent "x";
      expr_loc = dummy_loc;
      expr_type = None;
      expr_type_info = None;
      expr_rc = None;
    }
    ty

let expr_with_legacy_type_only ty =
  {
    expr_desc = EIdent "x";
    expr_loc = dummy_loc;
    expr_type = Some ty;
    expr_type_info = None;
    expr_rc = None;
  }

let untyped_expr =
  {
    expr_desc = EIdent "x";
    expr_loc = dummy_loc;
    expr_type = None;
    expr_type_info = None;
    expr_rc = None;
  }

let param ?(ty = Some ty_int) name =
  {
    param_name = Some name;
    param_pattern = None;
    param_type = ty;
    param_loc = dummy_loc;
  }

let func_decl ?(params = [ param "x" ]) ?(return_ty = Some ty_int)
    ?(body = FuncBodyExpr (expr_with_type ty_int)) () =
  {
    func_name = Some "f";
    func_type_params = [];
    func_params = params;
    func_return_type = return_ty;
    func_body = body;
    func_is_pure = true;
    func_is_tailrec = false;
    func_no_copy = false;
    func_debug_only = false;
    func_dim_constraints = [];
  }

let decl desc = { decl_desc = desc; decl_loc = dummy_loc; decl_doc = None }

let test_accepts_finalized_expr () =
  match Blorp.Typed_ast.of_ast_expr (expr_with_type ty_int) with
  | Ok typed ->
      check_true "semantic type retained"
        (types_equal (Blorp.Typed_ast.semantic_type typed) ty_int);
      check_true "ast retained"
        (match (Blorp.Typed_ast.ast typed).expr_desc with
        | EIdent "x" -> true
        | _ -> false)
  | Error _ -> Alcotest.fail "expected finalized typed expr"

let test_rejects_legacy_expr_type_without_info () =
  match
    Blorp.Typed_ast.of_ast_expr ~context:"unit test"
      (expr_with_legacy_type_only ty_int)
  with
  | Error (Blorp.Typed_ast.MissingExprTypeInfo { context; _ }) ->
      Alcotest.(check string) "context retained" "unit test" context
  | Ok _ -> Alcotest.fail "expected missing expr_type_info error"
  | Error _ -> Alcotest.fail "expected missing expr_type_info error"

let test_value_slot_type_info_preserves_widening () =
  let slot = Blorp.Type_widening.mutable_binding_slot (TyConstInt 1) in
  match
    Blorp.Typed_ast.of_ast_expr_with_type_info
      ~semantic_ty:(Blorp.Type_widening.semantic_type slot)
      ~value_ty:(Blorp.Type_widening.value_type slot)
      ~widening:(Blorp.Type_widening.decision slot)
      untyped_expr
  with
  | Ok typed -> (
      let ast = Blorp.Typed_ast.ast typed in
      let info = Blorp.Typed_ast.type_info typed in
      check_true "semantic singleton retained"
        (types_equal (Blorp.Typed_ast.semantic_type typed) (TyConstInt 1));
      check_true "value type widened to Int"
        (types_equal (Blorp.Typed_ast.value_type typed) ty_int);
      (match ast.expr_type with
      | Some ty ->
          check_true "compatibility expr_type is semantic"
            (types_equal ty (TyConstInt 1))
      | None -> Alcotest.fail "expected compatibility expr_type");
      match Blorp.Typed_ast.type_info_widening info with
      | Blorp.Type_widening.Widen { from_ty; to_ty; reason } ->
          check_true "widening source retained"
            (types_equal from_ty (TyConstInt 1));
          check_true "widening target retained" (types_equal to_ty ty_int);
          check_true "widening reason retained"
            (reason = Blorp.Type_widening.MutableBinding)
      | Blorp.Type_widening.Keep _ -> Alcotest.fail "expected widening")
  | Error _ -> Alcotest.fail "expected typed expression from value slot"

let test_expr_prefers_ast_type_info () =
  let expr =
    {
      untyped_expr with
      expr_type = Some (TyConstInt 1);
      expr_type_info =
        Some
          {
            source_ty = None;
            semantic_ty = TyConstInt 1;
            value_ty = ty_int;
            origin = Inferred;
            widening =
              Widen
                {
                  from_ty = TyConstInt 1;
                  to_ty = ty_int;
                  reason = MutableBinding;
                };
            proofs = Blorp.Type_proof_metadata.unproven_expr;
            resolved_call = None;
          };
    }
  in
  match Blorp.Typed_ast.of_ast_expr expr with
  | Ok typed -> (
      let info = Blorp.Typed_ast.type_info typed in
      check_true "semantic type retained"
        (types_equal
           (Blorp.Typed_ast.type_info_semantic_type info)
           (TyConstInt 1));
      check_true "value type retained"
        (types_equal (Blorp.Typed_ast.type_info_value_type info) ty_int);
      match Blorp.Typed_ast.type_info_widening info with
      | Blorp.Type_widening.Widen { from_ty; to_ty; reason } ->
          check_true "widening source retained"
            (types_equal from_ty (TyConstInt 1));
          check_true "widening target retained" (types_equal to_ty ty_int);
          check_true "widening reason retained"
            (reason = Blorp.Type_widening.MutableBinding)
      | Blorp.Type_widening.Keep _ -> Alcotest.fail "expected widening")
  | Error _ -> Alcotest.fail "expected AST-carried type info to validate"

let test_typed_type_info_is_canonical_ast_payload () =
  let slot = Blorp.Type_widening.mutable_binding_slot (TyConstInt 1) in
  match
    Blorp.Typed_ast.of_ast_expr_with_type_info
      ~semantic_ty:(Blorp.Type_widening.semantic_type slot)
      ~value_ty:(Blorp.Type_widening.value_type slot)
      ~widening:(Blorp.Type_widening.decision slot)
      untyped_expr
  with
  | Ok typed ->
      let typed_info =
        Blorp.Typed_ast.type_info_to_ast (Blorp.Typed_ast.type_info typed)
      in
      let ast_info =
        match (Blorp.Typed_ast.ast typed).expr_type_info with
        | Some info -> info
        | None -> Alcotest.fail "expected AST-carried type info"
      in
      check_true "typed info is assignable to canonical AST payload"
        (types_equal typed_info.semantic_ty ast_info.semantic_ty);
      check_true "value type retained"
        (types_equal typed_info.value_ty ast_info.value_ty)
  | Error _ -> Alcotest.fail "expected typed expression from value slot"

let test_expr_call_metadata_accessors () =
  let fn_ty = ty_func [] ty_int ~pure:true in
  let callee = with_type { untyped_expr with expr_desc = EIdent "f" } fn_ty in
  let call =
    with_type { untyped_expr with expr_desc = ECall (callee, []) } ty_int
  in
  let resolved =
    {
      call_syntax = CallBare;
      call_target =
        CallDirect
          {
            callable_id = 42;
            source_name = "f";
            call_pure = true;
            origin = CallableLocal;
          };
      instantiated_params = [];
      instantiated_return = ty_int;
    }
  in
  let call = Blorp.Ast.with_expr_resolved_call call resolved in
  Alcotest.(check (option bool))
    "ast call purity" (Some true)
    (Option.map Blorp.Ast.resolved_call_purity
       (Blorp.Ast.expr_resolved_call call));
  Alcotest.(check (option int))
    "ast concrete callable id" (Some 42)
    (Blorp.Ast.expr_concrete_callable_id call);
  match Blorp.Typed_ast.of_ast_expr call with
  | Ok typed ->
      check_true "resolved call retained"
        (Blorp.Typed_ast.expr_resolved_call typed = Some resolved);
      Alcotest.(check (option bool))
        "call purity" (Some true)
        (Blorp.Typed_ast.expr_call_purity typed);
      Alcotest.(check (option int))
        "direct call id" (Some 42)
        (Blorp.Typed_ast.expr_direct_call_id typed);
      Alcotest.(check (option int))
        "concrete callable id" (Some 42)
        (Blorp.Typed_ast.expr_concrete_callable_id typed)
  | Error _ -> Alcotest.fail "expected typed call expression"

let test_expr_trait_method_concrete_callable_accessor () =
  let fn_ty = ty_func [ ty_bool ] ty_string ~pure:true in
  let callee =
    with_type { untyped_expr with expr_desc = EIdent "to_string" } fn_ty
  in
  let arg =
    with_type { untyped_expr with expr_desc = ELiteral (LitBool true) } ty_bool
  in
  let call =
    with_type
      { untyped_expr with expr_desc = ECall (callee, [ arg ]) }
      ty_string
  in
  let resolved =
    {
      call_syntax = CallQualified "std/bool";
      call_target =
        CallTraitMethod
          {
            trait_name = "Stringable";
            method_name = "to_string";
            call_pure = true;
            callable_id = Some 99;
          };
      instantiated_params = [ ty_bool ];
      instantiated_return = ty_string;
    }
  in
  let call = Blorp.Ast.with_expr_resolved_call call resolved in
  Alcotest.(check (option int))
    "ast concrete callable id includes impl method" (Some 99)
    (Blorp.Ast.expr_concrete_callable_id call);
  match Blorp.Typed_ast.of_ast_expr call with
  | Ok typed ->
      Alcotest.(check (option int))
        "direct-only accessor excludes trait metadata" None
        (Blorp.Typed_ast.expr_direct_call_id typed);
      Alcotest.(check (option int))
        "concrete callable id includes impl method" (Some 99)
        (Blorp.Typed_ast.expr_concrete_callable_id typed)
  | Error _ -> Alcotest.fail "expected typed call expression"

let test_expr_desc_returns_typed_children () =
  let left = expr_with_type (TyConstInt 1) in
  let right = expr_with_type ty_int in
  let expr =
    with_type
      { untyped_expr with expr_desc = EBinary (Add, left, right) }
      ty_int
  in
  match Blorp.Typed_ast.of_ast_expr expr with
  | Error _ -> Alcotest.fail "expected finalized typed expr"
  | Ok typed -> (
      match Blorp.Typed_ast.expr_desc typed with
      | Error _ -> Alcotest.fail "expected typed expression view"
      | Ok (Blorp.Typed_ast.EBinary (Add, typed_left, typed_right)) ->
          check_true "left child is typed"
            (types_equal
               (Blorp.Typed_ast.semantic_type typed_left)
               (TyConstInt 1));
          check_true "right child is typed"
            (types_equal (Blorp.Typed_ast.semantic_type typed_right) ty_int)
      | Ok _ -> Alcotest.fail "expected binary typed view")

let test_rejects_missing_type () =
  match Blorp.Typed_ast.of_ast_expr ~context:"unit test" untyped_expr with
  | Error (Blorp.Typed_ast.MissingExprType { context; _ }) ->
      Alcotest.(check string) "context retained" "unit test" context
  | Ok _ -> Alcotest.fail "expected missing expr_type error"
  | Error _ -> Alcotest.fail "expected missing expr_type error"

let test_rejects_inference_meta () =
  let ty = TyNamed ("List", [ TyMeta 7 ]) in
  match
    Blorp.Typed_ast.of_ast_expr ~context:"unit test" (expr_with_type ty)
  with
  | Error (Blorp.Typed_ast.UnfinalizedExprType { context; ty = reported; _ }) ->
      Alcotest.(check string) "context retained" "unit test" context;
      check_true "reported type retained" (types_equal reported ty)
  | Ok _ -> Alcotest.fail "expected unfinalized expr_type error"
  | Error _ -> Alcotest.fail "expected unfinalized expr_type error"

let test_expr_rejects_untyped_child () =
  let body =
    with_type
      {
        expr_desc = EBinary (Add, expr_with_type ty_int, untyped_expr);
        expr_loc = dummy_loc;
        expr_type = None;
        expr_type_info = None;
        expr_rc = None;
      }
      ty_int
  in
  match Blorp.Typed_ast.of_ast_expr body with
  | Error (Blorp.Typed_ast.MissingExprType _) -> ()
  | Ok _ -> Alcotest.fail "expected missing child expr_type"
  | Error _ -> Alcotest.fail "expected missing expr_type"

let test_expr_rejects_root_lambda_missing_param_type () =
  let func =
    { (func_decl ~params:[ param ~ty:None "x" ] ()) with func_name = None }
  in
  let lambda =
    with_type
      { untyped_expr with expr_desc = ELambda func }
      (TyFunc { params = [ ty_int ]; return = ty_int; is_pure = true })
  in
  match Blorp.Typed_ast.of_ast_expr lambda with
  | Error (Blorp.Typed_ast.MissingRequiredType { context; _ }) ->
      Alcotest.(check string) "context retained" "lambda param" context
  | Ok _ -> Alcotest.fail "expected missing root lambda param type"
  | Error _ -> Alcotest.fail "expected missing required type"

let test_expr_rejects_root_loop_view_meta_element_type () =
  let source = expr_with_type (TyArray (ty_int, [ TyConstInt 4 ])) in
  let loop_view =
    {
      loop_view_kind = LoopEnumerate;
      loop_view_source = source;
      loop_view_size_arg = None;
      loop_view_elem_type = TyTuple [ ty_int; TyMeta 3 ];
    }
  in
  let expr =
    with_type
      { untyped_expr with expr_desc = ELoopView loop_view }
      (TyNamed ("Loop", [ ty_int ]))
  in
  match Blorp.Typed_ast.of_ast_expr expr with
  | Error (Blorp.Typed_ast.UnfinalizedType { context; _ }) ->
      Alcotest.(check string)
        "context retained" "loop view element type" context
  | Ok _ -> Alcotest.fail "expected unfinalized root loop view type"
  | Error _ -> Alcotest.fail "expected unfinalized type"

let test_ast_with_expr_type_info_from_type_sets_legacy_payload () =
  let typed = with_type untyped_expr ty_bool in
  (match typed.expr_type with
  | Some ty -> check_true "type set" (types_equal ty ty_bool)
  | None -> Alcotest.fail "expected expr_type");
  match typed.expr_type_info with
  | Some info -> (
      check_true "semantic type set" (types_equal info.semantic_ty ty_bool);
      check_true "value type set" (types_equal info.value_ty ty_bool);
      match info.widening with
      | Keep ty -> check_true "no-widening payload set" (types_equal ty ty_bool)
      | Widen _ -> Alcotest.fail "did not expect widening")
  | None -> Alcotest.fail "expected expr_type_info"

let test_ast_with_expr_type_info_sets_consistent_payload () =
  let info =
    {
      source_ty = Some (TyNamed ("Int", []));
      semantic_ty = TyConstInt 1;
      value_ty = ty_int;
      origin = ExplicitAnnotation ty_int;
      widening =
        Widen
          { from_ty = TyConstInt 1; to_ty = ty_int; reason = MutableBinding };
      proofs = Blorp.Type_proof_metadata.unproven_expr;
      resolved_call = None;
    }
  in
  let typed = Blorp.Ast.with_expr_type_info untyped_expr info in
  (match typed.expr_type with
  | Some ty ->
      check_true "semantic expr_type set" (types_equal ty (TyConstInt 1))
  | None -> Alcotest.fail "expected expr_type");
  match typed.expr_type_info with
  | Some actual -> (
      check_true "value type retained" (types_equal actual.value_ty ty_int);
      match actual.widening with
      | Widen { from_ty; to_ty; reason = MutableBinding } ->
          check_true "from type retained" (types_equal from_ty (TyConstInt 1));
          check_true "to type retained" (types_equal to_ty ty_int)
      | Keep _ | Widen _ -> Alcotest.fail "expected mutable binding widening")
  | None -> Alcotest.fail "expected expr_type_info"

let test_ast_map_expr_type_payload_maps_all_payload_types () =
  let info =
    {
      source_ty = Some ty_int;
      semantic_ty = TyConstInt 1;
      value_ty = ty_int;
      origin = ExplicitAnnotation ty_int;
      widening =
        Widen
          { from_ty = TyConstInt 1; to_ty = ty_int; reason = MutableBinding };
      proofs = Blorp.Type_proof_metadata.unproven_expr;
      resolved_call = None;
    }
  in
  let typed = Blorp.Ast.with_expr_type_info untyped_expr info in
  let map_ty = function
    | TyConstInt 1 -> TyConstInt 2
    | TyNamed ("Int", []) -> ty_float
    | ty -> ty
  in
  let mapped = Blorp.Ast.map_expr_type_payload map_ty typed in
  let mapped_info =
    match mapped.expr_type_info with
    | Some info -> info
    | None -> Alcotest.fail "expected mapped expr_type_info"
  in
  (match mapped.expr_type with
  | Some ty ->
      check_true "compatibility expr_type mapped"
        (types_equal ty (TyConstInt 2))
  | None -> Alcotest.fail "expected mapped expr_type");
  (match mapped_info.source_ty with
  | Some ty -> check_true "source type mapped" (types_equal ty ty_float)
  | None -> Alcotest.fail "expected mapped source type");
  check_true "semantic type mapped"
    (types_equal mapped_info.semantic_ty (TyConstInt 2));
  check_true "value type mapped" (types_equal mapped_info.value_ty ty_float);
  (match mapped_info.origin with
  | ExplicitAnnotation ty ->
      check_true "origin type mapped" (types_equal ty ty_float)
  | Inferred | Synthesized _ -> Alcotest.fail "expected explicit annotation");
  match mapped_info.widening with
  | Widen { from_ty; to_ty; reason = MutableBinding } ->
      check_true "widening source mapped" (types_equal from_ty (TyConstInt 2));
      check_true "widening target mapped" (types_equal to_ty ty_float)
  | Keep _ | Widen _ -> Alcotest.fail "expected mapped widening"

let test_func_decl_accepts_finalized_boundary () =
  match Blorp.Typed_ast.of_ast_func_decl (func_decl ()) with
  | Ok typed ->
      check_true "function retained"
        (match (Blorp.Typed_ast.func_ast typed).func_name with
        | Some "f" -> true
        | _ -> false)
  | Error _ -> Alcotest.fail "expected finalized function declaration"

let test_func_decl_preserves_inferred_return_separately () =
  let func =
    func_decl ~return_ty:None ~body:(FuncBodyExpr (expr_with_type ty_int)) ()
  in
  match Blorp.Typed_ast.of_ast_func_decl func with
  | Ok typed ->
      check_true "source return annotation remains absent"
        (Option.is_none (Blorp.Typed_ast.func_ast typed).func_return_type);
      check_true "semantic return inferred from body"
        (types_equal (Blorp.Typed_ast.func_semantic_return_type typed) ty_int)
  | Error _ -> Alcotest.fail "expected finalized function declaration"

let test_func_decl_rejects_missing_param_type () =
  let func = func_decl ~params:[ param ~ty:None "x" ] () in
  match Blorp.Typed_ast.of_ast_func_decl func with
  | Error (Blorp.Typed_ast.MissingRequiredType { context; _ }) ->
      Alcotest.(check string) "context retained" "param" context
  | Ok _ -> Alcotest.fail "expected missing param type"
  | Error _ -> Alcotest.fail "expected missing required type"

let test_func_decl_rejects_meta_return_type () =
  let ty = TyNamed ("Option", [ TyMeta 1 ]) in
  let func = func_decl ~return_ty:(Some ty) () in
  match Blorp.Typed_ast.of_ast_func_decl func with
  | Error (Blorp.Typed_ast.UnfinalizedType { context; ty = reported; _ }) ->
      Alcotest.(check string) "context retained" "function return type" context;
      check_true "reported return type retained" (types_equal reported ty)
  | Ok _ -> Alcotest.fail "expected unfinalized return type"
  | Error _ -> Alcotest.fail "expected unfinalized type"

let test_func_decl_rejects_untyped_body_child () =
  let body =
    with_type
      {
        expr_desc = EBinary (Add, expr_with_type ty_int, untyped_expr);
        expr_loc = dummy_loc;
        expr_type = None;
        expr_type_info = None;
        expr_rc = None;
      }
      ty_int
  in
  match
    Blorp.Typed_ast.of_ast_func_decl (func_decl ~body:(FuncBodyExpr body) ())
  with
  | Error (Blorp.Typed_ast.MissingExprType _) -> ()
  | Ok _ -> Alcotest.fail "expected missing child expr_type"
  | Error _ -> Alcotest.fail "expected missing expr_type"

let test_var_decl_preserves_inferred_binding_type () =
  let slot = Blorp.Type_widening.mutable_binding_slot (TyConstInt 1) in
  let value =
    Blorp.Ast.with_expr_type_info
      { untyped_expr with expr_desc = ELiteral (LitInt 1L) }
      {
        source_ty = None;
        semantic_ty = Blorp.Type_widening.semantic_type slot;
        value_ty = Blorp.Type_widening.value_type slot;
        origin = Inferred;
        widening = Blorp.Type_widening.decision slot;
        proofs = Blorp.Type_proof_metadata.unproven_expr;
        resolved_call = None;
      }
  in
  let var =
    {
      var_name = Some "total";
      var_pattern = None;
      var_type = None;
      var_value = value;
      var_is_mutable = true;
      var_is_const = false;
    }
  in
  match Blorp.Typed_ast.of_ast_var_decl var with
  | Ok typed ->
      check_true "source binding annotation remains absent"
        (Option.is_none (Blorp.Typed_ast.var_info typed).source_binding_ty);
      check_true "binding type uses value slot"
        (types_equal (Blorp.Typed_ast.var_binding_type typed) ty_int)
  | Error _ -> Alcotest.fail "expected finalized variable declaration"

let test_impl_decl_exposes_typed_methods () =
  let method_func =
    func_decl
      ~params:[ param "self" ]
      ~return_ty:None
      ~body:(FuncBodyExpr (expr_with_type ty_string))
      ()
  in
  let impl =
    {
      impl_trait = "Show";
      impl_for_type = ty_int;
      impl_methods = [ method_func ];
    }
  in
  match Blorp.Typed_ast.of_ast_decl (decl (DImpl impl)) with
  | Ok typed -> (
      match Blorp.Typed_ast.decl_view typed with
      | Blorp.Typed_ast.DeclImpl typed_impl -> (
          match Blorp.Typed_ast.impl_methods typed_impl with
          | [ typed_method ] ->
              check_true "method semantic return retained"
                (types_equal
                   (Blorp.Typed_ast.func_semantic_return_type typed_method)
                   ty_string)
          | _ -> Alcotest.fail "expected one typed impl method")
      | _ -> Alcotest.fail "expected typed impl declaration")
  | Error _ -> Alcotest.fail "expected finalized impl declaration"

let test_decl_rejects_meta_global_annotation () =
  let ty = TyNamed ("List", [ TyMeta 2 ]) in
  let var =
    {
      var_name = Some "xs";
      var_pattern = None;
      var_type = Some ty;
      var_value = expr_with_type (TyNamed ("List", [ ty_int ]));
      var_is_mutable = false;
      var_is_const = false;
    }
  in
  match Blorp.Typed_ast.of_ast_decl (decl (DVar var)) with
  | Error (Blorp.Typed_ast.UnfinalizedType { context; ty = reported; _ }) ->
      Alcotest.(check string)
        "context retained" "global variable annotation" context;
      check_true "reported annotation retained" (types_equal reported ty)
  | Ok _ -> Alcotest.fail "expected unfinalized global annotation"
  | Error _ -> Alcotest.fail "expected unfinalized type"

let test_expr_rejects_meta_loop_view_element_type () =
  let source = expr_with_type (TyArray (ty_int, [ TyConstInt 4 ])) in
  let loop_view =
    {
      loop_view_kind = LoopEnumerate;
      loop_view_source = source;
      loop_view_size_arg = None;
      loop_view_elem_type = TyTuple [ ty_int; TyMeta 3 ];
    }
  in
  let body =
    with_type
      {
        expr_desc = ELoopView loop_view;
        expr_loc = dummy_loc;
        expr_type = None;
        expr_type_info = None;
        expr_rc = None;
      }
      (TyNamed ("Loop", [ ty_int ]))
  in
  match
    Blorp.Typed_ast.of_ast_func_decl (func_decl ~body:(FuncBodyExpr body) ())
  with
  | Error (Blorp.Typed_ast.UnfinalizedType { context; _ }) ->
      Alcotest.(check string)
        "context retained" "loop view element type" context
  | Ok _ -> Alcotest.fail "expected unfinalized loop view type"
  | Error _ -> Alcotest.fail "expected unfinalized type"

let test_program_accepts_finalized_decls () =
  let ast_program = [ decl (DFunc (func_decl ())) ] in
  match Blorp.Typed_ast.of_ast_program ast_program with
  | Ok typed -> (
      let typed_decls = Blorp.Typed_ast.program_decls typed in
      Alcotest.(check int) "decl count" 1 (List.length typed_decls);
      Alcotest.(check int)
        "ast retained" 1
        (List.length (Blorp.Typed_ast.program_ast typed));
      match typed_decls with
      | [ typed_decl ] -> (
          match Blorp.Typed_ast.decl_func typed_decl with
          | Some typed_func ->
              check_true "function return metadata retained"
                (types_equal
                   (Blorp.Typed_ast.func_semantic_return_type typed_func)
                   ty_int)
          | None -> Alcotest.fail "expected typed function metadata")
      | _ -> Alcotest.fail "expected one typed declaration")
  | Error _ -> Alcotest.fail "expected finalized typed program"

let test_program_rejects_untyped_decl_child () =
  let var =
    {
      var_name = Some "x";
      var_pattern = None;
      var_type = Some ty_int;
      var_value = untyped_expr;
      var_is_mutable = false;
      var_is_const = false;
    }
  in
  match Blorp.Typed_ast.of_ast_program [ decl (DVar var) ] with
  | Error (Blorp.Typed_ast.MissingExprType _) -> ()
  | Ok _ -> Alcotest.fail "expected missing expr_type"
  | Error _ -> Alcotest.fail "expected missing expr_type"

let suite =
  [
    ( "expr",
      [
        Alcotest.test_case "accepts finalized expr" `Quick
          test_accepts_finalized_expr;
        Alcotest.test_case "rejects legacy expr_type without info" `Quick
          test_rejects_legacy_expr_type_without_info;
        Alcotest.test_case "value slot preserves widening info" `Quick
          test_value_slot_type_info_preserves_widening;
        Alcotest.test_case "prefers AST-carried type info" `Quick
          test_expr_prefers_ast_type_info;
        Alcotest.test_case "type info is canonical AST payload" `Quick
          test_typed_type_info_is_canonical_ast_payload;
        Alcotest.test_case "call metadata accessors" `Quick
          test_expr_call_metadata_accessors;
        Alcotest.test_case "trait method concrete callable accessor" `Quick
          test_expr_trait_method_concrete_callable_accessor;
        Alcotest.test_case "expr view returns typed children" `Quick
          test_expr_desc_returns_typed_children;
        Alcotest.test_case "rejects missing type" `Quick
          test_rejects_missing_type;
        Alcotest.test_case "rejects inference meta" `Quick
          test_rejects_inference_meta;
        Alcotest.test_case "rejects untyped child" `Quick
          test_expr_rejects_untyped_child;
        Alcotest.test_case "rejects root lambda missing param type" `Quick
          test_expr_rejects_root_lambda_missing_param_type;
        Alcotest.test_case "rejects root loop view meta element type" `Quick
          test_expr_rejects_root_loop_view_meta_element_type;
        Alcotest.test_case "Ast.expr_type_info_from_type sets legacy payload"
          `Quick test_ast_with_expr_type_info_from_type_sets_legacy_payload;
        Alcotest.test_case "Ast.with_expr_type_info sets consistent payload"
          `Quick test_ast_with_expr_type_info_sets_consistent_payload;
        Alcotest.test_case "Ast.map_expr_type_payload maps payload types" `Quick
          test_ast_map_expr_type_payload_maps_all_payload_types;
      ] );
    ( "decl",
      [
        Alcotest.test_case "accepts finalized function declaration" `Quick
          test_func_decl_accepts_finalized_boundary;
        Alcotest.test_case "preserves inferred return separately" `Quick
          test_func_decl_preserves_inferred_return_separately;
        Alcotest.test_case "rejects missing param type" `Quick
          test_func_decl_rejects_missing_param_type;
        Alcotest.test_case "rejects meta return type" `Quick
          test_func_decl_rejects_meta_return_type;
        Alcotest.test_case "rejects untyped body child" `Quick
          test_func_decl_rejects_untyped_body_child;
        Alcotest.test_case "preserves var binding type separately" `Quick
          test_var_decl_preserves_inferred_binding_type;
        Alcotest.test_case "impl exposes typed methods" `Quick
          test_impl_decl_exposes_typed_methods;
        Alcotest.test_case "rejects meta global annotation" `Quick
          test_decl_rejects_meta_global_annotation;
        Alcotest.test_case "rejects meta loop view element type" `Quick
          test_expr_rejects_meta_loop_view_element_type;
      ] );
    ( "program",
      [
        Alcotest.test_case "accepts finalized declarations" `Quick
          test_program_accepts_finalized_decls;
        Alcotest.test_case "rejects untyped declaration child" `Quick
          test_program_rejects_untyped_decl_child;
      ] );
  ]
