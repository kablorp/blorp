(** Tests for late Core tensor static type facts. *)

open Blorp.Ast

let ty name args = TyNamed (name, args)
let ty_float = ty "Float" []
let ty_float32 = ty "Float32" []
let ty_int = ty "Int" []
let dim n = TyConstInt n

let registry_with_aliases () =
  let reg = Blorp.Codegen_types.create_registry () in
  Hashtbl.replace reg.type_aliases "Meters" ([], ty_float);
  Hashtbl.replace reg.type_aliases "Positions"
    ([], ty "Vector" [ ty "Meters" []; dim 3 ]);
  reg

let expect_tensor msg reg ty =
  match Blorp.Core_tensor_type.of_type ~reg ty with
  | Some info -> info
  | None -> Alcotest.fail (msg ^ ": expected tensor type facts")

let test_vector_alias_normalizes_to_tensor_facts () =
  let reg = registry_with_aliases () in
  let info = expect_tensor "alias" reg (ty "Positions" []) in
  Alcotest.(check bool)
    "semantic type is canonical tensor" true
    (Blorp.Types.types_equal info.semantic_ty (ty "Tensor" [ ty_float; dim 3 ]));
  Alcotest.(check bool)
    "element alias is expanded" true
    (Blorp.Types.types_equal info.elem_ty ty_float);
  Alcotest.(check int) "one dimension" 1 (List.length info.dims)

let test_scalar_is_not_tensor_after_zero_dim_normalization () =
  let reg = Blorp.Codegen_types.create_registry () in
  Alcotest.(check bool)
    "Tensor[T] normalizes to scalar, not tensor facts" true
    (Blorp.Core_tensor_type.of_type ~reg (ty "Tensor" [ ty_int ]) = None);
  Alcotest.(check bool)
    "is_type follows tensor fact availability" false
    (Blorp.Core_tensor_type.is_type ~reg (ty "Tensor" [ ty_int ]))

let test_same_static_shape_ignores_element_type () =
  let reg = Blorp.Codegen_types.create_registry () in
  let floats =
    expect_tensor "float vector" reg (ty "Vector" [ ty_float; dim 4 ])
  in
  let ints = expect_tensor "int vector" reg (ty "Vector" [ ty_int; dim 4 ]) in
  let matrix =
    expect_tensor "float matrix" reg (ty "Matrix" [ ty_float; dim 2; dim 2 ])
  in
  Alcotest.(check bool)
    "same dims are same static shape" true
    (Blorp.Core_tensor_type.same_static_shape floats ints);
  Alcotest.(check bool)
    "different rank is not same static shape" false
    (Blorp.Core_tensor_type.same_static_shape floats matrix)

let test_floating_scalar_classification_is_explicit () =
  let reg = registry_with_aliases () in
  let positions = expect_tensor "positions" reg (ty "Positions" []) in
  let f32 =
    expect_tensor "float32 vector" reg (ty "Vector" [ ty_float32; dim 3 ])
  in
  Alcotest.(check bool)
    "Float tensor element is Float64 fusion scalar" true
    (Blorp.Core_tensor_type.floating_scalar_of_tensor positions
    = Some Blorp.Core_tensor_type.Float64);
  Alcotest.(check bool)
    "Float32 tensor element is Float32 fusion scalar" true
    (Blorp.Core_tensor_type.floating_scalar_of_tensor f32
    = Some Blorp.Core_tensor_type.Float32);
  Alcotest.(check bool)
    "Int has no floating fusion scalar" true
    (Blorp.Core_tensor_type.floating_scalar_of_type ~reg ty_int = None)

let project_type reg typ =
  let names = Blorp.Core_emit_blorp_c.StringSet.empty in
  match
    Blorp.Core_emit_blorp_c.type_json ~reg names names names names "type" typ
  with
  | Ok json -> Blorp.Lsp_json.to_string json
  | Error error ->
      Alcotest.fail (Blorp.Core_emit_blorp_c.unsupported_to_string error)

let test_projection_canonicalizes_ordinary_tensor_spellings () =
  let reg = Blorp.Codegen_types.create_registry () in
  let expected_vector =
    {|{"kind":"tensor","info":{"element_type":{"kind":"named","name":"Float32","args":[]},"dims":[{"kind":"static","value":4}]}}|}
  in
  let vector_spellings =
    [
      ty "Vector" [ ty_float32; dim 4 ];
      ty "Tensor" [ ty_float32; dim 4 ];
      TyArray (ty_float32, [ dim 4 ]);
    ]
  in
  List.iter
    (fun typ ->
      Alcotest.(check string)
        "ordinary vector spelling projects as tensor" expected_vector
        (project_type reg typ))
    vector_spellings;
  Alcotest.(check string)
    "matrix spelling preserves both dimensions"
    {|{"kind":"tensor","info":{"element_type":{"kind":"named","name":"Float","args":[]},"dims":[{"kind":"static","value":2},{"kind":"static","value":3}]}}|}
    (project_type reg (ty "Matrix" [ ty_float; dim 2; dim 3 ]))

let test_projection_expands_tensor_aliases () =
  let reg = registry_with_aliases () in
  Alcotest.(check string)
    "aliases project as their canonical tensor type"
    {|{"kind":"tensor","info":{"element_type":{"kind":"named","name":"Float","args":[]},"dims":[{"kind":"static","value":3}]}}|}
    (project_type reg (ty "Positions" []))

let test_projection_normalizes_zero_dim_tensor_to_scalar () =
  let reg = Blorp.Codegen_types.create_registry () in
  Alcotest.(check string)
    "zero-dimensional tensor projects as its scalar element"
    {|{"kind":"named","name":"Int","args":[]}|}
    (project_type reg (ty "Tensor" [ ty_int ]))

let test_projection_keeps_parallel_tensor_views_distinct () =
  let reg = Blorp.Codegen_types.create_registry () in
  Alcotest.(check string)
    "parallel view is not projected as ordinary tensor storage"
    {|{"kind":"named","name":"ParallelVector","args":[{"kind":"named","name":"Float","args":[]},{"kind":"named","name":"Int","args":[]}]}|}
    (project_type reg (ty "ParallelVector" [ ty_float; dim 4 ]))

let suite =
  [
    ( "facts",
      [
        Alcotest.test_case "vector alias normalizes to tensor facts" `Quick
          test_vector_alias_normalizes_to_tensor_facts;
        Alcotest.test_case "0D tensor normalization is scalar" `Quick
          test_scalar_is_not_tensor_after_zero_dim_normalization;
        Alcotest.test_case "same static shape ignores element type" `Quick
          test_same_static_shape_ignores_element_type;
        Alcotest.test_case "floating scalar classification is explicit" `Quick
          test_floating_scalar_classification_is_explicit;
        Alcotest.test_case "projection canonicalizes tensor spellings" `Quick
          test_projection_canonicalizes_ordinary_tensor_spellings;
        Alcotest.test_case "projection expands tensor aliases" `Quick
          test_projection_expands_tensor_aliases;
        Alcotest.test_case "projection normalizes 0D tensor to scalar" `Quick
          test_projection_normalizes_zero_dim_tensor_to_scalar;
        Alcotest.test_case "projection preserves parallel tensor views" `Quick
          test_projection_keeps_parallel_tensor_views_distinct;
      ] );
  ]
