(** Unit tests for structured generic parameter helpers. *)

open Blorp.Generic_params

let test_source_spelling () =
  let bounded = make_bound_type_param "T" [ "Stringable"; "Showable" ] in
  Alcotest.(check string) "name" "T" bounded.param_name;
  Alcotest.(check (list string))
    "bounds"
    [ "Stringable"; "Showable" ]
    (trait_ref_names bounded.param_bounds);
  Alcotest.(check string)
    "roundtrip" "T:Stringable+Showable" (to_parser_string bounded);

  let unbounded = make_bound_type_param "U" [] in
  Alcotest.(check string) "unbounded name" "U" unbounded.param_name;
  Alcotest.(check (list string))
    "unbounded bounds" []
    (trait_ref_names unbounded.param_bounds);
  Alcotest.(check string) "unbounded roundtrip" "U" (to_parser_string unbounded)

let test_param_list_helpers () =
  let params =
    [ make_bound_type_param "T" [ "Equatable" ]; make_bound_type_param "U" [] ]
  in
  Alcotest.(check (list string)) "param names" [ "T"; "U" ] (param_names params);
  Alcotest.(check (list string))
    "encoded" [ "T:Equatable"; "U" ]
    (List.map to_parser_string params)

let test_constructor_helpers () =
  let param = make_bound_type_param "Item" [ "Hashable"; "Equatable" ] in
  Alcotest.(check string)
    "trait ref" "Hashable"
    (trait_ref_name (trait_ref "Hashable"));
  Alcotest.(check (list string))
    "constructed bounds"
    [ "Hashable"; "Equatable" ]
    (trait_ref_names param.param_bounds)

let suite =
  [
    ( "params",
      [
        Alcotest.test_case "source spelling" `Quick test_source_spelling;
        Alcotest.test_case "param list helpers" `Quick test_param_list_helpers;
        Alcotest.test_case "constructor helpers" `Quick test_constructor_helpers;
      ] );
  ]
