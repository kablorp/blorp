(** Unit tests for [Core_invariants] (Phase 2.2).

    Each check is tested two ways:
      - A valid program produces no violations.
      - A deliberately constructed invalid program produces one
        violation per offending node, and the message identifies the
        problem.

    The dispatcher [run_for_stage] is tested separately — it picks the
    right checks for each stage, and stages with no enabled checks
    return an empty list. *)

open Blorp
open Blorp.Ast
open Blorp.Core

let loc =
  { line = 1; column = 1; end_line = 1; end_column = 1; loc_file = None }

let ty_int = TyNamed ("Int", [])
let ty_float = TyNamed ("Float", [])
let ty_bool = TyNamed ("Bool", [])
let ty_string = TyNamed ("String", [])
let ty_void = TyNamed ("Void", [])
let ty_test_resource = TyNamed ("TestResource", [])
let ty_resource_holder = TyNamed ("ResourceHolder", [])
let ty_resource_box = TyNamed ("ResourceBox", [])
let ty_list_int = TyNamed ("List", [ ty_int ])
let ty_concurrency_error = TyNamed ("ConcurrencyError", [])
let ty_vector_int_4 = TyNamed ("Vector", [ ty_int; TyConstInt 4 ])
let ty_vector_float_4 = TyNamed ("Vector", [ ty_float; TyConstInt 4 ])
let ty_dict_int_int = TyNamed ("Dict", [ ty_int; ty_int ])

let ty_fn_int_int =
  TyFunc { params = [ ty_int ]; return = ty_int; is_pure = true }

let mk d t = { desc = d; ty = t; loc }
let mk_call k fn args ret_ty = mk (CCall (k, fn, args)) ret_ty

let mk_simple_func ~name ~body =
  {
    cf_name = name;
    cf_module = None;
    cf_type_params = [];
    cf_params = [];
    cf_return_ty = ty_int;
    cf_body = Some body;
    cf_is_pure = false;
    cf_kind = CFUser;
    cf_def_id = 0;
  }

let mk_prog decls : core_program =
  List.map (fun d -> { cd_desc = d; cd_loc = loc; cd_doc = None }) decls

let ty_result ok_ty = TyNamed ("Result", [ ok_ty; ty_concurrency_error ])
let ty_list elem_ty = TyNamed ("List", [ elem_ty ])

let task_closure ?(name = "_blorp_task_test") ?(def_id = 9000) ?(captures = [])
    return_ty =
  {
    tc_func = name;
    tc_def_id = def_id;
    tc_captures = task_copy_captures captures;
    tc_return_ty = return_ty;
  }

let type_alias_decl name target =
  { alias_name = name; alias_type_params = []; alias_target = target }

let resource_type_decl =
  {
    type_name = "TestResource";
    type_params = [];
    type_variants = [];
    type_is_enum = false;
    type_is_builtin = true;
    type_is_resource = true;
    type_resource_cleanup = None;
  }

let resource_holder_record_decl =
  {
    record_name = "ResourceHolder";
    record_type_params = [];
    record_fields =
      [
        {
          field_name = "handle";
          field_type = ty_test_resource;
          field_loc = loc;
        };
      ];
    record_is_value = false;
    record_is_builtin = false;
  }

let resource_box_type_decl =
  {
    type_name = "ResourceBox";
    type_params = [];
    type_variants =
      [
        {
          variant_name = "Box";
          variant_fields = [ ty_test_resource ];
          variant_tag = 0;
          variant_loc = loc;
          variant_def_id = None;
        };
        {
          variant_name = "Empty";
          variant_fields = [];
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

let var_with_def_id name id = { (Var.named name) with vdef_id = Some id }

let boxed_int n =
  mk
    (CBoxTyped
       {
         box_value = mk (CLit (LitInt (Int64.of_int n))) ty_int;
         box_source_ty = ty_int;
         box_kind = BoxPrim;
       })
    ty_void

let cint n = mk (CLit (LitInt (Int64.of_int n))) ty_int

(* ============================================================================
   Post-specialize: no CKUnknown in user code
   ============================================================================ *)

let test_ckunknown_passes_on_valid_program () =
  let fn = mk (CVar (Var.named "f")) ty_int in
  let call = mk_call (CKUser ("f", None)) fn [] ty_int in
  let body = call in
  let prog = mk_prog [ CDFunc (mk_simple_func ~name:"main" ~body) ] in
  let violations = Core_invariants.check_no_ckunknown prog in
  Alcotest.(check int) "no violations" 0 (List.length violations)

let test_ckunknown_flags_unresolved_call () =
  let fn = mk (CVar (Var.named "mystery")) ty_int in
  let call = mk_call CKUnknown fn [] ty_int in
  let prog = mk_prog [ CDFunc (mk_simple_func ~name:"main" ~body:call) ] in
  let violations = Core_invariants.check_no_ckunknown prog in
  Alcotest.(check int) "one violation" 1 (List.length violations);
  match violations with
  | [ v ] ->
      Alcotest.(check bool)
        "mentions unresolved call" true
        (Modules.contains v.Core_error.msg "unresolved call target");
      Alcotest.(check bool)
        "phase tag is Specialize" true
        (v.Core_error.phase = Core_error.Stage Core_stage.Specialize)
  | _ -> Alcotest.fail "unreachable"

let test_ckselected_direct_flags_unresolved_call () =
  let fn = mk (CVar (Var.named "selected")) ty_int in
  let call = mk_call (CKSelectedDirect 123) fn [] ty_int in
  let prog = mk_prog [ CDFunc (mk_simple_func ~name:"main" ~body:call) ] in
  let violations = Core_invariants.check_no_ckunknown prog in
  Alcotest.(check int) "one violation" 1 (List.length violations);
  match violations with
  | [ v ] ->
      Alcotest.(check bool)
        "mentions unresolved call" true
        (Modules.contains v.Core_error.msg "unresolved call target")
  | _ -> Alcotest.fail "unreachable"

let test_ckunknown_walks_into_nested () =
  (* CKUnknown deep inside a let body must also surface. *)
  let fn = mk (CVar (Var.named "g")) ty_int in
  let call = mk_call CKUnknown fn [] ty_int in
  let bind =
    {
      bind_var = Var.named "x";
      bind_mut = false;
      bind_ty = ty_int;
      bind_rhs = mk (CLit (LitInt 1L)) ty_int;
    }
  in
  let body = mk (CLet (bind, call)) ty_int in
  let prog = mk_prog [ CDFunc (mk_simple_func ~name:"main" ~body) ] in
  let violations = Core_invariants.check_no_ckunknown prog in
  Alcotest.(check int) "one violation under let" 1 (List.length violations)

let test_layoutless_list_alloc_flags_post_specialize () =
  let cap = mk (CLit (LitInt 4L)) ty_int in
  let alloc =
    mk_call (CKIntrinsic "list_alloc") (mk CVoid ty_void) [ cap ] ty_list_int
  in
  let prog = mk_prog [ CDFunc (mk_simple_func ~name:"main" ~body:alloc) ] in
  let violations =
    Core_invariants.check_no_layoutless_list_alloc_at Core_stage.Specialize prog
  in
  Alcotest.(check int) "one violation" 1 (List.length violations);
  match violations with
  | [ v ] ->
      Alcotest.(check bool)
        "mentions list_alloc" true
        (Modules.contains v.Core_error.msg "list_alloc")
  | _ -> Alcotest.fail "unreachable"

let test_layoutless_builtin_list_alloc_flags_post_specialize () =
  let cap = mk (CLit (LitInt 4L)) ty_int in
  let alloc =
    mk_call (CKBuiltin "blorp_list_new") (mk CVoid ty_void) [ cap ] ty_list_int
  in
  let prog = mk_prog [ CDFunc (mk_simple_func ~name:"main" ~body:alloc) ] in
  let violations =
    Core_invariants.check_no_layoutless_list_alloc_at Core_stage.Specialize prog
  in
  Alcotest.(check int) "one violation" 1 (List.length violations);
  match violations with
  | [ v ] ->
      Alcotest.(check bool)
        "mentions blorp_list_new" true
        (Modules.contains v.Core_error.msg "blorp_list_new")
  | _ -> Alcotest.fail "unreachable"

let test_dispatcher_specialize_runs_layout_check () =
  let cap = mk (CLit (LitInt 4L)) ty_int in
  let alloc =
    mk_call (CKIntrinsic "list_alloc") (mk CVoid ty_void) [ cap ] ty_list_int
  in
  let prog = mk_prog [ CDFunc (mk_simple_func ~name:"main" ~body:alloc) ] in
  let violations = Core_invariants.run_for_stage Core_stage.Specialize prog in
  Alcotest.(check int) "one violation" 1 (List.length violations)

(* ============================================================================
   Post-mono: no TyVar in user-function call arg types
   ============================================================================ *)

let test_tyvar_passes_when_monomorphized () =
  let fn = mk (CVar (Var.named "id")) ty_int in
  let arg = mk (CLit (LitInt 5L)) ty_int in
  let call = mk_call (CKUser ("id", None)) fn [ arg ] ty_int in
  let prog = mk_prog [ CDFunc (mk_simple_func ~name:"main" ~body:call) ] in
  let violations = Core_invariants.check_no_tyvar_leak prog in
  Alcotest.(check int) "no violations" 0 (List.length violations)

let test_tyvar_flags_unmonomorphized_call () =
  (* A CCall whose arg type carries TyVar "T" — mono failed to specialize *)
  let t_var = TyVar "T" in
  let fn = mk (CVar (Var.named "id")) t_var in
  let arg = mk (CVar (Var.named "x")) t_var in
  let call = mk_call (CKUser ("id", None)) fn [ arg ] t_var in
  let prog = mk_prog [ CDFunc (mk_simple_func ~name:"main" ~body:call) ] in
  let violations = Core_invariants.check_no_tyvar_leak prog in
  Alcotest.(check bool)
    "at least one violation" true
    (List.length violations >= 1);
  match violations with
  | v :: _ ->
      Alcotest.(check bool)
        "mentions TyVar" true
        (Modules.contains v.Core_error.msg "type variable");
      Alcotest.(check bool)
        "phase tag is Mono" true
        (v.Core_error.phase = Core_error.Stage Core_stage.Mono)
  | [] -> Alcotest.fail "unreachable"

let test_tyvar_ignores_builtin_calls () =
  (* A CKBuiltin call is allowed to carry generic types (the runtime
     function accepts any). The check only fires for CKUser calls. *)
  let t_var = TyVar "T" in
  let fn = mk (CVar (Var.named "blorp_list_get")) t_var in
  let arg = mk (CVar (Var.named "lst")) t_var in
  let call = mk_call (CKBuiltin "blorp_list_get") fn [ arg ] t_var in
  let prog = mk_prog [ CDFunc (mk_simple_func ~name:"main" ~body:call) ] in
  let violations = Core_invariants.check_no_tyvar_leak prog in
  Alcotest.(check int) "no violations for builtin" 0 (List.length violations)

(* ============================================================================
   Post-debug: no debug blocks survive
   ============================================================================ *)

let debug_block_body () =
  let dbg = mk (CDebugBlock (mk CVoid ty_void)) ty_void in
  mk (CSeq (dbg, mk (CLit (LitInt 0L)) ty_int)) ty_int

let test_debug_check_flags_debug_block () =
  let prog =
    mk_prog [ CDFunc (mk_simple_func ~name:"main" ~body:(debug_block_body ())) ]
  in
  let violations =
    Core_invariants.check_no_debug_blocks_at Core_stage.Debug prog
  in
  Alcotest.(check int) "one violation" 1 (List.length violations);
  match violations with
  | [ v ] ->
      Alcotest.(check bool)
        "mentions debug block" true
        (Modules.contains v.Core_error.msg "debug block")
  | _ -> Alcotest.fail "expected one debug-block violation"

let test_debug_check_passes_on_clean_program () =
  let body =
    mk (CSeq (mk CVoid ty_void, mk (CLit (LitInt 0L)) ty_int)) ty_int
  in
  let prog = mk_prog [ CDFunc (mk_simple_func ~name:"main" ~body) ] in
  let violations =
    Core_invariants.check_no_debug_blocks_at Core_stage.Debug prog
  in
  Alcotest.(check int) "no violations" 0 (List.length violations)

(* ============================================================================
   Post-desugar: no sugar nodes (CStringInterp / CRecordUpdate). The dispatcher
   also runs this check at Desugar and Perceus as a bookend.
   ============================================================================ *)

let test_sugar_check_flags_cstringinterp () =
  let parts = [ IPLit "hi" ] in
  let node = mk (CStringInterp (parts, false)) (TyNamed ("String", [])) in
  let prog = mk_prog [ CDFunc (mk_simple_func ~name:"main" ~body:node) ] in
  let violations = Core_invariants.check_no_sugar prog in
  Alcotest.(check int) "one violation" 1 (List.length violations);
  match violations with
  | [ v ] ->
      Alcotest.(check bool)
        "mentions CStringInterp" true
        (Modules.contains v.Core_error.msg "CStringInterp")
  | _ -> Alcotest.fail "unreachable"

let test_sugar_check_passes_on_clean_program () =
  let body = mk (CLit (LitInt 42L)) ty_int in
  let prog = mk_prog [ CDFunc (mk_simple_func ~name:"main" ~body) ] in
  let violations = Core_invariants.check_no_sugar prog in
  Alcotest.(check int) "no violations" 0 (List.length violations)

let bind ?(mut = false) name ty rhs =
  { bind_var = Var.named name; bind_mut = mut; bind_ty = ty; bind_rhs = rhs }

let test_mutation_check_flags_no_assignment_mutable_let () =
  let body =
    mk
      (CLet
         ( bind ~mut:true "x" ty_int (mk (CLit (LitInt 1L)) ty_int),
           mk (CVar (Var.named "x")) ty_int ))
      ty_int
  in
  let prog = mk_prog [ CDFunc (mk_simple_func ~name:"main" ~body) ] in
  let violations = Core_invariants.check_no_desugarable_mutation prog in
  Alcotest.(check int) "one violation" 1 (List.length violations);
  match violations with
  | [ v ] ->
      Alcotest.(check bool)
        "mentions mutable binding" true
        (Modules.contains v.Core_error.msg "mutable local binding");
      Alcotest.(check bool)
        "phase tag is Desugar" true
        (v.Core_error.phase = Core_error.Stage Core_stage.Desugar)
  | _ -> Alcotest.fail "unreachable"

let test_mutation_check_flags_straight_line_assignment () =
  let assign =
    mk (CAssign (Var.named "x", mk (CLit (LitInt 2L)) ty_int)) ty_void
  in
  let body =
    mk
      (CLet
         ( bind ~mut:true "x" ty_int (mk (CLit (LitInt 1L)) ty_int),
           mk (CSeq (assign, mk (CVar (Var.named "x")) ty_int)) ty_int ))
      ty_int
  in
  let prog = mk_prog [ CDFunc (mk_simple_func ~name:"main" ~body) ] in
  let violations = Core_invariants.check_no_desugarable_mutation prog in
  Alcotest.(check int) "one violation" 1 (List.length violations);
  match violations with
  | [ v ] ->
      Alcotest.(check bool)
        "mentions straight-line" true
        (Modules.contains v.Core_error.msg "straight-line mutable assignment")
  | _ -> Alcotest.fail "unreachable"

let test_mutation_check_allows_control_flow_assignment () =
  let assign =
    mk (CAssign (Var.named "x", mk (CLit (LitInt 2L)) ty_int)) ty_void
  in
  let branch =
    mk
      (CIf (mk (CLit (LitBool true)) ty_bool, assign, mk CVoid ty_void))
      ty_void
  in
  let body =
    mk
      (CLet (bind ~mut:true "x" ty_int (mk (CLit (LitInt 1L)) ty_int), branch))
      ty_void
  in
  let prog = mk_prog [ CDFunc (mk_simple_func ~name:"main" ~body) ] in
  let violations = Core_invariants.check_no_desugarable_mutation prog in
  Alcotest.(check int)
    "control-flow mutation is not this invariant" 0 (List.length violations)

let test_dispatcher_desugar_runs_mutation_check () =
  let body =
    mk
      (CLet
         ( bind ~mut:true "x" ty_int (mk (CLit (LitInt 1L)) ty_int),
           mk (CVar (Var.named "x")) ty_int ))
      ty_int
  in
  let prog = mk_prog [ CDFunc (mk_simple_func ~name:"main" ~body) ] in
  let violations = Core_invariants.run_for_stage Core_stage.Desugar prog in
  Alcotest.(check bool)
    "desugar flags mutable local" true
    (List.exists
       (fun v -> Modules.contains v.Core_error.msg "mutable local binding")
       violations)

(* ============================================================================
   Post-match: no raw CMatchArms survives
   ============================================================================ *)

let test_match_check_flags_raw_cmatcharms () =
  let scrut = mk (CLit (LitInt 1L)) ty_int in
  let arms = [ (PatLiteral (LitInt 1L), mk (CLit (LitInt 0L)) ty_int) ] in
  let node = mk (CMatchArms (scrut, arms)) ty_int in
  let prog = mk_prog [ CDFunc (mk_simple_func ~name:"main" ~body:node) ] in
  let violations = Core_invariants.check_no_cmatcharms prog in
  Alcotest.(check int) "one violation" 1 (List.length violations)

let test_match_check_passes_on_decision_tree () =
  let scrut = mk (CLit (LitInt 1L)) ty_int in
  let leaf =
    CTLeaf { ct_bindings = []; ct_body = mk (CLit (LitInt 0L)) ty_int }
  in
  let node = mk (CMatch (scrut, leaf)) ty_int in
  let prog = mk_prog [ CDFunc (mk_simple_func ~name:"main" ~body:node) ] in
  let violations = Core_invariants.check_no_cmatcharms prog in
  Alcotest.(check int) "no violations" 0 (List.length violations)

(* ============================================================================
   Dispatcher: run_for_stage picks the right checks
   ============================================================================ *)

let test_dispatcher_resolve_allows_ckunknown () =
  let fn = mk (CVar (Var.named "mystery")) ty_int in
  let call = mk_call CKUnknown fn [] ty_int in
  let prog = mk_prog [ CDFunc (mk_simple_func ~name:"main" ~body:call) ] in
  let violations = Core_invariants.run_for_stage Core_stage.Resolve prog in
  Alcotest.(check int)
    "Resolve leaves specialize-owned calls alone" 0 (List.length violations)

let test_dispatcher_specialize_runs_ckunknown_check () =
  let fn = mk (CVar (Var.named "mystery")) ty_int in
  let call = mk_call CKUnknown fn [] ty_int in
  let prog = mk_prog [ CDFunc (mk_simple_func ~name:"main" ~body:call) ] in
  let violations = Core_invariants.run_for_stage Core_stage.Specialize prog in
  Alcotest.(check bool) "fires at Specialize" true (List.length violations >= 1)

let test_dispatcher_debug_fires_check () =
  let prog =
    mk_prog [ CDFunc (mk_simple_func ~name:"main" ~body:(debug_block_body ())) ]
  in
  let violations = Core_invariants.run_for_stage Core_stage.Debug prog in
  Alcotest.(check bool) "debug fires check" true (List.length violations >= 1)

let test_dispatcher_empty_for_unchecked_stages () =
  (* Stages without enabled invariants return empty. Lower is one of
     those today (no checks drafted yet). *)
  let body = mk (CLit (LitInt 1L)) ty_int in
  let prog = mk_prog [ CDFunc (mk_simple_func ~name:"main" ~body) ] in
  let violations = Core_invariants.run_for_stage Core_stage.Lower prog in
  Alcotest.(check int) "lower has no checks" 0 (List.length violations)

let test_dispatcher_match_fires_check () =
  (* Phase 2.5: check_no_cmatcharms enabled at Match. Raw CMatchArms in
     post-match IR is a violation. *)
  let scrut = mk (CLit (LitInt 1L)) ty_int in
  let arms = [ (PatLiteral (LitInt 1L), mk (CLit (LitInt 0L)) ty_int) ] in
  let node = mk (CMatchArms (scrut, arms)) ty_int in
  let prog = mk_prog [ CDFunc (mk_simple_func ~name:"main" ~body:node) ] in
  let violations = Core_invariants.run_for_stage Core_stage.Match prog in
  Alcotest.(check bool) "match fires check" true (List.length violations >= 1)

let test_dispatcher_desugar_fires () =
  (* Phase 2.4 enabled check_no_sugar at the Desugar stage — sugar
     surviving should now be reported as a violation. *)
  let parts = [ IPLit "hi" ] in
  let node = mk (CStringInterp (parts, false)) (TyNamed ("String", [])) in
  let prog = mk_prog [ CDFunc (mk_simple_func ~name:"main" ~body:node) ] in
  let violations = Core_invariants.run_for_stage Core_stage.Desugar prog in
  Alcotest.(check bool) "sugar flagged" true (List.length violations >= 1)

let tensor_raw_view_source = mk (CVar (Var.named "xs")) ty_vector_float_4

let tensor_raw_view_binding =
  {
    trv_var = Var.named "__raw";
    trv_kind = TensorFloat64Elements;
    trv_source = tensor_raw_view_source;
  }

let tensor_raw_index = mk (CLit (LitInt 0L)) ty_int

let test_raw_tensor_view_invariant_accepts_scoped_matching_view () =
  let read =
    mk
      (CTensorRawRead
         {
           trr_view = tensor_raw_view_binding.trv_var;
           trr_kind = TensorFloat64Elements;
           trr_index = tensor_raw_index;
         })
      ty_float
  in
  let body = mk (CTensorRawViewLet (tensor_raw_view_binding, read)) ty_float in
  let prog = mk_prog [ CDFunc (mk_simple_func ~name:"main" ~body) ] in
  let violations =
    Core_invariants.check_raw_tensor_views_at Core_stage.Specialize prog
  in
  Alcotest.(check int) "no violations" 0 (List.length violations)

let test_raw_tensor_view_invariant_accepts_alias_source () =
  let source = mk (CVar (Var.named "xs")) (TyNamed ("Positions", [])) in
  let binding = { tensor_raw_view_binding with trv_source = source } in
  let read =
    mk
      (CTensorRawRead
         {
           trr_view = binding.trv_var;
           trr_kind = TensorFloat64Elements;
           trr_index = tensor_raw_index;
         })
      ty_float
  in
  let body = mk (CTensorRawViewLet (binding, read)) ty_float in
  let prog =
    mk_prog
      [
        CDTypeAlias
          (type_alias_decl "Positions"
             (TyNamed ("Vector", [ ty_float; TyConstInt 4 ])));
        CDFunc (mk_simple_func ~name:"main" ~body);
      ]
  in
  let violations =
    Core_invariants.check_raw_tensor_views_at Core_stage.Specialize prog
  in
  Alcotest.(check int) "no violations" 0 (List.length violations)

let test_raw_tensor_view_invariant_flags_unbound_view () =
  let read =
    mk
      (CTensorRawRead
         {
           trr_view = Var.named "__missing_raw";
           trr_kind = TensorFloat64Elements;
           trr_index = tensor_raw_index;
         })
      ty_float
  in
  let prog = mk_prog [ CDFunc (mk_simple_func ~name:"main" ~body:read) ] in
  let violations =
    Core_invariants.check_raw_tensor_views_at Core_stage.Specialize prog
  in
  Alcotest.(check int) "one violation" 1 (List.length violations);
  match violations with
  | [ v ] ->
      Alcotest.(check bool)
        "mentions unbound view" true
        (Modules.contains v.Core_error.msg "unbound view")
  | _ -> Alcotest.fail "unreachable"

let test_raw_tensor_view_invariant_flags_kind_mismatch () =
  let read =
    mk
      (CTensorRawRead
         {
           trr_view = tensor_raw_view_binding.trv_var;
           trr_kind = TensorInt64Elements;
           trr_index = tensor_raw_index;
         })
      ty_int
  in
  let body = mk (CTensorRawViewLet (tensor_raw_view_binding, read)) ty_int in
  let prog = mk_prog [ CDFunc (mk_simple_func ~name:"main" ~body) ] in
  let violations =
    Core_invariants.check_raw_tensor_views_at Core_stage.Specialize prog
  in
  Alcotest.(check int) "one violation" 1 (List.length violations);
  match violations with
  | [ v ] ->
      Alcotest.(check bool)
        "mentions kind mismatch" true
        (Modules.contains v.Core_error.msg "does not match")
  | _ -> Alcotest.fail "unreachable"

let tensor_var = mk (CVar (Var.named "values")) ty_vector_float_4
let tensor_other_var = mk (CVar (Var.named "other_values")) ty_vector_float_4
let tensor_int_var = mk (CVar (Var.named "int_values")) ty_vector_int_4

let tensor_raw_get_f64_from source index =
  mk_call (CKIntrinsic "tensor_get_f64_raw_unchecked") (mk CVoid ty_void)
    [ source; index ] ty_float

let tensor_raw_get_f64 index = tensor_raw_get_f64_from tensor_var index

let tensor_raw_get_f64_as_int index =
  mk_call (CKIntrinsic "tensor_get_f64_raw_unchecked") (mk CVoid ty_void)
    [ tensor_var; index ] ty_int

let tensor_safe_get_f64_from source index =
  mk_call (CKIntrinsic "tensor_get_f64") (mk CVoid ty_void) [ source; index ]
    ty_float

let tensor_safe_get_f64 index = tensor_safe_get_f64_from tensor_var index

let tensor_storage_guard_f64_for source =
  mk_call (CKIntrinsic "tensor_is_f64_storage") (mk CVoid ty_void) [ source ]
    ty_bool

let tensor_storage_guard_f64 = tensor_storage_guard_f64_for tensor_var

let test_final_rejects_unguarded_raw_tensor_get_intrinsic () =
  let body = tensor_raw_get_f64 tensor_raw_index in
  let prog = mk_prog [ CDFunc (mk_simple_func ~name:"main" ~body) ] in
  let violations = Core_invariants.run_for_stage Core_stage.Final prog in
  Alcotest.(check int) "one violation" 1 (List.length violations);
  match violations with
  | [ v ] ->
      Alcotest.(check bool)
        "mentions raw tensor intrinsic" true
        (Modules.contains v.Core_error.msg "raw tensor intrinsic");
      Alcotest.(check bool)
        "mentions storage guard" true
        (Modules.contains v.Core_error.msg "storage guard")
  | _ -> Alcotest.fail "unreachable"

let test_final_rejects_malformed_raw_tensor_get_intrinsic () =
  let body =
    mk_call (CKIntrinsic "tensor_get_f64_raw_unchecked") (mk CVoid ty_void)
      [ tensor_var ] ty_float
  in
  let prog = mk_prog [ CDFunc (mk_simple_func ~name:"main" ~body) ] in
  let violations = Core_invariants.run_for_stage Core_stage.Final prog in
  Alcotest.(check int) "one violation" 1 (List.length violations);
  match violations with
  | [ v ] ->
      Alcotest.(check bool)
        "mentions raw tensor intrinsic" true
        (Modules.contains v.Core_error.msg "raw tensor intrinsic");
      Alcotest.(check bool)
        "mentions arity" true
        (Modules.contains v.Core_error.msg "arity")
  | _ -> Alcotest.fail "unreachable"

let test_final_rejects_raw_string_byte_intrinsic () =
  let source = mk (CVar (Var.named "s")) ty_string in
  let body =
    mk_call (CKIntrinsic "string_get_byte") (mk CVoid ty_void)
      [ source; tensor_raw_index ]
      ty_int
  in
  let prog = mk_prog [ CDFunc (mk_simple_func ~name:"main" ~body) ] in
  let violations = Core_invariants.run_for_stage Core_stage.Final prog in
  Alcotest.(check int) "one violation" 1 (List.length violations);
  match violations with
  | [ v ] ->
      Alcotest.(check bool)
        "mentions unchecked string byte intrinsic" true
        (Modules.contains v.Core_error.msg "unchecked string byte intrinsic");
      Alcotest.(check bool)
        "mentions proof-carrying Core node" true
        (Modules.contains v.Core_error.msg "proof-carrying Core node")
  | _ -> Alcotest.fail "unreachable"

let test_perceus_rejects_intrinsic_without_ownership_contract () =
  let body =
    mk_call (CKIntrinsic "missing_ownership_contract") (mk CVoid ty_void)
      [ cint 1 ]
      ty_int
  in
  let prog = mk_prog [ CDFunc (mk_simple_func ~name:"main" ~body) ] in
  let violations = Core_invariants.run_for_stage Core_stage.Perceus prog in
  Alcotest.(check int) "one violation" 1 (List.length violations);
  match violations with
  | [ v ] ->
      Alcotest.(check bool)
        "mentions intrinsic" true
        (Modules.contains v.Core_error.msg "intrinsic");
      Alcotest.(check bool)
        "mentions ownership contract" true
        (Modules.contains v.Core_error.msg "ownership contract")
  | _ -> Alcotest.fail "unreachable"

let test_perceus_rejects_builtin_without_ownership_contract () =
  let body =
    mk_call (CKBuiltin "missing_ownership_contract") (mk CVoid ty_void)
      [ cint 1 ]
      ty_int
  in
  let prog = mk_prog [ CDFunc (mk_simple_func ~name:"main" ~body) ] in
  let violations = Core_invariants.run_for_stage Core_stage.Perceus prog in
  Alcotest.(check int) "one violation" 1 (List.length violations);
  match violations with
  | [ v ] ->
      Alcotest.(check bool)
        "mentions builtin" true
        (Modules.contains v.Core_error.msg "builtin");
      Alcotest.(check bool)
        "mentions ownership contract" true
        (Modules.contains v.Core_error.msg "ownership contract")
  | _ -> Alcotest.fail "unreachable"

let test_perceus_rejects_pre_perceus_sentinel_builtin () =
  let body =
    mk_call (CKBuiltin "blorp_eq_dispatch") (mk CVoid ty_void)
      [ cint 1; cint 1 ]
      ty_bool
  in
  let prog = mk_prog [ CDFunc (mk_simple_func ~name:"main" ~body) ] in
  let violations = Core_invariants.run_for_stage Core_stage.Perceus prog in
  Alcotest.(check int) "one violation" 1 (List.length violations);
  match violations with
  | [ v ] ->
      Alcotest.(check bool)
        "mentions pre-Perceus" true
        (Modules.contains v.Core_error.msg "pre-Perceus");
      Alcotest.(check bool)
        "mentions specialized before Perceus" true
        (Modules.contains v.Core_error.msg "specialized before Perceus")
  | _ -> Alcotest.fail "unreachable"

let test_final_accepts_guarded_raw_tensor_get_intrinsic () =
  let body =
    mk
      (CIf
         ( tensor_storage_guard_f64,
           tensor_raw_get_f64 tensor_raw_index,
           tensor_safe_get_f64 tensor_raw_index ))
      ty_float
  in
  let prog = mk_prog [ CDFunc (mk_simple_func ~name:"main" ~body) ] in
  let violations = Core_invariants.run_for_stage Core_stage.Final prog in
  Alcotest.(check int) "no violations" 0 (List.length violations)

let test_final_accepts_raw_tensor_get_inside_guarded_branch () =
  let body =
    mk
      (CIf
         ( tensor_storage_guard_f64,
           mk
             (CSeq (mk CVoid ty_void, tensor_raw_get_f64 tensor_raw_index))
             ty_float,
           tensor_safe_get_f64 tensor_raw_index ))
      ty_float
  in
  let prog = mk_prog [ CDFunc (mk_simple_func ~name:"main" ~body) ] in
  let violations = Core_invariants.run_for_stage Core_stage.Final prog in
  Alcotest.(check int) "no violations" 0 (List.length violations)

let test_final_accepts_conjunctive_guarded_raw_tensor_get_intrinsics () =
  let guarded_cond =
    mk
      (CLog
         ( Ast.And,
           tensor_storage_guard_f64,
           tensor_storage_guard_f64_for tensor_other_var ))
      ty_bool
  in
  let raw_body =
    mk
      (CBin
         ( Ast.Add,
           tensor_raw_get_f64 tensor_raw_index,
           tensor_raw_get_f64_from tensor_other_var tensor_raw_index ))
      ty_float
  in
  let safe_body =
    mk
      (CBin
         ( Ast.Add,
           tensor_safe_get_f64 tensor_raw_index,
           tensor_safe_get_f64_from tensor_other_var tensor_raw_index ))
      ty_float
  in
  let body = mk (CIf (guarded_cond, raw_body, safe_body)) ty_float in
  let prog = mk_prog [ CDFunc (mk_simple_func ~name:"main" ~body) ] in
  let violations = Core_invariants.run_for_stage Core_stage.Final prog in
  Alcotest.(check int) "no violations" 0 (List.length violations)

let test_final_rejects_guarded_raw_tensor_get_result_type_mismatch () =
  let body =
    mk
      (CIf
         ( tensor_storage_guard_f64,
           tensor_raw_get_f64_as_int tensor_raw_index,
           mk (CLit (LitInt 0L)) ty_int ))
      ty_int
  in
  let prog = mk_prog [ CDFunc (mk_simple_func ~name:"main" ~body) ] in
  let violations = Core_invariants.run_for_stage Core_stage.Final prog in
  Alcotest.(check int) "one violation" 1 (List.length violations);
  match violations with
  | [ v ] ->
      Alcotest.(check bool)
        "mentions result type" true
        (Modules.contains v.Core_error.msg "result type")
  | _ -> Alcotest.fail "unreachable"

let test_final_rejects_guarded_raw_tensor_get_source_type_mismatch () =
  let body =
    mk
      (CIf
         ( tensor_storage_guard_f64_for tensor_int_var,
           tensor_raw_get_f64_from tensor_int_var tensor_raw_index,
           tensor_safe_get_f64_from tensor_int_var tensor_raw_index ))
      ty_float
  in
  let prog = mk_prog [ CDFunc (mk_simple_func ~name:"main" ~body) ] in
  let violations = Core_invariants.run_for_stage Core_stage.Final prog in
  Alcotest.(check int) "one violation" 1 (List.length violations);
  match violations with
  | [ v ] ->
      Alcotest.(check bool)
        "mentions source type" true
        (Modules.contains v.Core_error.msg "source type")
  | _ -> Alcotest.fail "unreachable"

let test_final_rejects_mismatched_guarded_raw_tensor_get_intrinsic () =
  let wrong_guard =
    mk_call (CKIntrinsic "tensor_is_i64_storage") (mk CVoid ty_void)
      [ tensor_var ] ty_bool
  in
  let body =
    mk
      (CIf
         ( wrong_guard,
           tensor_raw_get_f64 tensor_raw_index,
           tensor_safe_get_f64 tensor_raw_index ))
      ty_float
  in
  let prog = mk_prog [ CDFunc (mk_simple_func ~name:"main" ~body) ] in
  let violations = Core_invariants.run_for_stage Core_stage.Final prog in
  Alcotest.(check int) "one violation" 1 (List.length violations)

let test_final_rejects_shadowed_guarded_raw_tensor_get_intrinsic () =
  let shadow_binding =
    {
      bind_var = Var.named "values";
      bind_mut = false;
      bind_ty = ty_vector_float_4;
      bind_rhs = mk (CVar (Var.named "other_values")) ty_vector_float_4;
    }
  in
  let body =
    mk
      (CIf
         ( tensor_storage_guard_f64,
           mk
             (CLet (shadow_binding, tensor_raw_get_f64 tensor_raw_index))
             ty_float,
           tensor_safe_get_f64 tensor_raw_index ))
      ty_float
  in
  let prog = mk_prog [ CDFunc (mk_simple_func ~name:"main" ~body) ] in
  let violations = Core_invariants.run_for_stage Core_stage.Final prog in
  Alcotest.(check int) "one violation" 1 (List.length violations)

let tensor_payload_elem = mk (CLit (LitFloat 1.0)) ty_float

let tensor_literal_with_layout layout payload =
  mk
    (CTensorLiteral
       {
         tl_shape = TensorVectorLength 1;
         tl_layout = layout;
         tl_payload = payload;
       })
    ty_vector_float_4

let test_tensor_literal_layout_invariant_accepts_matching_raw_payload () =
  let body =
    tensor_literal_with_layout
      (tensor_raw_scalar_storage ~elem_ty:ty_float TensorFloat64Elements)
      (TensorRawElements (TensorFloat64Elements, [ tensor_payload_elem ]))
  in
  let prog = mk_prog [ CDFunc (mk_simple_func ~name:"main" ~body) ] in
  let violations =
    Core_invariants.check_tensor_literal_layouts_at Core_stage.Final prog
  in
  Alcotest.(check int) "no violations" 0 (List.length violations)

let test_tensor_literal_layout_invariant_flags_storage_mismatch () =
  let body =
    tensor_literal_with_layout
      (tensor_boxed_storage ~elem_ty:ty_float ())
      (TensorRawElements (TensorFloat64Elements, [ tensor_payload_elem ]))
  in
  let prog = mk_prog [ CDFunc (mk_simple_func ~name:"main" ~body) ] in
  let violations =
    Core_invariants.check_tensor_literal_layouts_at Core_stage.Final prog
  in
  Alcotest.(check int) "one violation" 1 (List.length violations);
  match violations with
  | [ v ] ->
      Alcotest.(check bool)
        "mentions tensor literal layout" true
        (Modules.contains v.Core_error.msg "tensor literal layout")
  | _ -> Alcotest.fail "unreachable"

let test_tensor_literal_layout_invariant_flags_scalar_kind_mismatch () =
  let body =
    tensor_literal_with_layout
      (tensor_raw_scalar_storage ~elem_ty:ty_float TensorFloat32Elements)
      (TensorRawElements (TensorFloat64Elements, [ tensor_payload_elem ]))
  in
  let prog = mk_prog [ CDFunc (mk_simple_func ~name:"main" ~body) ] in
  let violations =
    Core_invariants.check_tensor_literal_layouts_at Core_stage.Final prog
  in
  Alcotest.(check int) "one violation" 1 (List.length violations);
  match violations with
  | [ v ] ->
      Alcotest.(check bool)
        "mentions scalar kind" true
        (Modules.contains v.Core_error.msg "raw scalar")
  | _ -> Alcotest.fail "unreachable"

let tensor_loop_with_storage_for iter_ty proof =
  let iter = mk (CVar (Var.named "values")) iter_ty in
  let binder =
    { (loop_binder_named "x" ty_int) with loop_source_storage = proof }
  in
  mk (CFor (binder, iter, mk CVoid ty_void)) ty_void

let tensor_loop_with_storage proof =
  tensor_loop_with_storage_for ty_vector_int_4 proof

let test_tensor_loop_storage_provenance_accepts_matching_layout () =
  let body =
    tensor_loop_with_storage
      (tensor_storage_known_producer
         (tensor_raw_scalar_storage ~elem_ty:ty_int TensorInt64Elements))
  in
  let prog = mk_prog [ CDFunc (mk_simple_func ~name:"main" ~body) ] in
  let violations =
    Core_invariants.check_tensor_loop_storage_provenance_at Core_stage.Final
      prog
  in
  Alcotest.(check int) "no violations" 0 (List.length violations)

let test_tensor_loop_storage_provenance_accepts_alias_iter () =
  let body =
    tensor_loop_with_storage_for
      (TyNamed ("IntVector", []))
      (tensor_storage_known_producer
         (tensor_raw_scalar_storage ~elem_ty:ty_int TensorInt64Elements))
  in
  let prog =
    mk_prog
      [
        CDTypeAlias (type_alias_decl "IntVector" ty_vector_int_4);
        CDFunc (mk_simple_func ~name:"main" ~body);
      ]
  in
  let violations =
    Core_invariants.check_tensor_loop_storage_provenance_at Core_stage.Final
      prog
  in
  Alcotest.(check int) "no violations" 0 (List.length violations)

let test_tensor_loop_storage_provenance_flags_element_mismatch () =
  let body =
    tensor_loop_with_storage
      (tensor_storage_known_producer
         (tensor_raw_scalar_storage ~elem_ty:ty_float TensorFloat64Elements))
  in
  let prog = mk_prog [ CDFunc (mk_simple_func ~name:"main" ~body) ] in
  let violations =
    Core_invariants.check_tensor_loop_storage_provenance_at Core_stage.Final
      prog
  in
  Alcotest.(check int) "one violation" 1 (List.length violations);
  match violations with
  | [ v ] ->
      Alcotest.(check bool)
        "mentions loop source storage proof" true
        (Modules.contains v.Core_error.msg "loop source storage proof")
  | _ -> Alcotest.fail "unreachable"

let test_closure_check_flags_raw_clambda () =
  let lam =
    mk
      (CLambda
         {
           lam_params = [];
           lam_body = mk (CLit (LitInt 42L)) ty_int;
           lam_return_ty = ty_int;
           lam_is_pure = false;
         })
      (TyFunc { params = []; return = ty_int; is_pure = false })
  in
  let prog = mk_prog [ CDFunc (mk_simple_func ~name:"main" ~body:lam) ] in
  let violations = Core_invariants.check_no_preclosure_forms prog in
  Alcotest.(check int) "one violation" 1 (List.length violations);
  match violations with
  | [ v ] ->
      Alcotest.(check bool)
        "mentions CLambda" true
        (Modules.contains v.Core_error.msg "CLambda");
      Alcotest.(check bool)
        "phase tag is Closure" true
        (v.Core_error.phase = Core_error.Stage Core_stage.Closure)
  | _ -> Alcotest.fail "unreachable"

let test_closure_check_flags_missing_detach_task () =
  let detach =
    mk (CDetach { detach_body = mk CVoid ty_void; detach_task = None }) ty_void
  in
  let func =
    {
      cf_name = "main";
      cf_module = None;
      cf_type_params = [];
      cf_params = [];
      cf_return_ty = ty_void;
      cf_body = Some detach;
      cf_is_pure = false;
      cf_kind = CFUser;
      cf_def_id = 0;
    }
  in
  let prog = mk_prog [ CDFunc func ] in
  let violations = Core_invariants.check_no_preclosure_forms prog in
  Alcotest.(check int) "one violation" 1 (List.length violations);
  match violations with
  | [ v ] ->
      Alcotest.(check bool)
        "mentions detach task metadata" true
        (Modules.contains v.Core_error.msg "detach");
      Alcotest.(check bool)
        "phase tag is Closure" true
        (v.Core_error.phase = Core_error.Stage Core_stage.Closure)
  | _ -> Alcotest.fail "unreachable"

let test_dispatcher_closure_fires () =
  let lam =
    mk
      (CLambda
         {
           lam_params = [];
           lam_body = mk (CLit (LitInt 1L)) ty_int;
           lam_return_ty = ty_int;
           lam_is_pure = false;
         })
      (TyFunc { params = []; return = ty_int; is_pure = false })
  in
  let prog = mk_prog [ CDFunc (mk_simple_func ~name:"main" ~body:lam) ] in
  let violations = Core_invariants.run_for_stage Core_stage.Closure prog in
  Alcotest.(check bool) "closure fires check" true (List.length violations >= 1)

let test_resource_capture_metadata_flags_closure_create () =
  let closure =
    mk
      (CClosureCreate
         {
           cc_func = "_blorp_closure_test";
           cc_def_id = 42;
           cc_captures = [ ("resource", ty_test_resource) ];
         })
      ty_fn_int_int
  in
  let prog =
    mk_prog
      [
        CDType resource_type_decl;
        CDFunc (mk_simple_func ~name:"main" ~body:closure);
      ]
  in
  let violations =
    Core_invariants.check_no_resource_capture_metadata_at Core_stage.Final prog
  in
  Alcotest.(check int) "one violation" 1 (List.length violations);
  match violations with
  | [ v ] ->
      Alcotest.(check bool)
        "mentions resource capture" true
        (Modules.contains v.Core_error.msg "resource capture")
  | _ -> Alcotest.fail "unreachable"

let test_resource_capture_metadata_flags_task_capture () =
  let rhs = cint 1 in
  let task = task_closure ~captures:[ ("resource", ty_test_resource) ] rhs.ty in
  let binding =
    {
      cb_var = Var.named "answer";
      cb_ty = ty_result rhs.ty;
      cb_rhs = rhs;
      cb_task_scope = synthetic_concurrent_task_scope;
      cb_task = Some task;
    }
  in
  let body = mk CVoid ty_void in
  let node =
    mk
      (CConcurrent
         {
           conc_bindings = [ binding ];
           conc_body = body;
           conc_timeout = None;
           conc_max_threads = None;
         })
      body.ty
  in
  let prog =
    mk_prog
      [
        CDType resource_type_decl;
        CDFunc (mk_simple_func ~name:"main" ~body:node);
      ]
  in
  let violations =
    Core_invariants.check_no_resource_capture_metadata_at Core_stage.Final prog
  in
  Alcotest.(check int) "one violation" 1 (List.length violations);
  match violations with
  | [ v ] ->
      Alcotest.(check bool)
        "mentions resource capture" true
        (Modules.contains v.Core_error.msg "resource capture")
  | _ -> Alcotest.fail "unreachable"

let test_task_capture_metadata_flags_unsupported_kind () =
  let rhs = cint 1 in
  let task =
    {
      tc_func = "_blorp_task_test";
      tc_def_id = 9001;
      tc_captures =
        [
          {
            task_capture_name = "item";
            task_capture_ty = ty_int;
            task_capture_kind = TaskMoveResourceItem;
          };
        ];
      tc_return_ty = rhs.ty;
    }
  in
  let binding =
    {
      cb_var = Var.named "answer";
      cb_ty = ty_result rhs.ty;
      cb_rhs = rhs;
      cb_task_scope = synthetic_concurrent_task_scope;
      cb_task = Some task;
    }
  in
  let body = mk CVoid ty_void in
  let node =
    mk
      (CConcurrent
         {
           conc_bindings = [ binding ];
           conc_body = body;
           conc_timeout = None;
           conc_max_threads = None;
         })
      body.ty
  in
  let prog = mk_prog [ CDFunc (mk_simple_func ~name:"main" ~body:node) ] in
  let violations =
    Core_invariants.check_no_resource_capture_metadata_at Core_stage.Final prog
  in
  Alcotest.(check int) "one violation" 1 (List.length violations);
  match violations with
  | [ v ] ->
      Alcotest.(check bool)
        "mentions unsupported capture" true
        (Modules.contains v.Core_error.msg "unsupported")
  | _ -> Alcotest.fail "unreachable"

(* ============================================================================
   Final Core: concurrency semantic contracts are explicit
   ============================================================================ *)

let concurrent_binding ?cb_ty ?task_ty name rhs =
  let cb_ty = Option.value cb_ty ~default:(ty_result rhs.ty) in
  let task_ty = Option.value task_ty ~default:rhs.ty in
  {
    cb_var = Var.named name;
    cb_ty;
    cb_rhs = rhs;
    cb_task_scope = synthetic_concurrent_task_scope;
    cb_task = Some (task_closure task_ty);
  }

let concurrent_block_expr ?timeout ?max_threads ?(node_ty = ty_void) bindings
    body =
  mk
    (CConcurrent
       {
         conc_bindings = bindings;
         conc_body = body;
         conc_timeout = timeout;
         conc_max_threads = max_threads;
       })
    node_ty

let concurrently_loop_expr ?iter_ty ?body_ty ?node_ty ?timeout ?task_ty
    ?task_scope ?output () =
  let iter_ty = Option.value iter_ty ~default:(ty_list ty_int) in
  let body_ty = Option.value body_ty ~default:ty_int in
  let node_ty = Option.value node_ty ~default:(ty_list (ty_result body_ty)) in
  let task_ty = Option.value task_ty ~default:body_ty in
  let width = Core.ConcurrentlyLoopLimit (cint 2) in
  let task_scope =
    Option.value task_scope ~default:Core.synthetic_concurrent_task_scope
  in
  let output = Option.value output ~default:Core.ConcurrentlyLoopCollect in
  mk
    (CConcurrentlyLoop
       {
         cf_var = Var.named "item";
         cf_iter = mk (CVar (Var.named "items")) iter_ty;
         cf_body = mk (CVar (Var.named "item")) body_ty;
         cf_timeout = timeout;
         cf_width = width;
         cf_output = output;
         cf_item_mode = ConcurrentlyLoopCopyItem;
         cf_task_scope = task_scope;
         cf_task = Some (task_closure task_ty);
       })
    node_ty

let test_concurrent_semantics_accepts_well_formed_block () =
  let rhs = cint 1 in
  let body = mk CVoid ty_void in
  let node =
    concurrent_block_expr ~timeout:(cint 10)
      [ concurrent_binding "answer" rhs ]
      body
  in
  let prog = mk_prog [ CDFunc (mk_simple_func ~name:"main" ~body:node) ] in
  let violations =
    Core_invariants.check_concurrent_semantics_at Core_stage.Final prog
  in
  Alcotest.(check int) "no violations" 0 (List.length violations)

let test_concurrent_semantics_flags_binding_result_mismatch () =
  let rhs = cint 1 in
  let node =
    concurrent_block_expr
      [ concurrent_binding ~cb_ty:(ty_result ty_string) "answer" rhs ]
      (mk CVoid ty_void)
  in
  let prog = mk_prog [ CDFunc (mk_simple_func ~name:"main" ~body:node) ] in
  let violations =
    Core_invariants.check_concurrent_semantics_at Core_stage.Final prog
  in
  Alcotest.(check int) "one violation" 1 (List.length violations);
  match violations with
  | [ v ] ->
      Alcotest.(check bool)
        "mentions concurrent binding result type" true
        (Modules.contains v.Core_error.msg "concurrent binding");
      Alcotest.(check bool)
        "mentions expected Result" true
        (Modules.contains v.Core_error.msg "Result[Int, ConcurrencyError]")
  | _ -> Alcotest.fail "unreachable"

let test_concurrent_semantics_flags_duplicate_binding_names () =
  let node =
    concurrent_block_expr
      [
        concurrent_binding "answer" (cint 1);
        concurrent_binding "answer" (cint 2);
      ]
      (mk CVoid ty_void)
  in
  let prog = mk_prog [ CDFunc (mk_simple_func ~name:"main" ~body:node) ] in
  let violations =
    Core_invariants.check_concurrent_semantics_at Core_stage.Final prog
  in
  Alcotest.(check int) "one violation" 1 (List.length violations);
  match violations with
  | [ v ] ->
      Alcotest.(check bool)
        "mentions duplicate concurrent binding" true
        (Modules.contains v.Core_error.msg "duplicate concurrent binding")
  | _ -> Alcotest.fail "unreachable"

let test_concurrent_semantics_flags_task_return_mismatch () =
  let rhs = cint 1 in
  let node =
    concurrent_block_expr
      [ concurrent_binding ~task_ty:ty_string "answer" rhs ]
      (mk CVoid ty_void)
  in
  let prog = mk_prog [ CDFunc (mk_simple_func ~name:"main" ~body:node) ] in
  let violations =
    Core_invariants.check_concurrent_semantics_at Core_stage.Final prog
  in
  Alcotest.(check int) "one violation" 1 (List.length violations);
  match violations with
  | [ v ] ->
      Alcotest.(check bool)
        "mentions task return" true
        (Modules.contains v.Core_error.msg "task return type")
  | _ -> Alcotest.fail "unreachable"

let test_concurrent_semantics_flags_timeout_type () =
  let rhs = cint 1 in
  let bad_timeout = mk (CLit (LitBool true)) ty_bool in
  let node =
    concurrent_block_expr ~timeout:bad_timeout
      [ concurrent_binding "answer" rhs ]
      (mk CVoid ty_void)
  in
  let prog = mk_prog [ CDFunc (mk_simple_func ~name:"main" ~body:node) ] in
  let violations =
    Core_invariants.check_concurrent_semantics_at Core_stage.Final prog
  in
  Alcotest.(check int) "one violation" 1 (List.length violations);
  match violations with
  | [ v ] ->
      Alcotest.(check bool)
        "mentions timeout" true
        (Modules.contains v.Core_error.msg "timeout")
  | _ -> Alcotest.fail "unreachable"

let test_concurrent_semantics_flags_non_positive_max_threads () =
  let rhs = cint 1 in
  let node =
    concurrent_block_expr ~max_threads:0
      [ concurrent_binding "answer" rhs ]
      (mk CVoid ty_void)
  in
  let prog = mk_prog [ CDFunc (mk_simple_func ~name:"main" ~body:node) ] in
  let violations =
    Core_invariants.check_concurrent_semantics_at Core_stage.Final prog
  in
  Alcotest.(check int) "one violation" 1 (List.length violations);
  match violations with
  | [ v ] ->
      Alcotest.(check bool)
        "mentions max_threads" true
        (Modules.contains v.Core_error.msg "max_threads")
  | _ -> Alcotest.fail "unreachable"

let test_concurrent_semantics_flags_non_list_concurrently_loop () =
  let node = concurrently_loop_expr ~iter_ty:(TyNamed ("Set", [ ty_int ])) () in
  let prog = mk_prog [ CDFunc (mk_simple_func ~name:"main" ~body:node) ] in
  let violations =
    Core_invariants.check_concurrent_semantics_at Core_stage.Final prog
  in
  Alcotest.(check int) "one violation" 1 (List.length violations);
  match violations with
  | [ v ] ->
      Alcotest.(check bool)
        "mentions List" true
        (Modules.contains v.Core_error.msg "requires List")
  | _ -> Alcotest.fail "unreachable"

let test_concurrent_semantics_flags_concurrently_loop_result_shape () =
  let node =
    concurrently_loop_expr ~body_ty:ty_string
      ~node_ty:(ty_list (ty_result ty_int))
      ()
  in
  let prog = mk_prog [ CDFunc (mk_simple_func ~name:"main" ~body:node) ] in
  let violations =
    Core_invariants.check_concurrent_semantics_at Core_stage.Final prog
  in
  Alcotest.(check int) "one violation" 1 (List.length violations);
  match violations with
  | [ v ] ->
      Alcotest.(check bool)
        "mentions for ... concurrently result" true
        (Modules.contains v.Core_error.msg "for ... concurrently result type")
  | _ -> Alcotest.fail "unreachable"

let test_concurrent_semantics_flags_discard_body_result () =
  let node =
    concurrently_loop_expr ~node_ty:ty_void ~output:Core.ConcurrentlyLoopDiscard
      ()
  in
  let prog = mk_prog [ CDFunc (mk_simple_func ~name:"main" ~body:node) ] in
  let violations =
    Core_invariants.check_concurrent_semantics_at Core_stage.Final prog
  in
  Alcotest.(check int) "one violation" 1 (List.length violations);
  match violations with
  | [ v ] ->
      Alcotest.(check bool)
        "mentions discard body type" true
        (Modules.contains v.Core_error.msg
           "discarding for ... concurrently body type")
  | _ -> Alcotest.fail "unreachable"

let test_concurrent_semantics_flags_malformed_task_scope () =
  let bad_scope =
    {
      task_parent_scope_id = TaskScopeId 7;
      task_child_scope_id = TaskScopeId 7;
    }
  in
  let node = concurrently_loop_expr ~task_scope:bad_scope () in
  let prog = mk_prog [ CDFunc (mk_simple_func ~name:"main" ~body:node) ] in
  let violations =
    Core_invariants.check_concurrent_semantics_at Core_stage.Final prog
  in
  Alcotest.(check int) "one violation" 1 (List.length violations);
  match violations with
  | [ v ] ->
      Alcotest.(check bool)
        "mentions task scope" true
        (Modules.contains v.Core_error.msg "task scope ids must differ")
  | _ -> Alcotest.fail "unreachable"

let test_dispatcher_final_runs_concurrent_semantics () =
  let rhs = cint 1 in
  let node =
    concurrent_block_expr
      [ concurrent_binding ~cb_ty:ty_int "answer" rhs ]
      (mk CVoid ty_void)
  in
  let prog = mk_prog [ CDFunc (mk_simple_func ~name:"main" ~body:node) ] in
  let violations = Core_invariants.run_for_stage Core_stage.Final prog in
  Alcotest.(check int) "one violation" 1 (List.length violations);
  match violations with
  | [ v ] ->
      Alcotest.(check bool)
        "mentions concurrent binding" true
        (Modules.contains v.Core_error.msg "concurrent binding")
  | _ -> Alcotest.fail "unreachable"

(* ============================================================================
   Pipeline integration: ~check_invariants fires the checks
   ============================================================================ *)

let small_source =
  {|
func inc(x: Int) -> Int:
    x + 1

func main(args: List[String]) -> Int:
    inc(41)
|}

let lower_source src =
  Blorp.Lexer.reset_state ();
  let lexbuf = Lexing.from_string src in
  let program = Blorp.Parser.program Blorp.Lexer.next_token lexbuf in
  let program = Blorp.Interp_parser.transform_program program in
  match Blorp.Typecheck.typecheck_typed program with
  | Ok typed_program -> typed_program
  | Error errors ->
      Alcotest.failf "expected no type errors, got: %s"
        (String.concat "; "
           (List.map (fun (e : Blorp.Ast.compiler_error) -> e.message) errors))

let test_pipeline_check_invariants_passes_on_clean_code () =
  (* The happy path: a well-formed program runs through the pipeline
     with ~check_invariants:true and produces no Core_error. *)
  let prog = lower_source small_source in
  match Core_pipeline.compile_typed ~check_invariants:true prog with
  | _c_code -> () (* no exception = pass *)
  | exception Core_error.Core_error err ->
      Alcotest.failf "unexpected invariant violation: %s"
        (Core_error.to_string err)

let test_make_stage_hook_raises_on_violation () =
  (* Prove [make_stage_hook] runs the invariant check BEFORE the user
     callback. When violations exist, the user callback does NOT fire
     — this is the post-Phase-2.5 semantics so [--stop-after] can't
     mask invariant violations. *)
  let fn = mk (CVar (Var.named "mystery")) ty_int in
  let call = mk_call CKUnknown fn [] ty_int in
  let bad_prog = mk_prog [ CDFunc (mk_simple_func ~name:"main" ~body:call) ] in
  let user_fired = ref false in
  let user_cb _ _ = user_fired := true in
  let hook =
    Core_pipeline.make_stage_hook ~check_invariants:true ~user:user_cb
  in
  match hook Core_stage.Specialize bad_prog with
  | exception Core_error.Core_error err ->
      Alcotest.(check bool)
        "user callback skipped on violation" false !user_fired;
      Alcotest.(check bool)
        "phase is Specialize" true
        (err.Core_error.phase = Core_error.Stage Core_stage.Specialize);
      Alcotest.(check bool)
        "msg mentions unresolved call" true
        (Blorp.Modules.contains err.Core_error.msg "unresolved call target")
  | () -> Alcotest.fail "expected Core_error from make_stage_hook"

let test_make_stage_hook_silent_when_disabled () =
  (* With [check_invariants:false], a violating program runs the user
     callback but does NOT raise before the final safety boundary. This is
     the default behavior for development-only stage checks. *)
  let fn = mk (CVar (Var.named "mystery")) ty_int in
  let call = mk_call CKUnknown fn [] ty_int in
  let bad_prog = mk_prog [ CDFunc (mk_simple_func ~name:"main" ~body:call) ] in
  let user_fired = ref false in
  let user_cb _ _ = user_fired := true in
  let hook =
    Core_pipeline.make_stage_hook ~check_invariants:false ~user:user_cb
  in
  hook Core_stage.Specialize bad_prog;
  Alcotest.(check bool) "user callback fired" true !user_fired

let test_final_critical_invariants_raise_when_disabled () =
  (* Even when development invariant checking is disabled, final Core must
     not allow unresolved calls or pre-closure forms to reach emission. *)
  let fn = mk (CVar (Var.named "mystery")) ty_int in
  let call = mk_call CKUnknown fn [] ty_int in
  let bad_prog = mk_prog [ CDFunc (mk_simple_func ~name:"main" ~body:call) ] in
  let user_fired = ref false in
  let user_cb _ _ = user_fired := true in
  let hook =
    Core_pipeline.make_stage_hook ~check_invariants:false ~user:user_cb
  in
  match hook Core_stage.Final bad_prog with
  | exception Core_error.Core_error err ->
      Alcotest.(check bool) "user callback skipped" false !user_fired;
      Alcotest.(check bool)
        "phase is Final" true
        (err.Core_error.phase = Core_error.Stage Core_stage.Final);
      Alcotest.(check bool)
        "msg mentions unresolved call" true
        (Blorp.Modules.contains err.Core_error.msg "unresolved call target")
  | () -> Alcotest.fail "expected final critical invariant violation"

let test_final_critical_invariants_reject_raw_match_when_disabled () =
  (* Raw match arms are a canonicalization leak. Even with development
     checks disabled, final Core must not rely on emitter fallbacks to
     catch this phase-boundary violation. *)
  let scrut = mk (CLit (LitInt 1L)) ty_int in
  let arms = [ (PatLiteral (LitInt 1L), mk (CLit (LitInt 0L)) ty_int) ] in
  let node = mk (CMatchArms (scrut, arms)) ty_int in
  let bad_prog = mk_prog [ CDFunc (mk_simple_func ~name:"main" ~body:node) ] in
  let user_fired = ref false in
  let user_cb _ _ = user_fired := true in
  let hook =
    Core_pipeline.make_stage_hook ~check_invariants:false ~user:user_cb
  in
  match hook Core_stage.Final bad_prog with
  | exception Core_error.Core_error err ->
      Alcotest.(check bool) "user callback skipped" false !user_fired;
      Alcotest.(check bool)
        "msg mentions CMatchArms" true
        (Blorp.Modules.contains err.Core_error.msg "CMatchArms")
  | () -> Alcotest.fail "expected final raw match invariant violation"

let test_final_critical_invariants_reject_sugar_when_disabled () =
  (* Sugar nodes have no business reaching the final Core boundary. *)
  let node =
    mk (CStringInterp ([ IPLit "hi" ], false)) (TyNamed ("String", []))
  in
  let bad_prog = mk_prog [ CDFunc (mk_simple_func ~name:"main" ~body:node) ] in
  let user_fired = ref false in
  let user_cb _ _ = user_fired := true in
  let hook =
    Core_pipeline.make_stage_hook ~check_invariants:false ~user:user_cb
  in
  match hook Core_stage.Final bad_prog with
  | exception Core_error.Core_error err ->
      Alcotest.(check bool) "user callback skipped" false !user_fired;
      Alcotest.(check bool)
        "msg mentions CStringInterp" true
        (Blorp.Modules.contains err.Core_error.msg "CStringInterp")
  | () -> Alcotest.fail "expected final sugar invariant violation"

let test_final_critical_invariants_reject_layoutless_list_alloc_when_disabled ()
    =
  let cap = mk (CLit (LitInt 4L)) ty_int in
  let alloc =
    mk_call (CKIntrinsic "list_alloc") (mk CVoid ty_void) [ cap ] ty_list_int
  in
  let bad_prog = mk_prog [ CDFunc (mk_simple_func ~name:"main" ~body:alloc) ] in
  let user_fired = ref false in
  let user_cb _ _ = user_fired := true in
  let hook =
    Core_pipeline.make_stage_hook ~check_invariants:false ~user:user_cb
  in
  match hook Core_stage.Final bad_prog with
  | exception Core_error.Core_error err ->
      Alcotest.(check bool) "user callback skipped" false !user_fired;
      Alcotest.(check bool)
        "msg mentions list_alloc" true
        (Blorp.Modules.contains err.Core_error.msg "list_alloc")
  | () -> Alcotest.fail "expected final list_alloc invariant violation"

let test_final_critical_invariants_reject_unprepared_codegen_when_disabled () =
  let node = mk (CBox (mk (CLit (LitInt 1L)) ty_int, ty_int)) ty_void in
  let bad_prog = mk_prog [ CDFunc (mk_simple_func ~name:"main" ~body:node) ] in
  let user_fired = ref false in
  let user_cb _ _ = user_fired := true in
  let hook =
    Core_pipeline.make_stage_hook ~check_invariants:false ~user:user_cb
  in
  match hook Core_stage.Final bad_prog with
  | exception Core_error.Core_error err ->
      Alcotest.(check bool) "user callback skipped" false !user_fired;
      Alcotest.(check bool)
        "msg mentions CBox" true
        (Blorp.Modules.contains err.Core_error.msg "CBox")
  | () -> Alcotest.fail "expected final unprepared codegen invariant violation"

let resource_cleanup_call ?(call_kind = CKUser ("close", None))
    ?(resource_var = Var.named "resource") ?(resource_ty = ty_test_resource) ()
    =
  let close_ty =
    TyFunc { params = [ resource_ty ]; return = ty_void; is_pure = false }
  in
  let close = mk (CVar (Var.named "close")) close_ty in
  let arg = mk (CVar resource_var) resource_ty in
  mk_call call_kind close [ arg ] ty_void

let resource_scope ?(acquire_ty = ty_test_resource) ?(body_ty = ty_int) ?body
    ?cleanup () =
  let body =
    match body with
    | Some body -> body
    | None ->
        if body_ty = ty_bool then mk (CLit (LitBool true)) ty_bool else cint 7
  in
  let resource_var = Var.named "resource" in
  mk
    (CResourceScope
       {
         rs_var = resource_var;
         rs_ty = ty_test_resource;
         rs_acquire = mk (CVar (Var.named "open_resource")) acquire_ty;
         rs_body = body;
         rs_cleanup =
           Option.value cleanup
             ~default:(resource_cleanup_call ~resource_var ());
       })
    body.ty

let test_resource_scope_contract_accepts_well_formed () =
  let prog =
    mk_prog [ CDFunc (mk_simple_func ~name:"main" ~body:(resource_scope ())) ]
  in
  let violations =
    Core_invariants.check_resource_scope_contracts_at Core_stage.Lower prog
  in
  Alcotest.(check int) "no violations" 0 (List.length violations)

let test_resource_scope_contract_flags_acquire_type_mismatch () =
  let prog =
    mk_prog
      [
        CDFunc
          (mk_simple_func ~name:"main"
             ~body:(resource_scope ~acquire_ty:ty_string ()));
      ]
  in
  let violations =
    Core_invariants.check_resource_scope_contracts_at Core_stage.Lower prog
  in
  Alcotest.(check int) "one violation" 1 (List.length violations);
  match violations with
  | [ v ] ->
      Alcotest.(check bool)
        "mentions acquire type" true
        (Modules.contains v.Core_error.msg "resource acquire type")
  | _ -> Alcotest.fail "unreachable"

let test_resource_scope_contract_flags_cleanup_type_mismatch () =
  let cleanup = mk (CLit (LitInt 0L)) ty_int in
  let prog =
    mk_prog
      [
        CDFunc (mk_simple_func ~name:"main" ~body:(resource_scope ~cleanup ()));
      ]
  in
  let violations =
    Core_invariants.check_resource_scope_contracts_at Core_stage.Lower prog
  in
  Alcotest.(check int) "one violation" 1 (List.length violations);
  match violations with
  | v :: _ ->
      Alcotest.(check bool)
        "mentions cleanup type" true
        (Modules.contains v.Core_error.msg "resource cleanup type")
  | _ -> Alcotest.fail "unreachable"

let test_resource_scope_contract_flags_cleanup_not_direct_call () =
  let prog =
    mk_prog
      [
        CDFunc
          (mk_simple_func ~name:"main"
             ~body:(resource_scope ~cleanup:(mk CVoid ty_void) ()));
      ]
  in
  let violations =
    Core_invariants.check_resource_scope_contracts_at Core_stage.Lower prog
  in
  Alcotest.(check int) "one violation" 1 (List.length violations);
  match violations with
  | [ v ] ->
      Alcotest.(check bool)
        "mentions cleanup call" true
        (Modules.contains v.Core_error.msg
           "resource cleanup must be a direct call")
  | _ -> Alcotest.fail "unreachable"

let test_resource_scope_contract_flags_cleanup_wrong_arg () =
  let cleanup =
    resource_cleanup_call ~resource_var:(Var.named "other_resource") ()
  in
  let prog =
    mk_prog
      [
        CDFunc (mk_simple_func ~name:"main" ~body:(resource_scope ~cleanup ()));
      ]
  in
  let violations =
    Core_invariants.check_resource_scope_contracts_at Core_stage.Lower prog
  in
  Alcotest.(check int) "one violation" 1 (List.length violations);
  match violations with
  | [ v ] ->
      Alcotest.(check bool)
        "mentions cleanup argument" true
        (Modules.contains v.Core_error.msg "resource cleanup argument")
  | _ -> Alcotest.fail "unreachable"

let test_resource_scope_contract_flags_body_result_mismatch () =
  let node = resource_scope ~body_ty:ty_bool () in
  let node = { node with ty = ty_int } in
  let prog = mk_prog [ CDFunc (mk_simple_func ~name:"main" ~body:node) ] in
  let violations =
    Core_invariants.check_resource_scope_contracts_at Core_stage.Lower prog
  in
  Alcotest.(check int) "one violation" 1 (List.length violations);
  match violations with
  | [ v ] ->
      Alcotest.(check bool)
        "mentions body type" true
        (Modules.contains v.Core_error.msg "resource body type")
  | _ -> Alcotest.fail "unreachable"

let test_resource_scope_contract_flags_resource_escape_result () =
  let resource_var = Var.named "resource" in
  let body = mk (CVar resource_var) ty_test_resource in
  let node =
    mk
      (CResourceScope
         {
           rs_var = resource_var;
           rs_ty = ty_test_resource;
           rs_acquire = mk (CVar (Var.named "open_resource")) ty_test_resource;
           rs_body = body;
           rs_cleanup = resource_cleanup_call ~resource_var ();
         })
      ty_test_resource
  in
  let prog =
    mk_prog
      [
        CDType resource_type_decl;
        CDFunc (mk_simple_func ~name:"main" ~body:node);
      ]
  in
  let violations =
    Core_invariants.check_resource_scope_contracts_at Core_stage.Lower prog
  in
  Alcotest.(check int) "one violation" 1 (List.length violations);
  match violations with
  | [ v ] ->
      Alcotest.(check bool)
        "mentions resource result" true
        (Modules.contains v.Core_error.msg "resource scope body")
  | _ -> Alcotest.fail "unreachable"

let test_resource_scope_contract_flags_record_resource_result () =
  let body = mk (CVar (Var.named "holder")) ty_resource_holder in
  let prog =
    mk_prog
      [
        CDType resource_type_decl;
        CDRecord resource_holder_record_decl;
        CDFunc (mk_simple_func ~name:"main" ~body:(resource_scope ~body ()));
      ]
  in
  let violations =
    Core_invariants.check_resource_scope_contracts_at Core_stage.Lower prog
  in
  Alcotest.(check int) "one violation" 1 (List.length violations);
  match violations with
  | [ v ] ->
      Alcotest.(check bool)
        "mentions resource result" true
        (Modules.contains v.Core_error.msg "resource scope body")
  | _ -> Alcotest.fail "unreachable"

let test_resource_scope_contract_flags_union_resource_result () =
  let body = mk (CVar (Var.named "box")) ty_resource_box in
  let prog =
    mk_prog
      [
        CDType resource_type_decl;
        CDType resource_box_type_decl;
        CDFunc (mk_simple_func ~name:"main" ~body:(resource_scope ~body ()));
      ]
  in
  let violations =
    Core_invariants.check_resource_scope_contracts_at Core_stage.Lower prog
  in
  Alcotest.(check int) "one violation" 1 (List.length violations);
  match violations with
  | [ v ] ->
      Alcotest.(check bool)
        "mentions resource result" true
        (Modules.contains v.Core_error.msg "resource scope body")
  | _ -> Alcotest.fail "unreachable"

let test_final_critical_invariants_allow_resource_scope_when_disabled () =
  let prog =
    mk_prog [ CDFunc (mk_simple_func ~name:"main" ~body:(resource_scope ())) ]
  in
  let user_fired = ref false in
  let user_cb _ _ = user_fired := true in
  let hook =
    Core_pipeline.make_stage_hook ~check_invariants:false ~user:user_cb
  in
  hook Core_stage.Final prog;
  Alcotest.(check bool) "user callback fired" true !user_fired

let test_resource_scope_final_rejects_nonlocal_break_body () =
  let prog =
    mk_prog
      [
        CDFunc
          (mk_simple_func ~name:"main"
             ~body:(resource_scope ~body:(mk CBreak ty_void) ()));
      ]
  in
  let violations = Core_invariants.run_for_stage Core_stage.Final prog in
  Alcotest.(check int) "one violation" 1 (List.length violations);
  match violations with
  | [ v ] ->
      Alcotest.(check bool)
        "mentions nonlocal control flow" true
        (Modules.contains v.Core_error.msg
           "resource scope body contains nonlocal control flow")
  | _ -> Alcotest.fail "unreachable"

let test_resource_scope_final_rejects_nonlocal_continue_body () =
  let prog =
    mk_prog
      [
        CDFunc
          (mk_simple_func ~name:"main"
             ~body:(resource_scope ~body:(mk CContinue ty_void) ()));
      ]
  in
  let violations = Core_invariants.run_for_stage Core_stage.Final prog in
  Alcotest.(check int) "one violation" 1 (List.length violations);
  match violations with
  | [ v ] ->
      Alcotest.(check bool)
        "mentions nonlocal control flow" true
        (Modules.contains v.Core_error.msg
           "resource scope body contains nonlocal control flow")
  | _ -> Alcotest.fail "unreachable"

let test_resource_scope_final_allows_rewritten_nonlocal_break () =
  let cleanup_exit =
    mk
      (CResourceCleanupExit
         {
           rce_cleanups =
             [ resource_cleanup_call ~resource_var:(Var.named "resource") () ];
           rce_exit = ResourceBreak;
         })
      ty_void
  in
  let prog =
    mk_prog
      [
        CDFunc
          (mk_simple_func ~name:"main"
             ~body:(resource_scope ~body:cleanup_exit ()));
      ]
  in
  let violations = Core_invariants.run_for_stage Core_stage.Final prog in
  Alcotest.(check int) "no violations" 0 (List.length violations)

let test_resource_cleanup_exit_final_rejects_empty_cleanup_stack () =
  let cleanup_exit =
    mk
      (CResourceCleanupExit { rce_cleanups = []; rce_exit = ResourceBreak })
      ty_void
  in
  let prog =
    mk_prog [ CDFunc (mk_simple_func ~name:"main" ~body:cleanup_exit) ]
  in
  let violations = Core_invariants.run_for_stage Core_stage.Final prog in
  Alcotest.(check int) "one violation" 1 (List.length violations);
  match violations with
  | [ v ] ->
      Alcotest.(check bool)
        "mentions cleanup actions" true
        (Modules.contains v.Core_error.msg "no cleanup actions")
  | _ -> Alcotest.fail "unreachable"

let test_resource_cleanup_exit_final_rejects_nonvoid_cleanup () =
  let cleanup_exit =
    mk
      (CResourceCleanupExit
         {
           rce_cleanups = [ mk (CLit (LitInt 0L)) ty_int ];
           rce_exit = ResourceBreak;
         })
      ty_void
  in
  let prog =
    mk_prog [ CDFunc (mk_simple_func ~name:"main" ~body:cleanup_exit) ]
  in
  let violations = Core_invariants.run_for_stage Core_stage.Final prog in
  Alcotest.(check int) "one violation" 1 (List.length violations);
  match violations with
  | [ v ] ->
      Alcotest.(check bool)
        "mentions non-Void cleanup" true
        (Modules.contains v.Core_error.msg "non-Void cleanup action")
  | _ -> Alcotest.fail "unreachable"

let test_resource_scope_final_allows_loop_local_break_continue () =
  let loop_body =
    mk
      (CWhile
         ( mk (CLit (LitBool true)) ty_bool,
           mk (CSeq (mk CContinue ty_void, mk CBreak ty_void)) ty_void ))
      ty_void
  in
  let prog =
    mk_prog
      [
        CDFunc
          (mk_simple_func ~name:"main"
             ~body:(resource_scope ~body:loop_body ()));
      ]
  in
  let violations = Core_invariants.run_for_stage Core_stage.Final prog in
  Alcotest.(check int) "no violations" 0 (List.length violations)

let test_final_rejects_unboxed_void_slot_builtin_arg () =
  let dict = mk (CVar (Var.named "d")) ty_dict_int_int in
  let call =
    mk_call (CKBuiltin "blorp_dict_insert") (mk CVoid ty_void)
      [ dict; mk (CLit (LitInt 1L)) ty_int; boxed_int 2 ]
      ty_dict_int_int
  in
  let prog = mk_prog [ CDFunc (mk_simple_func ~name:"main" ~body:call) ] in
  let violations = Core_invariants.run_for_stage Core_stage.Final prog in
  Alcotest.(check int) "one violation" 1 (List.length violations);
  match violations with
  | [ v ] ->
      Alcotest.(check bool)
        "mentions builtin" true
        (Modules.contains v.Core_error.msg "blorp_dict_insert");
      Alcotest.(check bool)
        "mentions CBoxTyped" true
        (Modules.contains v.Core_error.msg "CBoxTyped")
  | _ -> Alcotest.fail "unreachable"

let test_final_accepts_explicit_void_slot_builtin_boxes () =
  let dict = mk (CVar (Var.named "d")) ty_dict_int_int in
  let call =
    mk_call (CKBuiltin "blorp_dict_insert") (mk CVoid ty_void)
      [ dict; boxed_int 1; boxed_int 2 ]
      ty_dict_int_int
  in
  let prog = mk_prog [ CDFunc (mk_simple_func ~name:"main" ~body:call) ] in
  let violations = Core_invariants.run_for_stage Core_stage.Final prog in
  Alcotest.(check int) "no violations" 0 (List.length violations)

let test_final_rejects_raw_top_level_function_ref () =
  let target =
    {
      cf_name = "double";
      cf_module = None;
      cf_type_params = [];
      cf_params = [ { cp_name = Var.named "x"; cp_ty = ty_int; cp_loc = loc } ];
      cf_return_ty = ty_int;
      cf_body = Some (mk (CVar (Var.named "x")) ty_int);
      cf_is_pure = true;
      cf_kind = CFUser;
      cf_def_id = 100;
    }
  in
  let getter =
    {
      cf_name = "get_double";
      cf_module = None;
      cf_type_params = [];
      cf_params = [];
      cf_return_ty = ty_fn_int_int;
      cf_body = Some (mk (CVar (var_with_def_id "double" 100)) ty_fn_int_int);
      cf_is_pure = true;
      cf_kind = CFUser;
      cf_def_id = 101;
    }
  in
  let violations =
    Core_invariants.run_for_stage Core_stage.Final
      (mk_prog [ CDFunc target; CDFunc getter ])
  in
  Alcotest.(check int) "one violation" 1 (List.length violations);
  match violations with
  | [ v ] ->
      Alcotest.(check bool)
        "mentions function reference" true
        (Modules.contains v.Core_error.msg "function reference");
      Alcotest.(check bool)
        "mentions CClosureCreate" true
        (Modules.contains v.Core_error.msg "CClosureCreate")
  | _ -> Alcotest.fail "unreachable"

let test_final_allows_direct_top_level_function_call () =
  let target =
    {
      cf_name = "double";
      cf_module = None;
      cf_type_params = [];
      cf_params = [ { cp_name = Var.named "x"; cp_ty = ty_int; cp_loc = loc } ];
      cf_return_ty = ty_int;
      cf_body = Some (mk (CVar (Var.named "x")) ty_int);
      cf_is_pure = true;
      cf_kind = CFUser;
      cf_def_id = 102;
    }
  in
  let callee = mk (CVar (var_with_def_id "double" 102)) ty_fn_int_int in
  let call =
    mk_call
      (CKUser ("double", Some 102))
      callee
      [ mk (CLit (LitInt 21L)) ty_int ]
      ty_int
  in
  let main = mk_simple_func ~name:"main" ~body:call in
  let violations =
    Core_invariants.run_for_stage Core_stage.Final
      (mk_prog [ CDFunc target; CDFunc main ])
  in
  Alcotest.(check int) "no violations" 0 (List.length violations)

let test_final_allows_local_function_value_named_like_global () =
  let target =
    {
      cf_name = "double";
      cf_module = None;
      cf_type_params = [];
      cf_params = [ { cp_name = Var.named "x"; cp_ty = ty_int; cp_loc = loc } ];
      cf_return_ty = ty_int;
      cf_body = Some (mk (CVar (Var.named "x")) ty_int);
      cf_is_pure = true;
      cf_kind = CFUser;
      cf_def_id = 103;
    }
  in
  let local_closure =
    mk
      (CClosureCreate
         { cc_func = "_blorp_eta_0"; cc_def_id = 104; cc_captures = [] })
      ty_fn_int_int
  in
  let body =
    mk
      (CLet
         ( {
             bind_var = Var.named "double";
             bind_mut = false;
             bind_ty = ty_fn_int_int;
             bind_rhs = local_closure;
           },
           mk (CVar (Var.named "double")) ty_fn_int_int ))
      ty_fn_int_int
  in
  let getter =
    {
      cf_name = "get_double";
      cf_module = None;
      cf_type_params = [];
      cf_params = [];
      cf_return_ty = ty_fn_int_int;
      cf_body = Some body;
      cf_is_pure = true;
      cf_kind = CFUser;
      cf_def_id = 105;
    }
  in
  let violations =
    Core_invariants.run_for_stage Core_stage.Final
      (mk_prog [ CDFunc target; CDFunc getter ])
  in
  Alcotest.(check int) "no violations" 0 (List.length violations)

let suite =
  [
    ( "ckunknown",
      [
        Alcotest.test_case "valid program" `Quick
          test_ckunknown_passes_on_valid_program;
        Alcotest.test_case "flags unresolved" `Quick
          test_ckunknown_flags_unresolved_call;
        Alcotest.test_case "flags selected direct unresolved" `Quick
          test_ckselected_direct_flags_unresolved_call;
        Alcotest.test_case "walks nested" `Quick
          test_ckunknown_walks_into_nested;
        Alcotest.test_case "flags layoutless list_alloc post-specialize" `Quick
          test_layoutless_list_alloc_flags_post_specialize;
        Alcotest.test_case "flags blorp_list_new post-specialize" `Quick
          test_layoutless_builtin_list_alloc_flags_post_specialize;
      ] );
    ( "tyvar",
      [
        Alcotest.test_case "monomorphized ok" `Quick
          test_tyvar_passes_when_monomorphized;
        Alcotest.test_case "flags unmonomorphized" `Quick
          test_tyvar_flags_unmonomorphized_call;
        Alcotest.test_case "ignores builtin" `Quick
          test_tyvar_ignores_builtin_calls;
      ] );
    ( "sugar",
      [
        Alcotest.test_case "flags CStringInterp" `Quick
          test_sugar_check_flags_cstringinterp;
        Alcotest.test_case "clean passes" `Quick
          test_sugar_check_passes_on_clean_program;
      ] );
    ( "debug",
      [
        Alcotest.test_case "flags CDebugBlock" `Quick
          test_debug_check_flags_debug_block;
        Alcotest.test_case "clean passes" `Quick
          test_debug_check_passes_on_clean_program;
      ] );
    ( "desugarable_mutation",
      [
        Alcotest.test_case "flags no-assignment mutable let" `Quick
          test_mutation_check_flags_no_assignment_mutable_let;
        Alcotest.test_case "flags straight-line assignment" `Quick
          test_mutation_check_flags_straight_line_assignment;
        Alcotest.test_case "allows control-flow assignment" `Quick
          test_mutation_check_allows_control_flow_assignment;
        Alcotest.test_case "dispatcher runs mutation check" `Quick
          test_dispatcher_desugar_runs_mutation_check;
      ] );
    ( "cmatcharms",
      [
        Alcotest.test_case "flags raw CMatchArms" `Quick
          test_match_check_flags_raw_cmatcharms;
        Alcotest.test_case "decision-tree CMatch passes" `Quick
          test_match_check_passes_on_decision_tree;
      ] );
    ( "raw_tensor_views",
      [
        Alcotest.test_case "accepts scoped matching view" `Quick
          test_raw_tensor_view_invariant_accepts_scoped_matching_view;
        Alcotest.test_case "accepts alias source" `Quick
          test_raw_tensor_view_invariant_accepts_alias_source;
        Alcotest.test_case "flags unbound view" `Quick
          test_raw_tensor_view_invariant_flags_unbound_view;
        Alcotest.test_case "flags kind mismatch" `Quick
          test_raw_tensor_view_invariant_flags_kind_mismatch;
        Alcotest.test_case "final rejects unguarded raw intrinsic" `Quick
          test_final_rejects_unguarded_raw_tensor_get_intrinsic;
        Alcotest.test_case "final rejects malformed raw intrinsic" `Quick
          test_final_rejects_malformed_raw_tensor_get_intrinsic;
        Alcotest.test_case "final rejects raw string byte intrinsic" `Quick
          test_final_rejects_raw_string_byte_intrinsic;
        Alcotest.test_case "perceus rejects unknown intrinsic ownership" `Quick
          test_perceus_rejects_intrinsic_without_ownership_contract;
        Alcotest.test_case "perceus rejects unknown builtin ownership" `Quick
          test_perceus_rejects_builtin_without_ownership_contract;
        Alcotest.test_case "perceus rejects pre-perceus builtin sentinel" `Quick
          test_perceus_rejects_pre_perceus_sentinel_builtin;
        Alcotest.test_case "final accepts guarded raw intrinsic" `Quick
          test_final_accepts_guarded_raw_tensor_get_intrinsic;
        Alcotest.test_case "final accepts raw intrinsic in guarded branch"
          `Quick test_final_accepts_raw_tensor_get_inside_guarded_branch;
        Alcotest.test_case "final accepts conjunctive raw intrinsic guards"
          `Quick
          test_final_accepts_conjunctive_guarded_raw_tensor_get_intrinsics;
        Alcotest.test_case "final rejects raw intrinsic result type mismatch"
          `Quick test_final_rejects_guarded_raw_tensor_get_result_type_mismatch;
        Alcotest.test_case "final rejects raw intrinsic source type mismatch"
          `Quick test_final_rejects_guarded_raw_tensor_get_source_type_mismatch;
        Alcotest.test_case "final rejects mismatched raw intrinsic guard" `Quick
          test_final_rejects_mismatched_guarded_raw_tensor_get_intrinsic;
        Alcotest.test_case "final rejects shadowed raw intrinsic guard" `Quick
          test_final_rejects_shadowed_guarded_raw_tensor_get_intrinsic;
      ] );
    ( "tensor_literal_layouts",
      [
        Alcotest.test_case "accepts matching raw payload" `Quick
          test_tensor_literal_layout_invariant_accepts_matching_raw_payload;
        Alcotest.test_case "flags storage mismatch" `Quick
          test_tensor_literal_layout_invariant_flags_storage_mismatch;
        Alcotest.test_case "flags raw scalar mismatch" `Quick
          test_tensor_literal_layout_invariant_flags_scalar_kind_mismatch;
      ] );
    ( "tensor_loop_storage_provenance",
      [
        Alcotest.test_case "accepts matching layout" `Quick
          test_tensor_loop_storage_provenance_accepts_matching_layout;
        Alcotest.test_case "accepts alias iter" `Quick
          test_tensor_loop_storage_provenance_accepts_alias_iter;
        Alcotest.test_case "flags element mismatch" `Quick
          test_tensor_loop_storage_provenance_flags_element_mismatch;
      ] );
    ( "dispatcher",
      [
        Alcotest.test_case "resolve allows ckunknown" `Quick
          test_dispatcher_resolve_allows_ckunknown;
        Alcotest.test_case "specialize runs ckunknown" `Quick
          test_dispatcher_specialize_runs_ckunknown_check;
        Alcotest.test_case "specialize runs list_alloc layout check" `Quick
          test_dispatcher_specialize_runs_layout_check;
        Alcotest.test_case "debug fires debug-block check" `Quick
          test_dispatcher_debug_fires_check;
        Alcotest.test_case "lower disabled today" `Quick
          test_dispatcher_empty_for_unchecked_stages;
        Alcotest.test_case "desugar fires sugar check" `Quick
          test_dispatcher_desugar_fires;
        Alcotest.test_case "match fires cmatch check" `Quick
          test_dispatcher_match_fires_check;
        Alcotest.test_case "closure fires preclosure check" `Quick
          test_dispatcher_closure_fires;
      ] );
    ( "closure",
      [
        Alcotest.test_case "flags raw CLambda" `Quick
          test_closure_check_flags_raw_clambda;
        Alcotest.test_case "flags missing detach task metadata" `Quick
          test_closure_check_flags_missing_detach_task;
        Alcotest.test_case "flags resource closure capture metadata" `Quick
          test_resource_capture_metadata_flags_closure_create;
        Alcotest.test_case "flags resource task capture metadata" `Quick
          test_resource_capture_metadata_flags_task_capture;
        Alcotest.test_case "flags unsupported task capture metadata" `Quick
          test_task_capture_metadata_flags_unsupported_kind;
      ] );
    ( "concurrency_semantics",
      [
        Alcotest.test_case "accepts well-formed concurrent block" `Quick
          test_concurrent_semantics_accepts_well_formed_block;
        Alcotest.test_case "flags binding result mismatch" `Quick
          test_concurrent_semantics_flags_binding_result_mismatch;
        Alcotest.test_case "flags duplicate binding names" `Quick
          test_concurrent_semantics_flags_duplicate_binding_names;
        Alcotest.test_case "flags task return mismatch" `Quick
          test_concurrent_semantics_flags_task_return_mismatch;
        Alcotest.test_case "flags timeout type" `Quick
          test_concurrent_semantics_flags_timeout_type;
        Alcotest.test_case "flags non-positive max_threads" `Quick
          test_concurrent_semantics_flags_non_positive_max_threads;
        Alcotest.test_case "flags non-list for ... concurrently" `Quick
          test_concurrent_semantics_flags_non_list_concurrently_loop;
        Alcotest.test_case "flags for ... concurrently result shape" `Quick
          test_concurrent_semantics_flags_concurrently_loop_result_shape;
        Alcotest.test_case "flags for ... concurrently discard body result"
          `Quick test_concurrent_semantics_flags_discard_body_result;
        Alcotest.test_case "flags malformed task scope" `Quick
          test_concurrent_semantics_flags_malformed_task_scope;
        Alcotest.test_case "dispatcher runs final check" `Quick
          test_dispatcher_final_runs_concurrent_semantics;
      ] );
    ( "pipeline",
      [
        Alcotest.test_case "clean code passes" `Quick
          test_pipeline_check_invariants_passes_on_clean_code;
        Alcotest.test_case "hook raises on violation" `Quick
          test_make_stage_hook_raises_on_violation;
        Alcotest.test_case "hook silent when disabled" `Quick
          test_make_stage_hook_silent_when_disabled;
        Alcotest.test_case "final critical invariants raise when disabled"
          `Quick test_final_critical_invariants_raise_when_disabled;
        Alcotest.test_case "final critical rejects raw match when disabled"
          `Quick test_final_critical_invariants_reject_raw_match_when_disabled;
        Alcotest.test_case "final critical rejects sugar when disabled" `Quick
          test_final_critical_invariants_reject_sugar_when_disabled;
        Alcotest.test_case
          "final critical rejects layoutless list_alloc when disabled" `Quick
          test_final_critical_invariants_reject_layoutless_list_alloc_when_disabled;
        Alcotest.test_case
          "final critical rejects unprepared codegen when disabled" `Quick
          test_final_critical_invariants_reject_unprepared_codegen_when_disabled;
        Alcotest.test_case "resource scope contract accepts valid scope" `Quick
          test_resource_scope_contract_accepts_well_formed;
        Alcotest.test_case "resource scope flags acquire type mismatch" `Quick
          test_resource_scope_contract_flags_acquire_type_mismatch;
        Alcotest.test_case "resource scope flags cleanup type mismatch" `Quick
          test_resource_scope_contract_flags_cleanup_type_mismatch;
        Alcotest.test_case "resource scope flags cleanup non-call" `Quick
          test_resource_scope_contract_flags_cleanup_not_direct_call;
        Alcotest.test_case "resource scope flags cleanup wrong arg" `Quick
          test_resource_scope_contract_flags_cleanup_wrong_arg;
        Alcotest.test_case "resource scope flags body type mismatch" `Quick
          test_resource_scope_contract_flags_body_result_mismatch;
        Alcotest.test_case "resource scope flags body resource result" `Quick
          test_resource_scope_contract_flags_resource_escape_result;
        Alcotest.test_case "resource scope flags record resource result" `Quick
          test_resource_scope_contract_flags_record_resource_result;
        Alcotest.test_case "resource scope flags union resource result" `Quick
          test_resource_scope_contract_flags_union_resource_result;
        Alcotest.test_case "final critical allows resource scope" `Quick
          test_final_critical_invariants_allow_resource_scope_when_disabled;
        Alcotest.test_case "resource scope rejects nonlocal break" `Quick
          test_resource_scope_final_rejects_nonlocal_break_body;
        Alcotest.test_case "resource scope rejects nonlocal continue" `Quick
          test_resource_scope_final_rejects_nonlocal_continue_body;
        Alcotest.test_case "resource scope allows rewritten nonlocal break"
          `Quick test_resource_scope_final_allows_rewritten_nonlocal_break;
        Alcotest.test_case "resource cleanup exit rejects empty cleanup stack"
          `Quick test_resource_cleanup_exit_final_rejects_empty_cleanup_stack;
        Alcotest.test_case "resource cleanup exit rejects non-Void cleanup"
          `Quick test_resource_cleanup_exit_final_rejects_nonvoid_cleanup;
        Alcotest.test_case "resource scope allows loop-local break/continue"
          `Quick test_resource_scope_final_allows_loop_local_break_continue;
        Alcotest.test_case "final rejects unboxed void-slot builtin arg" `Quick
          test_final_rejects_unboxed_void_slot_builtin_arg;
        Alcotest.test_case "final accepts explicit void-slot builtin boxes"
          `Quick test_final_accepts_explicit_void_slot_builtin_boxes;
        Alcotest.test_case "final rejects raw top-level function ref" `Quick
          test_final_rejects_raw_top_level_function_ref;
        Alcotest.test_case "final allows direct top-level function call" `Quick
          test_final_allows_direct_top_level_function_call;
        Alcotest.test_case "final allows local function value named like global"
          `Quick test_final_allows_local_function_value_named_like_global;
      ] );
  ]
