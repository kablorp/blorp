(* Generated from core_emit_blorp_prepared_backend_templates.tsv by
   compiler/blorp/codegen_prepared_backend_renderer.brp. *)

let tsv =
  {|
backend_dict_ctor_generic	0	blorp_dict_new()
backend_dict_ctor_string	0	blorp_dict_new_string()
backend_dict_ctor_float	0	blorp_dict_new_float()
backend_dict_ctor_custom_no_release	2	blorp_dict_new_custom((unsigned long (*)(void*))@0@, (bool (*)(void*, void*))@1@, NULL)
backend_dict_ctor_custom_elem_release	2	blorp_dict_new_custom((unsigned long (*)(void*))@0@, (bool (*)(void*, void*))@1@, blorp_elem_release_fn)
backend_dict_stack_option_get_value_record	6	({ blorp_Dict* __gso_dict_@2@ = (blorp_Dict*)@0@; void* __gso_key_@2@ = @1@; void* __gso_raw_@2@ = NULL; bool __gso_found_@2@ = blorp_dict_get_raw(__gso_dict_@2@, __gso_key_@2@, &__gso_raw_@2@); @3@ __gso_result_@2@; if (__gso_found_@2@) { __gso_result_@2@ = ((@3@){ .tag = BLORP_TAG_SOME, .value = blorp_unbox_struct(__gso_raw_@2@, @4@) }); } else { __gso_result_@2@ = ((@3@){ .tag = BLORP_TAG_NONE, .value = @5@ }); } __gso_result_@2@; })
backend_dict_stack_option_get_value_record_release_key	6	({ blorp_Dict* __gso_dict_@2@ = (blorp_Dict*)@0@; void* __gso_key_@2@ = @1@; void* __gso_raw_@2@ = NULL; bool __gso_found_@2@ = blorp_dict_get_raw(__gso_dict_@2@, __gso_key_@2@, &__gso_raw_@2@); @3@ __gso_result_@2@; if (__gso_found_@2@) { __gso_result_@2@ = ((@3@){ .tag = BLORP_TAG_SOME, .value = blorp_unbox_struct(__gso_raw_@2@, @4@) }); } else { __gso_result_@2@ = ((@3@){ .tag = BLORP_TAG_NONE, .value = @5@ }); } blorp_release(__gso_key_@2@); __gso_result_@2@; })
backend_dict_stack_option_get_long	5	({ blorp_Dict* __gso_dict_@2@ = (blorp_Dict*)@0@; void* __gso_key_@2@ = @1@; void* __gso_raw_@2@ = NULL; bool __gso_found_@2@ = blorp_dict_get_raw(__gso_dict_@2@, __gso_key_@2@, &__gso_raw_@2@); @3@ __gso_result_@2@; if (__gso_found_@2@) { __gso_result_@2@ = ((@3@){ .tag = BLORP_TAG_SOME, .value = (long)__gso_raw_@2@ }); } else { __gso_result_@2@ = ((@3@){ .tag = BLORP_TAG_NONE, .value = @4@ }); } __gso_result_@2@; })
backend_dict_stack_option_get_long_release_key	5	({ blorp_Dict* __gso_dict_@2@ = (blorp_Dict*)@0@; void* __gso_key_@2@ = @1@; void* __gso_raw_@2@ = NULL; bool __gso_found_@2@ = blorp_dict_get_raw(__gso_dict_@2@, __gso_key_@2@, &__gso_raw_@2@); @3@ __gso_result_@2@; if (__gso_found_@2@) { __gso_result_@2@ = ((@3@){ .tag = BLORP_TAG_SOME, .value = (long)__gso_raw_@2@ }); } else { __gso_result_@2@ = ((@3@){ .tag = BLORP_TAG_NONE, .value = @4@ }); } blorp_release(__gso_key_@2@); __gso_result_@2@; })
backend_dict_stack_option_get_int128	5	({ blorp_Dict* __gso_dict_@2@ = (blorp_Dict*)@0@; void* __gso_key_@2@ = @1@; void* __gso_raw_@2@ = NULL; bool __gso_found_@2@ = blorp_dict_get_raw(__gso_dict_@2@, __gso_key_@2@, &__gso_raw_@2@); @3@ __gso_result_@2@; if (__gso_found_@2@) { __gso_result_@2@ = ((@3@){ .tag = BLORP_TAG_SOME, .value = blorp_unbox_int128(__gso_raw_@2@) }); } else { __gso_result_@2@ = ((@3@){ .tag = BLORP_TAG_NONE, .value = @4@ }); } __gso_result_@2@; })
backend_dict_stack_option_get_int128_release_key	5	({ blorp_Dict* __gso_dict_@2@ = (blorp_Dict*)@0@; void* __gso_key_@2@ = @1@; void* __gso_raw_@2@ = NULL; bool __gso_found_@2@ = blorp_dict_get_raw(__gso_dict_@2@, __gso_key_@2@, &__gso_raw_@2@); @3@ __gso_result_@2@; if (__gso_found_@2@) { __gso_result_@2@ = ((@3@){ .tag = BLORP_TAG_SOME, .value = blorp_unbox_int128(__gso_raw_@2@) }); } else { __gso_result_@2@ = ((@3@){ .tag = BLORP_TAG_NONE, .value = @4@ }); } blorp_release(__gso_key_@2@); __gso_result_@2@; })
backend_dict_stack_option_get_uint128	5	({ blorp_Dict* __gso_dict_@2@ = (blorp_Dict*)@0@; void* __gso_key_@2@ = @1@; void* __gso_raw_@2@ = NULL; bool __gso_found_@2@ = blorp_dict_get_raw(__gso_dict_@2@, __gso_key_@2@, &__gso_raw_@2@); @3@ __gso_result_@2@; if (__gso_found_@2@) { __gso_result_@2@ = ((@3@){ .tag = BLORP_TAG_SOME, .value = blorp_unbox_uint128(__gso_raw_@2@) }); } else { __gso_result_@2@ = ((@3@){ .tag = BLORP_TAG_NONE, .value = @4@ }); } __gso_result_@2@; })
backend_dict_stack_option_get_uint128_release_key	5	({ blorp_Dict* __gso_dict_@2@ = (blorp_Dict*)@0@; void* __gso_key_@2@ = @1@; void* __gso_raw_@2@ = NULL; bool __gso_found_@2@ = blorp_dict_get_raw(__gso_dict_@2@, __gso_key_@2@, &__gso_raw_@2@); @3@ __gso_result_@2@; if (__gso_found_@2@) { __gso_result_@2@ = ((@3@){ .tag = BLORP_TAG_SOME, .value = blorp_unbox_uint128(__gso_raw_@2@) }); } else { __gso_result_@2@ = ((@3@){ .tag = BLORP_TAG_NONE, .value = @4@ }); } blorp_release(__gso_key_@2@); __gso_result_@2@; })
backend_dict_construct_empty	1	@0@
backend_dict_value_release_init	1	 blorp_dict_set_value_release(__dict_@0@, blorp_elem_release_fn);
backend_dict_insert	3	 __dict_@0@ = blorp_dict_insert(__dict_@0@, @1@, @2@);
backend_dict_iter_source_binding	2	blorp_Dict* @0@ = (blorp_Dict*)@1@;
backend_dict_iter_loop_open	2	for (long @0@ = 0; @0@ < @1@->order_len; @0@++) {
backend_dict_iter_header	3	blorp_Dict* @0@ = (blorp_Dict*)@1@; for (long @2@ = 0; @2@ < @0@->order_len; @2@++) {
backend_dict_iter_slot_binding	3	long @0@ = @1@->order[@2@];
backend_dict_iter_deleted_slot_guard	1	if (@0@ < 0) continue;
backend_dict_iter_key_binding	4	@0@ @1@ = (@0@)@2@->keys[@3@];
backend_dict_iter_pair_binding	3	blorp_Tuple* @0@ = blorp_tuple_new(2, @1@->keys[@2@], @1@->values[@2@]);
backend_dict_construct_with_body	4	({ blorp_Dict* __dict_@1@ = @0@;@2@@3@ __dict_@1@; })
backend_set_ctor_generic	0	blorp_set_new()
backend_set_ctor_string	0	blorp_set_new_string()
backend_set_ctor_float	0	blorp_set_new_float()
backend_set_ctor_custom_no_release	2	blorp_set_new_custom((unsigned long (*)(void*))@0@, (bool (*)(void*, void*))@1@, NULL)
backend_set_ctor_custom_elem_release	2	blorp_set_new_custom((unsigned long (*)(void*))@0@, (bool (*)(void*, void*))@1@, blorp_elem_release_fn)
backend_set_iter_source_binding	2	blorp_Set* @0@ = (blorp_Set*)@1@;
backend_set_iter_retain	1	blorp_retain(@0@);
backend_set_iter_loop_open	2	for (blorp_SetEntry* @0@ = @1@->first; @0@ != NULL; @0@ = @0@->next_order) {
backend_set_iter_entry_key	1	@0@->key
backend_set_iter_release	1	blorp_release(@0@);
backend_set_iter_header	3	blorp_Set* @0@ = (blorp_Set*)@1@; blorp_retain(@0@); for (blorp_SetEntry* @2@ = @0@->first; @2@ != NULL; @2@ = @2@->next_order) {
backend_tuple_name	1	__tup_@0@
backend_tuple_arg	1	, @0@
backend_tuple_construct	2	blorp_tuple_new(@0@@1@)
backend_tuple_retain_elem	2	if (@0@->elem[@1@]) blorp_retain(@0@->elem[@1@]);
backend_tuple_construct_with_rc	5	({ blorp_Tuple* @0@ = blorp_tuple_new(@1@@2@); @3@ blorp_tuple_set_rc(@0@, @4@UL); @0@; })
backend_tuple_field_element	2	((blorp_Tuple*)@0@)->elem[@1@]
backend_tuple_field_access	3	({ void* @0@ = (void*)@1@; @2@; })
backend_string_find_byte_from	4	({ blorp_String* __string_find_src_@3@ = (blorp_String*)@0@; long __string_find_byte_@3@ = @1@; long __string_find_start_@3@ = @2@; blorp_string_find_byte_from(__string_find_src_@3@, __string_find_byte_@3@, __string_find_start_@3@); })
backend_string_byte_read	2	(long)(unsigned char)((blorp_String*)@0@)->data[@1@]
backend_string_byte_write	3	(((blorp_String*)@0@)->data[@1@] = (char)@2@)
backend_string_byte_copy	6	({ blorp_String* __string_copy_dst_@5@ = (blorp_String*)@0@; long __string_copy_dst_pos_@5@ = @1@; blorp_String* __string_copy_src_@5@ = (blorp_String*)@2@; long __string_copy_src_pos_@5@ = @3@; long __string_copy_len_@5@ = @4@; if (__string_copy_len_@5@ > 0) { memcpy(__string_copy_dst_@5@->data + __string_copy_dst_pos_@5@, __string_copy_src_@5@->data + __string_copy_src_pos_@5@, (size_t)__string_copy_len_@5@); } (void)0; })
backend_string_set_len	2	({ blorp_String* __sl = (blorp_String*)@0@; long __sn = @1@; __sl->len = __sn; __sl->data[__sn] = '\0'; (void)0; })
backend_string_iter_source_binding	2	blorp_String* @0@ = (blorp_String*)@1@;
backend_string_iter_loop_open	2	for (long @0@ = 0; @0@ < @1@->len; ) {
backend_string_iter_codepoint_binding	3	int32_t @0@ = blorp_string_next_codepoint(@1@, &@2@);
backend_string_iter_header	3	blorp_String* @0@ = (blorp_String*)@1@; for (long @2@ = 0; @2@ < @0@->len; ) {
backend_flat_iter_source_binding	3	@0@ @1@ = @2@;
backend_flat_iter_length_binding	2	long @0@ = @1@->len;
backend_flat_iter_loop_open	2	for (long @0@ = 0; @0@ < @1@; @0@++) {
backend_flat_iter_loop_header	3	long @0@ = @1@->len; for (long @2@ = 0; @2@ < @0@; @2@++) {
backend_flat_iter_raw_data_binding	3	@0@ @1@ = (@0@)@2@->data;
backend_flat_iter_raw_value_binding	4	@0@ @1@ = (@0@)@2@[@3@];
backend_dict_with_capacity_generic	1	blorp_dict_with_capacity(@0@)
backend_dict_with_capacity_string	1	blorp_dict_with_capacity_string(@0@)
backend_dict_with_capacity_float	1	blorp_dict_with_capacity_float(@0@)
backend_dict_with_capacity_custom_no_release	3	blorp_dict_with_capacity_custom(@0@, (unsigned long (*)(void*))@1@, (bool (*)(void*, void*))@2@, NULL)
backend_dict_with_capacity_custom_elem_release	3	blorp_dict_with_capacity_custom(@0@, (unsigned long (*)(void*))@1@, (bool (*)(void*, void*))@2@, blorp_elem_release_fn)
backend_channel_with_elem_release	2	({ blorp_Channel* __ch_@1@ = blorp_channel_new(@0@); blorp_channel_init_elem_release(__ch_@1@, blorp_elem_release_fn); __ch_@1@; })
backend_channel_send_retaining	6	({ void* __chan_send_value_@3@ = @2@; blorp_CancelCleanupFrame __chan_send_cleanup_@4@; blorp_task_cleanup_push(&__chan_send_cleanup_@4@, &__chan_send_value_@3@, (void*)__chan_send_value_@3@, blorp_cleanup_release_arc_value); @0@ __chan_send_result_@5@ = blorp_channel_send(@1@, __chan_send_value_@3@); blorp_task_cleanup_pop_slot(&__chan_send_value_@3@); blorp_release(__chan_send_value_@3@); __chan_send_result_@5@; })
backend_channel_try_send_retaining	6	({ void* __chan_send_value_@3@ = @2@; blorp_CancelCleanupFrame __chan_send_cleanup_@4@; blorp_task_cleanup_push(&__chan_send_cleanup_@4@, &__chan_send_value_@3@, (void*)__chan_send_value_@3@, blorp_cleanup_release_arc_value); @0@ __chan_send_result_@5@ = blorp_channel_try_send(@1@, __chan_send_value_@3@); blorp_task_cleanup_pop_slot(&__chan_send_value_@3@); blorp_release(__chan_send_value_@3@); __chan_send_result_@5@; })
backend_channel_try_send_status_retaining	6	({ void* __chan_send_value_@3@ = @2@; blorp_CancelCleanupFrame __chan_send_cleanup_@4@; blorp_task_cleanup_push(&__chan_send_cleanup_@4@, &__chan_send_value_@3@, (void*)__chan_send_value_@3@, blorp_cleanup_release_arc_value); @0@ __chan_send_result_@5@ = blorp_channel_try_send_status(@1@, __chan_send_value_@3@); blorp_task_cleanup_pop_slot(&__chan_send_value_@3@); blorp_release(__chan_send_value_@3@); __chan_send_result_@5@; })
backend_channel_send_timeout_retaining	7	({ void* __chan_send_value_@4@ = @2@; blorp_CancelCleanupFrame __chan_send_cleanup_@5@; blorp_task_cleanup_push(&__chan_send_cleanup_@5@, &__chan_send_value_@4@, (void*)__chan_send_value_@4@, blorp_cleanup_release_arc_value); @0@ __chan_send_result_@6@ = blorp_channel_send_timeout(@1@, __chan_send_value_@4@, @3@); blorp_task_cleanup_pop_slot(&__chan_send_value_@4@); blorp_release(__chan_send_value_@4@); __chan_send_result_@6@; })
backend_channel_send_timeout_status_retaining	7	({ void* __chan_send_value_@4@ = @2@; blorp_CancelCleanupFrame __chan_send_cleanup_@5@; blorp_task_cleanup_push(&__chan_send_cleanup_@5@, &__chan_send_value_@4@, (void*)__chan_send_value_@4@, blorp_cleanup_release_arc_value); @0@ __chan_send_result_@6@ = blorp_channel_send_timeout_status(@1@, __chan_send_value_@4@, @3@); blorp_task_cleanup_pop_slot(&__chan_send_value_@4@); blorp_release(__chan_send_value_@4@); __chan_send_result_@6@; })
backend_channel_try_send_attempt	9	({ long __chan_send_status_@3@ = blorp_channel_try_send_status(@1@, @2@); @0@ __chan_send_result_@4@; if (__chan_send_status_@3@ == BLORP_CHANNEL_SEND_ACCEPTED) { __chan_send_result_@4@ = @5@; } else if (__chan_send_status_@3@ == BLORP_CHANNEL_SEND_WOULD_BLOCK) { __chan_send_result_@4@ = @6@; } else if (__chan_send_status_@3@ == BLORP_CHANNEL_SEND_SEALED) { __chan_send_result_@4@ = @7@; } else { __chan_send_result_@4@ = @8@; } __chan_send_result_@4@; })
backend_channel_try_send_attempt_retained_value	11	({ void* __chan_send_value_@5@ = @2@; blorp_CancelCleanupFrame __chan_send_cleanup_@6@; blorp_task_cleanup_push(&__chan_send_cleanup_@6@, &__chan_send_value_@5@, (void*)__chan_send_value_@5@, blorp_cleanup_release_arc_value); long __chan_send_status_@3@ = blorp_channel_try_send_status(@1@, __chan_send_value_@5@); blorp_task_cleanup_pop_slot(&__chan_send_value_@5@); blorp_release(__chan_send_value_@5@); @0@ __chan_send_result_@4@; if (__chan_send_status_@3@ == BLORP_CHANNEL_SEND_ACCEPTED) { __chan_send_result_@4@ = @7@; } else if (__chan_send_status_@3@ == BLORP_CHANNEL_SEND_WOULD_BLOCK) { __chan_send_result_@4@ = @8@; } else if (__chan_send_status_@3@ == BLORP_CHANNEL_SEND_SEALED) { __chan_send_result_@4@ = @9@; } else { __chan_send_result_@4@ = @10@; } __chan_send_result_@4@; })
backend_channel_send_timeout_attempt	10	({ long __chan_send_status_@4@ = blorp_channel_send_timeout_status(@1@, @2@, @3@); @0@ __chan_send_result_@5@; if (__chan_send_status_@4@ == BLORP_CHANNEL_SEND_ACCEPTED) { __chan_send_result_@5@ = @6@; } else if (__chan_send_status_@4@ == BLORP_CHANNEL_SEND_WOULD_BLOCK) { __chan_send_result_@5@ = @7@; } else if (__chan_send_status_@4@ == BLORP_CHANNEL_SEND_SEALED) { __chan_send_result_@5@ = @8@; } else { __chan_send_result_@5@ = @9@; } __chan_send_result_@5@; })
backend_channel_send_timeout_attempt_retained_value	12	({ void* __chan_send_value_@6@ = @2@; blorp_CancelCleanupFrame __chan_send_cleanup_@7@; blorp_task_cleanup_push(&__chan_send_cleanup_@7@, &__chan_send_value_@6@, (void*)__chan_send_value_@6@, blorp_cleanup_release_arc_value); long __chan_send_status_@4@ = blorp_channel_send_timeout_status(@1@, __chan_send_value_@6@, @3@); blorp_task_cleanup_pop_slot(&__chan_send_value_@6@); blorp_release(__chan_send_value_@6@); @0@ __chan_send_result_@5@; if (__chan_send_status_@4@ == BLORP_CHANNEL_SEND_ACCEPTED) { __chan_send_result_@5@ = @8@; } else if (__chan_send_status_@4@ == BLORP_CHANNEL_SEND_WOULD_BLOCK) { __chan_send_result_@5@ = @9@; } else if (__chan_send_status_@4@ == BLORP_CHANNEL_SEND_SEALED) { __chan_send_result_@5@ = @10@; } else { __chan_send_result_@5@ = @11@; } __chan_send_result_@5@; })
backend_channel_try_recv_attempt	9	({ void* __chan_recv_value_@2@ = NULL; long __chan_recv_status_@3@ = blorp_channel_try_recv_status_raw((blorp_Channel*)@1@, &__chan_recv_value_@2@); @0@ __chan_recv_result_@4@; if (__chan_recv_status_@3@ == BLORP_CHANNEL_RECV_VALUE) { __chan_recv_result_@4@ = @6@(__chan_recv_value_@2@, @5@UL); } else if (__chan_recv_status_@3@ == BLORP_CHANNEL_RECV_SEALED) { __chan_recv_result_@4@ = @7@; } else { __chan_recv_result_@4@ = @8@; } __chan_recv_result_@4@; })
backend_channel_recv_timeout_attempt	10	({ void* __chan_recv_value_@3@ = NULL; long __chan_recv_status_@4@ = blorp_channel_recv_timeout_status_raw((blorp_Channel*)@1@, @2@, &__chan_recv_value_@3@); @0@ __chan_recv_result_@5@; if (__chan_recv_status_@4@ == BLORP_CHANNEL_RECV_VALUE) { __chan_recv_result_@5@ = @7@(__chan_recv_value_@3@, @6@UL); } else if (__chan_recv_status_@4@ == BLORP_CHANNEL_RECV_SEALED) { __chan_recv_result_@5@ = @8@; } else { __chan_recv_result_@5@ = @9@; } __chan_recv_result_@5@; })
backend_channel_iter_source_binding	2	blorp_Channel* @0@ = (blorp_Channel*)@1@;
backend_channel_iter_value_init	1	void* @0@ = NULL;
backend_channel_iter_loop_open	2	while (blorp_channel_recv_raw(@0@, &@1@)) {
backend_channel_iter_release_object	1	if (@0@) blorp_release((blorp_Object*)@0@);
backend_channel_iter_header	3	blorp_Channel* @0@ = (blorp_Channel*)@1@; void* @2@ = NULL; while (blorp_channel_recv_raw(@0@, &@2@)) {
backend_select_arms_decl	2	blorp_SelectArm @0@[@1@];
backend_select_recv_arm	3	@0@[@1@] = (blorp_SelectArm){ .kind = BLORP_SELECT_RECV, .channel = (blorp_Channel*)@2@, .timeout_ms = 0L };
backend_select_sealed_arm	3	@0@[@1@] = (blorp_SelectArm){ .kind = BLORP_SELECT_SEALED, .channel = (blorp_Channel*)@2@, .timeout_ms = 0L };
backend_select_after_arm	3	@0@[@1@] = (blorp_SelectArm){ .kind = BLORP_SELECT_AFTER, .channel = NULL, .timeout_ms = @2@ };
backend_select_wait	3	blorp_SelectResult @0@ = blorp_select_wait(@1@, @2@L);
backend_select_first_branch_open	2	if (@0@.arm_index == @1@L) {
backend_select_next_branch_open	2	else if (@0@.arm_index == @1@L) {
backend_select_cleanup_frame_decl	1	blorp_CancelCleanupFrame @0@;
backend_select_cleanup_push	4	blorp_task_cleanup_push(&@0@, &@1@, @2@, @3@);
backend_select_cleanup_pop	1	blorp_task_cleanup_pop_slot(&@0@);
backend_select_received_value_binding	2	void* @0@ = @1@.value;
backend_stack_option_some_value	2	((@0@){ .tag = BLORP_TAG_SOME, .value = @1@ })
backend_stack_option_some_void_statement	2	({ @1@ ((@0@){ .tag = BLORP_TAG_SOME, .value = 0 }); })
backend_stack_option_none	2	((@0@){ .tag = BLORP_TAG_NONE, .value = @1@ })
backend_stack_option_tagged_value	3	((@0@){ .tag = @1@, .value = @2@ })
backend_stack_option_tagged_void_statement	3	({ @2@ ((@0@){ .tag = @1@, .value = 0 }); })
backend_stack_option_tagged_none	3	((@0@){ .tag = @1@, .value = @2@ })
backend_stack_result_ok	3	((@0@){ .tag = BLORP_TAG_OK, .release_mask = @2@UL, .data.Ok.field0 = @1@ })
backend_stack_result_err	3	((@0@){ .tag = BLORP_TAG_ERR, .release_mask = @2@UL, .data.Err.field0 = @1@ })
backend_stack_result_tagged_payload	5	((@0@){ .tag = @1@, .release_mask = @4@UL, .data.@2@.field0 = @3@ })
|}
