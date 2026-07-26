(** Shared callable-name normalization for selected Core calls.

    Definition IDs are local to frontend module artifacts. Once those
    artifacts are merged, a callable is identified by its definition ID and
    its source member identity. Imported callees preserve that identity with a
    lossless UFCS name; declarations preserve it with [cf_module] because
    flattened [cf_name] prefixes are lossy. *)

open Core

let has_prefix prefix value =
  let prefix_length = String.length prefix in
  String.length value >= prefix_length
  && String.sub value 0 prefix_length = prefix

let has_suffix suffix value =
  let suffix_length = String.length suffix in
  let value_length = String.length value in
  value_length >= suffix_length
  && String.sub value (value_length - suffix_length) suffix_length = suffix

let module_qualified_name module_path source_name =
  let prefix = Codegen_names.sanitize_module_name module_path ^ "__" in
  if has_prefix prefix source_name then source_name else prefix ^ source_name

let source_member_name (func : core_func) =
  let source_name =
    match func.cf_module with
    | None -> func.cf_name
    | Some module_path ->
        let prefix = Codegen_names.sanitize_module_name module_path ^ "__" in
        if has_prefix prefix func.cf_name then
          String.sub func.cf_name (String.length prefix)
            (String.length func.cf_name - String.length prefix)
        else func.cf_name
  in
  let pure_suffix = "__pure" in
  if has_suffix pure_suffix source_name then
    String.sub source_name 0
      (String.length source_name - String.length pure_suffix)
  else source_name

let declaration_name (func : core_func) =
  match func.cf_module with
  | None -> func.cf_name
  | Some module_path -> module_qualified_name module_path func.cf_name

let ufcs_source_name_for_module module_path callee_name =
  let module_prefix = Codegen_names.make_ufcs_name module_path "" in
  if has_prefix module_prefix callee_name then
    Some
      (String.sub callee_name (String.length module_prefix)
         (String.length callee_name - String.length module_prefix))
  else None

let is_ufcs_name name = has_prefix Codegen_names.ufcs_prefix name

let selected_callee_matches_function ~(callee_name : string) (func : core_func) =
  let source_name = source_member_name func in
  let canonical_name = declaration_name func in
  if is_ufcs_name callee_name then
    match func.cf_module with
    | Some module_path -> (
        match ufcs_source_name_for_module module_path callee_name with
        | Some selected_source_name ->
            String.equal source_name selected_source_name
        | None -> false)
    | None -> (
        match Codegen_names.parse_ufcs_name callee_name with
        | Some (module_path, selected_source_name) ->
            String.equal canonical_name
              (module_qualified_name module_path selected_source_name)
            && String.equal source_name selected_source_name
        | None -> false)
  else
      String.equal source_name callee_name
      || String.equal canonical_name callee_name
      || (match func.cf_module with
         | Some module_path ->
             String.equal
               (module_qualified_name module_path source_name)
               callee_name
         | None -> false)
