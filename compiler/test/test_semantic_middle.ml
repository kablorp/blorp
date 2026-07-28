(** Boundary tests for the remaining OCaml semantic middle. *)

open Blorp
open Ast
open Core

let loc = dummy_loc
let decl cd_desc = { cd_desc; cd_loc = loc; cd_doc = None }
let type_param name = make_type_param name []

let function_decl ?(type_params = []) name def_id =
  {
    cf_name = name;
    cf_module = None;
    cf_type_params = type_params;
    cf_params = [];
    cf_return_ty = TyNamed ("Int", []);
    cf_body = None;
    cf_is_pure = true;
    cf_kind = CFUser;
    cf_def_id = def_id;
  }

let union_decl name type_params =
  {
    type_name = name;
    type_params;
    type_variants = [];
    type_is_enum = false;
    type_is_builtin = false;
    type_is_resource = false;
    type_resource_cleanup = None;
  }

let record_decl name type_params =
  {
    record_name = name;
    record_type_params = type_params;
    record_fields = [];
    record_is_value = false;
    record_is_builtin = false;
  }

let test_post_match_entry_projects_generic_templates () =
  let generic_params = [ type_param "T" ] in
  let program =
    [
      decl (CDFunc (function_decl ~type_params:generic_params "identity" 1));
      decl (CDFunc (function_decl "concrete" 2));
      decl (CDType (union_decl "Container" generic_params));
      decl (CDType (union_decl "Option" generic_params));
      decl (CDRecord (record_decl "Box" generic_params));
      decl
        (CDTypeAlias
           {
             alias_name = "Wrapped";
             alias_type_params = generic_params;
             alias_target = TyNamed ("List", [ TyVar "T" ]);
             alias_is_opaque = false;
           });
    ]
  in
  let at_trait_resolve = ref None in
  let on_stage stage current =
    if stage = Core_stage.TraitResolve then at_trait_resolve := Some current
  in
  let reg = Codegen_types.create_registry () in
  Core_registry.register_types reg program;
  ignore
    (Core_pipeline.run_core_passes_from_post_match ~on_stage ~reg program);
  let projected =
    match !at_trait_resolve with
    | Some projected -> projected
    | None -> Alcotest.fail "trait-resolve stage did not run"
  in
  let has_decl predicate =
    List.exists (fun declaration -> predicate declaration.cd_desc) projected
  in
  Alcotest.(check bool)
    "generic function removed" false
    (has_decl (function CDFunc fn -> fn.cf_name = "identity" | _ -> false));
  Alcotest.(check bool)
    "concrete function retained" true
    (has_decl (function CDFunc fn -> fn.cf_name = "concrete" | _ -> false));
  Alcotest.(check bool)
    "generic user union removed" false
    (has_decl
       (function
         | CDType type_decl -> type_decl.type_name = "Container"
         | _ -> false));
  Alcotest.(check bool)
    "runtime ABI union retained" true
    (has_decl
       (function
         | CDType type_decl -> type_decl.type_name = "Option"
         | _ -> false));
  Alcotest.(check bool)
    "generic record removed" false
    (has_decl
       (function
         | CDRecord record_decl -> record_decl.record_name = "Box"
         | _ -> false));
  Alcotest.(check bool)
    "generic alias metadata retained" true
    (has_decl
       (function
         | CDTypeAlias alias_decl -> alias_decl.alias_name = "Wrapped"
         | _ -> false))

let import_binding ?original_name local_name module_path :
    Session.import_binding =
  { local_name; module_path; original_name }

let test_import_tables_preserve_explicit_bindings () =
  let main_imports =
    [
      import_binding ~original_name:"SourceValue" "Value" "pkg/value";
      import_binding "qualified" "pkg/qualified";
    ]
  in
  let module_bindings =
    [
      ( "pkg/consumer",
        [ import_binding ~original_name:"make" "create" "pkg/provider" ] );
      ("pkg/empty", []);
    ]
  in
  let main_table, module_tables =
    Core_imports.tables_of_bindings ~main_import_bindings:main_imports
      module_bindings
  in
  Alcotest.(check (option (pair string string)))
    "main alias preserves source name"
    (Some ("pkg/value", "SourceValue"))
    (Hashtbl.find_opt main_table "Value");
  Alcotest.(check (option (pair string string)))
    "qualified import has no selected source name"
    (Some ("pkg/qualified", ""))
    (Hashtbl.find_opt main_table "qualified");
  Alcotest.(check bool)
    "empty module table omitted" false
    (Hashtbl.mem module_tables "pkg/empty");
  match Hashtbl.find_opt module_tables "pkg/consumer" with
  | Some table ->
      Alcotest.(check (option (pair string string)))
        "module alias preserves owner and source name"
        (Some ("pkg/provider", "make"))
        (Hashtbl.find_opt table "create")
  | None -> Alcotest.fail "expected consumer import table"

let suite =
  [
    ( "boundary",
      [
        Alcotest.test_case "projects generic templates" `Quick
          test_post_match_entry_projects_generic_templates;
        Alcotest.test_case "preserves explicit import bindings" `Quick
          test_import_tables_preserve_explicit_bindings;
      ] );
  ]
