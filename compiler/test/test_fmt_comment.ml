(** Unit tests for formatter comment cursor behavior.

    Formatter integration tests cover rendered output. These tests pin the
    lower-level cursor contract so local refactors in [Fmt_comment] do not
    accidentally change how leading/trailing comments are consumed. *)

module Comment = Blorp.Fmt_comment

let comment ?(trailing = false) line text : Blorp.Lexer.collected_comment =
  { cc_text = text; cc_line = line; cc_col = 0; cc_trailing = trailing }

let comment_texts comments = List.map (fun c -> c.Blorp.Lexer.cc_text) comments

let check_texts msg expected comments =
  Alcotest.(check (list string)) msg expected (comment_texts comments)

let check_comment_opt msg expected actual =
  Alcotest.(check (option string))
    msg expected
    (Option.map (fun c -> c.Blorp.Lexer.cc_text) actual)

let test_take_leading_consumes_prefix_before_line () =
  let store =
    Comment.create
      [
        comment 1 "-- leading";
        comment ~trailing:true 2 "-- orphan trailing";
        comment 4 "-- next";
      ]
  in
  check_texts "leading prefix"
    [ "-- leading"; "-- orphan trailing" ]
    (Comment.take_leading store ~before_line:4);
  check_comment_opt "remaining trailing same line is not leading" None
    (Comment.take_trailing store ~on_line:4);
  check_texts "remaining leading can be consumed later" [ "-- next" ]
    (Comment.take_leading store ~before_line:5)

let test_take_trailing_variants_consume_only_matching_head () =
  let store =
    Comment.create
      [
        comment ~trailing:true 3 "-- line 3";
        comment ~trailing:true 5 "-- line 5";
        comment 6 "-- leading";
      ]
  in
  check_comment_opt "wrong line stays queued" None
    (Comment.take_trailing store ~on_line:4);
  check_comment_opt "exact line consumed" (Some "-- line 3")
    (Comment.take_trailing store ~on_line:3);
  check_comment_opt "before line consumes next trailing" (Some "-- line 5")
    (Comment.take_trailing_before store ~before_line:6);
  check_comment_opt "leading head is not trailing" None
    (Comment.take_next_trailing store);
  check_texts "leading head remains queued" [ "-- leading" ]
    (Comment.take_leading store ~before_line:7)

let test_comment_text_is_preserved_verbatim () =
  Alcotest.(check string)
    "comment text" "  -- keep spacing"
    (Comment.comment_text "  -- keep spacing")

let suite =
  [
    ( "cursor",
      [
        Alcotest.test_case "leading consumes prefix before line" `Quick
          test_take_leading_consumes_prefix_before_line;
        Alcotest.test_case "trailing variants consume matching head" `Quick
          test_take_trailing_variants_consume_only_matching_head;
        Alcotest.test_case "comment text is preserved" `Quick
          test_comment_text_is_preserved_verbatim;
      ] );
  ]
