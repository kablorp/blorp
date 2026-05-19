(** Unit tests for the OCaml formatter layout engine.

    These intentionally mirror [tests/test_blorp/tools/test_document_layout.brp] so
    the OCaml and Blorp layout implementations stay pinned to the same visible
    behavior while the formatter is split across phases. *)

module Doc = Blorp.Fmt_doc
module DocJson = Blorp.Fmt_doc_json
module Layout = Blorp.Fmt_layout

let ( ^^ ) = Doc.( ^^ )
let check_string msg = Alcotest.(check string) msg

let call_doc =
  Doc.group
    (Doc.text "call("
    ^^ Doc.indent
         (Doc.softline ^^ Doc.text "one," ^^ Doc.softline_space
        ^^ Doc.text "two")
    ^^ Doc.softline ^^ Doc.text ")")

let test_group_stays_flat_when_it_fits () =
  let doc =
    Doc.group (Doc.text "abc" ^^ Doc.softline_space ^^ Doc.text "def")
  in
  check_string "flat group" "abc def\n" (Layout.layout ~width:100 doc)

let test_group_breaks_with_indent_when_too_wide () =
  check_string "broken group" "call(\n\tone,\n\ttwo\n)\n"
    (Layout.layout ~width:8 call_doc)

let test_if_break_adds_trailing_comma_only_when_broken () =
  let body = Doc.comma_sep_break [ Doc.text "alpha"; Doc.text "beta" ] in
  let doc =
    Doc.group
      (Doc.text "["
      ^^ Doc.indent (Doc.softline ^^ body)
      ^^ Doc.softline ^^ Doc.text "]")
  in
  check_string "flat comma" "[alpha, beta]\n" (Layout.layout ~width:100 doc);
  check_string "broken trailing comma" "[\n\talpha,\n\tbeta,\n]\n"
    (Layout.layout ~width:8 doc)

let test_line_suffix_flushes_before_newline () =
  let doc =
    Doc.text "x" ^^ Doc.line_suffix "-- comment" ^^ Doc.hardline ^^ Doc.text "y"
  in
  check_string "line suffix" "x -- comment\ny\n" (Layout.layout ~width:100 doc)

let test_post_process_trims_and_collapses_blank_lines () =
  check_string "post process" "a\n\n\nb\n"
    (Layout.post_process "a  \n\n\n\nb\t\n\n")

let test_empty_document_stays_empty () =
  check_string "empty layout" "" (Layout.layout ~width:100 Doc.Nil);
  check_string "blank post process" "" (Layout.post_process "\n\n")

let test_doc_json_serializes_layout_boundary () =
  let doc =
    Doc.group (Doc.text "abc" ^^ Doc.softline_space ^^ Doc.text "def")
  in
  check_string "doc json"
    "{\"tag\":\"Group\",\"doc\":{\"tag\":\"Concat\",\"left\":{\"tag\":\"Text\",\"text\":\"abc\"},\"right\":{\"tag\":\"Concat\",\"left\":{\"tag\":\"SoftlineSpace\"},\"right\":{\"tag\":\"Text\",\"text\":\"def\"}}}}"
    (DocJson.to_json doc)

let test_doc_json_escapes_utf8_as_codepoints () =
  let text = "dash \226\128\148 grin \240\159\152\128" in
  check_string "doc json unicode escapes"
    "{\"tag\":\"Text\",\"text\":\"dash \\u2014 grin \\ud83d\\ude00\"}"
    (DocJson.to_json (Doc.text text))

let suite =
  [
    ( "layout",
      [
        Alcotest.test_case "group stays flat when it fits" `Quick
          test_group_stays_flat_when_it_fits;
        Alcotest.test_case "group breaks with indent when too wide" `Quick
          test_group_breaks_with_indent_when_too_wide;
        Alcotest.test_case "IfBreak adds trailing comma only when broken" `Quick
          test_if_break_adds_trailing_comma_only_when_broken;
        Alcotest.test_case "line suffix flushes before newline" `Quick
          test_line_suffix_flushes_before_newline;
        Alcotest.test_case "post process trims and collapses blank lines" `Quick
          test_post_process_trims_and_collapses_blank_lines;
        Alcotest.test_case "empty document stays empty" `Quick
          test_empty_document_stays_empty;
        Alcotest.test_case "Doc JSON serializes layout boundary" `Quick
          test_doc_json_serializes_layout_boundary;
        Alcotest.test_case "Doc JSON escapes UTF-8 as codepoints" `Quick
          test_doc_json_escapes_utf8_as_codepoints;
      ] );
  ]
