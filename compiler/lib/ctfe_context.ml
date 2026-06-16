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

let make_function ~constructor_info func =
  {
    function_decl = func;
    function_ast = Typed_ast.func_ast func;
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
          func.function_decl
      in
      func.function_body_cache := Some result;
      result

let rec collect_functions constructor_info acc decl =
  match Typed_ast.decl_view decl with
  | Typed_ast.DeclFunction func -> (
      match Typed_ast.func_callable_id func with
      | Some callable_id ->
          (callable_id, make_function ~constructor_info func) :: acc
      | None -> acc)
  | Typed_ast.DeclPrivate inner -> collect_functions constructor_info acc inner
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
  let constructors =
    List.fold_left collect_constructor_decls []
      (Typed_ast.program_decls program)
  in
  let constructor_info name =
    match List.assoc_opt name constructors with
    | Some info -> Some info
    | None -> fallback_constructor_info name
  in
  let functions =
    List.fold_left
      (collect_functions constructor_info)
      []
      (Typed_ast.program_decls program)
  in
  { functions; constructor_info }
