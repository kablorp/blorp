(** Tests for [Core_ssa] mutable-local lowering.

    This suite characterizes the pass boundary: straight-line [var]
    rebinding is rewritten into immutable versioned lets, while mutation
    inside control flow deliberately survives for later loop/control-flow
    handling. *)

open Blorp.Ast
open Blorp.Core

let loc =
  { line = 1; column = 1; end_line = 1; end_column = 1; loc_file = None }

let ty_int = TyNamed ("Int", [])
let ty_bool = TyNamed ("Bool", [])
let ty_void = TyNamed ("Void", [])
let ty_list_int = TyNamed ("List", [ ty_int ])
let mk d t = { desc = d; ty = t; loc }
let cint n = mk (CLit (LitInt (Int64.of_int n))) ty_int
let cbool b = mk (CLit (LitBool b)) ty_bool
let cvar name ty = mk (CVar (Var.named name)) ty
let cvoid = mk CVoid ty_void
let assign name rhs = mk (CAssign (Var.named name, rhs)) ty_void
let seq a b = mk (CSeq (a, b)) b.ty

let resource_scope name ty acquire body cleanup =
  mk
    (CResourceScope
       {
         rs_var = Var.named name;
         rs_ty = ty;
         rs_acquire = acquire;
         rs_body = body;
         rs_cleanup = cleanup;
       })
    body.ty

let bind ?(mut = false) name ty rhs =
  { bind_var = Var.named name; bind_mut = mut; bind_ty = ty; bind_rhs = rhs }

let let_ ?(mut = false) name ty rhs body =
  mk (CLet (bind ~mut name ty rhs, body)) body.ty

let desugar e =
  Blorp.Session.(reset_core_counters (current ()));
  Blorp.Core_ssa.desugar_mut_vars e

let pp_assignment_shape fmt = function
  | Blorp.Core_ssa.No_assign -> Format.fprintf fmt "No_assign"
  | Blorp.Core_ssa.Straight_line_assign ->
      Format.fprintf fmt "Straight_line_assign"
  | Blorp.Core_ssa.Control_flow_assign ->
      Format.fprintf fmt "Control_flow_assign"

let assignment_shape = Alcotest.testable pp_assignment_shape ( = )
let classify name body = Blorp.Core_ssa.classify_assignment_shape name body

let check_shape msg expected actual =
  Alcotest.check assignment_shape msg expected actual

let var_name e =
  match e.desc with CVar v -> v.vname | _ -> Alcotest.fail "expected CVar"

let test_classify_no_assign () =
  check_shape "no assignment" Blorp.Core_ssa.No_assign
    (classify "x" (cvar "x" ty_int))

let test_classify_straight_line_assign () =
  let body = seq (assign "x" (cint 2)) (cvar "x" ty_int) in
  check_shape "straight-line assignment" Blorp.Core_ssa.Straight_line_assign
    (classify "x" body)

let test_classify_control_flow_assign () =
  let body = mk (CIf (cbool true, assign "x" (cint 2), cvoid)) ty_void in
  check_shape "control-flow assignment" Blorp.Core_ssa.Control_flow_assign
    (classify "x" body)

let test_no_assignment_flips_binding_immutable () =
  let input = let_ ~mut:true "x" ty_int (cint 1) (cvar "x" ty_int) in
  match desugar input with
  | { desc = CLet (b, body); _ } ->
      Alcotest.(check string) "same name" "x" b.bind_var.vname;
      Alcotest.(check bool) "immutable" false b.bind_mut;
      Alcotest.(check string) "body still x" "x" (var_name body)
  | _ -> Alcotest.fail "expected CLet"

let test_unrelated_assignment_does_not_version_binding () =
  let body = seq (assign "y" (cint 2)) (cvar "x" ty_int) in
  let input = let_ ~mut:true "x" ty_int (cint 1) body in
  match desugar input with
  | {
   desc = CLet (b, { desc = CSeq ({ desc = CAssign (target, _); _ }, tail); _ });
   _;
  } ->
      Alcotest.(check string) "same name" "x" b.bind_var.vname;
      Alcotest.(check bool) "immutable" false b.bind_mut;
      Alcotest.(check string) "unrelated assignment survives" "y" target.vname;
      Alcotest.(check string) "tail still x" "x" (var_name tail)
  | other ->
      Alcotest.failf "unexpected shape:\n%s" (Blorp.Core.pp_to_string other)

let test_straight_line_assignment_versions_binding () =
  let body = seq (assign "x" (cint 2)) (cvar "x" ty_int) in
  let input = let_ ~mut:true "x" ty_int (cint 1) body in
  match desugar input with
  | { desc = CLet (init, { desc = CLet (next, tail); _ }); _ } ->
      Alcotest.(check string) "init version" "x__v0" init.bind_var.vname;
      Alcotest.(check string) "next version" "x__v1" next.bind_var.vname;
      Alcotest.(check bool) "init immutable" false init.bind_mut;
      Alcotest.(check bool) "next immutable" false next.bind_mut;
      Alcotest.(check string) "tail reads latest" "x__v1" (var_name tail)
  | other ->
      Alcotest.failf "unexpected shape:\n%s" (Blorp.Core.pp_to_string other)

let test_assignment_rhs_uses_previous_version () =
  let rhs = mk (CBin (Add, cvar "x" ty_int, cint 1)) ty_int in
  let body = seq (assign "x" rhs) (cvar "x" ty_int) in
  let input = let_ ~mut:true "x" ty_int (cint 1) body in
  match desugar input with
  | { desc = CLet (_, { desc = CLet (next, _); _ }); _ } -> (
      match next.bind_rhs.desc with
      | CBin (Add, lhs, { desc = CLit (LitInt 1L); _ }) ->
          Alcotest.(check string) "rhs reads previous" "x__v0" (var_name lhs)
      | _ -> Alcotest.fail "expected rewritten x + 1 rhs")
  | other ->
      Alcotest.failf "unexpected shape:\n%s" (Blorp.Core.pp_to_string other)

let test_multiple_assignments_form_version_chain () =
  let body =
    seq (assign "x" (cint 2)) (seq (assign "x" (cint 3)) (cvar "x" ty_int))
  in
  let input = let_ ~mut:true "x" ty_int (cint 1) body in
  match desugar input with
  | {
   desc = CLet (init, { desc = CLet (v1, { desc = CLet (v2, tail); _ }); _ });
   _;
  } ->
      Alcotest.(check string) "init version" "x__v0" init.bind_var.vname;
      Alcotest.(check string) "second version" "x__v1" v1.bind_var.vname;
      Alcotest.(check string) "third version" "x__v2" v2.bind_var.vname;
      Alcotest.(check string) "tail reads latest" "x__v2" (var_name tail)
  | other ->
      Alcotest.failf "unexpected shape:\n%s" (Blorp.Core.pp_to_string other)

let test_terminal_assignment_versions_binding_and_returns_void () =
  let input = let_ ~mut:true "x" ty_int (cint 1) (assign "x" (cint 2)) in
  match desugar input with
  | {
   desc =
     CLet
       ( init,
         {
           desc =
             CLet
               ( next,
                 { desc = CVoid; ty = terminal_ty; _ } );
           _;
         } );
   _;
  } ->
      Alcotest.(check string) "init version" "x__v0" init.bind_var.vname;
      Alcotest.(check string) "terminal version" "x__v1" next.bind_var.vname;
      Alcotest.(check bool) "init immutable" false init.bind_mut;
      Alcotest.(check bool) "terminal immutable" false next.bind_mut;
      Alcotest.(check bool) "terminal remains void" true (terminal_ty = ty_void)
  | other ->
      Alcotest.failf "unexpected shape:\n%s" (Blorp.Core.pp_to_string other)

let loc_at line = { loc with line; end_line = line }

let sequence_at line head tail =
  { desc = CSeq (head, tail); ty = tail.ty; loc = loc_at line }

let test_sequence_rewrite_preserves_node_metadata () =
  let inner = sequence_at 22 cvoid (cvar "x" ty_int) in
  let body = sequence_at 11 (assign "x" (cint 2)) inner in
  let input = let_ ~mut:true "x" ty_int (cint 1) body in
  match desugar input with
  | {
   desc =
     CLet
       ( _,
         {
           desc =
             CLet
               ( _,
                 {
                   desc = CSeq (_, tail);
                   ty = inner_ty;
                   loc = inner_loc;
                 } );
           ty = outer_ty;
           loc = outer_loc;
         } );
   _;
  } ->
      Alcotest.(check int) "version let keeps outer sequence line" 11
        outer_loc.line;
      Alcotest.(check int) "remaining sequence keeps inner line" 22
        inner_loc.line;
      Alcotest.(check bool) "version let keeps outer sequence type" true
        (outer_ty = ty_int);
      Alcotest.(check bool) "remaining sequence keeps inner type" true
        (inner_ty = ty_int);
      Alcotest.(check string) "tail uses current version" "x__v1"
        (var_name tail)
  | other ->
      Alcotest.failf "unexpected shape:\n%s" (Blorp.Core.pp_to_string other)

let deep_sequence_length = 50_000

let repeated_sequence count head final =
  let body = ref final in
  for _ = 1 to count do
    body := seq head !body
  done;
  !body

let test_long_assignment_sequence_is_stack_bounded () =
  let body =
    repeated_sequence deep_sequence_length (assign "x" (cint 2))
      (cvar "x" ty_int)
  in
  let current = ref (desugar (let_ ~mut:true "x" ty_int (cint 1) body)) in
  let binding_count = ref 0 in
  let valid = ref true in
  let finished = ref false in
  while not !finished do
    match !current with
    | { desc = CLet (binding, tail); _ } ->
        let expected = Printf.sprintf "x__v%d" !binding_count in
        if binding.bind_mut || binding.bind_var.vname <> expected then (
          valid := false;
          finished := true)
        else (
          incr binding_count;
          current := tail)
    | tail ->
        valid := var_name tail = Printf.sprintf "x__v%d" deep_sequence_length;
        finished := true
  done;
  Alcotest.(check bool) "all bindings are versioned without stack growth" true
    (!valid && !binding_count = deep_sequence_length + 1)

let sequence_vars_are_named expected_name expected_count expr =
  let current = ref expr in
  let count = ref 0 in
  let valid = ref true in
  let finished = ref false in
  while not !finished do
    match !current with
    | { desc = CSeq (head, tail); _ } ->
        if var_name head <> expected_name then (
          valid := false;
          finished := true)
        else (
          incr count;
          current := tail)
    | final ->
        valid := var_name final = expected_name;
        incr count;
        finished := true
  done;
  !valid && !count = expected_count

let test_nested_sequence_substitution_is_stack_bounded () =
  let branch =
    repeated_sequence deep_sequence_length (cvar "x" ty_int)
      (cvar "x" ty_int)
  in
  let control = mk (CIf (cbool true, branch, cvar "x" ty_int)) ty_int in
  let body = seq (assign "x" (cint 2)) control in
  let input = let_ ~mut:true "x" ty_int (cint 1) body in
  match desugar input with
  | {
   desc =
     CLet
       ( _,
         {
           desc =
             CLet
               ( _,
                 { desc = CIf (_, then_branch, else_branch); _ } );
           _;
         } );
   _;
  } ->
      Alcotest.(check bool)
        "nested sequence references latest version without stack growth" true
        (sequence_vars_are_named "x__v1" (deep_sequence_length + 1)
           then_branch
        && var_name else_branch = "x__v1")
  | other ->
      Alcotest.failf "unexpected shape:\n%s" (Blorp.Core.pp_to_string other)

let test_nested_let_shadowing_preserves_inner_body () =
  let inner = let_ "x" ty_int (cvar "x" ty_int) (cvar "x" ty_int) in
  let body = seq (assign "x" (cint 2)) inner in
  let input = let_ ~mut:true "x" ty_int (cint 1) body in
  match desugar input with
  | {
   desc =
     CLet
       (_, { desc = CLet (_, { desc = CLet (inner_bind, inner_body); _ }); _ });
   _;
  } ->
      Alcotest.(check string)
        "inner binding unchanged" "x" inner_bind.bind_var.vname;
      Alcotest.(check string)
        "inner rhs sees outer current version" "x__v1"
        (var_name inner_bind.bind_rhs);
      Alcotest.(check string)
        "inner body remains shadowed" "x" (var_name inner_body)
  | other ->
      Alcotest.failf "unexpected shape:\n%s" (Blorp.Core.pp_to_string other)

let test_lambda_param_shadowing_preserves_body () =
  let lam_ty =
    TyFunc { params = [ ty_int ]; return = ty_int; is_pure = true }
  in
  let lam =
    mk
      (CLambda
         {
           lam_params = [ (Var.named "x", ty_int) ];
           lam_body = cvar "x" ty_int;
           lam_return_ty = ty_int;
           lam_is_pure = true;
         })
      lam_ty
  in
  let body = seq (assign "x" (cint 2)) lam in
  let input = let_ ~mut:true "x" ty_int (cint 1) body in
  match desugar input with
  | { desc = CLet (_, { desc = CLet (_, { desc = CLambda lam'; _ }); _ }); _ }
    ->
      Alcotest.(check string)
        "lambda body remains param" "x" (var_name lam'.lam_body)
  | other ->
      Alcotest.failf "unexpected shape:\n%s" (Blorp.Core.pp_to_string other)

let test_for_binder_shadowing_preserves_body () =
  let loop =
    mk
      (CFor
         (loop_binder_named "x" ty_int, cvar "xs" ty_list_int, cvar "x" ty_int))
      ty_void
  in
  let body = seq (assign "x" (cint 2)) loop in
  let input = let_ ~mut:true "x" ty_int (cint 1) body in
  match desugar input with
  | {
   desc =
     CLet
       (_, { desc = CLet (_, { desc = CFor (binder, iter, loop_body); _ }); _ });
   _;
  } ->
      Alcotest.(check string) "binder unchanged" "x" binder.loop_var.vname;
      Alcotest.(check string) "iter unaffected" "xs" (var_name iter);
      Alcotest.(check string)
        "loop body remains binder" "x" (var_name loop_body)
  | other ->
      Alcotest.failf "unexpected shape:\n%s" (Blorp.Core.pp_to_string other)

let test_resource_scope_shadowing_preserves_body_and_cleanup () =
  let scope =
    resource_scope "x" ty_int (cvar "x" ty_int) (cvar "x" ty_int)
      (cvar "x" ty_int)
  in
  let body = seq (assign "x" (cint 2)) scope in
  let input = let_ ~mut:true "x" ty_int (cint 1) body in
  match desugar input with
  | {
   desc =
     CLet
       ( _,
         {
           desc =
             CLet
               ( _,
                 {
                   desc =
                     CResourceScope
                       { rs_acquire; rs_body; rs_cleanup; rs_var; _ };
                   _;
                 } );
           _;
         } );
   _;
  } ->
      Alcotest.(check string) "scope binding unchanged" "x" rs_var.vname;
      Alcotest.(check string)
        "acquisition sees outer current version" "x__v1" (var_name rs_acquire);
      Alcotest.(check string)
        "body remains scoped binding" "x" (var_name rs_body);
      Alcotest.(check string)
        "cleanup remains scoped binding" "x" (var_name rs_cleanup)
  | other ->
      Alcotest.failf "unexpected shape:\n%s" (Blorp.Core.pp_to_string other)

let test_resource_scope_shadowed_assignment_does_not_version_outer () =
  let scope =
    resource_scope "x" ty_int (cint 0)
      (seq (assign "x" (cint 2)) (cvar "x" ty_int))
      cvoid
  in
  let input = let_ ~mut:true "x" ty_int (cint 1) scope in
  match desugar input with
  | { desc = CLet (b, { desc = CResourceScope { rs_body; _ }; _ }); _ } -> (
      Alcotest.(check string) "outer binding unchanged" "x" b.bind_var.vname;
      Alcotest.(check bool) "outer binding immutable" false b.bind_mut;
      match rs_body.desc with
      | CSeq ({ desc = CAssign (target, _); _ }, tail) ->
          Alcotest.(check string)
            "assignment targets scoped binding" "x" target.vname;
          Alcotest.(check string)
            "tail reads scoped binding" "x" (var_name tail)
      | _ -> Alcotest.fail "expected resource body sequence")
  | other ->
      Alcotest.failf "unexpected shape:\n%s" (Blorp.Core.pp_to_string other)

let test_control_flow_assignment_survives () =
  let branch = mk (CIf (cbool true, assign "x" (cint 2), cvoid)) ty_void in
  let input = let_ ~mut:true "x" ty_int (cint 1) branch in
  match desugar input with
  | {
   desc = CLet (b, { desc = CIf (_, { desc = CAssign (target, _); _ }, _); _ });
   _;
  } ->
      Alcotest.(check string) "binding remains source name" "x" b.bind_var.vname;
      Alcotest.(check bool) "binding remains mutable" true b.bind_mut;
      Alcotest.(check string) "assignment survives" "x" target.vname
  | other ->
      Alcotest.failf "unexpected shape:\n%s" (Blorp.Core.pp_to_string other)

let suite =
  [
    ( "classification",
      [
        Alcotest.test_case "no assign" `Quick test_classify_no_assign;
        Alcotest.test_case "straight-line assign" `Quick
          test_classify_straight_line_assign;
        Alcotest.test_case "control-flow assign" `Quick
          test_classify_control_flow_assign;
      ] );
    ( "desugar_mut_vars",
      [
        Alcotest.test_case "no assignment flips immutable" `Quick
          test_no_assignment_flips_binding_immutable;
        Alcotest.test_case "unrelated assignment does not version" `Quick
          test_unrelated_assignment_does_not_version_binding;
        Alcotest.test_case "straight-line assignment versions binding" `Quick
          test_straight_line_assignment_versions_binding;
        Alcotest.test_case "assignment rhs uses previous version" `Quick
          test_assignment_rhs_uses_previous_version;
        Alcotest.test_case "multiple assignments form version chain" `Quick
          test_multiple_assignments_form_version_chain;
        Alcotest.test_case "terminal assignment versions and returns void"
          `Quick test_terminal_assignment_versions_binding_and_returns_void;
        Alcotest.test_case "sequence rewrite preserves node metadata" `Quick
          test_sequence_rewrite_preserves_node_metadata;
        Alcotest.test_case "long assignment sequence is stack bounded" `Quick
          test_long_assignment_sequence_is_stack_bounded;
        Alcotest.test_case "nested sequence substitution is stack bounded"
          `Quick test_nested_sequence_substitution_is_stack_bounded;
        Alcotest.test_case "nested let shadowing" `Quick
          test_nested_let_shadowing_preserves_inner_body;
        Alcotest.test_case "lambda param shadowing" `Quick
          test_lambda_param_shadowing_preserves_body;
        Alcotest.test_case "for binder shadowing" `Quick
          test_for_binder_shadowing_preserves_body;
        Alcotest.test_case "resource scope shadowing" `Quick
          test_resource_scope_shadowing_preserves_body_and_cleanup;
        Alcotest.test_case "resource scope shadowed assignment" `Quick
          test_resource_scope_shadowed_assignment_does_not_version_outer;
        Alcotest.test_case "control-flow assignment survives" `Quick
          test_control_flow_assignment_survives;
      ] );
  ]
