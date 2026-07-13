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

let parse_artifact source =
  match
    Blorp.Modules.parse_typecheck_source_artifact
      ~filename:"module_surface_test.brp" source
  with
  | Ok artifact -> artifact
  | Error err -> Alcotest.failf "expected source to parse: %s" err.message

let sorted_names exports = exports |> List.map fst |> List.sort String.compare

let check_names msg expected actual =
  Alcotest.(check (list string))
    msg (List.sort String.compare expected) (List.sort String.compare actual)

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

let test_parse_artifact_preserves_module_surface () =
  let artifact = parse_artifact surface_program_source in
  match artifact.Blorp.Modules.source_artifact_surface with
  | None -> Alcotest.fail "expected parser artifact to include module surface"
  | Some surface ->
      check_names "artifact export names"
        [ "Box"; "Renderable"; "render"; "render" ]
        (List.map (fun (symbol : MS.symbol) -> symbol.name) surface.exports);
      check_names "artifact private names"
        [ "HiddenTrait"; "hidden_func"; "hidden_impl"; "hidden_method" ]
        (List.map (fun (symbol : MS.symbol) -> symbol.name) surface.private_names)

let suite =
  [
    ( "exports",
      [
        Alcotest.test_case "surface exports map trait and impl methods" `Quick
          test_surface_exports_map_trait_and_impl_methods;
        Alcotest.test_case "impl method export decl returns function decl" `Quick
          test_impl_method_export_decl_returns_function_decl;
        Alcotest.test_case "surface private names map private methods" `Quick
          test_surface_private_names_map_private_methods;
        Alcotest.test_case "parse artifact preserves module surface" `Quick
          test_parse_artifact_preserves_module_surface;
      ] );
  ]
