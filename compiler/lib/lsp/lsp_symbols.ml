(** LSP document symbols handler.

    Walks the parsed AST and emits hierarchical DocumentSymbol objects
    for the outline view. *)

open Ast
open Lsp_json

(* ============================================================================
   Symbol kind constants
   ============================================================================ *)

let kind_class = 5
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

(* ============================================================================
   AST walking
   ============================================================================ *)

(** Convert a declaration to a DocumentSymbol *)
let rec decl_to_symbol (d : decl) : json option =
  match d.decl_desc with
  | DFunc fd ->
      let name = match fd.func_name with Some n -> n | None -> "<lambda>" in
      let range = loc_to_range d.decl_loc in
      let sel = selection_range d.decl_loc (String.length name) in
      Some
        (document_symbol ~name ~kind:kind_function ~range ~selection_range:sel
           ())
  | DType td ->
      let range = loc_to_range d.decl_loc in
      let sel = selection_range d.decl_loc (String.length td.type_name) in
      let children =
        List.map
          (fun (v : variant) ->
            let vrange = loc_to_range v.variant_loc in
            let vsel =
              selection_range v.variant_loc (String.length v.variant_name)
            in
            document_symbol ~name:v.variant_name ~kind:kind_enum_member
              ~range:vrange ~selection_range:vsel ())
          td.type_variants
      in
      Some
        (document_symbol ~name:td.type_name ~kind:kind_class ~range
           ~selection_range:sel ~children ())
  | DRecord rd ->
      let range = loc_to_range d.decl_loc in
      let sel = selection_range d.decl_loc (String.length rd.record_name) in
      let k = if rd.record_is_value then kind_struct else kind_class in
      let children =
        List.map
          (fun (f : field_decl) ->
            let frange = loc_to_range f.field_loc in
            let fsel =
              selection_range f.field_loc (String.length f.field_name)
            in
            document_symbol ~name:f.field_name ~kind:kind_property ~range:frange
              ~selection_range:fsel ())
          rd.record_fields
      in
      Some
        (document_symbol ~name:rd.record_name ~kind:k ~range
           ~selection_range:sel ~children ())
  | DVar vd ->
      let name = match vd.var_name with Some n -> n | None -> "_" in
      let range = loc_to_range d.decl_loc in
      let sel = selection_range d.decl_loc (String.length name) in
      Some
        (document_symbol ~name ~kind:kind_variable ~range ~selection_range:sel
           ())
  | DTrait td ->
      let range = loc_to_range d.decl_loc in
      let sel = selection_range d.decl_loc (String.length td.trait_name) in
      let children =
        List.map
          (fun (m : trait_method) ->
            let mrange = loc_to_range d.decl_loc in
            (* methods don't have own loc *)
            let msel =
              selection_range d.decl_loc (String.length m.method_name)
            in
            document_symbol ~name:m.method_name ~kind:kind_method ~range:mrange
              ~selection_range:msel ())
          td.trait_methods
      in
      Some
        (document_symbol ~name:td.trait_name ~kind:kind_interface ~range
           ~selection_range:sel ~children ())
  | DImpl impl ->
      let name =
        Printf.sprintf "%s for %s" impl.impl_trait
          (Types.type_to_string impl.impl_for_type)
      in
      let range = loc_to_range d.decl_loc in
      let sel = selection_range d.decl_loc (String.length name) in
      let children =
        List.map
          (fun (fd : func_decl) ->
            let mname = match fd.func_name with Some n -> n | None -> "_" in
            let mrange = loc_to_range d.decl_loc in
            let msel = selection_range d.decl_loc (String.length mname) in
            document_symbol ~name:mname ~kind:kind_method ~range:mrange
              ~selection_range:msel ())
          impl.impl_methods
      in
      Some
        (document_symbol ~name ~kind:kind_class ~range ~selection_range:sel
           ~children ())
  | DTypeAlias ad ->
      let range = loc_to_range d.decl_loc in
      let sel = selection_range d.decl_loc (String.length ad.alias_name) in
      Some
        (document_symbol ~name:ad.alias_name ~kind:kind_class ~range
           ~selection_range:sel ())
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
