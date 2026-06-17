(** LSP document symbols handler.

    Walks the parsed AST and emits hierarchical DocumentSymbol objects
    for the outline view. *)

open Ast
open Lsp_json

(* ============================================================================
   Symbol kind constants
   ============================================================================ *)

let kind_class = 5
let kind_namespace = 3
let kind_method = 6
let kind_property = 7
let kind_interface = 8
let kind_function = 12
let kind_variable = 13
let kind_enum_member = 14
let kind_struct = 22

(* ============================================================================
   Range helpers
   ============================================================================ *)

(** Build an LSP range from a blorp loc *)
let loc_to_range (loc : loc) : json =
  Lsp_protocol.loc_to_range loc |> Lsp_protocol.range_to_json

let position_to_json line character =
  Lsp_protocol.position_to_json { line; character }

(** Build a selection range (just the name) from loc + name length *)
let selection_range (loc : loc) (name_len : int) : json =
  let line = max 0 (loc.line - 1) in
  let col = max 0 (loc.column - 1) in
  Object
    [
      ("start", position_to_json line col);
      ("end", position_to_json line (col + name_len));
    ]

(* ============================================================================
   Symbol builders
   ============================================================================ *)

let document_symbol ~name ~kind ~range ~selection_range ?(children = []) () :
    json =
  let base =
    [
      ("name", String name);
      ("kind", Int kind);
      ("range", range);
      ("selectionRange", selection_range);
    ]
  in
  if children = [] then Object base
  else Object (base @ [ ("children", Array children) ])

let symbol_at ?(children = []) ~name ~kind loc =
  let range = loc_to_range loc in
  let selection_range = selection_range loc (String.length name) in
  document_symbol ~name ~kind ~range ~selection_range ~children ()

(* ============================================================================
   AST walking
   ============================================================================ *)

(** Convert a declaration to a DocumentSymbol *)
let rec decl_to_symbol (d : decl) : json option =
  match d.decl_desc with
  | DFunc fd ->
      let name = match fd.func_name with Some n -> n | None -> "<lambda>" in
      Some (symbol_at ~name ~kind:kind_function d.decl_loc)
  | DType td ->
      let children =
        List.map
          (fun (v : variant) ->
            symbol_at ~name:v.variant_name ~kind:kind_enum_member v.variant_loc)
          td.type_variants
      in
      Some (symbol_at ~name:td.type_name ~kind:kind_class ~children d.decl_loc)
  | DRecord rd ->
      let k = if rd.record_is_value then kind_struct else kind_class in
      let children =
        List.map
          (fun (f : field_decl) ->
            symbol_at ~name:f.field_name ~kind:kind_property f.field_loc)
          rd.record_fields
      in
      Some (symbol_at ~name:rd.record_name ~kind:k ~children d.decl_loc)
  | DVar vd ->
      let name = match vd.var_name with Some n -> n | None -> "_" in
      Some (symbol_at ~name ~kind:kind_variable d.decl_loc)
  | DTrait td ->
      let children =
        List.map
          (fun (m : trait_method) ->
            (* methods don't have own loc *)
            symbol_at ~name:m.method_name ~kind:kind_method d.decl_loc)
          td.trait_methods
      in
      Some
        (symbol_at ~name:td.trait_name ~kind:kind_interface ~children d.decl_loc)
  | DImpl impl ->
      let name =
        Printf.sprintf "%s for %s" impl.impl_trait
          (Types.type_to_string impl.impl_for_type)
      in
      let children =
        List.map
          (fun (fd : func_decl) ->
            let mname = match fd.func_name with Some n -> n | None -> "_" in
            symbol_at ~name:mname ~kind:kind_method d.decl_loc)
          impl.impl_methods
      in
      Some (symbol_at ~name ~kind:kind_class ~children d.decl_loc)
  | DTypeAlias ad ->
      Some (symbol_at ~name:ad.alias_name ~kind:kind_class d.decl_loc)
  | DImport _ -> None
  | DPrivate inner -> decl_to_symbol inner

(* ============================================================================
   Main handler
   ============================================================================ *)

let handle_document_symbols (state : Lsp_state.state) (params : json) : json =
  let td = get "textDocument" params in
  match td with
  | Some td -> (
      let uri = Lsp_protocol.get_uri td in
      match Lsp_state.find_document state uri with
      | Some doc -> (
          match doc.program with
          | Some program ->
              let symbols = List.filter_map decl_to_symbol program in
              Array symbols
          | None -> Array [])
      | None -> Array [])
  | None -> Array []
