(** Tests for Core_emit: Core IR → C string.

    Phase 1.2b scope: basic arithmetic, control flow, let bindings,
    simple function calls. Matches the existing codegen byte-for-byte
    on the supported subset. *)

open Blorp.Ast
open Blorp.Core

(* ============================================================================
   Test helpers
   ============================================================================ *)

let loc =
  { line = 1; column = 1; end_line = 1; end_column = 1; loc_file = None }

let ty_int = TyNamed ("Int", [])
let ty_bool = TyNamed ("Bool", [])
let ty_float = TyNamed ("Float", [])
let ty_char = TyNamed ("Char", [])
let ty_int128 = TyNamed ("Int128", [])
let ty_uint128 = TyNamed ("UInt128", [])
let ty_fixed = TyNamed ("Fixed", [])
let ty_string = TyNamed ("String", [])
let ty_ptr = TyNamed ("Ptr", [])
let ty_void = TyNamed ("Void", [])
let ty_channel_int = TyNamed ("Channel", [ ty_int ])
let ty_list_string = TyNamed ("List", [ ty_string ])
let ty_set_string = TyNamed ("Set", [ ty_string ])
let ty_dict_string_string = TyNamed ("Dict", [ ty_string; ty_string ])
let ty_opt_string = TyNamed ("Option", [ ty_string ])
let ty_result_int_bool = TyNamed ("Result", [ ty_int; ty_bool ])
let ty_result_int_string = TyNamed ("Result", [ ty_int; ty_string ])
let ty_test_resource = TyNamed ("TestResource", [])

let ty_result_opt_string_string =
  TyNamed ("Result", [ ty_opt_string; ty_string ])

let ast_with_type expr ty =
  Blorp.Ast.with_expr_type_info expr (Blorp.Ast.expr_type_info_from_type ty)

let option_int = TyNamed ("Option", [ ty_int ])
let option_float = TyNamed ("Option", [ ty_float ])
let option_bool = TyNamed ("Option", [ ty_bool ])
let option_char = TyNamed ("Option", [ ty_char ])
let option_int128 = TyNamed ("Option", [ ty_int128 ])
let option_uint128 = TyNamed ("Option", [ ty_uint128 ])
let mk d t = { desc = d; ty = t; loc }
let cint n = mk (CLit (LitInt (Int64.of_int n))) ty_int
let cbool b = mk (CLit (LitBool b)) ty_bool
let cfloat f = mk (CLit (LitFloat f)) ty_float

let cstr s =
  mk (CLit (LitString (s, { sf_triple = false; sf_raw = false }))) ty_string

let cvoid = mk CVoid ty_void
let cvar n t = mk (CVar (Var.named n)) t
let lower_expr = Test_helpers.lower_valid_expr
let compile_program = Test_helpers.compile_valid_program

let clist ?(layout = list_pointer_storage ()) elems =
  CList { ll_layout = layout; ll_elems = elems }

let clist_for ty elems =
  CList
    {
      ll_layout = Blorp.Core_list_layout.layout_of_type ty loc;
      ll_elems = elems;
    }

let boxed_int_storage value =
  {
    bsv_box = { box_value = value; box_source_ty = ty_int; box_kind = BoxPrim };
    bsv_needs_release = false;
    bsv_transfers_ownership = false;
  }

let boxed_storage value source_ty =
  {
    bsv_box =
      { box_value = value; box_source_ty = source_ty; box_kind = BoxPrim };
    bsv_needs_release = false;
    bsv_transfers_ownership = false;
  }

let boxed_pointer_storage value source_ty =
  {
    bsv_box =
      { box_value = value; box_source_ty = source_ty; box_kind = BoxPointer };
    bsv_needs_release = true;
    bsv_transfers_ownership = true;
  }

let contains_sub output sub =
  let n = String.length sub in
  let m = String.length output in
  let rec go i = i + n <= m && (String.sub output i n = sub || go (i + 1)) in
  go 0

(** Emit a Core expression and return the resulting C string. *)
let emit_to_string (e : core) : string =
  let ctx = Blorp.Core_emit_context.create () in
  Blorp.Core_emit.emit_expr ctx e;
  Buffer.contents ctx.output

let emit_to_string_with_ctx (ctx : Blorp.Core_emit_context.t) (e : core) :
    string =
  Blorp.Core_emit.emit_expr ctx e;
  Buffer.contents ctx.output

(** Emit a Core expression in statement context and return the C. *)
let emit_stmt_to_string (e : core) : string =
  let ctx = Blorp.Core_emit_context.create () in
  Blorp.Core_emit.emit_stmt ctx e;
  Buffer.contents ctx.output

(* ============================================================================
   Literals
   ============================================================================ *)

let test_emit_int () =
  (* Matches gen_literal: "42L" with an L suffix *)
  Alcotest.(check string) "int 42" "42L" (emit_to_string (cint 42))

let test_emit_int_zero () =
  Alcotest.(check string) "int 0" "0L" (emit_to_string (cint 0))

let test_emit_int_negative () =
  Alcotest.(check string) "int -5" "-5L" (emit_to_string (cint (-5)))

let test_emit_bool_true () =
  Alcotest.(check string) "bool true" "true" (emit_to_string (cbool true))

let test_emit_bool_false () =
  Alcotest.(check string) "bool false" "false" (emit_to_string (cbool false))

let test_emit_float () =
  let e = mk (CLit (LitFloat 3.14)) (TyNamed ("Float", [])) in
  let s = emit_to_string e in
  Alcotest.(check bool) "starts with 3" true (String.length s > 0 && s.[0] = '3')

let test_emit_char () =
  let e = mk (CLit (LitChar 65)) (TyNamed ("Char", [])) in
  (* Matches gen_literal: emits the codepoint as an integer *)
  Alcotest.(check string) "char 'A' (65)" "65" (emit_to_string e)

(* ============================================================================
   Variables and void
   ============================================================================ *)

let test_emit_var () =
  Alcotest.(check string) "var x" "x" (emit_to_string (cvar "x" ty_int))

let test_emit_void () =
  Alcotest.(check string) "void" "(void)0" (emit_to_string cvoid)

(* ============================================================================
   Operators
   ============================================================================ *)

let test_emit_add () =
  let e = mk (CBin (Add, cint 1, cint 2)) ty_int in
  Alcotest.(check string) "1+2" "(1L + 2L)" (emit_to_string e)

let test_emit_mul_nested () =
  (* (1 + 2) * 3 *)
  let add = mk (CBin (Add, cint 1, cint 2)) ty_int in
  let e = mk (CBin (Mul, add, cint 3)) ty_int in
  Alcotest.(check string) "(1+2)*3" "((1L + 2L) * 3L)" (emit_to_string e)

let test_emit_compare () =
  let e = mk (CBin (Lt, cvar "a" ty_int, cvar "b" ty_int)) ty_bool in
  Alcotest.(check string) "a<b" "(a < b)" (emit_to_string e)

let test_emit_eq () =
  let e = mk (CBin (Eq, cint 1, cint 1)) ty_bool in
  Alcotest.(check string) "1==1" "(1L == 1L)" (emit_to_string e)

let test_emit_float_modulo_uses_fmod () =
  let e = mk (CBin (Mod, cfloat 7.5, cfloat 2.5)) ty_float in
  let output = emit_to_string e in
  Alcotest.(check bool) "uses fmod" true (contains_sub output "fmod(");
  Alcotest.(check bool)
    "guards zero divisor" true
    (contains_sub output " == 0.0 ? 0.0 : ")

let test_emit_fixed_add_uses_runtime () =
  let e = mk (CBin (Add, cvar "a" ty_fixed, cvar "b" ty_fixed)) ty_fixed in
  Alcotest.(check string) "fixed add" "blorp_fixed_add(a, b)" (emit_to_string e)

let test_emit_fixed_sub_uses_runtime () =
  let e = mk (CBin (Sub, cvar "a" ty_fixed, cvar "b" ty_fixed)) ty_fixed in
  Alcotest.(check string) "fixed sub" "blorp_fixed_sub(a, b)" (emit_to_string e)

let test_emit_fixed_mul_uses_runtime () =
  let e = mk (CBin (Mul, cvar "a" ty_fixed, cvar "b" ty_fixed)) ty_fixed in
  Alcotest.(check string) "fixed mul" "blorp_fixed_mul(a, b)" (emit_to_string e)

let test_emit_fixed_div_uses_runtime () =
  let e = mk (CBin (Div, cvar "a" ty_fixed, cvar "b" ty_fixed)) ty_fixed in
  Alcotest.(check string) "fixed div" "blorp_fixed_div(a, b)" (emit_to_string e)

let test_emit_fixed_eq_uses_runtime () =
  let e = mk (CBin (Eq, cvar "a" ty_fixed, cvar "b" ty_fixed)) ty_bool in
  Alcotest.(check string) "fixed eq" "blorp_fixed_eq(a, b)" (emit_to_string e)

let test_emit_fixed_ne_uses_runtime () =
  let e = mk (CBin (Ne, cvar "a" ty_fixed, cvar "b" ty_fixed)) ty_bool in
  Alcotest.(check string)
    "fixed ne" "(!blorp_fixed_eq(a, b))" (emit_to_string e)

let test_emit_fixed_ordering_uses_runtime () =
  let cases =
    [
      (Lt, "blorp_fixed_lt(a, b)");
      (Le, "blorp_fixed_le(a, b)");
      (Gt, "blorp_fixed_gt(a, b)");
      (Ge, "blorp_fixed_ge(a, b)");
    ]
  in
  List.iter
    (fun (op, expected) ->
      let e = mk (CBin (op, cvar "a" ty_fixed, cvar "b" ty_fixed)) ty_bool in
      Alcotest.(check string) "fixed ordering" expected (emit_to_string e))
    cases

let test_emit_neg () =
  let e = mk (CUn (Neg, cvar "x" ty_int)) ty_int in
  Alcotest.(check string) "-x" "(-x)" (emit_to_string e)

let test_emit_not () =
  let e = mk (CUn (Not, cbool true)) ty_bool in
  Alcotest.(check string) "not true" "(!true)" (emit_to_string e)

let test_emit_and () =
  let e = mk (CLog (And, cbool true, cbool false)) ty_bool in
  Alcotest.(check string) "true && false" "(true && false)" (emit_to_string e)

let test_emit_or () =
  let e = mk (CLog (Or, cbool false, cbool true)) ty_bool in
  Alcotest.(check string) "false || true" "(false || true)" (emit_to_string e)

(* ============================================================================
   If (ternary)
   ============================================================================ *)

let test_emit_if_simple () =
  let e = mk (CIf (cbool true, cint 1, cint 0)) ty_int in
  Alcotest.(check string)
    "ternary"
    (String.concat "\n" [ "(true ?"; "    1L :"; "    0L)" ])
    (emit_to_string e)

let test_emit_if_nested () =
  (* if x < 0 then -1 else if x == 0 then 0 else 1 *)
  let x = cvar "x" ty_int in
  let inner =
    mk (CIf (mk (CBin (Eq, x, cint 0)) ty_bool, cint 0, cint 1)) ty_int
  in
  let e =
    mk
      (CIf
         ( mk (CBin (Lt, x, cint 0)) ty_bool,
           mk (CUn (Neg, cint 1)) ty_int,
           inner ))
      ty_int
  in
  Alcotest.(check string)
    "nested"
    (String.concat "\n"
       [
         "((x < 0L) ?";
         "    (-1L) :";
         "    ((x == 0L) ?";
         "        0L :";
         "        1L))";
       ])
    (emit_to_string e)

(* ============================================================================
   Let (GCC statement expression)
   ============================================================================ *)

let test_emit_let_simple () =
  (* let x: Int = 10 in x + 1 *)
  let bind =
    {
      bind_var = Var.named "x";
      bind_mut = false;
      bind_ty = ty_int;
      bind_rhs = cint 10;
    }
  in
  let body = mk (CBin (Add, cvar "x" ty_int, cint 1)) ty_int in
  let e = mk (CLet (bind, body)) ty_int in
  Alcotest.(check string)
    "let" "({ long x = 10L; (x + 1L); })" (emit_to_string e)

let test_emit_let_nested () =
  (* let a: Int = 1 in let b: Int = 2 in a + b *)
  let inner_bind =
    {
      bind_var = Var.named "b";
      bind_mut = false;
      bind_ty = ty_int;
      bind_rhs = cint 2;
    }
  in
  let inner_body = mk (CBin (Add, cvar "a" ty_int, cvar "b" ty_int)) ty_int in
  let inner = mk (CLet (inner_bind, inner_body)) ty_int in
  let outer_bind =
    {
      bind_var = Var.named "a";
      bind_mut = false;
      bind_ty = ty_int;
      bind_rhs = cint 1;
    }
  in
  let e = mk (CLet (outer_bind, inner)) ty_int in
  Alcotest.(check string)
    "nested let" "({ long a = 1L; ({ long b = 2L; (a + b); }); })"
    (emit_to_string e)

(* ============================================================================
   Seq
   ============================================================================ *)

let test_emit_seq () =
  let e = mk (CSeq (cint 1, cint 2)) ty_int in
  Alcotest.(check string) "seq" "({ 1L; 2L; })" (emit_to_string e)

(* ============================================================================
   Resource scope
   ============================================================================ *)

let resource_cleanup_call resource_var =
  let close_ty =
    TyFunc { params = [ ty_test_resource ]; return = ty_void; is_pure = false }
  in
  mk
    (CCall
       ( CKUser ("close", None),
         cvar "close" close_ty,
         [ mk (CVar resource_var) ty_test_resource ] ))
    ty_void

let resource_scope body =
  let resource_var = Var.named "resource" in
  mk
    (CResourceScope
       {
         rs_var = resource_var;
         rs_ty = ty_test_resource;
         rs_acquire = cvar "open_resource" ty_test_resource;
         rs_body = body;
         rs_cleanup = resource_cleanup_call resource_var;
       })
    body.ty

let test_emit_resource_scope_expr_normal_completion () =
  let e = resource_scope (cint 7) in
  Alcotest.(check string)
    "resource expr"
    "({ TestResource* resource = open_resource; blorp_CancelCleanupFrame \
     __blorp_cleanup_resource; \
     blorp_task_cleanup_push(&__blorp_cleanup_resource, &resource, \
     (void*)resource, (blorp_CancelCleanupFn)_blorp_close); long \
     __resource_result_0 = 7L; blorp_task_cleanup_pop_slot(&resource); \
     _blorp_close(resource); __resource_result_0; })"
    (emit_to_string e)

let test_emit_resource_scope_stmt_normal_completion () =
  let e = resource_scope (cint 7) in
  Alcotest.(check string)
    "resource stmt"
    "{\n\
    \    TestResource* resource = open_resource;\n\
    \    blorp_CancelCleanupFrame __blorp_cleanup_resource; \
     blorp_task_cleanup_push(&__blorp_cleanup_resource, &resource, \
     (void*)resource, (blorp_CancelCleanupFn)_blorp_close);\n\
    \    7L;\n\
    \    blorp_task_cleanup_pop_slot(&resource);\n\
    \    _blorp_close(resource);\n\
     }\n"
    (emit_stmt_to_string e)

let test_emit_resource_scope_stmt_loop_local_break_cleanup_after_loop () =
  let loop_body =
    mk
      (CWhile
         ( cbool true,
           mk (CSeq (mk CContinue ty_void, mk CBreak ty_void)) ty_void ))
      ty_void
  in
  let e = resource_scope loop_body in
  Alcotest.(check string)
    "resource stmt loop-local break"
    "{\n\
    \    TestResource* resource = open_resource;\n\
    \    blorp_CancelCleanupFrame __blorp_cleanup_resource; \
     blorp_task_cleanup_push(&__blorp_cleanup_resource, &resource, \
     (void*)resource, (blorp_CancelCleanupFn)_blorp_close);\n\
    \    while (true) {\n\
    \        continue;\n\
    \        break;\n\
    \    }\n\
    \    blorp_task_cleanup_pop_slot(&resource);\n\
    \    _blorp_close(resource);\n\
     }\n"
    (emit_stmt_to_string e)

let test_emit_resource_cleanup_exit_stmt_break () =
  let resource_var = Var.named "resource" in
  let e =
    mk
      (CResourceCleanupExit
         {
           rce_cleanups = [ resource_cleanup_call resource_var ];
           rce_exit = ResourceBreak;
         })
      ty_void
  in
  Alcotest.(check string)
    "resource cleanup break"
    "blorp_task_cleanup_pop_slot(&resource);\n_blorp_close(resource);\nbreak;\n"
    (emit_stmt_to_string e)

(* ============================================================================
   Call
   ============================================================================ *)

let test_emit_call_no_args () =
  let f_ty = TyFunc { params = []; return = ty_int; is_pure = true } in
  let e = mk (CCall (CKUser ("f", None), cvar "f" f_ty, [])) ty_int in
  Alcotest.(check string) "f()" "f()" (emit_to_string e)

let test_emit_call_with_args () =
  let f_ty =
    TyFunc { params = [ ty_int; ty_int ]; return = ty_int; is_pure = true }
  in
  let e =
    mk
      (CCall (CKUser ("add", None), cvar "add" f_ty, [ cint 1; cint 2 ]))
      ty_int
  in
  Alcotest.(check string) "add(1,2)" "add(1L, 2L)" (emit_to_string e)

let test_emit_union_constructor_sized_int_uses_stack_option () =
  (* Sized-int payloads use the primitive stack Option ABI, not the generic
     heap union constructor. *)
  let ctx = Blorp.Core_emit_context.create () in
  Hashtbl.replace ctx.constructor_names "Some" ();
  let ty_i32 = TyNamed ("Int32", []) in
  let option_i32 = TyNamed ("Option", [ ty_i32 ]) in
  let some_ty =
    TyFunc { params = [ ty_i32 ]; return = option_i32; is_pure = true }
  in
  let payload = mk (CLit (LitInt 1L)) ty_i32 in
  let e =
    mk
      (CCall (CKUser ("Some", None), cvar "Some" some_ty, [ payload ]))
      option_i32
  in
  Blorp.Core_emit.emit_expr ctx e;
  Alcotest.(check string)
    "Some(Int32) uses stack option"
    "((blorp_StackOption_Int32){ .tag = BLORP_TAG_SOME, .value = 1L })"
    (Buffer.contents ctx.output)

let test_emit_union_constructor_int_arg_clears_release_mask () =
  let ctx = Blorp.Core_emit_context.create () in
  Hashtbl.replace ctx.constructor_names "Some" ();
  let option_int = TyNamed ("Option", [ ty_int ]) in
  let some_ty =
    TyFunc { params = [ ty_int ]; return = option_int; is_pure = true }
  in
  let e =
    mk
      (CCall (CKUser ("Some", None), cvar "Some" some_ty, [ cint 1 ]))
      option_int
  in
  Blorp.Core_emit.emit_expr ctx e;
  Alcotest.(check string)
    "Some(Int) stack option"
    "((blorp_StackOption_Int){ .tag = BLORP_TAG_SOME, .value = 1L })"
    (Buffer.contents ctx.output)

let test_emit_union_constructor_int128_arg_sets_release_mask () =
  let ctx = Blorp.Core_emit_context.create () in
  Hashtbl.replace ctx.constructor_names "Some" ();
  let some_ty =
    TyFunc { params = [ ty_int128 ]; return = option_int128; is_pure = true }
  in
  let payload = mk (CLit (LitInt 1L)) ty_int128 in
  let e =
    mk
      (CCall (CKUser ("Some", None), cvar "Some" some_ty, [ payload ]))
      option_int128
  in
  Blorp.Core_emit.emit_expr ctx e;
  Alcotest.(check string)
    "Some(Int128) uses generated stack option"
    "((blorp_StackOption_Int128){ .tag = BLORP_TAG_SOME, .value = 1L })"
    (Buffer.contents ctx.output)

let test_emit_stack_option_int_some_construct () =
  let e =
    mk
      (CUnionConstruct
         {
           uc_type_name = "Option";
           uc_constructor_name = "Some";
           uc_c_name = "Some";
           uc_tag = 0;
           uc_representation =
             OptionUnion
               (Blorp.Core_option_layout.StackScalar
                  Blorp.Core_option_layout.ScalarInt);
           uc_args = [ boxed_int_storage (cint 7) ];
           uc_release_mask = 0;
         })
      option_int
  in
  Alcotest.(check string)
    "Some(Int) stack option"
    "((blorp_StackOption_Int){ .tag = 0, .value = 7L })" (emit_to_string e)

let test_emit_stack_option_int_none_construct () =
  let e =
    mk
      (CUnionConstruct
         {
           uc_type_name = "Option";
           uc_constructor_name = "None";
           uc_c_name = "None";
           uc_tag = 1;
           uc_representation =
             OptionUnion
               (Blorp.Core_option_layout.StackScalar
                  Blorp.Core_option_layout.ScalarInt);
           uc_args = [];
           uc_release_mask = 0;
         })
      option_int
  in
  Alcotest.(check string)
    "None stack option" "((blorp_StackOption_Int){ .tag = 1, .value = 0L })"
    (emit_to_string e)

let stack_option_int_some n =
  mk
    (CUnionConstruct
       {
         uc_type_name = "Option";
         uc_constructor_name = "Some";
         uc_c_name = "Some";
         uc_tag = 0;
         uc_representation =
           OptionUnion
             (Blorp.Core_option_layout.StackScalar
                Blorp.Core_option_layout.ScalarInt);
         uc_args = [ boxed_int_storage (cint n) ];
         uc_release_mask = 0;
       })
    option_int

let stack_option_int_none =
  mk
    (CUnionConstruct
       {
         uc_type_name = "Option";
         uc_constructor_name = "None";
         uc_c_name = "None";
         uc_tag = 1;
         uc_representation =
           OptionUnion
             (Blorp.Core_option_layout.StackScalar
                Blorp.Core_option_layout.ScalarInt);
         uc_args = [];
         uc_release_mask = 0;
       })
    option_int

let stack_option_construct option_ty layout tag args =
  mk
    (CUnionConstruct
       {
         uc_type_name = "Option";
         uc_constructor_name = (if args = [] then "None" else "Some");
         uc_c_name = (if args = [] then "None" else "Some");
         uc_tag = tag;
         uc_representation = OptionUnion layout;
         uc_args = args;
         uc_release_mask = 0;
       })
    option_ty

let test_emit_stack_option_primitive_constructs () =
  let cases =
    [
      ( "Float",
        option_float,
        Blorp.Core_option_layout.StackScalar
          Blorp.Core_option_layout.ScalarFloat,
        boxed_storage (cfloat 1.5) ty_float,
        "((blorp_StackOption_Float){ .tag = 0, .value = 1.5 })" );
      ( "Bool",
        option_bool,
        Blorp.Core_option_layout.StackScalar Blorp.Core_option_layout.ScalarBool,
        boxed_storage (cbool true) ty_bool,
        "((blorp_StackOption_Bool){ .tag = 0, .value = true })" );
      ( "Char",
        option_char,
        Blorp.Core_option_layout.StackScalar Blorp.Core_option_layout.ScalarChar,
        boxed_storage (mk (CLit (LitChar 65)) ty_char) ty_char,
        "((blorp_StackOption_Char){ .tag = 0, .value = 65 })" );
    ]
  in
  List.iter
    (fun (name, option_ty, layout, arg, expected) ->
      Alcotest.(check string)
        (name ^ " Some stack option")
        expected
        (emit_to_string (stack_option_construct option_ty layout 0 [ arg ])))
    cases;
  Alcotest.(check string)
    "Float None stack option"
    "((blorp_StackOption_Float){ .tag = 1, .value = 0 })"
    (emit_to_string
       (stack_option_construct option_float
          (Blorp.Core_option_layout.StackScalar
             Blorp.Core_option_layout.ScalarFloat) 1 []))

let test_emit_generated_stack_option_scalar_constructs () =
  let cases =
    [
      ( "Int128",
        option_int128,
        Blorp.Core_option_layout.StackScalar
          Blorp.Core_option_layout.ScalarInt128,
        boxed_storage (mk (CLit (LitInt 7L)) ty_int128) ty_int128,
        "((blorp_StackOption_Int128){ .tag = 0, .value = 7L })",
        "((blorp_StackOption_Int128){ .tag = 1, .value = 0 })" );
      ( "UInt128",
        option_uint128,
        Blorp.Core_option_layout.StackScalar
          Blorp.Core_option_layout.ScalarUInt128,
        boxed_storage (mk (CLit (LitInt 8L)) ty_uint128) ty_uint128,
        "((blorp_StackOption_UInt128){ .tag = 0, .value = 8L })",
        "((blorp_StackOption_UInt128){ .tag = 1, .value = 0 })" );
      ( "Range",
        TyNamed ("Option", [ TyRange (TyConstInt 10) ]),
        Blorp.Core_option_layout.StackScalar
          Blorp.Core_option_layout.ScalarRange,
        boxed_storage (cint 3) (TyRange (TyConstInt 10)),
        "((blorp_StackOption_Range){ .tag = 0, .value = 3L })",
        "((blorp_StackOption_Range){ .tag = 1, .value = 0 })" );
      ( "Enum",
        TyNamed ("Option", [ TyNamed ("Color", []) ]),
        Blorp.Core_option_layout.StackScalar
          (Blorp.Core_option_layout.ScalarEnum "Color"),
        boxed_storage
          (cvar "Red" (TyNamed ("Color", [])))
          (TyNamed ("Color", [])),
        "((blorp_StackOption_Color){ .tag = 0, .value = Red })",
        "((blorp_StackOption_Color){ .tag = 1, .value = 0 })" );
    ]
  in
  List.iter
    (fun (name, option_ty, layout, arg, expected_some, expected_none) ->
      Alcotest.(check string)
        (name ^ " Some generated stack option")
        expected_some
        (emit_to_string (stack_option_construct option_ty layout 0 [ arg ]));
      Alcotest.(check string)
        (name ^ " None generated stack option")
        expected_none
        (emit_to_string (stack_option_construct option_ty layout 1 [])))
    cases

let test_emit_generated_stack_option_value_record_constructs () =
  let point_ty = TyNamed ("Point", []) in
  let option_point = TyNamed ("Option", [ point_ty ]) in
  let point = mk (CRecord [ ("x", cint 1); ("y", cint 2) ]) point_ty in
  Alcotest.(check string)
    "Some(Point) generated stack option"
    "((blorp_StackOption_Point){ .tag = 0, .value = Point_make(1L, 2L) })"
    (emit_to_string
       (stack_option_construct option_point
          (Blorp.Core_option_layout.StackValueRecord "Point") 0
          [ boxed_storage point point_ty ]));
  Alcotest.(check string)
    "None[Point] zero-initializes value payload"
    "((blorp_StackOption_Point){ .tag = 1, .value = {0} })"
    (emit_to_string
       (stack_option_construct option_point
          (Blorp.Core_option_layout.StackValueRecord "Point") 1 []))

let test_emit_generated_stack_option_value_record_none_cvar () =
  let ctx = Blorp.Core_emit_context.create () in
  Hashtbl.replace ctx.reg.value_records "Point" ();
  Hashtbl.replace ctx.constructor_names "None" ();
  let option_point = TyNamed ("Option", [ TyNamed ("Point", []) ]) in
  let e = mk (CVar (Var.named "None")) option_point in
  Blorp.Core_emit.emit_expr ctx e;
  Alcotest.(check string)
    "typed None[Point] uses generated stack option"
    "((blorp_StackOption_Point){ .tag = BLORP_TAG_NONE, .value = {0} })"
    (Buffer.contents ctx.output)

let test_emit_stack_option_int_boxed_storage () =
  let e =
    mk
      (CBoxTyped
         {
           box_value = stack_option_int_some 7;
           box_source_ty = option_int;
           box_kind = BoxStruct "blorp_StackOption_Int";
         })
      ty_void
  in
  let s = emit_to_string e in
  Alcotest.(check bool)
    "declares stack option temp" true
    (contains_sub s "blorp_StackOption_Int __box_0 =");
  Alcotest.(check bool)
    "boxes stack option struct" true
    (contains_sub s "blorp_box_struct(&__box_0, sizeof(blorp_StackOption_Int))")

let test_emit_stack_option_int_unboxed_storage () =
  let e =
    mk
      (CUnboxTyped
         {
           unbox_value = cvar "raw" ty_void;
           unbox_target_ty = option_int;
           unbox_kind = UnboxStruct "blorp_StackOption_Int";
         })
      option_int
  in
  Alcotest.(check string)
    "unboxes stack option struct"
    "(*(blorp_StackOption_Int*)((char*)raw + sizeof(blorp_Object)))"
    (emit_to_string e)

let test_emit_stack_option_int_builtin_some_call () =
  let e =
    mk (CCall (CKBuiltin "blorp_option_some", cvoid, [ cint 7 ])) option_int
  in
  Alcotest.(check string)
    "builtin Some(Int) uses stack ABI"
    "((blorp_StackOption_Int){ .tag = BLORP_TAG_SOME, .value = 7L })"
    (emit_to_string e)

let test_emit_stack_option_int_user_some_call () =
  let ctx = Blorp.Core_emit_context.create () in
  Hashtbl.replace ctx.constructor_names "Some" ();
  let some_ty =
    TyFunc { params = [ ty_int ]; return = option_int; is_pure = true }
  in
  let e =
    mk
      (CCall
         ( CKUser ("Some", Some 1),
           mk (CVar (Var.named "Some")) some_ty,
           [ cint 7 ] ))
      option_int
  in
  Blorp.Core_emit.emit_expr ctx e;
  Alcotest.(check string)
    "resolved Some(Int) uses stack ABI"
    "((blorp_StackOption_Int){ .tag = BLORP_TAG_SOME, .value = 7L })"
    (Buffer.contents ctx.output)

let test_emit_stack_option_int_user_some_call_without_constructor_context () =
  let some_ty =
    TyFunc { params = [ ty_int ]; return = option_int; is_pure = true }
  in
  let e =
    mk
      (CCall
         ( CKUser ("Some", Some 1),
           mk (CVar (Var.named "Some")) some_ty,
           [ cint 7 ] ))
      option_int
  in
  Alcotest.(check string)
    "ordinary user Some(Int) call is not stolen" "__def_1_Some(7L)"
    (emit_to_string e)

let test_emit_stack_option_int_builtin_none_call () =
  let e = mk (CCall (CKBuiltin "blorp_option_none", cvoid, [])) option_int in
  Alcotest.(check string)
    "builtin None[Int] uses stack ABI"
    "((blorp_StackOption_Int){ .tag = BLORP_TAG_NONE, .value = 0 })"
    (emit_to_string e)

let stack_result_construct ?(layout = Blorp.Core_result_layout.StackErased)
    result_ty ctor tag arg =
  mk
    (CUnionConstruct
       {
         uc_type_name = "Result";
         uc_constructor_name = ctor;
         uc_c_name = ctor;
         uc_tag = tag;
         uc_representation = ResultUnion layout;
         uc_args = [ arg ];
         uc_release_mask = (if arg.bsv_needs_release then 1 else 0);
       })
    result_ty

let test_emit_stack_result_int_bool_constructs () =
  Alcotest.(check string)
    "Ok(Int) stack result"
    "((blorp_StackResult){ .tag = 0, .release_mask = 0UL, .data.Ok.field0 = ({ \
     long __box_0 = 7L; (void*)(long)(__box_0); }) })"
    (emit_to_string
       (stack_result_construct ty_result_int_bool "Ok" 0
          (boxed_int_storage (cint 7))));
  Alcotest.(check string)
    "Err(Bool) stack result"
    "((blorp_StackResult){ .tag = 1, .release_mask = 0UL, .data.Err.field0 = \
     ({ bool __box_0 = true; (void*)(long)(__box_0); }) })"
    (emit_to_string
       (stack_result_construct ty_result_int_bool "Err" 1
          (boxed_storage (cbool true) ty_bool)))

let test_emit_stack_result_managed_construct () =
  Alcotest.(check string)
    "Err(String) managed stack result"
    "((blorp_StackResult){ .tag = 1, .release_mask = 1UL, .data.Err.field0 = \
     ({ blorp_String* __box_0 = msg; (void*)__box_0; }) })"
    (emit_to_string
       (stack_result_construct ~layout:Blorp.Core_result_layout.StackManaged
          ty_result_int_string "Err" 1
          (boxed_pointer_storage (cvar "msg" ty_string) ty_string)))

let test_emit_stack_result_int_builtin_ok_call () =
  let e =
    mk
      (CCall (CKBuiltin "blorp_result_ok", cvoid, [ cint 7 ]))
      ty_result_int_bool
  in
  Alcotest.(check string)
    "builtin Ok(Int) uses stack ABI"
    "((blorp_StackResult){ .tag = BLORP_TAG_OK, .release_mask = 0UL, \
     .data.Ok.field0 = ({ long __box_0 = 7L; (void*)(long)(__box_0); }) })"
    (emit_to_string e)

let test_emit_managed_stack_result_rc_ops () =
  let retain =
    mk
      (CDup (Var.named "r", ty_result_int_string, cvar "r" ty_result_int_string))
      ty_result_int_string
  in
  let drop = mk (CDrop (Var.named "r", ty_result_int_string, cint 0)) ty_int in
  Alcotest.(check string)
    "managed stack Result retain" "({ blorp_stack_result_retain(r); r; })"
    (emit_to_string retain);
  Alcotest.(check string)
    "managed stack Result release"
    "({ blorp_task_cleanup_pop_slot(&r); blorp_stack_result_release(r); 0L; })"
    (emit_to_string drop)

let test_emit_box_managed_stack_result_uses_stack_box_helper () =
  let e =
    mk
      (CBoxTyped
         {
           box_value = cvar "r" ty_result_int_string;
           box_source_ty = ty_result_int_string;
           box_kind = BoxStruct "blorp_StackResult";
         })
      (TyVar "T")
  in
  Alcotest.(check string)
    "box managed stack Result"
    "({ blorp_StackResult __box_0 = r; blorp_box_stack_result(__box_0); })"
    (emit_to_string e)

let test_emit_stack_option_int_mangled_none_cvar () =
  let ctx = Blorp.Core_emit_context.create () in
  Hashtbl.replace ctx.constructor_names "None" ();
  Hashtbl.replace ctx.constructor_c_names_by_type ("Option", "None")
    "__def_1962_None";
  let none_var = Var.named "__def_1962_None" in
  let e = mk (CVar none_var) option_int in
  Blorp.Core_emit.emit_expr ctx e;
  Alcotest.(check string)
    "mangled None[Int] CVar uses stack ABI"
    "((blorp_StackOption_Int){ .tag = BLORP_TAG_NONE, .value = 0 })"
    (Buffer.contents ctx.output)

let test_emit_stack_option_int_mangled_none_let_uses_binding_type () =
  let ctx = Blorp.Core_emit_context.create () in
  Hashtbl.replace ctx.constructor_names "None" ();
  Hashtbl.replace ctx.constructor_c_names_by_type ("Option", "None")
    "__def_1962_None";
  let none_var = Var.named "__def_1962_None" in
  let imprecise_option = TyNamed ("Option", [ TyVar "?" ]) in
  let rhs = mk (CVar none_var) imprecise_option in
  let binding =
    {
      bind_var = Var.named "x";
      bind_mut = false;
      bind_ty = option_int;
      bind_rhs = rhs;
    }
  in
  let body = cvar "x" option_int in
  let e = mk (CLet (binding, body)) option_int in
  Blorp.Core_emit.emit_expr ctx e;
  Alcotest.(check bool)
    "let initializer uses binding type for None[Int]" true
    (contains_sub
       (Buffer.contents ctx.output)
       "blorp_StackOption_Int x = ((blorp_StackOption_Int){ .tag = \
        BLORP_TAG_NONE, .value = 0 })")

let test_emit_stack_option_int_none_let_with_stale_constructor_registry () =
  let ctx = Blorp.Core_emit_context.create () in
  Hashtbl.replace ctx.constructor_names "None" ();
  Hashtbl.replace ctx.constructor_c_names_by_type ("Option", "None")
    "__def_999_None";
  let none_var = { (Var.named "None") with vdef_id = Some 1962 } in
  let imprecise_option = TyNamed ("Option", [ TyVar "?" ]) in
  let rhs = mk (CVar none_var) imprecise_option in
  let binding =
    {
      bind_var = Var.named "x";
      bind_mut = false;
      bind_ty = option_int;
      bind_rhs = rhs;
    }
  in
  let body = cvar "x" option_int in
  let e = mk (CLet (binding, body)) option_int in
  Blorp.Core_emit.emit_expr ctx e;
  Alcotest.(check bool)
    "let initializer uses expected type even with duplicate Option registry"
    true
    (contains_sub
       (Buffer.contents ctx.output)
       "blorp_StackOption_Int x = ((blorp_StackOption_Int){ .tag = \
        BLORP_TAG_NONE, .value = 0 })")

let nullable_option_string_construct ctor_name tag args =
  mk
    (CUnionConstruct
       {
         uc_type_name = "Option";
         uc_constructor_name = ctor_name;
         uc_c_name = ctor_name;
         uc_tag = tag;
         uc_representation =
           OptionUnion Blorp.Core_option_layout.NullableManagedPointer;
         uc_args = args;
         uc_release_mask = (if args = [] then 0 else 1);
       })
    ty_opt_string

let test_emit_nullable_option_string_constructs_as_pointer () =
  Alcotest.(check string)
    "Some(String) is the payload pointer" "s"
    (emit_to_string
       (nullable_option_string_construct "Some" 0
          [ boxed_storage (cvar "s" ty_string) ty_string ]));
  Alcotest.(check string)
    "None[String] is NULL" "NULL"
    (emit_to_string (nullable_option_string_construct "None" 1 []))

let test_emit_nullable_option_string_builtin_calls () =
  Alcotest.(check string)
    "builtin Some(String) is the payload pointer" "s"
    (emit_to_string
       (mk
          (CCall (CKBuiltin "blorp_option_some", cvoid, [ cvar "s" ty_string ]))
          ty_opt_string));
  Alcotest.(check string)
    "builtin None[String] is NULL" "NULL"
    (emit_to_string
       (mk (CCall (CKBuiltin "blorp_option_none", cvoid, [])) ty_opt_string))

let test_emit_nullable_option_string_type_and_match () =
  let tree =
    CTSwitchTag
      {
        cts_scrut = AccRoot;
        cts_cases =
          [
            ( "Some",
              CTLeaf
                {
                  ct_bindings =
                    [ (Var.named "s", AccVariantField (AccRoot, "Some", 0)) ];
                  ct_body = cvar "s" ty_string;
                } );
            ("None", CTLeaf { ct_bindings = []; ct_body = cstr "fallback" });
          ];
        cts_default = None;
      }
  in
  let output =
    emit_to_string (mk (CMatch (cvar "opt" ty_opt_string, tree)) ty_string)
  in
  Alcotest.(check bool)
    "scrutinee uses payload pointer C type" true
    (contains_sub output "blorp_String* __scrut_");
  Alcotest.(check bool)
    "Some tests non-null" true
    (contains_sub output " != NULL");
  Alcotest.(check bool) "None tests null" true (contains_sub output " == NULL");
  Alcotest.(check bool)
    "payload binding is direct pointer" true
    (contains_sub output "blorp_String* s = (blorp_String*)__scrut_")

(* ============================================================================
   Field access
   ============================================================================ *)

let test_emit_field () =
  (* Heap-allocated record: field access uses [->] *)
  let pt_ty = TyNamed ("HeapPoint", []) in
  let e = mk (CField (cvar "p" pt_ty, "x")) ty_int in
  Alcotest.(check string) "heap field" "p->x" (emit_to_string e)

let test_emit_field_value_struct () =
  (* Value struct ([record_is_value = true]): field access uses [.] instead of [->].
     Register "ValPoint" in the context's registry of value-record names. *)
  let ctx = Blorp.Core_emit_context.create () in
  Hashtbl.replace ctx.reg.value_records "ValPoint" ();
  let pt_ty = TyNamed ("ValPoint", []) in
  let e = mk (CField (cvar "p" pt_ty, "x")) ty_int in
  Blorp.Core_emit.emit_expr ctx e;
  let output = Buffer.contents ctx.output in
  Alcotest.(check string) "value struct field" "p.x" output

(* Regression: field access on a record with a C-keyword field name must escape
   the field name at the use site, matching the definition site. Previously,
   accessing [p->long] emitted raw [long] which is a C keyword — parse error. *)
let test_emit_field_access_c_keyword_heap () =
  let ctx = Blorp.Core_emit_context.create () in
  (* Heap record — arrow access. *)
  let rty = TyNamed ("Param", []) in
  let e = mk (CField (cvar "p" rty, "long")) ty_int in
  Blorp.Core_emit.emit_expr ctx e;
  Alcotest.(check string)
    "heap field w/ C keyword" "p->_blorp_long"
    (Buffer.contents ctx.output)

let test_emit_field_access_c_keyword_value () =
  let ctx = Blorp.Core_emit_context.create () in
  Hashtbl.replace ctx.reg.value_records "Flags" ();
  let fty = TyNamed ("Flags", []) in
  let e = mk (CField (cvar "f" fty, "short")) ty_int in
  Blorp.Core_emit.emit_expr ctx e;
  Alcotest.(check string)
    "value field w/ C keyword" "f._blorp_short"
    (Buffer.contents ctx.output)

(* ============================================================================
   Record / Dict construction (Phase 1.2c)
   ============================================================================ *)

let test_emit_record () =
  (* {x = 1, y = 2} of type Point — emits as Point_make(1L, 2L) *)
  let pt_ty = TyNamed ("Point", []) in
  let e = mk (CRecord [ ("x", cint 1); ("y", cint 2) ]) pt_ty in
  Alcotest.(check string) "record make" "Point_make(1L, 2L)" (emit_to_string e)

let test_emit_record_empty () =
  (* An empty record literal on a named type — still calls the
     constructor with zero args. *)
  let unit_ty = TyNamed ("Unit", []) in
  let e = mk (CRecord []) unit_ty in
  Alcotest.(check string) "empty record" "Unit_make()" (emit_to_string e)

let test_emit_generic_record_float_fields_clear_release_mask () =
  (* Generic record fields are stored as void*. Float fields are boxed
     with a bit-preserving cast, so record destruction must not release
     those slots as ARC objects. *)
  let ctx = Blorp.Core_emit_context.create () in
  let rdecl : record_decl =
    {
      record_name = "Pair";
      record_type_params = [ Blorp.Ast.make_type_param "T" [] ];
      record_fields =
        [
          { field_name = "first"; field_type = TyVar "T"; field_loc = loc };
          { field_name = "second"; field_type = TyVar "T"; field_loc = loc };
        ];
      record_is_value = false;
      record_is_builtin = false;
    }
  in
  Hashtbl.replace ctx.record_decls "Pair" rdecl;
  let e =
    mk
      (CRecord [ ("first", cfloat 1.5); ("second", cfloat 2.5) ])
      (TyNamed ("Pair", [ ty_float ]))
  in
  Blorp.Core_emit.emit_expr ctx e;
  Alcotest.(check string)
    "generic record float fields"
    "Pair_make(blorp_box_float(1.5), blorp_box_float(2.5), 0UL)"
    (Buffer.contents ctx.output)

let test_emit_generic_record_int_fields_clear_release_mask () =
  (* Immediate integer payloads use pointer-sized casts and must not be
     released by the generic record destructor. *)
  let ctx = Blorp.Core_emit_context.create () in
  let rdecl : record_decl =
    {
      record_name = "Pair";
      record_type_params = [ Blorp.Ast.make_type_param "T" [] ];
      record_fields =
        [
          { field_name = "first"; field_type = TyVar "T"; field_loc = loc };
          { field_name = "second"; field_type = TyVar "T"; field_loc = loc };
        ];
      record_is_value = false;
      record_is_builtin = false;
    }
  in
  Hashtbl.replace ctx.record_decls "Pair" rdecl;
  let e =
    mk
      (CRecord [ ("first", cint 1); ("second", cint 2) ])
      (TyNamed ("Pair", [ ty_int ]))
  in
  Blorp.Core_emit.emit_expr ctx e;
  Alcotest.(check string)
    "generic record int fields"
    "Pair_make((void*)(long)(1L), (void*)(long)(2L), 0UL)"
    (Buffer.contents ctx.output)

let test_emit_generic_record_int128_fields_set_release_mask () =
  let ctx = Blorp.Core_emit_context.create () in
  let ty_i128 = TyNamed ("Int128", []) in
  let rdecl : record_decl =
    {
      record_name = "Pair";
      record_type_params = [ Blorp.Ast.make_type_param "T" [] ];
      record_fields =
        [
          { field_name = "first"; field_type = TyVar "T"; field_loc = loc };
          { field_name = "second"; field_type = TyVar "T"; field_loc = loc };
        ];
      record_is_value = false;
      record_is_builtin = false;
    }
  in
  Hashtbl.replace ctx.record_decls "Pair" rdecl;
  let e =
    mk
      (CRecord
         [
           ("first", mk (CLit (LitInt 1L)) ty_i128);
           ("second", mk (CLit (LitInt 2L)) ty_i128);
         ])
      (TyNamed ("Pair", [ ty_i128 ]))
  in
  Blorp.Core_emit.emit_expr ctx e;
  Alcotest.(check string)
    "generic record int128 fields"
    "Pair_make(blorp_box_int128(1L), blorp_box_int128(2L), 3UL)"
    (Buffer.contents ctx.output)

let test_emit_dict_generic () =
  (* {1 => 10, 2 => 20} : Dict[Int, Int] — generic dict_new + insert *)
  let dict_ty = TyNamed ("Dict", [ ty_int; ty_int ]) in
  let kvs = [ (cint 1, cint 10); (cint 2, cint 20) ] in
  let e = mk (CDict kvs) dict_ty in
  (* Boxing: primitives cast to [(void* )(long)] *)
  Alcotest.(check string)
    "generic dict"
    "({ blorp_Dict* __dict_0 = blorp_dict_new(); __dict_0 = \
     blorp_dict_insert(__dict_0, (void*)(long)(1L), (void*)(long)(10L)); \
     __dict_0 = blorp_dict_insert(__dict_0, (void*)(long)(2L), \
     (void*)(long)(20L)); __dict_0; })"
    (emit_to_string e)

let test_emit_dict_string_keys () =
  (* {"a" => 1} : Dict[String, Int] — uses blorp_dict_new_string() *)
  let dict_ty = TyNamed ("Dict", [ ty_string; ty_int ]) in
  let k =
    mk (CLit (LitString ("a", { sf_triple = false; sf_raw = false }))) ty_string
  in
  let v = cint 1 in
  let e = mk (CDict [ (k, v) ]) dict_ty in
  let s = emit_to_string e in
  (* Expect it to start with the string-key constructor *)
  Alcotest.(check bool)
    "uses blorp_dict_new_string" true
    (String.length s > 30
    && String.sub s 0 40 = "({ blorp_Dict* __dict_0 = blorp_dict_new")

let test_emit_dict_empty () =
  let dict_ty = TyNamed ("Dict", [ ty_int; ty_int ]) in
  let e = mk (CDict []) dict_ty in
  Alcotest.(check string)
    "empty dict" "({ blorp_Dict* __dict_0 = blorp_dict_new(); __dict_0; })"
    (emit_to_string e)

let test_emit_dict_managed_values_set_release () =
  let list_int_ty = TyNamed ("List", [ ty_int ]) in
  let dict_ty = TyNamed ("Dict", [ ty_string; list_int_ty ]) in
  let e =
    mk
      (CDict
         [
           ( cstr "nums",
             mk (clist_for list_int_ty [ cint 1; cint 2 ]) list_int_ty );
         ])
      dict_ty
  in
  let s = emit_to_string e in
  Alcotest.(check bool)
    "sets dict value release" true
    (contains_sub s
       "blorp_dict_set_value_release(__dict_0, blorp_elem_release_fn)");
  Alcotest.(check bool)
    "sets release before insert" true
    (contains_sub s
       "blorp_dict_new_string(); blorp_dict_set_value_release(__dict_0, \
        blorp_elem_release_fn); __dict_0 = blorp_dict_insert")

let test_emit_dict_new_managed_values_set_release () =
  let dict_ty = TyNamed ("Dict", [ ty_string; TyNamed ("List", [ ty_int ]) ]) in
  let e = mk (CCall (CKBuiltin "blorp_dict_new_string", cvoid, [])) dict_ty in
  let s = emit_to_string e in
  Alcotest.(check bool)
    "wraps dict constructor" true
    (contains_sub s
       "blorp_dict_set_value_release(__dict_0, blorp_elem_release_fn)");
  Alcotest.(check bool) "returns temp" true (contains_sub s "__dict_0; })")

let test_emit_generic_record_empty_dict_field_uses_substituted_type () =
  let ctx = Blorp.Core_emit_context.create () in
  let dict_field_ty =
    TyNamed ("Dict", [ TyVar "K"; TyTuple [ TyVar "V"; ty_int ] ])
  in
  let rdecl : record_decl =
    {
      record_name = "Cache";
      record_type_params =
        [ Blorp.Ast.make_type_param "K" []; Blorp.Ast.make_type_param "V" [] ];
      record_fields =
        [ { field_name = "data"; field_type = dict_field_ty; field_loc = loc } ];
      record_is_value = false;
      record_is_builtin = false;
    }
  in
  Hashtbl.replace ctx.record_decls "Cache" rdecl;
  let e =
    mk
      (CRecord [ ("data", mk (CRecord []) dict_field_ty) ])
      (TyNamed ("Cache", [ ty_string; ty_string ]))
  in
  Blorp.Core_emit.emit_expr ctx e;
  let s = Buffer.contents ctx.output in
  Alcotest.(check bool)
    "uses substituted dict field type" true
    (contains_sub s "blorp_dict_new_string()");
  Alcotest.(check bool)
    "sets value release for tuple values" true
    (contains_sub s
       "blorp_dict_set_value_release(__dict_0, blorp_elem_release_fn)")

let test_emit_dict_custom_managed_keys_set_release () =
  let ctx = Blorp.Core_emit_context.create () in
  let open Blorp.Codegen_types in
  Blorp.Codegen_types.register_managed_type ctx.reg "Widget"
    { managed_kind = ManagedHeapRecord; destructor = ArcReleaseOnly };
  let dict_ty = TyNamed ("Dict", [ TyNamed ("Widget", []); ty_int ]) in
  let e = mk (CCall (CKBuiltin "blorp_dict_new_custom", cvoid, [])) dict_ty in
  Blorp.Core_emit.emit_expr ctx e;
  let s = Buffer.contents ctx.output in
  Alcotest.(check bool)
    "uses custom dict key release" true
    (contains_sub s
       "blorp_dict_new_custom((unsigned long (*)(void*))Hashable_hash_Widget, \
        (bool (*)(void*, void*))Equatable_equals_Widget, \
        blorp_elem_release_fn)")

let test_emit_set_custom_managed_elems_set_release () =
  let ctx = Blorp.Core_emit_context.create () in
  let open Blorp.Codegen_types in
  Blorp.Codegen_types.register_managed_type ctx.reg "Widget"
    { managed_kind = ManagedHeapRecord; destructor = ArcReleaseOnly };
  let set_ty = TyNamed ("Set", [ TyNamed ("Widget", []) ]) in
  let e = mk (CCall (CKBuiltin "blorp_set_new_custom", cvoid, [])) set_ty in
  Blorp.Core_emit.emit_expr ctx e;
  let s = Buffer.contents ctx.output in
  Alcotest.(check bool)
    "uses custom set elem release" true
    (contains_sub s
       "blorp_set_new_custom((unsigned long (*)(void*))Hashable_hash_Widget, \
        (bool (*)(void*, void*))Equatable_equals_Widget, \
        blorp_elem_release_fn)")

(* ============================================================================
   CDup / CDrop emission (Phase 2.8a)
   ============================================================================ *)

let test_emit_dup_expr () =
  (* dup s; 42 — bump s's refcount, then evaluate body *)
  let body = cint 42 in
  let e = mk (CDup (Var.named "s", ty_string, body)) ty_int in
  Alcotest.(check string)
    "dup expr" "({ blorp_retain(s); 42L; })" (emit_to_string e)

let test_emit_drop_expr () =
  (* drop s; 42 — drop-before semantics: release, then body *)
  let body = cint 42 in
  let e = mk (CDrop (Var.named "s", ty_string, body)) ty_int in
  Alcotest.(check string)
    "drop expr"
    "({ blorp_task_cleanup_pop_slot(&s); blorp_release_arc_only(s); 42L; })"
    (emit_to_string e)

let test_emit_drop_with_destructor_expr () =
  let body = cint 42 in
  let e = mk (CDrop (Var.named "xs", ty_list_string, body)) ty_int in
  Alcotest.(check string)
    "drop expr with destructor"
    "({ blorp_task_cleanup_pop_slot(&xs); blorp_release(xs); 42L; })"
    (emit_to_string e)

let test_emit_dup_stmt () =
  let print_ty =
    TyFunc { params = [ ty_string ]; return = ty_void; is_pure = false }
  in
  let call =
    mk
      (CCall
         (CKUser ("print", None), cvar "print" print_ty, [ cvar "s" ty_string ]))
      ty_void
  in
  let e = mk (CDup (Var.named "s", ty_string, call)) ty_void in
  Alcotest.(check string)
    "dup stmt" "blorp_retain(s);\nprint(s);\n" (emit_stmt_to_string e)

let test_emit_drop_stmt () =
  let e = mk (CDrop (Var.named "s", ty_string, cvoid)) ty_void in
  Alcotest.(check string)
    "drop stmt" "blorp_task_cleanup_pop_slot(&s);\nblorp_release_arc_only(s);\n"
    (emit_stmt_to_string e)

let test_emit_nested_dup () =
  (* dup s; dup s; f(s, s, s) — two dups producing 3 refs for 3 uses *)
  let fty =
    TyFunc
      {
        params = [ ty_string; ty_string; ty_string ];
        return = ty_int;
        is_pure = true;
      }
  in
  let call =
    mk
      (CCall
         ( CKUser ("f", None),
           cvar "f" fty,
           [ cvar "s" ty_string; cvar "s" ty_string; cvar "s" ty_string ] ))
      ty_int
  in
  let inner = mk (CDup (Var.named "s", ty_string, call)) ty_int in
  let e = mk (CDup (Var.named "s", ty_string, inner)) ty_int in
  Alcotest.(check string)
    "nested dups" "({ blorp_retain(s); ({ blorp_retain(s); f(s, s, s); }); })"
    (emit_to_string e)

(* ============================================================================
   Void-typed CLet: sequence instead of declare
   ============================================================================ *)

(** Regression: [CLet] with [bind_ty = Void] previously emitted
    [long x = (void)0;] which is illegal C. A void-typed binding must
    sequence the rhs and discard the name. *)
let test_emit_void_let_expr () =
  let side_ty = TyFunc { params = []; return = ty_void; is_pure = false } in
  let rhs =
    mk
      (CCall (CKUser ("side_effect", None), cvar "side_effect" side_ty, []))
      ty_void
  in
  let bind =
    {
      bind_var = Var.named "_";
      bind_mut = false;
      bind_ty = ty_void;
      bind_rhs = rhs;
    }
  in
  let body = cint 42 in
  let e = mk (CLet (bind, body)) ty_int in
  Alcotest.(check string)
    "void let (expr)" "({ side_effect(); 42L; })" (emit_to_string e)

let test_emit_void_let_stmt () =
  let side_ty = TyFunc { params = []; return = ty_void; is_pure = false } in
  let rhs =
    mk (CCall (CKUser ("do_a", None), cvar "do_a" side_ty, [])) ty_void
  in
  let body =
    mk (CCall (CKUser ("do_b", None), cvar "do_b" side_ty, [])) ty_void
  in
  let bind =
    {
      bind_var = Var.named "_";
      bind_mut = false;
      bind_ty = ty_void;
      bind_rhs = rhs;
    }
  in
  let e = mk (CLet (bind, body)) ty_void in
  Alcotest.(check string)
    "void let (stmt)" "do_a();\ndo_b();\n" (emit_stmt_to_string e)

(* ============================================================================
   Allocating constructors
   ============================================================================ *)

let test_emit_tuple_primitives () =
  (* Tuple of ints — primitives boxed via a (void* )(long) cast *)
  let e =
    mk (CTuple [ cint 1; cint 2; cint 3 ]) (TyTuple [ ty_int; ty_int; ty_int ])
  in
  Alcotest.(check string)
    "tuple"
    "blorp_tuple_new(3, (void*)(long)(1L), (void*)(long)(2L), \
     (void*)(long)(3L))"
    (emit_to_string e)

let test_emit_tuple_int128 () =
  (* Int128 needs a dedicated blorp_box_int128 helper — the generic
     (void* )(long) cast silently truncates. The heap box is ARC-managed, so
     tuples must mark the slot releasable. *)
  let ty_i128 = TyNamed ("Int128", []) in
  let x = mk (CLit (LitInt 42L)) ty_i128 in
  let e = mk (CTuple [ x ]) (TyTuple [ ty_i128 ]) in
  Alcotest.(check string)
    "int128 boxed"
    "({ blorp_Tuple* __tup_0 = blorp_tuple_new(1, blorp_box_int128(42L)); \
     blorp_tuple_set_rc(__tup_0, 1UL); __tup_0; })"
    (emit_to_string e)

let test_emit_tuple_tyvar_is_pointer () =
  (* Generic type vars are treated as potentially managed pointers during
     generic code, so tuples must install a release mask until
     monomorphization resolves them to concrete types. The field itself is an
     owned value being moved into the tuple; Perceus inserts CDup before
     emission when a borrowed value must be retained. *)
  let ty_var = TyVar "T" in
  let x = cvar "x" ty_var in
  let e = mk (CTuple [ x ]) (TyTuple [ ty_var ]) in
  Alcotest.(check string)
    "tyvar release-tracked"
    "({ blorp_Tuple* __tup_0 = blorp_tuple_new(1, x); \
     blorp_tuple_set_rc(__tup_0, 1UL); __tup_0; })"
    (emit_to_string e)

let test_emit_tuple_dim_op_raises () =
  (* Dimension values retain their type-level identity for specialization, but
     erase to Int-compatible scalar values when they reach runtime value slots. *)
  let bad_ty = TyDimOp (DimAdd, TyConstInt 1, TyConstInt 2) in
  let x = mk (CLit (LitInt 42L)) bad_ty in
  let e = mk (CTuple [ x ]) (TyTuple [ bad_ty ]) in
  Alcotest.(check string)
    "dim scalar boxed" "blorp_tuple_new(1, (void*)(long)(42L))"
    (emit_to_string e)

let test_emit_tuple_float () =
  let ty_float = TyNamed ("Float", []) in
  let f1 = mk (CLit (LitFloat 1.5)) ty_float in
  let f2 = mk (CLit (LitFloat 2.5)) ty_float in
  let e = mk (CTuple [ f1; f2 ]) (TyTuple [ ty_float; ty_float ]) in
  let s = emit_to_string e in
  (* Should start with blorp_tuple_new(2, blorp_box_float(...) *)
  Alcotest.(check string)
    "tuple of floats"
    "blorp_tuple_new(2, blorp_box_float(1.5), blorp_box_float(2.5))" s

let test_emit_tuple_owned_var_sets_release_mask_without_retain () =
  let name = cvar "name" ty_string in
  let e = mk (CTuple [ cint 1; name ]) (TyTuple [ ty_int; ty_string ]) in
  let s = emit_to_string e in
  Alcotest.(check bool)
    "wraps tuple construction" true
    (contains_sub s "blorp_Tuple* __tup_0 = blorp_tuple_new(2");
  Alcotest.(check bool)
    "does not retain owned var" false
    (contains_sub s "blorp_retain(__tup_0->elem[1])");
  Alcotest.(check bool)
    "sets tuple release mask" true
    (contains_sub s "blorp_tuple_set_rc(__tup_0, 2UL);")

let test_emit_tuple_borrowed_unbox_retains_and_sets_release_mask () =
  let raw = cvar "raw" ty_ptr in
  let name = mk (CUnbox (raw, ty_string)) ty_string in
  let e = mk (CTuple [ cint 1; name ]) (TyTuple [ ty_int; ty_string ]) in
  let s = emit_to_string e in
  Alcotest.(check bool)
    "retains borrowed unboxed managed field" true
    (contains_sub s "if (__tup_0->elem[1]) blorp_retain(__tup_0->elem[1]);");
  Alcotest.(check bool)
    "sets tuple release mask" true
    (contains_sub s "blorp_tuple_set_rc(__tup_0, 2UL);")

let test_emit_list_primitives () =
  let list_ty = TyNamed ("List", [ ty_int ]) in
  let e = mk (clist_for list_ty [ cint 10; cint 20 ]) list_ty in
  (* Fresh ctx → expr_temp_counter starts at 0 → __lst_0 *)
  Alcotest.(check string)
    "list of ints"
    "({ blorp_List* __lst_0 = blorp_list_new_inline(2, 8); __lst_0 = \
     blorp_list_append(__lst_0, (void*)(long)(10L)); __lst_0 = \
     blorp_list_append(__lst_0, (void*)(long)(20L)); __lst_0; })"
    (emit_to_string e)

let test_emit_list_sized_primitives_use_packed_layout () =
  let ty_i32 = TyNamed ("Int32", []) in
  let i32 n = mk (CLit (LitInt (Int64.of_int n))) ty_i32 in
  let list_ty = TyNamed ("List", [ ty_i32 ]) in
  let e = mk (clist_for list_ty [ i32 10; i32 20 ]) list_ty in
  let s = emit_to_string e in
  Alcotest.(check bool)
    "uses 4-byte inline storage" true
    (contains_sub s "blorp_list_new_inline(2, 4)");
  Alcotest.(check bool)
    "does not set release" false
    (contains_sub s "blorp_list_init_elem_release")

let test_emit_list_enum_uses_registry_layout () =
  let ctx = Blorp.Core_emit_context.create () in
  let color_ty = TyNamed ("Color", []) in
  Blorp.Codegen_types.register_enum_type ctx.reg "Color"
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
  let red = mk (CVar (Var.named "Red")) color_ty in
  let blue = mk (CVar (Var.named "Blue")) color_ty in
  let e =
    mk
      (clist ~layout:(list_inline_storage InlineBytes1) [ red; blue ])
      (TyNamed ("List", [ color_ty ]))
  in
  Blorp.Core_emit.emit_expr ctx e;
  let s = Buffer.contents ctx.output in
  Alcotest.(check bool)
    "enum uses byte-sized inline storage" true
    (contains_sub s "blorp_list_new_inline(2, 1)");
  Alcotest.(check bool)
    "enum is not retained" false
    (contains_sub s "blorp_list_init_elem_release")

let test_emit_list_managed_elements_set_release () =
  let list_ty = TyNamed ("List", [ ty_string ]) in
  let e = mk (clist_for list_ty [ cstr "a"; cstr "b" ]) list_ty in
  let s = emit_to_string e in
  Alcotest.(check bool)
    "sets elem release" true
    (contains_sub s
       "blorp_list_init_elem_release(__lst_0, blorp_elem_release_fn)");
  Alcotest.(check bool)
    "appends first element" true
    (contains_sub s "__lst_0 = blorp_list_append(__lst_0, __blorp_get_sl_0()")

let test_emit_list_float_elements_do_not_set_release () =
  let list_ty = TyNamed ("List", [ ty_float ]) in
  let e = mk (clist_for list_ty [ cfloat 1.5; cfloat 2.5 ]) list_ty in
  let s = emit_to_string e in
  Alcotest.(check bool)
    "uses 8-byte inline storage" true
    (contains_sub s "blorp_list_new_inline(2, 8)");
  Alcotest.(check bool)
    "does not set elem release" false
    (contains_sub s
       "blorp_list_init_elem_release(__lst_0, blorp_elem_release_fn)");
  Alcotest.(check bool)
    "boxes first float as immediate" true
    (contains_sub s "__lst_0 = blorp_list_append(__lst_0, blorp_box_float(1.5))")

let test_emit_list_int128_elements_set_release () =
  let ty_i128 = TyNamed ("Int128", []) in
  let list_ty = TyNamed ("List", [ ty_i128 ]) in
  let e =
    mk
      (clist_for list_ty
         [ mk (CLit (LitInt 1L)) ty_i128; mk (CLit (LitInt 2L)) ty_i128 ])
      list_ty
  in
  let s = emit_to_string e in
  Alcotest.(check bool)
    "sets elem release" true
    (contains_sub s
       "blorp_list_init_elem_release(__lst_0, blorp_elem_release_fn)");
  Alcotest.(check bool)
    "transfers fresh boxes" true
    (contains_sub s
       "__lst_0 = blorp_list_append_owned(__lst_0, blorp_box_int128(1L))")

let test_emit_list_option_int_elements_use_inline_stack_storage () =
  let list_ty = TyNamed ("List", [ option_int ]) in
  let e =
    mk
      (clist_for list_ty [ stack_option_int_some 1; stack_option_int_none ])
      list_ty
  in
  let s = emit_to_string e in
  Alcotest.(check bool)
    "allocates inline stack-option slots" true
    (contains_sub s "blorp_list_new_inline(2, sizeof(blorp_StackOption_Int))");
  Alcotest.(check bool)
    "copies first stack option by address" true
    (contains_sub s "blorp_list_set_raw_copy(__lst_0, 0, &__lst_elem_");
  Alcotest.(check bool)
    "does not install ARC element release" false
    (contains_sub s "blorp_list_init_elem_release");
  Alcotest.(check bool)
    "does not box stack options for list storage" false
    (contains_sub s "blorp_box_struct")

let test_emit_list_inline_int_set_uses_direct_inline_storage () =
  let list_ty = TyNamed ("List", [ ty_int ]) in
  let e =
    mk
      (CCall
         (CKIntrinsic "list_set", cvoid, [ cvar "xs" list_ty; cint 1; cint 42 ]))
      ty_void
  in
  let s = emit_to_string e in
  Alcotest.(check bool)
    "primitive list set writes inline bits directly" true
    (contains_sub s "memcpy((char*)__list_store_");
  Alcotest.(check bool)
    "primitive set skips runtime helper" false
    (contains_sub s "blorp_list_set_raw((blorp_List*)")

let test_emit_list_managed_string_set_uses_pointer_path () =
  let e =
    mk
      (CCall
         ( CKIntrinsic "list_set",
           cvoid,
           [ cvar "xs" ty_list_string; cint 1; cstr "x" ] ))
      ty_void
  in
  let s = emit_to_string e in
  Alcotest.(check bool)
    "managed pointer lists do not use inline store temp" false
    (contains_sub s "__list_store_");
  Alcotest.(check bool)
    "managed pointer lists call raw store helper" true
    (contains_sub s "blorp_list_set_raw((blorp_List*)xs")

let test_emit_list_boxed_value_retain_for_is_noop () =
  let list_ty = TyNamed ("List", [ ty_int128 ]) in
  let e =
    mk
      (CCall
         ( CKIntrinsic "list_retain_for",
           cvoid,
           [ cvar "xs" list_ty; mk (CLit (LitInt 1L)) ty_int128 ] ))
      ty_void
  in
  let s = emit_to_string e in
  Alcotest.(check bool)
    "boxed value source retain is no-op" false
    (contains_sub s "blorp_list_retain_for");
  Alcotest.(check bool)
    "boxed value source is not boxed just to retain" false
    (contains_sub s "blorp_box_int128")

let test_emit_list_inline_struct_set_unknown_storage_branches_safely () =
  let list_ty = TyNamed ("List", [ option_int ]) in
  let e =
    mk
      (CCall
         ( CKIntrinsic "list_set",
           cvoid,
           [ cvar "xs" list_ty; cint 1; stack_option_int_some 42 ] ))
      ty_void
  in
  let s = emit_to_string e in
  Alcotest.(check bool)
    "stack-option list stores through typed temporary" true
    (contains_sub s "blorp_StackOption_Int __list_elem_");
  Alcotest.(check bool)
    "stack-option unknown storage checks actual runtime layout" true
    (contains_sub s "storage_mode == BLORP_LIST_STORAGE_INLINE");
  Alcotest.(check bool)
    "stack-option inline branch copies typed bytes" true
    (contains_sub s "blorp_list_set_raw_copy(__list_store_");
  Alcotest.(check bool)
    "fallback boxes the already evaluated typed temporary" true
    (contains_sub s "blorp_box_struct(&__list_elem_");
  Alcotest.(check bool)
    "fallback closes the runtime store call around the boxed temporary" true
    (contains_sub s "sizeof(blorp_StackOption_Int)));");
  Alcotest.(check bool)
    "fallback does not re-evaluate through a generic box temp" false
    (contains_sub s "blorp_box_struct(&__box_");
  Alcotest.(check bool)
    "stack-option list does not use primitive bit temporary" false
    (contains_sub s "__list_store_bits_")

let test_emit_list_inline_struct_get_unknown_storage_reads_inline_slot_directly
    () =
  let ctx = Blorp.Core_emit_context.create () in
  Hashtbl.replace ctx.reg.value_records "Small" ();
  let small_ty = TyNamed ("Small", []) in
  let list_ty = TyNamed ("List", [ small_ty ]) in
  let layout = list_inline_struct_storage ~elem_ty:small_ty "Small" in
  let get =
    mk
      (CListGet
         {
           lg_layout = layout;
           lg_list = cvar "xs" list_ty;
           lg_index = cint 1;
           lg_bounds = ListBoundsChecked;
         })
      ty_ptr
  in
  let e =
    mk
      (CUnboxTyped
         {
           unbox_value = get;
           unbox_target_ty = small_ty;
           unbox_kind = UnboxStruct "Small";
         })
      small_ty
  in
  let s = emit_to_string_with_ctx ctx e in
  Alcotest.(check bool)
    "inline branch reads from list data, not blorp_list_get bits" true
    (contains_sub s "memcpy(&__lg_out_");
  Alcotest.(check bool)
    "inline branch computes the slot address from list data" true
    (contains_sub s "(char*)__lg_list_");
  let memcpys_from_raw =
    contains_sub s "memcpy(&__lg_out_" && contains_sub s ", __lg_raw_"
  in
  Alcotest.(check bool)
    "does not memcpy from raw value returned by blorp_list_get" false
    memcpys_from_raw

let test_emit_list_ensure_intrinsics_use_common_fast_paths () =
  let list_ty = TyNamed ("List", [ ty_int ]) in
  let unique =
    mk
      (CCall (CKIntrinsic "list_ensure_unique", cvoid, [ cvar "xs" list_ty ]))
      list_ty
  in
  let capacity =
    mk
      (CCall
         ( CKIntrinsic "list_ensure_capacity",
           cvoid,
           [ cvar "xs" list_ty; cint 8 ] ))
      list_ty
  in
  let unique_c = emit_to_string unique in
  let capacity_c = emit_to_string capacity in
  Alcotest.(check bool)
    "unique check avoids runtime helper on common path" true
    (contains_sub unique_c "blorp_is_unique(__list_unique_");
  Alcotest.(check bool)
    "unique check keeps COW fallback" true
    (contains_sub unique_c "blorp_list_cow(__list_unique_");
  Alcotest.(check bool)
    "capacity check avoids runtime helper on common path" true
    (contains_sub capacity_c "->capacity >= __list_cap_min_");
  Alcotest.(check bool)
    "capacity check keeps growth fallback" true
    (contains_sub capacity_c "blorp_list_ensure_capacity(__list_cap_")

let test_emit_list_new_managed_elements_set_release () =
  let e =
    mk
      (CCall (CKBuiltin "blorp_list_new", cvoid, [ cint 4 ]))
      (TyNamed ("List", [ ty_string ]))
  in
  let s = emit_to_string e in
  Alcotest.(check bool)
    "wraps list_new" true
    (contains_sub s
       "blorp_list_init_elem_release(__lst_0, blorp_elem_release_fn)");
  Alcotest.(check bool) "returns temp" true (contains_sub s "__lst_0; })")

let test_emit_list_reuse_alloc_managed_elements_set_release () =
  let e =
    mk
      (CCall
         ( CKIntrinsic "list_reuse_alloc",
           cvoid,
           [ cvar "xs" ty_list_string; cint 4 ] ))
      ty_list_string
  in
  let s = emit_to_string e in
  Alcotest.(check bool)
    "calls reuse boundary" true
    (contains_sub s "blorp_list_reuse_alloc(xs, 4L)");
  Alcotest.(check bool)
    "sets elem release" true
    (contains_sub s
       "blorp_list_init_elem_release(__lst_0, blorp_elem_release_fn)");
  Alcotest.(check bool) "returns temp" true (contains_sub s "__lst_0; })")

let test_emit_set_reuse_alloc () =
  let e =
    mk
      (CCall
         ( CKIntrinsic "set_reuse_alloc",
           cvoid,
           [ cvar "xs" ty_set_string; cint 0 ] ))
      ty_set_string
  in
  let s = emit_to_string e in
  Alcotest.(check bool)
    "calls set reuse boundary" true
    (contains_sub s "blorp_set_reuse_alloc((blorp_Set*)xs, 0L)")

let test_emit_dict_reuse_alloc () =
  let e =
    mk
      (CCall
         ( CKIntrinsic "dict_reuse_alloc",
           cvoid,
           [ cvar "d" ty_dict_string_string; cint 0 ] ))
      ty_dict_string_string
  in
  let s = emit_to_string e in
  Alcotest.(check bool)
    "calls dict reuse boundary" true
    (contains_sub s "blorp_dict_reuse_alloc((blorp_Dict*)d, 0L)")

let test_emit_list_handoff_managed_reuse_releases_old_slots () =
  let result = cvar "__lh_result" ty_list_string in
  let out = cvar "__lh_out" ty_int in
  let store =
    mk
      (CCall
         ( CKIntrinsic "list_handoff_set_owned",
           cvoid,
           [ result; out; cstr "fresh" ] ))
      ty_void
  in
  let e =
    mk
      (CListHandoff
         {
           lh_mode = ConsumeReuse;
           lh_layout = Blorp.Core_list_layout.layout_of_type ty_list_string loc;
           lh_source = cvar "xs" ty_list_string;
           lh_source_var = Var.named "__lh_src";
           lh_source_ty = ty_list_string;
           lh_result_ty = ty_list_string;
           lh_capacity = cint 4;
           lh_result_var = Var.named "__lh_result";
           lh_len_var = Var.named "__lh_len";
           lh_out_var = Var.named "__lh_out";
           lh_body = store;
           lh_write_order = ForwardCompacting;
         })
      ty_list_string
  in
  let s = emit_to_string e in
  Alcotest.(check bool)
    "handoff begins through runtime helper" true
    (contains_sub s "blorp_list_handoff_begin_reuse(");
  Alcotest.(check bool)
    "handoff passes layout and reuse flag explicitly" true
    (contains_sub s
       "__lh_release_0, BLORP_LIST_STORAGE_POINTER, sizeof(void*), \
        &__lh_reuse_0)");
  Alcotest.(check bool)
    "handoff finishes through runtime helper" true
    (contains_sub s
       "blorp_list_handoff_finish((blorp_List*)__lh_result, __lh_out, \
        __lh_len, __lh_reuse_0, (blorp_List*)__lh_src)");
  Alcotest.(check bool)
    "reuse guard is runtime-owned" false
    (contains_sub s "blorp_is_unique");
  Alcotest.(check bool)
    "old overwritten slot is released by store" true
    (contains_sub s
       "blorp_list_handoff_set_owned((blorp_List*)__lh_result, __lh_out, \
        (void*)");
  Alcotest.(check bool)
    "tail slots are released after body" true
    (contains_sub s
       "blorp_list_handoff_finish((blorp_List*)__lh_result, __lh_out, \
        __lh_len, __lh_reuse_0, (blorp_List*)__lh_src)");
  Alcotest.(check bool)
    "managed handoff is no longer blocked by release fn" false
    (contains_sub s "== NULL && blorp_is_unique")

let test_emit_string_literal () =
  let e =
    mk
      (CLit (LitString ("hello", { sf_triple = false; sf_raw = false })))
      ty_string
  in
  (* gen_literal dedupes via a lazy helper for __sl_0 in a fresh ctx *)
  Alcotest.(check string) "string lit" "__blorp_get_sl_0()" (emit_to_string e)

let test_escape_unicode_before_hex_digit () =
  Alcotest.(check string)
    "unicode before hex-like ascii" "\\303\\251fac"
    (Blorp.Core_emit_context.c_escape_string "éfac")

(* ============================================================================
   Deferred variants raise clearly
   ============================================================================ *)

let test_emit_vector () =
  let ty_float = TyNamed ("Float", []) in
  let f n = mk (CLit (LitFloat n)) ty_float in
  let e =
    mk
      (CVector [ f 1.0; f 2.0; f 3.0 ])
      (TyNamed ("Tensor", [ ty_float; TyConstInt 3 ]))
  in
  let s = emit_to_string e in
  Alcotest.(check bool)
    "has vector_new_f64" true
    (contains_sub s "blorp_vector_new_f64(3)");
  Alcotest.(check bool)
    "float stored raw" true
    (contains_sub s "((double*)__vec_0->data)[0] = 1");
  Alcotest.(check bool)
    "has data[2]" true
    (contains_sub s "((double*)__vec_0->data)[2]")

let test_emit_vector_int () =
  let e =
    mk
      (CVector [ cint 1; cint 2 ])
      (TyNamed ("Tensor", [ ty_int; TyConstInt 2 ]))
  in
  let s = emit_to_string e in
  Alcotest.(check bool)
    "has vector_new_i64" true
    (contains_sub s "blorp_vector_new_i64(2)");
  Alcotest.(check bool)
    "int stored raw" true
    (contains_sub s "((long*)__vec_0->data)[0] = 1L")

let test_emit_vector_alias_uses_expanded_element_layout () =
  let ctx = Blorp.Core_emit_context.create () in
  Hashtbl.replace ctx.reg.type_aliases "Meters" ([], TyNamed ("Float", []));
  Hashtbl.replace ctx.reg.type_aliases "Positions"
    ([], TyNamed ("Vector", [ TyNamed ("Meters", []); TyConstInt 2 ]));
  let f n = mk (CLit (LitFloat n)) ty_float in
  let e = mk (CVector [ f 1.0; f 2.0 ]) (TyNamed ("Positions", [])) in
  let s = emit_to_string_with_ctx ctx e in
  Alcotest.(check bool)
    "alias uses f64 constructor" true
    (contains_sub s "blorp_vector_new_f64(2)");
  Alcotest.(check bool)
    "alias stores f64 raw values" true
    (contains_sub s "((double*)__vec_0->data)[0] = 1")

let test_emit_nullable_vector_set_cow_releases_value_record_box () =
  let ctx = Blorp.Core_emit_context.create () in
  Hashtbl.replace ctx.reg.value_records "SmallNode" ();
  let node_ty = TyNamed ("SmallNode", []) in
  let vector_ty = TyNamed ("Tensor", [ node_ty; TyConstInt 4 ]) in
  let option_vector_ty = TyNamed ("Option", [ vector_ty ]) in
  let e =
    mk
      (CCall
         ( CKBuiltin "blorp_vector_set_cow_nullable",
           cvoid,
           [ cvar "nodes" vector_ty; cint 0; cvar "updated" node_ty ] ))
      option_vector_ty
  in
  let s = emit_to_string_with_ctx ctx e in
  Alcotest.(check bool)
    "boxes value-record setter argument" true
    (contains_sub s "blorp_box_struct(&__box_");
  Alcotest.(check bool)
    "calls nullable COW setter" true
    (contains_sub s "blorp_vector_set_cow_nullable(nodes, 0L, __set_value_");
  Alcotest.(check bool)
    "releases temporary box after setter copies/retains it" true
    (contains_sub s "if (__set_value_")

let test_emit_matrix_set_opt_releases_value_record_box () =
  let ctx = Blorp.Core_emit_context.create () in
  Hashtbl.replace ctx.reg.value_records "SmallNode" ();
  let node_ty = TyNamed ("SmallNode", []) in
  let matrix_ty = TyNamed ("Tensor", [ node_ty; TyConstInt 2; TyConstInt 2 ]) in
  let option_matrix_ty = TyNamed ("Option", [ matrix_ty ]) in
  let e =
    mk
      (CCall
         ( CKBuiltin "blorp_matrix_set_opt",
           cvoid,
           [ cvar "nodes" matrix_ty; cint 0; cint 1; cvar "updated" node_ty ] ))
      option_matrix_ty
  in
  let s = emit_to_string_with_ctx ctx e in
  Alcotest.(check bool)
    "boxes value-record setter argument" true
    (contains_sub s "blorp_box_struct(&__box_");
  Alcotest.(check bool)
    "calls Option-returning matrix setter" true
    (contains_sub s "blorp_matrix_set_opt(nodes, 0L, 1L, __set_value_");
  Alcotest.(check bool)
    "releases temporary box after setter copies/retains it" true
    (contains_sub s "if (__set_value_")

(* ============================================================================
   CLambda / closure emission
   ============================================================================ *)

let test_emit_lambda_no_captures () =
  let lam : lambda =
    {
      lam_params = [ (Var.named "y", ty_int) ];
      lam_body = mk (CBin (Add, cvar "y" ty_int, cint 1)) ty_int;
      lam_return_ty = ty_int;
      lam_is_pure = true;
    }
  in
  let e =
    mk (CLambda lam)
      (TyFunc { params = [ ty_int ]; return = ty_int; is_pure = true })
  in
  match emit_to_string e with
  | exception Blorp.Core_error.Core_error err ->
      Alcotest.(check bool)
        "phase is Emit" true
        (err.Blorp.Core_error.phase = Blorp.Core_error.Emit);
      Alcotest.(check bool)
        "mentions CLambda" true
        (contains_sub err.Blorp.Core_error.msg "CLambda")
  | _ -> Alcotest.fail "expected raw CLambda emit invariant failure"

let test_emit_lambda_with_capture () =
  let lam : lambda =
    {
      lam_params = [ (Var.named "y", ty_int) ];
      lam_body = mk (CBin (Add, cvar "x" ty_int, cvar "y" ty_int)) ty_int;
      lam_return_ty = ty_int;
      lam_is_pure = true;
    }
  in
  let e =
    mk (CLambda lam)
      (TyFunc { params = [ ty_int ]; return = ty_int; is_pure = true })
  in
  match emit_to_string e with
  | exception Blorp.Core_error.Core_error err ->
      Alcotest.(check bool)
        "phase is Emit" true
        (err.Blorp.Core_error.phase = Blorp.Core_error.Emit);
      Alcotest.(check bool)
        "mentions CLambda" true
        (contains_sub err.Blorp.Core_error.msg "CLambda")
  | _ -> Alcotest.fail "expected raw CLambda emit invariant failure"

(* ============================================================================
   Match emission: void-return helper
   ============================================================================ *)

(* Phase 2.5 / 2.6.2: raw CMatchArms is an emit invariant violation.
   The legacy raw-match emission tests have been removed. Decision-tree
   emission is covered by the "match_tree" suite below. *)

let test_emit_match_tree_void_expr () =
  let union_ty = TyNamed ("Color", []) in
  let print_ty =
    TyFunc { params = [ ty_int ]; return = ty_void; is_pure = false }
  in
  let tree =
    CTSwitchTag
      {
        cts_scrut = AccRoot;
        cts_cases =
          [
            ( "Red",
              CTLeaf
                {
                  ct_bindings = [];
                  ct_body =
                    mk
                      (CCall
                         ( CKUser ("handle", None),
                           cvar "handle" print_ty,
                           [ cint 1 ] ))
                      ty_void;
                } );
          ];
        cts_default =
          Some (CTLeaf { ct_bindings = []; ct_body = mk CVoid ty_void });
      }
  in
  let e = mk (CMatch (cvar "c" union_ty, tree)) ty_void in
  let s = emit_to_string e in
  Alcotest.(check bool) "no void __mr" false (contains_sub s "void __mr");
  Alcotest.(check bool) "has (void)0" true (contains_sub s "(void)0")

(* ============================================================================
   Statement-context emission
   ============================================================================ *)

let test_stmt_void () =
  Alcotest.(check string) "void stmt" "" (emit_stmt_to_string cvoid)

let test_stmt_call () =
  (* print("hi"); *)
  let print_ty =
    TyFunc { params = [ ty_string ]; return = ty_void; is_pure = false }
  in
  let call =
    mk
      (CCall
         ( CKUser ("print", None),
           cvar "print" print_ty,
           [ mk (CLit (LitInt 42L)) ty_int ] ))
      ty_void
  in
  Alcotest.(check string) "call stmt" "print(42L);\n" (emit_stmt_to_string call)

let test_stmt_let () =
  (* var x: Int = 10; x + 1 *)
  let bind =
    {
      bind_var = Var.named "x";
      bind_mut = true;
      bind_ty = ty_int;
      bind_rhs = cint 10;
    }
  in
  let body = mk (CBin (Add, cvar "x" ty_int, cint 1)) ty_int in
  let e = mk (CLet (bind, body)) ty_int in
  (* emit_stmt for CLet produces a real declaration, not a stmt-expr *)
  Alcotest.(check string)
    "let stmt" "long x = 10L;\n(x + 1L);\n" (emit_stmt_to_string e)

let test_stmt_seq () =
  let print_ty =
    TyFunc { params = [ ty_int ]; return = ty_void; is_pure = false }
  in
  let call1 =
    mk
      (CCall (CKUser ("print", None), cvar "print" print_ty, [ cint 1 ]))
      ty_void
  in
  let call2 =
    mk
      (CCall (CKUser ("print", None), cvar "print" print_ty, [ cint 2 ]))
      ty_void
  in
  let e = mk (CSeq (call1, call2)) ty_void in
  Alcotest.(check string)
    "seq" "print(1L);\nprint(2L);\n" (emit_stmt_to_string e)

let test_stmt_if () =
  (* if x > 0: print(1) *)
  let print_ty =
    TyFunc { params = [ ty_int ]; return = ty_void; is_pure = false }
  in
  let cond = mk (CBin (Gt, cvar "x" ty_int, cint 0)) ty_bool in
  let then_e =
    mk
      (CCall (CKUser ("print", None), cvar "print" print_ty, [ cint 1 ]))
      ty_void
  in
  let e = mk (CIf (cond, then_e, cvoid)) ty_void in
  (* else branch is CVoid — should be omitted *)
  Alcotest.(check string)
    "if without else" "if ((x > 0L)) {\n    print(1L);\n}\n"
    (emit_stmt_to_string e)

let test_stmt_if_else () =
  let print_ty =
    TyFunc { params = [ ty_int ]; return = ty_void; is_pure = false }
  in
  let cond = mk (CBin (Lt, cvar "x" ty_int, cint 0)) ty_bool in
  let then_e =
    mk
      (CCall (CKUser ("print", None), cvar "print" print_ty, [ cint (-1) ]))
      ty_void
  in
  let else_e =
    mk
      (CCall (CKUser ("print", None), cvar "print" print_ty, [ cint 1 ]))
      ty_void
  in
  let e = mk (CIf (cond, then_e, else_e)) ty_void in
  Alcotest.(check string)
    "if/else" "if ((x < 0L)) {\n    print(-1L);\n} else {\n    print(1L);\n}\n"
    (emit_stmt_to_string e)

let test_stmt_while () =
  (* while i < 10: i = i + 1 *)
  let cond = mk (CBin (Lt, cvar "i" ty_int, cint 10)) ty_bool in
  let inc = mk (CBin (Add, cvar "i" ty_int, cint 1)) ty_int in
  let body = mk (CAssign (Var.named "i", inc)) ty_void in
  let e = mk (CWhile (cond, body)) ty_void in
  Alcotest.(check string)
    "while" "while ((i < 10L)) {\n    i = (i + 1L);\n}\n"
    (emit_stmt_to_string e)

let test_stmt_break_continue () =
  Alcotest.(check string)
    "break" "break;\n"
    (emit_stmt_to_string (mk CBreak ty_void));
  Alcotest.(check string)
    "continue" "continue;\n"
    (emit_stmt_to_string (mk CContinue ty_void))

let test_stmt_assign () =
  let e = mk (CAssign (Var.named "i", cint 5)) ty_void in
  Alcotest.(check string) "assign" "i = 5L;\n" (emit_stmt_to_string e)

let test_stmt_discard_managed_var_releases () =
  let e = mk (CAssign (Var.named "_", cvar "s" ty_string)) ty_void in
  Alcotest.(check string)
    "discard managed var" "blorp_release_arc_only(s);\n" (emit_stmt_to_string e)

let test_stmt_for_range () =
  (* for i in 0..10: print(i) *)
  let print_ty =
    TyFunc { params = [ ty_int ]; return = ty_void; is_pure = false }
  in
  let range = mk (CRange (cint 0, cint 10)) ty_int in
  let body =
    mk
      (CCall (CKUser ("print", None), cvar "print" print_ty, [ cvar "i" ty_int ]))
      ty_void
  in
  let e = mk (CFor (loop_binder_named "i" ty_int, range, body)) ty_void in
  Alcotest.(check string)
    "for range"
    "long __range_start_0 = 0L;\n\
     long __range_end_0 = 10L;\n\
     for (long i = __range_start_0; i < __range_end_0; i++) {\n\
    \    print(i);\n\
     }\n"
    (emit_stmt_to_string e)

let test_stmt_for_list () =
  let print_ty =
    TyFunc { params = [ ty_int ]; return = ty_void; is_pure = false }
  in
  let list_ty = TyNamed ("List", [ ty_int ]) in
  let iter = cvar "items" list_ty in
  let body =
    mk
      (CCall (CKUser ("print", None), cvar "print" print_ty, [ cvar "x" ty_int ]))
      ty_void
  in
  let e = mk (CFor (loop_binder_named "x" ty_int, iter, body)) ty_void in
  let s = emit_stmt_to_string e in
  Alcotest.(check bool) "has list iter" true (contains_sub s "__iter_0");
  Alcotest.(check bool) "has len" true (contains_sub s "->len;");
  Alcotest.(check bool)
    "primitive list iteration loads inline element bits" true
    (contains_sub s "memcpy(&__iter_bits_");
  Alcotest.(check bool) "has var bind" true (contains_sub s "long x =")

let test_stmt_for_string () =
  let print_ty =
    TyFunc
      { params = [ TyNamed ("Char", []) ]; return = ty_void; is_pure = false }
  in
  let iter = cvar "text" ty_string in
  let body =
    mk
      (CCall
         ( CKUser ("print", None),
           cvar "print" print_ty,
           [ cvar "c" (TyNamed ("Char", [])) ] ))
      ty_void
  in
  let e =
    mk (CFor (loop_binder_named "c" (TyNamed ("Char", [])), iter, body)) ty_void
  in
  let s = emit_stmt_to_string e in
  Alcotest.(check bool) "has str iter" true (contains_sub s "__str_iter_0");
  Alcotest.(check bool)
    "has next_codepoint" true
    (contains_sub s "blorp_string_next_codepoint");
  Alcotest.(check bool) "has int32_t" true (contains_sub s "int32_t c =")

let test_stmt_for_dict_tuple_binder () =
  let dict_ty = TyNamed ("Dict", [ ty_int; ty_string ]) in
  let pair_ty = TyTuple [ ty_int; ty_string ] in
  let iter = cvar "items" dict_ty in
  let e = mk (CFor (loop_binder_named "pair" pair_ty, iter, cvoid)) ty_void in
  let s = emit_stmt_to_string e in
  Alcotest.(check bool)
    "creates tuple binder" true
    (contains_sub s "blorp_tuple_new(2");
  Alcotest.(check bool) "uses dict keys" true (contains_sub s "->keys[");
  Alcotest.(check bool) "uses dict values" true (contains_sub s "->values[");
  Alcotest.(check bool)
    "releases tuple binder" true
    (contains_sub s "blorp_release(pair);")

let test_stmt_for_channel () =
  let print_ty =
    TyFunc { params = [ ty_int ]; return = ty_void; is_pure = false }
  in
  let iter = cvar "ch" ty_channel_int in
  let body =
    mk
      (CCall (CKUser ("print", None), cvar "print" print_ty, [ cvar "v" ty_int ]))
      ty_void
  in
  let e = mk (CFor (loop_binder_named "v" ty_int, iter, body)) ty_void in
  let s = emit_stmt_to_string e in
  Alcotest.(check bool)
    "uses channel recv raw" true
    (contains_sub s "blorp_channel_recv_raw");
  Alcotest.(check bool) "has raw slot" true (contains_sub s "void* __chan_val_");
  Alcotest.(check bool) "does not read list len" false (contains_sub s "->len;");
  Alcotest.(check bool)
    "does not read list data" false (contains_sub s "->data[")

let test_stmt_nested_if_in_while () =
  (* while True: if i < 5: break else: continue *)
  let cond_outer = cbool true in
  let cond_inner = mk (CBin (Lt, cvar "i" ty_int, cint 5)) ty_bool in
  let inner_if =
    mk (CIf (cond_inner, mk CBreak ty_void, mk CContinue ty_void)) ty_void
  in
  let e = mk (CWhile (cond_outer, inner_if)) ty_void in
  Alcotest.(check string)
    "nested"
    "while (true) {\n\
    \    if ((i < 5L)) {\n\
    \        break;\n\
    \    } else {\n\
    \        continue;\n\
    \    }\n\
     }\n"
    (emit_stmt_to_string e)

let test_stmt_let_with_seq_body () =
  (* Block: let x = 10 in print(x); x + 1 *)
  let print_ty =
    TyFunc { params = [ ty_int ]; return = ty_void; is_pure = false }
  in
  let bind =
    {
      bind_var = Var.named "x";
      bind_mut = false;
      bind_ty = ty_int;
      bind_rhs = cint 10;
    }
  in
  let call =
    mk
      (CCall (CKUser ("print", None), cvar "print" print_ty, [ cvar "x" ty_int ]))
      ty_void
  in
  let result = mk (CBin (Add, cvar "x" ty_int, cint 1)) ty_int in
  let body = mk (CSeq (call, result)) ty_int in
  let e = mk (CLet (bind, body)) ty_int in
  Alcotest.(check string)
    "let + seq" "long x = 10L;\nprint(x);\n(x + 1L);\n" (emit_stmt_to_string e)

(* ============================================================================
   Small integration: lower + emit
   ============================================================================ *)

let test_integration_arith () =
  (* Build a typed AST for (x + 1) where x is Int, lower to Core,
     then emit. Result should match what we'd expect. *)
  let mk_ast desc ty =
    ast_with_type
      {
        expr_desc = desc;
        expr_loc = loc;
        expr_type = None;
        expr_type_info = None;
        expr_rc = None;
      }
      ty
  in
  let lhs = mk_ast (EIdent "x") ty_int in
  let rhs = mk_ast (ELiteral (LitInt 1L)) ty_int in
  let ast = mk_ast (EBinary (Add, lhs, rhs)) ty_int in
  let core = lower_expr ast in
  Alcotest.(check string) "lowered (x+1)" "(x + 1L)" (emit_to_string core)

(** End-to-end: hand-build a Core [let s = "hi" in f(s, s)], run
    Perceus on it, and verify the emitted C contains the expected
    retain call (matching the "every use consumes" model). *)
let test_integration_perceus_emit () =
  let fty =
    TyFunc
      { params = [ ty_string; ty_string ]; return = ty_int; is_pure = true }
  in
  let bind : binding =
    {
      bind_var = Var.named "s";
      bind_mut = false;
      bind_ty = ty_string;
      bind_rhs =
        mk
          (CLit (LitString ("hi", { sf_triple = false; sf_raw = false })))
          ty_string;
    }
  in
  let body =
    mk
      (CCall
         ( CKUser ("f", None),
           cvar "f" fty,
           [ cvar "s" ty_string; cvar "s" ty_string ] ))
      ty_int
  in
  let e = mk (CLet (bind, body)) ty_int in
  (* Run perceus — this should insert exactly one dup for the two uses *)
  let transformed =
    Blorp.Core_perceus.insert_drops_expr_with_env
      (Blorp.Core_perceus.empty_env ())
      e
  in
  let emitted = emit_to_string transformed in
  (* Two uses → 1 dup → blorp_retain(s) appears once in the output *)
  let count_occurrences s sub =
    let sub_len = String.length sub in
    let s_len = String.length s in
    let rec go i acc =
      if i + sub_len > s_len then acc
      else if String.sub s i sub_len = sub then go (i + 1) (acc + 1)
      else go (i + 1) acc
    in
    go 0 0
  in
  Alcotest.(check int)
    "one blorp_retain(s)" 1
    (count_occurrences emitted "blorp_retain(s)")

let test_emit_primitive_rc_ops_are_noops () =
  let retain_expr = mk (CDup (Var.named "i", ty_int, cvar "i" ty_int)) ty_int in
  let drop_expr = mk (CDrop (Var.named "i", ty_int, cvar "i" ty_int)) ty_int in
  Alcotest.(check string)
    "primitive dup expression" "i"
    (emit_to_string retain_expr);
  Alcotest.(check string)
    "primitive drop expression" "i" (emit_to_string drop_expr)

(* ============================================================================
   Decl-level emission (Phase 1.2c)
   ============================================================================ *)

(** Helper: emit a whole program to a string via Core_emit_context.

    A4.2: we run [Core_resolve.resolve_program] first so [CVar]
    references pick up [vdef_id] from [env.user_funcs]. Without this
    step, inter-function calls in hand-built test programs emit bare
    names at the call site while the decl side emits the mangled
    [__def_<id>_<name>] form — a guaranteed link error in [e2e_program]
    tests that cc + run the result. *)
let emit_program_to_string ?(profile = false) (prog : core_program) : string =
  let resolved = Blorp.Core_resolve.resolve_program prog in
  let converted = Blorp.Core_closure.convert_program resolved in
  let ctx = Blorp.Core_emit_context.create ~profile () in
  Blorp.Core_emit.emit_program ctx converted;
  Buffer.contents ctx.output

(* ============================================================================
   Global var and impl emission
   ============================================================================ *)

let test_emit_global_var_const () =
  let v : core_var =
    {
      cv_name = Var.named "MAX";
      cv_module = None;
      cv_ty = ty_int;
      cv_init = cint 100;
      cv_is_mutable = false;
      cv_is_const = true;
      cv_def_id = 0;
    }
  in
  let prog = [ { cd_desc = CDVar v; cd_loc = loc; cd_doc = None } ] in
  let output = emit_program_to_string prog in
  (* Globals keep bare (flatten-prefixed) names in A4.2 — see
     [emit_global_var] comment. A5 will switch both sides together. *)
  Alcotest.(check bool)
    "has static decl" true
    (contains_sub output "static long MAX = 100L;")

let test_emit_global_var_non_const () =
  let fty = TyFunc { params = []; return = ty_int; is_pure = true } in
  let v : core_var =
    {
      cv_name = Var.named "computed";
      cv_module = None;
      cv_ty = ty_int;
      cv_init = mk (CCall (CKUser ("init", None), cvar "init" fty, [])) ty_int;
      cv_is_mutable = false;
      cv_is_const = false;
      cv_def_id = 0;
    }
  in
  let prog = [ { cd_desc = CDVar v; cd_loc = loc; cd_doc = None } ] in
  let output = emit_program_to_string prog in
  Alcotest.(check bool)
    "has static no init" true
    (contains_sub output "static long computed;");
  Alcotest.(check bool)
    "has init func" true
    (contains_sub output "__blorp_init_globals");
  (* A4.2: [emit_program_to_string] now runs [Core_resolve.resolve_program]
     before emit, which classifies the [init]-callee as a closure (since
     [init] isn't declared anywhere in this minimal test). The assignment
     target is what matters for this test — the RHS is closure dispatch
     code. *)
  Alcotest.(check bool)
    "has deferred init assignment" true
    (contains_sub output "computed = ")

let test_emit_global_var_string_literal_deferred () =
  let v : core_var =
    {
      cv_name = Var.named "GREETING";
      cv_module = None;
      cv_ty = ty_string;
      cv_init = cstr "hello";
      cv_is_mutable = false;
      cv_is_const = true;
      cv_def_id = 0;
    }
  in
  let prog = [ { cd_desc = CDVar v; cd_loc = loc; cd_doc = None } ] in
  let output = emit_program_to_string prog in
  Alcotest.(check bool)
    "has static string decl" true
    (contains_sub output "static blorp_String* GREETING;");
  Alcotest.(check bool)
    "has deferred string assignment" true
    (contains_sub output "GREETING = ");
  Alcotest.(check bool)
    "assignment constructs string literal" true
    (contains_sub output "blorp_string_literal_len(\"hello\", 5L)")

let test_escape_nul_string_literal_keeps_explicit_length () =
  let v =
    {
      cv_name = Var.named "NUL_TEXT";
      cv_module = None;
      cv_ty = ty_string;
      cv_init =
        mk
          (CLit (LitString ("a\000b", { sf_triple = false; sf_raw = false })))
          ty_string;
      cv_is_mutable = false;
      cv_is_const = true;
      cv_def_id = 0;
    }
  in
  let prog = [ { cd_desc = CDVar v; cd_loc = loc; cd_doc = None } ] in
  let output = emit_program_to_string prog in
  Alcotest.(check bool)
    "literal includes explicit byte length" true
    (contains_sub output "blorp_string_literal_len(\"a\\000b\", 3L)")

let test_emit_impl_methods () =
  let body =
    mk
      (CBin
         ( Add,
           mk (CField (cvar "self" (TyNamed ("Point", [])), "x")) ty_int,
           mk (CField (cvar "other" (TyNamed ("Point", [])), "x")) ty_int ))
      ty_int
  in
  let method_func : core_func =
    {
      cf_name = "add";
      cf_type_params = [];
      cf_module = None;
      cf_params =
        [
          {
            cp_name = Var.named "self";
            cp_ty = TyNamed ("Point", []);
            cp_loc = loc;
          };
          {
            cp_name = Var.named "other";
            cp_ty = TyNamed ("Point", []);
            cp_loc = loc;
          };
        ];
      cf_return_ty = ty_int;
      cf_body = Some body;
      cf_is_pure = true;
      cf_kind = CFUser;
      cf_def_id = 0;
    }
  in
  let impl : core_impl =
    {
      ci_trait = "Addable";
      ci_for_type = TyNamed ("Point", []);
      ci_methods = [ method_func ];
    }
  in
  let prog = [ { cd_desc = CDImpl impl; cd_loc = loc; cd_doc = None } ] in
  let output = emit_program_to_string prog in
  Alcotest.(check bool)
    "has mangled name" true
    (contains_sub output "Addable_add_Point(")

let test_emit_lambda_body_emitted () =
  let lam : lambda =
    {
      lam_params = [ (Var.named "y", ty_int) ];
      lam_body = mk (CBin (Add, cvar "y" ty_int, cint 1)) ty_int;
      lam_return_ty = ty_int;
      lam_is_pure = true;
    }
  in
  let func_body =
    mk (CLambda lam)
      (TyFunc { params = [ ty_int ]; return = ty_int; is_pure = true })
  in
  let func : core_func =
    {
      cf_name = "make_fn";
      cf_type_params = [];
      cf_params = [];
      cf_module = None;
      cf_return_ty =
        TyFunc { params = [ ty_int ]; return = ty_int; is_pure = true };
      cf_body = Some func_body;
      cf_is_pure = true;
      cf_kind = CFUser;
      cf_def_id = 0;
    }
  in
  let prog = [ { cd_desc = CDFunc func; cd_loc = loc; cd_doc = None } ] in
  let output = emit_program_to_string prog in
  Alcotest.(check bool)
    "has lambda body" true
    (contains_sub output "_blorp_clambda_0(void* __env");
  Alcotest.(check bool)
    "has param unbox" true
    (contains_sub output "long y = (long)(long)__arg0;");
  Alcotest.(check bool)
    "has return box" true
    (contains_sub output "(void*)(long)(")

let test_emit_lambda_capture_body () =
  let lam : lambda =
    {
      lam_params = [ (Var.named "y", ty_int) ];
      lam_body = mk (CBin (Add, cvar "x" ty_int, cvar "y" ty_int)) ty_int;
      lam_return_ty = ty_int;
      lam_is_pure = true;
    }
  in
  let bind =
    {
      bind_var = Var.named "result";
      bind_mut = false;
      bind_ty = TyFunc { params = [ ty_int ]; return = ty_int; is_pure = true };
      bind_rhs =
        mk (CLambda lam)
          (TyFunc { params = [ ty_int ]; return = ty_int; is_pure = true });
    }
  in
  let body =
    mk
      (CLet
         ( bind,
           cvar "result"
             (TyFunc { params = [ ty_int ]; return = ty_int; is_pure = true })
         ))
      (TyFunc { params = [ ty_int ]; return = ty_int; is_pure = true })
  in
  let func : core_func =
    {
      cf_name = "make_adder";
      cf_type_params = [];
      cf_module = None;
      cf_params = [ { cp_name = Var.named "x"; cp_ty = ty_int; cp_loc = loc } ];
      cf_return_ty =
        TyFunc { params = [ ty_int ]; return = ty_int; is_pure = true };
      cf_body = Some body;
      cf_is_pure = true;
      cf_kind = CFUser;
      cf_def_id = 0;
    }
  in
  let prog = [ { cd_desc = CDFunc func; cd_loc = loc; cd_doc = None } ] in
  let output = emit_program_to_string prog in
  Alcotest.(check bool)
    "has env unbox" true
    (contains_sub output "void** __e = (void**)__env;");
  Alcotest.(check bool)
    "has capture read" true
    (contains_sub output "long x = (long)(long)__e[0];")

let test_emit_lambda_rc_capture_release_mask () =
  let lam : lambda =
    {
      lam_params = [];
      lam_body = cvar "s" ty_string;
      lam_return_ty = ty_string;
      lam_is_pure = true;
    }
  in
  let body =
    mk (CLambda lam)
      (TyFunc { params = []; return = ty_string; is_pure = true })
  in
  let func : core_func =
    {
      cf_name = "capture_string";
      cf_type_params = [];
      cf_module = None;
      cf_params =
        [ { cp_name = Var.named "s"; cp_ty = ty_string; cp_loc = loc } ];
      cf_return_ty = TyFunc { params = []; return = ty_string; is_pure = true };
      cf_body = Some body;
      cf_is_pure = true;
      cf_kind = CFUser;
      cf_def_id = 0;
    }
  in
  let output =
    emit_program_to_string
      [ { cd_desc = CDFunc func; cd_loc = loc; cd_doc = None } ]
  in
  Alcotest.(check bool)
    "retains captured string" true
    (contains_sub output "(void*)blorp_retain((blorp_Object*)s)");
  Alcotest.(check bool)
    "marks captured string releasable" true
    (contains_sub output "->env_release_mask = 1UL;");
  Alcotest.(check bool)
    "retains returned captured string" true
    (contains_sub output "return (void*)blorp_retain((blorp_Object*)s);")

let test_emit_lambda_ptr_capture_not_retained () =
  let lam : lambda =
    {
      lam_params = [];
      lam_body = cvar "p" ty_ptr;
      lam_return_ty = ty_ptr;
      lam_is_pure = true;
    }
  in
  let body =
    mk (CLambda lam) (TyFunc { params = []; return = ty_ptr; is_pure = true })
  in
  let func : core_func =
    {
      cf_name = "capture_ptr";
      cf_type_params = [];
      cf_module = None;
      cf_params = [ { cp_name = Var.named "p"; cp_ty = ty_ptr; cp_loc = loc } ];
      cf_return_ty = TyFunc { params = []; return = ty_ptr; is_pure = true };
      cf_body = Some body;
      cf_is_pure = true;
      cf_kind = CFUser;
      cf_def_id = 0;
    }
  in
  let output =
    emit_program_to_string
      [ { cd_desc = CDFunc func; cd_loc = loc; cd_doc = None } ]
  in
  Alcotest.(check bool)
    "does not retain captured ptr" false
    (contains_sub output "blorp_retain((blorp_Object*)p)");
  Alcotest.(check bool)
    "does not mark captured ptr releasable" true
    (contains_sub output "->env_release_mask = 0UL;")

(* ============================================================================
   Concurrency emission
   ============================================================================ *)

let test_emit_concurrent_block () =
  let fty = TyFunc { params = []; return = ty_int; is_pure = true } in
  let bind_a =
    {
      cb_var = Var.named "a";
      cb_ty = ty_int;
      cb_rhs =
        mk (CCall (CKUser ("compute_a", None), cvar "compute_a" fty, [])) ty_int;
      cb_task_scope = synthetic_concurrent_task_scope;
      cb_task = None;
    }
  in
  let bind_b =
    {
      cb_var = Var.named "b";
      cb_ty = ty_int;
      cb_rhs =
        mk (CCall (CKUser ("compute_b", None), cvar "compute_b" fty, [])) ty_int;
      cb_task_scope = synthetic_concurrent_task_scope;
      cb_task = None;
    }
  in
  let tail = mk (CBin (Add, cvar "a" ty_int, cvar "b" ty_int)) ty_int in
  let e =
    mk
      (CConcurrent
         {
           conc_bindings = [ bind_a; bind_b ];
           conc_body = tail;
           conc_timeout = None;
           conc_max_threads = None;
         })
      ty_int
  in
  let func : core_func =
    {
      cf_name = "run_two";
      cf_type_params = [];
      cf_params = [];
      cf_module = None;
      cf_return_ty = ty_int;
      cf_body = Some e;
      cf_is_pure = false;
      cf_kind = CFUser;
      cf_def_id = 0;
    }
  in
  let output =
    emit_program_to_string
      [ { cd_desc = CDFunc func; cd_loc = loc; cd_doc = None } ]
  in
  Alcotest.(check bool)
    "has batch init" true
    (contains_sub output "blorp_task_batch_init(&__conc_batch_");
  Alcotest.(check bool)
    "has owned batched task_spawn" true
    (contains_sub output "blorp_task_spawn_owned_in_batch(&__conc_batch_");
  Alcotest.(check bool)
    "flushes batch before join" true
    (contains_sub output "blorp_task_batch_flush(&__conc_batch_");
  Alcotest.(check bool)
    "has concurrent_join" true
    (contains_sub output "blorp_concurrent_join");
  Alcotest.(check bool)
    "has task release" true
    (contains_sub output "blorp_release((blorp_Object*)");
  Alcotest.(check bool)
    "has two tasks" true
    (contains_sub output "__conc_task_")

let test_emit_concurrent_program () =
  let fty = TyFunc { params = []; return = ty_int; is_pure = true } in
  let bind_a =
    {
      cb_var = Var.named "a";
      cb_ty = ty_int;
      cb_rhs =
        mk (CCall (CKUser ("compute", None), cvar "compute" fty, [])) ty_int;
      cb_task_scope = synthetic_concurrent_task_scope;
      cb_task = None;
    }
  in
  let body =
    mk
      (CConcurrent
         {
           conc_bindings = [ bind_a ];
           conc_body = cvar "a" ty_int;
           conc_timeout = None;
           conc_max_threads = None;
         })
      ty_int
  in
  let func : core_func =
    {
      cf_name = "run";
      cf_type_params = [];
      cf_params = [];
      cf_module = None;
      cf_return_ty = ty_int;
      cf_body = Some body;
      cf_is_pure = false;
      cf_kind = CFUser;
      cf_def_id = 0;
    }
  in
  let prog = [ { cd_desc = CDFunc func; cd_loc = loc; cd_doc = None } ] in
  let output = emit_program_to_string prog in
  Alcotest.(check bool)
    "has lambda body" true
    (contains_sub output "_blorp_task_0(void* __env)");
  Alcotest.(check bool)
    "has spawn" true
    (contains_sub output "blorp_task_spawn")

let test_emit_concurrent_capture_release_mask () =
  let result_ty =
    TyNamed ("Result", [ ty_string; TyNamed ("ConcurrencyError", []) ])
  in
  let bind_a =
    {
      cb_var = Var.named "a";
      cb_ty = result_ty;
      cb_rhs = cvar "s" ty_string;
      cb_task_scope = synthetic_concurrent_task_scope;
      cb_task = None;
    }
  in
  let e =
    mk
      (CConcurrent
         {
           conc_bindings = [ bind_a ];
           conc_body = cvoid;
           conc_timeout = None;
           conc_max_threads = None;
         })
      ty_void
  in
  let func : core_func =
    {
      cf_name = "capture_task";
      cf_type_params = [];
      cf_params = [];
      cf_module = None;
      cf_return_ty = ty_void;
      cf_body = Some e;
      cf_is_pure = false;
      cf_kind = CFUser;
      cf_def_id = 0;
    }
  in
  let output =
    emit_program_to_string
      [ { cd_desc = CDFunc func; cd_loc = loc; cd_doc = None } ]
  in
  Alcotest.(check bool)
    "retains captured task value" true
    (contains_sub output "(void*)blorp_retain((blorp_Object*)s)");
  Alcotest.(check bool)
    "releases captured task value with closure" true
    (contains_sub output "->env_release_mask = 1UL;");
  Alcotest.(check bool)
    "transfers emitter's closure ref to task spawn" true
    (contains_sub output "blorp_task_spawn_owned");
  Alcotest.(check bool)
    "does not release transferred task closure in caller" false
    (contains_sub output "blorp_release((blorp_Object*)__conc_fn_")

let test_emit_concurrent_stack_result_join_conversion () =
  let bind =
    {
      cb_var = Var.named "r";
      cb_ty = ty_result_int_bool;
      cb_rhs = cint 7;
      cb_task_scope = synthetic_concurrent_task_scope;
      cb_task = None;
    }
  in
  let e =
    mk
      (CConcurrent
         {
           conc_bindings = [ bind ];
           conc_body = cvoid;
           conc_timeout = None;
           conc_max_threads = None;
         })
      ty_void
  in
  let func : core_func =
    {
      cf_name = "stack_result_join";
      cf_type_params = [];
      cf_params = [];
      cf_module = None;
      cf_return_ty = ty_void;
      cf_body = Some e;
      cf_is_pure = false;
      cf_kind = CFUser;
      cf_def_id = 0;
    }
  in
  let output =
    emit_program_to_string
      [ { cd_desc = CDFunc func; cd_loc = loc; cd_doc = None } ]
  in
  Alcotest.(check bool)
    "converts boxed join Result to stack Result" true
    (contains_sub output
       "blorp_StackResult r = \
        blorp_stack_result_from_boxed((blorp_Result*)blorp_concurrent_join(");
  Alcotest.(check bool)
    "does not cast boxed join Result to stack Result" false
    (contains_sub output
       "blorp_StackResult r = (blorp_StackResult)blorp_concurrent_join(")

let test_emit_concurrent_for_rc_result_uses_spawn_rc () =
  let list_string_ty = TyNamed ("List", [ ty_string ]) in
  let result_string_ty =
    TyNamed ("Result", [ ty_string; TyNamed ("ConcurrencyError", []) ])
  in
  let e =
    mk
      (CConcurrentFor
         {
           cf_var = Var.named "item";
           cf_iter = cvar "items" list_string_ty;
           cf_body = cvar "item" ty_string;
           cf_timeout = None;
           cf_width = ConcurrentForDefault;
           cf_task_scope = synthetic_concurrent_task_scope;
           cf_task = None;
         })
      (TyNamed ("List", [ result_string_ty ]))
  in
  let func : core_func =
    {
      cf_name = "run_each";
      cf_type_params = [];
      cf_params = [];
      cf_module = None;
      cf_return_ty = TyNamed ("List", [ result_string_ty ]);
      cf_body = Some e;
      cf_is_pure = false;
      cf_kind = CFUser;
      cf_def_id = 0;
    }
  in
  let output =
    emit_program_to_string
      [ { cd_desc = CDFunc func; cd_loc = loc; cd_doc = None } ]
  in
  Alcotest.(check bool)
    "rc task result uses owned spawn_rc" true
    (contains_sub output "blorp_task_spawn_owned_rc_in_batch");
  Alcotest.(check bool)
    "concurrent for uses batch init" true
    (contains_sub output "blorp_task_batch_init(&__conc_batch_");
  Alcotest.(check bool)
    "concurrent for flushes spawn batches" true
    (contains_sub output "% BLORP_TASK_BATCH_FLUSH_INTERVAL) == 0");
  Alcotest.(check bool)
    "concurrent for schedules batch before joins" true
    (contains_sub output "blorp_task_batch_flush(&__conc_batch_")

let test_emit_detach () =
  let fty = TyFunc { params = []; return = ty_void; is_pure = false } in
  let inner =
    mk (CCall (CKUser ("cleanup", None), cvar "cleanup" fty, [])) ty_void
  in
  let e = mk (CDetach { detach_body = inner; detach_task = None }) ty_void in
  let func : core_func =
    {
      cf_name = "fire_once";
      cf_type_params = [];
      cf_params = [];
      cf_module = None;
      cf_return_ty = ty_void;
      cf_body = Some e;
      cf_is_pure = false;
      cf_kind = CFUser;
      cf_def_id = 0;
    }
  in
  let output =
    emit_program_to_string
      [ { cd_desc = CDFunc func; cd_loc = loc; cd_doc = None } ]
  in
  Alcotest.(check bool)
    "has blorp_detach" true
    (contains_sub output "blorp_detach")

let test_emit_detach_void_task_abi () =
  let fty = TyFunc { params = []; return = ty_void; is_pure = false } in
  let body =
    mk
      (CDetach
         {
           detach_body =
             mk
               (CCall (CKUser ("cleanup", None), cvar "cleanup" fty, []))
               ty_void;
           detach_task = None;
         })
      ty_void
  in
  let func : core_func =
    {
      cf_name = "fire";
      cf_type_params = [];
      cf_params = [];
      cf_module = None;
      cf_return_ty = ty_void;
      cf_body = Some body;
      cf_is_pure = false;
      cf_kind = CFUser;
      cf_def_id = 0;
    }
  in
  let output =
    emit_program_to_string
      [ { cd_desc = CDFunc func; cd_loc = loc; cd_doc = None } ]
  in
  Alcotest.(check bool)
    "task lambda returns void pointer" true
    (contains_sub output "_blorp_task_0(void* __env)");
  Alcotest.(check bool)
    "void task returns null result" true
    (contains_sub output "return (void*)0;")

let test_emit_detach_rc_capture_uses_void_result_task_abi () =
  let body =
    mk
      (CDetach { detach_body = cvar "s" ty_string; detach_task = None })
      ty_void
  in
  let func : core_func =
    {
      cf_name = "fire_string";
      cf_type_params = [];
      cf_module = None;
      cf_params =
        [ { cp_name = Var.named "s"; cp_ty = ty_string; cp_loc = loc } ];
      cf_return_ty = ty_void;
      cf_body = Some body;
      cf_is_pure = false;
      cf_kind = CFUser;
      cf_def_id = 0;
    }
  in
  let output =
    emit_program_to_string
      [ { cd_desc = CDFunc func; cd_loc = loc; cd_doc = None } ]
  in
  Alcotest.(check bool)
    "detach ignores body result ownership" true
    (contains_sub output "blorp_detach(__conc_fn_");
  Alcotest.(check bool)
    "task lambda returns null result" true
    (contains_sub output "return (void*)0;");
  Alcotest.(check bool)
    "captured rc result has release mask" true
    (contains_sub output "->env_release_mask = 1UL;")

(* ============================================================================
   Core_pipeline integration test
   ============================================================================ *)

let test_core_pipeline_simple () =
  let mk_ast desc ty =
    ast_with_type
      {
        expr_desc = desc;
        expr_loc = loc;
        expr_type = None;
        expr_type_info = None;
        expr_rc = None;
      }
      ty
  in
  let body =
    mk_ast
      (EBinary
         ( Add,
           mk_ast (ELiteral (LitInt 40L)) ty_int,
           mk_ast (ELiteral (LitInt 2L)) ty_int ))
      ty_int
  in
  let func : func_decl =
    {
      func_name = Some "compute";
      func_params = [];
      func_return_type = Some ty_int;
      func_body = FuncBodyExpr body;
      func_type_params = [];
      func_is_pure = true;
      func_is_tailrec = false;
      func_no_copy = false;
      func_debug_only = false;
      func_resource_result_ordinary = false;
      func_dim_constraints = [];
    }
  in
  let program : program =
    [ { decl_desc = DFunc func; decl_loc = loc; decl_doc = None } ]
  in
  let c_code = compile_program program in
  (* A4.2: the pipeline mints a fresh [cf_def_id]; we can't predict
     the exact id number, so just check the mangled suffix. *)
  Alcotest.(check bool)
    "has function" true
    (contains_sub c_code "_compute(void)");
  Alcotest.(check bool)
    "has return" true
    (contains_sub c_code "return (40L + 2L);");
  Alcotest.(check bool)
    "has preamble" true
    (contains_sub c_code "#include <stdbool.h>")

let test_core_pipeline_profile_flag () =
  let mk_ast desc ty =
    ast_with_type
      {
        expr_desc = desc;
        expr_loc = loc;
        expr_type = None;
        expr_type_info = None;
        expr_rc = None;
      }
      ty
  in
  let body = mk_ast (ELiteral (LitInt 42L)) ty_int in
  let func : func_decl =
    {
      func_name = Some "compute";
      func_params = [];
      func_return_type = Some ty_int;
      func_body = FuncBodyExpr body;
      func_type_params = [];
      func_is_pure = true;
      func_is_tailrec = false;
      func_no_copy = false;
      func_debug_only = false;
      func_resource_result_ordinary = false;
      func_dim_constraints = [];
    }
  in
  let program : program =
    [ { decl_desc = DFunc func; decl_loc = loc; decl_doc = None } ]
  in
  let c_code = compile_program ~profile:true program in
  Alcotest.(check bool)
    "pipeline forwards profile flag" true
    (contains_sub c_code "blorp_profile_start(\"compute\");");
  Alcotest.(check bool)
    "pipeline emits profile end" true
    (contains_sub c_code "blorp_profile_end(\"compute\");")

let test_emit_simple_function () =
  (* func inc(x: Int) -> Int: x + 1 *)
  let body = mk (CBin (Add, cvar "x" ty_int, cint 1)) ty_int in
  let func : core_func =
    {
      cf_name = "inc";
      cf_module = None;
      cf_type_params = [];
      cf_params = [ { cp_name = Var.named "x"; cp_ty = ty_int; cp_loc = loc } ];
      cf_return_ty = ty_int;
      cf_body = Some body;
      cf_is_pure = true;
      cf_kind = CFUser;
      cf_def_id = 0;
    }
  in
  let prog = [ { cd_desc = CDFunc func; cd_loc = loc; cd_doc = None } ] in
  let output = emit_program_to_string prog in
  (* Check the output contains the expected signature and return *)
  let contains sub =
    let n = String.length sub in
    let m = String.length output in
    let rec go i = i + n <= m && (String.sub output i n = sub || go (i + 1)) in
    go 0
  in
  (* A4.2: cf_def_id = 0 in test, so the mangled name is __def_0_inc. *)
  Alcotest.(check bool)
    "has signature" true
    (contains "long __def_0_inc(long x)");
  Alcotest.(check bool) "has return" true (contains "return (x + 1L);")

let test_emit_profile_named_function () =
  let body = mk (CBin (Add, cvar "x" ty_int, cint 1)) ty_int in
  let func : core_func =
    {
      cf_name = "inc";
      cf_module = None;
      cf_type_params = [];
      cf_params = [ { cp_name = Var.named "x"; cp_ty = ty_int; cp_loc = loc } ];
      cf_return_ty = ty_int;
      cf_body = Some body;
      cf_is_pure = true;
      cf_kind = CFUser;
      cf_def_id = 0;
    }
  in
  let prog = [ { cd_desc = CDFunc func; cd_loc = loc; cd_doc = None } ] in
  let output = emit_program_to_string ~profile:true prog in
  Alcotest.(check bool)
    "starts timer" true
    (contains_sub output "blorp_profile_start(\"inc\");");
  Alcotest.(check bool)
    "stores result before ending timer" true
    (contains_sub output "long __blorp_profile_result = (x + 1L);");
  Alcotest.(check bool)
    "ends timer" true
    (contains_sub output "blorp_profile_end(\"inc\");");
  Alcotest.(check bool)
    "returns stored result" true
    (contains_sub output "return __blorp_profile_result;")

let test_emit_profile_main_enables_report () =
  let func : core_func =
    {
      cf_name = "main";
      cf_module = None;
      cf_type_params = [];
      cf_params =
        [ { cp_name = Var.named "args"; cp_ty = ty_list_string; cp_loc = loc } ];
      cf_return_ty = ty_int;
      cf_body = Some (cint 0);
      cf_is_pure = false;
      cf_kind = CFUser;
      cf_def_id = 0;
    }
  in
  let prog = [ { cd_desc = CDFunc func; cd_loc = loc; cd_doc = None } ] in
  let output = emit_program_to_string ~profile:true prog in
  Alcotest.(check bool)
    "enables profiler" true
    (contains_sub output "blorp_profile_enable();");
  Alcotest.(check bool)
    "registers report" true
    (contains_sub output "atexit(blorp_profile_report);");
  Alcotest.(check bool)
    "profiles main" true
    (contains_sub output "blorp_profile_start(\"main\");");
  Alcotest.(check bool)
    "ends main" true
    (contains_sub output "blorp_profile_end(\"main\");")

let test_emit_profile_lambda_body () =
  let lam : lambda =
    {
      lam_params = [ (Var.named "y", ty_int) ];
      lam_body = mk (CBin (Add, cvar "y" ty_int, cint 1)) ty_int;
      lam_return_ty = ty_int;
      lam_is_pure = true;
    }
  in
  let func_body =
    mk (CLambda lam)
      (TyFunc { params = [ ty_int ]; return = ty_int; is_pure = true })
  in
  let func : core_func =
    {
      cf_name = "make_fn";
      cf_type_params = [];
      cf_params = [];
      cf_module = None;
      cf_return_ty =
        TyFunc { params = [ ty_int ]; return = ty_int; is_pure = true };
      cf_body = Some func_body;
      cf_is_pure = true;
      cf_kind = CFUser;
      cf_def_id = 0;
    }
  in
  let prog = [ { cd_desc = CDFunc func; cd_loc = loc; cd_doc = None } ] in
  let output = emit_program_to_string ~profile:true prog in
  Alcotest.(check bool)
    "starts lambda timer" true
    (contains_sub output "blorp_profile_start(\"_blorp_clambda_0\");");
  Alcotest.(check bool)
    "stores boxed lambda result before ending timer" true
    (contains_sub output "void* __blorp_profile_result = ");
  Alcotest.(check bool)
    "ends lambda timer" true
    (contains_sub output "blorp_profile_end(\"_blorp_clambda_0\");");
  Alcotest.(check bool)
    "returns stored boxed result" true
    (contains_sub output "return __blorp_profile_result;")

(* Regression: a user function whose name collides with a POSIX stdlib
   function (like [truncate]) must be mangled so the emitted symbol doesn't
   clash with the system declaration. Before the fix, the emitted C contained
   both `int truncate(const char *, off_t);` (from unistd.h, transitively
   included by the runtime) and `blorp_String* truncate(blorp_String*, long)`
   (the user function), producing a conflicting-types C parse error. *)
let test_emit_function_name_posix_collision () =
  let body = cint 0 in
  let func : core_func =
    {
      cf_name = "truncate";
      cf_module = None;
      cf_type_params = [];
      cf_params = [];
      cf_return_ty = ty_int;
      cf_body = Some body;
      cf_is_pure = true;
      cf_kind = CFUser;
      cf_def_id = 0;
    }
  in
  let prog = [ { cd_desc = CDFunc func; cd_loc = loc; cd_doc = None } ] in
  let output = emit_program_to_string prog in
  let has sub = contains_sub output sub in
  (* A4.2: the DefId-mangled name [__def_0_truncate] doesn't collide
     with the POSIX [truncate] symbol, so the old [_blorp_] C-keyword
     shield is no longer needed to avoid the conflict. Either form
     is correct as long as the emitted symbol isn't the bare
     [truncate(void)]. *)
  Alcotest.(check bool) "no raw truncate def" false (has "long truncate(void)");
  Alcotest.(check bool) "mangled def" true (has "long __def_0_truncate(void)")

let test_emit_function_no_params () =
  let body = cint 42 in
  let func : core_func =
    {
      cf_name = "answer";
      cf_module = None;
      cf_type_params = [];
      cf_params = [];
      cf_return_ty = ty_int;
      cf_body = Some body;
      cf_is_pure = true;
      cf_kind = CFUser;
      cf_def_id = 0;
    }
  in
  let prog = [ { cd_desc = CDFunc func; cd_loc = loc; cd_doc = None } ] in
  let output = emit_program_to_string prog in
  (* A4.2: cf_def_id = 0 → mangled name is __def_0_answer. *)
  Alcotest.(check bool)
    "no-param signature" true
    (let needle = "long __def_0_answer(void)" in
     let n = String.length needle in
     let m = String.length output in
     let rec go i =
       i + n <= m && (String.sub output i n = needle || go (i + 1))
     in
     go 0)

let test_emit_foreign_func_skipped () =
  (* Foreign funcs have no body — emitter should skip them *)
  let func : core_func =
    {
      cf_name = "printf";
      cf_module = None;
      cf_type_params = [];
      cf_params =
        [ { cp_name = Var.named "fmt"; cp_ty = ty_string; cp_loc = loc } ];
      cf_return_ty = ty_void;
      cf_body = None;
      cf_is_pure = false;
      cf_kind =
        CFForeign
          {
            c_name = "printf";
            includes = [];
            link_flags = [];
            arg_passing = ForeignDefaultArgs [];
          };
      cf_def_id = 0;
    }
  in
  let prog = [ { cd_desc = CDFunc func; cd_loc = loc; cd_doc = None } ] in
  let output = emit_program_to_string prog in
  (* Output should contain only the preamble, no function definition *)
  let contains_printf =
    let sub = "printf(" in
    let n = String.length sub in
    let m = String.length output in
    let rec go i = i + n <= m && (String.sub output i n = sub || go (i + 1)) in
    go 0
  in
  Alcotest.(check bool) "foreign func skipped" false contains_printf

(* ============================================================================
   Union/Enum type emission
   ============================================================================ *)

let test_emit_enum_type () =
  let tdecl : type_decl =
    {
      type_name = "Color";
      type_params = [];
      type_is_enum = true;
      type_is_builtin = false;
      type_is_resource = false;
      type_resource_cleanup = None;
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
    }
  in
  let prog = [ { cd_desc = CDType tdecl; cd_loc = loc; cd_doc = None } ] in
  let output = emit_program_to_string prog in
  Alcotest.(check bool) "has Red" true (contains_sub output "#define Red 0L");
  Alcotest.(check bool)
    "has Green" true
    (contains_sub output "#define Green 1L");
  Alcotest.(check bool) "has Blue" true (contains_sub output "#define Blue 2L");
  Alcotest.(check bool) "no struct" false (contains_sub output "struct Color")

let test_emit_union_no_rc () =
  let tdecl : type_decl =
    {
      type_name = "Shape";
      type_params = [];
      type_is_enum = false;
      type_is_builtin = false;
      type_is_resource = false;
      type_resource_cleanup = None;
      type_variants =
        [
          {
            variant_name = "Circle";
            variant_fields = [ TyNamed ("Float", []) ];
            variant_tag = 0;
            variant_loc = loc;
            variant_def_id = None;
          };
          {
            variant_name = "Rect";
            variant_fields = [ TyNamed ("Float", []); TyNamed ("Float", []) ];
            variant_tag = 1;
            variant_loc = loc;
            variant_def_id = None;
          };
        ];
    }
  in
  let prog = [ { cd_desc = CDType tdecl; cd_loc = loc; cd_doc = None } ] in
  let output = emit_program_to_string prog in
  Alcotest.(check bool) "has struct" true (contains_sub output "struct Shape {");
  Alcotest.(check bool)
    "has header" true
    (contains_sub output "blorp_Object header;");
  Alcotest.(check bool) "has tag" true (contains_sub output "int tag;");
  Alcotest.(check bool)
    "has release_mask" true
    (contains_sub output "unsigned long release_mask;");
  Alcotest.(check bool)
    "has Circle struct" true
    (contains_sub output "} Circle;");
  Alcotest.(check bool)
    "has TAG_Circle" true
    (contains_sub output "#define TAG_Shape_Circle 0");
  Alcotest.(check bool)
    "has TAG_Rect" true
    (contains_sub output "#define TAG_Shape_Rect 1");
  Alcotest.(check bool)
    "has Circle ctor" true
    (contains_sub output "Shape* Circle(");
  Alcotest.(check bool) "no destroy" false (contains_sub output "Shape_destroy")

let test_emit_union_with_rc () =
  let tdecl : type_decl =
    {
      type_name = "Expr";
      type_params = [];
      type_is_enum = false;
      type_is_builtin = false;
      type_is_resource = false;
      type_resource_cleanup = None;
      type_variants =
        [
          {
            variant_name = "Lit";
            variant_fields = [ ty_int ];
            variant_tag = 0;
            variant_loc = loc;
            variant_def_id = None;
          };
          {
            variant_name = "Name";
            variant_fields = [ ty_string ];
            variant_tag = 1;
            variant_loc = loc;
            variant_def_id = None;
          };
        ];
    }
  in
  let prog = [ { cd_desc = CDType tdecl; cd_loc = loc; cd_doc = None } ] in
  let output = emit_program_to_string prog in
  Alcotest.(check bool) "has destroy" true (contains_sub output "Expr_destroy");
  Alcotest.(check bool)
    "has release for Name.field0" true
    (contains_sub output "blorp_release(self->data.Name.field0)");
  Alcotest.(check bool)
    "has destructor assign" true
    (contains_sub output "BLORP_SET_DESTRUCTOR(__vc, Expr_destroy)");
  (* Constructors take [unsigned long release_mask] as a trailing param —
     the mask is computed at each call site from the actual arg types,
     not baked in here. See [emit_union_type] for the rationale (Option
     [Int] would otherwise destroy a non-pointer Int payload). *)
  Alcotest.(check bool)
    "Lit ctor takes mask" true
    (contains_sub output "Lit(void* field0, unsigned long release_mask)");
  Alcotest.(check bool)
    "Name ctor takes mask" true
    (contains_sub output "Name(void* field0, unsigned long release_mask)");
  Alcotest.(check bool)
    "ctor assigns mask param" true
    (contains_sub output "release_mask = release_mask;")

let test_emit_union_with_int128_boxed_payload_has_destructor () =
  let tdecl : type_decl =
    {
      type_name = "Wide";
      type_params = [];
      type_is_enum = false;
      type_is_builtin = false;
      type_is_resource = false;
      type_resource_cleanup = None;
      type_variants =
        [
          {
            variant_name = "WideValue";
            variant_fields = [ TyNamed ("Int128", []) ];
            variant_tag = 0;
            variant_loc = loc;
            variant_def_id = None;
          };
        ];
    }
  in
  let prog = [ { cd_desc = CDType tdecl; cd_loc = loc; cd_doc = None } ] in
  let output = emit_program_to_string prog in
  Alcotest.(check bool) "has destroy" true (contains_sub output "Wide_destroy");
  Alcotest.(check bool)
    "releases boxed int128 payload" true
    (contains_sub output "blorp_release(self->data.WideValue.field0)");
  Alcotest.(check bool)
    "has destructor assign" true
    (contains_sub output "BLORP_SET_DESTRUCTOR(__vc, Wide_destroy)")

let test_emit_union_obeys_registered_arc_only_policy () =
  (* Deliberately inconsistent with the field type: this isolates the
     emitter boundary and proves emission obeys the precomputed policy. *)
  let tdecl : type_decl =
    {
      type_name = "PolicyUnion";
      type_params = [];
      type_is_enum = false;
      type_is_builtin = false;
      type_is_resource = false;
      type_resource_cleanup = None;
      type_variants =
        [
          {
            variant_name = "PolicyName";
            variant_fields = [ ty_string ];
            variant_tag = 0;
            variant_loc = loc;
            variant_def_id = None;
          };
        ];
    }
  in
  let ctx = Blorp.Core_emit_context.create () in
  Blorp.Codegen_types.register_union_type ctx.reg tdecl.type_name
    ~destructor:Blorp.Codegen_types.ArcReleaseOnly;
  Blorp.Core_emit.emit_union_type ctx tdecl;
  let output = Buffer.contents ctx.output in
  Alcotest.(check bool)
    "does not emit destroy function" false
    (contains_sub output "PolicyUnion_destroy");
  Alcotest.(check bool)
    "does not assign destroy function" false
    (contains_sub output "BLORP_SET_DESTRUCTOR(__vc, PolicyUnion_destroy)")

let test_emit_union_empty_singleton () =
  let tdecl : type_decl =
    {
      type_name = "MyOpt";
      type_params = [];
      type_is_enum = false;
      type_is_builtin = false;
      type_is_resource = false;
      type_resource_cleanup = None;
      type_variants =
        [
          {
            variant_name = "MySome";
            variant_fields = [ ty_int ];
            variant_tag = 0;
            variant_loc = loc;
            variant_def_id = None;
          };
          {
            variant_name = "MyNone";
            variant_fields = [];
            variant_tag = 1;
            variant_loc = loc;
            variant_def_id = None;
          };
        ];
    }
  in
  let prog = [ { cd_desc = CDType tdecl; cd_loc = loc; cd_doc = None } ] in
  let output = emit_program_to_string prog in
  Alcotest.(check bool)
    "has singleton instance" true
    (contains_sub output "__instance_MyNone");
  Alcotest.(check bool)
    "has init function" true
    (contains_sub output "__init_MyNone");
  Alcotest.(check bool)
    "has define macro" true
    (contains_sub output "#define MyNone ((MyOpt*)&__instance_MyNone)");
  Alcotest.(check bool)
    "has IMMORTAL" true
    (contains_sub output "BLORP_IMMORTAL_REFCOUNT");
  Alcotest.(check bool)
    "has tag set" true
    (contains_sub output "__instance_MyNone.tag = TAG_MyOpt_MyNone")

let test_emit_union_forward_decl () =
  let tdecl : type_decl =
    {
      type_name = "MyUnion";
      type_params = [];
      type_is_enum = false;
      type_is_builtin = false;
      type_is_resource = false;
      type_resource_cleanup = None;
      type_variants =
        [
          {
            variant_name = "A";
            variant_fields = [ ty_int ];
            variant_tag = 0;
            variant_loc = loc;
            variant_def_id = None;
          };
        ];
    }
  in
  let prog = [ { cd_desc = CDType tdecl; cd_loc = loc; cd_doc = None } ] in
  let output = emit_program_to_string prog in
  Alcotest.(check bool)
    "has forward decl" true
    (contains_sub output "typedef struct MyUnion MyUnion;")

(* ============================================================================
   Heap record emission
   ============================================================================ *)

let test_emit_heap_record_no_rc () =
  let rdecl : record_decl =
    {
      record_name = "IntPair";
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
  let prog = [ { cd_desc = CDRecord rdecl; cd_loc = loc; cd_doc = None } ] in
  let output = emit_program_to_string prog in
  let contains sub =
    let n = String.length sub in
    let m = String.length output in
    let rec go i = i + n <= m && (String.sub output i n = sub || go (i + 1)) in
    go 0
  in
  Alcotest.(check bool) "has header" true (contains "blorp_Object header;");
  Alcotest.(check bool) "has typedef" true (contains "typedef struct IntPair {");
  Alcotest.(check bool) "has fields" true (contains "long x;");
  Alcotest.(check bool) "has make" true (contains "IntPair* IntPair_make(");
  Alcotest.(check bool)
    "has alloc" true
    (contains "blorp_alloc(sizeof(IntPair))");
  Alcotest.(check bool) "no destroy" false (contains "IntPair_destroy")

let test_emit_heap_record_with_rc () =
  let rdecl : record_decl =
    {
      record_name = "Named";
      record_type_params = [];
      record_fields =
        [
          { field_name = "name"; field_type = ty_string; field_loc = loc };
          { field_name = "id"; field_type = ty_int; field_loc = loc };
        ];
      record_is_value = false;
      record_is_builtin = false;
    }
  in
  let prog = [ { cd_desc = CDRecord rdecl; cd_loc = loc; cd_doc = None } ] in
  let output = emit_program_to_string prog in
  let contains sub =
    let n = String.length sub in
    let m = String.length output in
    let rec go i = i + n <= m && (String.sub output i n = sub || go (i + 1)) in
    go 0
  in
  Alcotest.(check bool) "has destroy" true (contains "Named_destroy");
  Alcotest.(check bool)
    "has release" true
    (contains "blorp_release((blorp_Object*)__rec->name)");
  Alcotest.(check bool)
    "has destructor assign" true
    (contains "BLORP_SET_DESTRUCTOR(__rec, Named_destroy)");
  Alcotest.(check bool)
    "no release for id" false
    (contains "__rec->id) blorp_release")

let test_emit_heap_record_obeys_registered_generated_policy () =
  (* Deliberately unnecessary for the field type: this isolates the
     emitter boundary and proves emission obeys the precomputed policy. *)
  let rdecl : record_decl =
    {
      record_name = "PolicyRecord";
      record_type_params = [];
      record_fields =
        [ { field_name = "id"; field_type = ty_int; field_loc = loc } ];
      record_is_value = false;
      record_is_builtin = false;
    }
  in
  let ctx = Blorp.Core_emit_context.create () in
  Blorp.Codegen_types.register_heap_record_type ctx.reg rdecl.record_name
    ~destructor:(Blorp.Codegen_types.GeneratedDestructor "PolicyRecord_destroy");
  Blorp.Core_emit.emit_heap_record ctx rdecl;
  let output = Buffer.contents ctx.output in
  Alcotest.(check bool)
    "emits registered destroy function" true
    (contains_sub output "static void PolicyRecord_destroy(void* obj)");
  Alcotest.(check bool)
    "assigns registered destroy function" true
    (contains_sub output "BLORP_SET_DESTRUCTOR(__rec, PolicyRecord_destroy)")

let test_emit_heap_record_forward_decl () =
  let rdecl : record_decl =
    {
      record_name = "Widget";
      record_type_params = [];
      record_fields =
        [ { field_name = "val"; field_type = ty_int; field_loc = loc } ];
      record_is_value = false;
      record_is_builtin = false;
    }
  in
  let prog = [ { cd_desc = CDRecord rdecl; cd_loc = loc; cd_doc = None } ] in
  let output = emit_program_to_string prog in
  let contains sub =
    let n = String.length sub in
    let m = String.length output in
    let rec go i = i + n <= m && (String.sub output i n = sub || go (i + 1)) in
    go 0
  in
  Alcotest.(check bool)
    "has forward decl" true
    (contains "typedef struct Widget Widget;")

let test_emit_value_record () =
  let rdecl : record_decl =
    {
      record_name = "Point";
      record_type_params = [];
      record_fields =
        [
          { field_name = "x"; field_type = ty_int; field_loc = loc };
          { field_name = "y"; field_type = ty_int; field_loc = loc };
        ];
      record_is_value = true;
      record_is_builtin = false;
    }
  in
  let prog = [ { cd_desc = CDRecord rdecl; cd_loc = loc; cd_doc = None } ] in
  let output = emit_program_to_string prog in
  let contains sub =
    let n = String.length sub in
    let m = String.length output in
    let rec go i = i + n <= m && (String.sub output i n = sub || go (i + 1)) in
    go 0
  in
  Alcotest.(check bool)
    "typedef" true
    (contains "typedef struct { long x; long y; } Point;");
  Alcotest.(check bool)
    "Point_make" true
    (contains "Point_make(long x, long y)")

let test_emit_value_record_used_in_function_sig () =
  (* Regression test: value records must emit as value types in function
     signatures, not as pointers. A function [add(a: Point, b: Point) -> Point]
     must emit as [Point add(Point a, Point b)], never [Point* add(Point* a, Point* b)].

     Previously this was broken because [Codegen_types.type_to_c] consulted a
     global [value_record_names] table that was never populated — the production
     writer only populated [ctx.value_record_names]. *)
  let point_ty = TyNamed ("Point", []) in
  let rdecl : record_decl =
    {
      record_name = "Point";
      record_type_params = [];
      record_fields =
        [
          { field_name = "x"; field_type = ty_int; field_loc = loc };
          { field_name = "y"; field_type = ty_int; field_loc = loc };
        ];
      record_is_value = true;
      record_is_builtin = false;
    }
  in
  let a_var = Var.named "a" in
  let b_var = Var.named "b" in
  (* body: Point_make(a.x + b.x, a.y + b.y) *)
  let a_val = mk (CVar a_var) point_ty in
  let b_val = mk (CVar b_var) point_ty in
  let a_x = mk (CField (a_val, "x")) ty_int in
  let b_x = mk (CField (b_val, "x")) ty_int in
  let a_y = mk (CField (a_val, "y")) ty_int in
  let b_y = mk (CField (b_val, "y")) ty_int in
  let sum_x = mk (CBin (Add, a_x, b_x)) ty_int in
  let sum_y = mk (CBin (Add, a_y, b_y)) ty_int in
  let body = mk (CRecord [ ("x", sum_x); ("y", sum_y) ]) point_ty in
  let add_fn : core_func =
    {
      cf_name = "add";
      cf_type_params = [];
      cf_module = None;
      cf_params =
        [
          { cp_name = a_var; cp_ty = point_ty; cp_loc = loc };
          { cp_name = b_var; cp_ty = point_ty; cp_loc = loc };
        ];
      cf_return_ty = point_ty;
      cf_body = Some body;
      cf_is_pure = true;
      cf_kind = CFUser;
      cf_def_id = 0;
    }
  in
  let prog =
    [
      { cd_desc = CDRecord rdecl; cd_loc = loc; cd_doc = None };
      { cd_desc = CDFunc add_fn; cd_loc = loc; cd_doc = None };
    ]
  in
  let output = emit_program_to_string prog in
  let has sub = contains_sub output sub in
  (* A4.2: signature becomes [Point __def_0_add(...)] — the DefId
     mangle replaces the bare function name. The Point-by-value
     check is now on the suffixed form. *)
  Alcotest.(check bool)
    "no Point* in signature" false
    (has "Point* __def_0_add(");
  Alcotest.(check bool) "no Point* parameter" false (has "Point* a");
  Alcotest.(check bool) "Point by value return" true (has "Point __def_0_add(");
  Alcotest.(check bool) "Point by value param" true (has "Point a")

(* Regression: enum-union types must emit as [long] in function signatures,
   mirroring the value-record fix. Bug class: [type_to_c] falls back to
   the pointer form if [reg.enum_types] isn't consulted, producing
   "Color* name(Color*)" with invalid switch/tag access in the body. *)
let test_emit_enum_type_used_in_function_sig () =
  let color_ty = TyNamed ("Color", []) in
  let tdecl : type_decl =
    {
      type_name = "Color";
      type_params = [];
      type_is_enum = true;
      type_is_builtin = false;
      type_is_resource = false;
      type_resource_cleanup = None;
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
    }
  in
  let c_var = Var.named "c" in
  (* Trivial body: 0 — we're inspecting the signature only. *)
  let body = cint 0 in
  let classify_fn : core_func =
    {
      cf_name = "classify";
      cf_type_params = [];
      cf_module = None;
      cf_params = [ { cp_name = c_var; cp_ty = color_ty; cp_loc = loc } ];
      cf_return_ty = ty_int;
      cf_body = Some body;
      cf_is_pure = true;
      cf_kind = CFUser;
      cf_def_id = 0;
    }
  in
  let prog =
    [
      { cd_desc = CDType tdecl; cd_loc = loc; cd_doc = None };
      { cd_desc = CDFunc classify_fn; cd_loc = loc; cd_doc = None };
    ]
  in
  let output = emit_program_to_string prog in
  let has sub = contains_sub output sub in
  Alcotest.(check bool) "no Color* parameter" false (has "Color* c");
  Alcotest.(check bool) "enum emitted as long" true (has "long c")

(** Regression: a heap record with a value-record field must emit the field
    as a bare struct, not as a pointer. Exercises [type_to_c] via [emit_heap_record]. *)
let test_emit_heap_record_with_value_field () =
  let point_ty = TyNamed ("Point", []) in
  let point_decl : record_decl =
    {
      record_name = "Point";
      record_type_params = [];
      record_fields =
        [
          { field_name = "x"; field_type = ty_int; field_loc = loc };
          { field_name = "y"; field_type = ty_int; field_loc = loc };
        ];
      record_is_value = true;
      record_is_builtin = false;
    }
  in
  (* Heap record holds two Points by value *)
  let path_decl : record_decl =
    {
      record_name = "Path";
      record_type_params = [];
      record_fields =
        [
          { field_name = "start"; field_type = point_ty; field_loc = loc };
          { field_name = "stop"; field_type = point_ty; field_loc = loc };
        ];
      record_is_value = false;
      record_is_builtin = false;
    }
  in
  let prog =
    [
      { cd_desc = CDRecord point_decl; cd_loc = loc; cd_doc = None };
      { cd_desc = CDRecord path_decl; cd_loc = loc; cd_doc = None };
    ]
  in
  let output = emit_program_to_string prog in
  let has sub = contains_sub output sub in
  Alcotest.(check bool) "no pointer-valued field" false (has "Point* start;");
  Alcotest.(check bool) "value-struct field" true (has "Point start;");
  Alcotest.(check bool) "value-struct field 2" true (has "Point stop;")

(** Regression: [Core_emit_context.reset] must clear the registry so a
    context reused for a second emission doesn't silently carry over the
    first emission's value-record registrations. *)
let test_emit_context_reset_clears_registry () =
  let ctx = Blorp.Core_emit_context.create () in
  Hashtbl.replace ctx.reg.value_records "StaleRecord" ();
  let open Blorp.Codegen_types in
  Blorp.Codegen_types.register_enum_type ctx.reg "StaleEnum" [];
  Blorp.Codegen_types.register_managed_type ctx.reg "StaleManaged"
    { managed_kind = ManagedHeapRecord; destructor = ArcReleaseOnly };
  Hashtbl.replace ctx.reg.type_aliases "StaleAlias" ([], ty_int);
  Blorp.Core_emit_context.reset ctx;
  Alcotest.(check bool)
    "value_records cleared" false
    (Hashtbl.mem ctx.reg.value_records "StaleRecord");
  Alcotest.(check bool)
    "enum_types cleared" false
    (Hashtbl.mem ctx.reg.enum_types "StaleEnum");
  Alcotest.(check bool)
    "managed_types cleared" false
    (Blorp.Codegen_types.is_managed_type ctx.reg "StaleManaged");
  Alcotest.(check bool)
    "type_aliases cleared" false
    (Hashtbl.mem ctx.reg.type_aliases "StaleAlias")

let test_emit_main_releases_argv_list () =
  let args_ty = TyNamed ("List", [ ty_string ]) in
  let index_of haystack needle =
    let n = String.length needle in
    let m = String.length haystack in
    let rec go i =
      if i + n > m then None
      else if String.sub haystack i n = needle then Some i
      else go (i + 1)
    in
    go 0
  in
  let check_order label output before after =
    match (index_of output before, index_of output after) with
    | Some i, Some j -> Alcotest.(check bool) label true (i < j)
    | _ ->
        Alcotest.failf
          "missing expected generated C in main wrapper: %S before %S" before
          after
  in
  let main_fn return_ty body : core_func =
    {
      cf_name = "main";
      cf_module = None;
      cf_type_params = [];
      cf_params =
        [ { cp_name = Var.named "args"; cp_ty = args_ty; cp_loc = loc } ];
      cf_return_ty = return_ty;
      cf_body = Some body;
      cf_is_pure = false;
      cf_kind = CFUser;
      cf_def_id = 0;
    }
  in
  let emit_main return_ty body =
    emit_program_to_string
      [
        {
          cd_desc = CDFunc (main_fn return_ty body);
          cd_loc = loc;
          cd_doc = None;
        };
      ]
  in
  let int_main = emit_main ty_int (cint 0) in
  Alcotest.(check bool)
    "int main stores result before cleanup" true
    (contains_sub int_main "long __blorp_main_result = (long)0L;");
  Alcotest.(check bool)
    "argv list releases string elements" true
    (contains_sub int_main
       "blorp_list_init_elem_release(args, blorp_elem_release_fn);");
  check_order "int main releases before return" int_main "blorp_release(args);"
    "return (int)__blorp_main_result;";
  let void_main = emit_main ty_void cvoid in
  check_order "void main releases before return" void_main
    "blorp_release(args);" "return 0;";
  match emit_main ty_int cvoid with
  | exception Blorp.Core_error.Core_error err ->
      Alcotest.(check bool)
        "main return mismatch is emit error" true
        (err.Blorp.Core_error.phase = Blorp.Core_error.Emit);
      Alcotest.(check bool)
        "main return mismatch explains expected Int" true
        (contains_sub err.Blorp.Core_error.msg "main declared return type Int")
  | _ -> Alcotest.fail "emit accepted main -> Int with Void body"

(* ============================================================================
   A4.2 invariant: every [__def_<id>_<name>] call has a matching decl

   Compiles a small realistic program through the full pipeline, then
   extracts every call-site symbol of the form [__def_N_name(] from
   the generated C and verifies each one also appears as a
   declaration [... __def_N_name(...)]. This is the quickest unit-level
   guard against the mangling drift that's expensive to catch via the
   runtime suite.
   ============================================================================ *)

(** Scan [c] for every call-site identifier matching [__def_<digits>_<name>(]
    and return them as a deduped set. Also scans for decl-site
    identifiers of the same shape, returning the intersection / the
    set-difference check. *)
let extract_def_symbols (c : string) : string list =
  let len = String.length c in
  let results = ref [] in
  let is_ident_char ch =
    (ch >= 'a' && ch <= 'z')
    || (ch >= 'A' && ch <= 'Z')
    || (ch >= '0' && ch <= '9')
    || ch = '_'
  in
  let rec scan i =
    if i >= len - 6 then ()
    else if String.sub c i 6 = "__def_" then begin
      let j = ref (i + 6) in
      while !j < len && is_ident_char c.[!j] do
        incr j
      done;
      if !j > i + 6 then results := String.sub c i (!j - i) :: !results;
      scan !j
    end
    else scan (i + 1)
  in
  scan 0;
  List.sort_uniq compare !results

let test_a4_3_trait_impl_methods_mangled () =
  (* A4.3: each trait impl method emits its C symbol via
     [mangle_by_def_id cf_def_id (Trait_method_Type)] on both the
     decl side (emit_impl → func_c_name) and every call site
     (core_trait_resolve rewrites CKUnknown to CKUser with the
     Trait_method_Type name, then user_call_c_name applies the same
     DefId mangle). This test compiles a program with a user union
     that implements Stringable, then checks that:
       (a) the impl method's decl is emitted as [__def_N_Stringable_to_string_Shape]
       (b) a call site to [to_string] with a Shape arg emits the
           same mangled symbol. *)
  Blorp.Session.(
    with_current (create ()) (fun () ->
        let source =
          {|
import:
    traits: Stringable

union Shape:
    Circle
    Square

implements Stringable for Shape:
    pure func to_string(self: Shape) -> String:
        match self:
            Circle: "circle"
            Square: "square"

pure func show_shape() -> String:
    to_string(Circle)

func main(args: List[String]) -> Int:
    if show_shape() == "circle":
        0
    else:
        1
|}
        in
        Blorp.Lexer.reset_state ();
        let lexbuf = Lexing.from_string source in
        let program = Blorp.Parser.program Blorp.Lexer.next_token lexbuf in
        let program = Blorp.Interp_parser.transform_program program in
        let typed =
          match Blorp.Typecheck.typecheck_typed program with
          | Ok typed -> typed
          | Error errors ->
              Alcotest.failf "expected no type errors, got: %s"
                (String.concat "; "
                   (List.map
                      (fun (e : Blorp.Ast.compiler_error) -> e.message)
                      errors))
        in
        let c_code = Blorp.Core_pipeline.compile_typed typed in
        let defs = extract_def_symbols c_code in
        let shape_method =
          List.find_opt
            (fun s ->
              let suffix = "_Stringable_to_string_Shape" in
              let n = String.length s in
              let m = String.length suffix in
              n >= m && String.sub s (n - m) m = suffix)
            defs
        in
        match shape_method with
        | None ->
            Alcotest.failf
              "no __def_N_Stringable_to_string_Shape in output. Defs seen: [%s]"
              (String.concat ", " defs)
        | Some sym ->
            (* Every such symbol must appear ≥2 times (decl + call). *)
            let count = ref 0 in
            let n = String.length sym in
            let m = String.length c_code in
            let i = ref 0 in
            while !i <= m - n do
              if String.sub c_code !i n = sym then (
                incr count;
                i := !i + n)
              else incr i
            done;
            if !count < 2 then
              Alcotest.failf
                "trait-impl symbol %s appears only %d time(s). Decl and every \
                 call site must agree on the mangled name."
                sym !count))

let test_a4_4_ufcs_mangling () =
  (* A4.4: UFCS method calls — [xs.length()] — resolve to the
     target module's function. After pre-A4 Fix 3, infer encodes
     the selected overload's ol_def_id as a [#<id>] suffix which
     core_lower strips into vdef_id; A4.2's user_call_c_name then
     mangles call sites via the def_id. The decl side is a normal
     module-prefixed function (e.g. [std_list__length]) mangled by
     its own cf_def_id. Both sides must agree on the final C symbol. *)
  Blorp.Session.(
    with_current (create ()) (fun () ->
        let source =
          {|
func main(args: List[String]) -> Int:
    xs: List[Int] = [1, 2, 3]
    n: Int = xs.length()
    n
|}
        in
        Blorp.Lexer.reset_state ();
        let lexbuf = Lexing.from_string source in
        let program = Blorp.Parser.program Blorp.Lexer.next_token lexbuf in
        let program = Blorp.Interp_parser.transform_program program in
        let typed =
          match Blorp.Typecheck.typecheck_typed program with
          | Ok typed -> typed
          | Error errors ->
              Alcotest.failf "expected no type errors, got: %s"
                (String.concat "; "
                   (List.map
                      (fun (e : Blorp.Ast.compiler_error) -> e.message)
                      errors))
        in
        let c_code = Blorp.Core_pipeline.compile_typed typed in
        (* Either the mangled symbol appears both at decl + call (≥2),
       or [length] resolves to a builtin ([blorp_list_len]) — in
       which case no [__def_N_..length] symbol is emitted. Both
       paths are valid; what matters is that the C compiler accepts
       the output. *)
        let defs = extract_def_symbols c_code in
        (* Verify no dangling calls: every [__def_N_name] symbol must
       appear ≥2 times (decl + call). This is the A4.2 invariant
       applied specifically to the UFCS-containing program. *)
        List.iter
          (fun sym ->
            let count = ref 0 in
            let n = String.length sym in
            let m = String.length c_code in
            let i = ref 0 in
            while !i <= m - n do
              if String.sub c_code !i n = sym then (
                incr count;
                i := !i + n)
              else incr i
            done;
            if !count < 2 then
              Alcotest.failf "UFCS program: symbol %s appears only %d time(s)"
                sym !count)
          defs))

let test_a4_2_every_call_has_decl () =
  let source =
    {|
pure func double(x: Int) -> Int:
    x * 2

pure func quadruple(x: Int) -> Int:
    double(double(x))

pure func compute() -> Int:
    quadruple(5) + double(3)

func main(args: List[String]) -> Int:
    compute()
|}
  in
  Blorp.Session.(
    with_current (create ()) (fun () ->
        Blorp.Lexer.reset_state ();
        let lexbuf = Lexing.from_string source in
        let program = Blorp.Parser.program Blorp.Lexer.next_token lexbuf in
        let program = Blorp.Interp_parser.transform_program program in
        let typed =
          match Blorp.Typecheck.typecheck_typed program with
          | Ok typed -> typed
          | Error errors ->
              Alcotest.failf "expected no type errors, got %d: %s"
                (List.length errors)
                (String.concat "; "
                   (List.map
                      (fun (e : Blorp.Ast.compiler_error) -> e.message)
                      errors))
        in
        let c_code = Blorp.Core_pipeline.compile_typed typed in
        let symbols = extract_def_symbols c_code in
        (* For each unique [__def_N_name] symbol, require that [<name>(]
       (with parens — i.e., a call or decl) appears in the output
       AND that a declaration / definition line with the exact
       symbol exists. The simplest proxy: the symbol appears more
       than once (once in decl, at least once elsewhere) OR the
       symbol is the entry [main] special-case which appears only
       once as [int main(]. *)
        List.iter
          (fun sym ->
            (* Count occurrences of the symbol. *)
            let count = ref 0 in
            let n = String.length sym in
            let m = String.length c_code in
            let i = ref 0 in
            while !i <= m - n do
              if String.sub c_code !i n = sym then (
                incr count;
                i := !i + n)
              else incr i
            done;
            if !count < 2 then
              Alcotest.failf
                "A4.2 invariant violation: symbol %s appears only %d time(s). \
                 Every [__def_<id>_<name>] used as a call must also have a \
                 matching decl; a symbol with exactly one occurrence is a \
                 dangling reference."
                sym !count)
          symbols))

(* ============================================================================
   End-to-end program-level validation via cc+run
   ============================================================================

   Build a core_program, emit the whole thing, append a trivial main
   that calls the emitted entry, compile with cc, run, check exit. *)

(** Compile and run a program, wrapping with a harness that calls
    [entry_fn_name] and returns its int value as the process exit code.

    A4.2: emitted function symbols are mangled
    [__def_<cf_def_id>_<cf_name>]. The callers in this file hand-
    construct core_funcs with [cf_def_id = 0], so the harness calls
    [__def_0_<entry_fn_name>]. *)
let run_program_expecting label (prog : core_program) entry_fn_name expected =
  let body = emit_program_to_string prog in
  let c_program =
    Printf.sprintf "%s\nint main(void) { return (int)__def_0_%s(); }\n" body
      entry_fn_name
  in
  let base = Filename.temp_file "blorp_core_prog_e2e" "" in
  let src = base ^ ".c" in
  let bin = base ^ ".out" in
  (try Sys.remove base with _ -> ());
  let oc = open_out src in
  output_string oc c_program;
  close_out oc;
  let cc_cmd = Printf.sprintf "cc -std=c99 -o %s %s 2>/dev/null" bin src in
  let cc_status = Sys.command cc_cmd in
  (try Sys.remove src with _ -> ());
  if cc_status <> 0 then begin
    (try Sys.remove bin with _ -> ());
    Alcotest.failf "%s: cc failed (exit %d) on program:\n%s" label cc_status
      c_program
  end;
  let run_status = Sys.command (bin ^ " > /dev/null 2>&1") in
  (try Sys.remove bin with _ -> ());
  Alcotest.(check int) (label ^ " exit code") expected run_status

let test_e2e_program_function () =
  (* func compute() -> Int: 40 + 2 *)
  let body = mk (CBin (Add, cint 40, cint 2)) ty_int in
  let func : core_func =
    {
      cf_name = "compute";
      cf_type_params = [];
      cf_params = [];
      cf_module = None;
      cf_return_ty = ty_int;
      cf_body = Some body;
      cf_is_pure = true;
      cf_kind = CFUser;
      cf_def_id = 0;
    }
  in
  let prog = [ { cd_desc = CDFunc func; cd_loc = loc; cd_doc = None } ] in
  run_program_expecting "compute() = 42" prog "compute" 42

let test_e2e_program_two_functions () =
  (* func inc(x: Int) -> Int: x + 1
     func compute() -> Int: inc(inc(inc(inc(39)))) -- returns 43 *)
  let inc : core_func =
    {
      cf_name = "inc";
      cf_type_params = [];
      cf_module = None;
      cf_params = [ { cp_name = Var.named "x"; cp_ty = ty_int; cp_loc = loc } ];
      cf_return_ty = ty_int;
      cf_body = Some (mk (CBin (Add, cvar "x" ty_int, cint 1)) ty_int);
      cf_is_pure = true;
      cf_kind = CFUser;
      cf_def_id = 0;
    }
  in
  let fty = TyFunc { params = [ ty_int ]; return = ty_int; is_pure = true } in
  let mk_call arg =
    mk (CCall (CKUser ("inc", Some 0), cvar "inc" fty, [ arg ])) ty_int
  in
  let body = mk_call (mk_call (mk_call (mk_call (cint 39)))) in
  let compute : core_func =
    {
      cf_name = "compute";
      cf_type_params = [];
      cf_params = [];
      cf_module = None;
      cf_return_ty = ty_int;
      cf_body = Some body;
      cf_is_pure = true;
      cf_kind = CFUser;
      cf_def_id = 0;
    }
  in
  (* Order matters: inc must be defined before compute references it *)
  let prog =
    [
      { cd_desc = CDFunc inc; cd_loc = loc; cd_doc = None };
      { cd_desc = CDFunc compute; cd_loc = loc; cd_doc = None };
    ]
  in
  run_program_expecting "4 x inc(39) = 43" prog "compute" 43

let test_e2e_program_match_in_func () =
  let tree =
    CTSwitchLit
      {
        ctl_scrut = AccRoot;
        ctl_cases =
          [
            (LitInt 1L, CTLeaf { ct_bindings = []; ct_body = cint 10 });
            (LitInt 2L, CTLeaf { ct_bindings = []; ct_body = cint 42 });
          ];
        ctl_default = CTLeaf { ct_bindings = []; ct_body = cint 0 };
      }
  in
  let classify_body = mk (CMatch (cvar "x" ty_int, tree)) ty_int in
  let classify : core_func =
    {
      cf_name = "classify";
      cf_type_params = [];
      cf_module = None;
      cf_params = [ { cp_name = Var.named "x"; cp_ty = ty_int; cp_loc = loc } ];
      cf_return_ty = ty_int;
      cf_body = Some classify_body;
      cf_is_pure = true;
      cf_kind = CFUser;
      cf_def_id = 0;
    }
  in
  let fty = TyFunc { params = [ ty_int ]; return = ty_int; is_pure = true } in
  let compute_body =
    mk
      (CCall (CKUser ("classify", Some 0), cvar "classify" fty, [ cint 2 ]))
      ty_int
  in
  let compute : core_func =
    {
      cf_name = "compute";
      cf_type_params = [];
      cf_params = [];
      cf_module = None;
      cf_return_ty = ty_int;
      cf_body = Some compute_body;
      cf_is_pure = true;
      cf_kind = CFUser;
      cf_def_id = 0;
    }
  in
  let prog =
    [
      { cd_desc = CDFunc classify; cd_loc = loc; cd_doc = None };
      { cd_desc = CDFunc compute; cd_loc = loc; cd_doc = None };
    ]
  in
  run_program_expecting "classify(2) via match" prog "compute" 42

let test_e2e_program_with_value_record () =
  (* struct Pair { a: Int, b: Int }
     func compute() -> Int: Pair_make(40, 2).a + Pair_make(40, 2).b *)
  let rdecl : record_decl =
    {
      record_name = "Pair";
      record_type_params = [];
      record_fields =
        [
          { field_name = "a"; field_type = ty_int; field_loc = loc };
          { field_name = "b"; field_type = ty_int; field_loc = loc };
        ];
      record_is_value = true;
      record_is_builtin = false;
    }
  in
  (* Pair is registered as a value record automatically by emit_program
     from the CDRecord declaration with record_is_value = true. *)
  let pair_ty = TyNamed ("Pair", []) in
  let mk_pair = mk (CRecord [ ("a", cint 40); ("b", cint 2) ]) pair_ty in
  let body =
    mk
      (CBin
         ( Add,
           mk (CField (mk_pair, "a")) ty_int,
           mk (CField (mk_pair, "b")) ty_int ))
      ty_int
  in
  let compute : core_func =
    {
      cf_name = "compute";
      cf_type_params = [];
      cf_params = [];
      cf_module = None;
      cf_return_ty = ty_int;
      cf_body = Some body;
      cf_is_pure = true;
      cf_kind = CFUser;
      cf_def_id = 0;
    }
  in
  let prog =
    [
      { cd_desc = CDRecord rdecl; cd_loc = loc; cd_doc = None };
      { cd_desc = CDFunc compute; cd_loc = loc; cd_doc = None };
    ]
  in
  run_program_expecting "Pair.a + Pair.b = 42" prog "compute" 42

(* ============================================================================
   CMatch emission (Phase 1.2c)
   ============================================================================ *)

let test_emit_match_tree_lit_int () =
  let tree =
    CTSwitchLit
      {
        ctl_scrut = AccRoot;
        ctl_cases =
          [
            (LitInt 1L, CTLeaf { ct_bindings = []; ct_body = cint 10 });
            (LitInt 2L, CTLeaf { ct_bindings = []; ct_body = cint 20 });
          ];
        ctl_default = CTLeaf { ct_bindings = []; ct_body = cint 0 };
      }
  in
  let e = mk (CMatch (cvar "x" ty_int, tree)) ty_int in
  Alcotest.(check string)
    "lit int switch"
    "({ long __scrut_0 = x; long __mr_1; if (__scrut_0 == 1L) { __mr_1 = 10L; \
     } else if (__scrut_0 == 2L) { __mr_1 = 20L; } else { __mr_1 = 0L; } \
     __mr_1; })"
    (emit_to_string e)

let test_emit_match_tree_lit_bool () =
  let tree =
    CTSwitchLit
      {
        ctl_scrut = AccRoot;
        ctl_cases =
          [ (LitBool true, CTLeaf { ct_bindings = []; ct_body = cint 1 }) ];
        ctl_default = CTLeaf { ct_bindings = []; ct_body = cint 0 };
      }
  in
  let e = mk (CMatch (cvar "flag" ty_bool, tree)) ty_int in
  Alcotest.(check string)
    "lit bool switch"
    "({ bool __scrut_0 = flag; long __mr_1; if (__scrut_0 == true) { __mr_1 = \
     1L; } else { __mr_1 = 0L; } __mr_1; })"
    (emit_to_string e)

let test_emit_match_tree_tag_no_bindings () =
  let union_ty = TyNamed ("Color", []) in
  let tree =
    CTSwitchTag
      {
        cts_scrut = AccRoot;
        cts_cases =
          [
            ("Red", CTLeaf { ct_bindings = []; ct_body = cint 1 });
            ("Blue", CTLeaf { ct_bindings = []; ct_body = cint 2 });
          ];
        cts_default = None;
      }
  in
  let e = mk (CMatch (cvar "c" union_ty, tree)) ty_int in
  Alcotest.(check string)
    "tag switch"
    "({ Color* __scrut_0 = c; long __mr_1; if (__scrut_0->tag == \
     TAG_Color_Red) { __mr_1 = 1L; } else if (__scrut_0->tag == \
     TAG_Color_Blue) { __mr_1 = 2L; } __mr_1; })"
    (emit_to_string e)

let test_emit_match_tree_tag_with_bindings () =
  let union_ty = TyNamed ("MyOpt", []) in
  let tree =
    CTSwitchTag
      {
        cts_scrut = AccRoot;
        cts_cases =
          [
            ( "Some",
              CTLeaf
                {
                  ct_bindings =
                    [ (Var.named "x", AccVariantField (AccRoot, "Some", 0)) ];
                  ct_body = cvar "x" ty_int;
                } );
            ("None", CTLeaf { ct_bindings = []; ct_body = cint 0 });
          ];
        cts_default = None;
      }
  in
  let e = mk (CMatch (cvar "opt" union_ty, tree)) ty_int in
  Alcotest.(check string)
    "tag with bindings"
    "({ MyOpt* __scrut_0 = opt; long __mr_1; if (__scrut_0->tag == \
     TAG_MyOpt_Some) { long x = (long)(long)__scrut_0->data.Some.field0; \
     __mr_1 = x; } else if (__scrut_0->tag == TAG_MyOpt_None) { __mr_1 = 0L; } \
     __mr_1; })"
    (emit_to_string e)

let test_emit_match_tree_stack_option_int () =
  let tree =
    CTSwitchTag
      {
        cts_scrut = AccRoot;
        cts_cases =
          [
            ( "Some",
              CTLeaf
                {
                  ct_bindings =
                    [ (Var.named "x", AccVariantField (AccRoot, "Some", 0)) ];
                  ct_body = cvar "x" ty_int;
                } );
            ("None", CTLeaf { ct_bindings = []; ct_body = cint 0 });
          ];
        cts_default = None;
      }
  in
  let e = mk (CMatch (cvar "opt" option_int, tree)) ty_int in
  Alcotest.(check string)
    "stack option tag with binding"
    "({ blorp_StackOption_Int __scrut_0 = opt; long __mr_1; if (__scrut_0.tag \
     == TAG_Option_Some) { long x = (long)__scrut_0.value; __mr_1 = x; } else \
     if (__scrut_0.tag == TAG_Option_None) { __mr_1 = 0L; } __mr_1; })"
    (emit_to_string e)

let test_emit_match_tree_stack_option_float () =
  let tree =
    CTSwitchTag
      {
        cts_scrut = AccRoot;
        cts_cases =
          [
            ( "Some",
              CTLeaf
                {
                  ct_bindings =
                    [ (Var.named "x", AccVariantField (AccRoot, "Some", 0)) ];
                  ct_body = cvar "x" ty_float;
                } );
            ("None", CTLeaf { ct_bindings = []; ct_body = cfloat 0.0 });
          ];
        cts_default = None;
      }
  in
  let e = mk (CMatch (cvar "opt" option_float, tree)) ty_float in
  Alcotest.(check string)
    "stack option float tag with binding"
    "({ blorp_StackOption_Float __scrut_0 = opt; double __mr_1; if \
     (__scrut_0.tag == TAG_Option_Some) { double x = (double)__scrut_0.value; \
     __mr_1 = x; } else if (__scrut_0.tag == TAG_Option_None) { __mr_1 = 0.0; \
     } __mr_1; })"
    (emit_to_string e)

let test_emit_match_tree_stack_result_int_bool () =
  let tree =
    CTSwitchTag
      {
        cts_scrut = AccRoot;
        cts_cases =
          [
            ( "Ok",
              CTLeaf
                {
                  ct_bindings =
                    [ (Var.named "x", AccVariantField (AccRoot, "Ok", 0)) ];
                  ct_body = cvar "x" ty_int;
                } );
            ("Err", CTLeaf { ct_bindings = []; ct_body = cint 0 });
          ];
        cts_default = None;
      }
  in
  let e = mk (CMatch (cvar "res" ty_result_int_bool, tree)) ty_int in
  Alcotest.(check string)
    "stack result tag with binding"
    "({ blorp_StackResult __scrut_0 = res; long __mr_1; if (__scrut_0.tag == \
     TAG_Result_Ok) { long x = (long)(long)__scrut_0.data.Ok.field0; __mr_1 = \
     x; } else if (__scrut_0.tag == TAG_Result_Err) { __mr_1 = 0L; } __mr_1; \
     })"
    (emit_to_string e)

let test_emit_match_tree_owned_builtin_scrutinee_releases () =
  let scrut =
    mk
      (CCall
         ( CKBuiltin "blorp_dict_get",
           cvoid,
           [ cvar "d" ty_dict_string_string; cstr "key" ] ))
      ty_opt_string
  in
  let tree =
    CTSwitchTag
      {
        cts_scrut = AccRoot;
        cts_cases =
          [
            ("Some", CTLeaf { ct_bindings = []; ct_body = cint 1 });
            ("None", CTLeaf { ct_bindings = []; ct_body = cint 0 });
          ];
        cts_default = None;
      }
  in
  let e = mk (CMatch (scrut, tree)) ty_int in
  let output = emit_to_string e in
  Alcotest.(check bool)
    "owned scrutinee released" true
    (contains_sub output "blorp_release(__scrut_0);")

let test_emit_match_tree_borrowed_intrinsic_scrutinee_does_not_release () =
  let scrut =
    mk
      (CCall
         (CKIntrinsic "list_get", cvoid, [ cvar "xs" ty_list_string; cint 0 ]))
      ty_string
  in
  let tree =
    CTLeaf { ct_bindings = [ (Var.named "s", AccRoot) ]; ct_body = cint 1 }
  in
  let e = mk (CMatch (scrut, tree)) ty_int in
  let output = emit_to_string e in
  Alcotest.(check bool)
    "borrowed scrutinee not released" false
    (contains_sub output "blorp_release(__scrut_0);")

let test_emit_match_tree_list_elem_tag_casts_void_ptr () =
  let ctx = Blorp.Core_emit_context.create () in
  Hashtbl.replace ctx.ctor_parent_types "TomlString" "TomlValue";
  let acc = AccListElem (AccRoot, 0) in
  let acc_c = Blorp.Core_emit_util.render_accessor ctx "__items" acc in
  Alcotest.(check string)
    "list element tag casts void*"
    "((TomlValue*)blorp_list_get((blorp_List*)__items, 0))->tag == \
     TAG_TomlValue_TomlString"
    (Blorp.Core_emit_util.tag_test_str ctx
       (TyNamed ("List", [ TyNamed ("TomlValue", []) ]))
       acc acc_c "TomlString")

let test_emit_match_tree_list_elem_variant_field_casts_void_ptr () =
  let ctx = Blorp.Core_emit_context.create () in
  Hashtbl.replace ctx.ctor_parent_types "TomlString" "TomlValue";
  Alcotest.(check string)
    "list element variant field casts void*"
    "((TomlValue*)blorp_list_get((blorp_List*)__items, \
     0))->data.TomlString.field0"
    (Blorp.Core_emit_util.render_accessor ctx "__items"
       (AccVariantField (AccListElem (AccRoot, 0), "TomlString", 0)))

let test_emit_match_tree_tuple_nullable_option_string () =
  let tuple_ty = TyTuple [ ty_opt_string; ty_opt_string ] in
  let first = AccTupleField (AccRoot, 0) in
  let tree =
    CTSwitchTag
      {
        cts_scrut = first;
        cts_cases =
          [
            ( "Some",
              CTLeaf
                {
                  ct_bindings =
                    [ (Var.named "s", AccVariantField (first, "Some", 0)) ];
                  ct_body = cvar "s" ty_string;
                } );
            ("None", CTLeaf { ct_bindings = []; ct_body = cstr "fallback" });
          ];
        cts_default = None;
      }
  in
  let output =
    emit_to_string (mk (CMatch (cvar "pair" tuple_ty, tree)) ty_string)
  in
  Alcotest.(check bool)
    "nested Some tag uses nullable payload" true
    (contains_sub output "((blorp_Tuple*)__scrut_0)->elem[0] != NULL");
  Alcotest.(check bool)
    "nested None tag uses nullable payload" true
    (contains_sub output "((blorp_Tuple*)__scrut_0)->elem[0] == NULL");
  Alcotest.(check bool)
    "nested payload binding is direct pointer" true
    (contains_sub output
       "blorp_String* s = (blorp_String*)((blorp_Tuple*)__scrut_0)->elem[0];");
  Alcotest.(check bool)
    "does not cast tuple payload to boxed Option" false
    (contains_sub output "Option*")

let test_emit_match_tree_tuple_stack_option_float () =
  let tuple_ty = TyTuple [ option_float; option_float ] in
  let first = AccTupleField (AccRoot, 0) in
  let tree =
    CTSwitchTag
      {
        cts_scrut = first;
        cts_cases =
          [
            ( "Some",
              CTLeaf
                {
                  ct_bindings =
                    [ (Var.named "x", AccVariantField (first, "Some", 0)) ];
                  ct_body = cvar "x" ty_float;
                } );
            ("None", CTLeaf { ct_bindings = []; ct_body = cfloat 0.0 });
          ];
        cts_default = None;
      }
  in
  let output =
    emit_to_string (mk (CMatch (cvar "pair" tuple_ty, tree)) ty_float)
  in
  let first_stack_option =
    "(*(blorp_StackOption_Float*)((char*)((blorp_Tuple*)__scrut_0)->elem[0] + \
     sizeof(blorp_Object)))"
  in
  Alcotest.(check bool)
    "nested Some tag reads boxed stack option" true
    (contains_sub output (first_stack_option ^ ".tag == TAG_Option_Some"));
  Alcotest.(check bool)
    "nested None tag reads boxed stack option" true
    (contains_sub output (first_stack_option ^ ".tag == TAG_Option_None"));
  Alcotest.(check bool)
    "nested payload binding reads boxed stack option value" true
    (contains_sub output
       ("double x = (double)" ^ first_stack_option ^ ".value;"));
  Alcotest.(check bool)
    "does not cast stack option tuple payload to boxed Option" false
    (contains_sub output "Option*")

let test_emit_match_tree_result_nullable_option_string () =
  let ok_payload = AccVariantField (AccRoot, "Ok", 0) in
  let tree =
    CTSwitchTag
      {
        cts_scrut = AccRoot;
        cts_cases =
          [
            ( "Ok",
              CTSwitchTag
                {
                  cts_scrut = ok_payload;
                  cts_cases =
                    [
                      ( "Some",
                        CTLeaf
                          {
                            ct_bindings =
                              [
                                ( Var.named "s",
                                  AccVariantField (ok_payload, "Some", 0) );
                              ];
                            ct_body = cvar "s" ty_string;
                          } );
                      ( "None",
                        CTLeaf { ct_bindings = []; ct_body = cstr "none" } );
                    ];
                  cts_default = None;
                } );
            ("Err", CTLeaf { ct_bindings = []; ct_body = cstr "err" });
          ];
        cts_default = None;
      }
  in
  let ctx = Blorp.Core_emit_context.create () in
  Hashtbl.replace ctx.ctor_parent_types "Some" "Option";
  let output =
    emit_to_string_with_ctx ctx
      (mk (CMatch (cvar "res" ty_result_opt_string_string, tree)) ty_string)
  in
  Alcotest.(check bool)
    "Result Ok(Some(_)) uses nullable payload test" true
    (contains_sub output "__scrut_0.data.Ok.field0 != NULL");
  Alcotest.(check bool)
    "Result Ok(None) uses nullable payload test" true
    (contains_sub output "__scrut_0.data.Ok.field0 == NULL");
  Alcotest.(check bool)
    "Result Ok(Some(s)) binding is direct pointer" true
    (contains_sub output
       "blorp_String* s = (blorp_String*)__scrut_0.data.Ok.field0;");
  Alcotest.(check bool)
    "does not cast Result payload to boxed Option" false
    (contains_sub output "Option*")

let test_emit_match_tree_tag_default () =
  let union_ty = TyNamed ("Shape", []) in
  let tree =
    CTSwitchTag
      {
        cts_scrut = AccRoot;
        cts_cases =
          [ ("Circle", CTLeaf { ct_bindings = []; ct_body = cint 1 }) ];
        cts_default = Some (CTLeaf { ct_bindings = []; ct_body = cint 0 });
      }
  in
  let e = mk (CMatch (cvar "s" union_ty, tree)) ty_int in
  Alcotest.(check string)
    "tag with default"
    "({ Shape* __scrut_0 = s; long __mr_1; if (__scrut_0->tag == \
     TAG_Shape_Circle) { __mr_1 = 1L; } else { __mr_1 = 0L; } __mr_1; })"
    (emit_to_string e)

let test_emit_match_tree_catchall () =
  let tree =
    CTLeaf
      {
        ct_bindings = [ (Var.named "y", AccRoot) ];
        ct_body = mk (CBin (Add, cvar "y" ty_int, cint 1)) ty_int;
      }
  in
  let e = mk (CMatch (cvar "x" ty_int, tree)) ty_int in
  Alcotest.(check string)
    "catchall leaf"
    "({ long __scrut_0 = x; long __mr_1; long y = (long)(long)__scrut_0; \
     __mr_1 = (y + 1L); __mr_1; })"
    (emit_to_string e)

let test_emit_match_tree_fail () =
  let tree = CTFail in
  let e = mk (CMatch (cvar "x" ty_int, tree)) ty_int in
  let output = emit_to_string e in
  let contains sub =
    let n = String.length sub in
    let m = String.length output in
    let rec go i = i + n <= m && (String.sub output i n = sub || go (i + 1)) in
    go 0
  in
  Alcotest.(check bool) "has abort" true (contains "abort()");
  Alcotest.(check bool) "has error msg" true (contains "non-exhaustive")

let test_emit_match_tree_lit_stmt () =
  let tree =
    CTSwitchLit
      {
        ctl_scrut = AccRoot;
        ctl_cases =
          [ (LitInt 1L, CTLeaf { ct_bindings = []; ct_body = cint 10 }) ];
        ctl_default = CTLeaf { ct_bindings = []; ct_body = cint 0 };
      }
  in
  let e = mk (CMatch (cvar "x" ty_int, tree)) ty_int in
  Alcotest.(check string)
    "lit switch stmt"
    "long __scrut_0 = x;\n\
     if (__scrut_0 == 1L) {\n\
    \    10L;\n\
     } else {\n\
    \    0L;\n\
     }\n"
    (emit_stmt_to_string e)

let test_emit_match_tree_tag_stmt () =
  let union_ty = TyNamed ("Color", []) in
  let print_ty =
    TyFunc { params = [ ty_int ]; return = ty_void; is_pure = false }
  in
  let tree =
    CTSwitchTag
      {
        cts_scrut = AccRoot;
        cts_cases =
          [
            ( "Red",
              CTLeaf
                {
                  ct_bindings = [];
                  ct_body =
                    mk
                      (CCall
                         ( CKUser ("handle", None),
                           cvar "handle" print_ty,
                           [ cint 1 ] ))
                      ty_void;
                } );
            ( "Blue",
              CTLeaf
                {
                  ct_bindings = [];
                  ct_body =
                    mk
                      (CCall
                         ( CKUser ("handle", None),
                           cvar "handle" print_ty,
                           [ cint 2 ] ))
                      ty_void;
                } );
          ];
        cts_default = None;
      }
  in
  let e = mk (CMatch (cvar "c" union_ty, tree)) ty_void in
  Alcotest.(check string)
    "tag switch stmt"
    "Color* __scrut_0 = c;\n\
     if (__scrut_0->tag == TAG_Color_Red) {\n\
    \    handle(1L);\n\
     } else if (__scrut_0->tag == TAG_Color_Blue) {\n\
    \    handle(2L);\n\
     }\n"
    (emit_stmt_to_string e)

(* ============================================================================
   End-to-end validation: compile + run actual binaries
   ============================================================================

   Routes tiny Core expressions through emit_to_string, wraps the result
   in a minimal [int main(void) { return (int)EXPR; }], compiles with
   [cc], runs the binary, and asserts the exit code matches expected.

   Arithmetic-only inputs so we don't need to link against the blorp
   runtime (no [blorp_retain]/[blorp_release] calls produced). This is
   the first real validation that the Core emission pipeline produces
   valid runnable C.

   Uses [Filename.temp_file] + [Sys.command] + [Sys.remove] — portable
   across macOS / Linux. On systems without [cc] the test fails with
   a clear message. *)

(** Compile [c_expr] as the return value of a trivial [main], run it,
    and assert the exit code equals [expected]. *)
let run_core_expr_expecting label e expected =
  let c_expr = emit_to_string e in
  let c_program =
    Printf.sprintf "#include <stdbool.h>\nint main(void) { return (int)%s; }\n"
      c_expr
  in
  let base = Filename.temp_file "blorp_core_e2e" "" in
  let src = base ^ ".c" in
  let bin = base ^ ".out" in
  (try Sys.remove base with _ -> ());
  let oc = open_out src in
  output_string oc c_program;
  close_out oc;
  let cc_cmd = Printf.sprintf "cc -std=c99 -o %s %s 2>/dev/null" bin src in
  let cc_status = Sys.command cc_cmd in
  (try Sys.remove src with _ -> ());
  if cc_status <> 0 then begin
    (try Sys.remove bin with _ -> ());
    Alcotest.failf "%s: cc failed (exit %d) on program:\n%s" label cc_status
      c_program
  end;
  let run_status = Sys.command (bin ^ " > /dev/null 2>&1") in
  (try Sys.remove bin with _ -> ());
  Alcotest.(check int) (label ^ " exit code") expected run_status

(** Simplest case: 40 + 2 → exit 42. *)
let test_e2e_arith () =
  let e = Build.add (Build.lit_int ~loc 40) (Build.lit_int ~loc 2) in
  run_core_expr_expecting "40 + 2" e 42

(** Nested arithmetic: (5 * 8) + 2 → exit 42. *)
let test_e2e_nested_arith () =
  let prod = Build.mul (Build.lit_int ~loc 5) (Build.lit_int ~loc 8) in
  let e = Build.add prod (Build.lit_int ~loc 2) in
  run_core_expr_expecting "5*8 + 2" e 42

(** If-true branch selection: if true then 42 else 0 → exit 42. *)
let test_e2e_if_true () =
  let e =
    Build.if_ ~cond:(Build.lit_bool ~loc true) ~then_:(Build.lit_int ~loc 42)
      ~else_:(Build.lit_int ~loc 0)
  in
  run_core_expr_expecting "if true then 42 else 0" e 42

(** If-false branch selection: if false then 0 else 42 → exit 42. *)
let test_e2e_if_false () =
  let e =
    Build.if_
      ~cond:(Build.lit_bool ~loc false)
      ~then_:(Build.lit_int ~loc 0) ~else_:(Build.lit_int ~loc 42)
  in
  run_core_expr_expecting "if false then 0 else 42" e 42

(** Comparison + if: if 5 < 10 then 42 else 0 → exit 42. *)
let test_e2e_comparison () =
  let cond = Build.lt (Build.lit_int ~loc 5) (Build.lit_int ~loc 10) in
  let e =
    Build.if_ ~cond ~then_:(Build.lit_int ~loc 42) ~else_:(Build.lit_int ~loc 0)
  in
  run_core_expr_expecting "5<10 then 42" e 42

(** Let binding: let x = 40 in x + 2 → exit 42. Exercises CLet's
    statement-expression emission. *)
let test_e2e_let () =
  let x = Build.var ~loc ~ty:Build.ty_int "x" in
  let body = Build.add x (Build.lit_int ~loc 2) in
  let e = Build.let_ "x" ~ty:Build.ty_int ~rhs:(Build.lit_int ~loc 40) ~body in
  run_core_expr_expecting "let x = 40 in x + 2" e 42

let test_e2e_match_lit_switch () =
  let tree =
    CTSwitchLit
      {
        ctl_scrut = AccRoot;
        ctl_cases =
          [
            (LitInt 1L, CTLeaf { ct_bindings = []; ct_body = cint 10 });
            (LitInt 2L, CTLeaf { ct_bindings = []; ct_body = cint 42 });
          ];
        ctl_default = CTLeaf { ct_bindings = []; ct_body = cint 0 };
      }
  in
  let e = mk (CMatch (cint 2, tree)) ty_int in
  run_core_expr_expecting "match 2 { 1->10, 2->42, _->0 }" e 42

let test_e2e_match_default () =
  let tree =
    CTSwitchLit
      {
        ctl_scrut = AccRoot;
        ctl_cases =
          [ (LitInt 1L, CTLeaf { ct_bindings = []; ct_body = cint 10 }) ];
        ctl_default = CTLeaf { ct_bindings = []; ct_body = cint 42 };
      }
  in
  let e = mk (CMatch (cint 99, tree)) ty_int in
  run_core_expr_expecting "match 99 { 1->10, _->42 }" e 42

let test_e2e_match_catchall_binding () =
  let tree =
    CTLeaf
      {
        ct_bindings = [ (Var.named "y", AccRoot) ];
        ct_body = mk (CBin (Add, cvar "y" ty_int, cint 2)) ty_int;
      }
  in
  let e = mk (CMatch (cint 40, tree)) ty_int in
  run_core_expr_expecting "match 40 { y -> y+2 }" e 42

(* ============================================================================
   Invariant violations — sugar/uncompiled forms must produce Core_error
   with phase + location, not failwith with only a string.
   ============================================================================ *)

let invariant_loc =
  { line = 42; column = 7; end_line = 42; end_column = 10; loc_file = None }

(** Helper: call [f] expecting a [Core_error.Core_error] whose msg contains
    [needle] and loc line = [line]. Fails the test if [f] raises anything
    else (including the pre-migration [Failure]). *)
let expect_core_error_at ~needle ~line f =
  match f () with
  | exception Blorp.Core_error.Core_error err ->
      Alcotest.(check bool)
        "phase is Emit" true
        (err.Blorp.Core_error.phase = Blorp.Core_error.Emit);
      Alcotest.(check int)
        "location carries line" line err.Blorp.Core_error.loc.line;
      Alcotest.(check bool)
        "msg mentions invariant" true
        (contains_sub err.Blorp.Core_error.msg needle)
  | exception e ->
      Alcotest.failf "expected Core_error, got %s" (Printexc.to_string e)
  | _ -> Alcotest.fail "expected Core_error, got normal return"

let unsupported_task_capture_task return_ty =
  {
    tc_func = "_blorp_task_bad_capture";
    tc_def_id = 9001;
    tc_captures =
      [
        {
          task_capture_name = "resource";
          task_capture_ty = ty_test_resource;
          task_capture_kind = TaskMoveResourceItem;
        };
      ];
    tc_return_ty = return_ty;
  }

let test_emit_rejects_unsupported_task_capture_kind () =
  let rhs = { desc = CLit (LitInt 1L); ty = ty_int; loc = invariant_loc } in
  let task = unsupported_task_capture_task rhs.ty in
  let result_ty =
    TyNamed ("Result", [ ty_int; TyNamed ("ConcurrencyError", []) ])
  in
  let binding =
    {
      cb_var = Var.named "answer";
      cb_ty = result_ty;
      cb_rhs = rhs;
      cb_task_scope = synthetic_concurrent_task_scope;
      cb_task = Some task;
    }
  in
  let block =
    {
      desc =
        CConcurrent
          {
            conc_bindings = [ binding ];
            conc_body = cvoid;
            conc_timeout = None;
            conc_max_threads = None;
          };
      ty = ty_void;
      loc = invariant_loc;
    }
  in
  expect_core_error_at ~needle:"unsupported concurrent binding task capture"
    ~line:42 (fun () -> ignore (emit_stmt_to_string block));
  let detach =
    {
      desc = CDetach { detach_body = rhs; detach_task = Some task };
      ty = ty_void;
      loc = invariant_loc;
    }
  in
  expect_core_error_at ~needle:"unsupported detach task capture" ~line:42
    (fun () -> ignore (emit_stmt_to_string detach));
  let concurrent_for =
    {
      desc =
        CConcurrentFor
          {
            cf_var = Var.named "item";
            cf_iter = cvar "items" (TyNamed ("List", [ ty_int ]));
            cf_body = rhs;
            cf_timeout = None;
            cf_width = ConcurrentForDefault;
            cf_task_scope = synthetic_concurrent_task_scope;
            cf_task = Some task;
          };
      ty = TyNamed ("List", [ result_ty ]);
      loc = invariant_loc;
    }
  in
  expect_core_error_at ~needle:"unsupported concurrent-for task capture"
    ~line:42 (fun () -> ignore (emit_stmt_to_string concurrent_for))

let test_emit_invariant_cmatch_expr () =
  (* Raw CMatchArms should never reach emit_expr — it should have been
     compiled to decision-tree CMatch by core_match. If we construct
     one by hand, emit must raise a structured Core_error with location
     + phase tag. *)
  let scrut = mk (CLit (LitInt 1L)) ty_int in
  let node =
    { desc = CMatchArms (scrut, []); ty = ty_int; loc = invariant_loc }
  in
  expect_core_error_at ~needle:"CMatchArms" ~line:42 (fun () ->
      emit_to_string node)

let test_emit_invariant_cstring_interp () =
  let node =
    {
      desc = CStringInterp ([ IPLit "hi" ], false);
      ty = ty_string;
      loc = invariant_loc;
    }
  in
  expect_core_error_at ~needle:"sugar node survived desugaring" ~line:42
    (fun () -> emit_to_string node)

let test_emit_invariant_cmatch_stmt () =
  let scrut = mk (CLit (LitInt 1L)) ty_int in
  let node =
    { desc = CMatchArms (scrut, []); ty = ty_void; loc = invariant_loc }
  in
  expect_core_error_at ~needle:"CMatchArms" ~line:42 (fun () ->
      emit_stmt_to_string node)

let test_emit_invariant_ckunknown_call () =
  let f_ty = TyFunc { params = []; return = ty_int; is_pure = true } in
  let node =
    {
      desc =
        CCall (CKUnknown, { (cvar "mystery" f_ty) with loc = invariant_loc }, []);
      ty = ty_int;
      loc = invariant_loc;
    }
  in
  expect_core_error_at ~needle:"unresolved call target" ~line:42 (fun () ->
      emit_to_string node)

let test_emit_invariant_tensor_literal_layout_payload_mismatch () =
  let tensor_ty = TyNamed ("Tensor", [ ty_float; TyConstInt 1 ]) in
  let node =
    {
      desc =
        CTensorLiteral
          {
            tl_shape = TensorVectorLength 1;
            tl_layout =
              tensor_raw_scalar_storage ~elem_ty:ty_float TensorFloat32Elements;
            tl_payload =
              TensorRawElements (TensorFloat64Elements, [ cfloat 1.0 ]);
          };
      ty = tensor_ty;
      loc = invariant_loc;
    }
  in
  expect_core_error_at ~needle:"tensor literal layout" ~line:42 (fun () ->
      emit_to_string node)

let test_emit_tensor_literal_uses_layout_release_policy () =
  let tensor_ty = TyNamed ("Tensor", [ ty_string; TyConstInt 1 ]) in
  let e =
    mk
      (CTensorLiteral
         {
           tl_shape = TensorVectorLength 1;
           tl_layout =
             Blorp.Core_layout_type.tensor_storage_layout_of_elem ty_string loc;
           tl_payload =
             TensorBoxedElements [ boxed_pointer_storage (cstr "a") ty_string ];
         })
      tensor_ty
  in
  let s = emit_to_string e in
  Alcotest.(check bool)
    "release follows tensor layout" true
    (contains_sub s "blorp_vector_init_elem_release")

let test_emit_invariant_for_unsupported_iterable () =
  let iter = { (cvar "not_iterable" ty_int) with loc = invariant_loc } in
  let node =
    {
      desc = CFor (loop_binder_named "x" ty_int, iter, cvoid);
      ty = ty_void;
      loc = invariant_loc;
    }
  in
  expect_core_error_at ~needle:"unsupported for-loop iterable" ~line:42
    (fun () -> emit_stmt_to_string node)

let test_emit_invariant_for_malformed_dict () =
  let malformed_dict_ty = TyNamed ("Dict", [ ty_string ]) in
  let iter = { (cvar "items" malformed_dict_ty) with loc = invariant_loc } in
  let node =
    {
      desc = CFor (loop_binder_named "k" ty_string, iter, cvoid);
      ty = ty_void;
      loc = invariant_loc;
    }
  in
  expect_core_error_at ~needle:"dict iteration requires Dict[K, V]" ~line:42
    (fun () -> emit_stmt_to_string node)

let test_emit_invariant_concurrent_for_requires_list () =
  let set_string_ty = TyNamed ("Set", [ ty_string ]) in
  let iter = { (cvar "items" set_string_ty) with loc = invariant_loc } in
  let task =
    {
      tc_func = "run_item";
      tc_def_id = 99;
      tc_captures = [];
      tc_return_ty = ty_string;
    }
  in
  let node =
    {
      desc =
        CConcurrentFor
          {
            cf_var = Var.named "item";
            cf_iter = iter;
            cf_body = cvar "item" ty_string;
            cf_timeout = None;
            cf_width = ConcurrentForDefault;
            cf_task_scope = synthetic_concurrent_task_scope;
            cf_task = Some task;
          };
      ty =
        TyNamed
          ( "List",
            [
              TyNamed ("Result", [ ty_string; TyNamed ("ConcurrencyError", []) ]);
            ] );
      loc = invariant_loc;
    }
  in
  expect_core_error_at ~needle:"concurrent for requires List[T]" ~line:42
    (fun () -> emit_stmt_to_string node)

(* ============================================================================
   Test suite
   ============================================================================ *)

let suite =
  [
    ( "invariant",
      [
        Alcotest.test_case "CMatchArms in expr" `Quick
          test_emit_invariant_cmatch_expr;
        Alcotest.test_case "CStringInterp" `Quick
          test_emit_invariant_cstring_interp;
        Alcotest.test_case "CMatchArms in stmt" `Quick
          test_emit_invariant_cmatch_stmt;
        Alcotest.test_case "CKUnknown call" `Quick
          test_emit_invariant_ckunknown_call;
        Alcotest.test_case "for unsupported iterable" `Quick
          test_emit_invariant_for_unsupported_iterable;
        Alcotest.test_case "for malformed Dict" `Quick
          test_emit_invariant_for_malformed_dict;
        Alcotest.test_case "unsupported task capture kind" `Quick
          test_emit_rejects_unsupported_task_capture_kind;
        Alcotest.test_case "concurrent for non-List" `Quick
          test_emit_invariant_concurrent_for_requires_list;
      ] );
    ( "lit",
      [
        Alcotest.test_case "int" `Quick test_emit_int;
        Alcotest.test_case "int_zero" `Quick test_emit_int_zero;
        Alcotest.test_case "int_neg" `Quick test_emit_int_negative;
        Alcotest.test_case "bool_true" `Quick test_emit_bool_true;
        Alcotest.test_case "bool_false" `Quick test_emit_bool_false;
        Alcotest.test_case "float" `Quick test_emit_float;
        Alcotest.test_case "char" `Quick test_emit_char;
      ] );
    ( "var_void",
      [
        Alcotest.test_case "var" `Quick test_emit_var;
        Alcotest.test_case "void" `Quick test_emit_void;
      ] );
    ( "operators",
      [
        Alcotest.test_case "add" `Quick test_emit_add;
        Alcotest.test_case "mul_nested" `Quick test_emit_mul_nested;
        Alcotest.test_case "compare" `Quick test_emit_compare;
        Alcotest.test_case "eq" `Quick test_emit_eq;
        Alcotest.test_case "float_modulo" `Quick
          test_emit_float_modulo_uses_fmod;
        Alcotest.test_case "fixed_add" `Quick test_emit_fixed_add_uses_runtime;
        Alcotest.test_case "fixed_sub" `Quick test_emit_fixed_sub_uses_runtime;
        Alcotest.test_case "fixed_mul" `Quick test_emit_fixed_mul_uses_runtime;
        Alcotest.test_case "fixed_div" `Quick test_emit_fixed_div_uses_runtime;
        Alcotest.test_case "fixed_eq" `Quick test_emit_fixed_eq_uses_runtime;
        Alcotest.test_case "fixed_ne" `Quick test_emit_fixed_ne_uses_runtime;
        Alcotest.test_case "fixed_order" `Quick
          test_emit_fixed_ordering_uses_runtime;
        Alcotest.test_case "neg" `Quick test_emit_neg;
        Alcotest.test_case "not" `Quick test_emit_not;
        Alcotest.test_case "and" `Quick test_emit_and;
        Alcotest.test_case "or" `Quick test_emit_or;
      ] );
    ( "if",
      [
        Alcotest.test_case "simple" `Quick test_emit_if_simple;
        Alcotest.test_case "nested" `Quick test_emit_if_nested;
      ] );
    ( "let",
      [
        Alcotest.test_case "simple" `Quick test_emit_let_simple;
        Alcotest.test_case "nested" `Quick test_emit_let_nested;
      ] );
    ("seq", [ Alcotest.test_case "seq" `Quick test_emit_seq ]);
    ( "resource_scope",
      [
        Alcotest.test_case "expr_normal_completion" `Quick
          test_emit_resource_scope_expr_normal_completion;
        Alcotest.test_case "stmt_normal_completion" `Quick
          test_emit_resource_scope_stmt_normal_completion;
        Alcotest.test_case "stmt_loop_local_break_cleanup_after_loop" `Quick
          test_emit_resource_scope_stmt_loop_local_break_cleanup_after_loop;
        Alcotest.test_case "stmt_cleanup_exit_break" `Quick
          test_emit_resource_cleanup_exit_stmt_break;
      ] );
    ( "call",
      [
        Alcotest.test_case "no_args" `Quick test_emit_call_no_args;
        Alcotest.test_case "with_args" `Quick test_emit_call_with_args;
        Alcotest.test_case "ctor_sized_int_stack" `Quick
          test_emit_union_constructor_sized_int_uses_stack_option;
        Alcotest.test_case "ctor_int_mask" `Quick
          test_emit_union_constructor_int_arg_clears_release_mask;
        Alcotest.test_case "ctor_int128_mask" `Quick
          test_emit_union_constructor_int128_arg_sets_release_mask;
        Alcotest.test_case "stack_option_int_some" `Quick
          test_emit_stack_option_int_some_construct;
        Alcotest.test_case "stack_option_int_none" `Quick
          test_emit_stack_option_int_none_construct;
        Alcotest.test_case "stack_option_int_boxed_storage" `Quick
          test_emit_stack_option_int_boxed_storage;
        Alcotest.test_case "stack_option_int_unboxed_storage" `Quick
          test_emit_stack_option_int_unboxed_storage;
        Alcotest.test_case "stack_option_primitive_constructs" `Quick
          test_emit_stack_option_primitive_constructs;
        Alcotest.test_case "generated_stack_option_scalar_constructs" `Quick
          test_emit_generated_stack_option_scalar_constructs;
        Alcotest.test_case "generated_stack_option_value_record_constructs"
          `Quick test_emit_generated_stack_option_value_record_constructs;
        Alcotest.test_case "generated_stack_option_value_record_none_cvar"
          `Quick test_emit_generated_stack_option_value_record_none_cvar;
        Alcotest.test_case "stack_option_int_builtin_some_call" `Quick
          test_emit_stack_option_int_builtin_some_call;
        Alcotest.test_case "stack_option_int_user_some_call" `Quick
          test_emit_stack_option_int_user_some_call;
        Alcotest.test_case "stack_option_int_user_some_call_not_ctor" `Quick
          test_emit_stack_option_int_user_some_call_without_constructor_context;
        Alcotest.test_case "stack_option_int_builtin_none_call" `Quick
          test_emit_stack_option_int_builtin_none_call;
        Alcotest.test_case "stack_result_int_bool_constructs" `Quick
          test_emit_stack_result_int_bool_constructs;
        Alcotest.test_case "stack_result_managed_construct" `Quick
          test_emit_stack_result_managed_construct;
        Alcotest.test_case "stack_result_int_builtin_ok_call" `Quick
          test_emit_stack_result_int_builtin_ok_call;
        Alcotest.test_case "box_managed_stack_result" `Quick
          test_emit_box_managed_stack_result_uses_stack_box_helper;
        Alcotest.test_case "stack_option_int_mangled_none_cvar" `Quick
          test_emit_stack_option_int_mangled_none_cvar;
        Alcotest.test_case "stack_option_int_mangled_none_let" `Quick
          test_emit_stack_option_int_mangled_none_let_uses_binding_type;
        Alcotest.test_case "stack_option_int_none_stale_ctor_registry" `Quick
          test_emit_stack_option_int_none_let_with_stale_constructor_registry;
        Alcotest.test_case "nullable_option_string_constructs" `Quick
          test_emit_nullable_option_string_constructs_as_pointer;
        Alcotest.test_case "nullable_option_string_builtin_calls" `Quick
          test_emit_nullable_option_string_builtin_calls;
        Alcotest.test_case "nullable_option_string_match" `Quick
          test_emit_nullable_option_string_type_and_match;
      ] );
    ( "field",
      [
        Alcotest.test_case "heap" `Quick test_emit_field;
        Alcotest.test_case "value_struct" `Quick test_emit_field_value_struct;
        Alcotest.test_case "c_keyword_heap" `Quick
          test_emit_field_access_c_keyword_heap;
        Alcotest.test_case "c_keyword_value" `Quick
          test_emit_field_access_c_keyword_value;
      ] );
    ( "void_let",
      [
        Alcotest.test_case "expr" `Quick test_emit_void_let_expr;
        Alcotest.test_case "stmt" `Quick test_emit_void_let_stmt;
      ] );
    ( "rc_ops",
      [
        Alcotest.test_case "dup_expr" `Quick test_emit_dup_expr;
        Alcotest.test_case "drop_expr" `Quick test_emit_drop_expr;
        Alcotest.test_case "drop_with_destructor_expr" `Quick
          test_emit_drop_with_destructor_expr;
        Alcotest.test_case "dup_stmt" `Quick test_emit_dup_stmt;
        Alcotest.test_case "drop_stmt" `Quick test_emit_drop_stmt;
        Alcotest.test_case "nested_dup" `Quick test_emit_nested_dup;
        Alcotest.test_case "managed_stack_result" `Quick
          test_emit_managed_stack_result_rc_ops;
      ] );
    ( "record_dict",
      [
        Alcotest.test_case "record" `Quick test_emit_record;
        Alcotest.test_case "record_empty" `Quick test_emit_record_empty;
        Alcotest.test_case "generic_record_float_mask" `Quick
          test_emit_generic_record_float_fields_clear_release_mask;
        Alcotest.test_case "generic_record_int_mask" `Quick
          test_emit_generic_record_int_fields_clear_release_mask;
        Alcotest.test_case "generic_record_int128_mask" `Quick
          test_emit_generic_record_int128_fields_set_release_mask;
        Alcotest.test_case "dict_generic" `Quick test_emit_dict_generic;
        Alcotest.test_case "dict_string_keys" `Quick test_emit_dict_string_keys;
        Alcotest.test_case "dict_empty" `Quick test_emit_dict_empty;
        Alcotest.test_case "dict_managed_values_release" `Quick
          test_emit_dict_managed_values_set_release;
        Alcotest.test_case "dict_new_managed_values_release" `Quick
          test_emit_dict_new_managed_values_set_release;
        Alcotest.test_case "generic_record_empty_dict_field_subst" `Quick
          test_emit_generic_record_empty_dict_field_uses_substituted_type;
        Alcotest.test_case "dict_custom_managed_keys_release" `Quick
          test_emit_dict_custom_managed_keys_set_release;
        Alcotest.test_case "set_custom_managed_elems_release" `Quick
          test_emit_set_custom_managed_elems_set_release;
      ] );
    ( "alloc",
      [
        Alcotest.test_case "tuple_primitives" `Quick test_emit_tuple_primitives;
        Alcotest.test_case "tuple_int128" `Quick test_emit_tuple_int128;
        Alcotest.test_case "tuple_tyvar" `Quick test_emit_tuple_tyvar_is_pointer;
        Alcotest.test_case "tuple_dim_op" `Quick test_emit_tuple_dim_op_raises;
        Alcotest.test_case "tuple_float" `Quick test_emit_tuple_float;
        Alcotest.test_case "tuple_owned_var_release_mask" `Quick
          test_emit_tuple_owned_var_sets_release_mask_without_retain;
        Alcotest.test_case "tuple_borrowed_unbox_release_mask" `Quick
          test_emit_tuple_borrowed_unbox_retains_and_sets_release_mask;
        Alcotest.test_case "list_primitives" `Quick test_emit_list_primitives;
        Alcotest.test_case "list_sized_primitives_packed" `Quick
          test_emit_list_sized_primitives_use_packed_layout;
        Alcotest.test_case "list_enum_packed" `Quick
          test_emit_list_enum_uses_registry_layout;
        Alcotest.test_case "list_managed_release" `Quick
          test_emit_list_managed_elements_set_release;
        Alcotest.test_case "list_float_no_release" `Quick
          test_emit_list_float_elements_do_not_set_release;
        Alcotest.test_case "list_int128_release" `Quick
          test_emit_list_int128_elements_set_release;
        Alcotest.test_case "list_option_int_inline_stack_storage" `Quick
          test_emit_list_option_int_elements_use_inline_stack_storage;
        Alcotest.test_case "list_inline_int_set_direct" `Quick
          test_emit_list_inline_int_set_uses_direct_inline_storage;
        Alcotest.test_case "list_managed_string_set_pointer_path" `Quick
          test_emit_list_managed_string_set_uses_pointer_path;
        Alcotest.test_case "list_boxed_value_retain_for_noop" `Quick
          test_emit_list_boxed_value_retain_for_is_noop;
        Alcotest.test_case "list_inline_struct_set_unknown_safe" `Quick
          test_emit_list_inline_struct_set_unknown_storage_branches_safely;
        Alcotest.test_case "list_inline_struct_get_unknown_safe" `Quick
          test_emit_list_inline_struct_get_unknown_storage_reads_inline_slot_directly;
        Alcotest.test_case "list_ensure_common_fast_paths" `Quick
          test_emit_list_ensure_intrinsics_use_common_fast_paths;
        Alcotest.test_case "list_new_managed_release" `Quick
          test_emit_list_new_managed_elements_set_release;
        Alcotest.test_case "list_reuse_alloc_managed_release" `Quick
          test_emit_list_reuse_alloc_managed_elements_set_release;
        Alcotest.test_case "set_reuse_alloc" `Quick test_emit_set_reuse_alloc;
        Alcotest.test_case "dict_reuse_alloc" `Quick test_emit_dict_reuse_alloc;
        Alcotest.test_case "list_handoff_managed_reuse_release" `Quick
          test_emit_list_handoff_managed_reuse_releases_old_slots;
        Alcotest.test_case "string_literal" `Quick test_emit_string_literal;
        Alcotest.test_case "string_escape_unicode" `Quick
          test_escape_unicode_before_hex_digit;
        Alcotest.test_case "string_literal_nul_length" `Quick
          test_escape_nul_string_literal_keeps_explicit_length;
      ] );
    ( "match_tree",
      [
        Alcotest.test_case "lit_int" `Quick test_emit_match_tree_lit_int;
        Alcotest.test_case "lit_bool" `Quick test_emit_match_tree_lit_bool;
        Alcotest.test_case "tag_no_bindings" `Quick
          test_emit_match_tree_tag_no_bindings;
        Alcotest.test_case "tag_with_bindings" `Quick
          test_emit_match_tree_tag_with_bindings;
        Alcotest.test_case "stack_option_int" `Quick
          test_emit_match_tree_stack_option_int;
        Alcotest.test_case "stack_option_float" `Quick
          test_emit_match_tree_stack_option_float;
        Alcotest.test_case "stack_result_int_bool" `Quick
          test_emit_match_tree_stack_result_int_bool;
        Alcotest.test_case "owned_builtin_scrutinee_release" `Quick
          test_emit_match_tree_owned_builtin_scrutinee_releases;
        Alcotest.test_case "borrowed_intrinsic_scrutinee_no_release" `Quick
          test_emit_match_tree_borrowed_intrinsic_scrutinee_does_not_release;
        Alcotest.test_case "list_elem_tag_cast" `Quick
          test_emit_match_tree_list_elem_tag_casts_void_ptr;
        Alcotest.test_case "list_elem_field_cast" `Quick
          test_emit_match_tree_list_elem_variant_field_casts_void_ptr;
        Alcotest.test_case "tuple_nullable_option_string" `Quick
          test_emit_match_tree_tuple_nullable_option_string;
        Alcotest.test_case "tuple_stack_option_float" `Quick
          test_emit_match_tree_tuple_stack_option_float;
        Alcotest.test_case "result_nullable_option_string" `Quick
          test_emit_match_tree_result_nullable_option_string;
        Alcotest.test_case "tag_default" `Quick test_emit_match_tree_tag_default;
        Alcotest.test_case "catchall" `Quick test_emit_match_tree_catchall;
        Alcotest.test_case "fail" `Quick test_emit_match_tree_fail;
        Alcotest.test_case "lit_stmt" `Quick test_emit_match_tree_lit_stmt;
        Alcotest.test_case "tag_stmt" `Quick test_emit_match_tree_tag_stmt;
      ] );
    ( "vector",
      [
        Alcotest.test_case "float" `Quick test_emit_vector;
        Alcotest.test_case "int" `Quick test_emit_vector_int;
        Alcotest.test_case "alias_expanded_layout" `Quick
          test_emit_vector_alias_uses_expanded_element_layout;
        Alcotest.test_case "tensor_literal_layout_payload_mismatch" `Quick
          test_emit_invariant_tensor_literal_layout_payload_mismatch;
        Alcotest.test_case "tensor_literal_layout_release_policy" `Quick
          test_emit_tensor_literal_uses_layout_release_policy;
        Alcotest.test_case "nullable_set_cow_releases_value_record_box" `Quick
          test_emit_nullable_vector_set_cow_releases_value_record_box;
        Alcotest.test_case "matrix_set_opt_releases_value_record_box" `Quick
          test_emit_matrix_set_opt_releases_value_record_box;
      ] );
    ( "match_tree_extra",
      [
        Alcotest.test_case "tree_void_expr" `Quick
          test_emit_match_tree_void_expr;
      ] );
    ( "concurrency",
      [
        Alcotest.test_case "concurrent_block" `Quick test_emit_concurrent_block;
        Alcotest.test_case "concurrent_program" `Quick
          test_emit_concurrent_program;
        Alcotest.test_case "concurrent_capture_release_mask" `Quick
          test_emit_concurrent_capture_release_mask;
        Alcotest.test_case "concurrent_stack_result_join_conversion" `Quick
          test_emit_concurrent_stack_result_join_conversion;
        Alcotest.test_case "concurrent_for_rc_result_uses_spawn_rc" `Quick
          test_emit_concurrent_for_rc_result_uses_spawn_rc;
        Alcotest.test_case "detach" `Quick test_emit_detach;
        Alcotest.test_case "detach_void_task_abi" `Quick
          test_emit_detach_void_task_abi;
        Alcotest.test_case "detach_rc_capture_void_result_task_abi" `Quick
          test_emit_detach_rc_capture_uses_void_result_task_abi;
      ] );
    ( "lambda",
      [
        Alcotest.test_case "no_captures" `Quick test_emit_lambda_no_captures;
        Alcotest.test_case "with_capture" `Quick test_emit_lambda_with_capture;
        Alcotest.test_case "body_emitted" `Quick test_emit_lambda_body_emitted;
        Alcotest.test_case "profile_body" `Quick test_emit_profile_lambda_body;
        Alcotest.test_case "capture_body" `Quick test_emit_lambda_capture_body;
        Alcotest.test_case "rc_capture_release_mask" `Quick
          test_emit_lambda_rc_capture_release_mask;
        Alcotest.test_case "ptr_capture_not_retained" `Quick
          test_emit_lambda_ptr_capture_not_retained;
      ] );
    ( "stmt",
      [
        Alcotest.test_case "void" `Quick test_stmt_void;
        Alcotest.test_case "call" `Quick test_stmt_call;
        Alcotest.test_case "let" `Quick test_stmt_let;
        Alcotest.test_case "seq" `Quick test_stmt_seq;
        Alcotest.test_case "if" `Quick test_stmt_if;
        Alcotest.test_case "if_else" `Quick test_stmt_if_else;
        Alcotest.test_case "while" `Quick test_stmt_while;
        Alcotest.test_case "break_continue" `Quick test_stmt_break_continue;
        Alcotest.test_case "assign" `Quick test_stmt_assign;
        Alcotest.test_case "discard_managed_var" `Quick
          test_stmt_discard_managed_var_releases;
        Alcotest.test_case "for_range" `Quick test_stmt_for_range;
        Alcotest.test_case "for_list" `Quick test_stmt_for_list;
        Alcotest.test_case "for_string" `Quick test_stmt_for_string;
        Alcotest.test_case "for_dict_tuple_binder" `Quick
          test_stmt_for_dict_tuple_binder;
        Alcotest.test_case "for_channel" `Quick test_stmt_for_channel;
        Alcotest.test_case "nested_if_while" `Quick test_stmt_nested_if_in_while;
        Alcotest.test_case "let_seq_body" `Quick test_stmt_let_with_seq_body;
      ] );
    ( "integration",
      [
        Alcotest.test_case "arith" `Quick test_integration_arith;
        Alcotest.test_case "perceus_to_emit" `Quick
          test_integration_perceus_emit;
        Alcotest.test_case "primitive_rc_ops_are_noops" `Quick
          test_emit_primitive_rc_ops_are_noops;
      ] );
    ( "e2e",
      [
        Alcotest.test_case "arith" `Quick test_e2e_arith;
        Alcotest.test_case "nested_arith" `Quick test_e2e_nested_arith;
        Alcotest.test_case "if_true" `Quick test_e2e_if_true;
        Alcotest.test_case "if_false" `Quick test_e2e_if_false;
        Alcotest.test_case "comparison" `Quick test_e2e_comparison;
        Alcotest.test_case "let" `Quick test_e2e_let;
        Alcotest.test_case "match_lit" `Quick test_e2e_match_lit_switch;
        Alcotest.test_case "match_default" `Quick test_e2e_match_default;
        Alcotest.test_case "match_catchall" `Quick
          test_e2e_match_catchall_binding;
      ] );
    ( "union_type",
      [
        Alcotest.test_case "enum" `Quick test_emit_enum_type;
        Alcotest.test_case "union_no_rc" `Quick test_emit_union_no_rc;
        Alcotest.test_case "union_with_rc" `Quick test_emit_union_with_rc;
        Alcotest.test_case "union_int128_boxed_payload_destroy" `Quick
          test_emit_union_with_int128_boxed_payload_has_destructor;
        Alcotest.test_case "union_obeys_registered_arc_only_policy" `Quick
          test_emit_union_obeys_registered_arc_only_policy;
        Alcotest.test_case "union_singleton" `Quick
          test_emit_union_empty_singleton;
        Alcotest.test_case "union_forward" `Quick test_emit_union_forward_decl;
      ] );
    ( "heap_record",
      [
        Alcotest.test_case "no_rc" `Quick test_emit_heap_record_no_rc;
        Alcotest.test_case "with_rc" `Quick test_emit_heap_record_with_rc;
        Alcotest.test_case "obeys_registered_generated_policy" `Quick
          test_emit_heap_record_obeys_registered_generated_policy;
        Alcotest.test_case "forward_decl" `Quick
          test_emit_heap_record_forward_decl;
      ] );
    ( "global_impl",
      [
        Alcotest.test_case "global_const" `Quick test_emit_global_var_const;
        Alcotest.test_case "global_non_const" `Quick
          test_emit_global_var_non_const;
        Alcotest.test_case "global_string_literal_deferred" `Quick
          test_emit_global_var_string_literal_deferred;
        Alcotest.test_case "impl_methods" `Quick test_emit_impl_methods;
      ] );
    ( "pipeline",
      [
        Alcotest.test_case "simple_ast_to_c" `Quick test_core_pipeline_simple;
        Alcotest.test_case "profile_flag" `Quick test_core_pipeline_profile_flag;
      ] );
    ( "decl",
      [
        Alcotest.test_case "simple_function" `Quick test_emit_simple_function;
        Alcotest.test_case "profile_named_function" `Quick
          test_emit_profile_named_function;
        Alcotest.test_case "profile_main_report" `Quick
          test_emit_profile_main_enables_report;
        Alcotest.test_case "function_no_params" `Quick
          test_emit_function_no_params;
        Alcotest.test_case "function_posix_collision" `Quick
          test_emit_function_name_posix_collision;
        Alcotest.test_case "foreign_skipped" `Quick
          test_emit_foreign_func_skipped;
        Alcotest.test_case "value_record" `Quick test_emit_value_record;
        Alcotest.test_case "value_record_sig" `Quick
          test_emit_value_record_used_in_function_sig;
        Alcotest.test_case "enum_type_sig" `Quick
          test_emit_enum_type_used_in_function_sig;
        Alcotest.test_case "heap_record_value_field" `Quick
          test_emit_heap_record_with_value_field;
        Alcotest.test_case "context_reset_clears_registry" `Quick
          test_emit_context_reset_clears_registry;
        Alcotest.test_case "main_releases_argv_list" `Quick
          test_emit_main_releases_argv_list;
      ] );
    ( "a4_invariants",
      [
        Alcotest.test_case "every call has decl" `Quick
          test_a4_2_every_call_has_decl;
        Alcotest.test_case "trait impl methods mangled" `Quick
          test_a4_3_trait_impl_methods_mangled;
        Alcotest.test_case "ufcs mangling" `Quick test_a4_4_ufcs_mangling;
      ] );
    ( "e2e_program",
      [
        Alcotest.test_case "single_function" `Quick test_e2e_program_function;
        Alcotest.test_case "two_functions" `Quick test_e2e_program_two_functions;
        Alcotest.test_case "value_record" `Quick
          test_e2e_program_with_value_record;
        Alcotest.test_case "match_in_func" `Quick test_e2e_program_match_in_func;
      ] );
  ]
