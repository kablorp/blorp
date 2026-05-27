(** Unit tests for LSP protocol helpers. *)

open Blorp

let test_file_uri_round_trips_reserved_path_chars () =
  let path = "/tmp/blorp space/#file%.brp" in
  let uri = Lsp_protocol.path_to_uri path in
  Alcotest.(check string)
    "encoded URI" "file:///tmp/blorp%20space/%23file%25.brp" uri;
  Alcotest.(check string) "decoded path" path (Lsp_protocol.uri_to_path uri)

let test_file_uri_decodes_localhost_authority () =
  Alcotest.(check string)
    "localhost authority decodes to a local absolute path"
    "/tmp/blorp space.brp"
    (Lsp_protocol.uri_to_path "file://localhost/tmp/blorp%20space.brp")

let test_loc_to_range_uses_source_span () =
  let loc : Ast.loc =
    { line = 3; column = 5; end_line = 3; end_column = 9; loc_file = None }
  in
  let range = Lsp_protocol.loc_to_range loc in
  Alcotest.(check int) "start line" 2 range.start.line;
  Alcotest.(check int) "start character" 4 range.start.character;
  Alcotest.(check int) "end line" 2 range.end_.line;
  Alcotest.(check int) "end character" 8 range.end_.character

let test_loc_to_range_expands_empty_span () =
  let loc : Ast.loc =
    { line = 1; column = 1; end_line = 1; end_column = 1; loc_file = None }
  in
  let range = Lsp_protocol.loc_to_range loc in
  Alcotest.(check int) "start character" 0 range.start.character;
  Alcotest.(check int) "end character" 1 range.end_.character

let suite =
  [
    ( "protocol",
      [
        Alcotest.test_case "file URI round-trips reserved path characters"
          `Quick test_file_uri_round_trips_reserved_path_chars;
        Alcotest.test_case "file URI decodes localhost authority" `Quick
          test_file_uri_decodes_localhost_authority;
        Alcotest.test_case "loc_to_range uses source span" `Quick
          test_loc_to_range_uses_source_span;
        Alcotest.test_case "loc_to_range expands empty span" `Quick
          test_loc_to_range_expands_empty_span;
      ] );
  ]
