open Blorp.Ast

let check_key label expected ty =
  Alcotest.(check (option string))
    label expected
    (Blorp.Codegen_types.type_key_for_impl ty)

let test_impl_key_bridge_contract () =
  let named name = TyNamed (name, []) in
  check_key "named" (Some "Widget") (named "Widget");
  check_key "parameterized" (Some "Result_Int_String")
    (TyNamed ("Result", [ named "Int"; named "String" ]));
  check_key "tuple" (Some "Tuple2_Int_String")
    (TyTuple [ named "Int"; named "String" ]);
  check_key "empty tuple" (Some "Tuple0_") (TyTuple []);
  check_key "Void" (Some "Void") (named "Void");
  check_key "range" None (TyRange (named "Int"));
  check_key "range argument" None
    (TyNamed ("Wrapper", [ TyRange (named "Int") ]));
  check_key "array" (Some "__Array_Int_4")
    (TyArray (named "Int", [ TyConstInt 4 ]));
  check_key "exact array dimension division" (Some "__Array_Int_2")
    (TyArray (named "Int", [ TyDimOp (DimDiv, TyConstInt 4, TyConstInt 2) ]));
  check_key "inexact array dimension division" None
    (TyArray (named "Int", [ TyDimOp (DimDiv, TyConstInt 5, TyConstInt 2) ]));
  check_key "nonzero array dimension division by zero" None
    (TyArray (named "Int", [ TyDimOp (DimDiv, TyConstInt 4, TyConstInt 0) ]));
  check_key "zero array dimension division by zero" (Some "__Array_Int_0")
    (TyArray (named "Int", [ TyDimOp (DimDiv, TyConstInt 0, TyConstInt 0) ]));
  check_key "zero array dimension division by unresolved" (Some "__Array_Int_0")
    (TyArray (named "Int", [ TyDimOp (DimDiv, TyConstInt 0, TyVar "#N") ]));
  check_key "left-zero array dimension multiplication" (Some "__Array_Int_0")
    (TyArray (named "Int", [ TyDimOp (DimMul, TyConstInt 0, TyVar "#N") ]));
  check_key "right-zero array dimension multiplication" (Some "__Array_Int_0")
    (TyArray (named "Int", [ TyDimOp (DimMul, TyVar "#N", TyConstInt 0) ]));
  check_key "self-subtracting array dimension" (Some "__Array_Int_0")
    (TyArray (named "Int", [ TyDimOp (DimSub, TyVar "#N", TyVar "#N") ]))

let suite =
  [
    ( "type_key_for_impl",
      [
        Alcotest.test_case "matches the Blorp bridge contract" `Quick
          test_impl_key_bridge_contract;
      ] );
  ]
