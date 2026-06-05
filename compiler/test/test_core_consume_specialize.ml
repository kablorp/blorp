(** Tests for pre-Perceus consuming-call specialization. *)

open Blorp.Ast
open Blorp.Core

let ty_int = TyNamed ("Int", [])
let ty_bool = TyNamed ("Bool", [])
let ty_void = TyNamed ("Void", [])
let ty_expr = TyNamed ("Expr", [])
let mk ty desc = { desc; ty; loc = dummy_loc }
let void () = mk ty_void CVoid
let int n = mk ty_int (CLit (LitInt (Int64.of_int n)))
let bool b = mk ty_bool (CLit (LitBool b))
let var name ty = mk ty (CVar (Var.named name))
let func_ty params return = TyFunc { params; return; is_pure = true }

let callee name def_id params return =
  mk (func_ty params return)
    (CVar { vname = name; vuniq = 0; vdef_id = Some def_id })

let user_call ~def_id name args return =
  mk return
    (CCall (CKUser (name, Some def_id), callee name def_id [] return, args))

let expr_type_decl =
  {
    type_name = "Expr";
    type_params = [];
    type_variants =
      [
        {
          variant_name = "Lit";
          variant_fields = [ ty_int ];
          variant_tag = 0;
          variant_loc = dummy_loc;
          variant_def_id = Some 100;
        };
        {
          variant_name = "Add";
          variant_fields = [ ty_expr; ty_expr ];
          variant_tag = 1;
          variant_loc = dummy_loc;
          variant_def_id = Some 101;
        };
      ];
    type_is_enum = false;
    type_is_builtin = false;
    type_is_resource = false;
    type_resource_cleanup = None;
  }

let expr_type_decl_core =
  { cd_desc = CDType expr_type_decl; cd_loc = dummy_loc; cd_doc = None }

let expr_reg () =
  let reg = Blorp.Codegen_types.create_registry () in
  Blorp.Core_flatten.register_types reg [ expr_type_decl_core ];
  reg

let param name ty = { cp_name = Var.named name; cp_ty = ty; cp_loc = dummy_loc }

let func ?(def_id = 10) name params return body =
  {
    cf_name = name;
    cf_module = None;
    cf_type_params = [];
    cf_params = params;
    cf_return_ty = return;
    cf_body = Some body;
    cf_is_pure = true;
    cf_kind = CFUser;
    cf_def_id = def_id;
  }

let func_decl f = { cd_desc = CDFunc f; cd_loc = dummy_loc; cd_doc = None }
let lit_expr n = user_call ~def_id:100 "Lit" [ int n ] ty_expr
let add_expr left right = user_call ~def_id:101 "Add" [ left; right ] ty_expr

let rewrite_func body =
  func "rewrite_expr" [ param "expr" ty_expr; param "pass" ty_int ] ty_expr body

let recursive_rewrite_body () =
  let left = var "left" ty_expr in
  let right = var "right" ty_expr in
  let recursive_left =
    user_call ~def_id:10 "rewrite_expr" [ left; var "pass" ty_int ] ty_expr
  in
  let recursive_right =
    user_call ~def_id:10 "rewrite_expr" [ right; var "pass" ty_int ] ty_expr
  in
  mk ty_expr
    (CMatch
       ( var "expr" ty_expr,
         CTSwitchTag
           {
             cts_scrut = AccRoot;
             cts_cases =
               [
                 ("Lit", CTLeaf { ct_bindings = []; ct_body = lit_expr 0 });
                 ( "Add",
                   CTLeaf
                     {
                       ct_bindings =
                         borrowed_match_binding_pairs
                           [
                             ( Var.named "left",
                               AccVariantField (AccRoot, "Add", 0) );
                             ( Var.named "right",
                               AccVariantField (AccRoot, "Add", 1) );
                           ];
                       ct_body = add_expr recursive_left recursive_right;
                     } );
               ];
             cts_default = None;
           } ))

let recursive_swap_rewrite_body () =
  let left = var "left" ty_expr in
  let right = var "right" ty_expr in
  let recursive_left =
    user_call ~def_id:10 "rewrite_expr" [ left; var "pass" ty_int ] ty_expr
  in
  let recursive_right =
    user_call ~def_id:10 "rewrite_expr" [ right; var "pass" ty_int ] ty_expr
  in
  let swapped = add_expr recursive_right recursive_left in
  let ordered = add_expr recursive_left recursive_right in
  mk ty_expr
    (CMatch
       ( var "expr" ty_expr,
         CTSwitchTag
           {
             cts_scrut = AccRoot;
             cts_cases =
               [
                 ( "Add",
                   CTLeaf
                     {
                       ct_bindings =
                         borrowed_match_binding_pairs
                           [
                             ( Var.named "left",
                               AccVariantField (AccRoot, "Add", 0) );
                             ( Var.named "right",
                               AccVariantField (AccRoot, "Add", 1) );
                           ];
                       ct_body = mk ty_expr (CIf (bool true, swapped, ordered));
                     } );
               ];
             cts_default =
               Some (CTLeaf { ct_bindings = []; ct_body = lit_expr 0 });
           } ))

let recursive_one_sided_rewrite_body () =
  let left = var "left" ty_expr in
  let recursive_left =
    user_call ~def_id:10 "rewrite_expr" [ left; var "pass" ty_int ] ty_expr
  in
  mk ty_expr
    (CMatch
       ( var "expr" ty_expr,
         CTSwitchTag
           {
             cts_scrut = AccRoot;
             cts_cases =
               [
                 ( "Add",
                   CTLeaf
                     {
                       ct_bindings =
                         borrowed_match_binding_pairs
                           [
                             ( Var.named "left",
                               AccVariantField (AccRoot, "Add", 0) );
                             ( Var.named "right",
                               AccVariantField (AccRoot, "Add", 1) );
                           ];
                       ct_body =
                         mk ty_expr
                           (CIf
                              ( bool true,
                                add_expr recursive_left (lit_expr 1),
                                lit_expr 2 ));
                     } );
               ];
             cts_default =
               Some (CTLeaf { ct_bindings = []; ct_body = lit_expr 0 });
           } ))

let run_func () =
  let assign =
    mk ty_void
      (CAssign
         ( Var.named "expr",
           user_call ~def_id:10 "rewrite_expr"
             [ var "expr" ty_expr; int 1 ]
             ty_expr ))
  in
  let body =
    mk ty_expr
      (CLet
         ( {
             bind_var = Var.named "expr";
             bind_mut = true;
             bind_ty = ty_expr;
             bind_rhs = lit_expr 0;
           },
           mk ty_expr (CSeq (assign, var "expr" ty_expr)) ))
  in
  func ~def_id:20 "run" [] ty_expr body

let program rewrite_body =
  [
    expr_type_decl_core;
    func_decl (rewrite_func rewrite_body);
    func_decl (run_func ());
  ]

let rewrite_program rewrite_body =
  let reg = expr_reg () in
  ( reg,
    Blorp.Core_consume_specialize.rewrite_program ~reg (program rewrite_body) )

let function_names prog =
  let rec collect acc decl =
    match decl.cd_desc with
    | CDFunc f -> f.cf_name :: acc
    | CDPrivate inner -> collect acc inner
    | _ -> acc
  in
  List.rev (List.fold_left collect [] prog)

let find_func name prog =
  let rec find_decl = function
    | [] -> None
    | decl :: rest -> (
        match decl.cd_desc with
        | CDFunc f when String.equal f.cf_name name -> Some f
        | CDPrivate inner -> (
            match find_decl [ inner ] with
            | Some f -> Some f
            | None -> find_decl rest)
        | _ -> find_decl rest)
  in
  find_decl prog

let assignment_call_names prog =
  match find_func "run" prog with
  | Some { cf_body = Some body; _ } ->
      Blorp.Core.fold_tree
        (fun acc expr ->
          match expr.desc with
          | CAssign (_, { desc = CCall (CKUser (name, _), _, _); _ }) ->
              name :: acc
          | _ -> acc)
        [] body
      |> List.rev
  | _ -> []

let clone_body_drops_param clone =
  match clone.cf_body with
  | Some
      {
        desc =
          CLet
            ( _,
              {
                desc =
                  CDrop
                    ( { vname = "expr"; _ },
                      TyNamed ("Expr", []),
                      { desc = CVar { vname = "__consume_result_expr"; _ }; _ }
                    );
                _;
              } );
        _;
      } ->
      true
  | _ -> false

let has_old_drop_reassign target expr =
  let is_old_drop_reassign = function
    | {
        desc =
          CLet
            ( { bind_var = tmp; _ },
              {
                desc =
                  CSeq
                    ( { desc = CDrop (drop_v, _, _); _ },
                      {
                        desc = CAssign (assign_v, { desc = CVar assign_rhs; _ });
                        _;
                      } );
                _;
              } );
        _;
      }
      when String.equal drop_v.vname target
           && String.equal assign_v.vname target
           && String.equal assign_rhs.vname tmp.vname ->
        true
    | _ -> false
  in
  Blorp.Core.exists_tree is_old_drop_reassign expr

let clone_inner_body clone =
  match clone.cf_body with
  | Some { desc = CLet ({ bind_rhs; _ }, _); _ } -> Some bind_rhs
  | _ -> None

let rec owned_binding_names_in_ctree tree =
  match tree with
  | CTLeaf { ct_bindings; _ } ->
      List.filter_map
        (fun binding ->
          match binding.mb_mode with
          | MatchOwn -> Some binding.mb_var.vname
          | MatchBorrow -> None)
        ct_bindings
  | CTFail -> []
  | CTSwitchTag { cts_cases; cts_default; _ } ->
      List.concat_map
        (fun (_, sub) -> owned_binding_names_in_ctree sub)
        cts_cases
      @ Option.value
          (Option.map owned_binding_names_in_ctree cts_default)
          ~default:[]
  | CTSwitchLit { ctl_cases; ctl_default; _ } ->
      List.concat_map
        (fun (_, sub) -> owned_binding_names_in_ctree sub)
        ctl_cases
      @ owned_binding_names_in_ctree ctl_default
  | CTSwitchLen { ctl_len_cases; ctl_len_geq; ctl_len_default; _ } ->
      List.concat_map
        (fun (_, sub) -> owned_binding_names_in_ctree sub)
        ctl_len_cases
      @ Option.value
          (Option.map
             (fun (_, sub) -> owned_binding_names_in_ctree sub)
             ctl_len_geq)
          ~default:[]
      @ Option.value
          (Option.map owned_binding_names_in_ctree ctl_len_default)
          ~default:[]

let owned_binding_names expr =
  match expr.desc with
  | CMatch (_, tree) -> owned_binding_names_in_ctree tree
  | _ -> []

let starts_with ~prefix s =
  let plen = String.length prefix in
  String.length s >= plen && String.sub s 0 plen = prefix

let rewrite_call_names expr =
  Blorp.Core.fold_tree
    (fun acc expr ->
      match expr.desc with
      | CCall (CKUser (name, _), _, _)
        when starts_with ~prefix:"rewrite_expr" name ->
          name :: acc
      | _ -> acc)
    [] expr
  |> List.sort String.compare

let test_rewrites_safe_self_replacement_call () =
  let _, rewritten = rewrite_program (lit_expr 7) in
  Alcotest.(check (list string))
    "functions"
    [ "rewrite_expr"; "rewrite_expr__consume_arg0"; "run" ]
    (function_names rewritten);
  Alcotest.(check (list string))
    "assignment calls clone"
    [ "rewrite_expr__consume_arg0" ]
    (assignment_call_names rewritten);
  match find_func "rewrite_expr__consume_arg0" rewritten with
  | Some clone ->
      Alcotest.(check bool)
        "clone drops consumed param" true
        (clone_body_drops_param clone)
  | None -> Alcotest.fail "expected consuming clone"

let test_consuming_clone_owns_recursive_match_fields () =
  let _, rewritten = rewrite_program (recursive_rewrite_body ()) in
  match find_func "rewrite_expr__consume_arg0" rewritten with
  | Some clone -> (
      match clone_inner_body clone with
      | Some body ->
          Alcotest.(check (list string))
            "owned bindings" [ "left"; "right" ]
            (owned_binding_names body |> List.sort String.compare);
          Alcotest.(check (list string))
            "recursive calls target clone"
            [ "rewrite_expr__consume_arg0"; "rewrite_expr__consume_arg0" ]
            (rewrite_call_names body)
      | None -> Alcotest.fail "expected clone body")
  | None -> Alcotest.fail "expected consuming clone"

let test_consuming_clone_owns_branch_swapped_recursive_fields () =
  let _, rewritten = rewrite_program (recursive_swap_rewrite_body ()) in
  match find_func "rewrite_expr__consume_arg0" rewritten with
  | Some clone -> (
      match clone_inner_body clone with
      | Some body ->
          Alcotest.(check (list string))
            "owned bindings" [ "left"; "right" ]
            (owned_binding_names body |> List.sort String.compare);
          Alcotest.(check (list string))
            "recursive calls target clone"
            [
              "rewrite_expr__consume_arg0";
              "rewrite_expr__consume_arg0";
              "rewrite_expr__consume_arg0";
              "rewrite_expr__consume_arg0";
            ]
            (rewrite_call_names body)
      | None -> Alcotest.fail "expected clone body")
  | None -> Alcotest.fail "expected consuming clone"

let test_consuming_clone_rejects_one_sided_recursive_field_use () =
  let _, rewritten = rewrite_program (recursive_one_sided_rewrite_body ()) in
  match find_func "rewrite_expr__consume_arg0" rewritten with
  | Some clone -> (
      match clone_inner_body clone with
      | Some body ->
          Alcotest.(check (list string))
            "owned bindings" [] (owned_binding_names body);
          Alcotest.(check (list string))
            "recursive call keeps original" [ "rewrite_expr" ]
            (rewrite_call_names body)
      | None -> Alcotest.fail "expected clone body")
  | None -> Alcotest.fail "expected consuming clone"

let test_perceus_uses_consuming_clone_to_skip_old_assignment_drop () =
  let _, rewritten = rewrite_program (lit_expr 7) in
  let perceus = Blorp.Core_perceus.insert_drops_program rewritten in
  match find_func "run" perceus with
  | Some { cf_body = Some body; _ } ->
      Alcotest.(check bool)
        "no old drop/reassign temp" false
        (has_old_drop_reassign "expr" body)
  | _ -> Alcotest.fail "expected run body"

let test_does_not_clone_when_result_is_consumed_param () =
  let _, rewritten = rewrite_program (var "expr" ty_expr) in
  Alcotest.(check (list string))
    "functions" [ "rewrite_expr"; "run" ] (function_names rewritten);
  Alcotest.(check (list string))
    "assignment keeps original" [ "rewrite_expr" ]
    (assignment_call_names rewritten)

let test_does_not_clone_when_result_contains_consumed_param () =
  let _, rewritten =
    rewrite_program (add_expr (var "expr" ty_expr) (lit_expr 1))
  in
  Alcotest.(check (list string))
    "functions" [ "rewrite_expr"; "run" ] (function_names rewritten);
  Alcotest.(check (list string))
    "assignment keeps original" [ "rewrite_expr" ]
    (assignment_call_names rewritten)

let suite =
  [
    ( "rewrite",
      [
        Alcotest.test_case "safe self replacement call" `Quick
          test_rewrites_safe_self_replacement_call;
        Alcotest.test_case "clone owns recursive match fields" `Quick
          test_consuming_clone_owns_recursive_match_fields;
        Alcotest.test_case "clone owns branch-swapped recursive match fields"
          `Quick test_consuming_clone_owns_branch_swapped_recursive_fields;
        Alcotest.test_case "clone rejects one-sided recursive field use" `Quick
          test_consuming_clone_rejects_one_sided_recursive_field_use;
        Alcotest.test_case "result aliases consumed param blocks clone" `Quick
          test_does_not_clone_when_result_is_consumed_param;
        Alcotest.test_case "result contains consumed param blocks clone" `Quick
          test_does_not_clone_when_result_contains_consumed_param;
      ] );
    ( "perceus",
      [
        Alcotest.test_case "consuming clone suppresses old assignment drop"
          `Quick test_perceus_uses_consuming_clone_to_skip_old_assignment_drop;
      ] );
  ]
