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
let mod_file = "std/file"
let mod_regex = "std/regex"
let mod_dns = "std/net/dns"
let mod_tcp = "std/net/tcp"
let mod_tls = "std/net/tls"
let mod_udp = "std/net/udp"
let mod_websocket = "std/net/websocket"

(** Sanitize a module path for use as a C identifier prefix.
    [std/list] → [std_list], [./utils] → [__utils]. *)
let sanitize_module_name name =
  String.map (function '/' -> '_' | '.' -> '_' | c -> c) name

let is_c_ident_char c =
  (c >= 'a' && c <= 'z')
  || (c >= 'A' && c <= 'Z')
  || (c >= '0' && c <= '9')
  || c = '_'

(** Sanitize an arbitrary source name for use inside a C identifier.
    Maps every character that isn't [A-Za-z0-9_] to underscore. Used by
    [mangle_by_def_id] so names containing [/], [.], [$], [#], [:],
    etc. produce valid C symbols. Letters / digits / underscores pass
    through unchanged. *)
let sanitize_c_ident name =
  String.map (fun c -> if is_c_ident_char c then c else '_') name

(** Mangle a user-defined symbol's C name from its DefId and source name.
    Format: [__def_<id>_<sanitized_name>] where [sanitized_name] has
    non-identifier characters mapped to underscore.

    {b Bypass rules} — these symbols MUST NOT pass through this function:
    - Foreign functions ([CFForeign { c_name }]) use their user-specified
      [c_name] verbatim.
    - Runtime builtins ([CKBuiltin]) emit the fixed [blorp_*] name from
      [Codegen_builtins.builtin_c_mapping].
    - The root program entrypoint keeps the bare C name [main] so the C
      linker can find it.

    {b Stability} — two calls with equal [(id, name)] arguments produce
    the same string. The function is pure. *)
let mangle_by_def_id (id : int) (name : string) : string =
  Printf.sprintf "__def_%d_%s" id (sanitize_c_ident name)

let ufcs_prefix = "__ufcs_"

let has_prefix prefix name =
  let prefix_len = String.length prefix in
  String.length name > prefix_len && String.sub name 0 prefix_len = prefix

let decode_ufcs_module_part mod_part =
  String.map (fun c -> if c = '$' then '/' else c) mod_part

(** Parse a __ufcs_ mangled name into (module_path, original_name).
    Returns None if the name doesn't have the __ufcs_ prefix.
    Encoding: __ufcs_std$list__get → ("std/list", "get") *)
let parse_ufcs_name (name : string) : (string * string) option =
  if has_prefix ufcs_prefix name then
    let prefix_len = String.length ufcs_prefix in
    let rest = String.sub name prefix_len (String.length name - prefix_len) in
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
        Some (decode_ufcs_module_part mod_part, func_name)
    | None -> None
  else None
