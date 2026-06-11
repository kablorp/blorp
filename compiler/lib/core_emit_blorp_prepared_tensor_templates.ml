(* Generated from core_emit_blorp_prepared_tensor_templates.tsv by
   compiler/blorp/codegen_prepared_tensor_renderer.brp. *)

let tsv =
  {|tensor_raw_view_decl	3	@0@ @1@ = (@0@)((blorp_Vector*)@2@)->data
tensor_raw_read	2	@0@[@1@]
tensor_raw_write_expr	3	({ @0@[@1@] = @2@; (void)0; })
tensor_raw_write_stmt	3	@0@[@1@] = @2@;
|}
