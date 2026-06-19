(* Generated from core_emit_blorp_static_constant_templates.tsv by
   compiler/blorp/codegen_static_constant_renderer.brp. *)

let tsv =
  {|
static_string_object	4	static struct { blorp_Object header; long len; long capacity; char data[@1@]; } @0@ = { { BLORP_IMMORTAL_REFCOUNT, BLORP_ALLOC_CLASS_DIRECT, 0 }, @2@L, @2@L, "@3@" };
static_tuple_object	5	static struct { blorp_Object header; long arity; long release_mask; void* elem[@1@]; } @0@ = { .header = { BLORP_IMMORTAL_REFCOUNT, BLORP_ALLOC_CLASS_DIRECT, 0 }, .arity = @2@L, .release_mask = @3@UL, .elem = { @4@ } };
static_pointer_list_object	6	static struct { blorp_Object header; long len; long capacity; void (*elem_release)(void*); int16_t elem_size; uint8_t storage_mode; char __pad[@1@]; void* data[@2@]; } @0@ = { { BLORP_IMMORTAL_REFCOUNT, BLORP_ALLOC_CLASS_DIRECT, 0 }, @3@L, @2@L, @4@, (int16_t)sizeof(void*), BLORP_LIST_STORAGE_POINTER, { 0 }, { @5@ } };
static_inline_list_object	7	static struct { blorp_Object header; long len; long capacity; void (*elem_release)(void*); int16_t elem_size; uint8_t storage_mode; char __pad[@1@]; @2@ data[@3@]; } @0@ = { { BLORP_IMMORTAL_REFCOUNT, BLORP_ALLOC_CLASS_DIRECT, 0 }, @4@L, @3@L, NULL, (int16_t)@5@, BLORP_LIST_STORAGE_INLINE, { 0 }, { @6@ } };
static_record_object	3	static @0@ @1@ = { { BLORP_IMMORTAL_REFCOUNT, BLORP_ALLOC_CLASS_DIRECT, 0 }@2@ };
static_union_object	5	static @0@ @1@ = { .header = { BLORP_IMMORTAL_REFCOUNT, BLORP_ALLOC_CLASS_DIRECT, 0 }, .tag = @2@, .data.@3@ = { @4@ } };
static_string_global_pointer	2	static blorp_String* @0@ = (blorp_String*)&@1@;
static_list_global_pointer	2	static blorp_List* @0@ = (blorp_List*)&@1@;
static_tuple_global_pointer	2	static blorp_Tuple* @0@ = (blorp_Tuple*)&@1@;
static_typed_pointer_global	3	static @0@ @1@ = (@0@)&@2@;
static_stack_result_initializer	4	{ .tag = @0@, .release_mask = @1@UL, .data.@2@.field0 = @3@ }
static_stack_value_global	3	static @0@ @1@ = @2@;
static_scalar_global	3	static @0@ @1@ = @2@;
static_uninitialized_global	2	static @0@ @1@;
static_string_storage_name	1	__blorp_static_string_@0@
static_list_storage_name	1	__blorp_static_list_@0@
static_tuple_storage_name	1	__blorp_static_tuple_@0@
static_record_storage_name	1	__blorp_static_record_@0@
static_union_storage_name	1	__blorp_static_union_@0@
static_child_path	2	@0@_@1@
static_list_child_path	2	@0@_elem_@1@
static_tuple_child_path	2	@0@_@1@
static_union_child_path	3	@0@_@1@_@2@
static_string_pointer_initializer	1	(blorp_String*)&@0@
static_list_pointer_initializer	1	(blorp_List*)&@0@
static_tuple_pointer_initializer	1	(blorp_Tuple*)&@0@
static_typed_pointer_initializer	2	(@0@)&@1@
static_pointer_slot_initializer	1	(void*)@0@
static_primitive_slot_initializer	1	(void*)(long)(@0@)
static_void_slot_initializer	0	(void*)0
static_inline_element_cast_initializer	2	((@0@)(@1@))
|}
