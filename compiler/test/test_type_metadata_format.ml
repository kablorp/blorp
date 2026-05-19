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
      ] );
  ]
