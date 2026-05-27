(** Unit tests for Rust-style diagnostic rendering. *)

module Ast = Blorp.Ast
module Diagnostics = Blorp.Diagnostics

let with_temp_source contents f =
  let path = Filename.temp_file "blorp-diagnostic" ".brp" in
  let oc = open_out path in
  Fun.protect
    ~finally:(fun () ->
      close_out_noerr oc;
      Sys.remove path)
    (fun () ->
      output_string oc contents;
      close_out oc;
      f path)

let check_string msg = Alcotest.(check string) msg

let test_format_error_prefers_location_file_and_keeps_tabs () =
  with_temp_source "first\n\tvalue = 1\nlast\n" (fun source_path ->
      let loc =
        {
          Ast.line = 2;
          column = 2;
          end_line = 2;
          end_column = 7;
          loc_file = Some source_path;
        }
      in
      let err =
        {
          Ast.message = "bad value";
          loc;
          phase = Ast.TypeCheck;
          kind = Ast.OtherError;
          notes = [ "expected Int" ];
          help = Some "use an integer expression";
        }
      in
      let expected =
        Printf.sprintf
          "error: bad value\n\
          \  --> %s:2:2\n\
          \   |\n\
          \ 2 | \tvalue = 1\n\
          \   |\t^^^^^\n\
          \   |\n\
          \   = note: expected Int\n\
          \   = help: use an integer expression"
          source_path
      in
      check_string "rendered diagnostic" expected
        (Diagnostics.format_error ~file:"fallback.brp" err))

let test_render_diagnostic_multiline_message_and_missing_source () =
  let loc =
    { Ast.line = 0; column = 0; end_line = 0; end_column = 0; loc_file = None }
  in
  let actual =
    Diagnostics.format_diagnostic ~file:"synthetic.brp" ~loc
      ~severity:Diagnostics.Warning ~message:"first line\nsecond line"
  in
  check_string "synthetic diagnostic"
    "warning: first line\n    second line\n  --> synthetic.brp\n" actual

let suite =
  [
    ( "render",
      [
        Alcotest.test_case "format_error uses loc file and tab padding" `Quick
          test_format_error_prefers_location_file_and_keeps_tabs;
        Alcotest.test_case "format_diagnostic handles synthetic loc" `Quick
          test_render_diagnostic_multiline_message_and_missing_source;
      ] );
  ]
