(* Generated from core_emit_blorp_prepared_string_templates.tsv by
   compiler/blorp/codegen_prepared_string_renderer.brp. *)

let tsv =
  {|string_find_byte_from	6	({ blorp_String* @3@ = (blorp_String*)@0@; long @4@ = @1@; long @5@ = @2@; blorp_string_find_byte_from(@3@, @4@, @5@); })
string_byte_read	2	(long)(unsigned char)((blorp_String*)@0@)->data[@1@]
string_byte_write	3	(((blorp_String*)@0@)->data[@1@] = (char)@2@)
string_byte_copy	10	({ blorp_String* @5@ = (blorp_String*)@0@; long @6@ = @1@; blorp_String* @7@ = (blorp_String*)@2@; long @8@ = @3@; long @9@ = @4@; if (@9@ > 0) { memcpy(@5@->data + @6@, @7@->data + @8@, (size_t)@9@); } (void)0; })
string_set_len	4	({ blorp_String* @2@ = (blorp_String*)@0@; long @3@ = @1@; @2@->len = @3@; @2@->data[@3@] = '\0'; (void)0; })
|}
