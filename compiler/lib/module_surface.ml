type symbol_kind =
  | Function
  | Variable
  | Type
  | Record
  | TypeAlias
  | Trait
  | TraitMethod
  | ImplMethod

type symbol_source =
  | Decl of int
  | TraitMethod of int * int
  | ImplMethod of int * int
  | PrivateDecl of int
  | PrivateTraitMethod of int * int
  | PrivateImplMethod of int * int

type symbol = {
  name : string;
  kind : symbol_kind;
  source : symbol_source;
}

type import = { module_path : string }

type t = {
  module_name : string;
  imports : import list;
  exports : symbol list;
  private_names : symbol list;
  private_traits : string list;
}

let symbol_kind_name = function
  | Function -> "function"
  | Variable -> "variable"
  | Type -> "type"
  | Record -> "record"
  | TypeAlias -> "type_alias"
  | Trait -> "trait"
  | TraitMethod -> "trait_method"
  | ImplMethod -> "impl_method"

let symbol_kind_of_string = function
  | "function" -> Ok Function
  | "variable" -> Ok Variable
  | "type" -> Ok Type
  | "record" -> Ok Record
  | "type_alias" -> Ok TypeAlias
  | "trait" -> Ok Trait
  | "trait_method" -> Ok TraitMethod
  | "impl_method" -> Ok ImplMethod
  | other -> Error ("unsupported module surface symbol kind `" ^ other ^ "`")

let export_names surface = List.map (fun symbol -> symbol.name) surface.exports

let private_names surface =
  List.map (fun symbol -> symbol.name) surface.private_names

let import_module_names surface =
  List.map (fun import -> import.module_path) surface.imports

let decl_at program index =
  if index < 0 then None else List.nth_opt program index

let method_at methods index =
  if index < 0 then None else List.nth_opt methods index

let validate_decl_source program symbol index =
  match decl_at program index with
  | Some _ -> Ok ()
  | None ->
      Error
        (Printf.sprintf "module surface symbol `%s` references missing decl %d"
           symbol.name index)

let validate_trait_method_source program symbol index method_index =
  match decl_at program index with
  | Some { Ast.decl_desc = Ast.DTrait trait; _ } -> (
      match method_at trait.trait_methods method_index with
      | Some _ -> Ok ()
      | None ->
          Error
            (Printf.sprintf
               "module surface symbol `%s` references missing trait method %d \
                on decl %d"
               symbol.name method_index index))
  | Some _ ->
      Error
        (Printf.sprintf
           "module surface symbol `%s` references decl %d as a trait method \
            source, but it is not a trait"
           symbol.name index)
  | None ->
      Error
        (Printf.sprintf "module surface symbol `%s` references missing decl %d"
           symbol.name index)

let validate_impl_method_source program symbol index method_index =
  match decl_at program index with
  | Some { Ast.decl_desc = Ast.DImpl impl; _ } -> (
      match method_at impl.impl_methods method_index with
      | Some _ -> Ok ()
      | None ->
          Error
            (Printf.sprintf
               "module surface symbol `%s` references missing impl method %d \
                on decl %d"
               symbol.name method_index index))
  | Some _ ->
      Error
        (Printf.sprintf
           "module surface symbol `%s` references decl %d as an impl method \
            source, but it is not an impl"
           symbol.name index)
  | None ->
      Error
        (Printf.sprintf "module surface symbol `%s` references missing decl %d"
           symbol.name index)

let validate_private_decl_source program symbol index =
  match decl_at program index with
  | Some { Ast.decl_desc = Ast.DPrivate _; _ } -> Ok ()
  | Some _ ->
      Error
        (Printf.sprintf
           "module surface symbol `%s` references decl %d as private, but it \
            is not private"
           symbol.name index)
  | None ->
      Error
        (Printf.sprintf "module surface symbol `%s` references missing decl %d"
           symbol.name index)

let validate_private_trait_method_source program symbol index method_index =
  match decl_at program index with
  | Some
      { Ast.decl_desc = Ast.DPrivate { decl_desc = Ast.DTrait trait; _ }; _ } -> (
      match method_at trait.trait_methods method_index with
      | Some _ -> Ok ()
      | None ->
          Error
            (Printf.sprintf
               "module surface symbol `%s` references missing private trait \
                method %d on decl %d"
               symbol.name method_index index))
  | Some _ ->
      Error
        (Printf.sprintf
           "module surface symbol `%s` references decl %d as a private trait \
            method source, but it is not a private trait"
           symbol.name index)
  | None ->
      Error
        (Printf.sprintf "module surface symbol `%s` references missing decl %d"
           symbol.name index)

let validate_private_impl_method_source program symbol index method_index =
  match decl_at program index with
  | Some { Ast.decl_desc = Ast.DPrivate { decl_desc = Ast.DImpl impl; _ }; _ }
    -> (
      match method_at impl.impl_methods method_index with
      | Some _ -> Ok ()
      | None ->
          Error
            (Printf.sprintf
               "module surface symbol `%s` references missing private impl \
                method %d on decl %d"
               symbol.name method_index index))
  | Some _ ->
      Error
        (Printf.sprintf
           "module surface symbol `%s` references decl %d as a private impl \
            method source, but it is not a private impl"
           symbol.name index)
  | None ->
      Error
        (Printf.sprintf "module surface symbol `%s` references missing decl %d"
           symbol.name index)

let validate_symbol_source program symbol =
  match symbol.source with
  | Decl index -> validate_decl_source program symbol index
  | PrivateDecl index -> validate_private_decl_source program symbol index
  | TraitMethod (index, method_index) ->
      validate_trait_method_source program symbol index method_index
  | ImplMethod (index, method_index) ->
      validate_impl_method_source program symbol index method_index
  | PrivateTraitMethod (index, method_index) ->
      validate_private_trait_method_source program symbol index method_index
  | PrivateImplMethod (index, method_index) ->
      validate_private_impl_method_source program symbol index method_index

let decl_symbol_identity = function
  | Ast.DFunc f -> Option.map (fun name -> (name, Function)) f.func_name
  | Ast.DVar v -> Option.map (fun name -> (name, Variable)) v.var_name
  | Ast.DType t -> Some (t.type_name, Type)
  | Ast.DRecord r -> Some (r.record_name, Record)
  | Ast.DTypeAlias a -> Some (a.alias_name, TypeAlias)
  | Ast.DTrait t -> Some (t.trait_name, Trait)
  | Ast.DImport _ | Ast.DImpl _ | Ast.DPrivate _ -> None

let trait_method_symbol_identity trait method_index =
  Option.map
    (fun meth -> (meth.Ast.method_name, (TraitMethod : symbol_kind)))
    (method_at trait.Ast.trait_methods method_index)

let impl_method_symbol_identity impl method_index =
  match method_at impl.Ast.impl_methods method_index with
  | Some func ->
      Option.map
        (fun name -> (name, (ImplMethod : symbol_kind)))
        func.Ast.func_name
  | None -> None

let symbol_identity_for_source program = function
  | Decl index -> (
      match decl_at program index with
      | Some decl -> decl_symbol_identity decl.Ast.decl_desc
      | None -> None)
  | TraitMethod (index, method_index) -> (
      match decl_at program index with
      | Some { Ast.decl_desc = Ast.DTrait trait; _ } ->
          trait_method_symbol_identity trait method_index
      | _ -> None)
  | ImplMethod (index, method_index) -> (
      match decl_at program index with
      | Some { Ast.decl_desc = Ast.DImpl impl; _ } ->
          impl_method_symbol_identity impl method_index
      | _ -> None)
  | PrivateDecl index -> (
      match decl_at program index with
      | Some { Ast.decl_desc = Ast.DPrivate inner; _ } ->
          decl_symbol_identity inner.decl_desc
      | _ -> None)
  | PrivateTraitMethod (index, method_index) -> (
      match decl_at program index with
      | Some { Ast.decl_desc = Ast.DPrivate inner; _ } -> (
          match inner.decl_desc with
          | Ast.DTrait trait -> trait_method_symbol_identity trait method_index
          | _ -> None)
      | _ -> None)
  | PrivateImplMethod (index, method_index) -> (
      match decl_at program index with
      | Some { Ast.decl_desc = Ast.DPrivate inner; _ } -> (
          match inner.decl_desc with
          | Ast.DImpl impl -> impl_method_symbol_identity impl method_index
          | _ -> None)
      | _ -> None)

let validate_symbol_identity program symbol =
  match symbol_identity_for_source program symbol.source with
  | None ->
      Error
        (Printf.sprintf
           "module surface symbol `%s` does not reference an exportable \
            declaration or method"
           symbol.name)
  | Some (expected_name, expected_kind)
    when expected_name = symbol.name && expected_kind = symbol.kind ->
      Ok ()
  | Some (expected_name, expected_kind) ->
      Error
        (Printf.sprintf
           "module surface symbol `%s` (%s) does not match referenced symbol \
            `%s` (%s)"
           symbol.name (symbol_kind_name symbol.kind) expected_name
           (symbol_kind_name expected_kind))

let validate_against_program program surface =
  let rec validate_symbols = function
    | [] -> Ok ()
    | symbol :: rest -> (
        match validate_symbol_source program symbol with
        | Ok () -> (
            match validate_symbol_identity program symbol with
            | Ok () -> validate_symbols rest
            | Error _ as error -> error)
        | Error _ as error -> error)
  in
  match validate_symbols surface.exports with
  | Error _ as error -> error
  | Ok () -> validate_symbols surface.private_names

let impl_method_export_decl decl ~method_index =
  match decl.Ast.decl_desc with
  | Ast.DImpl impl -> (
      match method_at impl.impl_methods method_index with
      | Some func -> Some { decl with decl_desc = Ast.DFunc func }
      | None -> None)
  | _ -> None

let decl_for_symbol_source program source =
  match source with
  | Decl index -> decl_at program index
  | TraitMethod (index, method_index) -> (
      match decl_at program index with
      | Some ({ Ast.decl_desc = Ast.DTrait trait; _ } as decl)
        when Option.is_some (method_at trait.trait_methods method_index) ->
          Some decl
      | _ -> None)
  | ImplMethod (index, method_index) -> (
      match decl_at program index with
      | Some decl -> impl_method_export_decl decl ~method_index
      | None -> None)
  | PrivateDecl index -> (
      match decl_at program index with
      | Some { Ast.decl_desc = Ast.DPrivate inner; _ } -> Some inner
      | _ -> None)
  | PrivateTraitMethod (index, method_index) -> (
      match decl_at program index with
      | Some { Ast.decl_desc = Ast.DPrivate inner; _ } -> (
          match inner.decl_desc with
          | Ast.DTrait trait
            when Option.is_some (method_at trait.trait_methods method_index) ->
              Some inner
          | _ -> None)
      | _ -> None)
  | PrivateImplMethod (index, method_index) -> (
      match decl_at program index with
      | Some { Ast.decl_desc = Ast.DPrivate inner; _ } ->
          impl_method_export_decl inner ~method_index
      | _ -> None)

let symbols_as_ast_pairs program symbols =
  List.filter_map
    (fun symbol ->
      Option.map
        (fun decl -> (symbol.name, decl))
        (decl_for_symbol_source program symbol.source))
    symbols

let exports_as_ast_pairs program surface =
  symbols_as_ast_pairs program surface.exports

let private_names_as_ast_pairs program surface =
  symbols_as_ast_pairs program surface.private_names
