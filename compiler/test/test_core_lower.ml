(** Tests for Core_lower: typed AST → Core IR translation.

    Each test builds a hand-crafted typed AST fragment, lowers it,
    and asserts the Core shape (via pattern matching or pp_to_string).

    Test philosophy: exercise every AST variant at least once, focus
    closely on EBlock (which becomes nested CLet/CSeq) and sugar forms
    that are preserved as pass-through Core nodes. *)

open Blorp.Ast
open Blorp.Core

(* ============================================================================
   AST construction helpers (typed)
   ============================================================================ *)

let loc =
  { line = 1; column = 1; end_line = 1; end_column = 1; loc_file = None }

let ty_int = TyNamed ("Int", [])
let ty_bool = TyNamed ("Bool", [])
let ty_string = TyNamed ("String", [])
let ty_void = TyNamed ("Void", [])
let ty_range = TyNamed ("Range", [])
let ty_list_int = TyNamed ("List", [ ty_int ])
let ty_opt_int = TyNamed ("Option", [ ty_int ])
let ty_test_resource = TyNamed ("TestResource", [])
let ty_opt_test_resource = TyNamed ("Option", [ ty_test_resource ])
let ty_file_reader = TyNamed ("std/fs::FileReader", [])
let ty_io_error = TyNamed ("std/fs::IOError", [])
let ty_fixed = TyNamed ("Fixed", [])

let ty_result_file_reader_error =
  TyNamed ("Result", [ ty_file_reader; ty_io_error ])

let ty_result_int_error = TyNamed ("Result", [ ty_int; ty_io_error ])
let str_flags = { sf_multiline = false; sf_raw = false }

let with_type expr ty =
  Blorp.Ast.with_expr_type_info expr (Test_helpers.expr_type_info_from_type ty)

(** Build a typed AST expression. *)
let mk_ast desc ty =
  with_type
    {
      expr_desc = desc;
      expr_loc = loc;
      expr_type = None;
      expr_type_info = None;
      expr_rc = None;
    }
    ty

let ast_int n = mk_ast (ELiteral (LitInt (Int64.of_int n))) ty_int
let ast_bool b = mk_ast (ELiteral (LitBool b)) ty_bool
let ast_str s = mk_ast (ELiteral (LitString (s, str_flags))) ty_string
let ast_void = mk_ast EVoid ty_void
let ast_var n t = mk_ast (EIdent n) t
let ast_add a b = mk_ast (EBinary (Add, a, b)) ty_int
let ast_block exprs ty = mk_ast (EBlock exprs) ty
let lower_expr = Test_helpers.lower_valid_expr
let lower_decl = Test_helpers.lower_valid_decl
let lower_program = Test_helpers.lower_valid_program

let ast_loop_view ?size_arg kind source elem_ty =
  mk_ast
    (ELoopView
       {
         loop_view_kind = kind;
         loop_view_source = source;
         loop_view_size_arg = size_arg;
         loop_view_elem_type = elem_ty;
       })
    (TyNamed ("Loop", [ elem_ty ]))

(* ============================================================================
   Leaves
   ============================================================================ *)

let test_lower_int_lit () =
  let c = lower_expr (ast_int 42) in
  Alcotest.(check string) "pp" "42" (pp_to_string c);
  Alcotest.(check bool) "type" true (c.ty = ty_int)

let test_lower_bool_lit () =
  let c = lower_expr (ast_bool true) in
  match c.desc with
  | CLit (LitBool true) -> ()
  | _ -> Alcotest.fail "expected bool lit"

let test_lower_string_lit () =
  let c = lower_expr (ast_str "hi") in
  match c.desc with
  | CLit (LitString ("hi", _)) -> ()
  | _ -> Alcotest.fail "expected str lit"

let test_lower_void () =
  let c = lower_expr ast_void in
  Alcotest.(check bool) "void" true (c.desc = CVoid)

let test_lower_ident () =
  let c = lower_expr (ast_var "x" ty_int) in
  match c.desc with
  | CVar { vname = "x"; _ } -> ()
  | _ -> Alcotest.fail "expected CVar"

let test_lower_break () =
  let c = lower_expr (mk_ast EBreak ty_void) in
  Alcotest.(check bool) "break" true (c.desc = CBreak)

let test_lower_continue () =
  let c = lower_expr (mk_ast EContinue ty_void) in
  Alcotest.(check bool) "continue" true (c.desc = CContinue)

let test_lower_builtin_raises () =
  (* EBuiltin is a placeholder for compiler-provided bodies. It should
     never reach lowering — if it does, something upstream is wrong
     and we raise loudly rather than silently producing CVoid. *)
  Test_helpers.check_core_error_raises
    ~phase:(Blorp.Core_error.Stage Blorp.Core_stage.Lower)
    ~msg_contains:"EBuiltin reached lowering" (fun () ->
      let _ = lower_expr (mk_ast (EBuiltin None) ty_void) in
      ())

(* ============================================================================
   Operators
   ============================================================================ *)

let test_lower_binary () =
  let ast = mk_ast (EBinary (Add, ast_int 1, ast_int 2)) ty_int in
  let c = lower_expr ast in
  match c.desc with
  | CBin (Add, l, r) ->
      Alcotest.(check bool) "lhs" true (l.desc = CLit (LitInt 1L));
      Alcotest.(check bool) "rhs" true (r.desc = CLit (LitInt 2L))
  | _ -> Alcotest.fail "expected CBin"

let test_lower_unary () =
  let ast = mk_ast (EUnary (Neg, ast_int 5)) ty_int in
  let c = lower_expr ast in
  match c.desc with CUn (Neg, _) -> () | _ -> Alcotest.fail "expected CUn"

let test_lower_logical () =
  let ast = mk_ast (ELogical (And, ast_bool true, ast_bool false)) ty_bool in
  let c = lower_expr ast in
  match c.desc with
  | CLog (And, _, _) -> ()
  | _ -> Alcotest.fail "expected CLog"

(* ============================================================================
   Call / Field
   ============================================================================ *)

let test_lower_call () =
  let f_ty = TyFunc { params = [ ty_int ]; return = ty_int; is_pure = true } in
  let ast = mk_ast (ECall (ast_var "inc" f_ty, [ ast_int 5 ])) ty_int in
  let c = lower_expr ast in
  match c.desc with
  | CCall (_, { desc = CVar { vname = "inc"; _ }; _ }, [ arg ]) ->
      Alcotest.(check bool) "arg" true (arg.desc = CLit (LitInt 5L))
  | _ -> Alcotest.fail "expected CCall"

let test_lower_field () =
  let pt_ty = TyNamed ("Point", []) in
  let ast = mk_ast (EFieldAccess (ast_var "p" pt_ty, "x")) ty_int in
  let c = lower_expr ast in
  match c.desc with
  | CField (_, "x") -> ()
  | _ -> Alcotest.fail "expected CField"

let test_lower_module_alias_field_uses_typed_sentinel () =
  let module_ty = TyNamed ("Module", []) in
  let callee_ty =
    TyFunc { params = [ ty_int ]; return = ty_int; is_pure = true }
  in
  let ast = mk_ast (EFieldAccess (ast_var "D" module_ty, "get_or")) callee_ty in
  let c = lower_expr ast in
  match c.desc with
  | CField ({ desc = CVar { vname = "D"; _ }; ty; _ }, "get_or")
    when Blorp.Types.types_equal ty module_ty ->
      ()
  | _ -> Alcotest.fail "expected typed module alias field"

let test_lower_module_alias_field_rejects_untyped_alias () =
  let module_alias =
    {
      expr_desc = EIdent "D";
      expr_loc = loc;
      expr_type = None;
      expr_type_info = None;
      expr_rc = None;
    }
  in
  let callee_ty =
    TyFunc { params = [ ty_int ]; return = ty_int; is_pure = true }
  in
  let ast = mk_ast (EFieldAccess (module_alias, "get_or")) callee_ty in
  Test_helpers.expect_typed_expr_error ast (function
    | Blorp.Typed_ast.MissingExprType { context; _ } ->
        Alcotest.(check string) "context" "expression type" context
    | _ -> Alcotest.fail "expected missing child expression type")

(* ============================================================================
   Control flow
   ============================================================================ *)

let test_lower_if_with_else () =
  let ast = mk_ast (EIf (ast_bool true, ast_int 1, Some (ast_int 0))) ty_int in
  let c = lower_expr ast in
  match c.desc with
  | CIf (_, t, e) ->
      Alcotest.(check bool) "then" true (t.desc = CLit (LitInt 1L));
      Alcotest.(check bool) "else" true (e.desc = CLit (LitInt 0L))
  | _ -> Alcotest.fail "expected CIf"

let test_lower_if_without_else () =
  (* No-else: lower to CIf with CVoid else branch *)
  let ast = mk_ast (EIf (ast_bool true, ast_void, None)) ty_void in
  let c = lower_expr ast in
  match c.desc with
  | CIf (_, _, e) -> Alcotest.(check bool) "else is void" true (e.desc = CVoid)
  | _ -> Alcotest.fail "expected CIf"

let test_lower_while () =
  let ast = mk_ast (EWhile (ast_bool true, ast_void)) ty_void in
  let c = lower_expr ast in
  match c.desc with CWhile _ -> () | _ -> Alcotest.fail "expected CWhile"

let test_lower_for () =
  let range = mk_ast (ERange (ast_int 0, ast_int 10)) ty_range in
  let ast = mk_ast (EFor ("i", range, ast_void)) ty_void in
  let c = lower_expr ast in
  match c.desc with
  | CFor ({ loop_var = { vname = "i"; _ }; loop_ty; _ }, _, _) ->
      Alcotest.(check bool) "loop binder type" true (loop_ty = ty_int)
  | _ -> Alcotest.fail "expected CFor"

let test_lower_for_unsupported_iterable_raises () =
  let iter = ast_var "not_iterable" ty_bool in
  let ast = mk_ast (EFor ("x", iter, ast_void)) ty_void in
  Test_helpers.check_core_error_raises
    ~phase:(Blorp.Core_error.Stage Blorp.Core_stage.Lower)
    ~msg_contains:"unsupported for-loop iterable type" (fun () ->
      ignore (lower_expr ast))

let test_lower_for_tuple_unsupported_iterable_raises () =
  let iter = ast_var "not_iterable" ty_bool in
  let ast = mk_ast (EForTuple ([ "a"; "b" ], iter, ast_void)) ty_void in
  Test_helpers.check_core_error_raises
    ~phase:(Blorp.Core_error.Stage Blorp.Core_stage.Lower)
    ~msg_contains:"unsupported for-loop iterable type" (fun () ->
      ignore (lower_expr ast))

let test_lower_tuple_for_binds_tuple_type () =
  let ty_tuple = TyTuple [ ty_int; ty_string ] in
  let iter_ty = TyNamed ("List", [ ty_tuple ]) in
  let iter = ast_var "pairs" iter_ty in
  let body =
    ast_block
      [
        mk_ast
          (ECall
             ( ast_var "use_int"
                 (TyFunc
                    { params = [ ty_int ]; return = ty_void; is_pure = false }),
               [ ast_var "k" ty_int ] ))
          ty_void;
        mk_ast
          (ECall
             ( ast_var "use_string"
                 (TyFunc
                    {
                      params = [ ty_string ];
                      return = ty_void;
                      is_pure = false;
                    }),
               [ ast_var "v" ty_string ] ))
          ty_void;
      ]
      ty_void
  in
  let ast = mk_ast (EForTuple ([ "k"; "v" ], iter, body)) ty_void in
  let c = lower_expr ast in
  match c.desc with
  | CFor
      ( { loop_ty; _ },
        _,
        {
          desc =
            CLet (_, { desc = CLet (k_bind, { desc = CLet (v_bind, _); _ }); _ });
          _;
        } ) ->
      Alcotest.(check bool) "loop tuple type" true (loop_ty = ty_tuple);
      Alcotest.(check bool)
        "first destructured type" true (k_bind.bind_ty = ty_int);
      Alcotest.(check bool)
        "second destructured type" true
        (v_bind.bind_ty = ty_string)
  | _ -> Alcotest.fail "expected CFor with typed tuple destructuring"

let test_lower_enumerate_nonconstant_tensor_inner_dims_raises () =
  let matrix_ty = TyNamed ("Tensor", [ ty_int; TyConstInt 2; TyVar "#N" ]) in
  let row_ty = TyNamed ("Tensor", [ ty_int; TyVar "#N" ]) in
  let iter =
    ast_loop_view LoopEnumerate (ast_var "m" matrix_ty)
      (TyTuple [ ty_int; row_ty ])
  in
  let ast = mk_ast (EFor ("pair", iter, ast_void)) ty_void in
  Test_helpers.check_core_error_raises
    ~phase:(Blorp.Core_error.Stage Blorp.Core_stage.Lower)
    ~msg_contains:"enumerate over a 2D+ tensor with non-literal inner dims"
    (fun () -> ignore (lower_expr ast))

let test_lower_enumerate_non_array_raises () =
  let iter =
    ast_loop_view LoopEnumerate (ast_var "b" ty_bool)
      (TyTuple [ ty_int; ty_bool ])
  in
  let ast = mk_ast (EFor ("pair", iter, ast_void)) ty_void in
  Test_helpers.check_core_error_raises
    ~phase:(Blorp.Core_error.Stage Blorp.Core_stage.Lower)
    ~msg_contains:"enumerate requires an array" (fun () ->
      ignore (lower_expr ast))

let test_lower_loop_view_outside_for_raises () =
  let vector_ty = TyNamed ("Tensor", [ ty_int; TyConstInt 8 ]) in
  let elem_ty = TyTuple [ TyRange (TyConstInt 8); ty_int ] in
  let ast = ast_loop_view LoopEnumerate (ast_var "xs" vector_ty) elem_ty in
  Test_helpers.check_core_error_raises
    ~phase:(Blorp.Core_error.Stage Blorp.Core_stage.Lower)
    ~msg_contains:"loop view reached core lowering outside a for-loop"
    (fun () -> ignore (lower_expr ast))

let test_lower_windows_non_array_raises () =
  let iter =
    ast_loop_view ~size_arg:(ast_int 2) (LoopWindows 2) (ast_var "b" ty_bool)
      (TyNamed ("Tensor", [ ty_bool; TyConstInt 2 ]))
  in
  let ast = mk_ast (EFor ("w", iter, ast_void)) ty_void in
  Test_helpers.check_core_error_raises
    ~phase:(Blorp.Core_error.Stage Blorp.Core_stage.Lower)
    ~msg_contains:"windows requires an array" (fun () ->
      ignore (lower_expr ast))

let test_lower_match () =
  let scrut = ast_var "opt" ty_opt_int in
  let cases =
    [
      {
        case_pattern = PatConstructor ("Some", [ PatVar "x" ]);
        case_body = ast_var "x" ty_int;
        case_loc = loc;
      };
      {
        case_pattern = PatConstructor ("None", []);
        case_body = ast_int 0;
        case_loc = loc;
      };
    ]
  in
  let ast = mk_ast (EMatch (scrut, cases)) ty_int in
  let c = lower_expr ast in
  match c.desc with
  | CMatchArms (_, arms) -> Alcotest.(check int) "arms" 2 (List.length arms)
  | _ -> Alcotest.fail "expected CMatchArms"

(* ============================================================================
   Data construction
   ============================================================================ *)

let test_lower_tuple () =
  let ast =
    mk_ast (ETuple [ ast_int 1; ast_int 2 ]) (TyTuple [ ty_int; ty_int ])
  in
  let c = lower_expr ast in
  match c.desc with
  | CTuple xs -> Alcotest.(check int) "size" 2 (List.length xs)
  | _ -> Alcotest.fail "expected CTuple"

let test_lower_list () =
  let ast = mk_ast (EList [ ast_int 1; ast_int 2; ast_int 3 ]) ty_list_int in
  let c = lower_expr ast in
  match c.desc with
  | CList lit ->
      Alcotest.(check int) "size" 3 (List.length lit.ll_elems);
      Alcotest.(check int)
        "inline width" 8
        (match lit.ll_layout.lsl_slots with
        | ListInlineStorage width -> inline_storage_width_bytes width
        | ListInlineStructStorage _ -> 0
        | ListPointerStorage -> 0)
  | _ -> Alcotest.fail "expected CList"

let test_lower_record () =
  let ast =
    mk_ast
      (ERecord [ ("x", ast_int 1); ("y", ast_int 2) ])
      (TyNamed ("Point", []))
  in
  let c = lower_expr ast in
  match c.desc with
  | CRecord fs -> Alcotest.(check int) "fields" 2 (List.length fs)
  | _ -> Alcotest.fail "expected CRecord"

let test_lower_record_update () =
  let pt_ty = TyNamed ("Point", []) in
  let base = ast_var "p" pt_ty in
  let ast = mk_ast (ERecordUpdate (base, [ ("x", ast_int 10) ])) pt_ty in
  let c = lower_expr ast in
  match c.desc with
  | CRecordUpdate (_, fs) -> Alcotest.(check int) "overrides" 1 (List.length fs)
  | _ -> Alcotest.fail "expected CRecordUpdate"

let test_lower_range () =
  let ast = mk_ast (ERange (ast_int 0, ast_int 10)) ty_range in
  let c = lower_expr ast in
  match c.desc with CRange _ -> () | _ -> Alcotest.fail "expected CRange"

let test_lower_dict () =
  let ast =
    mk_ast
      (EDict [ (ast_str "k", ast_int 1) ])
      (TyNamed ("Dict", [ ty_string; ty_int ]))
  in
  let c = lower_expr ast in
  match c.desc with CDict _ -> () | _ -> Alcotest.fail "expected CDict"

(* ============================================================================
   Lambda
   ============================================================================ *)

let test_lower_lambda () =
  let body = ast_add (ast_var "x" ty_int) (ast_int 1) in
  let func =
    {
      func_name = None;
      func_type_params = [];
      func_params =
        [
          {
            param_name = Some "x";
            param_pattern = None;
            param_type = Some ty_int;
            param_loc = loc;
          };
        ];
      func_return_type = Some ty_int;
      func_body = FuncBodyExpr body;
      func_is_pure = true;
      func_is_tailrec = false;
      func_no_copy = false;
      func_debug_only = false;
      func_resource_result_ordinary = false;
      func_dim_constraints = [];
    }
  in
  let fty = TyFunc { params = [ ty_int ]; return = ty_int; is_pure = true } in
  let ast = mk_ast (ELambda func) fty in
  let c = lower_expr ast in
  match c.desc with
  | CLambda lam ->
      Alcotest.(check int) "params" 1 (List.length lam.lam_params);
      Alcotest.(check bool) "pure" true lam.lam_is_pure
  | _ -> Alcotest.fail "expected CLambda"

let test_lower_lambda_missing_param_type_raises () =
  let func =
    {
      func_name = None;
      func_type_params = [];
      func_params =
        [
          {
            param_name = Some "x";
            param_pattern = None;
            param_type = None;
            param_loc = loc;
          };
        ];
      func_return_type = Some ty_int;
      func_body = FuncBodyExpr (ast_int 1);
      func_is_pure = true;
      func_is_tailrec = false;
      func_no_copy = false;
      func_debug_only = false;
      func_resource_result_ordinary = false;
      func_dim_constraints = [];
    }
  in
  let fty = TyFunc { params = [ ty_int ]; return = ty_int; is_pure = true } in
  Test_helpers.expect_typed_expr_error (mk_ast (ELambda func) fty) (function
    | Blorp.Typed_ast.MissingRequiredType { context; _ } ->
        Alcotest.(check string) "context" "lambda param" context
    | _ -> Alcotest.fail "expected missing lambda parameter type")

let test_lower_lambda_missing_body_raises () =
  let func =
    {
      func_name = None;
      func_type_params = [];
      func_params = [];
      func_return_type = Some ty_int;
      func_body = FuncNoBody;
      func_is_pure = true;
      func_is_tailrec = false;
      func_no_copy = false;
      func_debug_only = false;
      func_resource_result_ordinary = false;
      func_dim_constraints = [];
    }
  in
  let fty = TyFunc { params = []; return = ty_int; is_pure = true } in
  Test_helpers.check_core_error_raises
    ~phase:(Blorp.Core_error.Stage Blorp.Core_stage.Lower)
    ~msg_contains:"lambda has no body" (fun () ->
      ignore (lower_expr (mk_ast (ELambda func) fty)))

(* ============================================================================
   Block lowering (THE important case)
   ============================================================================ *)

let test_lower_empty_block () =
  let c = lower_expr (ast_block [] ty_void) in
  Alcotest.(check bool) "void" true (c.desc = CVoid)

let test_lower_single_expr_block () =
  let c = lower_expr (ast_block [ ast_int 42 ] ty_int) in
  Alcotest.(check bool) "unwrap" true (c.desc = CLit (LitInt 42L))

let test_lower_block_with_var_decl () =
  (* { var x: Int = 5; x + 1 } *)
  let decl = mk_ast (EVarDecl ("x", Some ty_int, ast_int 5, false)) ty_void in
  let body = ast_add (ast_var "x" ty_int) (ast_int 1) in
  let ast = ast_block [ decl; body ] ty_int in
  let c = lower_expr ast in
  match c.desc with
  | CLet (b, body') -> (
      Alcotest.(check string) "var" "x" b.bind_var.vname;
      Alcotest.(check bool) "immutable" false b.bind_mut;
      Alcotest.(check bool) "rhs = 5" true (b.bind_rhs.desc = CLit (LitInt 5L));
      (* body should be (x + 1) *)
      match body'.desc with
      | CBin (Add, _, _) -> ()
      | _ -> Alcotest.fail "expected body CBin(Add,_,_)")
  | _ -> Alcotest.fail "expected CLet"

let test_lower_block_with_mut_var_decl () =
  let decl = mk_ast (EVarDecl ("i", Some ty_int, ast_int 0, true)) ty_void in
  let body = ast_var "i" ty_int in
  let ast = ast_block [ decl; body ] ty_int in
  let c = lower_expr ast in
  match c.desc with
  | CLet (b, _) -> Alcotest.(check bool) "mutable" true b.bind_mut
  | _ -> Alcotest.fail "expected CLet"

let test_lower_block_with_seq () =
  (* { print("a"); print("b"); 42 } *)
  let print_ty =
    TyFunc { params = [ ty_string ]; return = ty_void; is_pure = false }
  in
  let p1 = mk_ast (ECall (ast_var "print" print_ty, [ ast_str "a" ])) ty_void in
  let p2 = mk_ast (ECall (ast_var "print" print_ty, [ ast_str "b" ])) ty_void in
  let ast = ast_block [ p1; p2; ast_int 42 ] ty_int in
  let c = lower_expr ast in
  match c.desc with
  | CSeq (first, rest) -> (
      (* first is the print("a") call *)
      Alcotest.(check bool)
        "first is call" true
        (match first.desc with CCall _ -> true | _ -> false);
      (* rest is CSeq(print("b"), 42) *)
      match rest.desc with
      | CSeq (_, r) ->
          Alcotest.(check bool) "final is 42" true (r.desc = CLit (LitInt 42L))
      | _ -> Alcotest.fail "expected nested CSeq")
  | _ -> Alcotest.fail "expected CSeq"

let test_lower_block_mixed () =
  (* { var x = 5; print(x); x + 1 } *)
  let print_ty =
    TyFunc { params = [ ty_int ]; return = ty_void; is_pure = false }
  in
  let decl = mk_ast (EVarDecl ("x", Some ty_int, ast_int 5, false)) ty_void in
  let use =
    mk_ast (ECall (ast_var "print" print_ty, [ ast_var "x" ty_int ])) ty_void
  in
  let body = ast_add (ast_var "x" ty_int) (ast_int 1) in
  let ast = ast_block [ decl; use; body ] ty_int in
  let c = lower_expr ast in
  (* Expected: CLet("x", 5, CSeq(print(x), x+1)) *)
  match c.desc with
  | CLet (b, rest) -> (
      Alcotest.(check string) "outer let" "x" b.bind_var.vname;
      match rest.desc with
      | CSeq (_, _) -> ()
      | _ -> Alcotest.fail "expected CSeq inside CLet")
  | _ -> Alcotest.fail "expected outer CLet"

(** Regression: a singleton block containing only an [EVarDecl] used to
    infinite-loop. [lower_block [last]] called [lower_expr last], whose
    stray [EVarDecl] case re-entered [lower_block [e]]. *)
let test_lower_singleton_block_with_var_decl () =
  let decl = mk_ast (EVarDecl ("x", Some ty_int, ast_int 5, false)) ty_void in
  let c = lower_expr (ast_block [ decl ] ty_void) in
  match c.desc with
  | CLet (b, body) ->
      Alcotest.(check string) "name" "x" b.bind_var.vname;
      Alcotest.(check bool) "body void" true (body.desc = CVoid)
  | _ -> Alcotest.fail "expected CLet(_, CVoid)"

(** Same regression for ETupleDestruct. *)
let test_lower_singleton_block_with_tuple_destruct () =
  let pair = ast_var "p" (TyTuple [ ty_int; ty_int ]) in
  let destruct = mk_ast (ETupleDestruct ([ "a"; "b" ], pair)) ty_void in
  let c = lower_expr (ast_block [ destruct ] ty_void) in
  (* Should terminate and produce nested CLets ending in CVoid. *)
  match c.desc with
  | CLet _ -> ()
  | _ -> Alcotest.fail "expected CLet (nested)"

let test_lower_tuple_destruct () =
  (* { (a, b) = pair; a + b } *)
  let pair_ty = TyTuple [ ty_int; ty_int ] in
  let pair = ast_var "pair" pair_ty in
  let destruct = mk_ast (ETupleDestruct ([ "a"; "b" ], pair)) ty_void in
  let body = ast_add (ast_var "a" ty_int) (ast_var "b" ty_int) in
  let ast = ast_block [ destruct; body ] ty_int in
  let c = lower_expr ast in
  (* Expected: CLet(__dt_0, pair, CLet(a, __dt_0.0, CLet(b, __dt_0.1, a + b))) *)
  let rec unwrap_lets e acc =
    match e.desc with
    | CLet (b, body') ->
        unwrap_lets body' ((b.bind_var.vname, b.bind_rhs) :: acc)
    | _ -> (List.rev acc, e)
  in
  let lets, final = unwrap_lets c [] in
  Alcotest.(check int) "3 lets (temp + a + b)" 3 (List.length lets);
  Alcotest.(check bool)
    "final is a + b" true
    (match final.desc with CBin (Add, _, _) -> true | _ -> false)

(* ============================================================================
   Assignment
   ============================================================================ *)

let test_lower_assign () =
  let ast = mk_ast (EAssign ("i", ast_int 5)) ty_void in
  let c = lower_expr ast in
  match c.desc with
  | CAssign ({ vname = "i"; _ }, _) -> ()
  | _ -> Alcotest.fail "expected CAssign"

(* ============================================================================
   String interpolation
   ============================================================================ *)

let test_lower_string_interp () =
  let parts =
    [ InterpLit "hello "; InterpExpr (ast_var "name" ty_string); InterpLit "!" ]
  in
  let ast = mk_ast (EStringInterp (parts, false)) ty_string in
  let c = lower_expr ast in
  match c.desc with
  | CStringInterp (ps, false) -> (
      Alcotest.(check int) "parts" 3 (List.length ps);
      match List.nth ps 1 with
      | IPExpr e ->
          Alcotest.(check bool)
            "var inside" true
            (match e.desc with
            | CVar { vname = "name"; _ } -> true
            | _ -> false)
      | _ -> Alcotest.fail "expected IPExpr")
  | _ -> Alcotest.fail "expected CStringInterp"

let test_lower_raw_string_interp_raises () =
  Test_helpers.check_core_error_raises
    ~phase:(Blorp.Core_error.Stage Blorp.Core_stage.Lower)
    ~msg_contains:"EStringInterpRaw reached lowering" (fun () ->
      ignore
        (lower_expr
           (mk_ast (EStringInterpRaw ("hello ${name}", false)) ty_string)))

(* ============================================================================
   Question-bind lowering: direct [?=] statements are fully desugared at lower
   time into nested let/match continuations.
   ============================================================================ *)

let test_lower_question_bind_statement () =
  let rhs = ast_var "maybe" ty_opt_int in
  let bind = mk_ast (EQuestionBind ("x", Some ty_int, rhs)) ty_int in
  let success =
    mk_ast (ECall (ast_var "Some" ty_int, [ ast_var "x" ty_int ])) ty_opt_int
  in
  let block = mk_ast (EBlock [ bind; success ]) ty_opt_int in
  let c = lower_expr block in
  match c.desc with
  | CLet ({ bind_ty; bind_rhs; _ }, { desc = CMatchArms (_, arms); ty; _ }) ->
      Alcotest.(check bool) "tmp binding type" true (bind_ty = ty_opt_int);
      Alcotest.(check bool) "rhs type" true (bind_rhs.ty = ty_opt_int);
      Alcotest.(check bool) "match result type" true (ty = ty_opt_int);
      Alcotest.(check int) "arms" 2 (List.length arms)
  | _ -> Alcotest.fail "expected question-bind let/match lowering"

let test_lower_result_question_bind_rebuilds_error_carrier () =
  let rhs = ast_var "opened" ty_result_file_reader_error in
  let bind =
    mk_ast (EQuestionBind ("reader", Some ty_file_reader, rhs)) ty_file_reader
  in
  let success =
    mk_ast (ECall (ast_var "Ok" ty_int, [ ast_int 1 ])) ty_result_int_error
  in
  let block = mk_ast (EBlock [ bind; success ]) ty_result_int_error in
  let c = lower_expr block in
  match c.desc with
  | CLet
      ( _,
        {
          desc =
            CMatchArms
              ( _,
                [
                  (PatConstructor ("Ok", [ PatVar "reader" ]), _);
                  ( PatConstructor ("Err", [ PatVar err_name ]),
                    {
                      desc =
                        CCall
                          ( CKBuiltin "blorp_result_err",
                            _,
                            [ { desc = CVar err_var; _ } ] );
                      ty;
                      _;
                    } );
                ] );
          _;
        } ) ->
      Alcotest.(check string) "error var reused" err_name err_var.vname;
      Alcotest.(check bool)
        "fallback carrier type" true (ty = ty_result_int_error)
  | _ -> Alcotest.fail "expected Result ?= to rebuild Err carrier"

let test_lower_question_bind_direct_error () =
  (* A stray [EQuestionBind] outside [lower_block]'s continuation-aware path is a
     typechecker violation. Lowering raises a structured error if it leaks. *)
  let rhs = ast_var "opt" ty_opt_int in
  let ast = mk_ast (EQuestionBind ("x", Some ty_int, rhs)) ty_int in
  try
    let _ = lower_expr ast in
    Alcotest.fail "expected EQuestionBind outside block lowering to raise"
  with Blorp.Core_error.Core_error _ -> ()

let test_lower_plain_with_to_resource_scope () =
  let acquire = ast_var "open_resource" ty_test_resource in
  let binding =
    {
      with_name = "handle";
      with_type = Some ty_test_resource;
      with_value = acquire;
      with_kind = WithPlain;
      with_error_map = None;
    }
  in
  let ast = mk_ast (EWith (binding, ast_int 7)) ty_int in
  let c = lower_expr ast in
  match c.desc with
  | CResourceScope scope ->
      Alcotest.(check string) "resource var" "handle" scope.rs_var.vname;
      Alcotest.(check bool) "resource type" true (scope.rs_ty = ty_test_resource);
      Alcotest.(check bool)
        "acquire" true
        (match scope.rs_acquire.desc with
        | CVar { vname = "open_resource"; _ } -> true
        | _ -> false);
      Alcotest.(check bool)
        "body" true
        (match scope.rs_body.desc with CLit (LitInt 7L) -> true | _ -> false);
      Alcotest.(check bool)
        "cleanup calls close(handle)" true
        (match scope.rs_cleanup.desc with
        | CCall
            ( CKUnknown,
              { desc = CVar { vname = "close"; _ }; _ },
              [ { desc = CVar { vname = "handle"; _ }; _ } ] ) ->
            true
        | _ -> false)
  | _ -> Alcotest.fail "expected CResourceScope"

let test_lower_with_uses_registered_resource_cleanup () =
  Blorp.Session.(
    with_current (create ()) (fun () ->
        let ty_widget = TyNamed ("WidgetHandle", []) in
        register_resource_cleanup (current ()) ~type_name:"WidgetHandle"
          (ResourceCleanupBuiltin "blorp_widget_close");
        let acquire = ast_var "open_widget" ty_widget in
        let binding =
          {
            with_name = "handle";
            with_type = Some ty_widget;
            with_value = acquire;
            with_kind = WithPlain;
            with_error_map = None;
          }
        in
        let ast = mk_ast (EWith (binding, ast_int 7)) ty_int in
        let c = lower_expr ast in
        match c.desc with
        | CResourceScope scope ->
            Alcotest.(check bool) "resource type" true (scope.rs_ty = ty_widget);
            Alcotest.(check bool)
              "cleanup uses registered builtin" true
              (match scope.rs_cleanup.desc with
              | CCall
                  ( CKBuiltin "blorp_widget_close",
                    _,
                    [ { desc = CVar { vname = "handle"; _ }; _ } ] ) ->
                  true
              | _ -> false)
        | _ -> Alcotest.fail "expected CResourceScope"))

let test_lower_fallible_with_to_resource_scope_success_arm () =
  let acquire = ast_var "maybe_resource" ty_opt_test_resource in
  let binding =
    {
      with_name = "handle";
      with_type = Some ty_test_resource;
      with_value = acquire;
      with_kind = WithTry;
      with_error_map = None;
    }
  in
  let ast = mk_ast (EWith (binding, ast_var "success" ty_opt_int)) ty_opt_int in
  let c = lower_expr ast in
  match c.desc with
  | CLet
      ( { bind_ty; bind_rhs; _ },
        {
          desc =
            CMatchArms
              ( _,
                [
                  ( PatConstructor ("Some", [ PatVar payload ]),
                    { desc = CResourceScope scope; _ } );
                  (PatConstructor ("None", []), _);
                ] );
          _;
        } ) ->
      Alcotest.(check bool)
        "tmp binding type" true
        (bind_ty = ty_opt_test_resource);
      Alcotest.(check bool) "rhs type" true (bind_rhs.ty = ty_opt_test_resource);
      Alcotest.(check string) "resource var" "handle" scope.rs_var.vname;
      Alcotest.(check bool) "resource type" true (scope.rs_ty = ty_test_resource);
      Alcotest.(check bool)
        "resource acquired from payload" true
        (match scope.rs_acquire.desc with
        | CVar { vname; _ } -> String.equal vname payload
        | _ -> false);
      Alcotest.(check bool)
        "cleanup calls close(handle)" true
        (match scope.rs_cleanup.desc with
        | CCall
            ( CKUnknown,
              { desc = CVar { vname = "close"; _ }; _ },
              [ { desc = CVar { vname = "handle"; _ }; _ } ] ) ->
            true
        | _ -> false)
  | _ -> Alcotest.fail "expected fallible with let/match resource lowering"

let test_lower_fallible_with_body_question_bind_stays_inside_resource_scope () =
  let acquire = ast_var "maybe_resource" ty_opt_test_resource in
  let binding =
    {
      with_name = "handle";
      with_type = Some ty_test_resource;
      with_value = acquire;
      with_kind = WithTry;
      with_error_map = None;
    }
  in
  let question =
    mk_ast
      (EQuestionBind ("x", Some ty_int, ast_var "maybe_int" ty_opt_int))
      ty_int
  in
  let some_ty =
    TyFunc { params = [ ty_int ]; return = ty_opt_int; is_pure = true }
  in
  let success =
    mk_ast (ECall (ast_var "Some" some_ty, [ ast_var "x" ty_int ])) ty_opt_int
  in
  let body = ast_block [ question; success ] ty_opt_int in
  let ast = mk_ast (EWith (binding, body)) ty_opt_int in
  let c = lower_expr ast in
  match c.desc with
  | CLet
      ( _,
        {
          desc =
            CMatchArms
              ( _,
                [
                  ( PatConstructor ("Some", [ PatVar payload ]),
                    { desc = CResourceScope scope; _ } );
                  _;
                ] );
          _;
        } ) ->
      Alcotest.(check bool)
        "resource acquired from with ?= payload" true
        (match scope.rs_acquire.desc with
        | CVar { vname; _ } -> String.equal vname payload
        | _ -> false);
      Alcotest.(check bool)
        "resource body owns body-level ?= lowering" true
        (match scope.rs_body.desc with
        | CLet
            ( { bind_ty; bind_rhs; _ },
              {
                desc =
                  CMatchArms
                    ( _,
                      [
                        (PatConstructor ("Some", [ PatVar "x" ]), _);
                        ( PatConstructor ("None", []),
                          {
                            desc = CCall (CKBuiltin "blorp_option_none", _, []);
                            _;
                          } );
                      ] );
                ty;
                _;
              } ) ->
            bind_ty = ty_opt_int && bind_rhs.ty = ty_opt_int && ty = ty_opt_int
        | _ -> false)
  | _ ->
      Alcotest.fail
        "expected fallible with success arm to own body-level question-bind \
         lowering"

(* ============================================================================
   Concurrency
   ============================================================================ *)

let test_lower_detach () =
  let ast = mk_ast (EDetach ast_void) ty_void in
  let c = lower_expr ast in
  match c.desc with CDetach _ -> () | _ -> Alcotest.fail "expected CDetach"

let test_lower_concurrent () =
  (* concurrent: a = 1; b = 2 — bindings now carried in [conc_bindings]
     explicitly, not as a nested CLet chain in [conc_body]. *)
  let bind_a = mk_ast (EConcurrentBind ("a", Some ty_int, ast_int 1)) ty_void in
  let bind_b = mk_ast (EConcurrentBind ("b", Some ty_int, ast_int 2)) ty_void in
  let ast = mk_ast (EConcurrent ([ bind_a; bind_b ], None, Some 4)) ty_void in
  let c = lower_expr ast in
  match c.desc with
  | CConcurrent blk -> (
      Alcotest.(check (option int)) "max threads" (Some 4) blk.conc_max_threads;
      Alcotest.(check int) "two bindings" 2 (List.length blk.conc_bindings);
      match blk.conc_bindings with
      | [ a; b ] ->
          Alcotest.(check string) "first" "a" a.cb_var.vname;
          Alcotest.(check string) "second" "b" b.cb_var.vname;
          let a_parent =
            task_scope_id_to_int a.cb_task_scope.task_parent_scope_id
          in
          let a_child =
            task_scope_id_to_int a.cb_task_scope.task_child_scope_id
          in
          let b_parent =
            task_scope_id_to_int b.cb_task_scope.task_parent_scope_id
          in
          let b_child =
            task_scope_id_to_int b.cb_task_scope.task_child_scope_id
          in
          Alcotest.(check int) "first parent scope" 0 a_parent;
          Alcotest.(check int) "second parent scope" 0 b_parent;
          Alcotest.(check bool) "first child scope" true (a_child > 0);
          Alcotest.(check bool) "second child scope" true (b_child > 0);
          Alcotest.(check bool)
            "task child scopes are distinct" true (a_child <> b_child)
      | _ -> Alcotest.fail "expected two bindings")
  | _ -> Alcotest.fail "expected CConcurrent"

let test_lower_concurrent_rejects_non_bindings () =
  let ast = mk_ast (EConcurrent ([ ast_void ], None, None)) ty_void in
  Test_helpers.check_core_error_raises
    ~phase:(Blorp.Core_error.Stage Blorp.Core_stage.Lower)
    ~msg_contains:"non-binding statement reached concurrent lowering" (fun () ->
      ignore (lower_expr ast))

(** Regression: concurrent bindings lower as explicit [conc_bindings] triples,
    not nested CLets in [conc_body]. User source cannot reference sibling
    concurrent bindings; this lower-level test preserves explicitly supplied
    typed binding RHSes. *)
let test_lower_concurrent_preserves_explicit_bindings () =
  let compute_ty = TyFunc { params = []; return = ty_int; is_pure = true } in
  let f_ty = TyFunc { params = [ ty_int ]; return = ty_int; is_pure = true } in
  let compute_a = mk_ast (ECall (ast_var "compute_a" compute_ty, [])) ty_int in
  let bind_a = mk_ast (EConcurrentBind ("a", Some ty_int, compute_a)) ty_void in
  let f_of_a =
    mk_ast (ECall (ast_var "f" f_ty, [ ast_var "a" ty_int ])) ty_int
  in
  let bind_b = mk_ast (EConcurrentBind ("b", Some ty_int, f_of_a)) ty_void in
  let ast = mk_ast (EConcurrent ([ bind_a; bind_b ], None, None)) ty_void in
  let c = lower_expr ast in
  match c.desc with
  | CConcurrent blk -> (
      match blk.conc_bindings with
      | [ a; b ] ->
          Alcotest.(check string) "first bind" "a" a.cb_var.vname;
          Alcotest.(check string) "second bind" "b" b.cb_var.vname
      | _ -> Alcotest.fail "expected two conc_bindings")
  | _ -> Alcotest.fail "expected CConcurrent"

let test_lower_concurrently_loop () =
  let range = mk_ast (ERange (ast_int 0, ast_int 10)) ty_range in
  let ast =
    mk_ast
      (EConcurrentlyLoop ("i", range, ast_void, None, ConcurrentlyLoopLimit 2))
      ty_void
  in
  let c = lower_expr ast in
  match c.desc with
  | CConcurrentlyLoop cf ->
      let parent_id =
        task_scope_id_to_int cf.cf_task_scope.task_parent_scope_id
      in
      let child_id =
        task_scope_id_to_int cf.cf_task_scope.task_child_scope_id
      in
      Alcotest.(check bool)
        "void for ... concurrently discards results" true
        (match cf.cf_output with
        | ConcurrentlyLoopDiscard -> true
        | ConcurrentlyLoopCollect -> false);
      Alcotest.(check int) "root parent scope" 0 parent_id;
      Alcotest.(check bool) "fresh child scope" true (child_id > 0);
      Alcotest.(check bool)
        "child scope differs from parent" true (child_id <> parent_id)
  | _ -> Alcotest.fail "expected CConcurrentlyLoop"

let test_lower_nested_concurrently_loop_task_scopes () =
  let outer_range = mk_ast (ERange (ast_int 0, ast_int 10)) ty_range in
  let inner_range = mk_ast (ERange (ast_int 0, ast_int 10)) ty_range in
  let inner =
    mk_ast
      (EConcurrentlyLoop
         ("j", inner_range, ast_void, None, ConcurrentlyLoopLimit 2))
      ty_void
  in
  let outer =
    mk_ast
      (EConcurrentlyLoop ("i", outer_range, inner, None, ConcurrentlyLoopLimit 2))
      ty_void
  in
  let c = lower_expr outer in
  match c.desc with
  | CConcurrentlyLoop outer_cf -> (
      Alcotest.(check bool)
        "outer void for ... concurrently discards results" true
        (match outer_cf.cf_output with
        | ConcurrentlyLoopDiscard -> true
        | ConcurrentlyLoopCollect -> false);
      let outer_child_id =
        task_scope_id_to_int outer_cf.cf_task_scope.task_child_scope_id
      in
      match outer_cf.cf_body.desc with
      | CConcurrentlyLoop inner_cf ->
          Alcotest.(check bool)
            "inner void for ... concurrently discards results" true
            (match inner_cf.cf_output with
            | ConcurrentlyLoopDiscard -> true
            | ConcurrentlyLoopCollect -> false);
          let inner_parent_id =
            task_scope_id_to_int inner_cf.cf_task_scope.task_parent_scope_id
          in
          let inner_child_id =
            task_scope_id_to_int inner_cf.cf_task_scope.task_child_scope_id
          in
          Alcotest.(check int)
            "inner parent is outer child" outer_child_id inner_parent_id;
          Alcotest.(check bool)
            "inner child is fresh" true
            (inner_child_id <> inner_parent_id)
      | _ -> Alcotest.fail "expected nested CConcurrentlyLoop")
  | _ -> Alcotest.fail "expected CConcurrentlyLoop"

(* ============================================================================
   Type preservation invariant
   ============================================================================ *)

let test_types_preserved () =
  let e = ast_add (ast_int 1) (ast_int 2) in
  let c = lower_expr e in
  Alcotest.(check bool) "root type = Int" true (c.ty = ty_int)

let test_missing_type_raises () =
  (* Post-typecheck invariant: every AST expression must carry [expr_type].
     [Core_lower] used to fall back to [Void] when a caller filtered errors,
     masking typechecker bugs. Now it raises — the untyped node's location
     surfaces in the error so the upstream leak is findable.

     Previously this test asserted the silent fallback; updated 2026-04-15
     as part of tightening the [expr_type] invariant. *)
  let untyped =
    {
      expr_desc = ELiteral (LitInt 1L);
      expr_loc = loc;
      expr_type = None;
      expr_type_info = None;
      expr_rc = None;
    }
  in
  Test_helpers.expect_typed_expr_error untyped (function
    | Blorp.Typed_ast.MissingExprType { context; _ } ->
        Alcotest.(check string) "context" "expression type" context
    | _ -> Alcotest.fail "expected missing expression type")

let test_missing_child_type_raises () =
  let untyped_child =
    {
      expr_desc = ELiteral (LitInt 2L);
      expr_loc = loc;
      expr_type = None;
      expr_type_info = None;
      expr_rc = None;
    }
  in
  let ast = mk_ast (EBinary (Add, ast_int 1, untyped_child)) ty_int in
  Test_helpers.expect_typed_expr_error ast (function
    | Blorp.Typed_ast.MissingExprType { context; _ } ->
        Alcotest.(check string) "context" "expression type" context
    | _ -> Alcotest.fail "expected missing child expression type")

let test_meta_type_raises () =
  let unfinalized =
    mk_ast (ELiteral (LitInt 1L)) (TyNamed ("List", [ TyMeta 1 ]))
  in
  Test_helpers.expect_typed_expr_error unfinalized (function
    | Blorp.Typed_ast.UnfinalizedExprType { context; _ } ->
        Alcotest.(check string) "context" "expression type" context
    | _ -> Alcotest.fail "expected unfinalized expression type")

let test_param_missing_type_raises () =
  let bad_param =
    {
      param_name = Some "x";
      param_pattern = None;
      param_type = None;
      param_loc = loc;
    }
  in
  let func =
    {
      func_name = Some "f";
      func_type_params = [];
      func_params = [ bad_param ];
      func_return_type = Some ty_int;
      func_body = FuncBodyExpr (ast_int 1);
      func_is_pure = true;
      func_is_tailrec = false;
      func_no_copy = false;
      func_debug_only = false;
      func_resource_result_ordinary = false;
      func_dim_constraints = [];
    }
  in
  Test_helpers.expect_typed_decl_error
    { decl_desc = DFunc func; decl_loc = loc; decl_doc = None } (function
    | Blorp.Typed_ast.MissingRequiredType { context; _ } ->
        Alcotest.(check string) "context" "param" context
    | _ -> Alcotest.fail "expected missing parameter type")

let test_param_meta_type_raises () =
  let bad_param =
    {
      param_name = Some "x";
      param_pattern = None;
      param_type = Some (TyNamed ("List", [ TyMeta 1 ]));
      param_loc = loc;
    }
  in
  let func =
    {
      func_name = Some "f";
      func_type_params = [];
      func_params = [ bad_param ];
      func_return_type = Some ty_int;
      func_body = FuncBodyExpr (ast_int 1);
      func_is_pure = true;
      func_is_tailrec = false;
      func_no_copy = false;
      func_debug_only = false;
      func_resource_result_ordinary = false;
      func_dim_constraints = [];
    }
  in
  Test_helpers.expect_typed_decl_error
    { decl_desc = DFunc func; decl_loc = loc; decl_doc = None } (function
    | Blorp.Typed_ast.UnfinalizedType { context; _ } ->
        Alcotest.(check string) "context" "function parameter type" context
    | _ -> Alcotest.fail "expected unfinalized parameter type")

let test_return_meta_type_raises () =
  let func =
    {
      func_name = Some "f";
      func_type_params = [];
      func_params = [];
      func_return_type = Some (TyNamed ("Option", [ TyMeta 1 ]));
      func_body = FuncBodyExpr (ast_int 1);
      func_is_pure = true;
      func_is_tailrec = false;
      func_no_copy = false;
      func_debug_only = false;
      func_resource_result_ordinary = false;
      func_dim_constraints = [];
    }
  in
  Test_helpers.expect_typed_decl_error
    { decl_desc = DFunc func; decl_loc = loc; decl_doc = None } (function
    | Blorp.Typed_ast.UnfinalizedType { context; _ } ->
        Alcotest.(check string) "context" "function return type" context
    | _ -> Alcotest.fail "expected unfinalized return type")

let test_param_without_name_or_pattern_raises () =
  let bad_param =
    {
      param_name = None;
      param_pattern = None;
      param_type = Some ty_int;
      param_loc = loc;
    }
  in
  let func =
    {
      func_name = Some "f";
      func_type_params = [];
      func_params = [ bad_param ];
      func_return_type = Some ty_int;
      func_body = FuncBodyExpr (ast_int 1);
      func_is_pure = true;
      func_is_tailrec = false;
      func_no_copy = false;
      func_debug_only = false;
      func_resource_result_ordinary = false;
      func_dim_constraints = [];
    }
  in
  Test_helpers.check_core_error_raises
    ~phase:(Blorp.Core_error.Stage Blorp.Core_stage.Lower)
    ~msg_contains:"param has neither name nor pattern" (fun () ->
      ignore
        (lower_decl { decl_desc = DFunc func; decl_loc = loc; decl_doc = None }))

let test_function_without_name_raises () =
  let func =
    {
      func_name = None;
      func_type_params = [];
      func_params = [];
      func_return_type = Some ty_int;
      func_body = FuncBodyExpr (ast_int 1);
      func_is_pure = true;
      func_is_tailrec = false;
      func_no_copy = false;
      func_debug_only = false;
      func_resource_result_ordinary = false;
      func_dim_constraints = [];
    }
  in
  Test_helpers.check_core_error_raises
    ~phase:(Blorp.Core_error.Stage Blorp.Core_stage.Lower)
    ~msg_contains:"function has no name" (fun () ->
      ignore
        (lower_decl { decl_desc = DFunc func; decl_loc = loc; decl_doc = None }))

(** Regression: a param with BOTH name and pattern used to silently
    drop the pattern. Now raises loudly. *)
let test_param_with_name_and_pattern_raises () =
  let bad_param =
    {
      param_name = Some "x";
      param_pattern = Some (PatVar "y");
      param_type = Some ty_int;
      param_loc = loc;
    }
  in
  let func =
    {
      func_name = Some "f";
      func_type_params = [];
      func_params = [ bad_param ];
      func_return_type = Some ty_int;
      func_body = FuncBodyExpr (ast_int 1);
      func_is_pure = true;
      func_is_tailrec = false;
      func_no_copy = false;
      func_debug_only = false;
      func_resource_result_ordinary = false;
      func_dim_constraints = [];
    }
  in
  let decl = { decl_desc = DFunc func; decl_loc = loc; decl_doc = None } in
  Test_helpers.check_core_error_raises
    ~phase:(Blorp.Core_error.Stage Blorp.Core_stage.Lower)
    ~msg_contains:"param has both a name and a pattern" (fun () ->
      let _ = lower_decl decl in
      ())

(** Regression: [ETupleDestruct] with more names than the tuple has
    fields used to silently use the whole tuple type for each extra
    name. Now raises. *)
let test_tuple_destruct_shape_mismatch_raises () =
  let pair_ty = TyTuple [ ty_int; ty_int ] in
  let pair = ast_var "pair" pair_ty in
  let destruct = mk_ast (ETupleDestruct ([ "a"; "b"; "c" ], pair)) ty_void in
  let body = ast_int 0 in
  let blk = ast_block [ destruct; body ] ty_int in
  Test_helpers.check_core_error_raises
    ~phase:(Blorp.Core_error.Stage Blorp.Core_stage.Lower)
    ~msg_contains:"tuple destructure has 3 names but tuple type has 2 fields"
    (fun () ->
      let _ = lower_expr blk in
      ())

let test_lower_program_propagates_decl_errors () =
  let pair_ty = TyTuple [ ty_int; ty_int ] in
  let pair = mk_ast (ETuple [ ast_int 1; ast_int 2 ]) pair_ty in
  let bad_global =
    {
      var_name = None;
      var_pattern = Some (PatTuple [ PatVar "a"; PatVar "b" ]);
      var_type = Some pair_ty;
      var_value = pair;
      var_is_mutable = false;
      var_is_const = true;
    }
  in
  let decl = { decl_desc = DVar bad_global; decl_loc = loc; decl_doc = None } in
  Test_helpers.check_core_error_raises
    ~phase:(Blorp.Core_error.Stage Blorp.Core_stage.Lower)
    ~msg_contains:"global var with pattern binding" (fun () ->
      let _ = lower_program [ decl ] in
      ())

let test_global_pattern_var_direct_raises () =
  let pair_ty = TyTuple [ ty_int; ty_int ] in
  let pair = mk_ast (ETuple [ ast_int 1; ast_int 2 ]) pair_ty in
  let bad_global =
    {
      var_name = None;
      var_pattern = Some (PatTuple [ PatVar "a"; PatVar "b" ]);
      var_type = Some pair_ty;
      var_value = pair;
      var_is_mutable = false;
      var_is_const = true;
    }
  in
  Test_helpers.check_core_error_raises
    ~phase:(Blorp.Core_error.Stage Blorp.Core_stage.Lower)
    ~msg_contains:"global var with pattern binding" (fun () ->
      ignore
        (lower_decl
           { decl_desc = DVar bad_global; decl_loc = loc; decl_doc = None }))

(* ============================================================================
   Program lowering: decls, functions, globals, impls, traits
   ============================================================================ *)

let mk_decl desc = { decl_desc = desc; decl_loc = loc; decl_doc = None }

let mk_param_named name ty =
  {
    param_name = Some name;
    param_pattern = None;
    param_type = Some ty;
    param_loc = loc;
  }

let mk_func_decl ?(is_pure = false) ?(is_tailrec = false) name params return_ty
    body =
  {
    func_name = Some name;
    func_type_params = [];
    func_params = params;
    func_return_type = Some return_ty;
    func_body =
      (match body with Some e -> FuncBodyExpr e | None -> FuncNoBody);
    func_is_pure = is_pure;
    func_is_tailrec = is_tailrec;
    func_no_copy = false;
    func_debug_only = false;
    func_resource_result_ordinary = false;
    func_dim_constraints = [];
  }

let test_lower_simple_func () =
  (* func inc(x: Int) -> Int: x + 1 *)
  let body = ast_add (ast_var "x" ty_int) (ast_int 1) in
  let func =
    mk_func_decl ~is_pure:true "inc"
      [ mk_param_named "x" ty_int ]
      ty_int (Some body)
  in
  let decl = mk_decl (DFunc func) in
  let cd = lower_decl decl in
  match cd.cd_desc with
  | CDFunc cf ->
      Alcotest.(check string) "name" "inc" cf.cf_name;
      Alcotest.(check int) "1 param" 1 (List.length cf.cf_params);
      Alcotest.(check bool) "has body" true (cf.cf_body <> None);
      Alcotest.(check bool) "pure" true cf.cf_is_pure
  | _ -> Alcotest.fail "expected CDFunc"

let test_lower_foreign_func () =
  (* foreign:
       func printf(fmt: String) = "printf" — no body *)
  let func =
    {
      (mk_func_decl "printf" [ mk_param_named "fmt" ty_string ] ty_void None) with
      func_body =
        FuncForeign
          {
            foreign_name = "printf";
            foreign_includes = [];
            foreign_link_flags = [];
          };
    }
  in
  let cd = lower_decl (mk_decl (DFunc func)) in
  match cd.cd_desc with
  | CDFunc cf -> (
      Alcotest.(check bool) "no body" true (cf.cf_body = None);
      match cf.cf_kind with
      | CFForeign { c_name; arg_passing; _ } ->
          Alcotest.(check string) "foreign name" "printf" c_name;
          Alcotest.(check bool)
            "default foreign copies args" true
            (arg_passing = ForeignDefaultArgs [])
      | _ -> Alcotest.fail "expected CFForeign")
  | _ -> Alcotest.fail "expected CDFunc"

let lower_foreign_arg_passing func =
  let cd = lower_decl (mk_decl (DFunc func)) in
  match cd.cd_desc with
  | CDFunc { cf_kind = CFForeign { arg_passing; _ }; _ } -> arg_passing
  | _ -> Alcotest.fail "expected lowered CFForeign"

let test_lower_foreign_pure_borrows_args () =
  let func =
    {
      (mk_func_decl ~is_pure:true "strlen"
         [ mk_param_named "s" ty_string ]
         ty_int None)
      with
      func_body =
        FuncForeign
          {
            foreign_name = "strlen";
            foreign_includes = [];
            foreign_link_flags = [];
          };
    }
  in
  Alcotest.(check bool)
    "pure foreign borrows args" true
    (lower_foreign_arg_passing func = ForeignBorrowArgs)

let test_lower_foreign_no_copy_borrows_args () =
  let func =
    {
      (mk_func_decl "log" [ mk_param_named "s" ty_string ] ty_int None) with
      func_no_copy = true;
      func_body =
        FuncForeign
          {
            foreign_name = "log";
            foreign_includes = [];
            foreign_link_flags = [];
          };
    }
  in
  Alcotest.(check bool)
    "no_copy foreign borrows args" true
    (lower_foreign_arg_passing func = ForeignBorrowArgs)

let test_lower_func_with_pattern_param () =
  (* func add_pair((a, b): (Int, Int)) -> Int: a + b *)
  let tup_ty = TyTuple [ ty_int; ty_int ] in
  let body = ast_add (ast_var "a" ty_int) (ast_var "b" ty_int) in
  let pat_param =
    {
      param_name = None;
      param_pattern = Some (PatTuple [ PatVar "a"; PatVar "b" ]);
      param_type = Some tup_ty;
      param_loc = loc;
    }
  in
  let func =
    mk_func_decl ~is_pure:true "add_pair" [ pat_param ] ty_int (Some body)
  in
  let cd = lower_decl (mk_decl (DFunc func)) in
  match cd.cd_desc with
  | CDFunc cf -> (
      Alcotest.(check int) "1 param (fresh name)" 1 (List.length cf.cf_params);
      let p = List.hd cf.cf_params in
      Alcotest.(check bool)
        "fresh name __p_" true
        (String.length p.cp_name.vname > 4
        && String.sub p.cp_name.vname 0 4 = "__p_");
      (* body should be wrapped in CMatchArms *)
      match cf.cf_body with
      | Some
          { desc = CMatchArms ({ desc = CVar _; _ }, [ (PatTuple _, _) ]); _ }
        ->
          ()
      | _ -> Alcotest.fail "expected body wrapped in CMatchArms")
  | _ -> Alcotest.fail "expected CDFunc"

let test_lower_global_var () =
  (* var x: Int = 5 *)
  let vdecl =
    {
      var_name = Some "x";
      var_pattern = None;
      var_type = Some ty_int;
      var_value = ast_int 5;
      var_is_mutable = false;
      var_is_const = false;
    }
  in
  let cd = lower_decl (mk_decl (DVar vdecl)) in
  match cd.cd_desc with
  | CDVar cv ->
      Alcotest.(check string) "name" "x" cv.cv_name.vname;
      Alcotest.(check bool) "init is 5" true (cv.cv_init.desc = CLit (LitInt 5L))
  | _ -> Alcotest.fail "expected CDVar"

let test_lower_typed_global_var_uses_binding_type () =
  let slot = Blorp.Type_widening.mutable_binding_slot (TyConstInt 1) in
  let value =
    Blorp.Ast.with_expr_type_info
      { (ast_int 1) with expr_type = None }
      {
        source_ty = None;
        semantic_ty = Blorp.Type_widening.semantic_type slot;
        value_ty = Blorp.Type_widening.value_type slot;
        origin = Inferred;
        widening = Blorp.Type_widening.decision slot;
        proofs = Blorp.Type_proof_metadata.unproven_expr;
        resolved_call = None;
      }
  in
  let vdecl =
    {
      var_name = Some "total";
      var_pattern = None;
      var_type = None;
      var_value = value;
      var_is_mutable = true;
      var_is_const = false;
    }
  in
  let prog = [ mk_decl (DVar vdecl) ] in
  match Blorp.Typed_ast.of_ast_program prog with
  | Error _ -> Alcotest.fail "expected typed program"
  | Ok typed_prog -> (
      match Blorp.Core_lower.lower_typed_program typed_prog with
      | [ { cd_desc = CDVar cv; _ } ] ->
          Alcotest.(check bool) "binding type is Int" true (cv.cv_ty = ty_int);
          Alcotest.(check bool)
            "initializer coerced to Int" true (cv.cv_init.ty = ty_int)
      | _ -> Alcotest.fail "expected one lowered global var")

let test_lower_record_passthrough () =
  let rdecl =
    {
      record_name = "Point";
      record_type_params = [];
      record_fields =
        [
          { field_name = "x"; field_type = ty_int; field_loc = loc };
          { field_name = "y"; field_type = ty_int; field_loc = loc };
        ];
      record_is_value = false;
      record_is_builtin = false;
    }
  in
  let cd = lower_decl (mk_decl (DRecord rdecl)) in
  match cd.cd_desc with
  | CDRecord r -> Alcotest.(check string) "name" "Point" r.record_name
  | _ -> Alcotest.fail "expected CDRecord"

let test_lower_type_passthrough () =
  let tdecl =
    {
      type_name = "Color";
      type_params = [];
      type_variants =
        [
          {
            variant_name = "Red";
            variant_fields = [];
            variant_tag = 0;
            variant_loc = loc;
            variant_def_id = None;
          };
          {
            variant_name = "Green";
            variant_fields = [];
            variant_tag = 1;
            variant_loc = loc;
            variant_def_id = None;
          };
          {
            variant_name = "Blue";
            variant_fields = [];
            variant_tag = 2;
            variant_loc = loc;
            variant_def_id = None;
          };
        ];
      type_is_enum = true;
      type_is_builtin = false;
      type_is_resource = false;
      type_resource_cleanup = None;
    }
  in
  let cd = lower_decl (mk_decl (DType tdecl)) in
  match cd.cd_desc with
  | CDType t -> Alcotest.(check string) "name" "Color" t.type_name
  | _ -> Alcotest.fail "expected CDType"

let test_lower_import_passthrough () =
  let idecl =
    { import_module = "memory"; import_symbols = None; import_alias = None }
  in
  let cd = lower_decl (mk_decl (DImport idecl)) in
  match cd.cd_desc with
  | CDImport i -> Alcotest.(check string) "module" "memory" i.import_module
  | _ -> Alcotest.fail "expected CDImport"

let test_lower_type_alias_passthrough () =
  let adecl =
    {
      alias_name = "Coord";
      alias_type_params = [];
      alias_target = TyTuple [ ty_int; ty_int ];
      alias_is_opaque = false;
    }
  in
  let cd = lower_decl (mk_decl (DTypeAlias adecl)) in
  match cd.cd_desc with
  | CDTypeAlias a -> Alcotest.(check string) "name" "Coord" a.alias_name
  | _ -> Alcotest.fail "expected CDTypeAlias"

let test_lower_private_wrapper () =
  (* private func helper(x: Int) -> Int: x + 1 *)
  let body = ast_add (ast_var "x" ty_int) (ast_int 1) in
  let func =
    mk_func_decl ~is_pure:true "helper"
      [ mk_param_named "x" ty_int ]
      ty_int (Some body)
  in
  let inner = mk_decl (DFunc func) in
  let outer = mk_decl (DPrivate inner) in
  let cd = lower_decl outer in
  match cd.cd_desc with
  | CDPrivate { cd_desc = CDFunc cf; _ } ->
      Alcotest.(check string) "inner func name" "helper" cf.cf_name
  | _ -> Alcotest.fail "expected CDPrivate(CDFunc _)"

let test_lower_impl () =
  (* impl Show for Int { func show(self: Int) -> String: ... } *)
  let body = ast_str "42" in
  let method_func =
    mk_func_decl ~is_pure:true "show"
      [ mk_param_named "self" ty_int ]
      ty_string (Some body)
  in
  let impl =
    {
      impl_trait = "Show";
      impl_for_type = ty_int;
      impl_methods = [ method_func ];
    }
  in
  let cd = lower_decl (mk_decl (DImpl impl)) in
  match cd.cd_desc with
  | CDImpl ci ->
      Alcotest.(check string) "trait" "Show" ci.ci_trait;
      Alcotest.(check int) "1 method" 1 (List.length ci.ci_methods);
      Alcotest.(check string)
        "method name" "show" (List.hd ci.ci_methods).cf_name
  | _ -> Alcotest.fail "expected CDImpl"

let test_lower_trait_with_default () =
  (* trait Greet { func greet(self: Self) -> String: "hi" } — default impl.
     Core IR no longer carries default bodies: Typecheck synthesizes them
     into each impl's method list before lowering, so core_trait_method
     only records the signature. This test pins that the signature
     survives but the body is not carried to Core IR. *)
  let default_body = ast_str "hi" in
  let method_sig =
    {
      method_name = "greet";
      method_params = [ mk_param_named "self" TySelf ];
      method_return_type = Some ty_string;
      method_is_pure = true;
      method_default_body = Some default_body;
    }
  in
  let trait =
    {
      trait_name = "Greet";
      trait_type_params = [];
      trait_supertraits = [];
      trait_methods = [ method_sig ];
    }
  in
  let cd = lower_decl (mk_decl (DTrait trait)) in
  match cd.cd_desc with
  | CDTrait ct ->
      Alcotest.(check string) "name" "Greet" ct.ct_name;
      let m = List.hd ct.ct_methods in
      Alcotest.(check string) "method name" "greet" m.ctm_name
  | _ -> Alcotest.fail "expected CDTrait"

(** Regression: fresh-name counters must reset per compile so repeated
    compilations produce identical Core. Counter reset moved from
    [lower_program] to [Session.reset_core_counters] in T1.4 — the
    test resets explicitly between calls, mirroring what [Core_pipeline]
    does at every compile entry. *)
let test_lower_program_deterministic () =
  let pair_ty = TyTuple [ ty_int; ty_int ] in
  let pair = ast_var "pair" pair_ty in
  let destruct = mk_ast (ETupleDestruct ([ "a"; "b" ], pair)) ty_void in
  let body = ast_add (ast_var "a" ty_int) (ast_var "b" ty_int) in
  let func =
    mk_func_decl ~is_pure:true "add_pair"
      [ mk_param_named "pair" pair_ty ]
      ty_int
      (Some (ast_block [ destruct; body ] ty_int))
  in
  let prog = [ mk_decl (DFunc func) ] in
  Blorp.Session.(reset_core_counters (current ()));
  let c1 = lower_program prog in
  Blorp.Session.(reset_core_counters (current ()));
  let c2 = lower_program prog in
  (* Extract the function body from each result and pp. *)
  let get_body cprog =
    match cprog with
    | [ { cd_desc = CDFunc { cf_body = Some body; _ }; _ } ] ->
        pp_to_string body
    | _ -> Alcotest.fail "expected single CDFunc with body"
  in
  Alcotest.(check string) "deterministic" (get_body c1) (get_body c2)

(** A3.1 invariants: every lowered core_func has a cf_def_id,
    and DefIds are unique across all functions in a program. *)
let test_cf_def_id_populated_and_unique () =
  Blorp.Session.(
    with_current (create ()) (fun () ->
        let source =
          {|
func a(x: Int) -> Int: x + 1
func b(x: Int) -> Int: x * 2
func c() -> Int: 42

func main(args: List[String]) -> Int:
    a(1) + b(2) + c()
|}
        in
        let program = Test_helpers.parse_program source in
        let typed, errors = Blorp.Typecheck.typecheck program in
        Alcotest.(check int) "no type errors" 0 (List.length errors);
        let cprog = lower_program typed in
        let funcs =
          List.filter_map
            (fun d -> match d.cd_desc with CDFunc f -> Some f | _ -> None)
            cprog
        in
        Alcotest.(check bool)
          "at least 4 funcs lowered" true
          (List.length funcs >= 4);
        let ids = List.map (fun f -> f.cf_def_id) funcs in
        let unique = List.sort_uniq compare ids in
        Alcotest.(check int)
          "cf_def_ids unique" (List.length ids) (List.length unique)))

(** Typed lowering must preserve the callable ids minted during typechecking.
    Inference threads those ids into resolved call metadata; minting fresh Core
    ids here makes UFCS/generic calls vulnerable to accidental id collisions in
    large combined programs. *)
let test_lower_typed_func_preserves_callable_id () =
  Blorp.Session.(
    with_current (create ()) (fun () ->
        let source =
          {|
func inc(x: Int) -> Int:
    x + 1

func caller() -> Int:
    inc(41)
|}
        in
        let program = Test_helpers.parse_program source in
        let typed =
          match Blorp.Typecheck.typecheck_with_state_typed program with
          | Ok (_state, typed) -> typed
          | Error errors ->
              Alcotest.fail
                ("expected no type errors, got:\n"
                ^ Test_helpers.format_errors errors)
        in
        let expected_ids =
          Blorp.Typed_ast.program_decls typed
          |> List.filter_map (fun decl ->
              match Blorp.Typed_ast.decl_func decl with
              | Some func -> (
                  match
                    ( (Blorp.Typed_ast.func_ast func).func_name,
                      Blorp.Typed_ast.func_callable_id func )
                  with
                  | Some name, Some callable_id -> Some (name, callable_id)
                  | _ -> None)
              | None -> None)
        in
        let cprog = Blorp.Core_lower.lower_typed_program typed in
        let funcs =
          List.filter_map
            (fun d -> match d.cd_desc with CDFunc f -> Some f | _ -> None)
            cprog
        in
        List.iter
          (fun f ->
            match List.assoc_opt f.cf_name expected_ids with
            | Some expected ->
                Alcotest.(check int)
                  ("cf_def_id for " ^ f.cf_name)
                  expected f.cf_def_id
            | None -> ())
          funcs))

(** A3.3: Core_lower parses a [#<def_id>] suffix off UFCS mangled
    identifiers and threads the DefId into [Core.var.vdef_id], leaving
    [vname] as the clean (unsuffixed) form.

    [Infer.infer_method_call] encodes the selected overload's
    [ol_def_id] into the mangled ident string — two call sites that
    select different overloads of the same method produce different
    suffixes, so they can't collide the way the earlier session-table
    design could. Testing just the lowering parse path is sufficient;
    the write path is exercised by runtime tests that perform
    module-imported UFCS calls. *)
let test_core_lower_parses_ufcs_def_id_suffix () =
  Blorp.Session.(
    with_current (create ()) (fun () ->
        let ident : Blorp.Ast.expr =
          mk_ast (Blorp.Ast.EIdent "__ufcs_std$list__get#99") ty_int
        in
        let core = lower_expr ident in
        match core.desc with
        | CVar v ->
            Alcotest.(check string)
              "vname is clean (no suffix)" "__ufcs_std$list__get" v.vname;
            Alcotest.(check (option int))
              "vdef_id parsed from suffix" (Some 99) v.vdef_id
        | _ -> Alcotest.fail "expected CVar"))

(** A3.3: UFCS ident without a suffix (fallback branch in infer) lowers
    to vdef_id = None. *)
let test_core_lower_ufcs_no_suffix () =
  Blorp.Session.(
    with_current (create ()) (fun () ->
        let ident : Blorp.Ast.expr =
          mk_ast (Blorp.Ast.EIdent "__ufcs_std$list__get") ty_int
        in
        let core = lower_expr ident in
        match core.desc with
        | CVar v ->
            Alcotest.(check string)
              "vname unchanged" "__ufcs_std$list__get" v.vname;
            Alcotest.(check (option int)) "no vdef_id" None v.vdef_id
        | _ -> Alcotest.fail "expected CVar"))

(** Phase 6 bridge: a typed call's [resolved_call] metadata is the source-level
    authority for callable identity. Lowering should carry that identity on the
    Core call kind even when the callee name itself has no UFCS suffix. *)
let test_core_lower_call_uses_resolved_call_def_id () =
  Blorp.Session.(
    with_current (create ()) (fun () ->
        let callee_ty =
          TyFunc { params = [ ty_int ]; return = ty_int; is_pure = true }
        in
        let callee = mk_ast (Blorp.Ast.EIdent "inc") callee_ty in
        let resolved_call =
          {
            call_syntax = CallBare;
            call_target =
              CallDirect
                {
                  callable_id = 321;
                  source_name = "inc";
                  call_pure = true;
                  origin = CallableLocal;
                };
            instantiated_params = [ ty_int ];
            instantiated_return = ty_int;
          }
        in
        let call =
          Blorp.Ast.with_expr_resolved_call
            (mk_ast (Blorp.Ast.ECall (callee, [ ast_int 1 ])) ty_int)
            resolved_call
        in
        let core = lower_expr call in
        match core.desc with
        | CCall (CKSelectedDirect 321, { desc = CVar v; _ }, _) ->
            Alcotest.(check string) "callee name" "inc" v.vname;
            Alcotest.(check (option int))
              "callee vdef_id remains local to callee identity" None v.vdef_id
        | _ -> Alcotest.fail "expected CCall with CVar callee"))

(** Bridge-selected IDs are local to a typecheck request. Imported qualified
    calls must keep the module-field shape for monomorphization and intrinsic
    dispatch, then let module-aware Core resolution choose the target. *)
let test_core_lower_qualified_imported_call_ignores_selected_call_id () =
  Blorp.Session.(
    with_current (create ()) (fun () ->
        let module_ty = TyNamed ("Module", []) in
        let callee_ty =
          TyFunc
            { params = [ ty_list_int ]; return = ty_list_int; is_pure = true }
        in
        let alias = ast_var "L" module_ty in
        let callee =
          mk_ast (Blorp.Ast.EFieldAccess (alias, "reverse")) callee_ty
        in
        let xs = ast_var "xs" ty_list_int in
        let resolved_call =
          {
            call_syntax = CallQualified "std/list";
            call_target =
              CallDirect
                {
                  callable_id = 654;
                  source_name = "reverse";
                  call_pure = true;
                  origin = CallableImported "std/list";
                };
            instantiated_params = [ ty_list_int ];
            instantiated_return = ty_list_int;
          }
        in
        let call =
          Blorp.Ast.with_expr_resolved_call
            (mk_ast (Blorp.Ast.ECall (callee, [ xs ])) ty_list_int)
            resolved_call
        in
        let core = lower_expr call in
        match core.desc with
        | CCall
            ( CKUnknown,
              {
                desc =
                  CField
                    ( { desc = CVar { vname = "L"; vdef_id = None; _ }; _ },
                      "reverse" );
                _;
              },
              _ ) ->
            ()
        | _ ->
            Alcotest.fail
              "expected imported qualified call to preserve CField without \
               trusting bridge-local callable id"))

(** Annotated local bindings rewrap the initializer with the declared slot type.
    That must keep the imported module-field callee shape so the later
    module-aware resolver does not mistake it for closure field dispatch. *)
let test_core_lower_annotated_binding_preserves_imported_call_shape () =
  Blorp.Session.(
    with_current (create ()) (fun () ->
        let module_ty = TyNamed ("Module", []) in
        let callee_ty =
          TyFunc { params = [ ty_int ]; return = ty_fixed; is_pure = true }
        in
        let alias = ast_var "F" module_ty in
        let callee = mk_ast (EFieldAccess (alias, "fixed")) callee_ty in
        let resolved_call =
          {
            call_syntax = CallQualified "std/fixed";
            call_target =
              CallDirect
                {
                  callable_id = 777;
                  source_name = "fixed";
                  call_pure = true;
                  origin = CallableImported "std/fixed";
                };
            instantiated_params = [ ty_int ];
            instantiated_return = ty_fixed;
          }
        in
        let init =
          Blorp.Ast.with_expr_resolved_call
            (mk_ast (ECall (callee, [ ast_int 2 ])) ty_fixed)
            resolved_call
        in
        let binding =
          mk_ast (EVarDecl ("price", Some ty_fixed, init, false)) ty_void
        in
        let block = ast_block [ binding; ast_var "price" ty_fixed ] ty_fixed in
        let core = lower_expr block in
        match core.desc with
        | CLet
            ( {
                bind_rhs =
                  {
                    desc =
                      CCall
                        ( CKUnknown,
                          {
                            desc =
                              CField
                                ( {
                                    desc =
                                      CVar { vname = "F"; vdef_id = None; _ };
                                    _;
                                  },
                                  "fixed" );
                            _;
                          },
                          _ );
                    _;
                  };
                _;
              },
              _ ) ->
            ()
        | _ ->
            Alcotest.fail
              "expected annotated binding initializer to retain qualified \
               selected call kind"))

(** A3.3: non-UFCS idents lower to CVar with vdef_id = None. *)
let test_core_lower_non_ufcs_ident_has_no_def_id () =
  Blorp.Session.(
    with_current (create ()) (fun () ->
        let ident : Blorp.Ast.expr =
          mk_ast (Blorp.Ast.EIdent "regular_ident") ty_int
        in
        let core = lower_expr ident in
        match core.desc with
        | CVar v -> Alcotest.(check (option int)) "no vdef_id" None v.vdef_id
        | _ -> Alcotest.fail "expected CVar"))

(** Integration sanity: parse → typecheck → lower a real source string.
    This exercises [lower_program] on realistic AST nodes produced by the
    actual parser + type-checker, not hand-built ones. *)
let test_lower_real_source () =
  let source =
    {|
func inc(x: Int) -> Int:
    x + 1

func main(args: List[String]) -> Int:
    inc(41)
|}
  in
  let program = Test_helpers.parse_program source in
  let typed_program, errors = Blorp.Typecheck.typecheck program in
  Alcotest.(check int) "no type errors" 0 (List.length errors);
  let cprog = lower_program typed_program in
  (* Find the two functions *)
  let funcs =
    List.filter_map
      (fun d -> match d.cd_desc with CDFunc f -> Some f | _ -> None)
      cprog
  in
  let names = List.map (fun f -> f.cf_name) funcs in
  Alcotest.(check bool) "inc lowered" true (List.mem "inc" names);
  Alcotest.(check bool) "main lowered" true (List.mem "main" names);
  (* inc body should be (x + 1), lowered to CBin(Add, ...) *)
  let inc = List.find (fun f -> f.cf_name = "inc") funcs in
  match inc.cf_body with
  | Some { desc = CBin (Add, _, _); _ } -> ()
  | Some other ->
      Alcotest.failf "inc body not CBin(Add,_,_): got %s" (pp_to_string other)
  | None -> Alcotest.fail "inc has no body"

let test_lower_program_multi () =
  (* A small program: a record + a function + a global *)
  let rdecl =
    {
      record_name = "Point";
      record_type_params = [];
      record_fields =
        [ { field_name = "x"; field_type = ty_int; field_loc = loc } ];
      record_is_value = false;
      record_is_builtin = false;
    }
  in
  let body = ast_int 42 in
  let func = mk_func_decl ~is_pure:true "main" [] ty_int (Some body) in
  let vdecl =
    {
      var_name = Some "MAX";
      var_pattern = None;
      var_type = Some ty_int;
      var_value = ast_int 100;
      var_is_mutable = false;
      var_is_const = true;
    }
  in
  let prog =
    [ mk_decl (DRecord rdecl); mk_decl (DFunc func); mk_decl (DVar vdecl) ]
  in
  let cprog = lower_program prog in
  Alcotest.(check int) "3 decls" 3 (List.length cprog);
  match
    ( (List.nth cprog 0).cd_desc,
      (List.nth cprog 1).cd_desc,
      (List.nth cprog 2).cd_desc )
  with
  | CDRecord _, CDFunc _, CDVar _ -> ()
  | _ -> Alcotest.fail "unexpected decl shapes"

let test_lower_typed_program_multi () =
  let body = ast_int 42 in
  let func = mk_func_decl ~is_pure:true "main" [] ty_int (Some body) in
  let prog = [ mk_decl (DFunc func) ] in
  match Blorp.Typed_ast.of_ast_program prog with
  | Error _ -> Alcotest.fail "expected typed program"
  | Ok typed_prog -> (
      let cprog = Blorp.Core_lower.lower_typed_program typed_prog in
      match cprog with
      | [ { cd_desc = CDFunc f; _ } ] ->
          Alcotest.(check string) "function name" "main" f.cf_name
      | _ -> Alcotest.fail "expected one lowered function")

let test_lower_typed_program_uses_semantic_return_type () =
  let body = ast_int 42 in
  let func =
    {
      (mk_func_decl ~is_pure:true "answer" [] ty_int (Some body)) with
      func_return_type = None;
    }
  in
  let prog = [ mk_decl (DFunc func) ] in
  match Blorp.Typed_ast.of_ast_program prog with
  | Error _ -> Alcotest.fail "expected typed program"
  | Ok typed_prog -> (
      let cprog = Blorp.Core_lower.lower_typed_program typed_prog in
      match cprog with
      | [ { cd_desc = CDFunc f; _ } ] ->
          Alcotest.(check bool)
            "semantic return type retained" true (f.cf_return_ty = ty_int)
      | _ -> Alcotest.fail "expected one lowered function")

let test_lower_typed_impl_method_uses_semantic_return_type () =
  let body = ast_str "42" in
  let method_func =
    {
      (mk_func_decl ~is_pure:true "show"
         [ mk_param_named "self" ty_int ]
         ty_string (Some body))
      with
      func_return_type = None;
    }
  in
  let impl =
    {
      impl_trait = "Show";
      impl_for_type = ty_int;
      impl_methods = [ method_func ];
    }
  in
  let prog = [ mk_decl (DImpl impl) ] in
  match Blorp.Typed_ast.of_ast_program prog with
  | Error _ -> Alcotest.fail "expected typed program"
  | Ok typed_prog -> (
      let cprog = Blorp.Core_lower.lower_typed_program typed_prog in
      match cprog with
      | [ { cd_desc = CDImpl { ci_methods = [ method_ ]; _ }; _ } ] ->
          Alcotest.(check bool)
            "impl method semantic return type retained" true
            (method_.cf_return_ty = ty_string)
      | _ -> Alcotest.fail "expected one lowered impl method")

(* ============================================================================
   Test suite
   ============================================================================ *)

let suite =
  [
    ( "leaves",
      [
        Alcotest.test_case "int_lit" `Quick test_lower_int_lit;
        Alcotest.test_case "bool_lit" `Quick test_lower_bool_lit;
        Alcotest.test_case "string_lit" `Quick test_lower_string_lit;
        Alcotest.test_case "void" `Quick test_lower_void;
        Alcotest.test_case "ident" `Quick test_lower_ident;
        Alcotest.test_case "break" `Quick test_lower_break;
        Alcotest.test_case "continue" `Quick test_lower_continue;
        Alcotest.test_case "builtin_raises" `Quick test_lower_builtin_raises;
      ] );
    ( "operators",
      [
        Alcotest.test_case "binary" `Quick test_lower_binary;
        Alcotest.test_case "unary" `Quick test_lower_unary;
        Alcotest.test_case "logical" `Quick test_lower_logical;
      ] );
    ( "call_field",
      [
        Alcotest.test_case "call" `Quick test_lower_call;
        Alcotest.test_case "field" `Quick test_lower_field;
        Alcotest.test_case "module_alias_field_typed_sentinel" `Quick
          test_lower_module_alias_field_uses_typed_sentinel;
        Alcotest.test_case "module_alias_field_rejects_untyped_alias" `Quick
          test_lower_module_alias_field_rejects_untyped_alias;
      ] );
    ( "control",
      [
        Alcotest.test_case "if_with_else" `Quick test_lower_if_with_else;
        Alcotest.test_case "if_no_else" `Quick test_lower_if_without_else;
        Alcotest.test_case "while" `Quick test_lower_while;
        Alcotest.test_case "for" `Quick test_lower_for;
        Alcotest.test_case "for_unsupported_iterable" `Quick
          test_lower_for_unsupported_iterable_raises;
        Alcotest.test_case "for_tuple_unsupported_iterable" `Quick
          test_lower_for_tuple_unsupported_iterable_raises;
        Alcotest.test_case "tuple_for_binds_tuple_type" `Quick
          test_lower_tuple_for_binds_tuple_type;
        Alcotest.test_case "enumerate_nonconstant_tensor_inner_dims" `Quick
          test_lower_enumerate_nonconstant_tensor_inner_dims_raises;
        Alcotest.test_case "enumerate_non_array" `Quick
          test_lower_enumerate_non_array_raises;
        Alcotest.test_case "loop_view_outside_for" `Quick
          test_lower_loop_view_outside_for_raises;
        Alcotest.test_case "windows_non_array" `Quick
          test_lower_windows_non_array_raises;
        Alcotest.test_case "match" `Quick test_lower_match;
      ] );
    ( "data",
      [
        Alcotest.test_case "tuple" `Quick test_lower_tuple;
        Alcotest.test_case "list" `Quick test_lower_list;
        Alcotest.test_case "record" `Quick test_lower_record;
        Alcotest.test_case "record_update" `Quick test_lower_record_update;
        Alcotest.test_case "range" `Quick test_lower_range;
        Alcotest.test_case "dict" `Quick test_lower_dict;
      ] );
    ( "lambda",
      [
        Alcotest.test_case "lambda" `Quick test_lower_lambda;
        Alcotest.test_case "lambda_missing_param_type" `Quick
          test_lower_lambda_missing_param_type_raises;
        Alcotest.test_case "lambda_missing_body" `Quick
          test_lower_lambda_missing_body_raises;
      ] );
    ( "block",
      [
        Alcotest.test_case "empty" `Quick test_lower_empty_block;
        Alcotest.test_case "single_expr" `Quick test_lower_single_expr_block;
        Alcotest.test_case "var_decl" `Quick test_lower_block_with_var_decl;
        Alcotest.test_case "mut_var_decl" `Quick
          test_lower_block_with_mut_var_decl;
        Alcotest.test_case "seq" `Quick test_lower_block_with_seq;
        Alcotest.test_case "mixed" `Quick test_lower_block_mixed;
        Alcotest.test_case "tuple_destr" `Quick test_lower_tuple_destruct;
        Alcotest.test_case "singleton_var" `Quick
          test_lower_singleton_block_with_var_decl;
        Alcotest.test_case "singleton_destr" `Quick
          test_lower_singleton_block_with_tuple_destruct;
      ] );
    ("assign", [ Alcotest.test_case "assign" `Quick test_lower_assign ]);
    ( "sugar",
      [
        Alcotest.test_case "string_interp" `Quick test_lower_string_interp;
        Alcotest.test_case "raw_string_interp_raises" `Quick
          test_lower_raw_string_interp_raises;
        Alcotest.test_case "question_bind" `Quick
          test_lower_question_bind_statement;
        Alcotest.test_case "result_question_bind_rebuilds_error_carrier" `Quick
          test_lower_result_question_bind_rebuilds_error_carrier;
        Alcotest.test_case "question_bind_direct_error" `Quick
          test_lower_question_bind_direct_error;
        Alcotest.test_case "plain_with_resource_scope" `Quick
          test_lower_plain_with_to_resource_scope;
        Alcotest.test_case "registered_resource_cleanup" `Quick
          test_lower_with_uses_registered_resource_cleanup;
        Alcotest.test_case "fallible_with_resource_scope" `Quick
          test_lower_fallible_with_to_resource_scope_success_arm;
        Alcotest.test_case "fallible_with_body_question_bind_scope" `Quick
          test_lower_fallible_with_body_question_bind_stays_inside_resource_scope;
      ] );
    ( "concurrency",
      [
        Alcotest.test_case "detach" `Quick test_lower_detach;
        Alcotest.test_case "concurrent" `Quick test_lower_concurrent;
        Alcotest.test_case "concurrent_rejects_non_bindings" `Quick
          test_lower_concurrent_rejects_non_bindings;
        Alcotest.test_case "concurrent_preserves_explicit_bindings" `Quick
          test_lower_concurrent_preserves_explicit_bindings;
        Alcotest.test_case "concurrently_loop" `Quick
          test_lower_concurrently_loop;
        Alcotest.test_case "nested_concurrently_loop_task_scopes" `Quick
          test_lower_nested_concurrently_loop_task_scopes;
      ] );
    ( "invariants",
      [
        Alcotest.test_case "types_preserved" `Quick test_types_preserved;
        Alcotest.test_case "missing_type_raises" `Quick test_missing_type_raises;
        Alcotest.test_case "missing_child_type_raises" `Quick
          test_missing_child_type_raises;
        Alcotest.test_case "meta_type_raises" `Quick test_meta_type_raises;
        Alcotest.test_case "param_missing_type" `Quick
          test_param_missing_type_raises;
        Alcotest.test_case "param_meta_type" `Quick test_param_meta_type_raises;
        Alcotest.test_case "return_meta_type" `Quick
          test_return_meta_type_raises;
        Alcotest.test_case "param_without_name_or_pattern" `Quick
          test_param_without_name_or_pattern_raises;
        Alcotest.test_case "function_without_name" `Quick
          test_function_without_name_raises;
        Alcotest.test_case "param_name_and_pattern" `Quick
          test_param_with_name_and_pattern_raises;
        Alcotest.test_case "tuple_shape_mismatch" `Quick
          test_tuple_destruct_shape_mismatch_raises;
        Alcotest.test_case "program_decl_error_propagates" `Quick
          test_lower_program_propagates_decl_errors;
        Alcotest.test_case "global_pattern_var_direct" `Quick
          test_global_pattern_var_direct_raises;
      ] );
    ( "decls",
      [
        Alcotest.test_case "simple_func" `Quick test_lower_simple_func;
        Alcotest.test_case "foreign_func" `Quick test_lower_foreign_func;
        Alcotest.test_case "foreign_pure_borrows_args" `Quick
          test_lower_foreign_pure_borrows_args;
        Alcotest.test_case "foreign_no_copy_borrows_args" `Quick
          test_lower_foreign_no_copy_borrows_args;
        Alcotest.test_case "pattern_param_func" `Quick
          test_lower_func_with_pattern_param;
        Alcotest.test_case "global_var" `Quick test_lower_global_var;
        Alcotest.test_case "typed_global_var_binding_type" `Quick
          test_lower_typed_global_var_uses_binding_type;
        Alcotest.test_case "record_passthrough" `Quick
          test_lower_record_passthrough;
        Alcotest.test_case "type_passthrough" `Quick test_lower_type_passthrough;
        Alcotest.test_case "import_passthrough" `Quick
          test_lower_import_passthrough;
        Alcotest.test_case "alias_passthrough" `Quick
          test_lower_type_alias_passthrough;
        Alcotest.test_case "private_wrapper" `Quick test_lower_private_wrapper;
        Alcotest.test_case "impl" `Quick test_lower_impl;
        Alcotest.test_case "trait_with_default" `Quick
          test_lower_trait_with_default;
        Alcotest.test_case "program_multi" `Quick test_lower_program_multi;
        Alcotest.test_case "typed_program_multi" `Quick
          test_lower_typed_program_multi;
        Alcotest.test_case "typed_program_semantic_return_type" `Quick
          test_lower_typed_program_uses_semantic_return_type;
        Alcotest.test_case "typed_impl_method_semantic_return_type" `Quick
          test_lower_typed_impl_method_uses_semantic_return_type;
        Alcotest.test_case "deterministic" `Quick
          test_lower_program_deterministic;
        Alcotest.test_case "real_source" `Quick test_lower_real_source;
        Alcotest.test_case "cf_def_id populated and unique" `Quick
          test_cf_def_id_populated_and_unique;
        Alcotest.test_case "typed func preserves callable id" `Quick
          test_lower_typed_func_preserves_callable_id;
        Alcotest.test_case "core_lower parses ufcs def_id suffix" `Quick
          test_core_lower_parses_ufcs_def_id_suffix;
        Alcotest.test_case "core_lower ufcs no suffix" `Quick
          test_core_lower_ufcs_no_suffix;
        Alcotest.test_case "core_lower call uses resolved_call def_id" `Quick
          test_core_lower_call_uses_resolved_call_def_id;
        Alcotest.test_case "core_lower qualified import ignores selected id"
          `Quick test_core_lower_qualified_imported_call_ignores_selected_call_id;
        Alcotest.test_case "annotated binding preserves imported call shape" `Quick
          test_core_lower_annotated_binding_preserves_imported_call_shape;
        Alcotest.test_case "non-ufcs ident has no vdef_id" `Quick
          test_core_lower_non_ufcs_ident_has_no_def_id;
      ] );
  ]
