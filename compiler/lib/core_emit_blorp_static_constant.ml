(** Blorp-owned static constant declaration templates.

    OCaml owns constant eligibility, nested storage emission, and C identifier
    escaping. This module is a typed facade; JSON transfer to Blorp-owned
    template data goes through [Compiler_blorp_bridge]. *)

let renderer = Compiler_blorp_bridge.static_constant_renderer
let render_template op args = Compiler_blorp_bridge.render_exn ~renderer ~op args

let render_string_object ~storage ~data_len ~byte_len ~escaped_text =
  render_template "static_string_object"
    [ storage; data_len; byte_len; escaped_text ]

let render_tuple_object ~storage ~storage_slots ~arity ~release_mask
    ~element_initializers =
  render_template "static_tuple_object"
    [ storage; storage_slots; arity; release_mask; element_initializers ]

let render_pointer_list_object ~storage ~padding_bytes ~capacity ~elem_count
    ~elem_release ~element_initializers =
  render_template "static_pointer_list_object"
    [
      storage;
      padding_bytes;
      capacity;
      elem_count;
      elem_release;
      element_initializers;
    ]

let render_inline_list_object ~storage ~padding_bytes ~storage_c_type ~capacity
    ~elem_count ~elem_size ~element_initializers =
  render_template "static_inline_list_object"
    [
      storage;
      padding_bytes;
      storage_c_type;
      capacity;
      elem_count;
      elem_size;
      element_initializers;
    ]

let render_record_object ~c_type ~storage ~field_initializer_tail =
  render_template "static_record_object"
    [ c_type; storage; field_initializer_tail ]

let render_union_object ~c_type ~storage ~tag ~variant ~field_initializers =
  render_template "static_union_object"
    [ c_type; storage; tag; variant; field_initializers ]

let render_string_global_pointer ~name ~storage =
  render_template "static_string_global_pointer" [ name; storage ]

let render_list_global_pointer ~name ~storage =
  render_template "static_list_global_pointer" [ name; storage ]

let render_tuple_global_pointer ~name ~storage =
  render_template "static_tuple_global_pointer" [ name; storage ]

let render_typed_pointer_global ~c_type ~name ~storage =
  render_template "static_typed_pointer_global" [ c_type; name; storage ]

let render_stack_result_initializer ~tag ~release_mask ~field ~payload =
  render_template "static_stack_result_initializer"
    [ tag; release_mask; field; payload ]

let render_stack_value_global ~c_type ~name ~init_expr =
  render_template "static_stack_value_global" [ c_type; name; init_expr ]

let render_scalar_global ~c_type ~name ~init_expr =
  render_template "static_scalar_global" [ c_type; name; init_expr ]

let render_uninitialized_global ~c_type ~name =
  render_template "static_uninitialized_global" [ c_type; name ]

let render_string_storage_name ~name =
  render_template "static_string_storage_name" [ name ]

let render_list_storage_name ~name =
  render_template "static_list_storage_name" [ name ]

let render_tuple_storage_name ~name =
  render_template "static_tuple_storage_name" [ name ]

let render_record_storage_name ~name =
  render_template "static_record_storage_name" [ name ]

let render_union_storage_name ~name =
  render_template "static_union_storage_name" [ name ]

let render_child_path ~parent ~child =
  render_template "static_child_path" [ parent; child ]

let render_list_child_path ~parent ~index =
  render_template "static_list_child_path" [ parent; index ]

let render_tuple_child_path ~parent ~index =
  render_template "static_tuple_child_path" [ parent; index ]

let render_union_child_path ~parent ~variant ~index =
  render_template "static_union_child_path" [ parent; variant; index ]

let render_string_pointer_initializer ~storage =
  render_template "static_string_pointer_initializer" [ storage ]

let render_list_pointer_initializer ~storage =
  render_template "static_list_pointer_initializer" [ storage ]

let render_tuple_pointer_initializer ~storage =
  render_template "static_tuple_pointer_initializer" [ storage ]

let render_typed_pointer_initializer ~c_type ~storage =
  render_template "static_typed_pointer_initializer" [ c_type; storage ]

let render_pointer_slot_initializer ~expression =
  render_template "static_pointer_slot_initializer" [ expression ]

let render_primitive_slot_initializer ~expression =
  render_template "static_primitive_slot_initializer" [ expression ]

let render_void_slot_initializer () =
  render_template "static_void_slot_initializer" []

let render_inline_element_cast_initializer ~c_type ~expression =
  render_template "static_inline_element_cast_initializer" [ c_type; expression ]
