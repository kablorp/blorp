(** Tests for string producer/consumer fusion.

    These tests pin the initial boundary of the string pipeline pass: only
    direct producer-to-consumer expressions are fused. If a producer is bound to
    a variable, it is materialized normally and later consumers see an ordinary
    string value. *)

open Blorp.Ast
open Blorp.Core
module P = Blorp.Core_string_pipeline

let ty_int = TyNamed ("Int", [])
let ty_string = TyNamed ("String", [])
let ty_void = TyNamed ("Void", [])
let loc = dummy_loc
let mk ty desc = { desc; ty; loc }
let cvar name ty = mk ty (CVar (Var.named name))
let void = mk ty_void CVoid
let ty_func params return = TyFunc { params; return; is_pure = true }

let call_user ?(id = 1) name args return_ty =
  let fn_ty = ty_func (List.map (fun arg -> arg.ty) args) return_ty in
  mk return_ty (CCall (CKUser (name, Some id), cvar name fn_ty, args))

let reverse_call source = call_user "std_string__reverse" [ source ] ty_string
let trim_call source = call_user "std_string__trim" [ source ] ty_string

let take_left_call source n =
  call_user "std_string__take_left" [ source; n ] ty_string

let substring_call source start len =
  call_user "std_string__substring" [ source; start; len ] ty_string

let replace_call source old_ new_ =
  call_user "std_string__replace" [ source; old_; new_ ] ty_string

let length_call source = call_user "HasLength_length_String" [ source ] ty_int
let lit_int n = mk ty_int (CLit (LitInt (Int64.of_int n)))
let lit_const_int n = mk (TyConstInt n) (CLit (LitInt (Int64.of_int n)))

let lit_string s =
  let flags = { sf_multiline = false; sf_raw = false } in
  mk ty_string (CLit (LitString (s, flags)))

let count_expr pred expr =
  fold_tree (fun acc node -> if pred node then acc + 1 else acc) 0 expr

let count_user_call name expr =
  count_expr
    (function
      | { desc = CCall (CKUser (got, _), _, _); _ } -> got = name | _ -> false)
    expr

let count_intrinsic_call name expr =
  count_expr
    (function
      | { desc = CCall (CKIntrinsic got, _, _); _ } -> got = name | _ -> false)
    expr

let test_reverse_length_rewrites_to_source_length () =
  let source = cvar "s" ty_string in
  let expr = length_call (reverse_call source) in
  let fused = P.fuse_expr expr in
  Alcotest.(check int)
    "reverse producer removed" 0
    (count_user_call "std_string__reverse" fused);
  Alcotest.(check bool)
    "fused length uses source length" true
    (count_intrinsic_call "string_len" fused > 0)

let test_trim_length_rewrites_without_materializing () =
  let source = cvar "s" ty_string in
  let expr = length_call (trim_call source) in
  let fused = P.fuse_expr expr in
  Alcotest.(check int)
    "trim producer removed" 0
    (count_user_call "std_string__trim" fused);
  Alcotest.(check bool)
    "trim length inspects source bytes" true
    (count_intrinsic_call "string_get_byte" fused > 0)

let test_composed_span_replace_length_rewrites_without_materializing () =
  let source = cvar "s" ty_string in
  let expr =
    length_call
      (replace_call
         (take_left_call (trim_call source) (lit_const_int 10))
         (lit_string "a") (lit_string "xy"))
  in
  let fused = P.fuse_expr expr in
  Alcotest.(check int)
    "replace producer removed" 0
    (count_user_call "std_string__replace" fused);
  Alcotest.(check int)
    "trim producer removed" 0
    (count_user_call "std_string__trim" fused);
  Alcotest.(check int)
    "take_left producer removed" 0
    (count_user_call "std_string__take_left" fused);
  Alcotest.(check bool)
    "fused length still inspects source bytes" true
    (count_intrinsic_call "string_get_byte" fused > 0)

let test_composed_span_replace_materializes_once () =
  let source = cvar "s" ty_string in
  let expr =
    replace_call
      (take_left_call (trim_call source) (lit_const_int 5))
      (lit_string "a") (lit_string "xy")
  in
  let fused = P.fuse_expr expr in
  Alcotest.(check int)
    "replace producer removed" 0
    (count_user_call "std_string__replace" fused);
  Alcotest.(check int)
    "trim producer removed" 0
    (count_user_call "std_string__trim" fused);
  Alcotest.(check int)
    "take_left producer removed" 0
    (count_user_call "std_string__take_left" fused);
  Alcotest.(check bool)
    "fused materialization allocates one result string" true
    (count_intrinsic_call "string_alloc" fused > 0);
  Alcotest.(check bool)
    "fused materialization copies directly into the result" true
    (count_intrinsic_call "string_copy_bytes" fused > 0)

let test_composed_span_materializes_once () =
  let source = cvar "s" ty_string in
  let expr = take_left_call (trim_call source) (lit_const_int 5) in
  let fused = P.fuse_expr expr in
  Alcotest.(check int)
    "trim producer removed" 0
    (count_user_call "std_string__trim" fused);
  Alcotest.(check int)
    "take_left producer removed" 0
    (count_user_call "std_string__take_left" fused);
  Alcotest.(check bool)
    "fused window materialization allocates one result string" true
    (count_intrinsic_call "string_alloc" fused > 0);
  Alcotest.(check bool)
    "fused window materialization copies directly from the source" true
    (count_intrinsic_call "string_copy_bytes" fused > 0)

let test_composed_span_reverse_materializes_once () =
  let source = cvar "s" ty_string in
  let expr = reverse_call (trim_call source) in
  let fused = P.fuse_expr expr in
  Alcotest.(check int)
    "reverse producer removed" 0
    (count_user_call "std_string__reverse" fused);
  Alcotest.(check int)
    "trim producer removed" 0
    (count_user_call "std_string__trim" fused);
  Alcotest.(check bool)
    "fused reverse materialization allocates one result string" true
    (count_intrinsic_call "string_alloc" fused > 0);
  Alcotest.(check bool)
    "fused reverse writes result bytes directly" true
    (count_intrinsic_call "string_set_byte" fused > 0)

let test_materialized_window_borrows_existing_source_alias () =
  let source = cvar "s" ty_string in
  let expr = substring_call source (lit_int 0) (lit_int 3) in
  match (P.fuse_expr expr).desc with
  | CBorrowLet ({ borrow_rhs = { desc = CVar v; _ }; _ }, _) when v.vname = "s"
    ->
      ()
  | other ->
      Alcotest.failf "expected borrowed string pipeline source alias, got %s"
        (Blorp.Core.pp_to_string { expr with desc = other })

let test_materialized_window_owns_non_variable_source () =
  let expr = substring_call (lit_string "abcdef") (lit_int 0) (lit_int 3) in
  match (P.fuse_expr expr).desc with
  | CLet ({ bind_rhs = { desc = CLit (LitString ("abcdef", _)); _ }; _ }, _) ->
      ()
  | other ->
      Alcotest.failf
        "expected owning string pipeline source binding for non-variable \
         source, got %s"
        (Blorp.Core.pp_to_string { expr with desc = other })

let test_replace_then_trim_length_is_not_rewritten () =
  let source = cvar "s" ty_string in
  let expr =
    length_call
      (trim_call (replace_call source (lit_string "a") (lit_string " ")))
  in
  let fused = P.fuse_expr expr in
  Alcotest.(check int)
    "replace remains materialized" 1
    (count_user_call "std_string__replace" fused);
  Alcotest.(check int)
    "trim remains materialized" 1
    (count_user_call "std_string__trim" fused)

let test_reverse_then_replace_length_is_not_rewritten () =
  let source = cvar "s" ty_string in
  let expr =
    length_call
      (replace_call (reverse_call source) (lit_string "ab") (lit_string "x"))
  in
  let fused = P.fuse_expr expr in
  Alcotest.(check int)
    "reverse remains materialized" 1
    (count_user_call "std_string__reverse" fused);
  Alcotest.(check int)
    "length-changing replace remains materialized" 1
    (count_user_call "std_string__replace" fused)

let test_reverse_then_same_width_replace_length_rewrites () =
  let source = cvar "s" ty_string in
  let expr =
    length_call
      (replace_call (reverse_call source) (lit_string "l") (lit_string "L"))
  in
  let fused = P.fuse_expr expr in
  Alcotest.(check int)
    "reverse producer removed" 0
    (count_user_call "std_string__reverse" fused);
  Alcotest.(check int)
    "length-preserving replace producer removed" 0
    (count_user_call "std_string__replace" fused);
  Alcotest.(check bool)
    "fused expression uses source length" true
    (count_intrinsic_call "string_len" fused > 0)

let test_plain_string_length_rewrites_to_intrinsic () =
  let expr = length_call (cvar "s" ty_string) in
  let fused = P.fuse_expr expr in
  Alcotest.(check int)
    "trait-resolved call removed" 0
    (count_user_call "HasLength_length_String" fused);
  Alcotest.(check int)
    "string length intrinsic introduced" 1
    (count_intrinsic_call "string_len" fused)

let test_plain_string_length_preserves_call_location () =
  let call_loc =
    {
      line = 29;
      column = 10;
      end_line = 29;
      end_column = 18;
      loc_file = Some "length_location.brp";
    }
  in
  let expr = { (length_call (cvar "s" ty_string)) with loc = call_loc } in
  match P.fuse_expr expr with
  | { desc = CCall (CKIntrinsic "string_len", _, _); loc; _ } ->
      Alcotest.(check int) "line" call_loc.line loc.line;
      Alcotest.(check int) "column" call_loc.column loc.column;
      Alcotest.(check (option string))
        "file" call_loc.loc_file loc.loc_file
  | fused ->
      Alcotest.failf "expected string_len intrinsic, got %s"
        (Blorp.Core.pp_to_string fused)

let test_user_defined_length_is_not_rewritten () =
  let expr = call_user "length" [ cvar "s" ty_string ] ty_int in
  let fused = P.fuse_expr expr in
  Alcotest.(check int)
    "user call remains" 1
    (count_user_call "length" fused);
  Alcotest.(check int)
    "string length intrinsic not introduced" 0
    (count_intrinsic_call "string_len" fused)

let test_bound_reverse_is_not_rewritten_as_pipeline () =
  let source = cvar "s" ty_string in
  let tmp = Var.named "tmp" in
  let tmp_ref = mk ty_string (CVar tmp) in
  let expr =
    mk ty_int
      (CLet
         ( {
             bind_var = tmp;
             bind_mut = false;
             bind_ty = ty_string;
             bind_rhs = reverse_call source;
           },
           length_call tmp_ref ))
  in
  match (P.fuse_expr expr).desc with
  | CLet
      ( binding,
        { desc = CCall (CKIntrinsic "string_len", _, _); _ } ) -> (
      match binding.bind_rhs.desc with
      | CCall (CKUser ("std_string__reverse", _), _, _) -> ()
      | _ -> Alcotest.fail "expected bound reverse producer to materialize")
  | other ->
      Alcotest.failf "expected bound reverse expression to remain, got %s"
        (Blorp.Core.pp_to_string { expr with desc = other })

let suite =
  [
    ( "rewrite",
      [
        Alcotest.test_case "reverse_length_rewrites_to_source_length" `Quick
          test_reverse_length_rewrites_to_source_length;
        Alcotest.test_case "trim_length_rewrites_without_materializing" `Quick
          test_trim_length_rewrites_without_materializing;
        Alcotest.test_case
          "composed_span_replace_length_rewrites_without_materializing" `Quick
          test_composed_span_replace_length_rewrites_without_materializing;
        Alcotest.test_case "composed_span_replace_materializes_once" `Quick
          test_composed_span_replace_materializes_once;
        Alcotest.test_case "composed_span_materializes_once" `Quick
          test_composed_span_materializes_once;
        Alcotest.test_case "composed_span_reverse_materializes_once" `Quick
          test_composed_span_reverse_materializes_once;
        Alcotest.test_case "materialized_window_borrows_existing_source_alias"
          `Quick test_materialized_window_borrows_existing_source_alias;
        Alcotest.test_case "materialized_window_owns_non_variable_source" `Quick
          test_materialized_window_owns_non_variable_source;
        Alcotest.test_case "replace_then_trim_length_is_not_rewritten" `Quick
          test_replace_then_trim_length_is_not_rewritten;
        Alcotest.test_case "reverse_then_replace_length_is_not_rewritten" `Quick
          test_reverse_then_replace_length_is_not_rewritten;
        Alcotest.test_case "reverse_then_same_width_replace_length_rewrites"
          `Quick test_reverse_then_same_width_replace_length_rewrites;
        Alcotest.test_case "plain_string_length_rewrites_to_intrinsic" `Quick
          test_plain_string_length_rewrites_to_intrinsic;
        Alcotest.test_case "plain_string_length_preserves_call_location" `Quick
          test_plain_string_length_preserves_call_location;
        Alcotest.test_case "user_defined_length_is_not_rewritten" `Quick
          test_user_defined_length_is_not_rewritten;
        Alcotest.test_case "bound_reverse_is_not_rewritten_as_pipeline" `Quick
          test_bound_reverse_is_not_rewritten_as_pipeline;
      ] );
  ]
