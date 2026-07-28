open Blorp

let kind name fields =
  Lsp_json.Object (("kind", Lsp_json.String name) :: fields)

let synthetic_loc = kind "synthetic" []
let named_type name = kind "named" [ ("name", Lsp_json.String name); ("args", Lsp_json.Array []) ]
let type_parameter name = kind "type_parameter" [ ("name", Lsp_json.String name) ]
let int_type = named_type "Int"
let void_type = kind "void" []

let named_type_with_args name args =
  kind "named" [ ("name", Lsp_json.String name); ("args", Lsp_json.Array args) ]

let variable ?def_id name =
  Lsp_json.Object
    [
      ("name", Lsp_json.String name);
      ("uniq", Lsp_json.Int 0);
      ("def_id", Option.fold ~none:Lsp_json.Null ~some:(fun id -> Lsp_json.Int id) def_id);
    ]

let int_literal value =
  kind "literal"
    [
      ("literal", kind "int" [ ("value", Lsp_json.Int value) ]);
      ("type", int_type);
      ("loc", synthetic_loc);
    ]

let variable_expr name =
  kind "var"
    [ ("var", variable name); ("type", int_type); ("loc", synthetic_loc) ]

let typed_variable_expr name typ =
  kind "var" [ ("var", variable name); ("type", typ); ("loc", synthetic_loc) ]

let function_type params return_type =
  kind "function"
    [
      ("pure", Lsp_json.Bool true);
      ("params", Lsp_json.Array params);
      ("return_type", return_type);
    ]

let call_expr call_kind callee args typ =
  kind "call"
    [
      ("call_kind", call_kind);
      ("callee", callee);
      ("args", Lsp_json.Array args);
      ("type", typ);
      ("loc", synthetic_loc);
    ]

let loop_binder name typ =
  Lsp_json.Object
    [
      ("var", variable name);
      ("type", typ);
      ("range_direction", Lsp_json.String "may_run_backward");
    ]

let container_loop tag binder_type iterable body extra_fields =
  let loop =
    Lsp_json.Object
      ([
         ("binder", loop_binder "item" binder_type);
         ("iterable", iterable);
         ("iterable_release_policy", Lsp_json.String "arc");
         ("body", body);
       ]
      @ extra_fields)
  in
  kind tag
    [ (tag, loop); ("type", void_type); ("loc", synthetic_loc) ]

let semantic_match scrutinee tree =
  kind "semantic_match"
    [
      ("scrutinee", scrutinee);
      ("tree", tree);
      ("type", int_type);
      ("loc", synthetic_loc);
    ]

let function_decl ?(body = Some (int_literal 0))
    ?(function_kind = kind "user" []) name def_id =
  kind "function"
    [
      ("name", Lsp_json.String name);
      ("module", Lsp_json.Null);
      ("type_params", Lsp_json.Array []);
      ("params", Lsp_json.Array []);
      ("return_type", int_type);
      ("body", Option.value ~default:Lsp_json.Null body);
      ("pure", Lsp_json.Bool false);
      ("function_kind", function_kind);
      ("def_id", Lsp_json.Int def_id);
      ("loc", synthetic_loc);
    ]

let union_decl name payload_storage =
  let variant =
    Lsp_json.Object
      [
        ("name", Lsp_json.String "Value");
        ("tag", Lsp_json.Int 0);
        ("def_id", Lsp_json.Int 9);
        ( "fields",
          Lsp_json.Array
            [
              Lsp_json.Object
                [
                  ("type", named_type "String");
                  ("release_policy", Lsp_json.String "arc");
                ];
            ] );
      ]
  in
  kind "union"
    [
      ("name", Lsp_json.String name);
      ("type_params", Lsp_json.Array []);
      ("payload_storage", Lsp_json.String payload_storage);
      ("variants", Lsp_json.Array [ variant ]);
      ("loc", synthetic_loc);
    ]

let program decls =
  kind "program"
    [
      ("decls", Lsp_json.Array decls);
      ("foreign_includes", Lsp_json.Array [ Lsp_json.String "fixture.h" ]);
    ]

let decode_exn json =
  match Core_post_match_json.decode_program json with
  | Ok decoded -> decoded
  | Error error -> Alcotest.fail (Core_post_match_json.decode_error_to_string error)

let test_decodes_post_match_program () =
  let decoded = decode_exn (program [ function_decl "main" 7 ]) in
  Alcotest.(check (list string)) "foreign includes" [ "fixture.h" ]
    decoded.foreign_includes;
  match decoded.core with
  | [ { Core.cd_desc = Core.CDFunc fn; _ } ] ->
      Alcotest.(check string) "name" "main" fn.cf_name;
      Alcotest.(check int) "def id" 7 fn.cf_def_id;
      Alcotest.(check bool) "has body" true (Option.is_some fn.cf_body)
  | _ -> Alcotest.fail "expected one decoded function"

let test_preserves_union_payload_storage () =
  let decoded = decode_exn (program [ union_decl "Choice__mono_String" "typed" ]) in
  Alcotest.(check bool)
    "decoded payload storage" true
    (List.assoc_opt "Choice__mono_String" decoded.union_payload_storage
    = Some Codegen_types.TypedUnionPayloadStorage);
  let reg = Codegen_types.create_registry () in
  Core_registry.register_types
    ~union_payload_storage_overrides:decoded.union_payload_storage reg
    decoded.core;
  Alcotest.(check bool)
    "registry payload storage" true
    (Codegen_types.union_uses_typed_payload_storage reg
       "Choice__mono_String")

let decoded_body_exn body =
  let decoded =
    decode_exn (program [ function_decl ~body:(Some body) "main" 1 ])
  in
  match decoded.core with
  | [ { Core.cd_desc = Core.CDFunc { cf_body = Some body; _ }; _ } ] -> body
  | _ -> Alcotest.fail "expected one decoded function body"

let test_rejects_late_ownership_node () =
  let late_dup =
    kind "dup"
      [
        ("var", variable "value");
        ("value_type", int_type);
        ("retain_policy", Lsp_json.String "none");
        ("body", int_literal 0);
        ("type", int_type);
        ("loc", synthetic_loc);
      ]
  in
  let json = program [ function_decl ~body:(Some late_dup) "main" 1 ] in
  match Core_post_match_json.decode_program json with
  | Ok _ -> Alcotest.fail "late ownership Core crossed the post-match boundary"
  | Error error ->
      Alcotest.(check string) "path" "program.decls[0].body.kind" error.path;
      Alcotest.(check bool) "diagnostic names rejected form" true
        (Modules.contains error.message "dup")

let test_decodes_synthesized_value_forms () =
  let boxed =
    kind "box"
      [
        ( "box",
          Lsp_json.Object
            [
              ("kind", kind "prim" []);
              ("value", int_literal 7);
              ("source_type", int_type);
            ] );
        ("type", named_type "Ptr");
        ("loc", synthetic_loc);
      ]
  in
  let unboxed =
    kind "unbox"
      [
        ("unbox_kind", kind "prim" []);
        ("expr", typed_variable_expr "boxed" (named_type "Ptr"));
        ("type", int_type);
        ("loc", synthetic_loc);
      ]
  in
  let cast =
    kind "cast"
      [
        ("expr", int_literal 7);
        ("type", named_type "Float");
        ("loc", synthetic_loc);
      ]
  in
  (match (decoded_body_exn boxed).desc with
  | Core.CBoxTyped { box_kind = Core.BoxPrim; box_source_ty; _ } ->
      Alcotest.(check bool) "box source type" true
        (Types.types_equal box_source_ty (Ast.TyNamed ("Int", [])))
  | _ -> Alcotest.fail "synthesized box did not decode");
  (match (decoded_body_exn unboxed).desc with
  | Core.CUnboxTyped
      { unbox_kind = Core.UnboxPrim; unbox_target_ty; _ } ->
      Alcotest.(check bool) "unbox target type" true
        (Types.types_equal unbox_target_ty (Ast.TyNamed ("Int", [])))
  | _ -> Alcotest.fail "synthesized unbox did not decode");
  match (decoded_body_exn cast).desc with
  | Core.CCast (_, target_ty) ->
      Alcotest.(check bool) "cast target type" true
        (Types.types_equal target_ty (Ast.TyNamed ("Float", [])))
  | _ -> Alcotest.fail "synthesized cast did not decode"

let test_decodes_synthesized_binding_and_tensor_forms () =
  let raw_read =
    kind "tensor_raw_read"
      [
        ( "read",
          Lsp_json.Object
            [
              ("view", variable "raw");
              ("raw_kind", Lsp_json.String "int64");
              ("index", int_literal 0);
            ] );
        ("type", int_type);
        ("loc", synthetic_loc);
      ]
  in
  let raw_view =
    kind "tensor_raw_view_let"
      [
        ( "binding",
          Lsp_json.Object
            [
              ("variable", variable "raw");
              ("raw_kind", Lsp_json.String "int64");
              ("source", typed_variable_expr "values" (named_type "Tensor"));
            ] );
        ("body", raw_read);
        ("type", int_type);
        ("loc", synthetic_loc);
      ]
  in
  let dropped =
    kind "drop"
      [
        ("var", variable "owner");
        ("value_type", named_type "String");
        ("release_policy", Lsp_json.String "arc");
        ("body", raw_view);
        ("type", int_type);
        ("loc", synthetic_loc);
      ]
  in
  let borrowed =
    kind "borrow_let"
      [
        ("name", variable "borrowed");
        ("type", named_type "String");
        ("rhs", typed_variable_expr "owner" (named_type "String"));
        ("body", dropped);
      ]
  in
  match (decoded_body_exn borrowed).desc with
  | Core.CBorrowLet
      ( _,
        {
          desc =
            Core.CDrop
              ( _,
                _,
                {
                  desc =
                    Core.CTensorRawViewLet
                      ( { trv_kind = Core.TensorInt64Elements; _ },
                        {
                          desc =
                            Core.CTensorRawRead
                              { trr_kind = Core.TensorInt64Elements; _ };
                          _
                        } );
                  _
                } );
          _
        } ) ->
      ()
  | _ ->
      Alcotest.fail
        "synthesized borrow/drop/raw tensor forms changed at the boundary"

let test_reports_nested_missing_field_path () =
  let malformed =
    kind "literal"
      [ ("literal", kind "int" []); ("type", int_type); ("loc", synthetic_loc) ]
  in
  let json = program [ function_decl ~body:(Some malformed) "main" 1 ] in
  match Core_post_match_json.decode_program json with
  | Ok _ -> Alcotest.fail "malformed literal decoded"
  | Error error ->
      Alcotest.(check string) "path" "program.decls[0].body.literal.value" error.path

let test_decodes_exact_int64_literal_text () =
  let max_int64 = "9223372036854775807" in
  let body =
    kind "literal"
      [
        ("literal", kind "int" [ ("value", Lsp_json.String max_int64) ]);
        ("type", int_type);
        ("loc", synthetic_loc);
      ]
  in
  let decoded = decode_exn (program [ function_decl ~body:(Some body) "main" 1 ]) in
  match decoded.core with
  | [
   {
     Core.cd_desc =
       Core.CDFunc
         { cf_body = Some { desc = Core.CLit (Ast.LitInt value); _ }; _ };
     _
   };
  ] ->
      Alcotest.(check string) "exact Int64" max_int64 (Int64.to_string value)
  | _ -> Alcotest.fail "exact integer literal did not decode to Core.CLit"

let test_decodes_invalid_debug_block_for_invariant_diagnostic () =
  let body =
    kind "debug_block"
      [
        ("body", int_literal 1);
        ("type", void_type);
        ("loc", synthetic_loc);
      ]
  in
  let decoded = decode_exn (program [ function_decl ~body:(Some body) "main" 1 ]) in
  match decoded.core with
  | [
   {
     Core.cd_desc =
       Core.CDFunc
         { cf_body = Some { desc = Core.CDebugBlock { desc = Core.CLit _; _ }; _ }; _ };
     _
   };
  ] ->
      ()
  | _ -> Alcotest.fail "post-mono debug block was not preserved for invariant diagnostics"

let test_downgrades_deferred_trait_call_for_ocaml_middle () =
  let callee_type = function_type [ int_type ] int_type in
  let body =
    call_expr
      (kind "deferred_trait"
         [
           ("trait_name", Lsp_json.String "Stringable");
           ("method_name", Lsp_json.String "to_string");
         ])
      (typed_variable_expr "to_string" callee_type)
      [ int_literal 1 ] int_type
  in
  let decoded =
    decode_exn (program [ function_decl ~body:(Some body) "main" 1 ])
  in
  match decoded.core with
  | [
   {
     Core.cd_desc =
       Core.CDFunc
         {
           cf_body =
             Some
               {
                 desc =
                   Core.CCall
                     (Core.CKUnknown, _, [ { desc = Core.CLit _; _ } ]);
                 _;
               };
           _;
         };
     _;
   };
  ] ->
      ()
  | _ ->
      Alcotest.fail
        "deferred Blorp trait dispatch did not downgrade at the OCaml boundary"

let test_preserves_selected_trait_target_for_ocaml_middle () =
  let callee_type = function_type [ int_type ] int_type in
  let body =
    call_expr
      (kind "selected_trait"
         [
           ("trait_name", Lsp_json.String "Stringable");
           ("method_name", Lsp_json.String "to_string");
           ("module_path", Lsp_json.String "std/traits");
           ("def_id", Lsp_json.Int 41);
         ])
      (typed_variable_expr "__ufcs_std$traits__to_string" callee_type)
      [ int_literal 1 ] int_type
  in
  let decoded =
    decode_exn (program [ function_decl ~body:(Some body) "main" 1 ])
  in
  match decoded.core with
  | [
   {
     Core.cd_desc =
       Core.CDFunc
         {
           cf_body =
             Some { desc = Core.CCall (Core.CKSelectedDirect 41, _, _); _ };
           _;
         };
     _;
   };
  ] ->
      ()
  | _ ->
      Alcotest.fail
        "selected Blorp trait target did not reach the OCaml middle"

let test_preserves_impl_type_param_bounds_for_remaining_middle () =
  let impl_decl =
    kind "impl"
      [
        ("trait_name", Lsp_json.String "Display");
        ("for_type", named_type_with_args "List" [ type_parameter "T" ]);
        ( "type_params",
          Lsp_json.Array
            [
              Lsp_json.Object
                [
                  ("name", Lsp_json.String "T");
                  ("bounds", Lsp_json.Array [ Lsp_json.String "Stringable" ]);
                ];
            ] );
        ("methods", Lsp_json.Array [ function_decl "display" 9 ]);
        ("loc", synthetic_loc);
      ]
  in
  let decoded = decode_exn (program [ impl_decl ]) in
  match decoded.core with
  | [
   {
     Core.cd_desc =
	       Core.CDImpl
	         {
	           ci_for_type = Ast.TyNamed ("List", [ Ast.TyVar "T" ]);
	           ci_methods =
             [
               {
                 cf_type_params =
                   [
                     {
                       Ast.param_name = "T";
                       param_bounds = [ { Generic_params.tr_name = "Stringable" } ];
                     };
                   ];
                 _;
               };
             ];
           _;
         };
     _;
   };
  ] ->
      ()
  | _ ->
      Alcotest.fail
        "generic impl bounds were not preserved at the post-mono handoff"

let test_decodes_semantic_match_tree () =
  let root_accessor = kind "root" [] in
  let payload_accessor =
    kind "variant_field"
      [
        ("parent", root_accessor);
        ("constructor", Lsp_json.String "Some");
        ("field_index", Lsp_json.Int 0);
      ]
  in
  let some_leaf =
    kind "leaf"
      [
        ( "bindings",
          Lsp_json.Array
            [
              Lsp_json.Object
                [
                  ("variable", variable "value");
                  ("accessor", payload_accessor);
                  ("mode", Lsp_json.String "borrow");
                ];
            ] );
        ("body", variable_expr "value");
      ]
  in
  let fallback =
    kind "leaf" [ ("bindings", Lsp_json.Array []); ("body", int_literal 0) ]
  in
  let tree =
    kind "constructor"
      [
        ("accessor", root_accessor);
        ( "cases",
          Lsp_json.Array
            [
              Lsp_json.Object
                [
                  ("constructor", Lsp_json.String "Some");
                  ("body", some_leaf);
                ];
            ] );
        ("fallback", fallback);
      ]
  in
  let body = semantic_match (variable_expr "input") tree in
  let decoded = decode_exn (program [ function_decl ~body:(Some body) "main" 1 ]) in
  match decoded.core with
  | [
   {
     Core.cd_desc =
       Core.CDFunc
         {
           cf_body =
             Some
               {
                 desc =
                   Core.CMatch
                     ( _,
                       Core.CTSwitchTag
                         {
                           cts_cases =
                             [
                               ( "Some",
                                 Core.CTLeaf
                                   {
                                     ct_bindings =
                                       [
                                         {
                                           mb_accessor =
                                             Core.AccVariantField
                                               (Core.AccRoot, "Some", 0);
                                           mb_mode = Core.MatchBorrow;
                                           _;
                                         };
                                       ];
                                     _;
                                   } );
                             ];
                           cts_default = Some (Core.CTLeaf _);
                           _;
                         } );
                 _;
               };
           _;
         };
     _;
   };
  ] ->
      ()
  | _ -> Alcotest.fail "semantic match tree changed across the Core boundary"

let precompiled_constructor_match ?(bindings = []) release_policy =
  let case =
    Lsp_json.Object
      [
        ("constructor", Lsp_json.String "Some");
        ("accessor", kind "root" []);
        ("test", kind "nullable_option" []);
        ("bindings", Lsp_json.Array bindings);
        ("body", kind "expr" [ ("expr", int_literal 1) ]);
      ]
  in
  kind "constructor_match"
    [
      ("scrutinee", variable_expr "input");
      ("scrutinee_release_policy", Lsp_json.String release_policy);
      ("cases", Lsp_json.Array [ case ]);
      ("fallback", kind "body" [ ("body", int_literal 0) ]);
      ("type", int_type);
      ("loc", synthetic_loc);
    ]

let test_decodes_precompiled_constructor_match () =
  let body = precompiled_constructor_match "none" in
  match (decoded_body_exn body).desc with
  | Core.CMatch
      ( _,
        Core.CTSwitchTag
          {
            cts_cases = [ ("Some", Core.CTLeaf _) ];
            cts_default = Some (Core.CTLeaf _);
            _;
          } ) ->
      ()
  | _ ->
      Alcotest.fail
        "precompiled constructor match changed across the post-match boundary"

let test_decodes_specialized_match_accessor () =
  let binding =
    Lsp_json.Object
      [
        ("variable", variable "value");
        ("type", int_type);
        ( "accessor",
          kind "stack_result_ok_payload" [ ("parent", kind "root" []) ] );
        ("mode", Lsp_json.String "borrow");
      ]
  in
  let body = precompiled_constructor_match ~bindings:[ binding ] "none" in
  match (decoded_body_exn body).desc with
  | Core.CMatch
      ( _,
        Core.CTSwitchTag
          {
            cts_cases =
              [
                ( "Some",
                  Core.CTLeaf
                    {
                      ct_bindings =
                        [
                          {
                            mb_accessor =
                              Core.AccVariantField (Core.AccRoot, "Ok", 0);
                            _;
                          };
                        ];
                      _;
                    } );
              ];
            _;
          } ) ->
      ()
  | _ ->
      Alcotest.fail
        "specialized match accessor changed across the post-match boundary"

let test_rejects_ownership_bearing_constructor_match () =
  let body = precompiled_constructor_match "arc" in
  match
    Core_post_match_json.decode_program
      (program [ function_decl ~body:(Some body) "main" 1 ])
  with
  | Ok _ ->
      Alcotest.fail
        "ownership-bearing constructor match crossed the post-match boundary"
  | Error error ->
      Alcotest.(check string) "path"
        "program.decls[0].body.scrutinee_release_policy" error.path;
      Alcotest.(check bool) "diagnostic explains ownership restriction" true
        (Modules.contains error.message "must not own")

let test_rejects_raw_match () =
  let body =
    kind "raw_match"
      [
        ("scrutinee", variable_expr "input");
        ("cases", Lsp_json.Array []);
        ("type", int_type);
        ("loc", synthetic_loc);
      ]
  in
  match
    Core_post_match_json.decode_program
      (program [ function_decl ~body:(Some body) "main" 1 ])
  with
  | Ok _ -> Alcotest.fail "raw match crossed the post-match boundary"
  | Error error ->
      Alcotest.(check string) "path" "program.decls[0].body.kind" error.path;
      Alcotest.(check bool) "diagnostic names rejected form" true
        (Modules.contains error.message "raw_match")

let test_preserves_pre_mono_type_structure () =
  let dim_var name = kind "runtime" [ ("name", Lsp_json.String name) ] in
  let variadic name = kind "variadic" [ ("name", Lsp_json.String name) ] in
  let operation op left right =
    kind "operation"
      [ ("op", Lsp_json.String op); ("left", left); ("right", right) ]
  in
  let tensor =
    kind "tensor"
      [
        ( "info",
          Lsp_json.Object
            [
              ("element_type", int_type);
              ( "dims",
                Lsp_json.Array
                  [ operation "multiply" (dim_var "#N") (kind "static" [ ("value", Lsp_json.Int 4) ]); variadic "#Ds" ] );
            ] );
      ]
  in
  let fn_type =
    kind "function"
      [
        ("pure", Lsp_json.Bool true);
        ("params", Lsp_json.Array [ tensor ]);
        ("return_type", tensor);
      ]
  in
  let json =
    program
      [
        kind "function"
          [
            ("name", Lsp_json.String "callback_factory");
            ("module", Lsp_json.Null);
            ("type_params", Lsp_json.Array [ Lsp_json.String "#N"; Lsp_json.String "#Ds" ]);
            ("params", Lsp_json.Array []);
            ("return_type", fn_type);
            ("body", Lsp_json.Null);
            ("pure", Lsp_json.Bool true);
            ("function_kind", kind "user" []);
            ("def_id", Lsp_json.Int 4);
            ("loc", synthetic_loc);
          ];
      ]
  in
  let decoded = decode_exn json in
  match decoded.core with
  | [ { Core.cd_desc = Core.CDFunc fn; _ } ] -> (
      match fn.cf_return_ty with
      | Ast.TyFunc
          {
            params =
              [
                Ast.TyArray
                  ( Ast.TyNamed ("Int", []),
                    [ Ast.TyDimOp (Ast.DimMul, Ast.TyVar "#N", Ast.TyConstInt 4); Ast.TyVarDims "#Ds" ] );
              ];
            return = Ast.TyArray _;
            is_pure = true;
          } -> ()
      | _ -> Alcotest.fail "pre-monomorphization type structure was erased")
  | _ -> Alcotest.fail "expected one decoded function"

let test_preserves_unresolved_type_identity () =
  let type_parameter = type_parameter "Accumulator" in
  let self_type = kind "self" [] in
  let json =
    program
      [
        kind "function"
          [
            ("name", Lsp_json.String "identity");
            ("module", Lsp_json.Null);
            ("type_params", Lsp_json.Array [ Lsp_json.String "Accumulator" ]);
            ( "params",
              Lsp_json.Array
                [
                  Lsp_json.Object
                    [
                      ("name", variable "value");
                      ("type", type_parameter);
                      ("loc", synthetic_loc);
                    ];
                ] );
            ("return_type", self_type);
            ("body", Lsp_json.Null);
            ("pure", Lsp_json.Bool true);
            ("function_kind", kind "user" []);
            ("def_id", Lsp_json.Int 5);
            ("loc", synthetic_loc);
          ];
      ]
  in
  let decoded = decode_exn json in
  match decoded.core with
  | [
   {
     Core.cd_desc =
       Core.CDFunc
         {
           cf_params = [ { cp_ty = Ast.TyVar "Accumulator"; _ } ];
           cf_return_ty = Ast.TySelf;
           _;
         };
     _;
   };
  ] ->
      ()
  | _ -> Alcotest.fail "unresolved Core type identity changed at the OCaml boundary"

let test_decodes_resource_source_and_tensor_loops () =
  let file_type = named_type "File" in
  let string_type = named_type "String" in
  let resource_source_type =
    named_type_with_args "ResourceSource" [ file_type; string_type ]
  in
  let tensor_type =
    kind "tensor"
      [
        ( "info",
          Lsp_json.Object
            [
              ("element_type", int_type);
              ("dims", Lsp_json.Array [ kind "static" [ ("value", Lsp_json.Int 4) ] ]);
            ] );
      ]
  in
  let resource_loop =
    container_loop "for_resource_source" file_type
      (typed_variable_expr "files" resource_source_type)
      (kind "void" [ ("type", void_type); ("loc", synthetic_loc) ]) []
  in
  let tensor_loop =
    container_loop "for_tensor" int_type
      (typed_variable_expr "values" tensor_type)
      (kind "void" [ ("type", void_type); ("loc", synthetic_loc) ])
      [ ("element_storage", kind "runtime_read" []) ]
  in
  let check_loop name body expected_iterable_type =
    let decoded = decode_exn (program [ function_decl ~body:(Some body) name 1 ]) in
    match decoded.core with
    | [ { Core.cd_desc = Core.CDFunc { cf_body = Some { desc = Core.CFor (_, iterable, _); _ }; _ }; _ } ] ->
        Alcotest.(check bool) (name ^ " iterable type") true
          (Types.types_equal iterable.ty expected_iterable_type)
    | _ -> Alcotest.fail (name ^ " did not decode to Core.CFor")
  in
  check_loop "resource_loop" resource_loop
    (Ast.TyNamed ("ResourceSource", [ Ast.TyNamed ("File", []); Ast.TyNamed ("String", []) ]));
  check_loop "tensor_loop" tensor_loop
    (Ast.TyArray (Ast.TyNamed ("Int", []), [ Ast.TyConstInt 4 ]))

let test_decodes_concurrent_resource_item_mode () =
  let file_type = named_type "File" in
  let string_type = named_type "String" in
  let resource_source_type =
    named_type_with_args "ResourceSource" [ file_type; string_type ]
  in
  let body =
    kind "pre_closure_concurrently_loop"
      [
        ( "pre_closure_concurrently_loop",
          Lsp_json.Object
            [
              ("var", variable "file");
              ("item_type", file_type);
              ( "item_mode",
                kind "move_resource_item"
                  [ ("resource_type", file_type); ("error_type", string_type) ] );
              ("iterable", typed_variable_expr "files" resource_source_type);
              ("body", kind "void" [ ("type", void_type); ("loc", synthetic_loc) ]);
              ("timeout", Lsp_json.Null);
              ("limit", int_literal 4);
              ("output", Lsp_json.String "discard");
            ] );
        ("type", void_type);
        ("loc", synthetic_loc);
      ]
  in
  let decoded = decode_exn (program [ function_decl ~body:(Some body) "main" 1 ]) in
  match decoded.core with
  | [
   {
     Core.cd_desc =
       Core.CDFunc
         {
           cf_body =
             Some
               {
                 desc =
                   Core.CConcurrentlyLoop
                     {
                       cf_item_mode =
                         Core.ConcurrentlyLoopMoveResourceItem
                           { clmi_resource_ty; clmi_error_ty };
                       _
                     };
                 _
               };
           _
         };
     _
   };
  ] ->
      Alcotest.(check bool) "resource type" true
        (Types.types_equal clmi_resource_ty (Ast.TyNamed ("File", [])));
      Alcotest.(check bool) "error type" true
        (Types.types_equal clmi_error_ty (Ast.TyNamed ("String", [])))
  | _ -> Alcotest.fail "concurrent resource loop did not retain move-item ownership"

let test_decodes_foreign_defensive_copy_policy () =
  let arg_passing =
    kind "default"
      [
        ( "policies",
          Lsp_json.Array
            [
              kind "defensive_copy"
                [ ("copy_kind", Lsp_json.String "string") ];
            ] );
      ]
  in
  let function_kind =
    kind "foreign"
      [
        ("c_name", Lsp_json.String "consume_string");
        ("includes", Lsp_json.Array []);
        ("link_flags", Lsp_json.Array []);
        ("arg_passing", arg_passing);
      ]
  in
  let decoded =
    decode_exn
      (program
         [ function_decl ~body:None ~function_kind "consume_string" 9 ])
  in
  match decoded.core with
  | [
   {
     Core.cd_desc =
       Core.CDFunc
         {
           cf_kind =
             Core.CFForeign
               {
                 arg_passing =
                   Core.ForeignDefaultArgs
                     [ Core.ForeignDefensiveCopy Core.ForeignStringCopy ];
                 _
               };
           _
         };
     _
   };
  ] ->
      ()
  | _ -> Alcotest.fail "foreign defensive-copy policy changed at the boundary"

let suite =
  [
    ( "boundary",
      [
        Alcotest.test_case "decodes post-match program" `Quick test_decodes_post_match_program;
        Alcotest.test_case "preserves union payload storage" `Quick
          test_preserves_union_payload_storage;
        Alcotest.test_case "rejects later ownership node" `Quick
          test_rejects_late_ownership_node;
        Alcotest.test_case "decodes synthesized value forms" `Quick
          test_decodes_synthesized_value_forms;
        Alcotest.test_case "decodes synthesized binding and tensor forms"
          `Quick test_decodes_synthesized_binding_and_tensor_forms;
        Alcotest.test_case "reports nested field path" `Quick test_reports_nested_missing_field_path;
        Alcotest.test_case "decodes exact int64 literal text" `Quick
          test_decodes_exact_int64_literal_text;
        Alcotest.test_case "preserves invalid debug block for invariant diagnostic" `Quick
          test_decodes_invalid_debug_block_for_invariant_diagnostic;
        Alcotest.test_case "downgrades deferred trait call for OCaml middle"
          `Quick test_downgrades_deferred_trait_call_for_ocaml_middle;
        Alcotest.test_case "preserves selected trait target for OCaml middle"
          `Quick test_preserves_selected_trait_target_for_ocaml_middle;
        Alcotest.test_case "preserves impl type parameter bounds for remaining middle"
          `Quick test_preserves_impl_type_param_bounds_for_remaining_middle;
        Alcotest.test_case "decodes semantic match tree" `Quick
          test_decodes_semantic_match_tree;
        Alcotest.test_case "decodes precompiled constructor match" `Quick
          test_decodes_precompiled_constructor_match;
        Alcotest.test_case "decodes specialized match accessor" `Quick
          test_decodes_specialized_match_accessor;
        Alcotest.test_case "rejects ownership-bearing constructor match" `Quick
          test_rejects_ownership_bearing_constructor_match;
        Alcotest.test_case "rejects raw match" `Quick test_rejects_raw_match;
        Alcotest.test_case "preserves pre-mono type structure" `Quick
          test_preserves_pre_mono_type_structure;
        Alcotest.test_case "preserves unresolved type identity" `Quick
          test_preserves_unresolved_type_identity;
        Alcotest.test_case "decodes resource source and tensor loops" `Quick
          test_decodes_resource_source_and_tensor_loops;
        Alcotest.test_case "decodes concurrent resource item mode" `Quick
          test_decodes_concurrent_resource_item_mode;
        Alcotest.test_case "decodes foreign defensive-copy policy" `Quick
          test_decodes_foreign_defensive_copy_policy;
      ] );
  ]
