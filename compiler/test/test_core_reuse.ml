(** Tests for reuse analysis and the narrow rewrite slices.

    The rewrite tests stay deliberately small: only proven collection allocation
    reuse may change Core, and all other candidates must remain unchanged. *)

open Blorp.Ast
open Blorp.Core

let ty_int = TyNamed ("Int", [])
let ty_int32 = TyNamed ("Int32", [])
let ty_uint64 = TyNamed ("UInt64", [])
let ty_bool = TyNamed ("Bool", [])
let ty_ptr = TyNamed ("Ptr", [])
let ty_string = TyNamed ("String", [])
let ty_void = TyNamed ("Void", [])
let ty_test_resource = TyNamed ("TestResource", [])
let ty_expr = TyNamed ("Expr", [])
let ty_list elem = TyNamed ("List", [ elem ])
let ty_set elem = TyNamed ("Set", [ elem ])
let ty_dict key value = TyNamed ("Dict", [ key; value ])
let mk ty desc = { desc; ty; loc = dummy_loc }
let void () = mk ty_void CVoid
let int n = mk ty_int (CLit (LitInt (Int64.of_int n)))
let bool b = mk ty_bool (CLit (LitBool b))
let var name ty = mk ty (CVar (Var.named name))
let intrinsic name args ty = mk ty (CCall (CKIntrinsic name, void (), args))

let user_call ?def_id name args ty =
  mk ty (CCall (CKUser (name, def_id), void (), args))

let lett name rhs body =
  mk body.ty
    (CLet
       ( {
           bind_var = Var.named name;
           bind_mut = false;
           bind_ty = rhs.ty;
           bind_rhs = rhs;
         },
         body ))

let drop name ty body = mk body.ty (CDrop (Var.named name, ty, body))
let dup name ty body = mk body.ty (CDup (Var.named name, ty, body))
let seq first second = mk second.ty (CSeq (first, second))

let list_alloc ?(len = int 4) () =
  intrinsic "list_alloc" [ len ] (ty_list ty_int)

let typed_list_alloc ?(len = int 4) list_ty =
  mk list_ty
    (CListAlloc
       {
         la_layout = Blorp.Core_list_layout.layout_of_type list_ty dummy_loc;
         la_capacity = len;
       })

let string_alloc ?(len = int 4) () = intrinsic "string_alloc" [ len ] ty_string
let set_alloc ty = mk ty (CSetAlloc { sa_constructor = SetGeneric })

let dict_construct ty =
  mk ty
    (CDictConstruct
       {
         dc_constructor = DictGeneric;
         dc_entries = [];
         dc_value_needs_release = false;
       })

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

let expr_reg () =
  let reg = Blorp.Codegen_types.create_registry () in
  Blorp.Core_flatten.register_types reg
    [ { cd_desc = CDType expr_type_decl; cd_loc = dummy_loc; cd_doc = None } ];
  reg

let boxed_expr_storage value =
  {
    bsv_box =
      { box_value = value; box_source_ty = ty_expr; box_kind = BoxPointer };
    bsv_needs_release = true;
    bsv_transfers_ownership = true;
  }

let prepared_expr_construct ctor_name ctor_def_id tag args =
  mk ty_expr
    (CUnionConstruct
       {
         uc_type_name = "Expr";
         uc_constructor_name = ctor_name;
         uc_c_name = Blorp.Codegen_names.mangle_by_def_id ctor_def_id ctor_name;
         uc_tag = tag;
         uc_representation = GenericUnion;
         uc_args = args;
         uc_release_mask =
           List.mapi
             (fun idx arg -> if arg.bsv_needs_release then 1 lsl idx else 0)
             args
           |> List.fold_left ( lor ) 0;
       })

let prepared_add_construct left right =
  prepared_expr_construct "Add" 101 1
    [ boxed_expr_storage left; boxed_expr_storage right ]

let owned_add_bindings =
  [
    owned_match_binding (Var.named "left") (AccVariantField (AccRoot, "Add", 0));
    owned_match_binding (Var.named "right")
      (AccVariantField (AccRoot, "Add", 1));
  ]

let borrowed_add_bindings =
  borrowed_match_binding_pairs
    [
      (Var.named "left", AccVariantField (AccRoot, "Add", 0));
      (Var.named "right", AccVariantField (AccRoot, "Add", 1));
    ]

let list_handoff ?(mode = BorrowFresh) ?result_ty source =
  let source_ty = source.ty in
  let result_ty = Option.value result_ty ~default:source_ty in
  mk result_ty
    (CListHandoff
       {
         lh_mode = mode;
         lh_layout = Blorp.Core_list_layout.layout_of_type result_ty dummy_loc;
         lh_source = source;
         lh_source_var = Var.named "__hsrc";
         lh_source_ty = source_ty;
         lh_result_ty = result_ty;
         lh_capacity = int 4;
         lh_result_var = Var.named "__hresult";
         lh_len_var = Var.named "__hlen";
         lh_out_var = Var.named "__hout";
         lh_body = void ();
         lh_write_order = ForwardCompacting;
       })

let resource_scope ?(name = "r") body_ty body =
  mk body_ty
    (CResourceScope
       {
         rs_var = Var.named name;
         rs_ty = ty_test_resource;
         rs_acquire = var "open_resource" ty_test_resource;
         rs_body = body;
         rs_cleanup = void ();
       })

let count_list_handoff mode body =
  fold_tree
    (fun acc node ->
      match node.desc with
      | CListHandoff h when h.lh_mode = mode -> acc + 1
      | _ -> acc)
    0 body

let count_intrinsic_calls name body =
  fold_tree
    (fun acc node ->
      match node.desc with
      | CCall (CKIntrinsic got, _, _) when got = name -> acc + 1
      | _ -> acc)
    0 body

let count_drops_of name body =
  fold_tree
    (fun acc node ->
      match node.desc with
      | CDrop (v, _, _) when v.vname = name -> acc + 1
      | _ -> acc)
    0 body

let candidate_names candidates =
  List.map
    (fun (c : Blorp.Core_reuse.reuse_candidate) ->
      let alloc_binding =
        Option.map (fun v -> v.vname) c.allocation_binding
        |> Option.value ~default:"<none>"
      in
      ( c.dropped_var.vname,
        alloc_binding,
        Blorp.Core_reuse.collection_family_to_string c.family ))
    candidates

let block_fact_tags facts =
  List.map
    (function
      | Blorp.Core_reuse.SafeBinding v -> "safe:" ^ v.vname
      | Blorp.Core_reuse.SafeStatement _ -> "stmt"
      | Blorp.Core_reuse.FreshAllocation (Some v, allocation) ->
          "alloc:" ^ v.vname ^ ":"
          ^ Blorp.Core_reuse.collection_family_to_string
              allocation.allocation_family
      | Blorp.Core_reuse.FreshAllocation (None, allocation) ->
          "alloc:<none>:"
          ^ Blorp.Core_reuse.collection_family_to_string
              allocation.allocation_family
      | Blorp.Core_reuse.Interference (reason, _) ->
          "interference:"
          ^ Blorp.Core_reuse.interference_reason_to_string reason)
    facts

let test_reuse_boundary_policy_is_explicit () =
  Alcotest.(check (option string))
    "list boundary" (Some "list_reuse_alloc")
    (Blorp.Core_reuse.reuse_boundary_for_family Blorp.Core_reuse.List);
  Alcotest.(check (option string))
    "dict boundary" (Some "dict_reuse_alloc")
    (Blorp.Core_reuse.reuse_boundary_for_family Blorp.Core_reuse.Dict);
  Alcotest.(check (option string))
    "set boundary" (Some "set_reuse_alloc")
    (Blorp.Core_reuse.reuse_boundary_for_family Blorp.Core_reuse.Set);
  List.iter
    (fun (name, family) ->
      Alcotest.(check (option string))
        name None
        (Blorp.Core_reuse.reuse_boundary_for_family family))
    [
      ("string boundary", Blorp.Core_reuse.String);
      ("bytes boundary", Blorp.Core_reuse.Bytes);
    ]

let test_marks_dead_list_before_fresh_list_alloc () =
  let list_ty = ty_list ty_int in
  let body = drop "xs" list_ty (lett "ys" (list_alloc ()) (var "ys" list_ty)) in
  Alcotest.(check (list (triple string string string)))
    "candidate"
    [ ("xs", "ys", "list") ]
    (candidate_names (Blorp.Core_reuse.analyze_expr body))

let test_marks_dead_string_before_fresh_string_alloc () =
  let body =
    drop "s" ty_string (lett "t" (string_alloc ()) (var "t" ty_string))
  in
  Alcotest.(check (list (triple string string string)))
    "candidate"
    [ ("s", "t", "string") ]
    (candidate_names (Blorp.Core_reuse.analyze_expr body))

let test_marks_dead_set_before_explicit_set_alloc () =
  let set_ty = ty_set ty_int in
  let body =
    drop "xs" set_ty (lett "ys" (set_alloc set_ty) (var "ys" set_ty))
  in
  Alcotest.(check (list (triple string string string)))
    "candidate"
    [ ("xs", "ys", "set") ]
    (candidate_names (Blorp.Core_reuse.analyze_expr body))

let test_marks_dead_dict_before_explicit_dict_construct () =
  let dict_ty = ty_dict ty_int ty_string in
  let body =
    drop "d" dict_ty (lett "next" (dict_construct dict_ty) (var "next" dict_ty))
  in
  Alcotest.(check (list (triple string string string)))
    "candidate"
    [ ("d", "next", "dict") ]
    (candidate_names (Blorp.Core_reuse.analyze_expr body))

let test_marks_dead_managed_union_before_constructor_call () =
  let reg = expr_reg () in
  let next = user_call ~def_id:100 "Lit" [ int 7 ] ty_expr in
  let body = drop "expr" ty_expr (lett "next" next (var "next" ty_expr)) in
  let analysis =
    Blorp.Core_reuse.analyze_drop_block ~reg (Var.named "expr") ty_expr
      (match body.desc with
      | CDrop (_, _, body) -> body
      | _ -> failwith "expected drop")
  in
  Alcotest.(check (list string))
    "block facts"
    [ "alloc:next:managed-union:Expr" ]
    (block_fact_tags analysis.facts);
  Alcotest.(check (list (triple string string string)))
    "candidate"
    [ ("expr", "next", "managed-union:Expr") ]
    (candidate_names (Blorp.Core_reuse.analyze_expr ~reg body));
  match analysis.candidate with
  | Some
      {
        allocation = { allocation_managed_constructor = Some constructor; _ };
        _;
      } ->
      Alcotest.(check string)
        "constructor type" "Expr" constructor.managed_type_name;
      Alcotest.(check string)
        "constructor name" "Lit" constructor.managed_constructor_name;
      Alcotest.(check (option int))
        "constructor def id" (Some 100) constructor.managed_constructor_def_id;
      Alcotest.(check int)
        "constructor tag" 0 constructor.managed_constructor_tag;
      Alcotest.(check int)
        "constructor arity" 1 constructor.managed_constructor_arity
  | _ -> Alcotest.fail "expected managed union constructor allocation fact"

let test_rejects_managed_union_constructor_def_id_mismatch () =
  let reg = expr_reg () in
  let next = user_call ~def_id:999 "Lit" [ int 7 ] ty_expr in
  let body = drop "expr" ty_expr (lett "next" next (var "next" ty_expr)) in
  Alcotest.(check int)
    "candidate count" 0
    (List.length (Blorp.Core_reuse.analyze_expr ~reg body))

let test_marks_later_allocation_after_safe_binding () =
  let list_ty = ty_list ty_int in
  let body =
    drop "xs" list_ty
      (lett "n" (int 4)
         (lett "ys" (list_alloc ~len:(var "n" ty_int) ()) (var "ys" list_ty)))
  in
  let analysis =
    Blorp.Core_reuse.analyze_drop_block (Var.named "xs") list_ty
      (match body.desc with
      | CDrop (_, _, body) -> body
      | _ -> failwith "expected drop")
  in
  Alcotest.(check (list string))
    "block facts"
    [ "safe:n"; "alloc:ys:list" ]
    (block_fact_tags analysis.facts);
  Alcotest.(check (list (triple string string string)))
    "candidate"
    [ ("xs", "ys", "list") ]
    (candidate_names (Blorp.Core_reuse.analyze_expr body))

let test_marks_later_allocation_after_safe_statement () =
  let list_ty = ty_list ty_int in
  let body =
    drop "xs" list_ty
      (seq (void ()) (lett "ys" (list_alloc ()) (var "ys" list_ty)))
  in
  let analysis =
    Blorp.Core_reuse.analyze_drop_block (Var.named "xs") list_ty
      (match body.desc with
      | CDrop (_, _, body) -> body
      | _ -> failwith "expected drop")
  in
  Alcotest.(check (list string))
    "block facts"
    [ "stmt"; "alloc:ys:list" ]
    (block_fact_tags analysis.facts);
  Alcotest.(check (list (triple string string string)))
    "candidate"
    [ ("xs", "ys", "list") ]
    (candidate_names (Blorp.Core_reuse.analyze_expr body))

let test_resource_scope_blocks_later_allocation_candidate () =
  let list_ty = ty_list ty_int in
  let scoped = resource_scope ty_void (void ()) in
  let body =
    drop "xs" list_ty
      (seq scoped (lett "ys" (list_alloc ()) (var "ys" list_ty)))
  in
  let analysis =
    Blorp.Core_reuse.analyze_drop_block (Var.named "xs") list_ty
      (match body.desc with
      | CDrop (_, _, body) -> body
      | _ -> failwith "expected drop")
  in
  Alcotest.(check (list string))
    "block facts"
    [ "interference:nonlinear control flow" ]
    (block_fact_tags analysis.facts);
  Alcotest.(check int)
    "candidate count" 0
    (List.length (Blorp.Core_reuse.analyze_expr body))

let test_rejects_collection_family_mismatch () =
  let list_ty = ty_list ty_int in
  let body =
    drop "s" ty_string (lett "ys" (list_alloc ()) (var "ys" list_ty))
  in
  Alcotest.(check int)
    "candidate count" 0
    (List.length (Blorp.Core_reuse.analyze_expr body))

let test_rejects_incompatible_allocation_before_candidate () =
  let list_ty = ty_list ty_int in
  let body =
    drop "xs" list_ty
      (lett "s" (string_alloc ())
         (lett "ys" (list_alloc ()) (var "ys" list_ty)))
  in
  let analysis =
    Blorp.Core_reuse.analyze_drop_block (Var.named "xs") list_ty
      (match body.desc with
      | CDrop (_, _, body) -> body
      | _ -> failwith "expected drop")
  in
  Alcotest.(check (list string))
    "block facts"
    [ "interference:incompatible allocation" ]
    (block_fact_tags analysis.facts);
  Alcotest.(check int)
    "candidate count" 0
    (List.length (Blorp.Core_reuse.analyze_expr body))

let test_rejects_sequence_allocation_without_binding () =
  let list_ty = ty_list ty_int in
  let body = drop "xs" list_ty (seq (list_alloc ()) (void ())) in
  let analysis =
    Blorp.Core_reuse.analyze_drop_block (Var.named "xs") list_ty
      (match body.desc with
      | CDrop (_, _, body) -> body
      | _ -> failwith "expected drop")
  in
  Alcotest.(check (list string))
    "block facts"
    [ "interference:incompatible allocation" ]
    (block_fact_tags analysis.facts);
  Alcotest.(check int)
    "candidate count" 0
    (List.length (Blorp.Core_reuse.analyze_expr body))

let test_rejects_post_drop_body_that_reads_dropped_owner () =
  let list_ty = ty_list ty_int in
  let xs = var "xs" list_ty in
  let len = intrinsic "list_len" [ xs ] ty_int in
  let body =
    drop "xs" list_ty (lett "ys" (list_alloc ~len ()) (var "ys" list_ty))
  in
  Alcotest.(check int)
    "candidate count" 0
    (List.length (Blorp.Core_reuse.analyze_expr body))

let test_rejects_later_read_of_dropped_owner () =
  let list_ty = ty_list ty_int in
  let body = drop "xs" list_ty (lett "ys" (list_alloc ()) (var "xs" list_ty)) in
  Alcotest.(check int)
    "candidate count" 0
    (List.length (Blorp.Core_reuse.analyze_expr body))

let test_rejects_later_rc_op_on_dropped_owner () =
  let list_ty = ty_list ty_int in
  let body =
    drop "xs" list_ty
      (lett "ys" (list_alloc ()) (drop "xs" list_ty (var "ys" list_ty)))
  in
  let dup_body =
    drop "xs" list_ty
      (lett "ys" (list_alloc ()) (dup "xs" list_ty (var "ys" list_ty)))
  in
  Alcotest.(check int)
    "drop candidate count" 0
    (List.length (Blorp.Core_reuse.analyze_expr body));
  Alcotest.(check int)
    "dup candidate count" 0
    (List.length (Blorp.Core_reuse.analyze_expr dup_body))

let test_rewrite_program_keeps_non_list_candidate () =
  let body =
    drop "s" ty_string (lett "ys" (list_alloc ()) (var "ys" (ty_list ty_int)))
  in
  let fn =
    {
      cf_name = "main";
      cf_module = None;
      cf_type_params = [];
      cf_params = [];
      cf_return_ty = ty_list ty_int;
      cf_body = Some body;
      cf_is_pure = true;
      cf_kind = CFUser;
      cf_def_id = 1;
    }
  in
  let prog = [ { cd_desc = CDFunc fn; cd_loc = dummy_loc; cd_doc = None } ] in
  Alcotest.(check bool)
    "program unchanged" true
    (Blorp.Core_reuse.rewrite_program prog = prog)

let test_rewrite_program_keeps_same_family_without_reuse_boundary () =
  let body =
    drop "s" ty_string (lett "t" (string_alloc ()) (var "t" ty_string))
  in
  let fn =
    {
      cf_name = "main";
      cf_module = None;
      cf_type_params = [];
      cf_params = [];
      cf_return_ty = ty_string;
      cf_body = Some body;
      cf_is_pure = true;
      cf_kind = CFUser;
      cf_def_id = 1;
    }
  in
  let prog = [ { cd_desc = CDFunc fn; cd_loc = dummy_loc; cd_doc = None } ] in
  Alcotest.(check bool)
    "program unchanged" true
    (Blorp.Core_reuse.rewrite_program prog = prog)

let test_rewrite_program_keeps_managed_union_candidate_without_reuse_boundary ()
    =
  let reg = expr_reg () in
  let body =
    drop "expr" ty_expr
      (lett "next"
         (user_call ~def_id:100 "Lit" [ int 7 ] ty_expr)
         (var "next" ty_expr))
  in
  let fn =
    {
      cf_name = "main";
      cf_module = None;
      cf_type_params = [];
      cf_params = [];
      cf_return_ty = ty_expr;
      cf_body = Some body;
      cf_is_pure = true;
      cf_kind = CFUser;
      cf_def_id = 1;
    }
  in
  let prog =
    [
      { cd_desc = CDType expr_type_decl; cd_loc = dummy_loc; cd_doc = None };
      { cd_desc = CDFunc fn; cd_loc = dummy_loc; cd_doc = None };
    ]
  in
  Alcotest.(check bool)
    "program unchanged" true
    (Blorp.Core_reuse.rewrite_program ~reg prog = prog)

let test_rewrite_program_reuses_dead_list_allocation () =
  let list_ty = ty_list ty_int in
  let body = drop "xs" list_ty (lett "ys" (list_alloc ()) (var "ys" list_ty)) in
  let fn =
    {
      cf_name = "main";
      cf_module = None;
      cf_type_params = [];
      cf_params = [];
      cf_return_ty = list_ty;
      cf_body = Some body;
      cf_is_pure = true;
      cf_kind = CFUser;
      cf_def_id = 1;
    }
  in
  let prog = [ { cd_desc = CDFunc fn; cd_loc = dummy_loc; cd_doc = None } ] in
  let rewritten = Blorp.Core_reuse.rewrite_program prog in
  let rewritten_body =
    match rewritten with
    | [ { cd_desc = CDFunc { cf_body = Some body; _ }; _ } ] -> body
    | _ -> failwith "expected rewritten function body"
  in
  match rewritten_body.desc with
  | CLet ({ bind_var; bind_rhs; _ }, result) when bind_var.vname = "ys" -> (
      match bind_rhs.desc with
      | CCall (CKIntrinsic "list_reuse_alloc", _, [ owner; cap ]) ->
          Alcotest.(check string)
            "owner" "xs"
            (match owner.desc with CVar v -> v.vname | _ -> "<not-var>");
          Alcotest.(check int)
            "capacity" 4
            (match cap.desc with CLit (LitInt n) -> Int64.to_int n | _ -> -1);
          Alcotest.(check string)
            "result" "ys"
            (match result.desc with CVar v -> v.vname | _ -> "<not-var>")
      | _ -> Alcotest.fail "expected list_reuse_alloc")
  | _ -> Alcotest.fail "expected drop to be removed around rewritten allocation"

let test_rewrite_program_reuses_dead_set_allocation () =
  let set_ty = ty_set ty_int in
  let body =
    drop "xs" set_ty (lett "ys" (set_alloc set_ty) (var "ys" set_ty))
  in
  let fn =
    {
      cf_name = "main";
      cf_module = None;
      cf_type_params = [];
      cf_params = [];
      cf_return_ty = set_ty;
      cf_body = Some body;
      cf_is_pure = true;
      cf_kind = CFUser;
      cf_def_id = 1;
    }
  in
  let prog = [ { cd_desc = CDFunc fn; cd_loc = dummy_loc; cd_doc = None } ] in
  let rewritten = Blorp.Core_reuse.rewrite_program prog in
  let rewritten_body =
    match rewritten with
    | [ { cd_desc = CDFunc { cf_body = Some body; _ }; _ } ] -> body
    | _ -> failwith "expected rewritten function body"
  in
  match rewritten_body.desc with
  | CLet ({ bind_var; bind_rhs; _ }, result) when bind_var.vname = "ys" -> (
      match bind_rhs.desc with
      | CCall (CKIntrinsic "set_reuse_alloc", _, [ owner; cap ]) ->
          Alcotest.(check string)
            "owner" "xs"
            (match owner.desc with CVar v -> v.vname | _ -> "<not-var>");
          Alcotest.(check int)
            "capacity" 0
            (match cap.desc with CLit (LitInt n) -> Int64.to_int n | _ -> -1);
          Alcotest.(check string)
            "result" "ys"
            (match result.desc with CVar v -> v.vname | _ -> "<not-var>")
      | _ -> Alcotest.fail "expected set_reuse_alloc")
  | _ -> Alcotest.fail "expected drop to be removed around rewritten allocation"

let test_rewrite_program_reuses_dead_dict_allocation () =
  let dict_ty = ty_dict ty_int ty_string in
  let body =
    drop "d" dict_ty (lett "next" (dict_construct dict_ty) (var "next" dict_ty))
  in
  let fn =
    {
      cf_name = "main";
      cf_module = None;
      cf_type_params = [];
      cf_params = [];
      cf_return_ty = dict_ty;
      cf_body = Some body;
      cf_is_pure = true;
      cf_kind = CFUser;
      cf_def_id = 1;
    }
  in
  let prog = [ { cd_desc = CDFunc fn; cd_loc = dummy_loc; cd_doc = None } ] in
  let rewritten = Blorp.Core_reuse.rewrite_program prog in
  let rewritten_body =
    match rewritten with
    | [ { cd_desc = CDFunc { cf_body = Some body; _ }; _ } ] -> body
    | _ -> failwith "expected rewritten function body"
  in
  match rewritten_body.desc with
  | CLet ({ bind_var; bind_rhs; _ }, result) when bind_var.vname = "next" -> (
      match bind_rhs.desc with
      | CCall (CKIntrinsic "dict_reuse_alloc", _, [ owner; cap ]) ->
          Alcotest.(check string)
            "owner" "d"
            (match owner.desc with CVar v -> v.vname | _ -> "<not-var>");
          Alcotest.(check int)
            "capacity" 0
            (match cap.desc with CLit (LitInt n) -> Int64.to_int n | _ -> -1);
          Alcotest.(check string)
            "result" "next"
            (match result.desc with CVar v -> v.vname | _ -> "<not-var>")
      | _ -> Alcotest.fail "expected dict_reuse_alloc")
  | _ -> Alcotest.fail "expected drop to be removed around rewritten allocation"

let test_rewrite_program_reuses_after_safe_statement () =
  let list_ty = ty_list ty_int in
  let body =
    drop "xs" list_ty
      (seq (void ()) (lett "ys" (list_alloc ()) (var "ys" list_ty)))
  in
  let fn =
    {
      cf_name = "main";
      cf_module = None;
      cf_type_params = [];
      cf_params = [];
      cf_return_ty = list_ty;
      cf_body = Some body;
      cf_is_pure = true;
      cf_kind = CFUser;
      cf_def_id = 1;
    }
  in
  let prog = [ { cd_desc = CDFunc fn; cd_loc = dummy_loc; cd_doc = None } ] in
  let rewritten = Blorp.Core_reuse.rewrite_program prog in
  let rewritten_body =
    match rewritten with
    | [ { cd_desc = CDFunc { cf_body = Some body; _ }; _ } ] -> body
    | _ -> failwith "expected rewritten function body"
  in
  match rewritten_body.desc with
  | CSeq
      ( { desc = CVoid; _ },
        {
          desc =
            CLet
              ( {
                  bind_rhs =
                    { desc = CCall (CKIntrinsic "list_reuse_alloc", _, _); _ };
                  _;
                },
                _ );
          _;
        } ) ->
      ()
  | _ ->
      Alcotest.fail
        "expected safe statement followed by rewritten list_reuse_alloc"

let test_rewrite_program_does_not_reuse_across_resource_scope () =
  let list_ty = ty_list ty_int in
  let scoped = resource_scope ty_void (void ()) in
  let body =
    drop "xs" list_ty
      (seq scoped (lett "ys" (list_alloc ()) (var "ys" list_ty)))
  in
  let fn =
    {
      cf_name = "main";
      cf_module = None;
      cf_type_params = [];
      cf_params = [];
      cf_return_ty = list_ty;
      cf_body = Some body;
      cf_is_pure = true;
      cf_kind = CFUser;
      cf_def_id = 1;
    }
  in
  let prog = [ { cd_desc = CDFunc fn; cd_loc = dummy_loc; cd_doc = None } ] in
  Alcotest.(check bool)
    "program unchanged" true
    (Blorp.Core_reuse.rewrite_program prog = prog)

let test_rewrite_program_reuses_same_layout_list_allocation () =
  let source_ty = ty_list ty_int in
  let result_ty = ty_list ty_uint64 in
  let body =
    drop "xs" source_ty
      (lett "ys" (typed_list_alloc result_ty) (var "ys" result_ty))
  in
  let fn =
    {
      cf_name = "reuse_same_layout_list";
      cf_module = None;
      cf_type_params = [];
      cf_params = [];
      cf_return_ty = result_ty;
      cf_body = Some body;
      cf_is_pure = true;
      cf_kind = CFUser;
      cf_def_id = 1;
    }
  in
  let prog = [ { cd_desc = CDFunc fn; cd_loc = dummy_loc; cd_doc = None } ] in
  let rewritten = Blorp.Core_reuse.rewrite_program prog in
  let rewritten_body =
    match rewritten with
    | [ { cd_desc = CDFunc { cf_body = Some body; _ }; _ } ] -> body
    | _ -> failwith "expected rewritten function body"
  in
  match rewritten_body.desc with
  | CLet
      ( {
          bind_rhs = { desc = CCall (CKIntrinsic "list_reuse_alloc", _, _); _ };
          _;
        },
        _ ) ->
      ()
  | _ ->
      Alcotest.fail
        "expected same-layout List[Int] -> List[UInt64] allocation reuse"

let test_rewrite_program_rejects_different_layout_list_allocation () =
  let source_ty = ty_list ty_int in
  let result_ty = ty_list ty_int32 in
  let body =
    drop "xs" source_ty
      (lett "ys" (typed_list_alloc result_ty) (var "ys" result_ty))
  in
  let fn =
    {
      cf_name = "reject_different_layout_list";
      cf_module = None;
      cf_type_params = [];
      cf_params = [];
      cf_return_ty = result_ty;
      cf_body = Some body;
      cf_is_pure = true;
      cf_kind = CFUser;
      cf_def_id = 1;
    }
  in
  let prog = [ { cd_desc = CDFunc fn; cd_loc = dummy_loc; cd_doc = None } ] in
  Alcotest.(check bool)
    "program unchanged" true
    (Blorp.Core_reuse.rewrite_program prog = prog)

let test_rewrite_program_rejects_release_mismatch_list_allocation () =
  let source_ty = ty_list ty_string in
  let result_ty = ty_list ty_ptr in
  let body =
    drop "xs" source_ty
      (lett "ys" (typed_list_alloc result_ty) (var "ys" result_ty))
  in
  let fn =
    {
      cf_name = "reject_release_mismatch_list";
      cf_module = None;
      cf_type_params = [];
      cf_params = [];
      cf_return_ty = result_ty;
      cf_body = Some body;
      cf_is_pure = true;
      cf_kind = CFUser;
      cf_def_id = 1;
    }
  in
  let prog = [ { cd_desc = CDFunc fn; cd_loc = dummy_loc; cd_doc = None } ] in
  Alcotest.(check bool)
    "program unchanged" true
    (Blorp.Core_reuse.rewrite_program prog = prog)

let test_rewrite_program_upgrades_post_handoff_drop () =
  let list_ty = ty_list ty_int in
  let tmp = Var.named "__cdrop_xs" in
  let handoff = list_handoff (var "xs" list_ty) in
  let body =
    lett "__cdrop_xs" handoff (drop "xs" list_ty (mk list_ty (CVar tmp)))
  in
  let fn =
    {
      cf_name = "reuse_handoff";
      cf_module = None;
      cf_type_params = [];
      cf_params =
        [ { cp_name = Var.named "xs"; cp_ty = list_ty; cp_loc = dummy_loc } ];
      cf_return_ty = list_ty;
      cf_body = Some body;
      cf_is_pure = true;
      cf_kind = CFUser;
      cf_def_id = 1;
    }
  in
  let prog = [ { cd_desc = CDFunc fn; cd_loc = dummy_loc; cd_doc = None } ] in
  let rewritten = Blorp.Core_reuse.rewrite_program prog in
  let rewritten_body =
    match rewritten with
    | [ { cd_desc = CDFunc { cf_body = Some body; _ }; _ } ] -> body
    | _ -> failwith "expected rewritten function body"
  in
  match rewritten_body.desc with
  | CListHandoff { lh_mode = ConsumeReuse; lh_source = { desc = CVar v; _ }; _ }
    ->
      Alcotest.(check string) "source" "xs" v.vname
  | _ -> Alcotest.fail "expected post-handoff drop to become consuming handoff"

let test_rewrite_program_upgrades_handoff_inside_post_drop_rhs () =
  let list_ty = ty_list ty_int in
  let outer_tmp = Var.named "__cdrop_xs" in
  let inner_tmp = Var.named "__cdrop_ys" in
  let handoff = list_handoff (var "xs" list_ty) in
  let body =
    lett "__cdrop_xs"
      (lett "ys" handoff
         (lett "__cdrop_ys"
            (intrinsic "list_len" [ var "ys" list_ty ] ty_int)
            (drop "ys" list_ty (mk ty_int (CVar inner_tmp)))))
      (drop "xs" list_ty (mk ty_int (CVar outer_tmp)))
  in
  let fn =
    {
      cf_name = "reuse_handoff_nested";
      cf_module = None;
      cf_type_params = [];
      cf_params =
        [ { cp_name = Var.named "xs"; cp_ty = list_ty; cp_loc = dummy_loc } ];
      cf_return_ty = ty_int;
      cf_body = Some body;
      cf_is_pure = true;
      cf_kind = CFUser;
      cf_def_id = 1;
    }
  in
  let prog = [ { cd_desc = CDFunc fn; cd_loc = dummy_loc; cd_doc = None } ] in
  let rewritten = Blorp.Core_reuse.rewrite_program prog in
  let rewritten_body =
    match rewritten with
    | [ { cd_desc = CDFunc { cf_body = Some body; _ }; _ } ] -> body
    | _ -> failwith "expected rewritten function body"
  in
  match rewritten_body.desc with
  | CLet
      ( {
          bind_var = ys;
          bind_rhs = { desc = CListHandoff { lh_mode = ConsumeReuse; _ }; _ };
          _;
        },
        _ ) ->
      Alcotest.(check string) "handoff binding" "ys" ys.vname
  | _ ->
      Alcotest.fail
        "expected nested post-handoff drop to become consuming handoff"

let test_rewrite_program_upgrades_last_handoff_before_post_drop () =
  let list_ty = ty_list ty_int in
  let outer_tmp = Var.named "__cdrop_xs" in
  let body =
    lett "__cdrop_xs"
      (lett "first"
         (list_handoff (var "xs" list_ty))
         (lett "second"
            (list_handoff (var "xs" list_ty))
            (drop "first" list_ty (var "second" list_ty))))
      (drop "xs" list_ty (mk list_ty (CVar outer_tmp)))
  in
  let fn =
    {
      cf_name = "reuse_last_handoff";
      cf_module = None;
      cf_type_params = [];
      cf_params =
        [ { cp_name = Var.named "xs"; cp_ty = list_ty; cp_loc = dummy_loc } ];
      cf_return_ty = list_ty;
      cf_body = Some body;
      cf_is_pure = true;
      cf_kind = CFUser;
      cf_def_id = 1;
    }
  in
  let prog = [ { cd_desc = CDFunc fn; cd_loc = dummy_loc; cd_doc = None } ] in
  let rewritten = Blorp.Core_reuse.rewrite_program prog in
  let rewritten_body =
    match rewritten with
    | [ { cd_desc = CDFunc { cf_body = Some body; _ }; _ } ] -> body
    | _ -> failwith "expected rewritten function body"
  in
  Alcotest.(check int)
    "earlier source use remains borrowed" 1
    (count_list_handoff BorrowFresh rewritten_body);
  Alcotest.(check int)
    "last source use consumes reusable owner" 1
    (count_list_handoff ConsumeReuse rewritten_body)

let test_rewrite_program_upgrades_nested_later_handoff_before_post_drop () =
  let list_ty = ty_list ty_int in
  let outer_tmp = Var.named "__cdrop_xs" in
  let body =
    lett "__cdrop_xs"
      (lett "first"
         (list_handoff (var "xs" list_ty))
         (lett "nested"
            (lett "second"
               (list_handoff (var "xs" list_ty))
               (var "second" list_ty))
            (drop "first" list_ty (var "nested" list_ty))))
      (drop "xs" list_ty (mk list_ty (CVar outer_tmp)))
  in
  let fn =
    {
      cf_name = "reuse_nested_later_handoff";
      cf_module = None;
      cf_type_params = [];
      cf_params =
        [ { cp_name = Var.named "xs"; cp_ty = list_ty; cp_loc = dummy_loc } ];
      cf_return_ty = list_ty;
      cf_body = Some body;
      cf_is_pure = true;
      cf_kind = CFUser;
      cf_def_id = 1;
    }
  in
  let prog = [ { cd_desc = CDFunc fn; cd_loc = dummy_loc; cd_doc = None } ] in
  let rewritten = Blorp.Core_reuse.rewrite_program prog in
  let rewritten_body =
    match rewritten with
    | [ { cd_desc = CDFunc { cf_body = Some body; _ }; _ } ] -> body
    | _ -> failwith "expected rewritten function body"
  in
  Alcotest.(check int)
    "earlier source use remains borrowed" 1
    (count_list_handoff BorrowFresh rewritten_body);
  Alcotest.(check int)
    "nested last source use consumes reusable owner" 1
    (count_list_handoff ConsumeReuse rewritten_body)

let test_rewrite_program_upgrades_same_layout_handoff_drop () =
  let source_ty = ty_list ty_int in
  let result_ty = ty_list ty_uint64 in
  let tmp = Var.named "__cdrop_xs" in
  let handoff = list_handoff ~result_ty (var "xs" source_ty) in
  let body =
    lett "__cdrop_xs" handoff (drop "xs" source_ty (mk result_ty (CVar tmp)))
  in
  let fn =
    {
      cf_name = "reuse_same_layout_handoff";
      cf_module = None;
      cf_type_params = [];
      cf_params =
        [ { cp_name = Var.named "xs"; cp_ty = source_ty; cp_loc = dummy_loc } ];
      cf_return_ty = result_ty;
      cf_body = Some body;
      cf_is_pure = true;
      cf_kind = CFUser;
      cf_def_id = 1;
    }
  in
  let prog = [ { cd_desc = CDFunc fn; cd_loc = dummy_loc; cd_doc = None } ] in
  let rewritten = Blorp.Core_reuse.rewrite_program prog in
  let rewritten_body =
    match rewritten with
    | [ { cd_desc = CDFunc { cf_body = Some body; _ }; _ } ] -> body
    | _ -> failwith "expected rewritten function body"
  in
  match rewritten_body.desc with
  | CListHandoff { lh_mode = ConsumeReuse; lh_source_ty; lh_result_ty; _ } ->
      Alcotest.(check bool)
        "source type preserved" true (lh_source_ty = source_ty);
      Alcotest.(check bool)
        "result type preserved" true (lh_result_ty = result_ty)
  | _ ->
      Alcotest.fail "expected same-layout handoff to become consuming handoff"

let prepared_union_match_with_body ct_bindings ct_body =
  let match_expr =
    mk ty_expr
      (CMatch
         ( var "expr" ty_expr,
           CTSwitchTag
             {
               cts_scrut = AccRoot;
               cts_cases = [ ("Add", CTLeaf { ct_bindings; ct_body }) ];
               cts_default = None;
             } ))
  in
  lett "__result" match_expr (drop "expr" ty_expr (var "__result" ty_expr))

let prepared_union_match_with_bindings ct_bindings =
  prepared_union_match_with_body ct_bindings
    (prepared_add_construct (var "left" ty_expr) (var "right" ty_expr))

let rewrite_prepared_expr_body ?body ct_bindings =
  let reg = expr_reg () in
  let body =
    match body with
    | Some body -> prepared_union_match_with_body ct_bindings body
    | None -> prepared_union_match_with_bindings ct_bindings
  in
  let fn =
    {
      cf_name = "rewrite_prepared";
      cf_module = None;
      cf_type_params = [];
      cf_params =
        [ { cp_name = Var.named "expr"; cp_ty = ty_expr; cp_loc = dummy_loc } ];
      cf_return_ty = ty_expr;
      cf_body = Some body;
      cf_is_pure = true;
      cf_kind = CFUser;
      cf_def_id = 1;
    }
  in
  let prog =
    [
      { cd_desc = CDType expr_type_decl; cd_loc = dummy_loc; cd_doc = None };
      { cd_desc = CDFunc fn; cd_loc = dummy_loc; cd_doc = None };
    ]
  in
  match Blorp.Core_reuse.rewrite_prepared_program ~reg prog with
  | [ _; { cd_desc = CDFunc { cf_body = Some body; _ }; _ } ] -> body
  | _ -> failwith "expected rewritten prepared function body"

let count_union_reuse_constructs body =
  fold_tree
    (fun acc node ->
      match node.desc with CUnionReuseConstruct _ -> acc + 1 | _ -> acc)
    0 body

let test_rewrite_prepared_program_reuses_owned_union_match_result () =
  let body = rewrite_prepared_expr_body owned_add_bindings in
  Alcotest.(check int)
    "reuse constructor count" 1
    (count_union_reuse_constructs body);
  match body.desc with
  | CMatch
      ( { desc = CVar { vname = "expr"; _ }; _ },
        CTSwitchTag
          {
            cts_cases =
              [
                ( "Add",
                  CTLeaf
                    {
                      ct_body =
                        {
                          desc =
                            CUnionReuseConstruct
                              {
                                urc_source = { desc = CVar source; _ };
                                urc_constructor_name = "Add";
                                urc_release_mask = 3;
                                _;
                              };
                          _;
                        };
                      _;
                    } );
              ];
            _;
          } ) ->
      Alcotest.(check string) "source" "expr" source.vname
  | _ -> Alcotest.fail "expected match leaf to use CUnionReuseConstruct"

let test_rewrite_prepared_program_rejects_borrowed_union_match_fields () =
  let body = rewrite_prepared_expr_body borrowed_add_bindings in
  Alcotest.(check int)
    "reuse constructor count" 0
    (count_union_reuse_constructs body);
  match body.desc with
  | CLet (_, { desc = CDrop ({ vname = "expr"; _ }, _, _); _ }) -> ()
  | _ -> Alcotest.fail "expected borrowed match fields to keep original drop"

let test_rewrite_prepared_program_reuses_all_if_branches () =
  let branch_body =
    mk ty_expr
      (CIf
         ( bool true,
           prepared_add_construct (var "left" ty_expr) (var "right" ty_expr),
           prepared_add_construct (var "right" ty_expr) (var "left" ty_expr) ))
  in
  let body = rewrite_prepared_expr_body ~body:branch_body owned_add_bindings in
  Alcotest.(check int)
    "reuse constructor count" 2
    (count_union_reuse_constructs body);
  match body.desc with
  | CMatch _ -> ()
  | _ -> Alcotest.fail "expected fully reusable if to replace outer drop"

let test_rewrite_prepared_program_rejects_partial_if_branch () =
  let branch_body =
    mk ty_expr
      (CIf
         ( bool true,
           prepared_add_construct (var "left" ty_expr) (var "right" ty_expr),
           var "left" ty_expr ))
  in
  let body = rewrite_prepared_expr_body ~body:branch_body owned_add_bindings in
  Alcotest.(check int)
    "reuse constructor count" 0
    (count_union_reuse_constructs body);
  match body.desc with
  | CLet (_, { desc = CDrop ({ vname = "expr"; _ }, _, _); _ }) -> ()
  | _ -> Alcotest.fail "expected partial if to keep original drop"

let test_rewrite_prepared_program_rejects_source_alias_payload () =
  let alias_body =
    lett "same" (var "expr" ty_expr)
      (prepared_add_construct (var "same" ty_expr) (var "right" ty_expr))
  in
  let body = rewrite_prepared_expr_body ~body:alias_body owned_add_bindings in
  Alcotest.(check int)
    "reuse constructor count" 0
    (count_union_reuse_constructs body);
  match body.desc with
  | CLet (_, { desc = CDrop ({ vname = "expr"; _ }, _, _); _ }) -> ()
  | _ -> Alcotest.fail "expected source alias payload to keep original drop"

let test_rewrite_inserts_reuse_boundary_without_extra_drop () =
  let list_ty = ty_list ty_int in
  let body = drop "xs" list_ty (lett "ys" (list_alloc ()) (var "ys" list_ty)) in
  let fn =
    {
      cf_name = "reuse_list";
      cf_module = None;
      cf_type_params = [];
      cf_params =
        [ { cp_name = Var.named "xs"; cp_ty = list_ty; cp_loc = dummy_loc } ];
      cf_return_ty = list_ty;
      cf_body = Some body;
      cf_is_pure = true;
      cf_kind = CFUser;
      cf_def_id = 1;
    }
  in
  let prog = [ { cd_desc = CDFunc fn; cd_loc = dummy_loc; cd_doc = None } ] in
  let rewritten = Blorp.Core_reuse.rewrite_program prog in
  let rewritten_body =
    match rewritten with
    | [ { cd_desc = CDFunc { cf_body = Some body; _ }; _ } ] -> body
    | _ -> Alcotest.fail "expected rewritten function body"
  in
  Alcotest.(check int)
    "inserts reuse boundary" 1
    (count_intrinsic_calls "list_reuse_alloc" rewritten_body);
  Alcotest.(check int)
    "does not emit separate drop for consumed owner" 0
    (count_drops_of "xs" rewritten_body)

let suite =
  [
    ( "analysis",
      [
        Alcotest.test_case "reuse_boundary_policy_is_explicit" `Quick
          test_reuse_boundary_policy_is_explicit;
        Alcotest.test_case "dead_list_before_fresh_list_alloc" `Quick
          test_marks_dead_list_before_fresh_list_alloc;
        Alcotest.test_case "dead_string_before_fresh_string_alloc" `Quick
          test_marks_dead_string_before_fresh_string_alloc;
        Alcotest.test_case "dead_set_before_explicit_set_alloc" `Quick
          test_marks_dead_set_before_explicit_set_alloc;
        Alcotest.test_case "dead_dict_before_explicit_dict_construct" `Quick
          test_marks_dead_dict_before_explicit_dict_construct;
        Alcotest.test_case "dead_managed_union_before_constructor_call" `Quick
          test_marks_dead_managed_union_before_constructor_call;
        Alcotest.test_case "rejects_managed_union_constructor_def_id_mismatch"
          `Quick test_rejects_managed_union_constructor_def_id_mismatch;
        Alcotest.test_case "later_allocation_after_safe_binding" `Quick
          test_marks_later_allocation_after_safe_binding;
        Alcotest.test_case "later_allocation_after_safe_statement" `Quick
          test_marks_later_allocation_after_safe_statement;
        Alcotest.test_case "resource_scope_blocks_later_allocation_candidate"
          `Quick test_resource_scope_blocks_later_allocation_candidate;
        Alcotest.test_case "rejects_collection_family_mismatch" `Quick
          test_rejects_collection_family_mismatch;
        Alcotest.test_case "rejects_incompatible_allocation_before_candidate"
          `Quick test_rejects_incompatible_allocation_before_candidate;
        Alcotest.test_case "rejects_sequence_allocation_without_binding" `Quick
          test_rejects_sequence_allocation_without_binding;
        Alcotest.test_case "rejects_allocator_reads_dropped_owner" `Quick
          test_rejects_post_drop_body_that_reads_dropped_owner;
        Alcotest.test_case "rejects_later_read_of_dropped_owner" `Quick
          test_rejects_later_read_of_dropped_owner;
        Alcotest.test_case "rejects_later_rc_op_on_dropped_owner" `Quick
          test_rejects_later_rc_op_on_dropped_owner;
        Alcotest.test_case "rewrite_program_keeps_non_list_candidate" `Quick
          test_rewrite_program_keeps_non_list_candidate;
        Alcotest.test_case
          "rewrite_program_keeps_same_family_without_reuse_boundary" `Quick
          test_rewrite_program_keeps_same_family_without_reuse_boundary;
        Alcotest.test_case
          "rewrite_program_keeps_managed_union_candidate_without_reuse_boundary"
          `Quick
          test_rewrite_program_keeps_managed_union_candidate_without_reuse_boundary;
        Alcotest.test_case "rewrite_program_reuses_dead_list_allocation" `Quick
          test_rewrite_program_reuses_dead_list_allocation;
        Alcotest.test_case "rewrite_program_reuses_dead_set_allocation" `Quick
          test_rewrite_program_reuses_dead_set_allocation;
        Alcotest.test_case "rewrite_program_reuses_dead_dict_allocation" `Quick
          test_rewrite_program_reuses_dead_dict_allocation;
        Alcotest.test_case "rewrite_program_reuses_after_safe_statement" `Quick
          test_rewrite_program_reuses_after_safe_statement;
        Alcotest.test_case
          "rewrite_program_does_not_reuse_across_resource_scope" `Quick
          test_rewrite_program_does_not_reuse_across_resource_scope;
        Alcotest.test_case "rewrite_program_reuses_same_layout_list_allocation"
          `Quick test_rewrite_program_reuses_same_layout_list_allocation;
        Alcotest.test_case
          "rewrite_program_rejects_different_layout_list_allocation" `Quick
          test_rewrite_program_rejects_different_layout_list_allocation;
        Alcotest.test_case
          "rewrite_program_rejects_release_mismatch_list_allocation" `Quick
          test_rewrite_program_rejects_release_mismatch_list_allocation;
        Alcotest.test_case "rewrite_program_upgrades_post_handoff_drop" `Quick
          test_rewrite_program_upgrades_post_handoff_drop;
        Alcotest.test_case "rewrite_program_upgrades_nested_post_handoff_drop"
          `Quick test_rewrite_program_upgrades_handoff_inside_post_drop_rhs;
        Alcotest.test_case "rewrite_program_upgrades_last_handoff_before_drop"
          `Quick test_rewrite_program_upgrades_last_handoff_before_post_drop;
        Alcotest.test_case
          "rewrite_program_upgrades_nested_later_handoff_before_drop" `Quick
          test_rewrite_program_upgrades_nested_later_handoff_before_post_drop;
        Alcotest.test_case "rewrite_program_upgrades_same_layout_handoff_drop"
          `Quick test_rewrite_program_upgrades_same_layout_handoff_drop;
        Alcotest.test_case
          "rewrite_prepared_program_reuses_owned_union_match_result" `Quick
          test_rewrite_prepared_program_reuses_owned_union_match_result;
        Alcotest.test_case
          "rewrite_prepared_program_rejects_borrowed_union_match_fields" `Quick
          test_rewrite_prepared_program_rejects_borrowed_union_match_fields;
        Alcotest.test_case "rewrite_prepared_program_reuses_all_if_branches"
          `Quick test_rewrite_prepared_program_reuses_all_if_branches;
        Alcotest.test_case "rewrite_prepared_program_rejects_partial_if_branch"
          `Quick test_rewrite_prepared_program_rejects_partial_if_branch;
        Alcotest.test_case
          "rewrite_prepared_program_rejects_source_alias_payload" `Quick
          test_rewrite_prepared_program_rejects_source_alias_payload;
        Alcotest.test_case "rewrite_inserts_reuse_boundary_without_extra_drop"
          `Quick test_rewrite_inserts_reuse_boundary_without_extra_drop;
      ] );
  ]
