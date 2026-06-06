(* Generated from core_emit_blorp_intrinsic_templates.tsv by
   tools/compiler/codegen_intrinsic_renderer.brp. *)

let tsv =
  {|math_sin	1	sin(@0@)
math_cos	1	cos(@0@)
math_tan	1	tan(@0@)
math_asin	1	asin(@0@)
math_acos	1	acos(@0@)
math_atan	1	atan(@0@)
math_sinh	1	sinh(@0@)
math_cosh	1	cosh(@0@)
math_tanh	1	tanh(@0@)
math_asinh	1	asinh(@0@)
math_acosh	1	acosh(@0@)
math_atanh	1	atanh(@0@)
math_exp	1	exp(@0@)
math_exp2	1	exp2(@0@)
math_expm1	1	expm1(@0@)
math_log	1	log(@0@)
math_log2	1	log2(@0@)
math_log10	1	log10(@0@)
math_log1p	1	log1p(@0@)
math_sqrt	1	sqrt(@0@)
math_cbrt	1	cbrt(@0@)
math_floor	1	floor(@0@)
math_ceil	1	ceil(@0@)
math_trunc	1	trunc(@0@)
math_pow	2	pow(@0@, @1@)
math_atan2	2	atan2(@0@, @1@)
math_hypot	2	hypot(@0@, @1@)
math_fmod	2	fmod(@0@, @1@)
math_copysign	2	copysign(@0@, @1@)
math_fma	3	fma(@0@, @1@, @2@)
math_infinity	0	(1.0/0.0)
math_neg_infinity	0	(-1.0/0.0)
math_nan	0	(0.0/0.0)
math_is_nan	1	isnan(@0@)
math_is_inf	1	isinf(@0@)
math_is_finite	1	isfinite(@0@)
bit_and	2	(@0@ & @1@)
bit_or	2	(@0@ | @1@)
bit_xor	2	(@0@ ^ @1@)
bit_not	1	(~@0@)
shift_left	2	((long)(@0@ << (@1@ & 63)))
shift_right	2	((long)(@0@ >> (@1@ & 63)))
list_len	1	((blorp_List*)@0@)->len
list_capacity	1	((blorp_List*)@0@)->capacity
string_len	1	((blorp_String*)@0@)->len
bytes_len	1	((blorp_Bytes*)@0@)->len
dict_len	1	((blorp_Dict*)@0@)->size
set_len	1	((blorp_Set*)@0@)->size
set_capacity	1	((blorp_Set*)@0@)->capacity
set_mask	1	((blorp_Set*)@0@)->mask
set_bucket	2	((void*)((blorp_Set*)@0@)->buckets[@1@])
set_first	1	((void*)((blorp_Set*)@0@)->first)
set_last	1	((void*)((blorp_Set*)@0@)->last)
set_entry_key	1	((blorp_SetEntry*)@0@)->key
set_entry_next	1	((void*)((blorp_SetEntry*)@0@)->next)
set_entry_prev_order	1	((void*)((blorp_SetEntry*)@0@)->prev_order)
set_entry_next_order	1	((void*)((blorp_SetEntry*)@0@)->next_order)
dict_capacity	1	((blorp_Dict*)@0@)->capacity
dict_mask	1	((blorp_Dict*)@0@)->mask
dict_grow_at	1	((blorp_Dict*)@0@)->grow_at
dict_key_at	2	((blorp_Dict*)@0@)->keys[@1@]
dict_value_at	2	((blorp_Dict*)@0@)->values[@1@]
dict_meta_get	2	((long)((blorp_Dict*)@0@)->meta[@1@])
dict_order_get	2	((blorp_Dict*)@0@)->order[@1@]
dict_order_len	1	((blorp_Dict*)@0@)->order_len
dict_order_index_get	2	((blorp_Dict*)@0@)->order_index[@1@]
dict_key_release_fn	1	((void*)((blorp_Dict*)@0@)->key_release)
dict_value_release_fn	1	((void*)((blorp_Dict*)@0@)->value_release)
slice_source	1	((void*)((blorp_StringSlice*)@0@)->source)
slice_start	1	((blorp_StringSlice*)@0@)->start
slice_len	1	((blorp_StringSlice*)@0@)->len
tensor_len	1	((blorp_Vector*)@0@)->len
tensor_capacity	1	((blorp_Vector*)@0@)->capacity
fixed_value	1	((blorp_Fixed*)@0@)->value
fixed_scale	1	(long)((blorp_Fixed*)@0@)->scale
fixed_precision	1	(long)((blorp_Fixed*)@0@)->precision|}
