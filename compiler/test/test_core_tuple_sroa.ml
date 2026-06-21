(** Tests for Core tuple scalar replacement. *)

open Blorp.Ast
open Blorp.Core
module Sroa = Blorp.Core_tuple_sroa

let loc = dummy_loc
let ty_int = TyNamed ("Int", [])
let ty_bool = TyNamed ("Bool", [])
let ty_string = TyNamed ("String", [])
let ty_void = TyNamed ("Void", [])
let ty_pair = TyTuple [ ty_int; ty_int ]
let ty_string_pair = TyTuple [ ty_string; ty_int ]
let mk ty desc = { desc; ty; loc }
let cvar name ty = mk ty (CVar (Var.named name))
let cint n = mk ty_int (CLit (LitInt (Int64.of_int n)))
let cbool b = mk ty_bool (CLit (LitBool b))
let cvoid = mk ty_void CVoid
let param name ty = { cp_name = Var.named name; cp_ty = ty; cp_loc = loc }
let fn_ty params return = TyFunc { params; return; is_pure = true }

let cstring s =
  mk ty_string (CLit (LitString (s, { sf_multiline = false; sf_raw = false })))

let field obj name ty = mk ty (CField (obj, name))

let resource_scope name ty acquire body cleanup =
  mk body.ty
    (CResourceScope
       {
         rs_var = Var.named name;
         rs_ty = ty;
         rs_acquire = acquire;
         rs_body = body;
         rs_cleanup = cleanup;
       })

let tuple_let ?(mut = false) name tuple_ty elems body =
  mk body.ty
    (CLet
       ( {
           bind_var = Var.named name;
           bind_mut = mut;
           bind_ty = tuple_ty;
           bind_rhs = mk tuple_ty (CTuple elems);
         },
         body ))

let simple_let name rhs body =
  mk body.ty
    (CLet
       ( {
           bind_var = Var.named name;
           bind_mut = false;
           bind_ty = rhs.ty;
           bind_rhs = rhs;
         },
         body ))

let func ?(def_id = 7) name params return_ty body =
  {
    cf_name = name;
    cf_module = None;
    cf_type_params = [];
    cf_params = params;
    cf_return_ty = return_ty;
    cf_body = Some body;
    cf_is_pure = true;
    cf_kind = CFUser;
    cf_def_id = def_id;
  }

let decl f = { cd_desc = CDFunc f; cd_loc = loc; cd_doc = None }

let rec contains_tuple_construct expr =
  match expr.desc with
  | CTuple _ | CTupleConstruct _ -> true
  | _ ->
      let found = ref false in
      ignore
        (map_children
           (fun child ->
             if contains_tuple_construct child then found := true;
             child)
           expr);
      !found

let rec contains_field_of name expr =
  match expr.desc with
  | CField ({ desc = CVar v; _ }, _) when v.vname = name -> true
  | _ ->
      let found = ref false in
      ignore
        (map_children
           (fun child ->
             if contains_field_of name child then found := true;
             child)
           expr);
      !found

let rec contains_call_to name expr =
  match expr.desc with
  | CCall (CKUser (callee, _), _, _) when callee = name -> true
  | _ ->
      let found = ref false in
      ignore
        (map_children
           (fun child ->
             if contains_call_to name child then found := true;
             child)
           expr);
      !found

let test_removed_tuple_binding_guard_rejects_leftover_root_reference () =
  let root_var = Var.named "pair" in
  let body = field (mk ty_pair (CVar root_var)) "0" ty_int in
  Test_helpers.check_core_error_raises
    ~phase:(Blorp.Core_error.Stage Blorp.Core_stage.Fusion)
    ~msg_contains:"tuple SROA removed binding" (fun () ->
      Sroa.assert_removed_tuple_binding_unreferenced ~loc ~root_var body)

let rec count_sroa_bindings expr =
  let here =
    match expr.desc with
    | CLet (binding, _)
      when String.starts_with ~prefix:"__tuple_sroa_" binding.bind_var.vname ->
        1
    | _ -> 0
  in
  let nested = ref 0 in
  ignore
    (map_children
       (fun child ->
         nested := !nested + count_sroa_bindings child;
         child)
       expr);
  here + !nested

let rec count_cond_bindings expr =
  let here =
    match expr.desc with
    | CLet (binding, _)
      when String.starts_with ~prefix:"__tuple_cond_" binding.bind_var.vname ->
        1
    | _ -> 0
  in
  let nested = ref 0 in
  ignore
    (map_children
       (fun child ->
         nested := !nested + count_cond_bindings child;
         child)
       expr);
  here + !nested

let test_local_field_access_scalar_replaced () =
  let pair = cvar "pair" ty_pair in
  let body =
    mk ty_int (CBin (Add, field pair "0" ty_int, field pair "1" ty_int))
  in
  let expr = tuple_let "pair" ty_pair [ cint 20; cint 22 ] body in
  let rewritten = Sroa.rewrite_expr expr in
  Alcotest.(check bool)
    "tuple allocation removed" false
    (contains_tuple_construct rewritten);
  Alcotest.(check bool)
    "field accesses removed" false
    (contains_field_of "pair" rewritten)

let test_escaping_tuple_is_left_heap_allocated () =
  let body = cvar "pair" ty_pair in
  let expr = tuple_let "pair" ty_pair [ cint 1; cint 2 ] body in
  let rewritten = Sroa.rewrite_expr expr in
  Alcotest.(check bool)
    "escaping tuple remains" true
    (contains_tuple_construct rewritten)

let test_mutable_tuple_binding_is_left_heap_allocated () =
  let pair = cvar "pair" ty_pair in
  let body = field pair "0" ty_int in
  let expr = tuple_let ~mut:true "pair" ty_pair [ cint 1; cint 2 ] body in
  let rewritten = Sroa.rewrite_expr expr in
  Alcotest.(check bool)
    "mutable tuple remains" true
    (contains_tuple_construct rewritten)

let test_managed_field_scalar_replaced_as_local_binding () =
  let pair = cvar "pair" ty_string_pair in
  let body = field pair "0" ty_string in
  let expr = tuple_let "pair" ty_string_pair [ cstring "hello"; cint 5 ] body in
  let rewritten = Sroa.rewrite_expr expr in
  Alcotest.(check bool)
    "managed tuple allocation removed" false
    (contains_tuple_construct rewritten);
  match rewritten.desc with
  | CLet (first, _) ->
      Alcotest.(check string)
        "first scalar binding keeps String type" "String"
        (Blorp.Types.type_to_string first.bind_ty)
  | _ -> Alcotest.fail "expected scalar element binding"

let test_branch_local_alias_does_not_leak_to_sibling_branch () =
  let pair = cvar "pair" ty_pair in
  let other = cvar "other" ty_pair in
  let branch_alias = cvar "branch_alias" ty_pair in
  let then_branch =
    simple_let "branch_alias" pair (field branch_alias "0" ty_int)
  in
  let else_branch =
    simple_let "branch_alias" other (field branch_alias "0" ty_int)
  in
  let body = mk ty_int (CIf (cbool true, then_branch, else_branch)) in
  let expr = tuple_let "pair" ty_pair [ cint 1; cint 2 ] body in
  let rewritten = Sroa.rewrite_expr expr in
  Alcotest.(check bool)
    "root tuple allocation removed" false
    (contains_tuple_construct rewritten);
  Alcotest.(check bool)
    "root alias field accesses removed" false
    (contains_field_of "pair" rewritten);
  Alcotest.(check bool)
    "sibling branch keeps unrelated same-name field" true
    (contains_field_of "branch_alias" rewritten)

let test_resource_scope_shadowed_tuple_alias_is_not_rewritten () =
  let pair = cvar "pair" ty_pair in
  let scoped =
    resource_scope "pair" ty_pair (cvar "open_pair" ty_pair)
      (field pair "0" ty_int) cvoid
  in
  let expr = tuple_let "pair" ty_pair [ cint 1; cint 2 ] scoped in
  let rewritten = Sroa.rewrite_expr expr in
  let rec find_scope expr =
    match expr.desc with
    | CResourceScope scope -> Some scope
    | _ ->
        let found = ref None in
        ignore
          (map_children
             (fun child ->
               if Option.is_none !found then found := find_scope child;
               child)
             expr);
        !found
  in
  match find_scope rewritten with
  | Some { rs_body = { desc = CField ({ desc = CVar v; _ }, "0"); _ }; _ } ->
      Alcotest.(check string)
        "resource body still reads scoped tuple" "pair" v.vname
  | Some { rs_body; _ } ->
      Alcotest.failf "resource body was rewritten:\n%s"
        (Blorp.Core.pp_to_string rs_body)
  | None -> Alcotest.fail "expected resource scope"

let test_local_if_tuple_binding_scalar_replaced () =
  let pair = cvar "pair" ty_pair in
  let body =
    mk ty_int (CBin (Add, field pair "0" ty_int, field pair "1" ty_int))
  in
  let expr =
    mk ty_int
      (CLet
         ( {
             bind_var = Var.named "pair";
             bind_mut = false;
             bind_ty = ty_pair;
             bind_rhs =
               mk ty_pair
                 (CIf
                    ( cbool true,
                      mk ty_pair (CTuple [ cint 20; cint 22 ]),
                      mk ty_pair (CTuple [ cint 1; cint 2 ]) ));
           },
           body ))
  in
  let rewritten = Sroa.rewrite_expr expr in
  Alcotest.(check bool)
    "tuple allocation removed" false
    (contains_tuple_construct rewritten);
  Alcotest.(check bool)
    "field accesses removed" false
    (contains_field_of "pair" rewritten);
  Alcotest.(check int)
    "all tuple elements stay evaluated" 2
    (count_sroa_bindings rewritten);
  Alcotest.(check int) "condition bound once" 1 (count_cond_bindings rewritten)

let test_managed_local_if_tuple_binding_scalar_replaced () =
  let pair = cvar "pair" ty_string_pair in
  let body = field pair "0" ty_string in
  let expr =
    mk ty_string
      (CLet
         ( {
             bind_var = Var.named "pair";
             bind_mut = false;
             bind_ty = ty_string_pair;
             bind_rhs =
               mk ty_string_pair
                 (CIf
                    ( cbool true,
                      mk ty_string_pair (CTuple [ cstring "left"; cint 1 ]),
                      mk ty_string_pair (CTuple [ cstring "right"; cint 2 ]) ));
           },
           body ))
  in
  let rewritten = Sroa.rewrite_expr expr in
  Alcotest.(check bool)
    "managed tuple allocation removed" false
    (contains_tuple_construct rewritten);
  Alcotest.(check bool)
    "managed tuple-root field accesses removed" false
    (contains_field_of "pair" rewritten);
  Alcotest.(check int)
    "all tuple elements stay evaluated" 2
    (count_sroa_bindings rewritten);
  Alcotest.(check int) "condition bound once" 1 (count_cond_bindings rewritten)

let test_local_if_tuple_binding_mismatched_arity_stays_heap_allocated () =
  let pair = cvar "pair" ty_pair in
  let body = field pair "0" ty_int in
  let expr =
    mk ty_int
      (CLet
         ( {
             bind_var = Var.named "pair";
             bind_mut = false;
             bind_ty = ty_pair;
             bind_rhs =
               mk ty_pair
                 (CIf
                    ( cbool true,
                      mk ty_pair (CTuple [ cint 20; cint 22 ]),
                      mk (TyTuple [ ty_int ]) (CTuple [ cint 1 ]) ));
           },
           body ))
  in
  let rewritten = Sroa.rewrite_expr expr in
  Alcotest.(check bool)
    "mismatched arity remains heap allocated" true
    (contains_tuple_construct rewritten);
  Alcotest.(check bool)
    "field access remains on original tuple binding" true
    (contains_field_of "pair" rewritten)

let test_local_if_tuple_binding_mismatched_element_type_stays_heap_allocated ()
    =
  let pair = cvar "pair" ty_pair in
  let body = field pair "0" ty_int in
  let expr =
    mk ty_int
      (CLet
         ( {
             bind_var = Var.named "pair";
             bind_mut = false;
             bind_ty = ty_pair;
             bind_rhs =
               mk ty_pair
                 (CIf
                    ( cbool true,
                      mk ty_pair (CTuple [ cint 20; cint 22 ]),
                      mk ty_string_pair (CTuple [ cstring "wrong"; cint 1 ]) ));
           },
           body ))
  in
  let rewritten = Sroa.rewrite_expr expr in
  Alcotest.(check bool)
    "mismatched element type remains heap allocated" true
    (contains_tuple_construct rewritten);
  Alcotest.(check bool)
    "field access remains on original tuple binding" true
    (contains_field_of "pair" rewritten)

let test_local_match_tuple_binding_scalar_replaced () =
  let choice = cvar "choice" ty_int in
  let pair = cvar "pair" ty_pair in
  let match_rhs =
    mk ty_pair
      (CMatch
         ( choice,
           CTSwitchLit
             {
               ctl_scrut = AccRoot;
               ctl_cases =
                 [
                   ( LitInt 0L,
                     CTLeaf
                       {
                         ct_bindings = [];
                         ct_body = mk ty_pair (CTuple [ cint 1; cint 2 ]);
                       } );
                 ];
               ctl_default =
                 CTLeaf
                   {
                     ct_bindings = [];
                     ct_body = mk ty_pair (CTuple [ cint 20; cint 22 ]);
                   };
             } ))
  in
  let caller_body =
    simple_let "pair" match_rhs
      (mk ty_int (CBin (Add, field pair "0" ty_int, field pair "1" ty_int)))
  in
  let caller =
    func ~def_id:56 "caller" [ param "choice" ty_int ] ty_int caller_body
  in
  let rewritten =
    Sroa.rewrite_program
      ~reg:(Blorp.Codegen_types.create_registry ())
      [ decl caller ]
  in
  match rewritten with
  | [ { cd_desc = CDFunc { cf_body = Some body; _ }; _ } ] ->
      Alcotest.(check bool)
        "tuple allocation removed" false
        (contains_tuple_construct body);
      Alcotest.(check bool)
        "tuple-root field accesses removed" false
        (contains_field_of "pair" body);
      Alcotest.(check int)
        "all tuple elements stay evaluated" 2 (count_sroa_bindings body)
  | _ -> Alcotest.fail "expected rewritten caller function"

let test_local_match_tuple_binding_non_tuple_leaf_stays_heap_allocated () =
  let choice = cvar "choice" ty_int in
  let pair = cvar "pair" ty_pair in
  let fallback = cvar "fallback" ty_pair in
  let match_rhs =
    mk ty_pair
      (CMatch
         ( choice,
           CTSwitchLit
             {
               ctl_scrut = AccRoot;
               ctl_cases =
                 [
                   ( LitInt 0L,
                     CTLeaf
                       {
                         ct_bindings = [];
                         ct_body = mk ty_pair (CTuple [ cint 1; cint 2 ]);
                       } );
                 ];
               ctl_default = CTLeaf { ct_bindings = []; ct_body = fallback };
             } ))
  in
  let caller_body = simple_let "pair" match_rhs (field pair "0" ty_int) in
  let caller =
    func ~def_id:57 "caller" [ param "choice" ty_int ] ty_int caller_body
  in
  let rewritten =
    Sroa.rewrite_program
      ~reg:(Blorp.Codegen_types.create_registry ())
      [ decl caller ]
  in
  match rewritten with
  | [ { cd_desc = CDFunc { cf_body = Some body; _ }; _ } ] ->
      Alcotest.(check bool)
        "non-tuple leaf keeps tuple allocation" true
        (contains_tuple_construct body);
      Alcotest.(check bool)
        "field access remains on original tuple binding" true
        (contains_field_of "pair" body)
  | _ -> Alcotest.fail "expected rewritten caller function"

let test_local_match_tuple_binding_mismatched_arity_stays_heap_allocated () =
  let choice = cvar "choice" ty_int in
  let pair = cvar "pair" ty_pair in
  let match_rhs =
    mk ty_pair
      (CMatch
         ( choice,
           CTSwitchLit
             {
               ctl_scrut = AccRoot;
               ctl_cases =
                 [
                   ( LitInt 0L,
                     CTLeaf
                       {
                         ct_bindings = [];
                         ct_body = mk ty_pair (CTuple [ cint 1; cint 2 ]);
                       } );
                 ];
               ctl_default =
                 CTLeaf
                   {
                     ct_bindings = [];
                     ct_body = mk (TyTuple [ ty_int ]) (CTuple [ cint 20 ]);
                   };
             } ))
  in
  let caller_body = simple_let "pair" match_rhs (field pair "0" ty_int) in
  let caller =
    func ~def_id:58 "caller" [ param "choice" ty_int ] ty_int caller_body
  in
  let rewritten =
    Sroa.rewrite_program
      ~reg:(Blorp.Codegen_types.create_registry ())
      [ decl caller ]
  in
  match rewritten with
  | [ { cd_desc = CDFunc { cf_body = Some body; _ }; _ } ] ->
      Alcotest.(check bool)
        "mismatched match arity keeps tuple allocation" true
        (contains_tuple_construct body);
      Alcotest.(check bool)
        "field access remains on original tuple binding" true
        (contains_field_of "pair" body)
  | _ -> Alcotest.fail "expected rewritten caller function"

let test_local_match_tuple_binding_mismatched_element_type_stays_heap_allocated
    () =
  let choice = cvar "choice" ty_int in
  let pair = cvar "pair" ty_pair in
  let match_rhs =
    mk ty_pair
      (CMatch
         ( choice,
           CTSwitchLit
             {
               ctl_scrut = AccRoot;
               ctl_cases =
                 [
                   ( LitInt 0L,
                     CTLeaf
                       {
                         ct_bindings = [];
                         ct_body = mk ty_pair (CTuple [ cint 1; cint 2 ]);
                       } );
                 ];
               ctl_default =
                 CTLeaf
                   {
                     ct_bindings = [];
                     ct_body =
                       mk ty_string_pair (CTuple [ cstring "wrong"; cint 20 ]);
                   };
             } ))
  in
  let caller_body = simple_let "pair" match_rhs (field pair "0" ty_int) in
  let caller =
    func ~def_id:59 "caller" [ param "choice" ty_int ] ty_int caller_body
  in
  let rewritten =
    Sroa.rewrite_program
      ~reg:(Blorp.Codegen_types.create_registry ())
      [ decl caller ]
  in
  match rewritten with
  | [ { cd_desc = CDFunc { cf_body = Some body; _ }; _ } ] ->
      Alcotest.(check bool)
        "mismatched match element type keeps tuple allocation" true
        (contains_tuple_construct body);
      Alcotest.(check bool)
        "field access remains on original tuple binding" true
        (contains_field_of "pair" body)
  | _ -> Alcotest.fail "expected rewritten caller function"

let test_immediate_tuple_field_access_scalar_replaced () =
  let tuple = mk ty_pair (CTuple [ cint 40; cint 2 ]) in
  let expr = field tuple "0" ty_int in
  let rewritten = Sroa.rewrite_expr expr in
  Alcotest.(check bool)
    "tuple allocation removed" false
    (contains_tuple_construct rewritten);
  Alcotest.(check int)
    "all tuple elements stay evaluated" 2
    (count_sroa_bindings rewritten)

let test_tuple_match_bindings_scalar_replaced () =
  let pair = cvar "pair" ty_pair in
  let a = Var.named "a" in
  let b = Var.named "b" in
  let body =
    mk ty_int
      (CMatch
         ( pair,
           CTLeaf
             {
               ct_bindings =
                 borrowed_match_binding_pairs
                   [
                     (a, AccTupleField (AccRoot, 0));
                     (b, AccTupleField (AccRoot, 1));
                   ];
               ct_body =
                 mk ty_int (CBin (Add, cvar "a" ty_int, cvar "b" ty_int));
             } ))
  in
  let expr = tuple_let "pair" ty_pair [ cint 3; cint 7 ] body in
  let rewritten = Sroa.rewrite_expr expr in
  Alcotest.(check bool)
    "tuple allocation removed" false
    (contains_tuple_construct rewritten);
  Alcotest.(check bool)
    "tuple-root field accesses removed" false
    (contains_field_of "pair" rewritten)

let test_tuple_match_literal_split_scalar_replaced () =
  let pair = cvar "pair" ty_pair in
  let y = Var.named "y" in
  let body =
    mk ty_int
      (CMatch
         ( pair,
           CTSwitchLit
             {
               ctl_scrut = AccTupleField (AccRoot, 0);
               ctl_cases =
                 [
                   ( LitInt 0L,
                     CTLeaf
                       {
                         ct_bindings =
                           borrowed_match_binding_pairs
                             [ (y, AccTupleField (AccRoot, 1)) ];
                         ct_body = cvar "y" ty_int;
                       } );
                 ];
               ctl_default = CTLeaf { ct_bindings = []; ct_body = cint 99 };
             } ))
  in
  let expr = tuple_let "pair" ty_pair [ cint 0; cint 5 ] body in
  let rewritten = Sroa.rewrite_expr expr in
  Alcotest.(check bool)
    "tuple allocation removed" false
    (contains_tuple_construct rewritten);
  Alcotest.(check bool)
    "tuple-root field accesses removed" false
    (contains_field_of "pair" rewritten)

let test_immediate_tuple_match_scalar_replaced () =
  let tuple = mk ty_pair (CTuple [ cint 0; cint 5 ]) in
  let y = Var.named "y" in
  let body =
    mk ty_int
      (CMatch
         ( tuple,
           CTSwitchLit
             {
               ctl_scrut = AccTupleField (AccRoot, 0);
               ctl_cases =
                 [
                   ( LitInt 0L,
                     CTLeaf
                       {
                         ct_bindings =
                           borrowed_match_binding_pairs
                             [ (y, AccTupleField (AccRoot, 1)) ];
                         ct_body = cvar "y" ty_int;
                       } );
                 ];
               ctl_default = CTLeaf { ct_bindings = []; ct_body = cint 99 };
             } ))
  in
  let rewritten = Sroa.rewrite_expr body in
  Alcotest.(check bool)
    "tuple allocation removed" false
    (contains_tuple_construct rewritten);
  Alcotest.(check int)
    "all tuple elements stay evaluated" 2
    (count_sroa_bindings rewritten)

let test_tuple_match_with_nested_constructor_stays_heap_allocated () =
  let ty_option_int = TyNamed ("Option", [ ty_int ]) in
  let ty_option_pair = TyTuple [ ty_option_int; ty_option_int ] in
  let pair = cvar "pair" ty_option_pair in
  let body =
    mk ty_bool
      (CMatch
         ( pair,
           CTSwitchTag
             {
               cts_scrut = AccTupleField (AccRoot, 0);
               cts_cases =
                 [ ("Some", CTLeaf { ct_bindings = []; ct_body = cbool true }) ];
               cts_default =
                 Some (CTLeaf { ct_bindings = []; ct_body = cbool false });
             } ))
  in
  let expr =
    tuple_let "pair" ty_option_pair
      [ cvar "left" ty_option_int; cvar "right" ty_option_int ]
      body
  in
  let rewritten = Sroa.rewrite_expr expr in
  Alcotest.(check bool)
    "nested constructor tuple match remains heap allocated" true
    (contains_tuple_construct rewritten)

let test_tuple_return_call_scalar_replaced_when_fields_only () =
  let def_id = 42 in
  let a = cvar "a" ty_int in
  let b = cvar "b" ty_int in
  let result_body = cvar "result" ty_pair in
  let swap_body = tuple_let "result" ty_pair [ b; a ] result_body in
  let swap =
    func ~def_id "swap" [ param "a" ty_int; param "b" ty_int ] ty_pair swap_body
  in
  let call =
    mk ty_pair
      (CCall
         ( CKUser ("swap", Some def_id),
           cvar "swap" (fn_ty [ ty_int; ty_int ] ty_pair),
           [ cint 1; cint 2 ] ))
  in
  let pair = cvar "pair" ty_pair in
  let caller_body =
    simple_let "pair" call
      (mk ty_int (CBin (Add, field pair "0" ty_int, field pair "1" ty_int)))
  in
  let caller = func ~def_id:43 "caller" [] ty_int caller_body in
  let rewritten =
    Sroa.rewrite_program
      ~reg:(Blorp.Codegen_types.create_registry ())
      [ decl swap; decl caller ]
  in
  match rewritten with
  | [ _; { cd_desc = CDFunc { cf_body = Some body; _ }; _ } ] ->
      Alcotest.(check bool)
        "tuple allocation removed" false
        (contains_tuple_construct body);
      Alcotest.(check bool)
        "tuple-return call removed" false
        (contains_call_to "swap" body);
      Alcotest.(check bool)
        "tuple-root field accesses removed" false
        (contains_field_of "pair" body)
  | _ -> Alcotest.fail "expected rewritten caller function"

let test_immediate_tuple_return_call_field_scalar_replaced () =
  let def_id = 44 in
  let a = cvar "a" ty_int in
  let b = cvar "b" ty_int in
  let swap_body = tuple_let "result" ty_pair [ b; a ] (cvar "result" ty_pair) in
  let swap =
    func ~def_id "swap" [ param "a" ty_int; param "b" ty_int ] ty_pair swap_body
  in
  let call =
    mk ty_pair
      (CCall
         ( CKUser ("swap", Some def_id),
           cvar "swap" (fn_ty [ ty_int; ty_int ] ty_pair),
           [ cint 3; cint 4 ] ))
  in
  let caller = func ~def_id:45 "caller" [] ty_int (field call "0" ty_int) in
  let rewritten =
    Sroa.rewrite_program
      ~reg:(Blorp.Codegen_types.create_registry ())
      [ decl swap; decl caller ]
  in
  match rewritten with
  | [ _; { cd_desc = CDFunc { cf_body = Some body; _ }; _ } ] ->
      Alcotest.(check bool)
        "tuple allocation removed" false
        (contains_tuple_construct body);
      Alcotest.(check bool)
        "tuple-return call removed" false
        (contains_call_to "swap" body);
      Alcotest.(check int)
        "all tuple elements stay evaluated" 2 (count_sroa_bindings body)
  | _ -> Alcotest.fail "expected rewritten caller function"

let test_immediate_tuple_return_call_match_scalar_replaced () =
  let def_id = 46 in
  let a = cvar "a" ty_int in
  let b = cvar "b" ty_int in
  let swap_body = tuple_let "result" ty_pair [ b; a ] (cvar "result" ty_pair) in
  let swap =
    func ~def_id "swap" [ param "a" ty_int; param "b" ty_int ] ty_pair swap_body
  in
  let call =
    mk ty_pair
      (CCall
         ( CKUser ("swap", Some def_id),
           cvar "swap" (fn_ty [ ty_int; ty_int ] ty_pair),
           [ cint 5; cint 6 ] ))
  in
  let x = Var.named "x" in
  let y = Var.named "y" in
  let caller_body =
    mk ty_int
      (CMatch
         ( call,
           CTLeaf
             {
               ct_bindings =
                 borrowed_match_binding_pairs
                   [
                     (x, AccTupleField (AccRoot, 0));
                     (y, AccTupleField (AccRoot, 1));
                   ];
               ct_body =
                 mk ty_int (CBin (Add, cvar "x" ty_int, cvar "y" ty_int));
             } ))
  in
  let caller = func ~def_id:47 "caller" [] ty_int caller_body in
  let rewritten =
    Sroa.rewrite_program
      ~reg:(Blorp.Codegen_types.create_registry ())
      [ decl swap; decl caller ]
  in
  match rewritten with
  | [ _; { cd_desc = CDFunc { cf_body = Some body; _ }; _ } ] ->
      Alcotest.(check bool)
        "tuple allocation removed" false
        (contains_tuple_construct body);
      Alcotest.(check bool)
        "tuple-return call removed" false
        (contains_call_to "swap" body);
      Alcotest.(check int)
        "all tuple elements stay evaluated" 2 (count_sroa_bindings body)
  | _ -> Alcotest.fail "expected rewritten caller function"

let test_tuple_return_call_simple_expr_elements_scalar_replaced () =
  let def_id = 48 in
  let a = cvar "a" ty_int in
  let b = cvar "b" ty_int in
  let pair_body =
    mk ty_pair
      (CTuple
         [
           mk ty_int (CBin (Add, a, cint 1)); mk ty_int (CBin (Mul, b, cint 2));
         ])
  in
  let pair =
    func ~def_id "pair_expr"
      [ param "a" ty_int; param "b" ty_int ]
      ty_pair pair_body
  in
  let call =
    mk ty_pair
      (CCall
         ( CKUser ("pair_expr", Some def_id),
           cvar "pair_expr" (fn_ty [ ty_int; ty_int ] ty_pair),
           [ cint 2; cint 3 ] ))
  in
  let pair_var = cvar "pair" ty_pair in
  let caller_body =
    simple_let "pair" call
      (mk ty_int
         (CBin (Add, field pair_var "0" ty_int, field pair_var "1" ty_int)))
  in
  let caller = func ~def_id:49 "caller" [] ty_int caller_body in
  let rewritten =
    Sroa.rewrite_program
      ~reg:(Blorp.Codegen_types.create_registry ())
      [ decl pair; decl caller ]
  in
  match rewritten with
  | [ _; { cd_desc = CDFunc { cf_body = Some body; _ }; _ } ] ->
      Alcotest.(check bool)
        "tuple allocation removed" false
        (contains_tuple_construct body);
      Alcotest.(check bool)
        "tuple-return call removed" false
        (contains_call_to "pair_expr" body);
      Alcotest.(check bool)
        "tuple-root field accesses removed" false
        (contains_field_of "pair" body)
  | _ -> Alcotest.fail "expected rewritten caller function"

let test_tuple_return_call_local_expr_elements_scalar_replaced () =
  let def_id = 50 in
  let a = cvar "a" ty_int in
  let b = cvar "b" ty_int in
  let x_rhs = mk ty_int (CBin (Add, a, cint 1)) in
  let y_rhs = mk ty_int (CBin (Mul, b, cint 2)) in
  let pair_body =
    simple_let "x" x_rhs
      (simple_let "y" y_rhs
         (mk ty_pair (CTuple [ cvar "x" ty_int; cvar "y" ty_int ])))
  in
  let pair =
    func ~def_id "pair_locals"
      [ param "a" ty_int; param "b" ty_int ]
      ty_pair pair_body
  in
  let call =
    mk ty_pair
      (CCall
         ( CKUser ("pair_locals", Some def_id),
           cvar "pair_locals" (fn_ty [ ty_int; ty_int ] ty_pair),
           [ cint 2; cint 3 ] ))
  in
  let pair_var = cvar "pair" ty_pair in
  let caller_body =
    simple_let "pair" call
      (mk ty_int
         (CBin (Add, field pair_var "0" ty_int, field pair_var "1" ty_int)))
  in
  let caller = func ~def_id:51 "caller" [] ty_int caller_body in
  let rewritten =
    Sroa.rewrite_program
      ~reg:(Blorp.Codegen_types.create_registry ())
      [ decl pair; decl caller ]
  in
  match rewritten with
  | [ _; { cd_desc = CDFunc { cf_body = Some body; _ }; _ } ] ->
      Alcotest.(check bool)
        "tuple allocation removed" false
        (contains_tuple_construct body);
      Alcotest.(check bool)
        "tuple-return call removed" false
        (contains_call_to "pair_locals" body);
      Alcotest.(check bool)
        "tuple-root field accesses removed" false
        (contains_field_of "pair" body)
  | _ -> Alcotest.fail "expected rewritten caller function"

let test_managed_tuple_return_call_stays_heap_allocated () =
  let def_id = 52 in
  let managed_body =
    mk ty_string_pair (CTuple [ cvar "s" ty_string; cvar "n" ty_int ])
  in
  let managed_pair =
    func ~def_id "managed_pair"
      [ param "s" ty_string; param "n" ty_int ]
      ty_string_pair managed_body
  in
  let call =
    mk ty_string_pair
      (CCall
         ( CKUser ("managed_pair", Some def_id),
           cvar "managed_pair" (fn_ty [ ty_string; ty_int ] ty_string_pair),
           [ cstring "hello"; cint 3 ] ))
  in
  let pair_var = cvar "pair" ty_string_pair in
  let caller_body = simple_let "pair" call (field pair_var "0" ty_string) in
  let caller = func ~def_id:53 "caller" [] ty_string caller_body in
  let rewritten =
    Sroa.rewrite_program
      ~reg:(Blorp.Codegen_types.create_registry ())
      [ decl managed_pair; decl caller ]
  in
  match rewritten with
  | [ _; { cd_desc = CDFunc { cf_body = Some body; _ }; _ } ] ->
      Alcotest.(check bool)
        "managed tuple-return call remains" true
        (contains_call_to "managed_pair" body);
      Alcotest.(check bool)
        "managed tuple-root field remains" true
        (contains_field_of "pair" body)
  | _ -> Alcotest.fail "expected rewritten caller function"

let test_tuple_return_call_if_tuple_branches_scalar_replaced () =
  let def_id = 54 in
  let flag = cvar "flag" ty_bool in
  let a = cvar "a" ty_int in
  let b = cvar "b" ty_int in
  let choose_body =
    mk ty_pair
      (CIf (flag, mk ty_pair (CTuple [ b; a ]), mk ty_pair (CTuple [ a; b ])))
  in
  let choose =
    func ~def_id "choose_pair"
      [ param "flag" ty_bool; param "a" ty_int; param "b" ty_int ]
      ty_pair choose_body
  in
  let call =
    mk ty_pair
      (CCall
         ( CKUser ("choose_pair", Some def_id),
           cvar "choose_pair" (fn_ty [ ty_bool; ty_int; ty_int ] ty_pair),
           [ cbool true; cint 2; cint 3 ] ))
  in
  let pair_var = cvar "pair" ty_pair in
  let caller_body =
    simple_let "pair" call
      (mk ty_int
         (CBin (Add, field pair_var "0" ty_int, field pair_var "1" ty_int)))
  in
  let caller = func ~def_id:55 "caller" [] ty_int caller_body in
  let rewritten =
    Sroa.rewrite_program
      ~reg:(Blorp.Codegen_types.create_registry ())
      [ decl choose; decl caller ]
  in
  match rewritten with
  | [ _; { cd_desc = CDFunc { cf_body = Some body; _ }; _ } ] ->
      Alcotest.(check bool)
        "tuple allocation removed" false
        (contains_tuple_construct body);
      Alcotest.(check bool)
        "tuple-return call removed" false
        (contains_call_to "choose_pair" body);
      Alcotest.(check bool)
        "tuple-root field accesses removed" false
        (contains_field_of "pair" body)
  | _ -> Alcotest.fail "expected rewritten caller function"

let suite =
  [
    ( "sroa",
      [
        Alcotest.test_case "local_field_access" `Quick
          test_local_field_access_scalar_replaced;
        Alcotest.test_case "escaping_tuple" `Quick
          test_escaping_tuple_is_left_heap_allocated;
        Alcotest.test_case "mutable_tuple" `Quick
          test_mutable_tuple_binding_is_left_heap_allocated;
        Alcotest.test_case "managed_field_binding" `Quick
          test_managed_field_scalar_replaced_as_local_binding;
        Alcotest.test_case "branch_alias_scope" `Quick
          test_branch_local_alias_does_not_leak_to_sibling_branch;
        Alcotest.test_case "resource_scope_shadowed_tuple_alias" `Quick
          test_resource_scope_shadowed_tuple_alias_is_not_rewritten;
        Alcotest.test_case "removed_tuple_binding_guard" `Quick
          test_removed_tuple_binding_guard_rejects_leftover_root_reference;
        Alcotest.test_case "local_if_tuple_binding" `Quick
          test_local_if_tuple_binding_scalar_replaced;
        Alcotest.test_case "managed_local_if_tuple_binding" `Quick
          test_managed_local_if_tuple_binding_scalar_replaced;
        Alcotest.test_case "local_if_tuple_binding_mismatched_arity" `Quick
          test_local_if_tuple_binding_mismatched_arity_stays_heap_allocated;
        Alcotest.test_case "local_if_tuple_binding_mismatched_element_type"
          `Quick
          test_local_if_tuple_binding_mismatched_element_type_stays_heap_allocated;
        Alcotest.test_case "local_match_tuple_binding" `Quick
          test_local_match_tuple_binding_scalar_replaced;
        Alcotest.test_case "local_match_tuple_binding_non_tuple_leaf" `Quick
          test_local_match_tuple_binding_non_tuple_leaf_stays_heap_allocated;
        Alcotest.test_case "local_match_tuple_binding_mismatched_arity" `Quick
          test_local_match_tuple_binding_mismatched_arity_stays_heap_allocated;
        Alcotest.test_case "local_match_tuple_binding_mismatched_element_type"
          `Quick
          test_local_match_tuple_binding_mismatched_element_type_stays_heap_allocated;
        Alcotest.test_case "immediate_tuple_field" `Quick
          test_immediate_tuple_field_access_scalar_replaced;
        Alcotest.test_case "tuple_match_bindings" `Quick
          test_tuple_match_bindings_scalar_replaced;
        Alcotest.test_case "tuple_match_literal_split" `Quick
          test_tuple_match_literal_split_scalar_replaced;
        Alcotest.test_case "immediate_tuple_match" `Quick
          test_immediate_tuple_match_scalar_replaced;
        Alcotest.test_case "tuple_match_nested_constructor" `Quick
          test_tuple_match_with_nested_constructor_stays_heap_allocated;
        Alcotest.test_case "tuple_return_call" `Quick
          test_tuple_return_call_scalar_replaced_when_fields_only;
        Alcotest.test_case "immediate_tuple_return_call_field" `Quick
          test_immediate_tuple_return_call_field_scalar_replaced;
        Alcotest.test_case "immediate_tuple_return_call_match" `Quick
          test_immediate_tuple_return_call_match_scalar_replaced;
        Alcotest.test_case "tuple_return_call_simple_expr_elements" `Quick
          test_tuple_return_call_simple_expr_elements_scalar_replaced;
        Alcotest.test_case "tuple_return_call_local_expr_elements" `Quick
          test_tuple_return_call_local_expr_elements_scalar_replaced;
        Alcotest.test_case "managed_tuple_return_call" `Quick
          test_managed_tuple_return_call_stays_heap_allocated;
        Alcotest.test_case "tuple_return_call_if_tuple_branches" `Quick
          test_tuple_return_call_if_tuple_branches_scalar_replaced;
      ] );
  ]
