(** Tests for collection pipeline fusion recognition and lowering. *)

open Blorp.Ast
open Blorp.Core
module LP = Blorp.Core_list_pipeline
module P = Blorp.Core_collection_pipeline

let ty_int = TyNamed ("Int", [])
let ty_int128 = TyNamed ("Int128", [])
let ty_bool = TyNamed ("Bool", [])
let ty_float = TyNamed ("Float", [])
let ty_string = TyNamed ("String", [])
let ty_widget = TyNamed ("Widget", [])
let ty_count = TyNamed ("Count", [])
let ty_void = TyNamed ("Void", [])
let ty_list elem = TyNamed ("List", [ elem ])
let ty_option elem = TyNamed ("Option", [ elem ])
let ty_func params return = TyFunc { params; return; is_pure = true }
let ty_impure_func params return = TyFunc { params; return; is_pure = false }
let loc = dummy_loc
let list_int = ty_list ty_int
let mk ty desc = { desc; ty; loc }
let cvar name ty = mk ty (CVar (Var.named name))
let cint n = mk ty_int (CLit (LitInt (Int64.of_int n)))
let cfloat n = mk ty_float (CLit (LitFloat n))
let void = mk ty_void CVoid
let callback name params return = cvar name (ty_func params return)

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

let impure_callback name params return =
  cvar name (ty_impure_func params return)

let call_user ?(id = 1) name args return_ty =
  let fn_ty = ty_func (List.map (fun arg -> arg.ty) args) return_ty in
  mk return_ty (CCall (CKUser (name, Some id), cvar name fn_ty, args))

let range_call start stop = call_user "std_list__range" [ start; stop ] list_int

let filter_call source pred =
  call_user "std_list__filter__mono_Int" [ source; pred ] list_int

let map_call source f =
  call_user "std_list__map__mono_Int_Int" [ source; f ] list_int

let filter_map_hof_call source f =
  call_user "std_list__filter_map__mono_Int_Int" [ source; f ] list_int

let fold_call source init reducer =
  call_user "std_list__fold_left__mono_Int_Int" [ source; init; reducer ] ty_int

let length_call source =
  call_user "std_list__length__mono_Int" [ source ] ty_int

let length_string_call source =
  call_user "std_list__length__mono_String" [ source ] ty_int

let trait_length_string_call source =
  call_user "HasLength_length_List_String" [ source ] ty_int

let pred = callback "pred" [ ty_int ] ty_bool
let mapper = callback "mapper" [ ty_int ] ty_int

let filter_map_hof_mapper =
  callback "filter_map_hof_mapper" [ ty_int ] (ty_option ty_int)

let impure_pred = impure_callback "impure_pred" [ ty_int ] ty_bool
let impure_mapper = impure_callback "impure_mapper" [ ty_int ] ty_int

let impure_filter_map_hof_mapper =
  impure_callback "impure_filter_map_hof_mapper" [ ty_int ] (ty_option ty_int)

let reducer = callback "reducer" [ ty_int; ty_int ] ty_int
let count_to_int_mapper = callback "count_to_int_mapper" [ ty_int ] ty_int
let impure_reducer = impure_callback "impure_reducer" [ ty_int; ty_int ] ty_int
let list_float = ty_list ty_float
let float_pred = callback "float_pred" [ ty_float ] ty_bool
let float_mapper = callback "float_mapper" [ ty_float ] ty_float
let int_to_float_mapper = callback "int_to_float_mapper" [ ty_int ] ty_float
let float_reducer = callback "float_reducer" [ ty_float; ty_float ] ty_float

let filter_float_call source pred =
  call_user "std_list__filter__mono_Float" [ source; pred ] list_float

let map_float_call source f =
  call_user "std_list__map__mono_Float_Float" [ source; f ] list_float

let map_int_float_call source f =
  call_user "std_list__map__mono_Int_Float" [ source; f ] list_float

let fold_float_call source init reducer =
  call_user "std_list__fold_left__mono_Float_Float" [ source; init; reducer ]
    ty_float

let list_int128 = ty_list ty_int128
let int128_pred = callback "int128_pred" [ ty_int128 ] ty_bool
let int128_mapper = callback "int128_mapper" [ ty_int128 ] ty_int128

let int128_reducer =
  callback "int128_reducer" [ ty_int128; ty_int128 ] ty_int128

let filter_int128_call source pred =
  call_user "std_list__filter__mono_Int128" [ source; pred ] list_int128

let map_int128_call source f =
  call_user "std_list__map__mono_Int128_Int128" [ source; f ] list_int128

let fold_int128_call source init reducer =
  call_user "std_list__fold_left__mono_Int128_Int128" [ source; init; reducer ]
    ty_int128

let list_string = ty_list ty_string
let string_pred = callback "string_pred" [ ty_string ] ty_bool
let string_mapper = callback "string_mapper" [ ty_string ] ty_string

let string_filter_map_hof_mapper =
  callback "string_filter_map_hof_mapper" [ ty_string ] (ty_option ty_string)

let filter_string_call source pred =
  call_user "std_list__filter__mono_String" [ source; pred ] list_string

let map_string_call source f =
  call_user "std_list__map__mono_String_String" [ source; f ] list_string

let string_filter_map_hof_call source f =
  call_user "std_list__filter_map__mono_String_String" [ source; f ] list_string

let option_int = ty_option ty_int
let list_option_int = ty_list option_int
let option_pred = callback "option_pred" [ option_int ] ty_bool
let option_mapper = callback "option_mapper" [ option_int ] option_int

let filter_option_call source pred =
  call_user "std_list__filter__mono_Option_Int" [ source; pred ] list_option_int

let map_option_call source f =
  call_user "std_list__map__mono_Option_Int_Option_Int" [ source; f ]
    list_option_int

let list_widget = ty_list ty_widget
let widget_pred = callback "widget_pred" [ ty_widget ] ty_bool
let widget_mapper = callback "widget_mapper" [ ty_widget ] ty_widget

let filter_widget_call source pred =
  call_user "std_list__filter__mono_Widget" [ source; pred ] list_widget

let map_widget_call source f =
  call_user "std_list__map__mono_Widget_Widget" [ source; f ] list_widget

let filter_map_fold_expr () =
  fold_call
    (map_call (filter_call (cvar "xs" list_int) pred) mapper)
    (cint 0) reducer

let filter_map_hof_fold_expr () =
  fold_call
    (filter_map_hof_call (cvar "xs" list_int) filter_map_hof_mapper)
    (cint 0) reducer

let filter_map_hof_collect_expr () =
  filter_map_hof_call (cvar "xs" list_int) filter_map_hof_mapper

let filter_map_collect_expr () =
  map_call (filter_call (cvar "xs" list_int) pred) mapper

let filter_collect_expr () = filter_call (cvar "xs" list_int) pred
let map_collect_expr () = map_call (cvar "xs" list_int) mapper

let alias_to_int_map_collect_expr () =
  call_user "std_list__map__mono_Count_Int"
    [ cvar "xs" (ty_list ty_count); count_to_int_mapper ]
    list_int

let map_filter_collect_expr () =
  filter_call (map_call (cvar "xs" list_int) mapper) pred

let map_filter_map_collect_expr () =
  map_call (filter_call (map_call (cvar "xs" list_int) mapper) pred) mapper

let filter_map_hof_map_collect_expr () =
  map_call
    (filter_map_hof_call (cvar "xs" list_int) filter_map_hof_mapper)
    mapper

let filter_map_length_expr () =
  length_call (map_call (filter_call (cvar "xs" list_int) pred) mapper)

let filter_length_expr () = length_call (filter_call (cvar "xs" list_int) pred)

let map_filter_length_expr () =
  length_call (filter_call (map_call (cvar "xs" list_int) mapper) pred)

let map_filter_map_length_expr () =
  length_call
    (map_call (filter_call (map_call (cvar "xs" list_int) mapper) pred) mapper)

let filter_map_map_fold_expr () =
  fold_call
    (map_call (map_call (filter_call (cvar "xs" list_int) pred) mapper) mapper)
    (cint 0) reducer

let impure_filter_map_fold_expr () =
  fold_call
    (map_call (filter_call (cvar "xs" list_int) impure_pred) mapper)
    (cint 0) reducer

let impure_reducer_filter_map_fold_expr () =
  fold_call
    (map_call (filter_call (cvar "xs" list_int) pred) mapper)
    (cint 0) impure_reducer

let impure_filter_map_hof_collect_expr () =
  filter_map_hof_call (cvar "xs" list_int) impure_filter_map_hof_mapper

let impure_filter_map_collect_expr () =
  map_call (filter_call (cvar "xs" list_int) pred) impure_mapper

let float_filter_map_fold_expr () =
  fold_float_call
    (map_float_call
       (filter_float_call (cvar "xs" list_float) float_pred)
       float_mapper)
    (cfloat 0.0) float_reducer

let float_filter_map_collect_expr () =
  map_float_call
    (filter_float_call (cvar "xs" list_float) float_pred)
    float_mapper

let int128_filter_map_fold_expr () =
  fold_int128_call
    (map_int128_call
       (filter_int128_call (cvar "xs" list_int128) int128_pred)
       int128_mapper)
    (cvar "zero128" ty_int128) int128_reducer

let int128_filter_map_collect_expr () =
  map_int128_call
    (filter_int128_call (cvar "xs" list_int128) int128_pred)
    int128_mapper

let string_filter_map_collect_expr () =
  map_string_call
    (filter_string_call (cvar "xs" list_string) string_pred)
    string_mapper

let string_filter_collect_expr () =
  filter_string_call (cvar "xs" list_string) string_pred

let string_map_collect_expr () =
  map_string_call (cvar "xs" list_string) string_mapper

let string_filter_map_hof_collect_expr () =
  string_filter_map_hof_call (cvar "xs" list_string)
    string_filter_map_hof_mapper

let string_filter_map_hof_map_collect_expr () =
  map_string_call
    (string_filter_map_hof_call (cvar "xs" list_string)
       string_filter_map_hof_mapper)
    string_mapper

let string_map_filter_map_collect_expr () =
  map_string_call
    (filter_string_call
       (map_string_call (cvar "xs" list_string) string_mapper)
       string_pred)
    string_mapper

let string_filter_map_length_expr () =
  length_string_call
    (map_string_call
       (filter_string_call (cvar "xs" list_string) string_pred)
       string_mapper)

let string_filter_length_expr () =
  length_string_call (filter_string_call (cvar "xs" list_string) string_pred)

let string_map_filter_length_expr () =
  length_string_call
    (filter_string_call
       (map_string_call (cvar "xs" list_string) string_mapper)
       string_pred)

let string_map_filter_map_length_expr () =
  length_string_call
    (map_string_call
       (filter_string_call
          (map_string_call (cvar "xs" list_string) string_mapper)
          string_pred)
       string_mapper)

let string_trait_map_filter_map_length_expr () =
  trait_length_string_call
    (map_string_call
       (filter_string_call
          (map_string_call (cvar "xs" list_string) string_mapper)
          string_pred)
       string_mapper)

let option_filter_map_collect_expr () =
  map_option_call
    (filter_option_call (cvar "xs" list_option_int) option_pred)
    option_mapper

let widget_filter_map_collect_expr () =
  map_widget_call
    (filter_widget_call (cvar "xs" list_widget) widget_pred)
    widget_mapper

let range_map_filter_expr () =
  filter_call (map_call (range_call (cint 0) (cvar "n" ty_int)) mapper) pred

let range_map_collect_expr () =
  map_call (range_call (cint 0) (cvar "n" ty_int)) mapper

let range_filter_length_expr () =
  length_call (filter_call (range_call (cint 0) (cvar "n" ty_int)) pred)

let range_filter_map_fold_expr () =
  fold_call
    (map_call (filter_call (range_call (cint 0) (cvar "n" ty_int)) pred) mapper)
    (cint 0) reducer

let range_filter_map_hof_fold_expr () =
  fold_call
    (filter_map_hof_call
       (range_call (cint 0) (cvar "n" ty_int))
       filter_map_hof_mapper)
    (cint 0) reducer

let impure_range_map_filter_expr () =
  filter_call
    (map_call (range_call (cint 0) (cvar "n" ty_int)) impure_mapper)
    pred

let range_map_float_filter_expr () =
  filter_float_call
    (map_int_float_call
       (range_call (cint 0) (cvar "n" ty_int))
       int_to_float_mapper)
    float_pred

let count_user_call basename body =
  fold_tree
    (fun acc node ->
      match node.desc with
      | CCall (CKUser (name, _), _, _)
        when LP.base_list_func_name name = Some basename ->
          acc + 1
      | _ -> acc)
    0 body

let count_intrinsic name body =
  fold_tree
    (fun acc node ->
      match node.desc with
      | CCall (CKIntrinsic got, _, _) when got = name -> acc + 1
      | _ -> acc)
    0 body

let count_for body =
  fold_tree
    (fun acc node -> match node.desc with CFor _ -> acc + 1 | _ -> acc)
    0 body

let count_list_handoff mode body =
  fold_tree
    (fun acc node ->
      match node.desc with
      | CListHandoff h when h.lh_mode = mode -> acc + 1
      | _ -> acc)
    0 body

let starts_with ~prefix s =
  let prefix_len = String.length prefix in
  String.length s >= prefix_len && String.sub s 0 prefix_len = prefix

let count_drop_prefix prefix body =
  fold_tree
    (fun acc node ->
      match node.desc with
      | CDrop (v, _, _) when starts_with ~prefix v.vname -> acc + 1
      | _ -> acc)
    0 body

let count_borrow_prefix prefix body =
  fold_tree
    (fun acc node ->
      match node.desc with
      | CBorrowLet ({ borrow_var; _ }, _)
        when starts_with ~prefix borrow_var.vname ->
          acc + 1
      | _ -> acc)
    0 body

let test_recognizes_filter_map_fold () =
  match P.plan_of_expr (filter_map_fold_expr ()) with
  | Some plan -> (
      match
        ( plan.source,
          LP.stages plan,
          plan.sink,
          plan.cardinality,
          plan.result_ty )
      with
      | ( LP.SourceList _,
          [ LP.StageFilter _; LP.StageMap _ ],
          LP.SinkFold _,
          LP.Terminal,
          TyNamed ("Int", []) ) ->
          ()
      | _ -> Alcotest.fail "unexpected filter->map->fold plan shape")
  | None -> Alcotest.fail "expected filter->map->fold pipeline plan"

let test_recognizes_filter_map_hof_fold () =
  match P.plan_of_expr (filter_map_hof_fold_expr ()) with
  | Some plan -> (
      match
        ( plan.source,
          LP.stages plan,
          plan.sink,
          plan.cardinality,
          plan.result_ty )
      with
      | ( LP.SourceList _,
          [ LP.StageFilterMap _ ],
          LP.SinkFold _,
          LP.Terminal,
          TyNamed ("Int", []) ) ->
          ()
      | _ -> Alcotest.fail "unexpected filter_map->fold plan shape")
  | None -> Alcotest.fail "expected filter_map->fold pipeline plan"

let test_recognizes_filter_map_hof_collect () =
  match P.plan_of_expr (filter_map_hof_collect_expr ()) with
  | Some plan -> (
      match
        ( plan.source,
          LP.stages plan,
          plan.sink,
          plan.cardinality,
          plan.result_ty )
      with
      | ( LP.SourceList _,
          [ LP.StageFilterMap _ ],
          LP.SinkCollect
            { result_ty = TyNamed ("List", [ TyNamed ("Int", []) ]) },
          LP.UpperBound,
          TyNamed ("List", [ TyNamed ("Int", []) ]) ) ->
          ()
      | _ -> Alcotest.fail "unexpected filter_map collect plan shape")
  | None -> Alcotest.fail "expected filter_map collect pipeline plan"

let test_recognizes_range_map_filter () =
  match P.plan_of_expr (range_map_filter_expr ()) with
  | Some plan -> (
      match
        (plan.source, LP.stages plan, plan.sink, plan.cardinality)
      with
      | ( LP.SourceRange _,
          [ LP.StageMap _; LP.StageFilter _ ],
          LP.SinkCollect
            { result_ty = TyNamed ("List", [ TyNamed ("Int", []) ]) },
          LP.UpperBound ) ->
          ()
      | _ -> Alcotest.fail "unexpected range->map->filter plan shape")
  | None -> Alcotest.fail "expected range->map->filter pipeline plan"

let test_rejects_materialized_let () =
  let filtered = filter_call (cvar "xs" list_int) pred in
  let body = map_call (cvar "ys" list_int) mapper in
  let expr =
    mk list_int
      (CLet
         ( {
             bind_var = Var.named "ys";
             bind_mut = false;
             bind_ty = list_int;
             bind_rhs = filtered;
           },
           body ))
  in
  let fused = P.fuse_expr expr in
  Alcotest.(check int) "filter call lowered" 0 (count_user_call "filter" fused);
  Alcotest.(check int) "map call lowered" 0 (count_user_call "map" fused);
  Alcotest.(check int)
    "materialized stages lower independently" 2
    (count_list_handoff BorrowFresh fused);
  Alcotest.(check int) "no cross-boundary single loop" 2 (count_for fused)

let test_rejects_barriers () =
  let flat_map =
    call_user "std_list__flat_map__mono_Int_Int"
      [ cvar "xs" list_int; mapper ]
      list_int
  in
  let sort = call_user "std_list__sort__mono_Int" [ flat_map ] list_int in
  let fused = P.fuse_expr sort in
  Alcotest.(check int)
    "flat_map call remains" 1
    (count_user_call "flat_map" fused);
  Alcotest.(check int) "sort call remains" 1 (count_user_call "sort" fused);
  Alcotest.(check int) "no fused loop" 0 (count_for fused)

let test_lowers_filter_map_fold_without_intermediate_hofs () =
  let fused = P.fuse_expr (filter_map_fold_expr ()) in
  Alcotest.(check int) "one fused loop" 1 (count_for fused);
  Alcotest.(check int) "no filter call" 0 (count_user_call "filter" fused);
  Alcotest.(check int) "no map call" 0 (count_user_call "map" fused);
  Alcotest.(check int) "no fold_left call" 0 (count_user_call "fold_left" fused);
  Alcotest.(check int)
    "no list allocation for terminal fold" 0
    (count_intrinsic "list_alloc" fused)

let test_lowers_bare_fold_with_borrowed_source () =
  let fused = P.fuse_expr (fold_call (cvar "xs" list_int) (cint 0) reducer) in
  Alcotest.(check int) "one fused loop" 1 (count_for fused);
  Alcotest.(check int) "no fold_left call" 0 (count_user_call "fold_left" fused);
  Alcotest.(check int)
    "pipeline source is a borrowed view" 1
    (count_borrow_prefix "__pipe_src_" fused);
  Alcotest.(check int)
    "fused loop uses proven unchecked source loads" 1
    (count_intrinsic "list_get_unchecked" fused);
  Alcotest.(check int)
    "fused loop does not use checked source loads" 0
    (count_intrinsic "list_get" fused)

let test_no_capture_callback_respects_resource_scope_binding () =
  let callback_ty = ty_func [ ty_int ] ty_int in
  let scoped =
    resource_scope "resource" ty_int (cint 0) (cvar "resource" ty_int) void
  in
  let callback =
    mk callback_ty
      (CLambda
         {
           lam_params = [ (Var.named "value", ty_int) ];
           lam_body = scoped;
           lam_return_ty = ty_int;
           lam_is_pure = true;
         })
  in
  let lowered = P.callback_call ~loc callback [ cint 1 ] ty_int in
  match lowered.desc with
  | CLet (_, { desc = CResourceScope { rs_body = { desc = CVar v; _ }; _ }; _ })
    ->
      Alcotest.(check string)
        "resource body reads scoped binding" "resource" v.vname
  | CCall (CKClosure, _, _) ->
      Alcotest.fail "resource-scope binding was mistaken for a capture"
  | _ ->
      Alcotest.failf "unexpected callback lowering:\n%s"
        (Blorp.Core.pp_to_string lowered)

let test_lowers_filter_map_fold_with_borrowed_source () =
  let fused = P.fuse_expr (filter_map_fold_expr ()) in
  Alcotest.(check int)
    "pipeline source is a borrowed view" 1
    (count_borrow_prefix "__pipe_src_" fused)

let test_lowers_filter_map_length_without_materialized_list () =
  let fused = P.fuse_expr (filter_map_length_expr ()) in
  Alcotest.(check int) "one fused loop" 1 (count_for fused);
  Alcotest.(check int) "no filter call" 0 (count_user_call "filter" fused);
  Alcotest.(check int) "no map call" 0 (count_user_call "map" fused);
  Alcotest.(check int)
    "no materialized result handoff" 0
    (count_list_handoff BorrowFresh fused);
  Alcotest.(check int)
    "no result list allocation" 0
    (count_intrinsic "list_alloc" fused)

let test_lowers_filter_length_without_materialized_list () =
  let fused = P.fuse_expr (filter_length_expr ()) in
  Alcotest.(check int) "one fused loop" 1 (count_for fused);
  Alcotest.(check int) "no filter call" 0 (count_user_call "filter" fused);
  Alcotest.(check int) "no length call" 0 (count_user_call "length" fused);
  Alcotest.(check int)
    "no materialized result handoff" 0
    (count_list_handoff BorrowFresh fused);
  Alcotest.(check int)
    "no result list allocation" 0
    (count_intrinsic "list_alloc" fused)

let test_lowers_map_filter_length_without_materialized_list () =
  let fused = P.fuse_expr (map_filter_length_expr ()) in
  Alcotest.(check int) "one fused loop" 1 (count_for fused);
  Alcotest.(check int) "no map call" 0 (count_user_call "map" fused);
  Alcotest.(check int) "no filter call" 0 (count_user_call "filter" fused);
  Alcotest.(check int)
    "no materialized result handoff" 0
    (count_list_handoff BorrowFresh fused);
  Alcotest.(check int)
    "no result list allocation" 0
    (count_intrinsic "list_alloc" fused)

let test_lowers_long_map_filter_map_length_without_materialized_list () =
  let fused = P.fuse_expr (map_filter_map_length_expr ()) in
  Alcotest.(check int) "one fused loop" 1 (count_for fused);
  Alcotest.(check int) "no map call" 0 (count_user_call "map" fused);
  Alcotest.(check int) "no filter call" 0 (count_user_call "filter" fused);
  Alcotest.(check int) "no length call" 0 (count_user_call "length" fused);
  Alcotest.(check int)
    "no materialized result handoff" 0
    (count_list_handoff BorrowFresh fused);
  Alcotest.(check int)
    "no result list allocation" 0
    (count_intrinsic "list_alloc" fused)

let test_lowers_long_filter_map_map_fold_without_intermediate_hofs () =
  let fused = P.fuse_expr (filter_map_map_fold_expr ()) in
  Alcotest.(check int) "one fused loop" 1 (count_for fused);
  Alcotest.(check int) "no filter call" 0 (count_user_call "filter" fused);
  Alcotest.(check int) "no map call" 0 (count_user_call "map" fused);
  Alcotest.(check int) "no fold_left call" 0 (count_user_call "fold_left" fused);
  Alcotest.(check int)
    "no list allocation for terminal fold" 0
    (count_intrinsic "list_alloc" fused)

let test_lowers_filter_map_hof_fold_without_result_allocation () =
  let fused = P.fuse_expr (filter_map_hof_fold_expr ()) in
  Alcotest.(check int) "one fused loop" 1 (count_for fused);
  Alcotest.(check int)
    "no filter_map call" 0
    (count_user_call "filter_map" fused);
  Alcotest.(check int) "no fold_left call" 0 (count_user_call "fold_left" fused);
  Alcotest.(check int)
    "no list allocation for terminal fold" 0
    (count_intrinsic "list_alloc" fused);
  Alcotest.(check int)
    "no pre-Perceus manual drop of mapped option" 0
    (count_drop_prefix "__pipe_mapped_opt_" fused);
  Alcotest.(check int)
    "compiled option match, not raw match arms" 1
    (fold_tree
       (fun acc node ->
         match node.desc with
         | CMatch _ -> acc + 1
         | CMatchArms _ -> Alcotest.fail "fusion must not introduce CMatchArms"
         | _ -> acc)
       0 fused)

let test_lowers_filter_map_hof_collect_without_hof_call () =
  let fused = P.fuse_expr (filter_map_hof_collect_expr ()) in
  Alcotest.(check int) "one handoff" 1 (count_list_handoff BorrowFresh fused);
  Alcotest.(check int)
    "no filter_map call" 0
    (count_user_call "filter_map" fused);
  Alcotest.(check int)
    "no raw list_alloc in fusion output" 0
    (count_intrinsic "list_alloc" fused);
  Alcotest.(check int)
    "handoff uses overwrite-aware store" 1
    (count_intrinsic "list_handoff_set_owned" fused);
  Alcotest.(check int)
    "handoff does not use generic store" 0
    (count_intrinsic "list_set_owned" fused);
  Alcotest.(check int)
    "no pre-Perceus manual drop of mapped option" 0
    (count_drop_prefix "__pipe_mapped_opt_" fused);
  Alcotest.(check int)
    "compiled option match, not raw match arms" 1
    (fold_tree
       (fun acc node ->
         match node.desc with
         | CMatch _ -> acc + 1
         | CMatchArms _ -> Alcotest.fail "fusion must not introduce CMatchArms"
         | _ -> acc)
       0 fused)

let test_does_not_lower_impure_filter_map_fold () =
  let fused = P.fuse_expr (impure_filter_map_fold_expr ()) in
  Alcotest.(check int) "filter call remains" 1 (count_user_call "filter" fused);
  Alcotest.(check int) "map call remains" 1 (count_user_call "map" fused);
  Alcotest.(check int)
    "fold_left call remains" 1
    (count_user_call "fold_left" fused);
  Alcotest.(check int) "no fused loop" 0 (count_for fused)

let test_does_not_lower_impure_reducer_terminal_fold () =
  let fused = P.fuse_expr (impure_reducer_filter_map_fold_expr ()) in
  Alcotest.(check int)
    "terminal fold_left remains" 1
    (count_user_call "fold_left" fused)

let test_does_not_lower_impure_filter_map_hof_collect () =
  let fused = P.fuse_expr (impure_filter_map_hof_collect_expr ()) in
  Alcotest.(check int)
    "filter_map call remains" 1
    (count_user_call "filter_map" fused);
  Alcotest.(check int) "no fused loop" 0 (count_for fused)

let test_does_not_lower_impure_filter_map_collect () =
  let fused = P.fuse_expr (impure_filter_map_collect_expr ()) in
  Alcotest.(check int)
    "pure source filter lowered independently" 0
    (count_user_call "filter" fused);
  Alcotest.(check int)
    "impure terminal map remains" 1
    (count_user_call "map" fused);
  Alcotest.(check int) "one independent source loop" 1 (count_for fused)

let test_does_not_lower_impure_range_map_filter () =
  let fused = P.fuse_expr (impure_range_map_filter_expr ()) in
  Alcotest.(check int) "range call remains" 1 (count_user_call "range" fused);
  Alcotest.(check int) "map call remains" 1 (count_user_call "map" fused);
  Alcotest.(check int) "filter call remains" 1 (count_user_call "filter" fused);
  Alcotest.(check int) "no fused loop" 0 (count_for fused)

let test_lowers_range_map_filter_without_intermediate_hofs () =
  let fused = P.fuse_expr (range_map_filter_expr ()) in
  Alcotest.(check int) "one fused loop" 1 (count_for fused);
  Alcotest.(check int) "no range call" 0 (count_user_call "range" fused);
  Alcotest.(check int) "no map call" 0 (count_user_call "map" fused);
  Alcotest.(check int) "no filter call" 0 (count_user_call "filter" fused);
  Alcotest.(check int)
    "one result allocation" 1
    (count_intrinsic "list_alloc" fused)

let test_lowers_range_map_collect_without_intermediate_hofs () =
  let fused = P.fuse_expr (range_map_collect_expr ()) in
  Alcotest.(check int) "one fused loop" 1 (count_for fused);
  Alcotest.(check int) "no range call" 0 (count_user_call "range" fused);
  Alcotest.(check int) "no map call" 0 (count_user_call "map" fused);
  Alcotest.(check int)
    "one result allocation" 1
    (count_intrinsic "list_alloc" fused);
  Alcotest.(check int)
    "one transfer store" 1
    (count_intrinsic "list_set_owned" fused)

let test_lowers_range_filter_length_without_materialized_range () =
  let fused = P.fuse_expr (range_filter_length_expr ()) in
  Alcotest.(check int) "one fused loop" 1 (count_for fused);
  Alcotest.(check int) "no range call" 0 (count_user_call "range" fused);
  Alcotest.(check int) "no filter call" 0 (count_user_call "filter" fused);
  Alcotest.(check int) "no length call" 0 (count_user_call "length" fused);
  Alcotest.(check int)
    "no result allocation" 0
    (count_intrinsic "list_alloc" fused)

let test_lowers_range_filter_map_fold_without_materialized_range () =
  let fused = P.fuse_expr (range_filter_map_fold_expr ()) in
  Alcotest.(check int) "one fused loop" 1 (count_for fused);
  Alcotest.(check int) "no range call" 0 (count_user_call "range" fused);
  Alcotest.(check int) "no filter call" 0 (count_user_call "filter" fused);
  Alcotest.(check int) "no map call" 0 (count_user_call "map" fused);
  Alcotest.(check int) "no fold_left call" 0 (count_user_call "fold_left" fused);
  Alcotest.(check int)
    "no result allocation" 0
    (count_intrinsic "list_alloc" fused)

let test_lowers_range_filter_map_hof_fold_without_materialized_range () =
  let fused = P.fuse_expr (range_filter_map_hof_fold_expr ()) in
  Alcotest.(check int) "one fused loop" 1 (count_for fused);
  Alcotest.(check int) "no range call" 0 (count_user_call "range" fused);
  Alcotest.(check int)
    "no filter_map call" 0
    (count_user_call "filter_map" fused);
  Alcotest.(check int) "no fold_left call" 0 (count_user_call "fold_left" fused);
  Alcotest.(check int)
    "no result allocation" 0
    (count_intrinsic "list_alloc" fused);
  Alcotest.(check int)
    "compiled option match, not raw match arms" 1
    (fold_tree
       (fun acc node ->
         match node.desc with
         | CMatch _ -> acc + 1
         | CMatchArms _ -> Alcotest.fail "fusion must not introduce CMatchArms"
         | _ -> acc)
       0 fused)

let test_lowers_range_map_float_filter_without_intermediate_hofs () =
  let fused = P.fuse_expr (range_map_float_filter_expr ()) in
  Alcotest.(check int) "one fused loop" 1 (count_for fused);
  Alcotest.(check int) "no range call" 0 (count_user_call "range" fused);
  Alcotest.(check int) "no map call" 0 (count_user_call "map" fused);
  Alcotest.(check int) "no filter call" 0 (count_user_call "filter" fused);
  Alcotest.(check int)
    "one result allocation" 1
    (count_intrinsic "list_alloc" fused);
  Alcotest.(check int)
    "one transfer store" 1
    (count_intrinsic "list_set_owned" fused)

let test_lowers_list_filter_map_collect_to_borrow_handoff () =
  let fused = P.fuse_expr (filter_map_collect_expr ()) in
  Alcotest.(check int) "one handoff" 1 (count_list_handoff BorrowFresh fused);
  Alcotest.(check int)
    "no consuming handoff before reuse" 0
    (count_list_handoff ConsumeReuse fused);
  Alcotest.(check int) "no filter call" 0 (count_user_call "filter" fused);
  Alcotest.(check int) "no map call" 0 (count_user_call "map" fused);
  Alcotest.(check int)
    "no raw list_alloc in fusion output" 0
    (count_intrinsic "list_alloc" fused);
  Alcotest.(check int)
    "handoff uses overwrite-aware store" 1
    (count_intrinsic "list_handoff_set_owned" fused);
  Alcotest.(check int)
    "handoff does not use generic store" 0
    (count_intrinsic "list_set_owned" fused)

let test_lowers_single_filter_collect_to_borrow_handoff () =
  let fused = P.fuse_expr (filter_collect_expr ()) in
  Alcotest.(check int) "one handoff" 1 (count_list_handoff BorrowFresh fused);
  Alcotest.(check int)
    "no consuming handoff before reuse" 0
    (count_list_handoff ConsumeReuse fused);
  Alcotest.(check int) "no filter call" 0 (count_user_call "filter" fused);
  Alcotest.(check int)
    "no raw list_alloc in fusion output" 0
    (count_intrinsic "list_alloc" fused);
  Alcotest.(check int)
    "handoff uses overwrite-aware store" 1
    (count_intrinsic "list_handoff_set_owned" fused)

let test_lowers_single_map_collect_to_borrow_handoff () =
  let fused = P.fuse_expr (map_collect_expr ()) in
  Alcotest.(check int) "one handoff" 1 (count_list_handoff BorrowFresh fused);
  Alcotest.(check int)
    "no consuming handoff before reuse" 0
    (count_list_handoff ConsumeReuse fused);
  Alcotest.(check int) "no map call" 0 (count_user_call "map" fused);
  Alcotest.(check int)
    "no raw list_alloc in fusion output" 0
    (count_intrinsic "list_alloc" fused);
  Alcotest.(check int)
    "handoff uses overwrite-aware store" 1
    (count_intrinsic "list_handoff_set_owned" fused)

let test_lowers_list_map_filter_collect_to_borrow_handoff () =
  let fused = P.fuse_expr (map_filter_collect_expr ()) in
  Alcotest.(check int) "one handoff" 1 (count_list_handoff BorrowFresh fused);
  Alcotest.(check int)
    "no consuming handoff before reuse" 0
    (count_list_handoff ConsumeReuse fused);
  Alcotest.(check int) "no map call" 0 (count_user_call "map" fused);
  Alcotest.(check int) "no filter call" 0 (count_user_call "filter" fused);
  Alcotest.(check int)
    "no raw list_alloc in fusion output" 0
    (count_intrinsic "list_alloc" fused);
  Alcotest.(check int)
    "handoff uses overwrite-aware store" 1
    (count_intrinsic "list_handoff_set_owned" fused);
  Alcotest.(check int)
    "handoff does not use generic store" 0
    (count_intrinsic "list_set_owned" fused)

let test_lowers_long_map_filter_map_collect_to_borrow_handoff () =
  let fused = P.fuse_expr (map_filter_map_collect_expr ()) in
  Alcotest.(check int) "one handoff" 1 (count_list_handoff BorrowFresh fused);
  Alcotest.(check int) "no map call" 0 (count_user_call "map" fused);
  Alcotest.(check int) "no filter call" 0 (count_user_call "filter" fused);
  Alcotest.(check int)
    "no raw list_alloc in fusion output" 0
    (count_intrinsic "list_alloc" fused);
  Alcotest.(check int)
    "handoff uses overwrite-aware store" 1
    (count_intrinsic "list_handoff_set_owned" fused)

let test_lowers_filter_map_hof_map_collect_to_borrow_handoff () =
  let fused = P.fuse_expr (filter_map_hof_map_collect_expr ()) in
  Alcotest.(check int) "one handoff" 1 (count_list_handoff BorrowFresh fused);
  Alcotest.(check int) "no map call" 0 (count_user_call "map" fused);
  Alcotest.(check int)
    "no filter_map call" 0
    (count_user_call "filter_map" fused);
  Alcotest.(check int)
    "handoff uses overwrite-aware store" 1
    (count_intrinsic "list_handoff_set_owned" fused);
  Alcotest.(check int)
    "compiled option match, not raw match arms" 1
    (fold_tree
       (fun acc node ->
         match node.desc with
         | CMatch _ -> acc + 1
         | CMatchArms _ -> Alcotest.fail "fusion must not introduce CMatchArms"
         | _ -> acc)
       0 fused)

let test_lowers_float_filter_map_fold_without_intermediate_hofs () =
  let fused = P.fuse_expr (float_filter_map_fold_expr ()) in
  Alcotest.(check int) "one fused loop" 1 (count_for fused);
  Alcotest.(check int) "no filter call" 0 (count_user_call "filter" fused);
  Alcotest.(check int) "no map call" 0 (count_user_call "map" fused);
  Alcotest.(check int) "no fold_left call" 0 (count_user_call "fold_left" fused);
  Alcotest.(check int)
    "no list allocation for terminal fold" 0
    (count_intrinsic "list_alloc" fused)

let test_lowers_float_filter_map_collect_to_borrow_handoff () =
  let fused = P.fuse_expr (float_filter_map_collect_expr ()) in
  Alcotest.(check int) "one handoff" 1 (count_list_handoff BorrowFresh fused);
  Alcotest.(check int)
    "no consuming handoff before reuse" 0
    (count_list_handoff ConsumeReuse fused);
  Alcotest.(check int) "no filter call" 0 (count_user_call "filter" fused);
  Alcotest.(check int) "no map call" 0 (count_user_call "map" fused);
  Alcotest.(check int)
    "handoff uses overwrite-aware store" 1
    (count_intrinsic "list_handoff_set_owned" fused)

let test_does_not_fuse_heap_boxed_int128_pipeline () =
  let fused = P.fuse_expr (int128_filter_map_fold_expr ()) in
  Alcotest.(check int) "keeps filter call" 1 (count_user_call "filter" fused);
  Alcotest.(check int) "keeps map call" 1 (count_user_call "map" fused);
  Alcotest.(check int)
    "keeps fold_left call" 1
    (count_user_call "fold_left" fused);
  Alcotest.(check int) "no fused loop" 0 (count_for fused)

let test_lowers_string_filter_map_collect_to_borrow_handoff () =
  let fused = P.fuse_expr (string_filter_map_collect_expr ()) in
  Alcotest.(check int) "one handoff" 1 (count_list_handoff BorrowFresh fused);
  Alcotest.(check int)
    "no consuming handoff before reuse" 0
    (count_list_handoff ConsumeReuse fused);
  Alcotest.(check int) "no filter call" 0 (count_user_call "filter" fused);
  Alcotest.(check int) "no map call" 0 (count_user_call "map" fused);
  Alcotest.(check int)
    "handoff uses overwrite-aware store" 1
    (count_intrinsic "list_handoff_set_owned" fused);
  Alcotest.(check int)
    "borrowed source element is not let-bound" 0
    (fold_tree
       (fun acc node ->
         match node.desc with
         | CLet
             ( {
                 bind_var;
                 bind_ty = TyNamed ("String", []);
                 bind_rhs = { desc = CUnbox _; _ };
                 _;
               },
               _ )
           when String.starts_with ~prefix:"__pipe_elem_" bind_var.vname ->
             acc + 1
         | _ -> acc)
       0 fused)

let test_lowers_single_string_filter_collect_to_borrow_handoff () =
  let fused = P.fuse_expr (string_filter_collect_expr ()) in
  Alcotest.(check int) "one handoff" 1 (count_list_handoff BorrowFresh fused);
  Alcotest.(check int) "no filter call" 0 (count_user_call "filter" fused);
  Alcotest.(check int)
    "borrowed source slot uses move-or-retain handoff store" 1
    (count_intrinsic "list_handoff_set_source_slot" fused);
  Alcotest.(check int)
    "borrowed source slot is not transferred as owned" 0
    (count_intrinsic "list_handoff_set_owned" fused);
  Alcotest.(check int)
    "borrowed source element is not let-bound" 0
    (fold_tree
       (fun acc node ->
         match node.desc with
         | CLet
             ( {
                 bind_var;
                 bind_ty = TyNamed ("String", []);
                 bind_rhs = { desc = CUnbox _; _ };
                 _;
               },
               _ )
           when String.starts_with ~prefix:"__pipe_elem_" bind_var.vname ->
             acc + 1
         | _ -> acc)
       0 fused)

let test_lowers_single_string_map_collect_to_borrow_handoff () =
  let fused = P.fuse_expr (string_map_collect_expr ()) in
  Alcotest.(check int) "one handoff" 1 (count_list_handoff BorrowFresh fused);
  Alcotest.(check int) "no map call" 0 (count_user_call "map" fused);
  Alcotest.(check int)
    "handoff uses overwrite-aware store" 1
    (count_intrinsic "list_handoff_set_owned" fused);
  Alcotest.(check int)
    "borrowed source element is not let-bound" 0
    (fold_tree
       (fun acc node ->
         match node.desc with
         | CLet
             ( {
                 bind_var;
                 bind_ty = TyNamed ("String", []);
                 bind_rhs = { desc = CUnbox _; _ };
                 _;
               },
               _ )
           when String.starts_with ~prefix:"__pipe_elem_" bind_var.vname ->
             acc + 1
         | _ -> acc)
       0 fused)

let test_lowers_managed_filter_map_hof_collect_to_borrow_handoff () =
  let fused = P.fuse_expr (string_filter_map_hof_collect_expr ()) in
  Alcotest.(check int) "one handoff" 1 (count_list_handoff BorrowFresh fused);
  Alcotest.(check int)
    "filter_map call lowered" 0
    (count_user_call "filter_map" fused);
  Alcotest.(check int)
    "payload transfers through ownership-aware store" 1
    (count_intrinsic "list_handoff_set_owned" fused);
  Alcotest.(check int)
    "payload is not a source slot" 0
    (count_intrinsic "list_handoff_set_source_slot" fused);
  Alcotest.(check int)
    "compiled option match, not raw match arms" 1
    (fold_tree
       (fun acc node ->
         match node.desc with
         | CMatch _ -> acc + 1
         | CMatchArms _ -> Alcotest.fail "fusion must not introduce CMatchArms"
         | _ -> acc)
       0 fused)

let test_lowers_managed_filter_map_hof_map_collect_to_borrow_handoff () =
  let fused = P.fuse_expr (string_filter_map_hof_map_collect_expr ()) in
  Alcotest.(check int) "one handoff" 1 (count_list_handoff BorrowFresh fused);
  Alcotest.(check int)
    "filter_map call lowered" 0
    (count_user_call "filter_map" fused);
  Alcotest.(check int) "map call lowered" 0 (count_user_call "map" fused);
  Alcotest.(check int)
    "mapped payload transfers through ownership-aware store" 1
    (count_intrinsic "list_handoff_set_owned" fused);
  Alcotest.(check int)
    "mapped payload is not a source slot" 0
    (count_intrinsic "list_handoff_set_source_slot" fused);
  Alcotest.(check int)
    "compiled option match, not raw match arms" 1
    (fold_tree
       (fun acc node ->
         match node.desc with
         | CMatch _ -> acc + 1
         | CMatchArms _ -> Alcotest.fail "fusion must not introduce CMatchArms"
         | _ -> acc)
       0 fused)

let test_lowers_long_string_map_filter_map_collect_to_borrow_handoff () =
  let fused = P.fuse_expr (string_map_filter_map_collect_expr ()) in
  Alcotest.(check int) "one handoff" 1 (count_list_handoff BorrowFresh fused);
  Alcotest.(check int) "no map call" 0 (count_user_call "map" fused);
  Alcotest.(check int) "no filter call" 0 (count_user_call "filter" fused);
  Alcotest.(check int)
    "handoff uses overwrite-aware store" 1
    (count_intrinsic "list_handoff_set_owned" fused);
  Alcotest.(check int)
    "borrowed source element is not let-bound" 0
    (fold_tree
       (fun acc node ->
         match node.desc with
         | CLet
             ( {
                 bind_var;
                 bind_ty = TyNamed ("String", []);
                 bind_rhs = { desc = CUnbox _; _ };
                 _;
               },
               _ )
           when String.starts_with ~prefix:"__pipe_elem_" bind_var.vname ->
             acc + 1
         | _ -> acc)
       0 fused)

let test_lowers_string_filter_map_length_without_materialized_list () =
  let fused = P.fuse_expr (string_filter_map_length_expr ()) in
  Alcotest.(check int) "one fused loop" 1 (count_for fused);
  Alcotest.(check int) "no filter call" 0 (count_user_call "filter" fused);
  Alcotest.(check int) "no map call" 0 (count_user_call "map" fused);
  Alcotest.(check int) "no length call" 0 (count_user_call "length" fused);
  Alcotest.(check int)
    "no materialized result handoff" 0
    (count_list_handoff BorrowFresh fused);
  Alcotest.(check int)
    "no result list allocation" 0
    (count_intrinsic "list_alloc" fused);
  Alcotest.(check int)
    "discarded mapped string is bound for ownership" 1
    (fold_tree
       (fun acc node ->
         match node.desc with
         | CLet
             ( {
                 bind_var;
                 bind_ty = TyNamed ("String", []);
                 bind_rhs = { desc = CCall (CKClosure, _, _); _ };
                 _;
               },
               _ )
           when String.starts_with ~prefix:"__pipe_mapped_" bind_var.vname ->
             acc + 1
         | _ -> acc)
       0 fused);
  Alcotest.(check int)
    "borrowed source element is not let-bound" 0
    (fold_tree
       (fun acc node ->
         match node.desc with
         | CLet
             ( {
                 bind_var;
                 bind_ty = TyNamed ("String", []);
                 bind_rhs = { desc = CUnbox _; _ };
                 _;
               },
               _ )
           when String.starts_with ~prefix:"__pipe_elem_" bind_var.vname ->
             acc + 1
         | _ -> acc)
       0 fused)

let test_lowers_string_filter_length_without_materialized_list () =
  let fused = P.fuse_expr (string_filter_length_expr ()) in
  Alcotest.(check int) "one fused loop" 1 (count_for fused);
  Alcotest.(check int) "no filter call" 0 (count_user_call "filter" fused);
  Alcotest.(check int) "no length call" 0 (count_user_call "length" fused);
  Alcotest.(check int)
    "no materialized result handoff" 0
    (count_list_handoff BorrowFresh fused);
  Alcotest.(check int)
    "no result list allocation" 0
    (count_intrinsic "list_alloc" fused);
  Alcotest.(check int)
    "borrowed source element is not let-bound" 0
    (fold_tree
       (fun acc node ->
         match node.desc with
         | CLet
             ( {
                 bind_var;
                 bind_ty = TyNamed ("String", []);
                 bind_rhs = { desc = CUnbox _; _ };
                 _;
               },
               _ )
           when String.starts_with ~prefix:"__pipe_elem_" bind_var.vname ->
             acc + 1
         | _ -> acc)
       0 fused)

let test_lowers_string_map_filter_length_without_materialized_list () =
  let fused = P.fuse_expr (string_map_filter_length_expr ()) in
  Alcotest.(check int) "one fused loop" 1 (count_for fused);
  Alcotest.(check int) "no map call" 0 (count_user_call "map" fused);
  Alcotest.(check int) "no filter call" 0 (count_user_call "filter" fused);
  Alcotest.(check int) "no length call" 0 (count_user_call "length" fused);
  Alcotest.(check int)
    "no materialized result handoff" 0
    (count_list_handoff BorrowFresh fused);
  Alcotest.(check int)
    "no result list allocation" 0
    (count_intrinsic "list_alloc" fused);
  Alcotest.(check int)
    "borrowed source element is not let-bound" 0
    (fold_tree
       (fun acc node ->
         match node.desc with
         | CLet
             ( {
                 bind_var;
                 bind_ty = TyNamed ("String", []);
                 bind_rhs = { desc = CUnbox _; _ };
                 _;
               },
               _ )
           when String.starts_with ~prefix:"__pipe_elem_" bind_var.vname ->
             acc + 1
         | _ -> acc)
       0 fused)

let test_lowers_long_string_map_filter_map_length_without_materialized_list () =
  let fused = P.fuse_expr (string_map_filter_map_length_expr ()) in
  Alcotest.(check int) "one fused loop" 1 (count_for fused);
  Alcotest.(check int) "no map call" 0 (count_user_call "map" fused);
  Alcotest.(check int) "no filter call" 0 (count_user_call "filter" fused);
  Alcotest.(check int) "no length call" 0 (count_user_call "length" fused);
  Alcotest.(check int)
    "no result list allocation" 0
    (count_intrinsic "list_alloc" fused);
  Alcotest.(check int)
    "borrowed source element is not let-bound" 0
    (fold_tree
       (fun acc node ->
         match node.desc with
         | CLet
             ( {
                 bind_var;
                 bind_ty = TyNamed ("String", []);
                 bind_rhs = { desc = CUnbox _; _ };
                 _;
               },
               _ )
           when String.starts_with ~prefix:"__pipe_elem_" bind_var.vname ->
             acc + 1
         | _ -> acc)
       0 fused)

let test_lowers_trait_resolved_string_map_filter_map_length_without_materialized_list
    () =
  let fused = P.fuse_expr (string_trait_map_filter_map_length_expr ()) in
  Alcotest.(check int) "one fused loop" 1 (count_for fused);
  Alcotest.(check int) "no map call" 0 (count_user_call "map" fused);
  Alcotest.(check int) "no filter call" 0 (count_user_call "filter" fused);
  Alcotest.(check int)
    "no materialized result handoff" 0
    (count_list_handoff BorrowFresh fused);
  Alcotest.(check int)
    "borrowed source element is not let-bound" 0
    (fold_tree
       (fun acc node ->
         match node.desc with
         | CLet
             ( {
                 bind_var;
                 bind_ty = TyNamed ("String", []);
                 bind_rhs = { desc = CUnbox _; _ };
                 _;
               },
               _ )
           when String.starts_with ~prefix:"__pipe_elem_" bind_var.vname ->
             acc + 1
         | _ -> acc)
       0 fused)

let test_lowers_stack_option_filter_map_collect_to_borrow_handoff () =
  let fused = P.fuse_expr (option_filter_map_collect_expr ()) in
  Alcotest.(check int) "one handoff" 1 (count_list_handoff BorrowFresh fused);
  Alcotest.(check int) "no filter call" 0 (count_user_call "filter" fused);
  Alcotest.(check int) "no map call" 0 (count_user_call "map" fused);
  Alcotest.(check int)
    "handoff uses overwrite-aware store" 1
    (count_intrinsic "list_handoff_set_owned" fused);
  Alcotest.(check int)
    "stack option source element is bound as an unmanaged value" 1
    (fold_tree
       (fun acc node ->
         match node.desc with
         | CLet
             ( {
                 bind_var;
                 bind_ty = TyNamed ("Option", [ TyNamed ("Int", []) ]);
                 bind_rhs = { desc = CUnbox _; _ };
                 _;
               },
               _ )
           when String.starts_with ~prefix:"__pipe_elem_" bind_var.vname ->
             acc + 1
         | _ -> acc)
       0 fused)

let test_lowers_registered_heap_record_filter_map_collect_to_borrow_handoff () =
  let reg = Blorp.Codegen_types.create_registry () in
  Blorp.Codegen_types.register_heap_record_type reg "Widget"
    ~destructor:Blorp.Codegen_types.ArcReleaseOnly;
  let model = Blorp.Core_collection_producer.model_of_registry reg in
  let fused = P.fuse_expr ~model (widget_filter_map_collect_expr ()) in
  Alcotest.(check int) "one handoff" 1 (count_list_handoff BorrowFresh fused);
  Alcotest.(check int) "no filter call" 0 (count_user_call "filter" fused);
  Alcotest.(check int) "no map call" 0 (count_user_call "map" fused);
  Alcotest.(check int)
    "borrowed heap-record source element is not let-bound" 0
    (fold_tree
       (fun acc node ->
         match node.desc with
         | CLet
             ( {
                 bind_var;
                 bind_ty = TyNamed ("Widget", []);
                 bind_rhs = { desc = CUnbox _; _ };
                 _;
               },
               _ )
           when String.starts_with ~prefix:"__pipe_elem_" bind_var.vname ->
             acc + 1
         | _ -> acc)
       0 fused)

let plan_or_fail expr =
  match P.plan_of_expr expr with
  | Some plan -> plan
  | None -> Alcotest.fail "expected pipeline plan"

let test_collect_policy_is_explicit_and_layout_backed () =
  let widget_plan = plan_or_fail (widget_filter_map_collect_expr ()) in
  Alcotest.(check bool)
    "unknown user layout has no collect policy" true
    (P.collect_policy_for_plan Blorp.Core_collection_producer.default_model
       widget_plan
    = None);
  let reg = Blorp.Codegen_types.create_registry () in
  Blorp.Codegen_types.register_heap_record_type reg "Widget"
    ~destructor:Blorp.Codegen_types.ArcReleaseOnly;
  let model = Blorp.Core_collection_producer.model_of_registry reg in
  (match P.collect_policy_for_plan model widget_plan with
  | Some
      {
        Blorp.Core_collection_producer.source_access = BorrowManagedAlias;
        result_elem_ty = TyNamed ("Widget", []);
        filter_map_payload_policy = NoFilterMapPayload;
      } ->
      ()
  | Some _ -> Alcotest.fail "expected borrowed managed Widget collect policy"
  | None -> Alcotest.fail "expected registered Widget collect policy");
  let int128_plan = plan_or_fail (int128_filter_map_collect_expr ()) in
  Alcotest.(check bool)
    "arc-boxed scalar storage has no collect policy" true
    (P.collect_policy_for_plan model int128_plan = None);
  let filter_map_plan = plan_or_fail (string_filter_map_hof_collect_expr ()) in
  match
    P.collect_policy_for_plan Blorp.Core_collection_producer.default_model
      filter_map_plan
  with
  | Some
      {
        Blorp.Core_collection_producer.source_access = BorrowManagedAlias;
        result_elem_ty = TyNamed ("String", []);
        filter_map_payload_policy = BorrowedPayloadAliasFromOwnedOption;
      } ->
      ()
  | Some _ ->
      Alcotest.fail
        "expected explicit borrowed filter_map payload collect policy"
  | None -> Alcotest.fail "expected managed filter_map collect policy"

let test_collect_policy_uses_layout_canonical_types () =
  let reg = Blorp.Codegen_types.create_registry () in
  Hashtbl.replace reg.type_aliases "Count" ([], ty_int);
  let model = Blorp.Core_collection_producer.model_of_registry reg in
  let plan = plan_or_fail (alias_to_int_map_collect_expr ()) in
  match P.collect_policy_for_plan model plan with
  | Some
      {
        Blorp.Core_collection_producer.source_access = BindUnboxedValue;
        result_elem_ty = TyNamed ("Int", []);
        filter_map_payload_policy = NoFilterMapPayload;
      } ->
      ()
  | Some _ -> Alcotest.fail "expected alias-backed unboxed collect policy"
  | None ->
      Alcotest.fail
        "alias to Int should not make a layout-backed collect policy ineligible"

let test_list_pipeline_rejects_empty_source_plan () =
  Alcotest.(check bool)
    "bare list source is not a fusible pipeline plan" true
    (LP.plan_of_expr (cvar "xs" list_int) = None)

let test_list_pipeline_exposes_nonempty_stages () =
  match LP.plan_of_expr (filter_map_fold_expr ()) with
  | Some plan -> (
      match (plan.source, LP.stages plan, plan.sink) with
      | LP.SourceList _, [ LP.StageFilter _; LP.StageMap _ ], LP.SinkFold _ ->
          ()
      | _ -> Alcotest.fail "unexpected ListPipeline shape")
  | None -> Alcotest.fail "expected explicit ListPipeline plan"

let test_list_pipeline_recognizes_compiler_owned_pure_suffix () =
  Alcotest.(check (option string))
    "pure monomorphized list function" (Some "filter")
    (LP.base_list_func_name "std_list__filter__pure__mono_Int")

let suite =
  [
    ( "recognition",
      [
        Alcotest.test_case "filter_map_fold" `Quick
          test_recognizes_filter_map_fold;
        Alcotest.test_case "filter_map_hof_fold" `Quick
          test_recognizes_filter_map_hof_fold;
        Alcotest.test_case "filter_map_hof_collect" `Quick
          test_recognizes_filter_map_hof_collect;
        Alcotest.test_case "range_map_filter" `Quick
          test_recognizes_range_map_filter;
        Alcotest.test_case "rejects_materialized_let" `Quick
          test_rejects_materialized_let;
        Alcotest.test_case "rejects_barriers" `Quick test_rejects_barriers;
      ] );
    ( "lowering",
      [
        Alcotest.test_case "filter_map_fold_no_intermediate_hofs" `Quick
          test_lowers_filter_map_fold_without_intermediate_hofs;
        Alcotest.test_case "bare_fold_borrows_source" `Quick
          test_lowers_bare_fold_with_borrowed_source;
        Alcotest.test_case "no_capture_callback_resource_scope_binding" `Quick
          test_no_capture_callback_respects_resource_scope_binding;
        Alcotest.test_case "filter_map_fold_borrows_source" `Quick
          test_lowers_filter_map_fold_with_borrowed_source;
        Alcotest.test_case "filter_map_length_no_materialized_list" `Quick
          test_lowers_filter_map_length_without_materialized_list;
        Alcotest.test_case "filter_length_no_materialized_list" `Quick
          test_lowers_filter_length_without_materialized_list;
        Alcotest.test_case "map_filter_length_no_materialized_list" `Quick
          test_lowers_map_filter_length_without_materialized_list;
        Alcotest.test_case "long_map_filter_map_length_no_materialized_list"
          `Quick
          test_lowers_long_map_filter_map_length_without_materialized_list;
        Alcotest.test_case "long_filter_map_map_fold_no_intermediate_hofs"
          `Quick test_lowers_long_filter_map_map_fold_without_intermediate_hofs;
        Alcotest.test_case "filter_map_hof_fold_no_result_allocation" `Quick
          test_lowers_filter_map_hof_fold_without_result_allocation;
        Alcotest.test_case "filter_map_hof_collect_no_hof_call" `Quick
          test_lowers_filter_map_hof_collect_without_hof_call;
        Alcotest.test_case "impure_filter_map_fold_not_lowered" `Quick
          test_does_not_lower_impure_filter_map_fold;
        Alcotest.test_case "impure_reducer_terminal_fold_not_lowered" `Quick
          test_does_not_lower_impure_reducer_terminal_fold;
        Alcotest.test_case "impure_filter_map_hof_collect_not_lowered" `Quick
          test_does_not_lower_impure_filter_map_hof_collect;
        Alcotest.test_case "impure_filter_map_collect_not_lowered" `Quick
          test_does_not_lower_impure_filter_map_collect;
        Alcotest.test_case "impure_range_map_filter_not_lowered" `Quick
          test_does_not_lower_impure_range_map_filter;
        Alcotest.test_case "range_map_filter_no_intermediate_hofs" `Quick
          test_lowers_range_map_filter_without_intermediate_hofs;
        Alcotest.test_case "range_map_collect_no_intermediate_hofs" `Quick
          test_lowers_range_map_collect_without_intermediate_hofs;
        Alcotest.test_case "range_filter_length_no_materialized_range" `Quick
          test_lowers_range_filter_length_without_materialized_range;
        Alcotest.test_case "range_filter_map_fold_no_materialized_range" `Quick
          test_lowers_range_filter_map_fold_without_materialized_range;
        Alcotest.test_case "range_filter_map_hof_fold_no_materialized_range"
          `Quick
          test_lowers_range_filter_map_hof_fold_without_materialized_range;
        Alcotest.test_case "range_map_float_filter_no_intermediate_hofs" `Quick
          test_lowers_range_map_float_filter_without_intermediate_hofs;
        Alcotest.test_case "list_filter_map_collect_borrow_handoff" `Quick
          test_lowers_list_filter_map_collect_to_borrow_handoff;
        Alcotest.test_case "single_filter_collect_borrow_handoff" `Quick
          test_lowers_single_filter_collect_to_borrow_handoff;
        Alcotest.test_case "single_map_collect_borrow_handoff" `Quick
          test_lowers_single_map_collect_to_borrow_handoff;
        Alcotest.test_case "list_map_filter_collect_borrow_handoff" `Quick
          test_lowers_list_map_filter_collect_to_borrow_handoff;
        Alcotest.test_case "long_map_filter_map_collect_borrow_handoff" `Quick
          test_lowers_long_map_filter_map_collect_to_borrow_handoff;
        Alcotest.test_case "filter_map_hof_map_collect_borrow_handoff" `Quick
          test_lowers_filter_map_hof_map_collect_to_borrow_handoff;
        Alcotest.test_case "float_filter_map_fold_no_intermediate_hofs" `Quick
          test_lowers_float_filter_map_fold_without_intermediate_hofs;
        Alcotest.test_case "float_filter_map_collect_borrow_handoff" `Quick
          test_lowers_float_filter_map_collect_to_borrow_handoff;
        Alcotest.test_case "int128_pipeline_not_fused" `Quick
          test_does_not_fuse_heap_boxed_int128_pipeline;
        Alcotest.test_case "string_filter_map_collect_borrow_handoff" `Quick
          test_lowers_string_filter_map_collect_to_borrow_handoff;
        Alcotest.test_case "single_string_filter_collect_borrow_handoff" `Quick
          test_lowers_single_string_filter_collect_to_borrow_handoff;
        Alcotest.test_case "single_string_map_collect_borrow_handoff" `Quick
          test_lowers_single_string_map_collect_to_borrow_handoff;
        Alcotest.test_case "managed_filter_map_hof_collect_borrow_handoff"
          `Quick test_lowers_managed_filter_map_hof_collect_to_borrow_handoff;
        Alcotest.test_case "managed_filter_map_hof_map_collect_borrow_handoff"
          `Quick
          test_lowers_managed_filter_map_hof_map_collect_to_borrow_handoff;
        Alcotest.test_case "long_string_map_filter_map_collect_borrow_handoff"
          `Quick
          test_lowers_long_string_map_filter_map_collect_to_borrow_handoff;
        Alcotest.test_case "string_filter_map_length_no_materialized_list"
          `Quick test_lowers_string_filter_map_length_without_materialized_list;
        Alcotest.test_case "string_filter_length_no_materialized_list" `Quick
          test_lowers_string_filter_length_without_materialized_list;
        Alcotest.test_case "string_map_filter_length_no_materialized_list"
          `Quick test_lowers_string_map_filter_length_without_materialized_list;
        Alcotest.test_case
          "long_string_map_filter_map_length_no_materialized_list" `Quick
          test_lowers_long_string_map_filter_map_length_without_materialized_list;
        Alcotest.test_case
          "trait_resolved_string_map_filter_map_length_no_materialized_list"
          `Quick
          test_lowers_trait_resolved_string_map_filter_map_length_without_materialized_list;
        Alcotest.test_case "stack_option_filter_map_collect_borrow_handoff"
          `Quick test_lowers_stack_option_filter_map_collect_to_borrow_handoff;
        Alcotest.test_case
          "registered_heap_record_filter_map_collect_borrow_handoff" `Quick
          test_lowers_registered_heap_record_filter_map_collect_to_borrow_handoff;
        Alcotest.test_case "collect_policy_is_explicit_and_layout_backed" `Quick
          test_collect_policy_is_explicit_and_layout_backed;
        Alcotest.test_case "collect_policy_uses_layout_canonical_types" `Quick
          test_collect_policy_uses_layout_canonical_types;
      ] );
    ( "list_pipeline",
      [
        Alcotest.test_case "rejects_empty_source_plan" `Quick
          test_list_pipeline_rejects_empty_source_plan;
        Alcotest.test_case "exposes_nonempty_stages" `Quick
          test_list_pipeline_exposes_nonempty_stages;
        Alcotest.test_case "recognizes_compiler_owned_pure_suffix" `Quick
          test_list_pipeline_recognizes_compiler_owned_pure_suffix;
      ] );
  ]
