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

let rec collect_functions acc decl =
  match Typed_ast.decl_view decl with
  | Typed_ast.DeclFunction func -> (
      match Typed_ast.func_callable_id func with
      | Some callable_id -> (callable_id, func) :: acc
      | None -> acc)
  | Typed_ast.DeclPrivate inner -> collect_functions acc inner
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

let of_program ?(fallback_constructor_info = fun _ -> None)
    (program : Typed_ast.program) =
  let functions =
    List.fold_left collect_functions [] (Typed_ast.program_decls program)
  in
  let constructors =
    List.fold_left collect_constructor_decls []
      (Typed_ast.program_decls program)
  in
  let constructor_info name =
    match List.assoc_opt name constructors with
    | Some info -> Some info
    | None -> fallback_constructor_info name
  in
  { functions; constructor_info }
