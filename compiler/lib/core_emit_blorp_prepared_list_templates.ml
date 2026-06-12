(* Generated from core_emit_blorp_prepared_list_templates.tsv by
   compiler/blorp/codegen_prepared_list_renderer.brp. *)

let tsv =
  {|list_get_pointer	2	blorp_list_get((blorp_List*)@0@, @1@)
list_get_inline_checked	6	({ blorp_List* @2@ = (blorp_List*)@0@; long @3@ = @1@; (__builtin_expect(!@2@ || @3@ < 0 || @3@ >= @2@->len, 0) ? NULL : ({ uintptr_t @4@ = 0; memcpy(&@4@, (char*)@2@->data + @3@ * @5@, @5@); (void*)@4@; })); })
list_get_inline_proven	6	({ blorp_List* @2@ = (blorp_List*)@0@; long @3@ = @1@; ({ uintptr_t @4@ = 0; memcpy(&@4@, (char*)@2@->data + @3@ * @5@, @5@); (void*)@4@; }); })
list_inline_bits_load	4	uintptr_t @2@ = 0; memcpy(&@2@, (char*)@0@->data + @1@ * @3@, @3@);
list_inline_bits_store	7	({ blorp_List* @3@ = (blorp_List*)@0@; long @4@ = @1@; uintptr_t @5@ = (uintptr_t)@2@; memcpy((char*)@3@->data + @4@ * @6@, &@5@, @6@); })
list_pointer_set_raw_store	3	blorp_list_set_raw((blorp_List*)@0@, @1@, (void*)@2@)
list_pointer_handoff_set_owned_store	3	blorp_list_handoff_set_owned((blorp_List*)@0@, @1@, (void*)@2@)
list_inline_struct_set_raw_store	8	({ blorp_List* @4@ = (blorp_List*)@0@; long @5@ = @1@; @7@ @6@ = @2@; if (@4@ && @4@->storage_mode == BLORP_LIST_STORAGE_INLINE && @4@->elem_size == (int16_t)sizeof(@7@)) { blorp_list_set_raw_copy(@4@, @5@, &@6@); } else { blorp_list_set_raw((blorp_List*)@4@, @5@, (void*)@3@); } })
list_inline_struct_handoff_set_owned_store	8	({ blorp_List* @4@ = (blorp_List*)@0@; long @5@ = @1@; @7@ @6@ = @2@; if (@4@ && @4@->storage_mode == BLORP_LIST_STORAGE_INLINE && @4@->elem_size == (int16_t)sizeof(@7@)) { blorp_list_set_raw_copy(@4@, @5@, &@6@); } else { blorp_list_handoff_set_owned((blorp_List*)@4@, @5@, (void*)@3@); } })
list_pointer_swap	7	({ blorp_List* @3@ = (blorp_List*)@0@; long @4@ = @1@; long @5@ = @2@; if (__builtin_expect(@3@ && @4@ != @5@, 1)) { void* @6@ = blorp_list_get(@3@, @4@); blorp_list_set_raw(@3@, @4@, blorp_list_get(@3@, @5@)); blorp_list_set_raw(@3@, @5@, @6@); } })
list_inline_bits_swap	9	({ blorp_List* @3@ = (blorp_List*)@0@; long @4@ = @1@; long @5@ = @2@; if (__builtin_expect(@3@ && @4@ != @5@, 1)) { char* @6@ = (char*)@3@->data; uintptr_t @7@ = 0; memcpy(&@7@, @6@ + @4@ * @8@, @8@); memcpy(@6@ + @4@ * @8@, @6@ + @5@ * @8@, @8@); memcpy(@6@ + @5@ * @8@, &@7@, @8@); } })
list_inline_struct_swap	12	({ blorp_List* @3@ = (blorp_List*)@0@; long @4@ = @1@; long @5@ = @2@; if (__builtin_expect(@3@ && @4@ != @5@, 1)) { if (@3@->storage_mode == BLORP_LIST_STORAGE_INLINE) { char* @6@ = (char*)@3@->data; size_t @7@ = (size_t)@3@->elem_size; void* @8@ = @6@ + @4@ * @7@; void* @9@ = @6@ + @5@ * @7@; unsigned char @10@[@7@]; memcpy(@10@, @8@, @7@); memcpy(@8@, @9@, @7@); memcpy(@9@, @10@, @7@); } else { void* @11@ = blorp_list_get(@3@, @4@); blorp_list_set_raw(@3@, @4@, blorp_list_get(@3@, @5@)); blorp_list_set_raw(@3@, @5@, @11@); } } })
list_inline_struct_load_checked	5	if (__builtin_expect(!@0@ || @1@ < 0 || @1@ >= @0@->len, 0)) { memset(&@2@, 0, sizeof(@4@)); } else if (@0@->storage_mode == BLORP_LIST_STORAGE_INLINE && @0@->elem_size == (int16_t)sizeof(@4@)) { memcpy(&@2@, (char*)@0@->data + @1@ * sizeof(@4@), sizeof(@4@)); } else { void* @3@ = blorp_list_get(@0@, @1@); if (!@3@) { memset(&@2@, 0, sizeof(@4@)); } else { @2@ = blorp_unbox_struct(@3@, @4@); } }
list_inline_struct_load_proven	5	if (@0@->storage_mode == BLORP_LIST_STORAGE_INLINE && @0@->elem_size == (int16_t)sizeof(@4@)) { memcpy(&@2@, (char*)@0@->data + @1@ * sizeof(@4@), sizeof(@4@)); } else { void* @3@ = blorp_list_get(@0@, @1@); if (!@3@) { memset(&@2@, 0, sizeof(@4@)); } else { @2@ = blorp_unbox_struct(@3@, @4@); } }
list_handoff_set_source_slot	4	blorp_list_handoff_set_source_slot((blorp_List*)@0@, @1@, (blorp_List*)@2@, @3@)
list_copy_span_uninit	5	blorp_list_copy_span_uninit((blorp_List*)@0@, @1@, (blorp_List*)@2@, @3@, @4@)
list_ensure_unique	2	({ blorp_List* @1@ = (blorp_List*)@0@; (__builtin_expect(@1@ && blorp_is_unique(@1@), 1) ? @1@ : blorp_list_cow(@1@)); })
list_ensure_capacity	4	({ blorp_List* @2@ = (blorp_List*)@0@; long @3@ = @1@; (__builtin_expect(@2@ && blorp_is_unique(@2@) && @2@->capacity >= @3@, 1) ? @2@ : blorp_list_ensure_capacity(@2@, @3@)); })
list_reuse_alloc	2	blorp_list_reuse_alloc(@0@, @1@)
list_reuse_alloc_with_release	3	({ blorp_List* @2@ = blorp_list_reuse_alloc(@0@, @1@); blorp_list_init_elem_release(@2@, blorp_elem_release_fn); @2@; })
list_alloc_pointer	1	blorp_list_new(@0@)
list_alloc_inline	2	blorp_list_new_inline(@0@, @1@)
list_alloc_with_release	2	({ blorp_List* @1@ = @0@; blorp_list_init_elem_release(@1@, blorp_elem_release_fn); @1@; })
list_retain_for	2	blorp_list_retain_for((blorp_List*)@0@, (void*)@1@)
list_retain_for_noop	0	((void)0)
list_construct_init_elem_release	1	blorp_list_init_elem_release(@0@, blorp_elem_release_fn);
list_construct_inline_struct_set	5	{ @4@ @3@ = @2@; blorp_list_set_raw_copy(@0@, @1@, &@3@); }
list_construct_set_len	2	@0@->len = @1@;
list_construct_append	2	@0@ = blorp_list_append(@0@, @1@);
list_construct_append_owned	2	@0@ = blorp_list_append_owned(@0@, @1@);
|}
