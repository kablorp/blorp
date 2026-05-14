(** C naming helpers and module-path constants for codegen.

    Keep this module lean: only define names that have active call sites.
    Type, trait, and constructor names mostly appear in OCaml pattern
    matches, where constants cannot be used directly. *)

(* ============================================================================
   Module Paths (canonical std/ names)
   ============================================================================ *)

let mod_list = "std/list"
let mod_string = "std/string"
let mod_dict = "std/dict"
let mod_set = "std/set"
let mod_tensor = "std/tensor"
let mod_vector = "std/vector"
let mod_matrix = "std/matrix"
let mod_bytes = "std/bytes"
let mod_stream = "std/stream"
let mod_regex = "std/regex"
let mod_tcp = "std/net/tcp"

(** Sanitize a module path for use as a C identifier prefix.
    [std/list] → [std_list], [./utils] → [__utils]. *)
let sanitize_module_name name =
  String.map (function '/' -> '_' | '.' -> '_' | c -> c) name

let starts_with s prefix =
  let slen = String.length s in
  let plen = String.length prefix in
  slen >= plen && String.sub s 0 plen = prefix

let ends_with s suffix =
  let slen = String.length s in
  let suffix_len = String.length suffix in
  slen >= suffix_len && String.sub s (slen - suffix_len) suffix_len = suffix

let strip_mono_suffix name =
  let marker = "__mono_" in
  let marker_len = String.length marker in
  let rec find i =
    if i + marker_len > String.length name then name
    else if String.sub name i marker_len = marker then String.sub name 0 i
    else find (i + 1)
  in
  find 0

(** Recover the source-level function name from a generated Core function name.
    This strips a monomorphization suffix, the owning module prefix when present,
    and the stdlib pure-overload suffix. *)
let source_name_for_generated_function ?module_path name =
  let source_name = strip_mono_suffix name in
  let source_name =
    match module_path with
    | None -> source_name
    | Some module_path ->
        let prefix = sanitize_module_name module_path ^ "__" in
        if starts_with source_name prefix then
          String.sub source_name (String.length prefix)
            (String.length source_name - String.length prefix)
        else source_name
  in
  let pure_suffix = "__pure" in
  if ends_with source_name pure_suffix then
    String.sub source_name 0
      (String.length source_name - String.length pure_suffix)
  else source_name

(** Sanitize an arbitrary source name for use inside a C identifier.
    Maps every character that isn't [A-Za-z0-9_] to underscore. Used by
    [mangle_by_def_id] so names containing [/], [.], [$], [#], [:],
    etc. produce valid C symbols. Letters / digits / underscores pass
    through unchanged. *)
let sanitize_c_ident name =
  String.map
    (fun c ->
      if
        (c >= 'a' && c <= 'z')
        || (c >= 'A' && c <= 'Z')
        || (c >= '0' && c <= '9')
        || c = '_'
      then c
      else '_')
    name

(** Mangle a user-defined symbol's C name from its DefId and source name.
    Format: [__def_<id>_<sanitized_name>] where [sanitized_name] has
    non-identifier characters mapped to underscore.

    {b Bypass rules} — these symbols MUST NOT pass through this function:
    - Foreign functions ([CFForeign { c_name }]) use their user-specified
      [c_name] verbatim.
    - Runtime builtins ([CKBuiltin]) emit the fixed [blorp_*] name from
      [Codegen_builtins.builtin_c_mapping].
    - The program entry point [main] keeps its bare name so the C linker
      can find it.

    {b Stability} — two calls with equal [(id, name)] arguments produce
    the same string. The function is pure. *)
let mangle_by_def_id (id : int) (name : string) : string =
  Printf.sprintf "__def_%d_%s" id (sanitize_c_ident name)

(** Parse a __ufcs_ mangled name into (module_path, original_name).
    Returns None if the name doesn't have the __ufcs_ prefix.
    Encoding: __ufcs_std$list__get → ("std/list", "get") *)
let parse_ufcs_name (name : string) : (string * string) option =
  let prefix = "__ufcs_" in
  let plen = String.length prefix in
  if String.length name > plen && String.sub name 0 plen = prefix then
    let rest = String.sub name plen (String.length name - plen) in
    let rec find_sep i =
      if i < 1 then None
      else if rest.[i] = '_' && rest.[i - 1] = '_' then Some (i - 1)
      else find_sep (i - 1)
    in
    match find_sep (String.length rest - 1) with
    | Some sep_pos ->
        let mod_part = String.sub rest 0 sep_pos in
        let func_name =
          String.sub rest (sep_pos + 2) (String.length rest - sep_pos - 2)
        in
        let module_path =
          String.map (fun c -> if c = '$' then '/' else c) mod_part
        in
        Some (module_path, func_name)
    | None -> None
  else None
