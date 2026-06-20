(** Compile-time evaluator context construction and lookup. *)

open Ctfe_value

let constructor_info ctx name = ctx.constructor_info name

let constructor_arity ctx name =
  Option.map
    (fun (info : constructor_info) -> info.constructor_arity)
    (constructor_info ctx name)

let constructor_is_nullary ctx name = constructor_arity ctx name = Some 0

let function_by_callable_id ctx callable_id =
  List.assoc_opt callable_id ctx.functions

let imported_functions_by_source ctx ~module_path ~source_name =
  match List.assoc_opt (module_path, source_name) ctx.imported_functions with
  | Some funcs -> funcs
  | None -> []

let module_global_env ctx module_path =
  match List.assoc_opt module_path ctx.module_global_envs with
  | Some env -> env
  | None -> []

let module_global_value ctx ~module_path ~name =
  match List.assoc_opt module_path ctx.module_global_envs with
  | None -> None
  | Some env -> (
      match List.assoc_opt name env with
      | Some { binding_value = AvailableValue cell; _ } -> Some !cell
      | Some { binding_value = UnavailableGlobal _; _ } -> None
      | None -> None)

let module_has_global_binding ctx ~module_path ~name =
  match List.assoc_opt module_path ctx.module_global_envs with
  | None -> false
  | Some env -> List.mem_assoc name env

let with_module_global_envs ctx module_global_envs =
  { ctx with module_global_envs }

let nullary_constructor_reference_of_lookup constructor_info name :
    Ctfe_ir.nullary_constructor option =
  match constructor_info name with
  | Some info when info.constructor_arity = 0 ->
      Some
        {
          constructor_name = name;
          constructor_parent_type = info.constructor_parent_type;
          constructor_callable_id = info.constructor_callable_id;
        }
  | Some _ | None -> None

let nullary_constructor_reference ctx name =
  nullary_constructor_reference_of_lookup ctx.constructor_info name

let default_module_alias _ = None
let default_module_has_global ~module_path:_ ~name:_ = false

let make_function ?module_path ?(module_alias = default_module_alias)
    ?(module_has_global = default_module_has_global) ~constructor_info func =
  {
    function_decl = func;
    function_ast = Typed_ast.func_ast func;
    function_module_path = module_path;
    function_module_alias = module_alias;
    function_module_has_global = module_has_global;
    function_constructor_info = constructor_info;
    function_body_cache = ref None;
  }

let function_ast func = func.function_ast

let function_body_ir func =
  match !(func.function_body_cache) with
  | Some result -> result
  | None ->
      let result =
        Ctfe_ir.of_function_body
          ~nullary_constructor:
            (nullary_constructor_reference_of_lookup
               func.function_constructor_info)
          ~module_alias:func.function_module_alias
          ~module_has_global:func.function_module_has_global func.function_decl
      in
      func.function_body_cache := Some result;
      result

let rec collect_functions ?module_path ?(module_alias = default_module_alias)
    ?(module_has_global = default_module_has_global) constructor_info acc decl =
  match Typed_ast.decl_view decl with
  | Typed_ast.DeclFunction func -> (
      match Typed_ast.func_callable_id func with
      | Some callable_id ->
          ( callable_id,
            make_function ?module_path ~module_alias ~module_has_global
              ~constructor_info func )
          :: acc
      | None -> acc)
  | Typed_ast.DeclPrivate inner ->
      collect_functions ?module_path ~module_alias ~module_has_global
        constructor_info acc inner
  | _ -> acc

let collect_imported_function ?module_path
    ?(module_alias = default_module_alias)
    ?(module_has_global = default_module_has_global) constructor_info acc decl =
  match (module_path, Typed_ast.decl_view decl) with
  | Some module_path, Typed_ast.DeclFunction func -> (
      match (Typed_ast.func_ast func).Ast.func_name with
      | Some source_name ->
          let func =
            make_function ~module_path ~module_alias ~module_has_global
              ~constructor_info func
          in
          let key = (module_path, source_name) in
          let existing =
            match List.assoc_opt key acc with Some funcs -> funcs | None -> []
          in
          (key, func :: existing) :: List.remove_assoc key acc
      | None -> acc)
  | _ -> acc

let collect_constructor_decls acc decl =
  let collect_type acc type_decl =
    List.fold_left
      (fun acc variant ->
        ( variant.Ast.variant_name,
          {
            constructor_parent_type = type_decl.Ast.type_name;
            constructor_arity = List.length variant.variant_fields;
            constructor_callable_id = variant.variant_def_id;
          } )
        :: acc)
      acc type_decl.Ast.type_variants
  in
  match (Typed_ast.decl_ast decl).Ast.decl_desc with
  | Ast.DType type_decl -> collect_type acc type_decl
  | Ast.DPrivate inner -> (
      match inner.Ast.decl_desc with
      | Ast.DType type_decl -> collect_type acc type_decl
      | _ -> acc)
  | _ -> acc

let program_constructor_decls program =
  List.fold_left collect_constructor_decls [] (Typed_ast.program_decls program)

let collect_program_functions ?module_path
    ?(module_alias = default_module_alias)
    ?(module_has_global = default_module_has_global) constructor_info program
    acc =
  List.fold_left
    (collect_functions ?module_path ~module_alias ~module_has_global
       constructor_info)
    acc
    (Typed_ast.program_decls program)

let collect_imported_program_functions ?(module_has_global = default_module_has_global)
    constructor_info imported_programs =
  List.fold_left
    (fun acc (module_path, program, module_alias) ->
      List.fold_left
        (collect_imported_function ~module_path ~module_alias
           ~module_has_global constructor_info)
        acc
        (Typed_ast.program_decls program))
    [] imported_programs

let of_program ?(fallback_constructor_info = fun _ -> None)
    ?(module_alias = default_module_alias)
    ?(module_has_global = default_module_has_global) ?(imported_programs = [])
    (program : Typed_ast.program) =
  let constructors =
    List.fold_left
      (fun acc (_, imported_program, _) ->
        List.rev_append (program_constructor_decls imported_program) acc)
      (program_constructor_decls program)
      imported_programs
  in
  let constructor_info name =
    match List.assoc_opt name constructors with
    | Some info -> Some info
    | None -> fallback_constructor_info name
  in
  let functions =
    let imported =
      List.fold_left
        (fun acc (module_path, imported_program, imported_module_alias) ->
          collect_program_functions ~module_path
            ~module_alias:imported_module_alias ~module_has_global
            constructor_info
            imported_program acc)
        [] imported_programs
    in
    collect_program_functions ~module_alias ~module_has_global constructor_info
      program imported
  in
  let imported_functions =
    collect_imported_program_functions ~module_has_global constructor_info
      imported_programs
  in
  {
    functions;
    imported_functions;
    module_global_envs = [];
    module_alias;
    module_has_global;
    constructor_info;
  }
