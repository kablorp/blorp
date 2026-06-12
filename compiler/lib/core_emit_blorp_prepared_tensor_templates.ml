(* Generated from core_emit_blorp_prepared_tensor_templates.tsv by
   compiler/blorp/codegen_prepared_tensor_renderer.brp. *)

let tsv =
  {|tensor_raw_view_decl	3	@0@ @1@ = (@0@)((blorp_Vector*)@2@)->data
tensor_raw_read	2	@0@[@1@]
tensor_raw_write_expr	3	({ @0@[@1@] = @2@; (void)0; })
tensor_raw_write_stmt	3	@0@[@1@] = @2@;
tensor_is_word_storage	2	({ blorp_Vector* @1@ = (blorp_Vector*)@0@; @1@ && @1@->storage_mode == BLORP_VECTOR_STORAGE_POINTER && @1@->elem_size == (int16_t)sizeof(void*) && @1@->elem_release == NULL; })
tensor_is_f64_storage	2	({ blorp_Vector* @1@ = (blorp_Vector*)@0@; @1@ && @1@->storage_mode == BLORP_VECTOR_STORAGE_F64 && @1@->elem_size == (int16_t)sizeof(double); })
tensor_is_f32_storage	2	({ blorp_Vector* @1@ = (blorp_Vector*)@0@; @1@ && @1@->storage_mode == BLORP_VECTOR_STORAGE_F32 && @1@->elem_size == (int16_t)sizeof(float); })
tensor_is_i64_storage	2	({ blorp_Vector* @1@ = (blorp_Vector*)@0@; @1@ && @1@->storage_mode == BLORP_VECTOR_STORAGE_I64 && @1@->elem_size == (int16_t)sizeof(long); })
tensor_data_pointer_get_unchecked	2	((blorp_Vector*)@0@)->data[@1@]
tensor_inline_struct_get_unchecked	7	({ blorp_Vector* @2@ = (blorp_Vector*)@0@; long @3@ = @1@; @6@ @4@; if (__builtin_expect(@2@->storage_mode == BLORP_VECTOR_STORAGE_INLINE && @2@->elem_size == sizeof(@6@), 1)) { memcpy(&@4@, (char*)@2@->data + @3@ * sizeof(@6@), sizeof(@6@)); } else { void* @5@ = @2@->data[@3@]; @4@ = blorp_unbox_struct(@5@, @6@); } @4@; })
tensor_get_f64_raw_unchecked	5	({ blorp_Vector* @2@ = (blorp_Vector*)@0@; long @3@ = @1@; double @4@; memcpy(&@4@, (char*)@2@->data + @3@ * sizeof(double), sizeof(double)); @4@; })
tensor_get_f32_raw_unchecked	5	({ blorp_Vector* @2@ = (blorp_Vector*)@0@; long @3@ = @1@; float @4@; memcpy(&@4@, (char*)@2@->data + @3@ * sizeof(float), sizeof(float)); @4@; })
tensor_alloc_pointer	1	blorp_vector_new(@0@)
tensor_alloc_i64	1	blorp_vector_new_i64(@0@)
tensor_alloc_f64	1	blorp_vector_new_f64(@0@)
tensor_alloc_f32	1	blorp_vector_new_f32(@0@)
tensor_alloc_packed	2	blorp_vector_new_packed(@0@, @1@)
tensor_alloc_sized	2	blorp_vector_new_sized(@0@, sizeof(@1@))
tensor_alloc_with_release	2	({ blorp_Vector* @1@ = @0@; blorp_vector_init_elem_release(@1@, blorp_elem_release_fn); @1@; })
tensor_init_elem_release	1	blorp_vector_init_elem_release(@0@, blorp_elem_release_fn);
tensor_ranked_alloc_pointer	2	blorp_tensor_new(@0@, @1@)
tensor_ranked_alloc_i64	2	blorp_tensor_new_i64(@0@, @1@)
tensor_ranked_alloc_f64	2	blorp_tensor_new_f64(@0@, @1@)
tensor_ranked_alloc_f32	2	blorp_tensor_new_f32(@0@, @1@)
tensor_ranked_alloc_packed	3	blorp_tensor_new_packed(@0@, @1@, @2@)
tensor_ranked_alloc_sized	3	blorp_tensor_new_sized(@0@, @1@, sizeof(@2@))
tensor_literal_write_f32	3	((float*)@0@->data)[@1@] = @2@;
tensor_literal_write_f64	3	blorp_vector_write_f64(@0@, @1@, @2@);
tensor_literal_write_i64	3	((long*)@0@->data)[@1@] = @2@;
tensor_literal_write_word	3	@0@->data[@1@] = (void*)(intptr_t)(@2@);
tensor_literal_write_packed	3	blorp_packed_set(@0@, @1@, (long)(@2@));
tensor_literal_write_inline_struct	5	{ @4@ @3@ = @2@; memcpy((char*)@0@->data + @1@ * sizeof(@4@), &@3@, sizeof(@4@)); }
tensor_literal_write_boxed	3	@0@->data[@1@] = @2@;
tensor_literal_boxed_retain	1	if (@0@) blorp_retain(@0@);
|}
