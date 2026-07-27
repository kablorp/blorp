(** Contract tests for the temporary OCaml typed-AST-to-Core compatibility
    route.

    Normal source commands enter Core through the Blorp implementation. These
    tests protect the smaller OCaml route that remains live for bounded
    bootstrap and direct in-memory callers until that route is retired. Keep
    this suite focused on boundary contracts rather than duplicating the
    authoritative Blorp implementation suites. *)

open Blorp.Ast
open Blorp.Core

let loc = dummy_loc
let ty name args = TyNamed (name, args)
let decl desc = { cd_desc = desc; cd_loc = loc; cd_doc = None }

let test_lowers_typed_source () =
  Test_helpers.with_isolated_env (fun () ->
      let typed_ast =
        Test_helpers.expect_ok_typed
          {|
pure func inc(value: Int) -> Int:
	value + 1

func main(args: List[String]) -> Int:
	inc(41)
|}
      in
      let typed = Test_helpers.expect_valid_typed_program typed_ast in
      let lowered = Blorp.Core_lower.lower_typed_program typed in
      let functions =
        List.filter_map
          (fun declaration ->
            match declaration.cd_desc with CDFunc fn -> Some fn | _ -> None)
          lowered
      in
      Alcotest.(check (list string))
        "function declarations survive lowering" [ "inc"; "main" ]
        (List.map (fun fn -> fn.cf_name) functions);
      match List.find_opt (fun fn -> fn.cf_name = "inc") functions with
      | Some { cf_body = Some { desc = CBin (Add, _, _); _ }; _ } -> ()
      | Some _ -> Alcotest.fail "expected inc to lower to integer addition"
      | None -> Alcotest.fail "expected lowered inc function")

let test_lowers_declared_type_parameters_as_explicit_vars () =
  Test_helpers.with_isolated_env (fun () ->
      let typed_ast =
        Test_helpers.expect_ok_typed
          {|
record Box[T] {value: T}

type alias Wrapped[T] = List[T]

pure func identity[T](value: T) -> T:
	value
|}
      in
      let typed = Test_helpers.expect_valid_typed_program typed_ast in
      let lowered = Blorp.Core_lower.lower_typed_program typed in
      let identity =
        List.find_map
          (fun declaration ->
            match declaration.cd_desc with
            | CDFunc fn when fn.cf_name = "identity" -> Some fn
            | _ -> None)
          lowered
      in
      let box =
        List.find_map
          (fun declaration ->
            match declaration.cd_desc with
            | CDRecord record when record.record_name = "Box" -> Some record
            | _ -> None)
          lowered
      in
      let wrapped =
        List.find_map
          (fun declaration ->
            match declaration.cd_desc with
            | CDTypeAlias alias when alias.alias_name = "Wrapped" -> Some alias
            | _ -> None)
          lowered
      in
      match (identity, box, wrapped) with
      | ( Some
            {
              cf_params = [ { cp_ty = TyVar "T"; _ } ];
              cf_return_ty = TyVar "T";
              cf_body = Some { desc = CVar _; ty = TyVar "T"; _ };
              _;
            },
          Some { record_fields = [ { field_type = TyVar "T"; _ } ]; _ },
          Some { alias_target = TyNamed ("List", [ TyVar "T" ]); _ } ) ->
          ()
      | _ ->
          Alcotest.fail
            "declared type parameters must cross the Core boundary as TyVar")

let test_projects_only_semantic_middle_runtime_declarations () =
  Test_helpers.with_isolated_env (fun () ->
      let typed_ast =
        Test_helpers.expect_ok_typed
          {|
union Container[T]:
	Value(T)
	Empty

record Box[T] {value: T}

type alias Wrapped[T] = List[T]

pure func identity[T](value: T) -> T:
	value

pure func concrete(value: Int) -> Int:
	value
|}
      in
      let typed = Test_helpers.expect_valid_typed_program typed_ast in
      let lowered = Blorp.Core_lower.lower_typed_program typed in
      let container =
        List.find_map
          (fun declaration ->
            match declaration.cd_desc with
            | CDType type_decl when type_decl.type_name = "Container" ->
                Some type_decl
            | _ -> None)
          lowered
      in
      let concrete =
        List.find_map
          (fun declaration ->
            match declaration.cd_desc with
            | CDFunc func when func.cf_name = "concrete" -> Some func
            | _ -> None)
          lowered
      in
      match (container, concrete) with
      | Some container, Some concrete ->
          let option_decl =
            decl (CDType { container with type_name = "Option" })
          in
          let bodyless_decl =
            decl
              (CDFunc
                 {
                   concrete with
                   cf_name = "deferred";
                   cf_body = None;
                   cf_def_id = concrete.cf_def_id + 1;
                 })
          in
          let projected =
            Blorp.Core_pipeline.project_semantic_middle_program
              (option_decl :: bodyless_decl :: lowered)
          in
          let has_function name =
            List.exists
              (fun declaration ->
                match declaration.cd_desc with
                | CDFunc func -> func.cf_name = name
                | _ -> false)
              projected
          in
          let has_type name =
            List.exists
              (fun declaration ->
                match declaration.cd_desc with
                | CDType type_decl -> type_decl.type_name = name
                | _ -> false)
              projected
          in
          let has_record name =
            List.exists
              (fun declaration ->
                match declaration.cd_desc with
                | CDRecord record_decl -> record_decl.record_name = name
                | _ -> false)
              projected
          in
          let has_alias name =
            List.exists
              (fun declaration ->
                match declaration.cd_desc with
                | CDTypeAlias alias_decl -> alias_decl.alias_name = name
                | _ -> false)
              projected
          in
          Alcotest.(check bool)
            "generic function is removed" false (has_function "identity");
          Alcotest.(check bool)
            "concrete function is retained" true (has_function "concrete");
          Alcotest.(check bool)
            "bodyless monomorphic declaration is retained" true
            (has_function "deferred");
          Alcotest.(check bool)
            "generic user union is removed" false (has_type "Container");
          Alcotest.(check bool)
            "generic runtime ABI union is retained" true (has_type "Option");
          Alcotest.(check bool)
            "generic record template is removed" false (has_record "Box");
          Alcotest.(check bool)
            "generic alias metadata is retained" true (has_alias "Wrapped")
      | _ -> Alcotest.fail "expected lowered generic and concrete declarations")

let test_prefixes_module_owned_type () =
  let record =
    {
      record_name = "Widget";
      record_type_params = [];
      record_fields = [];
      record_is_value = true;
      record_is_builtin = false;
    }
  in
  match
    Blorp.Core_flatten.prefix_module_names "pkg/widgets"
      [ decl (CDRecord record) ]
  with
  | [ { cd_desc = CDRecord rewritten; _ } ] ->
      Alcotest.(check string)
        "record identity includes module owner" "pkg_widgets__Widget"
        rewritten.record_name
  | _ -> Alcotest.fail "expected one rewritten record declaration"

let test_prefixes_module_owned_unresolved_builtin () =
  let function_decl =
    {
      cf_name = "fold_left";
      cf_module = Some "std/list";
      cf_type_params = [ Blorp.Ast.make_type_param "T" [] ];
      cf_params =
        [
          {
            cp_name = Var.named "self";
            cp_ty = ty "List" [ TyVar "T" ];
            cp_loc = loc;
          };
        ];
      cf_return_ty = TyVar "T";
      cf_body = None;
      cf_is_pure = true;
      cf_kind = CFUnresolvedBuiltin;
      cf_def_id = 41;
    }
  in
  match
    Blorp.Core_flatten.prefix_module_names "std/list"
      [ decl (CDFunc function_decl) ]
  with
  | [ { cd_desc = CDFunc rewritten; _ } ] ->
      Alcotest.(check string)
        "source builtin keeps its module-owned identity" "std_list__fold_left"
        rewritten.cf_name
  | _ -> Alcotest.fail "expected one rewritten builtin declaration"

let test_preserves_forward_builtin_purity_overload () =
  let function_decl ~def_id ~is_pure ~kind =
    {
      cf_name = "fold_right";
      cf_module = Some "std/list";
      cf_type_params = [ Blorp.Ast.make_type_param "T" [] ];
      cf_params =
        [
          {
            cp_name = Var.named "self";
            cp_ty = ty "List" [ TyVar "T" ];
            cp_loc = loc;
          };
        ];
      cf_return_ty = TyVar "T";
      cf_body = None;
      cf_is_pure = is_pure;
      cf_kind = kind;
      cf_def_id = def_id;
    }
  in
  match
    Blorp.Core_flatten.prefix_module_names "std/list"
      [
        decl
          (CDFunc
             (function_decl ~def_id:41 ~is_pure:false ~kind:CFUser));
        decl
          (CDFunc
             (function_decl ~def_id:42 ~is_pure:true
                ~kind:CFUnresolvedBuiltin));
      ]
  with
  | [
   { cd_desc = CDFunc impure; _ };
   { cd_desc = CDFunc pure; _ };
  ] ->
      Alcotest.(check string)
        "impure overload keeps primary name" "std_list__fold_right"
        impure.cf_name;
      Alcotest.(check bool)
        "forward overload becomes unresolved builtin" true
        (impure.cf_kind = CFUnresolvedBuiltin);
      Alcotest.(check int) "forward overload keeps id" 41 impure.cf_def_id;
      Alcotest.(check string)
        "pure overload remains distinct" "std_list__fold_right__pure"
        pure.cf_name;
      Alcotest.(check bool)
        "pure overload remains unresolved builtin" true
        (pure.cf_kind = CFUnresolvedBuiltin);
      Alcotest.(check int) "pure overload keeps id" 42 pure.cf_def_id
  | _ -> Alcotest.fail "expected both builtin purity overloads"

let import_binding ?original_name local_name module_path :
    Blorp.Session.import_binding =
  { local_name; module_path; original_name }

let test_builds_import_tables_from_explicit_bindings () =
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
    Blorp.Core_imports.tables_of_bindings
      ~main_import_bindings:main_imports module_bindings
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
    "empty module table is omitted" false
    (Hashtbl.mem module_tables "pkg/empty");
  match Hashtbl.find_opt module_tables "pkg/consumer" with
  | Some table ->
      Alcotest.(check (option (pair string string)))
        "module alias preserves owner and source name"
        (Some ("pkg/provider", "make"))
        (Hashtbl.find_opt table "create")
  | None -> Alcotest.fail "expected consumer import table"

let param name typ =
  { cp_name = Var.named name; cp_ty = typ; cp_loc = loc }

let foreign_func ?(passing = ForeignDefaultArgs []) name params =
  {
    cf_name = name;
    cf_module = None;
    cf_type_params = [];
    cf_params = params;
    cf_return_ty = ty "Void" [];
    cf_body = None;
    cf_is_pure = false;
    cf_kind =
      CFForeign
        {
          c_name = "c_" ^ name;
          includes = [];
          link_flags = [];
          arg_passing = passing;
        };
    cf_def_id = 0;
  }

let annotated_foreign_kind func =
  let program = [ decl (CDFunc func) ] in
  let registry = Blorp.Codegen_types.create_registry () in
  match Blorp.Core_ffi_boundary.annotate_program ~reg:registry program with
  | [ { cd_desc = CDFunc { cf_kind; _ }; _ } ] -> cf_kind
  | _ -> Alcotest.fail "expected one annotated foreign function"

let test_attaches_default_foreign_arg_policies () =
  let func =
    foreign_func "mix"
      [
        param "text" (ty "String" []);
        param "count" (ty "Int" []);
        param "bytes" (ty "Bytes" []);
      ]
  in
  match annotated_foreign_kind func with
  | CFForeign { arg_passing; _ } ->
      Alcotest.(check bool)
        "default policies classify scalar and managed arguments" true
        (arg_passing
        = ForeignDefaultArgs
            [
              ForeignDefensiveCopy ForeignStringCopy;
              ForeignScalarByValue;
              ForeignDefensiveCopy ForeignBytesCopy;
            ])
  | _ -> Alcotest.fail "expected foreign function"

let test_preserves_explicit_foreign_borrow () =
  let func =
    foreign_func ~passing:ForeignBorrowArgs "borrow"
      [ param "text" (ty "String" []) ]
  in
  match annotated_foreign_kind func with
  | CFForeign { arg_passing = ForeignBorrowArgs; _ } -> ()
  | _ -> Alcotest.fail "expected explicit borrow policy to survive annotation"

let test_rejects_managed_default_foreign_arg () =
  let message_variant =
    {
      variant_name = "Message";
      variant_fields = [ ty "String" [] ];
      variant_tag = 0;
      variant_loc = loc;
      variant_def_id = None;
    }
  in
  let message_type =
    {
      type_name = "Message";
      type_params = [];
      type_variants = [ message_variant ];
      type_is_enum = false;
      type_is_builtin = false;
      type_is_resource = false;
      type_resource_cleanup = None;
    }
  in
  let program =
    [
      decl (CDType message_type);
      decl
        (CDFunc
           (foreign_func "take_message"
              [ param "message" (ty "Message" []) ]));
    ]
  in
  let registry = Blorp.Codegen_types.create_registry () in
  Blorp.Core_registry.register_types registry program;
  Test_helpers.check_core_error_raises
    ~phase:(Blorp.Core_error.Stage Blorp.Core_stage.Lower)
    ~msg_contains:"has no safe boundary policy" (fun () ->
      ignore (Blorp.Core_ffi_boundary.annotate_program ~reg:registry program))

let suite =
  [
    ( "boundary",
      [
        Alcotest.test_case "lowers typed source" `Quick
          test_lowers_typed_source;
        Alcotest.test_case "lowers declared type parameters as explicit vars"
          `Quick test_lowers_declared_type_parameters_as_explicit_vars;
        Alcotest.test_case "projects semantic middle runtime declarations"
          `Quick test_projects_only_semantic_middle_runtime_declarations;
        Alcotest.test_case "prefixes module-owned type" `Quick
          test_prefixes_module_owned_type;
        Alcotest.test_case "prefixes module-owned unresolved builtin" `Quick
          test_prefixes_module_owned_unresolved_builtin;
        Alcotest.test_case "preserves forward builtin purity overload" `Quick
          test_preserves_forward_builtin_purity_overload;
        Alcotest.test_case "builds explicit import tables" `Quick
          test_builds_import_tables_from_explicit_bindings;
        Alcotest.test_case "attaches default foreign argument policies" `Quick
          test_attaches_default_foreign_arg_policies;
        Alcotest.test_case "preserves explicit foreign borrow" `Quick
          test_preserves_explicit_foreign_borrow;
        Alcotest.test_case "rejects managed default foreign argument" `Quick
          test_rejects_managed_default_foreign_arg;
      ] );
  ]
