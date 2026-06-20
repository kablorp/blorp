(** Blorp-owned prepared backend facade.

    OCaml still owns Core traversal, type/layout analysis, and child expression
    emission. C snippet shapes are served through the single compiler Blorp
    bridge so generated OCaml template manifests are not part of the production
    path. *)

open Core
open Core_emit_context

let render_arg = Core_emit_blorp_template.render_arg

let render_template op args =
  Compiler_blorp_bridge.render_via_command_exn
    ~renderer:Compiler_blorp_bridge.prepared_backend_renderer ~op args

let render_list_template op args =
  Compiler_blorp_bridge.render_via_command_exn
    ~renderer:Compiler_blorp_bridge.prepared_list_renderer ~op args

let emit_list_template ctx op args =
  Core_emit_context.emit ctx (render_list_template op args)

let render_tensor_template op args =
  Compiler_blorp_bridge.render_via_command_exn
    ~renderer:Compiler_blorp_bridge.prepared_tensor_renderer ~op args

let emit_tensor_template ctx op args =
  Core_emit_context.emit ctx (render_tensor_template op args)

let render_constructor_template op args =
  Compiler_blorp_bridge.render_via_command_exn
    ~renderer:Compiler_blorp_bridge.prepared_constructor_renderer ~op args

let render_tuple_template op args =
  Compiler_blorp_bridge.render_via_command_exn
    ~renderer:Compiler_blorp_bridge.prepared_tuple_renderer ~op args

let render_constructor_call ~callee ~argument_list =
  render_constructor_template "backend_constructor_call"
    [ callee; argument_list ]

let render_constructor_symbol ~name =
  render_constructor_template "backend_constructor_symbol" [ name ]

let render_constructor_nullable_none () =
  render_constructor_template "backend_constructor_nullable_none" []

let render_constructor_nullable_payload ~payload =
  render_constructor_template "backend_constructor_nullable_payload" [ payload ]

let render_stack_option_value ~option_type ~tag ~value =
  render_constructor_template "backend_constructor_stack_option_value"
    [ option_type; tag; value ]

let render_stack_option_void_statement ~option_type ~tag ~statement =
  render_constructor_template "backend_constructor_stack_option_void_statement"
    [ option_type; tag; statement ]

let render_stack_option_none ~option_type ~tag ~none_value =
  render_constructor_template "backend_constructor_stack_option_none"
    [ option_type; tag; none_value ]

let render_stack_result_payload ~result_type ~tag ~field ~payload ~release_mask
    =
  render_constructor_template "backend_constructor_stack_result_payload"
    [ result_type; tag; field; payload; release_mask ]

let render_tuple_name temp_seed =
  render_tuple_template "backend_tuple_name" [ temp_seed ]

let render_tuple_arg value = render_tuple_template "backend_tuple_arg" [ value ]

let render_tuple_construct ~arity ~args =
  render_tuple_template "backend_tuple_construct" [ arity; args ]

let render_tuple_retain_elem ~tuple ~index =
  render_tuple_template "backend_tuple_retain_elem" [ tuple; index ]

let render_tuple_construct_with_rc ~tuple ~arity ~args ~retain_statements
    ~release_mask =
  render_tuple_template "backend_tuple_construct_with_rc"
    [ tuple; arity; args; retain_statements; release_mask ]

let render_tuple_field_element ~tuple ~field =
  render_tuple_template "backend_tuple_field_element" [ tuple; field ]

let render_tuple_field_access ~tuple ~source ~read =
  render_tuple_template "backend_tuple_field_access" [ tuple; source; read ]

type elem_release_arg = NoElemRelease | ElemReleaseFn
type key_release_policy = KeepKey | ReleaseKey

type dict_constructor_call =
  | DictCtorGeneric
  | DictCtorString
  | DictCtorFloat
  | DictCtorCustom of {
      hash_fn : string;
      equals_fn : string;
      key_release : elem_release_arg;
    }

type dict_capacity_constructor_call =
  | DictWithCapacityGeneric of core
  | DictWithCapacityString of core
  | DictWithCapacityFloat of core
  | DictWithCapacityCustom of {
      capacity : core;
      hash_fn : string;
      equals_fn : string;
      key_release : elem_release_arg;
    }

type set_constructor_call =
  | SetCtorGeneric
  | SetCtorString
  | SetCtorFloat
  | SetCtorCustom of {
      hash_fn : string;
      equals_fn : string;
      elem_release : elem_release_arg;
    }

type channel_retaining_send_runtime =
  | ChannelSendRuntime
  | ChannelTrySendRuntime
  | ChannelTrySendStatusRuntime

type channel_retaining_send_timeout_runtime =
  | ChannelSendTimeoutRuntime
  | ChannelSendTimeoutStatusRuntime

type channel_retaining_send =
  | ChannelRetainingSendNoTimeout of {
      runtime : channel_retaining_send_runtime;
      result_type : string;
      channel : core;
      value : core;
    }
  | ChannelRetainingSendWithTimeout of {
      runtime : channel_retaining_send_timeout_runtime;
      result_type : string;
      channel : core;
      value : core;
      timeout : core;
    }

type channel_send_attempt_constructors = {
  accepted : string;
  would_block : string;
  sealed : string;
  timed_out : string;
}

type channel_send_attempt_value =
  | ChannelSendAttemptDirectValue of core
  | ChannelSendAttemptRetainedValue of core

type channel_send_attempt =
  | ChannelTrySendAttempt of {
      result_type : string;
      channel : core;
      value : channel_send_attempt_value;
      constructors : channel_send_attempt_constructors;
    }
  | ChannelSendTimeoutAttempt of {
      result_type : string;
      channel : core;
      value : channel_send_attempt_value;
      timeout : core;
      constructors : channel_send_attempt_constructors;
    }

type channel_recv_value_release_policy = KeepRecvValue | ReleaseRecvValue

type channel_recv_attempt_constructors = {
  value : string;
  sealed : string;
  empty : string;
}

type channel_recv_attempt =
  | ChannelTryRecvAttempt of {
      result_type : string;
      channel : core;
      release_policy : channel_recv_value_release_policy;
      value_constructor_takes_release_mask : bool;
      constructors : channel_recv_attempt_constructors;
    }
  | ChannelRecvTimeoutAttempt of {
      result_type : string;
      channel : core;
      timeout : core;
      release_policy : channel_recv_value_release_policy;
      value_constructor_takes_release_mask : bool;
      constructors : channel_recv_attempt_constructors;
    }

type list_store_runtime = ListSetRaw | ListHandoffSetOwned

let list_runtime_storage_args (layout : list_storage_layout) : string * string =
  match layout.lsl_slots with
  | ListPointerStorage ->
      ( render_list_template "list_storage_mode_pointer" [],
        render_list_template "list_element_size_pointer" [] )
  | ListInlineStorage width ->
      ( render_list_template "list_storage_mode_inline" [],
        string_of_int (inline_storage_width_bytes width) )
  | ListInlineStructStorage c_ty ->
      ( render_list_template "list_storage_mode_inline" [],
        render_list_template "list_element_size_inline_struct" [ c_ty ] )

let list_elem_release_arg ~loc layout =
  if
    list_storage_layout_requires_release_or_error ~phase:Core_error.Emit ~loc
      layout
  then render_list_template "list_element_release_fn" []
  else render_list_template "list_element_release_none" []

let render_list_temp_name temp_seed =
  render_list_template "list_construct_name" [ temp_seed ]

let render_list_alloc_call layout capacity_arg =
  match layout.lsl_slots with
  | ListPointerStorage ->
      render_list_template "list_alloc_pointer" [ capacity_arg ]
  | ListInlineStorage width ->
      let elem_size = string_of_int (inline_storage_width_bytes width) in
      render_list_template "list_alloc_inline" [ capacity_arg; elem_size ]
  | ListInlineStructStorage c_ty ->
      render_list_template "list_alloc_inline_struct" [ capacity_arg; c_ty ]

let render_list_alloc_with_release ~alloc_expr ~result_tmp =
  render_list_template "list_alloc_with_release" [ alloc_expr; result_tmp ]

let render_list_alloc_for_layout_capacity_arg ctx layout ~loc capacity_arg =
  let alloc_expr = render_list_alloc_call layout capacity_arg in
  if
    list_storage_layout_requires_release_or_error ~phase:Core_error.Emit ~loc
      layout
  then
    let result_tmp = render_list_temp_name (string_of_int (fresh_temp ctx)) in
    render_list_alloc_with_release ~alloc_expr ~result_tmp
  else alloc_expr

let emit_list_alloc_for_layout_capacity_arg ctx layout ~loc capacity_arg =
  emit ctx
    (render_list_alloc_for_layout_capacity_arg ctx layout ~loc capacity_arg)

let emit_list_alloc_for_layout ~emit_expr ctx layout ~loc capacity =
  let capacity_arg = render_arg ~emit_expr ctx capacity in
  emit_list_alloc_for_layout_capacity_arg ctx layout ~loc capacity_arg

let emit_list_alloc_for_type_capacity_arg ctx list_ty ~loc capacity_arg =
  let layout = Core_emit_layout.list_storage_layout_of_type ctx list_ty loc in
  emit_list_alloc_for_layout_capacity_arg ctx layout ~loc capacity_arg

let emit_list_alloc_for_type ~emit_expr ctx list_ty ~loc capacity =
  let capacity_arg = render_arg ~emit_expr ctx capacity in
  emit_list_alloc_for_type_capacity_arg ctx list_ty ~loc capacity_arg

let emit_list_runtime_get ~emit_expr ctx ~template_name list index =
  let list_arg = render_arg ~emit_expr ctx list in
  let index_arg = render_arg ~emit_expr ctx index in
  emit_list_template ctx template_name [ list_arg; index_arg ]

let emit_list_inline_get ~emit_expr ctx get width =
  let temp_seed = string_of_int (fresh_temp ctx) in
  let width_bytes = string_of_int (inline_storage_width_bytes width) in
  let template_name =
    match get.lg_bounds with
    | ListBoundsChecked -> "list_get_inline_checked"
    | ListBoundsProven -> "list_get_inline_proven"
  in
  let list_arg = render_arg ~emit_expr ctx get.lg_list in
  let index_arg = render_arg ~emit_expr ctx get.lg_index in
  emit_list_template ctx template_name
    [ list_arg; index_arg; temp_seed; width_bytes ]

let emit_list_inline_struct_dynamic_load ctx ~list_tmp ~idx_tmp ~out_tmp
    ~struct_ty ~bounds =
  let temp_seed = string_of_int (fresh_temp ctx) in
  let template_name =
    match bounds with
    | ListBoundsChecked -> "list_inline_struct_load_checked"
    | ListBoundsProven -> "list_inline_struct_load_proven"
  in
  emit_list_template ctx template_name
    [ list_tmp; idx_tmp; out_tmp; temp_seed; struct_ty ]

let render_list_inline_struct_unbox_list_name temp_seed =
  render_list_template "list_inline_struct_unbox_list_name" [ temp_seed ]

let render_list_inline_struct_unbox_index_name temp_seed =
  render_list_template "list_inline_struct_unbox_index_name" [ temp_seed ]

let render_list_inline_struct_unbox_out_name temp_seed =
  render_list_template "list_inline_struct_unbox_out_name" [ temp_seed ]

let emit_list_inline_struct_unbox_open ~emit_expr ctx ~list_tmp ~idx_tmp
    ~out_tmp ~struct_ty get =
  let list_arg = render_arg ~emit_expr ctx get.lg_list in
  let index_arg = render_arg ~emit_expr ctx get.lg_index in
  emit_list_template ctx "list_inline_struct_unbox_open"
    [ list_tmp; list_arg; idx_tmp; index_arg; struct_ty; out_tmp ];
  emit ctx " "

let emit_list_inline_struct_unbox_close ctx ~out_tmp =
  emit_list_template ctx "list_inline_struct_unbox_close" [ out_tmp ]

let emit_list_inline_struct_unbox_get ~emit_expr ctx get ~struct_ty =
  let temp_seed = string_of_int (fresh_temp ctx) in
  let list_tmp = render_list_inline_struct_unbox_list_name temp_seed in
  let idx_tmp = render_list_inline_struct_unbox_index_name temp_seed in
  let out_tmp = render_list_inline_struct_unbox_out_name temp_seed in
  emit_list_inline_struct_unbox_open ~emit_expr ctx ~list_tmp ~idx_tmp ~out_tmp
    ~struct_ty get;
  emit_list_inline_struct_dynamic_load ctx ~list_tmp ~idx_tmp ~out_tmp
    ~struct_ty ~bounds:get.lg_bounds;
  emit ctx " ";
  emit_list_inline_struct_unbox_close ctx ~out_tmp

let emit_list_inline_bits_load ctx ~list_tmp ~idx_tmp ~bits_tmp ~width =
  let width_bytes = string_of_int (inline_storage_width_bytes width) in
  emit_list_template ctx "list_inline_bits_load"
    [ list_tmp; idx_tmp; bits_tmp; width_bytes ]

let emit_list_inline_bits_store ~emit_expr ~emit_boxed ctx lst idx val_ width =
  let temp_seed = string_of_int (fresh_temp ctx) in
  let width_bytes = string_of_int (inline_storage_width_bytes width) in
  let list_arg = render_arg ~emit_expr ctx lst in
  let index_arg = render_arg ~emit_expr ctx idx in
  let value_arg = render_arg ~emit_expr:emit_boxed ctx val_ in
  emit_list_template ctx "list_inline_bits_store"
    [ list_arg; index_arg; value_arg; temp_seed; width_bytes ]

let emit_list_pointer_store ~emit_expr ~emit_boxed ctx runtime lst idx val_ =
  let list_arg = render_arg ~emit_expr ctx lst in
  let index_arg = render_arg ~emit_expr ctx idx in
  let value_arg = render_arg ~emit_expr:emit_boxed ctx val_ in
  let template_name =
    match runtime with
    | ListSetRaw -> "list_pointer_set_raw_store"
    | ListHandoffSetOwned -> "list_pointer_handoff_set_owned_store"
  in
  emit_list_template ctx template_name [ list_arg; index_arg; value_arg ]

let emit_list_inline_struct_store_template ~emit_expr ctx runtime lst idx val_
    ~struct_ty =
  let temp_seed = string_of_int (fresh_temp ctx) in
  let list_arg = render_arg ~emit_expr ctx lst in
  let index_arg = render_arg ~emit_expr ctx idx in
  let value_arg = render_arg ~emit_expr ctx val_ in
  let stack_result =
    Core_layout_type.is_stack_result_type ~reg:ctx.reg val_.ty
  in
  let template_name =
    match (runtime, stack_result) with
    | ListSetRaw, false -> "list_inline_struct_set_raw_store"
    | ListSetRaw, true -> "list_inline_struct_set_raw_store_stack_result"
    | ListHandoffSetOwned, false -> "list_inline_struct_handoff_set_owned_store"
    | ListHandoffSetOwned, true ->
        "list_inline_struct_handoff_set_owned_store_stack_result"
  in
  emit_list_template ctx template_name
    [ list_arg; index_arg; value_arg; temp_seed; struct_ty ]

let emit_list_store ~emit_expr ~emit_boxed ctx store_runtime lst idx val_ =
  let layout =
    Core_emit_layout.list_storage_layout_of_type ctx lst.ty lst.loc
  in
  match layout.lsl_slots with
  | ListInlineStructStorage c_ty ->
      emit_list_inline_struct_store_template ~emit_expr ctx store_runtime lst
        idx val_ ~struct_ty:c_ty
  | ListInlineStorage width ->
      emit_list_inline_bits_store ~emit_expr ~emit_boxed ctx lst idx val_ width
  | ListPointerStorage ->
      emit_list_pointer_store ~emit_expr ~emit_boxed ctx store_runtime lst idx
        val_

let list_swap_prefix_args ~emit_expr ctx lst left_index right_index =
  let temp_seed = string_of_int (fresh_temp ctx) in
  let list_arg = render_arg ~emit_expr ctx lst in
  let left_index_arg = render_arg ~emit_expr ctx left_index in
  let right_index_arg = render_arg ~emit_expr ctx right_index in
  (list_arg, left_index_arg, right_index_arg, temp_seed)

let emit_list_pointer_swap ~emit_expr ctx lst left_index right_index =
  let list_arg, left_index_arg, right_index_arg, temp_seed =
    list_swap_prefix_args ~emit_expr ctx lst left_index right_index
  in
  emit_list_template ctx "list_pointer_swap"
    [ list_arg; left_index_arg; right_index_arg; temp_seed ]

let emit_list_inline_bits_swap ~emit_expr ctx lst left_index right_index width =
  let list_arg, left_index_arg, right_index_arg, temp_seed =
    list_swap_prefix_args ~emit_expr ctx lst left_index right_index
  in
  let width_bytes = string_of_int (inline_storage_width_bytes width) in
  emit_list_template ctx "list_inline_bits_swap"
    [ list_arg; left_index_arg; right_index_arg; temp_seed; width_bytes ]

let emit_list_inline_struct_swap ~emit_expr ctx lst left_index right_index =
  let list_arg, left_index_arg, right_index_arg, temp_seed =
    list_swap_prefix_args ~emit_expr ctx lst left_index right_index
  in
  emit_list_template ctx "list_inline_struct_swap"
    [ list_arg; left_index_arg; right_index_arg; temp_seed ]

let emit_list_swap_slots ~emit_expr ctx lst left_index right_index =
  let layout =
    Core_emit_layout.list_storage_layout_of_type ctx lst.ty lst.loc
  in
  match layout.lsl_slots with
  | ListInlineStructStorage _ ->
      emit_list_inline_struct_swap ~emit_expr ctx lst left_index right_index
  | ListInlineStorage width ->
      emit_list_inline_bits_swap ~emit_expr ctx lst left_index right_index width
  | ListPointerStorage ->
      emit_list_pointer_swap ~emit_expr ctx lst left_index right_index

let emit_list_handoff_set_source_slot ~emit_expr ctx result out_idx source
    source_idx =
  let result_arg = render_arg ~emit_expr ctx result in
  let out_idx_arg = render_arg ~emit_expr ctx out_idx in
  let source_arg = render_arg ~emit_expr ctx source in
  let source_idx_arg = render_arg ~emit_expr ctx source_idx in
  emit_list_template ctx "list_handoff_set_source_slot"
    [ result_arg; out_idx_arg; source_arg; source_idx_arg ]

let emit_list_copy_span_uninit ~emit_expr ctx dst dst_start src src_start count
    =
  let dst_arg = render_arg ~emit_expr ctx dst in
  let dst_start_arg = render_arg ~emit_expr ctx dst_start in
  let src_arg = render_arg ~emit_expr ctx src in
  let src_start_arg = render_arg ~emit_expr ctx src_start in
  let count_arg = render_arg ~emit_expr ctx count in
  emit_list_template ctx "list_copy_span_uninit"
    [ dst_arg; dst_start_arg; src_arg; src_start_arg; count_arg ]

let emit_list_ensure_unique ~emit_expr ctx lst =
  let temp_seed = string_of_int (fresh_temp ctx) in
  let list_arg = render_arg ~emit_expr ctx lst in
  emit_list_template ctx "list_ensure_unique" [ list_arg; temp_seed ]

let emit_list_ensure_capacity ~emit_expr ctx lst cap =
  let temp_seed = string_of_int (fresh_temp ctx) in
  let list_arg = render_arg ~emit_expr ctx lst in
  let cap_arg = render_arg ~emit_expr ctx cap in
  emit_list_template ctx "list_ensure_capacity" [ list_arg; cap_arg; temp_seed ]

let emit_list_reuse_alloc ~emit_expr ctx lst cap =
  let list_arg = render_arg ~emit_expr ctx lst in
  let cap_arg = render_arg ~emit_expr ctx cap in
  emit_list_template ctx "list_reuse_alloc" [ list_arg; cap_arg ]

let emit_list_reuse_alloc_with_release ~emit_expr ctx lst cap =
  let temp_seed = string_of_int (fresh_temp ctx) in
  let list_arg = render_arg ~emit_expr ctx lst in
  let cap_arg = render_arg ~emit_expr ctx cap in
  emit_list_template ctx "list_reuse_alloc_with_release"
    [ list_arg; cap_arg; temp_seed ]

let emit_list_reuse_alloc_for_result ~emit_expr ctx result lst cap =
  let layout =
    Core_emit_layout.list_storage_layout_of_type ctx result.ty result.loc
  in
  if
    list_storage_layout_requires_release_or_error ~phase:Core_error.Emit
      ~loc:result.loc layout
  then emit_list_reuse_alloc_with_release ~emit_expr ctx lst cap
  else emit_list_reuse_alloc ~emit_expr ctx lst cap

let emit_list_retain_for ~emit_expr ~emit_boxed ctx lst value =
  let list_arg = render_arg ~emit_expr ctx lst in
  let value_arg = render_arg ~emit_expr:emit_boxed ctx value in
  emit_list_template ctx "list_retain_for" [ list_arg; value_arg ]

let emit_list_retain_for_noop ctx =
  emit_list_template ctx "list_retain_for_noop" []

let emit_list_retain_for_storage ~emit_expr ~emit_boxed ctx lst value =
  let layout =
    Core_emit_layout.list_storage_layout_of_type ctx lst.ty lst.loc
  in
  if
    list_storage_layout_requires_retain_or_error ~phase:Core_error.Emit
      ~loc:lst.loc layout
  then emit_list_retain_for ~emit_expr ~emit_boxed ctx lst value
  else emit_list_retain_for_noop ctx

let render_list_construct_init_elem_release ~list_tmp =
  render_list_template "list_construct_init_elem_release" [ list_tmp ]

let render_list_construct_name temp_seed = render_list_temp_name temp_seed

let render_list_construct ~list_tmp ~alloc_call ~statements =
  render_list_template "list_construct"
    [ list_tmp; alloc_call; String.concat " " statements ]

let emit_list_construct ctx ~list_tmp ~alloc_call ~statements =
  emit ctx (render_list_construct ~list_tmp ~alloc_call ~statements)

let render_list_construct_inline_struct_set ~emit_expr ctx ~list_tmp ~index
    ~struct_ty value =
  let temp_seed = string_of_int (Core_emit_context.fresh_temp ctx) in
  let value_arg = render_arg ~emit_expr ctx value in
  render_list_template "list_construct_inline_struct_set"
    [ list_tmp; string_of_int index; value_arg; temp_seed; struct_ty ]

let render_list_construct_set_len ~list_tmp ~len =
  render_list_template "list_construct_set_len" [ list_tmp; string_of_int len ]

let render_list_construct_append ~emit_boxed ctx ~list_tmp ~owned value =
  let value_arg = render_arg ~emit_expr:emit_boxed ctx value in
  let template_name =
    if owned then "list_construct_append_owned" else "list_construct_append"
  in
  render_list_template template_name [ list_tmp; value_arg ]

let emit_list_handoff_borrow_prefix ~emit_expr ctx ~source_ty_c ~source_c source
    capacity ~length_c ~release_fn_c ~result_ty_c ~result_c ~storage_mode_c
    ~elem_size_c ~out_c ~temp_seed =
  let source_arg = render_arg ~emit_expr ctx source in
  let capacity_arg = render_arg ~emit_expr ctx capacity in
  emit_list_template ctx "list_handoff_borrow_prefix"
    [
      source_ty_c;
      source_c;
      source_arg;
      capacity_arg;
      length_c;
      release_fn_c;
      result_ty_c;
      result_c;
      storage_mode_c;
      elem_size_c;
      out_c;
      temp_seed;
    ];
  emit ctx " "

let emit_list_handoff_reuse_prefix ~emit_expr ctx ~source_ty_c ~source_c source
    capacity ~length_c ~release_fn_c ~result_ty_c ~result_c ~storage_mode_c
    ~elem_size_c ~out_c ~temp_seed =
  let source_arg = render_arg ~emit_expr ctx source in
  let capacity_arg = render_arg ~emit_expr ctx capacity in
  emit_list_template ctx "list_handoff_reuse_prefix"
    [
      source_ty_c;
      source_c;
      source_arg;
      capacity_arg;
      length_c;
      release_fn_c;
      result_ty_c;
      result_c;
      storage_mode_c;
      elem_size_c;
      out_c;
      temp_seed;
    ];
  emit ctx " "

let emit_list_handoff_borrow_suffix ctx ~result_c ~out_c ~length_c =
  emit_list_template ctx "list_handoff_borrow_suffix"
    [ result_c; out_c; length_c ]

let emit_list_handoff_reuse_suffix ctx ~result_c ~out_c ~length_c ~source_c
    ~temp_seed =
  emit_list_template ctx "list_handoff_reuse_suffix"
    [ result_c; out_c; length_c; source_c; temp_seed ]

let render_list_construct_statements ~emit_expr ~emit_boxed ctx layout ~list_tmp
    ~elem_needs_release elems =
  match layout.lsl_slots with
  | ListInlineStructStorage c_ty ->
      let writes =
        List.mapi
          (fun i value ->
            render_list_construct_inline_struct_set ~emit_expr ctx ~list_tmp
              ~index:i ~struct_ty:c_ty value.bsv_box.box_value)
          elems
      in
      writes
      @ [ render_list_construct_set_len ~list_tmp ~len:(List.length elems) ]
  | ListPointerStorage | ListInlineStorage _ ->
      let init =
        if elem_needs_release then
          [ render_list_construct_init_elem_release ~list_tmp ]
        else []
      in
      let appends =
        List.map
          (fun value ->
            render_list_construct_append ~emit_boxed ctx ~list_tmp
              ~owned:(elem_needs_release && value.bsv_transfers_ownership)
              value)
          elems
      in
      init @ appends

let emit_list_get ~emit_expr (ctx : Core_emit_context.t) (get : list_get) : unit
    =
  match get.lg_layout.lsl_slots with
  | ListPointerStorage ->
      emit_list_runtime_get ~emit_expr ctx ~template_name:"list_get_pointer"
        get.lg_list get.lg_index
  | ListInlineStorage width -> emit_list_inline_get ~emit_expr ctx get width
  | ListInlineStructStorage _ ->
      emit_list_runtime_get ~emit_expr ctx ~template_name:"list_get_pointer"
        get.lg_list get.lg_index

let tensor_view_c_name v = Codegen_types.escape_c_ident (Var.to_c_name v)

type tensor_fill_value_policy = KeepFillValue | ReleaseFillValue

let tensor_runtime_storage_args (layout : tensor_storage_layout) :
    string * string =
  match layout.tsl_slots with
  | TensorRawScalarStorage TensorFloat64Elements ->
      ( render_tensor_template "tensor_storage_mode_f64" [],
        render_tensor_template "tensor_element_size_f64" [] )
  | TensorRawScalarStorage TensorFloat32Elements ->
      ( render_tensor_template "tensor_storage_mode_f32" [],
        render_tensor_template "tensor_element_size_f32" [] )
  | TensorRawScalarStorage TensorInt64Elements ->
      ( render_tensor_template "tensor_storage_mode_i64" [],
        render_tensor_template "tensor_element_size_i64" [] )
  | TensorInlineStructStorage c_ty ->
      ( render_tensor_template "tensor_storage_mode_inline" [],
        render_tensor_template "tensor_element_size_inline_struct" [ c_ty ] )
  | TensorPackedStorage _ | TensorWordStorage | TensorBoxedStorage ->
      ( render_tensor_template "tensor_storage_mode_pointer" [],
        render_tensor_template "tensor_element_size_pointer" [] )

let tensor_callback_result_encoding_arg (layout : tensor_storage_layout) :
    string =
  match layout.tsl_slots with
  | TensorInlineStructStorage _ ->
      render_tensor_template "tensor_callback_result_boxed_struct" []
  | TensorRawScalarStorage TensorFloat64Elements ->
      render_tensor_template "tensor_callback_result_boxed_float" []
  | TensorRawScalarStorage TensorFloat32Elements ->
      render_tensor_template "tensor_callback_result_boxed_float32" []
  | TensorRawScalarStorage TensorInt64Elements
  | TensorPackedStorage _ | TensorWordStorage | TensorBoxedStorage ->
      render_tensor_template "tensor_callback_result_bits" []

let render_tensor_alloc_call layout size_arg =
  match layout.tsl_slots with
  | TensorWordStorage | TensorBoxedStorage ->
      render_tensor_template "tensor_alloc_pointer" [ size_arg ]
  | TensorRawScalarStorage TensorInt64Elements ->
      render_tensor_template "tensor_alloc_i64" [ size_arg ]
  | TensorRawScalarStorage TensorFloat64Elements ->
      render_tensor_template "tensor_alloc_f64" [ size_arg ]
  | TensorRawScalarStorage TensorFloat32Elements ->
      render_tensor_template "tensor_alloc_f32" [ size_arg ]
  | TensorPackedStorage width ->
      let elem_size = Core.inline_storage_width_bytes width in
      render_tensor_template "tensor_alloc_packed"
        [ size_arg; string_of_int elem_size ]
  | TensorInlineStructStorage struct_ty ->
      render_tensor_template "tensor_alloc_sized" [ size_arg; struct_ty ]

let render_tensor_ranked_alloc_call layout ~first_dim ~total_dim =
  match layout.tsl_slots with
  | TensorWordStorage | TensorBoxedStorage ->
      render_tensor_template "tensor_ranked_alloc_pointer"
        [ first_dim; total_dim ]
  | TensorRawScalarStorage TensorInt64Elements ->
      render_tensor_template "tensor_ranked_alloc_i64" [ first_dim; total_dim ]
  | TensorRawScalarStorage TensorFloat64Elements ->
      render_tensor_template "tensor_ranked_alloc_f64" [ first_dim; total_dim ]
  | TensorRawScalarStorage TensorFloat32Elements ->
      render_tensor_template "tensor_ranked_alloc_f32" [ first_dim; total_dim ]
  | TensorPackedStorage width ->
      let elem_size = Core.inline_storage_width_bytes width in
      render_tensor_template "tensor_ranked_alloc_packed"
        [ first_dim; total_dim; string_of_int elem_size ]
  | TensorInlineStructStorage struct_ty ->
      render_tensor_template "tensor_ranked_alloc_sized"
        [ first_dim; total_dim; struct_ty ]

let render_tensor_fill_alloc_call layout ~first_dim ~total_dim loc =
  match layout.tsl_slots with
  | TensorRawScalarStorage _ | TensorPackedStorage _ ->
      render_tensor_ranked_alloc_call layout ~first_dim ~total_dim
  | TensorWordStorage | TensorBoxedStorage | TensorInlineStructStorage _ ->
      Core_error.errorf Core_error.Emit loc
        "unsupported tensor fill allocation layout"

let render_tensor_literal_alloc_call layout shape =
  match shape with
  | TensorStaticShape (first :: _ as dims) ->
      let total = List.fold_left ( * ) 1 dims in
      render_tensor_ranked_alloc_call layout ~first_dim:(string_of_int first)
        ~total_dim:(string_of_int total)
  | TensorStaticShape [] -> render_tensor_alloc_call layout "0"
  | TensorVectorLength n -> render_tensor_alloc_call layout (string_of_int n)

let render_tensor_literal_name temp_seed =
  render_tensor_template "tensor_literal_name" [ temp_seed ]

let render_tensor_literal_construct ~tensor_tmp ~alloc_call ~statements =
  render_tensor_template "tensor_literal_construct"
    [ tensor_tmp; alloc_call; String.concat " " statements ]

let emit_tensor_literal_construct ctx ~tensor_tmp ~alloc_call ~statements =
  Core_emit_context.emit ctx
    (render_tensor_literal_construct ~tensor_tmp ~alloc_call ~statements)

let render_tensor_literal_init_elem_release ~tensor_tmp =
  render_tensor_template "tensor_init_elem_release" [ tensor_tmp ]

let render_tensor_literal_write ~emit_expr ctx template_name ~tensor_tmp ~index
    value =
  let value_arg = render_arg ~emit_expr ctx value in
  render_tensor_template template_name
    [ tensor_tmp; string_of_int index; value_arg ]

let render_tensor_literal_f32_write ~emit_expr ctx ~tensor_tmp ~index value =
  render_tensor_literal_write ~emit_expr ctx "tensor_literal_write_f32"
    ~tensor_tmp ~index value

let render_tensor_literal_f64_write ~emit_expr ctx ~tensor_tmp ~index value =
  render_tensor_literal_write ~emit_expr ctx "tensor_literal_write_f64"
    ~tensor_tmp ~index value

let render_tensor_literal_i64_write ~emit_expr ctx ~tensor_tmp ~index value =
  render_tensor_literal_write ~emit_expr ctx "tensor_literal_write_i64"
    ~tensor_tmp ~index value

let render_tensor_literal_word_write ~emit_expr ctx ~tensor_tmp ~index value =
  render_tensor_literal_write ~emit_expr ctx "tensor_literal_write_word"
    ~tensor_tmp ~index value

let render_tensor_literal_packed_write ~emit_expr ctx ~tensor_tmp ~index value =
  render_tensor_literal_write ~emit_expr ctx "tensor_literal_write_packed"
    ~tensor_tmp ~index value

let render_tensor_literal_inline_struct_write ~emit_expr ctx ~tensor_tmp ~index
    ~struct_ty value =
  let temp_seed = string_of_int (Core_emit_context.fresh_temp ctx) in
  let value_arg = render_arg ~emit_expr ctx value in
  render_tensor_template "tensor_literal_write_inline_struct"
    [ tensor_tmp; string_of_int index; value_arg; temp_seed; struct_ty ]

let render_tensor_literal_boxed_write_rendered ~tensor_tmp ~index ~value_arg =
  render_tensor_template "tensor_literal_write_boxed"
    [ tensor_tmp; string_of_int index; value_arg ]

let render_tensor_literal_boxed_write ~emit_boxed ctx ~tensor_tmp ~index value =
  let value_arg = render_arg ~emit_expr:emit_boxed ctx value in
  render_tensor_literal_boxed_write_rendered ~tensor_tmp ~index ~value_arg

let render_tensor_literal_boxed_seeded_write ~emit_boxed ctx template_name
    ~tensor_tmp ~index value =
  let temp_seed = string_of_int (Core_emit_context.fresh_temp ctx) in
  let value_arg = render_arg ~emit_expr:emit_boxed ctx value in
  render_tensor_template template_name
    [ tensor_tmp; string_of_int index; value_arg; temp_seed ]

let render_tensor_literal_boxed_owned_write ~emit_boxed ctx ~tensor_tmp ~index
    value =
  render_tensor_literal_boxed_seeded_write ~emit_boxed ctx
    "tensor_literal_write_boxed_owned" ~tensor_tmp ~index value

let render_tensor_literal_boxed_borrowed_write ~emit_boxed ctx ~tensor_tmp
    ~index value =
  render_tensor_literal_boxed_seeded_write ~emit_boxed ctx
    "tensor_literal_write_boxed_borrowed" ~tensor_tmp ~index value

let render_tensor_literal_statements ~emit_expr ~emit_boxed ctx ~tensor_tmp
    ~elem_needs_release payload =
  match payload with
  | TensorRawElements (TensorFloat32Elements, elems) ->
      List.mapi
        (fun i el ->
          render_tensor_literal_f32_write ~emit_expr ctx ~tensor_tmp ~index:i el)
        elems
  | TensorRawElements (TensorFloat64Elements, elems) ->
      List.mapi
        (fun i el ->
          render_tensor_literal_f64_write ~emit_expr ctx ~tensor_tmp ~index:i el)
        elems
  | TensorRawElements (TensorInt64Elements, elems) ->
      List.mapi
        (fun i el ->
          render_tensor_literal_i64_write ~emit_expr ctx ~tensor_tmp ~index:i el)
        elems
  | TensorWordElements elems ->
      List.mapi
        (fun i el ->
          render_tensor_literal_word_write ~emit_expr ctx ~tensor_tmp ~index:i
            el)
        elems
  | TensorPackedElements (_width, elems) ->
      List.mapi
        (fun i el ->
          render_tensor_literal_packed_write ~emit_expr ctx ~tensor_tmp ~index:i
            el)
        elems
  | TensorInlineStructElements (c_ty, elems) ->
      List.mapi
        (fun i el ->
          render_tensor_literal_inline_struct_write ~emit_expr ctx ~tensor_tmp
            ~index:i ~struct_ty:c_ty el)
        elems
  | TensorBoxedElements elems ->
      List.mapi
        (fun i value ->
          if elem_needs_release then
            if value.bsv_transfers_ownership then
              render_tensor_literal_boxed_owned_write ~emit_boxed ctx
                ~tensor_tmp ~index:i value
            else
              render_tensor_literal_boxed_borrowed_write ~emit_boxed ctx
                ~tensor_tmp ~index:i value
          else
            render_tensor_literal_boxed_write ~emit_boxed ctx ~tensor_tmp
              ~index:i value)
        elems

let tensor_fill_inline_struct_value_source value =
  match value.desc with
  | CBoxTyped b -> b.box_value
  | CBox (inner, _) -> inner
  | _ -> value

let render_tensor_dim_args ~emit_expr ctx dims =
  dims
  |> List.map (fun dim ->
      render_tensor_template "tensor_fill_dim_arg"
        [ render_arg ~emit_expr ctx dim ])
  |> String.concat ""

let emit_tensor_fill_inline_struct ~emit_expr ctx function_name value dims
    ~struct_ty =
  let temp_seed = string_of_int (Core_emit_context.fresh_temp ctx) in
  let value_arg =
    render_arg ~emit_expr ctx (tensor_fill_inline_struct_value_source value)
  in
  let dim_args = render_tensor_dim_args ~emit_expr ctx dims in
  emit_tensor_template ctx "tensor_fill_inline_struct"
    [ function_name; value_arg; dim_args; temp_seed; struct_ty ]

let emit_tensor_fill_boxed ~emit_expr ~emit_boxed ctx function_name value dims
    ~fill_value_policy =
  let temp_seed = string_of_int (Core_emit_context.fresh_temp ctx) in
  let value_arg = render_arg ~emit_expr:emit_boxed ctx value in
  let dim_args = render_tensor_dim_args ~emit_expr ctx dims in
  let template_name =
    match fill_value_policy with
    | KeepFillValue -> "tensor_fill_boxed"
    | ReleaseFillValue -> "tensor_fill_boxed_release_value"
  in
  emit_tensor_template ctx template_name
    [ function_name; value_arg; dim_args; temp_seed ]

let render_tensor_fill_dim_name temp_seed index =
  render_tensor_template "tensor_fill_dim_name"
    [ temp_seed; string_of_int index ]

let render_tensor_fill_total_name temp_seed =
  render_tensor_template "tensor_fill_total_name" [ temp_seed ]

let render_tensor_fill_dim_bind ~emit_expr ctx temp_seed index dim =
  let dim_arg = render_arg ~emit_expr ctx dim in
  render_tensor_template "tensor_fill_dim_bind"
    [ temp_seed; string_of_int index; dim_arg ]

let render_tensor_fill_total_expr dim_tmps =
  let rec product = function
    | [] -> "0"
    | [ dim ] -> dim
    | dim :: rest ->
        render_tensor_template "tensor_fill_product_expr" [ dim; product rest ]
  in
  product dim_tmps

let emit_tensor_direct_fill_factory ~emit_expr ctx loc
    (layout : tensor_storage_layout) value dims =
  match (layout.tsl_slots, dims) with
  | (TensorRawScalarStorage _ | TensorPackedStorage _), [] ->
      Core_error.errorf Core_error.Emit loc
        ~hint:
          "tensor fill factories should carry at least the first dimension by \
           the time they reach C emission"
        "malformed tensor fill factory call"
  | (TensorRawScalarStorage _ | TensorPackedStorage _), _ :: _ -> (
      let temp_seed = string_of_int (Core_emit_context.fresh_temp ctx) in
      let dim_bindings =
        dims
        |> List.mapi (render_tensor_fill_dim_bind ~emit_expr ctx temp_seed)
        |> String.concat " "
      in
      let dim_tmps =
        List.mapi (fun i _ -> render_tensor_fill_dim_name temp_seed i) dims
      in
      let total_expr = render_tensor_fill_total_expr dim_tmps in
      let total_tmp = render_tensor_fill_total_name temp_seed in
      let first_dim = render_tensor_fill_dim_name temp_seed 0 in
      let value_arg =
        render_arg ~emit_expr ctx (tensor_fill_inline_struct_value_source value)
      in
      let alloc_expr =
        render_tensor_fill_alloc_call layout ~first_dim ~total_dim:total_tmp loc
      in
      match layout.tsl_slots with
      | TensorRawScalarStorage raw_kind ->
          let value_c_type =
            (Core_layout_type.tensor_raw_scalar_abi raw_kind).tras_c_type
          in
          emit_tensor_template ctx "tensor_fill_raw_scalar"
            [
              dim_bindings;
              total_expr;
              value_c_type;
              value_arg;
              alloc_expr;
              temp_seed;
            ]
      | TensorPackedStorage _ ->
          emit_tensor_template ctx "tensor_fill_packed"
            [ dim_bindings; total_expr; value_arg; alloc_expr; temp_seed ]
      | TensorInlineStructStorage _ | TensorWordStorage | TensorBoxedStorage ->
          Core_error.errorf Core_error.Emit loc
            ~hint:
              "Only raw numeric and packed tensor fill factories are emitted \
               by this path; boxed and inline-struct tensors use their \
               dedicated ownership-aware emitters."
            "unsupported tensor fill storage layout: %s"
            (tensor_storage_slot_layout_str layout.tsl_slots))
  | (TensorInlineStructStorage _ | TensorWordStorage | TensorBoxedStorage), _ ->
      Core_error.errorf Core_error.Emit loc
        ~hint:
          "Only raw numeric and packed tensor fill factories are emitted by \
           this path; boxed and inline-struct tensors use their dedicated \
           ownership-aware emitters."
        "unsupported tensor fill storage layout: %s"
        (tensor_storage_slot_layout_str layout.tsl_slots)

let emit_tensor_alloc ~emit_expr (ctx : Core_emit_context.t) (e : core) size :
    unit =
  let layout = Core_emit_layout.tensor_storage_layout_of_type ctx e.ty e.loc in
  let requires_release =
    tensor_storage_layout_requires_release_or_error ~phase:Core_error.Emit
      ~loc:e.loc layout
  in
  let release_temp_seed =
    if requires_release then
      Some (string_of_int (Core_emit_context.fresh_temp ctx))
    else None
  in
  let size_arg = render_arg ~emit_expr ctx size in
  let alloc_expr = render_tensor_alloc_call layout size_arg in
  match release_temp_seed with
  | Some temp_seed ->
      emit_tensor_template ctx "tensor_alloc_with_release"
        [ alloc_expr; temp_seed ]
  | None -> Core_emit_context.emit ctx alloc_expr

let emit_tensor_raw_view_decl ~emit_expr (ctx : Core_emit_context.t)
    (binding : tensor_raw_view_binding) : unit =
  let pointer_c_type =
    (Core_layout_type.tensor_raw_scalar_abi binding.trv_kind)
      .tras_pointer_c_type
  in
  let source_arg = render_arg ~emit_expr ctx binding.trv_source in
  emit_tensor_template ctx "tensor_raw_view_decl"
    [ pointer_c_type; tensor_view_c_name binding.trv_var; source_arg ]

let emit_tensor_raw_read ~emit_expr (ctx : Core_emit_context.t)
    (read : tensor_raw_read) : unit =
  let index_arg = render_arg ~emit_expr ctx read.trr_index in
  emit_tensor_template ctx "tensor_raw_read"
    [ tensor_view_c_name read.trr_view; index_arg ]

let emit_tensor_raw_write_expr ~emit_expr (ctx : Core_emit_context.t)
    (write : tensor_raw_write) : unit =
  let index_arg = render_arg ~emit_expr ctx write.trw_index in
  let value_arg = render_arg ~emit_expr ctx write.trw_value in
  emit_tensor_template ctx "tensor_raw_write_expr"
    [ tensor_view_c_name write.trw_view; index_arg; value_arg ]

let emit_tensor_raw_write_stmt ~emit_expr (ctx : Core_emit_context.t)
    (write : tensor_raw_write) : unit =
  let index_arg = render_arg ~emit_expr ctx write.trw_index in
  let value_arg = render_arg ~emit_expr ctx write.trw_value in
  emit_tensor_template ctx "tensor_raw_write_stmt"
    [ tensor_view_c_name write.trw_view; index_arg; value_arg ]

let emit_tensor_storage_check ~emit_expr ctx template_name tensor =
  let tensor_arg = render_arg ~emit_expr ctx tensor in
  let temp_seed = string_of_int (Core_emit_context.fresh_temp ctx) in
  emit_tensor_template ctx template_name [ tensor_arg; temp_seed ]

let emit_tensor_word_storage_check ~emit_expr ctx tensor =
  emit_tensor_storage_check ~emit_expr ctx "tensor_is_word_storage" tensor

let emit_tensor_f64_storage_check ~emit_expr ctx tensor =
  emit_tensor_storage_check ~emit_expr ctx "tensor_is_f64_storage" tensor

let emit_tensor_f32_storage_check ~emit_expr ctx tensor =
  emit_tensor_storage_check ~emit_expr ctx "tensor_is_f32_storage" tensor

let emit_tensor_i64_storage_check ~emit_expr ctx tensor =
  emit_tensor_storage_check ~emit_expr ctx "tensor_is_i64_storage" tensor

let emit_tensor_data_pointer_get_unchecked ~emit_expr ctx tensor index =
  let tensor_arg = render_arg ~emit_expr ctx tensor in
  let index_arg = render_arg ~emit_expr ctx index in
  emit_tensor_template ctx "tensor_data_pointer_get_unchecked"
    [ tensor_arg; index_arg ]

let render_tensor_inline_struct_get_unchecked ctx ~tensor_arg ~index_arg
    ~struct_ty =
  let temp_seed = string_of_int (Core_emit_context.fresh_temp ctx) in
  render_tensor_template "tensor_inline_struct_get_unchecked"
    [ tensor_arg; index_arg; temp_seed; struct_ty ]

let emit_tensor_inline_struct_get_unchecked ~emit_expr ctx tensor index
    ~struct_ty =
  let tensor_arg = render_arg ~emit_expr ctx tensor in
  let index_arg = render_arg ~emit_expr ctx index in
  Core_emit_context.emit ctx
    (render_tensor_inline_struct_get_unchecked ctx ~tensor_arg ~index_arg
       ~struct_ty)

let emit_tensor_inline_struct_get_checked ~emit_expr ctx tensor index ~struct_ty
    =
  let tensor_arg = render_arg ~emit_expr ctx tensor in
  let index_arg = render_arg ~emit_expr ctx index in
  let temp_seed = string_of_int (Core_emit_context.fresh_temp ctx) in
  emit_tensor_template ctx "tensor_inline_struct_get_checked"
    [ tensor_arg; index_arg; temp_seed; struct_ty ]

let emit_tensor_inline_struct_matrix_get_checked ~emit_expr ctx tensor row col
    ~struct_ty =
  let tensor_arg = render_arg ~emit_expr ctx tensor in
  let row_arg = render_arg ~emit_expr ctx row in
  let col_arg = render_arg ~emit_expr ctx col in
  let temp_seed = string_of_int (Core_emit_context.fresh_temp ctx) in
  emit_tensor_template ctx "tensor_inline_struct_matrix_get_checked"
    [ tensor_arg; row_arg; col_arg; temp_seed; struct_ty ]

let emit_tensor_stack_option_vector_get ~emit_expr ctx
    (abi : Core_layout_type.generated_stack_option_get_abi) tensor index =
  let tensor_arg = render_arg ~emit_expr ctx tensor in
  let index_arg = render_arg ~emit_expr ctx index in
  let temp_seed = string_of_int (Core_emit_context.fresh_temp ctx) in
  match abi.gsog_payload_storage with
  | Core_layout_type.GeneratedStackOptionValueRecord payload_c_type ->
      emit_tensor_template ctx "tensor_stack_option_vector_get_value_record"
        [
          tensor_arg;
          index_arg;
          temp_seed;
          abi.gsog_option_c_type;
          payload_c_type;
          abi.gsog_none_value;
        ]
  | Core_layout_type.GeneratedStackOptionLong ->
      emit_tensor_template ctx "tensor_stack_option_vector_get_long"
        [
          tensor_arg;
          index_arg;
          temp_seed;
          abi.gsog_option_c_type;
          abi.gsog_none_value;
        ]
  | Core_layout_type.GeneratedStackOptionInt128 ->
      emit_tensor_template ctx "tensor_stack_option_vector_get_int128"
        [
          tensor_arg;
          index_arg;
          temp_seed;
          abi.gsog_option_c_type;
          abi.gsog_none_value;
        ]
  | Core_layout_type.GeneratedStackOptionUInt128 ->
      emit_tensor_template ctx "tensor_stack_option_vector_get_uint128"
        [
          tensor_arg;
          index_arg;
          temp_seed;
          abi.gsog_option_c_type;
          abi.gsog_none_value;
        ]

let emit_tensor_stack_option_matrix_get ~emit_expr ctx
    (abi : Core_layout_type.generated_stack_option_get_abi) tensor row col =
  let tensor_arg = render_arg ~emit_expr ctx tensor in
  let row_arg = render_arg ~emit_expr ctx row in
  let col_arg = render_arg ~emit_expr ctx col in
  let temp_seed = string_of_int (Core_emit_context.fresh_temp ctx) in
  match abi.gsog_payload_storage with
  | Core_layout_type.GeneratedStackOptionValueRecord payload_c_type ->
      emit_tensor_template ctx "tensor_stack_option_matrix_get_value_record"
        [
          tensor_arg;
          row_arg;
          col_arg;
          temp_seed;
          abi.gsog_option_c_type;
          payload_c_type;
          abi.gsog_none_value;
        ]
  | Core_layout_type.GeneratedStackOptionLong ->
      emit_tensor_template ctx "tensor_stack_option_matrix_get_long"
        [
          tensor_arg;
          row_arg;
          col_arg;
          temp_seed;
          abi.gsog_option_c_type;
          abi.gsog_none_value;
        ]
  | Core_layout_type.GeneratedStackOptionInt128 ->
      emit_tensor_template ctx "tensor_stack_option_matrix_get_int128"
        [
          tensor_arg;
          row_arg;
          col_arg;
          temp_seed;
          abi.gsog_option_c_type;
          abi.gsog_none_value;
        ]
  | Core_layout_type.GeneratedStackOptionUInt128 ->
      emit_tensor_template ctx "tensor_stack_option_matrix_get_uint128"
        [
          tensor_arg;
          row_arg;
          col_arg;
          temp_seed;
          abi.gsog_option_c_type;
          abi.gsog_none_value;
        ]

let emit_tensor_inline_struct_element_decl ctx ~var_c ~tensor_c ~index_c
    ~struct_ty =
  let temp_seed = string_of_int (fresh_temp ctx) in
  emit_tensor_template ctx "tensor_inline_struct_element_decl"
    [ var_c; tensor_c; index_c; temp_seed; struct_ty ]

let emit_tensor_get_unchecked ~emit_expr (ctx : Core_emit_context.t) result
    tensor index =
  match Core_emit_layout.tensor_element_storage ctx result.ty with
  | Core_layout_type.TensorElementInlineStruct c_ty ->
      emit_tensor_inline_struct_get_unchecked ~emit_expr ctx tensor index
        ~struct_ty:c_ty
  | Core_layout_type.TensorElementRawScalar _
  | Core_layout_type.TensorElementPackedBits _
  | Core_layout_type.TensorElementBoxed ->
      emit_tensor_data_pointer_get_unchecked ~emit_expr ctx tensor index

let emit_tensor_raw_scalar_get_unchecked ~emit_expr ctx template_name tensor
    index =
  let tensor_arg = render_arg ~emit_expr ctx tensor in
  let index_arg = render_arg ~emit_expr ctx index in
  let temp_seed = string_of_int (Core_emit_context.fresh_temp ctx) in
  emit_tensor_template ctx template_name [ tensor_arg; index_arg; temp_seed ]

let emit_tensor_f64_raw_get_unchecked ~emit_expr ctx tensor index =
  emit_tensor_raw_scalar_get_unchecked ~emit_expr ctx
    "tensor_get_f64_raw_unchecked" tensor index

let emit_tensor_f32_raw_get_unchecked ~emit_expr ctx tensor index =
  emit_tensor_raw_scalar_get_unchecked ~emit_expr ctx
    "tensor_get_f32_raw_unchecked" tensor index

let custom_ctor_template_name ~prefix = function
  | NoElemRelease -> prefix ^ "_custom_no_release"
  | ElemReleaseFn -> prefix ^ "_custom_elem_release"

let render_dict_constructor = function
  | DictCtorGeneric -> render_template "backend_dict_ctor_generic" []
  | DictCtorString -> render_template "backend_dict_ctor_string" []
  | DictCtorFloat -> render_template "backend_dict_ctor_float" []
  | DictCtorCustom { hash_fn; equals_fn; key_release } ->
      render_template
        (custom_ctor_template_name ~prefix:"backend_dict_ctor" key_release)
        [ hash_fn; equals_fn ]

let render_set_constructor = function
  | SetCtorGeneric -> render_template "backend_set_ctor_generic" []
  | SetCtorString -> render_template "backend_set_ctor_string" []
  | SetCtorFloat -> render_template "backend_set_ctor_float" []
  | SetCtorCustom { hash_fn; equals_fn; elem_release } ->
      render_template
        (custom_ctor_template_name ~prefix:"backend_set_ctor" elem_release)
        [ hash_fn; equals_fn ]

let render_set_iter_entry_key ~entry =
  render_template "backend_set_iter_entry_key" [ entry ]

let emit_set_iter_header ~emit_expr ctx ~set ~entry source =
  let source_arg = render_arg ~emit_expr ctx source in
  Core_emit_context.emit_line ctx
    (render_template "backend_set_iter_header" [ set; source_arg; entry ])

let emit_set_iter_release ctx ~set =
  Core_emit_context.emit_line ctx
    (render_template "backend_set_iter_release" [ set ])

let emit_string_find_byte_from ~emit_expr ctx source byte start =
  let temp_seed = string_of_int (Core_emit_context.fresh_temp ctx) in
  let source_arg = render_arg ~emit_expr ctx source in
  let byte_arg = render_arg ~emit_expr ctx byte in
  let start_arg = render_arg ~emit_expr ctx start in
  Core_emit_context.emit ctx
    (render_template "backend_string_find_byte_from"
       [ source_arg; byte_arg; start_arg; temp_seed ])

let emit_string_byte_read ~emit_expr ctx read =
  let source_arg = render_arg ~emit_expr ctx read.sbr_source in
  let index_arg = render_arg ~emit_expr ctx read.sbr_index in
  Core_emit_context.emit ctx
    (render_template "backend_string_byte_read" [ source_arg; index_arg ])

let emit_string_byte_write ~emit_expr ctx write =
  let target_arg = render_arg ~emit_expr ctx write.sbw_target in
  let index_arg = render_arg ~emit_expr ctx write.sbw_index in
  let byte_arg = render_arg ~emit_expr ctx write.sbw_byte in
  Core_emit_context.emit ctx
    (render_template "backend_string_byte_write"
       [ target_arg; index_arg; byte_arg ])

let emit_string_byte_copy_intrinsic ~emit_expr ctx dst dst_pos src src_pos len =
  let temp_seed = string_of_int (Core_emit_context.fresh_temp ctx) in
  let dst_arg = render_arg ~emit_expr ctx dst in
  let dst_pos_arg = render_arg ~emit_expr ctx dst_pos in
  let src_arg = render_arg ~emit_expr ctx src in
  let src_pos_arg = render_arg ~emit_expr ctx src_pos in
  let len_arg = render_arg ~emit_expr ctx len in
  Core_emit_context.emit ctx
    (render_template "backend_string_byte_copy"
       [ dst_arg; dst_pos_arg; src_arg; src_pos_arg; len_arg; temp_seed ])

let emit_string_byte_copy ~emit_expr ctx copy =
  emit_string_byte_copy_intrinsic ~emit_expr ctx copy.sbc_dst copy.sbc_dst_pos
    copy.sbc_src copy.sbc_src_pos copy.sbc_len

let emit_string_set_len_intrinsic ~emit_expr ctx target len =
  let target_arg = render_arg ~emit_expr ctx target in
  let len_arg = render_arg ~emit_expr ctx len in
  Core_emit_context.emit ctx
    (render_template "backend_string_set_len" [ target_arg; len_arg ])

let emit_string_set_len ~emit_expr ctx set_len =
  emit_string_set_len_intrinsic ~emit_expr ctx set_len.ssl_target
    set_len.ssl_len

let emit_string_iter_codepoint_binding ctx ~binding ~iter ~index =
  Core_emit_context.emit_line ctx
    (render_template "backend_string_iter_codepoint_binding"
       [ binding; iter; index ])

let emit_string_iter_header ~emit_expr ctx ~iter ~index source =
  let source_arg = render_arg ~emit_expr ctx source in
  Core_emit_context.emit_line ctx
    (render_template "backend_string_iter_header" [ iter; source_arg; index ])

let emit_flat_iter_source_binding ~emit_expr ctx ~iter_c_type ~iter_tmp source =
  let source_arg = render_arg ~emit_expr ctx source in
  Core_emit_context.emit_line ctx
    (render_template "backend_flat_iter_source_binding"
       [ iter_c_type; iter_tmp; source_arg ])

let emit_flat_iter_loop_header ctx ~length ~iter_tmp ~index =
  Core_emit_context.emit_line ctx
    (render_template "backend_flat_iter_loop_header"
       [ length; iter_tmp; index ])

let emit_flat_iter_raw_data_binding ctx ~pointer_c_type ~raw ~iter_tmp =
  Core_emit_context.emit_line ctx
    (render_template "backend_flat_iter_raw_data_binding"
       [ pointer_c_type; raw; iter_tmp ])

let emit_flat_iter_raw_value_binding ctx ~value_c_type ~binding ~raw ~index =
  Core_emit_context.emit_line ctx
    (render_template "backend_flat_iter_raw_value_binding"
       [ value_c_type; binding; raw; index ])

let render_dict_capacity_constructor ~emit_expr ctx = function
  | DictWithCapacityGeneric capacity ->
      render_template "backend_dict_with_capacity_generic"
        [ render_arg ~emit_expr ctx capacity ]
  | DictWithCapacityString capacity ->
      render_template "backend_dict_with_capacity_string"
        [ render_arg ~emit_expr ctx capacity ]
  | DictWithCapacityFloat capacity ->
      render_template "backend_dict_with_capacity_float"
        [ render_arg ~emit_expr ctx capacity ]
  | DictWithCapacityCustom { capacity; hash_fn; equals_fn; key_release } ->
      render_template
        (custom_ctor_template_name ~prefix:"backend_dict_with_capacity"
           key_release)
        [ render_arg ~emit_expr ctx capacity; hash_fn; equals_fn ]

let render_dict_value_release_init temp_seed =
  render_template "backend_dict_value_release_init" [ temp_seed ]

let render_dict_insert temp_seed ~key_arg ~value_arg =
  render_template "backend_dict_insert" [ temp_seed; key_arg; value_arg ]

let emit_dict_iter_header ~emit_expr ctx ~dict ~index source =
  let source_arg = render_arg ~emit_expr ctx source in
  Core_emit_context.emit_line ctx
    (render_template "backend_dict_iter_header" [ dict; source_arg; index ])

let emit_dict_iter_slot_binding ctx ~slot ~dict ~index =
  Core_emit_context.emit_line ctx
    (render_template "backend_dict_iter_slot_binding" [ slot; dict; index ])

let emit_dict_iter_deleted_slot_guard ctx ~slot =
  Core_emit_context.emit_line ctx
    (render_template "backend_dict_iter_deleted_slot_guard" [ slot ])

let emit_dict_iter_key_binding ctx ~key_c_type ~binding ~dict ~slot =
  Core_emit_context.emit_line ctx
    (render_template "backend_dict_iter_key_binding"
       [ key_c_type; binding; dict; slot ])

let emit_dict_iter_pair_binding ctx ~entry ~dict ~slot =
  Core_emit_context.emit_line ctx
    (render_template "backend_dict_iter_pair_binding" [ entry; dict; slot ])

let emit_dict_construct_result ctx ~ctor_arg ~value_needs_release =
  if value_needs_release then
    let temp_seed = string_of_int (Core_emit_context.fresh_temp ctx) in
    let release_init = render_dict_value_release_init temp_seed in
    Core_emit_context.emit ctx
      (render_template "backend_dict_construct_with_body"
         [ ctor_arg; temp_seed; release_init; "" ])
  else
    Core_emit_context.emit ctx
      (render_template "backend_dict_construct_empty" [ ctor_arg ])

let emit_dict_construct ~emit_key ~emit_value ctx ~ctor_arg ~value_needs_release
    ~force_wrapper entries =
  if entries = [] && (not value_needs_release) && not force_wrapper then
    Core_emit_context.emit ctx
      (render_template "backend_dict_construct_empty" [ ctor_arg ])
  else
    let temp_seed = string_of_int (Core_emit_context.fresh_temp ctx) in
    let release_init =
      if value_needs_release then render_dict_value_release_init temp_seed
      else ""
    in
    let insert_statements =
      entries
      |> List.map (fun (key, value) ->
          let key_arg = render_arg ~emit_expr:emit_key ctx key in
          let value_arg = render_arg ~emit_expr:emit_value ctx value in
          render_dict_insert temp_seed ~key_arg ~value_arg)
      |> String.concat ""
    in
    Core_emit_context.emit ctx
      (render_template "backend_dict_construct_with_body"
         [ ctor_arg; temp_seed; release_init; insert_statements ])

let dict_stack_option_template_name payload_storage key_release_policy =
  match (payload_storage, key_release_policy) with
  | Core_layout_type.GeneratedStackOptionValueRecord _, KeepKey ->
      "backend_dict_stack_option_get_value_record"
  | Core_layout_type.GeneratedStackOptionValueRecord _, ReleaseKey ->
      "backend_dict_stack_option_get_value_record_release_key"
  | Core_layout_type.GeneratedStackOptionLong, KeepKey ->
      "backend_dict_stack_option_get_long"
  | Core_layout_type.GeneratedStackOptionLong, ReleaseKey ->
      "backend_dict_stack_option_get_long_release_key"
  | Core_layout_type.GeneratedStackOptionInt128, KeepKey ->
      "backend_dict_stack_option_get_int128"
  | Core_layout_type.GeneratedStackOptionInt128, ReleaseKey ->
      "backend_dict_stack_option_get_int128_release_key"
  | Core_layout_type.GeneratedStackOptionUInt128, KeepKey ->
      "backend_dict_stack_option_get_uint128"
  | Core_layout_type.GeneratedStackOptionUInt128, ReleaseKey ->
      "backend_dict_stack_option_get_uint128_release_key"

let emit_dict_stack_option_get ~emit_expr ~emit_boxed ctx
    (abi : Core_layout_type.generated_stack_option_get_abi) dict key
    ~key_release_policy =
  let dict_arg = render_arg ~emit_expr ctx dict in
  let key_arg = render_arg ~emit_expr:emit_boxed ctx key in
  let temp_seed = string_of_int (Core_emit_context.fresh_temp ctx) in
  let template_name =
    dict_stack_option_template_name abi.gsog_payload_storage key_release_policy
  in
  match abi.gsog_payload_storage with
  | Core_layout_type.GeneratedStackOptionValueRecord payload_c_type ->
      Core_emit_context.emit ctx
        (render_template template_name
           [
             dict_arg;
             key_arg;
             temp_seed;
             abi.gsog_option_c_type;
             payload_c_type;
             abi.gsog_none_value;
           ])
  | Core_layout_type.GeneratedStackOptionLong
  | Core_layout_type.GeneratedStackOptionInt128
  | Core_layout_type.GeneratedStackOptionUInt128 ->
      Core_emit_context.emit ctx
        (render_template template_name
           [
             dict_arg;
             key_arg;
             temp_seed;
             abi.gsog_option_c_type;
             abi.gsog_none_value;
           ])

let render_channel_with_elem_release ~emit_expr ctx capacity =
  let temp_seed = string_of_int (Core_emit_context.fresh_temp ctx) in
  let capacity_arg = render_arg ~emit_expr ctx capacity in
  render_template "backend_channel_with_elem_release"
    [ capacity_arg; temp_seed ]

let channel_retaining_send_temp_seeds ctx =
  let value_seed = string_of_int (Core_emit_context.fresh_temp ctx) in
  let cleanup_seed = string_of_int (Core_emit_context.fresh_temp ctx) in
  let result_seed = string_of_int (Core_emit_context.fresh_temp ctx) in
  (value_seed, cleanup_seed, result_seed)

let channel_retaining_send_template_name = function
  | ChannelSendRuntime -> "backend_channel_send_retaining"
  | ChannelTrySendRuntime -> "backend_channel_try_send_retaining"
  | ChannelTrySendStatusRuntime -> "backend_channel_try_send_status_retaining"

let channel_retaining_send_timeout_template_name = function
  | ChannelSendTimeoutRuntime -> "backend_channel_send_timeout_retaining"
  | ChannelSendTimeoutStatusRuntime ->
      "backend_channel_send_timeout_status_retaining"

let render_channel_retaining_send ~emit_expr ctx = function
  | ChannelRetainingSendNoTimeout { runtime; result_type; channel; value } ->
      let value_seed, cleanup_seed, result_seed =
        channel_retaining_send_temp_seeds ctx
      in
      let value_arg = render_arg ~emit_expr ctx value in
      let channel_arg = render_arg ~emit_expr ctx channel in
      render_template
        (channel_retaining_send_template_name runtime)
        [
          result_type;
          channel_arg;
          value_arg;
          value_seed;
          cleanup_seed;
          result_seed;
        ]
  | ChannelRetainingSendWithTimeout
      { runtime; result_type; channel; value; timeout } ->
      let value_seed, cleanup_seed, result_seed =
        channel_retaining_send_temp_seeds ctx
      in
      let value_arg = render_arg ~emit_expr ctx value in
      let channel_arg = render_arg ~emit_expr ctx channel in
      let timeout_arg = render_arg ~emit_expr ctx timeout in
      render_template
        (channel_retaining_send_timeout_template_name runtime)
        [
          result_type;
          channel_arg;
          value_arg;
          timeout_arg;
          value_seed;
          cleanup_seed;
          result_seed;
        ]

let channel_send_attempt_temp_seeds ctx =
  let status_seed = string_of_int (Core_emit_context.fresh_temp ctx) in
  let result_seed = string_of_int (Core_emit_context.fresh_temp ctx) in
  (status_seed, result_seed)

let channel_send_attempt_retained_value_temp_seeds ctx =
  let value_seed = string_of_int (Core_emit_context.fresh_temp ctx) in
  let cleanup_seed = string_of_int (Core_emit_context.fresh_temp ctx) in
  (value_seed, cleanup_seed)

let channel_send_attempt_constructor_args constructors =
  [
    constructors.accepted;
    constructors.would_block;
    constructors.sealed;
    constructors.timed_out;
  ]

let render_channel_try_send_attempt ~emit_expr ctx ~result_type ~channel ~value
    ~constructors =
  let status_seed, result_seed = channel_send_attempt_temp_seeds ctx in
  match value with
  | ChannelSendAttemptDirectValue value ->
      let channel_arg = render_arg ~emit_expr ctx channel in
      let value_arg = render_arg ~emit_expr ctx value in
      render_template "backend_channel_try_send_attempt"
        ([ result_type; channel_arg; value_arg; status_seed; result_seed ]
        @ channel_send_attempt_constructor_args constructors)
  | ChannelSendAttemptRetainedValue value ->
      let value_seed, cleanup_seed =
        channel_send_attempt_retained_value_temp_seeds ctx
      in
      let value_arg = render_arg ~emit_expr ctx value in
      let channel_arg = render_arg ~emit_expr ctx channel in
      render_template "backend_channel_try_send_attempt_retained_value"
        ([
           result_type;
           channel_arg;
           value_arg;
           status_seed;
           result_seed;
           value_seed;
           cleanup_seed;
         ]
        @ channel_send_attempt_constructor_args constructors)

let render_channel_send_timeout_attempt ~emit_expr ctx ~result_type ~channel
    ~value ~timeout ~constructors =
  let status_seed, result_seed = channel_send_attempt_temp_seeds ctx in
  match value with
  | ChannelSendAttemptDirectValue value ->
      let channel_arg = render_arg ~emit_expr ctx channel in
      let value_arg = render_arg ~emit_expr ctx value in
      let timeout_arg = render_arg ~emit_expr ctx timeout in
      render_template "backend_channel_send_timeout_attempt"
        ([
           result_type;
           channel_arg;
           value_arg;
           timeout_arg;
           status_seed;
           result_seed;
         ]
        @ channel_send_attempt_constructor_args constructors)
  | ChannelSendAttemptRetainedValue value ->
      let value_seed, cleanup_seed =
        channel_send_attempt_retained_value_temp_seeds ctx
      in
      let value_arg = render_arg ~emit_expr ctx value in
      let channel_arg = render_arg ~emit_expr ctx channel in
      let timeout_arg = render_arg ~emit_expr ctx timeout in
      render_template "backend_channel_send_timeout_attempt_retained_value"
        ([
           result_type;
           channel_arg;
           value_arg;
           timeout_arg;
           status_seed;
           result_seed;
           value_seed;
           cleanup_seed;
         ]
        @ channel_send_attempt_constructor_args constructors)

let render_channel_send_attempt ~emit_expr ctx = function
  | ChannelTrySendAttempt { result_type; channel; value; constructors } ->
      render_channel_try_send_attempt ~emit_expr ctx ~result_type ~channel
        ~value ~constructors
  | ChannelSendTimeoutAttempt
      { result_type; channel; value; timeout; constructors } ->
      render_channel_send_timeout_attempt ~emit_expr ctx ~result_type ~channel
        ~value ~timeout ~constructors

let channel_recv_attempt_temp_seeds ctx =
  let value_seed = string_of_int (Core_emit_context.fresh_temp ctx) in
  let status_seed = string_of_int (Core_emit_context.fresh_temp ctx) in
  let result_seed = string_of_int (Core_emit_context.fresh_temp ctx) in
  (value_seed, status_seed, result_seed)

let channel_try_recv_attempt_template_name = function
  | KeepRecvValue -> "backend_channel_try_recv_attempt_keep_value"
  | ReleaseRecvValue -> "backend_channel_try_recv_attempt_release_value"

let channel_recv_timeout_attempt_template_name = function
  | KeepRecvValue -> "backend_channel_recv_timeout_attempt_keep_value"
  | ReleaseRecvValue -> "backend_channel_recv_timeout_attempt_release_value"

let channel_recv_attempt_constructor_args constructors =
  [ constructors.value; constructors.sealed; constructors.empty ]

let render_channel_try_recv_attempt ~emit_expr ctx ~result_type ~channel
    ~release_policy ~value_constructor_takes_release_mask ~constructors =
  let value_seed, status_seed, result_seed =
    channel_recv_attempt_temp_seeds ctx
  in
  let channel_arg = render_arg ~emit_expr ctx channel in
  if value_constructor_takes_release_mask then
    render_template
      (channel_try_recv_attempt_template_name release_policy)
      ([ result_type; channel_arg; value_seed; status_seed; result_seed ]
      @ channel_recv_attempt_constructor_args constructors)
  else
    render_template "backend_channel_try_recv_attempt_no_release_mask"
      ([ result_type; channel_arg; value_seed; status_seed; result_seed ]
      @ channel_recv_attempt_constructor_args constructors)

let render_channel_recv_timeout_attempt ~emit_expr ctx ~result_type ~channel
    ~timeout ~release_policy ~value_constructor_takes_release_mask ~constructors
    =
  let value_seed, status_seed, result_seed =
    channel_recv_attempt_temp_seeds ctx
  in
  let channel_arg = render_arg ~emit_expr ctx channel in
  let timeout_arg = render_arg ~emit_expr ctx timeout in
  if value_constructor_takes_release_mask then
    render_template
      (channel_recv_timeout_attempt_template_name release_policy)
      ([
         result_type;
         channel_arg;
         timeout_arg;
         value_seed;
         status_seed;
         result_seed;
       ]
      @ channel_recv_attempt_constructor_args constructors)
  else
    render_template "backend_channel_recv_timeout_attempt_no_release_mask"
      ([
         result_type;
         channel_arg;
         timeout_arg;
         value_seed;
         status_seed;
         result_seed;
       ]
      @ channel_recv_attempt_constructor_args constructors)

let render_channel_recv_attempt ~emit_expr ctx = function
  | ChannelTryRecvAttempt
      {
        result_type;
        channel;
        release_policy;
        value_constructor_takes_release_mask;
        constructors;
      } ->
      render_channel_try_recv_attempt ~emit_expr ctx ~result_type ~channel
        ~release_policy ~value_constructor_takes_release_mask ~constructors
  | ChannelRecvTimeoutAttempt
      {
        result_type;
        channel;
        timeout;
        release_policy;
        value_constructor_takes_release_mask;
        constructors;
      } ->
      render_channel_recv_timeout_attempt ~emit_expr ctx ~result_type ~channel
        ~timeout ~release_policy ~value_constructor_takes_release_mask
        ~constructors

let emit_channel_iter_release_object ctx ~value =
  Core_emit_context.emit_line ctx
    (render_template "backend_channel_iter_release_object" [ value ])

let emit_channel_iter_header ~emit_expr ctx ~channel ~value source =
  let source_arg = render_arg ~emit_expr ctx source in
  Core_emit_context.emit_line ctx
    (render_template "backend_channel_iter_header"
       [ channel; source_arg; value ])

let emit_select_arms_decl ctx ~arms ~arm_count =
  Core_emit_context.emit_line ctx
    (render_template "backend_select_arms_decl"
       [ arms; string_of_int arm_count ])

let emit_select_recv_arm ~emit_expr ctx ~arms ~index channel =
  let channel_arg = render_arg ~emit_expr ctx channel in
  Core_emit_context.emit_line ctx
    (render_template "backend_select_recv_arm"
       [ arms; string_of_int index; channel_arg ])

let emit_select_sealed_arm ~emit_expr ctx ~arms ~index channel =
  let channel_arg = render_arg ~emit_expr ctx channel in
  Core_emit_context.emit_line ctx
    (render_template "backend_select_sealed_arm"
       [ arms; string_of_int index; channel_arg ])

let emit_select_after_arm ~emit_expr ctx ~arms ~index timeout =
  let timeout_arg = render_arg ~emit_expr ctx timeout in
  Core_emit_context.emit_line ctx
    (render_template "backend_select_after_arm"
       [ arms; string_of_int index; timeout_arg ])

let emit_select_wait ctx ~result ~arms ~arm_count =
  Core_emit_context.emit_line ctx
    (render_template "backend_select_wait"
       [ result; arms; string_of_int arm_count ])

let emit_select_first_branch_open ctx ~result ~index =
  Core_emit_context.emit_line ctx
    (render_template "backend_select_first_branch_open"
       [ result; string_of_int index ])

let emit_select_next_branch_open ctx ~result ~index =
  Core_emit_context.emit_line ctx
    (render_template "backend_select_next_branch_open"
       [ result; string_of_int index ])

let emit_select_cleanup_frame_decl ctx ~frame =
  Core_emit_context.emit_line ctx
    (render_template "backend_select_cleanup_frame_decl" [ frame ])

let emit_select_cleanup_push ctx ~cleanup_frame ~value_slot ~cleanup_value
    ~release_fn =
  Core_emit_context.emit_line ctx
    (render_template "backend_select_cleanup_push"
       [ cleanup_frame; value_slot; cleanup_value; release_fn ])

let emit_select_cleanup_pop ctx ~value_slot =
  Core_emit_context.emit_line ctx
    (render_template "backend_select_cleanup_pop" [ value_slot ])

let emit_select_received_value_binding ctx ~binding ~result =
  Core_emit_context.emit_line ctx
    (render_template "backend_select_received_value_binding" [ binding; result ])
