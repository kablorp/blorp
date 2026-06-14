(* Generated from core_emit_blorp_prepared_tensor_templates.tsv by
   compiler/blorp/codegen_prepared_tensor_renderer.brp. *)

let tsv =
  {|tensor_raw_view_decl	3	@0@ @1@ = (@0@)((blorp_Vector*)@2@)->data
tensor_raw_read	2	@0@[@1@]
tensor_raw_write_expr	3	({ @0@[@1@] = @2@; (void)0; })
tensor_raw_write_stmt	3	@0@[@1@] = @2@;
tensor_is_word_storage	2	({ blorp_Vector* __tensor_layout_@1@ = (blorp_Vector*)@0@; __tensor_layout_@1@ && __tensor_layout_@1@->storage_mode == BLORP_VECTOR_STORAGE_POINTER && __tensor_layout_@1@->elem_size == (int16_t)sizeof(void*) && __tensor_layout_@1@->elem_release == NULL; })
tensor_is_f64_storage	2	({ blorp_Vector* __tensor_layout_@1@ = (blorp_Vector*)@0@; __tensor_layout_@1@ && __tensor_layout_@1@->storage_mode == BLORP_VECTOR_STORAGE_F64 && __tensor_layout_@1@->elem_size == (int16_t)sizeof(double); })
tensor_is_f32_storage	2	({ blorp_Vector* __tensor_layout_@1@ = (blorp_Vector*)@0@; __tensor_layout_@1@ && __tensor_layout_@1@->storage_mode == BLORP_VECTOR_STORAGE_F32 && __tensor_layout_@1@->elem_size == (int16_t)sizeof(float); })
tensor_is_i64_storage	2	({ blorp_Vector* __tensor_layout_@1@ = (blorp_Vector*)@0@; __tensor_layout_@1@ && __tensor_layout_@1@->storage_mode == BLORP_VECTOR_STORAGE_I64 && __tensor_layout_@1@->elem_size == (int16_t)sizeof(long); })
tensor_data_pointer_get_unchecked	2	((blorp_Vector*)@0@)->data[@1@]
tensor_inline_struct_get_unchecked	4	({ blorp_Vector* __tgu_vec_@2@ = (blorp_Vector*)@0@; long __tgu_idx_@2@ = @1@; @3@ __tgu_out_@2@; if (__builtin_expect(__tgu_vec_@2@->storage_mode == BLORP_VECTOR_STORAGE_INLINE && __tgu_vec_@2@->elem_size == sizeof(@3@), 1)) { memcpy(&__tgu_out_@2@, (char*)__tgu_vec_@2@->data + __tgu_idx_@2@ * sizeof(@3@), sizeof(@3@)); } else { void* __tgu_raw_@2@ = __tgu_vec_@2@->data[__tgu_idx_@2@]; __tgu_out_@2@ = blorp_unbox_struct(__tgu_raw_@2@, @3@); } __tgu_out_@2@; })
tensor_get_f64_raw_unchecked	3	({ blorp_Vector* __tensor_raw_vec_@2@ = (blorp_Vector*)@0@; long __tensor_raw_idx_@2@ = @1@; double __tensor_raw_@2@; memcpy(&__tensor_raw_@2@, (char*)__tensor_raw_vec_@2@->data + __tensor_raw_idx_@2@ * sizeof(double), sizeof(double)); __tensor_raw_@2@; })
tensor_get_f32_raw_unchecked	3	({ blorp_Vector* __tensor_raw_vec_@2@ = (blorp_Vector*)@0@; long __tensor_raw_idx_@2@ = @1@; float __tensor_raw_@2@; memcpy(&__tensor_raw_@2@, (char*)__tensor_raw_vec_@2@->data + __tensor_raw_idx_@2@ * sizeof(float), sizeof(float)); __tensor_raw_@2@; })
tensor_alloc_pointer	1	blorp_vector_new(@0@)
tensor_alloc_i64	1	blorp_vector_new_i64(@0@)
tensor_alloc_f64	1	blorp_vector_new_f64(@0@)
tensor_alloc_f32	1	blorp_vector_new_f32(@0@)
tensor_alloc_packed	2	blorp_vector_new_packed(@0@, @1@)
tensor_alloc_sized	2	blorp_vector_new_sized(@0@, sizeof(@1@))
tensor_alloc_with_release	2	({ blorp_Vector* __tensor_alloc_@1@ = @0@; blorp_vector_init_elem_release(__tensor_alloc_@1@, blorp_elem_release_fn); __tensor_alloc_@1@; })
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
tensor_literal_write_inline_struct	5	{ @4@ __ten_elem_@3@ = @2@; memcpy((char*)@0@->data + @1@ * sizeof(@4@), &__ten_elem_@3@, sizeof(@4@)); }
tensor_literal_write_boxed	3	@0@->data[@1@] = @2@;
tensor_literal_write_boxed_owned	4	{ void* __ten_boxed_@3@ = @2@; @0@->data[@1@] = __ten_boxed_@3@; }
tensor_literal_write_boxed_borrowed	4	{ void* __ten_boxed_@3@ = @2@; @0@->data[@1@] = __ten_boxed_@3@; if (__ten_boxed_@3@) blorp_retain(__ten_boxed_@3@); }
|}
