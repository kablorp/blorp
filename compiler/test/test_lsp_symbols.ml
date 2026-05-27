(** Unit tests for LSP document symbol helpers. *)

open Blorp

let int_field name fields =
  match List.assoc_opt name fields with
  | Some (Lsp_json.Int value) -> value
  | _ -> Alcotest.fail ("missing int field: " ^ name)

let position_field name fields =
  match List.assoc_opt name fields with
  | Some (Lsp_json.Object position) ->
      (int_field "line" position, int_field "character" position)
  | _ -> Alcotest.fail ("missing position field: " ^ name)

let range_positions = function
  | Lsp_json.Object fields ->
      (position_field "start" fields, position_field "end" fields)
  | _ -> Alcotest.fail "expected range object"

let loc ?(end_line = 3) ?(end_column = 14) () : Ast.loc =
  { line = 3; column = 5; end_line; end_column; loc_file = None }

let test_symbol_range_matches_protocol_location_range () =
  let start_pos, end_pos =
    range_positions (Lsp_symbols.loc_to_range (loc ()))
  in
  Alcotest.(check (pair int int)) "start position" (2, 4) start_pos;
  Alcotest.(check (pair int int)) "end position" (2, 13) end_pos

let test_selection_range_covers_name () =
  let start_pos, end_pos =
    range_positions (Lsp_symbols.selection_range (loc ()) 6)
  in
  Alcotest.(check (pair int int)) "start position" (2, 4) start_pos;
  Alcotest.(check (pair int int)) "end position" (2, 10) end_pos

let suite =
  [
    ( "symbols",
      [
        Alcotest.test_case "range matches protocol location range" `Quick
          test_symbol_range_matches_protocol_location_range;
        Alcotest.test_case "selection range covers name" `Quick
          test_selection_range_covers_name;
      ] );
  ]
