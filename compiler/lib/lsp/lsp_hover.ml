(** LSP hover info generation.

    Produces markdown-formatted hover text for expressions and
    declarations, showing type signatures and documentation. *)

open Ast

let type_to_string = Types.type_to_string
let expr_type_view = Type_metadata_format.hover_type_view_for_expr

let hover_code ?(details = []) line =
  let block = Printf.sprintf "```blorp\n%s\n```" line in
  match details with
  | [] -> block
  | _ -> block ^ "\n" ^ String.concat "\n" details

let doc_prefix = function Some doc -> doc ^ "\n\n" | None -> ""

let detail_if_different ~label ~source ~semantic =
  if Types.types_equal source semantic then []
  else [ Printf.sprintf "%s: %s" label (type_to_string semantic) ]

let source_type_or_semantic source semantic =
  match source with Some ty -> ty | None -> semantic

let purity_prefix = function Env.Pure -> "pure " | Env.Impure -> ""
let mutability_prefix = function Env.Mutable -> "var " | Env.Immutable -> ""

let variant_label (variant : Ast.variant) =
  let fields = Lsp_protocol.format_field_types variant.variant_fields in
  "    " ^ variant.variant_name ^ fields

let field_decl_label (field : Ast.field_decl) =
  field.field_name ^ ": " ^ Types.type_to_string field.field_type

let record_keyword ~is_value = if is_value then "struct" else "record"

let hover_for_func_symbol name expr ~func_type ~purity =
  match expr_type_view ~fallback_ty:func_type expr with
  | Some view ->
      let label =
        Printf.sprintf "%sfunc %s: %s" (purity_prefix purity) name
          view.primary_type
      in
      Some (hover_code ~details:view.details label)
  | None -> None

let hover_for_var_symbol name expr ~var_type ~source_type ~mutability =
  let fallback_ty = Option.value source_type ~default:var_type in
  match expr_type_view ~fallback_ty expr with
  | Some view ->
      let label =
        Printf.sprintf "%s%s: %s"
          (mutability_prefix mutability)
          name view.primary_type
      in
      Some (hover_code ~details:view.details label)
  | None -> None

let hover_for_type_symbol name ~type_params ~variants =
  let params_str = Lsp_protocol.format_type_params type_params in
  let variants_str = variants |> List.map variant_label |> String.concat "\n" in
  Some
    (Printf.sprintf "```blorp\nunion %s%s:\n%s\n```" name params_str
       variants_str)

let hover_for_record_symbol name ~type_params ~fields ~is_value =
  let params_str = Lsp_protocol.format_type_params type_params in
  let fields_str = fields |> List.map field_decl_label |> String.concat ", " in
  Some
    (Printf.sprintf "```blorp\n%s %s%s {%s}\n```" (record_keyword ~is_value)
       name params_str fields_str)

let hover_for_constructor_symbol name ~parent_type ~field_types =
  let fields = Lsp_protocol.format_field_types field_types in
  Some (Printf.sprintf "```blorp\n%s%s  (from %s)\n```" name fields parent_type)

let hover_for_alias_symbol name ~type_params ~target =
  let params_str = Lsp_protocol.format_type_params type_params in
  Some
    (Printf.sprintf "```blorp\nalias %s%s = %s\n```" name params_str
       (Types.type_to_string target))

let hover_info_for_symbol name expr (symbol : Env.symbol) =
  match symbol.kind with
  | Env.FuncSymbol { func_type; purity; _ } ->
      hover_for_func_symbol name expr ~func_type ~purity
  | Env.VarSymbol { var_type; source_type; mutability; _ } ->
      hover_for_var_symbol name expr ~var_type ~source_type ~mutability
  | Env.TypeSymbol { type_params; variants; _ } ->
      hover_for_type_symbol name ~type_params ~variants
  | Env.RecordSymbol { type_params; fields; is_value; _ } ->
      hover_for_record_symbol name ~type_params ~fields ~is_value
  | Env.ConstructorSymbol { parent_type; field_types; _ } ->
      hover_for_constructor_symbol name ~parent_type ~field_types
  | Env.AliasSymbol { type_params; target } ->
      hover_for_alias_symbol name ~type_params ~target
  | Env.OpaqueAliasSymbol { type_params; target; _ } ->
      let params_str = Lsp_protocol.format_type_params type_params in
      Some
        (hover_code
           (Printf.sprintf "opaque type %s%s = %s" name params_str
              (Types.type_to_string target)))

(** Get hover info for an expression using the environment *)
let hover_info_for_expr (env : Env.env) (e : expr) : string option =
  match e.expr_desc with
  | EIdent name -> (
      match Env.lookup env name with
      | Some symbol -> hover_info_for_symbol name e symbol
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
      Some (doc_prefix d.decl_doc ^ hover_code label)
  | _ -> None

let hover_info_for_typed_func ?doc (func : Typed_ast.func_decl) =
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
  Some (doc_prefix doc ^ hover_code ~details label)

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
  | DeclFunction func ->
      let doc = (Typed_ast.decl_ast d).decl_doc in
      hover_info_for_typed_func ?doc func
  | DeclVar var -> hover_info_for_typed_var var
  | DeclRecord record -> hover_info_for_typed_record record
  | DeclTypeAlias alias -> hover_info_for_typed_type_alias alias
  | DeclPrivate inner -> hover_info_for_typed_decl inner
  | DeclImpl _ | DeclOther -> hover_info_for_decl (Typed_ast.decl_ast d)
