(** Unit tests for the minimal LSP JSON parser/emitter. *)

open Blorp

let test_parse_object_accessors () =
  let json =
    Lsp_json.parse {|{"name":"blorp","count":2,"items":[true,false]}|}
  in
  Alcotest.(check (option string))
    "string field" (Some "blorp")
    (Lsp_json.get_string "name" json);
  Alcotest.(check (option int))
    "int field" (Some 2)
    (Lsp_json.get_int "count" json);
  Alcotest.(check (option int))
    "array length" (Some 2)
    (Option.map List.length (Lsp_json.get_list "items" json))

let test_to_string_escapes_control_chars () =
  Alcotest.(check string)
    "escaped string" {|"a\n\t\"\\b"|}
    (Lsp_json.to_string (Lsp_json.String "a\n\t\"\\b"))

let test_parse_rejects_trailing_input () =
  Alcotest.check_raises "trailing input"
    (Lsp_json.Parse_error "unexpected trailing input at position 5") (fun () ->
      ignore (Lsp_json.parse "true false"))

let test_parse_rejects_raw_control_chars_in_strings () =
  match Lsp_json.parse "\"line\nbreak\"" with
  | _ -> Alcotest.fail "expected raw newline in JSON string to be rejected"
  | exception Lsp_json.Parse_error msg ->
      Alcotest.(check string)
        "parse error" "unescaped control character in string at position 6" msg
  | exception exn ->
      Alcotest.failf "expected Parse_error, got %s" (Printexc.to_string exn)

let suite =
  [
    ( "json",
      [
        Alcotest.test_case "parse object accessors" `Quick
          test_parse_object_accessors;
        Alcotest.test_case "to_string escapes control characters" `Quick
          test_to_string_escapes_control_chars;
        Alcotest.test_case "parse rejects trailing input" `Quick
          test_parse_rejects_trailing_input;
        Alcotest.test_case "parse rejects raw control chars in strings" `Quick
          test_parse_rejects_raw_control_chars_in_strings;
      ] );
  ]
