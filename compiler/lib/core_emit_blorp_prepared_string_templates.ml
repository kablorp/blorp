(* Generated from core_emit_blorp_prepared_string_templates.tsv by
   compiler/blorp/codegen_prepared_string_renderer.brp. *)

let tsv =
  {|string_find_byte_from	4	({ blorp_String* __string_find_src_@3@ = (blorp_String*)@0@; long __string_find_byte_@3@ = @1@; long __string_find_start_@3@ = @2@; blorp_string_find_byte_from(__string_find_src_@3@, __string_find_byte_@3@, __string_find_start_@3@); })
string_byte_read	2	(long)(unsigned char)((blorp_String*)@0@)->data[@1@]
string_byte_write	3	(((blorp_String*)@0@)->data[@1@] = (char)@2@)
string_byte_copy	6	({ blorp_String* __string_copy_dst_@5@ = (blorp_String*)@0@; long __string_copy_dst_pos_@5@ = @1@; blorp_String* __string_copy_src_@5@ = (blorp_String*)@2@; long __string_copy_src_pos_@5@ = @3@; long __string_copy_len_@5@ = @4@; if (__string_copy_len_@5@ > 0) { memcpy(__string_copy_dst_@5@->data + __string_copy_dst_pos_@5@, __string_copy_src_@5@->data + __string_copy_src_pos_@5@, (size_t)__string_copy_len_@5@); } (void)0; })
string_set_len	2	({ blorp_String* __sl = (blorp_String*)@0@; long __sn = @1@; __sl->len = __sn; __sl->data[__sn] = '\0'; (void)0; })
|}
