(** Collection pipeline recognition and v0 lowering.

    This pass runs after call resolution and before specialization/Perceus. It
    recognizes a deliberately narrow set of std/list pipelines and lowers them
    immediately to ordinary Core loops. Unsupported shapes are left unchanged,
    so the existing synthesized list bodies remain the correctness fallback. *)

open Core
module ListPipeline = Core_list_pipeline
module Producer = Core_collection_producer
open ListPipeline

let ty_int = Ast.TyNamed ("Int", [])
let ty_bool = Ast.TyNamed ("Bool", [])
let ty_void = Ast.TyNamed ("Void", [])
let ty_ptr = Ast.TyNamed ("Ptr", [])

type pipeline_source = ListPipeline.source
type pipeline_stage = ListPipeline.stage
type cardinality = ListPipeline.cardinality
type pipeline_sink = ListPipeline.sink
type pipeline_plan = ListPipeline.t

let mk ?(loc = Ast.dummy_loc) ty desc = { desc; ty; loc }
let void ?(loc = Ast.dummy_loc) () = mk ~loc ty_void CVoid
let vr ?(loc = Ast.dummy_loc) name ty = mk ~loc ty (CVar (Var.named name))

let lit_int ?(loc = Ast.dummy_loc) n =
  mk ~loc ty_int (CLit (Ast.LitInt (Int64.of_int n)))

let bin ?(loc = Ast.dummy_loc) op lhs rhs ty = mk ~loc ty (CBin (op, lhs, rhs))

let if_ ?(loc = Ast.dummy_loc) cond then_ else_ ty =
  mk ~loc ty (CIf (cond, then_, else_))

let seq ?(loc = Ast.dummy_loc) a b = mk ~loc b.ty (CSeq (a, b))

let assign ?(loc = Ast.dummy_loc) name rhs =
  mk ~loc ty_void (CAssign (Var.named name, rhs))

let lett ?(loc = Ast.dummy_loc) name rhs body =
  mk ~loc body.ty
    (CLet
       ( {
           bind_var = Var.named name;
           bind_mut = false;
           bind_ty = rhs.ty;
           bind_rhs = rhs;
         },
         body ))

let lettm ?(loc = Ast.dummy_loc) name rhs body =
  mk ~loc body.ty
    (CLet
       ( {
           bind_var = Var.named name;
           bind_mut = true;
           bind_ty = rhs.ty;
           bind_rhs = rhs;
         },
         body ))

let bind_pipeline_source ?(loc = Ast.dummy_loc) name rhs body =
  (* Fused read-only pipelines should not retain/drop an existing list source just
     to scan it. Existing variables are borrowed views; non-variable sources use
     an owned let so temporaries live across the loop. *)
  match rhs.desc with
  | CVar _ ->
      mk ~loc body.ty
        (CBorrowLet
           ( {
               borrow_var = Var.named name;
               borrow_ty = rhs.ty;
               borrow_rhs = rhs;
             },
             body ))
  | _ -> lett ~loc name rhs body

let intr ?(loc = Ast.dummy_loc) name args ty =
  mk ~loc ty (CCall (CKIntrinsic name, void ~loc (), args))

let closure_call ?(loc = Ast.dummy_loc) fn args ty =
  mk ~loc ty (CCall (CKClosure, fn, args))

let loop name ty = loop_binder_named name ty
let list_elem_ty = ListPipeline.list_elem_ty
let call_base_and_args = ListPipeline.call_base_and_args
let plan_of_expr = ListPipeline.plan_of_expr
let plan_stages = ListPipeline.stages
let counter = ref 0
let reset_fresh () = counter := 0

let fresh prefix =
  let n = !counter in
  incr counter;
  Printf.sprintf "__pipe_%s_%d" prefix n

let type_is_unboxed_pipeline_scalar = Producer.type_is_unboxed_pipeline_scalar

let stage_value_tys = function
  | StageFilter { input_ty; _ } -> [ input_ty ]
  | StageMap { input_ty; output_ty; _ }
  | StageFilterMap { input_ty; output_ty; _ } ->
      [ input_ty; output_ty ]

let plan_stage_value_tys plan =
  List.concat (List.map stage_value_tys (plan_stages plan))

let stage_extracts_option_payload = function
  | StageFilterMap _ -> true
  | StageFilter _ | StageMap _ -> false

let filter_map_payload_policy_for_stages stages =
  if List.exists stage_extracts_option_payload stages then
    Producer.BorrowedPayloadAliasFromOwnedOption
  else Producer.NoFilterMapPayload

let plan_is_unboxed_scalar model plan =
  let scalar = type_is_unboxed_pipeline_scalar model in
  let result_list_is_unboxed result_ty =
    match list_elem_ty result_ty with
    | Some elem_ty -> scalar elem_ty
    | None -> false
  in
  let source_is_unboxed = function
    | SourceList { elem_ty; _ } -> scalar elem_ty
    | SourceRange _ -> scalar ty_int
  in
  let stage_is_unboxed = function
    | StageFilter { input_ty; _ } -> scalar input_ty
    | StageMap { input_ty; output_ty; _ }
    | StageFilterMap { input_ty; output_ty; _ } ->
        scalar input_ty && scalar output_ty
  in
  let sink_is_unboxed = function
    | SinkCollect { result_ty } -> result_list_is_unboxed result_ty
    | SinkFold { acc_ty; _ } -> scalar acc_ty
    | SinkLength -> scalar plan.result_ty
  in
  source_is_unboxed plan.source
  && List.for_all stage_is_unboxed (plan_stages plan)
  && sink_is_unboxed plan.sink

let same_type_collect_policy model plan =
  match (plan.source, plan_stages plan, plan.sink) with
  | SourceList { elem_ty; _ }, _, SinkCollect { result_ty } -> (
      match
        Producer.same_type_collect_policy_for_stages model
          ~source_elem_ty:elem_ty
          ~stage_value_tys:(plan_stage_value_tys plan)
          ~filter_map_payload_policy:
            (filter_map_payload_policy_for_stages (plan_stages plan))
          ~result_ty
      with
      | Producer.Eligible policy -> Some policy
      | Producer.Ineligible _ -> None)
  | _ -> None

let unboxed_collect_policy model plan =
  match (plan.source, plan.sink) with
  | SourceList _, SinkCollect { result_ty }
    when plan_is_unboxed_scalar model plan -> (
      match list_elem_ty result_ty with
      | Some result_elem_ty ->
          Some
            {
              Producer.source_access = Producer.BindUnboxedValue;
              result_elem_ty;
              filter_map_payload_policy =
                filter_map_payload_policy_for_stages (plan_stages plan);
            }
      | None -> None)
  | _ -> None

let collect_policy_for_plan model plan =
  match unboxed_collect_policy model plan with
  | Some policy -> Some policy
  | None -> same_type_collect_policy model plan

let same_type_length_policy model plan =
  let policy_for source_elem_ty stage_value_tys =
    match
      Producer.same_type_source_access_policy model ~source_elem_ty
        ~stage_value_tys
    with
    | Producer.Eligible policy -> Some policy
    | Producer.Ineligible _ -> None
  in
  match (plan.source, plan_stages plan, plan.sink) with
  | SourceList { elem_ty; _ }, _, SinkLength ->
      policy_for elem_ty (plan_stage_value_tys plan)
  | _ -> None

let length_policy_for_plan model plan =
  if plan_is_unboxed_scalar model plan then
    Some
      {
        Producer.sap_access = Producer.BindUnboxedValue;
        sap_elem_ty =
          (match plan.source with
          | SourceList { elem_ty; _ } -> elem_ty
          | SourceRange _ -> ty_int);
      }
  else same_type_length_policy model plan

let callback_is_pure cb =
  match cb.ty with Ast.TyFunc { is_pure = true; _ } -> true | _ -> false

module StringSet = Set.Make (String)

let add_var bound v = StringSet.add v.vname bound

let add_names bound names =
  List.fold_left (fun acc n -> StringSet.add n acc) bound names

let add_typed_vars bound vars =
  List.fold_left (fun acc (v, _) -> add_var acc v) bound vars

let option_exists f = function Some value -> f value | None -> false

let rec ctree_has_runtime_free_var bound = function
  | CTLeaf { ct_bindings; ct_body } ->
      let bound =
        List.fold_left
          (fun acc binding -> add_var acc binding.mb_var)
          bound ct_bindings
      in
      expr_has_runtime_free_var bound ct_body
  | CTFail -> false
  | CTSwitchTag { cts_cases; cts_default; _ } ->
      List.exists
        (fun (_, sub) -> ctree_has_runtime_free_var bound sub)
        cts_cases
      || option_exists (ctree_has_runtime_free_var bound) cts_default
  | CTSwitchLit { ctl_cases; ctl_default; _ } ->
      List.exists
        (fun (_, sub) -> ctree_has_runtime_free_var bound sub)
        ctl_cases
      || ctree_has_runtime_free_var bound ctl_default
  | CTSwitchLen { ctl_len_cases; ctl_len_geq; ctl_len_default; _ } ->
      List.exists
        (fun (_, sub) -> ctree_has_runtime_free_var bound sub)
        ctl_len_cases
      || option_exists
           (fun (_, sub) -> ctree_has_runtime_free_var bound sub)
           ctl_len_geq
      || option_exists (ctree_has_runtime_free_var bound) ctl_len_default

and expr_has_runtime_free_var bound e =
  match e.desc with
  | CVar v -> not (StringSet.mem v.vname bound)
  | CLit _ | CVoid | CBreak | CContinue | CCooperativeCheckpoint -> false
  | CLambda lam ->
      expr_has_runtime_free_var
        (add_typed_vars bound lam.lam_params)
        lam.lam_body
  | CClosureCreate cc ->
      List.exists
        (fun (name, _) -> not (StringSet.mem name bound))
        cc.cc_captures
  | CLet (b, body) ->
      expr_has_runtime_free_var bound b.bind_rhs
      || expr_has_runtime_free_var (add_var bound b.bind_var) body
  | CBorrowLet (b, body) ->
      expr_has_runtime_free_var bound b.borrow_rhs
      || expr_has_runtime_free_var (add_var bound b.borrow_var) body
  | CResourceScope scope ->
      expr_has_runtime_free_var bound scope.rs_acquire
      ||
      let body_bound = add_var bound scope.rs_var in
      expr_has_runtime_free_var body_bound scope.rs_body
      || expr_has_runtime_free_var body_bound scope.rs_cleanup
  | CFor (binder, iter, body) ->
      expr_has_runtime_free_var bound iter
      || expr_has_runtime_free_var (add_var bound binder.loop_var) body
  | CConcurrentlyLoop cf ->
      expr_has_runtime_free_var bound cf.cf_iter
      || expr_has_runtime_free_var (add_var bound cf.cf_var) cf.cf_body
      || option_exists (expr_has_runtime_free_var bound) cf.cf_timeout
  | CConcurrent block ->
      let rhs_has_free =
        List.exists
          (fun b -> expr_has_runtime_free_var bound b.cb_rhs)
          block.conc_bindings
      in
      let body_bound =
        List.fold_left
          (fun acc b -> add_var acc b.cb_var)
          bound block.conc_bindings
      in
      rhs_has_free
      || expr_has_runtime_free_var body_bound block.conc_body
      || option_exists (expr_has_runtime_free_var bound) block.conc_timeout
  | CMatch (scrut, tree) ->
      expr_has_runtime_free_var bound scrut
      || ctree_has_runtime_free_var bound tree
  | CMatchArms (scrut, arms) ->
      expr_has_runtime_free_var bound scrut
      || List.exists
           (fun (pat, body) ->
             let bound = add_names bound (Ast.collect_pattern_vars pat) in
             expr_has_runtime_free_var bound body)
           arms
  | CListHandoff h ->
      let body_bound =
        bound |> fun acc ->
        add_var acc h.lh_source_var |> fun acc ->
        add_var acc h.lh_result_var |> fun acc ->
        add_var acc h.lh_len_var |> fun acc -> add_var acc h.lh_out_var
      in
      expr_has_runtime_free_var bound h.lh_source
      || expr_has_runtime_free_var bound h.lh_capacity
      || expr_has_runtime_free_var body_bound h.lh_body
  | CCall (kind, callee, args) ->
      let callee_has_free =
        match kind with
        | CKUnknown | CKClosure -> expr_has_runtime_free_var bound callee
        | CKSelectedDirect _ | CKUser _ | CKForeign _ | CKBuiltin _
        | CKIntrinsic _ ->
            false
      in
      callee_has_free || List.exists (expr_has_runtime_free_var bound) args
  | _ ->
      fold_immediate_children
        (fun found child -> found || expr_has_runtime_free_var bound child)
        false e

let lambda_has_no_runtime_captures lam =
  let bound = add_typed_vars StringSet.empty lam.lam_params in
  not (expr_has_runtime_free_var bound lam.lam_body)

let bind_lambda_args ~loc params args body =
  List.fold_right2
    (fun (param, param_ty) arg body ->
      mk ~loc body.ty
        (CLet
           ( {
               bind_var = param;
               bind_mut = false;
               bind_ty = param_ty;
               bind_rhs = arg;
             },
             body )))
    params args body

let inline_no_capture_callback ~loc callback args =
  match callback.desc with
  | CLambda lam
    when lam.lam_is_pure
         && List.length lam.lam_params = List.length args
         && lambda_has_no_runtime_captures lam ->
      Some (bind_lambda_args ~loc lam.lam_params args lam.lam_body)
  | _ -> None

let callback_call ?(loc = Ast.dummy_loc) fn args ty =
  match inline_no_capture_callback ~loc fn args with
  | Some inlined -> inlined
  | None -> closure_call ~loc fn args ty

let plan_callbacks_pure plan =
  let stage_callback = function
    | StageFilter { callback; _ }
    | StageMap { callback; _ }
    | StageFilterMap { callback; _ } ->
        callback
  in
  let sink_callbacks =
    match plan.sink with
    | SinkCollect _ | SinkLength -> []
    | SinkFold { reducer; _ } -> [ reducer ]
  in
  List.for_all callback_is_pure
    (List.map stage_callback (plan_stages plan) @ sink_callbacks)

let range_count_expr ~loc start stop =
  if_ ~loc
    (bin ~loc Ast.Le stop start ty_bool)
    (lit_int ~loc 0)
    (bin ~loc Ast.Sub stop start ty_int)
    ty_int

type stream_current =
  | CurrentValue of core
  | CurrentSourceSlot of { value : core; source : core; index : core }

let stream_current_expr = function
  | CurrentValue value -> value
  | CurrentSourceSlot { value; _ } -> value

let rec emit_stream_stages ~loc stages current terminal =
  match stages with
  | [] -> terminal current
  | StageFilter { callback; _ } :: rest ->
      let current_expr = stream_current_expr current in
      let pred_call = callback_call ~loc callback [ current_expr ] ty_bool in
      if_ ~loc pred_call
        (emit_stream_stages ~loc rest current terminal)
        (void ~loc ()) ty_void
  | StageMap { callback; output_ty; _ } :: rest ->
      let mapped_name = fresh "mapped" in
      let mapped = vr ~loc mapped_name output_ty in
      let current_expr = stream_current_expr current in
      let map_call = callback_call ~loc callback [ current_expr ] output_ty in
      lett ~loc mapped_name map_call
        (emit_stream_stages ~loc rest (CurrentValue mapped) terminal)
  | StageFilterMap { callback; output_ty; option_ty; _ } :: rest ->
      let mapped_opt_name = fresh "mapped_opt" in
      let value_name = fresh "value" in
      let mapped_opt = vr ~loc mapped_opt_name option_ty in
      let value = vr ~loc value_name output_ty in
      let current_expr = stream_current_expr current in
      let option_call =
        callback_call ~loc callback [ current_expr ] option_ty
      in
      let keep = emit_stream_stages ~loc rest (CurrentValue value) terminal in
      let match_mapped =
        mk ~loc ty_void
          (CMatch
             ( mapped_opt,
               CTSwitchTag
                 {
                   cts_scrut = AccRoot;
                   cts_cases =
                     [
                       ( "Some",
                         CTLeaf
                           {
                             ct_bindings =
                               [
                                 borrowed_match_binding (Var.named value_name)
                                   (AccVariantField (AccRoot, "Some", 0));
                               ];
                             ct_body = keep;
                           } );
                       ( "None",
                         CTLeaf { ct_bindings = []; ct_body = void ~loc () } );
                     ];
                   cts_default = None;
                 } ))
      in
      lett ~loc mapped_opt_name option_call match_mapped

let source_access_borrows_alias = function
  | Producer.BorrowManagedAlias -> true
  | Producer.BindUnboxedValue -> false

let collect_policy_supports_stages policy stages =
  match
    ( List.exists stage_extracts_option_payload stages,
      policy.Producer.filter_map_payload_policy )
  with
  | false, _ | true, Producer.BorrowedPayloadAliasFromOwnedOption -> true
  | true, Producer.NoFilterMapPayload -> false

let with_source_current ~loc source_access source index raw elem_name elem_ty k
    =
  let unbox_elem = mk ~loc elem_ty (CUnbox (raw, elem_ty)) in
  if source_access_borrows_alias source_access then
    k (CurrentSourceSlot { value = unbox_elem; source; index })
  else
    lett ~loc elem_name unbox_elem
      (k (CurrentValue (vr ~loc elem_name elem_ty)))

let lower_stream_length plan source elem_ty source_access stages =
  let loc = plan.loc in
  let src_name = fresh "src" in
  let n_name = fresh "n" in
  let i_name = fresh "i" in
  let raw_name = fresh "raw" in
  let elem_name = fresh "elem" in
  let count_name = fresh "count" in
  let src = vr ~loc src_name source.ty in
  let n = vr ~loc n_name ty_int in
  let i = vr ~loc i_name ty_int in
  let raw = vr ~loc raw_name ty_ptr in
  let count = vr ~loc count_name ty_int in
  let get_raw = intr ~loc "list_get_unchecked" [ src; i ] ty_ptr in
  let increment _ =
    assign ~loc count_name (bin ~loc Ast.Add count (lit_int ~loc 1) ty_int)
  in
  let loop_body =
    lett ~loc raw_name get_raw
      (with_source_current ~loc source_access src i raw elem_name elem_ty
         (fun elem -> emit_stream_stages ~loc stages elem increment))
  in
  let loop_expr =
    mk ~loc ty_void
      (CFor
         ( loop i_name ty_int,
           mk ~loc ty_int (CRange (lit_int ~loc 0, n)),
           loop_body ))
  in
  bind_pipeline_source ~loc src_name source
    (lett ~loc n_name
       (intr ~loc "list_len" [ src ] ty_int)
       (lettm ~loc count_name (lit_int ~loc 0) (seq ~loc loop_expr count)))

let lower_stream_fold_at ~loc source elem_ty source_access stages init reducer
    acc_ty =
  let src_name = fresh "src" in
  let n_name = fresh "n" in
  let i_name = fresh "i" in
  let raw_name = fresh "raw" in
  let elem_name = fresh "elem" in
  let acc_name = fresh "acc" in
  let src = vr ~loc src_name source.ty in
  let n = vr ~loc n_name ty_int in
  let i = vr ~loc i_name ty_int in
  let raw = vr ~loc raw_name ty_ptr in
  let acc = vr ~loc acc_name acc_ty in
  let get_raw = intr ~loc "list_get_unchecked" [ src; i ] ty_ptr in
  let reduce current =
    let current_expr = stream_current_expr current in
    let next_name = fresh "next" in
    let next = vr ~loc next_name acc_ty in
    let reduce_call = callback_call ~loc reducer [ acc; current_expr ] acc_ty in
    let update_acc =
      mk ~loc ty_void
        (CDrop (Var.named acc_name, acc_ty, assign ~loc acc_name next))
    in
    lett ~loc next_name reduce_call update_acc
  in
  let loop_body =
    lett ~loc raw_name get_raw
      (with_source_current ~loc source_access src i raw elem_name elem_ty
         (fun elem -> emit_stream_stages ~loc stages elem reduce))
  in
  let loop_expr =
    mk ~loc ty_void
      (CFor
         ( loop i_name ty_int,
           mk ~loc ty_int (CRange (lit_int ~loc 0, n)),
           loop_body ))
  in
  bind_pipeline_source ~loc src_name source
    (lett ~loc n_name
       (intr ~loc "list_len" [ src ] ty_int)
       (lettm ~loc acc_name init (seq ~loc loop_expr acc)))

let lower_stream_fold plan source elem_ty source_access stages init reducer
    acc_ty =
  lower_stream_fold_at ~loc:plan.loc source elem_ty source_access stages init
    reducer acc_ty

let lower_stream_collect ?reg plan source elem_ty source_access stages result_ty
    =
  let loc = plan.loc in
  let src_name = fresh "src" in
  let n_name = fresh "n" in
  let result_name = fresh "result" in
  let out_name = fresh "out" in
  let i_name = fresh "i" in
  let raw_name = fresh "raw" in
  let elem_name = fresh "elem" in
  let src = vr ~loc src_name source.ty in
  let n = vr ~loc n_name ty_int in
  let result = vr ~loc result_name result_ty in
  let out = vr ~loc out_name ty_int in
  let i = vr ~loc i_name ty_int in
  let raw = vr ~loc raw_name ty_ptr in
  let get_raw = intr ~loc "list_get_unchecked" [ src; i ] ty_ptr in
  let write current =
    let store =
      match current with
      | CurrentSourceSlot { source; index; _ } ->
          intr ~loc "list_handoff_set_source_slot"
            [ result; out; source; index ]
            ty_void
      | CurrentValue value ->
          intr ~loc "list_handoff_set_owned" [ result; out; value ] ty_void
    in
    seq ~loc store
      (assign ~loc out_name (bin ~loc Ast.Add out (lit_int ~loc 1) ty_int))
  in
  let loop_body =
    lett ~loc raw_name get_raw
      (with_source_current ~loc source_access src i raw elem_name elem_ty
         (fun elem -> emit_stream_stages ~loc stages elem write))
  in
  let loop_expr =
    mk ~loc ty_void
      (CFor
         ( loop i_name ty_int,
           mk ~loc ty_int (CRange (lit_int ~loc 0, n)),
           loop_body ))
  in
  mk ~loc result_ty
    (CListHandoff
       {
         lh_mode = BorrowFresh;
         lh_layout =
           Core_layout_type.list_storage_layout_of_type ?reg result_ty loc;
         lh_source = source;
         lh_source_var = Var.named src_name;
         lh_source_ty = source.ty;
         lh_result_ty = result_ty;
         lh_capacity = intr ~loc "list_len" [ src ] ty_int;
         lh_result_var = Var.named result_name;
         lh_len_var = Var.named n_name;
         lh_out_var = Var.named out_name;
         lh_body = loop_expr;
         lh_write_order = ForwardCompacting;
       })

let lower_range_stream_collect plan start stop stages result_ty =
  let loc = plan.loc in
  let start_name = fresh "start" in
  let stop_name = fresh "stop" in
  let n_name = fresh "n" in
  let result_name = fresh "result" in
  let out_name = fresh "out" in
  let offset_name = fresh "offset" in
  let elem_name = fresh "elem" in
  let start_ref = vr ~loc start_name ty_int in
  let stop_ref = vr ~loc stop_name ty_int in
  let n = vr ~loc n_name ty_int in
  let result = vr ~loc result_name result_ty in
  let out = vr ~loc out_name ty_int in
  let offset = vr ~loc offset_name ty_int in
  let elem = vr ~loc elem_name ty_int in
  let elem_rhs = bin ~loc Ast.Add start_ref offset ty_int in
  let write current =
    let value = stream_current_expr current in
    seq ~loc
      (intr ~loc "list_set_owned" [ result; out; value ] ty_void)
      (assign ~loc out_name (bin ~loc Ast.Add out (lit_int ~loc 1) ty_int))
  in
  let loop_body =
    lett ~loc elem_name elem_rhs
      (emit_stream_stages ~loc stages (CurrentValue elem) write)
  in
  let loop_expr =
    mk ~loc ty_void
      (CFor
         ( loop offset_name ty_int,
           mk ~loc ty_int (CRange (lit_int ~loc 0, n)),
           loop_body ))
  in
  lett ~loc start_name start
    (lett ~loc stop_name stop
       (lett ~loc n_name
          (range_count_expr ~loc start_ref stop_ref)
          (lett ~loc result_name
             (intr ~loc "list_alloc" [ n ] result_ty)
             (lettm ~loc out_name (lit_int ~loc 0)
                (seq ~loc loop_expr
                   (seq ~loc
                      (intr ~loc "list_set_len" [ result; out ] ty_void)
                      result))))))

let lower_range_stream_length plan start stop stages =
  let loc = plan.loc in
  let start_name = fresh "start" in
  let stop_name = fresh "stop" in
  let n_name = fresh "n" in
  let offset_name = fresh "offset" in
  let elem_name = fresh "elem" in
  let count_name = fresh "count" in
  let start_ref = vr ~loc start_name ty_int in
  let stop_ref = vr ~loc stop_name ty_int in
  let n = vr ~loc n_name ty_int in
  let offset = vr ~loc offset_name ty_int in
  let elem = vr ~loc elem_name ty_int in
  let count = vr ~loc count_name ty_int in
  let elem_rhs = bin ~loc Ast.Add start_ref offset ty_int in
  let increment _ =
    assign ~loc count_name (bin ~loc Ast.Add count (lit_int ~loc 1) ty_int)
  in
  let loop_body =
    lett ~loc elem_name elem_rhs
      (emit_stream_stages ~loc stages (CurrentValue elem) increment)
  in
  let loop_expr =
    mk ~loc ty_void
      (CFor
         ( loop offset_name ty_int,
           mk ~loc ty_int (CRange (lit_int ~loc 0, n)),
           loop_body ))
  in
  lett ~loc start_name start
    (lett ~loc stop_name stop
       (lett ~loc n_name
          (range_count_expr ~loc start_ref stop_ref)
          (lettm ~loc count_name (lit_int ~loc 0) (seq ~loc loop_expr count))))

let lower_range_stream_fold plan start stop stages init reducer acc_ty =
  let loc = plan.loc in
  let start_name = fresh "start" in
  let stop_name = fresh "stop" in
  let n_name = fresh "n" in
  let offset_name = fresh "offset" in
  let elem_name = fresh "elem" in
  let acc_name = fresh "acc" in
  let start_ref = vr ~loc start_name ty_int in
  let stop_ref = vr ~loc stop_name ty_int in
  let n = vr ~loc n_name ty_int in
  let offset = vr ~loc offset_name ty_int in
  let elem = vr ~loc elem_name ty_int in
  let acc = vr ~loc acc_name acc_ty in
  let elem_rhs = bin ~loc Ast.Add start_ref offset ty_int in
  let reduce current =
    let current_expr = stream_current_expr current in
    let next_name = fresh "next" in
    let next = vr ~loc next_name acc_ty in
    let reduce_call = callback_call ~loc reducer [ acc; current_expr ] acc_ty in
    let update_acc =
      mk ~loc ty_void
        (CDrop (Var.named acc_name, acc_ty, assign ~loc acc_name next))
    in
    lett ~loc next_name reduce_call update_acc
  in
  let loop_body =
    lett ~loc elem_name elem_rhs
      (emit_stream_stages ~loc stages (CurrentValue elem) reduce)
  in
  let loop_expr =
    mk ~loc ty_void
      (CFor
         ( loop offset_name ty_int,
           mk ~loc ty_int (CRange (lit_int ~loc 0, n)),
           loop_body ))
  in
  lett ~loc start_name start
    (lett ~loc stop_name stop
       (lett ~loc n_name
          (range_count_expr ~loc start_ref stop_ref)
          (lettm ~loc acc_name init (seq ~loc loop_expr acc))))

let lower_plan ?reg model plan =
  if not (plan_callbacks_pure plan) then None
  else
    match (plan.source, plan_stages plan, plan.sink) with
    | SourceRange { start; stop }, stages, SinkCollect { result_ty }
      when plan_is_unboxed_scalar model plan ->
        Some (lower_range_stream_collect plan start stop stages result_ty)
    | SourceRange { start; stop }, stages, SinkLength
      when plan_is_unboxed_scalar model plan ->
        Some (lower_range_stream_length plan start stop stages)
    | SourceRange { start; stop }, stages, SinkFold { init; reducer; acc_ty }
      when plan_is_unboxed_scalar model plan ->
        Some
          (lower_range_stream_fold plan start stop stages init reducer acc_ty)
    | SourceList { expr = source; elem_ty }, stages, SinkCollect { result_ty }
      -> (
        match (source.desc, collect_policy_for_plan model plan) with
        | CVar _, Some policy when collect_policy_supports_stages policy stages
          ->
            Some
              (lower_stream_collect ?reg plan source elem_ty
                 policy.Producer.source_access stages result_ty)
        | _ -> None)
    | SourceList { expr = source; elem_ty }, stages, SinkLength -> (
        match length_policy_for_plan model plan with
        | Some policy ->
            Some
              (lower_stream_length plan source elem_ty
                 policy.Producer.sap_access stages)
        | None -> None)
    | ( SourceList { expr = source; elem_ty },
        stages,
        SinkFold { init; reducer; acc_ty } )
      when plan_is_unboxed_scalar model plan ->
        Some
          (lower_stream_fold plan source elem_ty Producer.BindUnboxedValue
             stages init reducer acc_ty)
    | _ -> None

let lower_bare_list_fold model e =
  match call_base_and_args e with
  | Some ("fold_left", [ source; init; reducer ]) -> (
      match list_elem_ty source.ty with
      | Some elem_ty
        when callback_is_pure reducer
             && type_is_unboxed_pipeline_scalar model elem_ty
             && type_is_unboxed_pipeline_scalar model e.ty ->
          Some
            (lower_stream_fold_at ~loc:e.loc source elem_ty
               Producer.BindUnboxedValue [] init reducer e.ty)
      | _ -> None)
  | _ ->
      let _ = model in
      None

let rec fuse_expr ?reg ?(model = Producer.default_model) e =
  match plan_of_expr e with
  | Some plan -> (
      match lower_plan ?reg model plan with
      | Some lowered -> lowered
      | None -> map_children (fuse_expr ?reg ~model) e)
  | None -> (
      match lower_bare_list_fold model e with
      | Some lowered -> lowered
      | None -> map_children (fuse_expr ?reg ~model) e)

let fuse_func ?reg ?(model = Producer.default_model) f =
  { f with cf_body = Option.map (fuse_expr ?reg ~model) f.cf_body }

let rec fuse_decl ?reg ?(model = Producer.default_model) d =
  let desc =
    match d.cd_desc with
    | CDFunc f -> CDFunc (fuse_func ?reg ~model f)
    | CDVar v -> CDVar { v with cv_init = fuse_expr ?reg ~model v.cv_init }
    | CDImpl impl ->
        CDImpl
          {
            impl with
            ci_methods = List.map (fuse_func ?reg ~model) impl.ci_methods;
          }
    | CDPrivate inner -> CDPrivate (fuse_decl ?reg ~model inner)
    | other -> other
  in
  { d with cd_desc = desc }

let fuse_program ?reg prog =
  let model =
    match reg with
    | Some reg -> Producer.model_of_registry reg
    | None -> Producer.default_model
  in
  reset_fresh ();
  List.map (fuse_decl ?reg ~model) prog
