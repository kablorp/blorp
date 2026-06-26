(** Tests for Core_perceus — Phase 2.1 starter pass.

    Covers:
    - [is_managed_type] classification
    - [count_uses] correctness (including shadow cases)
    - [is_linear] branch detection
    - [insert_drops_expr_for_test] wraps unused managed bindings, preserves
      everything else
    - The program walker reaches function bodies, impl methods, etc. *)

open Blorp.Ast
open Blorp.Core

let loc =
  { line = 1; column = 1; end_line = 1; end_column = 1; loc_file = None }

let ty_int = TyNamed ("Int", [])
let ty_bool = TyNamed ("Bool", [])
let ty_float = TyNamed ("Float", [])
let ty_string = TyNamed ("String", [])
let ty_void = TyNamed ("Void", [])
let ty_ptr = TyNamed ("Ptr", [])
let ty_fixed = TyNamed ("Fixed", [])
let ty_channel_int = TyNamed ("Channel", [ ty_int ])
let ty_channel_string = TyNamed ("Channel", [ ty_string ])
let ty_string_slice = TyNamed ("StringSlice", [])
let ty_memstats = TyNamed ("MemStats", [])
let ty_scheduler_stats = TyNamed ("SchedulerStats", [])
let ty_list_int = TyNamed ("List", [ ty_int ])
let ty_list_string = TyNamed ("List", [ ty_string ])
let ty_stream_int = TyNamed ("Stream", [ ty_int ])
let ty_dict_string_string = TyNamed ("Dict", [ ty_string; ty_string ])
let ty_dict_int_int = TyNamed ("Dict", [ ty_int; ty_int ])
let ty_set_string = TyNamed ("Set", [ ty_string ])
let ty_set_int = TyNamed ("Set", [ ty_int ])
let ty_set_list_int = TyNamed ("Set", [ ty_list_int ])
let ty_send_attempt = TyNamed ("SendAttempt", [])
let ty_opt_int = TyNamed ("Option", [ ty_int ])
let ty_opt_string = TyNamed ("Option", [ ty_string ])
let ty_opt_list_int = TyNamed ("Option", [ ty_list_int ])
let ty_tensor_float = TyNamed ("Tensor", [ ty_float ])
let ty_vector_int = TyNamed ("Vector", [ ty_int; TyConstInt 3 ])
let tparams names = List.map (fun name -> make_type_param name []) names
let ty_pair_lists = TyTuple [ ty_list_int; ty_list_int ]
let ty_pair_dicts = TyTuple [ ty_dict_string_string; ty_dict_string_string ]
let ty_bool_fn = TyFunc { params = []; return = ty_bool; is_pure = false }
let str_flags = { sf_multiline = false; sf_raw = false }
let mk d t = { desc = d; ty = t; loc }
let cint n = mk (CLit (LitInt (Int64.of_int n))) ty_int
let cbool b = mk (CLit (LitBool b)) ty_bool
let cstr s = mk (CLit (LitString (s, str_flags))) ty_string
let cvoid = mk CVoid ty_void
let cvar n t = mk (CVar (Var.named n)) t
let intrinsic name args ty = mk (CCall (CKIntrinsic name, cvoid, args)) ty
let builtin name args ty = mk (CCall (CKBuiltin name, cvoid, args)) ty

let clist elems =
  CList { ll_layout = list_pointer_storage (); ll_elems = elems }

let bind_named ?(mut = false) name ty rhs : binding =
  { bind_var = Var.named name; bind_mut = mut; bind_ty = ty; bind_rhs = rhs }

let insert_drops_expr_for_test e =
  Blorp.Core_perceus.insert_drops_expr_with_env
    (Blorp.Core_perceus.empty_env ())
    e

let func_ty params return = TyFunc { params; return; is_pure = true }

let mk_func ?(def_id = 0) ?(type_params = []) ?(params = []) name return_ty body
    : core_func =
  {
    cf_name = name;
    cf_module = None;
    cf_type_params = tparams type_params;
    cf_params = params;
    cf_return_ty = return_ty;
    cf_body = Some body;
    cf_is_pure = true;
    cf_kind = CFUser;
    cf_def_id = def_id;
  }

let param name ty = { cp_name = Var.named name; cp_ty = ty; cp_loc = loc }

let rec count_drops_for name e =
  let here =
    match e.desc with CDrop (v, _, _) when v.vname = name -> 1 | _ -> 0
  in
  fold_immediate_children
    (fun acc child -> acc + count_drops_for name child)
    here e

let rec count_dups_for name e =
  let here =
    match e.desc with CDup (v, _, _) when v.vname = name -> 1 | _ -> 0
  in
  fold_immediate_children
    (fun acc child -> acc + count_dups_for name child)
    here e

let rec has_drop_before_assign_for name e =
  match e.desc with
  | CSeq
      ( { desc = CDrop ({ vname = drop_name; _ }, _, _); _ },
        { desc = CAssign ({ vname = assign_name; _ }, _); _ } )
    when drop_name = name && assign_name = name ->
      true
  | _ ->
      fold_immediate_children
        (fun found child -> found || has_drop_before_assign_for name child)
        false e

(* ============================================================================
   is_managed_type
   ============================================================================ *)

let empty_env () = Blorp.Core_perceus.empty_env ()

let expect_managed_type_info label env name expected_kind expected_destructor =
  let open Blorp.Codegen_types in
  match Blorp.Core_perceus.managed_type_info env name with
  | Some { managed_kind; destructor } ->
      Alcotest.(check bool) (label ^ " kind") true (managed_kind = expected_kind);
      Alcotest.(check bool)
        (label ^ " destructor") true
        (destructor = expected_destructor)
  | None -> Alcotest.failf "%s was not registered as a managed type" name

let test_managed_string () =
  Alcotest.(check bool)
    "String managed" true
    (Blorp.Core_perceus.is_managed_type (empty_env ()) ty_string)

let test_managed_list () =
  Alcotest.(check bool)
    "List managed" true
    (Blorp.Core_perceus.is_managed_type (empty_env ()) ty_list_int)

let test_managed_memstats () =
  Alcotest.(check bool)
    "MemStats managed" true
    (Blorp.Core_perceus.is_managed_type (empty_env ()) ty_memstats)

let test_managed_scheduler_stats () =
  Alcotest.(check bool)
    "SchedulerStats managed" true
    (Blorp.Core_perceus.is_managed_type (empty_env ()) ty_scheduler_stats)

let test_managed_fixed () =
  Alcotest.(check bool)
    "Fixed managed" true
    (Blorp.Core_perceus.is_managed_type (empty_env ()) ty_fixed)

let test_managed_channel () =
  Alcotest.(check bool)
    "Channel managed" true
    (Blorp.Core_perceus.is_managed_type (empty_env ()) ty_channel_int)

let test_managed_tensor_without_static_dims () =
  Alcotest.(check bool)
    "array managed" true
    (Blorp.Core_perceus.is_managed_type (empty_env ()) ty_tensor_float)

let test_managed_string_slice () =
  Alcotest.(check bool)
    "StringSlice managed" true
    (Blorp.Core_perceus.is_managed_type (empty_env ()) ty_string_slice)

let test_not_managed_int () =
  Alcotest.(check bool)
    "Int not managed" false
    (Blorp.Core_perceus.is_managed_type (empty_env ()) ty_int)

let test_not_managed_bool () =
  Alcotest.(check bool)
    "Bool not managed" false
    (Blorp.Core_perceus.is_managed_type (empty_env ()) ty_bool)

let test_dimension_value_refinements_are_not_managed () =
  let env = empty_env () in
  let cases =
    [
      ("concrete dimension", TyConstInt 3);
      ("symbolic dimension", TyVar "#N");
      ("dimension arithmetic", TyDimOp (DimAdd, TyVar "#N", TyConstInt 1));
    ]
  in
  List.iter
    (fun (name, ty) ->
      Alcotest.(check bool)
        name false
        (Blorp.Core_perceus.is_managed_type env ty))
    cases

let test_variadic_dimension_pack_still_invalid_as_value () =
  Test_helpers.check_core_error_raises
    ~phase:(Blorp.Core_error.Stage Blorp.Core_stage.Perceus)
    ~msg_contains:
      "variadic dimension pack reached ownership classifier in value position"
    (fun () ->
      ignore
        (Blorp.Core_perceus.is_managed_type (empty_env ()) (TyVarDims "#Ds")))

let test_not_managed_ptr () =
  Alcotest.(check bool)
    "Ptr not managed" false
    (Blorp.Core_perceus.is_managed_type (empty_env ()) ty_ptr)

let test_managed_func () =
  let fty = TyFunc { params = [ ty_int ]; return = ty_int; is_pure = true } in
  Alcotest.(check bool)
    "func type managed (closures)" true
    (Blorp.Core_perceus.is_managed_type (empty_env ()) fty)

let test_managed_tuple () =
  let tty = TyTuple [ ty_int; ty_int ] in
  Alcotest.(check bool)
    "tuple managed" true
    (Blorp.Core_perceus.is_managed_type (empty_env ()) tty)

(** Regression: a user-declared heap record [record Point { x: Int; y: Int }]
    should be recognized as managed by looking up the name in the env built
    from the program's declarations. *)
let test_managed_user_record () =
  let record_decl : record_decl =
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
  let prog =
    [ { cd_desc = CDRecord record_decl; cd_loc = loc; cd_doc = None } ]
  in
  let env = Blorp.Core_perceus.build_type_env prog in
  Alcotest.(check bool)
    "user record managed" true
    (Blorp.Core_perceus.is_managed_type env (TyNamed ("Point", [])))

(** Perceus should share the codegen ownership registry, not a reduced
    "managed name" table, so source heap records always carry a destructor
    policy before RC insertion consults their layout. *)
let test_user_record_destructor_policy_registered () =
  let field name field_type =
    { field_name = name; field_type; field_loc = loc }
  in
  let record name fields : record_decl =
    {
      record_name = name;
      record_type_params = [];
      record_fields = fields;
      record_is_value = false;
      record_is_builtin = false;
    }
  in
  let decl r = { cd_desc = CDRecord r; cd_loc = loc; cd_doc = None } in
  let env =
    Blorp.Core_perceus.build_type_env
      [
        decl (record "Point" [ field "x" ty_int ]);
        decl (record "Named" [ field "name" ty_string ]);
      ]
  in
  let open Blorp.Codegen_types in
  expect_managed_type_info "Point" env "Point" ManagedHeapRecord ArcReleaseOnly;
  expect_managed_type_info "Named" env "Named" ManagedHeapRecord
    (GeneratedDestructor "Named_destroy")

(** Regression: a value struct [struct Point ...] (record_is_value=true)
    is stack-allocated and NOT managed. *)
let test_not_managed_value_struct () =
  let record_decl : record_decl =
    {
      record_name = "Vec2";
      record_type_params = [];
      record_fields =
        [
          { field_name = "x"; field_type = ty_int; field_loc = loc };
          { field_name = "y"; field_type = ty_int; field_loc = loc };
        ];
      record_is_value = true;
      (* value struct — stack *)
      record_is_builtin = false;
    }
  in
  let prog =
    [ { cd_desc = CDRecord record_decl; cd_loc = loc; cd_doc = None } ]
  in
  let env = Blorp.Core_perceus.build_type_env prog in
  Alcotest.(check bool)
    "value struct not managed" false
    (Blorp.Core_perceus.is_managed_type env (TyNamed ("Vec2", [])))

(** Regression: non-enum ADT [type Color = Red | Green(Int) | Blue] is
    refcounted (constructor arguments may be heap). *)
let test_managed_union () =
  let type_decl : type_decl =
    {
      type_name = "Shape";
      type_params = [];
      type_variants =
        [
          {
            variant_name = "Circle";
            variant_fields = [ ty_int ];
            variant_tag = 0;
            variant_loc = loc;
            variant_def_id = None;
          };
          {
            variant_name = "Square";
            variant_fields = [ ty_int ];
            variant_tag = 1;
            variant_loc = loc;
            variant_def_id = None;
          };
        ];
      type_is_enum = false;
      type_is_builtin = false;
      type_is_resource = false;
      type_resource_cleanup = None;
    }
  in
  let prog = [ { cd_desc = CDType type_decl; cd_loc = loc; cd_doc = None } ] in
  let env = Blorp.Core_perceus.build_type_env prog in
  Alcotest.(check bool)
    "union managed" true
    (Blorp.Core_perceus.is_managed_type env (TyNamed ("Shape", [])))

(** Union ownership policy depends on boxed payload release requirements.
    Perceus should observe the same refined policy as the emitter. *)
let test_user_union_destructor_policy_registered () =
  let variant name fields =
    {
      variant_name = name;
      variant_fields = fields;
      variant_tag = 0;
      variant_loc = loc;
      variant_def_id = None;
    }
  in
  let union name fields : type_decl =
    {
      type_name = name;
      type_params = [];
      type_variants = [ variant "Value" fields ];
      type_is_enum = false;
      type_is_builtin = false;
      type_is_resource = false;
      type_resource_cleanup = None;
    }
  in
  let decl t = { cd_desc = CDType t; cd_loc = loc; cd_doc = None } in
  let env =
    Blorp.Core_perceus.build_type_env
      [
        decl (union "FloatBox" [ ty_float ]);
        decl (union "Wide" [ TyNamed ("Int128", []) ]);
      ]
  in
  let open Blorp.Codegen_types in
  expect_managed_type_info "FloatBox" env "FloatBox" ManagedUnion ArcReleaseOnly;
  expect_managed_type_info "Wide" env "Wide" ManagedUnion ArcReleaseOnly

(** Regression: [enum Color { Red; Green; Blue }] is integer-valued
    and NOT managed. *)
let test_not_managed_enum () =
  let type_decl : type_decl =
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
  let prog = [ { cd_desc = CDType type_decl; cd_loc = loc; cd_doc = None } ] in
  let env = Blorp.Core_perceus.build_type_env prog in
  Alcotest.(check bool)
    "enum not managed" false
    (Blorp.Core_perceus.is_managed_type env (TyNamed ("Color", [])))

let test_unknown_named_type_raises () =
  Test_helpers.check_core_error_raises
    ~phase:(Blorp.Core_error.Stage Blorp.Core_stage.Perceus)
    ~msg_contains:"ownership classifier has no layout for type Mystery"
    (fun () ->
      ignore
        (Blorp.Core_perceus.is_managed_type (empty_env ())
           (TyNamed ("Mystery", []))))

let test_alias_layout_uses_registry () =
  let alias name target =
    {
      alias_name = name;
      alias_type_params = [];
      alias_target = target;
      alias_is_opaque = false;
    }
  in
  let decl a = { cd_desc = CDTypeAlias a; cd_loc = loc; cd_doc = None } in
  let env =
    Blorp.Core_perceus.build_type_env
      [ decl (alias "Text" ty_string); decl (alias "Count" ty_int) ]
  in
  Alcotest.(check bool)
    "Text alias managed" true
    (Blorp.Core_perceus.is_managed_type env (TyNamed ("Text", [])));
  Alcotest.(check bool)
    "Count alias unmanaged" false
    (Blorp.Core_perceus.is_managed_type env (TyNamed ("Count", [])))

let test_program_generic_multi_char_type_param_has_layout () =
  let ty_t = TyNamed ("T", []) in
  let ty_acc = TyNamed ("Acc", []) in
  let f =
    mk_func ~type_params:[ "T"; "Acc" ]
      ~params:
        [ param "items" (TyNamed ("List", [ ty_t ])); param "init" ty_acc ]
      "fold_like" ty_acc (cvar "init" ty_acc)
  in
  let prog = [ { cd_desc = CDFunc f; cd_loc = loc; cd_doc = None } ] in
  ignore (Blorp.Core_perceus.insert_drops_program prog)

(* ============================================================================
   count_uses
   ============================================================================ *)

let test_count_uses_zero () =
  let body = cint 42 in
  Alcotest.(check int) "no uses" 0 (Blorp.Core_perceus.count_uses "x" body)

let test_count_uses_one () =
  let body = cvar "x" ty_int in
  Alcotest.(check int) "one use" 1 (Blorp.Core_perceus.count_uses "x" body)

let test_count_uses_binary () =
  (* x + x → 2 uses *)
  let body = mk (CBin (Add, cvar "x" ty_int, cvar "x" ty_int)) ty_int in
  Alcotest.(check int)
    "two uses in binary" 2
    (Blorp.Core_perceus.count_uses "x" body)

let test_count_uses_nested () =
  (* f(x, g(x, x)) → 3 uses *)
  let fty =
    TyFunc { params = [ ty_int; ty_int ]; return = ty_int; is_pure = true }
  in
  let g_call =
    mk
      (CCall (CKUnknown, cvar "g" fty, [ cvar "x" ty_int; cvar "x" ty_int ]))
      ty_int
  in
  let f_call =
    mk (CCall (CKUnknown, cvar "f" fty, [ cvar "x" ty_int; g_call ])) ty_int
  in
  Alcotest.(check int)
    "three uses nested" 3
    (Blorp.Core_perceus.count_uses "x" f_call)

let test_count_uses_shadowing () =
  (* let x = 10 in x + 1 — inner x is the binding, the `x` in body refers to it,
     but count_uses looking for OUTER "x" should return 0 (shadowed by inner let). *)
  let inner_rhs = cint 10 in
  let inner_body = mk (CBin (Add, cvar "x" ty_int, cint 1)) ty_int in
  let inner = mk (CLet (bind_named "x" ty_int inner_rhs, inner_body)) ty_int in
  Alcotest.(check int)
    "shadowed binding hides outer name" 0
    (Blorp.Core_perceus.count_uses "x" inner)

let test_count_uses_in_if () =
  (* if c then x else x + 1 — only one branch runs, so max is 1 *)
  let then_e = cvar "x" ty_int in
  let else_e = mk (CBin (Add, cvar "x" ty_int, cint 1)) ty_int in
  let e = mk (CIf (cvar "c" ty_bool, then_e, else_e)) ty_int in
  Alcotest.(check int)
    "max across if branches" 1
    (Blorp.Core_perceus.count_uses "x" e)

(** Regression: [count_uses] must take MAX across [CIf] branches, not
    sum — only one branch runs. Previously this returned the sum. *)
let test_count_uses_if_asymmetric () =
  (* if c then (x + x) else x — then=2, else=1, max=2 *)
  let then_e = mk (CBin (Add, cvar "x" ty_int, cvar "x" ty_int)) ty_int in
  let else_e = cvar "x" ty_int in
  let e = mk (CIf (cvar "c" ty_bool, then_e, else_e)) ty_int in
  Alcotest.(check int)
    "asymmetric if takes max (2, not 3)" 2
    (Blorp.Core_perceus.count_uses "x" e)

(** Regression: nested branches in a scrutinee propagate max upward. *)
let test_count_uses_nested_branches () =
  (* if (if c1 then x else x+x) then 0 else 1
     outer condition uses max(1, 2) = 2; branches use 0. Total = 2. *)
  let inner_t = cvar "x" ty_int in
  let inner_e = mk (CBin (Add, cvar "x" ty_int, cvar "x" ty_int)) ty_int in
  let inner_if = mk (CIf (cvar "c1" ty_bool, inner_t, inner_e)) ty_int in
  let outer = mk (CIf (inner_if, cint 0, cint 1)) ty_int in
  Alcotest.(check int)
    "nested branches use max" 2
    (Blorp.Core_perceus.count_uses "x" outer)

(** Regression: [count_uses] must take MAX across [CMatchArms] arms. *)
let test_count_uses_in_match () =
  (* match y { A -> x + x | B -> x } — max(2, 1) = 2 *)
  let arm_a_body = mk (CBin (Add, cvar "x" ty_int, cvar "x" ty_int)) ty_int in
  let arm_b_body = cvar "x" ty_int in
  let arms =
    [
      (PatConstructor ("A", []), arm_a_body);
      (PatConstructor ("B", []), arm_b_body);
    ]
  in
  let e = mk (CMatchArms (cvar "y" ty_int, arms)) ty_int in
  Alcotest.(check int)
    "match arms take max" 2
    (Blorp.Core_perceus.count_uses "x" e)

(** Regression: pattern binding that shadows the outer name → 0 uses. *)
let test_count_uses_pattern_shadow () =
  (* match opt { Some(s) -> s | None -> 0 } — the inner s shadows any
     outer s. If counting the OUTER "s", both arms should return 0. *)
  let arms =
    [
      (PatConstructor ("Some", [ PatVar "s" ]), cvar "s" ty_string);
      (PatConstructor ("None", []), cint 0);
    ]
  in
  let e = mk (CMatchArms (cvar "opt" ty_opt_int, arms)) ty_int in
  Alcotest.(check int)
    "pattern shadow hides outer name" 0
    (Blorp.Core_perceus.count_uses "s" e)

(** Regression: [CAssign] LHS is a write, not a consuming read. Should
    not count as a use of the name. *)
let test_count_uses_assign_lhs () =
  (* s = f(x) — LHS "s" is written, not read. Only rhs counts. *)
  let fty = TyFunc { params = [ ty_int ]; return = ty_int; is_pure = false } in
  let rhs = mk (CCall (CKUnknown, cvar "f" fty, [ cvar "x" ty_int ])) ty_int in
  let e = mk (CAssign (Var.named "s", rhs)) ty_void in
  Alcotest.(check int)
    "assign LHS not counted" 0
    (Blorp.Core_perceus.count_uses "s" e);
  Alcotest.(check int)
    "assign rhs counted" 1
    (Blorp.Core_perceus.count_uses "x" e)

(** Regression: [CLambda] captures a free var ONCE at closure construction,
    regardless of how many times the body references it. *)
let test_count_uses_lambda_capture () =
  (* fn = func(y): s + s + y — s is captured once, not twice *)
  let body =
    mk
      (CBin
         ( Add,
           mk (CBin (Add, cvar "s" ty_int, cvar "s" ty_int)) ty_int,
           cvar "y" ty_int ))
      ty_int
  in
  let lam =
    {
      lam_params = [ (Var.named "y", ty_int) ];
      lam_body = body;
      lam_return_ty = ty_int;
      lam_is_pure = true;
    }
  in
  let fty = TyFunc { params = [ ty_int ]; return = ty_int; is_pure = true } in
  let e = mk (CLambda lam) fty in
  Alcotest.(check int)
    "lambda capture counts as 1" 1
    (Blorp.Core_perceus.count_uses "s" e);
  Alcotest.(check int)
    "lambda param not captured" 0
    (Blorp.Core_perceus.count_uses "y" e)

(* ============================================================================
   is_linear
   ============================================================================ *)

let test_linear_literal () =
  Alcotest.(check bool)
    "literal is linear" true
    (Blorp.Core_perceus.is_linear (cint 42))

let test_linear_binary () =
  let e = mk (CBin (Add, cint 1, cint 2)) ty_int in
  Alcotest.(check bool) "binary is linear" true (Blorp.Core_perceus.is_linear e)

let test_linear_call () =
  let fty = TyFunc { params = []; return = ty_int; is_pure = true } in
  let e = mk (CCall (CKUnknown, cvar "f" fty, [])) ty_int in
  Alcotest.(check bool) "call is linear" true (Blorp.Core_perceus.is_linear e)

let test_not_linear_if () =
  let e = mk (CIf (cbool true, cint 1, cint 0)) ty_int in
  Alcotest.(check bool)
    "if is NOT linear" false
    (Blorp.Core_perceus.is_linear e)

let test_not_linear_while () =
  let e = mk (CWhile (cbool true, cvoid)) ty_void in
  Alcotest.(check bool)
    "while is NOT linear" false
    (Blorp.Core_perceus.is_linear e)

let test_not_linear_match () =
  let arms = [ (PatWildcard, cint 0) ] in
  let e = mk (CMatchArms (cvar "x" ty_int, arms)) ty_int in
  Alcotest.(check bool)
    "match is NOT linear" false
    (Blorp.Core_perceus.is_linear e)

let test_not_linear_nested () =
  (* A linear wrapper around a non-linear expression is non-linear *)
  let if_e = mk (CIf (cbool true, cint 1, cint 0)) ty_int in
  let e = mk (CBin (Add, if_e, cint 1)) ty_int in
  Alcotest.(check bool)
    "nested if not linear" false
    (Blorp.Core_perceus.is_linear e)

(* ============================================================================
   insert_drops_expr_for_test — the transformation
   ============================================================================ *)

let test_insert_drops_unused_string () =
  (* let s: String = "hi" in 42 — s is unused, should get a drop *)
  let bind = bind_named "s" ty_string (cstr "hi") in
  let body = cint 42 in
  let e = mk (CLet (bind, body)) ty_int in
  let transformed = insert_drops_expr_for_test e in
  match transformed.desc with
  | CLet
      ( _,
        {
          desc = CDrop ({ vname = "s"; _ }, _, { desc = CLit (LitInt 42L); _ });
          _;
        } ) ->
      ()
  | _ ->
      Alcotest.failf "expected CLet(_, CDrop(s, 42)), got %s"
        (pp_to_string transformed)

let test_insert_drops_unused_int_unchanged () =
  (* Int is not managed — no drop needed *)
  let bind = bind_named "n" ty_int (cint 10) in
  let body = cint 42 in
  let e = mk (CLet (bind, body)) ty_int in
  let transformed = insert_drops_expr_for_test e in
  match transformed.desc with
  | CLet (_, { desc = CLit (LitInt 42L); _ }) -> ()
  | _ -> Alcotest.fail "expected unchanged let(Int)"

let test_insert_drops_used_string_unchanged () =
  (* let s = "hi" in s — s is used once, no drop added (would double-drop) *)
  let bind = bind_named "s" ty_string (cstr "hi") in
  let body = cvar "s" ty_string in
  let e = mk (CLet (bind, body)) ty_string in
  let transformed = insert_drops_expr_for_test e in
  match transformed.desc with
  | CLet (_, { desc = CVar { vname = "s"; _ }; _ }) -> ()
  | _ -> Alcotest.fail "expected unchanged let(used String)"

let test_insert_drops_branching_unchanged () =
  (* let s = "hi" in if c then 1 else 2 — Phase 2.3 handles this:
     both branches have 0 uses, so [s] is entirely unused in the if.
     A [CDrop] is inserted before the whole if. *)
  let bind = bind_named "s" ty_string (cstr "hi") in
  let body = mk (CIf (cvar "c" ty_bool, cint 1, cint 2)) ty_int in
  let e = mk (CLet (bind, body)) ty_int in
  let transformed = insert_drops_expr_for_test e in
  match transformed.desc with
  | CLet (_, { desc = CDrop ({ vname = "s"; _ }, _, { desc = CIf _; _ }); _ })
    ->
      ()
  | _ ->
      Alcotest.failf "expected CLet(_, CDrop(s, CIf(...))), got:\n%s"
        (pp_to_string_indented transformed)

(** A linear body with 2 uses of the binding → 1 [CDup] prepended so
    refcount balance is [1 (bind) + 1 (dup) = 2 uses consumed]. *)
let test_insert_drops_two_uses () =
  let fty =
    TyFunc
      { params = [ ty_string; ty_string ]; return = ty_int; is_pure = true }
  in
  (* let s: String = "hi" in f(s, s) *)
  let bind = bind_named "s" ty_string (cstr "hi") in
  let body =
    mk
      (CCall
         (CKUnknown, cvar "f" fty, [ cvar "s" ty_string; cvar "s" ty_string ]))
      ty_int
  in
  let e = mk (CLet (bind, body)) ty_int in
  let transformed = insert_drops_expr_for_test e in
  match transformed.desc with
  | CLet (_, { desc = CDup ({ vname = "s"; _ }, _, inner); _ }) -> (
      (* Inside the CDup should be the original call, no further dups *)
      match inner.desc with
      | CCall _ -> ()
      | _ ->
          Alcotest.failf "expected CCall inside CDup, got %s"
            (pp_to_string inner))
  | _ ->
      Alcotest.failf "expected CLet(_, CDup(s, _)), got:\n%s"
        (pp_to_string_indented transformed)

(** 3 uses → 2 nested [CDup]s. *)
let test_insert_drops_three_uses () =
  let fty =
    TyFunc
      {
        params = [ ty_string; ty_string; ty_string ];
        return = ty_int;
        is_pure = true;
      }
  in
  let bind = bind_named "s" ty_string (cstr "hi") in
  let body =
    mk
      (CCall
         ( CKUnknown,
           cvar "f" fty,
           [ cvar "s" ty_string; cvar "s" ty_string; cvar "s" ty_string ] ))
      ty_int
  in
  let e = mk (CLet (bind, body)) ty_int in
  let transformed = insert_drops_expr_for_test e in
  (* Expected: CLet(s, CDup(s, CDup(s, f(s,s,s)))) *)
  match transformed.desc with
  | CLet
      ( _,
        {
          desc =
            CDup
              ( { vname = "s"; _ },
                _,
                {
                  desc = CDup ({ vname = "s"; _ }, _, { desc = CCall _; _ });
                  _;
                } );
          _;
        } ) ->
      ()
  | _ ->
      Alcotest.failf "expected 2 nested CDups, got:\n%s"
        (pp_to_string_indented transformed)

(** A borrowed intrinsic argument does not consume the list owner, so Perceus
    must drop after the call. A pre-call drop would invalidate the borrow. *)
let test_insert_drops_borrowed_intrinsic_drops_after () =
  let bind = bind_named "xs" ty_list_int (mk (clist []) ty_list_int) in
  let body = intrinsic "list_len" [ cvar "xs" ty_list_int ] ty_int in
  let e = mk (CLet (bind, body)) ty_int in
  let transformed = insert_drops_expr_for_test e in
  match transformed.desc with
  | CLet
      ( _,
        {
          desc =
            CLet
              ( {
                  bind_var = { vname = "__cdrop_xs"; _ };
                  bind_rhs =
                    {
                      desc =
                        CCall
                          ( CKIntrinsic "list_len",
                            _,
                            [ { desc = CVar { vname = "xs"; _ }; _ } ] );
                      _;
                    };
                  _;
                },
                {
                  desc =
                    CDrop
                      ( { vname = "xs"; _ },
                        _,
                        { desc = CVar { vname = "__cdrop_xs"; _ }; _ } );
                  _;
                } );
          _;
        } ) ->
      ()
  | _ ->
      Alcotest.failf "expected borrowed intrinsic to drop after call, got:\n%s"
        (pp_to_string_indented transformed)

let test_insert_drops_string_eq_borrows_in_nested_branch () =
  let bind = bind_named "s" ty_string (cstr "hi") in
  let cond =
    builtin "blorp_string_eq" [ cvar "s" ty_string; cstr "hi" ] ty_bool
  in
  let branch = mk (CIf (cond, cint 0, cint 1)) ty_int in
  let body = mk (CLet (bind_named "n" ty_int (cint 0), branch)) ty_int in
  let e = mk (CLet (bind, body)) ty_int in
  let transformed = insert_drops_expr_for_test e in
  Alcotest.(check int)
    "borrowed string eq gets one final drop" 1
    (count_drops_for "s" transformed)

let test_insert_drops_string_runtime_builtin_borrows_arg () =
  let bind = bind_named "s" ty_string (cstr "hello") in
  let body = builtin "blorp_base64_encode" [ cvar "s" ty_string ] ty_string in
  let e = mk (CLet (bind, body)) ty_string in
  let transformed = insert_drops_expr_for_test e in
  Alcotest.(check int)
    "string runtime builtin borrows arg" 1
    (count_drops_for "s" transformed);
  Alcotest.(check int)
    "string runtime builtin does not dup arg" 0
    (count_dups_for "s" transformed)

let test_insert_drops_channel_send_retains_payload_arg () =
  let bind = bind_named "s" ty_string (cstr "payload") in
  let send =
    builtin "blorp_channel_send"
      [ cvar "ch" ty_channel_string; cvar "s" ty_string ]
      ty_bool
  in
  let body = mk (CSeq (send, cint 0)) ty_int in
  let e = mk (CLet (bind, body)) ty_int in
  let transformed = insert_drops_expr_for_test e in
  Alcotest.(check int)
    "channel send retains and caller drops payload" 1
    (count_drops_for "s" transformed);
  Alcotest.(check int)
    "channel send does not dup payload" 0
    (count_dups_for "s" transformed)

let test_insert_drops_channel_send_status_retains_payload_args () =
  let check name args result_ty =
    let bind = bind_named "s" ty_string (cstr "payload") in
    let send = builtin name args result_ty in
    let body = mk (CSeq (send, cint 0)) ty_int in
    let e = mk (CLet (bind, body)) ty_int in
    let transformed = insert_drops_expr_for_test e in
    Alcotest.(check int)
      (name ^ " retains and caller drops payload")
      1
      (count_drops_for "s" transformed);
    Alcotest.(check int)
      (name ^ " does not dup payload")
      0
      (count_dups_for "s" transformed)
  in
  check "blorp_channel_try_send_status"
    [ cvar "ch" ty_channel_string; cvar "s" ty_string ]
    ty_int;
  check "blorp_channel_send_timeout_status"
    [ cvar "ch" ty_channel_string; cvar "s" ty_string; cint 10 ]
    ty_int;
  check "blorp_channel_try_send_attempt"
    [ cvar "ch" ty_channel_string; cvar "s" ty_string ]
    ty_send_attempt;
  check "blorp_channel_send_timeout_attempt"
    [ cvar "ch" ty_channel_string; cvar "s" ty_string; cint 10 ]
    ty_send_attempt

let test_insert_drops_channel_recv_borrows_channel_arg () =
  let bind =
    bind_named "ch" ty_channel_string
      (builtin "blorp_channel_new" [ cint 1 ] ty_channel_string)
  in
  let body =
    builtin "blorp_channel_recv" [ cvar "ch" ty_channel_string ] ty_opt_string
  in
  let e = mk (CLet (bind, body)) ty_opt_string in
  let transformed = insert_drops_expr_for_test e in
  Alcotest.(check int)
    "channel recv borrows and caller drops channel" 1
    (count_drops_for "ch" transformed);
  Alcotest.(check int)
    "channel recv does not dup channel" 0
    (count_dups_for "ch" transformed)

let test_insert_drops_borrowed_cast_arg_drops_after () =
  let bind = bind_named "s" ty_string (cstr "hi") in
  let casted = mk (CCast (cvar "s" ty_string, ty_ptr)) ty_ptr in
  let body =
    intrinsic "set_hash"
      [ cvar "set" (TyNamed ("Set", [ ty_string ])); casted ]
      ty_int
  in
  let e = mk (CLet (bind, body)) ty_int in
  let transformed = insert_drops_expr_for_test e in
  Alcotest.(check int)
    "borrowed cast arg gets one final drop" 1
    (count_drops_for "s" transformed)

let test_insert_drops_field_access_borrows_owner () =
  let bind = bind_named "stats" ty_memstats (mk (CRecord []) ty_memstats) in
  let body = mk (CField (cvar "stats" ty_memstats, "current_objects")) ty_int in
  let e = mk (CLet (bind, body)) ty_int in
  let transformed = insert_drops_expr_for_test e in
  match transformed.desc with
  | CLet
      ( _,
        {
          desc =
            CLet
              ( {
                  bind_var = { vname = "__cdrop_stats"; _ };
                  bind_rhs =
                    {
                      desc =
                        CField
                          ( { desc = CVar { vname = "stats"; _ }; _ },
                            "current_objects" );
                      _;
                    };
                  _;
                },
                {
                  desc =
                    CDrop
                      ( { vname = "stats"; _ },
                        _,
                        { desc = CVar { vname = "__cdrop_stats"; _ }; _ } );
                  _;
                } );
          _;
        } ) ->
      ()
  | _ ->
      Alcotest.failf "expected field access to borrow owner and drop after:\n%s"
        (pp_to_string_indented transformed)

let test_insert_drops_borrowed_loop_body_drops_after () =
  let bind = bind_named "xs" ty_list_int (mk (clist []) ty_list_int) in
  let loop_body =
    mk
      (CSeq (intrinsic "list_len" [ cvar "xs" ty_list_int ] ty_int, cvoid))
      ty_void
  in
  let loop =
    mk
      (CFor
         ( loop_binder_named "i" ty_int,
           mk (CRange (cint 0, cint 2)) ty_int,
           loop_body ))
      ty_void
  in
  let body = mk (CSeq (loop, cvoid)) ty_void in
  let e = mk (CLet (bind, body)) ty_void in
  let transformed = insert_drops_expr_for_test e in
  Alcotest.(check int)
    "xs drop after loop body" 1
    (count_drops_for "xs" transformed);
  match transformed.desc with
  | CLet
      ( _,
        { desc = CSeq (_, { desc = CDrop ({ vname = "xs"; _ }, _, _); _ }); _ }
      ) ->
      ()
  | _ ->
      Alcotest.failf "expected borrowed loop body to post-drop owner:\n%s"
        (pp_to_string_indented transformed)

let test_insert_drops_borrowed_while_body_drops_after () =
  let bind = bind_named "xs" ty_list_int (mk (clist []) ty_list_int) in
  let cond =
    mk
      (CBin (Lt, intrinsic "list_len" [ cvar "xs" ty_list_int ] ty_int, cint 2))
      ty_bool
  in
  let loop_body =
    mk
      (CSeq (intrinsic "list_len" [ cvar "xs" ty_list_int ] ty_int, cvoid))
      ty_void
  in
  let loop = mk (CWhile (cond, loop_body)) ty_void in
  let body = mk (CSeq (loop, cvoid)) ty_void in
  let e = mk (CLet (bind, body)) ty_void in
  let transformed = insert_drops_expr_for_test e in
  Alcotest.(check int)
    "xs drop after while body" 1
    (count_drops_for "xs" transformed);
  match transformed.desc with
  | CLet
      ( _,
        { desc = CSeq (_, { desc = CDrop ({ vname = "xs"; _ }, _, _); _ }); _ }
      ) ->
      ()
  | _ ->
      Alcotest.failf "expected borrowed while body to post-drop owner:\n%s"
        (pp_to_string_indented transformed)

let test_insert_drops_consuming_while_body_preserves_owner_each_iteration () =
  let bind = bind_named "xs" ty_list_int (mk (clist []) ty_list_int) in
  let consumed =
    intrinsic "list_ensure_unique" [ cvar "xs" ty_list_int ] ty_list_int
  in
  let tmp_bind = bind_named "updated" ty_list_int consumed in
  let loop_body = mk (CLet (tmp_bind, cvoid)) ty_void in
  let loop = mk (CWhile (cbool true, loop_body)) ty_void in
  let body = mk (CSeq (loop, cvoid)) ty_void in
  let e = mk (CLet (bind, body)) ty_void in
  let transformed = insert_drops_expr_for_test e in
  Alcotest.(check int)
    "xs dup inside loop body" 1
    (count_dups_for "xs" transformed);
  Alcotest.(check int) "xs drop after loop" 1 (count_drops_for "xs" transformed);
  let rec has_dup_in_while_body e =
    match e.desc with
    | CWhile (_, body) -> count_dups_for "xs" body > 0
    | _ ->
        fold_immediate_children
          (fun found child -> found || has_dup_in_while_body child)
          false e
  in
  if not (has_dup_in_while_body transformed) then
    Alcotest.failf "expected consuming while body to dup per iteration:\n%s"
      (pp_to_string_indented transformed)

let test_insert_drops_foreign_call_borrows () =
  let bind = bind_named "s" ty_string (cstr "hi") in
  let body =
    mk
      (CCall
         ( CKForeign { fc_c_name = "strlen"; fc_arg_passing = ForeignBorrowArgs },
           cvar "strlen" (func_ty [ ty_string ] ty_int),
           [ cvar "s" ty_string ] ))
      ty_int
  in
  let e = mk (CLet (bind, body)) ty_int in
  let transformed = insert_drops_expr_for_test e in
  match transformed.desc with
  | CLet
      ( _,
        {
          desc =
            CLet
              ( {
                  bind_rhs =
                    {
                      desc =
                        CCall
                          ( CKForeign
                              {
                                fc_c_name = "strlen";
                                fc_arg_passing = ForeignBorrowArgs;
                              },
                            _,
                            _ );
                      _;
                    };
                  _;
                },
                { desc = CDrop ({ vname = "s"; _ }, _, _); _ } );
          _;
        } ) ->
      ()
  | _ ->
      Alcotest.failf "expected foreign call to borrow and post-drop, got:\n%s"
        (pp_to_string_indented transformed)

(** COW-consuming intrinsics consume the original owner, so a single call needs
    no extra dup or post-drop. *)
let test_insert_drops_cow_consume_intrinsic_no_extra_drop () =
  let bind = bind_named "xs" ty_list_int (mk (clist []) ty_list_int) in
  let body =
    intrinsic "list_ensure_unique" [ cvar "xs" ty_list_int ] ty_list_int
  in
  let e = mk (CLet (bind, body)) ty_list_int in
  let transformed = insert_drops_expr_for_test e in
  match transformed.desc with
  | CLet
      ( _,
        {
          desc =
            CCall
              ( CKIntrinsic "list_ensure_unique",
                _,
                [ { desc = CVar { vname = "xs"; _ }; _ } ] );
          _;
        } ) ->
      ()
  | _ ->
      Alcotest.failf
        "expected COW-consuming intrinsic to consume directly, got:\n%s"
        (pp_to_string_indented transformed)

(** Raw list_get returns an alias into the list storage. Until result lifetimes
    are explicit, Perceus must not post-drop the owner immediately after the
    call, even though the argument itself is borrowed. *)
let test_insert_drops_aliasing_intrinsic_result_no_post_drop () =
  let bind = bind_named "xs" ty_list_int (mk (clist []) ty_list_int) in
  let body = intrinsic "list_get" [ cvar "xs" ty_list_int; cint 0 ] ty_string in
  let e = mk (CLet (bind, body)) ty_string in
  let transformed = insert_drops_expr_for_test e in
  match transformed.desc with
  | CLet
      ( _,
        {
          desc =
            CCall
              ( CKIntrinsic "list_get",
                _,
                [
                  { desc = CVar { vname = "xs"; _ }; _ };
                  { desc = CLit (LitInt 0L); _ };
                ] );
          _;
        } ) ->
      ()
  | _ ->
      Alcotest.failf
        "expected aliasing intrinsic result to avoid post-drop, got:\n%s"
        (pp_to_string_indented transformed)

(** If a consume happens before a later borrow, Perceus needs one dup before
    the body and one post-body drop for the preserved owner. *)
let test_insert_drops_consume_then_borrow_intrinsics () =
  let bind = bind_named "xs" ty_list_int (mk (clist []) ty_list_int) in
  let consume =
    intrinsic "list_ensure_unique" [ cvar "xs" ty_list_int ] ty_list_int
  in
  let borrow = intrinsic "list_len" [ cvar "xs" ty_list_int ] ty_int in
  let body = mk (CSeq (consume, borrow)) ty_int in
  let e = mk (CLet (bind, body)) ty_int in
  let transformed = insert_drops_expr_for_test e in
  match transformed.desc with
  | CLet
      ( _,
        {
          desc =
            CLet
              ( {
                  bind_var = { vname = "__cdrop_xs"; _ };
                  bind_rhs =
                    {
                      desc =
                        CDup
                          ( { vname = "xs"; _ },
                            _,
                            {
                              desc =
                                CSeq
                                  ( {
                                      desc =
                                        CCall
                                          ( CKIntrinsic "list_ensure_unique",
                                            _,
                                            _ );
                                      _;
                                    },
                                    {
                                      desc = CCall (CKIntrinsic "list_len", _, _);
                                      _;
                                    } );
                              _;
                            } );
                      _;
                    };
                  _;
                },
                {
                  desc =
                    CDrop
                      ( { vname = "xs"; _ },
                        _,
                        { desc = CVar { vname = "__cdrop_xs"; _ }; _ } );
                  _;
                } );
          _;
        } ) ->
      ()
  | _ ->
      Alcotest.failf
        "expected consume-then-borrow to dup and drop after, got:\n%s"
        (pp_to_string_indented transformed)

(** Internal borrowed aliases keep the source owner live without becoming a
    second owned binding that Perceus has to retain/drop independently. *)
let test_borrow_let_alias_does_not_own_alias () =
  let bind = bind_named "self" ty_list_int (mk (clist []) ty_list_int) in
  let borrowed =
    {
      borrow_var = Var.named "__self";
      borrow_ty = ty_list_int;
      borrow_rhs = cvar "self" ty_list_int;
    }
  in
  let body = intrinsic "list_len" [ cvar "__self" ty_list_int ] ty_int in
  let e = mk (CLet (bind, mk (CBorrowLet (borrowed, body)) ty_int)) ty_int in
  let transformed = insert_drops_expr_for_test e in
  Alcotest.(check int) "self dup count" 0 (count_dups_for "self" transformed);
  Alcotest.(check int)
    "borrowed alias drop count" 0
    (count_drops_for "__self" transformed);
  Alcotest.(check int) "self drop count" 1 (count_drops_for "self" transformed)

(** Detached task captures are retained by the task closure at spawn time. The
    original owner in the spawning scope is still live independently and must be
    dropped after the detach operation. *)
let test_detach_capture_drops_original_after_spawn () =
  let bind = bind_named "s" ty_string (cstr "hi") in
  let detach =
    mk
      (CDetach { detach_body = cvar "s" ty_string; detach_task = None })
      ty_void
  in
  let e = mk (CLet (bind, detach)) ty_void in
  let transformed = insert_drops_expr_for_test e in
  Alcotest.(check int) "s dup count" 0 (count_dups_for "s" transformed);
  Alcotest.(check int) "s drop count" 1 (count_drops_for "s" transformed);
  match transformed.desc with
  | CLet
      ( _,
        {
          desc =
            CSeq
              ( { desc = CDetach _; _ },
                { desc = CDrop ({ vname = "s"; _ }, _, { desc = CVoid; _ }); _ }
              );
          _;
        } ) ->
      ()
  | _ ->
      Alcotest.failf "expected detach capture followed by drop:\n%s"
        (pp_to_string_indented transformed)

(** Phase 2.3: [let s in if c then 1 else 1] — branching with zero uses
    on either branch. Drop inserted before the whole if. *)
let test_if_both_branches_unused () =
  let bind = bind_named "s" ty_string (cstr "hi") in
  let body = mk (CIf (cvar "c" ty_bool, cint 1, cint 0)) ty_int in
  let e = mk (CLet (bind, body)) ty_int in
  let transformed = insert_drops_expr_for_test e in
  match transformed.desc with
  | CLet (_, { desc = CDrop ({ vname = "s"; _ }, _, { desc = CIf _; _ }); _ })
    ->
      ()
  | _ ->
      Alcotest.failf "expected drop + if, got:\n%s"
        (pp_to_string_indented transformed)

(** Phase 2.3: [let s in if c then f(s) else 0] — use on one branch only.
    Other branch gets an excess drop. *)
let test_if_asymmetric_use () =
  let fty =
    TyFunc { params = [ ty_string ]; return = ty_int; is_pure = true }
  in
  let bind = bind_named "s" ty_string (cstr "hi") in
  let f_call =
    mk (CCall (CKUnknown, cvar "f" fty, [ cvar "s" ty_string ])) ty_int
  in
  let body = mk (CIf (cvar "c" ty_bool, f_call, cint 0)) ty_int in
  let e = mk (CLet (bind, body)) ty_int in
  let transformed = insert_drops_expr_for_test e in
  (* Expected: CLet(s, CIf(c, f(s), CDrop(s, 0))) — else gets the excess drop *)
  match transformed.desc with
  | CLet (_, { desc = CIf (_, then_e, else_e); _ }) -> (
      (match then_e.desc with
      | CCall _ -> () (* then unchanged: 1 use consumed *)
      | _ -> Alcotest.failf "then branch changed:\n%s" (pp_to_string then_e));
      match else_e.desc with
      | CDrop ({ vname = "s"; _ }, _, { desc = CLit (LitInt 0L); _ }) -> ()
      | _ -> Alcotest.failf "else branch not dropped:\n%s" (pp_to_string else_e)
      )
  | _ ->
      Alcotest.failf "expected CLet(_, CIf(...)), got:\n%s"
        (pp_to_string_indented transformed)

(** Phase 2.3: [let s in if c then f(s) else f(s)] — both branches use
    exactly once. No excess on either, no dup needed (refcount 1 suffices
    for whichever path runs). *)
let test_if_symmetric_single_use () =
  let fty =
    TyFunc { params = [ ty_string ]; return = ty_int; is_pure = true }
  in
  let bind = bind_named "s" ty_string (cstr "hi") in
  let f_call =
    mk (CCall (CKUnknown, cvar "f" fty, [ cvar "s" ty_string ])) ty_int
  in
  let body = mk (CIf (cvar "c" ty_bool, f_call, f_call)) ty_int in
  let e = mk (CLet (bind, body)) ty_int in
  let transformed = insert_drops_expr_for_test e in
  (* Expected: CLet(s, CIf(c, f(s), f(s))) — unchanged *)
  match transformed.desc with
  | CLet (_, { desc = CIf (_, { desc = CCall _; _ }, { desc = CCall _; _ }); _ })
    ->
      ()
  | _ ->
      Alcotest.failf "expected unchanged, got:\n%s"
        (pp_to_string_indented transformed)

(** Branch-aware ownership contracts: borrowed branch drops after the borrow;
    unused branch drops before its body. *)
let test_if_borrowed_then_unused_else () =
  let bind = bind_named "xs" ty_list_int (mk (clist []) ty_list_int) in
  let borrowed = intrinsic "list_len" [ cvar "xs" ty_list_int ] ty_int in
  let body = mk (CIf (cvar "c" ty_bool, borrowed, cint 0)) ty_int in
  let e = mk (CLet (bind, body)) ty_int in
  let transformed = insert_drops_expr_for_test e in
  match transformed.desc with
  | CLet (_, { desc = CIf (_, then_e, else_e); _ }) -> (
      (match then_e.desc with
      | CLet
          ( {
              bind_var = { vname = "__cdrop_xs"; _ };
              bind_rhs = { desc = CCall (CKIntrinsic "list_len", _, _); _ };
              _;
            },
            {
              desc =
                CDrop
                  ( { vname = "xs"; _ },
                    _,
                    { desc = CVar { vname = "__cdrop_xs"; _ }; _ } );
              _;
            } ) ->
          ()
      | _ ->
          Alcotest.failf "then branch should drop after borrow:\n%s"
            (pp_to_string_indented then_e));
      match else_e.desc with
      | CDrop ({ vname = "xs"; _ }, _, { desc = CLit (LitInt 0L); _ }) -> ()
      | _ ->
          Alcotest.failf "else branch should drop before unused body:\n%s"
            (pp_to_string_indented else_e))
  | _ ->
      Alcotest.failf "expected CLet(_, CIf(...)), got:\n%s"
        (pp_to_string_indented transformed)

(** A borrowed branch and a COW-consuming branch both need one live ref at
    branch entry; only the borrowed branch needs a post-body drop. *)
let test_if_borrowed_vs_cow_consuming () =
  let bind = bind_named "xs" ty_list_int (mk (clist []) ty_list_int) in
  let borrowed = intrinsic "list_len" [ cvar "xs" ty_list_int ] ty_int in
  let consumed =
    intrinsic "list_ensure_unique" [ cvar "xs" ty_list_int ] ty_list_int
  in
  let consumed_then_int = mk (CSeq (consumed, cint 1)) ty_int in
  let body = mk (CIf (cvar "c" ty_bool, borrowed, consumed_then_int)) ty_int in
  let e = mk (CLet (bind, body)) ty_int in
  let transformed = insert_drops_expr_for_test e in
  match transformed.desc with
  | CLet (_, { desc = CIf (_, then_e, else_e); _ }) -> (
      (match then_e.desc with
      | CLet
          ( { bind_rhs = { desc = CCall (CKIntrinsic "list_len", _, _); _ }; _ },
            { desc = CDrop ({ vname = "xs"; _ }, _, _); _ } ) ->
          ()
      | _ ->
          Alcotest.failf "borrowed branch should post-drop:\n%s"
            (pp_to_string_indented then_e));
      match else_e.desc with
      | CSeq
          ( {
              desc =
                CCall
                  ( CKIntrinsic "list_ensure_unique",
                    _,
                    [ { desc = CVar { vname = "xs"; _ }; _ } ] );
              _;
            },
            { desc = CLit (LitInt 1L); _ } ) ->
          ()
      | _ ->
          Alcotest.failf "COW-consuming branch should consume directly:\n%s"
            (pp_to_string_indented else_e))
  | _ ->
      Alcotest.failf "expected CLet(_, CIf(...)), got:\n%s"
        (pp_to_string_indented transformed)

let pair_back_field () =
  mk (CField (cvar "pair" ty_pair_lists, "1")) ty_list_int

let pair_back_read_then_alias () =
  mk
    (CSeq
       (intrinsic "list_len" [ pair_back_field () ] ty_int, pair_back_field ()))
    ty_list_int

let assert_no_legacy_pair_branch_balance label transformed =
  Alcotest.(check int)
    (label ^ " pair dup count")
    0
    (count_dups_for "pair" transformed);
  Alcotest.(check int)
    (label ^ " pair drop count")
    0
    (count_drops_for "pair" transformed)

let retained_shadow_value () =
  mk (CDup (Var.named "value", ty_string, cvar "value" ty_string)) ty_string

let shadow_value_tree () =
  let shadow_leaf =
    CTLeaf
      {
        ct_bindings =
          borrowed_match_binding_pairs
            [
              (Var.named "value", AccVariantField (AccRoot, "ShadowString", 0));
            ];
        ct_body = retained_shadow_value ();
      }
  in
  let outer_leaf =
    CTLeaf { ct_bindings = []; ct_body = cvar "value" ty_string }
  in
  CTSwitchTag
    {
      cts_scrut = AccRoot;
      cts_cases =
        [ ("ShadowString", shadow_leaf); ("UseOuterString", outer_leaf) ];
      cts_default = None;
    }

let assert_shadowed_value_branch_balanced label transformed =
  Alcotest.(check int)
    (label ^ " outer value dup count")
    0
    (count_dups_for "value" transformed);
  Alcotest.(check int)
    (label ^ " outer value drop count")
    1
    (count_drops_for "value" transformed)

let test_if_alias_return_uses_structured_branch_summary () =
  (* Returning a field alias keeps the owner live through the result. A branch
     that only borrows the owner before returning that alias must stay on the
     structured ownership-summary path; the old count-based fallback treated
     the borrow and alias result as two consuming uses, adding an unnecessary
     dup and a branch-local drop. *)
  let bind = bind_named "pair" ty_pair_lists (mk (CTuple []) ty_pair_lists) in
  let body =
    mk
      (CIf (cvar "c" ty_bool, pair_back_read_then_alias (), pair_back_field ()))
      ty_list_int
  in
  let transformed =
    insert_drops_expr_for_test (mk (CLet (bind, body)) ty_list_int)
  in
  assert_no_legacy_pair_branch_balance "if alias return" transformed

let test_nested_branch_alias_return_uses_structured_branch_summary () =
  let bind = bind_named "pair" ty_pair_lists (mk (CTuple []) ty_pair_lists) in
  let inner =
    mk
      (CMatchArms
         ( cvar "tag" ty_int,
           [
             (PatConstructor ("A", []), pair_back_read_then_alias ());
             (PatConstructor ("B", []), pair_back_field ());
           ] ))
      ty_list_int
  in
  let body =
    mk (CIf (cvar "c" ty_bool, inner, pair_back_read_then_alias ())) ty_list_int
  in
  let transformed =
    insert_drops_expr_for_test (mk (CLet (bind, body)) ty_list_int)
  in
  assert_no_legacy_pair_branch_balance "nested branch alias return" transformed

(** Phase 2.4: [let s in match x { A -> 0 | B -> 0 }] — all arms unused.
    Drop inserted before the whole match. *)
let test_match_all_arms_unused () =
  let bind = bind_named "s" ty_string (cstr "hi") in
  let arms =
    [ (PatConstructor ("A", []), cint 0); (PatConstructor ("B", []), cint 1) ]
  in
  let body = mk (CMatchArms (cvar "x" ty_int, arms)) ty_int in
  let e = mk (CLet (bind, body)) ty_int in
  let transformed = insert_drops_expr_for_test e in
  match transformed.desc with
  | CLet
      ( _,
        { desc = CDrop ({ vname = "s"; _ }, _, { desc = CMatchArms _; _ }); _ }
      ) ->
      ()
  | _ ->
      Alcotest.failf "expected drop + match, got:\n%s"
        (pp_to_string_indented transformed)

(** Phase 2.4: [let s in match x { A -> f(s) | B -> 0 }] — one arm uses,
    the other doesn't. Excess drop on the non-using arm. *)
let test_match_asymmetric () =
  let fty =
    TyFunc { params = [ ty_string ]; return = ty_int; is_pure = true }
  in
  let bind = bind_named "s" ty_string (cstr "hi") in
  let f_call =
    mk (CCall (CKUnknown, cvar "f" fty, [ cvar "s" ty_string ])) ty_int
  in
  let arms =
    [ (PatConstructor ("A", []), f_call); (PatConstructor ("B", []), cint 0) ]
  in
  let body = mk (CMatchArms (cvar "x" ty_int, arms)) ty_int in
  let e = mk (CLet (bind, body)) ty_int in
  let transformed = insert_drops_expr_for_test e in
  match transformed.desc with
  | CLet (_, { desc = CMatchArms (_, arms'); _ }) -> (
      match arms' with
      | [ (_, a_body); (_, b_body) ] -> (
          (match a_body.desc with
          | CCall _ -> ()
          | _ -> Alcotest.failf "A arm: %s" (pp_to_string a_body));
          match b_body.desc with
          | CDrop ({ vname = "s"; _ }, _, _) -> ()
          | _ -> Alcotest.failf "B arm not dropped: %s" (pp_to_string b_body))
      | _ -> Alcotest.fail "wrong arm count")
  | _ ->
      Alcotest.failf "expected CLet(_, CMatchArms):\n%s"
        (pp_to_string_indented transformed)

let test_match_alias_return_uses_structured_branch_summary () =
  let bind = bind_named "pair" ty_pair_lists (mk (CTuple []) ty_pair_lists) in
  let arms =
    [
      (PatConstructor ("A", []), pair_back_read_then_alias ());
      (PatConstructor ("B", []), pair_back_field ());
    ]
  in
  let body = mk (CMatchArms (cvar "tag" ty_int, arms)) ty_list_int in
  let transformed =
    insert_drops_expr_for_test (mk (CLet (bind, body)) ty_list_int)
  in
  assert_no_legacy_pair_branch_balance "match alias return" transformed

(** Phase 2.4: [let s in match x { A -> f(s) | B -> f(s) }] — both arms
    use exactly once. No dup, no excess drop. *)
let test_match_symmetric_single_use () =
  let fty =
    TyFunc { params = [ ty_string ]; return = ty_int; is_pure = true }
  in
  let bind = bind_named "s" ty_string (cstr "hi") in
  let f_call =
    mk (CCall (CKUnknown, cvar "f" fty, [ cvar "s" ty_string ])) ty_int
  in
  let arms =
    [ (PatConstructor ("A", []), f_call); (PatConstructor ("B", []), f_call) ]
  in
  let body = mk (CMatchArms (cvar "x" ty_int, arms)) ty_int in
  let e = mk (CLet (bind, body)) ty_int in
  let transformed = insert_drops_expr_for_test e in
  match transformed.desc with
  | CLet
      ( _,
        {
          desc =
            CMatchArms
              (_, [ (_, { desc = CCall _; _ }); (_, { desc = CCall _; _ }) ]);
          _;
        } ) ->
      ()
  | _ ->
      Alcotest.failf "expected unchanged:\n%s"
        (pp_to_string_indented transformed)

(** Branch-aware ownership contracts for raw match arms. *)
let test_match_borrowed_arm_unused_arm () =
  let bind = bind_named "xs" ty_list_int (mk (clist []) ty_list_int) in
  let borrowed = intrinsic "list_len" [ cvar "xs" ty_list_int ] ty_int in
  let arms =
    [ (PatConstructor ("A", []), borrowed); (PatConstructor ("B", []), cint 0) ]
  in
  let body = mk (CMatchArms (cvar "tag" ty_int, arms)) ty_int in
  let e = mk (CLet (bind, body)) ty_int in
  let transformed = insert_drops_expr_for_test e in
  match transformed.desc with
  | CLet (_, { desc = CMatchArms (_, [ (_, a_body); (_, b_body) ]); _ }) -> (
      (match a_body.desc with
      | CLet
          ( { bind_rhs = { desc = CCall (CKIntrinsic "list_len", _, _); _ }; _ },
            { desc = CDrop ({ vname = "xs"; _ }, _, _); _ } ) ->
          ()
      | _ ->
          Alcotest.failf "borrowed arm should post-drop:\n%s"
            (pp_to_string_indented a_body));
      match b_body.desc with
      | CDrop ({ vname = "xs"; _ }, _, { desc = CLit (LitInt 0L); _ }) -> ()
      | _ ->
          Alcotest.failf "unused arm should pre-drop:\n%s"
            (pp_to_string_indented b_body))
  | _ ->
      Alcotest.failf "expected CLet(_, CMatchArms(...)), got:\n%s"
        (pp_to_string_indented transformed)

(** Regression: if a match scrutinee returns an alias into a binding, pattern
    variables in the selected arm may still point into that binding. Keep the
    owner live through the arm, then drop it after the match result is
    produced. *)
let test_match_aliasing_scrutinee_post_drops_owner () =
  let bind =
    bind_named "xs" ty_list_string (mk (clist [ cstr "hi" ]) ty_list_string)
  in
  let scrut =
    intrinsic "list_get" [ cvar "xs" ty_list_string; cint 0 ] ty_string
  in
  let arms =
    [ (PatVar "item", intrinsic "string_len" [ cvar "item" ty_string ] ty_int) ]
  in
  let body = mk (CMatchArms (scrut, arms)) ty_int in
  let e = mk (CLet (bind, body)) ty_int in
  let transformed = insert_drops_expr_for_test e in
  Alcotest.(check int) "xs drop count" 1 (count_drops_for "xs" transformed);
  Alcotest.(check int) "xs dup count" 0 (count_dups_for "xs" transformed)

(** Phase 2.4: [let s in match x { A -> 0 | B -> 0 }] — all decision-tree
    leaves unused. Drop before the whole match. *)
let test_match_tree_all_leaves_unused () =
  let bind = bind_named "s" ty_string (cstr "hi") in
  let leaf_a = CTLeaf { ct_bindings = []; ct_body = cint 0 } in
  let leaf_b = CTLeaf { ct_bindings = []; ct_body = cint 1 } in
  let tree =
    CTSwitchTag
      {
        cts_scrut = AccRoot;
        cts_cases = [ ("A", leaf_a); ("B", leaf_b) ];
        cts_default = None;
      }
  in
  let body = mk (CMatch (cvar "x" ty_int, tree)) ty_int in
  let e = mk (CLet (bind, body)) ty_int in
  let transformed = insert_drops_expr_for_test e in
  match transformed.desc with
  | CLet (_, { desc = CDrop ({ vname = "s"; _ }, _, { desc = CMatch _; _ }); _ })
    ->
      ()
  | _ ->
      Alcotest.failf "expected drop + match (decision tree):\n%s"
        (pp_to_string_indented transformed)

(** Phase 2.4: match (decision tree) with asymmetric leaf usage — excess drop on the
    quieter leaf. *)
let test_match_tree_asymmetric () =
  let fty =
    TyFunc { params = [ ty_string ]; return = ty_int; is_pure = true }
  in
  let bind = bind_named "s" ty_string (cstr "hi") in
  let f_call =
    mk (CCall (CKUnknown, cvar "f" fty, [ cvar "s" ty_string ])) ty_int
  in
  let leaf_a = CTLeaf { ct_bindings = []; ct_body = f_call } in
  let leaf_b = CTLeaf { ct_bindings = []; ct_body = cint 0 } in
  let tree =
    CTSwitchTag
      {
        cts_scrut = AccRoot;
        cts_cases = [ ("A", leaf_a); ("B", leaf_b) ];
        cts_default = None;
      }
  in
  let body = mk (CMatch (cvar "x" ty_int, tree)) ty_int in
  let e = mk (CLet (bind, body)) ty_int in
  let transformed = insert_drops_expr_for_test e in
  (* Expected: CLet(s, CMatch(x, Switch(A -> f(s), B -> drop s; 0))) *)
  match transformed.desc with
  | CLet (_, { desc = CMatch (_, CTSwitchTag { cts_cases; _ }); _ }) -> (
      let leaf_a' = List.assoc "A" cts_cases in
      let leaf_b' = List.assoc "B" cts_cases in
      (match leaf_a' with
      | CTLeaf { ct_body = { desc = CCall _; _ }; _ } -> ()
      | _ -> Alcotest.fail "A leaf changed");
      match leaf_b' with
      | CTLeaf { ct_body = { desc = CDrop ({ vname = "s"; _ }, _, _); _ }; _ }
        ->
          ()
      | _ -> Alcotest.fail "B leaf not dropped")
  | _ ->
      Alcotest.failf "expected CLet(_, CMatch):\n%s"
        (pp_to_string_indented transformed)

(** Branch-aware ownership contracts for compiled decision-tree leaves. *)
let test_match_tree_borrowed_leaf_unused_leaf () =
  let bind = bind_named "xs" ty_list_int (mk (clist []) ty_list_int) in
  let leaf_a =
    CTLeaf
      {
        ct_bindings = [];
        ct_body = intrinsic "list_len" [ cvar "xs" ty_list_int ] ty_int;
      }
  in
  let leaf_b = CTLeaf { ct_bindings = []; ct_body = cint 0 } in
  let tree =
    CTSwitchTag
      {
        cts_scrut = AccRoot;
        cts_cases = [ ("A", leaf_a); ("B", leaf_b) ];
        cts_default = None;
      }
  in
  let body = mk (CMatch (cvar "tag" ty_int, tree)) ty_int in
  let e = mk (CLet (bind, body)) ty_int in
  let transformed = insert_drops_expr_for_test e in
  match transformed.desc with
  | CLet (_, { desc = CMatch (_, CTSwitchTag { cts_cases; _ }); _ }) -> (
      let leaf_a' = List.assoc "A" cts_cases in
      let leaf_b' = List.assoc "B" cts_cases in
      (match leaf_a' with
      | CTLeaf
          {
            ct_body =
              {
                desc =
                  CLet
                    ( {
                        bind_rhs =
                          { desc = CCall (CKIntrinsic "list_len", _, _); _ };
                        _;
                      },
                      { desc = CDrop ({ vname = "xs"; _ }, _, _); _ } );
                _;
              };
            _;
          } ->
          ()
      | _ -> Alcotest.fail "A leaf should post-drop after borrow");
      match leaf_b' with
      | CTLeaf
          {
            ct_body =
              {
                desc =
                  CDrop ({ vname = "xs"; _ }, _, { desc = CLit (LitInt 0L); _ });
                _;
              };
            _;
          } ->
          ()
      | _ -> Alcotest.fail "B leaf should pre-drop")
  | _ ->
      Alcotest.failf "expected CLet(_, CMatch(...)), got:\n%s"
        (pp_to_string_indented transformed)

let test_match_tree_alias_return_uses_structured_branch_summary () =
  let bind = bind_named "pair" ty_pair_lists (mk (CTuple []) ty_pair_lists) in
  let leaf_a =
    CTLeaf { ct_bindings = []; ct_body = pair_back_read_then_alias () }
  in
  let leaf_b = CTLeaf { ct_bindings = []; ct_body = pair_back_field () } in
  let tree =
    CTSwitchTag
      {
        cts_scrut = AccRoot;
        cts_cases = [ ("A", leaf_a); ("B", leaf_b) ];
        cts_default = None;
      }
  in
  let body = mk (CMatch (cvar "tag" ty_int, tree)) ty_list_int in
  let transformed =
    insert_drops_expr_for_test (mk (CLet (bind, body)) ty_list_int)
  in
  assert_no_legacy_pair_branch_balance "match tree alias return" transformed

let test_match_tree_shadowed_alias_leaf_freshens_rc_targets () =
  let bind = bind_named "value" ty_string (cstr "outer") in
  let body =
    mk
      (CMatch
         ( cvar "choice" (TyNamed ("ShadowStringChoice", [])),
           shadow_value_tree () ))
      ty_string
  in
  let transformed =
    insert_drops_expr_for_test (mk (CLet (bind, body)) ty_string)
  in
  assert_shadowed_value_branch_balanced "shadowed match leaf" transformed

let test_nested_match_shadowed_alias_leaf_balances_inner_branch () =
  let bind = bind_named "value" ty_string (cstr "outer") in
  let inner =
    mk
      (CMatch
         ( cvar "choice" (TyNamed ("ShadowStringChoice", [])),
           shadow_value_tree () ))
      ty_string
  in
  let body =
    mk (CIf (cvar "c" ty_bool, inner, cvar "value" ty_string)) ty_string
  in
  let transformed =
    insert_drops_expr_for_test (mk (CLet (bind, body)) ty_string)
  in
  assert_shadowed_value_branch_balanced "nested shadowed match leaf" transformed

(** Same aliasing-scrutinee regression after pattern matching has been compiled
    to a decision tree. This is the form that reaches Perceus for real
    frontend matches. *)
let test_match_tree_aliasing_scrutinee_post_drops_owner () =
  let bind =
    bind_named "xs" ty_list_string (mk (clist [ cstr "hi" ]) ty_list_string)
  in
  let scrut =
    intrinsic "list_get" [ cvar "xs" ty_list_string; cint 0 ] ty_string
  in
  let leaf =
    CTLeaf
      {
        ct_bindings =
          borrowed_match_binding_pairs [ (Var.named "item", AccRoot) ];
        ct_body = intrinsic "string_len" [ cvar "item" ty_string ] ty_int;
      }
  in
  let body = mk (CMatch (scrut, leaf)) ty_int in
  let e = mk (CLet (bind, body)) ty_int in
  let transformed = insert_drops_expr_for_test e in
  Alcotest.(check int) "xs drop count" 1 (count_drops_for "xs" transformed);
  Alcotest.(check int) "xs dup count" 0 (count_dups_for "xs" transformed)

let test_match_tree_local_scrutinee_post_drops_owner () =
  let bind =
    bind_named "opt" ty_opt_string
      (mk (CCall (CKUser ("Some", None), cvoid, [ cstr "hi" ])) ty_opt_string)
  in
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
                    borrowed_match_binding_pairs
                      [ (Var.named "s", AccVariantField (AccRoot, "Some", 0)) ];
                  ct_body = intrinsic "string_len" [ cvar "s" ty_string ] ty_int;
                } );
            ("None", CTLeaf { ct_bindings = []; ct_body = cint 0 });
          ];
        cts_default = None;
      }
  in
  let body = mk (CMatch (cvar "opt" ty_opt_string, tree)) ty_int in
  let e = mk (CLet (bind, body)) ty_int in
  let transformed = insert_drops_expr_for_test e in
  match transformed.desc with
  | CLet
      ( _,
        {
          desc =
            CLet
              ( {
                  bind_var = { vname = "__cdrop_opt"; _ };
                  bind_rhs =
                    {
                      desc = CMatch ({ desc = CVar { vname = "opt"; _ }; _ }, _);
                      _;
                    };
                  _;
                },
                {
                  desc =
                    CDrop
                      ( { vname = "opt"; _ },
                        _,
                        { desc = CVar { vname = "__cdrop_opt"; _ }; _ } );
                  _;
                } );
          _;
        } ) ->
      ()
  | _ ->
      Alcotest.failf "match scrutinee owner was not post-dropped:\n%s"
        (pp_to_string_indented transformed)

let test_match_tree_record_literal_retains_borrowed_binding () =
  let record_ty = TyNamed ("FastqRecord", []) in
  let leaf =
    CTLeaf
      {
        ct_bindings =
          borrowed_match_binding_pairs [ (Var.named "seq", AccRoot) ];
        ct_body = mk (CRecord [ ("sequence", cvar "seq" ty_string) ]) record_ty;
      }
  in
  let e =
    mk (CMatch (cvar "opt" (TyNamed ("Option", [ ty_string ])), leaf)) record_ty
  in
  let transformed = insert_drops_expr_for_test e in
  match transformed.desc with
  | CMatch
      ( _,
        CTLeaf
          {
            ct_body =
              {
                desc =
                  CDup
                    ( { vname = "seq"; _ },
                      _,
                      {
                        desc =
                          CRecord
                            [
                              ( "sequence",
                                { desc = CVar { vname = "seq"; _ }; _ } );
                            ];
                        _;
                      } );
                _;
              };
            _;
          } ) ->
      ()
  | _ ->
      Alcotest.failf "record literal did not retain borrowed match binding:\n%s"
        (pp_to_string_indented transformed)

let test_match_tree_record_literal_retains_borrowed_field () =
  let source_ty = TyNamed ("Person", []) in
  let record_ty = TyNamed ("Event", []) in
  let leaf =
    CTLeaf
      {
        ct_bindings = borrowed_match_binding_pairs [ (Var.named "p", AccRoot) ];
        ct_body =
          mk
            (CRecord
               [
                 ("source", mk (CField (cvar "p" source_ty, "name")) ty_string);
               ])
            record_ty;
      }
  in
  let e =
    mk (CMatch (cvar "opt" (TyNamed ("Option", [ source_ty ])), leaf)) record_ty
  in
  let transformed = insert_drops_expr_for_test e in
  match transformed.desc with
  | CMatch
      ( _,
        CTLeaf
          {
            ct_body =
              {
                desc =
                  CLet
                    ( {
                        bind_var = { vname = "__borrowed_record_field_0"; _ };
                        bind_rhs =
                          {
                            desc =
                              CField
                                ({ desc = CVar { vname = "p"; _ }; _ }, "name");
                            _;
                          };
                        _;
                      },
                      {
                        desc =
                          CDup
                            ( { vname = "__borrowed_record_field_0"; _ },
                              _,
                              {
                                desc =
                                  CRecord
                                    [
                                      ( "source",
                                        {
                                          desc =
                                            CVar
                                              {
                                                vname =
                                                  "__borrowed_record_field_0";
                                                _;
                                              };
                                          _;
                                        } );
                                    ];
                                _;
                              } );
                        _;
                      } );
                _;
              };
            _;
          } ) ->
      ()
  | _ ->
      Alcotest.failf "record literal did not retain borrowed field:\n%s"
        (pp_to_string_indented transformed)

let test_match_alias_result_binding_retains_binding () =
  let record_ty = TyNamed ("Event", []) in
  let leaf =
    CTLeaf
      {
        ct_bindings = borrowed_match_binding_pairs [ (Var.named "s", AccRoot) ];
        ct_body = cvar "s" ty_string;
      }
  in
  let src_bind =
    bind_named "src" ty_string
      (mk
         (CMatch (cvar "opt" (TyNamed ("Option", [ ty_string ])), leaf))
         ty_string)
  in
  let e =
    mk
      (CLet
         (src_bind, mk (CRecord [ ("source", cvar "src" ty_string) ]) record_ty))
      record_ty
  in
  let transformed = insert_drops_expr_for_test e in
  match transformed.desc with
  | CLet
      ( {
          bind_rhs =
            {
              desc =
                CMatch
                  ( _,
                    CTLeaf
                      {
                        ct_body =
                          {
                            desc =
                              CDup
                                ( { vname = "s"; _ },
                                  _,
                                  { desc = CVar { vname = "s"; _ }; _ } );
                            _;
                          };
                        _;
                      } );
              _;
            };
          _;
        },
        {
          desc = CRecord [ ("source", { desc = CVar { vname = "src"; _ }; _ }) ];
          _;
        } ) ->
      ()
  | _ ->
      Alcotest.failf "match alias result binding did not retain binding:\n%s"
        (pp_to_string_indented transformed)

let test_match_field_result_binding_retains_binding () =
  let source_ty = TyNamed ("Person", []) in
  let record_ty = TyNamed ("Event", []) in
  let leaf =
    CTLeaf
      {
        ct_bindings = borrowed_match_binding_pairs [ (Var.named "p", AccRoot) ];
        ct_body = mk (CField (cvar "p" source_ty, "name")) ty_string;
      }
  in
  let src_bind =
    bind_named "src" ty_string
      (mk
         (CMatch (cvar "opt" (TyNamed ("Option", [ source_ty ])), leaf))
         ty_string)
  in
  let e =
    mk
      (CLet
         (src_bind, mk (CRecord [ ("source", cvar "src" ty_string) ]) record_ty))
      record_ty
  in
  let transformed = insert_drops_expr_for_test e in
  match transformed.desc with
  | CLet
      ( {
          bind_rhs =
            {
              desc =
                CMatch
                  ( _,
                    CTLeaf
                      {
                        ct_body =
                          {
                            desc =
                              CLet
                                ( {
                                    bind_var =
                                      { vname = "__borrowed_match_result"; _ };
                                    bind_rhs =
                                      {
                                        desc =
                                          CField
                                            ( {
                                                desc = CVar { vname = "p"; _ };
                                                _;
                                              },
                                              "name" );
                                        _;
                                      };
                                    _;
                                  },
                                  {
                                    desc =
                                      CSeq
                                        ( {
                                            desc =
                                              CDup
                                                ( {
                                                    vname =
                                                      "__borrowed_match_result";
                                                    _;
                                                  },
                                                  _,
                                                  { desc = CVoid; _ } );
                                            _;
                                          },
                                          {
                                            desc =
                                              CVar
                                                {
                                                  vname =
                                                    "__borrowed_match_result";
                                                  _;
                                                };
                                            _;
                                          } );
                                    _;
                                  } );
                            _;
                          };
                        _;
                      } );
              _;
            };
          _;
        },
        {
          desc = CRecord [ ("source", { desc = CVar { vname = "src"; _ }; _ }) ];
          _;
        } ) ->
      ()
  | _ ->
      Alcotest.failf "match field result binding did not retain binding:\n%s"
        (pp_to_string_indented transformed)

let test_match_aliasing_call_result_binding_retains_result () =
  let record_ty = TyNamed ("Event", []) in
  let leaf =
    CTLeaf
      {
        ct_bindings = borrowed_match_binding_pairs [ (Var.named "xs", AccRoot) ];
        ct_body =
          intrinsic "list_get" [ cvar "xs" ty_list_string; cint 0 ] ty_string;
      }
  in
  let src_bind =
    bind_named "src" ty_string
      (mk
         (CMatch (cvar "opt" (TyNamed ("Option", [ ty_list_string ])), leaf))
         ty_string)
  in
  let e =
    mk
      (CLet
         (src_bind, mk (CRecord [ ("source", cvar "src" ty_string) ]) record_ty))
      record_ty
  in
  let transformed = insert_drops_expr_for_test e in
  match transformed.desc with
  | CLet
      ( {
          bind_rhs =
            {
              desc =
                CMatch
                  ( _,
                    CTLeaf
                      {
                        ct_body =
                          {
                            desc =
                              CLet
                                ( {
                                    bind_var =
                                      { vname = "__borrowed_match_result"; _ };
                                    bind_rhs =
                                      {
                                        desc =
                                          CCall
                                            ( CKIntrinsic "list_get",
                                              _,
                                              [
                                                {
                                                  desc =
                                                    CVar { vname = "xs"; _ };
                                                  _;
                                                };
                                                { desc = CLit (LitInt 0L); _ };
                                              ] );
                                        _;
                                      };
                                    _;
                                  },
                                  {
                                    desc =
                                      CSeq
                                        ( {
                                            desc =
                                              CDup
                                                ( {
                                                    vname =
                                                      "__borrowed_match_result";
                                                    _;
                                                  },
                                                  _,
                                                  { desc = CVoid; _ } );
                                            _;
                                          },
                                          {
                                            desc =
                                              CVar
                                                {
                                                  vname =
                                                    "__borrowed_match_result";
                                                  _;
                                                };
                                            _;
                                          } );
                                    _;
                                  } );
                            _;
                          };
                        _;
                      } );
              _;
            };
          _;
        },
        {
          desc = CRecord [ ("source", { desc = CVar { vname = "src"; _ }; _ }) ];
          _;
        } ) ->
      ()
  | _ ->
      Alcotest.failf
        "match aliasing call result binding did not retain result:\n%s"
        (pp_to_string_indented transformed)

let test_match_tree_list_eq_retains_borrowed_payload () =
  let expected = mk (clist [ cint 1; cint 99; cint 3 ]) ty_list_int in
  let eq = mk (CBin (Eq, cvar "r" ty_list_int, expected)) ty_bool in
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
                    borrowed_match_binding_pairs
                      [ (Var.named "r", AccVariantField (AccRoot, "Some", 0)) ];
                  ct_body = eq;
                } );
          ];
        cts_default = Some (CTLeaf { ct_bindings = []; ct_body = cbool false });
      }
  in
  let body = mk (CMatch (cvar "opt" ty_opt_list_int, tree)) ty_bool in
  let transformed = insert_drops_expr_for_test body in
  match transformed.desc with
  | CMatch
      ( _,
        CTSwitchTag
          {
            cts_cases =
              [
                ( "Some",
                  CTLeaf
                    {
                      ct_body =
                        {
                          desc =
                            CLet
                              ( {
                                  bind_var = { vname = tmp; _ };
                                  bind_rhs = { desc = CList _; _ };
                                  _;
                                },
                                {
                                  desc =
                                    CDup
                                      ( { vname = "r"; _ },
                                        _,
                                        {
                                          desc =
                                            CBin
                                              ( Eq,
                                                {
                                                  desc = CVar { vname = "r"; _ };
                                                  _;
                                                },
                                                {
                                                  desc =
                                                    CVar { vname = tmp_ref; _ };
                                                  _;
                                                } );
                                          _;
                                        } );
                                  _;
                                } );
                          _;
                        };
                      _;
                    } );
              ];
            _;
          } )
    when String.starts_with ~prefix:"__borrow_bin_r_" tmp && tmp_ref = tmp ->
      ()
  | _ ->
      Alcotest.failf
        "borrowed match payload was not retained before list equality:\n%s"
        (pp_to_string_indented transformed)

let test_match_tree_handoff_store_retains_borrowed_payload () =
  let store =
    intrinsic "list_handoff_set_owned"
      [ cvar "result" ty_list_string; cint 0; cvar "s" ty_string ]
      ty_void
  in
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
                    borrowed_match_binding_pairs
                      [ (Var.named "s", AccVariantField (AccRoot, "Some", 0)) ];
                  ct_body = store;
                } );
          ];
        cts_default = Some (CTLeaf { ct_bindings = []; ct_body = cvoid });
      }
  in
  let body = mk (CMatch (cvar "opt" ty_opt_string, tree)) ty_void in
  let transformed = insert_drops_expr_for_test body in
  match transformed.desc with
  | CMatch
      ( _,
        CTSwitchTag
          {
            cts_cases =
              [
                ( "Some",
                  CTLeaf
                    {
                      ct_body =
                        {
                          desc =
                            CDup
                              ( { vname = "s"; _ },
                                _,
                                {
                                  desc =
                                    CCall
                                      ( CKIntrinsic "list_handoff_set_owned",
                                        _,
                                        [
                                          _;
                                          _;
                                          { desc = CVar { vname = "s"; _ }; _ };
                                        ] );
                                  _;
                                } );
                          _;
                        };
                      _;
                    } );
              ];
            _;
          } ) ->
      ()
  | _ ->
      Alcotest.failf
        "handoff transfer did not retain borrowed match payload:\n%s"
        (pp_to_string_indented transformed)

(** Phase 2.3: [let s in if c then f(s, s) else f(s)] — then=2, else=1.
    Max=2, so 1 dup before the if. Else has excess 1, so drop at start of else. *)
let test_if_asymmetric_multi () =
  let fty2 =
    TyFunc
      { params = [ ty_string; ty_string ]; return = ty_int; is_pure = true }
  in
  let fty1 =
    TyFunc { params = [ ty_string ]; return = ty_int; is_pure = true }
  in
  let bind = bind_named "s" ty_string (cstr "hi") in
  let then_call =
    mk
      (CCall
         (CKUnknown, cvar "f" fty2, [ cvar "s" ty_string; cvar "s" ty_string ]))
      ty_int
  in
  let else_call =
    mk (CCall (CKUnknown, cvar "f" fty1, [ cvar "s" ty_string ])) ty_int
  in
  let body = mk (CIf (cvar "c" ty_bool, then_call, else_call)) ty_int in
  let e = mk (CLet (bind, body)) ty_int in
  let transformed = insert_drops_expr_for_test e in
  (* Expected: CLet(s, CDup(s, CIf(c, f(s, s), CDrop(s, f(s))))) *)
  match transformed.desc with
  | CLet
      ( _,
        {
          desc =
            CDup ({ vname = "s"; _ }, _, { desc = CIf (_, then_e, else_e); _ });
          _;
        } ) -> (
      (match then_e.desc with
      | CCall _ -> ()
      | _ -> Alcotest.failf "then: %s" (pp_to_string then_e));
      match else_e.desc with
      | CDrop ({ vname = "s"; _ }, _, { desc = CCall _; _ }) -> ()
      | _ -> Alcotest.failf "else: %s" (pp_to_string else_e))
  | _ ->
      Alcotest.failf "expected dup + if + drop:\n%s"
        (pp_to_string_indented transformed)

(** Regression: mutable bindings ([var s = ...]) rebind rather than consume,
    but they still own their current value and must release it at scope exit. *)
let test_insert_drops_mutable_scope_drop () =
  let bind = bind_named ~mut:true "s" ty_string (cstr "hi") in
  let body = cint 42 in
  let e = mk (CLet (bind, body)) ty_int in
  let transformed = insert_drops_expr_for_test e in
  Alcotest.(check int)
    "final mutable owner drop" 1
    (count_drops_for "s" transformed)

let test_mutable_assignment_releases_old_owner () =
  let xs = Var.named "xs" in
  let bind =
    bind_named ~mut:true "xs" ty_list_int (mk (clist []) ty_list_int)
  in
  let assign = mk (CAssign (xs, mk (clist []) ty_list_int)) ty_void in
  let e = mk (CLet (bind, assign)) ty_void in
  let transformed = insert_drops_expr_for_test e in
  Alcotest.(check int)
    "old owner plus final owner drops" 2
    (count_drops_for "xs" transformed);
  Alcotest.(check bool)
    "old owner drop before assignment" true
    (has_drop_before_assign_for "xs" transformed)

let test_mutable_assignment_cow_consume_skips_old_release () =
  let xs = Var.named "xs" in
  let bind =
    bind_named ~mut:true "xs" ty_list_int (mk (clist []) ty_list_int)
  in
  let rhs =
    intrinsic "list_ensure_unique" [ cvar "xs" ty_list_int ] ty_list_int
  in
  let assign = mk (CAssign (xs, rhs)) ty_void in
  let e = mk (CLet (bind, assign)) ty_void in
  let transformed = insert_drops_expr_for_test e in
  Alcotest.(check int)
    "final owner drop only" 1
    (count_drops_for "xs" transformed);
  Alcotest.(check bool)
    "no old owner drop before consuming assignment" false
    (has_drop_before_assign_for "xs" transformed);
  match transformed.desc with
  | CLet
      ( _,
        {
          desc =
            CSeq
              ( {
                  desc =
                    CAssign
                      ( { vname = "xs"; _ },
                        {
                          desc = CCall (CKIntrinsic "list_ensure_unique", _, _);
                          _;
                        } );
                  _;
                },
                {
                  desc = CDrop ({ vname = "xs"; _ }, _, { desc = CVoid; _ });
                  _;
                } );
          _;
        } ) ->
      ()
  | _ ->
      Alcotest.failf
        "COW-consuming reassignment should only release final owner:\n%s"
        (pp_to_string_indented transformed)

let test_mutable_assignment_borrow_then_cow_consume_does_not_retain_result () =
  let xs = Var.named "xs" in
  let bind =
    bind_named ~mut:true "xs" ty_list_int (mk (clist []) ty_list_int)
  in
  let elem_borrow =
    {
      borrow_var = Var.named "elem";
      borrow_ty = ty_int;
      borrow_rhs = cvar "i" ty_int;
    }
  in
  let n_bind =
    bind_named "__n" ty_int
      (intrinsic "list_len" [ cvar "xs" ty_list_int ] ty_int)
  in
  let result_bind =
    bind_named "__result" ty_list_int
      (intrinsic "list_ensure_capacity"
         [ cvar "xs" ty_list_int; cvar "__n" ty_int ]
         ty_list_int)
  in
  let rhs =
    mk
      (CBorrowLet
         ( elem_borrow,
           mk
             (CLet
                ( n_bind,
                  mk
                    (CLet (result_bind, cvar "__result" ty_list_int))
                    ty_list_int ))
             ty_list_int ))
      ty_list_int
  in
  let assign = mk (CAssign (xs, rhs)) ty_void in
  let e = mk (CLet (bind, assign)) ty_void in
  let transformed = insert_drops_expr_for_test e in
  Alcotest.(check int)
    "COW result should not be retained before reassignment" 0
    (count_dups_for "__owned_result" transformed);
  Alcotest.(check bool)
    "no old owner drop before consuming assignment" false
    (has_drop_before_assign_for "xs" transformed)

let test_readonly_tensor_builtin_drops_borrowed_inputs () =
  let alloc = intrinsic "tensor_alloc" [ cint 4 ] ty_tensor_float in
  let call =
    builtin "blorp_tensor_matrix_multiply_float"
      [
        cvar "a" ty_tensor_float;
        cvar "b" ty_tensor_float;
        cint 2;
        cint 2;
        cint 2;
      ]
      ty_tensor_float
  in
  let expr =
    mk
      (CLet
         ( bind_named "a" ty_tensor_float alloc,
           mk
             (CLet
                ( bind_named "b" ty_tensor_float alloc,
                  mk
                    (CLet (bind_named "out" ty_tensor_float call, cbool true))
                    ty_bool ))
             ty_bool ))
      ty_bool
  in
  let transformed = insert_drops_expr_for_test expr in
  Alcotest.(check int)
    "left tensor input dropped after read-only builtin" 1
    (count_drops_for "a" transformed);
  Alcotest.(check int)
    "right tensor input dropped after read-only builtin" 1
    (count_drops_for "b" transformed);
  Alcotest.(check int)
    "owned tensor result dropped when unused" 1
    (count_drops_for "out" transformed)

let test_sequence_alias_binding_retains_source_before_mutable_drop () =
  let bind =
    bind_named ~mut:true "result" ty_dict_string_string
      (builtin "blorp_dict_new_string" [] ty_dict_string_string)
  in
  let tmp_bind =
    bind_named "__cdrop_entries" ty_dict_string_string
      (mk
         (CSeq
            ( mk
                (CAssign
                   ( Var.named "result",
                     builtin "blorp_dict_new_string" [] ty_dict_string_string ))
                ty_void,
              cvar "result" ty_dict_string_string ))
         ty_dict_string_string)
  in
  let body =
    mk
      (CLet (tmp_bind, cvar "__cdrop_entries" ty_dict_string_string))
      ty_dict_string_string
  in
  let e = mk (CLet (bind, body)) ty_dict_string_string in
  let transformed = insert_drops_expr_for_test e in
  Alcotest.(check int)
    "sequence alias retained for return temp" 1
    (count_dups_for "result" transformed)

let test_alias_binding_retains_source () =
  let v_bind =
    bind_named ~mut:true "v" ty_vector_int (mk (CVector []) ty_vector_int)
  in
  let copy_bind = bind_named "copy" ty_vector_int (cvar "v" ty_vector_int) in
  let body =
    mk (CSeq (cvar "v" ty_vector_int, cvar "copy" ty_vector_int)) ty_vector_int
  in
  let e =
    mk (CLet (v_bind, mk (CLet (copy_bind, body)) ty_vector_int)) ty_vector_int
  in
  let transformed = insert_drops_expr_for_test e in
  match transformed.desc with
  | CLet
      (_, { desc = CLet (_, { desc = CDup ({ vname = "v"; _ }, _, _); _ }); _ })
    ->
      ()
  | _ ->
      Alcotest.failf "alias binding did not retain source:\n%s"
        (pp_to_string_indented transformed)

let test_alias_then_cow_consume_does_not_post_drop_source () =
  (* The alias retain gives the alias its own logical owner. It must not trick
     the enclosing source binding into thinking the COW-consuming call has been
     neutralized by an implementation dup and therefore needs a final drop. *)
  let source_alloc = intrinsic "string_alloc" [ cint 16 ] ty_string in
  let cow_call =
    intrinsic "string_ensure_capacity"
      [ cvar "source" ty_string; cint 32 ]
      ty_string
  in
  let expr =
    mk
      (CLet
         ( bind_named "source" ty_string source_alloc,
           mk
             (CLet
                ( bind_named "alias" ty_string (cvar "source" ty_string),
                  mk
                    (CLet (bind_named "result" ty_string cow_call, cbool true))
                    ty_bool ))
             ty_bool ))
      ty_bool
  in
  let transformed = insert_drops_expr_for_test expr in
  Alcotest.(check int)
    "retain source for alias" 1
    (count_dups_for "source" transformed);
  Alcotest.(check int)
    "source consumed by COW call, not post-dropped" 0
    (count_drops_for "source" transformed);
  Alcotest.(check int) "alias dropped" 1 (count_drops_for "alias" transformed);
  Alcotest.(check int) "result dropped" 1 (count_drops_for "result" transformed)

let test_field_alias_binding_retains_binding () =
  let pair_bind =
    bind_named "pair" ty_pair_lists (mk (CTuple []) ty_pair_lists)
  in
  let back_bind =
    bind_named "back" ty_list_int
      (mk (CField (cvar "pair" ty_pair_lists, "1")) ty_list_int)
  in
  let use_back =
    mk
      (CCall
         ( CKUser ("use", None),
           cvar "use"
             (TyFunc
                { params = [ ty_list_int ]; return = ty_int; is_pure = true }),
           [ cvar "back" ty_list_int ] ))
      ty_int
  in
  let branch = mk (CIf (cbool true, cint 1, use_back)) ty_int in
  let e = mk (CLet (pair_bind, mk (CLet (back_bind, branch)) ty_int)) ty_int in
  let transformed = insert_drops_expr_for_test e in
  Alcotest.(check int)
    "retains field alias binding" 1
    (count_dups_for "back" transformed);
  Alcotest.(check int)
    "does not retain owner directly" 0
    (count_dups_for "pair" transformed);
  Alcotest.(check int)
    "drops owner after alias scope" 1
    (count_drops_for "pair" transformed)

let test_assignment_field_alias_retains_rhs () =
  let record_ty = TyNamed ("Box", []) in
  let field = mk (CField (cvar "box" record_ty, "items")) ty_list_int in
  let e = mk (CAssign (Var.named "xs", field)) ty_void in
  let transformed = insert_drops_expr_for_test e in
  match transformed.desc with
  | CAssign
      ( { vname = "xs"; _ },
        {
          desc =
            CLet
              ( {
                  bind_var = { vname = "__owned_result"; _ };
                  bind_rhs = { desc = CField _; _ };
                  _;
                },
                {
                  desc =
                    CSeq
                      ( {
                          desc =
                            CDup
                              ( { vname = "__owned_result"; _ },
                                _,
                                { desc = CVoid; _ } );
                          _;
                        },
                        { desc = CVar { vname = "__owned_result"; _ }; _ } );
                  _;
                } );
          _;
        } ) ->
      ()
  | _ ->
      Alcotest.failf "assignment from field alias did not retain RHS:\n%s"
        (pp_to_string_indented transformed)

let test_assignment_alias_result_temp_does_not_double_retain_source () =
  let e =
    mk (CAssign (Var.named "xs", cvar "borrowed" ty_list_int)) ty_void
  in
  let transformed = insert_drops_expr_for_test e in
  Alcotest.(check int)
    "owned result temp retains once" 1
    (count_dups_for "__owned_result" transformed);
  Alcotest.(check int)
    "source alias does not get a redundant retain" 0
    (count_dups_for "borrowed" transformed)

let test_mutable_assignment_retained_alias_becomes_slot_owner () =
  let assign =
    mk (CAssign (Var.named "result_value", cvar "result_temp" ty_string)) ty_void
  in
  let body =
    mk
      (CLet
         ( bind_named "result_temp" ty_string (cstr "match_result"),
           mk (CSeq (assign, cvar "result_value" ty_string)) ty_string ))
      ty_string
  in
  let expr =
    mk
      (CLet
         ( bind_named ~mut:true "result_value" ty_string (cstr ""),
           body ))
      ty_string
  in
  let transformed = insert_drops_expr_for_test expr in
  let drops = count_drops_for "result_value" transformed in
  if drops = 1 then ()
  else
    Alcotest.failf
      "mutable assignment from retained alias must release only the old slot, \
       got %d drops:\n\
       %s"
      drops
      (pp_to_string_indented transformed)

let test_cow_consuming_field_arg_retains_alias () =
  let pair_bind =
    bind_named "pair" ty_pair_lists (mk (CTuple []) ty_pair_lists)
  in
  let field = mk (CField (cvar "pair" ty_pair_lists, "1")) ty_list_int in
  let body = intrinsic "list_ensure_unique" [ field ] ty_list_int in
  let e = mk (CLet (pair_bind, body)) ty_list_int in
  let transformed = insert_drops_expr_for_test e in
  match transformed.desc with
  | CLet
      ( _,
        {
          desc =
            CLet
              ( {
                  bind_var = { vname = "__cdrop_pair"; _ };
                  bind_rhs =
                    {
                      desc =
                        CLet
                          ( {
                              bind_var = { vname = "__cow_arg_0"; _ };
                              bind_rhs = { desc = CField _; _ };
                              _;
                            },
                            {
                              desc =
                                CDup
                                  ( { vname = "__cow_arg_0"; _ },
                                    _,
                                    {
                                      desc =
                                        CCall
                                          ( CKIntrinsic "list_ensure_unique",
                                            _,
                                            [
                                              {
                                                desc =
                                                  CVar
                                                    { vname = "__cow_arg_0"; _ };
                                                _;
                                              };
                                            ] );
                                      _;
                                    } );
                              _;
                            } );
                      _;
                    };
                  _;
                },
                {
                  desc =
                    CDrop
                      ( { vname = "pair"; _ },
                        _,
                        { desc = CVar { vname = "__cdrop_pair"; _ }; _ } );
                  _;
                } );
          _;
        } ) ->
      ()
  | _ ->
      Alcotest.failf "COW-consuming field arg did not retain alias:\n%s"
        (pp_to_string_indented transformed)

let test_mutable_tail_alias_through_drop_temp_suppresses_final_drop () =
  let inner =
    mk
      (CLet
         ( bind_named ~mut:true "current" ty_list_int (mk (clist []) ty_list_int),
           mk (CSeq (cvoid, cvar "result" ty_list_int)) ty_list_int ))
      ty_list_int
  in
  let expr =
    mk
      (CLet
         ( bind_named ~mut:true "result" ty_list_int (mk (clist []) ty_list_int),
           inner ))
      ty_list_int
  in
  let transformed = insert_drops_expr_for_test expr in
  Alcotest.(check int)
    "returned mutable owner is not dropped" 0
    (count_drops_for "result" transformed)

let tail_alias_chain source depth =
  let alias_name i = "alias_" ^ string_of_int i in
  let rec build i =
    if i > depth then cvar (alias_name depth) ty_list_int
    else
      let rhs =
        if i = 1 then cvar source ty_list_int
        else cvar (alias_name (i - 1)) ty_list_int
      in
      mk
        (CLet (bind_named (alias_name i) ty_list_int rhs, build (i + 1)))
        ty_list_int
  in
  build 1

let test_tail_alias_chain_analysis_is_structural () =
  let body = tail_alias_chain "source" 512 in
  Alcotest.(check bool)
    "source reaches tail through aliases" true
    (Blorp.Core_perceus.expr_tail_aliases_var "source" body);
  Alcotest.(check bool)
    "unrelated source does not reach tail" false
    (Blorp.Core_perceus.expr_tail_aliases_var "unrelated" body)

let test_mutable_deep_tail_alias_suppresses_final_drop () =
  let expr =
    mk
      (CLet
         ( bind_named ~mut:true "result" ty_list_int (mk (clist []) ty_list_int),
           tail_alias_chain "result" 512 ))
      ty_list_int
  in
  let transformed = insert_drops_expr_for_test expr in
  Alcotest.(check int)
    "deep returned mutable owner is not dropped" 0
    (count_drops_for "result" transformed)

let test_mutable_collection_eq_tail_consumes_without_final_drop () =
  let body =
    mk (CBin (Eq, cvar "result" ty_list_int, mk (clist []) ty_list_int)) ty_bool
  in
  let expr =
    mk
      (CLet
         ( bind_named ~mut:true "result" ty_list_int (mk (clist []) ty_list_int),
           body ))
      ty_bool
  in
  let transformed = insert_drops_expr_for_test expr in
  Alcotest.(check int)
    "collection equality consumes tail owner once" 0
    (count_drops_for "result" transformed)

let test_mutable_tail_consumes_after_assignment_without_final_drop () =
  let update =
    mk
      (CAssign
         ( Var.named "result",
           intrinsic "list_ensure_capacity"
             [ cvar "result" ty_list_int; cint 1 ]
             ty_list_int ))
      ty_void
  in
  let expected_bind =
    bind_named "expected" ty_list_int (mk (clist []) ty_list_int)
  in
  let tail =
    mk
      (CLet
         ( expected_bind,
           mk
             (CBin (Eq, cvar "result" ty_list_int, cvar "expected" ty_list_int))
             ty_bool ))
      ty_bool
  in
  let expr =
    mk
      (CLet
         ( bind_named ~mut:true "result" ty_list_int (mk (clist []) ty_list_int),
           mk (CSeq (update, tail)) ty_bool ))
      ty_bool
  in
  let transformed = insert_drops_expr_for_test expr in
  Alcotest.(check int)
    "tail equality consumes current owner after assignment without final drop" 0
    (count_drops_for "result" transformed)

let test_mutable_protected_tail_consume_drops_scope_owner () =
  let consume_ty = func_ty [ ty_list_int ] ty_bool in
  let tail =
    mk
      (CCall
         ( CKUser ("consume", Some 700),
           cvar "consume" consume_ty,
           [ cvar "result" ty_list_int ] ))
      ty_bool
  in
  let expr =
    mk
      (CLet
         ( bind_named ~mut:true "result" ty_list_int (mk (clist []) ty_list_int),
           tail ))
      ty_bool
  in
  let transformed = insert_drops_expr_for_test expr in
  Alcotest.(check int)
    "protected tail call consumes a retained ref" 1
    (count_dups_for "result" transformed);
  Alcotest.(check int)
    "mutable owner still drops at scope exit" 1
    (count_drops_for "result" transformed)

let test_mutable_final_borrow_keeps_scope_drop () =
  let borrow =
    {
      borrow_var = Var.named "borrowed";
      borrow_ty = ty_list_int;
      borrow_rhs = cvar "result" ty_list_int;
    }
  in
  let expr =
    mk
      (CLet
         ( bind_named ~mut:true "result" ty_list_int (mk (clist []) ty_list_int),
           mk (CBorrowLet (borrow, cbool true)) ty_bool ))
      ty_bool
  in
  let transformed = insert_drops_expr_for_test expr in
  Alcotest.(check int)
    "final borrow observes mutable owner without consuming it" 1
    (count_drops_for "result" transformed)

let test_mutable_assignment_match_scrutinee_consumes_target_skips_old_release ()
    =
  let option_list_ty = TyNamed ("Option", [ ty_list_int ]) in
  let scrut =
    mk
      (CCall
         ( CKBuiltin "blorp_vector_set_cow",
           cvoid,
           [ cvar "v" ty_list_int; cint 0; cint 1 ] ))
      option_list_ty
  in
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
                    borrowed_match_binding_pairs
                      [
                        (Var.named "new_v", AccVariantField (AccRoot, "Some", 0));
                      ];
                  ct_body =
                    mk
                      (CAssign (Var.named "v", cvar "new_v" ty_list_int))
                      ty_void;
                } );
            ("None", CTLeaf { ct_bindings = []; ct_body = cvoid });
          ];
        cts_default = None;
      }
  in
  let expr =
    mk
      (CLet
         ( bind_named ~mut:true "v" ty_list_int (mk (clist []) ty_list_int),
           mk (CMatch (scrut, tree)) ty_void ))
      ty_void
  in
  let transformed = insert_drops_expr_for_test expr in
  if has_drop_before_assign_for "v" transformed then
    Alcotest.failf
      "COW-consuming match scrutinee released old owner before assignment:\n%s"
      (pp_to_string_indented transformed);
  let drops = count_drops_for "v" transformed in
  if drops <> 1 then
    Alcotest.failf
      "COW-consuming match scrutinee should keep only the scope-exit drop; the \
       retained Some payload becomes the slot owner, got %d:\n\
       %s"
      drops
      (pp_to_string_indented transformed)

let test_discard_assignment_alias_does_not_retain_owned_result () =
  let expr =
    mk
      (CLet
         ( bind_named "s" ty_string (cstr "hi"),
           mk
             (CSeq
                (mk (CAssign (Var.named "_", cvar "s" ty_string)) ty_void, cvoid))
             ty_void ))
      ty_void
  in
  let transformed = insert_drops_expr_for_test expr in
  if count_dups_for "s" transformed = 0 then ()
  else
    Alcotest.failf
      "discard assignment retained an owned alias instead of consuming it:\n%s"
      (pp_to_string_indented transformed)

let test_builtin_cow_consuming_field_arg_retains_alias () =
  let pair_bind =
    bind_named "pair" ty_pair_dicts (mk (CTuple []) ty_pair_dicts)
  in
  let field =
    mk (CField (cvar "pair" ty_pair_dicts, "1")) ty_dict_string_string
  in
  let body =
    builtin "blorp_dict_remove" [ field; cstr "missing" ] ty_dict_string_string
  in
  let e = mk (CLet (pair_bind, body)) ty_dict_string_string in
  let transformed = insert_drops_expr_for_test e in
  match transformed.desc with
  | CLet
      ( _,
        {
          desc =
            CLet
              ( {
                  bind_var = { vname = "__cdrop_pair"; _ };
                  bind_rhs =
                    {
                      desc =
                        CLet
                          ( {
                              bind_var = { vname = "__cow_arg_0"; _ };
                              bind_rhs = { desc = CField _; _ };
                              _;
                            },
                            {
                              desc =
                                CDup
                                  ( { vname = "__cow_arg_0"; _ },
                                    _,
                                    {
                                      desc =
                                        CCall
                                          ( CKBuiltin "blorp_dict_remove",
                                            _,
                                            [
                                              {
                                                desc =
                                                  CVar
                                                    { vname = "__cow_arg_0"; _ };
                                                _;
                                              };
                                              _;
                                            ] );
                                      _;
                                    } );
                              _;
                            } );
                      _;
                    };
                  _;
                },
                {
                  desc =
                    CDrop
                      ( { vname = "pair"; _ },
                        _,
                        { desc = CVar { vname = "__cdrop_pair"; _ }; _ } );
                  _;
                } );
          _;
        } ) ->
      ()
  | _ ->
      Alcotest.failf "builtin COW-consuming field arg did not retain alias:\n%s"
        (pp_to_string_indented transformed)

let test_insert_drops_nested_unused () =
  (* let s1 = "a" in let s2 = "b" in 42 — both unused, both dropped *)
  let inner_bind = bind_named "s2" ty_string (cstr "b") in
  let inner_body = cint 42 in
  let inner = mk (CLet (inner_bind, inner_body)) ty_int in
  let outer_bind = bind_named "s1" ty_string (cstr "a") in
  let e = mk (CLet (outer_bind, inner)) ty_int in
  let transformed = insert_drops_expr_for_test e in
  (* Expected shape: let s1 = ... in (let s2 = ... in (42; drop s2)); drop s1 *)
  match transformed.desc with
  | CLet
      ( _,
        {
          desc =
            CDrop
              ( { vname = "s1"; _ },
                _,
                {
                  desc =
                    CLet (_, { desc = CDrop ({ vname = "s2"; _ }, _, _); _ });
                  _;
                } );
          _;
        } ) ->
      ()
  | _ ->
      Alcotest.failf "unexpected nested shape:\n%s"
        (pp_to_string_indented transformed)

(* ============================================================================
   Program-level walker
   ============================================================================ *)

let test_insert_drops_program_function_body () =
  (* func f() -> Int: let s: String = "hi" in 0 *)
  let bind = bind_named "s" ty_string (cstr "hi") in
  let body = mk (CLet (bind, cint 0)) ty_int in
  let func : core_func =
    {
      cf_name = "f";
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
  let transformed = Blorp.Core_perceus.insert_drops_program prog in
  match transformed with
  | [ { cd_desc = CDFunc { cf_body = Some b; _ }; _ } ] -> (
      match b.desc with
      | CLet (_, { desc = CDrop _; _ }) -> ()
      | _ -> Alcotest.failf "function body not transformed: %s" (pp_to_string b)
      )
  | _ -> Alcotest.fail "expected single function"

let test_program_function_alias_does_not_retain_global_symbol () =
  (* func my_test() -> Bool: true
     func main() -> Bool:
       f: () -> Bool = my_test
       f()

     The local [f] owns the closure that Core_closure will synthesize from
     [my_test]. Perceus must not retain [my_test] itself: that name is a
     top-level function symbol, not an RC-managed runtime value. *)
  let callee : core_func =
    {
      cf_name = "my_test";
      cf_type_params = [];
      cf_params = [];
      cf_module = None;
      cf_return_ty = ty_bool;
      cf_body = Some (cbool true);
      cf_is_pure = false;
      cf_kind = CFUser;
      cf_def_id = 1;
    }
  in
  let f_ref = cvar "f" ty_bool_fn in
  let main_body =
    mk
      (CLet
         ( bind_named "f" ty_bool_fn (cvar "my_test" ty_bool_fn),
           mk (CCall (CKClosure, f_ref, [])) ty_bool ))
      ty_bool
  in
  let main : core_func =
    {
      cf_name = "main";
      cf_type_params = [];
      cf_params = [];
      cf_module = None;
      cf_return_ty = ty_bool;
      cf_body = Some main_body;
      cf_is_pure = false;
      cf_kind = CFUser;
      cf_def_id = 2;
    }
  in
  let prog =
    [
      { cd_desc = CDFunc callee; cd_loc = loc; cd_doc = None };
      { cd_desc = CDFunc main; cd_loc = loc; cd_doc = None };
    ]
  in
  let transformed = Blorp.Core_perceus.insert_drops_program prog in
  match transformed with
  | [ _; { cd_desc = CDFunc { cf_body = Some body; _ }; _ } ] -> (
      match body.desc with
      | CLet (_, { desc = CDup ({ vname = "my_test"; _ }, _, _); _ }) ->
          Alcotest.failf "retained top-level function symbol:\n%s"
            (pp_to_string_indented body)
      | CLet _ -> ()
      | _ ->
          Alcotest.failf "unexpected main body shape:\n%s"
            (pp_to_string_indented body))
  | _ -> Alcotest.fail "expected two functions"

let test_program_closure_call_borrows_callee_and_drops_local_closure () =
  (* Calling a closure reads the closure object; it does not transfer ownership
     of the closure itself to the callee. The local [f] should therefore be
     dropped after its final call. *)
  let callee = mk_func ~def_id:40 "my_test" ty_bool (cbool true) in
  let f_ref = cvar "f" ty_bool_fn in
  let main_body =
    mk
      (CLet
         ( bind_named "f" ty_bool_fn (cvar "my_test" ty_bool_fn),
           mk (CCall (CKClosure, f_ref, [])) ty_bool ))
      ty_bool
  in
  let main = mk_func ~def_id:41 "main" ty_bool main_body in
  let prog =
    [
      { cd_desc = CDFunc callee; cd_loc = loc; cd_doc = None };
      { cd_desc = CDFunc main; cd_loc = loc; cd_doc = None };
    ]
  in
  let transformed = Blorp.Core_perceus.insert_drops_program prog in
  match transformed with
  | [ _; { cd_desc = CDFunc { cf_body = Some body; _ }; _ } ] ->
      Alcotest.(check int)
        "local closure drop after call" 1 (count_drops_for "f" body)
  | _ -> Alcotest.fail "expected two functions"

let test_program_closure_call_binds_and_drops_temporary_callee () =
  (* An inline closure call target is caller-owned but only borrowed by the
     invocation. Bind it so the normal let/drop machinery can release it after
     the call. *)
  let closure_ty = func_ty [] ty_int in
  let lam =
    {
      lam_params = [];
      lam_body = intrinsic "string_len" [ cvar "captured" ty_string ] ty_int;
      lam_return_ty = ty_int;
      lam_is_pure = true;
    }
  in
  let call = mk (CCall (CKClosure, mk (CLambda lam) closure_ty, [])) ty_int in
  let main_body =
    mk (CLet (bind_named "captured" ty_string (cstr "hi"), call)) ty_int
  in
  let main = mk_func ~def_id:42 "main" ty_int main_body in
  let prog = [ { cd_desc = CDFunc main; cd_loc = loc; cd_doc = None } ] in
  let transformed = Blorp.Core_perceus.insert_drops_program prog in
  let rec has_bound_temporary_closure_drop e =
    match e.desc with
    | CLet ({ bind_var = tmp; bind_rhs = { desc = CLambda _; _ }; _ }, body) ->
        count_drops_for tmp.vname body = 1
    | _ ->
        fold_immediate_children
          (fun found child -> found || has_bound_temporary_closure_drop child)
          false e
  in
  match transformed with
  | [ { cd_desc = CDFunc { cf_body = Some body; _ }; _ } ] ->
      Alcotest.(check bool)
        "temporary closure callee drop" true
        (has_bound_temporary_closure_drop body)
  | _ -> Alcotest.fail "expected main"

let test_program_closure_call_borrows_managed_args () =
  (* Function values use the internal closure ABI: the closure object and its
     arguments are borrowed during invocation. Returning or storing an argument
     is the callee's responsibility to retain. *)
  let callback_ty = func_ty [ ty_string ] ty_int in
  let read_param =
    mk_func ~def_id:44
      ~params:[ param "s" ty_string ]
      "read_param" ty_int
      (intrinsic "string_len" [ cvar "s" ty_string ] ty_int)
  in
  let call =
    mk (CCall (CKClosure, cvar "f" callback_ty, [ cvar "s" ty_string ])) ty_int
  in
  let main_body =
    mk
      (CLet
         ( bind_named "f" callback_ty (cvar "read_param" callback_ty),
           mk (CLet (bind_named "s" ty_string (cstr "hi"), call)) ty_int ))
      ty_int
  in
  let main = mk_func ~def_id:45 "main" ty_int main_body in
  let prog =
    [
      { cd_desc = CDFunc read_param; cd_loc = loc; cd_doc = None };
      { cd_desc = CDFunc main; cd_loc = loc; cd_doc = None };
    ]
  in
  let transformed = Blorp.Core_perceus.insert_drops_program prog in
  match transformed with
  | [ _; { cd_desc = CDFunc { cf_body = Some body; _ }; _ } ] ->
      Alcotest.(check int)
        "managed arg post-call drop" 1 (count_drops_for "s" body);
      Alcotest.(check int)
        "managed arg pre-call dup" 0 (count_dups_for "s" body)
  | _ -> Alcotest.fail "expected read_param + main"

let test_program_zero_capture_lambda_callback_is_not_owned_temp () =
  (* Zero-capture lambdas lower to static closure symbols, not heap-owned
     closure objects. Passing one to a borrowed callback slot must not create a
     synthetic binding/drop around it. *)
  let callback_ty = func_ty [ ty_int ] ty_int in
  let lam =
    {
      lam_params = [ (Var.named "x", ty_int) ];
      lam_body = cvar "x" ty_int;
      lam_return_ty = ty_int;
      lam_is_pure = true;
    }
  in
  let call =
    mk
      (CCall
         ( CKBuiltin "blorp_map_parallel",
           cvar "blorp_map_parallel"
             (func_ty [ ty_list_int; callback_ty ] ty_list_int),
           [ cvar "xs" ty_list_int; mk (CLambda lam) callback_ty ] ))
      ty_list_int
  in
  let main_body =
    mk
      (CLet (bind_named "xs" ty_list_int (mk (clist []) ty_list_int), call))
      ty_list_int
  in
  let main = mk_func ~def_id:43 "main" ty_list_int main_body in
  let prog = [ { cd_desc = CDFunc main; cd_loc = loc; cd_doc = None } ] in
  let transformed = Blorp.Core_perceus.insert_drops_program prog in
  let rec count_bound_zero_capture_lambdas e =
    let here =
      match e.desc with
      | CLet ({ bind_rhs = { desc = CLambda _; _ }; _ }, _) -> 1
      | _ -> 0
    in
    fold_immediate_children
      (fun count child -> count + count_bound_zero_capture_lambdas child)
      here e
  in
  match transformed with
  | [ { cd_desc = CDFunc { cf_body = Some body; _ }; _ } ] ->
      Alcotest.(check int)
        "zero-capture lambda temp bindings" 0
        (count_bound_zero_capture_lambdas body)
  | _ -> Alcotest.fail "expected main"

let test_program_infers_read_only_user_call_borrows () =
  (* read_len only calls the borrowed list_len intrinsic, so a caller passing
     xs should keep ownership and drop xs after the call returns. *)
  let self = param "self" ty_list_int in
  let read_len =
    mk_func ~def_id:10 ~params:[ self ] "read_len" ty_int
      (intrinsic "list_len" [ cvar "self" ty_list_int ] ty_int)
  in
  let call =
    mk
      (CCall
         ( CKUser ("read_len", Some 10),
           cvar "read_len" (func_ty [ ty_list_int ] ty_int),
           [ cvar "xs" ty_list_int ] ))
      ty_int
  in
  let main_body =
    mk
      (CLet (bind_named "xs" ty_list_int (mk (clist []) ty_list_int), call))
      ty_int
  in
  let main = mk_func ~def_id:11 "main" ty_int main_body in
  let prog =
    [
      { cd_desc = CDFunc read_len; cd_loc = loc; cd_doc = None };
      { cd_desc = CDFunc main; cd_loc = loc; cd_doc = None };
    ]
  in
  let transformed = Blorp.Core_perceus.insert_drops_program prog in
  match transformed with
  | [ _; { cd_desc = CDFunc { cf_body = Some body; _ }; _ } ] -> (
      Alcotest.(check int) "xs dup count" 0 (count_dups_for "xs" body);
      Alcotest.(check int) "xs post-call drop" 1 (count_drops_for "xs" body);
      match body.desc with
      | CLet
          ( _,
            {
              desc =
                CLet
                  ( {
                      bind_rhs =
                        { desc = CCall (CKUser ("read_len", Some 10), _, _); _ };
                      _;
                    },
                    { desc = CDrop ({ vname = "xs"; _ }, _, _); _ } );
              _;
            } ) ->
          ()
      | _ ->
          Alcotest.failf "read-only user call was not modeled as borrow:\n%s"
            (pp_to_string_indented body))
  | _ -> Alcotest.fail "expected read_len + main"

let test_program_nested_consuming_user_call_retains_immutable_source () =
  (* The caller must preserve value semantics even when a consuming user call
     is hidden inside an unmanaged non-linear binding before a later use. *)
  let self = param "self" ty_list_int in
  let replace_body =
    intrinsic "list_ensure_capacity"
      [ cvar "self" ty_list_int; cint 8 ]
      ty_list_int
  in
  let replace =
    mk_func ~def_id:50 ~params:[ self ] "replace" ty_list_int replace_body
  in
  let replace_call () =
    mk
      (CCall
         ( CKUser ("replace", Some 50),
           cvar "replace" (func_ty [ ty_list_int ] ty_list_int),
           [ cvar "xs" ty_list_int ] ))
      ty_list_int
  in
  let branchy_first =
    mk (CIf (cbool true, replace_call (), replace_call ())) ty_list_int
  in
  let main_body =
    mk
      (CLet
         ( bind_named "xs" ty_list_int (mk (clist []) ty_list_int),
           mk
             (CLet
                (bind_named "first" ty_list_int branchy_first, replace_call ()))
             ty_list_int ))
      ty_list_int
  in
  let main = mk_func ~def_id:51 "main" ty_list_int main_body in
  let prog =
    [
      { cd_desc = CDFunc replace; cd_loc = loc; cd_doc = None };
      { cd_desc = CDFunc main; cd_loc = loc; cd_doc = None };
    ]
  in
  let transformed = Blorp.Core_perceus.insert_drops_program prog in
  match transformed with
  | [ _; { cd_desc = CDFunc { cf_body = Some body; _ }; _ } ] ->
      if count_dups_for "xs" body >= 2 then ()
      else
        Alcotest.failf
          "nested consuming user calls did not retain immutable source:\n%s"
          (pp_to_string_indented body)
  | _ -> Alcotest.fail "expected replace + main"

let test_program_loop_var_consuming_user_call_retains_loop_owner () =
  (* For-in loop binders are owned by the loop runtime and released after each
     iteration. Passing one to a consuming function must retain first. *)
  let self = param "self" ty_string in
  let consume_body =
    intrinsic "string_ensure_capacity"
      [ cvar "self" ty_string; cint 8 ]
      ty_string
  in
  let consume =
    mk_func ~def_id:52 ~params:[ self ] "consume" ty_string consume_body
  in
  let consume_call =
    mk
      (CCall
         ( CKUser ("consume", Some 52),
           cvar "consume" (func_ty [ ty_string ] ty_string),
           [ cvar "msg" ty_string ] ))
      ty_string
  in
  let parser_body =
    mk
      (CFor
         ( loop_binder_named "msg" ty_string,
           cvar "input" ty_list_string,
           mk
             (CLet (bind_named "ignored" ty_string consume_call, cvoid))
             ty_void ))
      ty_void
  in
  let parser =
    mk_func ~def_id:53
      ~params:[ param "input" ty_list_string ]
      "parser" ty_void parser_body
  in
  let prog =
    [
      { cd_desc = CDFunc consume; cd_loc = loc; cd_doc = None };
      { cd_desc = CDFunc parser; cd_loc = loc; cd_doc = None };
    ]
  in
  let transformed = Blorp.Core_perceus.insert_drops_program prog in
  match transformed with
  | [ _; { cd_desc = CDFunc { cf_body = Some body; _ }; _ } ] ->
      if count_dups_for "msg" body > 0 then ()
      else
        Alcotest.failf
          "consuming loop-var call did not retain loop-owned value:\n%s"
          (pp_to_string_indented body)
  | _ -> Alcotest.fail "expected consume + parser"

let test_program_drops_borrowed_owned_temporary_user_call_arg () =
  (* A fresh managed value passed to a borrowed user-call parameter remains
     caller-owned. Perceus must bind it so the normal let/drop machinery can
     release it after the borrowed call. *)
  let self = param "self" ty_list_int in
  let read_len =
    mk_func ~def_id:12 ~params:[ self ] "read_len" ty_int
      (intrinsic "list_len" [ cvar "self" ty_list_int ] ty_int)
  in
  let call =
    mk
      (CCall
         ( CKUser ("read_len", Some 12),
           cvar "read_len" (func_ty [ ty_list_int ] ty_int),
           [ mk (clist []) ty_list_int ] ))
      ty_int
  in
  let main = mk_func ~def_id:13 "main" ty_int call in
  let prog =
    [
      { cd_desc = CDFunc read_len; cd_loc = loc; cd_doc = None };
      { cd_desc = CDFunc main; cd_loc = loc; cd_doc = None };
    ]
  in
  let transformed = Blorp.Core_perceus.insert_drops_program prog in
  match transformed with
  | [ _; { cd_desc = CDFunc { cf_body = Some body; _ }; _ } ] -> (
      Alcotest.(check int)
        "borrowed temp drop" 1
        (count_drops_for "__borrow_arg_0" body);
      match body.desc with
      | CLet
          ( {
              bind_var = { vname = "__borrow_arg_0"; _ };
              bind_rhs = { desc = CList { ll_layout = _; ll_elems = [] }; _ };
              _;
            },
            {
              desc =
                CLet
                  ( {
                      bind_rhs =
                        {
                          desc =
                            CCall
                              ( CKUser ("read_len", Some 12),
                                _,
                                [
                                  {
                                    desc = CVar { vname = "__borrow_arg_0"; _ };
                                    _;
                                  };
                                ] );
                          _;
                        };
                      _;
                    },
                    { desc = CDrop ({ vname = "__borrow_arg_0"; _ }, _, _); _ }
                  );
              _;
            } ) ->
          ()
      | _ ->
          Alcotest.failf "borrowed owned temporary was not post-dropped:\n%s"
            (pp_to_string_indented body))
  | _ -> Alcotest.fail "expected read_len + main"

let test_program_drops_retained_owned_temporary_builtin_arg () =
  (* Retain-mode call slots are caller-owned just like borrowed slots: the
     callee may retain for storage, but the caller must still drop an owned
     temporary after the call returns. *)
  let call =
    builtin "blorp_set_add"
      [ builtin "blorp_set_new" [] ty_set_list_int; mk (clist []) ty_list_int ]
      ty_set_list_int
  in
  let main = mk_func ~def_id:15 "main" ty_set_list_int call in
  let transformed =
    Blorp.Core_perceus.insert_drops_program
      [ { cd_desc = CDFunc main; cd_loc = loc; cd_doc = None } ]
  in
  match transformed with
  | [ { cd_desc = CDFunc { cf_body = Some body; _ }; _ } ] ->
      Alcotest.(check int)
        "retained temp drop" 1
        (count_drops_for "__borrow_arg_0" body)
  | _ -> Alcotest.fail "expected main"

let test_program_drops_retained_owned_temporary_returned_from_let () =
  (* Std inlining can turn an owned-producing call into:

       let __inline_result = owned_expr in __inline_result

     Passing that expression to a Retain slot is still caller-owned. Perceus
     must bind and drop it just like a direct owned temporary. *)
  let inline_owned =
    mk
      (CLet
         ( bind_named "__inline_result" ty_list_int (mk (clist []) ty_list_int),
           cvar "__inline_result" ty_list_int ))
      ty_list_int
  in
  let call =
    builtin "blorp_set_add"
      [ builtin "blorp_set_new" [] ty_set_list_int; inline_owned ]
      ty_set_list_int
  in
  let main = mk_func ~def_id:151 "main" ty_set_list_int call in
  let transformed =
    Blorp.Core_perceus.insert_drops_program
      [ { cd_desc = CDFunc main; cd_loc = loc; cd_doc = None } ]
  in
  match transformed with
  | [ { cd_desc = CDFunc { cf_body = Some body; _ }; _ } ] ->
      Alcotest.(check int)
        "retained let-returned temp drop" 1
        (count_drops_for "__borrow_arg_0" body)
  | _ -> Alcotest.fail "expected main"

let test_program_drops_stream_pipeline_owned_temporaries () =
  (* Stream source/intermediate constructors retain their inputs and return
     owned streams. Passing those temporaries into downstream borrowed stream
     slots must bind them so Perceus drops each caller-owned temporary. *)
  let source =
    builtin "blorp_stream_from_list" [ mk (clist []) ty_list_int ] ty_stream_int
  in
  let call = builtin "blorp_stream_collect" [ source ] ty_list_int in
  let main = mk_func ~def_id:16 "main" ty_list_int call in
  let transformed =
    Blorp.Core_perceus.insert_drops_program
      [ { cd_desc = CDFunc main; cd_loc = loc; cd_doc = None } ]
  in
  match transformed with
  | [ { cd_desc = CDFunc { cf_body = Some body; _ }; _ } ] ->
      Alcotest.(check int)
        "source list temp drop" 1
        (count_drops_for "__borrow_arg_0" body);
      Alcotest.(check int)
        "stream temp drop" 1
        (count_drops_for "__borrow_arg_1" body)
  | _ -> Alcotest.fail "expected main"

let test_program_infers_for_iter_borrows_collection () =
  (* Iterating a collection reads from it; it does not transfer ownership of
     the collection to the loop. This keeps read-only loop helpers from hiding
     caller-owned temporaries that still need a post-call drop. *)
  let self = param "self" ty_list_int in
  let body =
    mk
      (CFor (loop_binder_named "elem" ty_int, cvar "self" ty_list_int, cvoid))
      ty_void
  in
  let iterate = mk_func ~def_id:14 ~params:[ self ] "iterate" ty_void body in
  let env =
    Blorp.Core_perceus.build_type_env
      [ { cd_desc = CDFunc iterate; cd_loc = loc; cd_doc = None } ]
  in
  Blorp.Core_perceus.populate_user_call_contracts env
    [ { cd_desc = CDFunc iterate; cd_loc = loc; cd_doc = None } ];
  match
    Blorp.Core_perceus.contract_for_call env
      (CKUser ("iterate", Some 14))
      ~arg_count:1 ~return_ty:ty_void
  with
  | Some
      {
        Blorp.Core_ownership.args = [ Blorp.Core_ownership.Borrow ];
        result = Blorp.Core_ownership.ReturnVoid;
      } ->
      ()
  | Some other ->
      Alcotest.failf "unexpected iterate contract: args=%d"
        (List.length other.Blorp.Core_ownership.args)
  | None -> Alcotest.fail "missing inferred iterate contract"

let test_program_infers_alias_binding_read_helper_borrows () =
  (* A local alias is a source-level copy, not ownership transfer. Contract
     inference must keep read_alias borrowed so callers drop fresh temporaries
     after the call. *)
  let self = param "self" ty_list_int in
  let body =
    mk
      (CLet
         ( bind_named "ys" ty_list_int (cvar "self" ty_list_int),
           intrinsic "list_len" [ cvar "ys" ty_list_int ] ty_int ))
      ty_int
  in
  let read_alias =
    mk_func ~def_id:17 ~params:[ self ] "read_alias" ty_int body
  in
  let env =
    Blorp.Core_perceus.build_type_env
      [ { cd_desc = CDFunc read_alias; cd_loc = loc; cd_doc = None } ]
  in
  Blorp.Core_perceus.populate_user_call_contracts env
    [ { cd_desc = CDFunc read_alias; cd_loc = loc; cd_doc = None } ];
  match
    Blorp.Core_perceus.contract_for_call env
      (CKUser ("read_alias", Some 17))
      ~arg_count:1 ~return_ty:ty_int
  with
  | Some
      {
        Blorp.Core_ownership.args = [ Blorp.Core_ownership.Borrow ];
        result = Blorp.Core_ownership.ReturnPrimitive;
      } ->
      ()
  | Some { Blorp.Core_ownership.args; _ } ->
      Alcotest.failf "expected borrowed alias helper arg, got %d args"
        (List.length args)
  | None -> Alcotest.fail "missing inferred read_alias contract"

let test_program_infers_boxed_read_helper_borrows () =
  (* Boxing a managed value to pass through a void* read helper is not an
     ownership transfer. The helper should borrow elem so callers retain their
     own reference and still get a final drop after the call. *)
  let self = param "self" ty_set_string in
  let elem = param "elem" ty_string in
  let boxed = mk (CCast (cvar "elem" ty_string, ty_ptr)) ty_ptr in
  let body =
    mk
      (CLet
         ( bind_named "__elem" ty_ptr boxed,
           intrinsic "set_hash"
             [ cvar "self" ty_set_string; cvar "__elem" ty_ptr ]
             ty_int ))
      ty_int
  in
  let contains_like =
    mk_func ~def_id:16 ~params:[ self; elem ] "contains_like" ty_int body
  in
  let prog =
    [ { cd_desc = CDFunc contains_like; cd_loc = loc; cd_doc = None } ]
  in
  let env = Blorp.Core_perceus.build_type_env prog in
  Blorp.Core_perceus.populate_user_call_contracts env prog;
  match
    Blorp.Core_perceus.contract_for_call env
      (CKUser ("contains_like", Some 16))
      ~arg_count:2 ~return_ty:ty_int
  with
  | Some
      {
        Blorp.Core_ownership.args =
          [ Blorp.Core_ownership.Borrow; Blorp.Core_ownership.Borrow ];
        result = Blorp.Core_ownership.ReturnPrimitive;
      } ->
      ()
  | Some { Blorp.Core_ownership.args; _ } ->
      Alcotest.failf
        "expected borrowed boxed helper args, got %d args with elem mode not \
         borrow"
        (List.length args)
  | None -> Alcotest.fail "missing inferred contains_like contract"

let test_program_infers_passthrough_user_call_borrows () =
  (* Source-level functions return owned managed values. If a function returns
     a parameter alias directly, the callee must retain before returning, so
     the caller can still model the argument as borrowed. *)
  let s_param = param "s" ty_string in
  let identity_string =
    mk_func ~def_id:20 ~params:[ s_param ] "identity_string" ty_string
      (cvar "s" ty_string)
  in
  let env =
    Blorp.Core_perceus.build_type_env
      [ { cd_desc = CDFunc identity_string; cd_loc = loc; cd_doc = None } ]
  in
  Blorp.Core_perceus.populate_user_call_contracts env
    [ { cd_desc = CDFunc identity_string; cd_loc = loc; cd_doc = None } ];
  match
    Blorp.Core_perceus.contract_for_call env
      (CKUser ("identity_string", Some 20))
      ~arg_count:1 ~return_ty:ty_string
  with
  | Some
      {
        Blorp.Core_ownership.args = [ Blorp.Core_ownership.Borrow ];
        result = Blorp.Core_ownership.ReturnOwned;
      } ->
      ()
  | Some other ->
      Alcotest.failf "unexpected identity contract: args=%d"
        (List.length other.Blorp.Core_ownership.args)
  | None -> Alcotest.fail "missing inferred identity contract"

let test_program_infers_cow_wrapper_consumes_receiver () =
  (* A source-level wrapper around a COW-consuming intrinsic must expose that
     receiver consumption to callers. Otherwise callers keep dropping the
     original owner after the callee may already have released it while copying. *)
  let s_param = param "s" ty_string in
  let cap_param = param "cap" ty_int in
  let ensure_body =
    intrinsic "string_ensure_capacity"
      [ cvar "s" ty_string; cvar "cap" ty_int ]
      ty_string
  in
  let ensure =
    mk_func ~def_id:21 ~params:[ s_param; cap_param ] "ensure" ty_string
      ensure_body
  in
  let sb_param = param "sb" ty_string in
  let wrapper_body =
    mk
      (CCall (CKUser ("ensure", Some 21), cvoid, [ cvar "sb" ty_string; cint 8 ]))
      ty_string
  in
  let wrapper =
    mk_func ~def_id:22 ~params:[ sb_param ] "wrapper" ty_string wrapper_body
  in
  let prog =
    [
      { cd_desc = CDFunc ensure; cd_loc = loc; cd_doc = None };
      { cd_desc = CDFunc wrapper; cd_loc = loc; cd_doc = None };
    ]
  in
  let env = Blorp.Core_perceus.build_type_env prog in
  Blorp.Core_perceus.populate_user_call_contracts env prog;
  match
    Blorp.Core_perceus.contract_for_call env
      (CKUser ("wrapper", Some 22))
      ~arg_count:1 ~return_ty:ty_string
  with
  | Some
      {
        Blorp.Core_ownership.args = [ Blorp.Core_ownership.Consume ];
        result = Blorp.Core_ownership.ReturnOwned;
      } ->
      ()
  | Some { Blorp.Core_ownership.args = [ mode ]; _ } ->
      Alcotest.failf "expected consuming wrapper receiver, got %s"
        (Blorp.Core_ownership.string_of_arg_mode mode)
  | Some other ->
      Alcotest.failf "unexpected wrapper contract arity: args=%d"
        (List.length other.Blorp.Core_ownership.args)
  | None -> Alcotest.fail "missing inferred wrapper contract"

let test_program_borrow_then_cow_param_does_not_dup_before_cow () =
  (* append-like lowering reads length, then consumes the receiver at the COW
     boundary. Duplicating before the COW call makes the runtime see a shared
     list and copy on every append. *)
  let self = param "self" ty_list_int in
  let n_bind =
    bind_named "__n" ty_int
      (intrinsic "list_len" [ cvar "self" ty_list_int ] ty_int)
  in
  let body =
    mk
      (CLet
         ( n_bind,
           intrinsic "list_ensure_capacity"
             [ cvar "self" ty_list_int; cvar "__n" ty_int ]
             ty_list_int ))
      ty_list_int
  in
  let grow = mk_func ~def_id:23 ~params:[ self ] "grow" ty_list_int body in
  let prog = [ { cd_desc = CDFunc grow; cd_loc = loc; cd_doc = None } ] in
  match Blorp.Core_perceus.insert_drops_program prog with
  | [ { cd_desc = CDFunc { cf_body = Some transformed; _ }; _ } ] ->
      Alcotest.(check int)
        "borrow-before-cow parameter dup count" 0
        (count_dups_for "self" transformed)
  | _ -> Alcotest.fail "expected transformed grow function"

let cow_param_before_loop_body cow_intrinsic ty =
  let result_bind =
    bind_named ~mut:true "__result" ty
      (intrinsic cow_intrinsic [ cvar "self" ty ] ty)
  in
  let loop = mk (CWhile (cbool false, cvoid)) ty_void in
  mk (CLet (result_bind, mk (CSeq (loop, cvar "__result" ty)) ty)) ty

let assert_cow_param_before_loop_has_no_dup name cow_intrinsic ty def_id =
  let self = param "self" ty in
  let fn =
    mk_func ~def_id ~params:[ self ] name ty
      (cow_param_before_loop_body cow_intrinsic ty)
  in
  let prog = [ { cd_desc = CDFunc fn; cd_loc = loc; cd_doc = None } ] in
  match Blorp.Core_perceus.insert_drops_program prog with
  | [ { cd_desc = CDFunc { cf_body = Some transformed; _ }; _ } ] ->
      Alcotest.(check int)
        (name ^ " receiver dup count")
        0
        (count_dups_for "self" transformed)
  | _ -> Alcotest.failf "expected transformed %s function" name

let test_program_cow_param_before_loop_does_not_dup_before_cow () =
  (* Dict/set synthesized mutators COW the receiver into a mutable result, then
     run non-linear table probing against that result. The receiver is not used
     after the COW RHS, so duplicating it before COW defeats uniqueness and
     copies the whole table on every insertion. *)
  assert_cow_param_before_loop_has_no_dup "dict_grow" "dict_cow" ty_dict_int_int
    24;
  assert_cow_param_before_loop_has_no_dup "set_grow" "set_cow" ty_set_int 25

let person_record_decl () : record_decl =
  {
    record_name = "Person";
    record_type_params = [];
    record_fields =
      [ { field_name = "name"; field_type = ty_string; field_loc = loc } ];
    record_is_value = false;
    record_is_builtin = false;
  }

let ty_person = TyNamed ("Person", [])

let holder_record_decl () : record_decl =
  {
    record_name = "Holder";
    record_type_params = [];
    record_fields =
      [ { field_name = "items"; field_type = ty_list_int; field_loc = loc } ];
    record_is_value = false;
    record_is_builtin = false;
  }

let ty_holder = TyNamed ("Holder", [])

let test_program_field_return_borrows_parent_and_returns_owned () =
  (* A source-level function returning a field does not expose a borrowed
     lifetime. The parent can be borrowed, but the returned field must be
     owned. *)
  let person = param "person" ty_person in
  let name_of =
    mk_func ~def_id:30 ~params:[ person ] "name_of" ty_string
      (mk (CField (cvar "person" ty_person, "name")) ty_string)
  in
  let prog =
    [
      {
        cd_desc = CDRecord (person_record_decl ());
        cd_loc = loc;
        cd_doc = None;
      };
      { cd_desc = CDFunc name_of; cd_loc = loc; cd_doc = None };
    ]
  in
  let env = Blorp.Core_perceus.build_type_env prog in
  Blorp.Core_perceus.populate_user_call_contracts env prog;
  match
    Blorp.Core_perceus.contract_for_call env
      (CKUser ("name_of", Some 30))
      ~arg_count:1 ~return_ty:ty_string
  with
  | Some
      {
        Blorp.Core_ownership.args = [ Blorp.Core_ownership.Borrow ];
        result = Blorp.Core_ownership.ReturnOwned;
      } ->
      ()
  | Some
      {
        Blorp.Core_ownership.result = Blorp.Core_ownership.ReturnAliasOfArg _;
        _;
      }
  | Some
      { Blorp.Core_ownership.result = Blorp.Core_ownership.ReturnBorrowed; _ }
    ->
      Alcotest.fail "source-level function exposed a borrowed return contract"
  | Some other ->
      Alcotest.failf "unexpected name_of contract: args=%d"
        (List.length other.Blorp.Core_ownership.args)
  | None -> Alcotest.fail "missing inferred name_of contract"

let test_program_field_return_retains_before_return () =
  let person = param "person" ty_person in
  let name_of =
    mk_func ~def_id:31 ~params:[ person ] "name_of" ty_string
      (mk (CField (cvar "person" ty_person, "name")) ty_string)
  in
  let prog =
    [
      {
        cd_desc = CDRecord (person_record_decl ());
        cd_loc = loc;
        cd_doc = None;
      };
      { cd_desc = CDFunc name_of; cd_loc = loc; cd_doc = None };
    ]
  in
  let transformed = Blorp.Core_perceus.insert_drops_program prog in
  match transformed with
  | [ _; { cd_desc = CDFunc { cf_body = Some body; _ }; _ } ] -> (
      match body.desc with
      | CLet
          ( {
              bind_var = borrowed;
              bind_rhs =
                {
                  desc =
                    CField ({ desc = CVar { vname = "person"; _ }; _ }, "name");
                  _;
                };
              _;
            },
            body )
        when count_dups_for borrowed.vname body > 0 ->
          ()
      | _ ->
          Alcotest.failf
            "field return was not normalized to an owned result:\n%s"
            (pp_to_string_indented body))
  | _ -> Alcotest.fail "expected Person record + name_of"

let test_program_record_literal_retains_borrowed_param_field () =
  let items = param "items" ty_list_int in
  let make_holder =
    mk_func ~def_id:36 ~params:[ items ] "make_holder" ty_holder
      (mk (CRecord [ ("items", cvar "items" ty_list_int) ]) ty_holder)
  in
  let prog =
    [
      {
        cd_desc = CDRecord (holder_record_decl ());
        cd_loc = loc;
        cd_doc = None;
      };
      { cd_desc = CDFunc make_holder; cd_loc = loc; cd_doc = None };
    ]
  in
  let transformed = Blorp.Core_perceus.insert_drops_program prog in
  match transformed with
  | [ _; { cd_desc = CDFunc { cf_body = Some body; _ }; _ } ] ->
      if count_dups_for "items" body > 0 then ()
      else
        Alcotest.failf
          "record literal did not retain borrowed parameter field:\n%s"
          (pp_to_string_indented body)
  | _ -> Alcotest.fail "expected Holder record + make_holder"

let test_program_param_return_retains_before_return () =
  let s_param = param "s" ty_string in
  let identity_string =
    mk_func ~def_id:34 ~params:[ s_param ] "identity_string" ty_string
      (cvar "s" ty_string)
  in
  let prog =
    [ { cd_desc = CDFunc identity_string; cd_loc = loc; cd_doc = None } ]
  in
  let transformed = Blorp.Core_perceus.insert_drops_program prog in
  match transformed with
  | [ { cd_desc = CDFunc { cf_body = Some body; _ }; _ } ] -> (
      match body.desc with
      | CDup ({ vname = "s"; _ }, _, { desc = CVar { vname = "s"; _ }; _ }) ->
          ()
      | _ ->
          Alcotest.failf "parameter return was not retained before return:\n%s"
            (pp_to_string_indented body))
  | _ -> Alcotest.fail "expected identity_string"

let test_program_lambda_param_return_retains_before_closure_conversion () =
  let identity_ty = func_ty [ ty_string ] ty_string in
  let lam =
    {
      lam_params = [ (Var.named "s", ty_string) ];
      lam_body = cvar "s" ty_string;
      lam_return_ty = ty_string;
      lam_is_pure = true;
    }
  in
  let make_identity =
    mk_func ~def_id:35 "make_identity" identity_ty
      (mk (CLambda lam) identity_ty)
  in
  let prog =
    [ { cd_desc = CDFunc make_identity; cd_loc = loc; cd_doc = None } ]
  in
  let transformed = Blorp.Core_perceus.insert_drops_program prog in
  match transformed with
  | [
   {
     cd_desc =
       CDFunc { cf_body = Some { desc = CLambda { lam_body = body; _ }; _ }; _ };
     _;
   };
  ] -> (
      match body.desc with
      | CDup ({ vname = "s"; _ }, _, { desc = CVar { vname = "s"; _ }; _ }) ->
          ()
      | _ ->
          Alcotest.failf
            "lambda parameter return was not normalized before closure \
             conversion:\n\
             %s"
            (pp_to_string_indented body))
  | _ -> Alcotest.fail "expected make_identity"

let test_program_unbox_alias_return_retains_before_return () =
  let self = param "self" ty_list_string in
  let unsafe_get =
    mk_func ~def_id:32 ~params:[ self ] "unsafe_get" ty_string
      (mk
         (CUnbox
            ( intrinsic "list_get"
                [ cvar "self" ty_list_string; cint 0 ]
                ty_string,
              ty_string ))
         ty_string)
  in
  let prog = [ { cd_desc = CDFunc unsafe_get; cd_loc = loc; cd_doc = None } ] in
  let transformed = Blorp.Core_perceus.insert_drops_program prog in
  match transformed with
  | [ { cd_desc = CDFunc { cf_body = Some body; _ }; _ } ] -> (
      match body.desc with
      | CLet
          ( {
              bind_var = borrowed;
              bind_rhs =
                {
                  desc =
                    CUnbox
                      ({ desc = CCall (CKIntrinsic "list_get", _, _); _ }, _);
                  _;
                };
              _;
            },
            body )
        when count_dups_for borrowed.vname body > 0 ->
          ()
      | _ ->
          Alcotest.failf
            "unboxed alias return was not normalized to an owned result:\n%s"
            (pp_to_string_indented body))
  | _ -> Alcotest.fail "expected unsafe_get"

let test_program_lambda_field_return_retains_before_closure_conversion () =
  let getter_ty = func_ty [ ty_person ] ty_string in
  let lam =
    {
      lam_params = [ (Var.named "person", ty_person) ];
      lam_body = mk (CField (cvar "person" ty_person, "name")) ty_string;
      lam_return_ty = ty_string;
      lam_is_pure = true;
    }
  in
  let make_getter =
    mk_func ~def_id:33 "make_getter" getter_ty (mk (CLambda lam) getter_ty)
  in
  let prog =
    [
      {
        cd_desc = CDRecord (person_record_decl ());
        cd_loc = loc;
        cd_doc = None;
      };
      { cd_desc = CDFunc make_getter; cd_loc = loc; cd_doc = None };
    ]
  in
  let transformed = Blorp.Core_perceus.insert_drops_program prog in
  match transformed with
  | [
   _;
   {
     cd_desc =
       CDFunc { cf_body = Some { desc = CLambda { lam_body = body; _ }; _ }; _ };
     _;
   };
  ] -> (
      match body.desc with
      | CLet
          ( {
              bind_var = borrowed;
              bind_rhs =
                {
                  desc =
                    CField ({ desc = CVar { vname = "person"; _ }; _ }, "name");
                  _;
                };
              _;
            },
            body )
        when count_dups_for borrowed.vname body > 0 ->
          ()
      | _ ->
          Alcotest.failf
            "lambda field return was not normalized before closure conversion:\n\
             %s"
            (pp_to_string_indented body))
  | _ -> Alcotest.fail "expected Person record + make_getter"

let boxed_string_type_decl () : type_decl =
  {
    type_name = "BoxedString";
    type_params = [];
    type_variants =
      [
        {
          variant_name = "Boxed";
          variant_fields = [ ty_string ];
          variant_tag = 0;
          variant_loc = loc;
          variant_def_id = Some 40;
        };
      ];
    type_is_enum = false;
    type_is_builtin = false;
    type_is_resource = false;
    type_resource_cleanup = None;
  }

let ty_boxed_string = TyNamed ("BoxedString", [])

let test_program_constructor_contract_transfers_payload () =
  let prog =
    [
      {
        cd_desc = CDType (boxed_string_type_decl ());
        cd_loc = loc;
        cd_doc = None;
      };
    ]
  in
  let env = Blorp.Core_perceus.build_type_env prog in
  match
    Blorp.Core_perceus.contract_for_call env
      (CKUser ("Boxed", Some 40))
      ~arg_count:1 ~return_ty:ty_boxed_string
  with
  | Some
      {
        Blorp.Core_ownership.args = [ Blorp.Core_ownership.Transfer ];
        result = Blorp.Core_ownership.ReturnOwned;
      } ->
      ()
  | Some other ->
      Alcotest.failf "unexpected Boxed constructor contract: args=%d"
        (List.length other.Blorp.Core_ownership.args)
  | None -> Alcotest.fail "missing Boxed constructor contract"

let test_program_constructor_retains_borrowed_match_payload () =
  let boxed_ctor_ty = func_ty [ ty_string ] ty_boxed_string in
  let leaf =
    CTLeaf
      {
        ct_bindings =
          borrowed_match_binding_pairs
            [ (Var.named "seq", AccVariantField (AccRoot, "Boxed", 0)) ];
        ct_body =
          mk
            (CCall
               ( CKUser ("Boxed", Some 40),
                 cvar "Boxed" boxed_ctor_ty,
                 [ cvar "seq" ty_string ] ))
            ty_boxed_string;
      }
  in
  let rebox =
    mk_func ~def_id:41
      ~params:[ param "box" ty_boxed_string ]
      "rebox" ty_boxed_string
      (mk (CMatch (cvar "box" ty_boxed_string, leaf)) ty_boxed_string)
  in
  let prog =
    [
      {
        cd_desc = CDType (boxed_string_type_decl ());
        cd_loc = loc;
        cd_doc = None;
      };
      { cd_desc = CDFunc rebox; cd_loc = loc; cd_doc = None };
    ]
  in
  let transformed = Blorp.Core_perceus.insert_drops_program prog in
  match transformed with
  | [
   _;
   {
     cd_desc =
       CDFunc
         {
           cf_body =
             Some
               {
                 desc =
                   CMatch
                     ( _,
                       CTLeaf
                         {
                           ct_body =
                             {
                               desc =
                                 CDup
                                   ( { vname = "seq"; _ },
                                     _,
                                     {
                                       desc =
                                         CCall
                                           ( CKUser ("Boxed", Some 40),
                                             _,
                                             [
                                               {
                                                 desc =
                                                   CVar { vname = "seq"; _ };
                                                 _;
                                               };
                                             ] );
                                       _;
                                     } );
                               _;
                             };
                           _;
                         } );
                 _;
               };
           _;
         };
     _;
   };
  ] ->
      ()
  | _ ->
      let rendered =
        match transformed with
        | [ _; { cd_desc = CDFunc { cf_body = Some body; _ }; _ } ] ->
            pp_to_string_indented body
        | _ -> "<unexpected program shape>"
      in
      Alcotest.failf "constructor did not retain borrowed match payload:\n%s"
        rendered

let test_program_constructor_retains_borrowed_param () =
  let boxed_ctor_ty = func_ty [ ty_string ] ty_boxed_string in
  let s_param = param "s" ty_string in
  let box_param =
    mk_func ~def_id:39 ~params:[ s_param ] "box_param" ty_boxed_string
      (mk
         (CCall
            ( CKUser ("Boxed", Some 40),
              cvar "Boxed" boxed_ctor_ty,
              [ cvar "s" ty_string ] ))
         ty_boxed_string)
  in
  let prog =
    [
      {
        cd_desc = CDType (boxed_string_type_decl ());
        cd_loc = loc;
        cd_doc = None;
      };
      { cd_desc = CDFunc box_param; cd_loc = loc; cd_doc = None };
    ]
  in
  let transformed = Blorp.Core_perceus.insert_drops_program prog in
  match transformed with
  | [ _; { cd_desc = CDFunc { cf_body = Some body; _ }; _ } ]
    when count_dups_for "s" body > 0 ->
      ()
  | _ ->
      let rendered =
        match transformed with
        | [ _; { cd_desc = CDFunc { cf_body = Some body; _ }; _ } ] ->
            pp_to_string_indented body
        | _ -> "<unexpected program shape>"
      in
      Alcotest.failf "constructor did not retain borrowed function param:\n%s"
        rendered

let test_program_constructor_retains_borrowed_lambda_param () =
  let boxed_ctor_ty = func_ty [ ty_string ] ty_boxed_string in
  let lambda_ty = func_ty [ ty_string ] ty_boxed_string in
  let lam =
    {
      lam_params = [ (Var.named "s", ty_string) ];
      lam_return_ty = ty_boxed_string;
      lam_body =
        mk
          (CCall
             ( CKUser ("Boxed", Some 40),
               cvar "Boxed" boxed_ctor_ty,
               [ cvar "s" ty_string ] ))
          ty_boxed_string;
      lam_is_pure = true;
    }
  in
  let make_boxer =
    mk_func ~def_id:42 ~params:[] "make_boxer" lambda_ty
      (mk (CLambda lam) lambda_ty)
  in
  let prog =
    [
      {
        cd_desc = CDType (boxed_string_type_decl ());
        cd_loc = loc;
        cd_doc = None;
      };
      { cd_desc = CDFunc make_boxer; cd_loc = loc; cd_doc = None };
    ]
  in
  let transformed = Blorp.Core_perceus.insert_drops_program prog in
  match transformed with
  | [
   _;
   {
     cd_desc =
       CDFunc
         {
           cf_body =
             Some
               {
                 desc =
                   CLambda
                     {
                       lam_body =
                         {
                           desc =
                             CDup
                               ( { vname = "s"; _ },
                                 _,
                                 {
                                   desc =
                                     CCall
                                       ( CKUser ("Boxed", Some 40),
                                         _,
                                         [
                                           { desc = CVar { vname = "s"; _ }; _ };
                                         ] );
                                   _;
                                 } );
                           _;
                         };
                       _;
                     };
                 _;
               };
           _;
         };
     _;
   };
  ] ->
      ()
  | _ ->
      let rendered =
        match transformed with
        | [ _; { cd_desc = CDFunc { cf_body = Some body; _ }; _ } ] ->
            pp_to_string_indented body
        | _ -> "<unexpected program shape>"
      in
      Alcotest.failf "constructor did not retain borrowed lambda param:\n%s"
        rendered

let test_program_constructor_assignment_retains_mutable_local () =
  let boxed_ctor_ty = func_ty [ ty_string ] ty_boxed_string in
  let payload_bind =
    bind_named ~mut:true "payload" ty_string (cstr "payload")
  in
  let initial =
    mk
      (CCall
         ( CKUser ("Boxed", Some 40),
           cvar "Boxed" boxed_ctor_ty,
           [ cstr "initial" ] ))
      ty_boxed_string
  in
  let result_bind = bind_named ~mut:true "result" ty_boxed_string initial in
  let replacement =
    mk
      (CCall
         ( CKUser ("Boxed", Some 40),
           cvar "Boxed" boxed_ctor_ty,
           [ cvar "payload" ty_string ] ))
      ty_boxed_string
  in
  let assign = mk (CAssign (Var.named "result", replacement)) ty_void in
  let body =
    mk
      (CLet
         ( payload_bind,
           mk
             (CLet
                ( result_bind,
                  mk
                    (CSeq (assign, cvar "result" ty_boxed_string))
                    ty_boxed_string ))
             ty_boxed_string ))
      ty_boxed_string
  in
  let replace =
    mk_func ~def_id:43 ~params:[] "replace_box" ty_boxed_string body
  in
  let prog =
    [
      {
        cd_desc = CDType (boxed_string_type_decl ());
        cd_loc = loc;
        cd_doc = None;
      };
      { cd_desc = CDFunc replace; cd_loc = loc; cd_doc = None };
    ]
  in
  let transformed = Blorp.Core_perceus.insert_drops_program prog in
  match transformed with
  | [ _; { cd_desc = CDFunc { cf_body = Some body; _ }; _ } ]
    when count_dups_for "payload" body > 0 ->
      ()
  | _ ->
      let rendered =
        match transformed with
        | [ _; { cd_desc = CDFunc { cf_body = Some body; _ }; _ } ] ->
            pp_to_string_indented body
        | _ -> "<unexpected program shape>"
      in
      Alcotest.failf
        "constructor assignment did not retain mutable local payload:\n%s"
        rendered

(* ============================================================================
   Test suite
   ============================================================================ *)

let suite =
  [
    ( "managed_type",
      [
        Alcotest.test_case "string" `Quick test_managed_string;
        Alcotest.test_case "list" `Quick test_managed_list;
        Alcotest.test_case "memstats" `Quick test_managed_memstats;
        Alcotest.test_case "scheduler_stats" `Quick test_managed_scheduler_stats;
        Alcotest.test_case "fixed" `Quick test_managed_fixed;
        Alcotest.test_case "channel" `Quick test_managed_channel;
        Alcotest.test_case "tensor_no_static_dims" `Quick
          test_managed_tensor_without_static_dims;
        Alcotest.test_case "string_slice" `Quick test_managed_string_slice;
        Alcotest.test_case "int" `Quick test_not_managed_int;
        Alcotest.test_case "bool" `Quick test_not_managed_bool;
        Alcotest.test_case "dimension_value_refinements" `Quick
          test_dimension_value_refinements_are_not_managed;
        Alcotest.test_case "variadic_dimension_pack_invalid_value" `Quick
          test_variadic_dimension_pack_still_invalid_as_value;
        Alcotest.test_case "ptr" `Quick test_not_managed_ptr;
        Alcotest.test_case "func" `Quick test_managed_func;
        Alcotest.test_case "tuple" `Quick test_managed_tuple;
        Alcotest.test_case "user_record" `Quick test_managed_user_record;
        Alcotest.test_case "user_record_policy" `Quick
          test_user_record_destructor_policy_registered;
        Alcotest.test_case "value_struct" `Quick test_not_managed_value_struct;
        Alcotest.test_case "union" `Quick test_managed_union;
        Alcotest.test_case "union_policy" `Quick
          test_user_union_destructor_policy_registered;
        Alcotest.test_case "enum" `Quick test_not_managed_enum;
        Alcotest.test_case "unknown_raises" `Quick
          test_unknown_named_type_raises;
        Alcotest.test_case "alias_layout" `Quick test_alias_layout_uses_registry;
        Alcotest.test_case "generic_multi_char_param_layout" `Quick
          test_program_generic_multi_char_type_param_has_layout;
      ] );
    ( "count_uses",
      [
        Alcotest.test_case "zero" `Quick test_count_uses_zero;
        Alcotest.test_case "one" `Quick test_count_uses_one;
        Alcotest.test_case "binary" `Quick test_count_uses_binary;
        Alcotest.test_case "nested" `Quick test_count_uses_nested;
        Alcotest.test_case "shadowing" `Quick test_count_uses_shadowing;
        Alcotest.test_case "if_max" `Quick test_count_uses_in_if;
        Alcotest.test_case "if_asymmetric" `Quick test_count_uses_if_asymmetric;
        Alcotest.test_case "nested_branches" `Quick
          test_count_uses_nested_branches;
        Alcotest.test_case "match_max" `Quick test_count_uses_in_match;
        Alcotest.test_case "pattern_shadow" `Quick
          test_count_uses_pattern_shadow;
        Alcotest.test_case "assign_lhs" `Quick test_count_uses_assign_lhs;
        Alcotest.test_case "lambda_capture" `Quick
          test_count_uses_lambda_capture;
      ] );
    ( "is_linear",
      [
        Alcotest.test_case "literal" `Quick test_linear_literal;
        Alcotest.test_case "binary" `Quick test_linear_binary;
        Alcotest.test_case "call" `Quick test_linear_call;
        Alcotest.test_case "if" `Quick test_not_linear_if;
        Alcotest.test_case "while" `Quick test_not_linear_while;
        Alcotest.test_case "match" `Quick test_not_linear_match;
        Alcotest.test_case "nested" `Quick test_not_linear_nested;
      ] );
    ( "insert_drops",
      [
        Alcotest.test_case "unused_string" `Quick
          test_insert_drops_unused_string;
        Alcotest.test_case "unused_int_unch" `Quick
          test_insert_drops_unused_int_unchanged;
        Alcotest.test_case "used_string_unch" `Quick
          test_insert_drops_used_string_unchanged;
        Alcotest.test_case "branching_unch" `Quick
          test_insert_drops_branching_unchanged;
        Alcotest.test_case "nested_unused" `Quick
          test_insert_drops_nested_unused;
        Alcotest.test_case "mutable_scope_drop" `Quick
          test_insert_drops_mutable_scope_drop;
        Alcotest.test_case "alias_retains_source" `Quick
          test_alias_binding_retains_source;
        Alcotest.test_case "alias_then_cow_consume_no_source_post_drop" `Quick
          test_alias_then_cow_consume_does_not_post_drop_source;
        Alcotest.test_case "field_alias_retains_binding" `Quick
          test_field_alias_binding_retains_binding;
        Alcotest.test_case "assignment_field_alias_retains_rhs" `Quick
          test_assignment_field_alias_retains_rhs;
        Alcotest.test_case "assignment_alias_result_temp_no_double_retain"
          `Quick test_assignment_alias_result_temp_does_not_double_retain_source;
        Alcotest.test_case "mutable_assignment_retained_alias_slot_owner"
          `Quick test_mutable_assignment_retained_alias_becomes_slot_owner;
        Alcotest.test_case "mutable_assignment_releases_old_owner" `Quick
          test_mutable_assignment_releases_old_owner;
        Alcotest.test_case "mutable_assignment_cow_consume_skips_old_release"
          `Quick test_mutable_assignment_cow_consume_skips_old_release;
        Alcotest.test_case
          "mutable_assignment_borrow_then_cow_consume_no_result_retain" `Quick
          test_mutable_assignment_borrow_then_cow_consume_does_not_retain_result;
        Alcotest.test_case "readonly_tensor_builtin_drops_borrowed_inputs"
          `Quick test_readonly_tensor_builtin_drops_borrowed_inputs;
        Alcotest.test_case "mutable_tail_alias_through_drop_temp_no_final_drop"
          `Quick test_mutable_tail_alias_through_drop_temp_suppresses_final_drop;
        Alcotest.test_case "tail_alias_chain_analysis_structural" `Quick
          test_tail_alias_chain_analysis_is_structural;
        Alcotest.test_case "mutable_deep_tail_alias_no_final_drop" `Quick
          test_mutable_deep_tail_alias_suppresses_final_drop;
        Alcotest.test_case "mutable_collection_eq_tail_consumes_no_final_drop"
          `Quick test_mutable_collection_eq_tail_consumes_without_final_drop;
        Alcotest.test_case
          "mutable_tail_consumes_after_assignment_no_final_drop" `Quick
          test_mutable_tail_consumes_after_assignment_without_final_drop;
        Alcotest.test_case "mutable_protected_tail_consume_scope_drop" `Quick
          test_mutable_protected_tail_consume_drops_scope_owner;
        Alcotest.test_case "mutable_final_borrow_keeps_scope_drop" `Quick
          test_mutable_final_borrow_keeps_scope_drop;
        Alcotest.test_case
          "mutable_assignment_match_scrutinee_consumes_no_old_release" `Quick
          test_mutable_assignment_match_scrutinee_consumes_target_skips_old_release;
        Alcotest.test_case "discard_assignment_alias_no_retain" `Quick
          test_discard_assignment_alias_does_not_retain_owned_result;
        Alcotest.test_case "sequence_alias_retains_source_before_mutable_drop"
          `Quick test_sequence_alias_binding_retains_source_before_mutable_drop;
        Alcotest.test_case "cow_field_arg_retains_alias" `Quick
          test_cow_consuming_field_arg_retains_alias;
        Alcotest.test_case "builtin_cow_field_arg_retains_alias" `Quick
          test_builtin_cow_consuming_field_arg_retains_alias;
        Alcotest.test_case "two_uses_one_dup" `Quick test_insert_drops_two_uses;
        Alcotest.test_case "three_uses_two_dups" `Quick
          test_insert_drops_three_uses;
        Alcotest.test_case "borrowed_intrinsic_drop_after" `Quick
          test_insert_drops_borrowed_intrinsic_drops_after;
        Alcotest.test_case "string_eq_nested_branch_borrows" `Quick
          test_insert_drops_string_eq_borrows_in_nested_branch;
        Alcotest.test_case "string_runtime_builtin_borrows_arg" `Quick
          test_insert_drops_string_runtime_builtin_borrows_arg;
        Alcotest.test_case "channel_send_retains_payload_arg" `Quick
          test_insert_drops_channel_send_retains_payload_arg;
        Alcotest.test_case "channel_send_status_retains_payload_args" `Quick
          test_insert_drops_channel_send_status_retains_payload_args;
        Alcotest.test_case "channel_recv_borrows_channel_arg" `Quick
          test_insert_drops_channel_recv_borrows_channel_arg;
        Alcotest.test_case "borrowed_cast_arg_drop_after" `Quick
          test_insert_drops_borrowed_cast_arg_drops_after;
        Alcotest.test_case "field_access_borrows_owner" `Quick
          test_insert_drops_field_access_borrows_owner;
        Alcotest.test_case "borrowed_loop_body_drop_after" `Quick
          test_insert_drops_borrowed_loop_body_drops_after;
        Alcotest.test_case "borrowed_while_body_drop_after" `Quick
          test_insert_drops_borrowed_while_body_drops_after;
        Alcotest.test_case "consuming_while_body_preserves_owner" `Quick
          test_insert_drops_consuming_while_body_preserves_owner_each_iteration;
        Alcotest.test_case "foreign_call_borrows" `Quick
          test_insert_drops_foreign_call_borrows;
        Alcotest.test_case "cow_consume_intrinsic" `Quick
          test_insert_drops_cow_consume_intrinsic_no_extra_drop;
        Alcotest.test_case "aliasing_intrinsic_result" `Quick
          test_insert_drops_aliasing_intrinsic_result_no_post_drop;
        Alcotest.test_case "consume_then_borrow_intrinsics" `Quick
          test_insert_drops_consume_then_borrow_intrinsics;
        Alcotest.test_case "borrow_let_alias_not_owned" `Quick
          test_borrow_let_alias_does_not_own_alias;
        Alcotest.test_case "detach_capture_drops_original" `Quick
          test_detach_capture_drops_original_after_spawn;
        Alcotest.test_case "if_both_unused" `Quick test_if_both_branches_unused;
        Alcotest.test_case "if_asymmetric" `Quick test_if_asymmetric_use;
        Alcotest.test_case "if_symmetric_single" `Quick
          test_if_symmetric_single_use;
        Alcotest.test_case "if_borrowed_unused" `Quick
          test_if_borrowed_then_unused_else;
        Alcotest.test_case "if_borrowed_cow" `Quick
          test_if_borrowed_vs_cow_consuming;
        Alcotest.test_case "if_alias_return_structured_branch" `Quick
          test_if_alias_return_uses_structured_branch_summary;
        Alcotest.test_case "nested_branch_alias_return_structured" `Quick
          test_nested_branch_alias_return_uses_structured_branch_summary;
        Alcotest.test_case "if_asymmetric_multi" `Quick test_if_asymmetric_multi;
        Alcotest.test_case "match_all_unused" `Quick test_match_all_arms_unused;
        Alcotest.test_case "match_asymmetric" `Quick test_match_asymmetric;
        Alcotest.test_case "match_alias_return_structured_branch" `Quick
          test_match_alias_return_uses_structured_branch_summary;
        Alcotest.test_case "match_sym_single" `Quick
          test_match_symmetric_single_use;
        Alcotest.test_case "match_borrowed_unused" `Quick
          test_match_borrowed_arm_unused_arm;
        Alcotest.test_case "match_aliasing_scrutinee" `Quick
          test_match_aliasing_scrutinee_post_drops_owner;
        Alcotest.test_case "tree_all_unused" `Quick
          test_match_tree_all_leaves_unused;
        Alcotest.test_case "tree_asymmetric" `Quick test_match_tree_asymmetric;
        Alcotest.test_case "tree_borrowed_unused" `Quick
          test_match_tree_borrowed_leaf_unused_leaf;
        Alcotest.test_case "tree_alias_return_structured_branch" `Quick
          test_match_tree_alias_return_uses_structured_branch_summary;
        Alcotest.test_case "tree_shadowed_alias_leaf_freshens_rc" `Quick
          test_match_tree_shadowed_alias_leaf_freshens_rc_targets;
        Alcotest.test_case "nested_tree_shadowed_alias_leaf_balanced" `Quick
          test_nested_match_shadowed_alias_leaf_balances_inner_branch;
        Alcotest.test_case "tree_aliasing_scrutinee" `Quick
          test_match_tree_aliasing_scrutinee_post_drops_owner;
        Alcotest.test_case "tree_local_scrutinee_post_drop" `Quick
          test_match_tree_local_scrutinee_post_drops_owner;
        Alcotest.test_case "tree_record_literal_borrowed_binding" `Quick
          test_match_tree_record_literal_retains_borrowed_binding;
        Alcotest.test_case "tree_record_literal_borrowed_field" `Quick
          test_match_tree_record_literal_retains_borrowed_field;
        Alcotest.test_case "tree_match_alias_result_binding" `Quick
          test_match_alias_result_binding_retains_binding;
        Alcotest.test_case "tree_match_field_result_binding" `Quick
          test_match_field_result_binding_retains_binding;
        Alcotest.test_case "tree_match_aliasing_call_result_binding" `Quick
          test_match_aliasing_call_result_binding_retains_result;
        Alcotest.test_case "tree_list_eq_retains_borrowed_payload" `Quick
          test_match_tree_list_eq_retains_borrowed_payload;
        Alcotest.test_case "tree_handoff_retains_borrowed_payload" `Quick
          test_match_tree_handoff_store_retains_borrowed_payload;
      ] );
    ( "program",
      [
        Alcotest.test_case "function_body" `Quick
          test_insert_drops_program_function_body;
        Alcotest.test_case "function_alias_global_symbol" `Quick
          test_program_function_alias_does_not_retain_global_symbol;
        Alcotest.test_case "closure_call_borrows_callee" `Quick
          test_program_closure_call_borrows_callee_and_drops_local_closure;
        Alcotest.test_case "closure_call_drops_temporary_callee" `Quick
          test_program_closure_call_binds_and_drops_temporary_callee;
        Alcotest.test_case "closure_call_borrows_managed_args" `Quick
          test_program_closure_call_borrows_managed_args;
        Alcotest.test_case "zero_capture_lambda_callback_not_owned_temp" `Quick
          test_program_zero_capture_lambda_callback_is_not_owned_temp;
        Alcotest.test_case "read_only_user_call_borrows" `Quick
          test_program_infers_read_only_user_call_borrows;
        Alcotest.test_case "nested_consuming_user_call_retains_source" `Quick
          test_program_nested_consuming_user_call_retains_immutable_source;
        Alcotest.test_case "loop_var_consuming_user_call_retains_owner" `Quick
          test_program_loop_var_consuming_user_call_retains_loop_owner;
        Alcotest.test_case "borrowed_temp_user_call_drop" `Quick
          test_program_drops_borrowed_owned_temporary_user_call_arg;
        Alcotest.test_case "retained_temp_builtin_call_drop" `Quick
          test_program_drops_retained_owned_temporary_builtin_arg;
        Alcotest.test_case "retained_let_temp_builtin_call_drop" `Quick
          test_program_drops_retained_owned_temporary_returned_from_let;
        Alcotest.test_case "stream_pipeline_temp_drop" `Quick
          test_program_drops_stream_pipeline_owned_temporaries;
        Alcotest.test_case "for_iter_borrows_collection" `Quick
          test_program_infers_for_iter_borrows_collection;
        Alcotest.test_case "alias_binding_read_helper_borrows" `Quick
          test_program_infers_alias_binding_read_helper_borrows;
        Alcotest.test_case "boxed_read_helper_borrows" `Quick
          test_program_infers_boxed_read_helper_borrows;
        Alcotest.test_case "passthrough_user_call_borrows" `Quick
          test_program_infers_passthrough_user_call_borrows;
        Alcotest.test_case "cow_wrapper_consumes_receiver" `Quick
          test_program_infers_cow_wrapper_consumes_receiver;
        Alcotest.test_case "borrow_then_cow_param_no_dup" `Quick
          test_program_borrow_then_cow_param_does_not_dup_before_cow;
        Alcotest.test_case "cow_param_before_loop_no_dup" `Quick
          test_program_cow_param_before_loop_does_not_dup_before_cow;
        Alcotest.test_case "field_return_owned_contract" `Quick
          test_program_field_return_borrows_parent_and_returns_owned;
        Alcotest.test_case "field_return_retains" `Quick
          test_program_field_return_retains_before_return;
        Alcotest.test_case "record_literal_retains_borrowed_param_field" `Quick
          test_program_record_literal_retains_borrowed_param_field;
        Alcotest.test_case "param_return_retains" `Quick
          test_program_param_return_retains_before_return;
        Alcotest.test_case "lambda_param_return_retains" `Quick
          test_program_lambda_param_return_retains_before_closure_conversion;
        Alcotest.test_case "unbox_alias_return_retains" `Quick
          test_program_unbox_alias_return_retains_before_return;
        Alcotest.test_case "lambda_field_return_retains" `Quick
          test_program_lambda_field_return_retains_before_closure_conversion;
        Alcotest.test_case "constructor_contract_transfers_payload" `Quick
          test_program_constructor_contract_transfers_payload;
        Alcotest.test_case "constructor_retains_borrowed_param" `Quick
          test_program_constructor_retains_borrowed_param;
        Alcotest.test_case "constructor_retains_borrowed_match_payload" `Quick
          test_program_constructor_retains_borrowed_match_payload;
        Alcotest.test_case "constructor_retains_borrowed_lambda_param" `Quick
          test_program_constructor_retains_borrowed_lambda_param;
        Alcotest.test_case "constructor_assignment_retains_mutable_local" `Quick
          test_program_constructor_assignment_retains_mutable_local;
      ] );
  ]
