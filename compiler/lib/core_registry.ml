(** Populate the shared code-generation type registry from lowered Core.

    Registry construction is a phase-boundary operation, not a flattening
    concern.  Keeping it here lets either the former OCaml lowerer or the
    Blorp prepared-Core boundary feed the remaining middle passes without
    coupling them to module-name rewriting. *)

let register_types (reg : Codegen_types.registry) (program : Core.core_program) =
  let rec seed decl =
    match decl.Core.cd_desc with
    | Core.CDTypeAlias alias ->
        Hashtbl.replace reg.type_aliases alias.alias_name
          (Ast.type_param_names alias.alias_type_params, alias.alias_target)
    | Core.CDType type_decl when type_decl.type_is_enum ->
        Codegen_types.register_enum_type reg type_decl.type_name
          type_decl.type_variants
    | Core.CDType type_decl when not type_decl.type_is_builtin ->
        Codegen_types.register_union_variants reg type_decl.type_name
          type_decl.type_variants;
        Codegen_types.register_union_type reg type_decl.type_name
          ~payload_storage:(Codegen_types.source_union_payload_storage type_decl)
          ~destructor:
            (Codegen_types.GeneratedDestructor (type_decl.type_name ^ "_destroy"))
    | Core.CDRecord record when record.record_is_builtin -> ()
    | Core.CDRecord record when record.record_is_value ->
        Hashtbl.replace reg.value_records record.record_name ()
    | Core.CDRecord record ->
        Codegen_types.register_heap_record_type reg record.record_name
          ~destructor:
            (Codegen_types.GeneratedDestructor (record.record_name ^ "_destroy"))
    | Core.CDPrivate inner -> seed inner
    | _ -> ()
  in
  let rec refine decl =
    match decl.Core.cd_desc with
    | Core.CDType type_decl
      when (not type_decl.type_is_enum) && not type_decl.type_is_builtin ->
        Codegen_types.register_union_type reg type_decl.type_name
          ~payload_storage:(Codegen_types.source_union_payload_storage type_decl)
          ~destructor:(Core_layout_type.union_destructor_policy ~reg type_decl)
    | Core.CDRecord record
      when (not record.record_is_value) && not record.record_is_builtin ->
        Codegen_types.register_heap_record_type reg record.record_name
          ~destructor:(Core_layout_type.record_destructor_policy ~reg record)
    | Core.CDPrivate inner -> refine inner
    | _ -> ()
  in
  List.iter seed program;
  List.iter refine program
