(* Generated from core_emit_blorp_prepared_constructor_templates.tsv by
   compiler/blorp/codegen_prepared_constructor_renderer.brp. *)

let tsv =
  {|
backend_constructor_call	2	@0@(@1@)
backend_constructor_symbol	1	@0@
backend_constructor_nullable_none	0	NULL
backend_constructor_nullable_payload	1	@0@
backend_constructor_stack_option_value	3	((@0@){ .tag = @1@, .value = @2@ })
backend_constructor_stack_option_void_statement	3	({ @2@ ((@0@){ .tag = @1@, .value = 0 }); })
backend_constructor_stack_option_none	3	((@0@){ .tag = @1@, .value = @2@ })
backend_constructor_stack_result_payload	5	((@0@){ .tag = @1@, .release_mask = @4@UL, .data.@2@.field0 = @3@ })
|}
