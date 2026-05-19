(** Unit tests for type-expression formatting.

    These mirror [tests/test_blorp/tools/test_fmt_type_doc.brp] so the OCaml
    formatter printer and the Blorp type-doc printer stay pinned to the same
    visible syntax while this formatter slice is ported. *)

module Ast = Blorp.Ast
module Layout = Blorp.Fmt_layout
module Printer = Blorp.Fmt_printer

let check_string msg = Alcotest.(check string) msg
let layout_type ty = Layout.layout (Printer.print_type_expr ty)
let named name args = Ast.TyNamed (name, args)
let var name = Ast.TyVar name

let test_named_type_doc () =
  let ty =
    named "Dict" [ named "String" []; named "List" [ named "Int" [] ] ]
  in
  check_string "named type docs" "Dict[String, List[Int]]\n" (layout_type ty)

let test_pure_func_type_doc () =
  let ty =
    Ast.TyFunc
      {
        is_pure = true;
        params = [ named "Int" []; named "String" [] ];
        return = named "Option" [ named "Bool" [] ];
      }
  in
  check_string "pure function type docs" "pure (Int, String) -> Option[Bool]\n"
    (layout_type ty)

let test_array_function_elem_is_parenthesized () =
  let elem =
    Ast.TyFunc
      {
        is_pure = true;
        params = [ named "Int" [] ];
        return = named "String" [];
      }
  in
  let ty = Ast.TyArray (elem, [ var "#N" ]) in
  check_string "array function elem" "(pure (Int) -> String)[#N]\n"
    (layout_type ty)

let test_dim_precedence () =
  let ty =
    named "Tensor"
      [
        Ast.TyDimOp
          (Ast.DimMul, Ast.TyDimOp (Ast.DimAdd, var "#M", var "#N"), var "#K");
      ]
  in
  check_string "dimension precedence" "Tensor[(#M + #N) * #K]\n"
    (layout_type ty)

let test_misc_type_doc () =
  let ty =
    Ast.TyTuple
      [
        Ast.TySelf;
        Ast.TyRange (Ast.TyConstInt 8);
        Ast.TyVarDims "#Ds";
        Ast.TyBoundVar (Ast.make_type_param "T" [ "Stringable" ]);
        Ast.TyMeta 7;
      ]
  in
  check_string "misc type docs" "(Self, ..#8, #Ds..., T:Stringable, ?m7)\n"
    (layout_type ty)

let suite =
  [
    ( "type_doc",
      [
        Alcotest.test_case "named type docs" `Quick test_named_type_doc;
        Alcotest.test_case "pure function type docs" `Quick
          test_pure_func_type_doc;
        Alcotest.test_case "array function element type is parenthesized" `Quick
          test_array_function_elem_is_parenthesized;
        Alcotest.test_case "dimension precedence" `Quick test_dim_precedence;
        Alcotest.test_case "misc type docs" `Quick test_misc_type_doc;
      ] );
  ]
