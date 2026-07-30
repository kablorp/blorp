(** Unit tests for Types module *)

open Blorp.Ast
open Blorp.Types

(* ============================================================================
   Helpers
   ============================================================================ *)

let check_true msg b = Alcotest.(check bool) msg true b
let check_false msg b = Alcotest.(check bool) msg false b
let check_string msg = Alcotest.(check string) msg

let check_some msg = function
  | Some _ -> Alcotest.(check bool) msg true true
  | None -> Alcotest.fail (msg ^ ": expected Some, got None")

let check_none msg = function
  | Some _ -> Alcotest.fail (msg ^ ": expected None, got Some")
  | None -> Alcotest.(check bool) msg true true

(* ============================================================================
   type_to_string
   ============================================================================ *)

let test_type_to_string_simple () =
  check_string "Int" "Int" (type_to_string ty_int);
  check_string "String" "String" (type_to_string ty_string);
  check_string "Bool" "Bool" (type_to_string ty_bool);
  check_string "Void" "Void" (type_to_string ty_void);
  check_string "Char" "Char" (type_to_string ty_char)

let test_type_to_string_parameterized () =
  check_string "List[Int]" "List[Int]"
    (type_to_string (TyNamed ("List", [ ty_int ])));
  check_string "Dict[String, Int]" "Dict[String, Int]"
    (type_to_string (TyNamed ("Dict", [ ty_string; ty_int ])));
  check_string "Option[List[Int]]" "Option[List[Int]]"
    (type_to_string (TyNamed ("Option", [ TyNamed ("List", [ ty_int ]) ])))

let test_type_to_string_func () =
  check_string "impure func" "(Int, String) -> Bool"
    (type_to_string (ty_func [ ty_int; ty_string ] ty_bool));
  check_string "pure func" "pure (Int) -> Int"
    (type_to_string (ty_func ~pure:true [ ty_int ] ty_int))

let test_type_to_string_tuple () =
  check_string "TyTuple" "(Int, String)"
    (type_to_string (TyTuple [ ty_int; ty_string ]));
  check_string "TyNamed Tuple" "(Int, String)"
    (type_to_string (TyNamed ("Tuple", [ ty_int; ty_string ])))

let test_type_to_string_tyvar () =
  check_string "type var" "T" (type_to_string (TyVar "T"));
  check_string "fresh var" "$t0" (type_to_string (TyVar "$t0"))

let test_type_to_string_special () =
  check_string "Self" "Self" (type_to_string TySelf);
  check_string "VarDims" "#Ds..." (type_to_string (TyVarDims "#Ds"));
  check_string "VarDims named" "#N..." (type_to_string (TyVarDims "#N"));
  check_string "ConstInt" "#5" (type_to_string (TyConstInt 5));
  check_string "Range" "..#3" (type_to_string (TyRange (TyConstInt 3)))

(* ============================================================================
   types_equal
   ============================================================================ *)

let test_types_equal_basic () =
  check_true "Int = Int" (types_equal ty_int ty_int);
  check_false "Int != String" (types_equal ty_int ty_string);
  check_true "TyVar T = TyVar T" (types_equal (TyVar "T") (TyVar "T"));
  check_false "TyVar T != TyVar U" (types_equal (TyVar "T") (TyVar "U"))

let test_types_equal_parameterized () =
  check_true "List[Int] = List[Int]"
    (types_equal (TyNamed ("List", [ ty_int ])) (TyNamed ("List", [ ty_int ])));
  check_false "List[Int] != List[String]"
    (types_equal
       (TyNamed ("List", [ ty_int ]))
       (TyNamed ("List", [ ty_string ])));
  check_false "List[Int] != Dict[Int, Int]"
    (types_equal
       (TyNamed ("List", [ ty_int ]))
       (TyNamed ("Dict", [ ty_int; ty_int ])))

let test_types_equal_tensor_normalization () =
  check_true "Vector = Tensor"
    (types_equal
       (TyNamed ("Vector", [ ty_float; TyConstInt 3 ]))
       (TyNamed ("Tensor", [ ty_float; TyConstInt 3 ])));
  check_true "Matrix = Tensor"
    (types_equal
       (TyNamed ("Matrix", [ ty_float; TyConstInt 3; TyConstInt 3 ]))
       (TyNamed ("Tensor", [ ty_float; TyConstInt 3; TyConstInt 3 ])));
  check_true "Vector = Matrix (both Tensor)"
    (types_equal
       (TyNamed ("Vector", [ ty_float; TyConstInt 3 ]))
       (TyNamed ("Matrix", [ ty_float; TyConstInt 3 ])))

let test_types_equal_func () =
  let f1 = TyFunc { params = [ ty_int ]; return = ty_bool; is_pure = true } in
  let f2 = TyFunc { params = [ ty_int ]; return = ty_bool; is_pure = true } in
  let f3 = TyFunc { params = [ ty_int ]; return = ty_bool; is_pure = false } in
  check_true "same pure func" (types_equal f1 f2);
  check_false "pure != impure" (types_equal f1 f3)

let test_types_equal_tuple_named () =
  check_true "TyTuple = TyNamed Tuple"
    (types_equal
       (TyTuple [ ty_int; ty_string ])
       (TyNamed ("Tuple", [ ty_int; ty_string ])));
  check_true "TyNamed Tuple = TyTuple"
    (types_equal
       (TyNamed ("Tuple", [ ty_int; ty_string ]))
       (TyTuple [ ty_int; ty_string ]))

let test_types_equal_special () =
  check_true "Self = Self" (types_equal TySelf TySelf);
  check_true "VarDims same name" (types_equal (TyVarDims "a") (TyVarDims "a"));
  check_false "VarDims diff name" (types_equal (TyVarDims "a") (TyVarDims "b"));
  check_true "ConstInt 5 = ConstInt 5"
    (types_equal (TyConstInt 5) (TyConstInt 5));
  check_false "ConstInt 5 != ConstInt 3"
    (types_equal (TyConstInt 5) (TyConstInt 3));
  check_true "Range = Range"
    (types_equal (TyRange (TyConstInt 5)) (TyRange (TyConstInt 5)))

(* ============================================================================
   normalize_type_name
   ============================================================================ *)

let test_normalize_type_name () =
  check_string "Vector" "Tensor" (normalize_type_name "Vector");
  check_string "Matrix" "Tensor" (normalize_type_name "Matrix");
  check_string "Tensor" "Tensor" (normalize_type_name "Tensor");
  check_string "List" "List" (normalize_type_name "List")

(* ============================================================================
   strip_type_param_bounds
   ============================================================================ *)

let test_strip_type_param_bounds () =
  check_string "no bounds" "T" (strip_type_param_bounds "T");
  check_string "with bound" "T" (strip_type_param_bounds "T:Stringable");
  check_string "multi bound" "T"
    (strip_type_param_bounds "T:Stringable+Showable")

(* ============================================================================
   collect_type_vars
   ============================================================================ *)

let test_collect_type_vars () =
  let vars = collect_type_vars (TyVar "T") in
  check_true "TyVar T" (List.mem "T" vars);

  let vars = collect_type_vars (TyNamed ("List", [ TyVar "T" ])) in
  check_true "List[T]" (List.mem "T" vars);

  (* Single uppercase letter as TyNamed -> treated as type var *)
  let vars = collect_type_vars (TyNamed ("T", [])) in
  check_true "TyNamed T" (List.mem "T" vars);

  (* "Int" is not a type var (too long, concrete) *)
  let vars = collect_type_vars ty_int in
  check_true "Int has no vars" (vars = []);

  (* Nested *)
  let vars =
    collect_type_vars
      (TyFunc { params = [ TyVar "A" ]; return = TyVar "B"; is_pure = false })
  in
  check_true "func A" (List.mem "A" vars);
  check_true "func B" (List.mem "B" vars)

(* ============================================================================
   instantiate_type_params
   ============================================================================ *)

let test_instantiate_type_params () =
  let result =
    instantiate_type_params [ "T" ] (TyNamed ("List", [ TyNamed ("T", []) ]))
  in
  check_true "T -> TyVar T"
    (types_equal result (TyNamed ("List", [ TyVar "T" ])));

  (* Non-matching names left alone *)
  let result = instantiate_type_params [ "T" ] (TyNamed ("Int", [])) in
  check_true "Int unchanged" (types_equal result ty_int)

(* ============================================================================
   occurs_in
   ============================================================================ *)

let test_occurs_in () =
  check_true "direct" (occurs_in "T" (TyVar "T"));
  check_false "different var" (occurs_in "T" (TyVar "U"));
  check_true "nested in List" (occurs_in "T" (TyNamed ("List", [ TyVar "T" ])));
  check_true "in func param"
    (occurs_in "T"
       (TyFunc { params = [ TyVar "T" ]; return = ty_int; is_pure = false }));
  check_true "in func return"
    (occurs_in "T"
       (TyFunc { params = [ ty_int ]; return = TyVar "T"; is_pure = false }));
  check_false "not present" (occurs_in "T" ty_int)

(* ============================================================================
   apply_subst
   ============================================================================ *)

let test_apply_subst_basic () =
  let subst = [ { var_name = "T"; concrete_type = ty_int } ] in
  let result = apply_subst subst (TyVar "T") in
  check_true "T -> Int" (types_equal result ty_int);

  let result = apply_subst subst (TyVar "U") in
  check_true "U unchanged" (types_equal result (TyVar "U"))

let test_apply_subst_nested () =
  let subst = [ { var_name = "T"; concrete_type = ty_int } ] in
  let result = apply_subst subst (TyNamed ("List", [ TyVar "T" ])) in
  check_true "List[T] -> List[Int]"
    (types_equal result (TyNamed ("List", [ ty_int ])))

let test_apply_subst_chained () =
  (* T -> U, U -> Int should resolve T -> Int *)
  let subst =
    [
      { var_name = "T"; concrete_type = TyVar "U" };
      { var_name = "U"; concrete_type = ty_int };
    ]
  in
  let result = apply_subst subst (TyVar "T") in
  check_true "T -> U -> Int" (types_equal result ty_int)

let test_apply_subst_cycle_detection () =
  (* T -> U, U -> T: should not loop forever *)
  let subst =
    [
      { var_name = "T"; concrete_type = TyVar "U" };
      { var_name = "U"; concrete_type = TyVar "T" };
    ]
  in
  let _result = apply_subst subst (TyVar "T") in
  (* Just checking it terminates *)
  check_true "terminates" true

let test_apply_subst_func () =
  let subst =
    [
      { var_name = "A"; concrete_type = ty_int };
      { var_name = "B"; concrete_type = ty_string };
    ]
  in
  let ty =
    TyFunc { params = [ TyVar "A" ]; return = TyVar "B"; is_pure = true }
  in
  let result = apply_subst subst ty in
  let expected =
    TyFunc { params = [ ty_int ]; return = ty_string; is_pure = true }
  in
  check_true "(A) -> B => (Int) -> String" (types_equal result expected)

let test_apply_subst_self () =
  let subst = [ { var_name = "Self"; concrete_type = ty_int } ] in
  let result = apply_subst subst TySelf in
  check_true "Self -> Int" (types_equal result ty_int)

let test_apply_type_param_subst_uses_explicit_type_vars () =
  let subst = [ ("T", ty_int) ] in
  check_true "TyVar with bound uses stripped key"
    (types_equal (apply_type_param_subst subst (TyVar "T:Stringable")) ty_int);
  check_true "nested TyVar with bound uses stripped key"
    (types_equal
       (apply_type_param_subst subst
          (TyNamed ("List", [ TyVar "T:Stringable" ])))
       (TyNamed ("List", [ ty_int ])));
  let raw_subst = [ ("T:Stringable", ty_string) ] in
  check_true "raw bound-bearing key still works"
    (types_equal
       (apply_type_param_subst raw_subst (TyVar "T:Stringable"))
       ty_string);
  check_true "one-letter nominal type remains nominal"
    (types_equal
       (apply_type_param_subst subst (TyNamed ("T", [])))
       (TyNamed ("T", [])))

(* ============================================================================
   unify
   ============================================================================ *)

let test_unify_identical () =
  check_some "Int = Int" (unify ty_int ty_int);
  check_some "String = String" (unify ty_string ty_string)

let test_unify_mismatch () = check_none "Int != String" (unify ty_int ty_string)

let test_unify_tyvar_left () =
  let result = unify (TyVar "T") ty_int in
  check_some "T unifies with Int" result;
  match result with
  | Some subst ->
      let resolved = apply_subst subst (TyVar "T") in
      check_true "T = Int" (types_equal resolved ty_int)
  | None -> ()

let test_unify_tyvar_right_asymmetric () =
  (* Default: non-symmetric, so RHS TyVar doesn't bind *)
  check_none "Int vs T (asymmetric)" (unify ty_int (TyVar "T"))

let test_unify_tyvar_right_symmetric () =
  let result = unify ~symmetric:true ty_int (TyVar "T") in
  check_some "Int vs T (symmetric)" result

let test_unify_parameterized () =
  let result =
    unify (TyNamed ("List", [ TyVar "T" ])) (TyNamed ("List", [ ty_int ]))
  in
  check_some "List[T] = List[Int]" result;
  match result with
  | Some subst ->
      let resolved = apply_subst subst (TyVar "T") in
      check_true "T = Int" (types_equal resolved ty_int)
  | None -> ()

let test_unify_consistent_binding () =
  (* T must bind consistently *)
  let result =
    unify
      (TyNamed ("Dict", [ TyVar "T"; TyVar "T" ]))
      (TyNamed ("Dict", [ ty_int; ty_int ]))
  in
  check_some "Dict[T,T] = Dict[Int,Int]" result;

  let result =
    unify
      (TyNamed ("Dict", [ TyVar "T"; TyVar "T" ]))
      (TyNamed ("Dict", [ ty_int; ty_string ]))
  in
  check_none "Dict[T,T] != Dict[Int,String]" result

let test_unify_func_purity_covariance () =
  (* Pure function can satisfy impure expectation *)
  let pure_fn =
    TyFunc { params = [ ty_int ]; return = ty_int; is_pure = true }
  in
  let impure_fn =
    TyFunc { params = [ ty_int ]; return = ty_int; is_pure = false }
  in
  check_some "impure expected, pure actual" (unify impure_fn pure_fn);
  check_none "pure expected, impure actual" (unify pure_fn impure_fn)

let test_unify_tensor_normalization () =
  check_some "Vector = Tensor"
    (unify
       (TyNamed ("Vector", [ TyVar "T"; TyConstInt 3 ]))
       (TyNamed ("Tensor", [ ty_float; TyConstInt 3 ])))

let test_unify_tuple_forms () =
  check_some "TyTuple = TyNamed Tuple"
    (unify
       (TyTuple [ TyVar "A"; TyVar "B" ])
       (TyNamed ("Tuple", [ ty_int; ty_string ])));
  check_some "TyNamed Tuple = TyTuple"
    (unify
       (TyNamed ("Tuple", [ TyVar "A"; TyVar "B" ]))
       (TyTuple [ ty_int; ty_string ]))

let test_unify_range_subtyping () =
  (* Range flows to Int (one-way) *)
  check_some "Int accepts Range" (unify ty_int (TyRange (TyConstInt 5)));
  check_none "Range doesn't accept Int (asymmetric)"
    (unify (TyRange (TyConstInt 5)) ty_int);
  (* Range-to-range: smaller actual fits larger expected *)
  check_some "Range 10 accepts Range 5"
    (unify (TyRange (TyConstInt 10)) (TyRange (TyConstInt 5)));
  check_none "Range 5 rejects Range 10"
    (unify (TyRange (TyConstInt 5)) (TyRange (TyConstInt 10)))

let test_unify_vardims () =
  check_some "VarDims matches any args"
    (unify
       (TyNamed ("Tensor", [ TyVarDims "#Ns_test" ]))
       (TyNamed ("Tensor", [ ty_float; TyConstInt 3; TyConstInt 4 ])))

let test_unify_type_params () =
  let result = unify ~type_params:[ "T" ] (TyNamed ("T", [])) ty_int in
  check_some "type_param T binds to Int" result

let test_unify_occurs_check () =
  (* T = List[T] should fail (infinite type) *)
  check_none "occurs check"
    (unify (TyVar "T") (TyNamed ("List", [ TyVar "T" ])))

(* ============================================================================
   types_compatible / types_bidirectional
   ============================================================================ *)

let test_types_compatible () =
  check_true "Int compat Int" (types_compatible ty_int ty_int);
  check_false "Int not compat String" (types_compatible ty_int ty_string);
  check_true "T compat Int" (types_compatible (TyVar "T") ty_int);
  check_false "Int not compat T (one-way)" (types_compatible ty_int (TyVar "T"))

let test_types_bidirectional () =
  check_true "bidirectional T <-> Int" (types_bidirectional (TyVar "T") ty_int);
  check_true "bidirectional Int <-> T" (types_bidirectional ty_int (TyVar "T"))

(* ============================================================================
   Integer / Float type utilities
   ============================================================================ *)

let test_integer_type_checks () =
  check_true "Int is integer" (is_any_integer_type ty_int);
  check_true "Int8 is integer" (is_any_integer_type ty_int8);
  check_true "UInt32 is integer" (is_any_integer_type ty_uint32);
  check_false "Float is not integer" (is_any_integer_type ty_float);
  check_false "String is not integer" (is_any_integer_type ty_string);

  check_true "Int is signed" (is_signed_integer_type ty_int);
  check_false "UInt8 is not signed" (is_signed_integer_type ty_uint8);
  check_true "UInt8 is unsigned" (is_unsigned_integer_type ty_uint8);
  check_false "Int is not unsigned" (is_unsigned_integer_type ty_int)

let test_int_type_to_c () =
  check_string "Int -> long" "long" (int_type_to_c "Int");
  check_string "Int8 -> int8_t" "int8_t" (int_type_to_c "Int8");
  check_string "UInt64 -> uint64_t" "uint64_t" (int_type_to_c "UInt64")

(* ============================================================================
   map_type_expr
   ============================================================================ *)

let test_map_type_expr () =
  (* Replace all Int with String *)
  let result =
    map_type_expr
      (function TyNamed ("Int", []) -> Some ty_string | _ -> None)
      (TyNamed ("List", [ ty_int ]))
  in
  check_true "map Int->String in List"
    (types_equal result (TyNamed ("List", [ ty_string ])));

  (* Identity transform *)
  let ty = TyFunc { params = [ ty_int ]; return = ty_bool; is_pure = true } in
  let result = map_type_expr (fun _ -> None) ty in
  check_true "identity" (types_equal result ty)

(* ============================================================================
   Dim value/refinement boundary
   ============================================================================ *)

let test_dim_value_scalars_exclude_variadic_packs () =
  check_true "literal dim is scalar value" (Dim.is_value_dim (TyConstInt 10));
  check_true "range dim is scalar value"
    (Dim.is_value_dim (TyRange (TyConstInt 10)));
  check_true "dim var is scalar value" (Dim.is_value_dim (TyVar "#N"));
  check_true "dim arithmetic is scalar value"
    (Dim.is_value_dim (TyDimOp (DimAdd, TyVar "#N", TyConstInt 1)));
  check_false "variadic dim pack is not a scalar value"
    (Dim.is_value_dim (TyVarDims "#Ds"));
  check_true "scalar dim lifts to Int"
    (types_equal (Dim.lift_to_int (TyConstInt 10)) ty_int);
  check_true "variadic dim pack does not lift to Int"
    (types_equal (Dim.lift_to_int (TyVarDims "#Ds")) (TyVarDims "#Ds"))

let test_dim_normalization_rejects_symbolic_zero () =
  let n = TyVar "#N" in
  let zero = TyDimOp (DimSub, n, n) in
  check_true "N - N normalizes to zero"
    (types_equal (Dim.normalize zero) (TyConstInt 0));
  Alcotest.(check (option int))
    "zero dim is rejected" (Some 0)
    (Dim.find_negative (TyArray (ty_int, [ zero ])));
  let positive = TyDimOp (DimAdd, zero, TyConstInt 1) in
  check_true "N - N + 1 normalizes to one"
    (types_equal (Dim.normalize positive) (TyConstInt 1));
  check_none "positive normalized dim is accepted"
    (Dim.find_negative (TyArray (ty_int, [ positive ])))

(* ============================================================================
   Module-owned type identities
   ============================================================================ *)

let test_std_global_abi_type_identity_stays_bare () =
  check_true "List is ABI global" (is_global_abi_type_name "List");
  check_string "std List stays bare" "List"
    (canonical_module_type_name ~module_path:"std/list" "List");
  check_true "FileReader is ABI global" (is_global_abi_type_name "FileReader");
  check_string "std FileReader stays bare" "FileReader"
    (canonical_module_type_name ~module_path:"std/fs" "FileReader")

let test_std_non_abi_type_identity_is_owner_qualified () =
  check_false "AABB3 is not ABI global" (is_global_abi_type_name "AABB3");
  check_string "std geometry AABB3 is canonical" "std/geometry::AABB3"
    (canonical_module_type_name ~module_path:"std/geometry" "AABB3")

let test_qualify_module_local_types_for_std_non_abi_only () =
  let ty =
    TyNamed ("Tuple", [ TyNamed ("AABB3", []); TyNamed ("List", [ ty_int ]) ])
  in
  let qualified =
    qualify_module_local_types ~module_path:"std/geometry" [ "AABB3"; "List" ]
      ty
  in
  check_true "std local AABB3 qualified, ABI List stable"
    (types_equal qualified
       (TyNamed
          ( "Tuple",
            [
              TyNamed ("std/geometry::AABB3", []); TyNamed ("List", [ ty_int ]);
            ] )))

let test_resolve_qualified_types_recurses_into_arrays () =
  let aliases = [ ("G", "std/geometry") ] in
  let input =
    TyArray
      ( TyNamed ("G.AABB3", []),
        [ TyDimOp (DimAdd, TyNamed ("G.Dim", []), TyConstInt 1) ] )
  in
  let resolved = resolve_qualified_types aliases input in
  check_true "array element and dimension names are canonicalized"
    (types_equal resolved
       (TyArray
          ( TyNamed ("std/geometry::AABB3", []),
            [
              TyDimOp (DimAdd, TyNamed ("std/geometry::Dim", []), TyConstInt 1);
            ] )))

(* ============================================================================
   Test suite
   ============================================================================ *)

let suite =
  [
    ( "type_to_string",
      [
        Alcotest.test_case "simple types" `Quick test_type_to_string_simple;
        Alcotest.test_case "parameterized" `Quick
          test_type_to_string_parameterized;
        Alcotest.test_case "function types" `Quick test_type_to_string_func;
        Alcotest.test_case "tuple types" `Quick test_type_to_string_tuple;
        Alcotest.test_case "type variables" `Quick test_type_to_string_tyvar;
        Alcotest.test_case "special types" `Quick test_type_to_string_special;
      ] );
    ( "types_equal",
      [
        Alcotest.test_case "basic equality" `Quick test_types_equal_basic;
        Alcotest.test_case "parameterized" `Quick test_types_equal_parameterized;
        Alcotest.test_case "tensor normalization" `Quick
          test_types_equal_tensor_normalization;
        Alcotest.test_case "function types" `Quick test_types_equal_func;
        Alcotest.test_case "tuple/named tuple" `Quick
          test_types_equal_tuple_named;
        Alcotest.test_case "special types" `Quick test_types_equal_special;
      ] );
    ( "normalize_type_name",
      [ Alcotest.test_case "normalization" `Quick test_normalize_type_name ] );
    ( "strip_type_param_bounds",
      [ Alcotest.test_case "stripping" `Quick test_strip_type_param_bounds ] );
    ( "collect_type_vars",
      [ Alcotest.test_case "collection" `Quick test_collect_type_vars ] );
    ( "instantiate_type_params",
      [ Alcotest.test_case "instantiation" `Quick test_instantiate_type_params ]
    );
    ("occurs_in", [ Alcotest.test_case "occurs check" `Quick test_occurs_in ]);
    ( "apply_subst",
      [
        Alcotest.test_case "basic" `Quick test_apply_subst_basic;
        Alcotest.test_case "nested" `Quick test_apply_subst_nested;
        Alcotest.test_case "chained" `Quick test_apply_subst_chained;
        Alcotest.test_case "cycle detection" `Quick
          test_apply_subst_cycle_detection;
        Alcotest.test_case "function type" `Quick test_apply_subst_func;
        Alcotest.test_case "Self" `Quick test_apply_subst_self;
        Alcotest.test_case "explicit type-param identities" `Quick
          test_apply_type_param_subst_uses_explicit_type_vars;
      ] );
    ( "unify",
      [
        Alcotest.test_case "identical" `Quick test_unify_identical;
        Alcotest.test_case "mismatch" `Quick test_unify_mismatch;
        Alcotest.test_case "TyVar left" `Quick test_unify_tyvar_left;
        Alcotest.test_case "TyVar right asymmetric" `Quick
          test_unify_tyvar_right_asymmetric;
        Alcotest.test_case "TyVar right symmetric" `Quick
          test_unify_tyvar_right_symmetric;
        Alcotest.test_case "parameterized" `Quick test_unify_parameterized;
        Alcotest.test_case "consistent binding" `Quick
          test_unify_consistent_binding;
        Alcotest.test_case "purity covariance" `Quick
          test_unify_func_purity_covariance;
        Alcotest.test_case "tensor normalization" `Quick
          test_unify_tensor_normalization;
        Alcotest.test_case "tuple forms" `Quick test_unify_tuple_forms;
        Alcotest.test_case "range subtyping" `Quick test_unify_range_subtyping;
        Alcotest.test_case "VarDims" `Quick test_unify_vardims;
        Alcotest.test_case "type_params" `Quick test_unify_type_params;
        Alcotest.test_case "occurs check" `Quick test_unify_occurs_check;
      ] );
    ( "types_compatible",
      [
        Alcotest.test_case "compatible" `Quick test_types_compatible;
        Alcotest.test_case "bidirectional" `Quick test_types_bidirectional;
      ] );
    ( "integer types",
      [
        Alcotest.test_case "type checks" `Quick test_integer_type_checks;
        Alcotest.test_case "to C" `Quick test_int_type_to_c;
      ] );
    ("map_type_expr", [ Alcotest.test_case "mapping" `Quick test_map_type_expr ]);
    ( "dim values",
      [
        Alcotest.test_case "scalar dimension refinements exclude variadic packs"
          `Quick test_dim_value_scalars_exclude_variadic_packs;
        Alcotest.test_case "symbolic zero dimensions are rejected" `Quick
          test_dim_normalization_rejects_symbolic_zero;
      ] );
    ( "module_type_identity",
      [
        Alcotest.test_case "std global ABI type stays bare" `Quick
          test_std_global_abi_type_identity_stays_bare;
        Alcotest.test_case "std non-ABI type is owner-qualified" `Quick
          test_std_non_abi_type_identity_is_owner_qualified;
        Alcotest.test_case "std qualification skips only ABI types" `Quick
          test_qualify_module_local_types_for_std_non_abi_only;
        Alcotest.test_case "qualified names resolve inside array syntax" `Quick
          test_resolve_qualified_types_recurses_into_arrays;
      ] );
  ]
