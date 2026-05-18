(** Unit tests for [Codegen_names] mangling helpers.

    The DefId-based mangling scheme ([mangle_by_def_id]) is the C-symbol
    invariant: decl emission and every call site compute the same string from
    the same [(id, name)] pair, so link targets can never drift. These tests
    lock in the format and the purity of the function. *)

open Blorp.Codegen_names

let test_mangle_basic () =
  Alcotest.(check string)
    "simple name" "__def_42_foo"
    (mangle_by_def_id 42 "foo")

let test_mangle_zero_id () =
  Alcotest.(check string) "id 0" "__def_0_foo" (mangle_by_def_id 0 "foo")

let test_mangle_sanitizes_slash () =
  Alcotest.(check string) "/" "__def_1_std_list" (mangle_by_def_id 1 "std/list")

let test_mangle_sanitizes_dollar () =
  (* UFCS names contain [$] — must become valid C. *)
  Alcotest.(check string)
    "$" "__def_7___ufcs_std_list__get"
    (mangle_by_def_id 7 "__ufcs_std$list__get")

let test_mangle_sanitizes_mixed () =
  (* A grab-bag of non-identifier chars that might appear in synthetic
     names: [.], [:], [#], [/], [$], [-]. All must map to [_]. *)
  Alcotest.(check string)
    "mixed punctuation" "__def_3_a_b_c_d_e_f"
    (mangle_by_def_id 3 "a.b:c#d/e$f")

let test_mangle_preserves_underscores () =
  Alcotest.(check string)
    "existing _ and digits" "__def_12_my_func_42"
    (mangle_by_def_id 12 "my_func_42")

let test_mangle_deterministic () =
  let a = mangle_by_def_id 99 "foo" in
  let b = mangle_by_def_id 99 "foo" in
  Alcotest.(check string) "same args → same string" a b

let test_mangle_id_discriminates () =
  Alcotest.(check bool)
    "different ids → different strings" true
    (mangle_by_def_id 1 "foo" <> mangle_by_def_id 2 "foo")

let test_sanitize_c_ident_passthrough () =
  Alcotest.(check string)
    "valid ident passes through" "foo_bar_42"
    (sanitize_c_ident "foo_bar_42")

let test_sanitize_c_ident_empty () =
  Alcotest.(check string) "empty string" "" (sanitize_c_ident "")

let suite =
  [
    ( "mangle_by_def_id",
      [
        Alcotest.test_case "basic" `Quick test_mangle_basic;
        Alcotest.test_case "id zero" `Quick test_mangle_zero_id;
        Alcotest.test_case "sanitizes /" `Quick test_mangle_sanitizes_slash;
        Alcotest.test_case "sanitizes $" `Quick test_mangle_sanitizes_dollar;
        Alcotest.test_case "sanitizes mixed" `Quick test_mangle_sanitizes_mixed;
        Alcotest.test_case "preserves _ and digits" `Quick
          test_mangle_preserves_underscores;
        Alcotest.test_case "deterministic" `Quick test_mangle_deterministic;
        Alcotest.test_case "id discriminates" `Quick
          test_mangle_id_discriminates;
      ] );
    ( "sanitize_c_ident",
      [
        Alcotest.test_case "valid passthrough" `Quick
          test_sanitize_c_ident_passthrough;
        Alcotest.test_case "empty" `Quick test_sanitize_c_ident_empty;
      ] );
  ]
