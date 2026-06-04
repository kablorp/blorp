(** Canonical source-level type names that several compiler phases need to
    recognize after imports, mangling, or module qualification. Keep these
    string facts centralized so ownership and layout policy cannot drift. *)

let is_stream_name = function
  | "Stream" | "std_stream__Stream" | "std/stream::Stream" -> true
  | _ -> false

let is_fallible_stream_name = function
  | "FallibleStream" | "std_stream__FallibleStream"
  | "std/stream::FallibleStream" ->
      true
  | _ -> false

let is_resource_source_name = function
  | "ResourceSource" | "std_stream__ResourceSource"
  | "std/stream::ResourceSource" ->
      true
  | _ -> false

let is_one_shot_stream_name name =
  is_stream_name name || is_fallible_stream_name name
