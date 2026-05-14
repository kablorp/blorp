(** Unit tests for LSP diagnostic formatting. *)

open Blorp

let diagnostic_message = function
  | Lsp_json.Object fields -> (
      match List.assoc_opt "message" fields with
      | Some (String message) -> message
      | _ -> Alcotest.fail "diagnostic is missing message")
  | _ -> Alcotest.fail "expected diagnostic object"

let int_field name fields =
  match List.assoc_opt name fields with
  | Some (Lsp_json.Int value) -> value
  | _ -> Alcotest.fail ("missing int field: " ^ name)

let position_field name fields =
  match List.assoc_opt name fields with
  | Some (Lsp_json.Object position) ->
      (int_field "line" position, int_field "character" position)
  | _ -> Alcotest.fail ("missing position field: " ^ name)

let diagnostic_range = function
  | Lsp_json.Object fields -> (
      match List.assoc_opt "range" fields with
      | Some (Object range) ->
          (position_field "start" range, position_field "end" range)
      | _ -> Alcotest.fail "diagnostic is missing range")
  | _ -> Alcotest.fail "expected diagnostic object"

let test_lsp_diagnostic_preserves_notes_and_help () =
  let err : Ast.compiler_error =
    {
      message = "Argument type mismatch";
      loc = Ast.dummy_loc;
      phase = TypeCheck;
      kind = OtherError;
      notes = [ "expected Int, got String" ];
      help = Some "Use an explicit conversion before calling the function";
    }
  in
  let message =
    diagnostic_message (Lsp_protocol.compiler_error_to_diagnostic err)
  in
  Alcotest.(check bool)
    "note is included" true
    (Modules.contains message "note: expected Int, got String");
  Alcotest.(check bool)
    "help is included" true
    (Modules.contains message
       "help: Use an explicit conversion before calling the function")

let test_lsp_diagnostic_uses_full_source_span () =
  let loc : Ast.loc =
    {
      line = 3;
      column = 5;
      end_line = 3;
      end_column = 14;
      loc_file = Some "sample.brp";
    }
  in
  let err : Ast.compiler_error =
    {
      message = "Type mismatch";
      loc;
      phase = TypeCheck;
      kind = OtherError;
      notes = [];
      help = None;
    }
  in
  let start_pos, end_pos =
    diagnostic_range (Lsp_protocol.compiler_error_to_diagnostic err)
  in
  Alcotest.(check (pair int int)) "start position" (2, 4) start_pos;
  Alcotest.(check (pair int int)) "end position" (2, 13) end_pos

let suite =
  [
    ( "format",
      [
        Alcotest.test_case "preserves notes and help" `Quick
          test_lsp_diagnostic_preserves_notes_and_help;
        Alcotest.test_case "uses full source span" `Quick
          test_lsp_diagnostic_uses_full_source_span;
      ] );
  ]
