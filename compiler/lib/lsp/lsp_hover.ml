(** LSP hover info generation.

    Produces markdown-formatted hover text for expressions and
    declarations, showing type signatures and documentation. *)

open Ast

let type_to_string = Types.type_to_string

let expr_type_view ?fallback_ty (e : expr) =
  match e.expr_type_info with
  | Some info -> Some (Type_metadata_format.hover_type_view ?fallback_ty info)
  | None -> (
      match fallback_ty with
      | Some ty -> Some (Type_metadata_format.fallback_hover_type_view ty)
      | None -> None)

let hover_code ?(details = []) line =
  let block = Printf.sprintf "```blorp\n%s\n```" line in
  match details with
  | [] -> block
  | _ -> block ^ "\n" ^ String.concat "\n" details

let detail_if_different ~label ~source ~semantic =
  if Types.types_equal source semantic then []
  else [ Printf.sprintf "%s: %s" label (type_to_string semantic) ]

let source_type_or_semantic source semantic =
  match source with Some ty -> ty | None -> semantic

(** Get hover info for an expression using the environment *)
let hover_info_for_expr (env : Env.env) (e : expr) : string option =
  match e.expr_desc with
  | EIdent name -> (
      match Env.lookup env name with
      | Some { kind = Env.FuncSymbol { func_type; purity; _ }; _ } -> (
          let pure_str =
            match purity with Env.Pure -> "pure " | Env.Impure -> ""
          in
          match expr_type_view ~fallback_ty:func_type e with
          | Some view ->
              Some
                (hover_code ~details:view.details
                   (Printf.sprintf "%sfunc %s: %s" pure_str name
                      view.primary_type))
          | None -> None)
      | Some
          { kind = Env.VarSymbol { var_type; source_type; mutability; _ }; _ }
        -> (
          let mut_str =
            match mutability with Env.Mutable -> "var " | Env.Immutable -> ""
          in
          let fallback_ty = Option.value source_type ~default:var_type in
          match expr_type_view ~fallback_ty e with
          | Some view ->
              Some
                (hover_code ~details:view.details
                   (Printf.sprintf "%s%s: %s" mut_str name view.primary_type))
          | None -> None)
      | Some { kind = Env.TypeSymbol { type_params; variants; _ }; _ } ->
          let params_str = Lsp_protocol.format_type_params type_params in
          let variants_str =
            String.concat "\n"
              (List.map
                 (fun (v : Ast.variant) ->
                   let fields =
                     Lsp_protocol.format_field_types v.variant_fields
                   in
                   "    " ^ v.variant_name ^ fields)
                 variants)
          in
          Some
            (Printf.sprintf "```blorp\nunion %s%s:\n%s\n```" name params_str
               variants_str)
      | Some { kind = Env.RecordSymbol { type_params; fields; is_value }; _ } ->
          let params_str = Lsp_protocol.format_type_params type_params in
          let fields_str =
            String.concat ", "
              (List.map
                 (fun (f : Ast.field_decl) ->
                   f.field_name ^ ": " ^ Types.type_to_string f.field_type)
                 fields)
          in
          let keyword = if is_value then "struct" else "record" in
          Some
            (Printf.sprintf "```blorp\n%s %s%s {%s}\n```" keyword name
               params_str fields_str)
      | Some { kind = Env.ConstructorSymbol { parent_type; field_types; _ }; _ }
        ->
          let fields = Lsp_protocol.format_field_types field_types in
          Some
            (Printf.sprintf "```blorp\n%s%s  (from %s)\n```" name fields
               parent_type)
      | Some { kind = Env.AliasSymbol { type_params; target }; _ } ->
          let params_str = Lsp_protocol.format_type_params type_params in
          Some
            (Printf.sprintf "```blorp\nalias %s%s = %s\n```" name params_str
               (Types.type_to_string target))
      | Some { kind = Env.NewTypeSymbol { type_params; target }; _ } ->
          let params_str = Lsp_protocol.format_type_params type_params in
          Some
            (Printf.sprintf "```blorp\nnew type %s%s = %s\n```" name params_str
               (Types.type_to_string target))
      | None -> None)
  | EFieldAccess (_, field_name) -> (
      match expr_type_view e with
      | Some view ->
          Some
            (hover_code ~details:view.details
               (Printf.sprintf ".%s: %s" field_name view.primary_type))
      | None -> None)
  | _ -> (
      match expr_type_view e with
      | Some view -> Some (hover_code ~details:view.details view.primary_type)
      | None -> None)

(** Get hover info for a declaration *)
let hover_info_for_decl (d : decl) : string option =
  match d.decl_desc with
  | DFunc fd ->
      let name = match fd.func_name with Some n -> n | None -> "<lambda>" in
      let label, _ = Lsp_protocol.format_func_decl fd name in
      let doc = match d.decl_doc with Some d -> d ^ "\n\n" | None -> "" in
      Some (Printf.sprintf "%s```blorp\n%s\n```" doc label)
  | _ -> None

let hover_info_for_typed_func (func : Typed_ast.func_decl) =
  let ast = Typed_ast.func_ast func in
  let name = match ast.func_name with Some n -> n | None -> "<lambda>" in
  let label, _ = Lsp_protocol.format_func_decl ast name in
  let info = Typed_ast.func_info func in
  let details =
    match info.source_return_ty with
    | Some source ->
        detail_if_different ~label:"canonical return type" ~source
          ~semantic:(Typed_ast.func_semantic_return_type func)
    | None -> []
  in
  Some (hover_code ~details label)

let hover_info_for_typed_var (var : Typed_ast.var_decl) =
  let ast = Typed_ast.var_ast var in
  let info = Typed_ast.var_info var in
  match ast.var_name with
  | None -> None
  | Some name ->
      let source_ty =
        source_type_or_semantic info.source_binding_ty info.binding_ty
      in
      let mut_str = if ast.var_is_mutable then "var " else "" in
      let label =
        Printf.sprintf "%s%s: %s" mut_str name (type_to_string source_ty)
      in
      let details =
        detail_if_different ~label:"canonical binding type" ~source:source_ty
          ~semantic:info.binding_ty
      in
      Some (hover_code ~details label)

let hover_info_for_typed_record (record : Typed_ast.record_decl) =
  let ast = Typed_ast.record_ast record in
  let params_str =
    ast.record_type_params |> Ast.type_param_names
    |> Lsp_protocol.format_type_params
  in
  let field_infos = Typed_ast.record_field_infos record in
  let fields =
    field_infos
    |> List.map (fun (field : Typed_ast.record_field_info) ->
        Printf.sprintf "%s: %s" field.field_name
          (type_to_string field.source_field_ty))
    |> String.concat ", "
  in
  let details =
    field_infos
    |> List.concat_map (fun (field : Typed_ast.record_field_info) ->
        detail_if_different
          ~label:(field.field_name ^ " canonical type")
          ~source:field.source_field_ty ~semantic:field.semantic_field_ty)
  in
  let keyword = if ast.record_is_value then "struct" else "record" in
  Some
    (hover_code ~details
       (Printf.sprintf "%s %s%s {%s}" keyword ast.record_name params_str fields))

let hover_info_for_typed_type_alias (alias : Typed_ast.type_alias_decl) =
  let ast = Typed_ast.type_alias_ast alias in
  let info = Typed_ast.type_alias_info alias in
  let params_str =
    ast.alias_type_params |> Ast.type_param_names
    |> Lsp_protocol.format_type_params
  in
  let details =
    detail_if_different ~label:"canonical target" ~source:info.source_target_ty
      ~semantic:info.semantic_target_ty
  in
  Some
    (hover_code ~details
       (Printf.sprintf "alias %s%s = %s" ast.alias_name params_str
          (type_to_string info.source_target_ty)))

let hover_info_for_typed_param ~(name : string) ~(source_ty : Ast.type_expr)
    ~(semantic_ty : Ast.type_expr) =
  let details =
    detail_if_different ~label:"canonical parameter type" ~source:source_ty
      ~semantic:semantic_ty
  in
  hover_code ~details (Printf.sprintf "%s: %s" name (type_to_string source_ty))

(** Get hover info for a typed declaration. *)
let rec hover_info_for_typed_decl (d : Typed_ast.decl) : string option =
  match Typed_ast.decl_view d with
  | DeclFunction func -> hover_info_for_typed_func func
  | DeclVar var -> hover_info_for_typed_var var
  | DeclRecord record -> hover_info_for_typed_record record
  | DeclTypeAlias alias -> hover_info_for_typed_type_alias alias
  | DeclPrivate inner -> hover_info_for_typed_decl inner
  | DeclImpl _ | DeclOther -> hover_info_for_decl (Typed_ast.decl_ast d)
