(** Single OCaml transfer point for Blorp-owned backend emission.

    This is the production boundary from the OCaml compiler pipeline into
    Blorp-authored C emission. Domain-specific bridge modules remain
    implementation details while we migrate incrementally. OCaml still owns Core
    traversal, semantic/layout decisions, and child expression rendering; this
    module owns dispatching emission-ready operations to Blorp-owned renderers. *)

open Core

let intrinsic_template_arity name =
  Compiler_blorp_bridge.renderer_template_arity_opt_exn
    ~renderer:Compiler_blorp_bridge.intrinsic_renderer ~op:name

let emit_simple_intrinsic ~emit_expr (ctx : Core_emit_context.t) name args =
  match intrinsic_template_arity name with
  | Some arity when List.length args = arity ->
      let rendered_args =
        Core_emit_blorp_template.render_args ~emit_expr ctx args
      in
      Core_emit_context.emit ctx
        (Compiler_blorp_bridge.render_via_command_exn
           ~renderer:Compiler_blorp_bridge.intrinsic_renderer ~op:name
           rendered_args);
      true
  | Some _ | None -> false

type emitters = {
  emit_expr : Core_emit_context.t -> core -> unit;
  emit_stmt : Core_emit_context.t -> core -> unit;
  emit_boxed_core : Core_emit_context.t -> core -> unit;
  emit_boxed_storage : Core_emit_context.t -> boxed_storage_value -> unit;
  type_to_c : Core_emit_context.t -> Ast.type_expr -> string;
}

type tensor_storage_check =
  | TensorWordStorageCheck
  | TensorF64StorageCheck
  | TensorF32StorageCheck
  | TensorI64StorageCheck

type emit_node =
  | DictIterHeader of { dict : string; source : core; index : string }
  | DictIterSlotBinding of { slot : string; dict : string; index : string }
  | DictIterDeletedSlotGuard of { slot : string }
  | DictIterKeyBinding of {
      key_c_type : string;
      binding : string;
      dict : string;
      slot : string;
    }
  | DictIterPairBinding of { entry : string; dict : string; slot : string }
  | StringFindByteFrom of { source : core; byte : core; start : core }
  | StringByteRead of string_byte_read
  | StringByteWrite of string_byte_write
  | StringByteCopy of string_byte_copy
  | StringByteCopyIntrinsic of {
      dst : core;
      dst_pos : core;
      src : core;
      src_pos : core;
      len : core;
    }
  | StringSetLen of string_set_len
  | StringSetLenIntrinsic of { target : core; len : core }
  | StringIterCodepointBinding of {
      binding : string;
      iter : string;
      index : string;
    }
  | StringIterHeader of { iter : string; source : core; index : string }
  | FlatIterSourceBinding of {
      iter_c_type : string;
      iter_tmp : string;
      source : core;
    }
  | FlatIterLoopHeader of { length : string; iter_tmp : string; index : string }
  | FlatIterRawDataBinding of {
      pointer_c_type : string;
      raw : string;
      iter_tmp : string;
    }
  | FlatIterRawValueBinding of {
      value_c_type : string;
      binding : string;
      raw : string;
      index : string;
    }
  | ListGet of list_get
  | ListHandoff of { result : core; handoff : list_handoff }
  | ListConstruct of list_construct
  | ListStore of {
      runtime : Core_emit_blorp_prepared_backend.list_store_runtime;
      list : core;
      index : core;
      value : core;
    }
  | ListHandoffSetSourceSlot of {
      result : core;
      out_index : core;
      source : core;
      source_index : core;
    }
  | ListCopySpanUninit of {
      dst : core;
      dst_start : core;
      src : core;
      src_start : core;
      count : core;
    }
  | ListSwapSlots of { list : core; left_index : core; right_index : core }
  | ListEnsureUnique of core
  | ListEnsureCapacity of { list : core; capacity : core }
  | ListAllocForLayout of {
      layout : list_storage_layout;
      loc : Ast.loc;
      capacity : core;
    }
  | ListAllocForType of { ty : Ast.type_expr; loc : Ast.loc; capacity : core }
  | ListAllocForTypeCapacityArg of {
      ty : Ast.type_expr;
      loc : Ast.loc;
      capacity_arg : string;
    }
  | ListInlineStructDynamicLoad of {
      list_tmp : string;
      idx_tmp : string;
      out_tmp : string;
      struct_ty : string;
      bounds : list_access_bounds;
    }
  | ListInlineStructUnboxGet of { get : list_get; struct_ty : string }
  | ListInlineBitsLoad of {
      list_tmp : string;
      idx_tmp : string;
      bits_tmp : string;
      width : inline_storage_width;
    }
  | ListReuseAllocForResult of { result : core; list : core; capacity : core }
  | ListRetainForStorage of { list : core; value : core }
  | TensorRawViewDecl of tensor_raw_view_binding
  | TensorLiteral of { loc : Ast.loc; literal : tensor_literal }
  | TensorDirectFillFactory of {
      loc : Ast.loc;
      layout : tensor_storage_layout;
      value : core;
      dims : core list;
    }
  | TensorFillInlineStruct of {
      function_name : string;
      value : core;
      dims : core list;
      struct_ty : string;
    }
  | TensorFillBoxed of {
      function_name : string;
      value : core;
      dims : core list;
      fill_value_policy :
        Core_emit_blorp_prepared_backend.tensor_fill_value_policy;
    }
  | TensorRawRead of tensor_raw_read
  | TensorRawWriteExpr of tensor_raw_write
  | TensorRawWriteStmt of tensor_raw_write
  | TensorInlineStructGetChecked of {
      tensor : core;
      index : core;
      struct_ty : string;
    }
  | TensorInlineStructGetUnchecked of {
      tensor : core;
      index : core;
      struct_ty : string;
    }
  | TensorInlineStructMatrixGetChecked of {
      tensor : core;
      row : core;
      col : core;
      struct_ty : string;
    }
  | TensorInlineStructElementDecl of {
      var_c : string;
      tensor_c : string;
      index_c : string;
      struct_ty : string;
    }
  | TensorStorageCheck of { check : tensor_storage_check; tensor : core }
  | TensorGetUnchecked of { result : core; tensor : core; index : core }
  | TensorF64RawGetUnchecked of { tensor : core; index : core }
  | TensorF32RawGetUnchecked of { tensor : core; index : core }
  | TensorAlloc of { result : core; size : core }
  | TensorStackOptionVectorGet of {
      abi : Core_layout_type.generated_stack_option_get_abi;
      tensor : core;
      index : core;
    }
  | TensorStackOptionMatrixGet of {
      abi : Core_layout_type.generated_stack_option_get_abi;
      tensor : core;
      row : core;
      col : core;
    }
  | DictStackOptionGet of {
      abi : Core_layout_type.generated_stack_option_get_abi;
      dict : core;
      key : core;
      key_release_policy : Core_emit_blorp_prepared_backend.key_release_policy;
    }
  | DictConstructStorage of {
      ctor_arg : string;
      value_needs_release : bool;
      force_wrapper : bool;
      entries : (boxed_storage_value * boxed_storage_value) list;
    }
  | DictConstructCore of {
      ctor_arg : string;
      value_needs_release : bool;
      force_wrapper : bool;
      entries : (core * core) list;
    }
  | DictConstructResult of { ctor_arg : string; value_needs_release : bool }
  | ChannelAllocWithElemRelease of core
  | ChannelRetainingSend of
      Core_emit_blorp_prepared_backend.channel_retaining_send
  | ChannelSendAttempt of Core_emit_blorp_prepared_backend.channel_send_attempt
  | ChannelRecvAttempt of Core_emit_blorp_prepared_backend.channel_recv_attempt
  | ChannelIterReleaseObject of { value : string }
  | ChannelIterHeader of { channel : string; source : core; value : string }
  | SelectArmsDecl of { arms : string; arm_count : int }
  | SelectRecvArm of { arms : string; index : int; channel : core }
  | SelectSealedArm of { arms : string; index : int; channel : core }
  | SelectAfterArm of { arms : string; index : int; timeout : core }
  | SelectWait of { result : string; arms : string; arm_count : int }
  | SelectFirstBranchOpen of { result : string; index : int }
  | SelectNextBranchOpen of { result : string; index : int }
  | SelectCleanupFrameDecl of { frame : string }
  | SelectCleanupPush of {
      cleanup_frame : string;
      value_slot : string;
      cleanup_value : string;
      release_fn : string;
    }
  | SelectCleanupPop of { value_slot : string }
  | SelectReceivedValueBinding of { binding : string; result : string }
  | SetAlloc of Core_emit_blorp_prepared_backend.set_constructor_call
  | SetIterHeader of { set : string; source : core; entry : string }
  | SetIterRelease of { set : string }

let emit_list_handoff emitters ctx result handoff =
  let source_c =
    Codegen_types.escape_c_ident (Var.to_c_name handoff.lh_source_var)
  in
  let result_c =
    Codegen_types.escape_c_ident (Var.to_c_name handoff.lh_result_var)
  in
  let length_c =
    Codegen_types.escape_c_ident (Var.to_c_name handoff.lh_len_var)
  in
  let out_c = Codegen_types.escape_c_ident (Var.to_c_name handoff.lh_out_var) in
  let temp_seed = string_of_int (Core_emit_context.fresh_temp ctx) in
  let capacity_c =
    Core_emit_blorp_prepared_backend.render_list_handoff_capacity_name temp_seed
  in
  let reuse_c =
    Core_emit_blorp_prepared_backend.render_list_handoff_reuse_name temp_seed
  in
  let release_c =
    Core_emit_blorp_prepared_backend.render_list_handoff_release_name temp_seed
  in
  let source_ty_c = emitters.type_to_c ctx handoff.lh_source_ty in
  let result_ty_c = emitters.type_to_c ctx handoff.lh_result_ty in
  let storage_mode_c, elem_size_c =
    Core_emit_blorp_prepared_backend.list_runtime_storage_args handoff.lh_layout
  in
  let release_fn_c =
    Core_emit_blorp_prepared_backend.list_elem_release_arg ~loc:result.loc
      handoff.lh_layout
  in
  Core_emit_blorp_prepared_backend.emit_list_handoff_open
    ~emit_expr:emitters.emit_expr ctx ~source_ty_c ~source_c handoff.lh_source
    ~capacity_c handoff.lh_capacity ~length_c ~release_c ~release_fn_c;
  (match handoff.lh_mode with
  | BorrowFresh ->
      Core_emit_blorp_prepared_backend.emit_list_handoff_begin_borrow ctx
        ~result_ty_c ~result_c ~capacity_c ~release_c ~storage_mode_c
        ~elem_size_c ~out_c
  | ConsumeReuse ->
      Core_emit_blorp_prepared_backend.emit_list_handoff_begin_reuse ctx
        ~result_ty_c ~result_c ~source_c ~capacity_c ~release_c ~storage_mode_c
        ~elem_size_c ~reuse_c ~out_c);
  emitters.emit_stmt ctx handoff.lh_body;
  (match handoff.lh_mode with
  | BorrowFresh ->
      Core_emit_blorp_prepared_backend.emit_list_handoff_finish_borrow ctx
        ~result_c ~out_c ~length_c
  | ConsumeReuse ->
      Core_emit_blorp_prepared_backend.emit_list_handoff_finish_reuse ctx
        ~result_c ~out_c ~length_c ~reuse_c ~source_c);
  Core_emit_blorp_prepared_backend.emit_list_handoff_close ctx ~result_c

let emit emitters ctx = function
  | DictIterHeader { dict; source; index } ->
      Core_emit_blorp_prepared_backend.emit_dict_iter_header
        ~emit_expr:emitters.emit_expr ctx ~dict ~index source
  | DictIterSlotBinding { slot; dict; index } ->
      Core_emit_blorp_prepared_backend.emit_dict_iter_slot_binding ctx ~slot
        ~dict ~index
  | DictIterDeletedSlotGuard { slot } ->
      Core_emit_blorp_prepared_backend.emit_dict_iter_deleted_slot_guard ctx
        ~slot
  | DictIterKeyBinding { key_c_type; binding; dict; slot } ->
      Core_emit_blorp_prepared_backend.emit_dict_iter_key_binding ctx
        ~key_c_type ~binding ~dict ~slot
  | DictIterPairBinding { entry; dict; slot } ->
      Core_emit_blorp_prepared_backend.emit_dict_iter_pair_binding ctx ~entry
        ~dict ~slot
  | StringFindByteFrom { source; byte; start } ->
      Core_emit_blorp_prepared_backend.emit_string_find_byte_from
        ~emit_expr:emitters.emit_expr ctx source byte start
  | StringByteRead read ->
      Core_emit_blorp_prepared_backend.emit_string_byte_read
        ~emit_expr:emitters.emit_expr ctx read
  | StringByteWrite write ->
      Core_emit_blorp_prepared_backend.emit_string_byte_write
        ~emit_expr:emitters.emit_expr ctx write
  | StringByteCopy copy ->
      Core_emit_blorp_prepared_backend.emit_string_byte_copy
        ~emit_expr:emitters.emit_expr ctx copy
  | StringByteCopyIntrinsic { dst; dst_pos; src; src_pos; len } ->
      Core_emit_blorp_prepared_backend.emit_string_byte_copy_intrinsic
        ~emit_expr:emitters.emit_expr ctx dst dst_pos src src_pos len
  | StringSetLen set_len ->
      Core_emit_blorp_prepared_backend.emit_string_set_len
        ~emit_expr:emitters.emit_expr ctx set_len
  | StringSetLenIntrinsic { target; len } ->
      Core_emit_blorp_prepared_backend.emit_string_set_len_intrinsic
        ~emit_expr:emitters.emit_expr ctx target len
  | StringIterCodepointBinding { binding; iter; index } ->
      Core_emit_blorp_prepared_backend.emit_string_iter_codepoint_binding ctx
        ~binding ~iter ~index
  | StringIterHeader { iter; source; index } ->
      Core_emit_blorp_prepared_backend.emit_string_iter_header
        ~emit_expr:emitters.emit_expr ctx ~iter ~index source
  | FlatIterSourceBinding { iter_c_type; iter_tmp; source } ->
      Core_emit_blorp_prepared_backend.emit_flat_iter_source_binding
        ~emit_expr:emitters.emit_expr ctx ~iter_c_type ~iter_tmp source
  | FlatIterLoopHeader { length; iter_tmp; index } ->
      Core_emit_blorp_prepared_backend.emit_flat_iter_loop_header ctx ~length
        ~iter_tmp ~index
  | FlatIterRawDataBinding { pointer_c_type; raw; iter_tmp } ->
      Core_emit_blorp_prepared_backend.emit_flat_iter_raw_data_binding ctx
        ~pointer_c_type ~raw ~iter_tmp
  | FlatIterRawValueBinding { value_c_type; binding; raw; index } ->
      Core_emit_blorp_prepared_backend.emit_flat_iter_raw_value_binding ctx
        ~value_c_type ~binding ~raw ~index
  | ListGet get ->
      Core_emit_blorp_prepared_backend.emit_list_get
        ~emit_expr:emitters.emit_expr ctx get
  | ListHandoff { result; handoff } ->
      emit_list_handoff emitters ctx result handoff
  | ListConstruct construct ->
      let temp_seed = string_of_int (Core_emit_context.fresh_temp ctx) in
      let list_tmp =
        Core_emit_blorp_prepared_backend.render_list_construct_name temp_seed
      in
      let alloc_call =
        Core_emit_blorp_prepared_backend.render_list_alloc_call
          construct.lc_layout
          (string_of_int (List.length construct.lc_elems))
      in
      let statements =
        Core_emit_blorp_prepared_backend.render_list_construct_statements
          ~emit_expr:emitters.emit_expr ~emit_boxed:emitters.emit_boxed_storage
          ctx construct.lc_layout ~list_tmp
          ~elem_needs_release:construct.lc_elem_needs_release construct.lc_elems
      in
      Core_emit_blorp_prepared_backend.emit_list_construct ctx ~list_tmp
        ~alloc_call ~statements
  | ListStore { runtime; list; index; value } ->
      Core_emit_blorp_prepared_backend.emit_list_store
        ~emit_expr:emitters.emit_expr ~emit_boxed:emitters.emit_boxed_core ctx
        runtime list index value
  | ListHandoffSetSourceSlot { result; out_index; source; source_index } ->
      Core_emit_blorp_prepared_backend.emit_list_handoff_set_source_slot
        ~emit_expr:emitters.emit_expr ctx result out_index source source_index
  | ListCopySpanUninit { dst; dst_start; src; src_start; count } ->
      Core_emit_blorp_prepared_backend.emit_list_copy_span_uninit
        ~emit_expr:emitters.emit_expr ctx dst dst_start src src_start count
  | ListSwapSlots { list; left_index; right_index } ->
      Core_emit_blorp_prepared_backend.emit_list_swap_slots
        ~emit_expr:emitters.emit_expr ctx list left_index right_index
  | ListEnsureUnique list ->
      Core_emit_blorp_prepared_backend.emit_list_ensure_unique
        ~emit_expr:emitters.emit_expr ctx list
  | ListEnsureCapacity { list; capacity } ->
      Core_emit_blorp_prepared_backend.emit_list_ensure_capacity
        ~emit_expr:emitters.emit_expr ctx list capacity
  | ListAllocForLayout { layout; loc; capacity } ->
      Core_emit_blorp_prepared_backend.emit_list_alloc_for_layout
        ~emit_expr:emitters.emit_expr ctx layout ~loc capacity
  | ListAllocForType { ty; loc; capacity } ->
      Core_emit_blorp_prepared_backend.emit_list_alloc_for_type
        ~emit_expr:emitters.emit_expr ctx ty ~loc capacity
  | ListAllocForTypeCapacityArg { ty; loc; capacity_arg } ->
      Core_emit_blorp_prepared_backend.emit_list_alloc_for_type_capacity_arg ctx
        ty ~loc capacity_arg
  | ListInlineStructDynamicLoad
      { list_tmp; idx_tmp; out_tmp; struct_ty; bounds } ->
      Core_emit_blorp_prepared_backend.emit_list_inline_struct_dynamic_load ctx
        ~list_tmp ~idx_tmp ~out_tmp ~struct_ty ~bounds
  | ListInlineStructUnboxGet { get; struct_ty } ->
      Core_emit_blorp_prepared_backend.emit_list_inline_struct_unbox_get
        ~emit_expr:emitters.emit_expr ctx get ~struct_ty
  | ListInlineBitsLoad { list_tmp; idx_tmp; bits_tmp; width } ->
      Core_emit_blorp_prepared_backend.emit_list_inline_bits_load ctx ~list_tmp
        ~idx_tmp ~bits_tmp ~width
  | ListReuseAllocForResult { result; list; capacity } ->
      Core_emit_blorp_prepared_backend.emit_list_reuse_alloc_for_result
        ~emit_expr:emitters.emit_expr ctx result list capacity
  | ListRetainForStorage { list; value } ->
      Core_emit_blorp_prepared_backend.emit_list_retain_for_storage
        ~emit_expr:emitters.emit_expr ~emit_boxed:emitters.emit_boxed_core ctx
        list value
  | TensorRawViewDecl binding ->
      Core_emit_blorp_prepared_backend.emit_tensor_raw_view_decl
        ~emit_expr:emitters.emit_expr ctx binding
  | TensorLiteral { loc; literal } ->
      if
        not
          (tensor_literal_layout_matches_payload literal.tl_layout
             literal.tl_payload)
      then
        let expected =
          tensor_storage_slot_layout_str literal.tl_layout.tsl_slots
        in
        let actual =
          tensor_storage_slot_layout_str
            (tensor_literal_payload_slot_layout literal.tl_payload)
        in
        Core_error.errorf Core_error.Emit loc
          ~hint:
            "Run with --check-invariants to catch malformed final Core before \
             emission. Tensor literal storage layout and payload \
             representation must be selected together in Core_codegen_prepare."
          "tensor literal layout `%s` does not match payload storage `%s`"
          expected actual
      else ();
      let temp_seed = string_of_int (Core_emit_context.fresh_temp ctx) in
      let tensor_tmp =
        Core_emit_blorp_prepared_backend.render_tensor_literal_name temp_seed
      in
      let alloc_call =
        Core_emit_blorp_prepared_backend.render_tensor_literal_alloc_call
          literal.tl_layout literal.tl_shape
      in
      let elem_needs_release =
        tensor_storage_layout_requires_release_or_error ~phase:Core_error.Emit
          ~loc literal.tl_layout
      in
      let init_statements =
        if elem_needs_release then
          [
            Core_emit_blorp_prepared_backend
            .render_tensor_literal_init_elem_release ~tensor_tmp;
          ]
        else []
      in
      let element_statements =
        Core_emit_blorp_prepared_backend.render_tensor_literal_statements
          ~emit_expr:emitters.emit_expr ~emit_boxed:emitters.emit_boxed_storage
          ctx ~tensor_tmp ~elem_needs_release literal.tl_payload
      in
      Core_emit_blorp_prepared_backend.emit_tensor_literal_construct ctx
        ~tensor_tmp ~alloc_call
        ~statements:(init_statements @ element_statements)
  | TensorDirectFillFactory { loc; layout; value; dims } ->
      Core_emit_blorp_prepared_backend.emit_tensor_direct_fill_factory
        ~emit_expr:emitters.emit_expr ctx loc layout value dims
  | TensorFillInlineStruct { function_name; value; dims; struct_ty } ->
      Core_emit_blorp_prepared_backend.emit_tensor_fill_inline_struct
        ~emit_expr:emitters.emit_expr ctx function_name value dims ~struct_ty
  | TensorFillBoxed { function_name; value; dims; fill_value_policy } ->
      Core_emit_blorp_prepared_backend.emit_tensor_fill_boxed
        ~emit_expr:emitters.emit_expr ~emit_boxed:emitters.emit_boxed_core ctx
        function_name value dims ~fill_value_policy
  | TensorRawRead read ->
      Core_emit_blorp_prepared_backend.emit_tensor_raw_read
        ~emit_expr:emitters.emit_expr ctx read
  | TensorRawWriteExpr write ->
      Core_emit_blorp_prepared_backend.emit_tensor_raw_write_expr
        ~emit_expr:emitters.emit_expr ctx write
  | TensorRawWriteStmt write ->
      Core_emit_blorp_prepared_backend.emit_tensor_raw_write_stmt
        ~emit_expr:emitters.emit_expr ctx write
  | TensorInlineStructGetChecked { tensor; index; struct_ty } ->
      Core_emit_blorp_prepared_backend.emit_tensor_inline_struct_get_checked
        ~emit_expr:emitters.emit_expr ctx tensor index ~struct_ty
  | TensorInlineStructGetUnchecked { tensor; index; struct_ty } ->
      Core_emit_blorp_prepared_backend.emit_tensor_inline_struct_get_unchecked
        ~emit_expr:emitters.emit_expr ctx tensor index ~struct_ty
  | TensorInlineStructMatrixGetChecked { tensor; row; col; struct_ty } ->
      Core_emit_blorp_prepared_backend
      .emit_tensor_inline_struct_matrix_get_checked
        ~emit_expr:emitters.emit_expr ctx tensor row col ~struct_ty
  | TensorInlineStructElementDecl { var_c; tensor_c; index_c; struct_ty } ->
      Core_emit_blorp_prepared_backend.emit_tensor_inline_struct_element_decl
        ctx ~var_c ~tensor_c ~index_c ~struct_ty
  | TensorStorageCheck { check; tensor } -> (
      match check with
      | TensorWordStorageCheck ->
          Core_emit_blorp_prepared_backend.emit_tensor_word_storage_check
            ~emit_expr:emitters.emit_expr ctx tensor
      | TensorF64StorageCheck ->
          Core_emit_blorp_prepared_backend.emit_tensor_f64_storage_check
            ~emit_expr:emitters.emit_expr ctx tensor
      | TensorF32StorageCheck ->
          Core_emit_blorp_prepared_backend.emit_tensor_f32_storage_check
            ~emit_expr:emitters.emit_expr ctx tensor
      | TensorI64StorageCheck ->
          Core_emit_blorp_prepared_backend.emit_tensor_i64_storage_check
            ~emit_expr:emitters.emit_expr ctx tensor)
  | TensorGetUnchecked { result; tensor; index } ->
      Core_emit_blorp_prepared_backend.emit_tensor_get_unchecked
        ~emit_expr:emitters.emit_expr ctx result tensor index
  | TensorF64RawGetUnchecked { tensor; index } ->
      Core_emit_blorp_prepared_backend.emit_tensor_f64_raw_get_unchecked
        ~emit_expr:emitters.emit_expr ctx tensor index
  | TensorF32RawGetUnchecked { tensor; index } ->
      Core_emit_blorp_prepared_backend.emit_tensor_f32_raw_get_unchecked
        ~emit_expr:emitters.emit_expr ctx tensor index
  | TensorAlloc { result; size } ->
      Core_emit_blorp_prepared_backend.emit_tensor_alloc
        ~emit_expr:emitters.emit_expr ctx result size
  | TensorStackOptionVectorGet { abi; tensor; index } ->
      Core_emit_blorp_prepared_backend.emit_tensor_stack_option_vector_get
        ~emit_expr:emitters.emit_expr ctx abi tensor index
  | TensorStackOptionMatrixGet { abi; tensor; row; col } ->
      Core_emit_blorp_prepared_backend.emit_tensor_stack_option_matrix_get
        ~emit_expr:emitters.emit_expr ctx abi tensor row col
  | DictStackOptionGet { abi; dict; key; key_release_policy } ->
      Core_emit_blorp_prepared_backend.emit_dict_stack_option_get
        ~emit_expr:emitters.emit_expr ~emit_boxed:emitters.emit_boxed_core ctx
        abi dict key ~key_release_policy
  | DictConstructStorage
      { ctor_arg; value_needs_release; force_wrapper; entries } ->
      Core_emit_blorp_prepared_backend.emit_dict_construct
        ~emit_key:emitters.emit_boxed_storage
        ~emit_value:emitters.emit_boxed_storage ctx ~ctor_arg
        ~value_needs_release ~force_wrapper entries
  | DictConstructCore { ctor_arg; value_needs_release; force_wrapper; entries }
    ->
      Core_emit_blorp_prepared_backend.emit_dict_construct
        ~emit_key:emitters.emit_boxed_core ~emit_value:emitters.emit_boxed_core
        ctx ~ctor_arg ~value_needs_release ~force_wrapper entries
  | DictConstructResult { ctor_arg; value_needs_release } ->
      Core_emit_blorp_prepared_backend.emit_dict_construct_result ctx ~ctor_arg
        ~value_needs_release
  | ChannelAllocWithElemRelease capacity ->
      Core_emit_context.emit ctx
        (Core_emit_blorp_prepared_backend.render_channel_with_elem_release
           ~emit_expr:emitters.emit_expr ctx capacity)
  | ChannelRetainingSend send ->
      Core_emit_context.emit ctx
        (Core_emit_blorp_prepared_backend.render_channel_retaining_send
           ~emit_expr:emitters.emit_expr ctx send)
  | ChannelSendAttempt attempt ->
      Core_emit_context.emit ctx
        (Core_emit_blorp_prepared_backend.render_channel_send_attempt
           ~emit_expr:emitters.emit_expr ctx attempt)
  | ChannelRecvAttempt attempt ->
      Core_emit_context.emit ctx
        (Core_emit_blorp_prepared_backend.render_channel_recv_attempt
           ~emit_expr:emitters.emit_expr ctx attempt)
  | ChannelIterReleaseObject { value } ->
      Core_emit_blorp_prepared_backend.emit_channel_iter_release_object ctx
        ~value
  | ChannelIterHeader { channel; source; value } ->
      Core_emit_blorp_prepared_backend.emit_channel_iter_header
        ~emit_expr:emitters.emit_expr ctx ~channel ~value source
  | SelectArmsDecl { arms; arm_count } ->
      Core_emit_blorp_prepared_backend.emit_select_arms_decl ctx ~arms
        ~arm_count
  | SelectRecvArm { arms; index; channel } ->
      Core_emit_blorp_prepared_backend.emit_select_recv_arm
        ~emit_expr:emitters.emit_expr ctx ~arms ~index channel
  | SelectSealedArm { arms; index; channel } ->
      Core_emit_blorp_prepared_backend.emit_select_sealed_arm
        ~emit_expr:emitters.emit_expr ctx ~arms ~index channel
  | SelectAfterArm { arms; index; timeout } ->
      Core_emit_blorp_prepared_backend.emit_select_after_arm
        ~emit_expr:emitters.emit_expr ctx ~arms ~index timeout
  | SelectWait { result; arms; arm_count } ->
      Core_emit_blorp_prepared_backend.emit_select_wait ctx ~result ~arms
        ~arm_count
  | SelectFirstBranchOpen { result; index } ->
      Core_emit_blorp_prepared_backend.emit_select_first_branch_open ctx ~result
        ~index
  | SelectNextBranchOpen { result; index } ->
      Core_emit_blorp_prepared_backend.emit_select_next_branch_open ctx ~result
        ~index
  | SelectCleanupFrameDecl { frame } ->
      Core_emit_blorp_prepared_backend.emit_select_cleanup_frame_decl ctx ~frame
  | SelectCleanupPush { cleanup_frame; value_slot; cleanup_value; release_fn }
    ->
      Core_emit_blorp_prepared_backend.emit_select_cleanup_push ctx
        ~cleanup_frame ~value_slot ~cleanup_value ~release_fn
  | SelectCleanupPop { value_slot } ->
      Core_emit_blorp_prepared_backend.emit_select_cleanup_pop ctx ~value_slot
  | SelectReceivedValueBinding { binding; result } ->
      Core_emit_blorp_prepared_backend.emit_select_received_value_binding ctx
        ~binding ~result
  | SetAlloc ctor ->
      Core_emit_context.emit ctx
        (Core_emit_blorp_prepared_backend.render_set_constructor ctor)
  | SetIterHeader { set; source; entry } ->
      Core_emit_blorp_prepared_backend.emit_set_iter_header
        ~emit_expr:emitters.emit_expr ctx ~set ~entry source
  | SetIterRelease { set } ->
      Core_emit_blorp_prepared_backend.emit_set_iter_release ctx ~set
