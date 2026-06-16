(* Generated from core_emit_blorp_prepared_set_templates.tsv by
   compiler/blorp/codegen_prepared_set_renderer.brp. *)

let tsv =
  {|
set_iter_source_binding	2	blorp_Set* @0@ = (blorp_Set*)@1@;
set_iter_retain	1	blorp_retain(@0@);
set_iter_loop_open	2	for (blorp_SetEntry* @0@ = @1@->first; @0@ != NULL; @0@ = @0@->next_order) {
set_iter_entry_key	1	@0@->key
set_iter_release	1	blorp_release(@0@);
|}
