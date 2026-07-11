(** Unit tests for typed-AST debug formatting. *)

open Test_helpers

let typed_program_of_source source =
  with_isolated_env (fun () ->
      let sess = Blorp.Session.create () in
      match
        Blorp.Pipeline.typecheck_only_typed_reusing_session ~sess
          ~filename:"typed_ast_debug_test.brp" ~source ()
      with
      | Ok typed -> typed
      | Error errors ->
          Alcotest.fail
            ("expected successful typecheck, got:\n" ^ format_errors errors))

let test_debug_dump_exposes_widening_metadata () =
  let typed =
    typed_program_of_source
      {|
func main(args: List[String]) -> Int:
    var total = 1
    total
|}
  in
  let dump = Blorp.Typed_ast_debug.format_program typed in
  Alcotest.(check bool)
    "function included" true
    (contains_substring dump "func main");
  Alcotest.(check bool)
    "semantic type included" true
    (contains_substring dump "semantic type: #1");
  Alcotest.(check bool)
    "value type included" true
    (contains_substring dump "value-slot type: Int");
  Alcotest.(check bool)
    "source absence included" true
    (contains_substring dump "source type: <none>");
  Alcotest.(check bool)
    "widening reason included" true
    (contains_substring dump "widening: mutable binding (#1 -> Int)")

let test_debug_dump_exposes_source_annotation_metadata () =
  let typed =
    typed_program_of_source
      {|
func main(args: List[String]) -> Int:
    total = 1 as Int32
    0
|}
  in
  let dump = Blorp.Typed_ast_debug.format_program typed in
  Alcotest.(check bool)
    "source annotation included" true
    (contains_substring dump "source type: Int32");
  Alcotest.(check bool)
    "explicit origin included" true
    (contains_substring dump "origin: explicit annotation (Int32)")

let test_debug_dump_exposes_argument_slot_widening () =
  let typed =
    typed_program_of_source
      {|
func takes_int(x: Int) -> Int:
    x

func main(args: List[String]) -> Int:
    takes_int(1)
|}
  in
  let dump = Blorp.Typed_ast_debug.format_program typed in
  Alcotest.(check bool)
    "argument slot widening included" true
    (contains_substring dump "widening: argument slot (#1 -> Int)");
  Alcotest.(check bool)
    "literal proof remains semantic type" true
    (contains_substring dump
       "literal_int 1 {source type: <none>; semantic type: #1; value-slot \
        type: Int")

let test_debug_dump_exposes_declaration_type_metadata () =
  let typed =
    typed_program_of_source
      {|
counter: Int = 1

func main(args: List[String]) -> Int:
    counter
|}
  in
  let dump = Blorp.Typed_ast_debug.format_program typed in
  Alcotest.(check bool)
    "function return metadata included" true
    (contains_substring dump
       "func main {source return type: Int; semantic return type: Int}");
  Alcotest.(check bool)
    "global binding metadata included" true
    (contains_substring dump
       "var counter {source binding type: Int; binding value-slot type: Int}")

let test_debug_dump_exposes_record_and_alias_source_metadata () =
  let typed =
    typed_program_of_source
      {|
type alias UserId = Int
type alias MaybeUserId = Option[UserId]

record User {id: UserId}

func main(args: List[String]) -> Int:
    user: User = {id = 1}
    user.id
|}
  in
  let dump = Blorp.Typed_ast_debug.format_program typed in
  Alcotest.(check bool)
    "record field source metadata included" true
    (contains_substring dump "id: UserId {semantic: Int}");
  Alcotest.(check bool)
    "type alias source metadata included" true
    (contains_substring dump
       "type_alias MaybeUserId = Option[UserId] {semantic: Option[Int]}")

let suite =
  [
    ( "format",
      [
        Alcotest.test_case "exposes widening metadata" `Quick
          test_debug_dump_exposes_widening_metadata;
        Alcotest.test_case "exposes source annotation metadata" `Quick
          test_debug_dump_exposes_source_annotation_metadata;
        Alcotest.test_case "exposes argument-slot widening" `Quick
          test_debug_dump_exposes_argument_slot_widening;
        Alcotest.test_case "exposes declaration type metadata" `Quick
          test_debug_dump_exposes_declaration_type_metadata;
        Alcotest.test_case "exposes record and alias source metadata" `Quick
          test_debug_dump_exposes_record_and_alias_source_metadata;
      ] );
  ]
