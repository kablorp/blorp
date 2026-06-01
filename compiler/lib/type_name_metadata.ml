(** Canonical source-level type names that several compiler phases need to
    recognize after imports, mangling, or module qualification. Keep these
    string facts centralized so ownership and layout policy cannot drift. *)

let std_stream_type_names simple_name =
  [ simple_name; "std_stream__" ^ simple_name; "std/stream::" ^ simple_name ]

let string_member name names = List.exists (String.equal name) names

let is_std_stream_type simple_name name =
  match Types.split_canonical_module_type_name name with
  | Some (module_path, type_name) ->
      String.equal module_path "std/stream"
      && String.equal type_name simple_name
  | None -> string_member name (std_stream_type_names simple_name)

let is_stream_name = is_std_stream_type "Stream"
let is_fallible_stream_name = is_std_stream_type "FallibleStream"
let is_resource_source_name = is_std_stream_type "ResourceSource"

let is_one_shot_stream_name name =
  is_stream_name name || is_fallible_stream_name name
