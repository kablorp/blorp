(** Unit tests for shared type metadata formatting. *)

open Blorp

let source_alias_info : Ast.expr_type_info =
  {
    source_ty = Some (TyNamed ("UserId", []));
    semantic_ty = Types.ty_int;
    value_ty = Types.ty_int;
    origin = ExplicitAnnotation (TyNamed ("UserId", []));
    widening = Keep Types.ty_int;
    proofs = Type_proof_metadata.unproven_expr;
    resolved_call = None;
  }

let widened_literal_info : Ast.expr_type_info =
  {
    source_ty = None;
    semantic_ty = TyConstInt 1;
    value_ty = Types.ty_int;
    origin = Inferred;
    widening =
      Widen
        {
          from_ty = TyConstInt 1;
          to_ty = Types.ty_int;
          reason = MutableBinding;
        };
    proofs = Type_proof_metadata.unproven_expr;
    resolved_call = None;
  }

let detailed_hover_info : Ast.expr_type_info =
  {
    source_ty = Some (TyNamed ("TinyId", []));
    semantic_ty = TyConstInt 1;
    value_ty = Types.ty_int;
    origin = ExplicitAnnotation (TyNamed ("TinyId", []));
    widening =
      Widen
        { from_ty = TyConstInt 1; to_ty = Types.ty_int; reason = ArgumentSlot };
    proofs = Type_proof_metadata.unproven_expr;
    resolved_call = None;
  }

let test_debug_type_info_uses_shared_wording () =
  let rendered =
    Type_metadata_format.format_debug_type_info source_alias_info
  in
  Alcotest.(check string)
    "debug type metadata"
    "source type: UserId; semantic type: Int; value-slot type: Int; origin: \
     explicit annotation (UserId); widening: none (kept Int)"
    rendered

let test_hover_type_view_prefers_source_and_reports_canonical () =
  let view = Type_metadata_format.hover_type_view source_alias_info in
  Alcotest.(check string) "primary source type" "UserId" view.primary_type;
  Alcotest.(check (list string))
    "canonical detail" [ "canonical type: Int" ] view.details

let test_hover_type_view_reports_widening_details () =
  let view = Type_metadata_format.hover_type_view widened_literal_info in
  Alcotest.(check string) "primary semantic type" "#1" view.primary_type;
  Alcotest.(check (list string))
    "widening detail"
    [ "value-slot type: Int"; "widening: mutable binding (#1 -> Int)" ]
    view.details

let test_hover_type_view_preserves_detail_order () =
  let view = Type_metadata_format.hover_type_view detailed_hover_info in
  Alcotest.(check string) "primary source type" "TinyId" view.primary_type;
  Alcotest.(check (list string))
    "detail order"
    [
      "canonical type: #1";
      "value-slot type: Int";
      "widening: argument slot (#1 -> Int)";
    ]
    view.details

let test_expr_hover_type_view_uses_metadata_before_fallback () =
  let expr =
    Ast.with_expr_type_info
      (Ast.untyped_expr ~loc:Ast.dummy_loc (ELiteral (LitInt 1L)))
      source_alias_info
  in
  match
    Type_metadata_format.hover_type_view_for_expr ~fallback_ty:Types.ty_string
      expr
  with
  | Some view ->
      Alcotest.(check string) "metadata primary type" "UserId" view.primary_type;
      Alcotest.(check (list string))
        "metadata details" [ "canonical type: Int" ] view.details
  | None -> Alcotest.fail "expected hover view from expression metadata"

let test_expr_hover_type_view_uses_fallback_without_metadata () =
  let expr =
    Ast.untyped_expr ~loc:Ast.dummy_loc
      (ELiteral (LitString ("value", { sf_triple = false; sf_raw = false })))
  in
  match
    Type_metadata_format.hover_type_view_for_expr ~fallback_ty:Types.ty_string
      expr
  with
  | Some view ->
      Alcotest.(check string) "fallback primary type" "String" view.primary_type;
      Alcotest.(check (list string)) "fallback has no details" [] view.details
  | None -> Alcotest.fail "expected fallback hover view"

let suite =
  [
    ( "format",
      [
        Alcotest.test_case "debug type info wording" `Quick
          test_debug_type_info_uses_shared_wording;
        Alcotest.test_case "hover source and canonical wording" `Quick
          test_hover_type_view_prefers_source_and_reports_canonical;
        Alcotest.test_case "hover widening wording" `Quick
          test_hover_type_view_reports_widening_details;
        Alcotest.test_case "hover detail order" `Quick
          test_hover_type_view_preserves_detail_order;
        Alcotest.test_case "expr hover metadata before fallback" `Quick
          test_expr_hover_type_view_uses_metadata_before_fallback;
        Alcotest.test_case "expr hover fallback" `Quick
          test_expr_hover_type_view_uses_fallback_without_metadata;
      ] );
  ]
