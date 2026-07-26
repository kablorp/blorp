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
        { desc = CCall (CKUser ("HasLength_length_String", _), _, _); _ } ) -> (
      match binding.bind_rhs.desc with
      | CCall (CKUser ("std_string__reverse", _), _, _) -> ()
      | _ -> Alcotest.fail "expected bound reverse producer to materialize")
  | other ->
      Alcotest.failf "expected bound reverse expression to remain, got %s"
        (Blorp.Core.pp_to_string { expr with desc = other })

let rec find_func_body name = function
  | [] -> None
  | { cd_desc = CDFunc f; _ } :: _ when f.cf_name = name -> f.cf_body
  | { cd_desc = CDPrivate inner; _ } :: rest -> (
      match find_func_body name [ inner ] with
      | Some _ as found -> found
      | None -> find_func_body name rest)
  | _ :: rest -> find_func_body name rest

let test_pipeline_fuses_real_reverse_length_call () =
  Blorp.Modules.reset ();
  Blorp.Modules.init_module_paths ".";
  let source =
    {|
import:
    string: reverse

pure func measure(s: String) -> Int:
    s.reverse().length()

func main(args: List[String]) -> Int:
    measure("abcdef")
|}
  in
  let resolve_reverse_calls = ref None in
  let fusion_reverse_calls = ref None in
  let fusion_string_len_calls = ref None in
  let on_stage stage program =
    match (stage, find_func_body "measure" program) with
    | Blorp.Core_stage.Resolve, Some body ->
        resolve_reverse_calls :=
          Some (count_user_call "std_string__reverse" body)
    | Blorp.Core_stage.Fusion, Some body ->
        fusion_reverse_calls :=
          Some (count_user_call "std_string__reverse" body);
        fusion_string_len_calls := Some (count_intrinsic_call "string_len" body)
    | _ -> ()
  in
  match
    Blorp.Pipeline.compile_legacy_direct_source ~embed_runtime:false ~on_stage ~filename:"<test>"
      ~source ()
  with
  | Ok (Blorp.Pipeline.Compiled _) ->
      Alcotest.(check bool)
        "resolve stage contains reverse producer" true
        (Option.value ~default:0 !resolve_reverse_calls > 0);
      Alcotest.(check int)
        "fusion removes direct reverse producer" 0
        (Option.value ~default:(-1) !fusion_reverse_calls);
      Alcotest.(check bool)
        "fusion emits direct string length consumer" true
        (Option.value ~default:0 !fusion_string_len_calls > 0)
  | Ok (Blorp.Pipeline.Stopped_at s) ->
      Alcotest.failf "unexpected stop at %s" (Blorp.Core_stage.to_string s)
  | Error errs ->
      Alcotest.failf "compile failed:\n%s" (Test_helpers.format_errors errs)

let test_pipeline_fuses_real_composed_length_call () =
  Blorp.Modules.reset ();
  Blorp.Modules.init_module_paths ".";
  let source =
    {|
import:
    string: replace, take_left, trim

pure func measure() -> Int:
    "  abacad  "
        .trim()
        .take_left(5)
        .replace("a", "xy")
        .length()

func main(args: List[String]) -> Int:
    measure()
|}
  in
  let fusion_trim_calls = ref None in
  let fusion_take_calls = ref None in
  let fusion_replace_calls = ref None in
  let fusion_byte_reads = ref None in
  let on_stage stage program =
    match (stage, find_func_body "measure" program) with
    | Blorp.Core_stage.Fusion, Some body ->
        fusion_trim_calls := Some (count_user_call "std_string__trim" body);
        fusion_take_calls := Some (count_user_call "std_string__take_left" body);
        fusion_replace_calls :=
          Some (count_user_call "std_string__replace" body);
        fusion_byte_reads := Some (count_intrinsic_call "string_get_byte" body)
    | _ -> ()
  in
  match
    Blorp.Pipeline.compile_legacy_direct_source ~embed_runtime:false ~on_stage ~filename:"<test>"
      ~source ()
  with
  | Ok (Blorp.Pipeline.Compiled _) ->
      Alcotest.(check int)
        "fusion removes real trim producer" 0
        (Option.value ~default:(-1) !fusion_trim_calls);
      Alcotest.(check int)
        "fusion removes real take_left producer" 0
        (Option.value ~default:(-1) !fusion_take_calls);
      Alcotest.(check int)
        "fusion removes real replace producer" 0
        (Option.value ~default:(-1) !fusion_replace_calls);
      Alcotest.(check bool)
        "fusion scans source bytes directly" true
        (Option.value ~default:0 !fusion_byte_reads > 0)
  | Ok (Blorp.Pipeline.Stopped_at s) ->
      Alcotest.failf "unexpected stop at %s" (Blorp.Core_stage.to_string s)
  | Error errs ->
      Alcotest.failf "compile failed:\n%s" (Test_helpers.format_errors errs)

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
        Alcotest.test_case "bound_reverse_is_not_rewritten_as_pipeline" `Quick
          test_bound_reverse_is_not_rewritten_as_pipeline;
        Alcotest.test_case "pipeline_fuses_real_reverse_length_call" `Quick
          test_pipeline_fuses_real_reverse_length_call;
        Alcotest.test_case "pipeline_fuses_real_composed_length_call" `Quick
          test_pipeline_fuses_real_composed_length_call;
      ] );
  ]
