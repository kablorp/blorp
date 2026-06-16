(* Generated from core_emit_blorp_prepared_tuple_templates.tsv by
   compiler/blorp/codegen_prepared_tuple_renderer.brp. *)

let tsv =
  {|
tuple_name	1	__tup_@0@
tuple_arg	1	, @0@
tuple_construct	2	blorp_tuple_new(@0@@1@)
tuple_retain_elem	2	if (@0@->elem[@1@]) blorp_retain(@0@->elem[@1@]);
tuple_construct_with_rc	5	({ blorp_Tuple* @0@ = blorp_tuple_new(@1@@2@); @3@ blorp_tuple_set_rc(@0@, @4@UL); @0@; })
tuple_field_element	2	((blorp_Tuple*)@0@)->elem[@1@]
tuple_field_access	3	({ void* @0@ = (void*)@1@; @2@; })
|}
