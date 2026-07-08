open Blorp.Ast
open Blorp.Lsp_json

module Proof = Blorp.Type_proof_metadata
module Env = Blorp.Env_types
module Typed = Blorp.Typed_ast

let check_type msg expected actual =
  Alcotest.(check bool)
    msg true
    (Blorp.Types.types_equal expected actual)

let check_widening msg expected actual =
  Alcotest.(check bool) msg true (expected = actual)

let check_origin msg expected actual =
  Alcotest.(check bool) msg true (expected = actual)

let check_pattern msg expected actual =
  Alcotest.(check bool) msg true (expected = actual)

let expect_type json =
  match Blorp.Typed_ast_json.decode_type "$" json with
  | Ok ty -> ty
  | Error err -> Alcotest.fail (Blorp.Typed_ast_json.decode_error_to_string err)

let expect_widening json =
  match Blorp.Typed_ast_json.decode_widening_decision "$" json with
  | Ok decision -> decision
  | Error err -> Alcotest.fail (Blorp.Typed_ast_json.decode_error_to_string err)

let expect_origin json =
  match Blorp.Typed_ast_json.decode_expr_type_origin "$" json with
  | Ok origin -> origin
  | Error err -> Alcotest.fail (Blorp.Typed_ast_json.decode_error_to_string err)

let expect_value_proofs json =
  match Blorp.Typed_ast_json.decode_value_proofs "$" json with
  | Ok proofs -> proofs
  | Error err -> Alcotest.fail (Blorp.Typed_ast_json.decode_error_to_string err)

let expect_resolved_call_info json =
  match Blorp.Typed_ast_json.decode_resolved_call_info "$" json with
  | Ok info -> info
  | Error err -> Alcotest.fail (Blorp.Typed_ast_json.decode_error_to_string err)

let expect_expr_info json =
  match Blorp.Typed_ast_json.decode_typed_expr_info "$" json with
  | Ok info -> info
  | Error err -> Alcotest.fail (Blorp.Typed_ast_json.decode_error_to_string err)

let expect_expr_info_error json =
  match Blorp.Typed_ast_json.decode_typed_expr_info "$" json with
  | Ok _ -> Alcotest.fail "expected typed expr info decode error"
  | Error err -> err

let expect_pattern json =
  match Blorp.Typed_ast_json.decode_pattern "$" json with
  | Ok pattern -> pattern
  | Error err -> Alcotest.fail (Blorp.Typed_ast_json.decode_error_to_string err)

let expect_typed_expr json =
  match Blorp.Typed_ast_json.decode_typed_expr "$" json with
  | Ok expr -> expr
  | Error err -> Alcotest.fail (Blorp.Typed_ast_json.decode_error_to_string err)

let expect_typed_expr_error json =
  match Blorp.Typed_ast_json.decode_typed_expr "$" json with
  | Ok _ -> Alcotest.fail "expected typed expression decode error"
  | Error err -> err

let expect_typed_program json =
  match Blorp.Typed_ast_json.decode_typed_program json with
  | Ok program -> program
  | Error err -> Alcotest.fail (Blorp.Typed_ast_json.decode_error_to_string err)

let expect_span json =
  match Blorp.Typed_ast_json.decode_span "$" json with
  | Ok span -> span
  | Error err -> Alcotest.fail (Blorp.Typed_ast_json.decode_error_to_string err)

let expect_error json =
  match Blorp.Typed_ast_json.decode_type "$" json with
  | Ok ty ->
      Alcotest.fail
        ("expected decode error, got " ^ Blorp.Types.type_to_string ty)
  | Error err -> err

let named ?(args = []) name =
  Object
    [
      ("kind", String "named");
      ("name", String name);
      ("args", Array args);
    ]

let function_type ?(pure = false) params return_type =
  Object
    [
      ("kind", String "function");
      ("pure", Bool pure);
      ("params", Array params);
      ("return_type", return_type);
    ]

let const_int value =
  Object [ ("kind", String "const_int"); ("value", Int value) ]

let var_dims name =
  Object [ ("kind", String "var_dims"); ("name", String name) ]

let type_var name =
  Object [ ("kind", String "type_var"); ("name", String name) ]

let ident text = Object [ ("text", String text) ]

let keep ty = Object [ ("kind", String "keep"); ("type", ty) ]

let no_proofs =
  Object [ ("range", Null); ("subscript", Null) ]

let value_slot ?decision ty =
  let decision =
    match decision with
    | Some decision -> decision
    | None -> keep ty
  in
  Object [ ("semantic_type", ty); ("decision", decision) ]

let expr_info ?(resolved_call = Null) ty =
  Object
    [
      ("source_type", Null);
      ("semantic_type", ty);
      ("value_type", ty);
      ("origin", Object [ ("kind", String "inferred") ]);
      ("value_slot", value_slot ty);
      ("proofs", no_proofs);
      ("resolved_call", resolved_call);
      ("resource_dependencies", Array []);
    ]

let resolved_call_info =
  Object
    [
      ("callee_name", String "read_chunk_at");
      ("source_name", String "read_chunk_at");
      ("callable_id", Int 42);
      ("trait_name", Null);
      ("purity", String "impure");
      ( "origin",
        Object
          [
            ("kind", String "imported");
            ("module", String "std/file");
          ] );
      ("instantiated_params", Array [ named "String"; named "Int" ]);
      ("instantiated_return", named "String");
      ( "resource_args",
        Object
          [
            ("kind", String "allow");
            ("result_policy", String "dependent");
          ] );
      ( "dim_constraints",
        Array
          [
            Object
              [
                ("left", var_dims "#N");
                ("right", const_int 4096);
              ];
          ] );
    ]

let imported_string_split_resolved_call_info =
  Object
    [
      ("callee_name", String "make_string");
      ("source_name", String "string");
      ("callable_id", Int 123);
      ("trait_name", Null);
      ("purity", String "pure");
      ( "origin",
        Object
          [
            ("kind", String "imported");
            ("module", String "std/string");
          ] );
      ("instantiated_params", Array [ named "Int" ]);
      ("instantiated_return", named "String");
      ("resource_args", Object [ ("kind", String "reject") ]);
      ("dim_constraints", Array []);
    ]

let trait_resolved_call_info =
  Object
    [
      ("callee_name", String "zero");
      ("source_name", String "zero");
      ("callable_id", Null);
      ("trait_name", String "HasZero");
      ("purity", String "pure");
      ("origin", Object [ ("kind", String "impl_method") ]);
      ("instantiated_params", Array []);
      ("instantiated_return", type_var "T");
      ("resource_args", Object [ ("kind", String "reject") ]);
      ("dim_constraints", Array []);
    ]

let span_json =
  Object
    [
      ("path", String "typed_ast_json.brp");
      ("start_line", Int 2);
      ("start_column", Int 3);
      ("end_line", Int 4);
      ("end_column", Int 5);
    ]

let ident_at text = Object [ ("text", String text); ("span", span_json) ]

let parsed_named name =
  Object
    [
      ("kind", String "named");
      ("name", ident_at name);
      ("args", Array []);
      ("span", span_json);
    ]

let parsed_param name ty =
  Object
    [
      ( "binder",
        Object
          [
            ("kind", String "name");
            ("name", ident_at name);
          ] );
      ("type", ty);
      ("span", span_json);
    ]

let parsed_field name ty =
  Object
    [
      ("name", ident_at name);
      ("type", ty);
      ("span", span_json);
    ]

let typed_int_literal value =
  Object
    [
      ("kind", String "int_literal");
      ("span", span_json);
      ("info", expr_info (named "Int"));
      ("value", String value);
    ]

let typed_node ?(info = expr_info (named "Int")) kind fields =
  Object
    ([ ("kind", String kind); ("span", span_json); ("info", info) ] @ fields)

let typed_name name =
  Object
    [
      ("kind", String "name");
      ("name", ident_at name);
      ("info", expr_info (named "Int"));
    ]

let typed_name_with_type name ty =
  Object
    [
      ("kind", String "name");
      ("name", ident_at name);
      ("info", expr_info ty);
    ]

let typed_void = typed_node ~info:(expr_info (named "Void")) "void" []

let typed_bool_literal value =
  Object
    [
      ("kind", String "bool_literal");
      ("span", span_json);
      ("info", expr_info (named "Bool"));
      ("value", Bool value);
    ]

let typed_int_list items =
  typed_node
    ~info:(expr_info (named ~args:[ named "Int" ] "List"))
    "list"
    [ ("items", Array items) ]

let typed_concurrent_param name value =
  Object
    [
      ("name", ident_at name);
      ("value", value);
      ("span", span_json);
    ]

let typed_task_result ty =
  named ~args:[ ty; named "ConcurrencyError" ] "Result"

let typed_concurrent_bind name value =
  typed_node
    ~info:(expr_info (typed_task_result (named "Int")))
    "concurrent_bind"
    [
      ("name", ident_at name);
      ("annotation", Null);
      ("value", value);
    ]

let parsed_int_literal value =
  Object
    [
      ("kind", String "int_literal");
      ("span", span_json);
      ("value", String value);
    ]

let test_decode_span () =
  let span = expect_span span_json in
  Alcotest.(check (option string))
    "file" (Some "typed_ast_json.brp") span.loc_file;
  Alcotest.(check int) "start line" 2 span.line;
  Alcotest.(check int) "start column" 3 span.column;
  Alcotest.(check int) "end line" 4 span.end_line;
  Alcotest.(check int) "end column" 5 span.end_column

let test_decode_named_and_array () =
  let json =
    Object
      [
        ("kind", String "array");
        ("element", named "Int");
        ("dims", Array [ const_int 3; const_int 4 ]);
      ]
  in
  check_type "array type"
    (TyArray (TyNamed ("Int", []), [ TyConstInt 3; TyConstInt 4 ]))
    (expect_type json)

let test_decode_function_tuple_and_vars () =
  let json =
    Object
      [
        ("kind", String "function");
        ("pure", Bool true);
        ( "params",
          Array
            [
              Object
                [
                  ("kind", String "tuple");
                  ("items", Array [ named "Int"; named "String" ]);
                ];
              Object [ ("kind", String "type_var"); ("name", String "T") ];
            ] );
        ("return_type", Object [ ("kind", String "self") ]);
      ]
  in
  check_type "function type"
    (TyFunc
       {
         is_pure = true;
         params = [ TyTuple [ TyNamed ("Int", []); TyNamed ("String", []) ]; TyVar "T" ];
         return = TySelf;
       })
    (expect_type json)

let test_decode_dimension_shapes () =
  let json =
    Object
      [
        ("kind", String "range");
        ( "inner",
          Object
            [
              ("kind", String "dim_op");
              ("op", String "multiply");
              ("left", Object [ ("kind", String "var_dims"); ("name", String "#N") ]);
              ("right", const_int 2);
            ] );
      ]
  in
  check_type "dimension expression"
    (TyRange (TyDimOp (DimMul, TyVarDims "#N", TyConstInt 2)))
    (expect_type json)

let test_decode_meta_type () =
  check_type "meta type" (TyMeta 42)
    (expect_type
       (Object [ ("kind", String "meta"); ("id", Float 42.0) ]))

let test_decode_widening_metadata () =
  check_widening "keep"
    (Keep (TyNamed ("Int", [])))
    (expect_widening
       (Object [ ("kind", String "keep"); ("type", named "Int") ]));

  check_widening "numeric widen"
    (Widen
       {
         from_ty = TyNamed ("Int", []);
         to_ty = TyNamed ("Float", []);
         reason = NumericOperator Add;
       })
    (expect_widening
       (Object
          [
            ("kind", String "widen");
            ("from_type", named "Int");
            ("to_type", named "Float");
            ( "reason",
              Object [ ("kind", String "numeric_operator"); ("op", String "add") ] );
          ]));

  check_widening "collection widen"
    (Widen
       {
         from_ty = TyNamed ("Int", []);
         to_ty = TyNamed ("Float", []);
         reason = CollectionElement VectorLiteral;
       })
    (expect_widening
       (Object
          [
            ("kind", String "widen");
            ("from_type", named "Int");
            ("to_type", named "Float");
            ( "reason",
              Object
                [
                  ("kind", String "collection_element");
                  ("collection", String "vector");
                ] );
          ]))

let test_decode_type_origin () =
  check_origin "inferred" Inferred
    (expect_origin (Object [ ("kind", String "inferred") ]));
  check_origin "explicit annotation"
    (ExplicitAnnotation (TyNamed ("String", [])))
    (expect_origin
       (Object
          [
            ("kind", String "explicit_annotation");
            ("type", named "String");
          ]));
  check_origin "synthesized" (Synthesized "missing")
    (expect_origin
       (Object
          [
            ("kind", String "synthesized");
            ("label", String "missing");
          ]))

let test_decode_value_proofs () =
  let json =
    Object
      [
        ( "range",
          Object
            [
              ("start", Int 0);
              ( "upper",
                Object
                  [
                    ("kind", String "length_minus");
                    ("identity", Object [ ("name", String "items") ]);
                    ("offset", Int 1);
                  ] );
              ("source", String "loop_range");
            ] );
        ( "subscript",
          Object
            [
              ( "collection",
                Object
                  [
                    ("kind", String "subscript");
                    ( "parent",
                      Object
                        [
                          ("kind", String "var");
                          ("identity", Object [ ("name", String "items") ]);
                        ] );
                    ("identity", Object [ ("name", String "items_row") ]);
                  ] );
              ("source", String "condition");
            ] );
      ]
  in
  let proofs = expect_value_proofs json in
  (match Proof.binding_range_proof proofs with
  | Some
      {
        Proof.range_start = 0;
        range_upper = RangeUpperLengthMinus { coll; end_offset = 1 };
        range_source = ProofSourceLoopRange;
      } ->
      Alcotest.(check string)
        "range collection" "items"
        (Proof.collection_identity_name coll)
  | _ -> Alcotest.fail "decoded range proof did not preserve payload");
  let parent = Option.get (Proof.collection_identity "items") in
  let child = Option.get (Proof.collection_identity "items_row") in
  let expected =
    Proof.collection_subscript
      (Proof.collection_var parent)
      ~index:child
  in
  Alcotest.(check bool)
    "subscript proof" true
    (Proof.binding_proves_subscript proofs ~collection:expected)

let test_decode_resolved_call_info () =
  let info = expect_resolved_call_info resolved_call_info in
  Alcotest.(check string) "callee" "read_chunk_at" info.callee_name;
  Alcotest.(check bool) "callable id" true (info.callable_id = Some 42);
  Alcotest.(check bool) "purity" true (info.purity = Env.Impure);
  (match info.origin with
  | CallableImported "std/file" -> ()
  | _ -> Alcotest.fail "callable origin was not preserved");
  (match info.instantiated_params with
  | [ path_ty; offset_ty ] ->
      check_type "instantiated path" (TyNamed ("String", [])) path_ty;
      check_type "instantiated offset" (TyNamed ("Int", [])) offset_ty
  | _ -> Alcotest.fail "instantiated params were not preserved");
  check_type "instantiated return" (TyNamed ("String", []))
    info.instantiated_return;
  (match info.resource_args with
  | Env.AllowResourceArgs Env.ResourceResultDependent -> ()
  | _ -> Alcotest.fail "resource arg policy was not preserved");
  match info.dim_constraints with
  | [ (left, right) ] ->
      check_type "constraint left" (TyVarDims "#N") left;
      check_type "constraint right" (TyConstInt 4096) right
  | _ -> Alcotest.fail "expected one dimension constraint"

let test_decode_typed_expr_info () =
  let json =
    Object
      [
        ("source_type", named "Int");
        ("semantic_type", const_int 1);
        ("value_type", named "Int");
        ( "origin",
          Object
            [
              ("kind", String "explicit_annotation");
              ("type", named "Int");
            ] );
        ( "value_slot",
          value_slot
            ~decision:
              (Object
                 [
                   ("kind", String "widen");
                   ("from_type", const_int 1);
                   ("to_type", named "Int");
                   ("reason", Object [ ("kind", String "argument_slot") ]);
                 ])
            (const_int 1) );
        ("proofs", no_proofs);
        ("resolved_call", resolved_call_info);
        ("resource_dependencies", Array [ String "reader" ]);
      ]
  in
  let info = expect_expr_info json in
  (match info.source_ty with
  | Some ty -> check_type "source type" (TyNamed ("Int", [])) ty
  | None -> Alcotest.fail "expected source type");
  check_type "semantic type" (TyConstInt 1) info.semantic_ty;
  check_type "value type" (TyNamed ("Int", [])) info.value_ty;
  check_origin "origin" (ExplicitAnnotation (TyNamed ("Int", []))) info.origin;
  check_type "slot semantic" (TyConstInt 1)
    info.value_slot.value_slot_semantic_ty;
  check_widening "slot decision"
    (Widen
       {
         from_ty = TyConstInt 1;
         to_ty = TyNamed ("Int", []);
         reason = ArgumentSlot;
       })
    info.value_slot.value_slot_decision;
  Alcotest.(check (list string))
    "resource dependencies" [ "reader" ] info.resource_dependencies;
  match info.resolved_call with
  | Some call ->
      Alcotest.(check string) "resolved callee" "read_chunk_at" call.callee_name
  | None -> Alcotest.fail "expected resolved call info"

let test_decode_typed_expr_info_rejects_incoherent_metadata () =
  let origin_error =
    expect_expr_info_error
      (Object
         [
           ("source_type", Null);
           ("semantic_type", named "Int");
           ("value_type", named "Int");
           ( "origin",
             Object
               [
                 ("kind", String "explicit_annotation");
                 ("type", named "Int");
               ] );
           ("value_slot", value_slot (named "Int"));
           ("proofs", no_proofs);
           ("resolved_call", Null);
           ("resource_dependencies", Array []);
         ])
  in
  Alcotest.(check string) "origin path" "$.origin" origin_error.path;

  let slot_error =
    expect_expr_info_error
      (Object
         [
           ("source_type", named "Int");
           ("semantic_type", named "Int");
           ("value_type", named "Int");
           ( "origin",
             Object
               [
                 ("kind", String "explicit_annotation");
                 ("type", named "Int");
               ] );
           ("value_slot", value_slot (named "String"));
           ("proofs", no_proofs);
           ("resolved_call", Null);
           ("resource_dependencies", Array []);
         ])
  in
  Alcotest.(check string)
    "slot path" "$.value_slot.semantic_type" slot_error.path

let test_decode_patterns () =
  let name_pattern =
    Object
      [
        ("kind", String "name");
        ("name", ident "x");
        ("type", named "Int");
      ]
  in
  check_pattern "name pattern" (PatVar "x") (expect_pattern name_pattern);

  let list_pattern =
    Object
      [
        ("kind", String "list");
        ( "items",
          Array
            [
              name_pattern;
              Object
                [
                  ("kind", String "int");
                  ("value", String "7");
                ];
            ] );
        ( "spread",
          Object
            [
              ("kind", String "name");
              ("name", ident "rest");
            ] );
      ]
  in
  check_pattern "list spread"
    (PatList ([ PatVar "x"; PatLiteral (LitInt 7L) ], Some (PatVar "rest")))
    (expect_pattern list_pattern);

  let qualified =
    Object
      [
        ("kind", String "qualified_constructor");
        ("module", ident "Option");
        ("name", ident "Some");
        ( "args",
          Array
            [
              Object
                [
                  ("kind", String "string");
                  ("value", String "ok");
                ];
            ] );
      ]
  in
  check_pattern "qualified constructor"
    (PatQualified
       ( "Option",
         "Some",
         [
           PatLiteral
             (LitString ("ok", { sf_multiline = false; sf_raw = false }));
         ] ))
    (expect_pattern qualified);

  let or_pattern =
    Object
      [
        ("kind", String "or");
        ( "items",
          Array
            [
              Object [ ("kind", String "bool"); ("value", Bool true) ];
              Object [ ("kind", String "wildcard") ];
            ] );
      ]
  in
  check_pattern "or pattern"
    (PatOr [ PatLiteral (LitBool true); PatWildcard ])
    (expect_pattern or_pattern)

let test_decode_typed_expr_subset () =
  let name_expr =
    Object
      [
        ("kind", String "name");
        ("name", ident_at "x");
        ("info", expr_info (named "Int"));
      ]
  in
  let binary_expr =
    Object
      [
        ("kind", String "binary");
        ("span", span_json);
        ("info", expr_info (named "Int"));
        ("op", String "add");
        ("left", name_expr);
        ("right", typed_int_literal "1");
      ]
  in
  let block_expr =
    Object
      [
        ("kind", String "block");
        ("span", span_json);
        ("info", expr_info (named "Int"));
        ("items", Array [ binary_expr ]);
      ]
  in
  let typed = expect_typed_expr block_expr in
  check_type "typed expression semantic type" (TyNamed ("Int", []))
    (Typed.semantic_type typed);
  match (Typed.ast typed).expr_desc with
  | EBlock
      [
        {
          expr_desc =
            EBinary
              ( Add,
                { expr_desc = EIdent "x"; _ },
                { expr_desc = ELiteral (LitInt 1L); _ } );
          _;
        };
      ] -> ()
  | _ -> Alcotest.fail "typed expression subset did not decode as expected"

let test_decode_typed_expr_structural_forms () =
  let field_value =
    Object
      [
        ("name", ident_at "value");
        ("value", typed_int_literal "1");
        ("span", span_json);
      ]
  in
  let subscript =
    typed_node "subscript"
      [
        ("receiver", typed_name "items");
        ("indices", Array [ typed_int_literal "0" ]);
      ]
  in
  let structural_block =
    typed_node "block"
      [
        ( "items",
          Array
            [
              typed_node "tuple_destruct"
                [
                  ("names", Array [ ident_at "a"; ident_at "b" ]);
                  ( "value",
                    typed_node "tuple"
                      [ ("items", Array [ typed_int_literal "1"; typed_int_literal "2" ]) ] );
                ];
              typed_node "assign"
                [
                  ("name", ident_at "x");
                  ("scope", String "local");
                  ("value", typed_int_literal "3");
                ];
              subscript;
              typed_node "subscript_assign"
                [
                  ("target", Null);
                  ("receiver", typed_name "items");
                  ("indices", Array [ typed_int_literal "0" ]);
                  ("value", typed_int_literal "4");
                ];
              typed_node "dict"
                [
                  ( "entries",
                    Array
                      [
                        Object
                          [
                            ("key", typed_int_literal "1");
                            ("value", typed_int_literal "2");
                          ];
                      ] );
                ];
              typed_node "opaque_into"
                [
                  ("target_type", named "Int");
                  ("inner", typed_int_literal "5");
                ];
              typed_node "opaque_from"
                [
                  ("source_type", named "Int");
                  ("inner", typed_int_literal "6");
                ];
              typed_node "record" [ ("fields", Array [ field_value ]) ];
              typed_node "record_update"
                [
                  ("receiver", typed_name "box");
                  ("fields", Array [ field_value ]);
                ];
              typed_node "match"
                [
                  ("scrutinee", typed_name "value");
                  ( "cases",
                    Array
                      [
                        Object
                          [
                            ( "pattern",
                              Object
                                [
                                  ("kind", String "int");
                                  ("value", String "1");
                                ] );
                            ("body", typed_int_literal "10");
                            ("span", span_json);
                          ];
                      ] );
                ];
              typed_node "range"
                [
                  ("start", typed_int_literal "0");
                  ("end", typed_int_literal "10");
                ];
              typed_node "ascription"
                [
                  ("inner", typed_int_literal "7");
                  ("target_type", named "Int");
                ];
              typed_node "debug_block" [ ("body", typed_int_literal "8") ];
              typed_node "question_bind"
                [
                  ("name", ident_at "maybe");
                  ("annotation", named "Int");
                  ("value", typed_int_literal "9");
                ];
            ] );
      ]
  in
  let typed = expect_typed_expr structural_block in
  match (Typed.ast typed).expr_desc with
  | EBlock
      [
        { expr_desc = ETupleDestruct ([ "a"; "b" ], _); _ };
        { expr_desc = EAssign ("x", _); _ };
        { expr_desc = ESubscript _; _ };
        { expr_desc = ESubscriptAssign _; _ };
        { expr_desc = EDict [ _ ]; _ };
        { expr_desc = EOpaqueInto _; _ };
        { expr_desc = EOpaqueFrom _; _ };
        { expr_desc = ERecord [ ("value", _) ]; _ };
        { expr_desc = ERecordUpdate (_, [ ("value", _) ]); _ };
        { expr_desc = EMatch (_, [ { case_pattern = PatLiteral (LitInt 1L); _ } ]); _ };
        { expr_desc = ERange _; _ };
        { expr_desc = EAscription _; _ };
        { expr_desc = EDebugBlock [ _ ]; _ };
        { expr_desc = EQuestionBind ("maybe", Some _, _); _ };
      ] -> ()
  | _ -> Alcotest.fail "structural typed expression forms did not decode"

let test_decode_typed_expr_control_and_resource_forms () =
  let int_list = typed_int_list [ typed_int_literal "1"; typed_int_literal "2" ] in
  let channel =
    typed_name_with_type "ch" (named ~args:[ named "Int" ] "Channel")
  in
  let control_block =
    typed_node
      ~info:(expr_info (named "Void"))
      "block"
      [
        ( "items",
          Array
            [
              typed_node
                ~info:(expr_info (named "String"))
                "string_interpolation"
                [
                  ( "parts",
                    Array
                      [
                        Object
                          [
                            ("kind", String "literal");
                            ("text", String "value ");
                          ];
                        Object
                          [
                            ("kind", String "expr");
                            ("expr", typed_int_literal "7");
                          ];
                      ] );
                  ("multiline", Bool false);
                ];
              typed_node
                ~info:
                  (expr_info
                     (function_type [ named "Int" ] (named "Int")))
                "lambda"
                [
                  ("is_pure", Bool true);
                  ( "params",
                    Array
                      [
                        Object
                          [
                            ("name", ident_at "x");
                            ("source_type", Null);
                            ("param_type", named "Int");
                          ];
                      ] );
                  ("return_annotation", Null);
                  ("body", typed_int_literal "1");
                ];
              typed_node
                ~info:(expr_info (named "Void"))
                "select"
                [
                  ( "arms",
                    Array
                      [
                        Object
                          [
                            ( "kind",
                              Object
                                [
                                  ("kind", String "receive");
                                  ("name", ident_at "message");
                                  ("elem_type", named "Int");
                                  ("channel", channel);
                                ] );
                            ("body", typed_void);
                            ("span", span_json);
                          ];
                      ] );
                ];
              typed_node
                ~info:(expr_info (named "Void"))
                "while"
                [
                  ("condition", typed_bool_literal true);
                  ("body", typed_void);
                ];
              typed_node
                ~info:(expr_info (named "Void"))
                "for"
                [
                  ( "binder",
                    Object
                      [
                        ("kind", String "name");
                        ("name", ident_at "item");
                      ] );
                  ("iterable", int_list);
                  ("body", typed_void);
                ];
              typed_node
                ~info:(expr_info (named "Void"))
                "for"
                [
                  ( "binder",
                    Object
                      [
                        ("kind", String "tuple");
                        ("names", Array [ ident_at "key"; ident_at "value" ]);
                        ("span", span_json);
                      ] );
                  ("iterable", int_list);
                  ("body", typed_void);
                ];
              typed_node
                ~info:(expr_info (named "Void"))
                "with"
                [
                  ( "binding",
                    Object
                      [
                        ("name", ident_at "reader");
                        ("annotation", named "Int");
                        ("value", typed_int_literal "1");
                        ("kind", String "plain");
                        ("error_map", Null);
                        ("span", span_json);
                      ] );
                  ("body", typed_void);
                ];
              typed_node
                ~info:(expr_info (named "Void"))
                "concurrent_block"
                [
                  ( "params",
                    Array
                      [
                        typed_concurrent_param "max_threads"
                          (typed_int_literal "2");
                        typed_concurrent_param "timeout" (typed_int_literal "50");
                      ] );
                  ( "bindings",
                    Array [ typed_concurrent_bind "answer" (typed_int_literal "1") ] );
                  ( "body",
                    typed_node
                      ~info:(expr_info (named "Void"))
                      "block"
                      [
                        ( "items",
                          Array
                            [
                              typed_concurrent_bind "answer"
                                (typed_int_literal "1");
                            ] );
                      ] );
                ];
              typed_node
                ~info:(expr_info (named "Void"))
                "concurrent_for"
                [
                  ("name", ident_at "item");
                  ("iterable", int_list);
                  ( "params",
                    Array
                      [
                        typed_concurrent_param "limit" (typed_int_literal "4");
                        typed_concurrent_param "timeout" (typed_int_literal "50");
                      ] );
                  ("body", typed_void);
                ];
              typed_node
                ~info:(expr_info (named "Void"))
                "detach"
                [ ("body", typed_void) ];
            ] );
      ]
  in
  let typed = expect_typed_expr control_block in
  match (Typed.ast typed).expr_desc with
  | EBlock
      [
        { expr_desc = EStringInterp ([ InterpLit "value "; InterpExpr _ ], false); _ };
        { expr_desc = ELambda { func_params = [ { param_name = Some "x"; _ } ]; _ }; _ };
        { expr_desc = ESelect [ { select_arm_kind = SelectRecv { select_bind = "message"; _ }; _ } ]; _ };
        { expr_desc = EWhile _; _ };
        { expr_desc = EFor ("item", _, _); _ };
        { expr_desc = EForTuple ([ "key"; "value" ], _, _); _ };
        { expr_desc = EWith ({ with_name = "reader"; with_kind = WithPlain; _ }, _); _ };
        { expr_desc = EConcurrent ([ { expr_desc = EConcurrentBind ("answer", None, _); _ } ], Some _, Some 2); _ };
        { expr_desc = EConcurrentlyLoop ("item", _, _, Some _, ConcurrentlyLoopLimit 4); _ };
        { expr_desc = EDetach _; _ };
      ] -> ()
  | _ -> Alcotest.fail "control/resource typed expression forms did not decode"

let test_decode_concurrent_block_requires_explicit_bindings () =
  let concurrent_block =
    typed_node
      ~info:(expr_info (named "Void"))
      "concurrent_block"
      [
        ("params", Array []);
        ( "body",
          typed_node
            ~info:(expr_info (named "Void"))
            "block"
            [
              ( "items",
                Array
                  [ typed_concurrent_bind "answer" (typed_int_literal "1") ] );
            ] );
      ]
  in
  let err = expect_typed_expr_error concurrent_block in
  Alcotest.(check string) "path" "$" err.path;
  Alcotest.(check bool)
    "message names missing bindings" true
    (String.contains err.message '`'
    && String.starts_with ~prefix:"missing field" err.message)

let typed_global_var_decl =
  Object
    [
      ("kind", String "global_var");
      ( "info",
        Object
          [
            ( "decl",
              Object
                [
                  ("name", ident_at "answer");
                  ("type", Null);
                  ("value", parsed_int_literal "42");
                  ("is_mutable", Bool false);
                  ("span", span_json);
                ] );
            ("binding_type", named "Int");
            ("source_type", Null);
            ("value", typed_int_literal "42");
          ] );
    ]

let typed_function_info =
  Object
    [
      ( "decl",
        Object
          [
            ("name", ident_at "answer");
            ("type_params", Array []);
            ("params", Array [ parsed_param "x" (parsed_named "Int") ]);
            ("return_type", parsed_named "Int");
            ("dim_constraints", Array []);
            ("body", parsed_int_literal "1");
            ("is_pure", Bool true);
            ("annotations", Array []);
            ("doc", Null);
            ("span", span_json);
          ] );
      ("callable_id", Int 77);
      ("param_types", Array [ named "Int" ]);
      ("source_return_type", named "Int");
      ("semantic_return_type", named "Int");
      ("body", typed_int_literal "1");
    ]

let typed_function_decl =
  Object [ ("kind", String "function"); ("info", typed_function_info) ]

let parsed_impl_method_decl =
  Object
    [
      ("name", ident_at "show");
      ("type_params", Array []);
      ("params", Array [ parsed_param "self" (parsed_named "Int") ]);
      ("return_type", parsed_named "Int");
      ("dim_constraints", Array []);
      ("body", parsed_int_literal "1");
      ("is_pure", Bool true);
      ("annotations", Array []);
      ("doc", Null);
      ("span", span_json);
    ]

let typed_impl_method_info =
  Object
    [
      ("decl", parsed_impl_method_decl);
      ("callable_id", Int 88);
      ("param_types", Array [ named "Int" ]);
      ("source_return_type", named "Int");
      ("semantic_return_type", named "Int");
      ("body", typed_int_literal "1");
    ]

let typed_record_decl =
  Object
    [
      ("kind", String "record");
      ( "info",
        Object
          [
            ( "decl",
              Object
                [
                  ("name", ident_at "Box");
                  ("type_params", Array []);
                  ("fields", Array [ parsed_field "value" (parsed_named "Int") ]);
                  ("is_struct", Bool false);
                  ("doc", Null);
                  ("span", span_json);
                ] );
            ( "fields",
              Array
                [
                  Object
                    [
                      ("name", String "value");
                      ("source_type", named "Int");
                      ("semantic_type", named "String");
                    ];
                ] );
          ] );
    ]

let typed_type_alias_decl =
  Object
    [
      ("kind", String "type_alias");
      ( "info",
        Object
          [
            ( "decl",
              Object
                [
                  ("name", ident_at "Name");
                  ("type_params", Array []);
                  ("target", parsed_named "Int");
                  ("is_opaque", Bool false);
                  ("doc", Null);
                  ("span", span_json);
                ] );
            ("source_target_type", named "Int");
            ("semantic_target_type", named "String");
          ] );
    ]

let typed_impl_decl =
  Object
    [
      ("kind", String "impl");
      ( "info",
        Object
          [
            ( "decl",
              Object
                [
                  ("trait_name", ident_at "Show");
                  ("for_type", parsed_named "Int");
                  ("methods", Array [ parsed_impl_method_decl ]);
                  ("doc", Null);
                  ("span", span_json);
                ] );
            ("for_type", named "Int");
            ("methods", Array [ typed_impl_method_info ]);
          ] );
    ]

let typed_parsed_trait_decl =
  Object
    [
      ("kind", String "parsed");
      ( "decl",
        Object
          [
            ("kind", String "trait");
            ("name", String "Show");
            ( "trait",
              Object
                [
                  ("name", ident_at "Show");
                  ("type_params", Array []);
                  ("supertraits", Array []);
                  ("methods", Array []);
                  ("doc", Null);
                  ("span", span_json);
                ] );
          ] );
    ]

let parsed_variant name =
  Object
    [
      ("name", ident_at name);
      ("fields", Array []);
      ("span", span_json);
    ]

let typed_parsed_enum_decl =
  Object
    [
      ("kind", String "parsed");
      ( "decl",
        Object
          [
            ("kind", String "union");
            ( "union",
              Object
                [
                  ("name", ident_at "Color");
                  ("type_params", Array []);
                  ( "variants",
                    Array
                      [
                        parsed_variant "Red";
                        parsed_variant "Green";
                        parsed_variant "Blue";
                      ] );
                  ("is_enum", Bool true);
                  ("doc", Null);
                  ("span", span_json);
                ] );
          ] );
    ]

let parsed_import_decl ?alias module_path =
  Object
    [
      ("module_path", String module_path);
      ( "module_alias",
        match alias with
        | Some name -> ident_at name
        | None -> Null );
      ("symbols", Null);
      ("span", span_json);
    ]

let typed_parsed_import_block_decl =
  Object
    [
      ("kind", String "parsed");
      ( "decl",
        Object
          [
            ("kind", String "import_block");
            ( "imports",
              Array
                [
                  parsed_import_decl "option";
                  parsed_import_decl ~alias:"D" "dict";
                ] );
            ("span", span_json);
          ] );
    ]

let test_decode_typed_program_global_var () =
  let program =
    expect_typed_program
      (Object
         [
           ("kind", String "typed_program");
           ("source", Object []);
           ("decls", Array [ typed_global_var_decl ]);
           ("diagnostics", Array []);
         ])
  in
  match Typed.program_decls program with
  | [ decl ] -> (
      match Typed.decl_view decl with
      | Typed.DeclVar var ->
          Alcotest.(check (option string))
            "var name" (Some "answer") (Typed.var_ast var).var_name;
          check_type "var binding" (TyNamed ("Int", []))
            (Typed.var_binding_type var)
      | _ -> Alcotest.fail "expected typed var declaration")
  | _ -> Alcotest.fail "expected one typed declaration"

let test_decode_typed_program_function_decl () =
  let program =
    expect_typed_program
      (Object
         [
           ("kind", String "typed_program");
           ("source", Object []);
           ("decls", Array [ typed_function_decl ]);
           ("diagnostics", Array []);
         ])
  in
  match Typed.program_decls program with
  | [ decl ] -> (
      match Typed.decl_view decl with
      | Typed.DeclFunction func ->
          (match (Typed.func_ast func).func_name with
          | Some name -> Alcotest.(check string) "function name" "answer" name
          | None -> Alcotest.fail "expected named function");
          Alcotest.(check (option int))
            "callable id" (Some 77) (Typed.func_callable_id func);
          (match Typed.func_param_infos func with
          | [ param ] ->
              check_type "param type" (TyNamed ("Int", []))
                param.semantic_param_ty
          | _ -> Alcotest.fail "expected one function param");
          (match (Typed.func_info func).source_return_ty with
          | Some ty -> check_type "source return" (TyNamed ("Int", [])) ty
          | None -> Alcotest.fail "expected source return type");
          check_type "semantic return" (TyNamed ("Int", []))
            (Typed.func_semantic_return_type func);
          (match Typed.func_body_expr func with
          | Ok (Some body) ->
              check_type "body type" (TyNamed ("Int", []))
                (Typed.semantic_type body)
          | Ok None -> Alcotest.fail "expected typed function body"
          | Error _ -> Alcotest.fail "function body was not typed")
      | _ -> Alcotest.fail "expected typed function declaration")
  | _ -> Alcotest.fail "expected one typed declaration"

let test_decode_typed_program_record_and_alias_decls () =
  let program =
    expect_typed_program
      (Object
         [
           ("kind", String "typed_program");
           ("source", Object []);
           ("decls", Array [ typed_record_decl; typed_type_alias_decl ]);
           ("diagnostics", Array []);
         ])
  in
  match Typed.program_decls program with
  | [ record_decl; alias_decl ] ->
      (match Typed.decl_view record_decl with
      | Typed.DeclRecord record ->
          Alcotest.(check string)
            "record name" "Box" (Typed.record_ast record).record_name;
          (match Typed.record_field_infos record with
          | [ field ] ->
              Alcotest.(check string) "field name" "value" field.field_name;
              check_type "field source" (TyNamed ("Int", []))
                field.source_field_ty;
              check_type "field semantic" (TyNamed ("String", []))
                field.semantic_field_ty
          | _ -> Alcotest.fail "expected one record field")
      | _ -> Alcotest.fail "expected typed record declaration");
      (match Typed.decl_view alias_decl with
      | Typed.DeclTypeAlias alias ->
          Alcotest.(check string)
            "alias name" "Name" (Typed.type_alias_ast alias).alias_name;
          check_type "alias source" (TyNamed ("Int", []))
            (Typed.type_alias_info alias).source_target_ty;
          check_type "alias semantic" (TyNamed ("String", []))
            (Typed.type_alias_semantic_target_type alias)
      | _ -> Alcotest.fail "expected typed type alias declaration")
  | _ -> Alcotest.fail "expected two typed declarations"

let test_decode_typed_program_impl_decl () =
  let program =
    expect_typed_program
      (Object
         [
           ("kind", String "typed_program");
           ("source", Object []);
           ("decls", Array [ typed_impl_decl ]);
           ("diagnostics", Array []);
         ])
  in
  match Typed.program_decls program with
  | [ decl ] -> (
      match Typed.decl_view decl with
      | Typed.DeclImpl impl ->
          check_type "impl target" (TyNamed ("Int", []))
            (Typed.impl_ast impl).impl_for_type;
          (match Typed.impl_methods impl with
          | [ method_ ] ->
              (match (Typed.func_ast method_).func_name with
              | Some name -> Alcotest.(check string) "method name" "show" name
              | None -> Alcotest.fail "expected named impl method");
              Alcotest.(check (option int))
                "method callable id" (Some 88) (Typed.func_callable_id method_)
          | _ -> Alcotest.fail "expected one impl method")
      | _ -> Alcotest.fail "expected typed impl declaration")
  | _ -> Alcotest.fail "expected one typed declaration"

let test_decode_typed_program_parsed_trait_decl () =
  let program =
    expect_typed_program
      (Object
         [
           ("kind", String "typed_program");
           ("source", Object []);
           ("decls", Array [ typed_parsed_trait_decl ]);
           ("diagnostics", Array []);
         ])
  in
  match Typed.program_decls program with
  | [ decl ] -> (
      match Typed.decl_ast decl with
      | { decl_desc = DTrait trait; _ } ->
          Alcotest.(check string) "trait name" "Show" trait.trait_name
	      | _ -> Alcotest.fail "expected parsed trait declaration")
  | _ -> Alcotest.fail "expected one typed declaration"

let test_decode_typed_program_decorates_parsed_enum_decl () =
  let program =
    expect_typed_program
      (Object
         [
           ("kind", String "typed_program");
           ("source", Object []);
           ("decls", Array [ typed_parsed_enum_decl ]);
           ("diagnostics", Array []);
         ])
  in
  match Typed.program_decls program with
  | [ decl ] -> (
      match Typed.decl_ast decl with
      | { decl_desc = DType type_decl; _ } ->
          Alcotest.(check string) "enum name" "Color" type_decl.type_name;
          let variant_tags =
            List.map (fun variant -> variant.variant_tag) type_decl.type_variants
          in
          Alcotest.(check (list int)) "variant tags" [ 0; 1; 2 ] variant_tags;
          let variant_ids =
            List.map
              (fun variant -> Option.is_some variant.variant_def_id)
              type_decl.type_variants
          in
          Alcotest.(check (list bool))
            "variant ids" [ true; true; true ] variant_ids
      | _ -> Alcotest.fail "expected parsed enum declaration")
  | _ -> Alcotest.fail "expected one typed declaration"

let test_decode_typed_program_flattens_parsed_import_block () =
  let program =
    expect_typed_program
      (Object
         [
           ("kind", String "typed_program");
           ("source", Object []);
           ("decls", Array [ typed_parsed_import_block_decl ]);
           ("diagnostics", Array []);
         ])
  in
  match Typed.program_decls program with
  | [ option_decl; dict_decl ] -> (
      match
        ( (Typed.decl_ast option_decl).decl_desc,
          (Typed.decl_ast dict_decl).decl_desc )
      with
      | DImport option_import, DImport dict_import ->
          Alcotest.(check string) "option module" "option"
            option_import.import_module;
          Alcotest.(check string) "dict module" "dict"
            dict_import.import_module;
          Alcotest.(check (option string)) "dict alias" (Some "D")
            dict_import.import_alias
      | _ -> Alcotest.fail "expected flattened import declarations")
  | _ -> Alcotest.fail "expected flattened import declarations"

let test_decode_typed_expr_resolved_call_metadata () =
  let file_module =
    Object
      [
        ("kind", String "name");
        ("name", ident_at "file");
        ("info", expr_info (named "Module"));
      ]
  in
  let callee =
    Object
      [
        ("kind", String "field_access");
        ("span", span_json);
        ("info", expr_info (function_type [ named "String"; named "Int" ] (named "String")));
        ("receiver", file_module);
        ("field", ident "read_chunk_at");
      ]
  in
  let typed =
    expect_typed_expr
      (Object
         [
           ("kind", String "call");
           ("span", span_json);
           ("info", expr_info ~resolved_call:resolved_call_info (named "String"));
           ("callee", callee);
           ("args", Array []);
         ])
  in
  (match Typed.expr_resolved_call typed with
  | Some
      {
        call_syntax = CallQualified "std/file";
        call_target =
          CallDirect
            {
              callable_id = 42;
              source_name = "read_chunk_at";
              call_pure = false;
              origin = CallableImported "std/file";
            };
        instantiated_params = [ path_ty; offset_ty ];
        instantiated_return;
      } ->
      check_type "resolved path param" (TyNamed ("String", [])) path_ty;
      check_type "resolved offset param" (TyNamed ("Int", [])) offset_ty;
      check_type "resolved return" (TyNamed ("String", [])) instantiated_return
  | Some _ -> Alcotest.fail "resolved call metadata was not materialized"
  | None -> Alcotest.fail "expected resolved call metadata");

  let trait_callee =
    Object
      [
        ("kind", String "name");
        ("name", ident_at "zero");
        ("info", expr_info ~resolved_call:trait_resolved_call_info (function_type [] (type_var "T")));
      ]
  in
  let trait_typed =
    expect_typed_expr
      (Object
         [
           ("kind", String "call");
           ("span", span_json);
           ("info", expr_info ~resolved_call:trait_resolved_call_info (type_var "T"));
           ("callee", trait_callee);
           ("args", Array []);
         ])
  in
  match Typed.expr_resolved_call trait_typed with
  | Some
      {
        call_syntax = CallBare;
        call_target =
          CallTraitMethod
            {
              trait_name = "HasZero";
              method_name = "zero";
              call_pure = true;
              callable_id = None;
            };
        instantiated_params = [];
        instantiated_return;
      } ->
      check_type "trait return" (TyVar "T") instantiated_return
  | Some _ -> Alcotest.fail "trait resolved call metadata was not materialized"
  | None -> Alcotest.fail "expected trait resolved call metadata"

let test_decode_imported_bare_call_uses_ufcs_callee () =
  let callee =
    Object
      [
        ("kind", String "name");
        ("name", ident_at "make_string");
        ( "info",
          expr_info
            (function_type ~pure:true [ named "Int" ] (named "String")) );
      ]
  in
  let typed =
    expect_typed_expr
      (Object
         [
           ("kind", String "call");
           ("span", span_json);
           ( "info",
             expr_info ~resolved_call:imported_string_split_resolved_call_info
               (named "String") );
           ("callee", callee);
           ("args", Array [ typed_int_literal "16" ]);
         ])
  in
  match (Typed.ast typed).expr_desc with
  | ECall ({ expr_desc = EIdent "__ufcs_std$string__string"; _ }, _) -> ()
  | _ -> Alcotest.fail "imported bare call did not decode to UFCS callee"

let test_decode_rejects_unsupported_pattern () =
  match
    Blorp.Typed_ast_json.decode_pattern "$"
      (Object
         [
           ("kind", String "unsupported");
           ("label", String "missing");
         ])
  with
  | Ok _ -> Alcotest.fail "expected unsupported pattern decode error"
  | Error err ->
      Alcotest.(check string) "path" "$" err.path;
      Alcotest.(check bool)
        "message mentions label" true
        (String.contains err.message '`')

let test_decode_rejects_unknown_kind () =
  let err = expect_error (Object [ ("kind", String "mystery") ]) in
  Alcotest.(check string) "path" "$.kind" err.path;
  Alcotest.(check bool)
    "message mentions kind" true
    (String.contains err.message '`')

let suite =
  [
    ( "type decoder",
      [
        Alcotest.test_case "span" `Quick test_decode_span;
        Alcotest.test_case "named and array" `Quick test_decode_named_and_array;
        Alcotest.test_case "function tuple and vars" `Quick
          test_decode_function_tuple_and_vars;
        Alcotest.test_case "dimension shapes" `Quick test_decode_dimension_shapes;
        Alcotest.test_case "meta type" `Quick test_decode_meta_type;
        Alcotest.test_case "widening metadata" `Quick
          test_decode_widening_metadata;
        Alcotest.test_case "type origin" `Quick test_decode_type_origin;
        Alcotest.test_case "value proofs" `Quick test_decode_value_proofs;
        Alcotest.test_case "resolved call info" `Quick
          test_decode_resolved_call_info;
        Alcotest.test_case "typed expr info" `Quick
          test_decode_typed_expr_info;
        Alcotest.test_case "typed expr info coherence" `Quick
          test_decode_typed_expr_info_rejects_incoherent_metadata;
        Alcotest.test_case "patterns" `Quick test_decode_patterns;
        Alcotest.test_case "typed expr subset" `Quick
          test_decode_typed_expr_subset;
        Alcotest.test_case "typed expr structural forms" `Quick
          test_decode_typed_expr_structural_forms;
        Alcotest.test_case "typed expr control/resource forms" `Quick
          test_decode_typed_expr_control_and_resource_forms;
        Alcotest.test_case "concurrent block requires explicit bindings" `Quick
          test_decode_concurrent_block_requires_explicit_bindings;
        Alcotest.test_case "typed program global var" `Quick
          test_decode_typed_program_global_var;
        Alcotest.test_case "typed program function" `Quick
          test_decode_typed_program_function_decl;
        Alcotest.test_case "typed program record and alias" `Quick
          test_decode_typed_program_record_and_alias_decls;
        Alcotest.test_case "typed program impl" `Quick
          test_decode_typed_program_impl_decl;
        Alcotest.test_case "typed program parsed passthrough" `Quick
          test_decode_typed_program_parsed_trait_decl;
        Alcotest.test_case "typed program parsed enum metadata" `Quick
          test_decode_typed_program_decorates_parsed_enum_decl;
        Alcotest.test_case "typed program parsed import block" `Quick
          test_decode_typed_program_flattens_parsed_import_block;
        Alcotest.test_case "typed expr resolved call metadata" `Quick
          test_decode_typed_expr_resolved_call_metadata;
        Alcotest.test_case "imported bare call uses UFCS callee" `Quick
          test_decode_imported_bare_call_uses_ufcs_callee;
        Alcotest.test_case "unsupported pattern" `Quick
          test_decode_rejects_unsupported_pattern;
        Alcotest.test_case "unknown kind" `Quick test_decode_rejects_unknown_kind;
      ] );
  ]
