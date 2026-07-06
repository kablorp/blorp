(** Tests for the syntactic module surface produced by the Blorp parser bridge
    and consumed by OCaml module loading while the frontend migration is in
    progress. *)

module MS = Blorp.Module_surface

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

let surface_program_source =
  {|
trait Renderable:
    pure func render(value: Self) -> String

record Box {value: Int}

implements Renderable for Box:
    pure func render(value: Box) -> String:
        "box"

private func hidden_func() -> Int:
    1

private trait HiddenTrait:
    pure func hidden_method(value: Self) -> String

private implements HiddenTrait for Box:
    pure func hidden_impl(value: Box) -> String:
        "hidden"
|}

let surface_program () = parse_program surface_program_source

let mapped_surface : MS.t =
  {
    module_name = "./surface";
    imports = [];
    exports =
      [
        {
          name = "render";
          kind = MS.TraitMethod;
          source = MS.TraitMethod (0, 0);
        };
        {
          name = "render";
          kind = MS.ImplMethod;
          source = MS.ImplMethod (2, 0);
        };
      ];
    private_names =
      [
        { name = "hidden_func"; kind = MS.Function; source = MS.PrivateDecl 3 };
        {
          name = "hidden_method";
          kind = MS.TraitMethod;
          source = MS.PrivateTraitMethod (4, 0);
        };
        {
          name = "hidden_impl";
          kind = MS.ImplMethod;
          source = MS.PrivateImplMethod (5, 0);
        };
      ];
    private_traits = [ "HiddenTrait" ];
  }

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

let test_surface_exports_map_trait_and_impl_methods () =
  let program = surface_program () in
  match MS.validate_against_program program mapped_surface with
  | Error message -> Alcotest.fail message
  | Ok () ->
      let exports = MS.exports_as_ast_pairs program mapped_surface in
      let trait_method_count =
        List.length
          (List.filter
             (fun (_, decl) ->
               match decl.Blorp.Ast.decl_desc with
               | Blorp.Ast.DTrait _ -> true
               | _ -> false)
             exports)
      in
      let impl_method_count =
        List.length
          (List.filter
             (fun (_, decl) ->
               match decl.Blorp.Ast.decl_desc with
               | Blorp.Ast.DFunc _ -> true
               | _ -> false)
             exports)
      in
      Alcotest.(check int) "trait method export" 1 trait_method_count;
      Alcotest.(check int) "impl method export" 1 impl_method_count

let test_impl_method_export_decl_returns_function_decl () =
  let program = surface_program () in
  match List.nth_opt program 2 with
  | None -> Alcotest.fail "missing impl declaration"
  | Some decl -> (
      match MS.impl_method_export_decl decl ~method_index:0 with
      | Some { Blorp.Ast.decl_desc = Blorp.Ast.DFunc func; _ } ->
          Alcotest.(check (option string))
            "impl method name" (Some "render") func.func_name
      | Some _ -> Alcotest.fail "expected impl method export as function decl"
      | None -> Alcotest.fail "expected impl method export")

let test_surface_private_names_map_private_methods () =
  let program = surface_program () in
  match MS.validate_against_program program mapped_surface with
  | Error message -> Alcotest.fail message
  | Ok () ->
      let private_names =
        MS.private_names_as_ast_pairs program mapped_surface |> sorted_names
      in
      check_names "surface private names"
        [ "hidden_func"; "hidden_impl"; "hidden_method" ]
        private_names

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
        Alcotest.test_case "surface exports map trait and impl methods" `Quick
          test_surface_exports_map_trait_and_impl_methods;
        Alcotest.test_case "impl method export decl returns function decl" `Quick
          test_impl_method_export_decl_returns_function_decl;
        Alcotest.test_case "surface private names map private methods" `Quick
          test_surface_private_names_map_private_methods;
      ] );
  ]
