(** Single OCaml transfer point for Blorp-owned backend emission.

    This is the production boundary from the OCaml compiler pipeline into
    Blorp-authored C emission. Domain-specific bridge modules remain
    implementation details while we migrate incrementally. OCaml still owns Core
    traversal, semantic/layout decisions, and child expression rendering; this
    module owns dispatching emission-ready operations to Blorp-owned renderers. *)

open Core

type emitters = {
  emit_expr : Core_emit_context.t -> core -> unit;
  emit_stmt : Core_emit_context.t -> core -> unit;
  emit_boxed_core : Core_emit_context.t -> core -> unit;
  emit_boxed_storage : Core_emit_context.t -> boxed_storage_value -> unit;
  type_to_c : Core_emit_context.t -> Ast.type_expr -> string;
}

type list_store_runtime = ListSetRawStore | ListHandoffSetOwnedStore

type key_release_policy = Core_emit_blorp_prepared_dict.key_release_policy =
  | KeepKey
  | ReleaseKey

type elem_release_arg = NoElemRelease | ElemReleaseFn

type tensor_fill_value_policy =
      Core_emit_blorp_prepared_tensor.fill_value_policy =
  | KeepFillValue
  | ReleaseFillValue

type tensor_storage_check =
  | TensorWordStorageCheck
  | TensorF64StorageCheck
  | TensorF32StorageCheck
  | TensorI64StorageCheck

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

type emit_node =
  | TupleConstruct of tuple_construct
  | TupleFieldAccess of {
      obj : core;
      field : string;
      render_read : string -> string;
    }
  | DictIterSourceBinding of { dict : string; source : core }
  | DictIterLoopOpen of { index : string; dict : string }
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
  | ListGet of list_get
  | ListHandoff of { result : core; handoff : list_handoff }
  | ListConstruct of list_construct
  | ListStore of {
      runtime : list_store_runtime;
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
      fill_value_policy : tensor_fill_value_policy;
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
      key_release_policy : key_release_policy;
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
  | SetAlloc of set_constructor_call
  | SetIterSourceBinding of { set : string; source : core }
  | SetIterRetain of { set : string }
  | SetIterLoopOpen of { entry : string; set : string }
  | SetIterRelease of { set : string }

let render_tuple_field_element_at ~tuple_tmp ~index =
  Core_emit_blorp_prepared_tuple.render_tuple_field_element_at ~tuple_tmp ~index

let render_set_iter_entry_key ~entry =
  Core_emit_blorp_prepared_set.render_iter_entry_key ~entry

let prepared_list_store_runtime = function
  | ListSetRawStore -> Core_emit_blorp_prepared_list.ListSetRaw
  | ListHandoffSetOwnedStore ->
      Core_emit_blorp_prepared_list.ListHandoffSetOwned

let render_elem_release_arg = function
  | NoElemRelease -> "NULL"
  | ElemReleaseFn -> "blorp_elem_release_fn"

let render_dict_constructor = function
  | DictCtorGeneric ->
      Core_emit_blorp_prepared_dict.render_call_no_args "blorp_dict_new"
  | DictCtorString ->
      Core_emit_blorp_prepared_dict.render_call_no_args "blorp_dict_new_string"
  | DictCtorFloat ->
      Core_emit_blorp_prepared_dict.render_call_no_args "blorp_dict_new_float"
  | DictCtorCustom { hash_fn; equals_fn; key_release } ->
      Core_emit_blorp_prepared_dict.render_custom_ctor "blorp_dict_new_custom"
        ~hash_fn ~equals_fn
        ~key_release:(render_elem_release_arg key_release)

let render_set_constructor = function
  | SetCtorGeneric ->
      Core_emit_blorp_prepared_dict.render_call_no_args "blorp_set_new"
  | SetCtorString ->
      Core_emit_blorp_prepared_dict.render_call_no_args "blorp_set_new_string"
  | SetCtorFloat ->
      Core_emit_blorp_prepared_dict.render_call_no_args "blorp_set_new_float"
  | SetCtorCustom { hash_fn; equals_fn; elem_release } ->
      Core_emit_blorp_prepared_dict.render_custom_ctor "blorp_set_new_custom"
        ~hash_fn ~equals_fn
        ~key_release:(render_elem_release_arg elem_release)

let render_custom_constructor function_name ~hash_fn ~equals_fn ~key_release =
  Core_emit_blorp_prepared_dict.render_custom_ctor function_name ~hash_fn
    ~equals_fn
    ~key_release:(render_elem_release_arg key_release)

let render_dict_capacity_constructor emitters ctx = function
  | DictWithCapacityGeneric capacity ->
      Core_emit_blorp_prepared_dict.render_call_with_capacity
        ~emit_expr:emitters.emit_expr ctx "blorp_dict_with_capacity" capacity
  | DictWithCapacityString capacity ->
      Core_emit_blorp_prepared_dict.render_call_with_capacity
        ~emit_expr:emitters.emit_expr ctx "blorp_dict_with_capacity_string"
        capacity
  | DictWithCapacityFloat capacity ->
      Core_emit_blorp_prepared_dict.render_call_with_capacity
        ~emit_expr:emitters.emit_expr ctx "blorp_dict_with_capacity_float"
        capacity
  | DictWithCapacityCustom { capacity; hash_fn; equals_fn; key_release } ->
      Core_emit_blorp_prepared_dict.render_custom_with_capacity_ctor
        ~emit_expr:emitters.emit_expr ctx "blorp_dict_with_capacity_custom"
        capacity ~hash_fn ~equals_fn
        ~key_release:(render_elem_release_arg key_release)

let list_runtime_storage_args layout =
  Core_emit_blorp_prepared_list.runtime_storage_args layout

let list_elem_release_arg ~loc layout =
  Core_emit_blorp_prepared_list.elem_release_arg ~loc layout

let tensor_runtime_storage_args layout =
  Core_emit_blorp_prepared_tensor.runtime_storage_args layout

let tensor_callback_result_encoding_arg layout =
  Core_emit_blorp_prepared_tensor.callback_result_encoding_arg layout

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
    Core_emit_blorp_prepared_list.render_handoff_capacity_name temp_seed
  in
  let reuse_c =
    Core_emit_blorp_prepared_list.render_handoff_reuse_name temp_seed
  in
  let release_c =
    Core_emit_blorp_prepared_list.render_handoff_release_name temp_seed
  in
  let source_ty_c = emitters.type_to_c ctx handoff.lh_source_ty in
  let result_ty_c = emitters.type_to_c ctx handoff.lh_result_ty in
  let storage_mode_c, elem_size_c =
    list_runtime_storage_args handoff.lh_layout
  in
  let release_fn_c = list_elem_release_arg ~loc:result.loc handoff.lh_layout in
  Core_emit_blorp_prepared_list.emit_handoff_open ~emit_expr:emitters.emit_expr
    ctx ~source_ty_c ~source_c handoff.lh_source ~capacity_c handoff.lh_capacity
    ~length_c ~release_c ~release_fn_c;
  (match handoff.lh_mode with
  | BorrowFresh ->
      Core_emit_blorp_prepared_list.emit_handoff_begin_borrow ctx ~result_ty_c
        ~result_c ~capacity_c ~release_c ~storage_mode_c ~elem_size_c ~out_c
  | ConsumeReuse ->
      Core_emit_blorp_prepared_list.emit_handoff_begin_reuse ctx ~result_ty_c
        ~result_c ~source_c ~capacity_c ~release_c ~storage_mode_c ~elem_size_c
        ~reuse_c ~out_c);
  emitters.emit_stmt ctx handoff.lh_body;
  (match handoff.lh_mode with
  | BorrowFresh ->
      Core_emit_blorp_prepared_list.emit_handoff_finish_borrow ctx ~result_c
        ~out_c ~length_c
  | ConsumeReuse ->
      Core_emit_blorp_prepared_list.emit_handoff_finish_reuse ctx ~result_c
        ~out_c ~length_c ~reuse_c ~source_c);
  Core_emit_blorp_prepared_list.emit_handoff_close ctx ~result_c

let emit emitters ctx = function
  | TupleConstruct tuple ->
      Core_emit_blorp_prepared_tuple.emit_construct
        ~emit_boxed:emitters.emit_boxed_storage ctx tuple
  | TupleFieldAccess { obj; field; render_read } ->
      Core_emit_blorp_prepared_tuple.emit_field_access
        ~emit_expr:emitters.emit_expr ~render_read ctx obj field
  | DictIterSourceBinding { dict; source } ->
      Core_emit_blorp_prepared_dict.emit_iter_source_binding
        ~emit_expr:emitters.emit_expr ctx ~dict source
  | DictIterLoopOpen { index; dict } ->
      Core_emit_blorp_prepared_dict.emit_iter_loop_open ctx ~index ~dict
  | DictIterSlotBinding { slot; dict; index } ->
      Core_emit_blorp_prepared_dict.emit_iter_slot_binding ctx ~slot ~dict
        ~index
  | DictIterDeletedSlotGuard { slot } ->
      Core_emit_blorp_prepared_dict.emit_iter_deleted_slot_guard ctx ~slot
  | DictIterKeyBinding { key_c_type; binding; dict; slot } ->
      Core_emit_blorp_prepared_dict.emit_iter_key_binding ctx ~key_c_type
        ~binding ~dict ~slot
  | DictIterPairBinding { entry; dict; slot } ->
      Core_emit_blorp_prepared_dict.emit_iter_pair_binding ctx ~entry ~dict
        ~slot
  | StringFindByteFrom { source; byte; start } ->
      Core_emit_blorp_prepared_string.emit_find_byte_from
        ~emit_expr:emitters.emit_expr ctx source byte start
  | StringByteRead read ->
      Core_emit_blorp_prepared_string.emit_byte_read
        ~emit_expr:emitters.emit_expr ctx read
  | StringByteWrite write ->
      Core_emit_blorp_prepared_string.emit_byte_write
        ~emit_expr:emitters.emit_expr ctx write
  | StringByteCopy copy ->
      Core_emit_blorp_prepared_string.emit_byte_copy
        ~emit_expr:emitters.emit_expr ctx copy
  | StringByteCopyIntrinsic { dst; dst_pos; src; src_pos; len } ->
      Core_emit_blorp_prepared_string.emit_byte_copy_intrinsic
        ~emit_expr:emitters.emit_expr ctx dst dst_pos src src_pos len
  | StringSetLen set_len ->
      Core_emit_blorp_prepared_string.emit_set_len ~emit_expr:emitters.emit_expr
        ctx set_len
  | StringSetLenIntrinsic { target; len } ->
      Core_emit_blorp_prepared_string.emit_set_len_intrinsic
        ~emit_expr:emitters.emit_expr ctx target len
  | ListGet get ->
      Core_emit_blorp_prepared_list.emit_get ~emit_expr:emitters.emit_expr ctx
        get
  | ListHandoff { result; handoff } ->
      emit_list_handoff emitters ctx result handoff
  | ListConstruct construct ->
      let temp_seed = string_of_int (Core_emit_context.fresh_temp ctx) in
      let list_tmp =
        Core_emit_blorp_prepared_list.render_construct_name temp_seed
      in
      let alloc_call =
        Core_emit_blorp_prepared_list.render_alloc_call construct.lc_layout
          (string_of_int (List.length construct.lc_elems))
      in
      let statements =
        Core_emit_blorp_prepared_list.render_construct_statements
          ~emit_expr:emitters.emit_expr ~emit_boxed:emitters.emit_boxed_storage
          ctx construct.lc_layout ~list_tmp
          ~elem_needs_release:construct.lc_elem_needs_release construct.lc_elems
      in
      Core_emit_blorp_prepared_list.emit_construct ctx ~list_tmp ~alloc_call
        ~statements
  | ListStore { runtime; list; index; value } ->
      Core_emit_blorp_prepared_list.emit_store ~emit_expr:emitters.emit_expr
        ~emit_boxed:emitters.emit_boxed_core ctx
        (prepared_list_store_runtime runtime)
        list index value
  | ListHandoffSetSourceSlot { result; out_index; source; source_index } ->
      Core_emit_blorp_prepared_list.emit_handoff_set_source_slot
        ~emit_expr:emitters.emit_expr ctx result out_index source source_index
  | ListCopySpanUninit { dst; dst_start; src; src_start; count } ->
      Core_emit_blorp_prepared_list.emit_copy_span_uninit
        ~emit_expr:emitters.emit_expr ctx dst dst_start src src_start count
  | ListSwapSlots { list; left_index; right_index } ->
      Core_emit_blorp_prepared_list.emit_swap_slots
        ~emit_expr:emitters.emit_expr ctx list left_index right_index
  | ListEnsureUnique list ->
      Core_emit_blorp_prepared_list.emit_ensure_unique
        ~emit_expr:emitters.emit_expr ctx list
  | ListEnsureCapacity { list; capacity } ->
      Core_emit_blorp_prepared_list.emit_ensure_capacity
        ~emit_expr:emitters.emit_expr ctx list capacity
  | ListAllocForLayout { layout; loc; capacity } ->
      Core_emit_blorp_prepared_list.emit_alloc_for_layout
        ~emit_expr:emitters.emit_expr ctx layout ~loc capacity
  | ListAllocForType { ty; loc; capacity } ->
      Core_emit_blorp_prepared_list.emit_alloc_for_type
        ~emit_expr:emitters.emit_expr ctx ty ~loc capacity
  | ListAllocForTypeCapacityArg { ty; loc; capacity_arg } ->
      Core_emit_blorp_prepared_list.emit_alloc_for_type_capacity_arg ctx ty ~loc
        capacity_arg
  | ListInlineStructDynamicLoad
      { list_tmp; idx_tmp; out_tmp; struct_ty; bounds } ->
      Core_emit_blorp_prepared_list.emit_inline_struct_dynamic_load ctx
        ~list_tmp ~idx_tmp ~out_tmp ~struct_ty ~bounds
  | ListInlineStructUnboxGet { get; struct_ty } ->
      Core_emit_blorp_prepared_list.emit_inline_struct_unbox_get
        ~emit_expr:emitters.emit_expr ctx get ~struct_ty
  | ListInlineBitsLoad { list_tmp; idx_tmp; bits_tmp; width } ->
      Core_emit_blorp_prepared_list.emit_inline_bits_load ctx ~list_tmp ~idx_tmp
        ~bits_tmp ~width
  | ListReuseAllocForResult { result; list; capacity } ->
      Core_emit_blorp_prepared_list.emit_reuse_alloc_for_result
        ~emit_expr:emitters.emit_expr ctx result list capacity
  | ListRetainForStorage { list; value } ->
      Core_emit_blorp_prepared_list.emit_retain_for_storage
        ~emit_expr:emitters.emit_expr ~emit_boxed:emitters.emit_boxed_core ctx
        list value
  | TensorRawViewDecl binding ->
      Core_emit_blorp_prepared_tensor.emit_raw_view_decl
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
        Core_emit_blorp_prepared_tensor.render_literal_name temp_seed
      in
      let alloc_call =
        Core_emit_blorp_prepared_tensor.render_literal_alloc_call
          literal.tl_layout literal.tl_shape
      in
      let elem_needs_release =
        tensor_storage_layout_requires_release_or_error ~phase:Core_error.Emit
          ~loc literal.tl_layout
      in
      let init_statements =
        if elem_needs_release then
          [
            Core_emit_blorp_prepared_tensor.render_literal_init_elem_release
              ~tensor_tmp;
          ]
        else []
      in
      let element_statements =
        Core_emit_blorp_prepared_tensor.render_literal_statements
          ~emit_expr:emitters.emit_expr ~emit_boxed:emitters.emit_boxed_storage
          ctx ~tensor_tmp ~elem_needs_release literal.tl_payload
      in
      Core_emit_blorp_prepared_tensor.emit_literal_construct ctx ~tensor_tmp
        ~alloc_call
        ~statements:(init_statements @ element_statements)
  | TensorDirectFillFactory { loc; layout; value; dims } ->
      Core_emit_blorp_prepared_tensor.emit_direct_fill_factory
        ~emit_expr:emitters.emit_expr ctx loc layout value dims
  | TensorFillInlineStruct { function_name; value; dims; struct_ty } ->
      Core_emit_blorp_prepared_tensor.emit_fill_inline_struct
        ~emit_expr:emitters.emit_expr ctx function_name value dims ~struct_ty
  | TensorFillBoxed { function_name; value; dims; fill_value_policy } ->
      Core_emit_blorp_prepared_tensor.emit_fill_boxed
        ~emit_expr:emitters.emit_expr ~emit_boxed:emitters.emit_boxed_core ctx
        function_name value dims ~fill_value_policy
  | TensorRawRead read ->
      Core_emit_blorp_prepared_tensor.emit_raw_read
        ~emit_expr:emitters.emit_expr ctx read
  | TensorRawWriteExpr write ->
      Core_emit_blorp_prepared_tensor.emit_raw_write_expr
        ~emit_expr:emitters.emit_expr ctx write
  | TensorRawWriteStmt write ->
      Core_emit_blorp_prepared_tensor.emit_raw_write_stmt
        ~emit_expr:emitters.emit_expr ctx write
  | TensorInlineStructGetChecked { tensor; index; struct_ty } ->
      Core_emit_blorp_prepared_tensor.emit_inline_struct_get_checked
        ~emit_expr:emitters.emit_expr ctx tensor index ~struct_ty
  | TensorInlineStructGetUnchecked { tensor; index; struct_ty } ->
      Core_emit_blorp_prepared_tensor.emit_inline_struct_get_unchecked
        ~emit_expr:emitters.emit_expr ctx tensor index ~struct_ty
  | TensorInlineStructMatrixGetChecked { tensor; row; col; struct_ty } ->
      Core_emit_blorp_prepared_tensor.emit_inline_struct_matrix_get_checked
        ~emit_expr:emitters.emit_expr ctx tensor row col ~struct_ty
  | TensorInlineStructElementDecl { var_c; tensor_c; index_c; struct_ty } ->
      Core_emit_blorp_prepared_tensor.emit_inline_struct_element_decl ctx ~var_c
        ~tensor_c ~index_c ~struct_ty
  | TensorStorageCheck { check; tensor } -> (
      match check with
      | TensorWordStorageCheck ->
          Core_emit_blorp_prepared_tensor.emit_word_storage_check
            ~emit_expr:emitters.emit_expr ctx tensor
      | TensorF64StorageCheck ->
          Core_emit_blorp_prepared_tensor.emit_f64_storage_check
            ~emit_expr:emitters.emit_expr ctx tensor
      | TensorF32StorageCheck ->
          Core_emit_blorp_prepared_tensor.emit_f32_storage_check
            ~emit_expr:emitters.emit_expr ctx tensor
      | TensorI64StorageCheck ->
          Core_emit_blorp_prepared_tensor.emit_i64_storage_check
            ~emit_expr:emitters.emit_expr ctx tensor)
  | TensorGetUnchecked { result; tensor; index } ->
      Core_emit_blorp_prepared_tensor.emit_get_unchecked
        ~emit_expr:emitters.emit_expr ctx result tensor index
  | TensorF64RawGetUnchecked { tensor; index } ->
      Core_emit_blorp_prepared_tensor.emit_f64_raw_get_unchecked
        ~emit_expr:emitters.emit_expr ctx tensor index
  | TensorF32RawGetUnchecked { tensor; index } ->
      Core_emit_blorp_prepared_tensor.emit_f32_raw_get_unchecked
        ~emit_expr:emitters.emit_expr ctx tensor index
  | TensorAlloc { result; size } ->
      Core_emit_blorp_prepared_tensor.emit_alloc ~emit_expr:emitters.emit_expr
        ctx result size
  | TensorStackOptionVectorGet { abi; tensor; index } ->
      Core_emit_blorp_prepared_tensor.emit_stack_option_vector_get
        ~emit_expr:emitters.emit_expr ctx abi tensor index
  | TensorStackOptionMatrixGet { abi; tensor; row; col } ->
      Core_emit_blorp_prepared_tensor.emit_stack_option_matrix_get
        ~emit_expr:emitters.emit_expr ctx abi tensor row col
  | DictStackOptionGet { abi; dict; key; key_release_policy } ->
      Core_emit_blorp_prepared_dict.emit_stack_option_get
        ~emit_expr:emitters.emit_expr ~emit_boxed:emitters.emit_boxed_core ctx
        abi dict key ~key_release_policy
  | DictConstructStorage
      { ctor_arg; value_needs_release; force_wrapper; entries } ->
      Core_emit_blorp_prepared_dict.emit_construct
        ~emit_key:emitters.emit_boxed_storage
        ~emit_value:emitters.emit_boxed_storage ctx ~ctor_arg
        ~value_needs_release ~force_wrapper entries
  | DictConstructCore { ctor_arg; value_needs_release; force_wrapper; entries }
    ->
      Core_emit_blorp_prepared_dict.emit_construct
        ~emit_key:emitters.emit_boxed_core ~emit_value:emitters.emit_boxed_core
        ctx ~ctor_arg ~value_needs_release ~force_wrapper entries
  | DictConstructResult { ctor_arg; value_needs_release } ->
      Core_emit_blorp_prepared_dict.emit_construct_result ctx ~ctor_arg
        ~value_needs_release
  | SetAlloc ctor -> Core_emit_context.emit ctx (render_set_constructor ctor)
  | SetIterSourceBinding { set; source } ->
      Core_emit_blorp_prepared_set.emit_iter_source_binding
        ~emit_expr:emitters.emit_expr ctx ~set source
  | SetIterRetain { set } ->
      Core_emit_blorp_prepared_set.emit_iter_retain ctx ~set
  | SetIterLoopOpen { entry; set } ->
      Core_emit_blorp_prepared_set.emit_iter_loop_open ctx ~entry ~set
  | SetIterRelease { set } ->
      Core_emit_blorp_prepared_set.emit_iter_release ctx ~set
