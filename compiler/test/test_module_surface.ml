(** Tests for the syntactic module surface currently derived in
    [Modules.collect_exports] and [Modules.collect_private_names].

    These pin the OCaml behavior before the same surface is produced by the
    Blorp parser bridge. *)

let parse_program source =
  match
    Blorp.Modules.parse_typecheck_source ~filename:"module_surface_test.brp"
      source
  with
  | Ok program -> program
  | Error err -> Alcotest.failf "expected source to parse: %s" err.message

let sorted_names exports = exports |> List.map fst |> List.sort String.compare

let check_names msg expected actual =
  Alcotest.(check (list string))
    msg (List.sort String.compare expected) (List.sort String.compare actual)

let export_names source = source |> parse_program |> Blorp.Modules.collect_exports |> sorted_names

let private_names source =
  source |> parse_program |> Blorp.Modules.collect_private_names |> sorted_names

let test_exports_public_declarations () =
  let source =
    {|
func public_func() -> Int:
    1

answer: Int = 42

union Maybe:
    Some(Int)
    None

record Point {x: Int}

struct Pair {left: Int, right: Int}

type alias UserId = Int

type NativeHandle = builtin
|}
  in
  check_names "exports"
    [
      "Maybe";
      "NativeHandle";
      "Pair";
      "Point";
      "UserId";
      "answer";
      "public_func";
    ]
    (export_names source)

let test_exports_trait_name_and_methods () =
  let source =
    {|
trait Renderable:
    pure func render(value: Self) -> String
    pure func label(value: Self) -> String:
        "label"
|}
  in
  check_names "trait exports" [ "Renderable"; "label"; "render" ]
    (export_names source)

let test_exports_impl_methods_as_functions () =
  let source =
    {|
trait Renderable:
    pure func render(value: Self) -> String

record Box {value: Int}

implements Renderable for Box:
    pure func render(value: Box) -> String:
        "box"
|}
  in
  let program = parse_program source in
  let exports = Blorp.Modules.collect_exports program in
  let impl_method_exports =
    List.filter
      (fun (name, decl) ->
        name = "render"
        &&
        match decl.Blorp.Ast.decl_desc with Blorp.Ast.DFunc _ -> true | _ -> false)
      exports
  in
  Alcotest.(check int)
    "impl method function export count" 1
    (List.length impl_method_exports)

let test_private_declarations_are_not_exports () =
  let source =
    {|
private func hidden_func() -> Int:
    1

private union HiddenUnion:
    HiddenCase

private record HiddenRecord {value: Int}

private trait HiddenTrait:
    pure func hidden_method(value: Self) -> String

func visible() -> Int:
    2
|}
  in
  check_names "public exports" [ "visible" ] (export_names source)

let test_private_names_track_inner_decl_surface () =
  let source =
    {|
private func hidden_func() -> Int:
    1

private trait HiddenTrait:
    pure func hidden_method(value: Self) -> String

record Gadget {name: String}

private implements HiddenTrait for Gadget:
    pure func hidden_impl(value: Gadget) -> String:
        value.name
|}
  in
  check_names "private names"
    [ "HiddenTrait"; "hidden_func"; "hidden_impl"; "hidden_method" ]
    (private_names source)

let test_private_trait_suppresses_impl_method_exports () =
  let source =
    {|
private trait SecretTrait:
    pure func reveal(value: Self) -> String

record Gadget {name: String}

implements SecretTrait for Gadget:
    pure func reveal(value: Gadget) -> String:
        value.name
|}
  in
  check_names "exports" [ "Gadget" ] (export_names source)

let suite =
  [
    ( "exports",
      [
        Alcotest.test_case "exports public declarations" `Quick
          test_exports_public_declarations;
        Alcotest.test_case "exports trait name and methods" `Quick
          test_exports_trait_name_and_methods;
        Alcotest.test_case "exports impl methods as functions" `Quick
          test_exports_impl_methods_as_functions;
        Alcotest.test_case "private declarations are not exports" `Quick
          test_private_declarations_are_not_exports;
        Alcotest.test_case "private names track inner decl surface" `Quick
          test_private_names_track_inner_decl_surface;
        Alcotest.test_case "private trait suppresses impl method exports" `Quick
          test_private_trait_suppresses_impl_method_exports;
      ] );
  ]
