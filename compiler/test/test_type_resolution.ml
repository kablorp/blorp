(** Unit tests for the centralized type annotation resolver. *)

open Blorp.Ast
open Blorp.Types

let check_true msg b = Alcotest.(check bool) msg true b

let test_annotation_resolves_qualified_array_element () =
  let ctx =
    Blorp.Type_resolution.make_context ~env:(Blorp.Env.empty ())
      ~module_aliases:[ ("G", "std/geometry") ]
      ()
  in
  let source = TyArray (TyNamed ("G.AABB3", []), [ TyConstInt 4 ]) in
  let resolved = Blorp.Type_resolution.annotation ctx source in
  check_true "source spelling is retained"
    (types_equal (Blorp.Type_resolution.source resolved) source);
  check_true "canonical type resolves array element"
    (types_equal
       (Blorp.Type_resolution.canonical resolved)
       (TyArray (TyNamed ("std/geometry::AABB3", []), [ TyConstInt 4 ])))

let test_annotation_resolves_qualified_names_recursively () =
  let ctx =
    Blorp.Type_resolution.make_context ~env:(Blorp.Env.empty ())
      ~module_aliases:[ ("G", "std/geometry"); ("D", "std/dimensions") ]
      ()
  in
  let source =
    TyTuple
      [
        TyFunc
          {
            params =
              [ TyNamed ("G.Point", []); TyRange (TyNamed ("D.Width", [])) ];
            return =
              TyArray
                ( TyNamed ("G.Direction", []),
                  [
                    TyDimOp
                      (DimAdd, TyNamed ("D.Width", []), TyNamed ("D.Height", []));
                  ] );
            is_pure = true;
          };
      ]
  in
  let resolved =
    Blorp.Type_resolution.annotation ctx source
    |> Blorp.Type_resolution.canonical
  in
  let expected =
    TyTuple
      [
        TyFunc
          {
            params =
              [
                TyNamed ("std/geometry::Point", []);
                TyRange (TyNamed ("std/dimensions::Width", []));
              ];
            return =
              TyArray
                ( TyNamed ("std/geometry::Direction", []),
                  [
                    TyDimOp
                      ( DimAdd,
                        TyNamed ("std/dimensions::Width", []),
                        TyNamed ("std/dimensions::Height", []) );
                  ] );
            is_pure = true;
          };
      ]
  in
  if not (types_equal resolved expected) then
    Alcotest.failf "expected %s, got %s" (type_to_string expected)
      (type_to_string resolved)

let test_annotation_applies_nominal_dim_aliases () =
  let env =
    Blorp.Env.add_alias (Blorp.Env.empty ()) "FloatRow" [ "#N" ]
      (TyArray (ty_float, [ TyVar "#N" ]))
  in
  let ctx = Blorp.Type_resolution.make_context ~env ~module_aliases:[] () in
  let source = TyArray (TyNamed ("FloatRow", []), [ TyConstInt 8 ]) in
  let resolved = Blorp.Type_resolution.annotation ctx source in
  check_true "alias application resolves through central resolver"
    (types_equal
       (Blorp.Type_resolution.canonical resolved)
       (TyArray (ty_float, [ TyConstInt 8 ])))

let test_annotation_can_apply_owner_qualification () =
  let ctx =
    Blorp.Type_resolution.make_context ~env:(Blorp.Env.empty ())
      ~module_aliases:[ ("G", "std/geometry") ]
      ()
  in
  let source =
    TyFunc
      {
        params = [ TyNamed ("Local", []); TyNamed ("G.AABB3", []) ];
        return = TyNamed ("Local", []);
        is_pure = true;
      }
  in
  let qualify_owner =
    Blorp.Types.qualify_module_local_types ~module_path:"mod/a" [ "Local" ]
  in
  let resolved =
    Blorp.Type_resolution.annotation ~qualify_owner ctx source
    |> Blorp.Type_resolution.canonical
  in
  check_true "owner qualification composes with qualified-name resolution"
    (types_equal resolved
       (TyFunc
          {
            params =
              [
                TyNamed ("mod/a::Local", []); TyNamed ("std/geometry::AABB3", []);
              ];
            return = TyNamed ("mod/a::Local", []);
            is_pure = true;
          }))

let test_imported_signature_uses_named_resolution_path () =
  let env =
    Blorp.Env.add_alias (Blorp.Env.empty ()) "Row" [ "#N" ]
      (TyArray (ty_int, [ TyVar "#N" ]))
  in
  let ctx =
    Blorp.Type_resolution.make_context ~env
      ~module_aliases:[ ("M", "pkg/math") ]
      ()
  in
  let source =
    TyFunc
      {
        params = [ TyArray (TyNamed ("Row", []), [ TyConstInt 4 ]) ];
        return = TyNamed ("M.Result", []);
        is_pure = true;
      }
  in
  let resolved =
    Blorp.Type_resolution.imported_signature ctx source
    |> Blorp.Type_resolution.canonical
  in
  check_true "imported signatures resolve through the central resolver"
    (types_equal resolved
       (TyFunc
          {
            params = [ TyArray (ty_int, [ TyConstInt 4 ]) ];
            return = TyNamed ("pkg/math::Result", []);
            is_pure = true;
          }))

let test_record_field_type_can_preserve_alias_source () =
  let env = Blorp.Env.add_alias (Blorp.Env.empty ()) "UserId" [] ty_int in
  let ctx =
    Blorp.Type_resolution.make_context ~env ~module_aliases:[]
      ~alias_policy:Blorp.Type_resolution.PreserveAliasSource ()
  in
  let resolved =
    Blorp.Type_resolution.record_field_type ctx (TyNamed ("UserId", []))
    |> Blorp.Type_resolution.canonical
  in
  check_true "record field type alias source can be preserved"
    (types_equal resolved (TyNamed ("UserId", [])))

let test_declaration_entrypoints_share_resolution_pipeline () =
  let env =
    Blorp.Env.add_alias (Blorp.Env.empty ()) "LocalHit" []
      (* Typecheck stores aliases in Env after source declarations have already
         been canonicalized through Type_resolution. *)
      (TyNamed ("std/geometry::Hit", []))
  in
  let ctx =
    Blorp.Type_resolution.make_context ~env
      ~module_aliases:[ ("G", "std/geometry"); ("O", "std/option") ]
      ()
  in
  let source =
    TyNamed
      ("O.Option", [ TyArray (TyNamed ("LocalHit", []), [ TyConstInt 2 ]) ])
  in
  let expected =
    TyNamed
      ( "Option",
        [ TyArray (TyNamed ("std/geometry::Hit", []), [ TyConstInt 2 ]) ] )
  in
  let check_entrypoint label resolve =
    let resolved = resolve ctx source in
    check_true
      (label ^ " retains source spelling")
      (types_equal (Blorp.Type_resolution.source resolved) source);
    check_true
      (label ^ " canonicalizes through central resolver")
      (types_equal (Blorp.Type_resolution.canonical resolved) expected)
  in
  check_entrypoint "record field" Blorp.Type_resolution.record_field_type;
  check_entrypoint "variant field" Blorp.Type_resolution.variant_field_type;
  check_entrypoint "type alias target" Blorp.Type_resolution.type_alias_target

let test_inference_annotation_entrypoints_share_resolution_pipeline () =
  let env =
    Blorp.Env.add_alias (Blorp.Env.empty ()) "Row" [ "#N" ]
      (TyArray (ty_float, [ TyVar "#N" ]))
  in
  let ctx =
    Blorp.Type_resolution.make_context ~env
      ~module_aliases:[ ("G", "std/geometry") ]
      ()
  in
  let source =
    TyFunc
      {
        params = [ TyArray (TyNamed ("Row", []), [ TyConstInt 4 ]) ];
        return = TyNamed ("G.Point", []);
        is_pure = true;
      }
  in
  let expected =
    TyFunc
      {
        params = [ TyArray (ty_float, [ TyConstInt 4 ]) ];
        return = TyNamed ("std/geometry::Point", []);
        is_pure = true;
      }
  in
  let check_entrypoint label resolve =
    let resolved = resolve ctx source in
    check_true
      (label ^ " retains source spelling")
      (types_equal (Blorp.Type_resolution.source resolved) source);
    check_true
      (label ^ " canonicalizes through central resolver")
      (types_equal (Blorp.Type_resolution.canonical resolved) expected)
  in
  check_entrypoint "value ascription" Blorp.Type_resolution.value_ascription;
  check_entrypoint "local binding"
    Blorp.Type_resolution.local_binding_annotation;
  check_entrypoint "function parameter"
    Blorp.Type_resolution.function_parameter_annotation;
  check_entrypoint "function return"
    Blorp.Type_resolution.function_return_annotation

let suite =
  [
    ( "annotation",
      [
        Alcotest.test_case "qualified array element" `Quick
          test_annotation_resolves_qualified_array_element;
        Alcotest.test_case "recursive qualified names" `Quick
          test_annotation_resolves_qualified_names_recursively;
        Alcotest.test_case "nominal dimension alias" `Quick
          test_annotation_applies_nominal_dim_aliases;
        Alcotest.test_case "owner qualification hook" `Quick
          test_annotation_can_apply_owner_qualification;
        Alcotest.test_case "imported signature named path" `Quick
          test_imported_signature_uses_named_resolution_path;
        Alcotest.test_case "record field type alias preservation" `Quick
          test_record_field_type_can_preserve_alias_source;
        Alcotest.test_case "declaration named entrypoints" `Quick
          test_declaration_entrypoints_share_resolution_pipeline;
        Alcotest.test_case "inference annotation named entrypoints" `Quick
          test_inference_annotation_entrypoints_share_resolution_pipeline;
      ] );
  ]
