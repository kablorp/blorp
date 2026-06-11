(* Generated from core_emit_blorp_prepared_list_templates.tsv by
   compiler/blorp/codegen_prepared_list_renderer.brp. *)

let tsv =
  {|list_get_pointer	2	blorp_list_get((blorp_List*)@0@, @1@)
list_get_inline_checked	6	({ blorp_List* @2@ = (blorp_List*)@0@; long @3@ = @1@; (__builtin_expect(!@2@ || @3@ < 0 || @3@ >= @2@->len, 0) ? NULL : ({ uintptr_t @4@ = 0; memcpy(&@4@, (char*)@2@->data + @3@ * @5@, @5@); (void*)@4@; })); })
list_get_inline_proven	6	({ blorp_List* @2@ = (blorp_List*)@0@; long @3@ = @1@; ({ uintptr_t @4@ = 0; memcpy(&@4@, (char*)@2@->data + @3@ * @5@, @5@); (void*)@4@; }); })
list_inline_bits_load	4	uintptr_t @2@ = 0; memcpy(&@2@, (char*)@0@->data + @1@ * @3@, @3@);
list_inline_struct_load_checked	5	if (__builtin_expect(!@0@ || @1@ < 0 || @1@ >= @0@->len, 0)) { memset(&@2@, 0, sizeof(@4@)); } else if (@0@->storage_mode == BLORP_LIST_STORAGE_INLINE && @0@->elem_size == (int16_t)sizeof(@4@)) { memcpy(&@2@, (char*)@0@->data + @1@ * sizeof(@4@), sizeof(@4@)); } else { void* @3@ = blorp_list_get(@0@, @1@); if (!@3@) { memset(&@2@, 0, sizeof(@4@)); } else { @2@ = blorp_unbox_struct(@3@, @4@); } }
list_inline_struct_load_proven	5	if (@0@->storage_mode == BLORP_LIST_STORAGE_INLINE && @0@->elem_size == (int16_t)sizeof(@4@)) { memcpy(&@2@, (char*)@0@->data + @1@ * sizeof(@4@), sizeof(@4@)); } else { void* @3@ = blorp_list_get(@0@, @1@); if (!@3@) { memset(&@2@, 0, sizeof(@4@)); } else { @2@ = blorp_unbox_struct(@3@, @4@); } }
|}
