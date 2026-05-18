(** Tests for reuse analysis and the narrow rewrite slices.

    The rewrite tests stay deliberately small: only proven collection allocation
    reuse may change Core, and all other candidates must remain unchanged. *)

open Blorp.Ast
open Blorp.Core

let ty_int = TyNamed ("Int", [])
let ty_int32 = TyNamed ("Int32", [])
let ty_uint64 = TyNamed ("UInt64", [])
let ty_ptr = TyNamed ("Ptr", [])
let ty_string = TyNamed ("String", [])
let ty_void = TyNamed ("Void", [])
let ty_list elem = TyNamed ("List", [ elem ])
let ty_set elem = TyNamed ("Set", [ elem ])
let ty_dict key value = TyNamed ("Dict", [ key; value ])
let mk ty desc = { desc; ty; loc = dummy_loc }
let void () = mk ty_void CVoid
let int n = mk ty_int (CLit (LitInt (Int64.of_int n)))
let var name ty = mk ty (CVar (Var.named name))
let intrinsic name args ty = mk ty (CCall (CKIntrinsic name, void (), args))
let builtin name args ty = mk ty (CCall (CKBuiltin name, void (), args))

let may_park_foreign_effect =
  Blorp.Builtin_metadata.Impure
    { wait = May_park_fiber; cancellation = Cancellation_point }

let foreign ?(call_effect = may_park_foreign_effect) name args ty =
  mk ty
    (CCall
       ( CKForeign
           {
             fc_c_name = name;
             fc_arg_passing = ForeignBorrowArgs;
             fc_call_effect = call_effect;
           },
         void (),
         args ))

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

let contains_sub output sub =
  let n = String.length sub in
  let m = String.length output in
  let rec go i = i + n <= m && (String.sub output i n = sub || go (i + 1)) in
  go 0

let count_list_handoff mode body =
  fold_tree
    (fun acc node ->
      match node.desc with
      | CListHandoff h when h.lh_mode = mode -> acc + 1
      | _ -> acc)
    0 body

let emit_rewritten_program_to_string prog =
  let rewritten = Blorp.Core_reuse.rewrite_program prog in
  let converted = Blorp.Core_closure.convert_program rewritten in
  let ctx = Blorp.Core_emit_context.create () in
  Blorp.Core_emit.emit_program ctx converted;
  Buffer.contents ctx.output

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

let test_rejects_later_allocation_after_parking_call () =
  let list_ty = ty_list ty_int in
  let body =
    drop "xs" list_ty
      (seq
         (builtin "blorp_sleep" [ int 1 ] ty_void)
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
    [ "interference:call barrier" ]
    (block_fact_tags analysis.facts);
  Alcotest.(check int)
    "candidate count" 0
    (List.length (Blorp.Core_reuse.analyze_expr body))

let test_rejects_later_allocation_after_parking_foreign_call () =
  let list_ty = ty_list ty_int in
  let body =
    drop "xs" list_ty
      (seq
         (foreign "c_wait_for_io" [ int 1 ] ty_void)
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
    [ "interference:call barrier" ]
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

let test_rewrite_program_keeps_drop_before_parking_call () =
  let list_ty = ty_list ty_int in
  let body =
    drop "xs" list_ty
      (seq
         (builtin "blorp_sleep" [ int 1 ] ty_void)
         (lett "ys" (list_alloc ()) (var "ys" list_ty)))
  in
  let fn =
    {
      cf_name = "reuse_after_sleep";
      cf_module = None;
      cf_type_params = [];
      cf_params = [];
      cf_return_ty = list_ty;
      cf_body = Some body;
      cf_is_pure = false;
      cf_kind = CFUser;
      cf_def_id = 1;
    }
  in
  let prog = [ { cd_desc = CDFunc fn; cd_loc = dummy_loc; cd_doc = None } ] in
  Alcotest.(check bool)
    "program unchanged" true
    (Blorp.Core_reuse.rewrite_program prog = prog)

let test_rewrite_program_keeps_drop_before_parking_foreign_call () =
  let list_ty = ty_list ty_int in
  let body =
    drop "xs" list_ty
      (seq
         (foreign "c_wait_for_io" [ int 1 ] ty_void)
         (lett "ys" (list_alloc ()) (var "ys" list_ty)))
  in
  let fn =
    {
      cf_name = "reuse_after_foreign_wait";
      cf_module = None;
      cf_type_params = [];
      cf_params = [];
      cf_return_ty = list_ty;
      cf_body = Some body;
      cf_is_pure = false;
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

let test_rewrite_emits_reuse_boundary_without_extra_drop () =
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
  let c = emit_rewritten_program_to_string prog in
  Alcotest.(check bool)
    "emits reuse boundary" true
    (contains_sub c "blorp_list_reuse_alloc(xs, 4L)");
  Alcotest.(check bool)
    "does not emit separate drop for consumed owner" false
    (contains_sub c "blorp_release(xs);")

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
        Alcotest.test_case "later_allocation_after_safe_binding" `Quick
          test_marks_later_allocation_after_safe_binding;
        Alcotest.test_case "later_allocation_after_safe_statement" `Quick
          test_marks_later_allocation_after_safe_statement;
        Alcotest.test_case "rejects_later_allocation_after_parking_call" `Quick
          test_rejects_later_allocation_after_parking_call;
        Alcotest.test_case "rejects_later_allocation_after_parking_foreign_call"
          `Quick test_rejects_later_allocation_after_parking_foreign_call;
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
        Alcotest.test_case "rewrite_program_reuses_dead_list_allocation" `Quick
          test_rewrite_program_reuses_dead_list_allocation;
        Alcotest.test_case "rewrite_program_reuses_dead_set_allocation" `Quick
          test_rewrite_program_reuses_dead_set_allocation;
        Alcotest.test_case "rewrite_program_reuses_dead_dict_allocation" `Quick
          test_rewrite_program_reuses_dead_dict_allocation;
        Alcotest.test_case "rewrite_program_reuses_after_safe_statement" `Quick
          test_rewrite_program_reuses_after_safe_statement;
        Alcotest.test_case "rewrite_program_keeps_drop_before_parking_call"
          `Quick test_rewrite_program_keeps_drop_before_parking_call;
        Alcotest.test_case
          "rewrite_program_keeps_drop_before_parking_foreign_call" `Quick
          test_rewrite_program_keeps_drop_before_parking_foreign_call;
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
        Alcotest.test_case "rewrite_emits_reuse_boundary_without_extra_drop"
          `Quick test_rewrite_emits_reuse_boundary_without_extra_drop;
      ] );
  ]
